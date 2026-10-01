# F-04: XMP interoperability

Status: **closed as done on ART alone (the story is marked done; the open items below are picked up later). Kit ready, ART read and write runs done, RawTherapee pending. Lightroom Classic is deferred** (no license available now; it is tested with users once the app writes sidecars, as part of M-25). G-10: the GUI steps are run by hand from this checklist, the files they write come back for analysis.

Build the test folders with `scripts/make-xmp-kit.sh` (writes `TestData/xmp-kit/`, git-ignored; clones the RAWs, writes the sidecars). Every file name says what its sidecar holds, so a wrong reading is obvious.

| Folder | Tests |
| --- | --- |
| `A-stem` | `name.xmp` naming: Sony 3★ Red, Canon 5★ Green, Fuji reject (-1), DNG 2★ Blue |
| `B-fullname` | `name.ext.xmp` naming: Sony 4★ Yellow, Canon 1★ Purple, Fuji 0★ no label, DNG reject |
| `C-forms` | Same values (4★ Blue) as attributes, child elements, `xap:` prefix, mixed |
| `D-labels` | Label strings `Red`, `red`, `RED`, `Approved`, `Review`, `Second`, empty |
| `E-date` | `MetadataDate` test: four sidecar versions to swap in |

**Gap: no Nikon RAW.** The story wants Sony, Canon, Nikon, Fujifilm and a DNG. `TestData/` has no NEF; one can come from raw.pixls.us via `scripts/corpus.tsv` (needs your OK to download), or use one of your own.

## Checklist

Record every result in the tables below: what the tool showed (stars, label color, reject/trash), not what you expected.

### 1. Read direction (our sidecars into each tool)

For each tool: A-stem, B-fullname, C-forms, D-labels.

- **Lightroom Classic (deferred, see M-25).** Import the folder with *Add* (copy the folder to a local disk first, not from a card). Note stars, color, and any flag. Check *Metadata → Read Metadata from Files* afterwards on a photo that was imported before the sidecar existed (use a second copy of the folder: import it first, then run `make-xmp-kit.sh`'s sidecars over it).
  - Repeat with the default color label set and again with a custom set (Metadata → Color Label Set → Edit) that renames Red to "Approved". Which D-labels file shows which color?
  - For the DNG and any JPEG: does it read the sidecar or only the embedded XMP?
- **RawTherapee (latest).** Preferences → File Browser → tick "Load/Save thumbnail rank and color from/to XMP sidecars". Set "XMP sidecar style" to *Adobe* for A-stem and *darktable* for B-fullname. Record the exact wording of each setting you touched. Also record what happens with the setting at its default (off), and with a style that does not match the folder.
- **ART (latest).** Find the equivalent preference and record its exact path and wording. Open the same folders. Does -1 show as trash?

### 2. `MetadataDate` (E-date) — Lightroom only, deferred

In Lightroom: import `E-date` with `date-test.xmp` = v1. Then, each time, replace `date-test.xmp` with a copy of the version below and run *Read Metadata from Files*; record the rating Lightroom shows and whether it asks about a conflict.

| Replace with | Expect if the date matters |
| --- | --- |
| v2-newer-date (4★, later date) | updates to 4★ |
| v3-same-date (5★, same date as v1) | stays 4★ |
| v4-no-date (2★, no date) | ? |

Also: with *Automatically write changes into XMP* off, does Lightroom ever notice a changed sidecar without Read Metadata from Files?

### 3. Write direction (each tool's own sidecars)

For each tool, on a fresh clone of the corpus RAWs (one per vendor plus DNG) with no sidecar: set 3★ + Red on one, 5★ + Green on another, 0 stars with no label after setting both on a third (clear them again), reject on a fourth. Save metadata (Lightroom: ⌘S / *Save Metadata to Files*; RawTherapee and ART write on change). Copy the produced `.xmp` files back, unedited, with a note of tool, version and what you did.

Develop-settings fixture: with no Lightroom, make it in ART (change Exposure and add a crop, so the sidecar holds foreign data to preserve). A real Lightroom sidecar is collected at M-25; until then M-07 and M-08 tests use hand-written `crs:` content too.

### 4. Reject

For each tool: does a sidecar with `xmp:Rating="-1"` show as rejected, as 0 stars, or nothing? In reverse, what does each tool write when you reject (Lightroom flags it in the catalog and writes `xmp:Rating="-1"`? or `crs:` / `lr:` data?).

## Results (to fill in)

### Reader table

| Reader | name.xmp | name.ext.xmp | Stars | Colors | Reject (-1) | DNG | JPEG | Condition and exact preference steps |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Lightroom Classic | untested | untested | untested | untested | untested | untested | untested | Deferred to M-25. Behavior from the PRD (FastRawViewer's manual) is unverified |
| RawTherapee (version) | | | | | | | | |
| ART (version) | | | | | | | | |

### Decisions to record

- Rating 0 vs no property: write `0`. No label: remove `xmp:Label` (provisional, ART evidence only; ART itself writes an empty label). 
- No label: no property vs empty: 
- `MetadataDate`: needed? (deferred: Lightroom only; keep writing it until M-25 shows it is unneeded) 
- Custom Lightroom label sets: (deferred to M-25)
- Reject in ART (F-04/Q2; Lightroom deferred to M-25): 
- G-8 (DNG, TIFF, JPEG in Lightroom): deferred to M-25; ART and RawTherapee DNG behavior is recorded in the reader table

### Fixtures

Fixture sidecars go under `Packages/Sidecar/Tests/Fixtures/xmp/<tool>-<version>/` (the Sidecar package owns the M-07 tests; this replaces the story's `Tests/Fixtures/xmp/`). Collect one example each of attribute form, child-element form and `xap:` prefix for M-07.

## ART 1.26.7 findings (macOS)

Read direction (screenshots, sidecar naming `name.xmp`):
- Reads `xmp:Rating` / `xmp:Label` written as attributes, as child elements, with the `xap:` prefix, and mixed (C-forms, all four showed Blue).
- Label matching is exact and case-sensitive: `Red` shows red; `red`, `RED`, `Approved`, `Review`, `Second` show no label.
- A sidecar without a stem collision (`name.xmp` for `name.ARW`) is read; `name.ext.xmp` (B-fullname) not yet tested. Preference wording and default: pending.

Write direction (`Packages/Sidecar/Tests/Fixtures/xmp/art-1.26.7/`):

| ART action | Sidecar result |
| --- | --- |
| Rate 3 + Red on a file with no sidecar | Creates `<stem>.xmp` with `xmp:Rating="3" xmp:Label="Red"`; no `MetadataDate` |
| Change rating and label on an existing sidecar | Edits it in place (Exiv2): attributes `Rating="5" Label="Yellow"`; `MetadataDate` left at its old value; `<?xpacket?>` wrapper dropped; attributes reformatted one per line |
| Clear stars and label | `xmp:Rating="0"` and `xmp:Label=""` (empty), both kept |
| Move to trash | `xmp:Rating="-1"`, `xmp:Label` kept. Confirms the PRD's claim that ART maps trash to -1 |
| Change Exposure (+2.89) and other develop settings | Not in the `.xmp` (left untouched); everything goes to `<name>.<ext>.arp` |

ART also writes `<name>.<ext>.arp` (12 KB, INI format) next to the RAW for any edit, including `InTrash` and `ColorLabel` keys that were `false` and `0` here even for the trashed Red file, so the `.arp` does not mirror our properties. Oxys must ignore `.arp` files and never write them.

Consequence: ART's own sidecars contain no foreign develop data, so the "preserve foreign data" fixture for M-08 has to come from Lightroom (M-25) or hand-written `crs:` content.

### Open items (picked up later)

- RawTherapee 5.13: read and write results, and the exact preference wording.
- ART: preference path and default, `name.ext.xmp` (B-fullname), `fuji-reject` and `label-7-empty`.
- Nikon RAW (none in `TestData/`).
- Lightroom Classic: everything, at M-25.
