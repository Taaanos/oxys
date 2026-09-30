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
- `Packages/<Module>/`: one local Swift package per module (Commands, Library, Containers, Imaging, Canvas, Sidecar, Metadata), each with a Swift Testing target. Put logic in packages so it can be tested without launching the app. Add inter-package dependencies only when a story needs them.
- `scripts/`: developer scripts. `docs/` (spike write-ups, perf reports) appears as stories produce them. `TestData/` is git-ignored and never holds committed camera files.

## Commands (run from the repo root)

```sh
make build         # Release build into ./build
make test          # swift test in every Packages/* directory
make check-arch    # lipo -archs on the built app; must print only "arm64"
make launch-time   # 5 cold launches; prints launch-to-first-draw
```

Package manifests use `swift-tools-version: 6.4` (`.macOS(.v27)` needs it). Bundle ID is the placeholder `dev.oxys.Oxys` (G-1); set the real one before V-17.

## Gotchas

- Edit `App/Oxys.xcodeproj/project.pbxproj` only while Xcode is closed, and validate with `plutil -lint` and a build. New Swift files under `App/Oxys/` need no project edit (file-system-synchronized group).
- The app is signed ad hoc ("Sign to Run Locally"); it needs no Apple developer account.
- Never run `git init` inside `App/` or `Packages/`; Xcode's template once created a nested repo there.
- Never write into a photographer's folders except XMP sidecars (and their atomic-write temp files, G-9). Originals are never written.
