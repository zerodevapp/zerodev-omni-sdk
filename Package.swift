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
            checksum: "ec95bf2cd8b42ee23b34dd7560f948b63b5c3724606ee45efbb44a5e6e9bd1ff"
        ),
        .target(
            name: "ZeroDevAA",
            dependencies: ["CZeroDevAA"],
            path: "bindings/swift/Sources/ZeroDevAA"
        ),
    ]
)
