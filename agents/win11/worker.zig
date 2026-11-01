//! Sampling/upload worker shared by the tray UI and the `--once` path.

const std = @import("std");
const data = @import("data");
const config = @import("config.zig");
const client = @import("client.zig");
const Sampler = @import("sampler.zig").Sampler;
const Gpu = @import("gpu.zig").Gpu;
const LogBuffer = @import("logbuf.zig").LogBuffer;

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    cfg: config.Config,
    log: *LogBuffer,
    stop: *std.atomic.Value(bool),
    running: *std.atomic.Value(bool),
};

pub fn run(ctx: *Context) void {
    defer {
        ctx.running.store(false, .release);
        ctx.log.log("agent stopped");
        ctx.gpa.destroy(ctx);
    }

    ctx.running.store(true, .release);
    ctx.log.logf("agent started -> {s}", .{ctx.cfg.url()});

    var agent = Agent.init(ctx.io, ctx.gpa, ctx.environ, ctx.cfg, ctx.log);
    defer agent.deinit();

    while (!ctx.stop.load(.acquire)) {
        _ = agent.step();
        sleepInterruptible(ctx.io, ctx.cfg.interval_ms, ctx.stop);
    }
}

pub fn runOnce(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    cfg: config.Config,
    log: *LogBuffer,
) bool {
    var agent = Agent.init(io, gpa, environ, cfg, log);
    defer agent.deinit();
    return agent.step();
}

const Agent = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: config.Config,
    log: *LogBuffer,
    sampler: Sampler,
    gpu: Gpu,
    http: std.http.Client,
    last_cycle_ms: i64 = 0,
    samples: u64 = 0,

    fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        cfg: config.Config,
        log: *LogBuffer,
    ) Agent {
        var gpu = Gpu.init(gpa, cfg.enable_gpu);
        if (gpu.available()) {
            log.logf("gpu: {s} ({s})", .{
                std.mem.sliceTo(&gpu.name, 0),
                std.mem.sliceTo(&gpu.provider, 0),
            });
        } else if (cfg.enable_gpu) {
            log.log("gpu: no adapter detected");
        }
        return .{
            .io = io,
            .gpa = gpa,
            .cfg = cfg,
            .log = log,
            .sampler = Sampler.init(gpa, environ),
            .gpu = gpu,
            .http = .{ .allocator = gpa, .io = io },
        };
    }

    fn deinit(self: *Agent) void {
        self.http.deinit();
        self.gpu.deinit();
        self.sampler.deinit();
    }

    fn step(self: *Agent) bool {
        const now_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        const resume_gap_ms = @max(@as(i64, @intCast(self.cfg.interval_ms)) * 5, 5000);
        if (self.last_cycle_ms != 0 and now_ms - self.last_cycle_ms > resume_gap_ms) {
            self.log.logf("resumed after {d}s, resetting HTTP connection", .{@divTrunc(now_ms - self.last_cycle_ms, 1000)});
            resetHttpClient(&self.http, self.io, self.gpa);
        }
        self.last_cycle_ms = now_ms;

        self.sampler.sample();
        self.gpu.sample();

        var entries: std.ArrayList(client.Entry) = .empty;
        defer entries.deinit(self.gpa);
        collectEntries(self.gpa, &entries, &self.sampler, &self.gpu) catch {
            self.log.log("out of memory while building metrics");
            return false;
        };

        const payload = client.buildPayload(
            self.gpa,
            self.cfg.agentName(),
            now_ms,
            entries.items,
        ) catch {
            self.log.log("out of memory while encoding batch");
            return false;
        };
        defer self.gpa.free(payload);

        const ok = upload(&self.http, self.io, self.gpa, &self.cfg, payload, self.log);
        self.samples += 1;
        if (self.samples == 1 and ok) self.log.log("first batch uploaded");
        return ok;
    }
};

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
    try add(entries, gpa, "win.sys.updated", .{ .text = std.mem.sliceTo(&s.updated_text, 0) });
    try add(entries, gpa, "win.sys.updated.weekday", .{ .text = std.mem.sliceTo(&s.updated_weekday, 0) });
    try add(entries, gpa, "win.sys.updated.year", .{ .text = std.mem.sliceTo(&s.updated_year, 0) });
    try add(entries, gpa, "win.sys.updated.month", .{ .text = std.mem.sliceTo(&s.updated_month, 0) });
    try add(entries, gpa, "win.sys.updated.day", .{ .text = std.mem.sliceTo(&s.updated_day, 0) });
    try add(entries, gpa, "win.sys.updated.hour", .{ .text = std.mem.sliceTo(&s.updated_hour, 0) });
    try add(entries, gpa, "win.sys.updated.minute", .{ .text = std.mem.sliceTo(&s.updated_minute, 0) });
    try add(entries, gpa, "win.sys.updated.second", .{ .text = std.mem.sliceTo(&s.updated_second, 0) });
}

fn add(entries: *std.ArrayList(client.Entry), gpa: std.mem.Allocator, key: []const u8, value: data.Value) !void {
    try entries.append(gpa, .{ .key = key, .value = value });
}

fn upload(
    http: *std.http.Client,
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    payload: []u8,
    log: *LogBuffer,
) bool {
    client.postBatch(io, gpa, http, cfg.url(), cfg.secret(), payload) catch |err| {
        log.logf("upload failed ({s}); reconnecting and retrying", .{@errorName(err)});
        resetHttpClient(http, io, gpa);
        client.postBatch(io, gpa, http, cfg.url(), cfg.secret(), payload) catch |err2| {
            log.logf("upload failed after reconnect: {s}", .{@errorName(err2)});
            return false;
        };
    };
    return true;
}

fn resetHttpClient(http: *std.http.Client, io: std.Io, gpa: std.mem.Allocator) void {
    http.deinit();
    http.* = .{ .allocator = gpa, .io = io };
}

fn sleepInterruptible(io: std.Io, interval_ms: u64, stop: *std.atomic.Value(bool)) void {
    var remaining = interval_ms;
    while (remaining > 0 and !stop.load(.acquire)) {
        const step: u64 = @min(remaining, 100);
        const ns: i96 = @intCast(step * std.time.ns_per_ms);
        std.Io.sleep(io, .{ .nanoseconds = ns }, .awake) catch return;
        remaining -= step;
    }
}
