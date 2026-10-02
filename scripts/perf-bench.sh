#!/bin/zsh
# M-26: runs one in-app scenario (see PerfBench.swift) on a folder and prints its table.
# Usage: scripts/perf-bench.sh <scenario> <folder> [path/to/Oxys.app]
# Scenarios that write sidecars (cull, compare) run on an APFS clone, so the bench folders stay clean.
# Environment: BENCH_CLEAR_THUMBS=1 empties the disk thumbnail cache first (a cold first run).
set -eu
cd "$(dirname "$0")/.."
scenario=${1:?scenario}; folder=${2:?folder}
APP=${3:-build/Build/Products/Release/Oxys.app}
log=build/traces/bench-$scenario-$(date +%H%M%S).tsv
mkdir -p build/traces
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
open -n -W --env OXYS_BENCH="$scenario" --env OXYS_OPEN="$work" --env OXYS_PERF_LOG="$PWD/$log" \
  --env OXYS_FRAME_LOG="$PWD/$log.frames" "$APP"
{ [ "$scenario" != cull ] && [ "$scenario" != compare ]; } || rm -rf "$(dirname "$work")"
echo "== $scenario on $(basename "$folder") ($log)"
grep -q '^done' "$log" || echo "WARNING: run did not finish"
Packages/Diagnostics/.build/release/PerfTool log "$log"
