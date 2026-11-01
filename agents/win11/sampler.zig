//! Local Windows 11 metrics: CPU, memory, network and static system info.
//!
//! Only compiled for the Windows agent; all Win32 access goes through the
//! translated `winapi` module.

const std = @import("std");
const c = @import("winapi");
const History = @import("history.zig").History;

const PDH_MORE_DATA: c.PDH_STATUS = @bitCast(@as(u32, 0x800007D2));

pub const Sampler = struct {
    gpa: std.mem.Allocator,

    prev_idle: u64 = 0,
    prev_kernel: u64 = 0,
    prev_user: u64 = 0,
    cpu_util_pct: f32 = 0,
    cpu_queue: f32 = 0,
    cpu_count: u32 = 0,
    cpu_hist: History = .{},

    mem_total_bytes: u64 = 0,
    mem_avail_bytes: u64 = 0,

    net_ifindex: u32 = 0,
    net_prev_rx: u32 = 0,
    net_prev_tx: u32 = 0,
    net_total_rx: u64 = 0,
    net_total_tx: u64 = 0,
    net_last_ms: u64 = 0,
    net_rx_mbs: f32 = 0,
    net_tx_mbs: f32 = 0,

    hostname: [64]u8 = @splat(0),
    os_name: [64]u8 = @splat(0),
    cpu_model: [96]u8 = @splat(0),
    cpu_text: [32]u8 = @splat(0),
    uptime_text: [40]u8 = @splat(0),
    mem_text: [64]u8 = @splat(0),
    net_name: [64]u8 = @splat(0),
    net_text: [96]u8 = @splat(0),

    queue_counter: ?PdhScalar = null,

    pub fn init(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) Sampler {
        var self = Sampler{ .gpa = gpa };
        self.cpu_count = @intCast(std.Thread.getCpuCount() catch 0);
        formatInto(&self.cpu_text, "{d} cores", .{self.cpu_count});
        if (environ.get("PROCESSOR_IDENTIFIER")) |model| {
            copyInto(&self.cpu_model, model);
        } else {
            copyInto(&self.cpu_model, "Windows CPU");
        }
        self.readStaticInfo();
        self.queue_counter = PdhScalar.init(std.unicode.utf8ToUtf16LeStringLiteral("\\System\\Processor Queue Length"));
        return self;
    }

    pub fn deinit(self: *Sampler) void {
        if (self.queue_counter) |*q| q.deinit();
    }

    pub fn sample(self: *Sampler) void {
        self.sampleCpu();
        self.sampleMemory();
        self.sampleNetwork();
        self.sampleUptime();
        self.cpu_hist.push(self.cpu_util_pct);
    }

    fn sampleCpu(self: *Sampler) void {
        var idle: c.FILETIME = undefined;
        var kernel: c.FILETIME = undefined;
        var user: c.FILETIME = undefined;
        if (c.GetSystemTimes(&idle, &kernel, &user) == 0) return;

        const idle_n = fileTimeToU64(idle);
        const kernel_n = fileTimeToU64(kernel);
        const user_n = fileTimeToU64(user);

        if (self.prev_kernel != 0 or self.prev_user != 0) {
            const d_idle = idle_n -| self.prev_idle;
            const d_kernel = kernel_n -| self.prev_kernel;
            const d_user = user_n -| self.prev_user;
            const total = d_kernel + d_user; // kernel includes idle
            if (total > 0) {
                const busy = total -| d_idle;
                self.cpu_util_pct = @as(f32, @floatFromInt(busy)) * 100.0 / @as(f32, @floatFromInt(total));
            }
        }
        self.prev_idle = idle_n;
        self.prev_kernel = kernel_n;
        self.prev_user = user_n;

        if (self.queue_counter) |*q| {
            if (q.sample()) |value| self.cpu_queue = @floatCast(@max(0, value));
        }
    }

    fn sampleMemory(self: *Sampler) void {
        var mem: c.MEMORYSTATUSEX = std.mem.zeroes(c.MEMORYSTATUSEX);
        mem.dwLength = @sizeOf(c.MEMORYSTATUSEX);
        if (c.GlobalMemoryStatusEx(&mem) == 0) return;
        self.mem_total_bytes = mem.ullTotalPhys;
        self.mem_avail_bytes = mem.ullAvailPhys;

        const used = self.mem_total_bytes -| self.mem_avail_bytes;
        formatInto(&self.mem_text, "{d:.1} / {d:.1} GiB", .{
            @as(f64, @floatFromInt(used)) / 1024.0 / 1024.0 / 1024.0,
            @as(f64, @floatFromInt(self.mem_total_bytes)) / 1024.0 / 1024.0 / 1024.0,
        });
    }

    fn sampleNetwork(self: *Sampler) void {
        const now = c.GetTickCount64();
        const ifindex = defaultIfIndex(self.gpa);
        if (ifindex == 0) {
            copyInto(&self.net_name, "n/a");
            copyInto(&self.net_text, "no default interface");
            self.net_rx_mbs = 0;
            self.net_tx_mbs = 0;
            return;
        }

        var size: c.ULONG = 0;
        if (c.GetIfTable(null, &size, 0) != 0 and size == 0) return;
        const buf = self.gpa.alignedAlloc(u8, .of(c.MIB_IFROW), size) catch return;
        defer self.gpa.free(buf);
        if (c.GetIfTable(@ptrCast(@alignCast(buf.ptr)), &size, 0) != 0) return;
        const table: *c.MIB_IFTABLE = @ptrCast(@alignCast(buf.ptr));
        const rows: [*]c.MIB_IFROW = @ptrCast(&table.table[0]);

        var found: ?*c.MIB_IFROW = null;
        for (rows[0..table.dwNumEntries]) |*row| {
            if (row.dwIndex == ifindex) {
                found = row;
                break;
            }
        }
        const row = found orelse return;

        if (row.dwIndex != self.net_ifindex) {
            self.net_ifindex = row.dwIndex;
            self.net_prev_rx = row.dwInOctets;
            self.net_prev_tx = row.dwOutOctets;
            self.net_total_rx = 0;
            self.net_total_tx = 0;
            self.net_last_ms = now;
            self.net_rx_mbs = 0;
            self.net_tx_mbs = 0;
        }

        const drx: u32 = row.dwInOctets -% self.net_prev_rx;
        const dtx: u32 = row.dwOutOctets -% self.net_prev_tx;
        self.net_prev_rx = row.dwInOctets;
        self.net_prev_tx = row.dwOutOctets;

        const dt_ms = now -| self.net_last_ms;
        if (dt_ms > 0) {
            const secs = @as(f32, @floatFromInt(dt_ms)) / 1000.0;
            self.net_rx_mbs = @as(f32, @floatFromInt(drx)) / secs / 1024.0 / 1024.0;
            self.net_tx_mbs = @as(f32, @floatFromInt(dtx)) / secs / 1024.0 / 1024.0;
        }
        self.net_total_rx += drx;
        self.net_total_tx += dtx;
        self.net_last_ms = now;

        const desc = std.mem.sliceTo(&row.bDescr, 0);
        if (desc.len > 0) {
            copyInto(&self.net_name, desc);
        } else {
            var name: [128]u8 = undefined;
            wideToUtf8(&name, std.mem.sliceTo(&row.wszName, 0));
            copyInto(&self.net_name, std.mem.sliceTo(&name, 0));
        }
        formatInto(&self.net_text, "{s}  down {d:.1} MiB/s  up {d:.1} MiB/s", .{
            std.mem.sliceTo(&self.net_name, 0),
            self.net_rx_mbs,
            self.net_tx_mbs,
        });
    }

    fn sampleUptime(self: *Sampler) void {
        const ms = c.GetTickCount64();
        const secs = ms / 1000;
        const days = secs / 86400;
        if (days > 0) {
            formatInto(&self.uptime_text, "up {d}d {d:0>2}:{d:0>2}:{d:0>2}", .{
                days,
                (secs % 86400) / 3600,
                (secs % 3600) / 60,
                secs % 60,
            });
        } else {
            formatInto(&self.uptime_text, "up {d}h {d:0>2}m {d:0>2}s", .{
                secs / 3600,
                (secs % 3600) / 60,
                secs % 60,
            });
        }
    }

    fn readStaticInfo(self: *Sampler) void {
        var name_buf: [256]u16 = @splat(0);
        var name_len: c.DWORD = name_buf.len;
        if (c.GetComputerNameW(&name_buf, &name_len) != 0) {
            wideToUtf8(&self.hostname, name_buf[0..name_len]);
        }

        var vi: c.RTL_OSVERSIONINFOW = std.mem.zeroes(c.RTL_OSVERSIONINFOW);
        vi.dwOSVersionInfoSize = @sizeOf(c.RTL_OSVERSIONINFOW);
        if (RtlGetVersion(&vi) == 0) {
            const win_name = if (vi.dwBuildNumber >= 22000) "Windows 11" else "Windows 10";
            formatInto(&self.os_name, "{s} build {d}", .{ win_name, vi.dwBuildNumber });
        }
    }

    pub fn memUsedPct(self: *const Sampler) f32 {
        if (self.mem_total_bytes == 0) return 0;
        const used = self.mem_total_bytes -| self.mem_avail_bytes;
        return @as(f32, @floatFromInt(used)) * 100.0 / @as(f32, @floatFromInt(self.mem_total_bytes));
    }

    pub fn memUsedMb(self: *const Sampler) f32 {
        const used = self.mem_total_bytes -| self.mem_avail_bytes;
        return @as(f32, @floatFromInt(used)) / 1024.0 / 1024.0;
    }

    pub fn memTotalMb(self: *const Sampler) f32 {
        return @as(f32, @floatFromInt(self.mem_total_bytes)) / 1024.0 / 1024.0;
    }
};

extern "ntdll" fn RtlGetVersion(info: *c.RTL_OSVERSIONINFOW) callconv(.c) c.NTSTATUS;

const PdhScalar = struct {
    query: c.PDH_HQUERY = null,
    counter: c.PDH_HCOUNTER = null,

    fn init(path: [*:0]const u16) ?PdhScalar {
        var self = PdhScalar{};
        if (c.PdhOpenQueryW(null, 0, &self.query) != 0) return null;
        if (c.PdhAddEnglishCounterW(self.query, path, 0, &self.counter) != 0) {
            _ = c.PdhCloseQuery(self.query);
            return null;
        }
        _ = c.PdhCollectQueryData(self.query);
        return self;
    }

    fn deinit(self: *PdhScalar) void {
        _ = c.PdhCloseQuery(self.query);
        self.* = undefined;
    }

    fn sample(self: *PdhScalar) ?f64 {
        if (c.PdhCollectQueryData(self.query) != 0) return null;
        var value: c.PDH_FMT_COUNTERVALUE = std.mem.zeroes(c.PDH_FMT_COUNTERVALUE);
        if (c.PdhGetFormattedCounterValue(self.counter, c.PDH_FMT_DOUBLE, null, &value) != 0) return null;
        if (value.CStatus != 0) return null;
        return value.unnamed_0.doubleValue;
    }
};

fn defaultIfIndex(gpa: std.mem.Allocator) u32 {
    var size: c.ULONG = 0;
    if (c.GetIpForwardTable(null, &size, 0) != 0 and size == 0) return 0;
    const buf = gpa.alignedAlloc(u8, .of(c.MIB_IPFORWARDROW), size) catch return 0;
    defer gpa.free(buf);
    if (c.GetIpForwardTable(@ptrCast(@alignCast(buf.ptr)), &size, 0) != 0) return 0;

    const table: *c.MIB_IPFORWARDTABLE = @ptrCast(@alignCast(buf.ptr));
    const rows: [*]c.MIB_IPFORWARDROW = @ptrCast(&table.table[0]);
    var best: ?*c.MIB_IPFORWARDROW = null;
    for (rows[0..table.dwNumEntries]) |*row| {
        if (row.dwForwardDest != 0 or row.dwForwardMask != 0) continue;
        if (best) |b| {
            if (row.dwForwardMetric1 < b.dwForwardMetric1) best = row;
        } else {
            best = row;
        }
    }
    return if (best) |row| row.dwForwardIfIndex else 0;
}

fn wideToUtf8(dst: []u8, src: []const u16) void {
    const n = std.unicode.utf16LeToUtf8(dst[0 .. dst.len - 1], src) catch 0;
    dst[n] = 0;
}

fn fileTimeToU64(ft: c.FILETIME) u64 {
    return (@as(u64, @intCast(ft.dwHighDateTime)) << 32) | @as(u64, @intCast(ft.dwLowDateTime));
}

fn formatInto(dst: []u8, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(dst[0 .. dst.len - 1], fmt, args) catch "";
    dst[s.len] = 0;
}

fn copyInto(dst: []u8, src: []const u8) void {
    const n = @min(dst.len -| 1, src.len);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}
