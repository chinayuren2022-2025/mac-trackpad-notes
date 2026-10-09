// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackpadStudio",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CMultitouchShim"),
        .executableTarget(
            name: "TrackpadStudio",
            dependencies: ["CMultitouchShim"]
        ),
    ]
)
