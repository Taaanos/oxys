PROJECT   := App/Oxys.xcodeproj
SCHEME    := Oxys
BUILD_DIR := build
APP       := $(BUILD_DIR)/Build/Products/Release/Oxys.app
PACKAGES  := $(sort $(dir $(wildcard Packages/*/Package.swift)))

.PHONY: build test check-arch launch-time corpus manifest bench-folders perf-selftest perf-report clean

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
perf-selftest:
	scripts/perf-record.sh --selftest

perf-report:
	scripts/perf-record.sh --report $(TRACE)

clean:
	rm -rf $(BUILD_DIR) Packages/*/.build
