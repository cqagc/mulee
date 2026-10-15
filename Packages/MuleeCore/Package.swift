// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MuleeCore",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MuleeCore", targets: ["MuleeCore"])
    ],
    targets: [
        .target(name: "MuleeCore", resources: [.process("Resources")]),
        .testTarget(name: "MuleeCoreTests", dependencies: ["MuleeCore"])
    ]
)
