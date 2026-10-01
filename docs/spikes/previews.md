# F-03 · Locating embedded previews

Spike code: `Packages/Containers` (`PreviewLocator`, the `PreviewSpike` tool). Re-run with:

```sh
cd Packages/Containers && swift build -c release
PREVIEW_ORACLE=<path to a reference extractor> .build/out/Products/Release/PreviewSpike list|verify|bench ../../TestData/*   # PREVIEW_ORACLE is needed only for verify
```

14 files from 13 cameras. Measured on a MacBook with Apple M4, 24 GB, macOS 27.0, internal SSD, release build, median of 15 runs.
**All timings are warm** (file pages already in the page cache). Cold-SSD and SD-card numbers are **not measured**; see "Not covered".

## Corpus

| File | Camera | Format |
| --- | --- | --- |
| `DSC01014.ARW` | Sony ZV-1 | ARW (compressed) |
| `DSC09025.ARW` | Sony A7C II | ARW (JPEG-compressed raw, large JPEG in IFD2) |
| `DSC00204.dng` | Sony ZV-1 | DNG (lossy JPEG raw, JPEG XL previews) |
| `DJI_…_D.DNG` | DJI FC8482 | DNG (uncompressed raw) |
| `IMG_8248.DNG` | Apple iPhone 13 Pro | DNG (ProRAW, linear raw, semantic masks) |
| `Canon - EOS 7D … .CR2` | Canon EOS 7D | CR2 |
| `Canon - EOS R6 Mark III … .CR3` | Canon EOS R6 Mark III | CR3 |
| `Fujifilm - X-M1 … .RAF` | Fujifilm X-M1 | RAF |
| `Pentax - K10D … .tiff` | Pentax K10D | PEF (named `.tiff` by raw.pixls.us) |
| `Adobe DNG Converter - Canon EOS 5D Mark III … .tiff` | Canon 5D Mark III via Adobe DNG Converter | DNG (named `.tiff`) |
| `Hasselblad - L1D-20c … .tiff` | Hasselblad L1D-20c (DJI Mavic 2 Pro) | DNG (named `.tiff`) |
| `DJI - FC4382 … .tiff`, `DJI - FC7303 … .tiff` | DJI FC4382, FC7303 | DNG (named `.tiff`) |
| `Nikon - COOLSCAN IV ED … .tiff` | Nikon Coolscan IV ED (film scanner) | NEF (named `.tiff`); the only preview is uncompressed RGB |

Files from raw.pixls.us are named `.tiff` whatever they hold, so format detection has to sniff the header, not trust the extension (note for M-01).

## Result 1: byte-identical to the reference extractor

`PreviewSpike verify` compares every located JPEG with the bytes an independent reference extractor produces for the same location (oracle only, never a dependency; its path is passed in `PREVIEW_ORACLE`).
All **25** located JPEGs in the 14 corpus files are byte-identical. Exit code 0. One caveat: for the CR3 `PRVW`, the oracle appends two zero bytes after the JPEG's `FFD9` marker. Ours ends at the marker, which is the exact JPEG; the comparison tolerates trailing zero padding.

## Result 2: what each file holds, and read + decode time

Our parser's numbers: *locate* is mmap plus a header walk (about 0.03 ms for every file). *Read* copies the preview bytes out of the mapping. *Decode* is a full decode through `CGImageSourceCreateImageAtIndex`.

| Format | Camera | Preview | Size | Bytes | Read | Decode |
| --- | --- | --- | --- | --- | --- | --- |
| ARW | ZV-1 | IFD1 thumbnail | 160×120 | 3 KB | – | – |
| ARW | ZV-1 | IFD0 `PreviewImage` | 1616×1080 | 198 KB | 0.02 ms | 3.4 ms |
| ARW | A7C II | IFD1 thumbnail | 160×120 | 7 KB | – | – |
| ARW | A7C II | IFD0 `PreviewImage` | 1616×1080 | 169 KB | 0.01 ms | 3.3 ms |
| ARW | A7C II | IFD2 `JpgFromRaw` | 7008×4672 | 2.2 MB | 0.2 ms | **58–66 ms** |
| DNG | ZV-1 | SubIFD1 | 1024×683 | 80 KB | 0.00 ms | 0.9 ms |
| DNG | DJI | IFD0 | 160×120 | 15 KB | – | – |
| DNG | DJI | SubIFD1 | 960×720 | 684 KB | 0.04 ms | 4.3 ms |
| DNG | iPhone 13 Pro | IFD0 | 4032×3024 | 4.4 MB | 0.4 ms | 27 ms |
| DNG | 5D Mark III (Adobe) | SubIFD1 | 1024×683 | 48 KB | 0.00 ms | 0.7 ms |
| DNG | 5D Mark III (Adobe) | SubIFD2 `JpgFromRaw` | 5760×3840 | 1.2 MB | 0.1 ms | 43 ms |
| DNG | Hasselblad L1D-20c | IFD0 / SubIFD1 | 160×112 / 960×640 | 23 KB / 660 KB | 0.03 ms | 3.8 ms |
| DNG | DJI FC4382 | IFD0 / SubIFD1 | 160×120 / 960×720 | 15 KB / 676 KB | 0.03 ms | 4.0 ms |
| DNG | DJI FC7303 | IFD0 / SubIFD1 | 256×144 / 960×540 | 9 KB / 282 KB | 0.01 ms | 2.0 ms |
| CR2 | EOS 7D | IFD1 thumbnail | 160×120 | 16 KB | – | – |
| CR2 | EOS 7D | IFD0 | 5184×3456 (full size) | 2.2 MB | 0.2 ms | 35 ms |
| CR3 | EOS R6 Mark III | `THMB` | 160×120 | 19 KB | – | – |
| CR3 | EOS R6 Mark III | `PRVW` | 1620×1080 | 413 KB | 0.02 ms | 3.8 ms |
| CR3 | EOS R6 Mark III | `Track1` (in `mdat`) | 4320×2880 | 1.2 MB | 0.1 ms | 24 ms |
| RAF | X-M1 | JPEG at header offset | 1920×1280 | 794 KB | 0.05 ms | 5.3 ms |
| PEF | K10D | IFD1 thumbnail | 160×120 | 7 KB | – | – |
| PEF | K10D | IFD2 `JpgFromRaw` | 3872×2592 | 1.3 MB | 0.1 ms | 20 ms |
| NEF | Coolscan IV ED | none (`PreviewIFD` is uncompressed RGB) | – | – | – | – |

Not offered as previews, and why (the locator records these in `skipped`):

| File | Where | Reason |
| --- | --- | --- |
| ZV-1 DNG | IFD0 | Uncompressed 256×171 RGB pixels, not a JPEG |
| ZV-1 DNG | SubIFD2–4 | JPEG XL linear raw (reduced-resolution); no JPEG XL path |
| all | SubIFD (main) | The raw itself. In DNG it can be JPEG-compressed (lossless JPEG in tiles), so "has JPEG compression" does not mean "is a preview". Photometric CFA (32803) or Linear Raw (34892) is what excludes it |
| iPhone DNG | SubIFD1–3 | Semantic masks (photometric 52527, subfile type 4), JPEG-compressed but not pictures |
| EOS 7D CR2 | IFD3 | The raw: a 21 MB lossless JPEG (SOF3) strip. Caught by the first real CR2; the locator now rejects lossless JPEG (SOF3, 7, 11, 15) everywhere |
| EOS 7D CR2 | IFD2 | Uncompressed 670-px RGB pixels |
| Nikon Coolscan NEF | IFD0, SubIFD | Uncompressed RGB (the `PreviewIFD` in the maker note is also uncompressed) |

### Reduced-size decode (ImageIO on the extracted bytes)

| Source | 320 px | 1600 px | 2880 px |
| --- | --- | --- | --- |
| A7C II IFD2 7008×4672 | 17.7 ms | 35 ms | 64 ms |
| iPhone IFD0 4032×3024 | 16.7 ms | 18.4 ms | 22.6 ms |
| ZV-1 ARW IFD0 1616×1080 | 2.3 ms | 16 ms | – |

### ImageIO on the RAW file itself (`CGImageSourceCreateThumbnailAtIndex` on the URL)

| File | Reported image size | Thumb 320 | Thumb 2048 | Which preview it used |
| --- | --- | --- | --- | --- |
| ZV-1 ARW | 5472×3648 | 9.0 ms | 15.6 ms | IFD0 (1616×1080) |
| A7C II ARW | 7008×4672 | 8.5–9.7 ms | 14–16 ms | IFD0 (1080×1616); **never the 7008×4672 JPEG, even when asked for 8000 px** |
| ZV-1 DNG | 5472×3648 | 7.8 ms | 8.7 ms | SubIFD1 (1024×683) |
| DJI DNG | n/a | 9.2 ms | 11.5 ms | SubIFD1 (960×720) |
| iPhone DNG | 4032×3024 | 22 ms | 83 ms | IFD0 |
| EOS 7D CR2 | 5184×3456 | 20 ms | 37 ms | IFD0 (full-size JPEG, decoded and scaled) |
| R6 III CR3 | 4320×2880 | 14.5 ms | 28 ms | not stated |
| X-M1 RAF | 4896×3264 | 6.2 ms | 9.0 ms | the 1920×1280 JPEG |
| 5D III DNG | 5760×3840 | 32 ms | 54 ms | not stated |
| K10D PEF | – | – | – | **ImageIO opens no images at all; our locator finds the 3872×2592 JPEG** |

## Result 3: orientation, color space, ICC

- **Orientation.** In ARW every preview carries the main orientation tag (A7C II: 8 on all three). In DNG the reduced-resolution SubIFD previews carry **no orientation tag** (DJI SubIFD1, ZV-1 SubIFD1); the orientation lives in IFD0 only. So the rule for M-02: use the preview's own tag if present, else IFD0's. The iPhone's IFD0 preview also has an Exif orientation inside the JPEG (6), matching the tag.
- **ICC.** No preview in the corpus carries an ICC profile except the iPhone's. Treat "no ICC" as sRGB unless the file says otherwise.
- **Interoperability.** Both ARW bodies and the 7D write `InteroperabilityIndex = R98` (sRGB) and `ColorSpace = 1`. **No corpus camera writes `R03` (Adobe RGB)**, so that path is untested; `ContainerInfo.interopIndex` exposes it for M-02 to honor.
- **Orientation in CR2 and CR3.** CR2's IFD0 has the tag; IFD1 does not. CR3 JPEGs carry none; the orientation is in the `CMT1` box (a small TIFF). All corpus orientations except the A7C II (8) and the iPhone (6) are 1.
- **Embedded Exif in the JPEG.** Only the iPhone and Fujifilm JPEGs have an Exif segment (with orientation, agreeing with the container). The Sony, DJI, Canon, Pentax and Hasselblad previews have none, so orientation must come from the container.

## Decision

**Our own parser, for both browsing and extraction. ImageIO is used only to decode bytes we hand it.**

1. ImageIO's file-based thumbnail path cannot be the browse path. It reports the raw's size, not the preview's; it hides which preview it chose; and on the A7C II it never selects the 7008×4672 JPEG that our parser finds. It also fails outright on the Pentax PEF. It is 2–4× slower than our locate + read + decode of the same small preview (about 9 ms against 3–4 ms for a Grid-sized image) and 3× slower for the iPhone's 2048 px case (83 ms against 27 ms).
2. Extraction (V-13) needs the exact bytes, which ImageIO cannot give. One locator serves both, so there is one code path to trust.
3. Locate is about 0.03 ms and read under 0.5 ms for every file here; decode dominates, and ImageIO decodes extracted bytes well, including at reduced size.
4. No third-party code is needed for previews, so **G-2 (license) is not forced by F-03**. LibRaw only comes in for decoding the raw itself (F-06, V-04).

This answers open question 1 of the story: ImageIO's thumbnail path is not used for display.

## Consequences for later stories

- **M-02**: build the production `PreviewSource` on this locator (same classification rules and `skipped` reasons). Grid takes `smallestAdequate(longEdge:)`, Loupe takes `largest`.
- **M-12 (Grid)**: some bodies have nothing between the 160×120 thumbnail and the full-size JPEG (EOS 7D: 5184×3456, 35 ms full decode). For Grid, decode at reduced size from the extracted bytes (13.7 ms at 320 px on the 7D) instead of a full decode. Pick the preview by `smallestAdequate`, then decode at the cell size.
- **M-01**: sniff the container, not the extension; the pixls corpus is full of RAWs named `.tiff`.
- **M-04**: a full decode of a 33 MP preview (A7C II) takes about 60 ms on an M4, above the 50 ms next-image target. Decode at reduced size for fit-to-window (35 ms at 1600 px), or show the 1616×1080 IFD0 preview first and swap in the large one. This needs retesting on the slowest supported Mac (G-3).
- **M-14 / V-02**: the largest embedded JPEG may be the full sensor size (A7C II) or a few hundred KB at under 1 MP (ZV-1 DNG, 1024 px). The "preview is too small for 1:1" test must use the located pixel size, not the raw's.
- **V-05 (truth badge)**: record which IFD a preview came from; `EmbeddedJPEG.location` already does.

## Not covered (needs files or hardware we don't have)

- **Formats with no real corpus file:** ORF has none. RW2 stores its JPEG in a Panasonic-specific IFD0 tag (0x002E, an undefined-type blob), not the standard TIFF tags; the locator handles it and matches the oracle, but only on a tiny test stub (an 8×8 image from another tool's test set), not a real camera file. NEF has only a film-scanner file with no JPEG preview.
- **Maker-note preview IFDs** (Nikon `PreviewIFD`, Olympus, Pentax) are not walked. The Coolscan's `PreviewIFD` is uncompressed, and the K10D needed no maker note, so no corpus file shows whether a camera hides a JPEG preview only there. A real Nikon DSLR NEF would settle it.
- **Older CR3 bodies and other CR3 layouts:** one real CR3 (R6 Mark III) was checked. The locator reads `THMB`, `PRVW` and the JPEG track generically, but CR3 variants (for example CRM video files, or bodies with a 1620 px `PRVW` only) are untested.
- **Cold SSD and SD card timings.** Not measured: every run here is warm, and clearing the cache needs `sudo purge`. Run `sudo purge` before a bench to get one cold pass, and run the bench against a card-resident copy of the corpus.
- **Adobe RGB previews (`R03`)**: no corpus camera produces one.
- **A slow Mac** (G-3): numbers are from an M4.
