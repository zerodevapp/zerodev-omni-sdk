.PHONY: build build-native test test-live check clean

SDK_ROOT := $(shell cd ../.. && pwd)
LIB_PATH := $(SDK_ROOT)/zig-out/lib
SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

# Build the native Zig library (ReleaseFast)
build-native:
	cd ../.. && zig build -Doptimize=ReleaseFast

# Build Rust binding
build: build-native
	SDKROOT=$(SDKROOT) cargo build

# Type-check without building
check: build-native
	SDKROOT=$(SDKROOT) cargo check

# Run unit tests
test: build-native
	SDKROOT=$(SDKROOT) cargo test

# Run live E2E test against ZeroDev Sepolia
test-live: build-native
	SDKROOT=$(SDKROOT) cargo test --test live_test -- --nocapture

# Clean
clean:
	cargo clean
