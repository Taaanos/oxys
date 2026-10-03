#!/bin/zsh
# P-01: runs every performance scenario in scripts/perf-targets.tsv and holds the numbers to the PRD limits.
# Usage: scripts/perf-gate.sh [folder]          (default TestData/bench/24mp-1000; or set FOLDER=…)
#   make perf-gate FOLDER=TestData/bench/real-drone-840
# Each scenario runs PERF_GATE_RUNS times (default 3) and the gate value is the median run. Exit 1 when a row
# fails or has no number. The table is also saved in build/perf-gate/<stamp>/gate.txt, with every run's log.
#
# Cold scenarios (`open`, `nav-cold`) stop before each run and ask you to run `sudo purge`, so the file cache is
# empty. PERF_GATE_WARM=1 skips that (the numbers are then warm-cache and the table says so).
# Other environment: PERF_GATE_ONLY="nav-cold cull" runs only those scenarios; PERF_GATE_DELAY_MS=200 sets the
# loader delay of the "-slow" scenarios; PERF_GATE_APP=<path> uses another build of the app.
# Folders named in the targets file (scan-5000, grid-10000) come from TestData/bench/ and must exist.
set -eu
set -o pipefail
cd "$(dirname "$0")/.."

folder=${1:-${FOLDER:-TestData/bench/24mp-1000}}
runs=${PERF_GATE_RUNS:-3}
app=${PERF_GATE_APP:-build/Build/Products/Bench/Oxys.app}
targets=scripts/perf-targets.tsv
cold_scenarios=(open nav-cold)
stamp=$(date +%Y%m%d-%H%M%S)
out=build/perf-gate/$stamp
mkdir -p "$out"

[ -d "$folder" ] || { echo "no folder $folder (make bench-folders, or see STORIES P-01 for the real shoot)"; exit 2; }
[ -d "$app" ] || { echo "no app at $app (make build)"; exit 2; }
(cd Packages/Diagnostics && swift build -c release >/dev/null)
tool=Packages/Diagnostics/.build/release/PerfTool

# One group per distinct scenario and folder, in the order of the targets file.
groups=("${(@f)$(awk -F'\t' '!/^#/ && NF >= 5 { print $1 "\t" $6 }' "$targets" | awk '!seen[$0]++')}")

specs=()
warm_note=cold
[ -z "${PERF_GATE_WARM:-}" ] || warm_note=warm
for group in "${groups[@]}"; do
  scenario=${group%%$'\t'*}
  named=${group#*$'\t'}
  if [ -n "${PERF_GATE_ONLY:-}" ] && [[ " $PERF_GATE_ONLY " != *" $scenario "* ]]; then continue; fi
  base=${scenario%-slow}
  target_folder=$folder
  key=$scenario
  if [ -n "$named" ]; then
    target_folder=TestData/bench/$named
    key=$scenario@$named
    [ -d "$target_folder" ] || { echo "no folder $target_folder (make bench-folders)"; exit 2; }
  fi
  is_cold=0
  [[ " ${cold_scenarios[*]} " == *" $base "* ]] && is_cold=1
  logs=()
  for ((run = 1; run <= runs; run++)); do
    log=$PWD/$out/${key//@/_}-$run.tsv
    logs+=("$log")
    echo "== $key run $run of $runs ($target_folder)"
    if [ "$scenario" = launch ]; then
      for _ in 1 2 3 4 5; do
        scripts/launch-time.sh "$app" | sed -n 's/.*launch-to-first-draw: *\([0-9.]*\) *ms.*/launch-to-first-draw\t\1/p' >> "$log"
      done
      continue
    fi
    if [ "$is_cold" = 1 ] && [ -z "${PERF_GATE_WARM:-}" ]; then
      [ -t 0 ] || { echo "cold scenario needs a terminal: run 'sudo purge' and set PERF_GATE_WARM=1 to skip"; exit 2; }
      read -r "?Run 'sudo purge' in another terminal, then press Return: "
    fi
    delay=()
    [ "$base" = "$scenario" ] || delay=(env OXYS_BENCH_DELAY_MS="${PERF_GATE_DELAY_MS:-200}")
    "${delay[@]}" env BENCH_LOG="$log" BENCH_QUIET=1 scripts/perf-bench.sh "$base" "$target_folder" "$app" \
      || echo "run failed; its rows will show no data"
  done
  specs+=("$key=${(j:,:)logs}")
done

echo
files=$(find "$folder" -type f | wc -l | tr -d ' '); size=$(du -sh "$folder" | cut -f1)
{
  echo "Performance gate, $stamp: $folder ($files files, $size), $runs runs per scenario, cold scenarios $warm_note"
  echo
  "$tool" gate "$targets" "${specs[@]}"
} | tee "$out/gate.txt"
