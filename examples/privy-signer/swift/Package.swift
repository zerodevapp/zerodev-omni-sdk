// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrivySigner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "ZeroDevAA"),
    ],
    targets: [
        .executableTarget(
            name: "PrivySigner",
            dependencies: [
                .product(name: "ZeroDevAA", package: "ZeroDevAA"),
            ],
            path: "Sources"
        ),
    ]
)
