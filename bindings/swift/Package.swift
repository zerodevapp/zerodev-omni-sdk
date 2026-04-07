// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZeroDevAA",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ZeroDevAA", targets: ["ZeroDevAA"]),
    ],
    targets: [
        // Pre-built xcframework containing libzerodev_aa + libsecp256k1 + aa.h
        // Build locally: make build-xcframework (from repo root)
        // Release: replace path with url + checksum for remote SPM
        .binaryTarget(
            name: "CZeroDevAA",
            path: "../../dist/ZeroDevAA.xcframework"
        ),
        .target(
            name: "ZeroDevAA",
            dependencies: ["CZeroDevAA"],
            path: "Sources/ZeroDevAA"
        ),
        .executableTarget(
            name: "LiveTest",
            dependencies: ["ZeroDevAA"],
            path: "Tests/ZeroDevAATests"
        ),
    ]
)
