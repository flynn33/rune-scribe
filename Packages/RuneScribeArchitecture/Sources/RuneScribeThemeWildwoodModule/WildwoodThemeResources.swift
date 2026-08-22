import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum WildwoodThemeResourceError: Error, Equatable, Sendable {
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case invalidIntegrityManifest
    case resourcePayloadSetMismatch
    case resourceBudgetExceeded(String)
}

public struct WildwoodThemeBundledResourceDescriptor: Equatable, Hashable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data { Data(hexadecimal: expectedSHA256Hex) }
}

public enum WildwoodThemeBundledResourceCatalog {
    public static let moduleManifest = ApplicationResource(
        name: "module-manifest",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.wildwood"
    )
    public static let integrityManifest = ApplicationResource(
        name: "Resource-Integrity-Manifest-v1.0",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.wildwood"
    )
    public static let integrityManifestDescriptor = WildwoodThemeBundledResourceDescriptor(
        resource: integrityManifest,
        expectedByteCount: 14519,
        expectedSHA256Hex: "f41665d69e3034bd8df8cf60954a5e7fa338a144384116fac2a4ca8b71b6c8f8",
        maximumByteCount: 64 * 1_024
    )

    public static var all: Set<ApplicationResource> {
        Set([moduleManifest, integrityManifest] + WildwoodThemeResourceCatalog.productionDefinitions.map { $0.resource })
    }
}

public struct ValidatedWildwoodTheme: Sendable {
    public let descriptor: ThemeDescriptor
    public let resourcePayloads: [ThemeResourceID: Data]
}

public struct WildwoodThemeResourceBudgetReport: Equatable, Sendable {
    public let shippingBytes: Int
    public let staticImageBytes: Int
    public let fontBytes: Int
    public let largestResourceBytes: Int
}

public enum WildwoodThemeResources {
    public static func loadValidated(using runtimeIO: RuntimeIOClient) async throws -> ValidatedWildwoodTheme {
        let manifestData = try await read(
            WildwoodThemeBundledResourceCatalog.integrityManifestDescriptor,
            using: runtimeIO
        )
        guard WildwoodThemeResourceCatalog.validateIntegrityManifest(manifestData) else {
            throw WildwoodThemeResourceError.invalidIntegrityManifest
        }

        var payloads: [ThemeResourceID: Data] = [:]
        var physicalPayloads: [ApplicationResource: Data] = [
            WildwoodThemeBundledResourceCatalog.integrityManifest: manifestData,
        ]
        for definition in WildwoodThemeResourceCatalog.productionDefinitions {
            let data: Data
            if let cached = physicalPayloads[definition.resource] {
                data = cached
            } else {
                data = try await read(definition.bundledDescriptor, using: runtimeIO)
                physicalPayloads[definition.resource] = data
            }
            payloads[definition.id] = data
        }
        payloads[WildwoodThemeResourceCatalog.localizationDefinition.id] =
            WildwoodThemeResourceCatalog.localizationPayload

        _ = try budgetReport(payloads: payloads)
        let descriptor = WildwoodThemeDescriptorFactory.discoveryDescriptor
        guard Set(payloads.keys) == Set(descriptor.resources.map { $0.id }),
              WildwoodThemeResourceCatalog.validates(payloads)
        else {
            throw WildwoodThemeResourceError.resourcePayloadSetMismatch
        }
        return ValidatedWildwoodTheme(descriptor: descriptor, resourcePayloads: payloads)
    }

    public static func budgetReport(
        payloads: [ThemeResourceID: Data]
    ) throws -> WildwoodThemeResourceBudgetReport {
        let production = WildwoodThemeResourceCatalog.productionDefinitions
        let values = try production.map { definition -> (WildwoodThemeResourceDefinition, Data) in
            guard let data = payloads[definition.id], data.count <= definition.maximumByteCount else {
                throw WildwoodThemeResourceError.resourceBudgetExceeded(definition.id.rawValue)
            }
            return (definition, data)
        }
        let shipping = values.reduce(0) { $0 + $1.1.count }
        let staticBytes = values.filter { [.png, .heif, .pdf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let fontBytes = values.filter { [.ttf, .otf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let largest = values.map { $0.1.count }.max() ?? 0
        guard shipping == 697897,
              staticBytes <= 32 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else {
            throw WildwoodThemeResourceError.resourceBudgetExceeded("complete-theme")
        }
        return WildwoodThemeResourceBudgetReport(
            shippingBytes: shipping,
            staticImageBytes: staticBytes,
            fontBytes: fontBytes,
            largestResourceBytes: largest
        )
    }

    private static func read(
        _ descriptor: WildwoodThemeBundledResourceDescriptor,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data = try await runtimeIO.readVerifiedApplicationResource(
            descriptor.resource,
            expectedSHA256: descriptor.expectedSHA256,
            maximumByteCount: descriptor.maximumByteCount
        )
        guard data.count == descriptor.expectedByteCount else {
            throw WildwoodThemeResourceError.resourceByteCountMismatch(
                resource: "\(descriptor.resource.name).\(descriptor.resource.fileExtension)",
                expected: descriptor.expectedByteCount,
                actual: data.count
            )
        }
        return data
    }
}

struct WildwoodThemeResourceDefinition: Equatable, Sendable {
    let id: ThemeResourceID
    let resource: ApplicationResource
    let relativePath: String
    let role: ThemeResourceRoleID
    let mediaType: ThemeResourceMediaType
    let requirement: ThemeResourceRequirement
    let sha256Hex: String
    let byteCount: Int
    let maximumByteCount: Int
    let pixelWidth: Int?
    let pixelHeight: Int?
    let rightsID: ThemeProvenanceID

    var bundledDescriptor: WildwoodThemeBundledResourceDescriptor {
        WildwoodThemeBundledResourceDescriptor(
            resource: resource,
            expectedByteCount: byteCount,
            expectedSHA256Hex: sha256Hex,
            maximumByteCount: maximumByteCount
        )
    }
}

enum WildwoodThemeResourceCatalog {
    static let productionDefinitions: [WildwoodThemeResourceDefinition] = [
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.wildwood.oldgrowth-hollow.output.background-high-contrast")!,
    resource: ApplicationResource(name: "wildwood-background-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/background/wildwood-background-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "background.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "5de5fe6d5fec34fb8c6b330412386153adcbb6c12dc6488b92fcecfe8aad39a9",
    byteCount: 16175,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.wildwood.wildwood.background.recipe.json")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.wildwood.oldgrowth-hollow.output.background-reduce-motion")!,
    resource: ApplicationResource(name: "wildwood-background-reduce-motion", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/background/wildwood-background-reduce-motion.png",
    role: ThemeResourceRoleID(rawValue: "background.reduce-motion")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "a668e4192b802d954f51595c15e97a46581b920dc39035719984276cc19527b5",
    byteCount: 18328,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.wildwood.wildwood.background.recipe.json")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.wildwood.oldgrowth-hollow.output.background-static-base")!,
    resource: ApplicationResource(name: "wildwood-background-static", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/background/wildwood-background-static.png",
    role: ThemeResourceRoleID(rawValue: "background.static-base")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "7e111e301baad8765f31d4768c8815495e15a95cba68d8d9595dc7b1b44893cc",
    byteCount: 18776,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.wildwood.wildwood.background.recipe.json")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.wildwood.heartwood-crown.output.crest-static-fallback")!,
    resource: ApplicationResource(name: "wildwood-heartwood-crown-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/crest/wildwood-heartwood-crown-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "crest.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "464ede8003a0c63ecd58f569edea2dc9f92f510dca775da25718ceea9a34e62e",
    byteCount: 13158,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.wildwood.heartwood.crown.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.wildwood.heartwood-crown.output.crest-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-heartwood-crown-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/crest/wildwood-heartwood-crown-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "crest.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "43c0c4a07927790a1c97ba2795edf6eda71e932be64478847794f01164d83cf3",
    byteCount: 48284,
    maximumByteCount: 4194304,
    pixelWidth: 512,
    pixelHeight: 512,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.wildwood.heartwood.crown.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.wildwood.heartwood-crown.output.crest-vector-master")!,
    resource: ApplicationResource(name: "wildwood-heartwood-crown-vector", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/crest/wildwood-heartwood-crown-vector.pdf",
    role: ThemeResourceRoleID(rawValue: "crest.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "de45d8016f5fc070963aaac9d98040d452ad483f26a5fd1f2e884d979af89e45",
    byteCount: 4102,
    maximumByteCount: 8388608,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.wildwood.heartwood.crown.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.wildwood.living-root.output.frame-static-fallback")!,
    resource: ApplicationResource(name: "wildwood-living-root-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/frame/wildwood-living-root-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "frame.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "f0977e707a58bcff434c68413a9f7039dab990c3f68e2adffc81dfa3f038c953",
    byteCount: 13793,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.wildwood.living.root.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.wildwood.living-root.output.frame-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-living-root-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/frame/wildwood-living-root-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "frame.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "8587d7788dc13cffffa0bc1164146ba167e92449bbc71788babe587a3795c2ad",
    byteCount: 25286,
    maximumByteCount: 4194304,
    pixelWidth: 512,
    pixelHeight: 384,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.wildwood.living.root.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.wildwood.living-root.output.frame-vector-master")!,
    resource: ApplicationResource(name: "wildwood-living-root-vector", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/frame/wildwood-living-root-vector.pdf",
    role: ThemeResourceRoleID(rawValue: "frame.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "381cdd2fcf44bbd164ed7e7401a413df726367b484a2b15c5d455f5fe0c18cd9",
    byteCount: 5678,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.wildwood.living.root.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.elderbark-stele.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "wildwood-elderbark-stele-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-elderbark-stele-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "d3fd73e06eaeec21137dee3455c3e7fe4b8266bbd484e1a9c13571d1d8f83466",
    byteCount: 12713,
    maximumByteCount: 2097152,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.elderbark.stele.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.elderbark-stele.output.relic-master")!,
    resource: ApplicationResource(name: "wildwood-elderbark-stele-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-elderbark-stele-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "6fa64c72a2b18e3a6e8a6ae9423c715abbecde10b8a40233c542378a65f04cc6",
    byteCount: 16459,
    maximumByteCount: 4194304,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.elderbark.stele.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.elderbark-stele.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "wildwood-elderbark-stele-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-elderbark-stele-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "8854623f390becc77adcdaaa2c82f485a5c6d6abaef02408d6a9a010552956de",
    byteCount: 12243,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.elderbark.stele.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.elderbark-stele.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-elderbark-stele-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-elderbark-stele-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "50ed03ae75732871bac96d06008bef22d7a592d72fa95fc625ece69e6641409e",
    byteCount: 10187,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.elderbark.stele.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.mossbound-plaque.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "wildwood-mossbound-plaque-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-mossbound-plaque-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "ef86d01501af0e3f461542cf89d4f72a7385a75e8a7605bafb21c54e4a0b6151",
    byteCount: 12011,
    maximumByteCount: 2097152,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.mossbound.plaque.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.mossbound-plaque.output.relic-master")!,
    resource: ApplicationResource(name: "wildwood-mossbound-plaque-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-mossbound-plaque-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "a4aaf4f852aa60cd418017fbbf0007f6d6ba09f423e0a3139ff492567c218128",
    byteCount: 19363,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.mossbound.plaque.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.mossbound-plaque.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "wildwood-mossbound-plaque-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-mossbound-plaque-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "9e45e55723a34048ec188467bf181cc702898bfad601b54599afd372f7dbf930",
    byteCount: 22022,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.mossbound.plaque.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.mossbound-plaque.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-mossbound-plaque-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-mossbound-plaque-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "de9e9588765d2c2e5d03b11a70f88d10fea594d311954c4698afeec02c0afc7e",
    byteCount: 13690,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.mossbound.plaque.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.rootsong-tablet.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "wildwood-rootsong-tablet-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-rootsong-tablet-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "e92f551c948b182868340cec593699dc2da4e7d4ed06bee1f31c518f2de227d2",
    byteCount: 11420,
    maximumByteCount: 2097152,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.rootsong.tablet.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.rootsong-tablet.output.relic-master")!,
    resource: ApplicationResource(name: "wildwood-rootsong-tablet-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-rootsong-tablet-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "ba14ea3b37a4a4cd63bf3d62af7be53e9b4e2529ee60a7c666abd582b40e7c6a",
    byteCount: 20163,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.rootsong.tablet.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.rootsong-tablet.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "wildwood-rootsong-tablet-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-rootsong-tablet-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "0b9f2ceb4ee19013fe62e6895bebb2e863d3e56335e442d2c3de8c8743cd1d84",
    byteCount: 24466,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.rootsong.tablet.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.wildwood.rootsong-tablet.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-rootsong-tablet-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/relic/wildwood-rootsong-tablet-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "3fc6efe31416fd7b1ae1a8adfe17ffa83c6e53eaeeb1dc6201ef4c6a518ab9e5",
    byteCount: 10401,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.wildwood.rootsong.tablet.geometry.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.wildwood.output.script-font")!,
    resource: ApplicationResource(name: "wildwood-script-primary", fileExtension: "ttf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/script/wildwood-script-primary.ttf",
    role: ThemeResourceRoleID(rawValue: "script.font")!,
    mediaType: .ttf,
    requirement: .required,
    sha256Hex: "ad40e0285989a37f008be604de4e7a7687f016a0c8e97e709fd8848d1caf0093",
    byteCount: 53648,
    maximumByteCount: 8388608,
    pixelWidth: nil,
    pixelHeight: nil,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.wildwood.glyph.master.json")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.wildwood.output.script-specimen-preview")!,
    resource: ApplicationResource(name: "wildwood-script-specimen", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/script/wildwood-script-specimen.png",
    role: ThemeResourceRoleID(rawValue: "script.specimen-preview")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "385c6d2c6cb0a70eacb16498417dd2dc583fdf5662f8ba95d65143f9692bc096",
    byteCount: 29696,
    maximumByteCount: 2097152,
    pixelWidth: 1024,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.wildwood.glyph.master.json")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.wildwood.output.script-static-fallback")!,
    resource: ApplicationResource(name: "wildwood-script-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/script/wildwood-script-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "script.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "6878a846c741075d140d8136da62d20bbaf6e4ac25253e9fcfbd2f4c7b893e87",
    byteCount: 23480,
    maximumByteCount: 2097152,
    pixelWidth: 1024,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.wildwood.glyph.master.json")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.acorn-knot.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "wildwood-acorn-knot-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-acorn-knot-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "b2362fd72559be9a3fb9d939b4cff318455d4140618969aa98395325a9d7b1b3",
    byteCount: 6287,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.acorn.knot.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.acorn-knot.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-acorn-knot-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-acorn-knot-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "07a8c81fe34f3f7a3581b64cdf1ae4e1430ade2829dac904e685f5b02a5f2f22",
    byteCount: 3431,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.acorn.knot.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.acorn-knot.output.seal-vector-master")!,
    resource: ApplicationResource(name: "wildwood-acorn-knot-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-acorn-knot-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "2c00802d6b018153a06f8f7b5273a991a912aaa362ac8303f3a0ebc4de59520b",
    byteCount: 6448,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.acorn.knot.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.echo-seed.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "wildwood-echo-seed-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-echo-seed-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "1bb3efce248ffa1e3fd901eece3760ec02b48ff6ab73b8126dde9f3a6d88fc50",
    byteCount: 5537,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.echo.seed.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.echo-seed.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-echo-seed-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-echo-seed-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "d6dc84a6ffe477a2e250e26dc93f56c941b83563261a7be6d2c676a4b588ee17",
    byteCount: 3730,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.echo.seed.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.echo-seed.output.seal-vector-master")!,
    resource: ApplicationResource(name: "wildwood-echo-seed-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-echo-seed-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "a00778bdf7230d0cc0512cd7c8d60e999382b4f77cd0a381295de2ec045147fa",
    byteCount: 5675,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.echo.seed.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.fern-spiral.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "wildwood-fern-spiral-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-fern-spiral-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "31bfe6295c16dc50dd8d2d25fa19f969aa46ab2b9090bf2ee9a7af066ba2141e",
    byteCount: 10085,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.fern.spiral.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.fern-spiral.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-fern-spiral-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-fern-spiral-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "82d43d317ee85968095fa6cf9a84001096080509e4cbe68dfc33a69d34af0cdb",
    byteCount: 3211,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.fern.spiral.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.fern-spiral.output.seal-vector-master")!,
    resource: ApplicationResource(name: "wildwood-fern-spiral-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-fern-spiral-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "931549c42be88961f731c827213d71735008e0138cde3a4369382378f071ed46",
    byteCount: 10408,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.fern.spiral.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.lantern-moth.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "wildwood-lantern-moth-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-lantern-moth-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "975d6dbeaca6355b545a34eedca917092f66dba2a3468032db35bc1ed3022911",
    byteCount: 5969,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.lantern.moth.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.lantern-moth.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-lantern-moth-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-lantern-moth-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "bf456a8c1da30c16c07e934d5ff868a95010a6c3fc4523a7e98e698e6a5c4a00",
    byteCount: 3417,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.lantern.moth.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.lantern-moth.output.seal-vector-master")!,
    resource: ApplicationResource(name: "wildwood-lantern-moth-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-lantern-moth-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "22ed080ae48632f447ce171bf74c56f793709dae9cc84d0003b3c9e7f1723849",
    byteCount: 6199,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.lantern.moth.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.rooted-tree.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "wildwood-rooted-tree-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-rooted-tree-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "5e8bf3335e09c0560576224f23aeae851d667b49e13a63dfd2d6259f47740747",
    byteCount: 7689,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.rooted.tree.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.rooted-tree.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-rooted-tree-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-rooted-tree-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "8b73503c7cc7bc06c2b31339211a54f28143ca0e0cb70e9acc63e82b7711a652",
    byteCount: 3294,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.rooted.tree.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.rooted-tree.output.seal-vector-master")!,
    resource: ApplicationResource(name: "wildwood-rooted-tree-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-rooted-tree-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "74bb2d1a9ba8c5606c512177f457ecce4dd98640e3d6893cae49007bb8639e16",
    byteCount: 7873,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.rooted.tree.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.wild-fox.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "wildwood-wild-fox-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-wild-fox-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "09e58e8873c90d788b56fb7d4d261246cd2b1d1139334148ff7591ebcb704bbe",
    byteCount: 6343,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.wild.fox.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.wild-fox.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "wildwood-wild-fox-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-wild-fox-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "3134256dd98b00add8a0e3370387c3227e799eaf33bbd7b0b86d53fe7fa5ae25",
    byteCount: 3625,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.wild.fox.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.wildwood.wild-fox.output.seal-vector-master")!,
    resource: ApplicationResource(name: "wildwood-wild-fox-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/seal/wildwood-wild-fox-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "f8e1a38ae394b60c1915c935af415b14c1b15ae303d6319e874361a1da2ec8b9",
    byteCount: 6642,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.wildwood.wild.fox.svg")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.wildwood.codex.output.vault-card")!,
    resource: ApplicationResource(name: "wildwood-vault-card", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/vault/wildwood-vault-card.png",
    role: ThemeResourceRoleID(rawValue: "vault.card")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "ae90d75df16e8dc87c94d8e25bd99c076d56f0447d7d6f9f8818b3a85909dcdd",
    byteCount: 34145,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.wildwood.wildwood.vault.recipe.json")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.wildwood.codex.output.vault-encountered")!,
    resource: ApplicationResource(name: "wildwood-vault-encountered", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/vault/wildwood-vault-encountered.png",
    role: ThemeResourceRoleID(rawValue: "vault.encountered")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "c04eddf417d1aff006710f11f1afcb2659401da61fbc018d7cdfee9f7d5a4e32",
    byteCount: 32556,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.wildwood.wildwood.vault.recipe.json")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.wildwood.codex.output.vault-locked-silhouette")!,
    resource: ApplicationResource(name: "wildwood-vault-locked", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/vault/wildwood-vault-locked.png",
    role: ThemeResourceRoleID(rawValue: "vault.locked-silhouette")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "1e75e9da9330a19fdd657cd09043a809b342b2f54b137da2b2910ee6000ec64e",
    byteCount: 32150,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.wildwood.wildwood.vault.recipe.json")!
),
WildwoodThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.wildwood.codex.output.vault-selected")!,
    resource: ApplicationResource(name: "wildwood-vault-selected", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.wildwood"),
    relativePath: "Production/vault/wildwood-vault-selected.png",
    role: ThemeResourceRoleID(rawValue: "vault.selected")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "5e0892b57ff8b75ffa2e94e87184ce1bf605653028111962d49f1b58a8b94d24",
    byteCount: 37641,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.wildwood.wildwood.vault.recipe.json")!
)
    ]

    static let localizationPayload = Data(#"{"locale":"en","strings":{}}"#.utf8)

    static let localizationDefinition = WildwoodThemeResourceDefinition(
        id: ThemeResourceID(rawValue: "resource.localization.wildwood.control")!,
        resource: ApplicationResource(
            name: "wildwood-localization-en",
            fileExtension: "json",
            ownerModuleID: "com.runescribe.module.theme.wildwood"
        ),
        relativePath: "embedded/wildwood-localization-en.json",
        role: ThemeResourceRoles.localizationStrings,
        mediaType: .json,
        requirement: .required,
        sha256Hex: sha256Hex(localizationPayload),
        byteCount: localizationPayload.count,
        maximumByteCount: 64 * 1_024,
        pixelWidth: nil,
        pixelHeight: nil,
        rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.wildwood.wildwood.background.recipe.json")!
    )

    static let definitions = productionDefinitions + [localizationDefinition]

    static func references() throws -> [ThemeResourceReference] {
        try definitions.map { definition in
            let pixelSize: ThemePixelSize?
            if let width = definition.pixelWidth, let height = definition.pixelHeight {
                pixelSize = try ThemePixelSize(width: UInt32(width), height: UInt32(height))
            } else {
                pixelSize = nil
            }
            return try ThemeResourceReference(
                id: definition.id,
                role: definition.role,
                mediaType: definition.mediaType,
                requirement: definition.requirement,
                integrity: ThemeResourceIntegrity(
                    sha256: ThemeSHA256Digest(rawValue: definition.sha256Hex)!,
                    byteLength: UInt64(definition.byteCount),
                    pixelSize: pixelSize
                ),
                rightsID: definition.rightsID
            )
        }
    }

    static func validates(_ payloads: [ThemeResourceID: Data]) -> Bool {
        Set(payloads.keys) == Set(definitions.map { $0.id }) && definitions.allSatisfy { definition in
            guard let data = payloads[definition.id] else { return false }
            return data.count == definition.byteCount && sha256Hex(data) == definition.sha256Hex
        }
    }

    static func validateIntegrityManifest(_ data: Data) -> Bool {
        guard let manifest = try? JSONDecoder().decode(IntegrityManifest.self, from: data),
              manifest.schemaVersion == "1.0",
              manifest.codexID == "codex.wildwood",
              manifest.moduleID == "com.runescribe.module.theme.wildwood",
              manifest.acceptedPackageVersion == "3.1.0"
        else { return false }
        return manifest.files == productionDefinitions.map {
            IntegrityManifest.FileRecord(
                path: $0.relativePath,
                bytes: $0.byteCount,
                sha256: $0.sha256Hex,
                resourceID: $0.id.rawValue,
                role: $0.role.rawValue
            )
        }
    }

    private struct IntegrityManifest: Decodable {
        struct FileRecord: Decodable, Equatable {
            let path: String
            let bytes: Int
            let sha256: String
            let resourceID: String
            let role: String
        }
        let schemaVersion: String
        let codexID: String
        let moduleID: String
        let acceptedPackageVersion: String
        let files: [FileRecord]
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    init(hexadecimal value: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            bytes.append(UInt8(value[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
