#!/usr/bin/env python3
"""D-01: the test frames for the contrast probe, as sRGB TIFFs (deflate), into TestData/design/ by default.

They are large (6000 x 4000), so at 1:1 a frame fills the whole canvas and every label sits on it. A frame carries
Make, Model and DateTime, so the EXIF panel has rows to show. No camera files.

Usage: scripts/make-contrast-frames.py [out-dir]
"""
import os, struct, sys, zlib

WIDTH, HEIGHT = 6000, 4000
ROWS_PER_STRIP = 64
SRGB_PROFILE = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"


def solid(rgb):
    row = bytes(rgb) * WIDTH
    return lambda y: row


def checker(cell):
    """Black and white squares of `cell` pixels: blur under glass turns it into gray, the worst case for blur."""
    unit_a = (b"\x00\x00\x00" * cell + b"\xff\xff\xff" * cell)
    a = (unit_a * (WIDTH // (2 * cell) + 1))[: WIDTH * 3]
    b = a[cell * 3:] + a[: cell * 3]
    return lambda y: a if (y // cell) % 2 == 0 else b


def split():
    """White on the left half, black on the right. The probe pans the edge under each label."""
    half = WIDTH // 2
    row = b"\xff\xff\xff" * half + b"\x00\x00\x00" * (WIDTH - half)
    return lambda y: row


# Name -> row maker. 18% gray is 18% linear light, 118 in sRGB. The yellow is the dark-mode system yellow of the stars.
FRAMES = {
    "white": solid((255, 255, 255)),
    "black": solid((0, 0, 0)),
    "gray18": solid((118, 118, 118)),
    "yellow": solid((255, 214, 10)),
    "red": solid((255, 0, 0)),
    "checker": checker(2),
    "split": split(),
}


def tiff(path, row_at, name):
    strips, cache = [], {}
    for top in range(0, HEIGHT, ROWS_PER_STRIP):
        rows = b"".join(row_at(y) for y in range(top, min(top + ROWS_PER_STRIP, HEIGHT)))
        if rows not in cache:
            cache[rows] = zlib.compress(rows, 9)
        strips.append(cache[rows])
    profile = open(SRGB_PROFILE, "rb").read()
    texts = {271: b"Oxys\0", 272: ("Contrast frame " + name).encode() + b"\0", 306: b"2026:10:03 12:00:00\0"}

    # Layout: header, IFD, then the out-of-line values, then the strips.
    entries = 18
    ifd_size = 2 + entries * 12 + 4
    blob = bytearray()
    base = 8 + ifd_size

    def put(data):
        offset = base + len(blob)
        blob.extend(data)
        if len(blob) % 2:
            blob.append(0)
        return offset

    bits = put(struct.pack("<3H", 8, 8, 8))
    xres = put(struct.pack("<2I", 72, 1))
    yres = put(struct.pack("<2I", 72, 1))
    text_offsets = {tag: put(value) for tag, value in texts.items()}
    icc = put(profile)
    counts = put(struct.pack(f"<{len(strips)}I", *map(len, strips)))
    offsets_at = base + len(blob)
    first_strip = offsets_at + 4 * len(strips)
    strip_offsets, at = [], first_strip
    for s in strips:
        strip_offsets.append(at)
        at += len(s)
    put(struct.pack(f"<{len(strips)}I", *strip_offsets))

    SHORT, ASCII, LONG, RATIONAL, UNDEFINED = 3, 2, 4, 5, 7
    fields = [
        (256, LONG, 1, WIDTH), (257, LONG, 1, HEIGHT), (258, SHORT, 3, bits), (259, SHORT, 1, 8), (262, SHORT, 1, 2),
        (271, ASCII, len(texts[271]), text_offsets[271]), (272, ASCII, len(texts[272]), text_offsets[272]),
        (273, LONG, len(strips), offsets_at), (274, SHORT, 1, 1), (277, SHORT, 1, 3), (278, LONG, 1, ROWS_PER_STRIP),
        (279, LONG, len(strips), counts), (282, RATIONAL, 1, xres), (283, RATIONAL, 1, yres), (284, SHORT, 1, 1),
        (296, SHORT, 1, 2), (306, ASCII, len(texts[306]), text_offsets[306]), (34675, UNDEFINED, len(profile), icc),
    ]
    assert len(fields) == entries
    ifd = bytearray(struct.pack("<H", entries))
    for tag, kind, count, value in fields:
        packed = struct.pack("<HI", value, 0)[:4] if kind == SHORT and count == 1 else struct.pack("<I", value)
        ifd += struct.pack("<HHI", tag, kind, count) + packed
    ifd += struct.pack("<I", 0)
    with open(path, "wb") as f:
        f.write(b"II*\0" + struct.pack("<I", 8) + ifd + blob + b"".join(strips))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "TestData", "design")
    os.makedirs(out, exist_ok=True)
    for name, row_at in FRAMES.items():
        path = os.path.join(out, name + ".tif")
        tiff(path, row_at, name)
        print(f"{path}  {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main()
