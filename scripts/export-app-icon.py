#!/usr/bin/env python3
"""Export a potoo mood to a layered Icon Composer file: App/Oxys/AppIcon.icon.

macOS 26 and later draw the icon tile, shadow and glass themselves, so the file holds a flat
black fill and one transparent, full-bleed bird layer (the 824 px tile of the design, scaled
to the whole 1024 px canvas). The layer is matted from two renders, on black and on white,
because qlmanage cannot render transparency. The artwork is centred horizontally. Also writes design/AppIcon-1024.png as a preview.
Needs pillow, numpy and macOS qlmanage. Usage: scripts/export-app-icon.py [mood number, default 7]
"""
import importlib.util, json, os, shutil, subprocess, sys, tempfile
import numpy as np
from PIL import Image

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("moods", os.path.join(root, "scripts", "make-icon-moods.py"))
moods = importlib.util.module_from_spec(spec); spec.loader.exec_module(moods)

n = int(sys.argv[1]) if len(sys.argv) > 1 else 7
name, mood = moods.MOODS[n - 1]
body = moods.bird(mood)
tmp = tempfile.mkdtemp()

def render(bg):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="100 100 824 824" width="1024" height="1024">'
           f'<rect x="100" y="100" width="824" height="824" fill="{bg}"/>{body}</svg>')
    path = os.path.join(tmp, f"layer-{bg[1:]}.svg"); open(path, "w").write(svg)
    subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, path], capture_output=True, check=True)
    return np.asarray(Image.open(path + ".png").convert("RGB"), float)

black, white = render("#000000"), render("#ffffff")
alpha = np.clip(1 - (white - black).mean(axis=2) / 255, 0, 1)
color = np.where(alpha[..., None] > 0.003, black / np.maximum(alpha[..., None], 0.003), 0)
layer = np.dstack([np.clip(color, 0, 255), alpha * 255]).astype("uint8")

# Centre the artwork (dots and beak included) horizontally, so the black margins match.
cols = np.where((layer[..., 3] > 50).any(axis=0))[0]
dx = 512 - (int(cols.min()) + int(cols.max())) // 2
layer = np.roll(layer, dx, axis=1)
if dx > 0: layer[:, :dx] = 0
elif dx < 0: layer[:, dx:] = 0
print(f"centred horizontally: shifted {dx} px (left margin {cols.min() + dx}, right margin {1023 - cols.max() - dx})")

icon_dir = os.path.join(root, "App", "Oxys", "AppIcon.icon")
shutil.rmtree(icon_dir, ignore_errors=True)
os.makedirs(os.path.join(icon_dir, "Assets"))
Image.fromarray(layer, "RGBA").save(os.path.join(icon_dir, "Assets", "bird.png"))
with open(os.path.join(icon_dir, "icon.json"), "w") as f:
    json.dump({
        "fill": {"solid": "srgb:0.00000,0.00000,0.00000,1.00000"},
        "groups": [{"layers": [{"glass": True, "image-name": "bird.png", "name": "bird"}],
                    "shadow": {"kind": "neutral", "opacity": 0.5},
                    "translucency": {"enabled": False, "value": 0.5}}],
        "supported-platforms": {"squares": "shared"},
    }, f, indent=2); f.write("\n")

preview = Image.new("RGBA", (1024, 1024), (0, 0, 0, 255)); preview.alpha_composite(Image.fromarray(layer, "RGBA"))
os.makedirs(os.path.join(root, "design"), exist_ok=True)
preview.save(os.path.join(root, "design", "AppIcon-1024.png"))
print(f"wrote {icon_dir} from mood {n} ({name})")
