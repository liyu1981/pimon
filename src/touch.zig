//! Direct evdev touchscreen support for the SDL2/KMSDRM front-end.
//!
//! SDL2's Linux evdev input code only registers a touchscreen if the device
//! exposes `ABS_MT_PRESSURE` (see `SDL_EVDEV_init_touchscreen`).  The official
//! Raspberry Pi 7" panel does *not* expose that axis, so SDL silently drops
//! the device and touch never reaches DVUI.  This module reads the same evdev
//! node directly and posts DVUI touch events, bypassing SDL for touch.
//!
//! It is only enabled when SDL reports no touch devices, so there are no
//! duplicate events on setups where SDL handles touch itself.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const dvui = @import("dvui");

const InputEvent = extern struct {
    time: posix.timeval,
    type_: u16,
    code: u16,
    value: i32,
};

const AbsInfo = extern struct {
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
};

const EV_SYN = 0x00;
const EV_KEY = 0x01;
const EV_ABS = 0x03;

const ABS_X = 0x00;
const ABS_Y = 0x01;
const ABS_MT_SLOT = 0x2f;
const ABS_MT_POSITION_X = 0x35;
const ABS_MT_POSITION_Y = 0x36;
const ABS_MT_TRACKING_ID = 0x39;

const BTN_TOUCH = 0x14a;

const KEY_MAX = 0x2ff;
const ABS_MAX = 0x3f;

fn ioc(dir: u32, typ: u8, nr: u8, size: u32) u32 {
    return (dir << 30) | (size << 16) | (@as(u32, typ) << 8) | nr;
}
const IOC_READ: u32 = 2;

fn eviocgbit(ev: u8, len: u32) u32 {
    return ioc(IOC_READ, 'E', 0x20 + ev, len);
}
fn eviocgname(len: u32) u32 {
    return ioc(IOC_READ, 'E', 0x06, len);
}
fn eviocgabs(abs: u8) u32 {
    return ioc(IOC_READ, 'E', 0x40 + abs, @sizeOf(AbsInfo));
}

fn bitSet(bits: []const u8, code: u16) bool {
    const byte = code / 8;
    if (byte >= bits.len) return false;
    return (bits[byte] >> @intCast(code % 8)) & 1 != 0;
}

const Axis = struct { min: i32, max: i32 };

fn axisOf(fd: posix.fd_t, code: u8) ?Axis {
    var info: AbsInfo = .{ .value = 0, .minimum = 0, .maximum = 0, .fuzz = 0, .flat = 0, .resolution = 0 };
    if (posix.errno(linux.ioctl(fd, eviocgabs(code), @intFromPtr(&info))) != .SUCCESS) return null;
    if (info.maximum <= info.minimum) return null;
    return .{ .min = info.minimum, .max = info.maximum };
}

pub const Options = struct {
    path: ?[]const u8 = null,
    swap_xy: bool = false,
    invert_x: bool = false,
    invert_y: bool = false,
};

pub const Touch = struct {
    fd: posix.fd_t = -1,
    name: [64]u8 = @splat(0),
    x_axis: Axis = .{ .min = 0, .max = 1 },
    y_axis: Axis = .{ .min = 0, .max = 1 },
    swap_xy: bool = false,
    invert_x: bool = false,
    invert_y: bool = false,

    down: bool = false,
    pending_down: bool = false,
    pending_up: bool = false,
    /// Current multitouch slot.  Only slot 0 (the first finger) drives events:
    /// multi-touch panels emit `ABS_MT_TRACKING_ID = -1` for the *other* slots,
    /// and honouring those would press-then-release a single tap in one frame.
    mt_slot: i32 = 0,
    norm_x: f32 = 0.5,
    norm_y: f32 = 0.5,
    last_x: f32 = 0.5,
    last_y: f32 = 0.5,
    moved: bool = false,

    /// Try the given device, or scan /dev/input/event* for a touchscreen.
    pub fn init(allocator: std.mem.Allocator, opts: Options) Touch {
        _ = allocator;
        var self = Touch{
            .swap_xy = opts.swap_xy,
            .invert_x = opts.invert_x,
            .invert_y = opts.invert_y,
        };
        if (opts.path) |p| {
            _ = self.tryOpen(p);
        } else {
            var buf: [64]u8 = undefined;
            var i: u32 = 0;
            while (i < 32) : (i += 1) {
                const path = std.fmt.bufPrint(&buf, "/dev/input/event{d}", .{i}) catch continue;
                if (self.tryOpen(path)) break;
            }
        }
        if (self.fd >= 0) {
            std.log.info("touch: using {s} \"{s}\"", .{ "evdev", std.mem.sliceTo(&self.name, 0) });
        }
        return self;
    }

    pub fn deinit(self: *Touch) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.* = undefined;
    }

    pub fn active(self: *const Touch) bool {
        return self.fd >= 0;
    }

    fn tryOpen(self: *Touch, path: []const u8) bool {
        const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch return false;
        errdefer _ = linux.close(fd);

        var keys: [KEY_MAX / 8 + 1]u8 = @splat(0);
        _ = linux.ioctl(fd, eviocgbit(EV_KEY, keys.len), @intFromPtr(&keys));
        var abs: [ABS_MAX / 8 + 1]u8 = @splat(0);
        _ = linux.ioctl(fd, eviocgbit(EV_ABS, abs.len), @intFromPtr(&abs));

        const has_pos = bitSet(&abs, ABS_X) or bitSet(&abs, ABS_MT_POSITION_X);
        const has_touch = bitSet(&keys, BTN_TOUCH) or bitSet(&abs, ABS_MT_TRACKING_ID);
        if (!has_pos or !has_touch) {
            _ = linux.close(fd);
            return false;
        }

        // Prefer the multitouch axes, fall back to the single-touch ones.
        const ax = axisOf(fd, ABS_MT_POSITION_X) orelse axisOf(fd, ABS_X) orelse {
            _ = linux.close(fd);
            return false;
        };
        const ay = axisOf(fd, ABS_MT_POSITION_Y) orelse axisOf(fd, ABS_Y) orelse {
            _ = linux.close(fd);
            return false;
        };

        var name: [64]u8 = @splat(0);
        _ = linux.ioctl(fd, eviocgname(name.len), @intFromPtr(&name));

        self.fd = fd;
        self.name = name;
        self.x_axis = ax;
        self.y_axis = ay;
        return true;
    }

    /// Drain pending events and post DVUI touch events.
    pub fn poll(self: *Touch, win: *dvui.Window) void {
        if (self.fd < 0) return;

        var buf: [64 * @sizeOf(InputEvent)]u8 = undefined;
        while (true) {
            const n = posix.read(self.fd, &buf) catch return;
            if (n == 0) return;
            const count = n / @sizeOf(InputEvent);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const bytes = buf[i * @sizeOf(InputEvent) ..][0..@sizeOf(InputEvent)];
                const ev: InputEvent = std.mem.bytesToValue(InputEvent, bytes);
                self.handle(ev, win);
            }
            if (n < buf.len) return;
        }
    }

    fn handle(self: *Touch, ev: InputEvent, win: *dvui.Window) void {
        switch (ev.type_) {
            EV_ABS => switch (ev.code) {
                ABS_X, ABS_MT_POSITION_X => {
                    self.norm_x = self.normalize(ev.value, self.x_axis, self.invert_x);
                    self.moved = true;
                },
                ABS_Y, ABS_MT_POSITION_Y => {
                    self.norm_y = self.normalize(ev.value, self.y_axis, self.invert_y);
                    self.moved = true;
                },
                ABS_MT_TRACKING_ID => {
                    if (self.mt_slot == 0) {
                        if (ev.value < 0) self.pending_up = true else self.pending_down = true;
                    }
                },
                ABS_MT_SLOT => self.mt_slot = ev.value,
                else => {},
            },
            EV_KEY => {
                if (ev.code == BTN_TOUCH) {
                    if (ev.value != 0) self.pending_down = true else self.pending_up = true;
                }
            },
            EV_SYN => self.sync(win),
            else => {},
        }
    }

    fn normalize(_: *const Touch, value: i32, axis: Axis, invert: bool) f32 {
        const span: f32 = @floatFromInt(axis.max - axis.min);
        var t = (@as(f32, @floatFromInt(value)) - @as(f32, @floatFromInt(axis.min))) / span;
        t = std.math.clamp(t, 0, 1);
        return if (invert) 1.0 - t else t;
    }

    fn screenPoint(self: *const Touch) dvui.Point {
        var x = self.norm_x;
        var y = self.norm_y;
        if (self.swap_xy) {
            const tmp = x;
            x = y;
            y = tmp;
        }
        return .{ .x = x, .y = y };
    }

    /// Called on EV_SYN once the whole event batch has been consumed, so the
    /// position includes every ABS_MT_POSITION_* update in that batch.
    fn sync(self: *Touch, win: *dvui.Window) void {
        if (self.pending_down and !self.down) {
            self.down = true;
            const p = self.screenPoint();
            self.last_x = p.x;
            self.last_y = p.y;
            self.moved = false;
            _ = win.addEventPointer(.{
                .button = .touch0,
                .action = .press,
                .xynorm = p,
            }) catch {};
        }

        if (self.down and self.moved) {
            const p = self.screenPoint();
            _ = win.addEventTouchMotion(.touch0, p.x, p.y, p.x - self.last_x, p.y - self.last_y) catch {};
            self.last_x = p.x;
            self.last_y = p.y;
            self.moved = false;
        }

        if (self.pending_up and self.down) {
            self.down = false;
            const p = self.screenPoint();
            _ = win.addEventPointer(.{
                .button = .touch0,
                .action = .release,
                .xynorm = p,
            }) catch {};
        }

        self.pending_down = false;
        self.pending_up = false;
    }
};
