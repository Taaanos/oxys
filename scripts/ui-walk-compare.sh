#!/bin/zsh
# V-08: walks Compare with key events only, then checks the sidecars of both sides. Needs Accessibility permission
# for the terminal (System Events sends the keys).
# Usage: [KEY_DELAY=seconds between keys, default 0.5] scripts/ui-walk-compare.sh [path/to/Oxys.app]
set -eu
cd "$(dirname "$0")/.."
APP=${1:-build/Build/Products/Release/Oxys.app}
SRC=TestData
WORK=$(mktemp -d)/walk
mkdir -p "$WORK"
cp "$SRC/DSC01014.ARW" "$SRC/DSC09025.ARW" "$SRC/DSC00204.dng" "$WORK/"

key() { osascript -e "tell application \"System Events\" to tell process \"Oxys\" to key code $1 ${2:-}"; sleep "${KEY_DELAY:-0.5}"; }
# Key codes: 8 C, 48 Tab, 7 X, 20/21/23 digits 3/4/5, 125 ↓, 126 ↑, 123 ←, 124 →, 53 Esc, 115 Home.
snap() { sleep 1.5; echo "-- $1"; for x in "$WORK"/*.xmp(N); do echo "   $(basename "$x"): $(grep -o 'xmp:Rating="[-0-9]*"' "$x")"; done; }
pkill -x Oxys 2>/dev/null || true
open "$APP"
sleep 2
osascript -e 'tell application "System Events" to tell process "Oxys" to set frontmost to true'
osascript -e 'tell application "System Events" to tell process "Oxys" to keystroke "o" using command down'; sleep 1
osascript -e 'tell application "System Events" to tell process "Oxys" to keystroke "g" using {command down, shift down}'; sleep 0.5
osascript -e "tell application \"System Events\" to tell process \"Oxys\" to keystroke \"$WORK\""; sleep 0.3
key 36; sleep 0.5; key 36; sleep 2
# Grid, no selection: Home, then C compares the first photo (select, active) with the second (candidate).
key 115
key 8
key 20                      # 3 on the select (first photo)
snap "select rated 3"
key 48 "using option down"  # ⌥⇥: the candidate is active
key 23                      # 5 on the candidate (second photo)
snap "candidate rated 5"
key 7 "using shift down"    # ⇧X: rejects the candidate, which moves on to the third photo
snap "second photo rejected"
key 21                      # 4 on the candidate, now the third photo
snap "third photo rated 4"
key 125                     # ↓ swap
key 126                     # ↑ next pair (there is none: stays)
key 123                     # ←
key 53                      # Esc: Grid
sleep 2
pkill -x Oxys || true

fail=0
count=$(ls "$WORK"/*.xmp 2>/dev/null | wc -l | tr -d ' ')
[ "$count" -eq 3 ] || { echo "FAIL: expected 3 sidecars (ratings 3, -1, 4), found $count"; fail=1; }
for r in 3 -1 4; do grep -lq "xmp:Rating=\"$r\"" "$WORK"/*.xmp 2>/dev/null || { echo "FAIL: no sidecar with rating $r"; fail=1; }; done
grep -lq 'xmp:Rating="5"' "$WORK"/*.xmp 2>/dev/null && { echo "FAIL: the rejected photo still has rating 5"; fail=1; }
for x in "$WORK"/*.xmp; do echo "$(basename "$x"): $(grep -o 'xmp:Rating="[-0-9]*"' "$x")"; done
[ $fail -eq 0 ] && echo "PASS" || exit 1
