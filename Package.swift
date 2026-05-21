// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "tap-n-filter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "tap-n-filter", targets: ["tap-n-filter"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Graph", targets: ["Graph"]),
        .library(name: "Effects", targets: ["Effects"]),
        .library(name: "Presets", targets: ["Presets"])
    ],
    targets: [
        .executableTarget(
            name: "tap-n-filter",
            dependencies: ["Capture", "Graph", "Effects", "Presets"],
            path: "Sources/tap-n-filter",
            resources: [
                .copy("Resources")
            ]
        ),
        .target(
            name: "Capture",
            path: "Sources/Capture"
        ),
        .target(
            name: "Graph",
            dependencies: ["Effects"],
            path: "Sources/Graph"
        ),
        .target(
            name: "Effects",
            path: "Sources/Effects"
        ),
        .target(
            name: "Presets",
            dependencies: ["Graph", "Effects"],
            path: "Sources/Presets"
        ),
        .testTarget(
            name: "CaptureTests",
            dependencies: ["Capture"],
            path: "Tests/CaptureTests"
        ),
        .testTarget(
            name: "GraphTests",
            dependencies: ["Graph", "Effects"],
            path: "Tests/GraphTests"
        ),
        .testTarget(
            name: "EffectsTests",
            dependencies: ["Effects"],
            path: "Tests/EffectsTests"
        ),
        .testTarget(
            name: "PresetsTests",
            dependencies: ["Presets", "Graph", "Effects"],
            path: "Tests/PresetsTests"
        )
    ]
)
