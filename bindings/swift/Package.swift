// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZeroDevAA",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZeroDevAA", targets: ["ZeroDevAA"]),
    ],
    targets: [
        .systemLibrary(
            name: "CZeroDevAA",
            path: "Sources/CZeroDevAA"
        ),
        .target(
            name: "ZeroDevAA",
            dependencies: ["CZeroDevAA"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I../../include"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "../../zig-out/lib/libzerodev_aa.a",
                    "../../zig-out/lib/libsecp256k1.a",
                ]),
                .linkedLibrary("c"),
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "LiveTest",
            dependencies: ["ZeroDevAA"],
            path: "Tests/ZeroDevAATests"
        ),
    ]
)
