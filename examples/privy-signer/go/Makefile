SYSROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

.PHONY: all build run clean

all: run

build:
	CGO_ENABLED=1 CGO_CFLAGS="--sysroot=$(SYSROOT)" CGO_LDFLAGS="--sysroot=$(SYSROOT)" go build -o privy-signer .

run: build
	./privy-signer

clean:
	rm -f privy-signer
