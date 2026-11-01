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

test "value kinds" {
    try std.testing.expectEqual(Kind.float, kindOf(.{ .float = 1.5 }));
    try std.testing.expectEqual(Kind.series, kindOf(.{ .series = &.{ 1, 2 } }));
    try std.testing.expectEqual(Kind.text, kindOf(.{ .text = "x" }));
    try std.testing.expectEqual(Kind.boolean, kindOf(.{ .boolean = true }));
}
