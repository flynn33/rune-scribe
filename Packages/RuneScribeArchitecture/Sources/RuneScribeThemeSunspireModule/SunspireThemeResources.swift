import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum SunspireThemeResourceError: Error, Equatable, Sendable {
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case invalidIntegrityManifest
    case resourcePayloadSetMismatch
    case resourceBudgetExceeded(String)
}

public struct SunspireThemeBundledResourceDescriptor: Equatable, Hashable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data { Data(hexadecimal: expectedSHA256Hex) }
}

public enum SunspireThemeBundledResourceCatalog {
    public static let moduleManifest = ApplicationResource(
        name: "module-manifest",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.sunspire"
    )
    public static let integrityManifest = ApplicationResource(
        name: "Resource-Integrity-Manifest-v1.0",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.sunspire"
    )
    public static let integrityManifestDescriptor = SunspireThemeBundledResourceDescriptor(
        resource: integrityManifest,
        expectedByteCount: 14495,
        expectedSHA256Hex: "da391cc35e89ad0606099e50e98bb2e28591420f68ec745efc2878411e9b1edc",
        maximumByteCount: 64 * 1_024
    )

    public static var all: Set<ApplicationResource> {
        Set([moduleManifest, integrityManifest] + SunspireThemeResourceCatalog.productionDefinitions.map { $0.resource })
    }
}

public struct ValidatedSunspireTheme: Sendable {
    public let descriptor: ThemeDescriptor
    public let resourcePayloads: [ThemeResourceID: Data]
}

public struct SunspireThemeResourceBudgetReport: Equatable, Sendable {
    public let shippingBytes: Int
    public let staticImageBytes: Int
    public let fontBytes: Int
    public let largestResourceBytes: Int
}

public enum SunspireThemeResources {
    public static func loadValidated(using runtimeIO: RuntimeIOClient) async throws -> ValidatedSunspireTheme {
        let manifestData = try await read(
            SunspireThemeBundledResourceCatalog.integrityManifestDescriptor,
            using: runtimeIO
        )
        guard SunspireThemeResourceCatalog.validateIntegrityManifest(manifestData) else {
            throw SunspireThemeResourceError.invalidIntegrityManifest
        }

        var payloads: [ThemeResourceID: Data] = [:]
        var physicalPayloads: [ApplicationResource: Data] = [
            SunspireThemeBundledResourceCatalog.integrityManifest: manifestData,
        ]
        for definition in SunspireThemeResourceCatalog.productionDefinitions {
            let data: Data
            if let cached = physicalPayloads[definition.resource] {
                data = cached
            } else {
                data = try await read(definition.bundledDescriptor, using: runtimeIO)
                physicalPayloads[definition.resource] = data
            }
            payloads[definition.id] = data
        }
        payloads[SunspireThemeResourceCatalog.localizationDefinition.id] =
            SunspireThemeResourceCatalog.localizationPayload

        _ = try budgetReport(payloads: payloads)
        let descriptor = SunspireThemeDescriptorFactory.discoveryDescriptor
        guard Set(payloads.keys) == Set(descriptor.resources.map { $0.id }),
              SunspireThemeResourceCatalog.validates(payloads)
        else {
            throw SunspireThemeResourceError.resourcePayloadSetMismatch
        }
        return ValidatedSunspireTheme(descriptor: descriptor, resourcePayloads: payloads)
    }

    public static func budgetReport(
        payloads: [ThemeResourceID: Data]
    ) throws -> SunspireThemeResourceBudgetReport {
        let production = SunspireThemeResourceCatalog.productionDefinitions
        let values = try production.map { definition -> (SunspireThemeResourceDefinition, Data) in
            guard let data = payloads[definition.id], data.count <= definition.maximumByteCount else {
                throw SunspireThemeResourceError.resourceBudgetExceeded(definition.id.rawValue)
            }
            return (definition, data)
        }
        let shipping = values.reduce(0) { $0 + $1.1.count }
        let staticBytes = values.filter { [.png, .heif, .pdf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let fontBytes = values.filter { [.ttf, .otf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let largest = values.map { $0.1.count }.max() ?? 0
        guard shipping == 666458,
              staticBytes <= 32 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else {
            throw SunspireThemeResourceError.resourceBudgetExceeded("complete-theme")
        }
        return SunspireThemeResourceBudgetReport(
            shippingBytes: shipping,
            staticImageBytes: staticBytes,
            fontBytes: fontBytes,
            largestResourceBytes: largest
        )
    }

    private static func read(
        _ descriptor: SunspireThemeBundledResourceDescriptor,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data = try await runtimeIO.readVerifiedApplicationResource(
            descriptor.resource,
            expectedSHA256: descriptor.expectedSHA256,
            maximumByteCount: descriptor.maximumByteCount
        )
        guard data.count == descriptor.expectedByteCount else {
            throw SunspireThemeResourceError.resourceByteCountMismatch(
                resource: "\(descriptor.resource.name).\(descriptor.resource.fileExtension)",
                expected: descriptor.expectedByteCount,
                actual: data.count
            )
        }
        return data
    }
}

struct SunspireThemeResourceDefinition: Equatable, Sendable {
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

    var bundledDescriptor: SunspireThemeBundledResourceDescriptor {
        SunspireThemeBundledResourceDescriptor(
            resource: resource,
            expectedByteCount: byteCount,
            expectedSHA256Hex: sha256Hex,
            maximumByteCount: maximumByteCount
        )
    }
}

enum SunspireThemeResourceCatalog {
    static let productionDefinitions: [SunspireThemeResourceDefinition] = [
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.sunspire.hall-of-first-light.output.background-high-contrast")!,
    resource: ApplicationResource(name: "sunspire-background-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/background/sunspire-background-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "background.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "007ce2728036bde7a8d23ed5608c9e95cb347c3b2f5ee983eb2bfc4f2f0d95c4",
    byteCount: 14878,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.sunspire.sunspire.background.recipe.json")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.sunspire.hall-of-first-light.output.background-reduce-motion")!,
    resource: ApplicationResource(name: "sunspire-background-reduce-motion", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/background/sunspire-background-reduce-motion.png",
    role: ThemeResourceRoleID(rawValue: "background.reduce-motion")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "cc6ae9acd5a4f8677c6131f27cb7fb72267c161649d3c8a23011bd9a7b27d07a",
    byteCount: 16917,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.sunspire.sunspire.background.recipe.json")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.sunspire.hall-of-first-light.output.background-static-base")!,
    resource: ApplicationResource(name: "sunspire-background-static", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/background/sunspire-background-static.png",
    role: ThemeResourceRoleID(rawValue: "background.static-base")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "a53245f8cf3c7a07afb3495bc2ee2adf2f62e9de0b838d154375f820df0d6833",
    byteCount: 17307,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.sunspire.sunspire.background.recipe.json")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.sunspire.first-light.output.crest-static-fallback")!,
    resource: ApplicationResource(name: "sunspire-first-light-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/crest/sunspire-first-light-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "crest.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "65d67ec928b617d9835a2e1ef68e04bd5f2bc9b4065041d9ab99827cb605111d",
    byteCount: 13644,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.sunspire.first.light.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.sunspire.first-light.output.crest-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-first-light-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/crest/sunspire-first-light-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "crest.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "3ad40287cc4dd370fdcbaedbb713f95ca97938edd8cc20b2fe9d8df8d894618e",
    byteCount: 52561,
    maximumByteCount: 4194304,
    pixelWidth: 512,
    pixelHeight: 512,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.sunspire.first.light.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.sunspire.first-light.output.crest-vector-master")!,
    resource: ApplicationResource(name: "sunspire-first-light-vector", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/crest/sunspire-first-light-vector.pdf",
    role: ThemeResourceRoleID(rawValue: "crest.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "828a00733938d87859636681234499872e8f9c119ce39aa88def6fa2807e78bb",
    byteCount: 4932,
    maximumByteCount: 8388608,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.sunspire.first.light.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.sunspire.laurel-of-dawn.output.frame-static-fallback")!,
    resource: ApplicationResource(name: "sunspire-laurel-of-dawn-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/frame/sunspire-laurel-of-dawn-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "frame.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "b62b480e0a70b7104213366b701b6af65e82618e759a5bec322af7eb722a8b70",
    byteCount: 13802,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.sunspire.laurel.of.dawn.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.sunspire.laurel-of-dawn.output.frame-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-laurel-of-dawn-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/frame/sunspire-laurel-of-dawn-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "frame.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "c0ff9a66c29d01d92a3cfa3fcba8ecfdb9c9e26bfe2083aa767d5dfe772b6cfd",
    byteCount: 21479,
    maximumByteCount: 4194304,
    pixelWidth: 512,
    pixelHeight: 384,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.sunspire.laurel.of.dawn.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.sunspire.laurel-of-dawn.output.frame-vector-master")!,
    resource: ApplicationResource(name: "sunspire-laurel-of-dawn-vector", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/frame/sunspire-laurel-of-dawn-vector.pdf",
    role: ThemeResourceRoleID(rawValue: "frame.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "656ccf129f331672876123ffaa330c916f50d5829a40649be178f992f6fdaf03",
    byteCount: 15870,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.sunspire.laurel.of.dawn.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.auric-stele.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "sunspire-auric-stele-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-auric-stele-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "530b5dcda06e6ac9e644d41219dc04569916a08e2f25886e5e723f3dbe679514",
    byteCount: 11811,
    maximumByteCount: 2097152,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.auric.stele.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.auric-stele.output.relic-master")!,
    resource: ApplicationResource(name: "sunspire-auric-stele-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-auric-stele-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "cdd4117f9ca77b716c1eb0a61a0673c78097fb0c46b973f7d7868e89a0123a6f",
    byteCount: 15585,
    maximumByteCount: 4194304,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.auric.stele.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.auric-stele.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "sunspire-auric-stele-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-auric-stele-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "a2e4343e12fb0da7f68891c588d2261ea778ab07cb09be8893a0a2daad44d76c",
    byteCount: 10158,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.auric.stele.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.auric-stele.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-auric-stele-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-auric-stele-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "87ef57634e448730a14f0c46d9c9262357c476bc15f0ca77c703dbca037cc751",
    byteCount: 8557,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.auric.stele.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.dawnfire-tablet.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "sunspire-dawnfire-tablet-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-dawnfire-tablet-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "dca89a9ff479e3b9db01d9740090318ff7fe7d51fec66bf657fc27972a10e944",
    byteCount: 11155,
    maximumByteCount: 2097152,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.dawnfire.tablet.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.dawnfire-tablet.output.relic-master")!,
    resource: ApplicationResource(name: "sunspire-dawnfire-tablet-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-dawnfire-tablet-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "700d02edcc7e0d190f82275968c4ab83a7991d807b594881dd04513c59ef4573",
    byteCount: 17941,
    maximumByteCount: 4194304,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.dawnfire.tablet.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.dawnfire-tablet.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "sunspire-dawnfire-tablet-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-dawnfire-tablet-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "3d55513cede7edc3f41d2a3523379d5584e45eba23d7988a8e9f3cf117f4e47f",
    byteCount: 12388,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.dawnfire.tablet.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.dawnfire-tablet.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-dawnfire-tablet-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-dawnfire-tablet-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "37ff07e8a2658fe10c91ff7186f52ec969b82368be8b659b845d2e8133d61839",
    byteCount: 9049,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.dawnfire.tablet.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.solvine-plaque.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "sunspire-solvine-plaque-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-solvine-plaque-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "30cc72aacac5510e7bd34c19099f14a63db6d71dbd5f0bc4638c1a0cba5f2237",
    byteCount: 12040,
    maximumByteCount: 2097152,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.solvine.plaque.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.solvine-plaque.output.relic-master")!,
    resource: ApplicationResource(name: "sunspire-solvine-plaque-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-solvine-plaque-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "62e468e957cd76439700e7c3a301469f8edeb3c432fada531bb5d9fa13e2f79d",
    byteCount: 18176,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.solvine.plaque.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.solvine-plaque.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "sunspire-solvine-plaque-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-solvine-plaque-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "9092487a2eeddec2ac9d9cc886af09c36cf535ee7034c171f5daaf3c2fa7d171",
    byteCount: 15793,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.solvine.plaque.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.sunspire.solvine-plaque.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-solvine-plaque-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/relic/sunspire-solvine-plaque-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "ae668a737dca2c07283b609573ea824513a05c1f9c6c2e9c4c6463661639d2cf",
    byteCount: 10669,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.sunspire.solvine.plaque.geometry.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.sunspire.output.script-font")!,
    resource: ApplicationResource(name: "sunspire-script-primary", fileExtension: "ttf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/script/sunspire-script-primary.ttf",
    role: ThemeResourceRoleID(rawValue: "script.font")!,
    mediaType: .ttf,
    requirement: .required,
    sha256Hex: "af4394a11b37bbd0a7cfa276e727a26a505a2712a6a54847488a38f2f4ca79ab",
    byteCount: 96648,
    maximumByteCount: 8388608,
    pixelWidth: nil,
    pixelHeight: nil,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.sunspire.glyph.master.json")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.sunspire.output.script-specimen-preview")!,
    resource: ApplicationResource(name: "sunspire-script-specimen", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/script/sunspire-script-specimen.png",
    role: ThemeResourceRoleID(rawValue: "script.specimen-preview")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "8020e5f687a55af6bcea5db224ba2e2782c95dc3c91d45574458c0c1a3961dd4",
    byteCount: 24785,
    maximumByteCount: 2097152,
    pixelWidth: 1024,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.sunspire.glyph.master.json")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.sunspire.output.script-static-fallback")!,
    resource: ApplicationResource(name: "sunspire-script-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/script/sunspire-script-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "script.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "e8337ea0ddc8c421a6a01cf4b06275e674051adfdd682788288f47f4762cdf7e",
    byteCount: 20386,
    maximumByteCount: 2097152,
    pixelWidth: 1024,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.sunspire.glyph.master.json")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.dawnflower.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "sunspire-dawnflower-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-dawnflower-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "0d10a0d4aabead159b03f898882129ad205005b6378bc4072ef88d262f5df927",
    byteCount: 7305,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.dawnflower.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.dawnflower.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-dawnflower-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-dawnflower-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "2e92a2d1ae15b7373cc488a14068f5fd4783738eda45a726973436e1fededb59",
    byteCount: 2741,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.dawnflower.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.dawnflower.output.seal-vector-master")!,
    resource: ApplicationResource(name: "sunspire-dawnflower-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-dawnflower-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "d23a638f0109e909e51e2ac15450b03b7c64ffa1e033dd99382dee3f26932ab1",
    byteCount: 7535,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.dawnflower.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.echo-ember.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "sunspire-echo-ember-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-echo-ember-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "53d38096f911ceb5b2315c8c7356d58213a3bbf235ccc2ed462625ee3651363c",
    byteCount: 5860,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.echo.ember.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.echo-ember.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-echo-ember-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-echo-ember-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "e616bc60dd6455c479150677ca2ae3a82619a6f2f89af9e992198921cac6e3e4",
    byteCount: 3895,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.echo.ember.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.echo-ember.output.seal-vector-master")!,
    resource: ApplicationResource(name: "sunspire-echo-ember-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-echo-ember-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "08df4ce70b0db83a7bbfce91dc31af206967a6e8d530aa36f869992bcbe077c5",
    byteCount: 5998,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.echo.ember.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.golden-lark.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "sunspire-golden-lark-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-golden-lark-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "a2ceca638629edc8b3dc66a209e48c81805f62ac90112a7da7c2b033b5912b8b",
    byteCount: 6558,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.golden.lark.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.golden-lark.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-golden-lark-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-golden-lark-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "4d8d56307b745fabf4deff3fc125d654bd43cce0845114b7084f7391f17af87e",
    byteCount: 3063,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.golden.lark.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.golden-lark.output.seal-vector-master")!,
    resource: ApplicationResource(name: "sunspire-golden-lark-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-golden-lark-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "d2626f3d78f6ba4bac30c18d8786f018c2b61d8e12f16b208ee2ec9617bcd86d",
    byteCount: 6765,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.golden.lark.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.radiant-spire.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "sunspire-radiant-spire-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-radiant-spire-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "04552e8cf04d1f327c7271f99afffe6ba682b829b133ef5862f66245b747b672",
    byteCount: 2470,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.radiant.spire.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.radiant-spire.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-radiant-spire-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-radiant-spire-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "a8f22d8069f7f33e71ae0e0a009791f46d02a5abc8723a373a38f0533fd58944",
    byteCount: 2832,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.radiant.spire.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.radiant-spire.output.seal-vector-master")!,
    resource: ApplicationResource(name: "sunspire-radiant-spire-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-radiant-spire-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "3b5d9acd94acaa0ed9505a576285bdafde2128499362a72d987a70f29eb34d42",
    byteCount: 2654,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.radiant.spire.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.sunleaf-crest.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "sunspire-sunleaf-crest-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-sunleaf-crest-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "6ac37f57e720cf1cfe10c8d4e9bebde9c8da877e8f6242efed7477e3cc518185",
    byteCount: 8531,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.sunleaf.crest.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.sunleaf-crest.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-sunleaf-crest-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-sunleaf-crest-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "1964ff66b717ddb83ccd38a2a7b632059e831d3f7ee49fa594ebde010cc3bd51",
    byteCount: 3289,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.sunleaf.crest.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.sunleaf-crest.output.seal-vector-master")!,
    resource: ApplicationResource(name: "sunspire-sunleaf-crest-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-sunleaf-crest-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "994a9466b01ae555e3ad7d53a1244de3aa02c74b0316b08cf82428633782d86d",
    byteCount: 8968,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.sunleaf.crest.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.sunwheel.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "sunspire-sunwheel-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-sunwheel-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "dfbb9e6a5b8844a4488e32f399bc4e23e11947724abfd9a5298554861d5edbf8",
    byteCount: 9482,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.sunwheel.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.sunwheel.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "sunspire-sunwheel-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-sunwheel-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "b312b0f4552042b0b7c08a9f52eeac393d48c4f7af585243c41a5f42eb7da6b2",
    byteCount: 3772,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.sunwheel.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.sunspire.sunwheel.output.seal-vector-master")!,
    resource: ApplicationResource(name: "sunspire-sunwheel-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/seal/sunspire-sunwheel-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "2047ac32e8e22c4b68faa5f07fb4eb6524056fa2bac7be21a32074c1e6d814a3",
    byteCount: 9942,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.sunspire.sunwheel.svg")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.sunspire.codex.output.vault-card")!,
    resource: ApplicationResource(name: "sunspire-vault-card", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/vault/sunspire-vault-card.png",
    role: ThemeResourceRoleID(rawValue: "vault.card")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "cf69cf2ee9bf8dc1ad8623d14cc7e813757a3b95cc3db4e8b4439d27299557ea",
    byteCount: 25044,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.sunspire.sunspire.vault.recipe.json")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.sunspire.codex.output.vault-encountered")!,
    resource: ApplicationResource(name: "sunspire-vault-encountered", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/vault/sunspire-vault-encountered.png",
    role: ThemeResourceRoleID(rawValue: "vault.encountered")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "ce00d62d5e861a313bae15c70158f6a4164946d03167544651b8280183c58196",
    byteCount: 22764,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.sunspire.sunspire.vault.recipe.json")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.sunspire.codex.output.vault-locked-silhouette")!,
    resource: ApplicationResource(name: "sunspire-vault-locked", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/vault/sunspire-vault-locked.png",
    role: ThemeResourceRoleID(rawValue: "vault.locked-silhouette")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "5530458342ee5e21b04d80a0a052b982b95bbca03db40a7e3234fad637005a92",
    byteCount: 21734,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.sunspire.sunspire.vault.recipe.json")!
),
SunspireThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.sunspire.codex.output.vault-selected")!,
    resource: ApplicationResource(name: "sunspire-vault-selected", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.sunspire"),
    relativePath: "Production/vault/sunspire-vault-selected.png",
    role: ThemeResourceRoleID(rawValue: "vault.selected")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "8998efd0edf8196f5a38900c2985c0d81cf496ca2ad22d3ea2a5fda6bd46a56a",
    byteCount: 28725,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.sunspire.sunspire.vault.recipe.json")!
)
    ]

    static let localizationPayload = Data(#"{"locale":"en","strings":{}}"#.utf8)

    static let localizationDefinition = SunspireThemeResourceDefinition(
        id: ThemeResourceID(rawValue: "resource.localization.sunspire.control")!,
        resource: ApplicationResource(
            name: "sunspire-localization-en",
            fileExtension: "json",
            ownerModuleID: "com.runescribe.module.theme.sunspire"
        ),
        relativePath: "embedded/sunspire-localization-en.json",
        role: ThemeResourceRoles.localizationStrings,
        mediaType: .json,
        requirement: .required,
        sha256Hex: sha256Hex(localizationPayload),
        byteCount: localizationPayload.count,
        maximumByteCount: 64 * 1_024,
        pixelWidth: nil,
        pixelHeight: nil,
        rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.sunspire.sunspire.background.recipe.json")!
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
              manifest.codexID == "codex.sunspire",
              manifest.moduleID == "com.runescribe.module.theme.sunspire",
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
