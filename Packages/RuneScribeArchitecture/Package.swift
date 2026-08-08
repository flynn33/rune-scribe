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
    ],
    targets: [
        .target(name: "RuneScribeContracts"),
        .target(
            name: "RuneScribeRuntimeCore",
            dependencies: ["RuneScribeContracts"]
        ),
        .target(
            name: "RuneScribeUIRuntime",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"]
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
        .testTarget(
            name: "RuneScribeRuntimeCoreTests",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"]
        ),
        .testTarget(
            name: "RuneScribePlatformTests",
            dependencies: ["RuneScribeContracts", "RuneScribePlatform"]
        ),
        .testTarget(
            name: "RuneScribeCoreModuleTests",
            dependencies: ["RuneScribeCoreModule", "RuneScribeRuntimeCore"]
        ),
        .testTarget(
            name: "RuneScribeUIModuleTests",
            dependencies: [
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
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
