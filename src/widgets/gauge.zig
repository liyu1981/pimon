//! Radial gauge: a background arc with a coloured value arc laid on top.
//!
//! Both arcs are drawn with the Canvas-style `arc.zig`, which gives them round
//! ends.  The value arc changes colour past `yellow_at` / `red_at` of the full
//! scale.  Optional warning/danger bands can be drawn behind it with
//! `show_thresholds`, but they are off unless a layout asks for them.
//!
//! This module only draws into a `RectScale` it is handed; putting a value and
//! unit inside the ring with DVUI labels is left to the caller (`layout.zig`).

const std = @import("std");
const dvui = @import("dvui");
const arc = @import("arc.zig");
const palette = @import("palette.zig");

pub const Options = struct {
    value: f32 = 0,
    max: f32 = 100,
    /// Colour of the value arc while it is below both thresholds.
    accent: dvui.Color = palette.green,
    /// Sweep in degrees. 270 leaves a 90° gap at the bottom, like a dial.
    sweep_deg: f32 = 270.0,
    /// Fraction of `max` where the value arc turns yellow / red.
    yellow_at: f32 = 0.78,
    red_at: f32 = 0.90,
    /// Draw the yellow/red warning bands at the end of the sweep.  Off by
    /// default; dashboards that want traffic-light zones opt in per gauge.
    show_thresholds: bool = false,
    /// Ring thickness; `null` derives it from the scale factor.
    thickness: ?f32 = null,
    track: dvui.Color = palette.track,
    /// Ring radius as a fraction of the shorter side of the rect.
    radius_frac: f32 = 0.42,
};

/// Clamp the value to 0..1 of the full scale.
pub fn fraction(o: Options) f32 {
    const maxv: f32 = if (o.max == 0) 1 else o.max;
    return std.math.clamp(o.value / maxv, 0.0, 1.0);
}

/// Colour for a given fraction: the accent, or yellow/red past the thresholds.
pub fn valueColor(frac: f32, o: Options) dvui.Color {
    if (frac >= o.red_at) return palette.red;
    if (frac >= o.yellow_at) return palette.yellow;
    return o.accent;
}

pub fn thicknessFor(rs: dvui.RectScale, o: Options) f32 {
    return o.thickness orelse @max(4.0, 13.0 * rs.s);
}

/// Draw the ring only (track, thresholds, value arc).  Round-capped.
pub fn drawRing(rs: dvui.RectScale, o: Options) void {
    const r = rs.r;
    if (r.w <= 0 or r.h <= 0) return;

    const cx = r.x + r.w * 0.5;
    const cy = r.y + r.h * 0.5;
    const radius = @min(r.w, r.h) * o.radius_frac;
    if (radius <= 0) return;

    const thickness = thicknessFor(rs, o);
    const f = fraction(o);

    // The gap sits at the bottom, so the sweep starts at 90° + half the gap.
    const gap_deg = 360.0 - o.sweep_deg;
    const start = arc.rad(90.0 + gap_deg * 0.5);
    const sweep = arc.rad(o.sweep_deg);

    // 1. background arc ...
    arc.arcWithCaps(cx, cy, radius, start, start + sweep, thickness, o.track);

    // 2. optional warning/danger bands, layered on the same centre/radius/
    //    thickness as the track.  They are opt-in so a plain meter stays
    //    clean; use the round-capped ring primitive so the short bands read
    //    as arcs instead of square blocks.
    if (o.show_thresholds) {
        const yellow_at = std.math.clamp(o.yellow_at, 0.0, 1.0);
        const red_at = std.math.clamp(o.red_at, 0.0, 1.0);
        if (yellow_at < red_at) {
            arc.arcWithCaps(cx, cy, radius, start + sweep * yellow_at, start + sweep * red_at, thickness, palette.yellow);
        }
        if (red_at < 1.0) {
            arc.arcWithCaps(cx, cy, radius, start + sweep * red_at, start + sweep, thickness, palette.red);
        }
    }

    // 3. ... then the value arc on top.
    if (f > 0.002) {
        arc.arcWithCaps(cx, cy, radius, start, start + sweep * f, thickness, valueColor(f, o));
    }
}

/// Integer when whole, one decimal otherwise — for the readout in the middle.
pub fn formatValue(buf: []u8, v: f32) []const u8 {
    if (@round(v) == v and @abs(v) < 100000.0) {
        return std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.1}", .{v}) catch "?";
}

/// A complete gauge cell: an optional title, the ring, and the value/unit
/// centred inside it.  Reused by the built-in dashboard and by the
/// `.layout.zon` interpreter.
///
/// `id_extra` disambiguates sibling instances in a loop (DVUI derives ids
/// from `@src()` + `id_extra`).
pub fn cell(id_extra: usize, title: []const u8, o: Options, unit: []const u8, width: f32, height: f32, opts: dvui.Options) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, opts.override(.{ .id_extra = id_extra }));
    defer box.deinit();

    if (title.len > 0) {
        dvui.labelNoFmt(@src(), title, .{ .align_x = 0.5 }, .{ .expand = .horizontal, .id_extra = id_extra });
    }

    var ring = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = width, .h = height },
        .background = false,
    });
    defer ring.deinit();

    drawRing(ring.data().rectScale(), o);

    // Value + unit centred on the ring's pivot.
    var inner = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5, .gravity_y = 0.5, .id_extra = id_extra });
    defer inner.deinit();

    var buf: [32]u8 = undefined;
    dvui.labelNoFmt(@src(), formatValue(&buf, o.value), .{ .align_x = 0.5 }, .{
        .font = dvui.Font.theme(.title).larger(8),
        .color_text = .{ .color = valueColor(fraction(o), o) },
        .expand = .horizontal,
        .id_extra = id_extra,
    });
    if (unit.len > 0) {
        dvui.labelNoFmt(@src(), unit, .{ .align_x = 0.5 }, .{ .expand = .horizontal, .id_extra = id_extra });
    }
}

test "warning bands are opt-in" {
    const o: Options = .{};
    try std.testing.expect(!o.show_thresholds);
}

test "fraction clamps and thresholds" {
    const o: Options = .{ .value = 25, .max = 50 };
    try std.testing.expectEqual(@as(f32, 0.5), fraction(o));

    try std.testing.expectEqual(palette.green, valueColor(0.5, o));
    try std.testing.expectEqual(palette.yellow, valueColor(0.8, o));
    try std.testing.expectEqual(palette.red, valueColor(0.95, o));

    // a zero full scale must not divide by zero
    try std.testing.expectEqual(@as(f32, 0.0), fraction(.{ .value = 0, .max = 0 }));
    try std.testing.expectEqual(@as(f32, 1.0), fraction(.{ .value = 200, .max = 0 }));

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("49", formatValue(&buf, 49.0));
    try std.testing.expectEqualStrings("22.4", formatValue(&buf, 22.4));
}
