SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

.PHONY: all build run clean

all: run

build:
	SDKROOT=$(SDKROOT) cargo build

run: build
	DYLD_LIBRARY_PATH=../../../zig-out/lib cargo run

clean:
	cargo clean
