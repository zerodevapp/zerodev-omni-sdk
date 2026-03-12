.PHONY: build build-release test build-go run-go build-rust test-rust-live build-swift test-swift-live build-kotlin test-kotlin-live clean test-live test-go-live

# Load .env if it exists (Make can include KEY=VALUE files directly)
ifneq (,$(wildcard .env))
include .env
export
endif

SYSROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
CGO_EXTRA_FLAGS = $(if $(SYSROOT),--sysroot=$(SYSROOT),)
SWIFT_SDKROOT ?= $(SYSROOT)

# Build the Zig library (static + dynamic) — release mode for FFI consumers
build:
	zig build -Doptimize=ReleaseFast

# Build debug mode (for Zig development)
build-debug:
	zig build

# Run all Zig tests
test:
	zig build test

# Build the static library, then build Go example
build-go: build
	cd bindings/go/example && \
		CGO_ENABLED=1 \
		CGO_CFLAGS="$(CGO_EXTRA_FLAGS)" \
		CGO_LDFLAGS="$(CGO_EXTRA_FLAGS)" \
		go build -o example .

# Run Go example
run-go: build-go
	cd bindings/go/example && ./example

# Install test infrastructure dependencies
test-infra-install:
	cd test/infra && pnpm install

# Run E2E tests (starts Anvil + Alto, runs Zig tests, stops)
test-e2e: test-infra-install
	cd test/infra && node harness.mjs test

# Start test infrastructure (Anvil + Alto) for manual testing
test-infra-start: test-infra-install
	cd test/infra && node harness.mjs start

# Run live tests against ZeroDev Sepolia (requires ZERODEV_PROJECT_ID)
test-live:
	ZERODEV_PROJECT_ID=$(ZERODEV_PROJECT_ID) \
	E2E_PRIVATE_KEY=$(or $(E2E_PRIVATE_KEY),ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80) \
	zig build test-live

# Run Go live E2E test against ZeroDev Sepolia (requires ZERODEV_PROJECT_ID)
test-go-live: build
	cd bindings/go && \
		CGO_ENABLED=1 \
		CGO_CFLAGS="$(CGO_EXTRA_FLAGS)" \
		CGO_LDFLAGS="$(CGO_EXTRA_FLAGS)" \
		go test -v -count=1 -run TestSendUserOpSepolia ./aa/

# Build Rust binding (requires static lib from `make build`)
build-rust: build
	cd bindings/rust && cargo build

# Run Rust live E2E test against ZeroDev Sepolia (requires ZERODEV_PROJECT_ID)
test-rust-live: build
	cd bindings/rust && \
		ZERODEV_PROJECT_ID=$(ZERODEV_PROJECT_ID) \
		E2E_PRIVATE_KEY=$(or $(E2E_PRIVATE_KEY),ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80) \
		cargo test --test live_test -- --nocapture

# Build Swift binding (requires static lib from `make build`)
build-swift: build
	cd bindings/swift && \
		SDKROOT=$(SWIFT_SDKROOT) \
		swift build --target ZeroDevAA

# Run Swift live E2E test against ZeroDev Sepolia (requires ZERODEV_PROJECT_ID)
test-swift-live: build
	cd bindings/swift && \
		SDKROOT=$(SWIFT_SDKROOT) \
		ZERODEV_PROJECT_ID=$(ZERODEV_PROJECT_ID) \
		E2E_PRIVATE_KEY=$(or $(E2E_PRIVATE_KEY),ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80) \
		swift run LiveTest

# Build Kotlin binding (requires dynamic lib from `make build`)
build-kotlin: build
	cd bindings/kotlin && \
		JAVA_HOME=$(or $(JAVA_HOME),/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home) \
		./gradlew build -x test

# Run Kotlin live E2E test against ZeroDev Sepolia (requires ZERODEV_PROJECT_ID)
test-kotlin-live: build
	cd bindings/kotlin && \
		JAVA_HOME=$(or $(JAVA_HOME),/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home) \
		ZERODEV_PROJECT_ID=$(ZERODEV_PROJECT_ID) \
		E2E_PRIVATE_KEY=$(or $(E2E_PRIVATE_KEY),ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80) \
		./gradlew test

# Clean build artifacts
clean:
	rm -rf zig-out zig-cache .zig-cache
	rm -f bindings/go/example/example
	cd bindings/rust && cargo clean 2>/dev/null || true
	cd bindings/swift && rm -rf .build 2>/dev/null || true
	cd bindings/kotlin && rm -rf build .gradle 2>/dev/null || true
