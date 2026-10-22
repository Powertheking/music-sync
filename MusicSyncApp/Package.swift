// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MusicSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MusicSync", path: "Sources/MusicSync")
    ]
)
