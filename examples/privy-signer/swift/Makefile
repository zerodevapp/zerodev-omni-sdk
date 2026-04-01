SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
ZERODEV_SDK_ROOT ?= $(shell cd ../../.. && pwd)

.PHONY: all build run clean

all: run

build:
	SDKROOT=$(SDKROOT) ZERODEV_SDK_ROOT=$(ZERODEV_SDK_ROOT) swift build

run: build
	SDKROOT=$(SDKROOT) ZERODEV_SDK_ROOT=$(ZERODEV_SDK_ROOT) swift run

clean:
	swift package clean
