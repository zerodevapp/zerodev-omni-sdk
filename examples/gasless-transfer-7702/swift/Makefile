SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
ZERODEV_SDK_ROOT ?= $(shell cd ../../.. && pwd)

.PHONY: all build run clean link

all: run

# SPM derives a package's identifier from its directory name when resolving
# `.package(path:)`. We symlink `ZeroDevAA -> ../../../bindings/swift` so the
# identifier matches the binding's `name: "ZeroDevAA"`. Mirrors the sibling
# `examples/gasless-transfer/swift` example.
#
# The binding's Package.swift references `../../dist/ZeroDevAA.xcframework`;
# SPM resolves it relative to the symlink's location, not the link target,
# so from `examples/gasless-transfer-7702/swift/ZeroDevAA/` SPM looks for
# `examples/gasless-transfer-7702/dist/ZeroDevAA.xcframework`. Symlink
# `../dist -> ../../dist` (the repo-root dist directory) so
# `make build-xcframework` at the repo root lands the xcframework where SPM
# expects it.
link:
	@test -e ZeroDevAA || ln -s ../../../bindings/swift ZeroDevAA
	@test -e ../dist || ln -s ../../dist ../dist

build: link
	SDKROOT=$(SDKROOT) ZERODEV_SDK_ROOT=$(ZERODEV_SDK_ROOT) swift build

run: build
	SDKROOT=$(SDKROOT) ZERODEV_SDK_ROOT=$(ZERODEV_SDK_ROOT) swift run

clean:
	rm -f ZeroDevAA
	swift package clean
