#!/usr/bin/env python3
"""Write six moods of concept D, from very friendly to stern, to design/mood/Mood-N.svg,
and three calm variations to design/mood/Calm-N.svg.

Same bird, same tile, same peaking dots. Only the face changes: eye size, brow, eyelid,
cheek, beak line, contrast of the feather marks and the size of the dots.
Standard library only. Usage: scripts/make-icon-moods.py [out_dir]
"""
import importlib.util, math, os, sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("concepts", os.path.join(here, "make-icon-concepts.py"))
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
EYE = c.EYE

# A fuller chest, as on the real bird: the breast bulges out to the right below the throat.
CHEST_SEGS = list(c.SEGS)
CHEST_SEGS[6] = ((740, 940), (770, 820), (846, 720), (834, 610))
CHEST_SEGS[7] = ((834, 610), (826, 540), (786, 478), (730, 440))

BIRD, INK = "#f1f1f1", "#0a0a0a"

def face(m):
    """The eye, brow, lid, cheek and beak line for one mood."""
    return eye(m) + beak(m)

def eye(m):
    """The eye with its highlight, ring, lid, brow and cheek."""
    ex, ey = EYE; r = m["eye"]; out = []
    if m.get("cheek"):
        out.append(f'<ellipse cx="{ex + 38}" cy="{ey + r + 16}" rx="{m["cheek"]}" ry="{m["cheek"] * 0.65:.0f}" fill="#d4d4d4"/>')
    if m.get("ring"):
        out.append(f'<circle cx="{ex}" cy="{ey}" r="{r + m["ring"][0]}" fill="none" stroke="{m["ring"][1]}" stroke-width="{m["ring"][2]}"/>')
    k = r / 76
    if m.get("closed"):                            # a closed eye: one smooth arc, bulging downward
        w = m["closed"]
        out.append(f'<path d="M{ex - r} {ey - 6} Q{ex} {ey + r * 0.75:.0f} {ex + r} {ey - 6}" stroke="{INK}" stroke-width="{w}" fill="none" stroke-linecap="round"/>')
    else:
        out.append(f'<circle cx="{ex}" cy="{ey}" r="{r}" fill="{INK}"/>')
        sx, sy = m.get("shine_at", (-22, -24))        # highlight position, in units of the 76 px eye
        out.append(f'<circle cx="{ex + sx * k:.1f}" cy="{ey + sy * k:.1f}" r="{19 * k * m.get("shine", 1):.1f}" fill="#fff"/>')
        if m.get("shine2", True):
            out.append(f'<circle cx="{ex + 24 * k:.1f}" cy="{ey + 26 * k:.1f}" r="{8 * k:.1f}" fill="#fff"/>')
    if m.get("lower"):                             # a relaxed lower lid, soft grey
        out.append(f'<path d="M{ex - r * 0.95:.0f} {ey + r * 0.5:.0f} Q{ex} {ey + r * 1.45:.0f} {ex + r * 0.95:.0f} {ey + r * 0.5:.0f}" stroke="#c4c4c4" stroke-width="7" fill="none" stroke-linecap="round"/>')
    if m.get("raised"):                            # a raised, relaxed brow line: curves up, never down
        out.append(f'<path d="M{ex - r} {ey - r - 6} Q{ex} {ey - r - 38} {ex + r} {ey - r - 6}" stroke="#bcbcbc" stroke-width="7" fill="none" stroke-linecap="round"/>')
    if m.get("lid"):                               # a heavy upper lid: bird-coloured cap over the eye
        cut = ey - r + 2 * r * m["lid"]
        cid = f"lid{int(r)}{int(m['lid'] * 100)}"
        out.append(f'<clipPath id="{cid}"><circle cx="{ex}" cy="{ey}" r="{r + 1}"/></clipPath>'
                   f'<rect x="{ex - r - 2}" y="{ey - r - 2}" width="{2 * r + 4}" height="{cut - (ey - r - 2):.1f}" fill="{BIRD}" clip-path="url(#{cid})"/>'
                   f'<path d="M{ex - r - 4} {cut:.1f} L{ex + r + 4} {cut:.1f}" stroke="{INK}" stroke-width="7" stroke-linecap="round"/>')
    if m.get("brow"):                              # (thickness, drop of the beak-side end)
        w, drop = m["brow"]
        out.append(c.leaf((ex - r - 18, ey - r * 0.95 - 6), (ex + r + 20, ey - r * 0.95 - 6 + drop), w, INK))
    return "".join(out)

def beak(m):
    """The beak line."""
    out = []
    g, sm, curl = m["gape"], m["smile"], m.get("curl", 0)
    if curl:   # a straight line, then only its far end bends up
        pt = lambda f, dy=0: f"{806 - g * f:.1f} {338 + sm * f + dy:.1f}"
        d = f"M806 338 L{pt(0.80)} Q{pt(1.0)} {pt(1.04, -curl)}"
    else:
        d = (f"M806 338 C{806 - g * 0.4:.0f} {338 + sm * 0.4:.0f} {806 - g * 0.75:.0f} {338 + sm * 0.75:.0f} "
             f"{806 - g:.0f} {338 + sm}")
    out.append(f'<path d="{d}" stroke="{INK}" stroke-width="{m.get("beak_w", 9)}" fill="none" stroke-linecap="round"/>')
    return "".join(out)

def parts(m):
    """The bird as separate SVG fragments, back to front: body, marks, eye, beak, dots."""
    marks = "".join(c.leaf(a, b, w * m.get("mark_w", 1), m["mark"]) for a, b, w in (
        ((440, 480), (470, 940), 44), ((520, 530), (560, 940), 38), ((600, 570), (640, 900), 30),
        ((430, 260), (500, 196), 12), ((452, 304), (520, 214), 10))[: m.get("marks", 5)])
    dots = m.get("dots", 6.0)                       # None: no peaking dots along the head
    return dict(body=f'<path d="{c.path_d(CHEST_SEGS if m.get("chest") else None)}" fill="{BIRD}"/>', marks=marks,
                eye=eye(m), beak=beak(m),
                dots="" if dots is None else c.peaking_dots("#fff", EYE, rmax=dots, rmin=dots * 0.37))

def bird(m):
    p = parts(m)
    return p["body"] + p["marks"] + p["eye"] + p["beak"] + p["dots"]

MOODS = [
    ("1 delighted",  dict(eye=92, cheek=46, gape=60, smile=-4, mark="#c8c8c8", marks=3, shine=1.15)),
    ("2 observing",  dict(eye=66, ring=(11, "#cfcfcf", 4), shine=1.45, shine_at=(-9, -11), shine2=False, dots=None, gape=84, smile=10, mark="#b9b9b9", marks=5)),
    ("3 calm",       dict(eye=72, lid=0.34, gape=84, smile=14, mark="#a9a9a9", marks=5, shine2=False)),
    ("4 attentive",  dict(eye=64, ring=(12, "#bdbdbd", 5), brow=(11, 0), gape=96, smile=26, mark="#9d9d9d", marks=5)),
    ("5 serious",    dict(eye=58, lid=0.18, brow=(15, 10), gape=108, smile=30, mark="#868686", marks=5, shine2=False, beak_w=10, dots=7.0)),
    ("6 stern",      dict(eye=52, ring=(14, "#8d8d8d", 5), brow=(20, 20), gape=124, smile=34, mark="#6f6f6f", mark_w=1.15, marks=5, shine2=False, shine=0.7, beak_w=11, dots=8.0)),
    ("7 observing, full chest", dict(eye=66, ring=(11, "#cfcfcf", 4), shine=1.45, shine_at=(-9, -11), shine2=False, dots=None, gape=84, smile=10, mark="#b9b9b9", marks=5, chest=True)),
]

CALM = [
    ("asleep",     dict(eye=64, closed=15, cheek=40, gape=70, smile=4, mark="#c4c4c4", marks=3)),
    ("serene",     dict(eye=58, lower=True, raised=True, gape=76, smile=6, mark="#c0c0c0", marks=4, shine2=False)),
    ("meditative", dict(eye=58, closed=10, cheek=34, gape=52, smile=2, mark="#d0d0d0", marks=2, beak_w=7, dots=4.6)),
]

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "design/mood"
    os.makedirs(out, exist_ok=True)
    for i, (name, m) in enumerate(MOODS, 1):
        path = f"{out}/Mood-{i}.svg"
        open(path, "w").write(c.svg("#000", bird(m), f"D, mood {name}")); print(path, "-", name)
    for i, (name, m) in enumerate(CALM, 1):
        path = f"{out}/Calm-{i}.svg"
        open(path, "w").write(c.svg("#000", bird(m), f"D, calm {name}")); print(path, "-", name)
