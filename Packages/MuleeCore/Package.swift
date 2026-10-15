// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MuleeCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MuleeCore", targets: ["MuleeCore"])
    ],
    targets: [
        .target(name: "MuleeCore"),
        .testTarget(name: "MuleeCoreTests", dependencies: ["MuleeCore"])
    ]
)
