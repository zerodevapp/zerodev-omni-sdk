// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GaslessTransfer7702",
    platforms: [.macOS(.v14)],
    dependencies: [
        // NOTE: The sibling gasless-transfer/swift example uses a symlink
        // named `ZeroDevAA` -> `../../../bindings/swift` so that SPM's
        // package-identifier (derived from the directory name) matches the
        // Package.swift declaration `name: "ZeroDevAA"`. Create the same
        // symlink here to build this example:
        //
        //   ln -s ../../../bindings/swift ZeroDevAA
        //
        // Then run `swift build` (or `make build`). The binding's
        // Package.swift references `../../dist/ZeroDevAA.xcframework`, so
        // `make build-xcframework` at the repo root must run at least once.
        .package(path: "ZeroDevAA"),
    ],
    targets: [
        .executableTarget(
            name: "GaslessTransfer7702",
            dependencies: [
                .product(name: "ZeroDevAA", package: "ZeroDevAA"),
            ],
            path: "Sources"
        ),
    ]
)
