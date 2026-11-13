//! Universal typed data values shared by the local `/proc` sampler, the
//! network listener and the `.layout.zon` bindings.
//!
//! A layout declares the kind it expects for a key (`bind_type`); both local
//! and remote publications go through `Bindings.publish` / `publishOwned`,
//! which drop values whose active kind does not match the declaration.

const std = @import("std");

pub const Kind = enum {
    float,
    series,
    text,
    boolean,
};

pub const Value = union(Kind) {
    float: f32,
    series: []const f32,
    text: []const u8,
    boolean: bool,
};

/// Active kind of a `Value` (`std.meta.activeTag` with a narrower type).
pub fn kindOf(value: Value) Kind {
    return std.meta.activeTag(value);
}

/// A byte-per-second rate rescaled to a human-readable unit.
pub const Rate = struct {
    value: f32,
    unit: []const u8,
};

/// Pick B/s, KiB/s, MiB/s or GiB/s for `bytes_per_sec` and rescale it.
/// Negative values clamp to zero so a counter glitch never shows a negative
/// throughput.
pub fn scaleRate(bytes_per_sec: f32) Rate {
    const v = if (bytes_per_sec > 0) bytes_per_sec else 0;
    const kib = 1024.0;
    const mib = kib * 1024.0;
    const gib = mib * 1024.0;
    if (v < kib) return .{ .value = v, .unit = "B/s" };
    if (v < mib) return .{ .value = v / kib, .unit = "KiB/s" };
    if (v < gib) return .{ .value = v / mib, .unit = "MiB/s" };
    return .{ .value = v / gib, .unit = "GiB/s" };
}

/// Format just the numeric part of a rate, matching `formatRate`'s unit
/// choice.  Useful when the UI draws the value and unit separately.
pub fn formatRateValue(buf: []u8, bytes_per_sec: f32) []const u8 {
    const rate = scaleRate(bytes_per_sec);
    if (std.mem.eql(u8, rate.unit, "B/s")) {
        return std.fmt.bufPrint(buf, "{d:.0}", .{rate.value}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.1}", .{rate.value}) catch "?";
}

/// Format a byte-per-second rate with an automatic unit, e.g. `"512 B/s"`,
/// `"3.4 KiB/s"` or `"1.2 MiB/s"`.  The result points into `buf`.
pub fn formatRate(buf: []u8, bytes_per_sec: f32) []const u8 {
    const rate = scaleRate(bytes_per_sec);
    var num_buf: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ formatRateValue(&num_buf, bytes_per_sec), rate.unit }) catch "?";
}

test "value kinds" {
    try std.testing.expectEqual(Kind.float, kindOf(.{ .float = 1.5 }));
    try std.testing.expectEqual(Kind.series, kindOf(.{ .series = &.{ 1, 2 } }));
    try std.testing.expectEqual(Kind.text, kindOf(.{ .text = "x" }));
    try std.testing.expectEqual(Kind.boolean, kindOf(.{ .boolean = true }));
}

test "rate formatting adapts units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B/s", formatRate(&buf, 0));
    try std.testing.expectEqualStrings("512 B/s", formatRate(&buf, 512));
    try std.testing.expectEqualStrings("1.0 KiB/s", formatRate(&buf, 1024));
    try std.testing.expectEqualStrings("1.5 KiB/s", formatRate(&buf, 1536));
    try std.testing.expectEqualStrings("2.0 MiB/s", formatRate(&buf, 2.0 * 1024 * 1024));
    try std.testing.expectEqualStrings("1.5 GiB/s", formatRate(&buf, 1.5 * 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("0 B/s", formatRate(&buf, -1));
    try std.testing.expectEqualStrings("1.5", formatRateValue(&buf, 1536));
    try std.testing.expectEqualStrings("512", formatRateValue(&buf, 512));
}
