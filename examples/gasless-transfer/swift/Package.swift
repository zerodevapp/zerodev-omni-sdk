// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GaslessTransfer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "ZeroDevAA"),
    ],
    targets: [
        .executableTarget(
            name: "GaslessTransfer",
            dependencies: [
                .product(name: "ZeroDevAA", package: "ZeroDevAA"),
            ],
            path: "Sources"
        ),
    ]
)
