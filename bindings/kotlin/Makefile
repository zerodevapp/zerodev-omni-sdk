.PHONY: build build-native test test-live clean

SDK_ROOT := $(shell cd ../.. && pwd)
LIB_PATH := $(SDK_ROOT)/zig-out/lib
JAVA_HOME ?= /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home

# Build the native Zig library (ReleaseFast)
build-native:
	cd ../.. && zig build -Doptimize=ReleaseFast

# Build Kotlin binding
build: build-native
	JAVA_HOME=$(JAVA_HOME) ./gradlew build -x test

# Run unit tests
test: build-native
	JAVA_HOME=$(JAVA_HOME) ./gradlew test

# Run live E2E test against ZeroDev Sepolia
test-live: build-native
	JAVA_HOME=$(JAVA_HOME) ./gradlew test

# Clean
clean:
	JAVA_HOME=$(JAVA_HOME) ./gradlew clean
