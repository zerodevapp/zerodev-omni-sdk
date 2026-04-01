.PHONY: build build-native test test-quick test-live clean fmt lint

SDK_ROOT := $(shell cd ../.. && pwd)
LIB_PATH := $(SDK_ROOT)/zig-out/lib
SYSROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
CGO_FLAGS = CGO_ENABLED=1 CGO_CFLAGS="--sysroot=$(SYSROOT)" CGO_LDFLAGS="--sysroot=$(SYSROOT)"

# Build the native Zig library (ReleaseFast)
build-native:
	cd ../.. && zig build -Doptimize=ReleaseFast

# Build Go package
build: build-native
	$(CGO_FLAGS) go build ./aa/...

# Build example
build-example: build
	cd example && $(CGO_FLAGS) go build -o example .

# Run all unit tests
test: build-native
	$(CGO_FLAGS) go test -v ./aa/...

# Run tests without rebuilding native lib
test-quick:
	$(CGO_FLAGS) go test -v ./aa/...

# Run live E2E test against ZeroDev Sepolia
test-live: build-native
	$(CGO_FLAGS) go test -v -count=1 -run TestSendUserOpSepolia ./aa/

# Clean
clean:
	go clean ./...
	rm -f example/example

# Format
fmt:
	go fmt ./...

# Lint
lint:
	go vet ./...
