import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum NorseBaseThemeResourceError: Error, Equatable, Sendable {
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case invalidIntegrityManifest
    case invalidScriptFallback
    case invalidVisualCatalog
    case invalidLocalizationCatalog
    case invalidProgressionBindings
    case invalidGeometry(String)
    case resourcePayloadSetMismatch
    case resourceBudgetExceeded(String)
}

public struct NorseBaseBundledResourceDescriptor: Equatable, Hashable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data { Data(hexadecimal: expectedSHA256Hex) }
}

public enum NorseBaseBundledResourceCatalog {
    public static let moduleManifest = NorseApplicationResourceCatalog.moduleManifest
    public static let integrityManifest = NorseApplicationResourceCatalog.integrityManifest
    public static let integrityManifestDescriptor = descriptor(
        integrityManifest,
        24_610,
        "8bfb935ca4d3b82bdee00ce0f21756811e0d34460c9002dfed4c56ce13f1eb0a",
        32 * 1_024
    )
    public static let notoSansRunic = NorseApplicationResourceCatalog.notoSansRunic
    public static let notoSansRunicDescriptor = descriptor(
        notoSansRunic,
        55_800,
        "615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b",
        8 * 1_024 * 1_024
    )

    public static var all: Set<ApplicationResource> {
        Set([moduleManifest, integrityManifest] + NorseBaseThemeResourceCatalog.definitions.map(\.resource))
    }

    private static func descriptor(
        _ resource: ApplicationResource,
        _ byteCount: Int,
        _ sha256: String,
        _ maximumByteCount: Int
    ) -> NorseBaseBundledResourceDescriptor {
        NorseBaseBundledResourceDescriptor(
            resource: resource,
            expectedByteCount: byteCount,
            expectedSHA256Hex: sha256,
            maximumByteCount: maximumByteCount
        )
    }
}

public struct ValidatedNorseBaseTheme: Sendable {
    public let descriptor: ThemeDescriptor
    public let resourcePayloads: [ThemeResourceID: Data]

    public init(descriptor: ThemeDescriptor, resourcePayloads: [ThemeResourceID: Data]) {
        self.descriptor = descriptor
        self.resourcePayloads = resourcePayloads
    }
}

public struct NorseBaseThemeResourceBudgetReport: Equatable, Sendable {
    public let uniquePhysicalBytes: Int
    public let staticImageBytes: Int
    public let fontBytes: Int
    public let animationBytes: Int
    public let soundBytes: Int
    public let largestResourceBytes: Int
}

public enum NorseBaseThemeResources {
    public static func loadValidated(using runtimeIO: RuntimeIOClient) async throws -> ValidatedNorseBaseTheme {
        let manifestData = try await read(
            NorseBaseBundledResourceCatalog.integrityManifestDescriptor,
            using: runtimeIO
        )
        guard NorseProductionManifest.validate(manifestData) else {
            throw NorseBaseThemeResourceError.invalidIntegrityManifest
        }

        var payloads: [ThemeResourceID: Data] = [:]
        var physicalPayloads: [ApplicationResource: Data] = [:]
        for definition in NorseBaseThemeResourceCatalog.definitions {
            let data: Data
            if let cached = physicalPayloads[definition.resource] {
                data = cached
            } else {
                data = try await read(definition.bundledDescriptor, using: runtimeIO)
                physicalPayloads[definition.resource] = data
            }
            payloads[definition.id] = data
        }

        try validateSemanticJSON(payloads)
        _ = try budgetReport(physicalPayloads: physicalPayloads)

        let descriptor = NorseBaseThemeDescriptorFactory.discoveryDescriptor
        guard Set(payloads.keys) == Set(descriptor.resources.map(\.id)),
              NorseBaseThemeResourceCatalog.validates(payloads)
        else {
            throw NorseBaseThemeResourceError.resourcePayloadSetMismatch
        }
        return ValidatedNorseBaseTheme(descriptor: descriptor, resourcePayloads: payloads)
    }

    public static func budgetReport(
        physicalPayloads: [ApplicationResource: Data]
    ) throws -> NorseBaseThemeResourceBudgetReport {
        let uniqueDefinitions = Dictionary(
            NorseBaseThemeResourceCatalog.definitions.map { ($0.resource, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let unique = physicalPayloads.compactMap { resource, data in
            uniqueDefinitions[resource].map { ($0, data.count) }
        }
        let staticBytes = unique.filter { [.png, .heif, .pdf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1 }
        let fontBytes = unique.filter { [.ttf, .otf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1 }
        let animationBytes = unique.filter { $0.0.role.rawValue == "unlock-animation-cue" }
            .reduce(0) { $0 + $1.1 }
        let soundBytes = unique.filter { [.wav, .caf, .m4a].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1 }
        let total = unique.reduce(0) { $0 + $1.1 }
        let largest = unique.map(\.1).max() ?? 0
        guard staticBytes <= 32 * 1_024 * 1_024 else {
            throw NorseBaseThemeResourceError.resourceBudgetExceeded("static-images")
        }
        guard fontBytes <= 16 * 1_024 * 1_024 else {
            throw NorseBaseThemeResourceError.resourceBudgetExceeded("fonts")
        }
        guard animationBytes <= 16 * 1_024 * 1_024 else {
            throw NorseBaseThemeResourceError.resourceBudgetExceeded("animations")
        }
        guard soundBytes <= 8 * 1_024 * 1_024 else {
            throw NorseBaseThemeResourceError.resourceBudgetExceeded("sounds")
        }
        guard largest <= 8 * 1_024 * 1_024, total <= 64 * 1_024 * 1_024 else {
            throw NorseBaseThemeResourceError.resourceBudgetExceeded("complete-theme")
        }
        return NorseBaseThemeResourceBudgetReport(
            uniquePhysicalBytes: total,
            staticImageBytes: staticBytes,
            fontBytes: fontBytes,
            animationBytes: animationBytes,
            soundBytes: soundBytes,
            largestResourceBytes: largest
        )
    }

    private static func read(
        _ descriptor: NorseBaseBundledResourceDescriptor,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data = try await runtimeIO.readVerifiedApplicationResource(
            descriptor.resource,
            expectedSHA256: descriptor.expectedSHA256,
            maximumByteCount: descriptor.maximumByteCount
        )
        guard data.count == descriptor.expectedByteCount else {
            throw NorseBaseThemeResourceError.resourceByteCountMismatch(
                resource: "\(descriptor.resource.name).\(descriptor.resource.fileExtension)",
                expected: descriptor.expectedByteCount,
                actual: data.count
            )
        }
        return data
    }

    private static func validateSemanticJSON(_ payloads: [ThemeResourceID: Data]) throws {
        guard let mapping = payloads[NorseBaseThemeResourceIDs.scriptMapping],
              let mappingRoot = try? JSONSerialization.jsonObject(with: mapping) as? [String: Any],
              mappingRoot["schemaVersion"] as? String == "1.0",
              mappingRoot["scriptID"] as? String == "script.base-runes",
              let symbols = mappingRoot["glyphs"] as? [[String: Any]],
              symbols.count == ThemeCanonicalSymbolSet.symbolCount
        else { throw NorseBaseThemeResourceError.invalidScriptFallback }

        guard let palette = payloads[NorseBaseThemeResourceIDs.palette],
              let paletteRoot = try? JSONSerialization.jsonObject(with: palette) as? [String: Any],
              paletteRoot["codexID"] as? String == "codex.norse",
              let tokens = paletteRoot["tokens"] as? [String: Any],
              tokens.count >= 13,
              let headings = payloads[NorseBaseThemeResourceIDs.headings],
              let headingRoot = try? JSONSerialization.jsonObject(with: headings) as? [String: Any],
              let slots = headingRoot["decorativeHeadingSlots"] as? [String: Any],
              slots.count == 13
        else { throw NorseBaseThemeResourceError.invalidVisualCatalog }

        guard let localization = payloads[NorseBaseThemeResourceIDs.localization],
              let localizationRoot = try? JSONSerialization.jsonObject(with: localization) as? [String: Any],
              localizationRoot["locale"] as? String == "en"
        else { throw NorseBaseThemeResourceError.invalidLocalizationCatalog }

        guard let bindings = payloads[NorseBaseThemeResourceIDs.progressionBindings],
              let bindingRoot = try? JSONSerialization.jsonObject(with: bindings) as? [String: Any],
              let grants = bindingRoot["grants"] as? [[String: Any]],
              Set(grants.compactMap { $0["contentID"] as? String }).isSuperset(of: NorseProgressionBindingCatalog.contentIDs),
              grants.allSatisfy({ ($0["trigger"] as? String)?.isEmpty == false })
        else { throw NorseBaseThemeResourceError.invalidProgressionBindings }

        for (artifactID, geometryID) in NorseBaseThemeResourceIDs.geometryResourceIDs {
            guard let geometry = payloads[geometryID],
                  let root = try? JSONSerialization.jsonObject(with: geometry) as? [String: Any],
                  root["artifactID"] as? String == artifactID.rawValue,
                  let area = root["normalizedInscriptionSafeArea"] as? [String: Any],
                  let x = area["x"] as? Double,
                  let y = area["y"] as? Double,
                  let width = area["width"] as? Double,
                  let height = area["height"] as? Double,
                  x >= 0, y >= 0, width > 0, height > 0,
                  x + width <= 1, y + height <= 1
            else { throw NorseBaseThemeResourceError.invalidGeometry(artifactID.rawValue) }
        }
    }
}

enum NorseBaseThemeResourceIDs {
    static let font = id("resource.font.norse.noto-sans-runic")
    static let scriptMapping = id("resource.script.norse.mapping")
    static let scriptFallback = id("resource.script.norse.specimen")
    static let palette = id("resource.palette.norse.semantic")
    static let headings = id("resource.headings.norse")
    static let localization = id("resource.localization.norse.en")
    static let progressionBindings = id("resource.progression-bindings.norse")
    static let backgroundStatic = id("resource.background.norse.forge.static")
    static let backgroundReduceMotion = backgroundStatic
    static let backgroundHighContrast = id("resource.background.norse.high-contrast")
    static let backgroundParameters = id("resource.background.norse.profile")
    static let vaultCard = id("resource.codex-card.norse")
    static let vaultLocked = id("resource.codex-silhouette.norse")
    static let vaultEncountered = vaultCard
    static let vaultSelected = vaultCard
    static let frameVector = id("resource.frame.norse.carved-knotwork.vector")
    static let frameStatic = id("resource.frame.norse.carved-knotwork.static-fallback")
    static let crestVector = id("resource.crest.norse.forge-master.vector")
    static let crestStatic = id("resource.crest.norse.forge-master.static-fallback")

    static let relicResourceIDs: [ArtifactID: RelicResourceIDs] = Dictionary(
        uniqueKeysWithValues: NorseProgressionBindingCatalog.relicIDs.map { artifact in
            let suffix = artifact.rawValue.replacingOccurrences(of: "relic.norse.", with: "")
            return (artifact, RelicResourceIDs(
                primary: id("resource.relic.norse.\(suffix).art"),
                thumbnail: id("resource.relic.norse.\(suffix).art"),
                staticFallback: id("resource.share-fallback.norse.\(suffix)"),
                highContrast: id("resource.share-fallback.norse.\(suffix)")
            ))
        }
    )

    static let sealResourceIDs: [ArtifactID: SealResourceIDs] = Dictionary(
        uniqueKeysWithValues: NorseProgressionBindingCatalog.sealIDs.map { artifact in
            let suffix = artifact.rawValue.replacingOccurrences(of: "seal.norse.", with: "")
            return (artifact, SealResourceIDs(
                vector: id("resource.seal.norse.\(suffix).vector"),
                monochrome: id("resource.seal.norse.\(suffix).thumbnail"),
                thumbnail: id("resource.seal.norse.\(suffix).thumbnail")
            ))
        }
    )

    static let geometryResourceIDs: [ArtifactID: ThemeResourceID] = Dictionary(
        uniqueKeysWithValues: NorseProgressionBindingCatalog.relicIDs.map { artifact in
            let suffix = artifact.rawValue.replacingOccurrences(of: "relic.norse.", with: "")
            return (artifact, id("resource.relic.norse.\(suffix).geometry"))
        }
    )

    fileprivate static func id(_ value: String) -> ThemeResourceID { ThemeResourceID(rawValue: value)! }
}

struct RelicResourceIDs: Sendable {
    let primary: ThemeResourceID
    let thumbnail: ThemeResourceID
    let staticFallback: ThemeResourceID
    let highContrast: ThemeResourceID
}

struct SealResourceIDs: Sendable {
    let vector: ThemeResourceID
    let monochrome: ThemeResourceID
    let thumbnail: ThemeResourceID
}

enum NorseProgressionBindingCatalog {
    static let relicIDs = [
        "relic.norse.runestone.weathered", "relic.norse.raven-medallion",
        "relic.norse.ironbound-shield", "relic.norse.sealed-parchment",
        "relic.norse.runestone.blackstone", "relic.norse.runestone.frozen",
    ].map { ArtifactID(rawValue: $0)! }
    static let sealIDs = [
        "seal.norse.knotwork", "seal.norse.forge-flame", "seal.norse.raven",
        "seal.norse.longship", "seal.norse.forge-hammer", "seal.norse.echo-rune",
    ].map { ArtifactID(rawValue: $0)! }
    static let contentIDs = Set(
        ["script.base-runes", "frame.norse.carved-knotwork", "crest.norse.forge-master"]
            + relicIDs.map(\.rawValue) + sealIDs.map(\.rawValue)
    )
}

struct NorseBaseThemeResourceDefinition: Equatable, Sendable {
    enum Rights: Equatable, Sendable { case font, presentation }
    let id: ThemeResourceID
    let resource: ApplicationResource
    let role: ThemeResourceRoleID
    let mediaType: ThemeResourceMediaType
    let requirement: ThemeResourceRequirement
    let sha256Hex: String
    let byteCount: Int
    let pixelWidth: Int?
    let pixelHeight: Int?
    let rights: Rights

    var bundledDescriptor: NorseBaseBundledResourceDescriptor {
        NorseBaseBundledResourceDescriptor(
            resource: resource,
            expectedByteCount: byteCount,
            expectedSHA256Hex: sha256Hex,
            maximumByteCount: max(byteCount, 1) + 1
        )
    }
}

enum NorseBaseThemeResourceCatalog {
    static let definitions: [NorseBaseThemeResourceDefinition] = {
        let values = NorseProductionManifest.definitions + supplementalDefinitions
        precondition(Set(values.map(\.id)).count == values.count, "Duplicate Norse resource handle")
        return values.sorted { $0.id.rawValue < $1.id.rawValue }
    }()

    static func references(fontRightsID: ThemeProvenanceID, presentationRightsID: ThemeProvenanceID) throws -> [ThemeResourceReference] {
        try definitions.map { definition in
            let pixelSize: ThemePixelSize?
            if let width = definition.pixelWidth, let height = definition.pixelHeight {
                pixelSize = try ThemePixelSize(width: UInt32(width), height: UInt32(height))
            } else { pixelSize = nil }
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
                rightsID: definition.rights == .font ? fontRightsID : presentationRightsID
            )
        }
    }

    static func validates(_ payloads: [ThemeResourceID: Data]) -> Bool {
        Set(payloads.keys) == Set(definitions.map(\.id)) && definitions.allSatisfy { definition in
            guard let data = payloads[definition.id] else { return false }
            return data.count == definition.byteCount && sha256Hex(data) == definition.sha256Hex
        }
    }

    private static let supplementalDefinitions: [NorseBaseThemeResourceDefinition] = {
        var result: [NorseBaseThemeResourceDefinition] = []
        let sealPNGs: [(String, Int, String)] = [
            ("echo-rune", 159_691, "f98d9f2de501b78586363c3abe0b4949142bdd46523bc2e7c6a4e5d95da6aa36"),
            ("forge-flame", 145_780, "431f95199fd660c29d73d381236b7570bd70da380bf9cdbbd5ffefdfb89d9d2d"),
            ("forge-hammer", 154_174, "5734f5802b5af981ea8691fb720e1e258f32eaf5e7cd38eb447c86fd0f98b126"),
            ("knotwork", 163_306, "b08af25f444603ef8ae702d0317db5eb8dc072e518fb5a0d3ab296166e0091b6"),
            ("longship", 155_920, "0dd5edbb301588219bbc4d12a07d24e558f47db794ee5e9150f650be1b0e769f"),
            ("raven", 152_556, "8ffb0a2bd84838e6142e16130dff93277929cc442629edda2af7570537789448"),
        ]
        for (name, bytes, hash) in sealPNGs {
            let thumbnailID = NorseBaseThemeResourceIDs.id("resource.seal.norse.\(name).thumbnail")
            let physical = definition(thumbnailID, ThemeResourceRoles.sealThumbnail, .png, bytes, hash, 1_024, 1_024)
            result.append(physical)
        }
        result.append(definition(NorseBaseThemeResourceIDs.frameStatic, ThemeResourceRoles.frameStaticFallback, .png, 120_537, "632dc82de68d83a8ecec315d7ca7bbda54bbf242b3d5afed3691af0af0d4d36a", 1_600, 1_200))
        result.append(definition(NorseBaseThemeResourceIDs.crestStatic, ThemeResourceRoles.crestStaticFallback, .png, 123_379, "50a2620294a19c3fa6be7129e1d4973c90ee7abea3fe71ce5640f60ca4a6635f", 1_024, 1_024))
        return result
    }()

    private static func definition(_ id: ThemeResourceID, _ role: ThemeResourceRoleID, _ media: ThemeResourceMediaType, _ bytes: Int, _ hash: String, _ width: Int? = nil, _ height: Int? = nil) -> NorseBaseThemeResourceDefinition {
        guard let resource = NorseApplicationResourceCatalog.resourcesByHandle[id.rawValue] else {
            preconditionFailure("Missing canonical Norse application resource for \(id.rawValue)")
        }
        return NorseBaseThemeResourceDefinition(id: id, resource: resource, role: role, mediaType: media, requirement: .required, sha256Hex: hash, byteCount: bytes, pixelWidth: width, pixelHeight: height, rights: .presentation)
    }
}

private enum NorseProductionManifest {
    struct Manifest: Decodable { let resources: [Resource] }
    struct Resource: Decodable {
        struct Dimensions: Decodable { let width: Int; let height: Int }
        let resourceHandle: String
        let semanticRole: String
        let mediaType: String
        let byteLength: Int
        let sha256: String
        let requiredForActiveContent: Bool
        let dimensions: Dimensions?
    }

    private static let frozenResources: [Resource] = [
        seed("resource.relic.norse.runestone.weathered.art", "relic-art", "image/png", 2_100_882, "9c235fd40b841e16d35be138cf1f46a5061dd8eee79208e8982208b46d647da9", true, 1_600, 1_200),
        seed("resource.relic.norse.runestone.weathered.geometry", "relic-geometry", "application/json", 714, "c2ac57230859c86055a58d8c46cda281bc96dc8166954f47b6bdd9276e0fb9e1", true),
        seed("resource.share-fallback.norse.runestone.weathered", "static-share-fallback", "image/png", 2_444_821, "5d732b386160b227ec933a4e070ae85227f13b7dccf0dc2a22f47809c08d4c1b", true, 1_600, 1_200),
        seed("resource.relic.norse.raven-medallion.art", "relic-art", "image/png", 1_602_486, "460bb7db51c8734b4e6a0807fbe1e76303209a791ef8b5e4b4c5c687338628e7", true, 1_200, 1_200),
        seed("resource.relic.norse.raven-medallion.geometry", "relic-geometry", "application/json", 578, "ea0037cc3fc2761134e1f1bd2b8e3d0bfc077e1e7ac37910921ba07d5336f36b", true),
        seed("resource.share-fallback.norse.raven-medallion", "static-share-fallback", "image/png", 2_498_330, "22f0891d8bff407e5b497e1edba3936076e8779e5007d5366bcb7bee13ebf84d", true, 1_600, 1_200),
        seed("resource.relic.norse.ironbound-shield.art", "relic-art", "image/png", 1_664_406, "f10b581420cfd660a3439dbe8ad9c54d0b3c85eeb9c5162ca3f59a48124bf566", true, 1_200, 1_200),
        seed("resource.relic.norse.ironbound-shield.geometry", "relic-geometry", "application/json", 684, "b4877308e848f256f3b76e46eed115f215c0166446a0895292418a53759f0f5c", true),
        seed("resource.share-fallback.norse.ironbound-shield", "static-share-fallback", "image/png", 2_557_201, "14388717a88b3a0a980bb27a16fb030605c071997cd821ee71a450f0c8038dfa", true, 1_600, 1_200),
        seed("resource.relic.norse.sealed-parchment.art", "relic-art", "image/png", 1_772_507, "f15b28ab19e84e1164cf1f3b605d931ab49ccd88b40e3b759226a15e4531ac00", true, 1_600, 1_200),
        seed("resource.relic.norse.sealed-parchment.geometry", "relic-geometry", "application/json", 697, "8d08b882893002da5afd9f8e06e7a0f3f81a109f72584cbc3ea2c3add37cfae6", true),
        seed("resource.share-fallback.norse.sealed-parchment", "static-share-fallback", "image/png", 2_353_385, "f734c1f40d4e5499d2732c4050827841ac888da2f88959b4db27ddd600479569", true, 1_600, 1_200),
        seed("resource.relic.norse.runestone.blackstone.art", "relic-art", "image/png", 2_285_375, "9f161594f50105824675a6c13f808ed4f0f3ca490fd62e05e9b56d81e24c018f", true, 1_600, 1_200),
        seed("resource.relic.norse.runestone.blackstone.geometry", "relic-geometry", "application/json", 713, "0c3b1345f13650fb1a961b20ed5af381a57d10624eae2c850cfd08e9220c0aab", true),
        seed("resource.share-fallback.norse.runestone.blackstone", "static-share-fallback", "image/png", 2_568_492, "e65e90b71d9cd5a0e3c97f38b450f8341b372c80403bb8d523c813b7930cec08", true, 1_600, 1_200),
        seed("resource.relic.norse.runestone.frozen.art", "relic-art", "image/png", 2_249_646, "1540532b89c6c0f4f3f0c18727803a02d6f97dd22d7906dba6882ebdee963995", false, 1_600, 1_200),
        seed("resource.relic.norse.runestone.frozen.geometry", "relic-geometry", "application/json", 705, "6e48ec956828f06166b4629e38e0707eb74ee7c657c874b3afe2f43b4bfb908c", false),
        seed("resource.share-fallback.norse.runestone.frozen", "static-share-fallback", "image/png", 2_503_093, "fe9c9963d5d0a7264b43c058d2e1926cb5e2ebe75ecdd737a9231e4c0c51a417", false, 1_600, 1_200),
        seed("resource.seal.norse.knotwork.vector", "seal-vector", "application/pdf", 3_057, "90a0241c4d22b189bb4e5d31ee34de5c6bcdb5ae6bb07ae0a70c649179a37722", true),
        seed("resource.seal.norse.forge-flame.vector", "seal-vector", "application/pdf", 3_017, "4e7236d8848448e190bc0891f3b2256c6b7a9145a310288f229f5c1fde51371b", true),
        seed("resource.seal.norse.raven.vector", "seal-vector", "application/pdf", 3_110, "7205f8ead9ad3aa80300ea5e092c8c445bbfcdb0993a533d48935da12f145836", true),
        seed("resource.seal.norse.longship.vector", "seal-vector", "application/pdf", 3_145, "1eb0f40d4171befeac3a6d3cfa67efc726a0d5da2289f7efc93c164db2f5fc2c", true),
        seed("resource.seal.norse.forge-hammer.vector", "seal-vector", "application/pdf", 3_190, "8e0e1facae3f15895223655a7ec2921bed11fbf310d008a1934a98cf1ba0f481", true),
        seed("resource.seal.norse.echo-rune.vector", "seal-vector", "application/pdf", 3_046, "d9c0ce6b4a1e461ef6b7082cbd00aeebc683340bdea4a41a6cb5d4a4899d4c18", true),
        seed("resource.frame.norse.carved-knotwork.vector", "frame-vector", "application/pdf", 4_385, "7b293065bfada998c44a2e84a1b0346d2e8d2f961a54333562e5924c40c9e2e4", true),
        seed("resource.crest.norse.forge-master.vector", "crest-vector", "application/pdf", 2_963, "17f399835e761534fa911cd44dd5be1a73142f1d895d1681f75c5da2e7fe34b7", true),
        seed("resource.codex-card.norse", "codex-card", "image/png", 998_363, "79a1d46b20fe5958c33dd387ffb854d00147c3f47769116ec0ee6a409a521fd0", true, 1_200, 1_600),
        seed("resource.codex-silhouette.norse", "codex-silhouette", "image/png", 663_322, "821251ccb12aaaba43dd853e99f1090b041755e5ae16c37b472efb00daa92261", true, 1_200, 1_600),
        seed("resource.background.norse.forge.static", "reduce-motion-background", "image/png", 480_562, "2280566de99926bd1c078d9f26cf437c5cde1fa72c274834825c133b5b4f3b31", true, 2_048, 2_048),
        seed("resource.background.norse.high-contrast", "high-contrast-background", "image/png", 419_519, "a9a59d3e1587561c9059628a2abf2a1bb871a0428f7838e67e5e31edbc0d01d2", true, 1_920, 1_920),
        seed("resource.background.norse.profile", "background-parameter-record", "application/json", 1_678, "136e1285f0188665ea6a05578fd010138a9da9e629fd1ae26e796ac85087e1be", true),
        seed("resource.palette.norse.semantic", "semantic-palette", "application/json", 2_556, "33403c431735ae92c81816667e3c4040f16da3ff1b0846533a539d024a48652c", true),
        seed("resource.headings.norse", "decorative-heading-catalog", "application/json", 779, "190a7682b2e4b40251aca028841223e4624b87448534fb3c1fc2a855d586d1e4", true),
        seed("resource.script.norse.mapping", "script-mapping", "application/json", 4_552, "c66c76259ac7c8e4ac9ad0c42417f49ad4546d6901e339612dec6ef243627264", true),
        seed("resource.script.norse.specimen", "script-specimen", "image/png", 91_927, "ddace76f9dc0bbb11cdc485a71ed1f22b5e4788d8d5429e1902f1ded623d5627", false, 1_600, 960),
        seed("resource.accessibility.norse.en", "accessibility-localization", "application/json", 2_972, "376354f0c3fcf408b4bfdde894f1e38689ad83dd84d451d0202956af79d1c257", true),
        seed("resource.localization.norse.en", "content-localization", "application/json", 9_043, "58afc0693e8a35808c0776c6cd25069432cbd9b7227bd080ff0fa2bf4fe4a868", true),
        seed("resource.progression-bindings.norse", "progression-binding-catalog", "application/json", 4_826, "eeaaa67d71f3e8f3466fdd2a76b56f8ff673fa50325c7e17225223412f795bca", true),
        seed("resource.sound.norse.unlock-minor", "unlock-sound-candidate", "audio/wav", 157_484, "86ff6f83532792c120885c4177fbf4577aea4d9c93ce1a00ae92ef675d663231", true),
        seed("resource.effect.norse.reveal-minor", "unlock-animation-cue", "application/json", 638, "7886f75c160e25dfca5afa836b5ba0a87bf0669eee7da7f40ab441c855f11eb5", true),
        seed("resource.sound.norse.unlock-relic", "unlock-sound-candidate", "audio/wav", 245_804, "fd03dc2727db17991724175ad4de0e8441ceb635157869147e3ec4c4246d17d0", true),
        seed("resource.effect.norse.reveal-relic", "unlock-animation-cue", "application/json", 797, "1f72a5bdd443ea8edb38604c90d7de8c5b6cefa18f486b7ddee918996a22cb0f", true),
        seed("resource.sound.norse.unlock-codex", "unlock-sound-candidate", "audio/wav", 422_444, "92002d43b73dfbb6240ab8c3166b5044f9ebec9dc919925934774875caaa92f8", true),
        seed("resource.effect.norse.reveal-codex", "unlock-animation-cue", "application/json", 960, "7bb5b550ad37ea2cebf7619d78c165a62101b4e9a7b0d1dcee78801768161b4d", true),
        seed("resource.sound.norse.unlock-mastery", "unlock-sound-candidate", "audio/wav", 508_844, "a5e4be793829f6abc73727f6441894d79d0e93b548f754dc35005aac529f2682", true),
        seed("resource.effect.norse.reveal-mastery", "unlock-animation-cue", "application/json", 882, "8abd4c76f20243d2da901a4a87ba5a691efadadc669a75da23b1e53f8f59364f", true),
        seed("resource.font.norse.noto-sans-runic", "required-base-script-font", "font/ttf", 55_800, "615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b", true),
    ]

    static let definitions: [NorseBaseThemeResourceDefinition] = {
        guard let values = makeDefinitions(frozenResources), values.count == 47 else {
            preconditionFailure("Invalid frozen Norse resource catalog")
        }
        return values
    }()
    static let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })

    static func definition(_ id: ThemeResourceID) -> NorseBaseThemeResourceDefinition? { byID[id] }

    static func validate(_ data: Data) -> Bool {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let decodedDefinitions = makeDefinitions(manifest.resources)
        else { return false }
        return decodedDefinitions == definitions
    }

    private static func makeDefinitions(
        _ resources: [Resource]
    ) -> [NorseBaseThemeResourceDefinition]? {
        var values: [NorseBaseThemeResourceDefinition] = []
        values.reserveCapacity(resources.count)
        for resource in resources {
            guard let value = makeDefinition(resource) else { return nil }
            values.append(value)
        }
        guard Set(values.map(\.id)).count == values.count else { return nil }
        return values
    }

    private static func makeDefinition(
        _ resource: Resource
    ) -> NorseBaseThemeResourceDefinition? {
        guard let id = ThemeResourceID(rawValue: resource.resourceHandle),
              let applicationResource = NorseApplicationResourceCatalog.resourcesByHandle[resource.resourceHandle],
              let media = ThemeResourceMediaType(rawValue: resource.mediaType)
        else { return nil }
        return NorseBaseThemeResourceDefinition(
            id: id,
            resource: applicationResource,
            role: semanticRole(for: id, fallback: resource.semanticRole),
            mediaType: media,
            requirement: requiredResourceIDs.contains(id) || resource.requiredForActiveContent ? .required : .optional,
            sha256Hex: resource.sha256,
            byteCount: resource.byteLength,
            pixelWidth: resource.dimensions?.width,
            pixelHeight: resource.dimensions?.height,
            rights: id == NorseBaseThemeResourceIDs.font ? .font : .presentation
        )
    }

    private static func seed(
        _ resourceHandle: String,
        _ semanticRole: String,
        _ mediaType: String,
        _ byteLength: Int,
        _ sha256: String,
        _ requiredForActiveContent: Bool,
        _ width: Int? = nil,
        _ height: Int? = nil
    ) -> Resource {
        Resource(
            resourceHandle: resourceHandle,
            semanticRole: semanticRole,
            mediaType: mediaType,
            byteLength: byteLength,
            sha256: sha256,
            requiredForActiveContent: requiredForActiveContent,
            dimensions: width.flatMap { width in
                height.map { Resource.Dimensions(width: width, height: $0) }
            }
        )
    }

    private static func semanticRole(for id: ThemeResourceID, fallback: String) -> ThemeResourceRoleID {
        if id == NorseBaseThemeResourceIDs.font { return ThemeResourceRoles.scriptFont }
        if id == NorseBaseThemeResourceIDs.scriptFallback { return ThemeResourceRoles.scriptStaticFallback }
        if NorseBaseThemeResourceIDs.relicResourceIDs.values.contains(where: { $0.primary == id }) { return ThemeResourceRoles.relicMaster }
        if NorseBaseThemeResourceIDs.relicResourceIDs.values.contains(where: { $0.staticFallback == id }) { return ThemeResourceRoles.relicStaticShareFallback }
        if NorseBaseThemeResourceIDs.sealResourceIDs.values.contains(where: { $0.vector == id }) { return ThemeResourceRoles.sealVectorMaster }
        if id == NorseBaseThemeResourceIDs.frameVector { return ThemeResourceRoles.frameVectorMaster }
        if id == NorseBaseThemeResourceIDs.crestVector { return ThemeResourceRoles.crestVectorMaster }
        if id == NorseBaseThemeResourceIDs.backgroundStatic { return ThemeResourceRoles.backgroundStaticBase }
        if id == NorseBaseThemeResourceIDs.backgroundHighContrast { return ThemeResourceRoles.backgroundHighContrast }
        if id == NorseBaseThemeResourceIDs.backgroundParameters { return ThemeResourceRoles.backgroundRendererParameters }
        if id == NorseBaseThemeResourceIDs.vaultCard { return ThemeResourceRoles.vaultCard }
        if id == NorseBaseThemeResourceIDs.vaultLocked { return ThemeResourceRoles.vaultLockedSilhouette }
        if id == NorseBaseThemeResourceIDs.localization { return ThemeResourceRoles.localizationStrings }
        return ThemeResourceRoleID(rawValue: fallback)!
    }

    private static let requiredResourceIDs: Set<ThemeResourceID> = {
        var ids: Set<ThemeResourceID> = [
            NorseBaseThemeResourceIDs.font, NorseBaseThemeResourceIDs.scriptFallback,
            NorseBaseThemeResourceIDs.backgroundStatic,
            NorseBaseThemeResourceIDs.backgroundHighContrast, NorseBaseThemeResourceIDs.backgroundParameters,
            NorseBaseThemeResourceIDs.vaultCard, NorseBaseThemeResourceIDs.vaultLocked,
            NorseBaseThemeResourceIDs.localization,
        ]
        ids.formUnion(NorseBaseThemeResourceIDs.relicResourceIDs.values.flatMap { [$0.primary, $0.staticFallback] })
        ids.formUnion(NorseBaseThemeResourceIDs.sealResourceIDs.values.map(\.vector))
        ids.insert(NorseBaseThemeResourceIDs.frameVector)
        ids.insert(NorseBaseThemeResourceIDs.crestVector)
        return ids
    }()
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
