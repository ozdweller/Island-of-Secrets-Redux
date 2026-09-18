// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IslandOfSecrets",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "IslandOfSecrets",
            path: "Sources/IslandOfSecrets"
        )
    ]
)
