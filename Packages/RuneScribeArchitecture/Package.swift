// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RuneScribeArchitecture",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
    ],
    products: [
        .library(name: "RuneScribeContracts", targets: ["RuneScribeContracts"]),
        .library(name: "RuneScribeRuntimeCore", targets: ["RuneScribeRuntimeCore"]),
        .library(name: "RuneScribeUIRuntime", targets: ["RuneScribeUIRuntime"]),
        .library(name: "RuneScribePlatform", targets: ["RuneScribePlatform"]),
        .library(name: "RuneScribeCoreModule", targets: ["RuneScribeCoreModule"]),
        .library(name: "RuneScribeUIModule", targets: ["RuneScribeUIModule"]),
        .library(name: "RuneScribeTestSupport", targets: ["RuneScribeTestSupport"]),
    ],
    targets: [
        .target(name: "RuneScribeContracts"),
        .target(
            name: "RuneScribeRuntimeCore",
            dependencies: ["RuneScribeContracts"]
        ),
        .target(
            name: "RuneScribeUIRuntime",
            dependencies: ["RuneScribeContracts"]
        ),
        .target(
            name: "RuneScribePlatform",
            dependencies: ["RuneScribeContracts"]
        ),
        .target(
            name: "RuneScribeCoreModule",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeUIModule",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeRuntimeCore",
                "RuneScribeUIRuntime",
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeTestSupport",
            dependencies: ["RuneScribeContracts"]
        ),
        .testTarget(
            name: "RuneScribeRuntimeCoreTests",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"]
        ),
        .testTarget(
            name: "RuneScribePlatformTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribePlatform",
                "RuneScribeTestSupport",
            ]
        ),
        .testTarget(
            name: "RuneScribeCoreModuleTests",
            dependencies: ["RuneScribeCoreModule", "RuneScribeRuntimeCore"]
        ),
        .testTarget(
            name: "RuneScribeUIModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeRuntimeCore",
                "RuneScribeUIRuntime",
                "RuneScribeUIModule",
            ]
        ),
        .testTarget(
            name: "RuneScribeArchitectureTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeRuntimeCore",
                "RuneScribeUIRuntime",
                "RuneScribePlatform",
                "RuneScribeCoreModule",
                "RuneScribeUIModule",
                "RuneScribeTestSupport",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
