// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "paintest",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .target(
            name: "paintestCore",
            path: "Sources/paintestCore"
        ),
        .executableTarget(
            name: "paintest",
            dependencies: ["paintestCore"],
            path: "Sources/paintest"
        ),
        .testTarget(
            name: "paintestCoreTests",
            dependencies: ["paintestCore"],
            path: "Tests/paintestCoreTests"
        )
    ]
)
