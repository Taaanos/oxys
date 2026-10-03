#!/usr/bin/env python3
"""Export a potoo mood to a layered Icon Composer file: App/Oxys/AppIcon.icon.

macOS 26 and later draw the icon tile, shadow and glass themselves, so the file holds a flat
black fill and four transparent, full-bleed layers (the 824 px tile of the design, scaled to the
whole 1024 px canvas): body, feather marks, eye (with its highlight) and beak. Each layer is its
own group, so the system gives each its own depth, shadow and glass. Each layer is matted from two
renders, on black and on white, because qlmanage cannot render transparency. All layers share one
horizontal shift, so the artwork is centred as a whole. Also writes design/AppIcon-1024.png as a preview.
Needs pillow, numpy and macOS qlmanage. Usage: scripts/export-app-icon.py [mood number, default 7]
"""
import importlib.util, json, os, shutil, subprocess, sys, tempfile
import numpy as np
from PIL import Image

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("moods", os.path.join(root, "scripts", "make-icon-moods.py"))
moods = importlib.util.module_from_spec(spec); spec.loader.exec_module(moods)

n = int(sys.argv[1]) if len(sys.argv) > 1 else 7
mood_name, mood = moods.MOODS[n - 1]
pieces = moods.parts(mood)
tmp = tempfile.mkdtemp()

def render(body, bg):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="100 100 824 824" width="1024" height="1024">'
           f'<rect x="100" y="100" width="824" height="824" fill="{bg}"/>{body}</svg>')
    path = os.path.join(tmp, f"layer-{abs(hash(body))}-{bg[1:]}.svg"); open(path, "w").write(svg)
    subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, path], capture_output=True, check=True)
    return np.asarray(Image.open(path + ".png").convert("RGB"), float)

def matte(body):
    black, white = render(body, "#000000"), render(body, "#ffffff")
    alpha = np.clip(1 - (white - black).mean(axis=2) / 255, 0, 1)
    color = np.where(alpha[..., None] > 0.003, black / np.maximum(alpha[..., None], 0.003), 0)
    return np.dstack([np.clip(color, 0, 255), alpha * 255]).astype("uint8")

CLEAR = ("light-clear", "dark-clear")
# In Clear the system maps every layer to a grey ramp, and the near-black pupil ends up as
# mid-grey on a mid-grey tile. Multiply keeps the dark layers dark there (D-09). Only the eye and
# the beak line need it; the eye also loses its specular rim in Clear, where it adds noise.
CLEAR_FIX = {"eye": {"blend-mode": "normal",
                     "blend-mode-specializations": [{"appearance": a, "value": "multiply"} for a in CLEAR],
                     "glass-specializations": [{"value": True}] + [{"appearance": a, "value": False} for a in CLEAR]},
             "beak": {"blend-mode": "normal",
                      "blend-mode-specializations": [{"appearance": a, "value": "multiply"} for a in CLEAR]}}

# Back to front. The dots (peaking marks on the head) belong to the body. glass: the system's
# specular highlight on that layer; the feather marks and the beak line stay matte, so that
# only the shapes with volume (body, eye) catch light.
SPEC = [("body", pieces["body"] + pieces["dots"], True),
        ("marks", pieces["marks"], False),
        ("eye", pieces["eye"], True),
        ("beak", pieces["beak"], False)]
layers = {name: matte(svg) for name, svg, _ in SPEC}

# Centre the whole artwork (dots and beak included) horizontally, so the black margins match.
union = np.any([l[..., 3] > 50 for l in layers.values()], axis=0)
cols = np.where(union.any(axis=0))[0]
dx = 512 - (int(cols.min()) + int(cols.max())) // 2
for name, l in layers.items():
    l = np.roll(l, dx, axis=1)
    if dx > 0: l[:, :dx] = 0
    elif dx < 0: l[:, dx:] = 0
    layers[name] = l
print(f"centred horizontally: shifted {dx} px (left margin {cols.min() + dx}, right margin {1023 - cols.max() - dx})")

icon_dir = os.path.join(root, "App", "Oxys", "AppIcon.icon")
shutil.rmtree(icon_dir, ignore_errors=True)
os.makedirs(os.path.join(icon_dir, "Assets"))
for name, l in layers.items():
    Image.fromarray(l).save(os.path.join(icon_dir, "Assets", f"{name}.png"))
with open(os.path.join(icon_dir, "icon.json"), "w") as f:
    json.dump({
        "fill": {"solid": "srgb:0.00000,0.00000,0.00000,1.00000"},
        # Icon Composer lists groups front to back.
        "groups": [{"layers": [{"glass": glass, "image-name": f"{name}.png", "name": name, **CLEAR_FIX.get(name, {})}],
                    "shadow": {"kind": "neutral", "opacity": 0.5},
                    "translucency": {"enabled": False, "value": 0.5}}
                   for name, _, glass in reversed(SPEC)],
        "supported-platforms": {"squares": "shared"},
    }, f, indent=2); f.write("\n")

preview = Image.new("RGBA", (1024, 1024), (0, 0, 0, 255))
for name, _, _ in SPEC: preview.alpha_composite(Image.fromarray(layers[name]))
os.makedirs(os.path.join(root, "design"), exist_ok=True)
preview.save(os.path.join(root, "design", "AppIcon-1024.png"))
print(f"wrote {icon_dir} from mood {n} ({mood_name})")
