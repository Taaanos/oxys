# M-25: interoperability matrix (manual part)

Status: **ready to run. No results yet.**

Oxys must work with Lightroom Classic, RawTherapee and ART in both directions. A person must run the steps below (G-10). A person must also have a Lightroom Classic license. Do the steps in order. Write what each tool shows, not what you expect.

## Before you start

1. Build the app: `make build`.
2. Make the test folders: `scripts/make-xmp-kit.sh`. The folders are in `TestData/xmp-kit/`.
3. Get one file for each brand: Sony, Canon, Nikon, Fujifilm. Add one DNG. `TestData/` has no Nikon file yet. Ask before you download one (`scripts/corpus.tsv`).
4. Copy the files to a local disk. Do not use a card or a network share.
5. Use a new copy of the files for each tool. A sidecar from one tool must not affect the next tool.

## Part A: Oxys writes, the other tool reads

Do these steps for each tool and for each brand.

1. Open the folder in Oxys.
2. Photo 1: press `3`, then `6` (Red). Photo 2: press `5`, then `8` (Green). Photo 3: press `X` (reject). Photo 4: press `4` and `6`, then press `0` and `6` again (rating 0, no label). Wait 2 seconds.
3. Quit Oxys.
4. Open the same folder in the other tool.
   - **Lightroom Classic:** *Add* the folder, then select all photos and do *Metadata > Read Metadata from Files*.
   - **RawTherapee:** *Preferences > File Browser*. Turn on "Load/Save thumbnail rank and color from/to XMP sidecars". Set the XMP sidecar style to match the file name style. Write the exact words of each setting you change.
   - **ART:** Find the equivalent setting. Write its exact path and words.
5. Write the stars, the color and the reject state that the tool shows.

Also do these checks in Lightroom Classic:

- Use a custom color label set. Rename Red to "Approved". Write which color Lightroom shows for a sidecar with `xmp:Label="Red"`.
- Use `MetadataDate`. Open `TestData/xmp-kit/E-date`. Replace `date-test.xmp` with each version below. After each change, do *Read Metadata from Files*. Write the rating Lightroom shows. Write if it asks about a conflict.

  | Version | Content | Question |
  | --- | --- | --- |
  | v2-newer-date | 4 stars, later date | Does it change to 4 stars? |
  | v3-same-date | 5 stars, same date | Does it stay at 4 stars? |
  | v4-no-date | 2 stars, no date | What does it show? |

  The answer decides if Oxys must keep writing `MetadataDate`.
- Use a DNG and a JPEG. Write if Lightroom reads the sidecar or only the XMP inside the file (G-8).

## Part B: the other tool writes, Oxys reads

Do these steps for each tool and for each brand.

1. In the other tool, give 3 stars and Red to photo 1. Give 5 stars and Green to photo 2. Reject photo 3.
2. Save the metadata to files (Lightroom: `Cmd+S`. RawTherapee and ART save on change).
3. For Lightroom: also change Exposure and add a crop on photo 1 before you save. This gives the sidecar Camera Raw settings.
4. Open the folder in Oxys. Write the stars, the color and the reject state that Oxys shows.
5. Copy each `.xmp` file to `docs/m25-sidecars/<tool>-<version>/`. Do not edit the files.

## Part C: Oxys edits a sidecar that has Camera Raw settings

1. Use the Lightroom sidecar from Part B (photo 1, with Exposure and crop).
2. Copy it. Keep the copy as `before.xmp`.
3. In Oxys, change the rating and label of the photo. Wait 2 seconds.
4. Run `diff before.xmp <the sidecar>`.
5. The diff must show changes only in `xmp:Rating`, `xmp:Label` and `xmp:MetadataDate`. Open the photo in Lightroom. The Exposure and crop must be unchanged.
6. Put the real sidecar in `Packages/Sidecar/Tests/Fixtures/xmp/lightroom-classic-<version>/`. Add it to `allFixtures` in `SidecarWriteTests.swift`.

## Results

Reader table (the other tool reads Oxys sidecars):

| Tool and version | Brand | Stars | Color | Reject | Notes |
| --- | --- | --- | --- | --- | --- |
| Lightroom Classic | | | | | |
| RawTherapee | | | | | |
| ART | | | | | |

Writer table (Oxys reads the sidecars of the other tool):

| Tool and version | Brand | Stars | Color | Reject | Notes |
| --- | --- | --- | --- | --- | --- |
| Lightroom Classic | | | | | |
| RawTherapee | | | | | |
| ART | | | | | |

Open points to close:

- [ ] `MetadataDate`: needed or not needed.
- [ ] Custom Lightroom color label sets.
- [ ] Reject: how each tool shows and writes `xmp:Rating="-1"`.
- [ ] DNG, TIFF and JPEG in Lightroom (G-8).
- [ ] Part C diff is clean.

## Pass rule

The story passes when every cell for Lightroom Classic and RawTherapee shows the expected value. ART results must be in the table. They do not need to pass.
