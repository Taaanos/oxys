# MVP performance gate (M-26)

Measured on 2 Oct 2026 with `scripts/perf-bench.sh` (the in-app driver in `App/Oxys/PerfBench.swift`) on the Release build.

## Setup and limits

- **Mac:** Apple M4, 24 GB, internal SSD, 60 Hz display, macOS 27. **This is not the slowest supported Mac.** G-3 names a base M1 with 8 GB; none was available. Every number below is an M4 number, and the M1 is not measured.
- **Slow media (G-11):** SD card and network share were **not measured** (no media at hand). The gate does not depend on them (they report only), but the "never a stale frame" rule on slow media is unchecked.
- **Test sets** (`make bench-folders`): `24mp-1000` and `hires-1000` are 1,000 APFS clones of the 14 corpus files, `scan-5000`, `grid-10000`. Clones share data blocks, so the OS file cache is warmer than for 1,000 different files. The numbers for next image are therefore a little better than a real shoot would give. Real 1,000-frame shoots are still open (F-02/Q2).
- **Method:** the driver opens the folder, then calls the same commands as the keys (`nav.next`, `zoom.actual`, `cull.rate.*`) and writes every signpost interval to a file (`OXYS_PERF_LOG`). `PerfTool log` prints p50 and p95 (nearest rank). The key router is skipped; `key-to-frame` starts inside the navigate command, as in the app. Memory is the process `phys_footprint`, sampled every 250 ms.
- **Held key:** in a held-key run a frame that a newer key press replaces ends its interval at once. So its `key-to-frame` p95 (36 ms) is not a latency figure. The prefetched and cold runs (one step at a time) are.

## Results

| Target | Measured | Result | Fix for a miss |
| --- | --- | --- | --- |
| Launch to empty window, under 1 s | 276–306 ms (5 cold launches) | pass | |
| Folder open to first image, under 300 ms | 183–253 ms to the first preview in Loupe (24 MP, 1,000 files); Grid first screen 156 ms | pass | |
| Folder scan, 5,000 files with capture times, under 3 s | list in 82 ms, capture times 3.7 s | **fail** (list pass) | Capture times are read in the background after the list is shown, so the user is not blocked. Read them with more parallelism (now one pass) or cache them by path, size and date. Needs its own story. |
| Next image, prefetched, p95 under 50 ms | 45 ms (24 MP), 45 ms (hires set) | pass | |
| Next image, cold, p95 under 100 ms | 232 ms (24 MP; was 296 before the histogram moved beside the upload), 72 ms (hires set) | **fail** for the 24 MP set | A cold frame costs read, decode (about 100 ms), texture upload (about 30–50 ms). Show a screen-size decode first and the 8192 px frame after, and upload without the mip chain until the frame is idle. Needs its own story. |
| No stale frame under held key | 0 stale of 395, 397 and 1,007 logged frames (held at 30 Hz, and 10 Hz for 1,000 frames) | pass | |
| Cull key to feedback, within 16 ms | p50 16 ms, p95 41 ms (300 decisions, each followed by a step) | **fail** at p95 | The slow samples coincide with a frame load on the same main thread (texture upload runs there). Move the upload off the main thread or end the interval before the frame work starts. |
| Overlay toggles (histogram, info), within one display frame | histogram p50 17 ms, p95 23 ms; info p50 19 ms, p95 36 ms (to the next display tick) | **fail** at p95 (marginal) | As for cull feedback. Focus peaking and the highlight overlays do not exist yet (V-stories). |
| Zoom to 1:1, within one display frame | p50 27 ms, p95 36 ms | **fail** | The zoom re-renders a 24 MP texture on the main thread. Measure after the main-thread fix above, then look at the draw path. |
| Grid scrolling, 60 fps with 10,000 files | 3,312 ticks, every one at 16.67 ms, none dropped (second pass, thumbnails from the disk cache, 6,000 pt/s); the first pass, which makes the thumbnails, dropped frames (max 143 ms) | pass | |
| Sidecar write never blocks input | `make sidecar-stress`: 1,000 decisions in 60 s, 0 wrong, 0 temp files; during the cull run a write takes p50 6 ms, p95 8 ms | pass | |
| Memory, prefetch cache within its 2 GB budget | peak footprint 3.4 GB in a held scrub (400 frames), 3.4 GB in a 1,000-frame scrub; was 3.9 GB and 4.6 GB before the fix below. 1.5–1.9 GB remain after the scrub | **fail** | See below. |
| Idle, 0% CPU | 0.18% in Loupe, 0.01% in Grid (30 s each, nothing changing) | pass | The 0.18% in Loupe is small but not zero; find what wakes the process. |
| Full RAW decode, extraction | not MVP (V-02, V-14) | n/a | |

## Changes made in this story

- `Perf` writes every interval to `OXYS_PERF_LOG` when set; `PerfTool log` prints the table. This replaces Instruments for the gate (`perf-record.sh --report` still does not return on the old trace).
- `FramePipeline(transientFactor:)`: while frames load, the cache gives up the working memory of those loads (2.5 times a frame's cost), so the budget covers cache and loads together. The footprint peak fell by 0.5–1.2 GB.
- The histogram runs beside the texture upload. Cold frame load p50 fell from 184 ms to 137 ms.

## Memory: what is left

The cache is within its budget, but the process is not. Each 24 MP frame at 8192 px needs about 600 MB while it loads (decoded image, upload buffer, texture), up to three load at once, and cancelled loads finish their upload because the upload cannot be cancelled. Also the heap keeps what it freed (1.5–1.9 GB after the scrub). Options for a follow-up: decode at most to the screen's pixel size times 2 unless zoomed; load one frame at a time while the key is held; call `malloc_zone_pressure_relief` after a scrub.
