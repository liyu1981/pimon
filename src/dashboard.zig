//! The screens shared by the SDL2/KMSDRM and software-framebuffer front-ends.
//!
//! This file is only *composition*: sampling lives in `metrics`, drawing
//! primitives in `widgets`, and the markup engine in `layout`.

const std = @import("std");
const dvui = @import("dvui");
const metrics = @import("metrics");
const widgets = @import("widgets");
const layout_mod = @import("layout");
const net = @import("net");

pub const Channel = struct { bits: u8 = 0, offset: u8 = 0 };

pub const DisplayInfo = struct {
    width: u32 = 0,
    height: u32 = 0,
    bpp: u32 = 0,
    red: Channel = .{},
    green: Channel = .{},
    blue: Channel = .{},
    driver: []const u8 = "",
};

/// Widget state owned by the built-in dashboard screen.  Everything measured
/// from the system lives in `metrics.SystemMetrics`.
pub const Controls = struct {
    animate: bool = true,
    slider: f32 = 0.35,
    text: [128]u8 = @splat(0),
};

/// The built-in (code-driven) dashboard.
pub fn frame(m: *metrics.SystemMetrics, c: *Controls, info: DisplayInfo) !dvui.App.Result {
    // Escape closes the app (the Quit button does the same).
    for (dvui.events()) |*e| {
        if (e.evt == .key and e.evt.key.action == .down and e.evt.key.code == .escape) {
            return .close;
        }
    }

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .style = .window,
        .padding = dvui.Rect.all(10),
        .name = "root",
    });
    defer root.deinit();

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .name = "titlebar" });
        defer row.deinit();
        dvui.label(@src(), "pimon", .{}, .{ .font = .theme(.title), .gravity_y = 0.5, .name = "title" });
        dvui.label(@src(), "  {d:.1} fps", .{m.fps}, .{ .gravity_y = 0.5, .name = "fps" });
        if (dvui.button(@src(), "Quit", .{}, .{ .gravity_x = 1.0, .name = "quit" })) {
            return .close;
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    {
        var cols = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .name = "columns" });
        defer cols.deinit();

        // Left: system information as text.
        {
            var info_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .vertical, .min_size_content = .{ .w = 300 }, .name = "info" });
            defer info_box.deinit();

            dvui.label(@src(), "System", .{}, .{ .font = .theme(.heading), .name = "system_hdr" });
            dvui.label(@src(), "Host: {s}  ({d} CPUs)", .{ std.mem.sliceTo(&m.hostname, 0), m.cpu_count }, .{ .name = "host" });
            dvui.label(@src(), "Kernel: {s}", .{std.mem.sliceTo(&m.kernel, 0)}, .{ .name = "kernel" });
            dvui.label(@src(), "Uptime: {d}h {d}m {d}s", .{
                m.uptime_s / 3600,
                (m.uptime_s % 3600) / 60,
                m.uptime_s % 60,
            }, .{ .name = "uptime" });
            dvui.label(@src(), "Load: {d:.2}  {d:.2}  {d:.2}", .{ m.load[0], m.load[1], m.load[2] }, .{ .name = "load" });
            dvui.label(@src(), "Display: {d}x{d} {d}bpp {s}", .{ info.width, info.height, info.bpp, info.driver }, .{ .name = "display" });
            dvui.label(@src(), "Layout: {d}/{d}/{d} bits at {d}/{d}/{d}", .{
                info.red.bits,   info.green.bits,   info.blue.bits,
                info.red.offset, info.green.offset, info.blue.offset,
            }, .{ .name = "display_layout" });
        }

        // Right: gauges, a sparkline, and the demo controls.
        {
            var right = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .name = "right" });
            defer right.deinit();

            dvui.label(@src(), "Meters", .{}, .{ .font = .theme(.heading), .name = "meters_hdr" });
            {
                var row2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .name = "meters" });
                defer row2.deinit();

                const ncpu: f32 = @floatFromInt(@max(1, m.cpu_count));
                widgets.gauge.cell(0, "LOAD %", .{
                    .value = std.math.clamp(m.load[0] / ncpu * 100.0, 0, 100),
                    .accent = widgets.palette.green,
                }, "%", 150, 130, .{});

                widgets.gauge.cell(1, "TEMP", .{
                    .value = m.temp_c,
                    .max = 80.0,
                    .accent = widgets.palette.orange,
                }, "°C", 150, 130, .{});

                const used_kb: f32 = @floatFromInt(m.mem_total_kb -| m.mem_avail_kb);
                const total_kb: f32 = @floatFromInt(m.mem_total_kb);
                widgets.gauge.cell(2, "RAM %", .{
                    .value = if (total_kb > 0) used_kb / total_kb * 100.0 else 0,
                    .accent = widgets.palette.lime,
                }, "%", 150, 130, .{});
            }

            dvui.labelNoFmt(@src(), "load history (48 s)", .{}, .{ .name = "hist_lbl" });
            {
                var spark = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .expand = .horizontal,
                    .min_size_content = .{ .h = 48 },
                    .background = false,
                    .name = "spark",
                });
                defer spark.deinit();
                widgets.sparkline.draw(spark.data().rectScale(), m.loadHistory(), widgets.sparkline.default_color);
            }

            _ = dvui.separator(@src(), .{ .expand = .horizontal });

            dvui.label(@src(), "Controls", .{}, .{ .font = .theme(.heading), .name = "controls_hdr" });
            _ = dvui.checkbox(@src(), &c.animate, "Animate", .{ .name = "anim" });

            dvui.label(@src(), "Slider: {d:.0}%", .{c.slider * 100.0}, .{ .name = "slider_lbl" });
            _ = dvui.slider(@src(), .{ .fraction = &c.slider }, .{ .expand = .horizontal, .min_size_content = .{ .h = 22 }, .name = "slider" });

            dvui.label(@src(), "Text entry:", .{}, .{ .name = "te_lbl" });
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &c.text } }, .{ .expand = .horizontal, .name = "text" });
            te.deinit();

            dvui.label(@src(), "Tab/Shift-Tab focuses, Enter activates, Esc quits.", .{}, .{ .name = "hint" });
        }
    }

    return .ok;
}

/// Publish this frame's metrics so a `.layout.zon` file can bind to them.
/// Well-known keys (all live scalars / series):
///
/// | key | meaning |
/// | --- | --- |
/// | `cpu.load_pct` | load average 1min as % of CPU count (0..100) |
/// | `cpu.load1` / `cpu.load5` / `cpu.load15` | raw load averages |
/// | `cpu.count` | logical CPU count |
/// | `cpu.temp` | CPU temperature in °C |
/// | `cpu.temp_max` | scale hint for the temp gauge (80 °C) |
/// | `ram.used_mb` / `ram.total_mb` / `ram.used_pct` | memory usage |
/// | `cpu.load_hist` | series: last 48 one-second load samples |
pub fn publishMetrics(gpa: std.mem.Allocator, b: *layout_mod.Bindings, m: *metrics.SystemMetrics) void {
    const ncpu: f32 = @floatFromInt(@max(1, m.cpu_count));
    b.setFloat(gpa, "cpu.count", ncpu) catch {};
    b.setFloat(gpa, "cpu.load1", m.load[0]) catch {};
    b.setFloat(gpa, "cpu.load5", m.load[1]) catch {};
    b.setFloat(gpa, "cpu.load15", m.load[2]) catch {};
    b.setFloat(gpa, "cpu.load_pct", std.math.clamp(m.load[0] / ncpu * 100.0, 0, 100)) catch {};
    b.setFloat(gpa, "cpu.temp", m.temp_c) catch {};
    b.setFloat(gpa, "cpu.temp_max", 80.0) catch {};

    const used_kb: f32 = @floatFromInt(m.mem_total_kb -| m.mem_avail_kb);
    const total_kb: f32 = @floatFromInt(m.mem_total_kb);
    b.setFloat(gpa, "ram.used_mb", used_kb / 1024.0) catch {};
    b.setFloat(gpa, "ram.total_mb", total_kb / 1024.0) catch {};
    b.setFloat(gpa, "ram.used_pct", if (total_kb > 0) used_kb / total_kb * 100.0 else 0) catch {};

    if (m.loadHistory().len > 1) {
        b.setSeries(gpa, "cpu.load_hist", m.loadHistory()) catch {};
    }
}

/// Render a `.layout.zon` driven screen instead of the built-in dashboard.
///
/// The widget tree comes entirely from the file; this only supplies the window
/// chrome, an always-reachable Quit/Reload bar (so a broken or quit-less
/// layout can never strand the app, e.g. on a touchscreen with no keyboard),
/// and Escape-to-quit.
pub fn layoutFrame(
    layout: *layout_mod.Layout,
    bindings: *layout_mod.Bindings,
    m: *metrics.SystemMetrics,
) !dvui.App.Result {
    for (dvui.events()) |*e| {
        if (e.evt == .key and e.evt.key.action == .down and e.evt.key.code == .escape) {
            return .close;
        }
    }

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .style = .window,
        .padding = dvui.Rect.all(8),
        .name = "layout_root",
    });
    defer root.deinit();

    if (layout.load_error) |msg| {
        dvui.labelNoFmt(@src(), "layout error:", .{}, .{ .color_text = .{ .color = dvui.Color.red } });
        dvui.labelNoFmt(@src(), msg, .{}, .{});
        dvui.labelNoFmt(@src(), "Fix the .zon file, then press Reload layout.", .{}, .{});
    } else if (layout.root != null) {
        layout.render(bindings);
    } else {
        dvui.labelNoFmt(@src(), "(no layout loaded)", .{}, .{});
    }

    // Always-available control bar, independent of whatever the file declares.
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .name = "layout_bar" });
        defer bar.deinit();
        dvui.labelNoFmt(@src(), "layout.zon screen", .{}, .{ .gravity_y = 0.5 });
        dvui.label(@src(), "  {d:.1} fps", .{m.fps}, .{ .gravity_y = 0.5 });
        if (dvui.button(@src(), "Reload", .{}, .{ .gravity_x = 1.0 })) {
            bindings.action = "reload_layout";
        }
        if (dvui.button(@src(), "Quit", .{}, .{ .gravity_x = 1.0 })) {
            return .close;
        }
    }

    return .ok;
}

// ---------------------------------------------------------------------------
// Network listener glue
// ---------------------------------------------------------------------------

/// Apply one injected event to the layout bindings.  Returns an action name
/// (borrowed from the event) when the event asked the app to do something.
/// The event can be freed afterwards because owned copies of key/series live
/// in the bindings.
pub fn applyNetEvent(
    gpa: std.mem.Allocator,
    bindings: *layout_mod.Bindings,
    ev: *const net.Event,
) ?[]const u8 {
    switch (ev.*) {
        .set_float => |e| bindings.setFloatOwned(gpa, e.key, e.value) catch {},
        .set_bool => |e| {
            if (!bindings.setBool(e.key, e.value)) {
                std.log.debug("net: no bool binding named '{s}'", .{e.key});
            }
        },
        .set_series => |e| bindings.setSeriesOwned(gpa, e.key, e.values) catch {},
        .action => |a| return a,
    }
    return null;
}

/// Handle an action from a layout button or from the network listener.
/// Returns true when the app should quit.
pub fn runAction(
    gpa: std.mem.Allocator,
    action: []const u8,
    layout: *?layout_mod.Layout,
    bindings: *layout_mod.Bindings,
) bool {
    if (std.mem.eql(u8, action, "quit")) return true;
    if (std.mem.eql(u8, action, "reload_layout")) {
        // Rebuild the bindings too: `l.load` frees the old layout arena, and
        // the registered bool keys point into it.  Injected values are dropped
        // and can be re-sent by the controller.
        bindings.deinit(gpa);
        bindings.* = .{};
        if (layout.*) |*l| {
            l.load();
            l.registerBindings(bindings);
        }
        return false;
    }
    std.log.info("action: {s}", .{action});
    return false;
}

const Snapshot = struct {
    host: []const u8,
    kernel: []const u8,
    uptime_s: u64,
    load_1: f32,
    load_5: f32,
    load_15: f32,
    cpu_count: u32,
    cpu_temp_c: f32,
    mem_used_mb: f32,
    mem_total_mb: f32,
    mem_used_pct: f32,
    fps: f32,
    load_hist: []const f32,
    display: struct {
        width: u32,
        height: u32,
        bpp: u32,
        driver: []const u8,
    },
};

/// Serialize the current metrics as the JSON served by
/// `GET /api/v1/metrics`.  The caller owns the result.
pub fn snapshotJson(gpa: std.mem.Allocator, m: *const metrics.SystemMetrics, info: DisplayInfo) ![]u8 {
    const used_kb: f32 = @floatFromInt(m.mem_total_kb -| m.mem_avail_kb);
    const total_kb: f32 = @floatFromInt(m.mem_total_kb);
    const snap: Snapshot = .{
        .host = std.mem.sliceTo(&m.hostname, 0),
        .kernel = std.mem.sliceTo(&m.kernel, 0),
        .uptime_s = m.uptime_s,
        .load_1 = m.load[0],
        .load_5 = m.load[1],
        .load_15 = m.load[2],
        .cpu_count = m.cpu_count,
        .cpu_temp_c = m.temp_c,
        .mem_used_mb = used_kb / 1024.0,
        .mem_total_mb = total_kb / 1024.0,
        .mem_used_pct = if (total_kb > 0) used_kb / total_kb * 100.0 else 0,
        .fps = m.fps,
        .load_hist = m.loadHistory(),
        .display = .{
            .width = info.width,
            .height = info.height,
            .bpp = info.bpp,
            .driver = info.driver,
        },
    };
    return std.json.Stringify.valueAlloc(gpa, snap, .{});
}

/// Build and publish the metrics snapshot, dropping it silently if allocation
/// fails (the dashboard keeps rendering either way).
pub fn publishSnapshot(
    gpa: std.mem.Allocator,
    server: *net.Server,
    m: *const metrics.SystemMetrics,
    info: DisplayInfo,
) void {
    const json = snapshotJson(gpa, m, info) catch return;
    defer gpa.free(json);
    server.publishSnapshot(json);
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

/// Write a 0xAARRGGBB buffer as PNG using dvui's bundled encoder.
pub fn savePng(io: std.Io, gpa: std.mem.Allocator, pixels_argb: []const u32, w: u32, h: u32, path: []const u8) !void {
    const pixels = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(pixels);
    for (pixels_argb, 0..) |p, i| {
        pixels[i * 4 + 0] = @truncate(p >> 16);
        pixels[i * 4 + 1] = @truncate(p >> 8);
        pixels[i * 4 + 2] = @truncate(p);
        pixels[i * 4 + 3] = 0xff;
    }

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try dvui.PNGEncoder.writeWithResolution(&writer.interface, pixels, w, h, 0);
    try writer.end();
}
