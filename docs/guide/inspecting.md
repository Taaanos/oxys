# Check sharpness and exposure

These tools work in Loupe. Most of them also work in Compare.

## Zoom to 1:1

Press `Z` to zoom to 1:1. At 1:1, one image pixel uses one screen pixel. On a Retina display, you see the real detail from the sensor. Press `Z` again to return to Fit.

`Z` has two modes:

- **Tap** it to change between Fit and 1:1.
- **Hold** it to see 1:1 only while the key is down. When you release the key, you return to Fit.

| Key | Action |
| --- | --- |
| `Z` | Fit or 1:1 (tap or hold). |
| `⌘1` | Go to 1:1. |
| `⌘0` | Go to Fit. |
| `=` `-` | Zoom steps: Fit, 25%, 50%, 100%, 200%, 400%. |
| `⌘+` `⌘-` | The same steps in all views. |
| `⌥` + arrow | Pan one quarter of the view. |
| `⌥⇧` + arrow | Pan one full view. |
| `⌥Z` | Keep zoom for the next photo: on or off. |

You can also pinch or press `⌥` and scroll to zoom at the pointer. Scroll with two fingers, or drag, to pan. Bare arrow keys always change the photo. Panning never takes a cull key.

**Keep zoom** is on by default. You zoom in on a face. You go to the next photo. You see the same place. Press `⌥Z` to turn it off.

## The badge: what you see

The preview inside a RAW file is often smaller than the sensor image. If you zoom to 1:1 on a small preview, you do not see sensor detail. The badge tells you what you see.

| Badge | Meaning |
| --- | --- |
| `Preview 1616 px` | The preview, at or below its own size. |
| `Preview enlarged 2.4×` ⚠ | The preview is larger than 100%. It looks soft. |
| `Preview 1:1, not sensor pixels` ⚠ | The preview has fewer pixels than the sensor. |
| `Developing` ⚠ | Oxys decodes the RAW. The preview stays on screen. |
| `RAW`, `RAW 1:1` | The decoded RAW. At 1:1, each pixel is a sensor pixel. |
| `Full file`, `1:1` | A JPEG, HEIC, or TIFF. Oxys shows the file itself. |

A warning (⚠) means: do not judge sharpness from this view.

## Decode the RAW

| Key | Action |
| --- | --- |
| `R` | Show the decoded RAW. Press again to show the preview. Press `R` during decoding to cancel. |
| `⇧R` | Decode every RAW in this session. Press again to stop. |

Oxys decodes the RAW with sharpening and noise reduction off. You see what the sensor recorded. The preview stays on screen until the RAW is ready. If you go to another photo, Oxys cancels the decoding.

The mode is in **Settings ▸ General ▸ RAW decode**:

- **Never:** Oxys shows previews only. `R` and `⇧R` do nothing.
- **On demand** (default): `R` decodes one photo. If **Automatic RAW at 1:1** is on, Oxys also decodes when you zoom to 1:1 and the preview is too small.
- **Always:** Oxys decodes every RAW. It also decodes the nearby photos in the background.

## Focus peaking

Press `F` to mark the parts that are in focus.

- **Tap** `F` to turn peaking on or off. **Hold** `F` to see it only while you press the key.
- Press `⇧F` to change the mode. **Edges** marks the outlines of sharp areas. **Fine detail** marks small detail and texture. It also shows more noise. If peaking is off, `⇧F` turns it on.
- Change the color and sensitivity in **Settings ▸ Analysis**. The default color is magenta. Magenta is rare in photos.

The badge shows if the marks come from the preview or from the RAW.

## Highlight and shadow clipping

| Key | Action |
| --- | --- |
| `H` | Mark blown highlights in red. Tap or hold. |
| `S` | Mark blocked shadows in blue. Tap or hold. |
| `⌥H` | Open the threshold panel. |

A pixel is a highlight when any channel is at or above the highlight threshold. A pixel is a shadow when all channels are at or below the shadow threshold. The defaults are 98% and 2%. Change them in steps of 1%.

A readout shows how much of the photo is clipped. It also shows the source of the data. Small blown spots stay visible when you zoom out. To see the photo through the marks, turn on **Stripes instead of solid color** in Settings ▸ Analysis.

## Information on the photo

Press `I` to change what Oxys shows on the photo:

1. Nothing.
2. File name and stars.
3. File name, stars, and EXIF values.
4. All of the above and a histogram.

Press `⇧I` to show or hide only the histogram. The histogram shows luminance and RGB. It marks clipping at both ends. It also says if the data comes from the preview or from the RAW.

## Inspector

Press `⌥⌘I` to open the inspector. It shows the histogram, the full EXIF list, and the sidecar state. The sidecar state tells you which file holds your choices and if Oxys saved them. You can select and copy each value. Press `⌃⌘I` to move the keyboard to the inspector.

## EXIF

Oxys reads EXIF without decoding the image. The values show at once. They include camera, lens, focal length, aperture, shutter speed, ISO, exposure compensation, white balance, metering, flash, capture time, size, GPS, and focus data. Lens and focus data come from the maker note. Oxys reads them for Sony, Canon, and Fujifilm, and for other makes where the format allows.

In Loupe, press `↑` or `↓` to go through the values. Press `⌘C` to copy the selected value. If no value is selected, `⌘C` copies all values. If the photo has GPS data, choose **View ▸ Show in Maps**.
