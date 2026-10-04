# Oxys

Keyboard-first RAW culler for macOS. Swift 6, arm64 only, macOS 27+, no sandbox.
[PRD.md](PRD.md) is the product; [STORIES.md](STORIES.md) is the build plan and the record of decisions.

## Working on a story

- Follow "How we work through a story" in STORIES.md: read the story's open questions, settle the ones that change the design (each has a *Proposed* default, so nothing blocks), build, check every acceptance criterion, then record decisions in the story and update its status in the index.
- Meet the Definition of done in STORIES.md (strict concurrency with no warnings, unit tests for package logic, commands in the command table, signposts on performance paths, keyboard and VoiceOver, nothing written into photo folders except sidecars).
- One story per commit, on `main`. Don't push unless asked.
- Story IDs in commits and docs: `F-` foundation, `M-` MVP, `V-` v1.0, `P-` performance, `D-` design. Cross-cutting questions are `G-n`.

## Layout

- `App/Oxys.xcodeproj` and `App/Oxys/`: the SwiftUI app target (single `Window` scene, AppKit views behind `NSViewRepresentable`).
- `Packages/<Module>/`: one local Swift package per module (Commands, Library, Containers, Imaging, Canvas, Sidecar, Metadata, Diagnostics), each with a Swift Testing target. Put logic in packages so it can be tested without launching the app. Add inter-package dependencies only when a story needs them.
- `scripts/`: developer scripts. `docs/` (spike write-ups, perf reports, design reports) appears as stories produce them. `TestData/` is git-ignored and never holds committed camera files.

## Commands (run from the repo root)

```sh
make build         # Release build into ./build
make build-debug   # Debug build, for the edit-and-check loop: one edit builds in about 3 s (Release: 12 s). Same warnings; never use it for timing. Run `make build` before the story commit
make build-bench   # S-6: the Bench configuration, Release plus the OXYS_DEV_HOOKS compile condition; the OXYS_* variables work only here. perf-bench, perf-gate, contrast and launch-time build and use it; it is never shipped
make test          # swift test in every Packages/* directory
make check-arch    # lipo -archs on the built app; must print only "arm64"
make launch-time   # 5 cold launches; prints launch-to-first-draw
make corpus        # fetch the pixls files in scripts/corpus.tsv into TestData/, then write TestData/manifest.json
make bench-folders # TestData/bench/{24mp-1000,hires-1000,scan-5000,grid-10000} (APFS clones)
make sidecar-stress # 1,000 decisions over 60 s through the write queue, then verify every sidecar
make extract-bench FOLDER=TestData/bench/hires-1000 EXTRA=--exact   # V-13: extract every embedded JPEG, time vs cp -R; EXTRA=--verify with PREVIEW_ORACLE checks bytes; V-21: EXTRA=--developed=jpeg or =heic develops every RAW, times it, and checks Exif, GPS, size, depth, profile, dates and xattrs against the source
make sidecar-gate   # M-25: 10,000 real sidecar writes with outside writers and killed writers
make perf-bench SCENARIO=nav-cold FOLDER=TestData/bench/24mp-1000   # M-26: in-app scenario (open, nav-*, scrub, cull, zoom, develop, develop-cancel, compare, compare-link, overlays, peaking, peaking-still, peaking-view, clipping, clipping-still, grid, idle, load-memory); V-19: BENCH_LENS=1 runs it with lens correction on (off otherwise)
make perf-gate FOLDER=TestData/bench/real-drone-840   # P-01: every scenario in scripts/perf-targets.tsv, 3 runs each, held to the PRD limits; exit 1 on a fail; PERF_GATE_WARM=1 skips the `sudo purge` prompts; OXYS_BENCH_DELAY_MS=<n> slows every frame load
make perf-selftest # record + report synthetic signposts (pipeline check)
make contrast      # D-01: every label on the photo over TestData/design test frames; writes docs/design/contrast.md, exit 1 on a fail (needs Screen Recording permission)
make contrast-quick # the same probe on the white and yellow frames only: 16 captures, about 45 s, report in build/contrast/<time>/docs (docs/design stays as it is)
make contrast-selftest  # the WCAG math, the shape mask and the 1% cut of scripts/contrast-report.py
make ui-walk       # drive the built app with key events only, then check the sidecars (needs Accessibility permission)
scripts/perf-record.sh <Oxys.app> [seconds]   # record signposts, print p50/p95 per interval
```

Package manifests use `swift-tools-version: 6.4` (`.macOS(.v27)` needs it). Bundle ID is `com.thanosam.Oxys` (G-1). License is GPL-3.0-or-later (G-2): add no third-party code without recording it in `docs/license-audit.md`, and no GPL-only, AGPL or LGPL dependency without the owner's decision (the owner may sell on the Mac App Store later).

## Gotchas

- Read the `OXYS_*` environment variables only through `DevHooks.environment` (App/Oxys/DevHooks.swift). In Release it is empty. Packages must not read them.
- Edit `App/Oxys.xcodeproj/project.pbxproj` only while Xcode is closed, and validate with `plutil -lint` and a build. New Swift files under `App/Oxys/` need no project edit (file-system-synchronized group).
- The app is signed ad hoc ("Sign to Run Locally"); it needs no Apple developer account.
- Never run `git init` inside `App/` or `Packages/`; Xcode's template once created a nested repo there.
- Never write into a photographer's folders except XMP sidecars (and their atomic-write temp files, G-9). Originals are never written.
