//! Optional HTTP/WebSocket control listener.
//!
//! A small REST server so another device can inspect pimon and inject data
//! into a `.layout.zon` screen.  It is off unless a config file enables it:
//!
//! ```ini
//! # ~/.config/pimon.config   (env-file syntax, chmod 600)
//! PIMON_HTTP_ENABLED=1
//! PIMON_HTTP_BIND=0.0.0.0
//! PIMON_HTTP_PORT=8717
//! PIMON_HTTP_SECRET=<long random token>
//! ```
//!
//! Every endpoint except health requires `Authorization: Bearer <token>`,
//! including the WebSocket handshake.  The token is never logged and is
//! compared via SHA-256 digests in constant time.
//!
//! Endpoints:
//!
//! | method | path | meaning |
//! | --- | --- | --- |
//! | GET  | `/api/v1/health` (alias `/healthz`) | liveness + uptime (no token needed) |
//! | GET  | `/api/v1/metrics` | last JSON snapshot published by the UI |
//! | POST | `/api/v1/data`    | `{"key":"cpu.load_pct","value":42}` |
//! | POST | `/api/v1/action`  | `{"action":"reload_layout"}` |
//! | GET  | `/api/v1/ws`      | WebSocket; text frames use the same JSON |
//!
//! `value` may be a number (float binding), a boolean (existing bool binding),
//! or an array of numbers (sparkline series).  Accepted events are queued and
//! drained by the render loop with `poll`, so the HTTP threads never touch DVUI
//! state directly.
//!
//! The listener is deliberately conservative: no CORS headers, a 64 KiB body
//! limit, a bounded client count and an event queue that drops the oldest item
//! when full.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.pimon_net);

const max_body = 64 * 1024;
const max_clients = 16;
const max_events = 64;
const max_series = 512;
const max_key = 128;
const max_secret = 256;
const max_bind = 64;
const max_path = 256;
const default_port: u16 = 8717;

// ---------------------------------------------------------------------------
// Config: env-file parser
// ---------------------------------------------------------------------------

pub const Config = struct {
    enabled: bool = false,
    port: u16 = default_port,
    bind_buf: [max_bind]u8 = @splat(0),
    bind_len: usize = 0,
    secret_buf: [max_secret]u8 = @splat(0),
    secret_len: usize = 0,
    path_buf: [max_path]u8 = @splat(0),
    path_len: usize = 0,

    pub fn bind(self: *const Config) []const u8 {
        if (self.bind_len == 0) return "127.0.0.1";
        return self.bind_buf[0..self.bind_len];
    }

    pub fn secret(self: *const Config) []const u8 {
        return self.secret_buf[0..self.secret_len];
    }

    pub fn path(self: *const Config) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn setBind(self: *Config, value: []const u8) void {
        self.bind_len = copyInto(&self.bind_buf, value);
    }

    fn setSecret(self: *Config, value: []const u8) void {
        self.secret_len = copyInto(&self.secret_buf, value);
    }

    fn setPath(self: *Config, value: []const u8) void {
        self.path_len = copyInto(&self.path_buf, value);
    }
};

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len -| 1, src.len);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
    return n;
}

/// Read `$HOME/.config/pimon.config` (env-file format).  Never fails: a
/// missing file leaves the listener disabled, and a malformed entry is logged
/// and ignored so the dashboard always starts.
pub fn loadConfig(io: Io, gpa: Allocator, home: ?[]const u8) Config {
    var cfg = Config{};
    const h = home orelse {
        log.info("network listener disabled: HOME is not set", .{});
        return cfg;
    };

    var path_buf: [max_path]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/pimon.config", .{h}) catch {
        log.warn("network listener disabled: config path too long", .{});
        return cfg;
    };
    cfg.setPath(path);

    const text = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(64 * 1024),
        .@"1",
        0,
    ) catch |err| {
        switch (err) {
            error.FileNotFound => log.info("network listener disabled: {s} not found", .{path}),
            else => log.warn("network listener disabled: cannot read {s}: {s}", .{ path, @errorName(err) }),
        }
        return cfg;
    };
    defer gpa.free(text);

    cfg = parseConfigText(text) catch |err| {
        log.warn("network listener disabled: {s}: {s}", .{ path, @errorName(err) });
        var off = Config{};
        off.setPath(path);
        return off;
    };
    cfg.setPath(path);

    if (cfg.enabled and cfg.secret_len == 0) {
        log.warn("network listener disabled: PIMON_HTTP_ENABLED=1 but PIMON_HTTP_SECRET is empty", .{});
        cfg.enabled = false;
    }
    if (cfg.enabled and cfg.secret_len < 16) {
        log.warn("network listener: PIMON_HTTP_SECRET is shorter than 16 bytes -- use a long random token", .{});
    }
    if (cfg.enabled) {
        log.info("network listener enabled on {s}:{d}", .{ cfg.bind(), cfg.port });
    }
    return cfg;
}

const ConfigError = error{
    InvalidValue,
    ValueTooLong,
};

/// Parse an env-file (`KEY=VALUE`, `#` comments, optional quotes and an
/// optional `export` prefix).  Unknown keys are ignored for forward
/// compatibility.
pub fn parseConfigText(text: []const u8) ConfigError!Config {
    var cfg = Config{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line[7..], " \t");

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = parseEnvValue(std.mem.trim(u8, line[eq + 1 ..], " \t"));

        if (std.mem.eql(u8, key, "PIMON_HTTP_ENABLED")) {
            cfg.enabled = parseBool(value) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "PIMON_HTTP_PORT")) {
            cfg.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            if (cfg.port == 0) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "PIMON_HTTP_BIND")) {
            if (value.len >= max_bind) return error.ValueTooLong;
            cfg.setBind(value);
        } else if (std.mem.eql(u8, key, "PIMON_HTTP_SECRET") or
            std.mem.eql(u8, key, "PIMON_HTTP_TOKEN"))
        {
            if (value.len >= max_secret) return error.ValueTooLong;
            cfg.setSecret(value);
        }
    }
    return cfg;
}

fn parseEnvValue(raw: []const u8) []const u8 {
    if (raw.len >= 2) {
        const first = raw[0];
        const last = raw[raw.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return raw[1 .. raw.len - 1];
        }
    }
    // Strip an inline comment only when it follows whitespace, so values such
    // as `abc#def` keep the `#`.
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '#' and (i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t')) {
            return std.mem.trimEnd(u8, raw[0..i], " \t");
        }
    }
    return raw;
}

fn parseBool(v: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(v, "1") or
        std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "yes") or
        std.ascii.eqlIgnoreCase(v, "on")) return true;
    if (std.ascii.eqlIgnoreCase(v, "0") or
        std.ascii.eqlIgnoreCase(v, "false") or
        std.ascii.eqlIgnoreCase(v, "no") or
        std.ascii.eqlIgnoreCase(v, "off")) return false;
    return null;
}

/// `pimon --gen-config` result.
pub const ConfigInitResult = enum { created, updated, unchanged };

/// Path of the control config for `home` (`$HOME/.config/pimon.config`).
pub fn configPath(home: ?[]const u8, buf: []u8) error{ HomeNotSet, PathTooLong }![]const u8 {
    const h = home orelse return error.HomeNotSet;
    return std.fmt.bufPrint(buf, "{s}/.config/pimon.config", .{h}) catch error.PathTooLong;
}

/// Create `~/.config/pimon.config`, or upgrade an existing one in place:
///
/// * existing values (including `PIMON_HTTP_ENABLED=0`), comments and unknown
///   keys are preserved;
/// * missing keys are appended with defaults (enabled=1, bind=127.0.0.1,
///   port=8717);
/// * an empty or placeholder secret is replaced with a fresh 32-byte token;
/// * the file is written atomically with mode 0600.
///
/// Running it twice in a row is a no-op (`unchanged`).
pub fn generateConfig(io: Io, gpa: Allocator, home: ?[]const u8) !ConfigInitResult {
    var path_buf: [max_path]u8 = undefined;
    const path = try configPath(home, &path_buf);

    const existing = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(64 * 1024),
        .@"1",
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |text| gpa.free(text);

    var generated_buf: [64]u8 = undefined;
    const generated: []const u8 = if (findExistingSecret(existing) != null) "" else blk: {
        var bytes: [32]u8 = undefined;
        try Io.randomSecure(io, &bytes);
        generated_buf = std.fmt.bytesToHex(bytes, .lower);
        break :blk &generated_buf;
    };

    const content = try renderConfig(gpa, existing, generated);
    defer gpa.free(content);

    const result: ConfigInitResult = if (existing == null)
        .created
    else if (std.mem.eql(u8, existing.?, content))
        .unchanged
    else
        .updated;

    if (result == .unchanged) {
        // A hand-written file may be readable by the group/world; tighten it
        // even when the contents are already up to date.
        const maybe_file: ?std.Io.File = std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
        if (maybe_file) |file| {
            defer file.close(io);
            if (file.stat(io)) |st| {
                if (st.permissions.toMode() & 0o077 != 0) {
                    file.setPermissions(io, .fromMode(0o600)) catch {};
                }
            } else |_| {}
        }
    } else {
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
            .permissions = .fromMode(0o600),
            .make_path = true,
            .replace = existing != null,
        });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, content);
        if (existing != null) {
            try atomic.replace(io);
        } else {
            try atomic.link(io);
        }
    }

    return result;
}

const EnvLine = struct { key: []const u8, value: []const u8 };

fn parseEnvLine(raw: []const u8) ?EnvLine {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#' or line[0] == ';') return null;
    if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line[7..], " \t");
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, line[0..eq], " \t"),
        .value = parseEnvValue(std.mem.trim(u8, line[eq + 1 ..], " \t")),
    };
}

fn isSecretKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "PIMON_HTTP_SECRET") or std.mem.eql(u8, key, "PIMON_HTTP_TOKEN");
}

fn isPlaceholderSecret(value: []const u8) bool {
    if (value.len == 0) return true;
    return std.ascii.startsWithIgnoreCase(value, "replace") or
        std.ascii.startsWithIgnoreCase(value, "change") or
        std.ascii.startsWithIgnoreCase(value, "example") or
        std.ascii.startsWithIgnoreCase(value, "your") or
        value[0] == '<';
}

/// Last non-empty, non-placeholder secret in the file (either key spelling).
fn findExistingSecret(existing: ?[]const u8) ?[]const u8 {
    const text = existing orelse return null;
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const kv = parseEnvLine(raw) orelse continue;
        if (!isSecretKey(kv.key)) continue;
        if (kv.value.len >= max_secret or isPlaceholderSecret(kv.value)) continue;
        found = kv.value;
    }
    return found;
}

const config_header =
    "# pimon control listener (generated by `pimon --gen-config`).\n" ++
    "# Env-file syntax; re-run the command after upgrades to add new keys.\n" ++
    "# The listener stays off unless PIMON_HTTP_ENABLED is truthy.\n" ++
    "# Keep this file private: chmod 600.\n\n";

/// Pure text rendering for `generateConfig` (unit-testable).
fn renderConfig(gpa: Allocator, existing: ?[]const u8, generated_secret: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    var has_enabled = false;
    var has_bind = false;
    var has_port = false;
    var has_secret = false;
    const secret = findExistingSecret(existing) orelse generated_secret;

    if (existing) |text| {
        const body = std.mem.trimEnd(u8, text, "\r\n");
        var lines = std.mem.splitScalar(u8, body, '\n');
        var first = true;
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!first) try w.writeByte('\n');
            first = false;

            if (parseEnvLine(line)) |kv| {
                if (std.mem.eql(u8, kv.key, "PIMON_HTTP_ENABLED")) has_enabled = true;
                if (std.mem.eql(u8, kv.key, "PIMON_HTTP_BIND")) has_bind = true;
                if (std.mem.eql(u8, kv.key, "PIMON_HTTP_PORT")) has_port = true;
                if (isSecretKey(kv.key)) {
                    has_secret = true;
                    // Canonicalise the spelling and replace placeholders.
                    try w.print("PIMON_HTTP_SECRET={s}", .{secret});
                } else {
                    try w.writeAll(line);
                }
            } else {
                try w.writeAll(line);
            }
        }
    } else {
        try w.writeAll(config_header);
        try w.print("PIMON_HTTP_ENABLED=1\nPIMON_HTTP_BIND=127.0.0.1\nPIMON_HTTP_PORT=8717\nPIMON_HTTP_SECRET={s}\n", .{secret});
        has_enabled = true;
        has_bind = true;
        has_port = true;
        has_secret = true;
    }

    var added = false;
    if (!has_enabled) try appendMissing(w, &added, "PIMON_HTTP_ENABLED=1");
    if (!has_bind) try appendMissing(w, &added, "PIMON_HTTP_BIND=127.0.0.1");
    if (!has_port) try appendMissing(w, &added, "PIMON_HTTP_PORT=8717");
    if (!has_secret) {
        // A file with no secret key at all: create one.
        var buf: [80]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "PIMON_HTTP_SECRET={s}", .{secret}) catch unreachable;
        try appendMissing(w, &added, line);
    }

    const written = out.written();
    if (written.len == 0 or written[written.len - 1] != '\n') try w.writeByte('\n');
    return out.toOwnedSlice();
}

fn appendMissing(w: *std.Io.Writer, added: *bool, line: []const u8) !void {
    if (!added.*) {
        try w.writeAll("\n# added by pimon --gen-config\n");
        added.* = true;
    }
    try w.writeAll(line);
    try w.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Events consumed by the render loop
// ---------------------------------------------------------------------------

pub const Event = union(enum) {
    set_float: struct { key: []u8, value: f32 },
    set_bool: struct { key: []u8, value: bool },
    set_series: struct { key: []u8, values: []f32 },
    action: []u8,

    pub fn deinit(self: *Event, gpa: Allocator) void {
        switch (self.*) {
            .set_float => |e| gpa.free(e.key),
            .set_bool => |e| gpa.free(e.key),
            .set_series => |e| {
                gpa.free(e.key);
                gpa.free(e.values);
            },
            .action => |a| gpa.free(a),
        }
        self.* = undefined;
    }
};

/// Parse the JSON accepted by POST /api/v1/data and /api/v1/action, and by
/// WebSocket text frames.
pub fn eventFromJson(gpa: Allocator, body: []const u8) !Event {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidBody,
    };

    if (obj.get("action")) |v| {
        const action = switch (v) {
            .string => |s| s,
            else => return error.InvalidBody,
        };
        if (!validName(action)) return error.InvalidBody;
        return .{ .action = try gpa.dupe(u8, action) };
    }

    const key = switch (obj.get("key") orelse return error.InvalidBody) {
        .string => |s| s,
        else => return error.InvalidBody,
    };
    if (!validName(key)) return error.InvalidBody;

    const value = obj.get("value") orelse return error.InvalidBody;
    switch (value) {
        .float => |f| {
            if (!std.math.isFinite(f)) return error.InvalidBody;
            return .{ .set_float = .{ .key = try gpa.dupe(u8, key), .value = @floatCast(f) } };
        },
        .integer => |i| {
            return .{ .set_float = .{ .key = try gpa.dupe(u8, key), .value = @floatFromInt(i) } };
        },
        .bool => |b| return .{ .set_bool = .{ .key = try gpa.dupe(u8, key), .value = b } },
        .array => |arr| {
            if (arr.items.len > max_series) return error.InvalidBody;
            const values = try gpa.alloc(f32, arr.items.len);
            errdefer gpa.free(values);
            for (arr.items, 0..) |v, i| {
                values[i] = switch (v) {
                    .float => |f| blk: {
                        if (!std.math.isFinite(f)) return error.InvalidBody;
                        break :blk @floatCast(f);
                    },
                    .integer => |n| @floatFromInt(n),
                    else => return error.InvalidBody,
                };
            }
            const owned_key = try gpa.dupe(u8, key);
            return .{ .set_series = .{ .key = owned_key, .values = values } };
        },
        else => return error.InvalidBody,
    }
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_key) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const ClientCtx = struct {
    server: *Server,
    stream: std.Io.net.Stream,
    slot: usize,
};

pub const Server = struct {
    io: Io,
    gpa: Allocator,
    address: std.Io.net.IpAddress,
    secret_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    started: Io.Timestamp,

    stop: std.atomic.Value(bool) = .init(false),
    listen_fd: std.atomic.Value(std.posix.fd_t) = .init(-1),
    active: std.atomic.Value(u32) = .init(0),
    client_fds: [max_clients]std.atomic.Value(std.posix.fd_t) = undefined,
    thread: ?std.Thread = null,

    queue: Queue = .{},
    snapshot_mutex: Io.Mutex = .init,
    snapshot_buf: [8192]u8 = @splat(0),
    snapshot_len: usize = 0,

    pub fn init(io: Io, gpa: Allocator, cfg: *const Config) !Server {
        var self = Server{
            .io = io,
            .gpa = gpa,
            .address = try std.Io.net.IpAddress.parse(cfg.bind(), cfg.port),
            .secret_digest = undefined,
            .started = Io.Clock.awake.now(io),
        };
        for (&self.client_fds) |*fd| fd.* = .init(-1);
        std.crypto.hash.sha2.Sha256.hash(cfg.secret(), &self.secret_digest, .{});
        return self;
    }

    pub fn start(self: *Server) !void {
        if (self.thread != null) return;
        self.stop.store(false, .release);
        self.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, acceptMain, .{self});
    }

    pub fn deinit(self: *Server) void {
        if (self.thread) |t| {
            self.stop.store(true, .release);
            const fd = self.listen_fd.swap(-1, .acquire);
            if (fd >= 0) shutdownFd(self.io, fd);
            // Unblock any WebSocket / idle HTTP client.
            for (&self.client_fds) |*slot| {
                const cfd = slot.swap(-1, .acquire);
                if (cfd >= 0) shutdownFd(self.io, cfd);
            }
            t.join();
            self.thread = null;
            // Give connection threads a moment to notice the shutdown so the
            // queue is not freed underneath them.
            var spins: u32 = 0;
            while (self.active.load(.acquire) > 0 and spins < 200) : (spins += 1) {
                Io.sleep(self.io, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake) catch {};
            }
        }
        // If a wedged client outlived the grace period, leaking the queue is
        // safer than freeing it out from under a thread during process exit.
        if (self.active.load(.acquire) == 0) self.queue.deinit(self.io, self.gpa);
    }

    /// Copy the latest metrics JSON for `GET /api/v1/metrics`.  Called by the
    /// UI thread; safe to call every frame.
    pub fn publishSnapshot(self: *Server, json: []const u8) void {
        if (json.len > self.snapshot_buf.len) {
            log.warn("snapshot too large ({d} bytes); not published", .{json.len});
            return;
        }
        self.snapshot_mutex.lockUncancelable(self.io);
        defer self.snapshot_mutex.unlock(self.io);
        @memcpy(self.snapshot_buf[0..json.len], json);
        self.snapshot_len = json.len;
    }

    /// Take one queued event; the caller owns it (`Event.deinit`).
    pub fn poll(self: *Server) ?Event {
        return self.queue.pop(self.io);
    }

    fn reservedSlot(self: *Server, fd: std.posix.fd_t) ?usize {
        const prev = self.active.fetchAdd(1, .acq_rel);
        if (prev >= max_clients) {
            _ = self.active.fetchSub(1, .acq_rel);
            return null;
        }
        for (&self.client_fds, 0..) |*slot, i| {
            if (slot.cmpxchgStrong(-1, fd, .acquire, .monotonic) == null) return i;
        }
        _ = self.active.fetchSub(1, .acq_rel);
        return null;
    }

    fn releaseSlot(self: *Server, idx: usize) void {
        self.client_fds[idx].store(-1, .release);
        _ = self.active.fetchSub(1, .acq_rel);
    }

    fn authorized(self: *const Server, req: *const std.http.Server.Request) bool {
        var it = req.iterateHeaders();
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
            const value = std.mem.trim(u8, header.value, " \t");
            if (value.len < 7 or !std.ascii.eqlIgnoreCase(value[0..7], "bearer ")) return false;
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(std.mem.trim(u8, value[7..], " \t"), &digest, .{});
            return std.crypto.timing_safe.eql(
                [std.crypto.hash.sha2.Sha256.digest_length]u8,
                digest,
                self.secret_digest,
            );
        }
        return false;
    }
};

const Queue = struct {
    items: std.ArrayList(Event) = .empty,
    mutex: Io.Mutex = .init,

    fn push(self: *Queue, io: Io, gpa: Allocator, ev: Event) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len >= max_events) {
            var dropped = self.items.orderedRemove(0);
            dropped.deinit(gpa);
        }
        self.items.append(gpa, ev) catch {
            var e = ev;
            e.deinit(gpa);
        };
    }

    fn pop(self: *Queue, io: Io) ?Event {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    fn deinit(self: *Queue, io: Io, gpa: Allocator) void {
        self.mutex.lockUncancelable(io);
        for (self.items.items) |*ev| ev.deinit(gpa);
        self.items.deinit(gpa);
        self.mutex.unlock(io);
    }
};

fn acceptMain(self: *Server) void {
    var listener = self.address.listen(self.io, .{
        .reuse_address = true,
        .kernel_backlog = 64,
    }) catch |err| {
        log.err("cannot listen on {f}:{d}: {s}", .{ self.address, self.address.getPort(), @errorName(err) });
        return;
    };
    defer {
        listener.deinit(self.io);
        self.listen_fd.store(-1, .release);
    }
    self.listen_fd.store(listener.socket.handle, .release);
    log.info("listening on {f}", .{self.address});

    while (!self.stop.load(.acquire)) {
        var stream = listener.accept(self.io) catch |err| switch (err) {
            error.Canceled, error.SocketNotListening => return,
            else => {
                log.warn("accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };

        const slot = self.reservedSlot(stream.socket.handle) orelse {
            stream.close(self.io);
            continue;
        };
        const ctx = self.gpa.create(ClientCtx) catch {
            self.releaseSlot(slot);
            stream.close(self.io);
            continue;
        };
        ctx.* = .{ .server = self, .stream = stream, .slot = slot };
        const thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, clientMain, .{ctx}) catch {
            self.gpa.destroy(ctx);
            self.releaseSlot(slot);
            stream.close(self.io);
            continue;
        };
        thread.detach();
    }
}

fn clientMain(ctx: *ClientCtx) void {
    const server = ctx.server;
    defer {
        ctx.stream.close(server.io);
        server.releaseSlot(ctx.slot);
        server.gpa.destroy(ctx);
    }
    handleConnection(server, ctx.stream) catch |err| {
        log.debug("client ended: {s}", .{@errorName(err)});
    };
}

const Outcome = enum { keep, close };

fn handleConnection(server: *Server, stream: std.Io.net.Stream) !void {
    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [8 * 1024]u8 = undefined;
    var reader = stream.reader(server.io, &in_buf);
    var writer = stream.writer(server.io, &out_buf);
    var http = std.http.Server.init(&reader.interface, &writer.interface);

    while (!server.stop.load(.acquire)) {
        var req = http.receiveHead() catch return;
        const outcome = try handleRequest(server, &req);
        writer.interface.flush() catch return error.WriteFailed;
        // A response that had to disable keep-alive (e.g. an unframed POST
        // body) must end the connection here.
        if (outcome == .close or !keepAliveAllowed(&req)) return;
    }
}

fn handleRequest(server: *Server, req: *std.http.Server.Request) !Outcome {
    const target = requestPath(req.head.target);
    const upgrade = req.upgradeRequested();

    // Health is intentionally unauthenticated so a supervisor/other device can
    // check liveness without holding the control token.
    if (upgrade == .none and isHealthPath(target)) {
        if (req.head.method != .GET) return methodNotAllowed(server, req, "GET");
        return health(server, req);
    }

    if (!server.authorized(req)) {
        try respondJson(server, req, .unauthorized, ErrorBody{ .@"error" = "missing or invalid bearer token" }, false, true);
        return .close;
    }

    switch (upgrade) {
        .websocket => |key| {
            if (!std.mem.eql(u8, target, "/api/v1/ws")) return notFound(server, req);
            const k = key orelse {
                try respondJson(server, req, .bad_request, ErrorBody{ .@"error" = "missing sec-websocket-key" }, false, false);
                return .close;
            };
            try serveWebSocket(server, req, k);
            return .close;
        },
        .other => {
            try respondJson(server, req, .bad_request, ErrorBody{ .@"error" = "unsupported upgrade" }, false, false);
            return .close;
        },
        .none => {},
    }

    if (std.mem.eql(u8, target, "/api/v1/metrics")) {
        if (req.head.method != .GET) return methodNotAllowed(server, req, "GET");
        return metrics(server, req);
    }
    if (std.mem.eql(u8, target, "/api/v1/data")) {
        if (req.head.method != .POST) return methodNotAllowed(server, req, "POST");
        return enqueueBody(server, req, false);
    }
    if (std.mem.eql(u8, target, "/api/v1/action")) {
        if (req.head.method != .POST) return methodNotAllowed(server, req, "POST");
        return enqueueBody(server, req, true);
    }

    return notFound(server, req);
}

fn requestPath(target: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..end];
}

fn isHealthPath(target: []const u8) bool {
    return std.mem.eql(u8, target, "/api/v1/health") or std.mem.eql(u8, target, "/healthz");
}

/// POST/PUT/etc. without a content-length or transfer-encoding has no body
/// framing; `std.http.Server.respond` asserts if asked to drain one.
fn requestBodyUnframed(req: *const std.http.Server.Request) bool {
    return req.head.method.requestHasBody() and
        req.head.transfer_encoding == .none and
        req.head.content_length == null;
}

fn keepAliveAllowed(req: *const std.http.Server.Request) bool {
    return req.head.keep_alive and !requestBodyUnframed(req);
}

const ErrorBody = struct { @"error": []const u8 };
const OkBody = struct { ok: bool = true };

fn health(server: *Server, req: *std.http.Server.Request) !Outcome {
    const uptime = server.started.untilNow(server.io, .awake);
    const body = .{
        .ok = true,
        .server = "pimon",
        .uptime_s = @divTrunc(uptime.nanoseconds, std.time.ns_per_s),
        .clients = server.active.load(.acquire),
    };
    try respondJson(server, req, .ok, body, true, false);
    return .keep;
}

fn metrics(server: *Server, req: *std.http.Server.Request) !Outcome {
    var buf: [8192]u8 = undefined;
    server.snapshot_mutex.lockUncancelable(server.io);
    const n = server.snapshot_len;
    @memcpy(buf[0..n], server.snapshot_buf[0..n]);
    server.snapshot_mutex.unlock(server.io);

    if (n == 0) {
        try respondJson(server, req, .service_unavailable, ErrorBody{ .@"error" = "no metrics snapshot yet" }, true, false);
        return .keep;
    }
    try respondRaw(server, req, .ok, buf[0..n], true, false);
    return .keep;
}

fn enqueueBody(server: *Server, req: *std.http.Server.Request, want_action: bool) !Outcome {
    // POST without content-length or transfer-encoding cannot be framed; the
    // std server asserts if asked to drain it, so reject and close cleanly.
    if (requestBodyUnframed(req)) {
        try respondJson(server, req, .bad_request, ErrorBody{ .@"error" = "missing content-length" }, false, false);
        return .close;
    }

    var tmp: [16 * 1024]u8 = undefined;
    const r = req.readerExpectContinue(&tmp) catch {
        try respondJson(server, req, .bad_request, ErrorBody{ .@"error" = "cannot read request body" }, true, false);
        return .keep;
    };
    const body = r.allocRemaining(server.gpa, .limited(max_body)) catch |err| switch (err) {
        error.StreamTooLong => {
            try respondJson(server, req, .payload_too_large, ErrorBody{ .@"error" = "body exceeds 64 KiB" }, true, false);
            return .keep;
        },
        else => {
            try respondJson(server, req, .bad_request, ErrorBody{ .@"error" = "cannot read request body" }, true, false);
            return .keep;
        },
    };
    defer server.gpa.free(body);

    var ev = eventFromJson(server.gpa, body) catch {
        try respondJson(server, req, .bad_request, ErrorBody{ .@"error" = "invalid JSON payload" }, true, false);
        return .keep;
    };

    if (want_action and ev != .action) {
        ev.deinit(server.gpa);
        try respondJson(server, req, .bad_request, ErrorBody{ .@"error" = "expected {\"action\":\"...\"}" }, true, false);
        return .keep;
    }
    if (!want_action and ev == .action) {
        ev.deinit(server.gpa);
        try respondJson(server, req, .bad_request, ErrorBody{ .@"error" = "expected {\"key\":...,\"value\":...}" }, true, false);
        return .keep;
    }

    server.queue.push(server.io, server.gpa, ev);
    try respondJson(server, req, .ok, OkBody{}, true, false);
    return .keep;
}

fn notFound(server: *Server, req: *std.http.Server.Request) !Outcome {
    try respondJson(server, req, .not_found, ErrorBody{ .@"error" = "not found" }, true, false);
    return .keep;
}

fn methodNotAllowed(server: *Server, req: *std.http.Server.Request, allow: []const u8) !Outcome {
    var headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "allow", .value = allow },
    };
    const body = try std.json.Stringify.valueAlloc(server.gpa, ErrorBody{ .@"error" = "method not allowed" }, .{});
    defer server.gpa.free(body);
    try req.respond(body, .{
        .status = .method_not_allowed,
        .keep_alive = keepAliveAllowed(req),
        .extra_headers = &headers,
    });
    return if (keepAliveAllowed(req)) .keep else .close;
}

const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
};
const auth_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "www-authenticate", .value = "Bearer realm=\"pimon\"" },
};

fn respondJson(
    server: *Server,
    req: *std.http.Server.Request,
    status: std.http.Status,
    value: anytype,
    keep_alive: bool,
    with_auth: bool,
) !void {
    const body = try std.json.Stringify.valueAlloc(server.gpa, value, .{});
    defer server.gpa.free(body);
    try respondRaw(server, req, status, body, keep_alive, with_auth);
}

fn respondRaw(
    server: *Server,
    req: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    keep_alive: bool,
    with_auth: bool,
) !void {
    _ = server;
    try req.respond(body, .{
        .status = status,
        .keep_alive = keep_alive and keepAliveAllowed(req),
        .extra_headers = if (with_auth) &auth_headers else &json_headers,
    });
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

fn serveWebSocket(server: *Server, req: *std.http.Server.Request, key: []const u8) !void {
    var ws = req.respondWebSocket(.{ .key = key }) catch |err| {
        log.debug("websocket upgrade failed: {s}", .{@errorName(err)});
        return;
    };
    try ws.writeMessage("{\"ok\":true,\"type\":\"hello\",\"protocol\":1}", .text);

    while (!server.stop.load(.acquire)) {
        const msg = ws.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose => {
                ws.writeMessage("", .connection_close) catch {};
                return;
            },
            error.EndOfStream, error.ReadFailed => return,
            error.MessageOversize => {
                writeWsError(server, &ws, "frame exceeds 16 KiB") catch return;
                return;
            },
            error.MissingMaskBit, error.UnexpectedOpCode => {
                writeWsError(server, &ws, "invalid frame") catch return;
                return;
            },
        };

        switch (msg.opcode) {
            .text => {
                const ev = eventFromJson(server.gpa, msg.data) catch {
                    writeWsError(server, &ws, "invalid JSON payload") catch return;
                    continue;
                };
                server.queue.push(server.io, server.gpa, ev);
                ws.writeMessage("{\"ok\":true,\"queued\":true}", .text) catch return;
            },
            .ping => ws.writeMessage(msg.data, .pong) catch return,
            .binary => writeWsError(server, &ws, "binary frames are not supported") catch return,
            else => writeWsError(server, &ws, "unsupported opcode") catch return,
        }
    }
}

fn writeWsError(server: *Server, ws: *std.http.Server.WebSocket, msg: []const u8) !void {
    const body = try std.json.Stringify.valueAlloc(server.gpa, ErrorBody{ .@"error" = msg }, .{});
    defer server.gpa.free(body);
    try ws.writeMessage(body, .text);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn shutdownFd(io: Io, fd: std.Io.net.Socket.Handle) void {
    io.vtable.netShutdown(io.userdata, fd, .both) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "env config: comments, quotes, export and aliases" {
    const cfg = try parseConfigText(
        \\# pimon
        \\export PIMON_HTTP_ENABLED = on
        \\PIMON_HTTP_BIND="0.0.0.0"
        \\PIMON_HTTP_PORT=9000
        \\PIMON_HTTP_TOKEN='s3cret-token-value'
        \\UNKNOWN=ignored
        \\
    );
    try std.testing.expect(cfg.enabled);
    try std.testing.expectEqual(@as(u16, 9000), cfg.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.bind());
    try std.testing.expectEqualStrings("s3cret-token-value", cfg.secret());
}

test "env config: inline comments and defaults" {
    const cfg = try parseConfigText("PIMON_HTTP_ENABLED=0 # off\nPIMON_HTTP_SECRET=a#b\n");
    try std.testing.expect(!cfg.enabled);
    try std.testing.expectEqual(@as(u16, default_port), cfg.port);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.bind());
    try std.testing.expectEqualStrings("a#b", cfg.secret());
}

test "env config: invalid values are rejected" {
    try std.testing.expectError(error.InvalidValue, parseConfigText("PIMON_HTTP_ENABLED=maybe\n"));
    try std.testing.expectError(error.InvalidValue, parseConfigText("PIMON_HTTP_PORT=0\n"));
    try std.testing.expectError(error.InvalidValue, parseConfigText("PIMON_HTTP_PORT=nope\n"));
}

test "renderConfig creates a complete config and is idempotent" {
    const gpa = std.testing.allocator;
    const fresh = try renderConfig(gpa, null, "deadbeef");
    defer gpa.free(fresh);

    try std.testing.expect(std.mem.startsWith(u8, fresh, "# pimon control listener"));
    try std.testing.expect(std.mem.indexOf(u8, fresh, "PIMON_HTTP_ENABLED=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "PIMON_HTTP_BIND=127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "PIMON_HTTP_PORT=8717") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "PIMON_HTTP_SECRET=deadbeef") != null);

    const again = try renderConfig(gpa, fresh, "");
    defer gpa.free(again);
    try std.testing.expectEqualStrings(fresh, again);
}

test "renderConfig upgrades in place and preserves user values" {
    const gpa = std.testing.allocator;
    const existing =
        \\# my settings
        \\PIMON_HTTP_ENABLED=0
        \\PIMON_HTTP_BIND=0.0.0.0
        \\PIMON_HTTP_TOKEN=replace-me
        \\CUSTOM=keep
        \\
    ;
    const out = try renderConfig(gpa, existing, "0123456789abcdef");
    defer gpa.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "# my settings") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PIMON_HTTP_ENABLED=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PIMON_HTTP_BIND=0.0.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "CUSTOM=keep") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PIMON_HTTP_PORT=8717") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PIMON_HTTP_SECRET=0123456789abcdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PIMON_HTTP_TOKEN") == null);

    // A real secret is kept, and the next run is a no-op.
    const real = try renderConfig(gpa, "# c\nPIMON_HTTP_SECRET=keep-this-secret\n", "ignored");
    defer gpa.free(real);
    try std.testing.expect(std.mem.indexOf(u8, real, "PIMON_HTTP_SECRET=keep-this-secret") != null);
    try std.testing.expect(findExistingSecret(real) != null);
}

test "findExistingSecret ignores placeholders and accepts the token alias" {
    try std.testing.expect(findExistingSecret("# x\nPIMON_HTTP_ENABLED=1\n") == null);
    try std.testing.expect(findExistingSecret("PIMON_HTTP_SECRET=replace-me\n") == null);
    try std.testing.expectEqualStrings(
        "real-token",
        findExistingSecret("PIMON_HTTP_TOKEN='real-token'\n").?,
    );
}

test "eventFromJson: scalar, series, bool and action" {
    const gpa = std.testing.allocator;

    var f = try eventFromJson(gpa, "{\"key\":\"cpu.load_pct\",\"value\":42.5}");
    defer f.deinit(gpa);
    try std.testing.expectEqualStrings("cpu.load_pct", f.set_float.key);
    try std.testing.expectEqual(@as(f32, 42.5), f.set_float.value);

    var s = try eventFromJson(gpa, "{\"key\":\"demo.series\",\"value\":[1,2.5,3]}");
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), s.set_series.values.len);
    try std.testing.expectEqual(@as(f32, 2.5), s.set_series.values[1]);

    var b = try eventFromJson(gpa, "{\"key\":\"demo.flag\",\"value\":true}");
    defer b.deinit(gpa);
    try std.testing.expect(b.set_bool.value);

    var a = try eventFromJson(gpa, "{\"action\":\"reload_layout\"}");
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("reload_layout", a.action);
}

test "eventFromJson: rejects malformed input" {
    const gpa = std.testing.allocator;
    const bad = [_][]const u8{
        "{}",
        "[]",
        "{\"key\":\"has space\",\"value\":1}",
        "{\"key\":\"k\",\"value\":\"text\"}",
        "{\"key\":\"k\",\"value\":1e999}",
        "{\"key\":\"k\",\"value\":[1,\"x\"]}",
        "{\"action\":\"bad action\"}",
    };
    for (bad) |body| {
        try std.testing.expectError(error.InvalidBody, eventFromJson(gpa, body));
    }
}

test "health paths are recognised" {
    try std.testing.expect(isHealthPath("/api/v1/health"));
    try std.testing.expect(isHealthPath("/healthz"));
    try std.testing.expect(!isHealthPath("/api/v1/metrics"));
    try std.testing.expect(!isHealthPath("/api/v1/health/extra"));
}

test "bearer digest comparison" {
    const secret = "correct horse battery staple";
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &expected, .{});

    var same: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &same, .{});
    try std.testing.expect(std.crypto.timing_safe.eql([32]u8, expected, same));

    var other: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("wrong", &other, .{});
    try std.testing.expect(!std.crypto.timing_safe.eql([32]u8, expected, other));
}
