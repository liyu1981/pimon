//! Minimal read-only PawnIO client for the AMD package temperature.
//!
//! The signed module is embedded from `modules/AMDFamily17.bin`.  PawnIO.sys
//! only accepts modules signed by its author, so the binary is vendored
//! instead of built from `vendor/pawnio-modules`.
//!
//! The device requires an elevated process; `init` treats an access-denied
//! open as "not available" and the sampler falls back to its PDH source.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("winapi");
const cpu_temp = @import("cpu_temp.zig");

const amd_module = @embedFile("modules/AMDFamily17.bin");

const device_path = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\GLOBALROOT\\Device\\PawnIO");
const pci_mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\Access_PCI");

const device_type: u32 = 41394;
const ioctl_load_binary: u32 = (device_type << 16) | (0x821 << 2);
const ioctl_execute_fn: u32 = (device_type << 16) | (0x841 << 2);

const generic_read: u32 = 0x80000000;
const generic_write: u32 = 0x40000000;
const file_share_read: u32 = 0x00000001;
const file_share_write: u32 = 0x00000002;
const file_share_delete: u32 = 0x00000004;
const open_existing: u32 = 3;
const file_attribute_normal: u32 = 0x00000080;
const synchronize: u32 = 0x00100000;
const wait_object_0: u32 = 0;
const wait_abandoned: u32 = 0x80;

const amd_temp_register: u64 = 0x00059800;
const fn_name_len: usize = 32;
const max_args: usize = 4;

pub fn isDeviceAvailable() bool {
    const handle = openDevice();
    if (handle == c.INVALID_HANDLE_VALUE) return false;
    _ = c.CloseHandle(handle);
    return true;
}

fn openDevice() c.HANDLE {
    return c.CreateFileW(
        device_path,
        generic_read | generic_write,
        file_share_read | file_share_write | file_share_delete,
        null,
        open_existing,
        file_attribute_normal,
        null,
    );
}

pub const PawnIo = struct {
    device: c.HANDLE = c.INVALID_HANDLE_VALUE,
    pci_mutex: c.HANDLE = null,
    tctl_offset: f32 = 0,
    available: bool = false,

    pub fn init(cpu_model: []const u8) ?PawnIo {
        if (builtin.cpu.arch != .x86_64 or !isAmdCpu()) {
            std.log.info("pawnio: no AMD x64 CPU; AMD backend disabled", .{});
            return null;
        }

        var self = PawnIo{};
        self.device = openDevice();
        if (self.device == c.INVALID_HANDLE_VALUE) {
            const err: u32 = c.GetLastError();
            std.log.warn("pawnio: open PawnIO device failed (error {d}); CPU temp falls back to PDH", .{err});
            return null;
        }

        var returned: c.DWORD = 0;
        const loaded = c.DeviceIoControl(
            self.device,
            ioctl_load_binary,
            @ptrCast(@constCast(amd_module.ptr)),
            @intCast(amd_module.len),
            null,
            0,
            &returned,
            null,
        );
        if (loaded == 0) {
            const err: u32 = c.GetLastError();
            std.log.warn("pawnio: loading AMDFamily17 failed (error {d})", .{err});
            self.close();
            return null;
        }

        self.pci_mutex = openPciMutex();
        // `PROCESSOR_IDENTIFIER` is family/model text, not the marketing name;
        // the Tctl offset table needs the CPUID brand string.
        var brand_buf: [48]u8 = undefined;
        const brand = cpuBrandString(&brand_buf);
        self.tctl_offset = cpu_temp.amdTctlOffset(if (brand.len > 0) brand else cpu_model);
        self.available = true;
        std.log.info("pawnio: AMD package temperature enabled", .{});
        return self;
    }

    pub fn deinit(self: *PawnIo) void {
        self.close();
    }

    pub fn readCpuTemp(self: *PawnIo) ?f32 {
        if (!self.available) return null;

        const have_mutex = self.pci_mutex != null;
        const locked = self.lockPci();
        defer {
            if (have_mutex and locked) _ = c.ReleaseMutex(self.pci_mutex);
        }
        if (have_mutex and !locked) return null;

        const raw = self.readSmn(@intCast(amd_temp_register)) orelse return null;
        return cpu_temp.decodeAmdPackage(raw, self.tctl_offset);
    }

    fn close(self: *PawnIo) void {
        if (self.device != c.INVALID_HANDLE_VALUE) {
            _ = c.CloseHandle(self.device);
            self.device = c.INVALID_HANDLE_VALUE;
        }
        if (self.pci_mutex != null) {
            _ = c.CloseHandle(self.pci_mutex);
            self.pci_mutex = null;
        }
        self.available = false;
    }

    fn lockPci(self: *PawnIo) bool {
        const handle = self.pci_mutex orelse return true;
        const result = c.WaitForSingleObject(handle, 10);
        return result == wait_object_0 or result == wait_abandoned;
    }

    fn readSmn(self: *PawnIo, offset: u32) ?u32 {
        var out: [1]u64 = .{0};
        var returned: c.DWORD = 0;
        if (!execute(self.device, "ioctl_read_smn", &.{offset}, out[0..], &returned)) return null;
        if (returned < @sizeOf(u64)) return null;
        return @truncate(out[0]);
    }
};

fn execute(device: c.HANDLE, name: []const u8, args: []const u64, out: []u64, returned: *c.DWORD) bool {
    if (name.len >= fn_name_len) return false;
    if (args.len > max_args) return false;

    var input: [fn_name_len + max_args * @sizeOf(u64)]u8 = @splat(0);
    @memcpy(input[0..name.len], name);
    for (args, 0..) |arg, i| {
        std.mem.writeInt(u64, input[fn_name_len + i * @sizeOf(u64) ..][0..@sizeOf(u64)], arg, .little);
    }

    return c.DeviceIoControl(
        device,
        ioctl_execute_fn,
        @ptrCast(&input),
        @intCast(fn_name_len + args.len * @sizeOf(u64)),
        @ptrCast(out.ptr),
        @intCast(out.len * @sizeOf(u64)),
        returned,
        null,
    ) != 0;
}

fn openPciMutex() c.HANDLE {
    const created = c.CreateMutexW(null, 0, pci_mutex_name);
    if (created != null) return created;

    const opened = c.OpenMutexW(synchronize, 0, pci_mutex_name);
    if (opened != null) return opened;

    std.log.warn("pawnio: Access_PCI mutex unavailable; SMN reads may race", .{});
    return null;
}

const CpuidLeaf = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf_id: u32, sub_id: u32) CpuidLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf_id),
          [_] "{ecx}" (sub_id),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn isAmdCpu() bool {
    const leaf = cpuid(0, 0);
    var vendor: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor[0..4], leaf.ebx, .little);
    std.mem.writeInt(u32, vendor[4..8], leaf.edx, .little);
    std.mem.writeInt(u32, vendor[8..12], leaf.ecx, .little);
    return std.mem.eql(u8, vendor[0..], "AuthenticAMD");
}

fn cpuBrandString(buf: *[48]u8) []const u8 {
    @memset(buf, 0);
    var i: usize = 0;
    var leaf_id: u32 = 0x80000002;
    while (leaf_id <= 0x80000004) : (leaf_id += 1) {
        const leaf = cpuid(leaf_id, 0);
        std.mem.writeInt(u32, buf[i..][0..4], leaf.eax, .little);
        i += 4;
        std.mem.writeInt(u32, buf[i..][0..4], leaf.ebx, .little);
        i += 4;
        std.mem.writeInt(u32, buf[i..][0..4], leaf.ecx, .little);
        i += 4;
        std.mem.writeInt(u32, buf[i..][0..4], leaf.edx, .little);
        i += 4;
    }
    return std.mem.trim(u8, buf[0..], " \x00");
}
