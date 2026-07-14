// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TapInk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TapInk",
            dependencies: ["TapInkKit"]
        ),
        .target(
            name: "TapInkKit"
        ),
        .testTarget(
            name: "TapInkKitTests",
            dependencies: ["TapInkKit"]
        ),
    ]
)
