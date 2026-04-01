// swift-tools-version: 6.0
import PackageDescription
import Foundation

let repoRoot = ProcessInfo.processInfo.environment["ZERODEV_SDK_ROOT"]
    ?? ({
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return url.appendingPathComponent("../..").standardized.path
    })()
let libDir = repoRoot + "/zig-out/lib"
let includeDir = repoRoot + "/include"

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
                .unsafeFlags(["-Xcc", "-I\(includeDir)"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "\(libDir)/libzerodev_aa.a",
                    "\(libDir)/libsecp256k1.a",
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
