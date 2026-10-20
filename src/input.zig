//! Linux input (evdev) support for the framebuffer backend.
//!
//! Reads `/dev/input/event*` directly.  A device that advertises `KEY_A` is
//! treated as a keyboard; a device with `REL_X` or `ABS_X`/`ABS_MT_POSITION_X`
//! is treated as a pointing device (mouse or touchscreen).  Events are
//! translated into DVUI events and posted to the window.

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
const EV_REL = 0x02;
const EV_ABS = 0x03;

const REL_X = 0x00;
const REL_Y = 0x01;
const REL_HWHEEL = 0x06;
const REL_WHEEL = 0x08;

const ABS_X = 0x00;
const ABS_Y = 0x01;
const ABS_MT_SLOT = 0x2f;
const ABS_MT_POSITION_X = 0x35;
const ABS_MT_POSITION_Y = 0x36;
const ABS_MT_TRACKING_ID = 0x39;

const BTN_LEFT = 0x110;
const BTN_RIGHT = 0x111;
const BTN_MIDDLE = 0x112;
const BTN_TOUCH = 0x14a;

const KEY_MAX = 0x2ff;
const REL_MAX = 0x0f;
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

const Device = struct {
    fd: posix.fd_t,
    name: []u8,
    is_pointer: bool,
    abs_x: ?Axis = null,
    abs_y: ?Axis = null,
    mt_x: ?Axis = null,
    mt_y: ?Axis = null,

    fn close(self: *Device, allocator: std.mem.Allocator) void {
        _ = linux.close(self.fd);
        allocator.free(self.name);
    }
};

pub const Input = struct {
    allocator: std.mem.Allocator,
    kbd: ?Device = null,
    ptr: ?Device = null,

    x: f32 = 0,
    y: f32 = 0,
    mods: dvui.enums.Mod = .none,
    have_pointer: bool = false,
    touch_down: bool = false,
    pending_touch_down: bool = false,
    pending_touch_up: bool = false,
    mt_slot: i32 = 0,
    norm_x: f32 = 0.5,
    norm_y: f32 = 0.5,
    scroll_accum_x: f32 = 0,
    scroll_accum_y: f32 = 0,
    moved: bool = false,

    pub fn init(allocator: std.mem.Allocator) Input {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Input) void {
        if (self.kbd) |*d| d.close(self.allocator);
        if (self.ptr) |*d| d.close(self.allocator);
        self.* = undefined;
    }

    /// Open explicit device paths, or autodetect when the path is null.
    pub fn open(self: *Input, kbd_path: ?[]const u8, ptr_path: ?[]const u8) void {
        if (kbd_path) |p| {
            if (self.openDevice(p, .keyboard, false)) |d| self.kbd = d;
        }
        if (ptr_path) |p| {
            if (self.openDevice(p, .pointer, false)) |d| self.ptr = d;
        }
        if (self.kbd == null and kbd_path == null) self.kbd = self.autodetect(.keyboard);
        if (self.ptr == null and ptr_path == null) self.ptr = self.autodetect(.pointer);
        if (self.ptr == null) {
            std.log.warn("input: no touchscreen/pointer found; check /dev/input permissions (input group or sudo) or pass --pointer PATH", .{});
        }
        if (self.kbd == null) {
            std.log.warn("input: no keyboard found; check /dev/input permissions (input group or sudo) or pass --keyboard PATH", .{});
        }
    }

    const Want = enum { keyboard, pointer };

    fn openDevice(self: *Input, path: []const u8, want: Want, prefer_touch: bool) ?Device {
        const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch return null;
        var keep_fd = false;
        defer {
            if (!keep_fd) _ = linux.close(fd);
        }

        var keys: [KEY_MAX / 8 + 1]u8 = @splat(0);
        _ = linux.ioctl(fd, eviocgbit(EV_KEY, keys.len), @intFromPtr(&keys));
        var rels: [REL_MAX / 8 + 1]u8 = @splat(0);
        _ = linux.ioctl(fd, eviocgbit(EV_REL, rels.len), @intFromPtr(&rels));
        var abs: [ABS_MAX / 8 + 1]u8 = @splat(0);
        _ = linux.ioctl(fd, eviocgbit(EV_ABS, abs.len), @intFromPtr(&abs));

        const is_keyboard = bitSet(&keys, 30); // KEY_A
        const is_mouse = bitSet(&rels, REL_X);
        const is_touch = bitSet(&abs, ABS_X) or bitSet(&abs, ABS_MT_POSITION_X);
        const is_pointer = is_mouse or is_touch;

        const matches = switch (want) {
            .keyboard => is_keyboard,
            .pointer => is_pointer and !is_keyboard and (!prefer_touch or is_touch),
        };
        if (!matches) return null;

        var name_buf: [128]u8 = @splat(0);
        _ = linux.ioctl(fd, eviocgname(name_buf.len), @intFromPtr(&name_buf));
        const name = self.allocator.dupe(u8, std.mem.sliceTo(&name_buf, 0)) catch return null;

        var dev = Device{ .fd = fd, .name = name, .is_pointer = is_pointer };
        if (is_pointer) {
            dev.abs_x = axisOf(fd, ABS_X);
            dev.abs_y = axisOf(fd, ABS_Y);
            dev.mt_x = axisOf(fd, ABS_MT_POSITION_X);
            dev.mt_y = axisOf(fd, ABS_MT_POSITION_Y);
        }
        keep_fd = true;
        return dev;
    }

    fn axisOf(fd: posix.fd_t, code: u8) ?Axis {
        var info: AbsInfo = .{ .value = 0, .minimum = 0, .maximum = 0, .fuzz = 0, .flat = 0, .resolution = 0 };
        if (posix.errno(linux.ioctl(fd, eviocgabs(code), @intFromPtr(&info))) != .SUCCESS) return null;
        if (info.maximum <= info.minimum) return null;
        return .{ .min = info.minimum, .max = info.maximum };
    }

    fn autodetect(self: *Input, want: Want) ?Device {
        // Prefer a touchscreen over a relative mouse when both exist.
        if (want == .pointer) {
            if (self.scan(want, true)) |d| return d;
        }
        return self.scan(want, false);
    }

    fn scan(self: *Input, want: Want, prefer_touch: bool) ?Device {
        var buf: [64]u8 = undefined;
        var i: u32 = 0;
        while (i < 32) : (i += 1) {
            const path = std.fmt.bufPrint(&buf, "/dev/input/event{d}", .{i}) catch continue;
            if (self.openDevice(path, want, prefer_touch)) |d| {
                std.log.info("input: {s} \"{s}\"", .{ @tagName(want), d.name });
                return d;
            }
        }
        return null;
    }

    fn fillFds(self: *Input, fds: *[2]posix.pollfd) usize {
        var n: usize = 0;
        if (self.kbd) |d| {
            fds[n] = .{ .fd = d.fd, .events = posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        if (self.ptr) |d| {
            fds[n] = .{ .fd = d.fd, .events = posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        return n;
    }

    /// Wait up to `timeout_us` microseconds for input.  Returns true if any
    /// device became readable.
    pub fn wait(self: *Input, timeout_us: u32) bool {
        var fds: [2]posix.pollfd = undefined;
        const n = self.fillFds(&fds);
        if (n == 0) {
            const ts: posix.timespec = .{
                .sec = @intCast(timeout_us / 1_000_000),
                .nsec = @intCast((timeout_us % 1_000_000) * std.time.ns_per_us),
            };
            _ = linux.nanosleep(&ts, null);
            return false;
        }
        var ms: i32 = @intCast(@min(timeout_us / 1000, @as(u32, std.math.maxInt(i32))));
        if (ms == 0 and timeout_us != 0) ms = 1;
        const ready = posix.poll(fds[0..n], ms) catch return false;
        return ready > 0;
    }

    /// Drain all pending input and post DVUI events.
    pub fn poll(self: *Input, win: *dvui.Window, width: f32, height: f32) void {
        if (self.kbd) |d| self.readDevice(d, win, width, height);
        if (self.ptr) |d| self.readDevice(d, win, width, height);
        self.flushScroll(win);
    }

    fn readDevice(self: *Input, dev: Device, win: *dvui.Window, width: f32, height: f32) void {
        var buf: [64 * @sizeOf(InputEvent)]u8 = undefined;
        while (true) {
            const n = posix.read(dev.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return,
            };
            if (n == 0) return;
            const count = n / @sizeOf(InputEvent);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const bytes = buf[i * @sizeOf(InputEvent) ..][0..@sizeOf(InputEvent)];
                const ev: InputEvent = std.mem.bytesToValue(InputEvent, bytes);
                self.handleEvent(dev, ev, win, width, height);
            }
            if (n < buf.len) return;
        }
    }

    fn handleEvent(self: *Input, dev: Device, ev: InputEvent, win: *dvui.Window, width: f32, height: f32) void {
        switch (ev.type_) {
            EV_SYN => self.flushScroll(win),
            EV_KEY => {
                if (dev.is_pointer) {
                    self.handlePointerKey(ev, win);
                } else {
                    self.handleKey(ev, win);
                }
            },
            EV_REL => self.handleRel(ev, width, height),
            EV_ABS => self.handleAbs(dev, ev, width, height),
            else => {},
        }
    }

    fn handleKey(self: *Input, ev: InputEvent, win: *dvui.Window) void {
        const action: @TypeOf(@as(dvui.Event.Key, undefined).action) = switch (ev.value) {
            0 => .up,
            1 => .down,
            2 => .repeat,
            else => return,
        };

        switch (ev.code) {
            42, 54 => self.setMod(.lshift, .rshift, ev.value != 0, ev.code == 42),
            29, 97 => self.setMod(.lcontrol, .rcontrol, ev.value != 0, ev.code == 29),
            56, 100 => self.setMod(.lalt, .ralt, ev.value != 0, ev.code == 56),
            125, 126 => self.setMod(.lcommand, .rcommand, ev.value != 0, ev.code == 125),
            else => {},
        }

        const key = keyFromCode(ev.code);
        _ = win.addEventKey(.{ .code = key, .action = action, .mod = self.mods }) catch {};

        if (ev.value == 1 or ev.value == 2) {
            if (!self.mods.control()) {
                if (charFromCode(ev.code, self.mods.shift())) |ch| {
                    var tmp = [1]u8{ch};
                    _ = win.addEventText(.{ .text = &tmp }) catch {};
                }
            }
        }
    }

    fn setMod(self: *Input, left: dvui.enums.Mod, right: dvui.enums.Mod, down: bool, is_left: bool) void {
        const bit = if (is_left) left else right;
        const s: u16 = @backingInt(self.mods);
        const t: u16 = @backingInt(bit);
        self.mods = @fromBackingInt(@intCast(if (down) s | t else s & ~t));
    }

    fn handleRel(self: *Input, ev: InputEvent, width: f32, height: f32) void {
        switch (ev.code) {
            REL_X => self.x = std.math.clamp(self.x + @as(f32, @floatFromInt(ev.value)), 0, width - 1),
            REL_Y => self.y = std.math.clamp(self.y + @as(f32, @floatFromInt(ev.value)), 0, height - 1),
            REL_WHEEL => self.scroll_accum_y += @floatFromInt(ev.value),
            REL_HWHEEL => self.scroll_accum_x += @floatFromInt(ev.value),
            else => {},
        }
        self.have_pointer = true;
        self.moved = true;
    }

    fn handleAbs(self: *Input, dev: Device, ev: InputEvent, width: f32, height: f32) void {
        const raw = @as(f32, @floatFromInt(ev.value));
        switch (ev.code) {
            ABS_X, ABS_MT_POSITION_X => {
                if (dev.mt_x orelse dev.abs_x) |r| self.norm_x = (raw - @as(f32, @floatFromInt(r.min))) / @as(f32, @floatFromInt(r.max - r.min));
                self.x = std.math.clamp(self.norm_x, 0, 1) * width;
                self.have_pointer = true;
                self.moved = true;
            },
            ABS_Y, ABS_MT_POSITION_Y => {
                if (dev.mt_y orelse dev.abs_y) |r| self.norm_y = (raw - @as(f32, @floatFromInt(r.min))) / @as(f32, @floatFromInt(r.max - r.min));
                self.y = std.math.clamp(self.norm_y, 0, 1) * height;
                self.have_pointer = true;
                self.moved = true;
            },
            ABS_MT_SLOT => self.mt_slot = ev.value,
            ABS_MT_TRACKING_ID => {
                // Multi-touch devices (including the official 7" panel) signal
                // touch down/up with the tracking id, often without BTN_TOUCH.
                if (self.mt_slot == 0) {
                    if (ev.value < 0) self.pending_touch_up = true else self.pending_touch_down = true;
                }
            },
            else => {},
        }
    }

    fn handlePointerKey(self: *Input, ev: InputEvent, win: *dvui.Window) void {
        self.have_pointer = true;
        if (ev.code == BTN_TOUCH) {
            // Defer to EV_SYN: the position ABS events for this touch may
            // arrive after BTN_TOUCH in the same batch.
            if (ev.value != 0) self.pending_touch_down = true else self.pending_touch_up = true;
            return;
        }
        const button: dvui.enums.Button = switch (ev.code) {
            BTN_LEFT => .left,
            BTN_RIGHT => .right,
            BTN_MIDDLE => .middle,
            else => return,
        };
        const action: dvui.Event.Mouse.Action = if (ev.value != 0) .press else .release;
        _ = win.addEventMouseMotion(.{ .pt = .{ .x = self.x, .y = self.y } }) catch {};
        _ = win.addEventMouseButton(button, action) catch {};
    }

    fn flushScroll(self: *Input, win: *dvui.Window) void {
        if (self.pending_touch_down and !self.touch_down) {
            self.touch_down = true;
            _ = win.addEventMouseMotion(.{ .pt = .{ .x = self.x, .y = self.y } }) catch {};
            _ = win.addEventMouseButton(.left, .press) catch {};
            self.moved = false;
        }

        if (self.moved) {
            self.moved = false;
            _ = win.addEventMouseMotion(.{ .pt = .{ .x = self.x, .y = self.y } }) catch {};
        }

        if (self.pending_touch_up and self.touch_down) {
            self.touch_down = false;
            _ = win.addEventMouseMotion(.{ .pt = .{ .x = self.x, .y = self.y } }) catch {};
            _ = win.addEventMouseButton(.left, .release) catch {};
        }
        self.pending_touch_down = false;
        self.pending_touch_up = false;
        if (self.scroll_accum_y != 0) {
            _ = win.addEventMouseWheel(self.scroll_accum_y / 120.0, .vertical, .mouse) catch {};
            self.scroll_accum_y = 0;
        }
        if (self.scroll_accum_x != 0) {
            _ = win.addEventMouseWheel(self.scroll_accum_x / 120.0, .horizontal, .mouse) catch {};
            self.scroll_accum_x = 0;
        }
    }
};

fn keyFromCode(code: u16) dvui.enums.Key {
    return switch (code) {
        1 => .escape,
        2 => .one,
        3 => .two,
        4 => .three,
        5 => .four,
        6 => .five,
        7 => .six,
        8 => .seven,
        9 => .eight,
        10 => .nine,
        11 => .zero,
        12 => .minus,
        13 => .equal,
        14 => .backspace,
        15 => .tab,
        16 => .q,
        17 => .w,
        18 => .e,
        19 => .r,
        20 => .t,
        21 => .y,
        22 => .u,
        23 => .i,
        24 => .o,
        25 => .p,
        26 => .left_bracket,
        27 => .right_bracket,
        28 => .enter,
        29 => .left_control,
        30 => .a,
        31 => .s,
        32 => .d,
        33 => .f,
        34 => .g,
        35 => .h,
        36 => .j,
        37 => .k,
        38 => .l,
        39 => .semicolon,
        40 => .apostrophe,
        41 => .grave,
        42 => .left_shift,
        43 => .backslash,
        44 => .z,
        45 => .x,
        46 => .c,
        47 => .v,
        48 => .b,
        49 => .n,
        50 => .m,
        51 => .comma,
        52 => .period,
        53 => .slash,
        54 => .right_shift,
        55 => .kp_multiply,
        56 => .left_alt,
        57 => .space,
        58 => .caps_lock,
        59 => .f1,
        60 => .f2,
        61 => .f3,
        62 => .f4,
        63 => .f5,
        64 => .f6,
        65 => .f7,
        66 => .f8,
        67 => .f9,
        68 => .f10,
        69 => .num_lock,
        70 => .scroll_lock,
        71 => .kp_7,
        72 => .kp_8,
        73 => .kp_9,
        74 => .kp_subtract,
        75 => .kp_4,
        76 => .kp_5,
        77 => .kp_6,
        78 => .kp_add,
        79 => .kp_1,
        80 => .kp_2,
        81 => .kp_3,
        82 => .kp_0,
        83 => .kp_decimal,
        87 => .f11,
        88 => .f12,
        96 => .kp_enter,
        97 => .right_control,
        98 => .kp_divide,
        99 => .print,
        100 => .right_alt,
        102 => .home,
        103 => .up,
        104 => .page_up,
        105 => .left,
        106 => .right,
        107 => .end,
        108 => .down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        119 => .pause,
        125 => .left_command,
        126 => .right_command,
        else => .unknown,
    };
}

fn charFromCode(code: u16, shift: bool) ?u8 {
    return switch (code) {
        2 => if (shift) '!' else '1',
        3 => if (shift) '@' else '2',
        4 => if (shift) '#' else '3',
        5 => if (shift) '$' else '4',
        6 => if (shift) '%' else '5',
        7 => if (shift) '^' else '6',
        8 => if (shift) '&' else '7',
        9 => if (shift) '*' else '8',
        10 => if (shift) '(' else '9',
        11 => if (shift) ')' else '0',
        12 => if (shift) '_' else '-',
        13 => if (shift) '+' else '=',
        16 => if (shift) 'Q' else 'q',
        17 => if (shift) 'W' else 'w',
        18 => if (shift) 'E' else 'e',
        19 => if (shift) 'R' else 'r',
        20 => if (shift) 'T' else 't',
        21 => if (shift) 'Y' else 'y',
        22 => if (shift) 'U' else 'u',
        23 => if (shift) 'I' else 'i',
        24 => if (shift) 'O' else 'o',
        25 => if (shift) 'P' else 'p',
        26 => if (shift) '{' else '[',
        27 => if (shift) '}' else ']',
        30 => if (shift) 'A' else 'a',
        31 => if (shift) 'S' else 's',
        32 => if (shift) 'D' else 'd',
        33 => if (shift) 'F' else 'f',
        34 => if (shift) 'G' else 'g',
        35 => if (shift) 'H' else 'h',
        36 => if (shift) 'J' else 'j',
        37 => if (shift) 'K' else 'k',
        38 => if (shift) 'L' else 'l',
        39 => if (shift) ':' else ';',
        40 => if (shift) '"' else '\'',
        41 => if (shift) '~' else '`',
        43 => if (shift) '|' else '\\',
        44 => if (shift) 'Z' else 'z',
        45 => if (shift) 'X' else 'x',
        46 => if (shift) 'C' else 'c',
        47 => if (shift) 'V' else 'v',
        48 => if (shift) 'B' else 'b',
        49 => if (shift) 'N' else 'n',
        50 => if (shift) 'M' else 'm',
        51 => if (shift) '<' else ',',
        52 => if (shift) '>' else '.',
        53 => if (shift) '?' else '/',
        57 => ' ',
        else => null,
    };
}
