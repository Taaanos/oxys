#!/bin/bash
# Cold-launch measurement (F-01; the formal check is M-26).
# Launches the app 5 times. The app prints "launch-to-first-draw: N ms" (process
# start to first drawn frame) and quits itself. Also prints wall time for `open`.
set -euo pipefail

APP="${1:?usage: launch-time.sh path/to/Oxys.app}"
out=$(mktemp)
trap 'rm -f "$out"' EXIT

for i in 1 2 3 4 5; do
  : > "$out"
  start=$(date +%s.%N)
  open -n -W --env OXYS_REPORT_LAUNCH=1 --stdout "$out" "$APP"
  end=$(date +%s.%N)
  printf "run %d: %s, open-to-exit %.0f ms\n" "$i" "$(tr -d '\n' < "$out")" \
    "$(echo "($end - $start) * 1000" | bc)"
done
