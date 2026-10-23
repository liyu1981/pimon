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
    load: [3]f32 = .{ 0, 0, 0 },
    cpu_count: u32 = 0,
    uptime_s: u64 = 0,
    mem_total_kb: u64 = 0,
    mem_avail_kb: u64 = 0,
    temp_c: f32 = 0,

    fps: f32 = 0,
    frame_count: u64 = 0,
    fps_frames: u32 = 0,
    last_sample_ms: i128 = 0,
    last_fps_ms: i128 = 0,

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
        self.last_sample_ms = nowMs();

        var buf: [2048]u8 = undefined;
        if (readSmallFile("/proc/sys/kernel/hostname", &buf)) |data| copyTrimmed(&self.hostname, data);
        if (readSmallFile("/proc/sys/kernel/osrelease", &buf)) |data| copyTrimmed(&self.kernel, data);
        if (readSmallFile("/proc/loadavg", &buf)) |data| {
            var toks = std.mem.tokenizeAny(u8, data, " \n");
            for (&self.load) |*l| {
                l.* = std.fmt.parseFloat(f32, toks.next() orelse break) catch 0;
            }
        }
        if (readSmallFile("/proc/cpuinfo", &buf)) |data| {
            var count: u32 = 0;
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |line| {
                if (std.mem.startsWith(u8, line, "processor")) count += 1;
            }
            if (count > 0) self.cpu_count = count;
        }
        if (readSmallFile("/proc/uptime", &buf)) |data| {
            if (std.mem.indexOfScalar(u8, data, ' ')) |sp| {
                self.uptime_s = @intFromFloat(std.fmt.parseFloat(f64, data[0..sp]) catch 0);
            }
        }
        if (readSmallFile("/proc/meminfo", &buf)) |data| {
            self.mem_total_kb = findMeminfo(data, "MemTotal:") orelse self.mem_total_kb;
            self.mem_avail_kb = findMeminfo(data, "MemAvailable:") orelse self.mem_avail_kb;
        }
        if (readSmallFile("/sys/class/thermal/thermal_zone0/temp", &buf)) |data| {
            const milli = std.fmt.parseInt(i64, std.mem.trim(u8, data, " \n\r\t"), 10) catch 0;
            self.temp_c = @as(f32, @floatFromInt(milli)) / 1000.0;
        }
    }
};

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
