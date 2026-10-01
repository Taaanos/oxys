# Oxys

A keyboard-first RAW culler for macOS. Instant embedded previews, full keyboard culling, and ratings and labels saved in XMP sidecars that Lightroom Classic, RawTherapee and ART can read.

Status: early development. See [PRD.md](PRD.md) for the product and [STORIES.md](STORIES.md) for the build plan.

## Requirements

- Apple silicon Mac running macOS 27 or newer
- Xcode 27 (Swift 6.4)

## Build from source

```sh
git clone <repo-url> oxys && cd oxys
make build        # Release build into ./build
make check-arch   # prints the app's architectures; must be just "arm64"
```

The app is signed ad hoc ("Sign to Run Locally"), so no Apple developer account is needed. You can also open `App/Oxys.xcodeproj` in Xcode and press Run.

## Tests

```sh
make test         # runs the unit tests of every package under Packages/
```

## Layout

| Path | What |
| --- | --- |
| `App/` | Xcode project and the SwiftUI app target |
| `Packages/` | One local Swift package per module: Commands, Library, Containers, Imaging, Canvas, Sidecar, Metadata, Diagnostics |
| `scripts/` | Developer scripts |
| `docs/` | Spike write-ups and performance reports (added as stories land) |
