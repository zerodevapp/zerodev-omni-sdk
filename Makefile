.PHONY: build build-release test build-go run-go build-rust test-rust-live build-swift test-swift-live build-kotlin test-kotlin-live clean test-live test-go-live

# Load .env if it exists (Make can include KEY=VALUE files directly)
ifneq (,$(wildcard .env))
include .env
export
endif

SYSROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
CGO_EXTRA_FLAGS = $(if $(SYSROOT),--sysroot=$(SYSROOT),)
SWIFT_SDKROOT ?= $(SYSROOT)

# Force Zig to use CommandLineTools SDK (not Xcode.app) for libc linkage
ZIG_ENV = $(if $(wildcard /Library/Developer/CommandLineTools),DEVELOPER_DIR=/Library/Developer/CommandLineTools)

# Build the Zig library (static + dynamic) — release mode for FFI consumers
build:
	$(ZIG_ENV) zig build -Doptimize=ReleaseFast
ifeq ($(shell uname),Darwin)
	@# Repack .a archives with Apple libtool for Xcode compatibility
	@# (Zig's archiver produces members that aren't 8-byte aligned)
	@for lib in libzerodev_aa.a libsecp256k1.a; do \
		if [ -f zig-out/lib/$$lib ]; then \
			tmpdir=$$(mktemp -d) && \
			cd "$$tmpdir" && \
			ar x "$(CURDIR)/zig-out/lib/$$lib" && \
			chmod 644 *.o && \
			libtool -static -o "$(CURDIR)/zig-out/lib/$$lib" *.o 2>/dev/null && \
			cd "$(CURDIR)" && \
			rm -r "$$tmpdir"; \
		fi; \
	done
endif

# Build xcframework for Swift (macOS universal, no unsafeFlags)
build-xcframework:
	bash scripts/build-xcframework.sh

# Build debug mode (for Zig development)
build-debug:
	$(ZIG_ENV) zig build

# Run all Zig tests
test:
	$(ZIG_ENV) zig build test

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
	$(ZIG_ENV) zig build test-live

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

# Build Kotlin binding (compiles JNI bridge + links with static libs)
build-kotlin: build
	@# Compile JNI bridge into the dynamic lib (overwrites Zig's version)
	@JAVA_HOME=$(or $(JAVA_HOME),/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home) && \
	clang -shared -o zig-out/lib/libzerodev_aa.dylib \
		-I"$$JAVA_HOME/include" -I"$$JAVA_HOME/include/darwin" -Iinclude \
		bindings/kotlin/jni/zerodev_aa_jni.c \
		-Wl,-force_load,zig-out/lib/libzerodev_aa.a \
		-Wl,-force_load,zig-out/lib/libsecp256k1.a
	cd bindings/kotlin && \
		JAVA_HOME=$(or $(JAVA_HOME),/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home) \
		./gradlew build -x test

# Run Kotlin live E2E test against ZeroDev Sepolia (requires ZERODEV_PROJECT_ID)
test-kotlin-live: build-kotlin
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
