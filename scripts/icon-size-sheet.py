#!/usr/bin/env python3
"""Render icon SVGs large and at 128, 64, 32 and 16 px on one sheet, to judge legibility.

Needs pillow and macOS qlmanage. Usage: scripts/icon-size-sheet.py out.png icon1.svg icon2.svg ...
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw

SIZES = [128, 64, 32, 16]
def render(svg, tmp):
    subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, svg], capture_output=True)
    im = Image.open(os.path.join(tmp, os.path.basename(svg) + ".png")).convert("RGBA")
    tile = im.crop((100, 100, 924, 924))
    mask = Image.new("L", (824 * 4, 824 * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 824 * 4 - 1, 824 * 4 - 1), radius=185 * 4, fill=255)
    tile.putalpha(mask.resize((824, 824), Image.LANCZOS))
    return tile

out, svgs = sys.argv[1], sys.argv[2:]
tmp = tempfile.mkdtemp()
cols = [render(s, tmp) for s in svgs]
pad = 28; big = 400
W = pad + len(cols) * (big + pad)
H = pad + big + pad + 128 + pad
sheet = Image.new("RGB", (W, H), (200, 200, 204))
for i, tile in enumerate(cols):
    x = pad + i * (big + pad)
    sheet.paste(tile.resize((big, big), Image.LANCZOS), (x, pad), tile.resize((big, big), Image.LANCZOS))
    cx = x
    for s in SIZES:
        t = tile.resize((s, s), Image.LANCZOS)
        sheet.paste(t, (cx, pad + big + pad), t)
        cx += s + 14
sheet.save(out); print(out)
