//! Host metrics sampled from `/proc` and `/sys`, plus a rolling load history
//! that backs a `sparkline`.  Pure sampling — it knows nothing about DVUI or
//! the layout engine, so anything can consume it.
//!
//! Values are published into the layout engine by `dashboard.publishMetrics`,
//! which is where the `/proc` keys and the `.layout.zon` bindings meet.

const std = @import("std");
const posix = std.posix;

pub const SystemMetrics = struct {
    tick: u32 = 0,

    hostname: [64]u8 = @splat(0),
    kernel: [64]u8 = @splat(0),
    cpu_model: [72]u8 = @splat(0),
    load: [3]f32 = .{ 0, 0, 0 },
    cpu_count: u32 = 0,
    cpu_util_pct: f32 = 0,
    cpu_prev_total: u64 = 0,
    cpu_prev_idle: u64 = 0,
    uptime_s: u64 = 0,
    mem_total_kb: u64 = 0,
    mem_avail_kb: u64 = 0,
    temp_c: f32 = 0,

    /// Network throughput of the default-route interface (or all non-lo
    /// interfaces when there is no default route).
    net_iface: [16]u8 = @splat(0),
    net_rx_kbs: f32 = 0,
    net_tx_kbs: f32 = 0,
    net_rx_total: u64 = 0,
    net_tx_total: u64 = 0,
    net_prev_rx: u64 = 0,
    net_prev_tx: u64 = 0,
    net_prev_ms: i128 = 0,

    fps: f32 = 0,
    frame_count: u64 = 0,
    fps_frames: u32 = 0,
    last_sample_ms: i128 = 0,
    last_fps_ms: i128 = 0,

    /// Pre-formatted values for dynamic labels in the layout.
    load_text: [64]u8 = @splat(0),
    cpu_text: [32]u8 = @splat(0),
    uptime_text: [40]u8 = @splat(0),
    mem_text: [64]u8 = @splat(0),
    net_text: [72]u8 = @splat(0),
    net_total_text: [64]u8 = @splat(0),

    /// Rolling one-per-second load history (newest last).
    load_hist: [48]f32 = @splat(0),
    load_hist_len: u32 = 0,

    pub fn nowMs() i128 {
        var ts: posix.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1000 + @divTrunc(@as(i128, ts.nsec), std.time.ns_per_ms);
    }

    /// True when the `/proc` files are due for another read (~1 s).
    pub fn shouldSample(self: *const SystemMetrics) bool {
        return nowMs() - self.last_sample_ms > 1000;
    }

    /// Call once per frame: updates the frame rate and appends a load sample
    /// every second.
    pub fn updateFrameStats(self: *SystemMetrics) void {
        self.frame_count += 1;
        self.fps_frames += 1;
        const now = nowMs();
        if (now - self.last_fps_ms >= 1000) {
            self.fps = @as(f32, @floatFromInt(self.fps_frames)) * 1000.0 / @as(f32, @floatFromInt(now - self.last_fps_ms));
            self.fps_frames = 0;
            self.last_fps_ms = now;

            std.mem.copyForwards(f32, self.load_hist[0 .. self.load_hist.len - 1], self.load_hist[1..]);
            self.load_hist[self.load_hist.len - 1] = self.load[0];
            if (self.load_hist_len < self.load_hist.len) self.load_hist_len += 1;
        }
    }

    /// The newest `load_hist_len` samples, oldest first.
    pub fn loadHistory(self: *const SystemMetrics) []const f32 {
        if (self.load_hist_len == 0) return &.{};
        const start = self.load_hist.len - self.load_hist_len;
        return self.load_hist[start..];
    }

    /// Re-read the system files.
    pub fn sample(self: *SystemMetrics) void {
        const now = nowMs();
        self.last_sample_ms = now;

        var buf: [2048]u8 = undefined;
        if (readSmallFile("/proc/sys/kernel/hostname", &buf)) |data| copyTrimmed(&self.hostname, data);
        if (readSmallFile("/proc/sys/kernel/osrelease", &buf)) |data| copyTrimmed(&self.kernel, data);

        if (readSmallFile("/proc/loadavg", &buf)) |data| {
            var toks = std.mem.tokenizeAny(u8, data, " \n");
            for (&self.load) |*l| {
                l.* = std.fmt.parseFloat(f32, toks.next() orelse break) catch 0;
            }
        }
        formatInto(&self.load_text, "load  {d:.2}  {d:.2}  {d:.2}", .{ self.load[0], self.load[1], self.load[2] });

        if (readSmallFile("/proc/cpuinfo", &buf)) |data| {
            var count: u32 = 0;
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |line| {
                if (std.mem.startsWith(u8, line, "processor")) count += 1;
            }
            if (count > 0) self.cpu_count = count;
            if (findCpuModel(data)) |model| copyTrimmed(&self.cpu_model, model);
        }
        formatInto(&self.cpu_text, "{d} cores", .{self.cpu_count});

        if (readSmallFile("/proc/stat", &buf)) |data| {
            if (parseCpuTimes(data)) |times| {
                self.cpu_util_pct = cpuUtilPercent(self.cpu_prev_total, self.cpu_prev_idle, times.total, times.idle);
                self.cpu_prev_total = times.total;
                self.cpu_prev_idle = times.idle;
            }
        }

        if (readSmallFile("/proc/uptime", &buf)) |data| {
            if (std.mem.indexOfScalar(u8, data, ' ')) |sp| {
                self.uptime_s = @intFromFloat(std.fmt.parseFloat(f64, data[0..sp]) catch 0);
            }
        }
        const days = self.uptime_s / 86400;
        if (days > 0) {
            formatInto(&self.uptime_text, "up {d}d {d:0>2}:{d:0>2}:{d:0>2}", .{
                days,
                (self.uptime_s % 86400) / 3600,
                (self.uptime_s % 3600) / 60,
                self.uptime_s % 60,
            });
        } else {
            formatInto(&self.uptime_text, "up {d}h {d:0>2}m {d:0>2}s", .{
                self.uptime_s / 3600,
                (self.uptime_s % 3600) / 60,
                self.uptime_s % 60,
            });
        }

        if (readSmallFile("/proc/meminfo", &buf)) |data| {
            self.mem_total_kb = findMeminfo(data, "MemTotal:") orelse self.mem_total_kb;
            self.mem_avail_kb = findMeminfo(data, "MemAvailable:") orelse self.mem_avail_kb;
        }
        const used_kb = self.mem_total_kb -| self.mem_avail_kb;
        formatInto(&self.mem_text, "{d:.1} / {d:.1} GiB", .{
            @as(f64, @floatFromInt(used_kb)) / 1024.0 / 1024.0,
            @as(f64, @floatFromInt(self.mem_total_kb)) / 1024.0 / 1024.0,
        });

        if (readSmallFile("/sys/class/thermal/thermal_zone0/temp", &buf)) |data| {
            const milli = std.fmt.parseInt(i64, std.mem.trim(u8, data, " \n\r\t"), 10) catch 0;
            self.temp_c = @as(f32, @floatFromInt(milli)) / 1000.0;
        }

        self.sampleNetwork(now, &buf);
    }

    fn sampleNetwork(self: *SystemMetrics, now: i128, buf: []u8) void {
        var iface_buf: [16]u8 = @splat(0);
        var have_iface = false;
        if (readSmallFile("/proc/net/route", buf)) |data| {
            if (parseDefaultRoute(data)) |name| {
                copyTrimmed(&iface_buf, name);
                have_iface = true;
            }
        }
        if (have_iface) {
            copyTrimmed(&self.net_iface, std.mem.sliceTo(&iface_buf, 0));
        } else {
            copyTrimmed(&self.net_iface, "all");
        }

        var totals: NetTotals = .{};
        if (readSmallFile("/proc/net/dev", buf)) |data| {
            const wanted: ?[]const u8 = if (have_iface) std.mem.sliceTo(&iface_buf, 0) else null;
            totals = parseNetDev(data, wanted);
        }

        const dt_ms = now - self.net_prev_ms;
        if (self.net_prev_ms != 0 and dt_ms > 0 and
            totals.rx >= self.net_prev_rx and totals.tx >= self.net_prev_tx)
        {
            const secs = @as(f32, @floatFromInt(dt_ms)) / 1000.0;
            self.net_rx_kbs = @as(f32, @floatFromInt(totals.rx - self.net_prev_rx)) / secs / 1024.0;
            self.net_tx_kbs = @as(f32, @floatFromInt(totals.tx - self.net_prev_tx)) / secs / 1024.0;
        } else {
            self.net_rx_kbs = 0;
            self.net_tx_kbs = 0;
        }

        self.net_rx_total = totals.rx;
        self.net_tx_total = totals.tx;
        self.net_prev_rx = totals.rx;
        self.net_prev_tx = totals.tx;
        self.net_prev_ms = now;

        formatInto(&self.net_text, "{s}  down {d:.1} KiB/s  up {d:.1} KiB/s", .{
            std.mem.sliceTo(&self.net_iface, 0),
            self.net_rx_kbs,
            self.net_tx_kbs,
        });
        const rx_mib = @as(f64, @floatFromInt(self.net_rx_total)) / 1024.0 / 1024.0;
        const tx_mib = @as(f64, @floatFromInt(self.net_tx_total)) / 1024.0 / 1024.0;
        if (rx_mib >= 1024.0 or tx_mib >= 1024.0) {
            formatInto(&self.net_total_text, "{s}  RX {d:.1} GiB  TX {d:.1} GiB", .{
                std.mem.sliceTo(&self.net_iface, 0),
                rx_mib / 1024.0,
                tx_mib / 1024.0,
            });
        } else {
            formatInto(&self.net_total_text, "{s}  RX {d:.1} MiB  TX {d:.1} MiB", .{
                std.mem.sliceTo(&self.net_iface, 0),
                rx_mib,
                tx_mib,
            });
        }
    }
};

const CpuTimes = struct { total: u64, idle: u64 };

/// First aggregate `cpu` line of `/proc/stat`.  Guest time is deliberately
/// excluded: Linux already counts it in `user`/`nice`.
fn parseCpuTimes(data: []const u8) ?CpuTimes {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu ")) continue;
        var vals: [8]u64 = @splat(0);
        var it = std.mem.tokenizeAny(u8, line[4..], " \t");
        var n: usize = 0;
        while (it.next()) |tok| {
            if (n == vals.len) break;
            vals[n] = std.fmt.parseInt(u64, tok, 10) catch 0;
            n += 1;
        }
        if (n < 4) return null;
        var total: u64 = 0;
        for (vals[0..n]) |v| total += v;
        const idle = vals[3] + (if (n > 4) vals[4] else 0);
        return .{ .total = total, .idle = idle };
    }
    return null;
}

fn cpuUtilPercent(prev_total: u64, prev_idle: u64, total: u64, idle: u64) f32 {
    if (prev_total == 0 or total <= prev_total) return 0;
    const d_total = total - prev_total;
    const d_idle = @min(idle -| prev_idle, d_total);
    return @as(f32, @floatFromInt(d_total - d_idle)) * 100.0 / @as(f32, @floatFromInt(d_total));
}

const NetTotals = struct { rx: u64 = 0, tx: u64 = 0 };

/// First default route (`Destination=00000000`, `RTF_UP`) in `/proc/net/route`.
fn parseDefaultRoute(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        const iface = toks.next() orelse continue;
        const dest = toks.next() orelse continue;
        _ = toks.next(); // gateway
        const flags = toks.next() orelse continue;
        if (!std.mem.eql(u8, dest, "00000000")) continue;
        const bits = std.fmt.parseInt(u16, flags, 16) catch continue;
        if (bits & 0x1 == 0) continue; // RTF_UP
        return iface;
    }
    return null;
}

/// Sum rx/tx bytes from `/proc/net/dev`.  `wanted` selects one interface;
/// `null` sums every non-loopback interface.
fn parseNetDev(data: []const u8, wanted: ?[]const u8) NetTotals {
    var totals: NetTotals = .{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next();
    _ = lines.next(); // two header lines
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const iface = std.mem.trim(u8, line[0..colon], " \t");
        if (std.mem.eql(u8, iface, "lo")) continue;
        if (wanted) |w| {
            if (!std.mem.eql(u8, iface, w)) continue;
        }

        var vals: [16][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        while (it.next()) |tok| {
            if (n == vals.len) break;
            vals[n] = tok;
            n += 1;
        }
        if (n < 9) continue;
        totals.rx += std.fmt.parseInt(u64, vals[0], 10) catch continue;
        totals.tx += std.fmt.parseInt(u64, vals[8], 10) catch continue;
    }
    return totals;
}

/// First `model name`, else `Hardware`/`Model` from `/proc/cpuinfo`.
fn findCpuModel(data: []const u8) ?[]const u8 {
    var hardware: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) continue;
        if (std.mem.eql(u8, key, "model name")) return value;
        if (std.mem.eql(u8, key, "Hardware") or std.mem.eql(u8, key, "Model")) {
            if (hardware == null) hardware = value;
        }
    }
    return hardware;
}

fn formatInto(dst: []u8, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(dst[0 .. dst.len - 1], fmt, args) catch "";
    dst[s.len] = 0;
}

pub fn copyTrimmed(dst: []u8, src: []const u8) void {
    const trimmed = std.mem.trim(u8, src, " \t\n\r");
    const n = @min(dst.len - 1, trimmed.len);
    @memcpy(dst[0..n], trimmed[0..n]);
    dst[n] = 0;
}

pub fn readSmallFile(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);
    const n = posix.read(fd, buf) catch return null;
    return buf[0..n];
}

fn findMeminfo(data: []const u8, key: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) {
            var nums = std.mem.tokenizeAny(u8, line[key.len..], " \tkB");
            const first = nums.next() orelse return null;
            return std.fmt.parseInt(u64, first, 10) catch null;
        }
    }
    return null;
}

test "load history exposes only the filled tail" {
    var m: SystemMetrics = .{};
    // Pretend we just ticked, so no sample is due yet.
    m.last_fps_ms = SystemMetrics.nowMs();
    m.last_sample_ms = SystemMetrics.nowMs();
    try std.testing.expectEqual(@as(usize, 0), m.loadHistory().len);

    m.load[0] = 1.5;
    m.updateFrameStats(); // no full second elapsed yet
    try std.testing.expectEqual(@as(usize, 0), m.loadHistory().len);

    m.last_fps_ms = SystemMetrics.nowMs() - 1500; // force the 1 s tick
    m.load[0] = 2.5;
    m.updateFrameStats();
    const hist = m.loadHistory();
    try std.testing.expectEqual(@as(usize, 1), hist.len);
    try std.testing.expectEqual(@as(f32, 2.5), hist[0]);
}

test "copyTrimmed stops at the destination size" {
    var dst: [4]u8 = undefined;
    copyTrimmed(&dst, "  hello world \n");
    // 3 usable bytes plus the NUL terminator.
    try std.testing.expectEqualStrings("hel", std.mem.sliceTo(&dst, 0));
}

test "parseCpuTimes and utilisation" {
    const data =
        \\cpu  100 20 30 400 50 10 5 5 0 0
        \\cpu0 10 2 3 40 5 1 0 0 0 0
    ;
    const t = parseCpuTimes(data).?;
    // 100+20+30+400+50+10+5+5 = 620, idle = 400+50
    try std.testing.expectEqual(@as(u64, 620), t.total);
    try std.testing.expectEqual(@as(u64, 450), t.idle);

    try std.testing.expectEqual(@as(f32, 0), cpuUtilPercent(0, 0, 620, 450));
    // 100 more total, 50 more idle => 50% busy
    try std.testing.expectEqual(@as(f32, 50), cpuUtilPercent(620, 450, 720, 500));
    // counters going backwards after a reboot
    try std.testing.expectEqual(@as(f32, 0), cpuUtilPercent(720, 500, 10, 5));
}

test "parseDefaultRoute picks the up default route" {
    const data =
        \\Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT
        \\eth0 00000000 0100A8C0 0003 0 0 100 00000000 0 0 0
        \\wlan0 0000A8C0 00000000 0001 0 0 200 00FFFFFF 0 0 0
    ;
    try std.testing.expectEqualStrings("eth0", parseDefaultRoute(data).?);
    try std.testing.expect(parseDefaultRoute("Iface\n") == null);
}

test "parseNetDev sums and filters interfaces" {
    const data =
        \\Inter-|   Receive                                                |  Transmit
        \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        \\    lo:  999 1 0 0 0 0 0 0  999 1 0 0 0 0 0 0
        \\  eth0: 1000 2 0 0 0 0 0 0 2000 3 0 0 0 0 0 0
        \\ wlan0:  300 4 0 0 0 0 0 0  500 5 0 0 0 0 0 0
    ;
    const all = parseNetDev(data, null);
    try std.testing.expectEqual(@as(u64, 1300), all.rx); // lo skipped
    try std.testing.expectEqual(@as(u64, 2500), all.tx);

    const eth = parseNetDev(data, "eth0");
    try std.testing.expectEqual(@as(u64, 1000), eth.rx);
    try std.testing.expectEqual(@as(u64, 2000), eth.tx);
}

test "findCpuModel prefers model name and falls back to Hardware" {
    const x86 =
        \\processor : 0
        \\model name : Intel(R) Core(TM) i7
    ;
    try std.testing.expectEqualStrings("Intel(R) Core(TM) i7", findCpuModel(x86).?);

    const arm =
        \\processor : 0
        \\Hardware : BCM2835
    ;
    try std.testing.expectEqualStrings("BCM2835", findCpuModel(arm).?);
}
