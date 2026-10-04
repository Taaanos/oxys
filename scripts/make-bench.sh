#!/bin/bash
# F-02: build benchmark folders under TestData/bench/ from the files in TestData/ (APFS clones: no extra disk).
#   24mp-1000     1,000 files from sources that ImageIO reports at 18-36 MP
#   hires-1000    1,000 files from sources at 40 to 60 MP
#   61mp-28       28 files from sources at 60 MP or more (P-10: Sony A7R IV and A7R V files, 14 different files with 2 clones each); skipped without sources
#   scan-5000     5,000 files from sources at 5 to 60 MP, mixed: folder-scan tests
#   grid-10000    10,000 files, the same mix: Grid scrolling (P-10: the 60 MP files stay out, so the scan and Grid numbers keep their baseline)
# Folders named real-* hold a real shoot (all different files; P-01). They are never touched here, only counted.
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
big=();  while IFS= read -r l; do big+=("$l");  done < <(sources 40 60)
top=();  while IFS= read -r l; do top+=("$l");  done < <(sources 60 1000)
all=();  while IFS= read -r l; do all+=("$l");  done < <(sources 5 60)

fill $out/24mp-1000   1000  "${mid[@]}"
fill $out/hires-1000  1000  "${big[@]}"
# P-10: the 61 MP files are not in hires-1000, so its numbers stay comparable with the earlier stories.
# Sorted by file name, so 28 clones cycle through the 14 files and 14 neighbours in a row differ (the RAW cache holds 5).
if (( ${#top[@]} )); then fill $out/61mp-28 28 "${top[@]}"; else echo "no source of 60 MP or more in TestData/: 61mp-28 skipped (STORIES P-10)"; fi
fill $out/scan-5000   5000  "${all[@]}"
fill $out/grid-10000  10000 "${all[@]}"

# P-01: real shoots (real-* folders) are the user's own files, never made here; report which are present.
shopt -s nullglob
real=($out/real-*/)
if (( ${#real[@]} )); then
  for dir in "${real[@]}"; do
    echo "${dir%/}: $(find "$dir" -type f | wc -l | tr -d ' ') files, $(du -sh "$dir" | cut -f1) (real shoot, kept)"
  done
else
  echo "no real shoot in $out/real-*: clone your own files there (cp -c, no extra disk), see STORIES P-01"
fi
