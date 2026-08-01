// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FillerKillerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DetectorKit", targets: ["DetectorKit"]),
        .library(name: "SessionKit", targets: ["SessionKit"]),
        .library(name: "SpeechEngine", targets: ["SpeechEngine"]),
    ],
    targets: [
        .target(name: "DetectorKit"),
        .target(name: "SessionKit", dependencies: ["DetectorKit"]),
        // Compiled out (empty module) on platforms without Speech, so the
        // whole package still builds and tests on Linux CI.
        .target(name: "SpeechEngine"),
        .testTarget(name: "DetectorKitTests", dependencies: ["DetectorKit"]),
        .testTarget(name: "SessionKitTests", dependencies: ["SessionKit"]),
    ]
)
