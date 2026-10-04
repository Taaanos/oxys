# Changelog

All notable changes to Oxys. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH, and the tag is `v` plus the version.

## [Unreleased]

### Changed
- The bundle ID is now `com.thanosam.Oxys` (it was the placeholder `dev.oxys.Oxys`). Settings that you changed in 0.1.0 start from their defaults, and the thumbnail cache is made again. Your photos and XMP sidecars are not affected. You can delete the old folder `~/Library/Caches/dev.oxys.Oxys`.

### Added
- Settings > Keys: change, add, remove and reset the keys of any command. Oxys shows a key that is already in use before it saves, and you can reassign it. Menus, the `?` list, and the key hints change at once. Import and export the keys as a file. `F1` to `F12`, `Page Up`, `Page Down` and forward delete can be used as keys. See [Settings](docs/guide/settings.md#keys).
- License: GPL-3.0-or-later (`LICENSE`), and a license audit (`docs/license-audit.md`).
- Install with Homebrew from the `taaanos/tap` tap.

### Fixed
- A key pressed in the Settings window no longer rates or rejects the photo in the main window.
- The keypad digits show as "Keypad 1" and so on, so they differ from the digit row in the menus and the `?` list.

## [0.1.0] - 2026-10-03

First public preview. See the [release notes](notes/0.1.0.md).
