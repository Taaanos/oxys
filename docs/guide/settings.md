# Settings

Press `⌘,` to open Settings. It has seven tabs: General, RAW, Memory, Editors, Peaking, Clipping, and Sidecars.

## General

- **Advance after rating, label or reject:** off by default. When it is on, hold `⇧` with a key to apply it and stay on the photo. `A` switches it on and off.
- **Show a RAW and its JPEG as one photo:** on by default. A RAW and a JPEG or HEIC with the same name in the same folder become one photo. You see the camera JPEG, and a rating goes to both files. Reveal in Finder selects both files. Switching this changes the open folder at once.

## RAW

**RAW decode** sets when Oxys decodes the full RAW. Without decoding, Oxys shows the preview.

| Mode | What happens |
| --- | --- |
| Never | Oxys shows previews only. |
| On demand (default) | `R` decodes one photo. `⇧R` switches to Always until you quit. |
| Always | Oxys decodes every RAW. It also decodes nearby photos in the background. |

**Automatic RAW at 1:1** is on by default. It works in On demand mode. When you zoom to 1:1 and the preview has fewer pixels than the sensor, Oxys decodes the RAW. Then 1:1 shows real sensor detail.

**Lens correction for RAW** is off by default. When it is on, the system decoder corrects the lens geometry in the decoded RAW, as the camera's own preview and most editors do. Applies only to cameras that the system decoder supports. Other cameras are not changed. With the correction on, 1:1 is resampled and does not show sensor pixels. When you change this setting, Oxys decodes the RAW on screen again. To see the result for the photo on screen, look at the **Lens correction** row in the inspector (`⌥⌘I`).

## Memory

**Frame cache** is the memory Oxys uses to keep decoded photos ready. Choose Automatic or Custom. Automatic is 2 GB, or one quarter of your RAM if that is less. On a Mac with little memory, choose a smaller size.

**Cached RAW frames** is how many developed RAWs stay in memory. Choose Automatic (5) or Custom (1 to 1000). The frame cache size is the higher limit: if the frames do not fit in it, the oldest ones go first, whatever the number is.

## Editors

This list holds the apps that `⌘E` and `⌥⌘E` can open photos in. Lightroom Classic, RawTherapee, and ART are in it already. Choose the default editor, add other apps, or remove the ones you added. An app that is not installed stays in the list but is dimmed. If you choose no default, `⌘E` uses the first installed editor.

## Peaking

- **Mode:** Edges or Fine detail. In Loupe, `⇧F` changes it.
- **Color:** magenta by default.
- **Sensitivity:** from Strict to Loose. Strict marks only the strongest edges. Loose also marks faint edges.

## Clipping

- The highlight percentage and the shadow percentage. The defaults are 98% and 2%. `⌥H` opens the same values.
- **Stripes instead of solid color:** Oxys draws the marks as stripes. You can see the photo through them.

Each of these two tabs has a **Reset to Defaults** button.

## Sidecars

**Sidecar name** sets the sidecar file name: `name.xmp` (Lightroom, FastRawViewer) or `name.ext.xmp` (darktable style). Set the XMP sidecar style in RawTherapee to match. See [Sidecars and other apps](sidecars.md).

## Appearance

The window follows the light or dark appearance of your Mac. The photo always has a neutral dark gray surround. The surround does not change how you see the exposure.
