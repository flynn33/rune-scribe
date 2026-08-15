import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum NorseBaseThemeResourceError: Error, Equatable, Sendable {
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case invalidScriptFallback
    case invalidVisualCatalog
    case invalidLocalizationCatalog
    case invalidPlaceholderCatalog
    case placeholderAssetMismatch(String)
    case resourcePayloadSetMismatch
}

public struct NorseBaseBundledResourceDescriptor: Equatable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data { Data(hexadecimal: expectedSHA256Hex) }
}

public enum NorseBaseBundledResourceCatalog {
    private static let owner = RuneScribeModuleIDs.norseTheme

    public static let moduleManifest = resource("module-manifest", "json")
    public static let scriptFallback = resource("NorseBaseScriptFallback-v1.0", "json")
    public static let visualResources = resource("NorseBaseVisualResources-v1.0", "json")
    public static let localizations = resource("NorseBaseLocalizations-en-US-v1.0", "json")
    public static let notoSansRunic = resource("NotoSansRunic-Regular", "ttf")
    public static let placeholderAssets = resource("NorseBasePlaceholderAssets-v1.0", "json")

    public static let scriptFallbackDescriptor = descriptor(
        scriptFallback,
        3_012,
        "b4c6b17c75a29faeed7c51f9c34d975b4c8b10c0522f7c3212b8471e53fd2cac",
        8 * 1_024
    )
    public static let visualResourcesDescriptor = descriptor(
        visualResources,
        3_385,
        "ede2823478bf8afa7838fe3b6e6965d9e76e6eefd2b745e45431abc68aa0fc38",
        8 * 1_024
    )
    public static let localizationsDescriptor = descriptor(
        localizations,
        3_799,
        "5151ffb31d7d3622b067422e959d2054ff095ef35f92ca25b1bf4bfcb1de2949",
        8 * 1_024
    )
    public static let notoSansRunicDescriptor = descriptor(
        notoSansRunic,
        55_800,
        "615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b",
        8 * 1_024 * 1_024
    )
    public static let placeholderAssetsDescriptor = descriptor(
        placeholderAssets,
        1_019_985,
        "3a488cfbec99d79f8e776e52e57504c049312d865ba85a336068a2641e8b07d2",
        2 * 1_024 * 1_024
    )

    public static var all: Set<ApplicationResource> {
        [moduleManifest, scriptFallback, visualResources, localizations, notoSansRunic, placeholderAssets]
    }

    private static func resource(_ name: String, _ fileExtension: String) -> ApplicationResource {
        ApplicationResource(name: name, fileExtension: fileExtension, ownerModuleID: owner)
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

public enum NorseBaseThemeResources {
    public static func loadValidated(
        using runtimeIO: RuntimeIOClient
    ) async throws -> ValidatedNorseBaseTheme {
        let scriptMapping = try await read(
            NorseBaseBundledResourceCatalog.scriptFallbackDescriptor,
            using: runtimeIO
        )
        let backgroundParameters = try await read(
            NorseBaseBundledResourceCatalog.visualResourcesDescriptor,
            using: runtimeIO
        )
        let localizations = try await read(
            NorseBaseBundledResourceCatalog.localizationsDescriptor,
            using: runtimeIO
        )
        let font = try await read(
            NorseBaseBundledResourceCatalog.notoSansRunicDescriptor,
            using: runtimeIO
        )
        let placeholderCatalog = try await read(
            NorseBaseBundledResourceCatalog.placeholderAssetsDescriptor,
            using: runtimeIO
        )

        try validateScriptFallback(scriptMapping)
        try validateVisualCatalog(backgroundParameters)
        try validateLocalizationCatalog(localizations)
        let assets = try validatedPlaceholderAssets(placeholderCatalog)

        var payloads: [ThemeResourceID: Data] = [
            NorseBaseThemeResourceIDs.font: font,
            NorseBaseThemeResourceIDs.scriptMapping: scriptMapping,
            NorseBaseThemeResourceIDs.backgroundParameters: backgroundParameters,
            NorseBaseThemeResourceIDs.localization: localizations,
        ]
        for definition in NorseBaseThemeResourceCatalog.definitions {
            guard let assetID = definition.placeholderAssetID else { continue }
            guard let data = assets[assetID] else {
                throw NorseBaseThemeResourceError.placeholderAssetMismatch(assetID)
            }
            payloads[definition.id] = data
        }

        let descriptor = NorseBaseThemeDescriptorFactory.discoveryDescriptor
        guard Set(payloads.keys) == Set(descriptor.resources.map(\.id)),
              NorseBaseThemeResourceCatalog.validates(payloads)
        else {
            throw NorseBaseThemeResourceError.resourcePayloadSetMismatch
        }
        return ValidatedNorseBaseTheme(descriptor: descriptor, resourcePayloads: payloads)
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

    private static func validateScriptFallback(_ data: Data) throws {
        struct ScriptFallback: Decodable {
            struct FontReference: Decodable {
                let id: String
                let version: Int
                let postScriptName: String
            }
            struct Glyph: Decodable {
                let canonicalValue: Int
                let glyphID: String
                let textToken: String
            }
            let schemaVersion: String
            let scriptID: String
            let fontReference: FontReference
            let portability: String
            let glyphs: [Glyph]
        }

        let expectedGlyphIDs = (0 ..< ThemeCanonicalSymbolSet.symbolCount).map {
            String(format: "glyph.base-runes.%02d", $0)
        }
        guard let value = try? JSONDecoder().decode(ScriptFallback.self, from: data),
              value.schemaVersion == "1.0",
              value.scriptID == "script.base-runes",
              value.fontReference.id == "noto-sans-runic",
              value.fontReference.version == 1,
              value.fontReference.postScriptName == "NotoSansRunic-Regular",
              value.portability == "unicode-portable",
              value.glyphs.count == ThemeCanonicalSymbolSet.symbolCount,
              value.glyphs.map(\.canonicalValue) == Array(0 ..< ThemeCanonicalSymbolSet.symbolCount),
              value.glyphs.map(\.glyphID) == expectedGlyphIDs,
              value.glyphs.map(\.textToken) == ThemeCanonicalSymbolSet.transportTokens
        else {
            throw NorseBaseThemeResourceError.invalidScriptFallback
        }
    }

    private static func validateVisualCatalog(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              root["schemaVersion"] as? String == "1.0",
              root["purpose"] as? String == "norse-base-conformance-presentation",
              let palette = root["semanticPalette"] as? [String: Any],
              palette["backgroundPrimary"] as? String == "#080A1E",
              palette["accentPrimary"] as? String == "#D4971A",
              let parameters = root["rendererParameters"] as? [String: Any],
              parameters["rendererID"] as? String == "fragment-rune-background",
              let relics = root["relics"] as? [[String: Any]], relics.count == 3,
              let seals = root["seals"] as? [[String: Any]], seals.count == 6
        else { throw NorseBaseThemeResourceError.invalidVisualCatalog }
    }

    private static func validateLocalizationCatalog(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              root["schemaVersion"] as? String == "1.0",
              root["locale"] as? String == "en-US",
              let strings = root["strings"] as? [String: Any], !strings.isEmpty
        else { throw NorseBaseThemeResourceError.invalidLocalizationCatalog }
    }

    private static func validatedPlaceholderAssets(_ data: Data) throws -> [String: Data] {
        struct PlaceholderCatalog: Decodable {
            struct Asset: Decodable {
                struct PixelSize: Decodable {
                    let width: Int
                    let height: Int
                }
                let id: String
                let mediaType: String
                let byteLength: Int
                let sha256: String
                let pixelSize: PixelSize?
                let data: Data
            }
            let schemaVersion: String
            let generator: String
            let assets: [Asset]
        }

        guard let catalog = try? JSONDecoder().decode(PlaceholderCatalog.self, from: data),
              catalog.schemaVersion == "1.0",
              catalog.generator == "make_norse_base_placeholders.swift",
              catalog.assets.count == NorseBasePlaceholderAssetCatalog.definitions.count
        else { throw NorseBaseThemeResourceError.invalidPlaceholderCatalog }

        var result: [String: Data] = [:]
        for asset in catalog.assets {
            guard result[asset.id] == nil,
                  let expected = NorseBasePlaceholderAssetCatalog.byID[asset.id],
                  asset.mediaType == expected.mediaType.rawValue,
                  asset.byteLength == expected.byteCount,
                  asset.data.count == expected.byteCount,
                  asset.sha256 == expected.sha256Hex,
                  sha256Hex(asset.data) == expected.sha256Hex,
                  asset.pixelSize?.width == expected.pixelWidth,
                  asset.pixelSize?.height == expected.pixelHeight
            else { throw NorseBaseThemeResourceError.placeholderAssetMismatch(asset.id) }
            result[asset.id] = asset.data
        }
        guard Set(result.keys) == Set(NorseBasePlaceholderAssetCatalog.byID.keys) else {
            throw NorseBaseThemeResourceError.invalidPlaceholderCatalog
        }
        return result
    }
}

enum NorseBaseThemeResourceIDs {
    static let font = id("resource.norse.font.noto-sans-runic")
    static let scriptMapping = id("resource.norse.script.base-runes.mapping")
    static let scriptFallback = id("resource.norse.script.base-runes.static")
    static let localization = id("resource.norse.localization.en-us")
    static let backgroundStatic = id("resource.norse.background.static")
    static let backgroundReduceMotion = id("resource.norse.background.reduce-motion")
    static let backgroundHighContrast = id("resource.norse.background.high-contrast")
    static let backgroundParameters = id("resource.norse.background.parameters")
    static let vaultCard = id("resource.norse.vault.card")
    static let vaultLocked = id("resource.norse.vault.locked")
    static let vaultEncountered = id("resource.norse.vault.encountered")
    static let vaultSelected = id("resource.norse.vault.selected")

    static let relicResourceIDs: [ArtifactID: RelicResourceIDs] = [
        artifactID("relic.norse.runestone.weathered"): RelicResourceIDs(
            primary: id("resource.norse.relic.weathered.primary"),
            thumbnail: id("resource.norse.relic.weathered.thumbnail"),
            staticFallback: id("resource.norse.relic.weathered.static"),
            highContrast: id("resource.norse.relic.weathered.high-contrast")
        ),
        artifactID("relic.norse.raven-medallion"): RelicResourceIDs(
            primary: id("resource.norse.relic.raven-medallion.primary"),
            thumbnail: id("resource.norse.relic.raven-medallion.thumbnail"),
            staticFallback: id("resource.norse.relic.raven-medallion.static"),
            highContrast: id("resource.norse.relic.raven-medallion.high-contrast")
        ),
        artifactID("relic.norse.sealed-parchment"): RelicResourceIDs(
            primary: id("resource.norse.relic.sealed-parchment.primary"),
            thumbnail: id("resource.norse.relic.sealed-parchment.thumbnail"),
            staticFallback: id("resource.norse.relic.sealed-parchment.static"),
            highContrast: id("resource.norse.relic.sealed-parchment.high-contrast")
        ),
    ]

    static let sealResourceIDs: [ArtifactID: SealResourceIDs] = [
        artifactID("seal.norse.knotwork"): sealResources("knotwork"),
        artifactID("seal.norse.forge-flame"): sealResources("forge-flame"),
        artifactID("seal.norse.raven"): sealResources("raven"),
        artifactID("seal.norse.longship"): sealResources("longship"),
        artifactID("seal.norse.forge-hammer"): sealResources("forge-hammer"),
        artifactID("seal.norse.echo-rune"): sealResources("echo-rune"),
    ]

    private static func sealResources(_ name: String) -> SealResourceIDs {
        SealResourceIDs(
            vector: id("resource.norse.seal.\(name).vector"),
            monochrome: id("resource.norse.seal.\(name).monochrome"),
            thumbnail: id("resource.norse.seal.\(name).thumbnail")
        )
    }
    private static func id(_ value: String) -> ThemeResourceID { ThemeResourceID(rawValue: value)! }
    private static func artifactID(_ value: String) -> ArtifactID { ArtifactID(rawValue: value)! }
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

struct NorseBasePlaceholderAssetDefinition: Sendable {
    let id: String
    let mediaType: ThemeResourceMediaType
    let byteCount: Int
    let sha256Hex: String
    let pixelWidth: Int?
    let pixelHeight: Int?
}

enum NorseBasePlaceholderAssetCatalog {
    static let definitions: [NorseBasePlaceholderAssetDefinition] = [
        asset("background-0", .png, 176_255, "1c4c4d9411b03bc4daad351b0406f13584d86ef255492b460cb591ab4c27426a", 1_024, 1_024),
        asset("background-1", .png, 166_171, "cca5d27b9112c32f934ad7344552431c7d6d9ed99697e531d6278d3d35f17bc3", 1_024, 1_024),
        asset("background-2", .png, 22_216, "1079da5d3ead27f640bd4a849aaa77fbdcf681edf1d3d59c77a2ebf882b55f45", 1_024, 1_024),
        asset("relic-raven-medallion-high-contrast", .png, 41_289, "92d0eebeccd88b0dda83cf885e036ea1453b77abbd7d352fdeb7193ab52103f8", 1_024, 1_024),
        asset("relic-raven-medallion-master", .png, 55_498, "c91bbfc32d840948d7280433df8af699242982a5b5c35b376267b9b5a262cef4", 1_024, 1_024),
        asset("relic-raven-medallion-thumbnail", .png, 9_843, "5e3da19c554ee981977812cc7cbf12b680956ffbc002892685f7893bdb87b429", 256, 256),
        asset("relic-sealed-parchment-high-contrast", .png, 26_064, "ee00979ee19a779beefe5e7c649e1abb4288b207a6922d61e347404a21b05843", 1_024, 1_024),
        asset("relic-sealed-parchment-master", .png, 29_339, "6bf6c6a40707e06c270be5fbc16da538030bab12ec724ba1aa991bc7f01b1489", 1_024, 1_024),
        asset("relic-sealed-parchment-thumbnail", .png, 4_152, "51fe0e97a5de4bab0a4c41581a6945599b20c0684497f3fad1d211eeb21666a6", 256, 256),
        asset("relic-weathered-high-contrast", .png, 37_513, "a8cb314b6e9ec39ca0850d28e00633ffec08148270172ce410adac5980935972", 1_024, 1_024),
        asset("relic-weathered-master", .png, 50_401, "840cbe21bae98e4386a3dfee261f302c8fee28f43f414a4c9f05327638ce6e0c", 1_024, 1_024),
        asset("relic-weathered-thumbnail", .png, 7_903, "7039ab2ab91e0b2025dd5044af1494a1e4d3e9c0c95ab89fe2d421f213fd53a3", 256, 256),
        asset("script-fallback", .png, 23_176, "f437c7e7b30c761acd5a4014418d0ae9bb00bcd894c1da9e341ba1d2f2dd7878", 1_024, 256),
        asset("seal-echo-rune-raster", .png, 9_787, "5b7f1cc4a09544f19092041a618a9b7c4818f06d553ac257d0d0fee7bc4fa171", 256, 256),
        asset("seal-echo-rune-vector", .pdf, 957, "45a33efa0ccca8e55998c10616d0025fd5b5c0439df08aaf7a6831cbe933f361"),
        asset("seal-forge-flame-raster", .png, 9_121, "784324d8e49d2aa4affb4b1480bbe69187303e920dbafc2917f4f3440a270182", 256, 256),
        asset("seal-forge-flame-vector", .pdf, 809, "6516959bcfbff31598c340106089bb6a929e2eb6bde3b5f9a950156cd3ef52cc"),
        asset("seal-forge-hammer-raster", .png, 12_276, "aca95225a4eb89c95ac1d3e7e135af158961e53df87149e6f4e7642c252cd8f8", 256, 256),
        asset("seal-forge-hammer-vector", .pdf, 920, "ac3b7a446fc23dd74b016a8520a894a0af581755186c463f57dd1cdf6f0c88fb"),
        asset("seal-knotwork-raster", .png, 10_187, "91f04aa58485eecc7c4ff433659024ddfb9dd6cab8d6b6b089820bdbc694f5cc", 256, 256),
        asset("seal-knotwork-vector", .pdf, 770, "2d43815babc140ab34fa62402ec96d7aa7cd6b83f01720093b92c37c1a8535b0"),
        asset("seal-longship-raster", .png, 10_846, "b28e6528f7f6662500398481cc57c731a35ea7b4cbee71bc803612f94fb6d67a", 256, 256),
        asset("seal-longship-vector", .pdf, 882, "8d547e178929d9936acfe7695b8352cda83d6226a75132a9e0a317e29dcfca79"),
        asset("seal-raven-raster", .png, 11_261, "edda9e79bb9415f0deeb7fc3c32a9932c03ad9ffb8a8c3fb0bee8225e23ad2af", 256, 256),
        asset("seal-raven-vector", .pdf, 845, "512b9811407af74f2e1261741e75e0c6f92938f890100d1e2a4ac2c251408234"),
        asset("vault-0", .png, 10_100, "5ff6cbef00ea56e69c16285d14d4e6a53d4cfff272de05f52f0aba79d8748d3a", 512, 320),
        asset("vault-1", .png, 8_979, "2fd60bd5ca82bd148cadef6231f86319bd435041e0b501e58b26031c56df09a4", 512, 320),
        asset("vault-2", .png, 12_035, "c5c2d4c9e1440799cdeee7570508096606a1f321e31d114bd3f104e301620891", 512, 320),
        asset("vault-3", .png, 9_264, "fb32c94b68d0e0ac41c46428c0e7fa47c86bdc68936ed07936158706c65579f8", 512, 320),
    ]

    static let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })

    private static func asset(
        _ id: String,
        _ mediaType: ThemeResourceMediaType,
        _ byteCount: Int,
        _ sha256Hex: String,
        _ pixelWidth: Int? = nil,
        _ pixelHeight: Int? = nil
    ) -> NorseBasePlaceholderAssetDefinition {
        NorseBasePlaceholderAssetDefinition(
            id: id,
            mediaType: mediaType,
            byteCount: byteCount,
            sha256Hex: sha256Hex,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

struct NorseBaseThemeResourceDefinition: Sendable {
    enum Rights: Sendable { case font, presentation }

    let id: ThemeResourceID
    let role: ThemeResourceRoleID
    let mediaType: ThemeResourceMediaType
    let requirement: ThemeResourceRequirement
    let sha256Hex: String
    let byteCount: Int
    let pixelWidth: Int?
    let pixelHeight: Int?
    let rights: Rights
    let placeholderAssetID: String?
}

enum NorseBaseThemeResourceCatalog {
    static let definitions: [NorseBaseThemeResourceDefinition] = {
        var result = [
            bundled(
                NorseBaseThemeResourceIDs.font,
                ThemeResourceRoles.scriptFont,
                .ttf,
                NorseBaseBundledResourceCatalog.notoSansRunicDescriptor,
                rights: .font
            ),
            bundled(
                NorseBaseThemeResourceIDs.scriptMapping,
                role("script.mapping"),
                .json,
                NorseBaseBundledResourceCatalog.scriptFallbackDescriptor
            ),
            bundled(
                NorseBaseThemeResourceIDs.backgroundParameters,
                ThemeResourceRoles.backgroundRendererParameters,
                .json,
                NorseBaseBundledResourceCatalog.visualResourcesDescriptor
            ),
            bundled(
                NorseBaseThemeResourceIDs.localization,
                ThemeResourceRoles.localizationStrings,
                .json,
                NorseBaseBundledResourceCatalog.localizationsDescriptor
            ),
            placeholder(
                NorseBaseThemeResourceIDs.scriptFallback,
                ThemeResourceRoles.scriptStaticFallback,
                "script-fallback"
            ),
            placeholder(
                NorseBaseThemeResourceIDs.backgroundStatic,
                ThemeResourceRoles.backgroundStaticBase,
                "background-0"
            ),
            placeholder(
                NorseBaseThemeResourceIDs.backgroundReduceMotion,
                ThemeResourceRoles.backgroundReduceMotion,
                "background-1"
            ),
            placeholder(
                NorseBaseThemeResourceIDs.backgroundHighContrast,
                ThemeResourceRoles.backgroundHighContrast,
                "background-2"
            ),
            placeholder(NorseBaseThemeResourceIDs.vaultCard, ThemeResourceRoles.vaultCard, "vault-0"),
            placeholder(
                NorseBaseThemeResourceIDs.vaultLocked,
                ThemeResourceRoles.vaultLockedSilhouette,
                "vault-1"
            ),
            placeholder(
                NorseBaseThemeResourceIDs.vaultEncountered,
                ThemeResourceRoles.vaultEncountered,
                "vault-2"
            ),
            placeholder(
                NorseBaseThemeResourceIDs.vaultSelected,
                ThemeResourceRoles.vaultSelected,
                "vault-3"
            ),
        ]

        let relicAssets: [(ArtifactID, String)] = [
            (ArtifactID(rawValue: "relic.norse.runestone.weathered")!, "relic-weathered"),
            (ArtifactID(rawValue: "relic.norse.raven-medallion")!, "relic-raven-medallion"),
            (ArtifactID(rawValue: "relic.norse.sealed-parchment")!, "relic-sealed-parchment"),
        ]
        for (artifactID, assetPrefix) in relicAssets {
            let resourceIDs = NorseBaseThemeResourceIDs.relicResourceIDs[artifactID]!
            result.append(contentsOf: [
                placeholder(resourceIDs.primary, ThemeResourceRoles.relicMaster, "\(assetPrefix)-master"),
                placeholder(resourceIDs.thumbnail, ThemeResourceRoles.relicThumbnail, "\(assetPrefix)-thumbnail"),
                placeholder(
                    resourceIDs.staticFallback,
                    ThemeResourceRoles.relicStaticShareFallback,
                    "\(assetPrefix)-master"
                ),
                placeholder(
                    resourceIDs.highContrast,
                    ThemeResourceRoles.relicHighContrast,
                    "\(assetPrefix)-high-contrast"
                ),
            ])
        }

        let sealAssets: [(ArtifactID, String)] = [
            (ArtifactID(rawValue: "seal.norse.knotwork")!, "seal-knotwork"),
            (ArtifactID(rawValue: "seal.norse.forge-flame")!, "seal-forge-flame"),
            (ArtifactID(rawValue: "seal.norse.raven")!, "seal-raven"),
            (ArtifactID(rawValue: "seal.norse.longship")!, "seal-longship"),
            (ArtifactID(rawValue: "seal.norse.forge-hammer")!, "seal-forge-hammer"),
            (ArtifactID(rawValue: "seal.norse.echo-rune")!, "seal-echo-rune"),
        ]
        for (artifactID, assetPrefix) in sealAssets {
            let resourceIDs = NorseBaseThemeResourceIDs.sealResourceIDs[artifactID]!
            result.append(contentsOf: [
                placeholder(
                    resourceIDs.vector,
                    ThemeResourceRoles.sealVectorMaster,
                    "\(assetPrefix)-vector"
                ),
                placeholder(
                    resourceIDs.monochrome,
                    ThemeResourceRoles.sealMonochromeFallback,
                    "\(assetPrefix)-raster"
                ),
                placeholder(
                    resourceIDs.thumbnail,
                    ThemeResourceRoles.sealThumbnail,
                    "\(assetPrefix)-raster"
                ),
            ])
        }
        return result.sorted { $0.id.rawValue < $1.id.rawValue }
    }()

    static func references(
        fontRightsID: ThemeProvenanceID,
        presentationRightsID: ThemeProvenanceID
    ) throws -> [ThemeResourceReference] {
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
                rightsID: definition.rights == .font ? fontRightsID : presentationRightsID
            )
        }
    }

    static func validates(_ payloads: [ThemeResourceID: Data]) -> Bool {
        guard Set(payloads.keys) == Set(definitions.map(\.id)) else { return false }
        return definitions.allSatisfy { definition in
            guard let data = payloads[definition.id] else { return false }
            return data.count == definition.byteCount && sha256Hex(data) == definition.sha256Hex
        }
    }

    private static func bundled(
        _ id: ThemeResourceID,
        _ role: ThemeResourceRoleID,
        _ mediaType: ThemeResourceMediaType,
        _ bundled: NorseBaseBundledResourceDescriptor,
        rights: NorseBaseThemeResourceDefinition.Rights = .presentation
    ) -> NorseBaseThemeResourceDefinition {
        NorseBaseThemeResourceDefinition(
            id: id,
            role: role,
            mediaType: mediaType,
            requirement: .required,
            sha256Hex: bundled.expectedSHA256Hex,
            byteCount: bundled.expectedByteCount,
            pixelWidth: nil,
            pixelHeight: nil,
            rights: rights,
            placeholderAssetID: nil
        )
    }

    private static func placeholder(
        _ id: ThemeResourceID,
        _ role: ThemeResourceRoleID,
        _ assetID: String
    ) -> NorseBaseThemeResourceDefinition {
        let asset = NorseBasePlaceholderAssetCatalog.byID[assetID]!
        return NorseBaseThemeResourceDefinition(
            id: id,
            role: role,
            mediaType: asset.mediaType,
            requirement: .required,
            sha256Hex: asset.sha256Hex,
            byteCount: asset.byteCount,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            rights: .presentation,
            placeholderAssetID: assetID
        )
    }

    private static func role(_ value: String) -> ThemeResourceRoleID {
        ThemeResourceRoleID(rawValue: value)!
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
