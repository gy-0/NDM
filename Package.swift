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
        .executable(name: "NDMSoak", targets: ["NDMSoak"]),
        // Not "ndm": the app product is "NDM", and on a case-insensitive filesystem
        // the two would fight over the same output path.
        .executable(name: "ndmcli", targets: ["NDMCLI"]),
        .executable(name: "NDMHost", targets: ["NDMHost"]),
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
        // Long-run stability probe. Serves its own local origin, so it never
        // needs the public internet. Also never part of `swift test`.
        .executableTarget(
            name: "NDMSoak",
            dependencies: ["NDMCore", "NDMEngine", "NDMDiagnostics"],
            path: "Sources/NDMSoak"
        ),
        // Command-line surface. Split into a testable library plus a thin executable
        // so the grammar and the exact output bytes are pinned by tests rather than
        // discovered by whoever writes a script against them.
        .target(
            name: "NDMCLICore",
            dependencies: ["NDMCore"],
            path: "Sources/NDMCLICore"
        ),
        .executableTarget(
            name: "NDMCLI",
            dependencies: ["NDMCore", "NDMEngine", "NDMCLICore"],
            path: "Sources/NDMCLI"
        ),
        // Headless engine for the Electron shell. JSON-lines on 127.0.0.1:51874.
        .executableTarget(
            name: "NDMHost",
            dependencies: ["NDMCore", "NDMEngine"],
            path: "Sources/NDMHost"
        ),
        .testTarget(
            name: "NDMCLICoreTests",
            dependencies: ["NDMCLICore", "NDMCore"],
            path: "Tests/NDMCLICoreTests"
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
