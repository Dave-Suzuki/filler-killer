// swift-tools-version: 5.9
// Mac-only package: depends on GRDB (which doesn't build on Linux), so it is
// separate from FillerKillerKit — Linux CI tests the pure package only.
import PackageDescription

let package = Package(
    name: "FillerKillerMacKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SessionStore", targets: ["SessionStore"])
    ],
    dependencies: [
        .package(path: "../FillerKillerKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "SessionStore",
            dependencies: [
                .product(name: "DetectorKit", package: "FillerKillerKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "SessionStoreTests", dependencies: ["SessionStore"]),
    ]
)
