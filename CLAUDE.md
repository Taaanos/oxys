# Oxys

Keyboard-first RAW culler for macOS. Swift 6, arm64 only, macOS 27+, no sandbox.
[PRD.md](PRD.md) is the product; [STORIES.md](STORIES.md) is the build plan and the record of decisions.

## Working on a story

- Follow "How we work through a story" in STORIES.md: read the story's open questions, settle the ones that change the design (each has a *Proposed* default, so nothing blocks), build, check every acceptance criterion, then record decisions in the story and update its status in the index.
- Meet the Definition of done in STORIES.md (strict concurrency with no warnings, unit tests for package logic, commands in the command table, signposts on performance paths, keyboard and VoiceOver, nothing written into photo folders except sidecars).
- One story per commit, on `main`. Don't push unless asked.
- Story IDs in commits and docs: `F-` foundation, `M-` MVP, `V-` v1.0. Cross-cutting questions are `G-n`.

## Layout

- `App/Oxys.xcodeproj` and `App/Oxys/`: the SwiftUI app target (single `Window` scene, AppKit views behind `NSViewRepresentable`).
- `Packages/<Module>/`: one local Swift package per module (Commands, Library, Containers, Imaging, Canvas, Sidecar, Metadata, Diagnostics), each with a Swift Testing target. Put logic in packages so it can be tested without launching the app. Add inter-package dependencies only when a story needs them.
- `scripts/`: developer scripts. `docs/` (spike write-ups, perf reports) appears as stories produce them. `TestData/` is git-ignored and never holds committed camera files.

## Commands (run from the repo root)

```sh
make build         # Release build into ./build
make test          # swift test in every Packages/* directory
make check-arch    # lipo -archs on the built app; must print only "arm64"
make launch-time   # 5 cold launches; prints launch-to-first-draw
make corpus        # fetch the pixls files in scripts/corpus.tsv into TestData/, then write TestData/manifest.json
make bench-folders # TestData/bench/{24mp-1000,hires-1000,scan-5000,grid-10000} (APFS clones)
make sidecar-stress # 1,000 decisions over 60 s through the write queue, then verify every sidecar
make sidecar-gate   # M-25: 10,000 real sidecar writes with outside writers and killed writers
make perf-bench SCENARIO=nav-cold FOLDER=TestData/bench/24mp-1000   # M-26: in-app scenario (open, nav-*, scrub, cull, zoom, overlays, grid, idle)
make perf-selftest # record + report synthetic signposts (pipeline check)
make ui-walk       # drive the built app with key events only, then check the sidecars (needs Accessibility permission)
scripts/perf-record.sh <Oxys.app> [seconds]   # record signposts, print p50/p95 per interval
```

Package manifests use `swift-tools-version: 6.4` (`.macOS(.v27)` needs it). Bundle ID is the placeholder `dev.oxys.Oxys` (G-1); set the real one before V-17.

## Gotchas

- Edit `App/Oxys.xcodeproj/project.pbxproj` only while Xcode is closed, and validate with `plutil -lint` and a build. New Swift files under `App/Oxys/` need no project edit (file-system-synchronized group).
- The app is signed ad hoc ("Sign to Run Locally"); it needs no Apple developer account.
- Never run `git init` inside `App/` or `Packages/`; Xcode's template once created a nested repo there.
- Never write into a photographer's folders except XMP sidecars (and their atomic-write temp files, G-9). Originals are never written.
