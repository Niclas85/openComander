// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenCommanderNTFS",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OpenCommanderNTFS", targets: ["OpenCommanderNTFS"])
    ],
    targets: [
        .target(name: "OpenCommanderNTFS"),
        .testTarget(name: "OpenCommanderNTFSTests", dependencies: ["OpenCommanderNTFS"])
    ]
)
