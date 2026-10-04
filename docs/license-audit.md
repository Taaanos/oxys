# License audit

Oxys is licensed under the GNU General Public License, version 3 or (at your option) any later version (`GPL-3.0-or-later`). The full text is in [LICENSE](../LICENSE). This audit is the V-17 record of what Oxys contains and under which terms. G-2 in STORIES.md has the decision.

Checked on 2026-10-04 for version 0.1.0.

## What is in the shipped app

| Part | Source | Terms |
| --- | --- | --- |
| Oxys code (`App/`, `Packages/`) | written for this project | GPL-3.0-or-later |
| App icon (`App/Oxys/AppIcon.icon`, `Assets.xcassets`) | made for this project (`scripts/make-icon-*.py`) | GPL-3.0-or-later with the rest of the repository, except the name and icon rule below |
| Apple system frameworks: SwiftUI, AppKit, Observation, Foundation, Synchronization, CoreGraphics, ImageIO, CoreImage, Metal, QuartzCore, UniformTypeIdentifiers, CryptoKit, CoreServices, Carbon.HIToolbox, os | macOS 27, linked at run time, not copied into the app | System libraries. They need no license notice and they do not put terms on Oxys. |
| Swift runtime | part of macOS 27, not copied into the app | Same as above |

There is **no third-party code**. Specifically:

- No Swift package dependency. Every `Package.swift` in `Packages/` has only local targets, and the Xcode project has no package reference.
- No vendored C, C++ or Objective-C source, and no prebuilt library or framework.
- No font file, and no shader file from another project. Metal code is in Oxys sources.
- No LibRaw, Exiv2 or other GPL, LGPL or CDDL library. F-06 and the RAW story record that the system RAW decoder (`CIRAWFilter`) is enough for v1.0.
- Tag tables for maker notes were written from documentation, not copied from other tools (V-01).

## What is only used in development

| Part | Use | Terms |
| --- | --- | --- |
| Swift Testing (`import Testing`) | unit tests only, never in the app | Apache-2.0 with Runtime Library Exception |
| raw.pixls.us sample files | downloaded by `make corpus` into the git-ignored `TestData/` | CC0 1.0 (checked per file in `scripts/corpus.tsv`). They are never committed. |
| An external metadata tool used as a test oracle | checks bytes in extract and export tests, set with `PREVIEW_ORACLE`. It is not part of the repository. | not distributed |

## Rules for new dependencies

1. Before a story adds third-party code, check its license and add it to the table above in the same commit.
2. **No GPL-only, AGPL or LGPL code without the owner's decision.** The owner may later want to sell Oxys on the Mac App Store. The owner can relicense only code that the owner holds the copyright to (or that has a permissive license). A GPL-only dependency would block this.
3. Permissive licenses (MIT, BSD, Apache-2.0, ISC, zlib) are fine. Keep their copyright notice and license text in `THIRD-PARTY-NOTICES.md` and in the app's About window.
4. Contributions from other people need a Contributor License Agreement before the first one is merged, so the owner keeps the right to relicense. There is no outside contribution yet.

## Name and icon

The GPL covers the code. The name "Oxys" and the app icon identify the official build. A changed version that you distribute must use another name and another icon. This rule is in the README.
