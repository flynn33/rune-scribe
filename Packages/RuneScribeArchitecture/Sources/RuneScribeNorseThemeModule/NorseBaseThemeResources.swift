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
        NorseV2ResourcePins.integrityManifestByteCount,
        NorseV2ResourcePins.integrityManifestSHA256,
        128 * 1_024
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
            resourceID: nil,
            mediaType: .json,
            readStage: .manifestRead,
            digestStage: .manifestIntegrity,
            using: runtimeIO
        )
        guard NorseProductionManifest.validate(manifestData) else {
            throw requiredFailure(
                stage: .manifestIntegrity,
                code: .invalidIntegrityManifest,
                expectedByteCount: NorseBaseBundledResourceCatalog
                    .integrityManifestDescriptor.expectedByteCount,
                expectedSHA256Hex: NorseBaseBundledResourceCatalog
                    .integrityManifestDescriptor.expectedSHA256Hex,
                mediaType: .json
            )
        }

        var payloads: [ThemeResourceID: Data] = [:]
        var physicalPayloads: [ApplicationResource: Data] = [:]
        for definition in NorseBaseThemeResourceCatalog.definitions {
            let data: Data
            if let cached = physicalPayloads[definition.resource] {
                data = cached
            } else {
                do {
                    data = try await read(
                        definition.bundledDescriptor,
                        resourceID: definition.id,
                        mediaType: definition.mediaType,
                        readStage: .resourceRead,
                        digestStage: .digest,
                        using: runtimeIO
                    )
                    try validateMediaMetadata(data, definition: definition)
                } catch is CancellationError {
                    throw CancellationError()
                } catch where definition.requirement == .optional {
                    continue
                }
                physicalPayloads[definition.resource] = data
            }
            payloads[definition.id] = data
        }

        try validateSemanticJSON(payloads)
        do {
            _ = try budgetReport(physicalPayloads: physicalPayloads)
        } catch NorseBaseThemeResourceError.resourceBudgetExceeded {
            throw requiredFailure(stage: .budget, code: .resourceBudgetExceeded)
        }

        let descriptor = NorseBaseThemeDescriptorFactory.discoveryDescriptor
        guard Set(payloads.keys).isSubset(of: Set(descriptor.resources.map(\.id))),
              NorseBaseThemeResourceCatalog.validates(payloads)
        else {
            throw requiredFailure(
                stage: .contributionPublication,
                code: .resourceSetMismatch
            )
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
        guard staticBytes <= 96 * 1_024 * 1_024 else {
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
        guard largest <= 8 * 1_024 * 1_024, total <= 112 * 1_024 * 1_024 else {
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
        resourceID: ThemeResourceID?,
        mediaType: ThemeResourceMediaType?,
        readStage: RequiredThemeResourceFailureStage,
        digestStage: RequiredThemeResourceFailureStage,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data: Data
        do {
            data = try await runtimeIO.readVerifiedApplicationResource(
                descriptor.resource,
                expectedSHA256: descriptor.expectedSHA256,
                maximumByteCount: descriptor.maximumByteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as RuntimeVerifiedApplicationResourceFailure {
            switch failure {
            case .resourceUnavailable:
                throw requiredFailure(
                    stage: readStage,
                    resourceID: resourceID,
                    code: .resourceUnavailable,
                    expectedByteCount: descriptor.expectedByteCount,
                    expectedSHA256Hex: descriptor.expectedSHA256Hex,
                    mediaType: mediaType
                )
            case .contentTooLarge:
                throw requiredFailure(
                    stage: readStage,
                    resourceID: resourceID,
                    code: .contentTooLarge,
                    expectedByteCount: descriptor.expectedByteCount,
                    expectedSHA256Hex: descriptor.expectedSHA256Hex,
                    mediaType: mediaType
                )
            case .integrityMismatch(let actualSHA256, let actualByteCount):
                if actualByteCount != descriptor.expectedByteCount {
                    throw requiredFailure(
                        stage: .byteCount,
                        resourceID: resourceID,
                        code: .byteCountMismatch,
                        expectedByteCount: descriptor.expectedByteCount,
                        actualByteCount: actualByteCount,
                        expectedSHA256Hex: descriptor.expectedSHA256Hex,
                        actualSHA256Hex: hexadecimal(actualSHA256),
                        mediaType: mediaType
                    )
                }
                throw requiredFailure(
                    stage: digestStage,
                    resourceID: resourceID,
                    code: .digestMismatch,
                    expectedByteCount: descriptor.expectedByteCount,
                    actualByteCount: actualByteCount,
                    expectedSHA256Hex: descriptor.expectedSHA256Hex,
                    actualSHA256Hex: hexadecimal(actualSHA256),
                    mediaType: mediaType
                )
            case .invalidMaximumByteCount:
                throw requiredFailure(
                    stage: readStage,
                    resourceID: resourceID,
                    code: .unexpectedFailure,
                    expectedByteCount: descriptor.expectedByteCount,
                    expectedSHA256Hex: descriptor.expectedSHA256Hex,
                    mediaType: mediaType
                )
            }
        } catch {
            throw requiredFailure(
                stage: readStage,
                resourceID: resourceID,
                code: .resourceUnavailable,
                expectedByteCount: descriptor.expectedByteCount,
                expectedSHA256Hex: descriptor.expectedSHA256Hex,
                mediaType: mediaType
            )
        }
        guard data.count == descriptor.expectedByteCount else {
            throw requiredFailure(
                stage: .byteCount,
                resourceID: resourceID,
                code: .byteCountMismatch,
                expectedByteCount: descriptor.expectedByteCount,
                actualByteCount: data.count,
                expectedSHA256Hex: descriptor.expectedSHA256Hex,
                actualSHA256Hex: sha256Hex(data),
                mediaType: mediaType
            )
        }
        return data
    }

    static func validateMediaMetadata(
        _ data: Data,
        definition: NorseBaseThemeResourceDefinition
    ) throws {
        guard let expectedWidth = definition.pixelWidth,
              let expectedHeight = definition.pixelHeight
        else { return }
        guard definition.mediaType == .png,
              let dimensions = pngDimensions(data),
              dimensions.width == expectedWidth,
              dimensions.height == expectedHeight
        else {
            throw requiredFailure(
                stage: .mediaMetadata,
                resourceID: definition.id,
                code: .mediaMetadataMismatch,
                expectedByteCount: definition.byteCount,
                actualByteCount: data.count,
                expectedSHA256Hex: definition.sha256Hex,
                actualSHA256Hex: sha256Hex(data),
                mediaType: definition.mediaType
            )
        }
    }

    private static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= 24,
              Array(data.prefix(signature.count)) == signature,
              String(decoding: data[12 ..< 16], as: UTF8.self) == "IHDR"
        else { return nil }
        func integer(at offset: Int) -> Int {
            data[offset ..< offset + 4].reduce(0) { value, byte in
                (value << 8) | Int(byte)
            }
        }
        return (integer(at: 16), integer(at: 20))
    }

    private static func validateSemanticJSON(_ payloads: [ThemeResourceID: Data]) throws {
        guard let mapping = payloads[NorseBaseThemeResourceIDs.scriptMapping],
              let mappingRoot = try? JSONSerialization.jsonObject(with: mapping) as? [String: Any],
              mappingRoot["schemaVersion"] as? String == "1.0",
              mappingRoot["scriptID"] as? String == "script.base-runes",
              let symbols = mappingRoot["glyphs"] as? [[String: Any]],
              symbols.count == ThemeCanonicalSymbolSet.symbolCount
        else {
            throw requiredFailure(
                stage: .semanticJSON,
                resourceID: NorseBaseThemeResourceIDs.scriptMapping,
                code: .invalidSemanticJSON,
                mediaType: .json
            )
        }

        guard let palette = payloads[NorseBaseThemeResourceIDs.palette],
              let paletteRoot = try? JSONSerialization.jsonObject(with: palette) as? [String: Any],
              paletteRoot["codexID"] as? String == "codex.norse",
              let tokens = paletteRoot["tokens"] as? [String: Any],
              tokens.count >= 13
        else {
            throw requiredFailure(
                stage: .semanticJSON,
                resourceID: NorseBaseThemeResourceIDs.palette,
                code: .invalidSemanticJSON,
                mediaType: .json
            )
        }

        guard let headings = payloads[NorseBaseThemeResourceIDs.headings],
              let headingRoot = try? JSONSerialization.jsonObject(with: headings) as? [String: Any],
              let slots = headingRoot["decorativeHeadingSlots"] as? [String: Any],
              slots.count == 13
        else {
            throw requiredFailure(
                stage: .semanticJSON,
                resourceID: NorseBaseThemeResourceIDs.headings,
                code: .invalidSemanticJSON,
                mediaType: .json
            )
        }

        guard let localization = payloads[NorseBaseThemeResourceIDs.localization],
              let localizationRoot = try? JSONSerialization.jsonObject(with: localization) as? [String: Any],
              localizationRoot["locale"] as? String == "en"
        else {
            throw requiredFailure(
                stage: .semanticJSON,
                resourceID: NorseBaseThemeResourceIDs.localization,
                code: .invalidSemanticJSON,
                mediaType: .json
            )
        }

        guard let bindings = payloads[NorseBaseThemeResourceIDs.progressionBindings],
              let bindingRoot = try? JSONSerialization.jsonObject(with: bindings) as? [String: Any],
              let grants = bindingRoot["grants"] as? [[String: Any]],
              Set(grants.compactMap { $0["contentID"] as? String }).isSuperset(of: NorseProgressionBindingCatalog.contentIDs),
              grants.allSatisfy({ ($0["trigger"] as? String)?.isEmpty == false })
        else {
            throw requiredFailure(
                stage: .semanticJSON,
                resourceID: NorseBaseThemeResourceIDs.progressionBindings,
                code: .invalidSemanticJSON,
                mediaType: .json
            )
        }

        for (artifactID, geometryID) in NorseBaseThemeResourceIDs.geometryResourceIDs {
            guard let geometry = payloads[geometryID] else {
                if NorseBaseThemeResourceCatalog.definitions.first(where: {
                    $0.id == geometryID
                })?.requirement == .optional {
                    continue
                }
                throw requiredFailure(
                    stage: .geometry,
                    resourceID: geometryID,
                    code: .invalidGeometry,
                    mediaType: .json
                )
            }
            guard let root = try? JSONSerialization.jsonObject(with: geometry) as? [String: Any],
                  root["artifactID"] as? String == artifactID.rawValue,
                  let area = root["normalizedInscriptionSafeArea"] as? [String: Any],
                  let x = area["x"] as? Double,
                  let y = area["y"] as? Double,
                  let width = area["width"] as? Double,
                  let height = area["height"] as? Double,
                  x >= 0, y >= 0, width > 0, height > 0,
                  x + width <= 1, y + height <= 1
            else {
                throw requiredFailure(
                    stage: .geometry,
                    resourceID: geometryID,
                    code: .invalidGeometry,
                    mediaType: .json
                )
            }
        }
    }

    private static func requiredFailure(
        stage: RequiredThemeResourceFailureStage,
        resourceID: ThemeResourceID? = nil,
        code: RequiredThemeResourceFailureCode,
        expectedByteCount: Int? = nil,
        actualByteCount: Int? = nil,
        expectedSHA256Hex: String? = nil,
        actualSHA256Hex: String? = nil,
        mediaType: ThemeResourceMediaType? = nil
    ) -> RequiredThemeResourceFailureDTO {
        RequiredThemeResourceFailureDTO(
            moduleID: RuneScribeModuleIDs.norseTheme,
            codexID: RuneScribeCodexIDs.norse,
            stage: stage,
            resourceID: resourceID,
            errorCode: code,
            expectedByteCount: expectedByteCount.flatMap(UInt64.init(exactly:)),
            actualByteCount: actualByteCount.flatMap(UInt64.init(exactly:)),
            expectedSHA256: expectedSHA256Hex.flatMap(ThemeSHA256Digest.init(rawValue:)),
            actualSHA256: actualSHA256Hex.flatMap(ThemeSHA256Digest.init(rawValue:)),
            mediaType: mediaType
        )
    }
}

enum NorseBaseThemeResourceIDs {
    static let font = id("resource.font.norse.noto-sans-runic")
    static let scriptMapping = id("resource.script.norse.mapping")
    static let scriptFallback = id("resource.script.norse.specimen.static-fallback")
    static let scriptSpecimenStandard = id("resource.script.norse.specimen.standard")
    static let scriptSpecimenHighContrast = id("resource.script.norse.specimen.high-contrast")
    static let palette = id("resource.palette.norse.semantic")
    static let headings = id("resource.headings.norse")
    static let localization = id("resource.localization.norse.en")
    static let progressionBindings = id("resource.progression-bindings.norse")
    static let backgroundStatic = id("resource.background.norse.cold-sea-hall.standard")
    static let backgroundReduceMotion = id("resource.background.norse.cold-sea-hall.reduce-motion")
    static let backgroundHighContrast = id("resource.background.norse.cold-sea-hall.high-contrast")
    static let backgroundMacOSWide = id("resource.background.norse.cold-sea-hall.macos-wide-crop")
    static let vaultCard = id("resource.codex-card.norse.owned")
    static let vaultLocked = id("resource.codex-card.norse.locked")
    static let vaultEncountered = id("resource.codex-card.norse.encountered")
    static let vaultSelected = id("resource.codex-card.norse.selected")
    static let vaultUnavailable = id("resource.codex-card.norse.unavailable")
    static let frameVector = id("resource.frame.norse.carved-knotwork.vector-master")
    static let frameStatic = id("resource.frame.norse.carved-knotwork.static-fallback")
    static let crestVector = id("resource.crest.norse.raven-mastery.vector-master")
    static let crestStatic = id("resource.crest.norse.raven-mastery.static-fallback")
    static let crestThumbnail = id("resource.crest.norse.raven-mastery.thumbnail")

    static let relicResourceIDs: [ArtifactID: RelicResourceIDs] = Dictionary(
        uniqueKeysWithValues: NorseProgressionBindingCatalog.relicIDs.map { artifact in
            let suffix = artifact.rawValue.replacingOccurrences(of: "relic.norse.", with: "")
            return (artifact, RelicResourceIDs(
                primary: id("resource.relic.norse.\(suffix).master"),
                thumbnail: id("resource.relic.norse.\(suffix).thumbnail"),
                staticFallback: id("resource.relic.norse.\(suffix).static-share-fallback"),
                highContrast: id("resource.relic.norse.\(suffix).high-contrast")
            ))
        }
    )

    static let sealResourceIDs: [ArtifactID: SealResourceIDs] = Dictionary(
        uniqueKeysWithValues: NorseProgressionBindingCatalog.sealIDs.map { artifact in
            let suffix = artifact.rawValue.replacingOccurrences(of: "seal.norse.", with: "")
            return (artifact, SealResourceIDs(
                vector: id("resource.seal.norse.\(suffix).vector-master"),
                monochrome: id("resource.seal.norse.\(suffix).monochrome-fallback"),
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
        "relic.norse.runestone-tablet", "relic.norse.dragonwood-plaque",
        "relic.norse.stormforged-stele",
    ].map { ArtifactID(rawValue: $0)! }
    static let sealIDs = [
        "seal.norse.valknut", "seal.norse.ravenshield", "seal.norse.mjolnir",
        "seal.norse.wolkin", "seal.norse.yggdrasil", "seal.norse.berserk",
    ].map { ArtifactID(rawValue: $0)! }
    static let contentIDs = Set(
        [
            "script.base-runes", "frame.norse.carved-knotwork",
            "crest.norse.raven-mastery", "title.norse.master-of-runes",
        ]
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
        let values = NorseProductionManifest.definitions
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
        let definedIDs = Set(definitions.map(\.id))
        guard Set(payloads.keys).isSubset(of: definedIDs) else { return false }
        return definitions.allSatisfy { definition in
            guard let data = payloads[definition.id] else {
                return definition.requirement == .optional
            }
            return data.count == definition.byteCount && sha256Hex(data) == definition.sha256Hex
        }
    }

}

enum NorseProductionManifest {
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

    static let definitions: [NorseBaseThemeResourceDefinition] = {
        guard let values = makeDefinitions(frozenResources),
              values.count == NorseV2ResourcePins.resourceCount
        else {
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
            requirement: resource.requiredForActiveContent ? .required : .optional,
            sha256Hex: resource.sha256,
            byteCount: resource.byteLength,
            pixelWidth: resource.dimensions?.width,
            pixelHeight: resource.dimensions?.height,
            rights: id == NorseBaseThemeResourceIDs.font ? .font : .presentation
        )
    }

    private static func semanticRole(for id: ThemeResourceID, fallback: String) -> ThemeResourceRoleID {
        if id == NorseBaseThemeResourceIDs.font { return ThemeResourceRoles.scriptFont }
        if id == NorseBaseThemeResourceIDs.scriptFallback { return ThemeResourceRoles.scriptStaticFallback }
        if id == NorseBaseThemeResourceIDs.scriptSpecimenStandard { return ThemeResourceRoles.scriptSpecimenStandard }
        if id == NorseBaseThemeResourceIDs.scriptSpecimenHighContrast { return ThemeResourceRoles.scriptSpecimenHighContrast }
        if NorseBaseThemeResourceIDs.relicResourceIDs.values.contains(where: { $0.primary == id }) { return ThemeResourceRoles.relicMaster }
        if NorseBaseThemeResourceIDs.relicResourceIDs.values.contains(where: { $0.thumbnail == id }) { return ThemeResourceRoles.relicThumbnail }
        if NorseBaseThemeResourceIDs.relicResourceIDs.values.contains(where: { $0.staticFallback == id }) { return ThemeResourceRoles.relicStaticShareFallback }
        if NorseBaseThemeResourceIDs.relicResourceIDs.values.contains(where: { $0.highContrast == id }) { return ThemeResourceRoles.relicHighContrast }
        if NorseBaseThemeResourceIDs.sealResourceIDs.values.contains(where: { $0.vector == id }) { return ThemeResourceRoles.sealVectorMaster }
        if NorseBaseThemeResourceIDs.sealResourceIDs.values.contains(where: { $0.monochrome == id }) { return ThemeResourceRoles.sealMonochromeFallback }
        if NorseBaseThemeResourceIDs.sealResourceIDs.values.contains(where: { $0.thumbnail == id }) { return ThemeResourceRoles.sealThumbnail }
        if id == NorseBaseThemeResourceIDs.frameVector { return ThemeResourceRoles.frameVectorMaster }
        if id == NorseBaseThemeResourceIDs.frameStatic { return ThemeResourceRoles.frameStaticFallback }
        if id == NorseBaseThemeResourceIDs.crestVector { return ThemeResourceRoles.crestVectorMaster }
        if id == NorseBaseThemeResourceIDs.crestStatic { return ThemeResourceRoles.crestStaticFallback }
        if id == NorseBaseThemeResourceIDs.crestThumbnail { return ThemeResourceRoles.crestThumbnail }
        if id == NorseBaseThemeResourceIDs.backgroundStatic { return ThemeResourceRoles.backgroundStaticBase }
        if id == NorseBaseThemeResourceIDs.backgroundReduceMotion { return ThemeResourceRoles.backgroundReduceMotion }
        if id == NorseBaseThemeResourceIDs.backgroundHighContrast { return ThemeResourceRoles.backgroundHighContrast }
        if id == NorseBaseThemeResourceIDs.backgroundMacOSWide { return ThemeResourceRoles.backgroundMacOSWideCrop }
        if id == NorseBaseThemeResourceIDs.vaultCard { return ThemeResourceRoles.vaultCard }
        if id == NorseBaseThemeResourceIDs.vaultLocked { return ThemeResourceRoles.vaultLockedSilhouette }
        if id == NorseBaseThemeResourceIDs.vaultEncountered { return ThemeResourceRoles.vaultEncountered }
        if id == NorseBaseThemeResourceIDs.vaultSelected { return ThemeResourceRoles.vaultSelected }
        if id == NorseBaseThemeResourceIDs.vaultUnavailable { return ThemeResourceRoles.vaultUnavailable }
        if id == NorseBaseThemeResourceIDs.localization { return ThemeResourceRoles.localizationStrings }
        return ThemeResourceRoleID(rawValue: fallback)!
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func hexadecimal(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
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
