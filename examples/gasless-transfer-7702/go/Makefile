SYSROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

.PHONY: all build run clean

all: run

build:
	CGO_ENABLED=1 CGO_CFLAGS="--sysroot=$(SYSROOT)" CGO_LDFLAGS="--sysroot=$(SYSROOT)" go build -o gasless-transfer-7702 .

run: build
	./gasless-transfer-7702

clean:
	rm -f gasless-transfer-7702
