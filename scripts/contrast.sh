#!/bin/zsh
# D-01: the contrast probe. Opens the test frames (TestData/design, made by scripts/make-contrast-frames.py) with the
# `contrast` bench scenario, captures the window each time the app asks, then runs scripts/contrast-report.py, which
# writes docs/design/contrast.md and exits 1 when a label fails.
# Usage: [QUICK=1] scripts/contrast.sh [path/to/Oxys.app]
# The terminal needs the Screen Recording permission once (System Settings > Privacy & Security), for `screencapture -l`.
# Run it again with Reduce Transparency and Increase Contrast on (System Settings > Accessibility > Display): each
# combination gets its own section in the report.
set -eu
cd "$(dirname "$0")/.."
APP=${1:-build/Build/Products/Bench/Oxys.app}
frames=TestData/design
[ -f $frames/split.tif ] || scripts/make-contrast-frames.py $frames >/dev/null
out=build/contrast/$(date +%Y%m%d-%H%M%S)
mkdir -p $out
out=$(cd $out && pwd)
# The probe must leave the photo folder as it was: names, sizes and dates.
listing() { find $frames -type f -exec stat -f '%N %z %m' {} + | sort }
before=$(listing)

# The probe changes view settings the app remembers; put the user's back when the script ends, even when it is stopped.
domain=com.thanosam.Oxys
keys=(infoLevel showHistogram ratingCorner autoAdvance showInspector)
typeset -A saved
for key in $keys; do saved[$key]=$(defaults read $domain $key 2>/dev/null || true); done
restore() {
  pkill -x Oxys 2>/dev/null || true
  for key in $keys; do
    value=${saved[$key]}
    if [ -z "$value" ]; then defaults delete $domain $key 2>/dev/null || true
    elif [ $key = infoLevel ]; then defaults write $domain $key -int $value
    elif [ $value = 1 ]; then defaults write $domain $key -bool true
    else defaults write $domain $key -bool false
    fi
  done
}
trap restore EXIT INT TERM

pkill -x Oxys 2>/dev/null || true
# QUICK=1: only the white and yellow frames, no edge positions, and the report goes to $out/docs, not to docs/design.
quick=(); docs=()
if [ -n "${QUICK:-}" ]; then quick=(--env OXYS_CONTRAST_QUICK=1); docs=(--docs "$out/docs"); fi
open -n -W $quick --env OXYS_BENCH=contrast --env OXYS_OPEN="$PWD/$frames" --env OXYS_CONTRAST_DIR="$out" \
  --env OXYS_PERF_LOG="$out/bench.tsv" "$APP" --args -rawMode onDemand &
app=$!
n=0
while :; do
  request=$out/req-$n.json
  if [ -f $request ]; then
    window=$(jq -r .window $request); image=$(jq -r .image $request)
    # The window can be between two states for a moment; try again before giving up.
    for try in 1 2 3 4 5; do
      ! screencapture -l$window -o -x $out/capture.tmp.png 2>/dev/null || break
      sleep 0.3
    done
    if [ ! -f $out/capture.tmp.png ]; then
      echo "contrast: cannot capture window $window. Does the terminal have the Screen Recording permission?" >&2
      kill $app 2>/dev/null; exit 1
    fi
    mv $out/capture.tmp.png $out/$image
    n=$((n + 1))
    continue
  fi
  [ ! -f $out/done ] || break
  kill -0 $app 2>/dev/null || break
  sleep 0.05
done
wait $app || true
[ -f $out/done ] || { echo "contrast: the probe did not finish ($out)" >&2; exit 1 }
[ "$before" = "$(listing)" ] || { echo "contrast: the probe changed files in $frames" >&2; exit 1 }
echo "contrast: $n captures in $out"
python3 scripts/contrast-report.py $docs $out
