#!/bin/sh
# Builds the Release app and packs it for GitHub Releases: dist/Oxys-<version>.zip and its SHA-256 file.
# Usage: [VERSION=1.2.0] scripts/package-release.sh   (run from the repo root; makes no commit, no tag, no upload)
# With VERSION set, the app is built with that marketing version and the commit count as its build number.
set -eu

if [ -n "${VERSION:-}" ]; then
	make build BUILD_SETTINGS="MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)"
else
	make build
fi
app="build/Build/Products/Release/Oxys.app"
archs=$(lipo -archs "$app/Contents/MacOS/Oxys")
[ "$archs" = "arm64" ] || { echo "expected arm64 only, got: $archs" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
codesign --verify --deep --strict "$app"
[ -z "${VERSION:-}" ] || [ "$version" = "$VERSION" ] || { echo "built version $version, expected $VERSION" >&2; exit 1; }

mkdir -p dist
zip="dist/Oxys.zip"
rm -f "$zip"
# ditto keeps the code signature, symlinks and extended attributes that plain zip can damage.
ditto -c -k --keepParent "$app" "$zip"
(cd dist && shasum -a 256 Oxys.zip > Oxys.zip.sha256)
echo "$zip"
cat dist/Oxys.zip.sha256
echo "version $version"
