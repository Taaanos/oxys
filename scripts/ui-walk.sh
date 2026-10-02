#!/bin/zsh
# M-24: walks the core workflow (open, first pass, narrow, hand off) with key events only, no pointer events,
# then checks the sidecars. Needs Accessibility permission for the terminal (System Events sends the keys).
# Usage: [KEY_DELAY=seconds between keys, default 0.4] scripts/ui-walk.sh [path/to/Oxys.app]
set -eu
cd "$(dirname "$0")/.."
APP=${1:-build/Build/Products/Release/Oxys.app}
SRC=TestData
WORK=$(mktemp -d)/walk
mkdir -p "$WORK"
cp "$SRC/DSC01014.ARW" "$SRC/DSC09025.ARW" "$SRC/DSC00204.dng" "$WORK/"

key() { osascript -e "tell application \"System Events\" to tell process \"Oxys\" to key code $1 ${2:-}"; sleep "${KEY_DELAY:-0.4}"; }
# Key codes (physical keys): 36 Return, 124 →, 7 X, 20 digit 3, 23 digit 5.
# After a step, shows which sidecars exist and their ratings (the trace for a failed walk).
# The Loupe image's VoiceOver label starts with the file name, so it says which photo is current.
shown() {
  osascript <<'APPLESCRIPT' 2>&1 | head -c 200
tell application "System Events" to tell process "Oxys"
  set found to {}
  repeat with e in (entire contents of window 1)
    try
      set d to value of attribute "AXDescription" of e
      if d begins with "DSC" then set end of found to d
    end try
  end repeat
  return found
end tell
APPLESCRIPT
}
# After a step, shows the photo on screen, then which sidecars exist and their ratings (the trace for a failed walk).
snap() { sleep 1.5; echo "-- $1 | shown: $(shown)"; for x in "$WORK"/*.xmp(N); do echo "   $(basename "$x"): $(grep -o 'xmp:Rating="[-0-9]*"' "$x")"; done; }
pkill -x Oxys 2>/dev/null || true
open "$APP"
sleep 2
osascript -e 'tell application "System Events" to tell process "Oxys" to set frontmost to true'
# 1. Open: ⌘O, then ⇧⌘G in the panel, type the path, Return, Return.
osascript -e 'tell application "System Events" to tell process "Oxys" to keystroke "o" using command down'; sleep 1
osascript -e 'tell application "System Events" to tell process "Oxys" to keystroke "g" using {command down, shift down}'; sleep 0.5
osascript -e "tell application \"System Events\" to tell process \"Oxys\" to keystroke \"$WORK\""; sleep 0.3
key 36; sleep 0.5; key 36; sleep 2
# The folder opens in Grid. Return opens the active photo in Loupe.
key 36
# 2. First pass: rate 3, next, reject, next, rate 5 with ⇧ (applies and advances).
key 20            # 3
snap "after 3"
key 124           # next
key 7             # X
snap "after X (next photo should be rejected)"
key 124
snap "after next (should show DSC00204)"
key 23 "using shift down"   # ⇧5
sleep 2           # the write queue settles
# 4. Narrow: ⌥⌘3 shows 3 stars and more.
key 20 "using {option down, command down}"
# 5. Hand off: ⌘A selects all in the filtered view.
osascript -e 'tell application "System Events" to tell process "Oxys" to keystroke "a" using command down'
sleep 1
pkill -x Oxys || true

fail=0
count=$(ls "$WORK"/*.xmp 2>/dev/null | wc -l | tr -d ' ')
[ "$count" -ge 3 ] || { echo "FAIL: expected 3 sidecars (ratings 3, -1, 5), found $count"; fail=1; }
for r in 3 -1 5; do grep -lq "xmp:Rating=\"$r\"" "$WORK"/*.xmp 2>/dev/null || { echo "FAIL: no sidecar with rating $r"; fail=1; }; done
for x in "$WORK"/*.xmp; do echo "$(basename "$x"): $(grep -o 'xmp:Rating="[-0-9]*"' "$x") $(grep -o 'xmp:Label="[A-Za-z]*"' "$x")"; done
[ $fail -eq 0 ] && echo "PASS" || exit 1
