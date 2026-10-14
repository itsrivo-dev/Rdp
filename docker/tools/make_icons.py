#!/usr/bin/env python3
"""Generate the PWA icons and favicon used by the login page.

Run at image build time (and by the test suite). Everything is drawn from
scratch with the standard library - no image libraries, no binary blobs in the
repository.

Usage: make_icons.py <output-directory>
"""

from __future__ import annotations

import binascii
import math
import os
import struct
import sys
import zlib

AUBERGINE = (44, 0, 30)
AUBERGINE_TOP = (74, 0, 51)
ORANGE = (233, 84, 32)
LIGHT = (240, 232, 236)


# ---------------------------------------------------------------------------
# PNG writing
# ---------------------------------------------------------------------------
def write_png(path: str, width: int, height: int, rows: list[bytearray]) -> None:
    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack("!I", len(payload)) + tag + payload
                + struct.pack("!I", binascii.crc32(tag + payload) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(png)


def write_ico(path: str, png_bytes: bytes, size: int) -> None:
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(png_bytes),
                        6 + 16)
    with open(path, "wb") as handle:
        handle.write(header + entry + png_bytes)


# ---------------------------------------------------------------------------
# drawing
# ---------------------------------------------------------------------------
def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return low if value < low else high if value > high else value


def sdf_round_rect(px: float, py: float, cx: float, cy: float, hw: float, hh: float,
                   radius: float) -> float:
    dx = abs(px - cx) - (hw - radius)
    dy = abs(py - cy) - (hh - radius)
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    return outside + min(max(dx, dy), 0.0) - radius


def sdf_segment(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    length_squared = vx * vx + vy * vy
    t = 0.0 if length_squared == 0 else clamp((wx * vx + wy * vy) / length_squared)
    return math.hypot(wx - t * vx, wy - t * vy)


def blend(pixels: list, width: int, index: int, color, alpha: float) -> None:
    if alpha <= 0:
        return
    x = index % width
    y = index // width
    r, g, b = color
    if r == g == b == -1:  # marker for "background gradient"
        return
    existing = pixels[y][x * 4:(x + 1) * 4]
    source = (r, g, b, int(round(alpha * 255)))
    if existing[3] == 0:
        new = source
    else:
        out_alpha = alpha + existing[3] / 255.0 * (1 - alpha)
        if out_alpha <= 0:
            new = (0, 0, 0, 0)
        else:
            new = tuple(
                int(round((c * alpha + e * (existing[3] / 255.0) * (1 - alpha)) / out_alpha))
                for c, e in zip((r, g, b), existing[:3])
            ) + (int(round(out_alpha * 255)),)
    pixels[y][x * 4:(x + 1) * 4] = bytes(new)


def draw_icon(size: int, maskable: bool) -> tuple[list, int, int]:
    """Return (rows, width, height) with the icon rendered at *size* pixels."""
    pixels = [bytearray(size * 4) for _ in range(size)]
    background = AUBERGINE if not maskable else AUBERGINE

    # background: full bleed for maskable icons, rounded square otherwise
    for y in range(size):
        for x in range(size):
            px, py = x + 0.5, y + 0.5
            if maskable:
                coverage = 1.0
                top = AUBERGINE_TOP
            else:
                radius = size * 0.22
                coverage = clamp(0.5 - sdf_round_rect(px, py, size / 2, size / 2,
                                                      size / 2 - 0.5, size / 2 - 0.5, radius))
                top = AUBERGINE_TOP
            if coverage <= 0:
                continue
            ratio = py / size
            color = tuple(int(round(top[i] + (background[i] - top[i]) * ratio)) for i in range(3))
            blend(pixels, size, y * size + x, color, coverage)

    # glyph: ">_" terminal prompt, scaled down inside the maskable safe zone
    scale = 0.62 if maskable else 1.0
    def point(nx: float, ny: float) -> tuple[float, float]:
        return (size / 2 + (nx - 0.5) * size * scale, size / 2 + (ny - 0.5) * size * scale)

    stroke = size * 0.075 * scale
    ax, ay = point(0.31, 0.31)
    bx, by = point(0.52, 0.50)
    cx, cy = point(0.31, 0.69)
    bar_x0, bar_y0 = point(0.57, 0.64)
    bar_x1, bar_y1 = point(0.79, 0.72)

    for y in range(size):
        for x in range(size):
            px, py = x + 0.5, y + 0.5
            alpha = 0.0
            colors = []
            d1 = sdf_segment(px, py, ax, ay, bx, by) - stroke / 2
            d2 = sdf_segment(px, py, bx, by, cx, cy) - stroke / 2
            bar_radius = (bar_y1 - bar_y0) / 2
            d3 = sdf_round_rect(px, py, (bar_x0 + bar_x1) / 2, (bar_y0 + bar_y1) / 2,
                                (bar_x1 - bar_x0) / 2, (bar_y1 - bar_y0) / 2, bar_radius)
            for distance, color in ((d1, ORANGE), (d2, ORANGE), (d3, LIGHT)):
                cov = clamp(0.5 - distance)
                if cov > 0:
                    if cov > alpha:
                        alpha = cov
                        colors = [color]
                    elif cov == alpha:
                        colors.append(color)
            if alpha > 0:
                blend(pixels, size, y * size + x, colors[0], alpha)

    return pixels, size, size


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)

    for size, name in ((192, "icon-192.png"), (512, "icon-512.png")):
        rows, width, height = draw_icon(size, maskable=False)
        write_png(os.path.join(outdir, name), width, height, rows)
        print("wrote %s (%dx%d)" % (name, width, height))

    rows, width, height = draw_icon(512, maskable=True)
    write_png(os.path.join(outdir, "icon-maskable-512.png"), width, height, rows)
    print("wrote icon-maskable-512.png (512x512)")

    rows, width, height = draw_icon(32, maskable=False)
    tmp = os.path.join(outdir, "favicon-32.png")
    write_png(tmp, width, height, rows)
    with open(tmp, "rb") as handle:
        png_bytes = handle.read()
    os.unlink(tmp)
    write_ico(os.path.join(outdir, "favicon.ico"), png_bytes, 32)
    print("wrote favicon.ico (32x32)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
