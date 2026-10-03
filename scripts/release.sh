#!/bin/sh
# Publishes a release: builds main, packs it, tags it and uploads it to GitHub Releases.
# Usage: scripts/release.sh <version> [--notes <file>] [--dry-run] [--yes]     e.g. scripts/release.sh 1.0.1
#   <version>  X.Y.Z; the tag is v<version>. Becomes the app's version (About, Finder).
#   --dry-run  checks, builds, packs and prints the notes; creates no tag and uploads nothing.
#   --notes    a Markdown file that replaces the commit list under "Changes". The install steps still follow it.
#   --yes      skips the question before the tag and upload.
#   The zip is signed with OXYS_SIGNING_KEY (scripts/sign-release.sh) and the signature is uploaded with it.
#   --unsigned skips the signature (a dry run, or a test release); the notes then say nothing about verifying.
# Without --notes, the changes are the commit subjects since the previous tag.
set -eu

version="" dry=0 yes=0 unsigned=0 custom=""
while [ $# -gt 0 ]; do
	arg=$1; shift
	case "$arg" in
		--notes) [ $# -gt 0 ] || { echo "--notes needs a file" >&2; exit 2; }; custom=$1; shift ;;
		--dry-run) dry=1 ;;
		--yes) yes=1 ;;
		--unsigned) unsigned=1 ;;
		-*) echo "unknown option: $arg" >&2; exit 2 ;;
		*) version="$arg" ;;
	esac
done
[ -n "$version" ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must look like 1.2.3, got: $version" >&2; exit 2; }
tag="v$version"

custom_abs=""
if [ -n "$custom" ]; then
	[ -s "$custom" ] || { echo "--notes file is missing or empty: $custom" >&2; exit 2; }
	custom_abs=$(cd "$(dirname "$custom")" && pwd)/$(basename "$custom")
fi

cd "$(git rev-parse --show-toplevel)"
fail() { echo "$1" >&2; exit 1; }

[ "$(git branch --show-current)" = "main" ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "the working tree is not clean"
git fetch --quiet origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main differs from origin/main: push or pull first, so the release is what GitHub has"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "tag $tag already exists"
[ "$unsigned" = 1 ] || [ -n "${OXYS_SIGNING_KEY:-}" ] || fail "set OXYS_SIGNING_KEY to the release signing key (docs/release-signing.md), or pass --unsigned"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in: run gh auth login"

previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
range=${previous:+$previous..}HEAD
notes="dist/release-notes.md"
mkdir -p dist
{
	echo "## Changes"
	echo
	if [ -n "$custom_abs" ]; then cat "$custom_abs"; else git log --no-merges --format='- %s (%h)' "$range"; fi
	echo
	echo "## Install"
	echo
	echo "Needs an Apple silicon Mac with macOS 27 or newer. The build is not signed with a Developer ID, so macOS blocks it until you remove the quarantine mark."
	if [ "$unsigned" != 1 ]; then
		echo
		echo '**Check the download first.** `Oxys.zip.sig` is a signature made with the Oxys release key. Steps and the key fingerprint: [Check the download](https://github.com/Taaanos/oxys/blob/main/docs/guide/install.md#check-the-download).'
	fi
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
assets="dist/Oxys.zip dist/Oxys.zip.sha256"
if [ "$unsigned" != 1 ]; then scripts/sign-release.sh; assets="$assets dist/Oxys.zip.sig"; fi

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
gh release create "$tag" $assets \
	--target "$(git rev-parse HEAD)" --title "Oxys $version" --notes-file "$notes"
git fetch --quiet origin --tags
echo "published: $(gh release view "$tag" --json url -q .url)"
