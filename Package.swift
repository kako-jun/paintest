// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "paintest",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "paintest",
            path: "Sources/paintest"
        )
    ]
)
