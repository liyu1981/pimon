//! Canvas-style `arc()` for DVUI.
//!
//! A port of an HTML5 Canvas `ctx.arc()` re-implementation.  Two adaptations
//! were needed for DVUI 0.6:
//!
//! * The original stroked every segment with `WindowContext.line(...)`.  That
//!   type/method does not exist in DVUI 0.6 (drawing goes through
//!   `Path.Builder` + `Path.stroke`), so the points are collected and stroked
//!   once — fewer draw calls and no seams between segments.
//! * The original wrapped a negative sweep with
//!   `tau + @mod(diff, tau)`, which adds a full turn on top of an already
//!   wrapped value (`diff = -1` became `11.56` instead of `5.28`).  Here the
//!   sweep is normalised to a single turn, matching Canvas.
//!
//! Angles are radians in screen space: `0` is +x, increasing is clockwise
//! (y grows downward).

const std = @import("std");
const dvui = @import("dvui");

pub const tau: f32 = 2.0 * std.math.pi;

pub fn rad(deg: f32) f32 {
    return deg * std.math.pi / 180.0;
}

/// Append the points of a Canvas-style arc to `builder`.
pub fn addArcPoints(
    builder: *dvui.Path.Builder,
    center_x: f32,
    center_y: f32,
    radius: f32,
    start_angle: f32,
    end_angle: f32,
    anticlockwise: bool,
) void {
    if (radius <= 0) return;

    var diff = end_angle - start_angle;
    if (!anticlockwise and diff < 0) {
        diff += tau;
    } else if (anticlockwise and diff > 0) {
        diff -= tau;
    }
    if (diff == 0) return;

    // About one segment per two physical pixels of arc: smooth at any radius,
    // and the cost grows with both the radius and the sweep.
    const wanted = @abs(diff) * radius / 2.0;
    const segment_count: usize = @intFromFloat(std.math.clamp(@ceil(wanted), 12.0, 2048.0));

    builder.addPoint(.{ .x = center_x + @cos(start_angle) * radius, .y = center_y + @sin(start_angle) * radius });
    var i: usize = 1;
    while (i <= segment_count) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segment_count));
        const a = start_angle + diff * t;
        builder.addPoint(.{ .x = center_x + @cos(a) * radius, .y = center_y + @sin(a) * radius });
    }
}

/// Stroke a Canvas-style arc with square end caps (the only caps DVUI strokes
/// provide — use `arcWithCaps` for round ends).
pub fn arc(
    center_x: f32,
    center_y: f32,
    radius: f32,
    start_angle: f32,
    end_angle: f32,
    anticlockwise: bool,
    thickness: f32,
    color: dvui.Color,
) void {
    var b: dvui.Path.Builder = .init(dvui.currentWindow().arena());
    addArcPoints(&b, center_x, center_y, radius, start_angle, end_angle, anticlockwise);
    if (b.points.items.len < 2) return;
    b.build().stroke(.{ .thickness = thickness, .color = .{ .color = color }, .endcap_style = .square });
}

/// Stroke a Canvas-style arc and round off both ends with a filled disc, which
/// is what makes thick progress arcs look finished.
pub fn arcWithCaps(
    center_x: f32,
    center_y: f32,
    radius: f32,
    start_angle: f32,
    end_angle: f32,
    thickness: f32,
    color: dvui.Color,
) void {
    var diff = end_angle - start_angle;
    if (diff < 0) diff += tau;

    arc(center_x, center_y, radius, start_angle, end_angle, false, thickness, color);

    const half = thickness * 0.5;
    disc(center_x + @cos(start_angle) * radius, center_y + @sin(start_angle) * radius, half, color);
    const end_angle_actual = start_angle + diff;
    disc(center_x + @cos(end_angle_actual) * radius, center_y + @sin(end_angle_actual) * radius, half, color);
}

/// Filled circle (a convex path), used for arc end caps and dots.
pub fn disc(center_x: f32, center_y: f32, radius: f32, color: dvui.Color) void {
    if (radius <= 0) return;
    var b: dvui.Path.Builder = .init(dvui.currentWindow().arena());
    const n: usize = 18;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, n) * tau;
        b.addPoint(.{ .x = center_x + @cos(a) * radius, .y = center_y + @sin(a) * radius });
    }
    b.build().fillConvex(.{ .color = .{ .color = color } });
}
