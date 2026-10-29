// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EventPostProbe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "EventPostProbe", path: "Sources/EventPostProbe")
    ]
)
