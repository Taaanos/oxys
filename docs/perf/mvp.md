# MVP performance gate (M-26)

Measured on 2 Oct 2026 with `scripts/perf-bench.sh` (the in-app driver in `App/Oxys/PerfBench.swift`) on the Release build.

## Setup and limits

- **Mac:** Apple M4, 24 GB, internal SSD, 60 Hz display, macOS 27. **This is not the slowest supported Mac.** G-3 names a base M1 with 8 GB; none was available. Every number below is an M4 number, and the M1 is not measured.
- **Slow media (G-11):** SD card and network share were **not measured** (no media at hand). The gate does not depend on them (they report only), but the "never a stale frame" rule on slow media is unchecked.
- **Test sets** (`make bench-folders`): `24mp-1000` is 1,000 APFS clones of **5** corpus files (two ARW, one DNG, two TIFF scans, 18–33 MP), `hires-1000` is 1,000 clones of **one** file (the 48.8 MP DJI DNG), plus `scan-5000` and `grid-10000`. Clones share data blocks, so the OS file cache is warmer than for 1,000 different files. The numbers for next image are therefore a little better than a real shoot would give. P-01 adds a real shoot (`real-*` folders) for the new baseline.
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
| Cull key to feedback, within 16 ms | p50 16 ms, p95 41 ms (300 decisions, each followed by a step) | **fail** at p95 | The slow samples coincide with a frame load. *Corrected in P-01: the texture upload does not run on the main thread; see "Corrections" below.* |
| Overlay toggles (histogram, info), within one display frame | histogram p50 17 ms, p95 23 ms; info p50 19 ms, p95 36 ms (to the next display tick) | **fail** at p95 (marginal) | As for cull feedback. Focus peaking and the highlight overlays do not exist yet (V-stories). |
| Zoom to 1:1, within one display frame | p50 27 ms, p95 36 ms | **fail** | The zoom re-renders a 24 MP texture. *Corrected in P-01: not on the main thread; see "Corrections" below.* Measure after P-05, then look at the draw path. |
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

## Corrections (P-01)

Found while planning the performance phase (STORIES.md, "Phase 2b"):

- The texture upload does not run on the main thread: `FrameLoader.load` is `nonisolated` and runs on the cooperative pool. But `LoupeGPU.prepare` blocks one of those threads with `waitUntilCompleted()`, and the histogram blocks another with `group.wait()`.
- One `MTLCommandQueue` (`LoupeGPU.queue`) carries the upload blits, the mip chains, the Core Image RAW renders, the overlay analysis and the present pass. A present can wait behind a prefetch. This explains "slow samples coincide with a frame load" better than the main thread does. The Instruments check of this is in the P-01 section below.
- The two test sets are smaller than first written (see Test sets above).

## P-01: the gate tool and the new baseline

Measured on 2 Oct 2026, same Mac as above (Apple M4, 24 GB, 60 Hz), Release build of commit e073ce9 plus P-01. `make perf-gate FOLDER=<folder>` runs every row of `scripts/perf-targets.tsv`, 3 runs each, and gates on the median run. Cold scenarios (`open`, `nav-cold`) ran **without** `sudo purge` (it needs a password): on `24mp-1000` (34 GB) they are warm-cache; on the real set (77 GB, more than the RAM) most reads are cold anyway, but not provably all. Re-run both after `purge` before a number is quoted as cold.

### Baseline

Median of 3 runs. Limits are the PRD's (see `scripts/perf-targets.tsv`). `scan-5000` and `grid-10000` rows use their own clone folders in both columns.

| Row | Limit | `24mp-1000` | `real-drone-840` (48.8 MP DNG) |
| --- | --- | --- | --- |
| Launch to first draw | 1,000 ms | 298 ms pass | 310 ms pass |
| Folder open to first image | 300 ms | 264 ms pass | 248 ms pass |
| Folder scan list, 5,000 files | 3,000 ms | 67 ms pass | 67 ms pass |
| Capture times, 5,000 files | 3,000 ms | 3,558 ms **fail** | 3,707 ms **fail** |
| Next image, prefetched, p95 | 50 ms | 63 ms **fail** | 68 ms **fail** |
| Next image, cold, p95 | 100 ms | 257 ms **fail** | 78 ms pass |
| Stale frames, held key | 0 | 0 of 322 frames pass | 0 of 245 pass |
| Stale frames, held key, 200 ms loader delay | 0 | 0 of 404 pass | 0 of 401 pass |
| Cull key to feedback, p95 | 16.7 ms | 28 ms **fail** | 35 ms **fail** |
| Histogram toggle, p95 | 16.7 ms | 23 ms **fail** | 23 ms **fail** |
| Info toggle, p95 | 16.7 ms | 35 ms **fail** | 35 ms **fail** |
| Zoom to 1:1, p95 | 16.7 ms | 45 ms **fail** | 34 ms **fail** |
| Grid scroll, worst frame | 25 ms | 33 ms **fail** (2 of 3 runs dropped a frame) | 16.7 ms pass (1 of 3 runs dropped a frame) |
| Memory peak in a 1,000-frame scrub | 2,048 MB | 5,572 MB **fail** | 2,587 MB **fail** |
| Idle CPU, Loupe | 0.5 % | 0.41 % pass | 0.25 % pass |
| Idle CPU, Grid | 0.5 % | 0.18 % pass | 0.01 % pass |

Sidecar write p95 while culling: 6.8 ms and 7.4 ms (reported only; `make sidecar-stress` gates it).

What the real set shows that the clones hid:
- **The drone DNGs are a light test for the frame pipeline.** Their largest embedded preview is 960×720 px (checked in `TestData/manifest.json`), so Oxys decodes and uploads a tiny image whatever the 48.8 MP of the sensor. That is why a cold next image is fine here (78 ms) and the memory peak is about half (2.6 GB against 5.6 GB). The 24 MP set has previews of 5760×3840 (a TIFF) and 7008×4672 (an ARW), and that is where the decode, upload and memory work shows. What the drone set does test is real: 840 different files read from disk, a 77 GB folder, and the sidecar and Grid paths.
- P-02 and P-03 (decode once, screen-size first) must be judged on `24mp-1000`, or on a shoot whose embedded previews are full size (a Sony ARW shoot, as the story first asked). This set cannot show their gain. P-10 (RAW develop) is different: develop reads the whole 48.8 MP sensor, so the drone set is a good test there.
- Everything that is not about frame size (cull, overlays, zoom, prefetched next image) fails on both sets by about the same amount.

### The M-26 table does not reproduce

P-01's first criterion was that the gate reproduces the M-26 table (same passes and fails) on `24mp-1000`. It does not, on three rows:

| Row | M-26 | Gate today | M-26 build, run again today |
| --- | --- | --- | --- |
| Next image, prefetched, p95 | 45 ms pass | 63 ms fail | 57, 65, 148 ms (3 runs) fail |
| Grid, worst frame | 16.7 ms pass | 33 ms fail | 35, 16.7, 16.7 ms (median pass) |
| Memory peak, scrub | 3.4 GB | 5.6 GB | 4.3, 4.6, 4.6 GB |

I built the M-26 commit (7e08ae7) and ran the same scenarios with the same gate. It shows the same drift, so the V-02 to V-13 stories did not cause it. The cause is the state of the Mac or noise: memory pressure and swap looked normal, and the cause is unknown. Run-to-run noise is large (148 ms against 57 ms for the same build), which is why the gate takes the median of 3. Treat the M-26 numbers for these three rows as not repeatable, and the baseline above as the number to beat.

### Is it one GPU queue? (Instruments, `cull`)

A Metal System Trace of the `cull` scenario (45 s, 1,392 command buffers; kept in `build/traces/cull-metal.trace`, not committed):
- 1,176 command buffers are submitted from the main thread (the present passes) and 216 from other threads (uploads, mip chains).
- **A present waited behind a background command buffer 5 times in 1,176.** Their wait was p50 1.4 ms, p95 7.5 ms, against p50 1.2 ms and p95 3.4 ms for the others. That is too rare and too short to explain a cull-feedback p95 of 28 to 35 ms.
- The same run's log shows the main thread late: a 10 ms timer fires late by p95 14 ms (p50 0.02 ms). So the main thread does stall during the cull run, and the cause is something other than waiting for the GPU.

So the one-queue diagnosis in "Corrections" is **not confirmed**: it may be a real cost under heavier prefetch (the `scrub` run), but it does not explain the cull miss. P-05 must start from a Time Profiler or System Trace of the main thread in `cull`, not from the queue.

### Tools made in P-01

- `scripts/perf-gate.sh`, `make perf-gate`, `scripts/perf-targets.tsv`, `PerfTool gate` (logic and tests in `Packages/Diagnostics`: `PerfGate.swift`).
- `OXYS_BENCH_DELAY_MS=<n>`: every frame load waits n ms first (a slow card or share). With 200 ms the frame load p50 is 326 ms and a held key shows only the frames of the photo the cursor is on: 0 stale.
- `make bench-folders` lists every `real-*` folder with its file count and size.
- Gaps: no other Mac (G-3), no SD card or network share (G-11): the 200 ms delay stands in for the second.
