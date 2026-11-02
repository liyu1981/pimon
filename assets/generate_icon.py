#!/usr/bin/env python3
"""Generate the pimon Win11 agent icon (ICO + PNG) with no dependencies."""

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SIZES = (16, 24, 32, 48, 64, 128, 256)
SS = 4

BG = (0x17, 0x1B, 0x24, 255)
BORDER = (0x2B, 0x34, 0x46, 255)
TRACK = (0x35, 0x3C, 0x4D, 255)
ACCENT = (0x35, 0xE0, 0xB0, 255)
YELLOW = (0xFF, 0xD2, 0x4A, 255)
RED = (0xFF, 0x4D, 0x5A, 255)
PI = (0xEE, 0xF7, 0xFF, 255)


def rounded_rect(x, y, w, h, r, px, py):
    cx = min(max(px, x + r), x + w - r)
    cy = min(max(py, y + r), y + h - r)
    return (px - cx) ** 2 + (py - cy) ** 2 <= r * r


def dist_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def sample(size, px, py):
    """Return RGBA for one high-resolution sample in a size x size square."""
    if not rounded_rect(0.06 * size, 0.06 * size, 0.88 * size, 0.88 * size,
                        0.22 * size, px, py):
        return (0, 0, 0, 0)

    color = BG
    # subtle border
    if not rounded_rect(0.08 * size, 0.08 * size, 0.84 * size, 0.84 * size,
                        0.20 * size, px, py):
        color = BORDER

    cx = cy = size * 0.5
    dx, dy = px - cx, py - cy
    radius = 0.335 * size
    thickness = 0.078 * size
    dist = math.hypot(dx, dy)
    if abs(dist - radius) <= thickness * 0.5:
        # Screen space: 0 is +x, 90 is down.  The gauge gap is at the bottom.
        angle = math.degrees(math.atan2(dy, dx)) % 360.0
        rel = (angle - 135.0) % 360.0
        if rel <= 270.0:
            f = rel / 270.0
            color = ACCENT
            if f >= 0.86:
                color = RED
            elif f >= 0.72:
                color = YELLOW

    # Round caps for the value arc.
    for degrees, col in ((135.0, ACCENT), (45.0, RED)):
        ex = cx + math.cos(math.radians(degrees)) * radius
        ey = cy + math.sin(math.radians(degrees)) * radius
        if math.hypot(px - ex, py - ey) <= thickness * 0.5:
            color = col

    # A small pi mark in the middle.
    bar = 0.055 * size
    if (dist_segment(px, py, 0.43 * size, 0.38 * size, 0.43 * size, 0.64 * size) <= bar * 0.5 or
            dist_segment(px, py, 0.57 * size, 0.38 * size, 0.57 * size, 0.64 * size) <= bar * 0.5 or
            dist_segment(px, py, 0.39 * size, 0.42 * size, 0.61 * size, 0.42 * size) <= bar * 0.5):
        color = PI

    return color


def render(size):
    hi = size * SS
    data = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            rs = gs = bs = a = 0
            for sy in range(SS):
                for sx in range(SS):
                    r, g, b, al = sample(size, (x * SS + sx + 0.5) / SS,
                                         (y * SS + sy + 0.5) / SS)
                    rs += r * al
                    gs += g * al
                    bs += b * al
                    a += al
            n = SS * SS
            i = (y * size + x) * 4
            if a == 0:
                data[i:i + 4] = b"\0\0\0\0"
            else:
                data[i] = rs // a
                data[i + 1] = gs // a
                data[i + 2] = bs // a
                data[i + 3] = a // n
    return bytes(data)


def dib(size, rgba):
    mask_row = ((size + 31) // 32) * 4
    info = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0,
                       size * size * 4 + mask_row * size, 0, 0, 0, 0)
    # ICO DIB pixels are bottom-up and BGRA.
    pixels = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            src = ((size - 1 - y) * size + x) * 4
            dst = (y * size + x) * 4
            r, g, b, a = rgba[src:src + 4]
            pixels[dst:dst + 4] = bytes((b, g, r, a))
    mask = b"\0" * (mask_row * size)
    return info + bytes(pixels) + mask


def png(size, rgba):
    raw = b"".join(b"\0" + rgba[y * size * 4:(y + 1) * size * 4]
                   for y in range(size))

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload +
                struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff))

    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 9)) +
            chunk(b"IEND", b""))


def main():
    images = [(size, render(size)) for size in SIZES]
    entries = []
    payloads = []
    offset = 6 + 16 * len(images)
    for size, rgba in images:
        payload = dib(size, rgba)
        entries.append(struct.pack("<BBBBHHII", 0 if size == 256 else size,
                                   0 if size == 256 else size, 0, 0, 1, 32,
                                   len(payload), offset))
        payloads.append(payload)
        offset += len(payload)
    ico = (struct.pack("<HHH", 0, 1, len(images)) + b"".join(entries) +
           b"".join(payloads))
    (ROOT / "pimon-win11.ico").write_bytes(ico)
    (ROOT / "pimon-win11.png").write_bytes(png(256, images[-1][1]))
    print(f"wrote {ROOT / 'pimon-win11.ico'} ({len(ico)} bytes)")
    print(f"wrote {ROOT / 'pimon-win11.png'} ({ROOT / 'pimon-win11.png'} )")


if __name__ == "__main__":
    main()
