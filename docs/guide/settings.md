# Settings

Press `⌘,` to open Settings. It has four tabs: General, Editors, Analysis, and Sidecars.

## General

**RAW decode** sets when Oxys decodes the full RAW. Without decoding, Oxys shows the preview.

| Mode | What happens |
| --- | --- |
| Never | Oxys shows previews only. |
| On demand (default) | `R` decodes one photo. `⇧R` switches to Always until you quit. |
| Always | Oxys decodes every RAW. It also decodes nearby photos in the background. |

**Automatic RAW at 1:1** is on by default. It works in On demand mode. When you zoom to 1:1 and the preview has fewer pixels than the sensor, Oxys decodes the RAW. Then 1:1 shows real sensor detail.

**Frame cache size** is the memory Oxys uses to keep decoded photos ready. Automatic is 2 GB, or one quarter of your RAM if that is less. To choose a size, turn Automatic off and use the slider. On a Mac with little memory, choose a smaller size.

**Extract exact bytes, without added EXIF** is off by default. `⇧⌘E` copies the largest embedded JPEG of each RAW. When the JPEG has no EXIF block, Oxys adds one with the RAW's orientation, camera, and capture time. The image data does not change. Turn this on to get the embedded bytes and nothing else. See [Extract embedded JPEGs](filtering.md#extract-embedded-jpegs).

## Editors

This list holds the apps that `⌘E` and `⌥⌘E` can open photos in. Lightroom Classic, RawTherapee, and ART are in it already. Choose the default editor, add other apps, or remove the ones you added. An app that is not installed stays in the list but is dimmed. If you choose no default, `⌘E` uses the first installed editor.

## Analysis

**Focus peaking**

- **Mode:** Edges or Fine detail. In Loupe, `⇧F` changes it.
- **Color:** magenta by default.
- **Sensitivity:** from Strict to Loose. Strict marks only the strongest edges. Loose also marks faint edges.

**Highlight and shadow clipping**

- The highlight percentage and the shadow percentage. The defaults are 98% and 2%. `⌥H` opens the same values.
- **Stripes instead of solid color:** Oxys draws the marks as stripes. You can see the photo through them.

Each section has a **Reset to Defaults** button.

## Sidecars

**Sidecar name** sets the sidecar file name: `name.xmp` (Lightroom, FastRawViewer) or `name.ext.xmp` (darktable style). Set the XMP sidecar style in RawTherapee to match. See [Sidecars and other apps](sidecars.md).

## Appearance

The window follows the light or dark appearance of your Mac. The photo always has a neutral dark gray surround. The surround does not change how you see the exposure.
