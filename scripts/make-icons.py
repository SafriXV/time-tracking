#!/usr/bin/env python3
"""Generate the two PWA icons without external dependencies."""
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "web" / "icons"
OUT.mkdir(parents=True, exist_ok=True)


def png(size: int, path: Path) -> None:
    w = h = size
    bg = (16, 22, 32)
    ring = (74, 222, 128)
    white = (238, 243, 251)

    def pixel(x: int, y: int):
        cx = cy = (size - 1) / 2
        dx, dy = x - cx, y - cy
        r2 = dx * dx + dy * dy
        outer = (size * 0.40) ** 2
        inner = (size * 0.325) ** 2
        if inner <= r2 <= outer:
            return ring
        if r2 < inner:
            # minute hand (up) and hour hand (down-right)
            if (-size * 0.022 <= dx <= size * 0.022 and -size * 0.25 <= dy <= size * 0.02):
                return white
            if (0 <= dx <= size * 0.018 and 0 <= -dy <= size * 0.16 and abs(dy + 1.7 * dx) < size * 0.02):
                return white
            if r2 < (size * 0.035) ** 2:
                return ring
        return bg

    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(pixel(x, y))

    def chunk(tag: bytes, data: bytes):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">2I5B", w, h, 8, 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
                     chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    print(f"wrote {path}")


for dimension in (192, 512):
    png(dimension, OUT / f"icon-{dimension}.png")
