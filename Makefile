PROJECT   := App/Oxys.xcodeproj
SCHEME    := Oxys
BUILD_DIR := build
APP       := $(BUILD_DIR)/Build/Products/Release/Oxys.app
PACKAGES  := $(sort $(dir $(wildcard Packages/*/Package.swift)))

.PHONY: build test check-arch launch-time clean

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

clean:
	rm -rf $(BUILD_DIR) Packages/*/.build
