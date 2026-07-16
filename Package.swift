// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NDM",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "NDMCore", targets: ["NDMCore"]),
        .library(name: "NDMEngine", targets: ["NDMEngine"]),
        .library(name: "NDMBridge", targets: ["NDMBridge"]),
        .executable(name: "NDM", targets: ["NDMApp"]),
    ],
    targets: [
        .target(
            name: "NDMCore",
            path: "Sources/NDMCore"
        ),
        .target(
            name: "NDMEngine",
            dependencies: ["NDMCore"],
            path: "Sources/NDMEngine"
        ),
        .target(
            name: "NDMBridge",
            dependencies: ["NDMCore"],
            path: "Sources/NDMBridge"
        ),
        .executableTarget(
            name: "NDMApp",
            dependencies: ["NDMCore", "NDMEngine", "NDMBridge"],
            path: "Sources/NDMApp"
        ),
        .testTarget(
            name: "NDMCoreTests",
            dependencies: ["NDMCore"],
            path: "Tests/NDMCoreTests"
        ),
        .testTarget(
            name: "NDMEngineTests",
            dependencies: ["NDMEngine", "NDMCore"],
            path: "Tests/NDMEngineTests"
        ),
        .testTarget(
            name: "NDMBridgeTests",
            dependencies: ["NDMBridge", "NDMCore", "NDMEngine"],
            path: "Tests/NDMBridgeTests"
        ),
    ]
)
