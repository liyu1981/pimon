//! Tiny CPU triangle rasterizer tailored to the triangles DVUI emits.
//!
//! DVUI hands us:
//!   * vertices with physical-pixel positions, premultiplied-alpha colours and
//!     normalized texture coordinates,
//!   * an optional RGBA (premultiplied) texture,
//!   * an optional integer clip rectangle.
//!
//! Everything is blended source-over in premultiplied-alpha space into a
//! 0xAARRGGBB `u32` buffer.  No anti-aliasing pass is needed: DVUI has already
//! baked coverage into the vertex colours / font atlas alpha.

const std = @import("std");
const dvui = @import("dvui");

pub const Texture = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    interpolation: dvui.enums.TextureInterpolation = .linear,
    wrap_u: dvui.enums.TextureWrap = .clamp,
    wrap_v: dvui.enums.TextureWrap = .clamp,
};

pub inline fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

pub inline fn fromPma(c: dvui.Color.PMA) u32 {
    return rgba(c.r, c.g, c.b, c.a);
}

pub const Surface = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

pub fn clear(surface: Surface, color: u32) void {
    @memset(surface.pixels, color);
}

inline fn edge(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) f32 {
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

inline fn isTopLeft(ax: f32, ay: f32, bx: f32, by: f32) bool {
    return (by > ay) or (by == ay and bx < ax);
}

inline fn mul8(a: u8, b: u8) u8 {
    return @intCast((@as(u32, a) * @as(u32, b) + 127) / 255);
}

inline fn blendPixel(dst: *u32, r: u8, g: u8, b: u8, a: u8) void {
    if (a == 0) return;
    if (a == 255) {
        dst.* = rgba(r, g, b, 255);
        return;
    }
    const p = dst.*;
    const inv: u32 = 255 - a;
    const dr: u32 = (p >> 16) & 0xff;
    const dg: u32 = (p >> 8) & 0xff;
    const db: u32 = p & 0xff;
    const da: u32 = (p >> 24) & 0xff;

    const nr: u32 = @min(@as(u32, r) + (dr * inv + 127) / 255, 255);
    const ng: u32 = @min(@as(u32, g) + (dg * inv + 127) / 255, 255);
    const nb: u32 = @min(@as(u32, b) + (db * inv + 127) / 255, 255);
    const na: u32 = @min(@as(u32, a) + (da * inv + 127) / 255, 255);
    dst.* = (na << 24) | (nr << 16) | (ng << 8) | nb;
}

inline fn wrapCoord(mode: dvui.enums.TextureWrap, x: i32, n: i32) i32 {
    if (mode == .repeat) {
        if (n <= 0) return 0;
        return @mod(x, n);
    }
    return std.math.clamp(x, 0, n - 1);
}

inline fn texel(tex: *const Texture, x: i32, y: i32) u32 {
    const w: i32 = @intCast(tex.width);
    const h: i32 = @intCast(tex.height);
    const xi = wrapCoord(tex.wrap_u, x, w);
    const yi = wrapCoord(tex.wrap_v, y, h);
    return tex.pixels[@as(usize, @intCast(yi)) * tex.width + @as(usize, @intCast(xi))];
}

const Sample = struct { r: u8, g: u8, b: u8, a: u8 };

fn sampleTexel(tex: *const Texture, u: f32, v: f32) Sample {
    const w: f32 = @floatFromInt(tex.width);
    const h: f32 = @floatFromInt(tex.height);

    if (tex.interpolation == .nearest) {
        const x: i32 = @intFromFloat(@floor(u * w));
        const y: i32 = @intFromFloat(@floor(v * h));
        const p = texel(tex, x, y);
        return .{ .r = @truncate(p >> 16), .g = @truncate(p >> 8), .b = @truncate(p), .a = @truncate(p >> 24) };
    }

    // Bilinear, sampling at texel centres.
    const fx = u * w - 0.5;
    const fy = v * h - 0.5;
    const x0: i32 = @intFromFloat(@floor(fx));
    const y0: i32 = @intFromFloat(@floor(fy));
    const tx = fx - @floor(fx);
    const ty = fy - @floor(fy);

    const p00 = texel(tex, x0, y0);
    const p10 = texel(tex, x0 + 1, y0);
    const p01 = texel(tex, x0, y0 + 1);
    const p11 = texel(tex, x0 + 1, y0 + 1);

    const w00 = (1 - tx) * (1 - ty);
    const w10 = tx * (1 - ty);
    const w01 = (1 - tx) * ty;
    const w11 = tx * ty;

    return .{
        .r = lerp4(p00 >> 16, p10 >> 16, p01 >> 16, p11 >> 16, w00, w10, w01, w11),
        .g = lerp4(p00 >> 8, p10 >> 8, p01 >> 8, p11 >> 8, w00, w10, w01, w11),
        .b = lerp4(p00, p10, p01, p11, w00, w10, w01, w11),
        .a = lerp4(p00 >> 24, p10 >> 24, p01 >> 24, p11 >> 24, w00, w10, w01, w11),
    };
}

inline fn lerp4(a: u32, b: u32, c: u32, d: u32, wa: f32, wb: f32, wc: f32, wd: f32) u8 {
    const v = @as(f32, @floatFromInt(a & 0xff)) * wa +
        @as(f32, @floatFromInt(b & 0xff)) * wb +
        @as(f32, @floatFromInt(c & 0xff)) * wc +
        @as(f32, @floatFromInt(d & 0xff)) * wd;
    return @intFromFloat(std.math.clamp(v + 0.5, 0, 255));
}

pub fn drawTriangles(
    surface: Surface,
    texture: ?*const Texture,
    vtx: []const dvui.Vertex,
    idx: []const dvui.Vertex.Index,
    clip_in: ?dvui.Rect.Physical,
) void {
    var clip_x0: f32 = 0;
    var clip_y0: f32 = 0;
    var clip_x1: f32 = @floatFromInt(surface.width);
    var clip_y1: f32 = @floatFromInt(surface.height);
    if (clip_in) |c| {
        clip_x0 = @max(clip_x0, c.x);
        clip_y0 = @max(clip_y0, c.y);
        clip_x1 = @min(clip_x1, c.x + c.w);
        clip_y1 = @min(clip_y1, c.y + c.h);
    }
    if (clip_x1 <= clip_x0 or clip_y1 <= clip_y0) return;

    var i: usize = 0;
    while (i + 3 <= idx.len) : (i += 3) {
        drawTriangle(surface, texture, vtx[idx[i]], vtx[idx[i + 1]], vtx[idx[i + 2]], clip_x0, clip_y0, clip_x1, clip_y1);
    }
}

fn drawTriangle(
    surface: Surface,
    texture: ?*const Texture,
    va: dvui.Vertex,
    vb: dvui.Vertex,
    vc: dvui.Vertex,
    clip_x0: f32,
    clip_y0: f32,
    clip_x1: f32,
    clip_y1: f32,
) void {
    const v0 = va;
    var v1 = vb;
    var v2 = vc;
    var area = edge(v0.pos.x, v0.pos.y, v1.pos.x, v1.pos.y, v2.pos.x, v2.pos.y);
    if (area == 0) return;
    if (area < 0) {
        const tmp = v1;
        v1 = v2;
        v2 = tmp;
        area = -area;
    }
    const inv_area = 1.0 / area;

    const minx = @min(v0.pos.x, @min(v1.pos.x, v2.pos.x));
    const miny = @min(v0.pos.y, @min(v1.pos.y, v2.pos.y));
    const maxx = @max(v0.pos.x, @max(v1.pos.x, v2.pos.x));
    const maxy = @max(v0.pos.y, @max(v1.pos.y, v2.pos.y));

    var x0: i32 = @intFromFloat(@floor(minx));
    var y0: i32 = @intFromFloat(@floor(miny));
    var x1: i32 = @intFromFloat(@ceil(maxx));
    var y1: i32 = @intFromFloat(@ceil(maxy));

    x0 = @max(x0, @as(i32, @intFromFloat(@floor(clip_x0))));
    y0 = @max(y0, @as(i32, @intFromFloat(@floor(clip_y0))));
    x1 = @min(x1, @as(i32, @intFromFloat(@ceil(clip_x1))));
    y1 = @min(y1, @as(i32, @intFromFloat(@ceil(clip_y1))));

    x0 = @max(x0, 0);
    y0 = @max(y0, 0);
    x1 = @min(x1, @as(i32, @intCast(surface.width)));
    y1 = @min(y1, @as(i32, @intCast(surface.height)));
    if (x0 >= x1 or y0 >= y1) return;

    const tl0 = isTopLeft(v1.pos.x, v1.pos.y, v2.pos.x, v2.pos.y);
    const tl1 = isTopLeft(v2.pos.x, v2.pos.y, v0.pos.x, v0.pos.y);
    const tl2 = isTopLeft(v0.pos.x, v0.pos.y, v1.pos.x, v1.pos.y);

    // Edge deltas for step along x.
    const dx0 = -(v2.pos.y - v1.pos.y);
    const dx1 = -(v0.pos.y - v2.pos.y);
    const dx2 = -(v1.pos.y - v0.pos.y);

    const col0 = fromPma(v0.col);
    const col1 = fromPma(v1.col);
    const col2 = fromPma(v2.col);

    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const px = @as(f32, @floatFromInt(x0)) + 0.5;

        var w0 = edge(v1.pos.x, v1.pos.y, v2.pos.x, v2.pos.y, px, py);
        var w1 = edge(v2.pos.x, v2.pos.y, v0.pos.x, v0.pos.y, px, py);
        var w2 = edge(v0.pos.x, v0.pos.y, v1.pos.x, v1.pos.y, px, py);

        var x: i32 = x0;
        while (x < x1) : (x += 1) {
            const inside = (w0 > 0 or (w0 == 0 and tl0)) and
                (w1 > 0 or (w1 == 0 and tl1)) and
                (w2 > 0 or (w2 == 0 and tl2));
            if (inside) {
                const l0 = w0 * inv_area;
                const l1 = w1 * inv_area;
                const l2 = w2 * inv_area;

                const cr = interp8(col0 >> 16, col1 >> 16, col2 >> 16, l0, l1, l2);
                const cg = interp8(col0 >> 8, col1 >> 8, col2 >> 8, l0, l1, l2);
                const cb = interp8(col0, col1, col2, l0, l1, l2);
                const ca = interp8(col0 >> 24, col1 >> 24, col2 >> 24, l0, l1, l2);

                const idx_px = @as(usize, @intCast(y)) * surface.width + @as(usize, @intCast(x));
                if (texture) |tex| {
                    const u = v0.uv[0] * l0 + v1.uv[0] * l1 + v2.uv[0] * l2;
                    const v = v0.uv[1] * l0 + v1.uv[1] * l1 + v2.uv[1] * l2;
                    const s = sampleTexel(tex, u, v);
                    blendPixel(&surface.pixels[idx_px], mul8(s.r, cr), mul8(s.g, cg), mul8(s.b, cb), mul8(s.a, ca));
                } else {
                    blendPixel(&surface.pixels[idx_px], cr, cg, cb, ca);
                }
            }
            w0 += dx0;
            w1 += dx1;
            w2 += dx2;
        }
    }
}

inline fn interp8(a: u32, b: u32, c: u32, l0: f32, l1: f32, l2: f32) u8 {
    const v = @as(f32, @floatFromInt(a & 0xff)) * l0 +
        @as(f32, @floatFromInt(b & 0xff)) * l1 +
        @as(f32, @floatFromInt(c & 0xff)) * l2;
    return @intFromFloat(std.math.clamp(v + 0.5, 0, 255));
}
