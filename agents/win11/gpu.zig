//! GPU provider for the Win11 agent.
//!
//! Baseline: DXGI (name, dedicated VRAM, live local usage) + PDH GPU Engine
//! counters (utilisation).  NVIDIA adapters additionally use NVML when
//! `nvml.dll` is available, which gives reliable utilisation, VRAM, temperature
//! and power.  AMD/Intel work through the generic path.

const std = @import("std");
const c = @import("winapi");
const History = @import("history.zig").History;

const PDH_MORE_DATA: c.PDH_STATUS = @bitCast(@as(u32, 0x800007D2));

pub const Gpu = struct {
    gpa: std.mem.Allocator,
    dxgi: ?Dxgi = null,
    nvml: ?Nvml = null,
    util: ?GpuUtil = null,
    provider: [16]u8 = @splat(0),
    name: [128]u8 = @splat(0),

    util_pct: f32 = 0,
    mem_used_mb: f32 = 0,
    mem_total_mb: f32 = 0,
    temp_c: f32 = 0,
    power_w: f32 = 0,
    temp_available: bool = false,
    power_available: bool = false,

    hist: History = .{},

    pub fn init(gpa: std.mem.Allocator, enable: bool) Gpu {
        var self = Gpu{ .gpa = gpa };
        if (!enable) return self;

        self.dxgi = Dxgi.init(gpa) orelse return self;
        copyInto(&self.name, std.mem.sliceTo(&self.dxgi.?.name, 0));
        self.util = GpuUtil.init(std.unicode.utf8ToUtf16LeStringLiteral("\\GPU Engine(*)\\Utilization Percentage"));

        const vendor = self.dxgi.?.vendor_id;
        if (vendor == 0x10DE) {
            self.nvml = Nvml.open();
            if (self.nvml) |*n| {
                copyInto(&self.provider, "nvml+dxgi");
                if (n.name_buf[0] != 0) copyInto(&self.name, std.mem.sliceTo(&n.name_buf, 0));
                return self;
            }
        }

        copyInto(&self.provider, "pdh+dxgi");
        return self;
    }

    pub fn deinit(self: *Gpu) void {
        if (self.util) |*u| u.deinit();
        if (self.nvml) |*n| n.deinit();
        if (self.dxgi) |*d| d.deinit();
    }

    pub fn available(self: *const Gpu) bool {
        return self.dxgi != null;
    }

    pub fn sample(self: *Gpu) void {
        const d = if (self.dxgi) |*dxgi| dxgi else return;

        if (self.nvml) |*n| {
            self.util_pct = n.sampleUtilization() orelse if (self.util) |*u| u.sample() else 0;
            if (n.sampleMemory()) |mem| {
                self.mem_used_mb = @as(f32, @floatFromInt(mem.used)) / 1024.0 / 1024.0;
                self.mem_total_mb = @as(f32, @floatFromInt(mem.total)) / 1024.0 / 1024.0;
            } else {
                self.mem_used_mb = @as(f32, @floatFromInt(d.memoryUsed())) / 1024.0 / 1024.0;
                self.mem_total_mb = @as(f32, @floatFromInt(d.dedicated_vram)) / 1024.0 / 1024.0;
            }
            if (n.sampleTemp()) |t| {
                self.temp_c = t;
                self.temp_available = true;
            }
            if (n.samplePower()) |p| {
                self.power_w = p;
                self.power_available = true;
            }
        } else {
            if (self.util) |*u| self.util_pct = u.sample();
            self.mem_used_mb = @as(f32, @floatFromInt(d.memoryUsed())) / 1024.0 / 1024.0;
            self.mem_total_mb = @as(f32, @floatFromInt(d.dedicated_vram)) / 1024.0 / 1024.0;
        }

        if (self.util_pct < 0) self.util_pct = 0;
        if (self.util_pct > 100) self.util_pct = 100;
        self.hist.push(self.util_pct);
    }
};

const Dxgi = struct {
    factory: [*c]c.IDXGIFactory1 = null,
    adapter1: [*c]c.IDXGIAdapter1 = null,
    adapter3: [*c]c.IDXGIAdapter3 = null,
    vendor_id: u32 = 0,
    dedicated_vram: u64 = 0,
    name: [128]u8 = @splat(0),
    com_initialized: bool = false,

    fn init(gpa: std.mem.Allocator) ?Dxgi {
        _ = gpa;
        var self = Dxgi{};
        if (c.CoInitializeEx(null, c.COINIT_MULTITHREADED) >= 0) self.com_initialized = true;

        if (c.CreateDXGIFactory1(&c.IID_IDXGIFactory1, @ptrCast(&self.factory)) < 0) {
            if (self.com_initialized) c.CoUninitialize();
            return null;
        }

        var i: c.UINT = 0;
        var best_adapter: [*c]c.IDXGIAdapter1 = null;
        var best_desc: c.DXGI_ADAPTER_DESC1 = std.mem.zeroes(c.DXGI_ADAPTER_DESC1);
        while (true) : (i += 1) {
            var adapter: [*c]c.IDXGIAdapter1 = null;
            if (self.factory.*.lpVtbl.*.EnumAdapters1.?(self.factory, i, &adapter) < 0) break;

            var desc: c.DXGI_ADAPTER_DESC1 = std.mem.zeroes(c.DXGI_ADAPTER_DESC1);
            const ok = adapter.*.lpVtbl.*.GetDesc1.?(adapter, &desc) >= 0;
            if (ok and (desc.Flags & c.DXGI_ADAPTER_FLAG_SOFTWARE) == 0) {
                // Prefer the discrete adapter on hybrid laptops; fall back to
                // the first hardware adapter when everything has 0 dedicated
                // VRAM (integrated GPUs).
                if (best_adapter == null or desc.DedicatedVideoMemory > best_desc.DedicatedVideoMemory) {
                    if (best_adapter != null) _ = best_adapter.*.lpVtbl.*.Release.?(best_adapter);
                    best_adapter = adapter;
                    best_desc = desc;
                    continue;
                }
            }
            _ = adapter.*.lpVtbl.*.Release.?(adapter);
        }

        if (best_adapter != null) {
            self.adapter1 = best_adapter;
            self.vendor_id = best_desc.VendorId;
            self.dedicated_vram = best_desc.DedicatedVideoMemory;
            wideToUtf8(&self.name, std.mem.sliceTo(&best_desc.Description, 0));
        }

        if (self.adapter1 == null) {
            if (self.factory != null) _ = self.factory.*.lpVtbl.*.Release.?(self.factory);
            self.factory = null;
            if (self.com_initialized) c.CoUninitialize();
            return null;
        }

        var adapter3: [*c]c.IDXGIAdapter3 = null;
        if (self.adapter1.*.lpVtbl.*.QueryInterface.?(self.adapter1, &c.IID_IDXGIAdapter3, @ptrCast(&adapter3)) >= 0) {
            self.adapter3 = adapter3;
        }

        if (self.factory != null) _ = self.factory.*.lpVtbl.*.Release.?(self.factory);
        self.factory = null;
        return self;
    }

    fn deinit(self: *Dxgi) void {
        if (self.adapter3 != null) _ = self.adapter3.*.lpVtbl.*.Release.?(self.adapter3);
        if (self.adapter1 != null) _ = self.adapter1.*.lpVtbl.*.Release.?(self.adapter1);
        if (self.factory != null) _ = self.factory.*.lpVtbl.*.Release.?(self.factory);
        if (self.com_initialized) c.CoUninitialize();
        self.* = undefined;
    }

    fn memoryUsed(self: *Dxgi) u64 {
        if (self.adapter3) |_| {
            var info: c.DXGI_QUERY_VIDEO_MEMORY_INFO = std.mem.zeroes(c.DXGI_QUERY_VIDEO_MEMORY_INFO);
            const local: c.DXGI_MEMORY_SEGMENT_GROUP = @intCast(c.DXGI_MEMORY_SEGMENT_GROUP_LOCAL);
            if (self.adapter3.*.lpVtbl.*.QueryVideoMemoryInfo.?(self.adapter3, 0, local, &info) >= 0) {
                return info.CurrentUsage;
            }
        }
        return 0;
    }
};

const GpuUtil = struct {
    query: c.PDH_HQUERY = null,
    counter: c.PDH_HCOUNTER = null,

    fn init(path: [*:0]const u16) ?GpuUtil {
        var self = GpuUtil{};
        if (c.PdhOpenQueryW(null, 0, &self.query) != 0) return null;
        if (c.PdhAddEnglishCounterW(self.query, path, 0, &self.counter) != 0) {
            _ = c.PdhCloseQuery(self.query);
            return null;
        }
        _ = c.PdhCollectQueryData(self.query);
        return self;
    }

    fn deinit(self: *GpuUtil) void {
        _ = c.PdhCloseQuery(self.query);
        self.* = undefined;
    }

    fn sample(self: *GpuUtil) f32 {
        if (c.PdhCollectQueryData(self.query) != 0) return 0;

        var size: c.DWORD = 0;
        var count: c.DWORD = 0;
        var status = c.PdhGetFormattedCounterArrayW(self.counter, c.PDH_FMT_DOUBLE, &size, &count, null);
        if (status != PDH_MORE_DATA or size == 0) return 0;

        const buf = std.heap.page_allocator.alignedAlloc(u8, .of(c.PDH_FMT_COUNTERVALUE_ITEM_W), size) catch return 0;
        defer std.heap.page_allocator.free(buf);
        status = c.PdhGetFormattedCounterArrayW(
            self.counter,
            c.PDH_FMT_DOUBLE,
            &size,
            &count,
            @ptrCast(@alignCast(buf.ptr)),
        );
        if (status != 0) return 0;

        const items: [*]c.PDH_FMT_COUNTERVALUE_ITEM_W = @ptrCast(@alignCast(buf.ptr));
        var max: f64 = 0;
        for (items[0..count]) |item| {
            if (item.FmtValue.CStatus != 0) continue;
            const v = item.FmtValue.unnamed_0.doubleValue;
            if (v > max and v < 1e9) max = v;
        }
        return @floatCast(@min(max, 100.0));
    }
};

const WinLib = struct {
    module: c.HMODULE,

    fn open(name: [*:0]const u16) ?WinLib {
        const module = c.LoadLibraryW(name);
        if (module == null) return null;
        return .{ .module = module };
    }

    fn lookup(self: WinLib, comptime T: type, name: [:0]const u8) ?T {
        const proc = c.GetProcAddress(self.module, name.ptr) orelse return null;
        return @ptrCast(proc);
    }

    fn close(self: WinLib) void {
        _ = c.FreeLibrary(self.module);
    }
};

const NvmlUtilization = extern struct { gpu: c_uint, memory: c_uint };
const NvmlMemory = extern struct { total: u64, free: u64, used: u64 };

const Nvml = struct {
    lib: WinLib,
    init_fn: *const fn () callconv(.c) c_int,
    shutdown_fn: *const fn () callconv(.c) c_int,
    get_count: *const fn (*c_uint) callconv(.c) c_int,
    get_handle: *const fn (c_uint, *?*anyopaque) callconv(.c) c_int,
    get_name: *const fn (?*anyopaque, [*]u8, c_uint) callconv(.c) c_int,
    get_util: *const fn (?*anyopaque, *NvmlUtilization) callconv(.c) c_int,
    get_mem: *const fn (?*anyopaque, *NvmlMemory) callconv(.c) c_int,
    get_temp: *const fn (?*anyopaque, c_uint, *c_uint) callconv(.c) c_int,
    get_power: *const fn (?*anyopaque, *c_uint) callconv(.c) c_int,
    handle: ?*anyopaque = null,
    name_buf: [96]u8 = @splat(0),

    fn open() ?Nvml {
        const lib = WinLib.open(std.unicode.utf8ToUtf16LeStringLiteral("nvml.dll")) orelse return null;
        const fail = struct {
            fn f(l: WinLib) void {
                l.close();
            }
        }.f;

        const init_fn = lib.lookup(*const fn () callconv(.c) c_int, "nvmlInit_v2") orelse {
            fail(lib);
            return null;
        };
        const shutdown_fn = lib.lookup(*const fn () callconv(.c) c_int, "nvmlShutdown") orelse {
            fail(lib);
            return null;
        };
        const get_count = lib.lookup(*const fn (*c_uint) callconv(.c) c_int, "nvmlDeviceGetCount_v2") orelse {
            fail(lib);
            return null;
        };
        const get_handle = lib.lookup(*const fn (c_uint, *?*anyopaque) callconv(.c) c_int, "nvmlDeviceGetHandleByIndex_v2") orelse {
            fail(lib);
            return null;
        };
        const get_name = lib.lookup(*const fn (?*anyopaque, [*]u8, c_uint) callconv(.c) c_int, "nvmlDeviceGetName") orelse {
            fail(lib);
            return null;
        };
        const get_util = lib.lookup(*const fn (?*anyopaque, *NvmlUtilization) callconv(.c) c_int, "nvmlDeviceGetUtilizationRates") orelse {
            fail(lib);
            return null;
        };
        const get_mem = lib.lookup(*const fn (?*anyopaque, *NvmlMemory) callconv(.c) c_int, "nvmlDeviceGetMemoryInfo") orelse {
            fail(lib);
            return null;
        };
        const get_temp = lib.lookup(*const fn (?*anyopaque, c_uint, *c_uint) callconv(.c) c_int, "nvmlDeviceGetTemperature") orelse {
            fail(lib);
            return null;
        };
        const get_power = lib.lookup(*const fn (?*anyopaque, *c_uint) callconv(.c) c_int, "nvmlDeviceGetPowerUsage") orelse {
            fail(lib);
            return null;
        };

        if (init_fn() != 0) {
            fail(lib);
            return null;
        }

        var count: c_uint = 0;
        if (get_count(&count) != 0 or count == 0) {
            _ = shutdown_fn();
            fail(lib);
            return null;
        }

        var handle: ?*anyopaque = null;
        if (get_handle(0, &handle) != 0) {
            _ = shutdown_fn();
            fail(lib);
            return null;
        }

        var self = Nvml{
            .lib = lib,
            .init_fn = init_fn,
            .shutdown_fn = shutdown_fn,
            .get_count = get_count,
            .get_handle = get_handle,
            .get_name = get_name,
            .get_util = get_util,
            .get_mem = get_mem,
            .get_temp = get_temp,
            .get_power = get_power,
            .handle = handle,
        };
        _ = get_name(handle, &self.name_buf, self.name_buf.len);
        return self;
    }

    fn deinit(self: *Nvml) void {
        _ = self.shutdown_fn();
        self.lib.close();
        self.* = undefined;
    }

    fn sampleUtilization(self: *Nvml) ?f32 {
        var u: NvmlUtilization = .{ .gpu = 0, .memory = 0 };
        if (self.get_util(self.handle, &u) != 0) return null;
        return @floatFromInt(u.gpu);
    }

    fn sampleMemory(self: *Nvml) ?NvmlMemory {
        var mem: NvmlMemory = .{ .total = 0, .free = 0, .used = 0 };
        if (self.get_mem(self.handle, &mem) != 0) return null;
        return mem;
    }

    fn sampleTemp(self: *Nvml) ?f32 {
        var temp: c_uint = 0;
        if (self.get_temp(self.handle, 0, &temp) != 0) return null;
        return @floatFromInt(temp);
    }

    fn samplePower(self: *Nvml) ?f32 {
        var mw: c_uint = 0;
        if (self.get_power(self.handle, &mw) != 0) return null;
        return @as(f32, @floatFromInt(mw)) / 1000.0;
    }
};

fn wideToUtf8(dst: []u8, src: []const u16) void {
    const n = std.unicode.utf16LeToUtf8(dst[0 .. dst.len - 1], src) catch 0;
    dst[n] = 0;
}

fn copyInto(dst: []u8, src: []const u8) void {
    const n = @min(dst.len -| 1, src.len);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

test "nvml structs match the C ABI" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(NvmlUtilization));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(NvmlMemory));
}
