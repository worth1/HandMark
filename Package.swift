// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HandMark",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "HandMarkCore",
            path: "Sources/HandMarkCore"
        ),
        .executableTarget(
            name: "HandMark",
            dependencies: ["HandMarkCore"],
            path: "Sources/HandMark",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .testTarget(
            name: "HandMarkCoreTests",
            dependencies: ["HandMarkCore"],
            path: "Tests/HandMarkCoreTests"
        )
    ]
)
