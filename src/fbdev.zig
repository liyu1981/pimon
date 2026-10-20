//! Minimal Linux framebuffer (`/dev/fb0`) access for 16/24/32 bpp displays.
//!
//! This talks to the kernel directly (no libdrm, no window system).  It is
//! deliberately small: query the screen info with `ioctl`, `mmap` the pixels,
//! and blit a 32-bit ARGB software buffer into whatever layout the driver
//! reported (RGB565 on a Raspberry Pi configured for 16 bpp, XRGB8888 usually).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const FBIOGET_VSCREENINFO: u32 = 0x4600;
pub const FBIOGET_FSCREENINFO: u32 = 0x4602;
pub const FBIOPAN_DISPLAY: u32 = 0x4606;

pub const BitField = extern struct {
    offset: u32 = 0,
    length: u32 = 0,
    msb_right: u32 = 0,
};

pub const VarScreenInfo = extern struct {
    xres: u32 = 0,
    yres: u32 = 0,
    xres_virtual: u32 = 0,
    yres_virtual: u32 = 0,
    xoffset: u32 = 0,
    yoffset: u32 = 0,
    bits_per_pixel: u32 = 0,
    grayscale: u32 = 0,
    red: BitField = .{},
    green: BitField = .{},
    blue: BitField = .{},
    transp: BitField = .{},
    nonstd: u32 = 0,
    activate: u32 = 0,
    height: u32 = 0,
    width: u32 = 0,
    accel_flags: u32 = 0,
    pixclock: u32 = 0,
    left_margin: u32 = 0,
    right_margin: u32 = 0,
    upper_margin: u32 = 0,
    lower_margin: u32 = 0,
    hsync_len: u32 = 0,
    vsync_len: u32 = 0,
    sync: u32 = 0,
    vmode: u32 = 0,
    rotate: u32 = 0,
    colorspace: u32 = 0,
    reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const FixScreenInfo = extern struct {
    id: [16]u8 = @splat(0),
    smem_start: usize = 0,
    smem_len: u32 = 0,
    type: u32 = 0,
    type_aux: u32 = 0,
    visual: u32 = 0,
    xpanstep: u16 = 0,
    ypanstep: u16 = 0,
    ywrapstep: u16 = 0,
    line_length: u32 = 0,
    mmio_start: usize = 0,
    mmio_len: u32 = 0,
    accel: u32 = 0,
    capabilities: u16 = 0,
    reserved: [2]u16 = .{ 0, 0 },
};

/// Optional overrides used when rendering to a plain file (headless testing)
/// or when the driver does not report something useful.
pub const Options = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    bpp: ?u32 = null,
    stride: ?u32 = null,
    red: ?BitField = null,
    green: ?BitField = null,
    blue: ?BitField = null,
};

pub const Framebuffer = struct {
    fd: posix.fd_t,
    mem: []align(std.heap.page_size_min) u8,
    width: u32,
    height: u32,
    stride: u32,
    bpp: u32,
    red: BitField,
    green: BitField,
    blue: BitField,

    /// Number of bytes needed for one full frame in framebuffer format.
    pub fn frameBytes(self: *const Framebuffer) usize {
        return @as(usize, self.stride) * self.height;
    }

    pub fn open(path: []const u8, opts: Options) !Framebuffer {
        const flags: posix.O = .{ .ACCMODE = .RDWR, .CREAT = true };
        const fd = try posix.openat(posix.AT.FDCWD, path, flags, 0o644);
        errdefer _ = linux.close(fd);

        var var_info: VarScreenInfo = .{};
        var fix_info: FixScreenInfo = .{};
        var width: u32 = 0;
        var height: u32 = 0;
        var bpp: u32 = 0;
        var stride: u32 = 0;
        var red: BitField = .{};
        var green: BitField = .{};
        var blue: BitField = .{};
        var queried = false;

        if (posix.errno(linux.ioctl(fd, FBIOGET_VSCREENINFO, @intFromPtr(&var_info))) == .SUCCESS and
            posix.errno(linux.ioctl(fd, FBIOGET_FSCREENINFO, @intFromPtr(&fix_info))) == .SUCCESS)
        {
            queried = true;
            width = var_info.xres;
            height = var_info.yres;
            bpp = var_info.bits_per_pixel;
            red = var_info.red;
            green = var_info.green;
            blue = var_info.blue;
        }

        const overridden = opts.width != null or opts.height != null or opts.bpp != null;
        width = opts.width orelse if (queried) width else return error.MissingGeometry;
        height = opts.height orelse if (queried) height else return error.MissingGeometry;
        bpp = opts.bpp orelse if (queried) bpp else return error.MissingGeometry;
        if (opts.stride) |s| {
            stride = s;
        } else if (queried and !overridden and fix_info.line_length != 0) {
            stride = fix_info.line_length;
        } else {
            stride = width * bpp / 8;
        }

        if (opts.red) |r| red = r;
        if (opts.green) |g| green = g;
        if (opts.blue) |b| blue = b;

        if (red.length == 0 and green.length == 0 and blue.length == 0) {
            switch (bpp) {
                16 => {
                    red = .{ .offset = 11, .length = 5 };
                    green = .{ .offset = 5, .length = 6 };
                    blue = .{ .offset = 0, .length = 5 };
                },
                24, 32 => {
                    red = .{ .offset = 16, .length = 8 };
                    green = .{ .offset = 8, .length = 8 };
                    blue = .{ .offset = 0, .length = 8 };
                },
                else => return error.UnsupportedFormat,
            }
        }

        if (bpp != 16 and bpp != 24 and bpp != 32) return error.UnsupportedFormat;
        if (width == 0 or height == 0) return error.MissingGeometry;

        // Regular files must be sized before mmap.  A real framebuffer returns
        // EINVAL here, which is fine.
        const trunc_rc = linux.ftruncate(fd, @intCast(stride * height));
        _ = trunc_rc;

        const mem = try posix.mmap(
            null,
            stride * height,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        return .{
            .fd = fd,
            .mem = mem,
            .width = width,
            .height = height,
            .stride = stride,
            .bpp = bpp,
            .red = red,
            .green = green,
            .blue = blue,
        };
    }

    pub fn deinit(self: *Framebuffer) void {
        posix.munmap(self.mem);
        _ = linux.close(self.fd);
        self.* = undefined;
    }

    inline fn channel(value: u8, field: BitField) u32 {
        if (field.length == 0) return 0;
        const len = @min(field.length, 8);
        const reduced: u32 = @as(u32, value) >> @intCast(8 - len);
        return reduced << @intCast(field.offset);
    }

    inline fn pack(self: *const Framebuffer, pixel: u32) u32 {
        const r: u8 = @truncate(pixel >> 16);
        const g: u8 = @truncate(pixel >> 8);
        const b: u8 = @truncate(pixel);
        return channel(r, self.red) | channel(g, self.green) | channel(b, self.blue);
    }

    /// Decode the mapped framebuffer memory back into a 0xAARRGGBB buffer.
    /// Used by `--dump` so the PNG reflects exactly what was scanned out.
    pub fn decodeToRgba(self: *const Framebuffer, out: []u32) void {
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const row = self.mem.ptr + @as(usize, y) * self.stride;
            switch (self.bpp) {
                32 => {
                    const src: [*]const u32 = @ptrCast(@alignCast(row));
                    for (0..self.width) |x| out[@as(usize, y) * self.width + x] = unpackRgba(src[x], self);
                },
                16 => {
                    const src: [*]const u16 = @ptrCast(@alignCast(row));
                    for (0..self.width) |x| out[@as(usize, y) * self.width + x] = unpackRgba(src[x], self);
                },
                24 => {
                    const src: [*]const u8 = @ptrCast(row);
                    for (0..self.width) |x| {
                        const v: u32 = @as(u32, src[x * 3]) | (@as(u32, src[x * 3 + 1]) << 8) | (@as(u32, src[x * 3 + 2]) << 16);
                        out[@as(usize, y) * self.width + x] = unpackRgba(v, self);
                    }
                },
                else => unreachable,
            }
        }
    }

    /// Copy a 0xAARRGGBB software buffer into the mapped framebuffer memory.
    pub fn present(self: *const Framebuffer, back: []const u32) void {
        // Fast path: 32bpp with a matching layout and no row padding.
        if (self.bpp == 32 and self.stride == self.width * 4 and
            self.red.offset == 16 and self.red.length == 8 and
            self.green.offset == 8 and self.green.length == 8 and
            self.blue.offset == 0 and self.blue.length == 8)
        {
            @memcpy(self.mem[0 .. back.len * 4], std.mem.sliceAsBytes(back));
            return;
        }

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const src = back[@as(usize, y) * self.width ..][0..self.width];
            const dst_ptr = self.mem.ptr + @as(usize, y) * self.stride;
            switch (self.bpp) {
                32 => {
                    const dst: [*]u32 = @ptrCast(@alignCast(dst_ptr));
                    for (src, 0..) |p, x| dst[x] = self.pack(p);
                },
                16 => {
                    const dst: [*]u16 = @ptrCast(@alignCast(dst_ptr));
                    for (src, 0..) |p, x| dst[x] = @truncate(self.pack(p));
                },
                24 => {
                    const dst: [*]u8 = @ptrCast(dst_ptr);
                    for (src, 0..) |p, x| {
                        const v = self.pack(p);
                        dst[x * 3 + 0] = @truncate(v);
                        dst[x * 3 + 1] = @truncate(v >> 8);
                        dst[x * 3 + 2] = @truncate(v >> 16);
                    }
                },
                else => unreachable,
            }
        }
    }
};

inline fn unpackChannel(value: u32, field: BitField) u8 {
    if (field.length == 0) return 0;
    const len = @min(field.length, 8);
    const mask: u32 = (@as(u32, 1) << @intCast(len)) - 1;
    const raw = (value >> @intCast(field.offset)) & mask;
    if (len == 8) return @intCast(raw);
    return @intCast(raw << @intCast(8 - len));
}

fn unpackRgba(value: u32, fb: *const Framebuffer) u32 {
    const r = unpackChannel(value, fb.red);
    const g = unpackChannel(value, fb.green);
    const b = unpackChannel(value, fb.blue);
    return 0xff000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

test "channel packing" {
    const fb = Framebuffer{
        .fd = 0,
        .mem = undefined,
        .width = 0,
        .height = 0,
        .stride = 0,
        .bpp = 16,
        .red = .{ .offset = 11, .length = 5 },
        .green = .{ .offset = 5, .length = 6 },
        .blue = .{ .offset = 0, .length = 5 },
    };
    try std.testing.expectEqual(@as(u32, 0xF800), fb.pack(0x00FF0000));
    try std.testing.expectEqual(@as(u32, 0x07E0), fb.pack(0x0000FF00));
    try std.testing.expectEqual(@as(u32, 0x001F), fb.pack(0x000000FF));
}
