PROJECT   := App/Oxys.xcodeproj
SCHEME    := Oxys
BUILD_DIR := build
APP       := $(BUILD_DIR)/Build/Products/Release/Oxys.app
PACKAGES  := $(sort $(dir $(wildcard Packages/*/Package.swift)))

.PHONY: build test check-arch launch-time corpus manifest bench-folders perf-bench perf-gate perf-selftest perf-report sidecar-stress extract-bench sidecar-gate contrast contrast-selftest ui-walk ui-walk-compare clean

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath $(BUILD_DIR) build

test:
	@set -e; for p in $(PACKAGES); do \
		echo "== $$p"; (cd $$p && swift test); \
	done

check-arch: build
	lipo -archs $(APP)/Contents/MacOS/Oxys

launch-time: build
	scripts/launch-time.sh $(APP)

# F-02: test corpus and performance harness
corpus:
	scripts/fetch-corpus.sh
	$(MAKE) manifest

manifest:
	cd Packages/Containers && swift build -c release --product CorpusManifest
	Packages/Containers/.build/release/CorpusManifest TestData > TestData/manifest.json
	@jq -r '.[] | [.file[0:48], .format, (.make // "?"), (.model // "?"), ((.megapixels | if . == null then "?" else tostring end) + " MP"), (.previews | map("\(.width)x\(.height)") | join(" "))] | @tsv' TestData/manifest.json

bench-folders: manifest
	scripts/make-bench.sh

# Latency table for a run: scripts/perf-record.sh <app> [seconds] records and prints it;
# `make perf-report TRACE=build/traces/x.trace` prints it for an existing trace.
# M-26: one in-app scenario, e.g. `make perf-bench SCENARIO=nav-cold FOLDER=TestData/bench/24mp-1000`.
perf-bench: build
	scripts/perf-bench.sh $(SCENARIO) $(FOLDER)

# P-01: every scenario in scripts/perf-targets.tsv, 3 runs each, held to the PRD limits; exits 1 on a fail.
# `make perf-gate FOLDER=TestData/bench/real-drone-840`. PERF_GATE_WARM=1 skips the `sudo purge` prompts.
perf-gate: build
	scripts/perf-gate.sh $(FOLDER)

perf-selftest:
	scripts/perf-record.sh --selftest

perf-report:
	scripts/perf-record.sh --report $(TRACE)

# M-08: 1,000 random decisions over a minute through the write queue, then every sidecar is checked.
sidecar-stress:
	cd Packages/Sidecar && swift run -c release SidecarStress stress 60 1000

# V-13: extracts the embedded JPEGs of every RAW in FOLDER (default: the hires bench folder), times it against
# `cp -R` of the same bytes. EXTRA=--exact for exact bytes; EXTRA=--verify with PREVIEW_ORACLE set compares with the oracle.
extract-bench:
	cd Packages/Library && swift run -c release ExtractBench $(abspath $(or $(FOLDER),TestData/bench/hires-1000)) $(EXTRA)

# M-25: 10,000 real file writes with outside writers and killed writers; exits 1 on any damage.
sidecar-gate:
	cd Packages/Sidecar && swift build -c release --product SidecarStress && .build/release/SidecarStress gate Tests/Fixtures/xmp/hand-written/lightroom-style-crs-3star-red.xmp 10000

# D-01: every label on the photo over the test frames, in Loupe and Compare; writes docs/design/contrast.md, exits 1 on a fail.
# The terminal needs the Screen Recording permission once. Run again with Reduce Transparency and Increase Contrast on.
contrast: build
	scripts/contrast.sh

contrast-selftest:
	python3 scripts/contrast-report.py --selftest

clean:
	rm -rf $(BUILD_DIR) Packages/*/.build

# Key-only walk of the core workflow against the built app (needs Accessibility permission for the terminal).
ui-walk:
	scripts/ui-walk.sh

ui-walk-compare:
	scripts/ui-walk-compare.sh
