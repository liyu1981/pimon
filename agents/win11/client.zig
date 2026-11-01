//! JSON payload builder and HTTP batch sender for the pimon protocol.

const std = @import("std");
const data = @import("data");

pub const Entry = struct {
    key: []const u8,
    value: data.Value,
};

pub const PostError = error{
    InvalidUrl,
    HttpStatus,
    OutOfMemory,
};

/// Build the batch accepted by `POST /api/v1/data`:
///
/// ```json
/// {"agent":"win11","ts":1762000000123,"values":{"win.cpu.util_pct":23.4}}
/// ```
pub fn buildPayload(
    gpa: std.mem.Allocator,
    agent_name: []const u8,
    ts_ms: i64,
    entries: []const Entry,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer };

    try js.beginObject();
    try js.objectField("agent");
    try js.write(agent_name);
    try js.objectField("ts");
    try js.write(ts_ms);
    try js.objectField("values");
    try js.beginObject();
    for (entries) |entry| {
        try js.objectField(entry.key);
        switch (entry.value) {
            .float => |v| try js.write(v),
            .series => |v| try js.write(v),
            .text => |v| try js.write(v),
            .boolean => |v| try js.write(v),
        }
    }
    try js.endObject();
    try js.endObject();
    return aw.toOwnedSlice();
}

/// POST one batch to pimon.  The client is kept alive by the caller so the
/// connection pool can be reused between samples.
pub fn postBatch(
    io: std.Io,
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    base_url: []const u8,
    secret: []const u8,
    payload: []u8,
) PostError!void {
    const endpoint = endpointAlloc(gpa, base_url) catch return error.OutOfMemory;
    defer gpa.free(endpoint);

    const uri = std.Uri.parse(endpoint) catch return error.InvalidUrl;

    var auth_buf: [512]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{secret}) catch return error.InvalidUrl;

    var headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth },
        .{ .name = "content-type", .value = "application/json" },
    };

    var req = client.request(.POST, uri, .{
        .extra_headers = &headers,
        .keep_alive = true,
    }) catch return error.HttpStatus;
    defer req.deinit();

    req.sendBodyComplete(payload) catch return error.HttpStatus;

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.HttpStatus;

    var read_buf: [4096]u8 = undefined;
    const body = response.reader(&read_buf).allocRemaining(gpa, .limited(64 * 1024)) catch &.{};
    defer if (body.len > 0) gpa.free(body);

    if (response.head.status.class() != .success) {
        std.log.err("agent: pimon returned {d}: {s}", .{
            @backingInt(response.head.status),
            if (body.len > 0) body else "(empty body)",
        });
        return error.HttpStatus;
    }
    _ = io;
}

fn endpointAlloc(gpa: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(gpa, "{s}/api/v1/data", .{base});
}

test "payload shape and kinds" {
    const gpa = std.testing.allocator;
    const history = [_]f32{ 1, 2, 3 };
    const entries = [_]Entry{
        .{ .key = "win.cpu.util_pct", .value = .{ .float = 12.5 } },
        .{ .key = "win.cpu.util_hist", .value = .{ .series = &history } },
        .{ .key = "win.sys.host", .value = .{ .text = "desk" } },
        .{ .key = "win.online", .value = .{ .boolean = true } },
    };
    const json = try buildPayload(gpa, "win11", 1234, &entries);
    defer gpa.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"agent\":\"win11\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"win.cpu.util_pct\":12.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"win.cpu.util_hist\":[1,2,3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"win.sys.host\":\"desk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"win.online\":true") != null);
}

test "endpoint trims trailing slash" {
    const gpa = std.testing.allocator;
    const e = try endpointAlloc(gpa, "http://pi:8717/");
    defer gpa.free(e);
    try std.testing.expectEqualStrings("http://pi:8717/api/v1/data", e);
}
