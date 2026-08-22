import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum GloamthornThemeResourceError: Error, Equatable, Sendable {
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case invalidIntegrityManifest
    case resourcePayloadSetMismatch
    case resourceBudgetExceeded(String)
}

public struct GloamthornThemeBundledResourceDescriptor: Equatable, Hashable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data { Data(hexadecimal: expectedSHA256Hex) }
}

public enum GloamthornThemeBundledResourceCatalog {
    public static let moduleManifest = ApplicationResource(
        name: "module-manifest",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.gloamthorn"
    )
    public static let integrityManifest = ApplicationResource(
        name: "Resource-Integrity-Manifest-v1.0",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.gloamthorn"
    )
    public static let integrityManifestDescriptor = GloamthornThemeBundledResourceDescriptor(
        resource: integrityManifest,
        expectedByteCount: 14743,
        expectedSHA256Hex: "1808d845cbcf30ae21ae87cd1ec8e3db549ab493a652de420de7d8868466c6d9",
        maximumByteCount: 64 * 1_024
    )

    public static var all: Set<ApplicationResource> {
        Set([moduleManifest, integrityManifest] + GloamthornThemeResourceCatalog.productionDefinitions.map { $0.resource })
    }
}

public struct ValidatedGloamthornTheme: Sendable {
    public let descriptor: ThemeDescriptor
    public let resourcePayloads: [ThemeResourceID: Data]
}

public struct GloamthornThemeResourceBudgetReport: Equatable, Sendable {
    public let shippingBytes: Int
    public let staticImageBytes: Int
    public let fontBytes: Int
    public let largestResourceBytes: Int
}

public enum GloamthornThemeResources {
    public static func loadValidated(using runtimeIO: RuntimeIOClient) async throws -> ValidatedGloamthornTheme {
        let manifestData = try await read(
            GloamthornThemeBundledResourceCatalog.integrityManifestDescriptor,
            using: runtimeIO
        )
        guard GloamthornThemeResourceCatalog.validateIntegrityManifest(manifestData) else {
            throw GloamthornThemeResourceError.invalidIntegrityManifest
        }

        var payloads: [ThemeResourceID: Data] = [:]
        var physicalPayloads: [ApplicationResource: Data] = [
            GloamthornThemeBundledResourceCatalog.integrityManifest: manifestData,
        ]
        for definition in GloamthornThemeResourceCatalog.productionDefinitions {
            let data: Data
            if let cached = physicalPayloads[definition.resource] {
                data = cached
            } else {
                data = try await read(definition.bundledDescriptor, using: runtimeIO)
                physicalPayloads[definition.resource] = data
            }
            payloads[definition.id] = data
        }
        payloads[GloamthornThemeResourceCatalog.localizationDefinition.id] =
            GloamthornThemeResourceCatalog.localizationPayload

        _ = try budgetReport(payloads: payloads)
        let descriptor = GloamthornThemeDescriptorFactory.discoveryDescriptor
        guard Set(payloads.keys) == Set(descriptor.resources.map { $0.id }),
              GloamthornThemeResourceCatalog.validates(payloads)
        else {
            throw GloamthornThemeResourceError.resourcePayloadSetMismatch
        }
        return ValidatedGloamthornTheme(descriptor: descriptor, resourcePayloads: payloads)
    }

    public static func budgetReport(
        payloads: [ThemeResourceID: Data]
    ) throws -> GloamthornThemeResourceBudgetReport {
        let production = GloamthornThemeResourceCatalog.productionDefinitions
        let values = try production.map { definition -> (GloamthornThemeResourceDefinition, Data) in
            guard let data = payloads[definition.id], data.count <= definition.maximumByteCount else {
                throw GloamthornThemeResourceError.resourceBudgetExceeded(definition.id.rawValue)
            }
            return (definition, data)
        }
        let shipping = values.reduce(0) { $0 + $1.1.count }
        let staticBytes = values.filter { [.png, .heif, .pdf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let fontBytes = values.filter { [.ttf, .otf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let largest = values.map { $0.1.count }.max() ?? 0
        guard shipping == 609418,
              staticBytes <= 32 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else {
            throw GloamthornThemeResourceError.resourceBudgetExceeded("complete-theme")
        }
        return GloamthornThemeResourceBudgetReport(
            shippingBytes: shipping,
            staticImageBytes: staticBytes,
            fontBytes: fontBytes,
            largestResourceBytes: largest
        )
    }

    private static func read(
        _ descriptor: GloamthornThemeBundledResourceDescriptor,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data = try await runtimeIO.readVerifiedApplicationResource(
            descriptor.resource,
            expectedSHA256: descriptor.expectedSHA256,
            maximumByteCount: descriptor.maximumByteCount
        )
        guard data.count == descriptor.expectedByteCount else {
            throw GloamthornThemeResourceError.resourceByteCountMismatch(
                resource: "\(descriptor.resource.name).\(descriptor.resource.fileExtension)",
                expected: descriptor.expectedByteCount,
                actual: data.count
            )
        }
        return data
    }
}

struct GloamthornThemeResourceDefinition: Equatable, Sendable {
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

    var bundledDescriptor: GloamthornThemeBundledResourceDescriptor {
        GloamthornThemeBundledResourceDescriptor(
            resource: resource,
            expectedByteCount: byteCount,
            expectedSHA256Hex: sha256Hex,
            maximumByteCount: maximumByteCount
        )
    }
}

enum GloamthornThemeResourceCatalog {
    static let productionDefinitions: [GloamthornThemeResourceDefinition] = [
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.gloamthorn.twilight-briar.output.background-high-contrast")!,
    resource: ApplicationResource(name: "gloamthorn-background-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/background/gloamthorn-background-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "background.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "b89c76557b73373ed2b14c7faa398c0cc9bfe8ed5150e084511b6d91c3d28d2c",
    byteCount: 15112,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.gloamthorn.gloamthorn.background.recipe.json")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.gloamthorn.twilight-briar.output.background-reduce-motion")!,
    resource: ApplicationResource(name: "gloamthorn-background-reduce-motion", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/background/gloamthorn-background-reduce-motion.png",
    role: ThemeResourceRoleID(rawValue: "background.reduce-motion")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "b0e34c2b202b73af6e844d76e9579f40b63ad803bd0e8809e61e34da06f8a5a2",
    byteCount: 16736,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.gloamthorn.gloamthorn.background.recipe.json")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.background.gloamthorn.twilight-briar.output.background-static-base")!,
    resource: ApplicationResource(name: "gloamthorn-background-static", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/background/gloamthorn-background-static.png",
    role: ThemeResourceRoleID(rawValue: "background.static-base")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "e43f33634ec59dcb72a85bf216eb99336a5d5a08793684e9898073cc699b1830",
    byteCount: 17088,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.gloamthorn.gloamthorn.background.recipe.json")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.gloamthorn.gloam-sovereign.output.crest-static-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-gloam-sovereign-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/crest/gloamthorn-gloam-sovereign-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "crest.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "09b0828666c9ffcb20774062e1121d08771aaaa8878396cd2269f5569ab53c7f",
    byteCount: 13505,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.gloamthorn.gloam.sovereign.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.gloamthorn.gloam-sovereign.output.crest-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-gloam-sovereign-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/crest/gloamthorn-gloam-sovereign-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "crest.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "f468d674c57388e9fc4533f4c8dbe78a8cfae3b7da038c325ae8895775e63569",
    byteCount: 51976,
    maximumByteCount: 4194304,
    pixelWidth: 512,
    pixelHeight: 512,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.gloamthorn.gloam.sovereign.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.crest.gloamthorn.gloam-sovereign.output.crest-vector-master")!,
    resource: ApplicationResource(name: "gloamthorn-gloam-sovereign-vector", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/crest/gloamthorn-gloam-sovereign-vector.pdf",
    role: ThemeResourceRoleID(rawValue: "crest.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "50c8781c15ec8c2422ca99f792874fc0db710b87e80f3dc1623cda6986c7aec8",
    byteCount: 3661,
    maximumByteCount: 8388608,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Crests.gloamthorn.gloam.sovereign.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.gloamthorn.briar-court.output.frame-static-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-briar-court-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/frame/gloamthorn-briar-court-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "frame.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "66882d7c3901ec72f345264c06f662ef53296bdfeef0d741983e848dafe3efdb",
    byteCount: 13165,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.gloamthorn.briar.court.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.gloamthorn.briar-court.output.frame-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-briar-court-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/frame/gloamthorn-briar-court-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "frame.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "ce384663dfe73ac798719f4e360c9a970af45db8d0aec1e2160c76ad716f5b83",
    byteCount: 20302,
    maximumByteCount: 4194304,
    pixelWidth: 512,
    pixelHeight: 384,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.gloamthorn.briar.court.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.frame.gloamthorn.briar-court.output.frame-vector-master")!,
    resource: ApplicationResource(name: "gloamthorn-briar-court-vector", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/frame/gloamthorn-briar-court-vector.pdf",
    role: ThemeResourceRoleID(rawValue: "frame.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "048d120d0d5d430522cf9a9a0480abd4c7411bbcae490604498bc06dedc79aff",
    byteCount: 1803,
    maximumByteCount: 8388608,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Frames.gloamthorn.briar.court.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.duskbriar-stele.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "gloamthorn-duskbriar-stele-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-duskbriar-stele-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "6b203ae4c6861b06b1e93a838fc19cdbf96dff455a5187b6d67d493ea8d6ba3a",
    byteCount: 13142,
    maximumByteCount: 2097152,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.duskbriar.stele.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.duskbriar-stele.output.relic-master")!,
    resource: ApplicationResource(name: "gloamthorn-duskbriar-stele-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-duskbriar-stele-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "e6633bc20729dc1f6bae60503e823673109ab0501b49343e4651fee2ede0652c",
    byteCount: 16096,
    maximumByteCount: 4194304,
    pixelWidth: 1200,
    pixelHeight: 1600,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.duskbriar.stele.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.duskbriar-stele.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-duskbriar-stele-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-duskbriar-stele-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "59aa8e355187988adae1ddaff4bcd01fa1cbee7feb9c8dd9253927d2d370b2bb",
    byteCount: 11712,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.duskbriar.stele.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.duskbriar-stele.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-duskbriar-stele-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-duskbriar-stele-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "4aef66418a094bb7886b377247dddd660e7293fb8ccfe4eb4fb668c9e196f2cf",
    byteCount: 9148,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.duskbriar.stele.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.nightthorn-tablet.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "gloamthorn-nightthorn-tablet-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-nightthorn-tablet-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "813e21998c3b954a4b2c7997b00b6a1a4aefbc4dc3591f1b6f69a98743f685ab",
    byteCount: 10987,
    maximumByteCount: 2097152,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.nightthorn.tablet.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.nightthorn-tablet.output.relic-master")!,
    resource: ApplicationResource(name: "gloamthorn-nightthorn-tablet-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-nightthorn-tablet-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "0701c379f9a3e3a24fde187bdfa1315d65449bbf1a9a45dc37c2a43f21da1bdd",
    byteCount: 16844,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.nightthorn.tablet.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.nightthorn-tablet.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-nightthorn-tablet-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-nightthorn-tablet-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "dbfe396cce48a24e8a9e8778b773cb9d927fcdba919dbeadf732b62604a29ce9",
    byteCount: 19240,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.nightthorn.tablet.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.nightthorn-tablet.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-nightthorn-tablet-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-nightthorn-tablet-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "acbe38e9bf460b167c193f814d3d0a028d5115a0741ccde4d35753fcdb405e60",
    byteCount: 7830,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.nightthorn.tablet.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.umbral-plaque.output.relic-high-contrast")!,
    resource: ApplicationResource(name: "gloamthorn-umbral-plaque-high-contrast", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-umbral-plaque-high-contrast.png",
    role: ThemeResourceRoleID(rawValue: "relic.high-contrast")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "e9949cf29f15dff7ae01ba496cf1d5722ea73b9632ee60877d81278167c0ff8a",
    byteCount: 12021,
    maximumByteCount: 2097152,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.umbral.plaque.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.umbral-plaque.output.relic-master")!,
    resource: ApplicationResource(name: "gloamthorn-umbral-plaque-master", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-umbral-plaque-master.png",
    role: ThemeResourceRoleID(rawValue: "relic.master")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "db54c2ceb5e4dad8961920c411d47214a3c9443f77c3cdd43eef8be398957dcb",
    byteCount: 16353,
    maximumByteCount: 4194304,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.umbral.plaque.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.umbral-plaque.output.relic-static-share-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-umbral-plaque-static-share-fallback", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-umbral-plaque-static-share-fallback.heif",
    role: ThemeResourceRoleID(rawValue: "relic.static-share-fallback")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "e50cc6c861da2f632ec2af0e3778ffe4d6c79ce83841ca40105529f59afe1e6a",
    byteCount: 18508,
    maximumByteCount: 3145728,
    pixelWidth: 1600,
    pixelHeight: 1200,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.umbral.plaque.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.relic.gloamthorn.umbral-plaque.output.relic-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-umbral-plaque-thumbnail", fileExtension: "heif", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/relic/gloamthorn-umbral-plaque-thumbnail.heif",
    role: ThemeResourceRoleID(rawValue: "relic.thumbnail")!,
    mediaType: .heif,
    requirement: .required,
    sha256Hex: "f4618c89d8c6f76c0876f1ef58191e645245e955fcafc38d9ada32fc22ed2515",
    byteCount: 12742,
    maximumByteCount: 1048576,
    pixelWidth: 768,
    pixelHeight: 768,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Relic.Geometry.gloamthorn.umbral.plaque.geometry.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.gloamthorn.output.script-font")!,
    resource: ApplicationResource(name: "gloamthorn-script-primary", fileExtension: "ttf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/script/gloamthorn-script-primary.ttf",
    role: ThemeResourceRoleID(rawValue: "script.font")!,
    mediaType: .ttf,
    requirement: .required,
    sha256Hex: "a2cf3dd18a4e1bbf4a11b3995307873820c8715a17f4e745cd61fae6f92a65b3",
    byteCount: 44108,
    maximumByteCount: 8388608,
    pixelWidth: nil,
    pixelHeight: nil,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.gloamthorn.glyph.master.json")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.gloamthorn.output.script-specimen-preview")!,
    resource: ApplicationResource(name: "gloamthorn-script-specimen", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/script/gloamthorn-script-specimen.png",
    role: ThemeResourceRoleID(rawValue: "script.specimen-preview")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "216f9b64ac93ec10dd2a1f3af7d6cc708197c8319aa57fb6799c7ed5439c3975",
    byteCount: 26659,
    maximumByteCount: 2097152,
    pixelWidth: 1024,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.gloamthorn.glyph.master.json")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.script.gloamthorn.output.script-static-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-script-static-fallback", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/script/gloamthorn-script-static-fallback.png",
    role: ThemeResourceRoleID(rawValue: "script.static-fallback")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "2cf5bd8006079eaed36020fb5c2bdee6b5e85a2063d53a964330b84a6f035d78",
    byteCount: 20985,
    maximumByteCount: 2097152,
    pixelWidth: 1024,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Glyphs.gloamthorn.glyph.master.json")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.echo-wisp.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-echo-wisp-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-echo-wisp-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "40ee5a49390db358a0ecc5cc40b2d7c89273bcdbbe34592d95307ed7b4aedd57",
    byteCount: 5055,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.echo.wisp.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.echo-wisp.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-echo-wisp-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-echo-wisp-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "702adfae279b442206fb1f81f62b0512cbd4fcb042f9f6f4ed2462f8313d2103",
    byteCount: 3144,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.echo.wisp.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.echo-wisp.output.seal-vector-master")!,
    resource: ApplicationResource(name: "gloamthorn-echo-wisp-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-echo-wisp-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "1b12e7f7b305a1102a3c0390c7693c56f5390571103ff1bf36456124273af28d",
    byteCount: 5193,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.echo.wisp.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.eclipse-bloom.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-eclipse-bloom-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-eclipse-bloom-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "1278a84db313ed923e54cf85ba6b3dfda5dca3283443f7940bc6c2bfe8b39740",
    byteCount: 8862,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.eclipse.bloom.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.eclipse-bloom.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-eclipse-bloom-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-eclipse-bloom-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "f437f0c0499a44fa1cfe757c1cf6d2a5c2a95dcfc25df122b3d8c02c0b680f68",
    byteCount: 3069,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.eclipse.bloom.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.eclipse-bloom.output.seal-vector-master")!,
    resource: ApplicationResource(name: "gloamthorn-eclipse-bloom-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-eclipse-bloom-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "792eb0965a77cdf3fe2b376bf51de9747f0296fc28cbb37bb1cd83f344d32f60",
    byteCount: 9138,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.eclipse.bloom.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.nightglass-moth.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-nightglass-moth-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-nightglass-moth-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "829b3b0af2ab9d93aa871251244e91780eaf32ef3a74307f4f8578ce6887ad12",
    byteCount: 5078,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.nightglass.moth.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.nightglass-moth.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-nightglass-moth-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-nightglass-moth-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "329a43484dfcdd3be34404309807b7a73137c039c9cfc6e25701d64e51d7b26e",
    byteCount: 3377,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.nightglass.moth.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.nightglass-moth.output.seal-vector-master")!,
    resource: ApplicationResource(name: "gloamthorn-nightglass-moth-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-nightglass-moth-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "074f56f5c24cccf0bf2e3578304dd79b4e5cbfb3e87b193fb5508a84a1a9211a",
    byteCount: 5262,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.nightglass.moth.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.pact-crown.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-pact-crown-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-pact-crown-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "8159565e06b9342750ccf5f47e3b8992bea56c22099b236e506e496295f238c2",
    byteCount: 2490,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.pact.crown.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.pact-crown.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-pact-crown-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-pact-crown-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "79e3784c2ea421e00bfef6f307a1faf034ad2c8af537692fc7e4e06829a92956",
    byteCount: 2779,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.pact.crown.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.pact-crown.output.seal-vector-master")!,
    resource: ApplicationResource(name: "gloamthorn-pact-crown-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-pact-crown-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "45613ebfd4471e719cb9cfa1d16ffc95601b7cb68ba65ca9027cc5f00c42d01e",
    byteCount: 2674,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.pact.crown.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.thornmoon.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-thornmoon-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-thornmoon-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "0e37f0eb7a13d3d157aa44089aa96a94789f6cd693215221c70eae8f8f30aada",
    byteCount: 4465,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.thornmoon.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.thornmoon.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-thornmoon-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-thornmoon-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "836586c3163990026babd2458c065d99fd369fdcaa924466450a77b2432ac91f",
    byteCount: 3696,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.thornmoon.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.thornmoon.output.seal-vector-master")!,
    resource: ApplicationResource(name: "gloamthorn-thornmoon-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-thornmoon-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "98eb2245f23d9064c3814f0e1d76ce933ef71fbc1fcd25b0e6a3664d7a95ff68",
    byteCount: 4741,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.thornmoon.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.veiled-serpent.output.seal-monochrome-fallback")!,
    resource: ApplicationResource(name: "gloamthorn-veiled-serpent-monochrome-fallback", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-veiled-serpent-monochrome-fallback.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.monochrome-fallback")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "6e0b41d9a1e26c86ed85f43e2cb90c50e72ffc125e1ef56afab2a0f694ef10e6",
    byteCount: 6525,
    maximumByteCount: 262144,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.veiled.serpent.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.veiled-serpent.output.seal-thumbnail")!,
    resource: ApplicationResource(name: "gloamthorn-veiled-serpent-thumbnail", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-veiled-serpent-thumbnail.png",
    role: ThemeResourceRoleID(rawValue: "seal.thumbnail")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "085068273481b7d8d6f64bc6910cea54bb1280b7785f5d7086212afee86673f8",
    byteCount: 2952,
    maximumByteCount: 524288,
    pixelWidth: 256,
    pixelHeight: 256,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.veiled.serpent.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.seal.gloamthorn.veiled-serpent.output.seal-vector-master")!,
    resource: ApplicationResource(name: "gloamthorn-veiled-serpent-vector-master", fileExtension: "pdf", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/seal/gloamthorn-veiled-serpent-vector-master.pdf",
    role: ThemeResourceRoleID(rawValue: "seal.vector-master")!,
    mediaType: .pdf,
    requirement: .required,
    sha256Hex: "bdb15ec2ae7f1a037c368bba24613b89337af38ef89e8ca50dd4d841e2a754ca",
    byteCount: 6686,
    maximumByteCount: 524288,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Source.Masters.Seals.gloamthorn.veiled.serpent.svg")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.gloamthorn.codex.output.vault-card")!,
    resource: ApplicationResource(name: "gloamthorn-vault-card", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/vault/gloamthorn-vault-card.png",
    role: ThemeResourceRoleID(rawValue: "vault.card")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "28ce38649aac54894d86e8a651aecddf3a01350c51421f6ecf6d866357c3dba1",
    byteCount: 28720,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.gloamthorn.gloamthorn.vault.recipe.json")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.gloamthorn.codex.output.vault-encountered")!,
    resource: ApplicationResource(name: "gloamthorn-vault-encountered", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/vault/gloamthorn-vault-encountered.png",
    role: ThemeResourceRoleID(rawValue: "vault.encountered")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "cbb158d7fedc6e3e7d82aec05ba80d08dd78341cb7141f1fd72ed51fc313ecbf",
    byteCount: 27496,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.gloamthorn.gloamthorn.vault.recipe.json")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.gloamthorn.codex.output.vault-locked-silhouette")!,
    resource: ApplicationResource(name: "gloamthorn-vault-locked", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/vault/gloamthorn-vault-locked.png",
    role: ThemeResourceRoleID(rawValue: "vault.locked-silhouette")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "7f6a4cf0909cc5bd409c9d3a59d9f744bb13e29ea5dc900091163d013d5e34a2",
    byteCount: 26825,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.gloamthorn.gloamthorn.vault.recipe.json")!
),
GloamthornThemeResourceDefinition(
    id: ThemeResourceID(rawValue: "resource.vault.gloamthorn.codex.output.vault-selected")!,
    resource: ApplicationResource(name: "gloamthorn-vault-selected", fileExtension: "png", ownerModuleID: "com.runescribe.module.theme.gloamthorn"),
    relativePath: "Production/vault/gloamthorn-vault-selected.png",
    role: ThemeResourceRoleID(rawValue: "vault.selected")!,
    mediaType: .png,
    requirement: .required,
    sha256Hex: "6352141ea272dc4be13639c1a29ab4b5494292ab076037b96047e5a9894f2051",
    byteCount: 31468,
    maximumByteCount: 4194304,
    pixelWidth: 1024,
    pixelHeight: 1024,
    rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.gloamthorn.gloamthorn.vault.recipe.json")!
)
    ]

    static let localizationPayload = Data(#"{"locale":"en","strings":{}}"#.utf8)

    static let localizationDefinition = GloamthornThemeResourceDefinition(
        id: ThemeResourceID(rawValue: "resource.localization.gloamthorn.control")!,
        resource: ApplicationResource(
            name: "gloamthorn-localization-en",
            fileExtension: "json",
            ownerModuleID: "com.runescribe.module.theme.gloamthorn"
        ),
        relativePath: "embedded/gloamthorn-localization-en.json",
        role: ThemeResourceRoles.localizationStrings,
        mediaType: .json,
        requirement: .required,
        sha256Hex: sha256Hex(localizationPayload),
        byteCount: localizationPayload.count,
        maximumByteCount: 64 * 1_024,
        pixelWidth: nil,
        pixelHeight: nil,
        rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.gloamthorn.gloamthorn.background.recipe.json")!
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
              manifest.codexID == "codex.gloamthorn",
              manifest.moduleID == "com.runescribe.module.theme.gloamthorn",
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
