#!/bin/sh
# Publishes a release: builds main, packs it, tags it and uploads it to GitHub Releases.
# Usage: scripts/release.sh <version> [--dry-run] [--yes]     e.g. scripts/release.sh 1.0.1
#   <version>  X.Y.Z; the tag is v<version>. Becomes the app's version (About, Finder).
#   --dry-run  checks, builds, packs and prints the notes; creates no tag and uploads nothing.
#   --yes      skips the question before the tag and upload.
# The notes are the commit subjects since the previous tag, plus the install steps.
set -eu

version="" dry=0 yes=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) dry=1 ;;
		--yes) yes=1 ;;
		-*) echo "unknown option: $arg" >&2; exit 2 ;;
		*) version="$arg" ;;
	esac
done
[ -n "$version" ] || { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must look like 1.2.3, got: $version" >&2; exit 2; }
tag="v$version"

cd "$(git rev-parse --show-toplevel)"
fail() { echo "$1" >&2; exit 1; }

[ "$(git branch --show-current)" = "main" ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "the working tree is not clean"
git fetch --quiet origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main differs from origin/main: push or pull first, so the release is what GitHub has"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "tag $tag already exists"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in: run gh auth login"

previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
range=${previous:+$previous..}HEAD
notes="dist/release-notes.md"
mkdir -p dist
{
	echo "## Changes"
	echo
	git log --no-merges --format='- %s (%h)' "$range"
	echo
	echo "## Install"
	echo
	echo "Needs an Apple silicon Mac with macOS 27 or newer. The build is not signed with a Developer ID, so macOS blocks it until you remove the quarantine mark."
	echo
	echo '1. Download `Oxys.zip` and double-click it.'
	echo '2. Move `Oxys.app` to `/Applications`.'
	echo '3. In Terminal, run:'
	echo
	echo '   ```sh'
	echo '   xattr -dr com.apple.quarantine /Applications/Oxys.app'
	echo '   ```'
	echo
	echo 'Details and another method: [docs/guide/install.md](https://github.com/Taaanos/oxys/blob/main/docs/guide/install.md).'
	[ -z "$previous" ] || { echo; echo "Full changelog: https://github.com/Taaanos/oxys/compare/$previous...$tag"; }
} > "$notes"

VERSION="$version" scripts/package-release.sh

echo
echo "Release $tag from $(git rev-parse --short HEAD), previous ${previous:-none}"
cat "$notes"
if [ "$dry" = 1 ]; then echo; echo "dry run: no tag, no upload"; exit 0; fi

if [ "$yes" != 1 ]; then
	printf 'Tag %s and publish on GitHub? [y/N] ' "$tag"
	read -r answer
	[ "$answer" = "y" ] || fail "cancelled"
fi

# gh creates the tag on the remote at this commit, so a failed upload leaves no local tag to clean up.
gh release create "$tag" dist/Oxys.zip dist/Oxys.zip.sha256 \
	--target "$(git rev-parse HEAD)" --title "Oxys $version" --notes-file "$notes"
git fetch --quiet origin --tags
echo "published: $(gh release view "$tag" --json url -q .url)"
