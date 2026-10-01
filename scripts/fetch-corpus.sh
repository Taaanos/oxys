#!/bin/bash
# F-02: recreate the test corpus in TestData/ (git-ignored; camera files are never committed).
# Downloads every file listed in scripts/corpus.tsv from raw.pixls.us (CC0) unless it is already there
# with the right sha256. Files of your own that sit in TestData/ are left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p TestData
failed=0
while IFS=$'\t' read -r id file sha _camera; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  dest="TestData/$file"
  if [[ -f "$dest" && "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$sha" ]]; then
    echo "ok       $file"; continue
  fi
  # The site looks the file up by id; the name in the URL only sets the download's file name.
  echo "fetch    $file"
  tmp="$dest.part"
  if ! curl -fsSL --retry 3 -o "$tmp" "https://raw.pixls.us/getfile.php/$id/nice/file"; then
    echo "FAILED   $file (download)"; rm -f "$tmp"; failed=1; continue
  fi
  if [[ "$(shasum -a 256 "$tmp" | cut -d' ' -f1)" != "$sha" ]]; then
    echo "FAILED   $file (sha256 mismatch)"; rm -f "$tmp"; failed=1; continue
  fi
  mv "$tmp" "$dest"
done < scripts/corpus.tsv
exit $failed
