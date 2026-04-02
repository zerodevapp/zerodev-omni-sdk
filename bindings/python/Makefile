.PHONY: build build-native install test test-live clean

SDK_ROOT := $(shell cd ../.. && pwd)
export ZERODEV_SDK_ROOT := $(SDK_ROOT)

# Build the native Zig library (ReleaseFast)
build-native:
	cd ../.. && zig build -Doptimize=ReleaseFast

# Install Python package in editable mode
install:
	pip install -e .

# Build native + install
build: build-native install

# Run tests
test: build-native
	python -c "from zerodev_aa import Context, Signer, Call; print('Import OK')"

# Run live E2E test against ZeroDev Sepolia
test-live: build-native
	python -c "\
from zerodev_aa import *; import os; \
ctx = Context(os.environ['ZERODEV_PROJECT_ID']); \
s = Signer.generate(); \
a = ctx.new_account(s); \
print('Address:', a.get_address_hex()); \
h = a.send_user_op([Call(target=a.get_address().bytes)]); \
print('Hash:', h.hex()); \
r = a.wait_for_receipt(h); \
print('Success:', r.get('success')); \
a.close(); s.close(); ctx.close()"

# Clean
clean:
	pip uninstall -y zerodev-aa 2>/dev/null || true
