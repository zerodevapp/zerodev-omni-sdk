#!/bin/bash
set -euo pipefail

SDK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$SDK_ROOT/dist"
rm -rf "$OUT"

echo "=== Building xcframework ==="

build_target() {
    local target=$1
    local developer_dir=$2
    local out_dir="$OUT/$target"
    
    echo "  Building $target..."
    mkdir -p "$out_dir"
    
    # Clean zig-out before each target to avoid stale artifacts
    rm -rf "$SDK_ROOT/zig-out"

    # Build (ignore exit code for iOS — static lib succeeds but dylib link fails)
    DEVELOPER_DIR="$developer_dir" zig build -Doptimize=ReleaseFast -Dtarget="$target" -Dstatic-only=true 2>/dev/null || true

    # Find the built static libs in zig-out or cache
    if [ -f "$SDK_ROOT/zig-out/lib/libzerodev_aa.a" ]; then
        cp "$SDK_ROOT/zig-out/lib/libzerodev_aa.a" "$out_dir/"
        cp "$SDK_ROOT/zig-out/lib/libsecp256k1.a" "$out_dir/"
    else
        echo "    WARNING: zig-out not populated, searching cache..."
        # Find the most recent arm64/x86_64 .a in cache
        latest=$(find "$SDK_ROOT/.zig-cache" -name "libzerodev_aa.a" -newer "$SDK_ROOT/build.zig" 2>/dev/null | tail -1)
        if [ -n "$latest" ]; then
            cp "$latest" "$out_dir/"
            # Also find secp256k1
            secp_dir=$(dirname "$latest")
            secp=$(find "$secp_dir" -name "libsecp256k1.a" 2>/dev/null || find "$SDK_ROOT/.zig-cache" -name "libsecp256k1.a" -newer "$SDK_ROOT/build.zig" 2>/dev/null | tail -1)
            [ -n "$secp" ] && cp "$secp" "$out_dir/"
        else
            echo "    ERROR: Could not find built library for $target"
            return 1
        fi
    fi
    
    # Repack with Apple libtool for Xcode compatibility
    for lib in libzerodev_aa.a libsecp256k1.a; do
        if [ -f "$out_dir/$lib" ]; then
            tmpdir=$(mktemp -d)
            cd "$tmpdir"
            ar x "$out_dir/$lib"
            chmod 644 *.o 2>/dev/null || true
            libtool -static -o "$out_dir/$lib" *.o 2>/dev/null
            cd "$SDK_ROOT"
            rm -rf "$tmpdir"
        fi
    done
    
    # Merge into single lib
    libtool -static -o "$out_dir/libZeroDevAA.a" "$out_dir/libzerodev_aa.a" "$out_dir/libsecp256k1.a" 2>/dev/null
    
    echo "  Done: $(lipo -info "$out_dir/libZeroDevAA.a" 2>/dev/null || echo 'built')"
}

# macOS targets (use CommandLineTools)
build_target "aarch64-macos" "/Library/Developer/CommandLineTools"
build_target "x86_64-macos" "/Library/Developer/CommandLineTools"

# iOS targets (requires Xcode for iOS SDK headers)
if [ -d "/Applications/Xcode.app" ]; then
    IOS_SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
    SIM_SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk

    for target_info in "aarch64-ios:$IOS_SDK" "aarch64-ios-simulator:$SIM_SDK" "x86_64-ios-simulator:$SIM_SDK"; do
        target="${target_info%%:*}"
        sdk="${target_info#*:}"
        echo "  Building $target..."
        rm -rf "$SDK_ROOT/zig-out"
        DEVELOPER_DIR=/Library/Developer/CommandLineTools \
        C_INCLUDE_PATH="$sdk/usr/include" \
        zig build -Doptimize=ReleaseFast -Dtarget=$target -Dstatic-only=true \
            --sysroot "$sdk"
        mkdir -p "$OUT/$target"
        cp "$SDK_ROOT/zig-out/lib/libzerodev_aa.a" "$OUT/$target/"
        cp "$SDK_ROOT/zig-out/lib/libsecp256k1.a" "$OUT/$target/"
        # Repack with libtool
        for lib in libzerodev_aa.a libsecp256k1.a; do
            tmpdir=$(mktemp -d)
            cd "$tmpdir"
            ar x "$OUT/$target/$lib"
            chmod 644 *.o 2>/dev/null || true
            libtool -static -o "$OUT/$target/$lib" *.o 2>/dev/null
            cd "$SDK_ROOT"
            rm -rf "$tmpdir"
        done
        libtool -static -o "$OUT/$target/libZeroDevAA.a" "$OUT/$target/libzerodev_aa.a" "$OUT/$target/libsecp256k1.a" 2>/dev/null
        echo "  Done: $(lipo -info "$OUT/$target/libZeroDevAA.a" 2>/dev/null || echo 'built')"
    done
else
    echo "  iOS targets: skipped (Xcode not installed)"
fi

echo ""
echo "=== Creating fat binaries ==="

# macOS universal (arm64 + x86_64)
mkdir -p "$OUT/macos-universal"
lipo -create "$OUT/aarch64-macos/libZeroDevAA.a" "$OUT/x86_64-macos/libZeroDevAA.a" \
     -output "$OUT/macos-universal/libZeroDevAA.a"
echo "  macOS universal: $(lipo -info "$OUT/macos-universal/libZeroDevAA.a")"

# iOS simulator universal (arm64 + x86_64)
if [ -f "$OUT/aarch64-ios-simulator/libZeroDevAA.a" ] && [ -f "$OUT/x86_64-ios-simulator/libZeroDevAA.a" ]; then
    mkdir -p "$OUT/ios-simulator-universal"
    lipo -create "$OUT/aarch64-ios-simulator/libZeroDevAA.a" "$OUT/x86_64-ios-simulator/libZeroDevAA.a" \
         -output "$OUT/ios-simulator-universal/libZeroDevAA.a"
    echo "  iOS sim universal: $(lipo -info "$OUT/ios-simulator-universal/libZeroDevAA.a")"
fi

echo ""
echo "=== Creating xcframework ==="

# Build xcframework args
XCF_ARGS=(-create-xcframework)
XCF_ARGS+=(-library "$OUT/macos-universal/libZeroDevAA.a" -headers "$SDK_ROOT/include")

if [ -f "$OUT/aarch64-ios/libZeroDevAA.a" ]; then
    XCF_ARGS+=(-library "$OUT/aarch64-ios/libZeroDevAA.a" -headers "$SDK_ROOT/include")
fi
if [ -f "$OUT/ios-simulator-universal/libZeroDevAA.a" ]; then
    XCF_ARGS+=(-library "$OUT/ios-simulator-universal/libZeroDevAA.a" -headers "$SDK_ROOT/include")
elif [ -f "$OUT/aarch64-ios-simulator/libZeroDevAA.a" ]; then
    XCF_ARGS+=(-library "$OUT/aarch64-ios-simulator/libZeroDevAA.a" -headers "$SDK_ROOT/include")
fi

XCF_ARGS+=(-output "$OUT/ZeroDevAA.xcframework")

xcodebuild "${XCF_ARGS[@]}"

# Add module map for SPM import
for dir in "$OUT/ZeroDevAA.xcframework"/*/Headers; do
    cat > "$dir/module.modulemap" << 'MODMAP'
module CZeroDevAA {
    header "aa.h"
    export *
}
MODMAP
done

echo ""
echo "=== Packaging ==="
cd "$OUT"
zip -r ZeroDevAA.xcframework.zip ZeroDevAA.xcframework
CHECKSUM=$(shasum -a 256 ZeroDevAA.xcframework.zip | cut -d' ' -f1)
echo "  Zip: $OUT/ZeroDevAA.xcframework.zip"
echo "  SHA256: $CHECKSUM"
echo ""
echo "Done! Update Package.swift with:"
echo "  .binaryTarget(name: \"CZeroDevAA\", path: \"../../dist/ZeroDevAA.xcframework\")"
