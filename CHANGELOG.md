# Changelog

All notable changes to Oxys. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH, and the tag is `v` plus the version.

## [Unreleased]

## [1.0.0] - 2026-10-04

First stable release. See the [release notes](notes/1.0.0.md).

### Changed
- Full screen is `⌃⌘F`, the system key (it was `⌘⇧F`).
- The bundle ID is now `com.thanosam.Oxys` (it was the placeholder `dev.oxys.Oxys`). Settings that you changed in 0.1.0 start from their defaults, and the thumbnail cache is made again. Your photos and XMP sidecars are not affected. You can delete the old folder `~/Library/Caches/dev.oxys.Oxys`.

### Added
- Settings > Keys: change, add, remove and reset the keys of any command. Oxys shows a key that is already in use before it saves, and you can reassign it. Menus, the `?` list, and the key hints change at once. A Photo Mechanic key set (stars on `⌃1` to `⌃5`, `B` and `N` for the overlays, `V` for Compare, and more). Import and export the keys as a file. `F1` to `F12`, `Page Up`, `Page Down` and forward delete can be used as keys. See [Settings](docs/guide/settings.md#keys).
- License: GPL-3.0-or-later (`LICENSE`), and a license audit (`docs/license-audit.md`).
- Install with Homebrew from the `taaanos/tap` tap.

- Film strip in Loupe: a row of thumbnails under the photo.
- Focus mode: `⇥` hides every panel but the RAW badge and the decision. In Compare, `⌥⇥` switches the side.
- Settings > RAW: optional lens correction for the developed RAW, off by default. It applies only to cameras that the system decoder supports. The inspector shows its state.
- Grid: the decision marks are in one capsule on every cell, and the active cell has a glass lens.
- Export: an opt-in switch removes location and serial numbers.
- Settings > Memory: a button clears the thumbnail cache.
- Releases are signed with an off-GitHub key (`Oxys.zip.sig`). See [Check the download](docs/guide/install.md#check-the-download).

### Performance
- Grid: the slowest frame while scrolling went from 143–185 ms to 17–45 ms.
- RAW develop, p95: 470 ms at 24–33 MP, 276 ms at 48.8 MP, 480 ms at 61 MP. Extracting the embedded JPEGs takes 0.34 to 0.57 of a plain copy.
- One memory budget for preview frames, developed RAWs and loads in flight, with a trim on memory pressure and when idle. A held key waits before it prefetches.
- ImageIO opens of RAW and TIFF files are limited to 8 at once, which fixes a crash in the system RAW decoder.

### Security
- Hardened runtime in the release build. Developer hooks exist only in the Bench build.
- Nesting depth and IFD count are limited in the CR3 and TIFF parsers. A decode over 250 megapixels is refused before ImageIO allocates it.
- Symlinked sidecars are refused. A sidecar's type and size are checked before it is read. Only regular stale temp files are deleted.
- After an unclean quit, Oxys starts empty and does not reopen the last folder.

### Fixed
- A key pressed in the Settings window no longer rates or rejects the photo in the main window.
- The keypad digits show as "Keypad 1" and so on, so they differ from the digit row in the menus and the `?` list.
- A folder that disappears keeps the list and its decisions.

## [0.1.0] - 2026-10-03

First public preview. See the [release notes](notes/0.1.0.md).
