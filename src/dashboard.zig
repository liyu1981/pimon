//! Shared dashboard UI used by both the SDL2/KMSDRM and the software
//! framebuffer front-ends.

const std = @import("std");
const posix = std.posix;
const dvui = @import("dvui");

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

pub const State = struct {
    tick: u32 = 0,
    checkbox: bool = true,
    slider: f32 = 0.35,
    progress: f32 = 0.0,
    text_buf: [128]u8 = @splat(0),

    hostname: [64]u8 = @splat(0),
    kernel: [64]u8 = @splat(0),
    load: [3]f32 = .{ 0, 0, 0 },
    cpu_count: u32 = 0,
    uptime_s: u64 = 0,
    mem_total_kb: u64 = 0,
    mem_avail_kb: u64 = 0,
    temp_c: f32 = 0,
    frame_count: u64 = 0,
    fps: f32 = 0,
    last_sample_ms: i128 = 0,
    last_fps_ms: i128 = 0,
    fps_frames: u32 = 0,

    pub fn nowMs() i128 {
        var ts: posix.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1000 + @divTrunc(@as(i128, ts.nsec), std.time.ns_per_ms);
    }

    pub fn shouldSample(self: *State) bool {
        return nowMs() - self.last_sample_ms > 1000;
    }

    pub fn updateFps(self: *State) void {
        self.frame_count += 1;
        self.fps_frames += 1;
        const now = nowMs();
        if (now - self.last_fps_ms >= 1000) {
            self.fps = @as(f32, @floatFromInt(self.fps_frames)) * 1000.0 / @as(f32, @floatFromInt(now - self.last_fps_ms));
            self.fps_frames = 0;
            self.last_fps_ms = now;
        }
        if (self.checkbox) {
            self.progress += 0.01;
            if (self.progress > 1.0) self.progress = 0.0;
        }
    }

    pub fn sample(self: *State) void {
        self.last_sample_ms = nowMs();

        var buf: [2048]u8 = undefined;
        if (readSmallFile("/proc/sys/kernel/hostname", &buf)) |data| copyTrimmed(&self.hostname, data);
        if (readSmallFile("/proc/sys/kernel/osrelease", &buf)) |data| copyTrimmed(&self.kernel, data);
        if (readSmallFile("/proc/loadavg", &buf)) |data| {
            var toks = std.mem.tokenizeAny(u8, data, " \n");
            for (&self.load) |*l| {
                l.* = std.fmt.parseFloat(f32, toks.next() orelse break) catch 0;
            }
        }
        if (readSmallFile("/proc/cpuinfo", &buf)) |data| {
            var count: u32 = 0;
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |line| {
                if (std.mem.startsWith(u8, line, "processor")) count += 1;
            }
            if (count > 0) self.cpu_count = count;
        }
        if (readSmallFile("/proc/uptime", &buf)) |data| {
            if (std.mem.indexOfScalar(u8, data, ' ')) |sp| {
                self.uptime_s = @intFromFloat(std.fmt.parseFloat(f64, data[0..sp]) catch 0);
            }
        }
        if (readSmallFile("/proc/meminfo", &buf)) |data| {
            self.mem_total_kb = findMeminfo(data, "MemTotal:") orelse self.mem_total_kb;
            self.mem_avail_kb = findMeminfo(data, "MemAvailable:") orelse self.mem_avail_kb;
        }
        if (readSmallFile("/sys/class/thermal/thermal_zone0/temp", &buf)) |data| {
            const milli = std.fmt.parseInt(i64, std.mem.trim(u8, data, " \n\r\t"), 10) catch 0;
            self.temp_c = @as(f32, @floatFromInt(milli)) / 1000.0;
        }
    }
};

pub fn frame(state: *State, info: DisplayInfo) !dvui.App.Result {
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
        dvui.label(@src(), "  {d:.1} fps", .{state.fps}, .{ .gravity_y = 0.5, .name = "fps" });
        if (dvui.button(@src(), "Quit", .{}, .{ .gravity_x = 1.0, .name = "quit" })) {
            return .close;
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    {
        var cols = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .name = "columns" });
        defer cols.deinit();

        // Left: system information.
        {
            var info_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .vertical, .min_size_content = .{ .w = 300 }, .name = "info" });
            defer info_box.deinit();

            dvui.label(@src(), "System", .{}, .{ .font = .theme(.heading), .name = "system_hdr" });
            dvui.label(@src(), "Host: {s}  ({d} CPUs)", .{ std.mem.sliceTo(&state.hostname, 0), state.cpu_count }, .{ .name = "host" });
            dvui.label(@src(), "Kernel: {s}", .{std.mem.sliceTo(&state.kernel, 0)}, .{ .name = "kernel" });
            dvui.label(@src(), "Uptime: {d}h {d}m {d}s", .{
                state.uptime_s / 3600,
                (state.uptime_s % 3600) / 60,
                state.uptime_s % 60,
            }, .{ .name = "uptime" });
            dvui.label(@src(), "Load: {d:.2}  {d:.2}  {d:.2}", .{ state.load[0], state.load[1], state.load[2] }, .{ .name = "load" });
            dvui.label(@src(), "Memory: {d} / {d} MiB", .{
                (state.mem_total_kb -| state.mem_avail_kb) / 1024,
                state.mem_total_kb / 1024,
            }, .{ .name = "memory" });
            if (state.mem_total_kb > 0) {
                const used = @as(f32, @floatFromInt(state.mem_total_kb -| state.mem_avail_kb)) /
                    @as(f32, @floatFromInt(state.mem_total_kb));
                dvui.progress(@src(), .{ .percent = used }, .{ .expand = .horizontal, .min_size_content = .{ .h = 10 }, .name = "mem_bar" });
            }
            dvui.label(@src(), "CPU temp: {d:.1} C", .{state.temp_c}, .{ .name = "temp" });
            dvui.label(@src(), "Display: {d}x{d} {d}bpp {s}", .{ info.width, info.height, info.bpp, info.driver }, .{ .name = "display" });
            dvui.label(@src(), "Layout: {d}/{d}/{d} bits at {d}/{d}/{d}", .{
                info.red.bits,   info.green.bits,   info.blue.bits,
                info.red.offset, info.green.offset, info.blue.offset,
            }, .{ .name = "display_layout" });

            dvui.progress(@src(), .{ .percent = state.progress }, .{ .expand = .horizontal, .min_size_content = .{ .h = 14 }, .name = "prog" });
        }

        // Right: interactive widgets.
        {
            var controls = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .name = "controls" });
            defer controls.deinit();

            dvui.label(@src(), "Controls", .{}, .{ .font = .theme(.heading), .name = "controls_hdr" });

            _ = dvui.checkbox(@src(), &state.checkbox, "Animate progress bar", .{ .name = "anim" });

            dvui.label(@src(), "Slider: {d:.0}%", .{state.slider * 100.0}, .{ .name = "slider_lbl" });
            _ = dvui.slider(@src(), .{ .fraction = &state.slider }, .{ .expand = .horizontal, .min_size_content = .{ .h = 22 }, .name = "slider" });

            dvui.label(@src(), "Text entry:", .{}, .{ .name = "te_lbl" });
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.text_buf } }, .{ .expand = .horizontal, .name = "text" });
            te.deinit();

            dvui.label(@src(), "Keybind hint: Tab/Shift-Tab focuses, Enter activates, Esc quits.", .{}, .{ .name = "hint" });
        }
    }

    return .ok;
}

// ---------------------------------------------------------------------------
// Small utilities shared by the front-ends
// ---------------------------------------------------------------------------

pub fn copyTrimmed(dst: []u8, src: []const u8) void {
    const trimmed = std.mem.trim(u8, src, " \t\n\r");
    const n = @min(dst.len - 1, trimmed.len);
    @memcpy(dst[0..n], trimmed[0..n]);
    dst[n] = 0;
}

pub fn readSmallFile(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.os.linux.close(fd);
    const n = posix.read(fd, buf) catch return null;
    return buf[0..n];
}

fn findMeminfo(data: []const u8, key: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) {
            var nums = std.mem.tokenizeAny(u8, line[key.len..], " \tkB");
            const first = nums.next() orelse return null;
            return std.fmt.parseInt(u64, first, 10) catch null;
        }
    }
    return null;
}

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
