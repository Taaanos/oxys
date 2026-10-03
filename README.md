# Oxys

A keyboard-first RAW culler for macOS. Instant embedded previews, full keyboard culling, and ratings and labels saved in XMP sidecars that Lightroom Classic, RawTherapee and ART can read.

Status: early development. See [PRD.md](PRD.md) for the product and [STORIES.md](STORIES.md) for the build plan.

## Using Oxys

The [user guide](docs/guide/README.md) explains each feature and key: [get started](docs/guide/getting-started.md), [cull photos](docs/guide/culling.md), [check sharpness and exposure](docs/guide/inspecting.md), [Compare](docs/guide/compare.md), [sidecars and other apps](docs/guide/sidecars.md), and all [keyboard shortcuts](docs/guide/shortcuts.md).

## Requirements

- Apple silicon Mac running macOS 27 or newer
- Xcode 27 (Swift 6.4)

## Install

Download `Oxys.zip` from [Releases](https://github.com/Taaanos/oxys/releases). The build has no Apple Developer ID, so Apple does not check it. Check the signature first ([how](docs/guide/install.md#check-the-download)). Then move the app to `/Applications` and run this, because macOS blocks it the first time:

```sh
xattr -dr com.apple.quarantine /Applications/Oxys.app
```

See [Install Oxys](docs/guide/install.md) for the System Settings way and for other ways.

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
