# Sidecars and other apps

## What Oxys saves

Oxys saves each rating, label, and reject in an **XMP sidecar**. A sidecar is a small text file next to the photo. The sidecar for `IMG_0042.ARW` is `IMG_0042.xmp`.

| Choice | Saved as |
| --- | --- |
| 1 to 5 stars | `xmp:Rating` = 1 to 5 |
| No rating | `xmp:Rating` = 0 |
| Reject | `xmp:Rating` = -1 (the Adobe Bridge way) |
| Color | `xmp:Label` = `Red`, `Yellow`, `Green`, `Blue`, or `Purple`. No label removes the property. |

Oxys follows these rules:

- **It never changes your original files.** It writes only sidecars.
- **It makes a sidecar at your first choice for a photo.** If you only look at photos, it makes nothing.
- **It keeps other data.** If a sidecar has Lightroom or Camera Raw settings, Oxys changes only its own properties.
- **It writes in a safe way.** Oxys writes a temporary file and then renames it. A crash never leaves half a sidecar. For a short time, a hidden temporary file is in the folder.
- **It never makes you wait.** The badge shows at once. The write runs in the background.
- **It never overwrites a damaged sidecar.** Oxys keeps your choice in memory. It shows a banner and tells you in the inspector.

Press `⌥⌘I` to open the inspector. It shows which sidecar a photo uses. It also shows if Oxys saved the choice. If not, the info line says "Not saved yet".

## Sidecar names

By default, the sidecar for `IMG_0042.ARW` is `IMG_0042.xmp`. Lightroom Classic and FastRawViewer use this name. Some tools, for example darktable, use `IMG_0042.ARW.xmp`. Choose the name in **Settings ▸ Sidecars**.

- Oxys does not rename existing sidecars.
- If a photo has a sidecar with the other name, Oxys keeps that file.
- Oxys uses your chosen name for new sidecars.

## When another program changes a sidecar

Lightroom, RawTherapee, or another tool can change a sidecar while Oxys has the folder open. Oxys sees the change. It reloads the sidecar before the next write. It merges property by property. If the other tool changed the label, Oxys keeps that change and your stars.

## If Oxys cannot save

A locked SD card, a read-only network share, or a full disk can stop the save. Oxys shows one banner. The banner does not block you. You can continue to cull. Oxys keeps your choices in memory.

- **Retry** tries again. Oxys also tries again when you return to the app.
- **Save Decisions To…** (`⇧⌘S`, or in the banner) writes only the sidecars to a folder you choose. Later, move them next to the photos. Keep the same names. The banner tells you where Oxys put them.

> **Warning:** If you quit before Oxys saves a choice, you lose it. Solve the banner before you close the window.

## Use Oxys with other programs

| Program | Stars | Colors | Reject | What to do |
| --- | --- | --- | --- | --- |
| **Lightroom Classic** | Yes | Yes | Not confirmed | See below. |
| **RawTherapee 5.11 or later** | Yes | Yes | No | Turn on one setting. See below. |
| **RawTherapee 5.10 or earlier** | No | No | No | Install a newer version. |
| **ART** | Yes | Yes | Yes (as trash) | Check the metadata settings in ART. |

### Lightroom Classic

- The photos must be on your disk first. Copy them from the card. Then add the folder. If you import straight from a card, Lightroom does not read the sidecars.
- For photos already in the catalog, select them. Then choose **Metadata ▸ Read Metadata from Files**.
- **JPEG, HEIC, TIFF, and DNG are different.** Lightroom keeps metadata inside these files. It can ignore a sidecar next to them. Oxys still saves your choices in the sidecar. Lightroom can show no stars for these formats.

### RawTherapee

1. Open **Preferences ▸ File Browser**.
2. Turn on "Load/Save thumbnail rank and color from/to XMP sidecars".
3. Set **XMP sidecar style** to match Oxys:
   - Choose Adobe if Oxys uses `name.xmp`.
   - Choose darktable if Oxys uses `name.ext.xmp`.

RawTherapee keeps its trash state outside XMP. It ignores a rating of -1. A reject from Oxys does not show in RawTherapee.

### ART

ART reads sidecars. Check the metadata settings in ART. Make the sidecar names match.

### About testing

We tested the sidecar format with ART. We did not finish the tests with Lightroom Classic and RawTherapee. The table above comes from the documentation of those programs. If a program shows something different, trust the program. Then [tell us](troubleshooting.md#report-a-problem).
