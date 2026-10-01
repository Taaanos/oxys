#!/bin/bash
# F-02: build benchmark folders under TestData/bench/ from the files in TestData/ (APFS clones: no extra disk).
#   24mp-1000     1,000 files from sources that ImageIO reports at 18-36 MP
#   hires-1000    1,000 files from sources at 40 MP or more
#   scan-5000     5,000 files, mixed: folder-scan tests
#   grid-10000    10,000 files, mixed: Grid scrolling
# Clones of one file share their bytes, so these folders suit scan and Grid tests but NOT next-image timings:
# the OS file cache makes repeated bytes look faster than a real shoot (use real shoots there, see STORIES F-02).
# Needs TestData/manifest.json (make manifest) and jq. Safe to re-run: existing folders are rebuilt.
set -euo pipefail
cd "$(dirname "$0")/.."
manifest=TestData/manifest.json
[[ -f $manifest ]] || { echo "run 'make manifest' first"; exit 1; }
out=TestData/bench

# sources <min MP> <max MP>  → file names, one per line (skips files with unknown size)
sources() { jq -r --argjson lo "$1" --argjson hi "$2" '.[] | select(.megapixels != null and .megapixels >= $lo and .megapixels < $hi) | .file' "$manifest"; }

# fill <folder> <count> <source names...>: cycle through the sources, giving each clone a unique, sortable name.
fill() {
  local dir=$1 count=$2; shift 2
  [[ $# -gt 0 ]] || { echo "no sources for $dir"; return 1; }
  rm -rf "$dir"; mkdir -p "$dir"
  local srcs=("$@") i src ext
  for ((i = 0; i < count; i++)); do
    src=${srcs[i % ${#srcs[@]}]}
    ext=${src##*.}
    cp -c "TestData/$src" "$dir/$(printf 'IMG_%05d' "$i").$ext"
  done
  echo "$dir: $(ls "$dir" | wc -l | tr -d ' ') files"
}

mid=();  while IFS= read -r l; do mid+=("$l");  done < <(sources 18 36)
big=();  while IFS= read -r l; do big+=("$l");  done < <(sources 40 1000)
all=();  while IFS= read -r l; do all+=("$l");  done < <(sources 5 1000)

fill $out/24mp-1000   1000  "${mid[@]}"
fill $out/hires-1000  1000  "${big[@]}"
fill $out/scan-5000   5000  "${all[@]}"
fill $out/grid-10000  10000 "${all[@]}"
