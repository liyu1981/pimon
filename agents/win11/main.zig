//! pimon Win11 agent.
//!
//! Headless console daemon: samples local Windows metrics and pushes typed
//! batches to a pimon server over `POST /api/v1/data`.
//!
//! `zig build win` produces `zig-out/bin/pimon-agent-win11.exe`.

const std = @import("std");
const c = @import("winapi");
const data = @import("data");
const config = @import("config.zig");
const client = @import("client.zig");
const Sampler = @import("sampler.zig").Sampler;
const Gpu = @import("gpu.zig").Gpu;

var quit_requested = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init) !void {
    var args = Args{};
    args.parse(init) catch |err| {
        std.debug.print("pimon-agent-win11: {s}\n\n", .{@errorName(err)});
        printUsage();
        std.process.exit(2);
    };
    if (args.help) {
        printUsage();
        return;
    }

    if (args.command == .install_config) {
        installConfig(init, args.config_path);
        return;
    }

    var cfg = config.load(init.io, init.gpa, init.environ_map, args.config_path);
    if (args.url) |url| cfg.setUrl(url);
    if (args.token) |token| cfg.setSecret(token);
    if (args.interval_ms) |ms| cfg.interval_ms = ms;
    if (args.agent_name) |name| cfg.setAgentName(name);
    if (args.no_gpu) cfg.enable_gpu = false;

    if (cfg.url().len == 0) {
        std.debug.print("pimon-agent-win11: PIMON_URL is not set.\n", .{});
        std.debug.print("Run `pimon-agent-win11 install-config` to create and edit the config.\n", .{});
        std.process.exit(2);
    }
    if (cfg.secret().len == 0) {
        std.debug.print("pimon-agent-win11: PIMON_HTTP_SECRET is not set.\n", .{});
        std.debug.print("Run `pimon-agent-win11 install-config` to create and edit the config.\n", .{});
        std.process.exit(2);
    }

    std.log.info("agent: name={s} server={s} interval={d}ms gpu={s}", .{
        cfg.agentName(),
        cfg.url(),
        cfg.interval_ms,
        if (cfg.enable_gpu) "on" else "off",
    });

    if (!args.once) {
        _ = c.SetConsoleCtrlHandler(onCtrl, 1);
    }

    var sampler = Sampler.init(init.gpa, init.environ_map);
    defer sampler.deinit();

    var gpu = Gpu.init(init.gpa, cfg.enable_gpu);
    defer gpu.deinit();
    if (gpu.available()) {
        std.log.info("gpu: {s} ({s})", .{
            std.mem.sliceTo(&gpu.name, 0),
            std.mem.sliceTo(&gpu.provider, 0),
        });
    }

    var http: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer http.deinit();

    while (!quit_requested.load(.acquire)) {
        sampler.sample();
        gpu.sample();

        var entries: std.ArrayList(client.Entry) = .empty;
        defer entries.deinit(init.gpa);
        try collectEntries(init.gpa, &entries, &sampler, &gpu);

        const payload = try client.buildPayload(
            init.gpa,
            cfg.agentName(),
            std.Io.Clock.real.now(init.io).toMilliseconds(),
            entries.items,
        );
        defer init.gpa.free(payload);

        if (args.verbose) std.debug.print("{s}\n", .{payload});

        var post_ok = true;
        client.postBatch(init.io, init.gpa, &http, cfg.url(), cfg.secret(), payload) catch |err| {
            post_ok = false;
            std.log.err("agent: upload failed: {s}", .{@errorName(err)});
        };

        if (args.once) {
            if (!post_ok) std.process.exit(1);
            return;
        }

        std.Io.sleep(init.io, .{ .nanoseconds = @intCast(cfg.interval_ms * std.time.ns_per_ms) }, .awake) catch return;
    }
}

fn installConfig(init: std.process.Init, config_path: ?[]const u8) void {
    var path_buf: [config.max_path]u8 = undefined;
    const path = config.resolvePath(init.environ_map, config_path, &path_buf) catch |err| {
        std.debug.print("pimon-agent-win11: cannot resolve config path: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };

    const result = config.installTemplate(init.io, path) catch |err| {
        std.debug.print("pimon-agent-win11: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    switch (result) {
        .created => std.debug.print("pimon-agent-win11: created {s}\n", .{path}),
        .exists => std.debug.print("pimon-agent-win11: config already exists: {s}\n", .{path}),
    }

    if (!openInNotepad(init.gpa, path)) {
        std.debug.print("pimon-agent-win11: could not launch Notepad; edit this file manually:\n  {s}\n", .{path});
        return;
    }
    std.debug.print("Fill in PIMON_URL and PIMON_HTTP_SECRET, save, then run pimon-agent-win11.exe.\n", .{});
}

fn openInNotepad(gpa: std.mem.Allocator, path: []const u8) bool {
    var cmd_buf: [config.max_path + 32]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "notepad.exe \"{s}\"", .{path}) catch return false;
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, cmd) catch return false;
    defer gpa.free(cmd_w);

    var si: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
    si.cb = @sizeOf(c.STARTUPINFOW);
    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);

    if (c.CreateProcessW(null, cmd_w.ptr, null, null, 0, 0, null, null, &si, &pi) == 0) return false;
    _ = c.CloseHandle(pi.hProcess);
    _ = c.CloseHandle(pi.hThread);
    return true;
}

fn collectEntries(
    gpa: std.mem.Allocator,
    entries: *std.ArrayList(client.Entry),
    s: *Sampler,
    gpu: *Gpu,
) !void {
    try add(entries, gpa, "win.online", .{ .boolean = true });
    try add(entries, gpa, "win.cpu.util_pct", .{ .float = s.cpu_util_pct });
    try add(entries, gpa, "win.cpu.queue", .{ .float = s.cpu_queue });
    try add(entries, gpa, "win.cpu.util_hist", .{ .series = s.cpu_hist.slice() });
    try add(entries, gpa, "win.ram.used_pct", .{ .float = s.memUsedPct() });
    try add(entries, gpa, "win.ram.used_mb", .{ .float = s.memUsedMb() });
    try add(entries, gpa, "win.ram.total_mb", .{ .float = s.memTotalMb() });
    try add(entries, gpa, "win.net.rx_mbs", .{ .float = s.net_rx_mbs });
    try add(entries, gpa, "win.net.tx_mbs", .{ .float = s.net_tx_mbs });
    try add(entries, gpa, "win.net.rx_total_mb", .{ .float = @as(f32, @floatFromInt(s.net_total_rx)) / 1024.0 / 1024.0 });
    try add(entries, gpa, "win.net.tx_total_mb", .{ .float = @as(f32, @floatFromInt(s.net_total_tx)) / 1024.0 / 1024.0 });

    if (gpu.available()) {
        try add(entries, gpa, "win.gpu.util_pct", .{ .float = gpu.util_pct });
        try add(entries, gpa, "win.gpu.util_hist", .{ .series = gpu.hist.slice() });
        try add(entries, gpa, "win.gpu.mem_used_mb", .{ .float = gpu.mem_used_mb });
        try add(entries, gpa, "win.gpu.mem_total_mb", .{ .float = gpu.mem_total_mb });
        const mem_pct = if (gpu.mem_total_mb > 0) gpu.mem_used_mb / gpu.mem_total_mb * 100.0 else 0;
        try add(entries, gpa, "win.gpu.mem_pct", .{ .float = mem_pct });
        try add(entries, gpa, "win.gpu.name", .{ .text = std.mem.sliceTo(&gpu.name, 0) });
        try add(entries, gpa, "win.gpu.provider", .{ .text = std.mem.sliceTo(&gpu.provider, 0) });
        if (gpu.temp_available) try add(entries, gpa, "win.gpu.temp_c", .{ .float = gpu.temp_c });
        if (gpu.power_available) try add(entries, gpa, "win.gpu.power_w", .{ .float = gpu.power_w });
    }

    try add(entries, gpa, "win.sys.host", .{ .text = std.mem.sliceTo(&s.hostname, 0) });
    try add(entries, gpa, "win.sys.os", .{ .text = std.mem.sliceTo(&s.os_name, 0) });
    try add(entries, gpa, "win.sys.cpu_model", .{ .text = std.mem.sliceTo(&s.cpu_model, 0) });
    try add(entries, gpa, "win.sys.cpu", .{ .text = std.mem.sliceTo(&s.cpu_text, 0) });
    try add(entries, gpa, "win.sys.uptime", .{ .text = std.mem.sliceTo(&s.uptime_text, 0) });
    try add(entries, gpa, "win.sys.mem", .{ .text = std.mem.sliceTo(&s.mem_text, 0) });
    try add(entries, gpa, "win.sys.net", .{ .text = std.mem.sliceTo(&s.net_text, 0) });
    try add(entries, gpa, "win.net.name", .{ .text = std.mem.sliceTo(&s.net_name, 0) });
}

fn add(entries: *std.ArrayList(client.Entry), gpa: std.mem.Allocator, key: []const u8, value: data.Value) !void {
    try entries.append(gpa, .{ .key = key, .value = value });
}

fn onCtrl(ctrl_type: c.DWORD) callconv(.c) c.WINBOOL {
    switch (ctrl_type) {
        0, 1, 2, 5, 6 => quit_requested.store(true, .seq_cst),
        else => {},
    }
    return 1;
}

const Args = struct {
    command: enum { run, install_config } = .run,
    config_path: ?[]const u8 = null,
    url: ?[]const u8 = null,
    token: ?[]const u8 = null,
    interval_ms: ?u64 = null,
    agent_name: ?[]const u8 = null,
    once: bool = false,
    no_gpu: bool = false,
    verbose: bool = false,
    help: bool = false,

    fn parse(self: *Args, init: std.process.Init) !void {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
        defer it.deinit();
        _ = it.next();

        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "install-config") or std.mem.eql(u8, arg, "config")) {
                self.command = .install_config;
            } else if (std.mem.eql(u8, arg, "--config")) {
                self.config_path = it.next() orelse return error.MissingValue;
            } else if (std.mem.eql(u8, arg, "--url")) {
                self.url = it.next() orelse return error.MissingValue;
            } else if (std.mem.eql(u8, arg, "--token")) {
                self.token = it.next() orelse return error.MissingValue;
            } else if (std.mem.eql(u8, arg, "--interval-ms")) {
                self.interval_ms = std.fmt.parseInt(u64, it.next() orelse return error.MissingValue, 10) catch return error.BadValue;
                if (self.interval_ms.? < 100) return error.BadValue;
            } else if (std.mem.eql(u8, arg, "--agent-name")) {
                self.agent_name = it.next() orelse return error.MissingValue;
            } else if (std.mem.eql(u8, arg, "--once")) {
                self.once = true;
            } else if (std.mem.eql(u8, arg, "--no-gpu")) {
                self.no_gpu = true;
            } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                self.verbose = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                self.help = true;
            } else {
                return error.UnknownArgument;
            }
        }
    }
};

fn printUsage() void {
    std.debug.print(
        \\pimon-agent-win11 - Windows 11 metrics agent for pimon
        \\
        \\Usage: pimon-agent-win11 [options]
        \\       pimon-agent-win11 install-config [--config PATH]
        \\
        \\Commands:
        \\  install-config      create the config (if absent) and open it in Notepad
        \\
        \\Options:
        \\  --config PATH      config file (default %APPDATA%\pimon\agent.config)
        \\  --url URL          override PIMON_URL (e.g. http://pi:8717)
        \\  --token TOKEN      override PIMON_HTTP_SECRET
        \\  --interval-ms N    sample interval (default 1000, min 100)
        \\  --agent-name NAME  name sent in the batch (default win11)
        \\  --once             sample and POST once, then exit
        \\  --no-gpu           disable GPU sampling
        \\  --verbose, -v      print each JSON batch
        \\  -h, --help         show this help
        \\
    , .{});
}
