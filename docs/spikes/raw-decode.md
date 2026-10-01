# F-06 · Honest RAW decode

Spike code: `Packages/Imaging` (`SharpnessMetric`, the `RawSpike` tool). Re-run with:

```sh
cd Packages/Imaging && swift build -c release
R=.build/out/Products/Release/RawSpike
$R flags|sharp|time <raw files...>      # support flags, default-vs-neutral sharpness, decode-to-texture time
$R compare <raw> <ref.tiff> <outdir>    # neutral CIRAWFilter against a reference decode (16-bit TIFF, no sharpening)
```

Measured on a MacBook with Apple M4, 24 GB, macOS 27.0, release build. 13 corpus files, 12 of them decodable RAWs.
The reference decoder was LibRaw 0.22.2 (`dcraw_emu -w -q 3 -6 -T`: camera white balance, AHD, no sharpening or noise reduction), installed locally as a test oracle only. Nothing from LibRaw is in the repo (G-2 is still open).

## "Neutral" CIRAWFilter

Neutral means sharpness, luminance and color noise reduction, detail, local tone mapping and moiré reduction at 0, with as-shot white balance and the filter's default tone (F-06/Q1).
`RawSpike flags` sets every control that is supported. A control that is unsupported counts as neutral only when its default is already 0.

**Result: every camera CIRAWFilter decodes can be made neutral.** Sharpness, both noise reductions, detail and moiré reduction are supported and settable on every decodable file. Local tone mapping is supported only on the iPhone ProRAW (default 1.0, set to 0); everywhere else it is unsupported with a default of 0.
Defaults are far from neutral: sharpness defaults to 0.5–1.0 and color noise reduction to 0.5 on every file, luminance noise reduction to 0.8 on the 7D, moiré reduction to 0.6–0.7 on the ARW and RAF.

## Per camera

Decode is `CIRAWFilter.outputImage` rendered into a private `rgba16Float` Metal texture and waited on. Median of 7 runs after one cold run; the filter is rebuilt each run; **file pages are warm**. "Sharpness" is the Laplacian variance of the central 1024×1024 crop, default over neutral (see the caveats below).

| Camera (file) | Format | MP | In `supportedCameraModels` | Neutral | Decode default / neutral | Sharpness default ÷ neutral |
| --- | --- | --- | --- | --- | --- | --- |
| Sony ZV-1 | ARW | 20.0 | yes | yes | 153 / 145 ms | 0.70 |
| Sony A7C II | ARW | 32.7 | yes | yes | 352 / 288 ms | 2.51 |
| Sony ZV-1 | DNG (lossy) | 20.0 | yes | yes | 92 / 68 ms | 2.07 |
| DJI FC8482 | DNG (uncompressed) | 48.8 | no, decodes as DNG | yes | 204 / 109 ms | 1.53 |
| iPhone 13 Pro | DNG (ProRAW) | 12.2 | no, decodes as DNG | yes | 178 / 174 ms | 4.25 |
| Canon EOS 7D | CR2 | 17.9 | yes | yes | 129 / 59 ms | 1.18 |
| Fujifilm X-M1 | RAF | 16.0 | yes | yes | 61 / 37 ms | 1.18 |
| Canon 5D Mark III (Adobe DNG) | DNG | 22.1 | yes | yes | 71 / 47 ms | 1.81 |
| Hasselblad L1D-20c | DNG | 19.9 | no, decodes as DNG | yes | 82 / 51 ms | 1.76 |
| Pentax K10D | PEF | 10.0 | yes | yes | 80 / 63 ms | 1.94 |
| DJI FC4382 | DNG | 12.1 | no, decodes as DNG | yes | not timed | 1.94 |
| DJI FC7303 | DNG | 9.0 | no, decodes as DNG | yes | not timed | 1.86 |
| Nikon Coolscan IV ED | "NEF" (uncompressed RGB) | 0.1 | no | **no: not a RAW** | – | – |
| Canon EOS R6 Mark III | CR3 | 12.4 | – | **not run** (file is not in `TestData/` here) | – | – |

- **`supportedCameraModels` is not a gate.** It lists 932 marketing names ("Sony Alpha ILCE-7C II"), while the EXIF model is "ILCE-7CM2", and DNG cameras (DJI, iPhone, Hasselblad L1D) decode through the DNG path whether listed or not. The test for "can we develop this" is whether `CIRAWFilter(imageURL:)` returns an image with the expected `nativeSize`.
- **The Coolscan file is a scan, not a RAW.** CIRAWFilter gives no image. Its only preview is uncompressed RGB (F-03), so it stays preview-only.
- **CIRAWFilter reads the file extension.** The raw.pixls.us files named `.tiff` returned only the embedded thumbnail (`nativeSize` 160×120, 256×171 and so on) until they were copied under their real extension (`.dng`, `.pef`). V-02 has to hand it the sniffed type. `CIRAWFilter(imageData:identifierHint:)` should do that but was **not tried**.
- Decode time with neutral settings is the same as or faster than with the defaults (no sharpening or noise-reduction passes). The slowest was 288 ms for the 33 MP compressed ARW; the biggest frame, 48.8 MP uncompressed, took 109 ms.
- **Not measured:** 61 MP. The corpus has nothing above 48.8 MP. A compressed 61 MP file will probably take around 0.5 s; that is an extrapolation, not a measurement. Cold-SSD and SD-card reads are also not covered.

## Against LibRaw at 1:1

`compare` crops the same 1024×1024 centre from both renderings and writes a side-by-side PNG. The two decoders use different tone curves, so the metric is the Laplacian variance divided by the luma variance (edge energy per unit of contrast).

| Camera | Mean luma CIRAWFilter / LibRaw | Normalised sharpness CIRAWFilter ÷ LibRaw |
| --- | --- | --- |
| Sony ZV-1 ARW | 0.35 / 0.33 | 0.10 (crop is smooth sky) |
| Sony A7C II | 0.30 / 0.15 | 0.33 |
| Sony ZV-1 DNG | 0.19 / 0.24 | 0.54 |
| DJI FC8482 | 0.14 / 0.14 | 0.58 |
| iPhone 13 Pro | 0.24 / 0.22 | 0.75 |
| Canon EOS 7D | 0.22 / 0.26 | 0.47 |
| Fujifilm X-M1 | 0.16 / 0.29 | 1.29 |
| Canon 5D Mark III | 0.25 / 0.20 | 0.82 |
| Hasselblad L1D-20c | 0.12 / 0.11 | 0.78 |
| Pentax K10D | 0.21 / 0.22 | 0.87 |
| DJI FC4382 | 0.01 / 0.01 | 0.87 |
| DJI FC7303 | 0.14 / 0.18 | 0.59 |

- Neutral CIRAWFilter is **never meaningfully sharper than LibRaw** (the one 1.29 is the X-M1, where the two tone renderings differ by almost 2× in mean luma). Equal-or-softer fits "nothing added".
- I looked at two side-by-sides (ZV-1 ARW and EOS 7D): at 1:1 they show the same detail, with CIRAWFilter slightly smoother in noise and chroma grain. A ratio of 0.5–0.9 is mostly that smoother grain, since the metric also counts noise as high-frequency energy. I did not tell apart "different demosaic" from "residual noise handling at amount 0".
- LibRaw's output includes the sensor's masked border (for example 5496×3672 against CIRAWFilter's 5472×3648), so the two crops are offset by up to 12 px. That is fine for a statistics comparison and makes a pixel diff meaningless, which is why no `|diff|` is reported.
- LibRaw wall time is 0.2–1.3 s per file with 16-bit TIFF output of up to 290 MB, so it says nothing about a decode into a texture and is not comparable with the table above.

**What the metric cannot do:** it is a ranking aid on one crop per file. Some centre crops are flat (sky) and measure grain, not detail. It does not prove the pipeline adds no sharpening. The default-versus-neutral column does show the controls work: with the defaults the same crop carries up to 4× the edge energy.

## Geometry against the embedded preview

- `CIRAWFilter.nativeSize` equals the full-sensor pixel size the embedded JPEG reports for every file where F-03 recorded one (A7C II 7008×4672, 7D 5184×3456, ZV-1 5472×3648, X-M1 4896×3264, 5D III 5760×3840, DJI 8064×6048). **No crop** is applied by CIRAWFilter relative to the preview.
- `outputImage.extent` is already **rotated** by the orientation tag (A7C II: native 7008×4672, tag 8, output 4672×7008; iPhone 4032×3024, tag 6, output 3024×4032). The embedded preview JPEG is stored unrotated and relies on the container tag. V-02 maps zoom positions between the two with that rotation, not with raw pixel coordinates.
- Lens correction is on by default for the ZV-1, DJI and X-M1 files. I left it on for these runs; the output extent still equalled `nativeSize`. Whether to switch it off for RAW mode (it resamples, and could shift geometry against the preview) is **not decided or measured**; V-02 should look at it.

## Decisions

1. **CIRAWFilter alone for v1.0; no LibRaw fallback.** Every decodable corpus file can be made neutral, decodes in under 0.3 s, and is never sharper than LibRaw. The only failure is a file that is not a RAW. V-04 is parked, and G-2 loses its LibRaw argument (LGPL-2.1 / CDDL-1.0) for v1.0. What would reopen it: a customer camera newer than the macOS in use, or a body where `CIRAWFilter(imageURL:)` returns no image.
2. **F-06/Q1: as-shot white balance and CIRAWFilter's default tone, with only detail processing switched off.** The default tone is camera-like, not flat, and mean luma differs from LibRaw's by up to 2× (A7C II: 0.30 against 0.15). V-07's clipping overlay must say it reports on the rendered pixels, not on the sensor data (L-02 covers sensor-level clipping).
3. Sniff the container before handing a file to CIRAWFilter; never trust the extension (adds to the M-01 note from F-03).
