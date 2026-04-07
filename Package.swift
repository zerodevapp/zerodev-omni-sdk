// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZeroDevAA",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ZeroDevAA", targets: ["ZeroDevAA"]),
    ],
    targets: [
        .binaryTarget(
            name: "CZeroDevAA",
            url: "https://github.com/zerodevapp/zerodev-omni-sdk/releases/download/v0.0.1-alpha.1/ZeroDevAA.xcframework.zip",
            checksum: "89da8a1f099c6073c6d11992d68f5180f1eb5d4b4c4336cb83adcc37b1ff0fc4"
        ),
        .target(
            name: "ZeroDevAA",
            dependencies: ["CZeroDevAA"],
            path: "bindings/swift/Sources/ZeroDevAA"
        ),
    ]
)
