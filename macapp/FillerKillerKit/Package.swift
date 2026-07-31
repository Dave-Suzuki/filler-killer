// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FillerKillerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DetectorKit", targets: ["DetectorKit"])
    ],
    targets: [
        .target(name: "DetectorKit"),
        .testTarget(name: "DetectorKitTests", dependencies: ["DetectorKit"]),
    ]
)
