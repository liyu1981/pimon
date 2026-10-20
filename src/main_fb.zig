//! pimon — software `/dev/fb0` front-end.
//!
//! This is the fallback path: it renders DVUI with the CPU rasterizer in
//! `backend.zig` straight into the Linux framebuffer.  It needs no GPU and no
//! SDL, and is handy for testing on a machine with a framebuffer but no DRM.
//!
//! Build/run with: `zig build -Dgui=fb run -- --fb /dev/fb0`

const std = @import("std");
const posix = std.posix;
const dvui = @import("dvui");
const backend_mod = @import("backend");
const dashboard = @import("dashboard");
const layout_mod = @import("layout");

const Backend = backend_mod.Backend;

var quit_requested = std.atomic.Value(bool).init(false);

fn onSignal(_: posix.SIG) callconv(.c) void {
    quit_requested.store(true, .seq_cst);
}

inline fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

pub fn main(init: std.process.Init) !void {
    dvui.io = init.io;

    var cfg = Config{};
    try cfg.parse(init);

    var backend = Backend.init(init.gpa, .{
        .path = cfg.fb_path,
        .geometry = .{
            .width = cfg.width,
            .height = cfg.height,
            .bpp = cfg.bpp,
        },
        .content_scale = cfg.scale,
        .dark = cfg.dark,
        .enable_input = !cfg.no_input,
        .kbd_path = cfg.kbd,
        .ptr_path = cfg.ptr,
        .grab_console = cfg.grab_console,
        .clear_color = if (cfg.clear) |c| c | 0xff000000 else if (cfg.dark) rgba(0x1e, 0x1e, 0x28, 0xff) else rgba(0xf5, 0xf5, 0xf5, 0xff),
    }) catch |err| {
        std.debug.print(
            "pimon: cannot use framebuffer '{s}': {s}\n" ++
                "  - if it exists, run with sudo or add your user to the 'video' group\n" ++
                "  - for a plain file add --size WxH --bpp 32, or use --help\n",
            .{ cfg.fb_path, @errorName(err) },
        );
        std.process.exit(1);
    };
    defer backend.deinit();

    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = if (cfg.dark) dvui.Theme.builtin.adwaita_dark else dvui.Theme.builtin.adwaita_light,
        .keybinds = .windows,
    });
    defer win.deinit();
    win.max_fps = cfg.fps;

    installSignalHandlers();

    var state = dashboard.State{};
    state.sample();

    // Optional `.layout.zon`-driven screen: layout structure lives in the file,
    // this binary only owns the schema (see src/layout.zig).
    var bindings: layout_mod.Bindings = .{};
    defer bindings.deinit(init.gpa);
    var layout: ?layout_mod.Layout = null;
    defer if (layout) |*l| l.deinit();
    if (cfg.layout_path) |path| {
        var l = layout_mod.Layout.init(init.gpa, init.io, path);
        l.load();
        l.registerBindings(&bindings);
        layout = l;
    }

    const info = dashboard.DisplayInfo{
        .width = backend.fb.width,
        .height = backend.fb.height,
        .bpp = backend.fb.bpp,
        .red = .{ .bits = @intCast(backend.fb.red.length), .offset = @intCast(backend.fb.red.offset) },
        .green = .{ .bits = @intCast(backend.fb.green.length), .offset = @intCast(backend.fb.green.offset) },
        .blue = .{ .bits = @intCast(backend.fb.blue.length), .offset = @intCast(backend.fb.blue.offset) },
        .driver = "fbdev",
    };

    std.log.info("pimon: {d}x{d} {d}bpp fb={s} rcs={d} field={d} line={d}", .{
        backend.fb.width,
        backend.fb.height,
        backend.fb.bpp,
        cfg.fb_path,
        backend.fb.red.length,
        backend.fb.green.length,
        backend.fb.blue.length,
    });

    // Continuously-animated dashboard: pace frames ourselves.
    const frame_ns: i128 = if (cfg.fps > 0) @intFromFloat(1_000_000_000.0 / cfg.fps) else 0;
    var next_frame_ns: i128 = 0;
    var interrupted = false;
    var frames: u64 = 0;
    while (true) {
        if (quit_requested.load(.seq_cst)) break;
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        backend.pollEvents(&win);

        state.tick += 1;
        if (state.shouldSample()) state.sample();
        state.updateFps();

        const result: dvui.App.Result = if (layout) |*l|
            try dashboard.layoutFrame(l, &bindings, &state)
        else
            try dashboard.frame(&state, info);
        if (result == .close) break;

        // Act on an action dispatched by the layout file this frame.
        if (bindings.takeAction()) |action| {
            if (std.mem.eql(u8, action, "quit")) break;
            if (std.mem.eql(u8, action, "reload_layout")) {
                if (layout) |*l| {
                    l.load();
                    l.registerBindings(&bindings);
                }
            } else {
                std.log.info("layout action: {s}", .{action});
            }
        }

        _ = try win.end(.{});
        frames += 1;
        if (cfg.frames != 0 and frames >= cfg.frames) break;

        if (frame_ns > 0) {
            const now = win.backend.nanoTime();
            next_frame_ns = @max(next_frame_ns, now) + frame_ns;
            const wait_ns = next_frame_ns - now;
            if (wait_ns > 0) {
                const wait_us: u32 = @intCast(@min(@divTrunc(wait_ns, 1000), std.math.maxInt(u32)));
                interrupted = backend.waitEvents(wait_us);
            } else {
                interrupted = false;
            }
        }
    }

    if (cfg.dump) |path| {
        const snapshot = try backend.snapshotRgba(init.gpa);
        defer init.gpa.free(snapshot);
        try dashboard.savePng(init.io, init.gpa, snapshot, backend.fb.width, backend.fb.height, path);
        std.log.info("wrote {s}", .{path});
    }
}

fn installSignalHandlers() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
}

const Config = struct {
    fb_path: []const u8 = "/dev/fb0",
    width: ?u32 = null,
    height: ?u32 = null,
    bpp: ?u32 = null,
    fps: f32 = 30,
    frames: u64 = 0,
    dump: ?[]const u8 = null,
    layout_path: ?[]const u8 = null,
    dark: bool = true,
    scale: f32 = 1.0,
    no_input: bool = false,
    grab_console: bool = true,
    kbd: ?[]const u8 = null,
    ptr: ?[]const u8 = null,
    clear: ?u32 = null,

    fn parse(self: *Config, init: std.process.Init) !void {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
        defer it.deinit();
        _ = it.next(); // executable

        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--fb")) {
                self.fb_path = it.next() orelse die();
            } else if (std.mem.eql(u8, arg, "--size")) {
                const s = it.next() orelse die();
                const x = std.mem.indexOfScalar(u8, s, 'x') orelse die();
                self.width = std.fmt.parseInt(u32, s[0..x], 10) catch die();
                self.height = std.fmt.parseInt(u32, s[x + 1 ..], 10) catch die();
            } else if (std.mem.eql(u8, arg, "--bpp")) {
                self.bpp = std.fmt.parseInt(u32, it.next() orelse die(), 10) catch die();
            } else if (std.mem.eql(u8, arg, "--fps")) {
                self.fps = std.fmt.parseFloat(f32, it.next() orelse die()) catch die();
            } else if (std.mem.eql(u8, arg, "--frames")) {
                self.frames = std.fmt.parseInt(u64, it.next() orelse die(), 10) catch die();
            } else if (std.mem.eql(u8, arg, "--dump")) {
                self.dump = it.next() orelse die();
            } else if (std.mem.eql(u8, arg, "--scale")) {
                self.scale = std.fmt.parseFloat(f32, it.next() orelse die()) catch die();
            } else if (std.mem.eql(u8, arg, "--light")) {
                self.dark = false;
            } else if (std.mem.eql(u8, arg, "--dark")) {
                self.dark = true;
            } else if (std.mem.eql(u8, arg, "--no-input")) {
                self.no_input = true;
            } else if (std.mem.eql(u8, arg, "--no-console")) {
                self.grab_console = false;
            } else if (std.mem.eql(u8, arg, "--keyboard")) {
                self.kbd = it.next() orelse die();
            } else if (std.mem.eql(u8, arg, "--pointer")) {
                self.ptr = it.next() orelse die();
            } else if (std.mem.eql(u8, arg, "--clear")) {
                const s = it.next() orelse die();
                self.clear = std.fmt.parseInt(u32, s, 16) catch die();
            } else if (std.mem.eql(u8, arg, "--layout")) {
                self.layout_path = it.next() orelse die();
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else {
                std.debug.print("unknown argument: {s}\n\n", .{arg});
                printUsage();
                std.process.exit(2);
            }
        }
    }
};

fn die() noreturn {
    printUsage();
    std.process.exit(2);
}

fn printUsage() void {
    std.debug.print(
        \\pimon (framebuffer backend) - DVUI dashboard on the Linux framebuffer
        \\
        \\Usage: pimon [options]
        \\  --fb PATH        framebuffer device or file (default /dev/fb0)
        \\  --size WxH       force resolution (needed for plain files)
        \\  --bpp N          force bits per pixel: 16, 24 or 32
        \\  --fps N          target frames per second (default 30)
        \\  --frames N       exit after N frames (0 = run until quit)
        \\  --dump PATH      write the last frame to a PNG and exit
        \\  --layout PATH    render a .layout.zon file instead of the dashboard
        \\  --scale F        content scale (default 1.0)
        \\  --light|--dark   colour scheme (default dark)
        \\  --clear RRGGBB   background colour
        \\  --no-input       do not open /dev/input/event*
        \\  --no-console     leave the VT in text mode (kernel cursor stays visible)
        \\  --keyboard PATH  use this evdev keyboard
        \\  --pointer PATH   use this evdev pointer device
        \\  -h, --help       show this help
        \\
    , .{});
}
