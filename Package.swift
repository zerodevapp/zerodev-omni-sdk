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
            url: "https://github.com/zerodevapp/zerodev-omni-sdk/releases/download/v0.0.1-alpha/ZeroDevAA.xcframework.zip",
            checksum: "b6c8c9aac92848b6f1d3ca445423646fc5faf1f6e6d46aa4b3b308f2b1ba5e1b"
        ),
        .target(
            name: "ZeroDevAA",
            dependencies: ["CZeroDevAA"],
            path: "bindings/swift/Sources/ZeroDevAA"
        ),
    ]
)
