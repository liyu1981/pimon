//! pimon — SDL2 + KMSDRM front-end (GPU accelerated, no X11/Wayland).
//!
//! On a Raspberry Pi booted to the console this talks to the DRM/KMS stack
//! directly through SDL2's `kmsdrm` video driver and renders with the
//! `opengles2` renderer (VideoCore IV / Mesa vc4).
//!
//! Build natively on the Pi with the system SDL2:
//!   sudo apt install libsdl2-dev libdrm-dev libgbm-dev libgles2-mesa-dev
//!   sudo usermod -aG video,input "$USER"      # then log out / reboot
//!   zig build -Doptimize=ReleaseFast
//!   ./zig-out/bin/pimon
//!
//! For a software `/dev/fb0` fallback use `zig build -Dgui=fb`.

const std = @import("std");
const posix = std.posix;
const dvui = @import("dvui");
const dashboard = @import("dashboard");
const SDLBackend = @import("sdl-backend");
const c = SDLBackend.c;
const touch_mod = @import("touch.zig");
const layout_mod = @import("layout");
const metrics = @import("metrics");

var quit_requested = std.atomic.Value(bool).init(false);

fn onSignal(_: posix.SIG) callconv(.c) void {
    quit_requested.store(true, .seq_cst);
}

pub fn main(init: std.process.Init) !void {
    dvui.io = init.io;

    var cfg = Config{};
    try cfg.parse(init);

    // Force the GPU-on-console path *before* SDL_Init runs.  These are the
    // hints from the SDL KMSDRM/GLES2 setup guide; they can be overridden from
    // the command line for debugging (e.g. --video-driver x11).
    setHint("SDL_VIDEODRIVER", cfg.video_driver orelse "kmsdrm");
    setHint("SDL_RENDER_DRIVER", cfg.render_driver orelse "opengles2");
    setHint("SDL_OPENGL_ES_DRIVER", "1");
    setHint("SDL_RENDER_SCALE_QUALITY", "linear");
    // DVUI handles SDL_FINGER* directly; don't duplicate them as mouse events.
    setHint("SDL_TOUCH_MOUSE_EVENTS", "0");
    if (!cfg.drm_master) setHint("SDL_KMSDRM_REQUIRE_DRM_MASTER", "0");

    var backend = SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = cfg.width, .h = cfg.height },
        .min_size = .{ .w = 320, .h = 240 },
        .vsync = cfg.vsync,
        .title = "pimon",
        .fullscreen = cfg.fullscreen,
    }) catch |err| {
        std.debug.print(
            "pimon: SDL init failed: {s}\n" ++
                "  video driver: {s}, render driver: {s}\n" ++
                "  - run from the console (not X/Wayland) and check /dev/dri/card0 access\n" ++
                "  - add your user to the 'video' and 'input' groups, or use sudo\n" ++
                "  - try --video-driver x11 for a desktop debugging session\n",
            .{ @errorName(err), cfg.video_driver orelse "kmsdrm", cfg.render_driver orelse "opengles2" },
        );
        std.process.exit(1);
    };
    defer backend.deinit();

    var window_open = true;
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = if (cfg.dark) dvui.Theme.builtin.adwaita_dark else dvui.Theme.builtin.adwaita_light,
        .keybinds = .windows,
        .open_flag = &window_open,
    });
    defer win.deinit();
    if (cfg.fps > 0) win.max_fps = cfg.fps;

    // The official Raspberry Pi 7" panel lacks ABS_MT_PRESSURE, which SDL2's
    // KMSDRM evdev code requires, so SDL may expose no touch device at all.
    // In that case read the evdev node ourselves and feed DVUI directly.
    var touchdev = touch_mod.Touch{};
    var touch_active = false;
    switch (cfg.touch_mode) {
        .off => {},
        .on => {
            touchdev = touch_mod.Touch.init(init.gpa, touchOptions(cfg));
            touch_active = true;
        },
        .auto => {
            const sdl_touch = c.SDL_GetNumTouchDevices();
            if (sdl_touch > 0) {
                std.log.info("touch: SDL reports {d} touch device(s); using SDL touch", .{sdl_touch});
            } else {
                std.log.info("touch: SDL has no usable touch device (the Pi 7\" panel lacks ABS_MT_PRESSURE); falling back to evdev", .{});
                touchdev = touch_mod.Touch.init(init.gpa, touchOptions(cfg));
                touch_active = true;
            }
        },
    }
    if (touch_active and !touchdev.active()) {
        std.log.warn("touch: no evdev touchscreen found -- check the 'input' group (or sudo), or pass --touch-device PATH", .{});
    }
    defer {
        if (touch_active) touchdev.deinit();
    }

    installSignalHandlers();

    var m = metrics.SystemMetrics{};
    m.sample();
    var controls: dashboard.Controls = .{};

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

    var driver_buf: [32]u8 = @splat(0);
    var renderer_buf: [32]u8 = @splat(0);
    const info = displayInfo(&backend, &driver_buf, &renderer_buf);
    std.log.info("pimon: SDL video={s} renderer={s} {d}x{d}", .{
        std.mem.sliceTo(&driver_buf, 0),
        std.mem.sliceTo(&renderer_buf, 0),
        info.width,
        info.height,
    });

    // Continuously-animated dashboard: pace frames ourselves so it keeps
    // updating even when dvui has no scheduled animation.
    const frame_ns: i128 = if (cfg.fps > 0) @intFromFloat(1_000_000_000.0 / cfg.fps) else 0;
    var next_frame_ns: i128 = 0;
    var interrupted = false;
    var frames: u64 = 0;
    while (window_open) {
        if (quit_requested.load(.seq_cst)) break;
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        // Forward every pending SDL event to dvui.
        try backend.addAllEvents(&win);
        // Then feed our own evdev touchscreen reader, if it is in use.
        if (touch_active) touchdev.poll(&win);

        m.tick += 1;
        if (m.shouldSample()) m.sample();
        m.updateFrameStats();

        // Publish live metrics for `.layout.zon` bindings (gauges/sparklines).
        if (layout != null) dashboard.publishMetrics(init.gpa, &bindings, &m);

        const result: dvui.App.Result = if (layout) |*l|
            try dashboard.layoutFrame(l, &bindings, &m)
        else
            try dashboard.frame(&m, &controls, info);
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
            const wait_us: u32 = if (wait_ns > 0) @intCast(@min(@divTrunc(wait_ns, 1000), std.math.maxInt(u32))) else 0;
            interrupted = try backend.waitEventTimeout(wait_us);
        }
    }
}

fn touchOptions(cfg: Config) touch_mod.Options {
    return .{
        .path = cfg.touch_device,
        .swap_xy = cfg.touch_swap,
        .invert_x = cfg.touch_invert_x,
        .invert_y = cfg.touch_invert_y,
    };
}

fn setHint(name: [*:0]const u8, value: []const u8) void {
    var buf: [256]u8 = undefined;
    const n = @min(buf.len - 1, value.len);
    @memcpy(buf[0..n], value[0..n]);
    buf[n] = 0;
    _ = c.SDL_SetHint(name, &buf);
}

fn displayInfo(backend: *SDLBackend, driver_buf: []u8, renderer_buf: []u8) dashboard.DisplayInfo {
    const ps = backend.pixelSize();

    if (c.SDL_GetCurrentVideoDriver()) |p| metrics.copyTrimmed(driver_buf, std.mem.sliceTo(p, 0));
    var rinfo: c.SDL_RendererInfo = undefined;
    if (c.SDL_GetRendererInfo(backend.renderer, &rinfo) == 0 and rinfo.name != null) {
        metrics.copyTrimmed(renderer_buf, std.mem.sliceTo(rinfo.name, 0));
    }

    return .{
        .width = @intFromFloat(ps.w),
        .height = @intFromFloat(ps.h),
        .bpp = 32,
        .red = .{ .bits = 8, .offset = 16 },
        .green = .{ .bits = 8, .offset = 8 },
        .blue = .{ .bits = 8, .offset = 0 },
        .driver = std.mem.sliceTo(driver_buf, 0),
    };
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
    width: f32 = 800,
    height: f32 = 480,
    fps: f32 = 30,
    frames: u64 = 0,
    layout_path: ?[]const u8 = null,
    dark: bool = true,
    fullscreen: bool = true,
    vsync: bool = true,
    drm_master: bool = true,
    video_driver: ?[]const u8 = null,
    render_driver: ?[]const u8 = null,
    touch_mode: enum { auto, on, off } = .auto,
    touch_device: ?[]const u8 = null,
    touch_swap: bool = false,
    touch_invert_x: bool = false,
    touch_invert_y: bool = false,

    fn parse(self: *Config, init: std.process.Init) !void {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
        defer it.deinit();
        _ = it.next(); // executable

        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--size")) {
                const s = it.next() orelse die();
                const x = std.mem.indexOfScalar(u8, s, 'x') orelse die();
                self.width = @floatFromInt(std.fmt.parseInt(u32, s[0..x], 10) catch die());
                self.height = @floatFromInt(std.fmt.parseInt(u32, s[x + 1 ..], 10) catch die());
            } else if (std.mem.eql(u8, arg, "--fps")) {
                self.fps = std.fmt.parseFloat(f32, it.next() orelse die()) catch die();
            } else if (std.mem.eql(u8, arg, "--frames")) {
                self.frames = std.fmt.parseInt(u64, it.next() orelse die(), 10) catch die();
            } else if (std.mem.eql(u8, arg, "--video-driver")) {
                self.video_driver = it.next() orelse die();
            } else if (std.mem.eql(u8, arg, "--render-driver")) {
                self.render_driver = it.next() orelse die();
            } else if (std.mem.eql(u8, arg, "--windowed")) {
                self.fullscreen = false;
            } else if (std.mem.eql(u8, arg, "--fullscreen")) {
                self.fullscreen = true;
            } else if (std.mem.eql(u8, arg, "--touch")) {
                self.touch_mode = .on;
            } else if (std.mem.eql(u8, arg, "--no-touch")) {
                self.touch_mode = .off;
            } else if (std.mem.eql(u8, arg, "--touch-device")) {
                self.touch_device = it.next() orelse die();
            } else if (std.mem.eql(u8, arg, "--touch-swap")) {
                self.touch_swap = true;
            } else if (std.mem.eql(u8, arg, "--touch-invert-x")) {
                self.touch_invert_x = true;
            } else if (std.mem.eql(u8, arg, "--touch-invert-y")) {
                self.touch_invert_y = true;
            } else if (std.mem.eql(u8, arg, "--no-vsync")) {
                self.vsync = false;
            } else if (std.mem.eql(u8, arg, "--no-drm-master")) {
                self.drm_master = false;
            } else if (std.mem.eql(u8, arg, "--light")) {
                self.dark = false;
            } else if (std.mem.eql(u8, arg, "--dark")) {
                self.dark = true;
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
        \\pimon (SDL2/KMSDRM backend) - DVUI dashboard on the console
        \\
        \\Usage: pimon [options]
        \\  --size WxH          requested window size (KMSDRM uses the panel mode)
        \\  --fps N             target frames per second (default 30, 0 = vsync-driven)
        \\  --frames N          exit after N frames (0 = run until quit)
        \\  --layout PATH       render a .layout.zon file instead of the dashboard
        \\  --video-driver S    SDL video driver (default kmsdrm; try x11 on a desktop)
        \\  --render-driver S   SDL render driver (default opengles2; try software)
        \\  --windowed          do not request fullscreen
        \\  --no-vsync          disable vertical sync
        \\  --touch             force the evdev touch reader (Pi 7" panel)
        \\  --no-touch          disable touch input
        \\  --touch-device P    use this evdev node (default: autodetect)
        \\  --touch-swap        swap touch X/Y (rotated panel)
        \\  --touch-invert-x    invert touch X
        \\  --touch-invert-y    invert touch Y
        \\  --no-drm-master     allow running without DRM master
        \\  --light | --dark    colour scheme (default dark)
        \\  -h, --help          show this help
        \\
    , .{});
}
