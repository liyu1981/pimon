//! Colours used by the custom widgets, plus a tiny colour parser so a
//! `.layout.zon` file can name a colour or spell one out in hex.

const std = @import("std");
const dvui = @import("dvui");

pub const track: dvui.Color = .{ .r = 0x3a, .g = 0x3a, .b = 0x3a, .a = 0xff };
pub const green: dvui.Color = .{ .r = 0x2f, .g = 0xe0, .b = 0x2f, .a = 0xff };
pub const lime: dvui.Color = .{ .r = 0x60, .g = 0xff, .b = 0x40, .a = 0xff };
pub const yellow: dvui.Color = .{ .r = 0xff, .g = 0xd0, .b = 0x00, .a = 0xff };
pub const orange: dvui.Color = .{ .r = 0xff, .g = 0x90, .b = 0x20, .a = 0xff };
pub const red: dvui.Color = .{ .r = 0xff, .g = 0x38, .b = 0x38, .a = 0xff };
pub const cyan: dvui.Color = .{ .r = 0x30, .g = 0xd8, .b = 0xf0, .a = 0xff };
pub const blue: dvui.Color = .{ .r = 0x40, .g = 0x90, .b = 0xff, .a = 0xff };
pub const white: dvui.Color = .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff };
pub const gray: dvui.Color = .{ .r = 0x90, .g = 0x90, .b = 0x90, .a = 0xff };

/// A name (`green`, `lime`, `red`, `yellow`, `orange`, `cyan`, `blue`, `white`,
/// `gray`/`grey`) or hex `rrggbb` / `aarrggbb`.
pub fn parse(s: ?[]const u8) ?dvui.Color {
    const str = s orelse return null;

    const named: ?dvui.Color = blk: {
        if (std.mem.eql(u8, str, "green")) break :blk green;
        if (std.mem.eql(u8, str, "lime")) break :blk lime;
        if (std.mem.eql(u8, str, "red")) break :blk red;
        if (std.mem.eql(u8, str, "yellow")) break :blk yellow;
        if (std.mem.eql(u8, str, "orange")) break :blk orange;
        if (std.mem.eql(u8, str, "cyan")) break :blk cyan;
        if (std.mem.eql(u8, str, "blue")) break :blk blue;
        if (std.mem.eql(u8, str, "white")) break :blk white;
        if (std.mem.eql(u8, str, "gray") or std.mem.eql(u8, str, "grey")) break :blk gray;
        break :blk null;
    };
    return named orelse parseHex(str);
}

fn nibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// `rrggbb` or `aarrggbb`.
fn parseHex(str: []const u8) ?dvui.Color {
    var a: u32 = 0xff;
    var rgb_str: []const u8 = undefined;
    if (str.len == 6) {
        rgb_str = str;
    } else if (str.len == 8) {
        a = 0;
        for (str[0..2]) |c| {
            a = (a << 4) | (nibble(c) orelse return null);
        }
        rgb_str = str[2..];
    } else {
        return null;
    }

    var rgb: u32 = 0;
    for (rgb_str) |c| {
        rgb = (rgb << 4) | (nibble(c) orelse return null);
    }
    return .{
        .r = @intCast((rgb >> 16) & 0xff),
        .g = @intCast((rgb >> 8) & 0xff),
        .b = @intCast(rgb & 0xff),
        .a = @intCast(a),
    };
}

test "parse names and hex" {
    try std.testing.expectEqual(green, parse("green").?);
    try std.testing.expectEqual(cyan, parse("cyan").?);
    try std.testing.expectEqual(gray, parse("grey").?);

    const hex = parse("ff8000").?;
    try std.testing.expectEqual(@as(u8, 0xff), hex.r);
    try std.testing.expectEqual(@as(u8, 0x80), hex.g);
    try std.testing.expectEqual(@as(u8, 0x00), hex.b);
    try std.testing.expectEqual(@as(u8, 0xff), hex.a);

    const argb = parse("80ff8000").?;
    try std.testing.expectEqual(@as(u8, 0x80), argb.a);
    try std.testing.expectEqual(@as(u8, 0xff), argb.r);

    try std.testing.expect(parse("not-a-color") == null);
    try std.testing.expect(parse(null) == null);
    try std.testing.expect(parse("fff") == null);
}
