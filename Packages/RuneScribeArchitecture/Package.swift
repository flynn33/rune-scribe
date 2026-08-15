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
        .library(
            name: "RuneScribeUIPresentationContracts",
            targets: ["RuneScribeUIPresentationContracts"]
        ),
        .library(name: "RuneScribeRuntimeCore", targets: ["RuneScribeRuntimeCore"]),
        .library(name: "RuneScribeUIRuntime", targets: ["RuneScribeUIRuntime"]),
        .library(name: "RuneScribePlatform", targets: ["RuneScribePlatform"]),
        .library(name: "RuneScribeCoreModule", targets: ["RuneScribeCoreModule"]),
        .library(
            name: "RuneScribeProgressionModule",
            targets: ["RuneScribeProgressionModule"]
        ),
        .library(name: "RuneScribeUIModule", targets: ["RuneScribeUIModule"]),
        .library(name: "RuneScribeTestSupport", targets: ["RuneScribeTestSupport"]),
    ],
    targets: [
        .target(name: "RuneScribeContracts"),
        .target(
            name: "RuneScribeUIPresentationContracts",
            dependencies: ["RuneScribeContracts"]
        ),
        .target(
            name: "RuneScribeRuntimeCore",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeUIPresentationContracts",
            ]
        ),
        .target(
            name: "RuneScribeUIRuntime",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeRuntimeCore",
                "RuneScribeUIPresentationContracts",
            ]
        ),
        .target(
            name: "RuneScribePlatform",
            dependencies: ["RuneScribeContracts"],
            exclude: ["Feedback/Resources/Source"],
            resources: [.process("Feedback/Resources")]
        ),
        .target(
            name: "RuneScribeCoreModule",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeProgressionModule",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeUIModule",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeRuntimeCore",
                "RuneScribeUIPresentationContracts",
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
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
                "RuneScribeUIPresentationContracts",
            ]
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
            name: "RuneScribeProgressionModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeProgressionModule",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
            ]
        ),
        .testTarget(
            name: "RuneScribeUIModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
                "RuneScribeUIPresentationContracts",
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
                "RuneScribeProgressionModule",
                "RuneScribeUIModule",
                "RuneScribeTestSupport",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
