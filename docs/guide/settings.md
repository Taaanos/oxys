# Settings

Press `⌘,` to open Settings. It has three tabs.

## General

**RAW decode** sets when Oxys decodes the full RAW. Without decoding, Oxys shows the preview.

| Mode | What happens |
| --- | --- |
| Never | Oxys shows previews only. |
| On demand (default) | `R` decodes one photo. `⇧R` switches to Always until you quit. |
| Always | Oxys decodes every RAW. It also decodes nearby photos in the background. |

**Automatic RAW at 1:1** is on by default. It works in On demand mode. When you zoom to 1:1 and the preview has fewer pixels than the sensor, Oxys decodes the RAW. Then 1:1 shows real sensor detail.

**Frame cache size** is the memory Oxys uses to keep decoded photos ready. Automatic is 2 GB, or one quarter of your RAM if that is less. To choose a size, turn Automatic off and use the slider. On a Mac with little memory, choose a smaller size.

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
