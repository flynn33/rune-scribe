import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum MoonleafThemeResourceError: Error, Equatable, Sendable {
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case invalidIntegrityManifest
    case resourcePayloadSetMismatch
    case resourceBudgetExceeded(String)
}

public struct MoonleafThemeBundledResourceDescriptor: Equatable, Hashable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data { Data(hexadecimal: expectedSHA256Hex) }
}

public enum MoonleafThemeBundledResourceCatalog {
    public static let moduleManifest = ApplicationResource(
        name: "module-manifest",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.moonleaf"
    )
    public static let integrityManifest = ApplicationResource(
        name: "Resource-Integrity-Manifest-v1.0",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.moonleaf"
    )
    public static let integrityManifestDescriptor = MoonleafThemeBundledResourceDescriptor(
        resource: integrityManifest,
        expectedByteCount: 14425,
        expectedSHA256Hex: "e7222671993ad13ff4f3c72dd048f31f49295a1412e1f365d9fd904ef0b4c633",
        maximumByteCount: 64 * 1_024
    )

    public static var all: Set<ApplicationResource> {
        Set([moduleManifest, integrityManifest] + MoonleafThemeResourceCatalog.productionDefinitions.map { $0.resource })
    }
}

public struct ValidatedMoonleafTheme: Sendable {
    public let descriptor: ThemeDescriptor
    public let resourcePayloads: [ThemeResourceID: Data]
}

public struct MoonleafThemeResourceBudgetReport: Equatable, Sendable {
    public let shippingBytes: Int
    public let staticImageBytes: Int
    public let fontBytes: Int
    public let largestResourceBytes: Int
}

public enum MoonleafThemeResources {
    public static func loadValidated(using runtimeIO: RuntimeIOClient) async throws -> ValidatedMoonleafTheme {
        let manifestData = try await read(
            MoonleafThemeBundledResourceCatalog.integrityManifestDescriptor,
            using: runtimeIO
        )
        guard MoonleafThemeResourceCatalog.validateIntegrityManifest(manifestData) else {
            throw MoonleafThemeResourceError.invalidIntegrityManifest
        }

        var payloads: [ThemeResourceID: Data] = [:]
        var physicalPayloads: [ApplicationResource: Data] = [
            MoonleafThemeBundledResourceCatalog.integrityManifest: manifestData,
        ]
        for definition in MoonleafThemeResourceCatalog.productionDefinitions {
            let data: Data
            if let cached = physicalPayloads[definition.resource] {
                data = cached
            } else {
                data = try await read(definition.bundledDescriptor, using: runtimeIO)
                physicalPayloads[definition.resource] = data
            }
            payloads[definition.id] = data
        }
        payloads[MoonleafThemeResourceCatalog.localizationDefinition.id] =
            MoonleafThemeResourceCatalog.localizationPayload

        _ = try budgetReport(payloads: payloads)
        let descriptor = MoonleafThemeDescriptorFactory.discoveryDescriptor
        guard Set(payloads.keys) == Set(descriptor.resources.map { $0.id }),
              MoonleafThemeResourceCatalog.validates(payloads)
        else {
            throw MoonleafThemeResourceError.resourcePayloadSetMismatch
        }
        return ValidatedMoonleafTheme(descriptor: descriptor, resourcePayloads: payloads)
    }

    public static func budgetReport(
        payloads: [ThemeResourceID: Data]
    ) throws -> MoonleafThemeResourceBudgetReport {
        let production = MoonleafThemeResourceCatalog.productionDefinitions
        let values = try production.map { definition -> (MoonleafThemeResourceDefinition, Data) in
            guard let data = payloads[definition.id], data.count <= definition.maximumByteCount else {
                throw MoonleafThemeResourceError.resourceBudgetExceeded(definition.id.rawValue)
            }
            return (definition, data)
        }
        let shipping = values.reduce(0) { $0 + $1.1.count }
        let staticBytes = values.filter { [.png, .heif, .pdf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let fontBytes = values.filter { [.ttf, .otf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let largest = values.map { $0.1.count }.max() ?? 0
        guard shipping == 678743,
              staticBytes <= 32 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else {
            throw MoonleafThemeResourceError.resourceBudgetExceeded("complete-theme")
        }
        return MoonleafThemeResourceBudgetReport(
            shippingBytes: shipping,
            staticImageBytes: staticBytes,
            fontBytes: fontBytes,
            largestResourceBytes: largest
        )
    }

    private static func read(
        _ descriptor: MoonleafThemeBundledResourceDescriptor,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data = try await runtimeIO.readVerifiedApplicationResource(
            descriptor.resource,
            expectedSHA256: descriptor.expectedSHA256,
            maximumByteCount: descriptor.maximumByteCount
        )
        guard data.count == descriptor.expectedByteCount else {
            throw MoonleafThemeResourceError.resourceByteCountMismatch(
                resource: "\(descriptor.resource.name).\(descriptor.resource.fileExtension)",
                expected: descriptor.expectedByteCount,
                actual: data.count
            )
        }
        return data
    }
}

struct MoonleafThemeResourceDefinition: Equatable, Sendable {
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

    var bundledDescriptor: MoonleafThemeBundledResourceDescriptor {
        MoonleafThemeBundledResourceDescriptor(
            resource: resource,
            expectedByteCount: byteCount,
            expectedSHA256Hex: sha256Hex,
            maximumByteCount: maximumByteCount
        )
    }
}

enum MoonleafThemeResourceCatalog {
    static let productionDefinitions: [MoonleafThemeResourceDefinition] = [
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.moonleaf.moonlit-canopy.output.background-high-contrast")!,
    resource: ApplicationResource(name: "moonleaf-background-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/background/moonleaf-background-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "background.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "2b14cf46a557aed8be18ae5c38ca3a2b9cb50d56708599a56f17e6494e0a046c",
    byteCount: 15129,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.moonleaf.moonlit-canopy.output.background-reduce-motion")!,
    resource: ApplicationResource(name: "moonleaf-background-reduce-motion", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/background/moonleaf-background-reduce-motion.png",
    role: ThemeResourceRoleID(rawValue: "background.reduce-motion")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "8e0912d1567b90e710e08a1a25098a41722bcee49e0e38da250c07d51256a190",
    byteCount: 16334,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.moonleaf.moonlit-canopy.output.background-static-base")!,
    resource: ApplicationResource(name: "moonleaf-background-static", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/background/moonleaf-background-static.png",
    role: ThemeResourceRoleID(rawValue: "background.static-base")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "a9cb7df4865a82bff66cb2bcfa646d2919596e55ff6c13993a1a0fd1f2fe74da",
    byteCount: 16733,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.moonleaf.moonbloom.output.crest-static-fallback")!,
    resource: ApplicationResource(name: "moonleaf-moonbloom-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/crest/moonleaf-moonbloom-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "crest.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "77e57c8459c7fcb409c673663ba67c4a42ce2b38abf0b6c81c8f1d487f79face",
    byteCount: 13357,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.moonleaf.moonbloom.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.moonleaf.moonbloom.output.crest-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-moonbloom-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/crest/moonleaf-moonbloom-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "crest.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "213dae530c2fefbd1fc7343eb430af4bec9bd037f2c8211c43c358ad91150d2f",
    byteCount: 54637,
    maximumByteCount: 4194304,
    pixelWidth: 512,
    pixelHeight: 512,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.moonleaf.moonbloom.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.moonleaf.moonbloom.output.crest-vector-master")!,
    resource: ApplicationResource(name: "moonleaf-moonbloom-vector", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/crest/moonleaf-moonbloom-vector.pdf",
    role: ThemeResourceRoleID(rawValue: "crest.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "dbcecf17caa9ef2d1ad789c729d5190c57cbd7d6689ff9da02342527a90d88f2",
    byteCount: 5329,
    maximumByteCount: 8388608,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.moonleaf.moonbloom.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.moonleaf.silvervine.output.frame-static-fallback")!,
    resource: ApplicationResource(name: "moonleaf-silvervine-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/frame/moonleaf-silvervine-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "frame.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "de9a692eb385179c32a3aa757a90c56603de9ee2bae9d83b4813f03e83b4e03c",
    byteCount: 12891,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.moonleaf.silvervine.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.moonleaf.silvervine.output.frame-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-silvervine-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/frame/moonleaf-silvervine-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "frame.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "a2bbaf76faf2263c380893b621374ef1260a8ce2d9aa71a4b2c46a8c60df915c",
    byteCount: 18450,
    maximumByteCount: 4194304,
    pixelWidth: 512,
    pixelHeight: 384,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.moonleaf.silvervine.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.moonleaf.silvervine.output.frame-vector-master")!,
    resource: ApplicationResource(name: "moonleaf-silvervine-vector", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/frame/moonleaf-silvervine-vector.pdf",
    role: ThemeResourceRoleID(rawValue: "frame.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "afc41cd980096eff420c13c93cab5896d7f99204faf30da9f692c97dbc2aa442",
    byteCount: 10415,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.moonleaf.silvervine.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.ivybound-plaque.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "moonleaf-ivybound-plaque-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-ivybound-plaque-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "b0091d9d04e0d76de31d978806bc4267331f1728fc275b221362761d2dbd03e9",
    byteCount: 12456,
    maximumByteCount: 2097152,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.ivybound.plaque.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.ivybound-plaque.output.relic-master")!,
    resource: ApplicationResource(name: "moonleaf-ivybound-plaque-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-ivybound-plaque-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "1c98bb7c732cd82f015b0e5589fda6ddd207ede43fc95521ce9f821f5b0cc484",
    byteCount: 17091,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.ivybound.plaque.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.ivybound-plaque.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "moonleaf-ivybound-plaque-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-ivybound-plaque-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "62b1fc6c0ebb4deab92b5a4bff5052c9802f30bd0de1e86d47c257f1570d3191",
    byteCount: 15009,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.ivybound.plaque.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.ivybound-plaque.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-ivybound-plaque-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-ivybound-plaque-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "093a1913e18dae8b7a370c4071369bbfa86f1d1ac7ab4740a9619c2ef679c30c",
    byteCount: 10214,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.ivybound.plaque.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.tablet.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "moonleaf-tablet-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-tablet-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "05e4d78439353087a5974db09fe85aa686773f6e28314bbb25c280733b11afcb",
    byteCount: 10800,
    maximumByteCount: 2097152,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.tablet.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.tablet.output.relic-master")!,
    resource: ApplicationResource(name: "moonleaf-tablet-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-tablet-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "b08058f7becb462212faa3753a96fc93b15fb30bcf1d87742b6275cb218c18b7",
    byteCount: 16518,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.tablet.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.tablet.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "moonleaf-tablet-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-tablet-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "c7145e03afd7b8d7ec5825d63c24392c7633081e926881e55c08db0e19ef5b50",
    byteCount: 12530,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.tablet.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.tablet.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-tablet-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-tablet-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "76028fcf8e80762b00831e261032a51770479d84e0a699227b13bb3a47517cda",
    byteCount: 4315,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.tablet.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.whisperbark-stele.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "moonleaf-whisperbark-stele-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-whisperbark-stele-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "09c33cfedd8424ada7d746ae376a8fc5dad40563768ba8c87ea027f3e9440fca",
    byteCount: 12085,
    maximumByteCount: 2097152,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.whisperbark.stele.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.whisperbark-stele.output.relic-master")!,
    resource: ApplicationResource(name: "moonleaf-whisperbark-stele-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-whisperbark-stele-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "4332eac874cbe8bd8c448918c4e68e543fccdf0a24668455d4b4bf9e8c77c59a",
    byteCount: 14769,
    maximumByteCount: 4194304,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.whisperbark.stele.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.whisperbark-stele.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "moonleaf-whisperbark-stele-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-whisperbark-stele-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "167c2b75c7de4b2dd824bd9d70b810584ada9a455b32e7dab3aaf0e19958fc04",
    byteCount: 8752,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.whisperbark.stele.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.moonleaf.whisperbark-stele.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-whisperbark-stele-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/relic/moonleaf-whisperbark-stele-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "660855bc0c979033347d7df253d196a9c51af86a20d6c0d6e2c4c7016004a35a",
    byteCount: 6686,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.moonleaf.whisperbark.stele.geometry.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.moonleaf.output.script-font")!,
    resource: ApplicationResource(name: "moonleaf-script-primary", fileExtension: "ttf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/script/moonleaf-script-primary.ttf",
    role: ThemeResourceRoleID(rawValue: "script.font")!,
    mediaType: .ttf,
    requirement: .required,
    sha256Hex: "7fa08b061fbbe897e4305dea1bf456ec87b491a2c34e2df4cf2f6845647f0f3e",
    byteCount: 111892,
    maximumByteCount: 8388608,
    pixelWidth: nil,
    pixelHeight: nil,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.moonleaf.glyph.master.json")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.moonleaf.output.script-specimen-preview")!,
    resource: ApplicationResource(name: "moonleaf-script-specimen", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/script/moonleaf-script-specimen.png",
    role: ThemeResourceRoleID(rawValue: "script.specimen-preview")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "4cb11f18b9e5a53194491e3739c218c71ef0486f42188b6808e4cfb6435af535",
    byteCount: 25929,
    maximumByteCount: 2097152,
    pixelWidth: 1024,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.moonleaf.glyph.master.json")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.moonleaf.output.script-static-fallback")!,
    resource: ApplicationResource(name: "moonleaf-script-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/script/moonleaf-script-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "script.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "8bd515c4e5056343bb89472bda3dee0c770db7ce55fe00aaecbd67999f383f8b",
    byteCount: 20870,
    maximumByteCount: 2097152,
    pixelWidth: 1024,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.moonleaf.glyph.master.json")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.crescentleaf.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "moonleaf-crescentleaf-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-crescentleaf-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "a9fd076062c75c42abeaf0078bfa1f5ce591d3e8f819c57eff6d0a32c990961d",
    byteCount: 5491,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.crescentleaf.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.crescentleaf.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-crescentleaf-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-crescentleaf-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "4f936a87ae6d2633c570b66e0703ccc572d10d450fdde04ed1be914d851f1e5a",
    byteCount: 3061,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.crescentleaf.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.crescentleaf.output.seal-vector-master")!,
    resource: ApplicationResource(name: "moonleaf-crescentleaf-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-crescentleaf-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "a09e3bd1e4ccf912099a211a66759cced016118260a36c177e5beb87d540be4d",
    byteCount: 5652,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.crescentleaf.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.echo-firefly.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "moonleaf-echo-firefly-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-echo-firefly-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "4fd60589ba7f1d5f54151be6e980f3f282dafddb8850b2c1a719ec20a66dcd81",
    byteCount: 10618,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.echo.firefly.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.echo-firefly.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-echo-firefly-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-echo-firefly-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "4610758e71cb2ba0853cdb68d5f544974bd0f4ef2002b296e822cf2e99e487c8",
    byteCount: 4494,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.echo.firefly.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.echo-firefly.output.seal-vector-master")!,
    resource: ApplicationResource(name: "moonleaf-echo-firefly-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-echo-firefly-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "fa7edb733a98cfa27d15c0d896aaa43ef50fbf1b3cd27a01f63c278d087d0a45",
    byteCount: 10917,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.echo.firefly.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.moonwell.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "moonleaf-moonwell-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-moonwell-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "5809b4e1e74ddfa3373161e8711ace591000ac3bf1e2e9527639abe8a7754ee6",
    byteCount: 4637,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.moonwell.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.moonwell.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-moonwell-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-moonwell-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "28799c6b433e3a3e4584dcb509e01390b62c151978b9432f1864701f86e0fac4",
    byteCount: 3061,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.moonwell.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.moonwell.output.seal-vector-master")!,
    resource: ApplicationResource(name: "moonleaf-moonwell-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-moonwell-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "3730e5bfbb1d6326e11e1788a98269c39dcdad899df0ac9ed18caa4b4125d053",
    byteCount: 4775,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.moonwell.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.night-owl.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "moonleaf-night-owl-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-night-owl-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "2b2a2fd8ea3d314171294c1383d599c6f6b2730533f14d5d0da78f56082bddee",
    byteCount: 9967,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.night.owl.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.night-owl.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-night-owl-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-night-owl-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "01e3c1e9f5610b453013aa6853a2f9f2b78b595df8cdfdd5d744f5dc0aa38ee1",
    byteCount: 3966,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.night.owl.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.night-owl.output.seal-vector-master")!,
    resource: ApplicationResource(name: "moonleaf-night-owl-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-night-owl-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "c5b01595d6dca521167834956567734e6a610ba35b5f8d71692766dbda72bfd0",
    byteCount: 10267,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.night.owl.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.starflower.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "moonleaf-starflower-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-starflower-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "3610e631476ffcde48b4300c386d0a80cd6a797cdf2e0bac7e1be191857b6a0c",
    byteCount: 7151,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.starflower.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.starflower.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-starflower-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-starflower-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "e1027e732995b59c9e4de24c0ec5b278864a62594da6484e3165eef87da03049",
    byteCount: 2863,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.starflower.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.starflower.output.seal-vector-master")!,
    resource: ApplicationResource(name: "moonleaf-starflower-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-starflower-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "2f9c49a0ebb174dd5eb55297f2ff113ea3d436e599a7ffccbdc0bcfeb9d17025",
    byteCount: 7450,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.starflower.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.woodland-stag.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "moonleaf-woodland-stag-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-woodland-stag-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "37830d44a69eb4e2892cc99f0a2695651fa429eb63cd79880cf1c0a1584ca19b",
    byteCount: 7891,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.woodland.stag.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.woodland-stag.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "moonleaf-woodland-stag-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-woodland-stag-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "af461c6544ba21e6d38861ef8088cd2edba31f09fc8a8ebd6bf3f074880aae52",
    byteCount: 3156,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.woodland.stag.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.moonleaf.woodland-stag.output.seal-vector-master")!,
    resource: ApplicationResource(name: "moonleaf-woodland-stag-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/seal/moonleaf-woodland-stag-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "d27ea99add22bbae3d1e55e5cce565543b92cb7a0d2bdc03252cbeffdc65e14b",
    byteCount: 8236,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.moonleaf.woodland.stag.svg")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.moonleaf.codex.output.vault-card")!,
    resource: ApplicationResource(name: "moonleaf-vault-card", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/vault/moonleaf-vault-card.png",
    role: ThemeResourceRoleID(rawValue: "vault.card")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "5531e21cdadfdd76780f96844daf86aa62858d813fad402d363e3ece91bb64b9",
    byteCount: 25986,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.moonleaf.moonleaf.vault.recipe.json")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.moonleaf.codex.output.vault-encountered")!,
    resource: ApplicationResource(name: "moonleaf-vault-encountered", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/vault/moonleaf-vault-encountered.png",
    role: ThemeResourceRoleID(rawValue: "vault.encountered")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "85f06aecbc0e07e555de3e968ae1497ec65c6c9f7c7f765585557be7cce0a2b7",
    byteCount: 23738,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.moonleaf.moonleaf.vault.recipe.json")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.moonleaf.codex.output.vault-locked-silhouette")!,
    resource: ApplicationResource(name: "moonleaf-vault-locked", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/vault/moonleaf-vault-locked.png",
    role: ThemeResourceRoleID(rawValue: "vault.locked-silhouette")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "a47fc521c19a7b6a97e77939d89bc2870e8f2cf4f4fb574c3eac6ece2e5a4a34",
    byteCount: 22858,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.moonleaf.moonleaf.vault.recipe.json")!
),
MoonleafThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.moonleaf.codex.output.vault-selected")!,
    resource: ApplicationResource(name: "moonleaf-vault-selected", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.moonleaf"),
    relativePath: "Production/vault/moonleaf-vault-selected.png",
    role: ThemeResourceRoleID(rawValue: "vault.selected")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "36aaa625951f2a6b4eab571afd39d85f27dad09aa41230b1da78258b0ac99890",
    byteCount: 29317,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.moonleaf.moonleaf.vault.recipe.json")!
)
    ]

    static let localizationPayload = Data(#"{"locale":"en","strings":{}}"#.utf8)

    static let localizationDefinition = MoonleafThemeResourceDefinition(
        id: ThemeResourceID(rawValue: "resource.localization.moonleaf.control")!,
        resource: ApplicationResource(
            name: "moonleaf-localization-en",
            fileExtension: "json",
            ownerModuleID: "com.runescribe.module.theme.moonleaf"
        ),
        relativePath: "embedded/moonleaf-localization-en.json",
        role: ThemeResourceRoles.localizationStrings,
        mediaType: .json,
        requirement: .required,
        sha256Hex: sha256Hex(localizationPayload),
        byteCount: localizationPayload.count,
        maximumByteCount: 64 * 1_024,
        pixelWidth: nil,
        pixelHeight: nil,
        rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json")!
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
              manifest.codexID == "codex.moonleaf",
              manifest.moduleID == "com.runescribe.module.theme.moonleaf",
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
