// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VisionMCP",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VisionMCP", path: "Sources/VisionMCP")
    ]
)
