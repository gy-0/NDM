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
        .executable(name: "NDMProbe", targets: ["NDMProbe"]),
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
            path: "Sources/NDMApp",
            resources: [
                .process("Resources"),
            ]
        ),
        // Pure aggregation and suite-parsing logic for the delivery success-rate
        // probe. Kept free of network and AppKit so it is unit-testable offline.
        .target(
            name: "NDMDiagnostics",
            path: "Sources/NDMDiagnostics"
        ),
        // Manually-run diagnostic; reaches the public internet, never part of
        // `swift test`. See Sources/NDMProbe/NDMProbe.swift.
        .executableTarget(
            name: "NDMProbe",
            dependencies: ["NDMCore", "NDMEngine", "NDMDiagnostics"],
            path: "Sources/NDMProbe"
        ),
        .testTarget(
            name: "NDMDiagnosticsTests",
            dependencies: ["NDMDiagnostics"],
            path: "Tests/NDMDiagnosticsTests"
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
