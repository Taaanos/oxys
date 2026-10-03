#!/usr/bin/env python3
"""D-01: measures the contrast of every label on the photo, from a run of scripts/contrast.sh.

For each label in each plate capture (text and symbols hidden), it takes the pixels inside the label's shape, inset by
2 pt (the glass rim is bright on purpose, and no text sits on it), converted to sRGB. The brightest 1% of them is the
worst case for light text. Each color drawn on the label is blended over that pixel (in sRGB, as the window server
composites) and compared with it by the WCAG formula. Text must keep 4.5:1, a mark (an icon, a star) 3:1.

Each combination of appearance, Reduce Transparency and Increase Contrast keeps its own rows in
docs/design/contrast/<combination>.tsv. docs/design/contrast.md is made from all of them.

Usage:
  contrast-report.py <run-dir> [--docs DIR]   measure a run, write its rows and the report; exit 1 on a fail
  contrast-report.py --render [--docs DIR]    write the report from the rows already there
  contrast-report.py --selftest               check the luminance math and the shape mask
"""
import collections, datetime, glob, json, math, os, struct, subprocess, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DOCS = os.path.join(ROOT, "docs", "design")
SRGB_PROFILE = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
INKS = ["white", "secondary", "star", "warning", "reject", "accent", "cyan"]
NEEDS = {"text": 4.5, "mark": 3.0}
FRAMES = ["white", "black", "gray18", "yellow", "red", "checker", "split"]
INSET_PT = 2
WORST_SHARE = 0.01

# MARK: color math


def linear(c):
    """sRGB component (0...1) to linear light."""
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


LINEAR = [linear(i / 255) for i in range(256)]


def luminance(rgb):
    """WCAG relative luminance of an sRGB color with components 0...1."""
    r, g, b = (linear(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def over(rgba, under):
    """`rgba` composited over the opaque color `under`, in sRGB values."""
    a = rgba[3]
    return tuple(a * f + (1 - a) * u for f, u in zip(rgba[:3], under))


# MARK: pixels


def read_bmp(path):
    data = open(path, "rb").read()
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, = struct.unpack_from("<H", data, 28)
    step = bpp // 8
    stride = (width * bpp + 31) // 32 * 4
    top_down = height < 0
    height = abs(height)

    def row(y):
        start = offset + (y if top_down else height - 1 - y) * stride
        return data[start:start + width * step]

    return width, height, step, row


def srgb_bitmap(png):
    """The capture converted to sRGB (it carries the display's profile), as an uncompressed BMP next to it."""
    bmp = png[:-4] + ".srgb.bmp"
    if not os.path.exists(bmp):
        subprocess.run(["sips", "-m", SRGB_PROFILE, "-s", "format", "bmp", png, "--out", bmp],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return read_bmp(bmp)


def shape_spans(rect, shape, scale):
    """For each pixel row inside the label's shape, inset by 2 pt: (y, first x, last x + 1)."""
    x, y, w, h = rect
    x0, y0, x1, y1 = [(v) * scale for v in (x + INSET_PT, y + INSET_PT, x + w - INSET_PT, y + h - INSET_PT)]
    if x1 <= x0 or y1 <= y0:
        return []
    kind = shape.get("kind")
    radius = {"capsule": min(w, h) / 2, "rounded": shape.get("radius", 0)}.get(kind, 0)
    r = max(0.0, radius - INSET_PT) * scale
    r = min(r, (x1 - x0) / 2, (y1 - y0) / 2)
    spans = []
    for py in range(math.floor(y0), math.ceil(y1)):
        cy = py + 0.5
        if cy < y0 or cy > y1:
            continue
        dy = max(0.0, (y0 + r) - cy, cy - (y1 - r))
        if dy > r:
            continue
        indent = r - math.sqrt(max(0.0, r * r - dy * dy))
        first = math.ceil(x0 + indent - 0.5)
        last = math.floor(x1 - indent - 0.5)
        if last >= first:
            spans.append((py, first, last + 1))
    return spans


def worst_plate(bitmap, rect, shape, scale):
    """The plate color at the brightest 1% of the shape's pixels, and how many pixels were looked at."""
    width, height, step, row = bitmap
    counts = collections.Counter()
    for y, first, end in shape_spans(rect, shape, scale):
        if not 0 <= y < height:
            continue
        first, end = max(0, first), min(width, end)
        line = row(y)[first * step:end * step]
        counts.update(zip(line[2::step], line[1::step], line[0::step]))
    total = sum(counts.values())
    if not total:
        return None, 0
    brightest = sorted(counts, key=lambda c: 0.2126 * LINEAR[c[0]] + 0.7152 * LINEAR[c[1]] + 0.0722 * LINEAR[c[2]], reverse=True)
    want, seen = max(1, math.ceil(total * WORST_SHARE)), 0
    for color in brightest:
        seen += counts[color]
        if seen >= want:
            return tuple(c / 255 for c in color), total
    return tuple(c / 255 for c in brightest[-1]), total


# MARK: measure a run


def combination(probe):
    s = probe["settings"]
    onoff = lambda k: "on" if s.get(k) else "off"
    key = f"{probe['appearance']}-rt-{onoff('reduceTransparency')}-ic-{onoff('increaseContrast')}"
    title = (f"{probe['appearance'].capitalize()} appearance, Reduce Transparency {onoff('reduceTransparency')}, "
             f"Increase Contrast {onoff('increaseContrast')}")
    return key, title


def measure(run):
    probe = json.load(open(os.path.join(run, "probe.json")))
    scale = probe["window"]["scale"]
    inks = probe["inks"]
    worst = {}   # (mode, label, frame) -> row
    for capture in probe["captures"]:
        png = os.path.join(run, capture["plate"])
        if not os.path.exists(png):
            raise SystemExit(f"contrast-report: missing capture {png}")
        bitmap = srgb_bitmap(png)
        expected = (round(probe["window"]["width"] * scale), round(probe["window"]["height"] * scale))
        if abs(bitmap[0] - expected[0]) > 2 or abs(bitmap[1] - expected[1]) > 2:
            raise SystemExit(f"contrast-report: {png} is {bitmap[0]}x{bitmap[1]}, the window is {expected[0]}x{expected[1]}")
        photos = {l["scope"]: l["photo"] for l in capture["labels"]}
        for label in capture["labels"]:
            plate, pixels = worst_plate(bitmap, label["rect"], label["shape"], scale)
            key = (capture["mode"], label["name"], label["photo"])
            row = worst.setdefault(key, {"material": label["material"], "plate": None, "ratios": {}, "pixels": 0, "missing": False})
            if plate is None:
                row["missing"] = True
                continue
            row["pixels"] += pixels
            if row["plate"] is None or luminance(plate) > luminance(row["plate"]):
                row["plate"] = plate
            for use in label["uses"]:
                value = ratio(over(inks[use["ink"]], plate), plate)
                old = row["ratios"].get(use["ink"])
                if old is None or value < old[1]:
                    row["ratios"][use["ink"]] = (use["role"], value)
        for name in capture["missing"]:
            scope, label = name.split("/", 1)
            key = (capture["mode"], label, photos.get(scope, "?"))
            worst.setdefault(key, {"material": "", "plate": None, "ratios": {}, "pixels": 0, "missing": True})["missing"] = True
    return probe, worst


def result(row):
    if row["missing"] or row["plate"] is None:
        return "missing"
    return "fail" if any(v < NEEDS[role] for role, v in row["ratios"].values()) else "pass"


def frame_order(frame):
    return FRAMES.index(frame) if frame in FRAMES else len(FRAMES)


def write_rows(probe, worst, run, docs):
    key, title = combination(probe)
    folder = os.path.join(docs, "contrast")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, key + ".tsv")
    inks = probe["inks"]
    with open(path, "w") as f:
        f.write(f"# {title}\n")
        f.write(f"# date\t{datetime.date.today().isoformat()}\n")
        f.write(f"# window\t{probe['window']['width']:.0f} x {probe['window']['height']:.0f} pt at {probe['window']['scale']:.0f}x\n")
        f.write(f"# captures\t{len(probe['captures'])}\n")
        f.write("# inks\t" + "  ".join(f"{n}={hexcolor(inks[n])}" + (f"@{inks[n][3]:.2f}" if inks[n][3] < 1 else "") for n in INKS) + "\n")
        f.write("\t".join(["mode", "label", "material", "frame", "plate", "luminance"] + INKS + ["result"]) + "\n")
        for (mode, label, frame), row in sorted(worst.items(), key=lambda kv: (kv[0][0] != "loupe", kv[0][0], kv[0][1], frame_order(kv[0][2]))):
            plate = row["plate"]
            cells = [f"{row['ratios'][i][0][0]} {row['ratios'][i][1]:.2f}" if i in row["ratios"] else "" for i in INKS]
            f.write("\t".join([mode, label, row["material"], frame, hexcolor(plate) if plate else "",
                               f"{luminance(plate):.4f}" if plate else ""] + cells + [result(row)]) + "\n")
    return path


def hexcolor(rgb):
    return "#" + "".join(f"{round(c * 255):02X}" for c in rgb[:3])


# MARK: the report


def read_rows(path):
    meta, rows, header = {}, [], None
    for line in open(path):
        line = line.rstrip("\n")
        if line.startswith("# "):
            parts = line[2:].split("\t", 1)
            if len(parts) == 1:
                meta["title"] = parts[0]
            else:
                meta[parts[0]] = parts[1]
        elif header is None:
            header = line.split("\t")
        elif line:
            rows.append(dict(zip(header, line.split("\t"))))
    return meta, rows


def cell(value):
    """`t 6.72` -> `6.7`, `m 3.10` -> `3.1 m`; a fail is bold with a cross."""
    if not value:
        return ""
    role, number = value.split(" ")
    number = float(number)
    need = NEEDS["text" if role == "t" else "mark"]
    text = f"{math.floor(number * 10) / 10:.1f}" + (" m" if role == "m" else "")
    return text if number >= need else f"**{text} ✗**"


def render(docs):
    files = sorted(glob.glob(os.path.join(docs, "contrast", "*.tsv")), key=lambda p: ("-rt-on" in p, "-ic-on" in p, p))
    out = ["# Contrast of the labels on the photo", "",
           "Made by `make contrast` (D-01, `scripts/contrast-report.py`). Do not edit it by hand.", "",
           "**How it is measured.** The `contrast` bench scenario opens each test frame (`scripts/make-contrast-frames.py`) at 1:1 "
           "in Loupe and in Compare, with every label on: the info strip at its last level (name, EXIF panel, histogram), "
           "and with the strip off (rating corner, truth badge); peaking, clipping and Auto-advance throughout. The overlays "
           "are analyzed but not painted, so each label sits on the bare frame. On the split frame the edge between white "
           "and black is moved under each label in turn. The window is captured with the labels' text and symbols hidden. "
           "Inside each label's shape, inset by 2 pt, the brightest 1% of the pixels (in sRGB) is the worst plate. Each color drawn on "
           "the label is composited over it and compared by the WCAG formula.", "",
           "**Rules.** Text keeps 4.5:1 and a mark (an icon, a star) keeps 3:1, on every frame. A value with `m` is a mark; the others "
           "are text. A fail is bold with ✗. Each value is the worst over both layouts, both Compare panes and every edge position. "
           "Inks: `secondary` is white at 85%, `star` the system yellow, `warning` `Plate.warning`, `reject` `Plate.reject`, "
           "`accent` the accent color, `cyan` the histogram's shadow percent, all as resolved in the dark appearance.", ""]
    if not files:
        out.append("No measurements yet. Run `make contrast`.")
    for path in files:
        meta, rows = read_rows(path)
        fails = [r for r in rows if r["result"] != "pass"]
        out += [f"## {meta.get('title', os.path.basename(path))}", "",
                f"{meta.get('date', '')}, window {meta.get('window', '?')}, {meta.get('captures', '?')} captures. "
                + (f"**{len(fails)} of {len(rows)} rows fail.**" if fails else f"All {len(rows)} rows pass."), "",
                f"Inks: {meta.get('inks', '')}", ""]
        # Summary: per label, the lowest value of each ink over all frames.
        groups = collections.OrderedDict()
        for r in rows:
            groups.setdefault((r["mode"], r["label"]), []).append(r)
        out += ["| Mode | Label | Material | Worst plate (frame) | " + " | ".join(INKS) + " | Result |",
                "| --- | --- | --- | --- | " + " | ".join("---:" for _ in INKS) + " | --- |"]
        for (mode, label), group in groups.items():
            measured = [r for r in group if r["luminance"]]
            top = max(measured, key=lambda r: float(r["luminance"])) if measured else None
            lows = []
            for ink in INKS:
                values = [r[ink] for r in group if r.get(ink)]
                lows.append(cell(min(values, key=lambda v: float(v.split(" ")[1]))) if values else "")
            verdict = "missing" if any(r["result"] == "missing" for r in group) else "fail" if any(r["result"] == "fail" for r in group) else "pass"
            plate = f"{top['plate']} L {float(top['luminance']):.3f} ({top['frame']})" if top else "—"
            out.append(f"| {mode} | {label} | {group[0]['material']} | {plate} | " + " | ".join(lows) + f" | {verdict} |")
        out += ["", "<details><summary>Every label on every frame</summary>", "",
                "| Mode | Label | Frame | Plate | L | " + " | ".join(INKS) + " | Result |",
                "| --- | --- | --- | --- | ---: | " + " | ".join("---:" for _ in INKS) + " | --- |"]
        for r in rows:
            out.append(f"| {r['mode']} | {r['label']} | {r['frame']} | {r['plate']} | {r['luminance']} | "
                       + " | ".join(cell(r.get(i, "")) for i in INKS) + f" | {r['result']} |")
        out += ["", "</details>", ""]
    path = os.path.join(docs, "contrast.md")
    open(path, "w").write("\n".join(out).rstrip() + "\n")
    return path


# MARK: self-test


def selftest():
    def near(a, b, tolerance=0.01):
        assert abs(a - b) <= tolerance, (a, b)

    near(ratio((1, 1, 1), (0, 0, 0)), 21.0)
    near(ratio((0x76 / 255,) * 3, (1, 1, 1)), 4.54)
    # M-18: white at 85% on a black 70% plate over white is about 6.7:1.
    plate = over((0, 0, 0, 0.7), (1, 1, 1))
    near(ratio(over((1, 1, 1, 0.85), plate), plate), 6.72)
    near(luminance((1, 1, 1)), 1.0, 1e-9)
    near(luminance((0, 0, 0)), 0.0, 1e-9)
    # The shape mask: a capsule leaves out the corners of its box; a rect keeps them.
    capsule = shape_spans((0, 0, 40, 20), {"kind": "capsule"}, 1)
    rect = shape_spans((0, 0, 40, 20), {"kind": "rect"}, 1)
    assert sum(e - s for _, s, e in capsule) < sum(e - s for _, s, e in rect) == 36 * 16
    assert capsule[0][1] > rect[0][1] and capsule[len(capsule) // 2][1] == rect[0][1]
    # The brightest 1%: in 100 pixels, 1 bright pixel is that 1%, so it sets the plate. In 200, it is 0.5%, a stray
    # pixel, and the plate is the dark color.
    width = 100
    data = bytearray(b"\x10\x10\x10" * 99 + b"\xf0\xf0\xf0")

    def row(y):
        return bytes(data)

    color, n = worst_plate((width, 1, 3, row), (-INSET_PT, -INSET_PT, width + 2 * INSET_PT, 1 + 2 * INSET_PT), {"kind": "rect"}, 1)
    assert n == 100 and color == (0xF0 / 255,) * 3, (color, n)
    data[-3:] = b"\x10\x10\x10"
    data[:3] = b"\xf0\xf0\xf0"
    data += b"\x10\x10\x10" * 100
    width = 200
    color, n = worst_plate((width, 1, 3, row), (-INSET_PT, -INSET_PT, width + 2 * INSET_PT, 1 + 2 * INSET_PT), {"kind": "rect"}, 1)
    assert n == 200 and color == (0x10 / 255,) * 3, (color, n)
    print("contrast-report selftest: ok")


def main(args):
    docs = DOCS
    if "--docs" in args:
        i = args.index("--docs")
        docs = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    if args == ["--selftest"]:
        selftest()
        return 0
    if args == ["--render"]:
        print(render(docs))
        return 0
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    probe, worst = measure(args[0])
    rows = write_rows(probe, worst, args[0], docs)
    report = render(docs)
    bad = sorted((k, result(r)) for k, r in worst.items() if result(r) != "pass")
    print(f"contrast: {len(worst)} rows -> {os.path.relpath(rows, ROOT)}, report {os.path.relpath(report, ROOT)}")
    for (mode, label, frame), verdict in bad:
        row = worst[(mode, label, frame)]
        lows = ", ".join(f"{ink} {v:.2f} ({role})" for ink, (role, v) in row["ratios"].items() if v < NEEDS[role])
        print(f"  {verdict}: {mode} {label} on {frame}" + (f": {lows}" if lows else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
