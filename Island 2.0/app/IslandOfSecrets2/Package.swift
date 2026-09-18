// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IslandOfSecrets2",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "IslandOfSecrets2",
            path: "Sources/IslandOfSecrets2"
        )
    ]
)
