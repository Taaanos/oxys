# V-19 spike · Lens correction in the system RAW decoder

Spike code: the `lens` command of `RawSpike` in `Packages/Imaging`. Re-run with:

```sh
cd Packages/Imaging && swift build -c release
.build/out/Products/Release/RawSpike lens <raw file> <output folder>
```

The command develops the file twice with the F-06 neutral settings, once with `isLensCorrectionEnabled` off and once with it on. It prints the support flag and the output extent, and it writes `lens-off.png` and `lens-on.png` at 1,600 px on the long edge.

Measured on a MacBook with Apple M4, macOS 27.0, one file: DJI FC8482 DNG (`DJI_20260823084729_0022_D.DNG`, 48.7 MP, wide-angle drone camera).

## Result

| | Correction off | Correction on |
| --- | --- | --- |
| `isLensCorrectionSupported` | yes | yes |
| Default of `isLensCorrectionEnabled` | | yes |
| `nativeSize` | 8064×6048 | 8064×6048 |
| Output extent (after orientation) | 6048×8064 | 6048×8064 |

- The decoder corrects this file. The correction comes from data inside the DNG, so no lens database is needed. ART uses a lens database (lensfun), which has no entry for this camera.
- The extent does not change. The content changes: the correction moves the picture toward the corners. The mountain and the stream are in different places in the two renders. We compared the renders by eye. We did not measure the shift in pixels.
- Core Image applies the correction by default for this camera. The embedded preview has the camera's correction in it. A side-by-side of Oxys and ART showed the same effect: the Oxys pane matched the corrected render, most likely because it showed the preview.
- V-02 switches the correction off, so that 1:1 shows sensor pixels. With the correction on, the decoder resamples, and 1:1 does not show sensor pixels.

## Effect on the preview-to-RAW zoom mapping

V-02 maps a zoom position between the preview and the RAW by fraction of the picture (exact at the centre).

- **Correction off (default):** the preview is corrected by the camera and the RAW is not. The mapped position is correct at the centre and wrong toward the edges. On the DJI file the shift looks like a few percent of the long edge at the extremes.
- **Correction on:** both images are corrected. We expect the mapped position to be close at all points. This is not measured.
- **AF point (V-01):** the camera writes the AF point in sensor coordinates, and Oxys maps it by the same fractions. It has the same error near the edges, and a larger one when the correction is on.
- **Decision (V-19):** the fraction mapping stays. The decoder does not give us its correction model, so an exact mapping is not possible. We document the error here and do not show it in the UI.

## Not checked

- Other cameras. Oxys reads `isLensCorrectionSupported` for each file when it develops it, so we keep no list of supported cameras.
- The size of the shift in pixels.
- The decode time with the correction on.
