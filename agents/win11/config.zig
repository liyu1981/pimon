//! Env-file config for the Win11 agent.
//!
//! Default path: `%APPDATA%\pimon\agent.config`
//! ```
//! PIMON_URL=http://192.168.1.50:8717
//! PIMON_HTTP_SECRET=<pimon bearer token>
//! PIMON_INTERVAL_MS=1000
//! PIMON_AGENT_NAME=win11
//! PIMON_ENABLE_GPU=1
//! ```

const std = @import("std");

pub const max_url = 512;
pub const max_secret = 256;
pub const max_name = 64;
pub const max_path = 512;

pub const Config = struct {
    url_buf: [max_url]u8 = @splat(0),
    url_len: usize = 0,
    secret_buf: [max_secret]u8 = @splat(0),
    secret_len: usize = 0,
    agent_buf: [max_name]u8 = @splat(0),
    agent_len: usize = 0,
    path_buf: [max_path]u8 = @splat(0),
    path_len: usize = 0,
    interval_ms: u64 = 1000,
    enable_gpu: bool = true,

    pub fn url(self: *const Config) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    pub fn secret(self: *const Config) []const u8 {
        return self.secret_buf[0..self.secret_len];
    }

    pub fn agentName(self: *const Config) []const u8 {
        if (self.agent_len == 0) return "win11";
        return self.agent_buf[0..self.agent_len];
    }

    pub fn path(self: *const Config) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn setUrl(self: *Config, value: []const u8) void {
        self.url_len = copyInto(&self.url_buf, value);
    }

    pub fn setSecret(self: *Config, value: []const u8) void {
        self.secret_len = copyInto(&self.secret_buf, value);
    }

    pub fn setAgentName(self: *Config, value: []const u8) void {
        self.agent_len = copyInto(&self.agent_buf, value);
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

/// Default template written by `install-config`.
pub const template =
    \\# pimon Win11 agent configuration.
    \\# Fill in the pimon server URL and bearer token, then save and close Notepad.
    \\# URL examples: http://192.168.1.50:8717 or http://127.0.0.1:8717 (SSH tunnel)
    \\PIMON_URL=
    \\PIMON_HTTP_SECRET=
    \\PIMON_INTERVAL_MS=1000
    \\PIMON_AGENT_NAME=win11
    \\PIMON_ENABLE_GPU=1
    \\
;

pub const InstallResult = enum { created, exists };

/// Resolve the config path for the current user (or `--config` override).
pub fn resolvePath(
    environ: *const std.process.Environ.Map,
    override_path: ?[]const u8,
    buf: []u8,
) error{ HomeNotSet, PathTooLong }![]const u8 {
    if (override_path) |p| {
        return if (p.len < buf.len) p else error.PathTooLong;
    }
    const appdata = environ.get("APPDATA") orelse environ.get("USERPROFILE") orelse return error.HomeNotSet;
    return std.fmt.bufPrint(buf, "{s}\\pimon\\agent.config", .{appdata}) catch error.PathTooLong;
}

/// Read the raw config text for the UI editor.  Returns null when missing.
pub fn readRaw(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    const text = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(64 * 1024),
        .@"1",
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return text;
}

/// Save text to the config path, creating parent directories as needed.
pub fn saveText(io: std.Io, path: []const u8, text: []const u8) !void {
    const existed = openFileExists(io, path);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .default_file,
        .make_path = true,
        .replace = existed,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, text);
    if (existed) {
        try atomic.replace(io);
    } else {
        try atomic.link(io);
    }
}

/// Create the config file with the template if it does not exist.  Never
/// overwrites an existing file.
pub fn installTemplate(io: std.Io, path: []const u8) !InstallResult {
    if (openFileExists(io, path)) return .exists;

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .default_file,
        .make_path = true,
        .replace = false,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, template);
    try atomic.link(io);
    return .created;
}

fn openFileExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Load the config from `%APPDATA%\pimon\agent.config`.  Missing files and
/// malformed values leave defaults / disable optional features; `main` reports
/// a missing URL or secret.
pub fn load(io: std.Io, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, override_path: ?[]const u8) Config {
    var cfg = Config{};
    var path_buf: [max_path]u8 = undefined;
    const path = if (override_path) |p|
        p
    else blk: {
        const appdata = environ.get("APPDATA") orelse environ.get("USERPROFILE") orelse return cfg;
        break :blk std.fmt.bufPrint(&path_buf, "{s}\\pimon\\agent.config", .{appdata}) catch return cfg;
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
            error.FileNotFound => std.log.info("agent: {s} not found; using defaults", .{path}),
            else => std.log.warn("agent: cannot read {s}: {s}", .{ path, @errorName(err) }),
        }
        return cfg;
    };
    defer gpa.free(text);

    if (parseText(text, &cfg)) |_| {} else |err| {
        std.log.warn("agent: invalid config {s}: {s}", .{ path, @errorName(err) });
    }
    return cfg;
}

pub const ParseError = error{ InvalidValue, ValueTooLong };

pub fn parseText(text: []const u8, cfg: *Config) ParseError!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line[7..], " \t");

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = parseValue(std.mem.trim(u8, line[eq + 1 ..], " \t"));

        if (std.mem.eql(u8, key, "PIMON_URL")) {
            if (value.len >= max_url) return error.ValueTooLong;
            cfg.setUrl(value);
        } else if (std.mem.eql(u8, key, "PIMON_HTTP_SECRET") or std.mem.eql(u8, key, "PIMON_HTTP_TOKEN")) {
            if (value.len >= max_secret) return error.ValueTooLong;
            cfg.setSecret(value);
        } else if (std.mem.eql(u8, key, "PIMON_AGENT_NAME")) {
            if (value.len >= max_name) return error.ValueTooLong;
            cfg.setAgentName(value);
        } else if (std.mem.eql(u8, key, "PIMON_INTERVAL_MS")) {
            cfg.interval_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidValue;
            if (cfg.interval_ms < 100) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "PIMON_ENABLE_GPU")) {
            cfg.enable_gpu = parseBool(value) orelse return error.InvalidValue;
        }
    }
}

fn parseValue(raw: []const u8) []const u8 {
    if (raw.len >= 2) {
        const first = raw[0];
        const last = raw[raw.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return raw[1 .. raw.len - 1];
        }
    }
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '#' and (i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t')) {
            return std.mem.trimEnd(u8, raw[0..i], " \t");
        }
    }
    return raw;
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on")) return true;
    if (std.ascii.eqlIgnoreCase(value, "0") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "off")) return false;
    return null;
}

test "config parser" {
    var cfg = Config{};
    try parseText(
        \\# agent
        \\export PIMON_URL = "http://192.168.1.50:8717"
        \\PIMON_HTTP_SECRET='token value'
        \\PIMON_INTERVAL_MS=2000
        \\PIMON_AGENT_NAME=win11-test
        \\PIMON_ENABLE_GPU=0
        \\
    , &cfg);
    try std.testing.expectEqualStrings("http://192.168.1.50:8717", cfg.url());
    try std.testing.expectEqualStrings("token value", cfg.secret());
    try std.testing.expectEqualStrings("win11-test", cfg.agentName());
    try std.testing.expectEqual(@as(u64, 2000), cfg.interval_ms);
    try std.testing.expect(!cfg.enable_gpu);
}

test "install template contains every key" {
    try std.testing.expect(std.mem.indexOf(u8, template, "PIMON_URL=") != null);
    try std.testing.expect(std.mem.indexOf(u8, template, "PIMON_HTTP_SECRET=") != null);
    try std.testing.expect(std.mem.indexOf(u8, template, "PIMON_INTERVAL_MS=1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, template, "PIMON_AGENT_NAME=win11") != null);
    try std.testing.expect(std.mem.indexOf(u8, template, "PIMON_ENABLE_GPU=1") != null);
}

test "config parser rejects bad values" {
    var cfg = Config{};
    try std.testing.expectError(error.InvalidValue, parseText("PIMON_INTERVAL_MS=10\n", &cfg));
    try std.testing.expectError(error.InvalidValue, parseText("PIMON_ENABLE_GPU=maybe\n", &cfg));
}
