#!/bin/zsh
# V-14: runs the keymap checks inside the app (see KeysSelfTest.swift). The app builds its own key events, so this
# needs no Accessibility permission. It works on a copy of two test photos and a temporary Keymap.json, so neither the
# TestData folder nor your own keymap changes.
# Usage: scripts/keys-selftest.sh [path/to/Oxys.app]      (the Bench build: make build-bench)
set -eu
cd "$(dirname "$0")/.."
APP=${1:-build/Build/Products/Bench/Oxys.app}
WORK=$(mktemp -d)
mkdir -p "$WORK/photos"
cp TestData/DSC01014.ARW TestData/DSC09025.ARW "$WORK/photos/"
OUT="$WORK/result.txt"
# The test must not depend on the user's settings: pin the ones that change what a key does.
# OXYS_SELFTEST_SHOT=<file.png> also draws the Settings window into that file (an absolute path).
hold=()
[ -z "${OXYS_SELFTEST_SHOT:-}" ] || hold=(--env OXYS_SELFTEST_SHOT="$OXYS_SELFTEST_SHOT")
pkill -x Oxys 2>/dev/null || true
open -n -W --env OXYS_KEYS_SELFTEST=1 --env OXYS_OPEN="$WORK/photos" --env OXYS_KEYMAP="$WORK/Keymap.json" \
 --env OXYS_SELFTEST_OUT="$OUT" "${hold[@]}" "$APP" --args -autoAdvance NO -rawMode never -showFilmStrip NO
[ -f "$OUT" ] || { echo "FAIL: the app wrote no result (it did not finish)"; rm -rf "$WORK"; exit 1; }
cat "$OUT"
rc=0
grep -q '^done failures=0$' "$OUT" || rc=1
rm -rf "$WORK"
[ $rc -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
