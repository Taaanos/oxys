#!/bin/bash
# F-02: record an Instruments trace of Oxys's signposts and print the latency table.
#   scripts/perf-record.sh path/to/Oxys.app [seconds]      launch the app, record for N seconds (default 60)
#   scripts/perf-record.sh --selftest                       record PerfTool's synthetic intervals (checks the pipeline)
#   scripts/perf-record.sh --report existing.trace          just print the table for a trace
# Traces go to build/traces/. Drive the app yourself during the recording (arrow through a bench folder).
set -euo pipefail
cd "$(dirname "$0")/.."
(cd Packages/Diagnostics && swift build -c release >/dev/null)
tool=Packages/Diagnostics/.build/release/PerfTool
mkdir -p build/traces
trace="build/traces/$(date +%Y%m%d-%H%M%S).trace"

case "${1:-}" in
  --report) "$tool" report "${2:?trace path}"; exit ;;
  --selftest)
    xctrace record --template Logging --output "$trace" --no-prompt --launch -- "$tool" selftest >/dev/null ;;
  "") echo "usage: perf-record.sh <Oxys.app> [seconds] | --selftest | --report <trace>"; exit 2 ;;
  *)
    xctrace record --template Logging --output "$trace" --no-prompt --time-limit "${2:-60}s" --launch -- "$1" >/dev/null ;;
esac
echo "trace: $trace"
"$tool" report "$trace"
