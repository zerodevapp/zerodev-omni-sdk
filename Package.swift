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
            checksum: "fddd5ec50a237b949d005b72f950ccd486903f9b881d9f8ed6b7a13e662bba7c"
        ),
        .target(
            name: "ZeroDevAA",
            dependencies: ["CZeroDevAA"],
            path: "bindings/swift/Sources/ZeroDevAA"
        ),
    ]
)
