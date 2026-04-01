.PHONY: build build-native test test-live clean

SDK_ROOT := $(shell cd ../.. && pwd)
SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
export ZERODEV_SDK_ROOT := $(SDK_ROOT)

# Build the native Zig library (ReleaseFast)
build-native:
	cd ../.. && zig build -Doptimize=ReleaseFast

# Build Swift binding
build: build-native
	SDKROOT=$(SDKROOT) swift build --target ZeroDevAA

# Run unit tests
test: build-native
	SDKROOT=$(SDKROOT) swift test

# Run live E2E test against ZeroDev Sepolia
test-live: build-native
	SDKROOT=$(SDKROOT) swift run LiveTest

# Clean
clean:
	swift package clean
