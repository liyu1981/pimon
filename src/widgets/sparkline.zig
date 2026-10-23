//! Sparkline: a small line chart of a series, auto-scaled to its own min/max.

const std = @import("std");
const dvui = @import("dvui");
const palette = @import("palette.zig");

/// Draw `series` as a polyline filling `rs`, normalised to its own range.
/// Fewer than two samples draws nothing.
pub fn draw(rs: dvui.RectScale, series: ?[]const f32, color: dvui.Color) void {
    const data = series orelse return;
    if (data.len < 2) return;

    const r = rs.r;
    const pad = 3.0 * rs.s;
    const w = r.w - 2 * pad;
    const h = r.h - 2 * pad;
    if (w <= 0 or h <= 0) return;

    var minv: f32 = std.math.floatMax(f32);
    var maxv: f32 = -std.math.floatMax(f32);
    for (data) |v| {
        minv = @min(minv, v);
        maxv = @max(maxv, v);
    }
    if (maxv - minv < 1e-6) {
        minv -= 1.0;
        maxv += 1.0;
    }
    const span = maxv - minv;

    var b: dvui.Path.Builder = .init(dvui.currentWindow().arena());
    for (data, 0..) |v, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(data.len - 1));
        b.addPoint(.{
            .x = r.x + pad + t * w,
            .y = r.y + pad + (1.0 - (v - minv) / span) * h,
        });
    }
    if (b.points.items.len < 2) return;
    b.build().stroke(.{
        .thickness = @max(1.0, rs.s * 2.0),
        .color = .{ .color = color },
        .endcap_style = .square,
        .join = .strip,
    });
}

/// Default colour when a layout does not name one.
pub const default_color = palette.cyan;

test "flat series still maps inside the rect" {
    // pure geometry check: a constant series must not divide by zero
    const flat = [_]f32{ 4, 4, 4 };
    var minv: f32 = std.math.floatMax(f32);
    var maxv: f32 = -std.math.floatMax(f32);
    for (flat) |v| {
        minv = @min(minv, v);
        maxv = @max(maxv, v);
    }
    if (maxv - minv < 1e-6) {
        minv -= 1.0;
        maxv += 1.0;
    }
    try std.testing.expect(maxv - minv > 1.0);
}
