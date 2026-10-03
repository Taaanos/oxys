#!/bin/zsh
# M-26: runs one in-app scenario (see PerfBench.swift) on a folder and prints its table.
# Usage: scripts/perf-bench.sh <scenario> <folder> [path/to/Oxys.app]
# Scenarios that write sidecars (cull, compare) run on an APFS clone, so the bench folders stay clean.
# Environment: BENCH_CLEAR_THUMBS=1 empties the disk thumbnail cache first (a cold first run).
#   BENCH_LOG=<file>          write the run's numbers there (the gate, scripts/perf-gate.sh, sets it); the frame log goes to <file>.frames
#   BENCH_QUIET=1             do not print the table
#   OXYS_BENCH_DELAY_MS=<n>   every frame load waits n ms first, as slow media would (P-01)
set -eu
cd "$(dirname "$0")/.."
scenario=${1:?scenario}; folder=${2:?folder}
APP=${3:-build/Build/Products/Bench/Oxys.app}
log=${BENCH_LOG:-build/traces/bench-$scenario-$(date +%H%M%S).tsv}
case $log in /*) ;; *) log=$PWD/$log ;; esac
mkdir -p "$(dirname "$log")"
work=$(cd "$folder" && pwd)
if [ "$scenario" = cull ] || [ "$scenario" = compare ]; then
  work=$(mktemp -d)/clone
  cp -c -R "$folder" "$work"
fi
if [ "${BENCH_CLEAR_THUMBS:-}" = 1 ]; then
  rm -rf ~/Library/Caches/dev.oxys.Oxys/thumbnails
fi
(cd Packages/Diagnostics && swift build -c release >/dev/null)
pkill -x Oxys 2>/dev/null || true
delay=()
[ -z "${OXYS_BENCH_DELAY_MS:-}" ] || delay=(--env OXYS_BENCH_DELAY_MS="$OXYS_BENCH_DELAY_MS")
# The user's RAW setting must not change a measurement: every scenario but the develop ones runs in the default mode.
mode=(--args -rawMode onDemand)
case $scenario in develop*) mode=() ;; esac
open -n -W --env OXYS_BENCH="$scenario" --env OXYS_OPEN="$work" --env OXYS_PERF_LOG="$log" \
  --env OXYS_FRAME_LOG="$log.frames" "${delay[@]}" "$APP" "${mode[@]}"
{ [ "$scenario" != cull ] && [ "$scenario" != compare ]; } || rm -rf "$(dirname "$work")"
grep -q '^done' "$log" || { echo "WARNING: $scenario run did not finish ($log)" >&2; [ -z "${BENCH_QUIET:-}" ] || exit 1; }
[ -z "${BENCH_QUIET:-}" ] || exit 0
echo "== $scenario on $(basename "$folder") ($log)"
Packages/Diagnostics/.build/release/PerfTool log "$log"
