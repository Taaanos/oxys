#!/bin/bash
# F-02: copy a benchmark folder to another volume (UHS-II SD card, network share) so the same
# measurements can be repeated there:  scripts/copy-to-volume.sh TestData/bench/24mp-1000 /Volumes/CARD
# Copies with rsync (real bytes, no clones), then verifies the file count.
set -euo pipefail
src="${1:?usage: copy-to-volume.sh <folder> <volume or destination folder>}"
dst="${2:?usage: copy-to-volume.sh <folder> <volume or destination folder>}"
[[ -d $src && -d $dst ]] || { echo "both arguments must be existing folders"; exit 1; }
name=$(basename "$src")
rsync -a --info=progress2 "$src/" "$dst/$name/"
want=$(find "$src" -type f | wc -l | tr -d ' ')
got=$(find "$dst/$name" -type f | wc -l | tr -d ' ')
[[ $want == "$got" ]] || { echo "count mismatch: $want vs $got"; exit 1; }
echo "$dst/$name: $got files"
echo "For a cold first pass run 'sudo purge' before measuring; for a card, eject and re-insert it."
