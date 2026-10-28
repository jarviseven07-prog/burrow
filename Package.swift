// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CodeIslandCore",
            path: "Sources/CodeIslandCore"
        ),
        .executableTarget(
            name: "CodeIsland",
            dependencies: ["CodeIslandCore"],
            path: "Sources/CodeIsland",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "codeisland-bridge",
            dependencies: ["CodeIslandCore"],
            path: "Sources/CodeIslandBridge"
        ),
        // Resets the xctest runner's shared defaults domain when a test
        // bundle loads (see Tests/TestDefaultsReset/TestDefaultsReset.c).
        .target(
            name: "TestDefaultsReset",
            path: "Tests/TestDefaultsReset"
        ),
        .testTarget(
            name: "CodeIslandCoreTests",
            dependencies: ["CodeIslandCore", "TestDefaultsReset"],
            path: "Tests/CodeIslandCoreTests"
        ),
        .testTarget(
            name: "CodeIslandTests",
            dependencies: ["CodeIsland", "TestDefaultsReset"],
            path: "Tests/CodeIslandTests"
        ),
    ]
)
