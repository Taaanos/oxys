# Oxys

Keyboard-first RAW culler for macOS. Swift 6, arm64 only, macOS 27+, no sandbox.
[PRD.md](PRD.md) is the product; [STORIES.md](STORIES.md) has the workflow, DoD, and decisions.

- **Architecture:** Put testable logic in `Packages/<Module>/`; keep `App/Oxys/` thin (SwiftUI + `NSViewRepresentable`).
- **Build & test:** `make build-debug` (fast loop), `make build` (Release, before commit), `make test`. See `Makefile` for bench/stress/contrast targets.
- **Tests:** For new package logic, write 2–3 sharp unit tests plus a seeded property/differential/simulation test (printing the failing seed).
- **Git:** One story per commit on `main`.
- **Invariants:**
  - Never modify originals or write into photo folders except XMP sidecars (and atomic temp files).
  - Read `OXYS_*` env vars only via `DevHooks.environment` (`App/Oxys/DevHooks.swift`), never in `Packages/`.
  - `App/Oxys/` auto-syncs new Swift files; edit `project.pbxproj` only with Xcode closed (`plutil -lint` + build).
  - GPL-3.0-or-later: log any third-party code in `docs/license-audit.md`; no GPL-only/AGPL/LGPL deps without approval.
