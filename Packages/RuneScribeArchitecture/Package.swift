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
        .library(
            name: "RuneScribeThemeCoordinatorModule",
            targets: ["RuneScribeThemeCoordinatorModule"]
        ),
        .library(
            name: "RuneScribeNorseThemeModule",
            targets: ["RuneScribeNorseThemeModule"]
        ),
        .library(
            name: "RuneScribeThemeMoonleafModule",
            targets: ["RuneScribeThemeMoonleafModule"]
        ),
        .library(
            name: "RuneScribeThemeSunspireModule",
            targets: ["RuneScribeThemeSunspireModule"]
        ),
        .library(
            name: "RuneScribeThemeWildwoodModule",
            targets: ["RuneScribeThemeWildwoodModule"]
        ),
        .library(
            name: "RuneScribeThemeGloamthornModule",
            targets: ["RuneScribeThemeGloamthornModule"]
        ),
        .library(
            name: "RuneScribeCloudSyncModule",
            targets: ["RuneScribeCloudSyncModule"]
        ),
        .library(
            name: "RuneScribeGameCenterModule",
            targets: ["RuneScribeGameCenterModule"]
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
                "RuneScribeCloudSyncModule",
                "RuneScribeContracts",
                "RuneScribeGameCenterModule",
                "RuneScribeProgressionSyncDomain",
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
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeProgressionSyncDomain",
                "RuneScribeRuntimeCore",
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeProgressionSyncDomain",
            dependencies: ["RuneScribeContracts"]
        ),
        .target(
            name: "RuneScribeThemeCoordinatorModule",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeNorseThemeModule",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"],
            exclude: ["Resources/Source"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeThemeMoonleafModule",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeThemeSunspireModule",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeThemeWildwoodModule",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeThemeGloamthornModule",
            dependencies: ["RuneScribeContracts", "RuneScribeRuntimeCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RuneScribeCloudSyncModule",
            dependencies: ["RuneScribeProgressionSyncDomain"]
        ),
        .target(
            name: "RuneScribeGameCenterModule",
            dependencies: ["RuneScribeContracts"],
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
                "RuneScribeCloudSyncModule",
                "RuneScribeContracts",
                "RuneScribeGameCenterModule",
                "RuneScribeProgressionSyncDomain",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
                "RuneScribeUIPresentationContracts",
            ],
            resources: [.process("Fixtures")]
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
                "RuneScribeProgressionSyncDomain",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
            ]
        ),
        .testTarget(
            name: "RuneScribeNorseThemeModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeNorseThemeModule",
                "RuneScribeRuntimeCore",
            ]
        ),
        .testTarget(
            name: "RuneScribeThemeMoonleafModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeNorseThemeModule",
                "RuneScribeProgressionModule",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
                "RuneScribeThemeCoordinatorModule",
                "RuneScribeThemeMoonleafModule",
            ]
        ),
        .testTarget(
            name: "RuneScribeThemeSunspireModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeNorseThemeModule",
                "RuneScribeProgressionModule",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
                "RuneScribeThemeCoordinatorModule",
                "RuneScribeThemeSunspireModule",
            ]
        ),
        .testTarget(
            name: "RuneScribeThemeWildwoodModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeNorseThemeModule",
                "RuneScribeProgressionModule",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
                "RuneScribeThemeCoordinatorModule",
                "RuneScribeThemeWildwoodModule",
            ]
        ),
        .testTarget(
            name: "RuneScribeThemeGloamthornModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeNorseThemeModule",
                "RuneScribeProgressionModule",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
                "RuneScribeThemeCoordinatorModule",
                "RuneScribeThemeGloamthornModule",
            ]
        ),
        .testTarget(
            name: "RuneScribeCloudSyncModuleTests",
            dependencies: [
                "RuneScribeCloudSyncModule",
                "RuneScribeContracts",
                "RuneScribeProgressionSyncDomain",
            ]
        ),
        .testTarget(
            name: "RuneScribeGameCenterModuleTests",
            dependencies: ["RuneScribeGameCenterModule", "RuneScribeContracts"]
        ),
        .testTarget(
            name: "RuneScribeThemeCoordinatorModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeNorseThemeModule",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
                "RuneScribeThemeCoordinatorModule",
                "RuneScribeThemeMoonleafModule",
            ]
        ),
        .testTarget(
            name: "RuneScribeUIModuleTests",
            dependencies: [
                "RuneScribeContracts",
                "RuneScribeNorseThemeModule",
                "RuneScribeRuntimeCore",
                "RuneScribeTestSupport",
                "RuneScribeThemeCoordinatorModule",
                "RuneScribeThemeGloamthornModule",
                "RuneScribeThemeMoonleafModule",
                "RuneScribeThemeSunspireModule",
                "RuneScribeThemeWildwoodModule",
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
                "RuneScribeNorseThemeModule",
                "RuneScribeProgressionModule",
                "RuneScribeThemeGloamthornModule",
                "RuneScribeThemeCoordinatorModule",
                "RuneScribeThemeMoonleafModule",
                "RuneScribeThemeSunspireModule",
                "RuneScribeThemeWildwoodModule",
                "RuneScribeUIModule",
                "RuneScribeTestSupport",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
