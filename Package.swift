// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Drawzee",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Drawzee",
            dependencies: ["DrawzeeKit"]
        ),
        .target(
            name: "DrawzeeKit"
        ),
        .testTarget(
            name: "DrawzeeKitTests",
            dependencies: ["DrawzeeKit"]
        ),
    ]
)
