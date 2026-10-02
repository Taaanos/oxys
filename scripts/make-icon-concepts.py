#!/usr/bin/env python3
"""Write four bold, flat eye-hero icon concepts to design/concepts/Concept-{A,B,C,D}.svg.

Flat shapes only, so the silhouette and the eye survive small sizes. The focus-peaking
idea is one quiet accent: a row of evenly spaced dots, shrinking away from the eye,
along the head outline. Standard library only. Usage: scripts/make-icon-concepts.py [out_dir]
"""
import math, os, sys

# --- geometry ---------------------------------------------------------------------
def bez(p0, p1, p2, p3, n=24):
    return [tuple((1 - t) ** 3 * p0[i] + 3 * (1 - t) ** 2 * t * p1[i] + 3 * (1 - t) * t * t * p2[i] + t ** 3 * p3[i]
                  for i in (0, 1)) for t in (k / n for k in range(n + 1))]

# Profile of a perched potoo facing right: beak, forehead, crown, back of head, back, then
# down off the tile and back up the chest. Each segment is one cubic Bezier.
SEGS = [
    ((812, 332), (770, 322), (740, 300), (722, 262)),   # beak to forehead
    ((722, 262), (690, 190), (610, 160), (520, 168)),   # crown
    ((520, 168), (430, 176), (372, 230), (360, 310)),   # back of head
    ((360, 310), (350, 400), (360, 470), (350, 560)),   # nape and back
    ((350, 560), (340, 680), (330, 800), (350, 940)),   # back, off the tile
    ((350, 940), (350, 940), (740, 940), (740, 940)),   # bottom edge (straight)
    ((740, 940), (740, 800), (770, 700), (760, 610)),   # chest, right side
    ((760, 610), (750, 530), (740, 480), (730, 440)),   # chest to throat
    ((730, 440), (720, 400), (760, 372), (812, 332)),   # throat to beak
]
def path_d(segs=None):
    segs = segs or SEGS
    d = f"M{segs[0][0][0]} {segs[0][0][1]}"
    for _, a, b, c in segs:
        d += f" C{a[0]} {a[1]} {b[0]} {b[1]} {c[0]} {c[1]}"
    return d + "Z"

def outline_points():
    pts = []
    for s in SEGS: pts += bez(*s)
    return pts

def inside(pt, poly):
    x, y = pt; c = False
    for i in range(len(poly)):
        (x1, y1), (x2, y2) = poly[i], poly[i - 1]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1: c = not c
    return c

def peaking_dots(fill, eye, first=0, last=4, step=27, offset=21, rmax=6.0, rmin=2.2):
    """Evenly spaced dots just outside the head outline; they shrink away from the eye."""
    poly = outline_points(); pts = []
    for s in SEGS[first:last]: pts += bez(*s, n=60)
    out, acc = [], 0.0
    for i in range(1, len(pts)):
        d = math.dist(pts[i - 1], pts[i]); acc += d
        if acc < step: continue
        acc = 0.0
        x, y = pts[i]; dx, dy = pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]; L = math.hypot(dx, dy) or 1
        nx, ny = -dy / L, dx / L
        if inside((x + nx * 6, y + ny * 6), poly): nx, ny = -nx, -ny
        px, py = x + nx * offset, y + ny * offset
        k = min(1.0, math.dist((px, py), eye) / 420)
        out.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="{rmax - (rmax - rmin) * k:.1f}" fill="{fill}"/>')
    return "".join(out)

def leaf(p1, p2, w, fill, op=1.0):
    """A pointed, lens-shaped mark between two points: one deliberate brush-like stroke."""
    mx, my = (p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2
    dx, dy = p2[0] - p1[0], p2[1] - p1[1]; L = math.hypot(dx, dy) or 1
    nx, ny = -dy / L * w, dx / L * w
    return (f'<path d="M{p1[0]} {p1[1]} Q{mx + nx:.1f} {my + ny:.1f} {p2[0]} {p2[1]} '
            f'Q{mx - nx:.1f} {my - ny:.1f} {p1[0]} {p1[1]}Z" fill="{fill}" fill-opacity="{op}"/>')

EYE = (590, 300)

# --- the three concepts -----------------------------------------------------------
def concept_a():
    """Black tile, pale bird, black eye; grey feather marks; white peaking dots on the head."""
    bg, bird, ink, mark = "#000", "#f1f1f1", "#0a0a0a", "#8d8d8d"
    marks = "".join(leaf(a, b, w, mark) for a, b, w in (
        ((440, 470), (470, 940), 46), ((520, 520), (560, 940), 40), ((600, 560), (640, 900), 34),
        ((420, 250), (500, 190), 14), ((450, 300), (520, 210), 12), ((410, 330), (470, 250), 10),
        ((660, 520), (690, 640), 26), ((600, 440), (640, 520), 20)))
    return bg, f'''
<path d="{path_d()}" fill="{bird}"/>{marks}
<path d="M806 338 C760 350 710 372 668 380" stroke="{ink}" stroke-width="9" fill="none" stroke-linecap="round"/>
{leaf((514, 238), (690, 262), 18, ink)}
<circle cx="{EYE[0]}" cy="{EYE[1]}" r="82" fill="none" stroke="#c9c9c9" stroke-width="6"/>
<circle cx="{EYE[0]}" cy="{EYE[1]}" r="62" fill="{ink}"/>
<circle cx="{EYE[0] - 20}" cy="{EYE[1] - 22}" r="15" fill="#fff"/><circle cx="{EYE[0] + 22}" cy="{EYE[1] + 24}" r="6" fill="#fff"/>
{peaking_dots("#fff", EYE)}'''

def concept_b():
    """Black tile; the eye is the whole icon: a lens of rings, with peaking dots as a ring."""
    cx, cy = 512, 512
    ring = "".join(f'<circle cx="{cx + 232 * math.cos(a):.1f}" cy="{cy + 232 * math.sin(a):.1f}" r="{5.5 - 2.2 * abs(math.sin(a)) :.1f}" fill="#fff"/>'
                   for a in (i / 48 * 2 * math.pi for i in range(48)))
    return "#000", f'''
<circle cx="{cx}" cy="{cy}" r="300" fill="none" stroke="#fff" stroke-width="26"/>
<circle cx="{cx}" cy="{cy}" r="268" fill="#e9e9e9"/>
{ring}
<circle cx="{cx}" cy="{cy}" r="182" fill="#0a0a0a"/>
<circle cx="{cx}" cy="{cy}" r="182" fill="none" stroke="#8d8d8d" stroke-width="5"/>
<ellipse cx="{cx - 62}" cy="{cy - 74}" rx="52" ry="44" fill="#fff" transform="rotate(-24 {cx - 62} {cy - 74})"/>
<circle cx="{cx + 70}" cy="{cy + 78}" r="17" fill="#fff"/>
{leaf((190, 300), (830, 300), 48, "#fff", 0.0)}
<path d="M200 270 C330 170 700 170 824 270" stroke="#fff" stroke-width="30" fill="none" stroke-linecap="round"/>'''

def concept_c():
    """White tile; bold black silhouette; white eye; black peaking dots along the head."""
    ink = "#0b0b0b"
    cuts = "".join(leaf(a, b, w, "#fff", 0.92) for a, b, w in (
        ((432, 520), (462, 940), 24), ((500, 560), (540, 940), 20), ((570, 600), (610, 920), 16),
        ((650, 560), (680, 700), 12)))
    return "#fff", f'''
<path d="{path_d()}" fill="{ink}"/>{cuts}
<path d="M806 338 C760 352 712 374 670 382" stroke="#fff" stroke-width="9" fill="none" stroke-linecap="round"/>
<circle cx="{EYE[0]}" cy="{EYE[1]}" r="74" fill="#fff"/>
<circle cx="{EYE[0]}" cy="{EYE[1]}" r="52" fill="{ink}"/>
<circle cx="{EYE[0] - 16}" cy="{EYE[1] - 18}" r="13" fill="#fff"/>
{peaking_dots(ink, EYE)}'''

def concept_d():
    """A, made friendly: no brow, a big round eye with two highlights, a short beak line,
    a soft cheek patch and lighter feather marks."""
    bg, bird, ink, mark = "#000", "#f1f1f1", "#0a0a0a", "#b9b9b9"
    marks = "".join(leaf(a, b, w, mark) for a, b, w in (
        ((440, 480), (470, 940), 44), ((520, 530), (560, 940), 38), ((600, 570), (640, 900), 30),
        ((430, 260), (500, 196), 12), ((452, 304), (520, 214), 10)))
    return bg, f'''
<path d="{path_d()}" fill="{bird}"/>{marks}
<ellipse cx="{EYE[0] + 38}" cy="{EYE[1] + 92}" rx="40" ry="26" fill="#d4d4d4"/>
<path d="M806 338 C778 346 750 356 722 362" stroke="{ink}" stroke-width="9" fill="none" stroke-linecap="round"/>
<circle cx="{EYE[0]}" cy="{EYE[1]}" r="76" fill="{ink}"/>
<circle cx="{EYE[0] - 22}" cy="{EYE[1] - 24}" r="19" fill="#fff"/><circle cx="{EYE[0] + 24}" cy="{EYE[1] + 26}" r="8" fill="#fff"/>
{peaking_dots("#fff", EYE)}'''

def svg(bg, body, name):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<title>Oxys app icon concept: {name}</title>
<defs><clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath></defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="{bg}"/>
<g clip-path="url(#tile)">{body}</g>
</svg>
'''

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "design/concepts"
    os.makedirs(out, exist_ok=True)
    for key, fn, name in (("A", concept_a, "pale bird on black"), ("B", concept_b, "the eye as a lens"), ("C", concept_c, "black silhouette on white"), ("D", concept_d, "friendly pale bird on black")):
        bg, body = fn()
        path = f"{out}/Concept-{key}.svg"
        open(path, "w").write(svg(bg, body, name)); print(path, "-", name)
