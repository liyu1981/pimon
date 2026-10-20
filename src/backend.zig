//! DVUI backend for the Linux framebuffer (`/dev/fb0`) + Linux evdev input.
//!
//! Rendering is pure software: DVUI emits triangles, `soft_render.zig`
//! rasterizes them into a 0xAARRGGBB back buffer and `fbdev.zig` blits that
//! into the mapped framebuffer in the hardware's native layout (XRGB8888 or
//! RGB565 on a Raspberry Pi).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const dvui = @import("dvui");
const fbdev = @import("fbdev.zig");
const soft = @import("soft_render.zig");
const input_mod = @import("input.zig");
const console_mod = @import("console.zig");

pub const kind: dvui.enums.Backend = .custom;

pub const Options = struct {
    path: []const u8 = "/dev/fb0",
    geometry: fbdev.Options = .{},
    clear_color: u32 = soft.rgba(0x1e, 0x1e, 0x28, 0xff),
    content_scale: f32 = 1.0,
    dark: bool = true,
    enable_input: bool = true,
    kbd_path: ?[]const u8 = null,
    ptr_path: ?[]const u8 = null,
    /// Put the virtual console into graphics mode (hides the kernel cursor).
    grab_console: bool = true,
};

pub const Backend = @This();

allocator: std.mem.Allocator,
arena: std.mem.Allocator = undefined,
fb: fbdev.Framebuffer,
back: []u32,
target: ?*soft.Texture = null,
clear_color: u32,
content_scale: f32,
dark: bool,
cursor: dvui.enums.Cursor = .arrow,
clipboard: ?[]u8 = null,
input: input_mod.Input,
input_enabled: bool,
console: ?console_mod.Console = null,

pub fn init(allocator: std.mem.Allocator, opts: Options) !Backend {
    var fb = try fbdev.Framebuffer.open(opts.path, opts.geometry);
    errdefer fb.deinit();

    const back = try allocator.alloc(u32, @as(usize, fb.width) * fb.height);
    errdefer allocator.free(back);

    var self = Backend{
        .allocator = allocator,
        .fb = fb,
        .back = back,
        .clear_color = opts.clear_color,
        .content_scale = opts.content_scale,
        .dark = opts.dark,
        .input = input_mod.Input.init(allocator),
        .input_enabled = opts.enable_input,
    };
    soft.clear(self.surface(), self.clear_color);
    if (opts.enable_input) self.input.open(opts.kbd_path, opts.ptr_path);
    if (opts.grab_console) self.console = console_mod.Console.acquire();
    return self;
}

pub fn deinit(self: *Backend) void {
    if (self.console) |c| c.release();
    if (self.clipboard) |c| self.allocator.free(c);
    self.input.deinit();
    self.allocator.free(self.back);
    self.fb.deinit();
    self.* = undefined;
}

pub fn backend(self: *Backend) dvui.Backend {
    return dvui.Backend.init(self);
}

/// Decode the physical framebuffer into a fresh 0xAARRGGBB buffer.
pub fn snapshotRgba(self: *Backend, allocator: std.mem.Allocator) ![]u32 {
    const out = try allocator.alloc(u32, @as(usize, self.fb.width) * self.fb.height);
    self.fb.decodeToRgba(out);
    return out;
}

fn surface(self: *Backend) soft.Surface {
    return .{ .pixels = self.back, .width = self.fb.width, .height = self.fb.height };
}

fn targetSurface(tex: *soft.Texture) soft.Surface {
    return .{ .pixels = tex.pixels, .width = tex.width, .height = tex.height };
}

/// The CLI main loop calls these before/after frames.
pub fn pollEvents(self: *Backend, win: *dvui.Window) void {
    if (!self.input_enabled) return;
    self.input.poll(win, @floatFromInt(self.fb.width), @floatFromInt(self.fb.height));
}

pub fn waitEvents(self: *Backend, timeout_us: u32) bool {
    if (!self.input_enabled) {
        sleepNs(@as(u64, timeout_us) * std.time.ns_per_us);
        return false;
    }
    return self.input.wait(timeout_us);
}

// ---------------------------------------------------------------------------
// Required dvui.Backend API
// ---------------------------------------------------------------------------

pub fn nanoTime(_: *Backend) i128 {
    var ts: posix.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

pub fn sleep(_: *Backend, ns: u64) void {
    sleepNs(ns);
}

fn sleepNs(ns: u64) void {
    const ts: posix.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&ts, null);
}

pub fn begin(self: *Backend, arena: std.mem.Allocator) !void {
    self.arena = arena;
    soft.clear(self.surface(), self.clear_color);
}

pub fn end(_: *Backend) !void {}

pub fn pixelSize(self: *Backend) dvui.Size.Physical {
    return .{ .w = @floatFromInt(self.fb.width), .h = @floatFromInt(self.fb.height) };
}

pub fn windowSize(self: *Backend) dvui.Size.Natural {
    return .{ .w = @floatFromInt(self.fb.width), .h = @floatFromInt(self.fb.height) };
}

pub fn contentScale(self: *Backend) f32 {
    return self.content_scale;
}

pub fn drawClippedTriangles(
    self: *Backend,
    texture: ?dvui.Texture,
    vtx: []const dvui.Vertex,
    idx: []const dvui.Vertex.Index,
    clipr: ?dvui.Rect.Physical,
) !void {
    const tex_ptr: ?*soft.Texture = if (texture) |t| @ptrCast(@alignCast(t.ptr)) else null;
    if (self.target) |t| {
        soft.drawTriangles(targetSurface(t), tex_ptr, vtx, idx, clipr);
    } else {
        soft.drawTriangles(self.surface(), tex_ptr, vtx, idx, clipr);
    }
}

pub fn textureCreate(self: *Backend, pixels: [*]const u8, options: dvui.Texture.CreateOptions) !dvui.Texture {
    const tex = try self.allocator.create(soft.Texture);
    errdefer self.allocator.destroy(tex);
    const count = @as(usize, options.width) * options.height;
    const buf = try self.allocator.alloc(u32, count);
    tex.* = .{
        .pixels = buf,
        .width = options.width,
        .height = options.height,
        .interpolation = options.interpolation,
        .wrap_u = options.wrap_u,
        .wrap_v = options.wrap_v,
    };
    copyPixels(buf, pixels, count);
    return texRef(tex);
}

pub fn textureUpdate(_: *Backend, texture: dvui.Texture, pixels: [*]const u8) !void {
    const tex: *soft.Texture = @ptrCast(@alignCast(texture.ptr));
    copyPixels(tex.pixels, pixels, tex.pixels.len);
}

pub fn textureUpdateSubRect(_: *Backend, texture: dvui.Texture, pixels: [*]const u8, x: u32, y: u32, w: u32, h: u32) !void {
    const tex: *soft.Texture = @ptrCast(@alignCast(texture.ptr));
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const src = pixels + (@as(usize, y + row) * tex.width + x) * 4;
        const dst_off = @as(usize, y + row) * tex.width + x;
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            tex.pixels[dst_off + col] = soft.rgba(src[col * 4], src[col * 4 + 1], src[col * 4 + 2], src[col * 4 + 3]);
        }
    }
}

pub fn textureDestroy(self: *Backend, texture: dvui.Texture) void {
    const tex: *soft.Texture = @ptrCast(@alignCast(texture.ptr));
    self.allocator.free(tex.pixels);
    self.allocator.destroy(tex);
}

pub fn textureCreateTarget(self: *Backend, options: dvui.Texture.CreateOptions) !dvui.TextureTarget {
    const tex = try self.allocator.create(soft.Texture);
    errdefer self.allocator.destroy(tex);
    const count = @as(usize, options.width) * options.height;
    const buf = try self.allocator.alloc(u32, count);
    tex.* = .{
        .pixels = buf,
        .width = options.width,
        .height = options.height,
        .interpolation = options.interpolation,
        .wrap_u = options.wrap_u,
        .wrap_v = options.wrap_v,
    };
    @memset(buf, 0);
    return .{
        .ptr = tex,
        .width = options.width,
        .height = options.height,
        .format = options.format,
        .interpolation = options.interpolation,
        .wrap_u = options.wrap_u,
        .wrap_v = options.wrap_v,
    };
}

pub fn textureClearTarget(_: *Backend, texture: dvui.Texture.Target) void {
    const tex: *soft.Texture = @ptrCast(@alignCast(texture.ptr));
    @memset(tex.pixels, 0);
}

pub fn textureReadTarget(_: *Backend, texture: dvui.Texture.Target, pixels_out: [*]u8) !void {
    const tex: *soft.Texture = @ptrCast(@alignCast(texture.ptr));
    for (tex.pixels, 0..) |p, i| {
        pixels_out[i * 4 + 0] = @truncate(p >> 16);
        pixels_out[i * 4 + 1] = @truncate(p >> 8);
        pixels_out[i * 4 + 2] = @truncate(p);
        pixels_out[i * 4 + 3] = @truncate(p >> 24);
    }
}

pub fn textureDestroyTarget(self: *Backend, texture: dvui.Texture.Target) void {
    const tex: *soft.Texture = @ptrCast(@alignCast(texture.ptr));
    self.allocator.free(tex.pixels);
    self.allocator.destroy(tex);
}

pub fn textureFromTarget(_: *Backend, target: dvui.TextureTarget) !dvui.Texture {
    return dvui.Texture.cast(target);
}

pub fn textureFromTargetTemp(_: *Backend, target: dvui.TextureTarget) !dvui.Texture {
    return dvui.Texture.cast(target);
}

pub fn renderTarget(self: *Backend, texture: ?dvui.TextureTarget) !void {
    self.target = if (texture) |t| @ptrCast(@alignCast(t.ptr)) else null;
}

pub const support_read_pixels = true;
pub fn readPixels(self: *Backend, rect: dvui.Rect.Physical, pixels_out: [*]u8) !void {
    const surf = if (self.target) |t| targetSurface(t) else self.surface();
    const x0: u32 = @intFromFloat(@max(0, @floor(rect.x)));
    const y0: u32 = @intFromFloat(@max(0, @floor(rect.y)));
    const w: u32 = @intFromFloat(@max(0, @floor(rect.w)));
    const h: u32 = @intFromFloat(@max(0, @floor(rect.h)));
    var y: u32 = 0;
    while (y < h and y0 + y < surf.height) : (y += 1) {
        var x: u32 = 0;
        while (x < w and x0 + x < surf.width) : (x += 1) {
            const p = surf.pixels[@as(usize, y0 + y) * surf.width + x0 + x];
            const a = @as(u8, @truncate(p >> 24));
            const inv: u32 = if (a == 0) 0 else 255;
            const r: u32 = if (a == 0) 0 else @min(((p >> 16) & 0xff) * inv / @max(a, 1), 255);
            const g: u32 = if (a == 0) 0 else @min(((p >> 8) & 0xff) * inv / @max(a, 1), 255);
            const b: u32 = if (a == 0) 0 else @min((p & 0xff) * inv / @max(a, 1), 255);
            const off = (@as(usize, y) * w + x) * 4;
            pixels_out[off + 0] = @truncate(r);
            pixels_out[off + 1] = @truncate(g);
            pixels_out[off + 2] = @truncate(b);
            pixels_out[off + 3] = a;
        }
    }
}

pub fn setCursor(self: *Backend, cursor: dvui.enums.Cursor) void {
    self.cursor = cursor;
}

pub fn textInputRect(_: *Backend, _: ?dvui.Rect.Natural) void {}

pub fn renderPresent(self: *Backend) void {
    self.drawCursor();
    self.fb.present(self.back);
}

pub fn clipboardText(self: *Backend) ![]const u8 {
    if (self.clipboard) |c| return try self.arena.dupe(u8, c);
    return "";
}

pub fn clipboardTextSet(self: *Backend, text: []const u8) !void {
    if (self.clipboard) |c| self.allocator.free(c);
    self.clipboard = try self.allocator.dupe(u8, text);
}

pub fn openURL(_: *Backend, url: []const u8, _: bool) !void {
    std.log.info("openURL: {s}", .{url});
}

pub fn preferredColorScheme(self: *Backend) ?dvui.enums.ColorScheme {
    return if (self.dark) .dark else .light;
}

pub fn prefersReducedMotion(_: *Backend) bool {
    return false;
}

pub fn refresh(_: *Backend) void {}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn texRef(tex: *soft.Texture) dvui.Texture {
    return .{
        .ptr = tex,
        .width = tex.width,
        .height = tex.height,
        .format = .rgba_32,
        .interpolation = tex.interpolation,
        .wrap_u = tex.wrap_u,
        .wrap_v = tex.wrap_v,
    };
}

fn copyPixels(dst: []u32, pixels: [*]const u8, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        dst[i] = soft.rgba(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]);
    }
}

fn drawCursor(self: *Backend) void {
    if (!self.input_enabled) return;
    if (!self.input.have_pointer) return;
    if (self.cursor == .hidden) return;

    const x = @max(self.input.x, 0);
    const y = @max(self.input.y, 0);

    const black: dvui.Color.PMA = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const white: dvui.Color.PMA = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    const vtx = [6]dvui.Vertex{
        .{ .pos = .{ .x = x + 0, .y = y + 0 }, .col = black },
        .{ .pos = .{ .x = x + 0, .y = y + 14 }, .col = black },
        .{ .pos = .{ .x = x + 11, .y = y + 10 }, .col = black },
        .{ .pos = .{ .x = x + 1, .y = y + 2 }, .col = white },
        .{ .pos = .{ .x = x + 1, .y = y + 11 }, .col = white },
        .{ .pos = .{ .x = x + 8, .y = y + 9 }, .col = white },
    };
    const idx = [6]dvui.Vertex.Index{ 0, 1, 2, 3, 4, 5 };
    soft.drawTriangles(self.surface(), null, &vtx, &idx, null);
}
