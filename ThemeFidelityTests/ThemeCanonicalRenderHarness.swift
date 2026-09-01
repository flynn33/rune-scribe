import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import RuneScribeUIModule
import RuneScribeUIRuntime
import SwiftUI
import UniformTypeIdentifiers
import XCTest

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ThemeCanonicalRenderRequest: Equatable, Sendable {
    let candidateID: String
    let wrapperID: String
    let themeName: String
    let themeID: String
    let codexID: String
    let seedID: String
    let seedIDs: [String]
    let recipe: ThemeCanonicalRecipe
    let renderMode: ThemeCanonicalRenderMode
    let width: Int
    let height: Int
    let locale: String
    let timeZone: String
    let colorScheme: String
    let dynamicType: String
    let contrastMode: ThemeCanonicalContrastMode
    let reduceMotion: Bool
    let animationsEnabled: Bool
    let testClock: Date
    let expectedProductionResourceIDs: [String]
    let outputPath: String

    var requiredCaptureElementIDs: [String] { [wrapperID] }
}

enum ThemeCanonicalContrastMode: String, Equatable, Sendable {
    case standard
    case increased
}

enum ThemeCanonicalRenderMode: String, Decodable, Sendable {
    case fullProductionScreen = "full-production-screen"
    case canonicalProductionComponent = "canonical-production-component"
    case resolvedResourceExport = "resolved-resource-export"
}

enum ThemeCanonicalRecipe: String, CaseIterable, Decodable, Sendable {
    case canonicalProductionComponent = "canonical-production-component"
    case fullScreenCodexCatalog = "full-screen-codex-catalog"
    case fullScreenCodexCatalogAlt = "full-screen-codex-catalog-alt"
    case fullScreenCodexCatalogSeries = "full-screen-codex-catalog-series"
    case fullScreenComposeDefault = "full-screen-compose-default"
    case fullScreenComposeLong = "full-screen-compose-long"
    case fullScreenInscriptionPreview = "full-screen-inscription-preview"
    case fullScreenReceivedPrimary = "full-screen-received-primary"
    case fullScreenReceivedShareCard = "full-screen-received-share-card"
    case fullScreenVaultUnlockProgress = "full-screen-vault-unlock-progress"
    case longMessagePanel = "long-message-panel"
    case masteryDetailPanel = "mastery-detail-panel"
    case masteryOverviewPanel = "mastery-overview-panel"
    case norseComposeWorkspacePanel = "norse-compose-workspace-panel"
    case receivedCipherPanel = "received-cipher-panel"
    case relicCatalogPanel = "relic-catalog-panel"
    case relicSpecimenCard = "relic-specimen-card"
    case sealCatalogPanel = "seal-catalog-panel"
    case sealSpecimenCard = "seal-specimen-card"
    case sharePreviewCard = "share-preview-card"
    case shortMessagePanel = "short-message-panel"
    case themeBackgroundPanel = "theme-background-panel"
    case vaultCardStateStack = "vault-card-state-stack"

    var preferredSurface: String {
        switch self {
        case .canonicalProductionComponent, .sealCatalogPanel, .sealSpecimenCard:
            "seal-picker"
        case .fullScreenCodexCatalog, .relicCatalogPanel, .relicSpecimenCard:
            "relic-picker"
        case .fullScreenCodexCatalogAlt:
            "vault-encountered"
        case .fullScreenCodexCatalogSeries:
            "vault-owned"
        case .fullScreenComposeDefault, .shortMessagePanel:
            "compose-short"
        case .fullScreenComposeLong, .longMessagePanel:
            "compose-long"
        case .fullScreenInscriptionPreview:
            "inscription-preview"
        case .fullScreenReceivedPrimary, .receivedCipherPanel:
            "received-cipher"
        case .fullScreenReceivedShareCard:
            "share-builder"
        case .fullScreenVaultUnlockProgress:
            "vault-progress"
        case .masteryDetailPanel, .masteryOverviewPanel:
            "mastery"
        case .norseComposeWorkspacePanel:
            "settings-defaults-preview"
        case .sharePreviewCard:
            "static-share"
        case .themeBackgroundPanel:
            "workspace-empty"
        case .vaultCardStateStack:
            "vault-selected"
        }
    }
}

enum ThemeCanonicalRegistryError: Error, Equatable {
    case missingCatalog
    case invalidJSONShape
    case unknownKeys(path: String, keys: [String])
    case invalidCatalog(String)
    case unknownCandidate(String)
}

enum ThemeCanonicalProductionBinding: Equatable, Sendable {
    case fullScreen(surface: String)
    case resolvedResource
    case artifactSpecimen(kind: String, artifactID: String)
    case productionComponent(ThemeCanonicalRecipe)
}

struct ThemeCanonicalReferenceIdentity: Equatable, Sendable {
    let sha256: String
    let width: Int
    let height: Int
}

enum ThemeCanonicalResourceExportSource: Equatable, Sendable {
    case resolvedProductionResource(Data)
    case systemSymbol(String)
}

struct ThemeCanonicalResolvedResourceValidator {
    static func validate(
        _ source: ThemeCanonicalResourceExportSource,
        candidateID: String,
        expectedByteCount: Int,
        expectedSHA256: String
    ) throws -> Data {
        guard case let .resolvedProductionResource(data) = source else {
            throw ThemeCanonicalRegistryError.invalidCatalog(
                "non-resource substitution \(candidateID)"
            )
        }
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        guard data.count == expectedByteCount, digest == expectedSHA256 else {
            throw ThemeCanonicalRegistryError.invalidCatalog(
                "resolved resource drift \(candidateID)"
            )
        }
        return data
    }
}

struct ThemeCanonicalRenderRegistry: Sendable {
    static let expectedCatalogID = "runescribe.theme-fidelity.v4.3.canonical-render-catalog"
    static let expectedCandidateCount = 50
    static let expectedUniqueReferenceCount = 49
    static let expectedReferenceIdentityByCandidate: [
        String: ThemeCanonicalReferenceIdentity
    ] = [
        "canonical.gloamthorn.gloamthorn-codex-catalog-final.f121a4dad9": .init(sha256: "f121a4dad91b65741321ca014bc2650a6913afadc91e19348aa9bbf375037ac0", width: 941, height: 1672),
        "canonical.gloamthorn.relic-duskbriar-stele-reference.b248c0b8cf": .init(sha256: "b248c0b8cf86aa6dcf33a9a7057b7d55f4bf7657a484bd6afb0aa01edb775584", width: 295, height: 365),
        "canonical.gloamthorn.relic-nightthorn-tablet-reference.d697177200": .init(sha256: "d697177200a2ec0990590270ef2354acbb48f09af0a0a00770afd1d1d42efe39", width: 535, height: 520),
        "canonical.gloamthorn.relic-umbral-plaque-reference.5b8fc04d7f": .init(sha256: "5b8fc04d7f1730189db4b941b43f4fb1a540c4d2b4a1fb3b6e2aac3dd5cfd8b1", width: 295, height: 270),
        "canonical.moonleaf.moonleaf-codex-catalog-final-alt.0a3fb35ab4": .init(sha256: "0a3fb35ab47efb272dab404a081a5d4d603fef91ec9d4093a917bf77311f66a1", width: 941, height: 1672),
        "canonical.moonleaf.moonleaf-codex-catalog-final.72ef342ade": .init(sha256: "72ef342adec3f194318c0af3e19b2b4dac40f23de160f31f2c22c5ae12a7c368", width: 941, height: 1672),
        "canonical.moonleaf.moonleaf-codex-catalog-series.0a3fb35ab4": .init(sha256: "0a3fb35ab47efb272dab404a081a5d4d603fef91ec9d4093a917bf77311f66a1", width: 941, height: 1672),
        "canonical.moonleaf.moonleaf-compose-final-a.b02a1fee73": .init(sha256: "b02a1fee731eeaae5846f29a2d1e4621e2c98fb8b47a962ca64efa4fe64f1467", width: 941, height: 1672),
        "canonical.moonleaf.moonleaf-compose-final-b.c30b5df472": .init(sha256: "c30b5df472b19abd4241afe77e20516e29a34ba3fd55f2404307b0a5ecf50fde", width: 941, height: 1672),
        "canonical.moonleaf.moonleaf-inscription-preview-final.a19fdfeb69": .init(sha256: "a19fdfeb693f50bb2cdf17a851cf19a911ea4c87e9db19d1889dfae7a23c9626", width: 941, height: 1672),
        "canonical.moonleaf.moonleaf-received-cipher-final-a.23b96619f9": .init(sha256: "23b96619f911ffc58be81e95869ea16b39b2e689a6b6164be77829d8e2a85b67", width: 941, height: 1672),
        "canonical.moonleaf.moonleaf-received-cipher-final-b.79446a4e03": .init(sha256: "79446a4e03976835f5727b3e9285f00e004602cba8c9496122bed115b0657db4", width: 941, height: 1672),
        "canonical.moonleaf.relic-ivybound-plaque-reference.c3e8009bfe": .init(sha256: "c3e8009bfe6cf4436b44ed406a690c3d57438120de7b412480bdf7219207024a", width: 290, height: 270),
        "canonical.moonleaf.relic-moonleaf-tablet-reference.06e58cc199": .init(sha256: "06e58cc199113d2533d694db44f605be508f85e6be33b1076570d5a018f8f91f", width: 525, height: 535),
        "canonical.moonleaf.relic-whisperbark-stele-reference.80e7aa747c": .init(sha256: "80e7aa747cf2b250004f3b9e248523be887569b75e0b8af1a2250f3ab3b2b997", width: 295, height: 365),
        "canonical.moonleaf.seal-crescentleaf-reference.f328c3f3ea": .init(sha256: "f328c3f3ea9ff14616e71517faca85fe10d4da716cf2b2bcc4b84d6e88c3f0c0", width: 365, height: 445),
        "canonical.moonleaf.seal-woodland-stag-reference.cd069361a1": .init(sha256: "cd069361a104a2a0967eed5ddb5540e95e20e4d0c7e943164484cc2faedc242e", width: 365, height: 405),
        "canonical.moonleaf.vault-elven-codex-unlock-progress.818dbd5057": .init(sha256: "818dbd5057589d2095cc6b3c5e32a8d7072523a0093ef9317dce24b37ce995e1", width: 941, height: 1672),
        "canonical.norse.02-relic-catalog.a30d3d6ac5": .init(sha256: "a30d3d6ac5112da8c1606008b307678e27611c4455c82e45b43bf0f5bb41fcf3", width: 1002, height: 730),
        "canonical.norse.03-seal-catalog.5849446001": .init(sha256: "58494460016fbb9a8e944604d36cfb5ed266554fb63fcfccf78e6f585b2b5a53", width: 806, height: 730),
        "canonical.norse.04-compose-workspace.619a137fbc": .init(sha256: "619a137fbcc760b60b28f1a1569cf289922fc37e39102040435782de17f7c2d6", width: 700, height: 648),
        "canonical.norse.05-short-message.aae1f3bf5c": .init(sha256: "aae1f3bf5cff4b94fbc2ca6eb86eedbeb2cabb8281588c53aef5d6d13e9efbe7", width: 398, height: 700),
        "canonical.norse.06-long-message.49860b3f30": .init(sha256: "49860b3f30e633dda4c15186d6d40f80a34192265c048bf20c9dfdcf774a12a1", width: 464, height: 700),
        "canonical.norse.07-received-cipher.3f840710d4": .init(sha256: "3f840710d4e1b3637d3f2abbfbdb59cbac174502485b824aca53797740d6224f", width: 496, height: 700),
        "canonical.norse.08-share-preview.17232537b1": .init(sha256: "17232537b11d19ea192127b887fcf6474ee32e2471e1d8a9ff1eefc49ac56767", width: 506, height: 700),
        "canonical.norse.10-background-treatment.78fa42c571": .init(sha256: "78fa42c5712c796f43efea41bab7dc8249fa076265b6903dc33d70f39756a810", width: 910, height: 460),
        "canonical.norse.11-mastery-rewards.12cd618085": .init(sha256: "12cd6180852261263b8e6b8d119dc6d7f33da6431f9e0ac7e0a6b4e2649eeb26", width: 792, height: 460),
        "canonical.norse.mastery-reference.53e6ee4d30": .init(sha256: "53e6ee4d30d1f3be91c7afe91aa93b975b0d6e6617222ac7a1687fd4377994c2", width: 402, height: 225),
        "canonical.norse.relic-dragonwood-plaque-reference.0ad79d60ba": .init(sha256: "0ad79d60ba52118e11e9ef68a4fd2895d0db6d2870f430f703e34a7c8a803ccf", width: 172, height: 307),
        "canonical.norse.relic-runestone-tablet-reference.2bc66b3956": .init(sha256: "2bc66b3956cece74b27f0f2c94717cef7db097b9fbd0fbc599d632a112379b6c", width: 172, height: 307),
        "canonical.norse.relic-stormforged-stele-reference.de8845428e": .init(sha256: "de8845428e1c8e937448c1fd34c1a0f6137a6623e0f26611ff969758d3646fe7", width: 165, height: 307),
        "canonical.norse.seal-norse-berserk.9594aeec80": .init(sha256: "9594aeec80db4e554461374690365bf0d932b251873aacf055072bb18992c996", width: 1_024, height: 981),
        "canonical.norse.seal-norse-mjolnir.db76bb110f": .init(sha256: "db76bb110f59353341e698b55a7c4884c9ead1ad091751f7e89b7970356324de", width: 1_003, height: 1_024),
        "canonical.norse.seal-norse-ravenshield.59dd542f4e": .init(sha256: "59dd542f4e79854e3d979ae002a04f422844db385812ae52e4ca28d66d9e5292", width: 1_024, height: 1_015),
        "canonical.norse.seal-norse-valknut.5e6c584ed9": .init(sha256: "5e6c584ed9825316f964e87277fa02f9e493ca6201e17a5278952a4f5c4f7e30", width: 1_015, height: 1_024),
        "canonical.norse.seal-norse-wolkin.61acc4bf6b": .init(sha256: "61acc4bf6bb77396f3dde400f0b55518e946454f0f1df3717ecc435530e6d87e", width: 1_013, height: 1_024),
        "canonical.norse.seal-norse-yggdrasil.2f8593cd6b": .init(sha256: "2f8593cd6b23d18f92666a2abd7c707ec045116efc99fafbb5d8dff0205e094b", width: 1_024, height: 991),
        "canonical.norse.vault-card-reference.9a056285ad": .init(sha256: "9a056285ad7a17a58966da921936b38622818f886fed8112772ad959d0771463", width: 270, height: 386),
        "canonical.sunspire.relic-auric-stele-reference.ac627d94ce": .init(sha256: "ac627d94ce1c3c2e67aa96ba073619c6d72548b1319e88c345a711ef46a20fab", width: 295, height: 365),
        "canonical.sunspire.relic-dawnfire-tablet-reference.e1e7c42e94": .init(sha256: "e1e7c42e94f285381bf175be618b102bc0dfa8dd5fc36fa43270adfcbf64f4d4", width: 525, height: 530),
        "canonical.sunspire.relic-solvine-plaque-reference.20aa5f2ac8": .init(sha256: "20aa5f2ac850b2175974c7cf5514c2dce7ed0736dd63868dda85165ca08934cb", width: 295, height: 270),
        "canonical.sunspire.seal-golden-lark-reference.2f9cade52e": .init(sha256: "2f9cade52e1b9d7292056f5052077f7c08be81c24fed39ad708ff861dbd10a4f", width: 280, height: 400),
        "canonical.sunspire.seal-sunleaf-reference.0c22590da2": .init(sha256: "0c22590da2e087abd69649e3599f75812d5e3dd2297b94d03376c9006e75f094", width: 275, height: 410),
        "canonical.sunspire.sunspire-codex-catalog-final.a99ecdcaa1": .init(sha256: "a99ecdcaa15f9a3233ea7515c991e02c789303d6113ca514c19c94b1ea72bc67", width: 941, height: 1672),
        "canonical.wildwood.relic-elderbark-stele-reference.7882cb87d6": .init(sha256: "7882cb87d6e80841285abfe962cf06075b64922e65ca94310709ba3006e67b8a", width: 295, height: 365),
        "canonical.wildwood.relic-mossbound-plaque-reference.4d6ef1a7f8": .init(sha256: "4d6ef1a7f8e7b8c8cf5e99c223f3e9aaac85f14e4c76f9501440d7dffc1c58d2", width: 295, height: 270),
        "canonical.wildwood.relic-rootsong-tablet-reference.366ca15971": .init(sha256: "366ca15971f02813323e8d5484230e48f422c50bec13c1deff2f4218eba86838", width: 530, height: 525),
        "canonical.wildwood.seal-lantern-moth-reference.2a9c37ff18": .init(sha256: "2a9c37ff18fe521868a48754985eb7e9960ae4ce5f1830d93a7b72f5fa3da8dd", width: 350, height: 455),
        "canonical.wildwood.seal-rooted-tree-reference.b7f3040eb4": .init(sha256: "b7f3040eb49ce3e84e99eeb0d28d5f821587c7dbfe864b940a519abf3207de82", width: 350, height: 420),
        "canonical.wildwood.wildwood-codex-catalog-final.1f004173f5": .init(sha256: "1f004173f5b876da5858c4accfbb96172c2a74a7ca92f009a3a9849553e18bd7", width: 941, height: 1672),
    ]

    let catalog: ThemeCanonicalCatalog
    private let candidatesByID: [String: ThemeCanonicalCatalog.Candidate]

    static func load(bundle: Bundle) throws -> Self {
        guard let url = bundle.url(
            forResource: "Canonical-Render-Catalog-v1.3",
            withExtension: "json"
        ) else { throw ThemeCanonicalRegistryError.missingCatalog }
        return try decode(data: Data(contentsOf: url))
    }

    static func decode(data: Data) throws -> Self {
        try validateKnownKeys(data: data)
        let decoder = JSONDecoder()
        let catalog: ThemeCanonicalCatalog
        do {
            catalog = try decoder.decode(ThemeCanonicalCatalog.self, from: data)
        } catch {
            throw ThemeCanonicalRegistryError.invalidCatalog(String(describing: error))
        }
        guard catalog.schemaVersion == "1.3",
              catalog.catalogID == expectedCatalogID,
              catalog.candidateCount == expectedCandidateCount,
              catalog.candidates.count == expectedCandidateCount,
              !catalog.requiresFurtherOwnerInput
        else { throw ThemeCanonicalRegistryError.invalidCatalog("catalog header") }

        let ids = catalog.candidates.map(\.id)
        guard Set(ids).count == ids.count,
              expectedReferenceIdentityByCandidate.count == expectedCandidateCount,
              Set(ids) == Set(expectedReferenceIdentityByCandidate.keys)
        else {
            throw ThemeCanonicalRegistryError.invalidCatalog("candidate identity set")
        }
        let wrappers = catalog.candidates.map(\.requiredCanonicalWrapperID)
        guard Set(wrappers).count == wrappers.count else {
            throw ThemeCanonicalRegistryError.invalidCatalog("duplicate wrapper ID")
        }
        for candidate in catalog.candidates {
            guard let expectedReference = expectedReferenceIdentityByCandidate[
                candidate.id
            ], expectedReference == ThemeCanonicalReferenceIdentity(
                sha256: candidate.referenceSHA256,
                width: candidate.referenceDimensions.first ?? 0,
                height: candidate.referenceDimensions.dropFirst().first ?? 0
            ) else {
                throw ThemeCanonicalRegistryError.invalidCatalog(
                    "reference identity drift \(candidate.id)"
                )
            }
            guard candidate.requiredCanonicalWrapperID == "\(candidate.id).wrapper",
                  candidate.referenceDimensions.count == 2,
                  candidate.requiredOutputDimensions == candidate.referenceDimensions,
                  candidate.referenceDimensions.allSatisfy({ $0 > 0 }),
                  candidate.host.displayScale == 1,
                  !candidate.seedIDs.isEmpty,
                  !candidate.outputPath.isEmpty,
                  candidate.outputPath.hasPrefix(
                    "docs/verification/theme-fidelity-v4-3/canonical/"
                  )
            else { throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id) }
        }
        let referenceIdentities = Set(catalog.candidates.map {
            "\($0.referenceSHA256)|\($0.referenceDimensions[0])x\($0.referenceDimensions[1])"
        })
        guard referenceIdentities.count == expectedUniqueReferenceCount else {
            throw ThemeCanonicalRegistryError.invalidCatalog("reference uniqueness")
        }
        return Self(
            catalog: catalog,
            candidatesByID: Dictionary(uniqueKeysWithValues: catalog.candidates.map {
                ($0.id, $0)
            })
        )
    }

    func request(
        candidateID: String,
        seedRegistry: ThemeCanonicalSeedRegistry,
        expectedProductionResourceIDs: [String] = []
    ) throws -> ThemeCanonicalRenderRequest {
        guard let candidate = candidatesByID[candidateID] else {
            throw ThemeCanonicalRegistryError.unknownCandidate(candidateID)
        }
        let parts = candidateID.split(separator: ".")
        guard parts.count >= 3 else {
            throw ThemeCanonicalRegistryError.invalidCatalog(candidateID)
        }
        let themeName = String(parts[1])
        guard candidate.surfaces.contains(candidate.recipeClass.preferredSurface)
        else { throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id) }
        let seeds = try candidate.seedIDs.map { seedID in
            (seedID, try seedRegistry.seed(id: seedID))
        }
        guard let selectedSeed = seeds.first(where: {
            $0.1.surface == candidate.recipeClass.preferredSurface
        }) else { throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id) }
        let environment = selectedSeed.1.launchEnvironment
        guard selectedSeed.1.theme.lowercased() == themeName,
              let themeID = environment["RUNESCRIBE_QUALIFICATION_THEME_ID"],
              let codexID = environment["RUNESCRIBE_QUALIFICATION_CODEX_ID"],
              let appearance = environment["RUNESCRIBE_QUALIFICATION_APPEARANCE"],
              ["standard", "high-contrast", "reduce-motion", "accessibility-xxxl"]
                .contains(appearance)
        else { throw ThemeCanonicalRegistryError.invalidCatalog(selectedSeed.0) }
        return ThemeCanonicalRenderRequest(
            candidateID: candidate.id,
            wrapperID: candidate.requiredCanonicalWrapperID,
            themeName: themeName,
            themeID: themeID,
            codexID: codexID,
            seedID: selectedSeed.0,
            seedIDs: candidate.seedIDs,
            recipe: candidate.recipeClass,
            renderMode: candidate.renderMode,
            width: candidate.requiredOutputDimensions[0],
            height: candidate.requiredOutputDimensions[1],
            locale: candidate.host.locale,
            timeZone: candidate.host.timeZone,
            colorScheme: candidate.host.colorScheme,
            dynamicType: candidate.host.dynamicType,
            contrastMode: appearance == "high-contrast" ? .increased : .standard,
            reduceMotion: appearance == "reduce-motion",
            animationsEnabled: candidate.host.animationsEnabled,
            testClock: Date(timeIntervalSince1970: 1_787_866_860),
            expectedProductionResourceIDs: expectedProductionResourceIDs.sorted(),
            outputPath: candidate.outputPath
        )
    }

    func candidate(id: String) throws -> ThemeCanonicalCatalog.Candidate {
        guard let candidate = candidatesByID[id] else {
            throw ThemeCanonicalRegistryError.unknownCandidate(id)
        }
        return candidate
    }

    func productionBinding(
        candidateID: String
    ) throws -> ThemeCanonicalProductionBinding {
        let candidate = try candidate(id: candidateID)
        switch candidate.renderMode {
        case .resolvedResourceExport:
            return .resolvedResource
        case .fullProductionScreen:
            let surface = try Self.fullScreenSurface(for: candidate)
            guard candidate.surfaces.contains(surface) else {
                throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id)
            }
            return .fullScreen(surface: surface)
        case .canonicalProductionComponent:
            if candidate.recipeClass == .relicSpecimenCard
                || candidate.recipeClass == .sealSpecimenCard
            {
                guard let binding = candidate.v42FormerCandidateBindings.first(where: {
                    $0.hasPrefix("theme.artifact-picker.")
                }) else {
                    throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id)
                }
                let prefix = "theme.artifact-picker."
                let remainder = String(binding.dropFirst(prefix.count))
                guard let separator = remainder.firstIndex(of: ".") else {
                    throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id)
                }
                let kind = String(remainder[..<separator])
                let artifactSuffix = String(
                    remainder[remainder.index(after: separator)...]
                )
                guard (kind == "relic" || kind == "seal"), !artifactSuffix.isEmpty else {
                    throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id)
                }
                let artifactID = "\(kind).\(artifactSuffix)"
                return .artifactSpecimen(kind: kind, artifactID: artifactID)
            }
            return .productionComponent(candidate.recipeClass)
        }
    }

    func resolvedResourceArtifactID(candidateID: String) throws -> String {
        let candidate = try candidate(id: candidateID)
        guard candidate.renderMode == .resolvedResourceExport,
              let binding = candidate.v42FormerCandidateBindings.first(where: {
                  $0.hasPrefix("theme.artifact-picker.seal.")
              })
        else { throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id) }
        let prefix = "theme.artifact-picker."
        let artifactID = String(binding.dropFirst(prefix.count))
        guard artifactID.hasPrefix("seal."), !artifactID.dropFirst(5).isEmpty else {
            throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id)
        }
        return artifactID
    }

    private static func fullScreenSurface(
        for candidate: ThemeCanonicalCatalog.Candidate
    ) throws -> String {
        switch candidate.recipeClass {
        case .fullScreenCodexCatalog:
            "relic-picker"
        case .fullScreenCodexCatalogAlt:
            "vault-encountered"
        case .fullScreenCodexCatalogSeries:
            "vault-owned"
        case .fullScreenComposeDefault:
            "compose-short"
        case .fullScreenComposeLong:
            "compose-long"
        case .fullScreenInscriptionPreview:
            "inscription-preview"
        case .fullScreenReceivedPrimary:
            "received-cipher"
        case .fullScreenReceivedShareCard:
            "share-builder"
        case .fullScreenVaultUnlockProgress:
            "vault-progress"
        default:
            throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id)
        }
    }

    private static func validateKnownKeys(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]]
        else { throw ThemeCanonicalRegistryError.invalidJSONShape }
        try requireKeys(
            root,
            allowed: [
                "candidateCount", "candidates", "catalogID",
                "requiresFurtherOwnerInput", "reuseRule", "schemaVersion",
            ],
            path: "$"
        )
        let candidateKeys: Set<String> = [
            "comparisonMask", "destinationsUsingResult", "entryIDs",
            "evaluationKind", "host", "id", "implementationConstraints",
            "outputPath", "productionSourceRequirements", "recipeClass",
            "recipeNotes", "referenceAsset", "referenceByteCount",
            "referenceDimensions", "referenceSHA256", "renderMode",
            "requiredCanonicalWrapperID", "requiredOutputDimensions", "seedIDs",
            "surfaces", "thresholdProfile", "v42FormerBindingKinds",
            "v42FormerCandidateBindings",
        ]
        let hostKeys: Set<String> = [
            "animationsEnabled", "backgroundPolicy", "calendar", "colorScheme",
            "displayScale", "dynamicType", "locale", "paddingPolicy",
            "safeAreaPolicy", "timeZone",
        ]
        for (index, candidate) in candidates.enumerated() {
            try requireKeys(candidate, allowed: candidateKeys, path: "$.candidates[\(index)]")
            guard let host = candidate["host"] as? [String: Any] else {
                throw ThemeCanonicalRegistryError.invalidJSONShape
            }
            try requireKeys(
                host,
                allowed: hostKeys,
                path: "$.candidates[\(index)].host"
            )
        }
    }

    private static func requireKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        path: String
    ) throws {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw ThemeCanonicalRegistryError.unknownKeys(path: path, keys: unknown)
        }
    }
}

struct ThemeCanonicalSeedRegistry: Sendable {
    static let expectedCatalogID = "runescribe.theme-fidelity.deterministic-seed-catalog.v4.3"
    static let expectedSeedCount = 100

    let catalog: ThemeCanonicalSeedCatalog
    private let seedsByID: [String: ThemeCanonicalSeedCatalog.Seed]

    static func load(bundle: Bundle) throws -> Self {
        guard let url = bundle.url(
            forResource: "Deterministic-Seed-Catalog-v1.3",
            withExtension: "json"
        ) else { throw ThemeCanonicalRegistryError.missingCatalog }
        return try decode(data: Data(contentsOf: url))
    }

    static func decode(data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seeds = root["seeds"] as? [[String: Any]]
        else { throw ThemeCanonicalRegistryError.invalidJSONShape }
        try requireExactKeys(
            root,
            expected: ["catalogID", "schemaVersion", "seedCount", "seeds"],
            path: "$"
        )
        let expectedSeedKeys: Set<String> = [
            "id", "launchEnvironment", "operatorInputRequired", "surface", "theme",
        ]
        let requiredEnvironmentKeys: Set<String> = [
            "RUNESCRIBE_QUALIFICATION",
            "RUNESCRIBE_QUALIFICATION_APPEARANCE",
            "RUNESCRIBE_QUALIFICATION_CODEX_ID",
            "RUNESCRIBE_QUALIFICATION_DEFAULT_RELIC_ID",
            "RUNESCRIBE_QUALIFICATION_DEFAULT_SEAL_ID",
            "RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE",
            "RUNESCRIBE_QUALIFICATION_RESET_STATE",
            "RUNESCRIBE_QUALIFICATION_SURFACE",
            "RUNESCRIBE_QUALIFICATION_THEME_ID",
        ]
        for (index, seed) in seeds.enumerated() {
            try requireExactKeys(
                seed,
                expected: expectedSeedKeys,
                path: "$.seeds[\(index)]"
            )
            guard let environment = seed["launchEnvironment"] as? [String: Any] else {
                throw ThemeCanonicalRegistryError.invalidJSONShape
            }
            let keys = Set(environment.keys)
            guard keys == requiredEnvironmentKeys
                    || keys == requiredEnvironmentKeys.union([
                        "RUNESCRIBE_QUALIFICATION_VAULT_STATE",
                    ])
            else {
                throw ThemeCanonicalRegistryError.unknownKeys(
                    path: "$.seeds[\(index)].launchEnvironment",
                    keys: Array(keys.subtracting(requiredEnvironmentKeys)).sorted()
                )
            }
        }

        let catalog: ThemeCanonicalSeedCatalog
        do {
            catalog = try JSONDecoder().decode(ThemeCanonicalSeedCatalog.self, from: data)
        } catch {
            throw ThemeCanonicalRegistryError.invalidCatalog(String(describing: error))
        }
        guard catalog.schemaVersion == "1.3",
              catalog.catalogID == expectedCatalogID,
              catalog.seedCount == expectedSeedCount,
              catalog.seeds.count == expectedSeedCount,
              Set(catalog.seeds.map(\.id)).count == expectedSeedCount,
              catalog.seeds.allSatisfy({ !$0.operatorInputRequired })
        else { throw ThemeCanonicalRegistryError.invalidCatalog("seed catalog header") }
        for seed in catalog.seeds {
            guard seed.launchEnvironment["RUNESCRIBE_QUALIFICATION"]
                    == "theme-fidelity-v4.2",
                  seed.launchEnvironment["RUNESCRIBE_QUALIFICATION_RESET_STATE"] == "1",
                  seed.launchEnvironment["RUNESCRIBE_QUALIFICATION_SURFACE"]
                    == seed.surface
            else { throw ThemeCanonicalRegistryError.invalidCatalog(seed.id) }
        }
        return Self(
            catalog: catalog,
            seedsByID: Dictionary(uniqueKeysWithValues: catalog.seeds.map { ($0.id, $0) })
        )
    }

    func environment(seedID: String, destination: String) throws -> [String: String] {
        guard let seed = seedsByID[seedID] else {
            throw ThemeCanonicalRegistryError.unknownCandidate(seedID)
        }
        var environment = seed.launchEnvironment
        environment["RUNESCRIBE_QUALIFICATION_DESTINATION"] = destination
        return environment
    }

    func seed(id: String) throws -> ThemeCanonicalSeedCatalog.Seed {
        guard let seed = seedsByID[id] else {
            throw ThemeCanonicalRegistryError.unknownCandidate(id)
        }
        return seed
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        expected: Set<String>,
        path: String
    ) throws {
        let actual = Set(object.keys)
        let differences = actual.symmetricDifference(expected).sorted()
        guard differences.isEmpty else {
            throw ThemeCanonicalRegistryError.unknownKeys(path: path, keys: differences)
        }
    }
}

struct ThemeCanonicalSeedCatalog: Decodable, Sendable {
    let schemaVersion: String
    let catalogID: String
    let seedCount: Int
    let seeds: [Seed]

    struct Seed: Decodable, Sendable {
        let id: String
        let theme: String
        let surface: String
        let launchEnvironment: [String: String]
        let operatorInputRequired: Bool
    }
}

struct ThemeCanonicalCatalog: Decodable, Sendable {
    let schemaVersion: String
    let catalogID: String
    let candidateCount: Int
    let requiresFurtherOwnerInput: Bool
    let reuseRule: String
    let candidates: [Candidate]

    struct Candidate: Decodable, Sendable {
        let id: String
        let referenceAsset: String
        let referenceSHA256: String
        let referenceByteCount: Int
        let referenceDimensions: [Int]
        let evaluationKind: String
        let thresholdProfile: String
        let renderMode: ThemeCanonicalRenderMode
        let recipeClass: ThemeCanonicalRecipe
        let recipeNotes: String
        let surfaces: [String]
        let destinationsUsingResult: [String]
        let seedIDs: [String]
        let entryIDs: [String]
        let outputPath: String
        let requiredOutputDimensions: [Int]
        let comparisonMask: String?
        let host: Host
        let implementationConstraints: [String]
        let requiredCanonicalWrapperID: String
        let v42FormerCandidateBindings: [String]
        let v42FormerBindingKinds: [String]
        let productionSourceRequirements: [String]
    }

    struct Host: Decodable, Sendable {
        let locale: String
        let calendar: String
        let timeZone: String
        let colorScheme: String
        let dynamicType: String
        let displayScale: Double
        let animationsEnabled: Bool
        let safeAreaPolicy: String
        let backgroundPolicy: String
        let paddingPolicy: String
    }
}

struct ThemeCanonicalOutputRecorder {
    struct Sidecar: Codable, Equatable, Sendable {
        let schemaVersion: String
        let candidateID: String
        let wrapperID: String
        let sourceSHA: String
        let seedIDs: [String]
        let recipe: String
        let renderMode: String
        let width: Int
        let height: Int
        let resourceIDs: [String]
        let visualPlanRevision: UInt64
        let runtimeState: String
        let byteCount: Int
        let sha256: String
        let deterministicSHA256: String
        let outputPath: String
    }

    static func record(
        request: ThemeCanonicalRenderRequest,
        first: Data,
        second: Data,
        sourceSHA: String,
        visualPlanRevision: UInt64,
        runtimeState: String,
        outputRoot: URL
    ) throws -> Sidecar {
        let firstDigest = digest(first)
        let secondDigest = digest(second)
        guard firstDigest == secondDigest else {
            throw ThemeCanonicalRegistryError.invalidCatalog(
                "nondeterministic output \(request.candidateID)"
            )
        }
        let dimensions = try pngDimensions(first)
        guard dimensions.width == request.width, dimensions.height == request.height else {
            throw ThemeCanonicalRegistryError.invalidCatalog(
                "dimension mismatch \(request.candidateID)"
            )
        }
        let destination = outputRoot.appendingPathComponent(request.outputPath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try first.write(to: destination, options: .atomic)
        let sidecar = Sidecar(
            schemaVersion: "1.0",
            candidateID: request.candidateID,
            wrapperID: request.wrapperID,
            sourceSHA: sourceSHA,
            seedIDs: request.seedIDs,
            recipe: request.recipe.rawValue,
            renderMode: request.renderMode.rawValue,
            width: request.width,
            height: request.height,
            resourceIDs: request.expectedProductionResourceIDs,
            visualPlanRevision: visualPlanRevision,
            runtimeState: runtimeState,
            byteCount: first.count,
            sha256: firstDigest,
            deterministicSHA256: secondDigest,
            outputPath: request.outputPath
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let sidecarURL = destination.deletingPathExtension()
            .appendingPathExtension("sidecar.json")
        try encoder.encode(sidecar).write(to: sidecarURL, options: .atomic)
        return sidecar
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func pngDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ThemeCanonicalRegistryError.invalidCatalog("invalid PNG") }
        return (width, height)
    }
}

@MainActor
struct ThemeCanonicalQualificationHost {
    struct RenderedOutput: Sendable {
        let data: Data
        let width: Int
        let height: Int
        let resourceIDs: [String]
        let visualPlanRevision: UInt64
        let runtimeState: String
    }

    func render(
        _ view: AnyView,
        request: ThemeCanonicalRenderRequest,
        resourceIDs: [String],
        visualPlanRevision: UInt64,
        runtimeState: String
    ) throws -> RenderedOutput {
        guard request.width > 0, request.height > 0,
              request.locale == "en-US",
              request.timeZone == "UTC",
              request.colorScheme == "dark",
              request.dynamicType == "large",
              !request.themeID.isEmpty,
              !request.seedID.isEmpty
        else { throw ThemeCanonicalRegistryError.invalidCatalog(request.candidateID) }

        let content = try content(view, request: request)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(
            width: CGFloat(request.width),
            height: CGFloat(request.height)
        )
        renderer.scale = 1
        renderer.isOpaque = true

        let data: Data
        let width: Int
        let height: Int
        #if os(macOS)
        guard let image = renderer.cgImage else {
            throw ThemeCanonicalRegistryError.invalidCatalog("render failed")
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw ThemeCanonicalRegistryError.invalidCatalog("PNG destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ThemeCanonicalRegistryError.invalidCatalog("PNG finalize")
        }
        data = mutableData as Data
        width = image.width
        height = image.height
        #elseif os(iOS)
        guard let image = renderer.uiImage,
              let cgImage = image.cgImage,
              let png = image.pngData()
        else { throw ThemeCanonicalRegistryError.invalidCatalog("render failed") }
        data = png
        width = cgImage.width
        height = cgImage.height
        #endif

        guard width == request.width, height == request.height else {
            throw ThemeCanonicalRegistryError.invalidCatalog(
                "host dimension mismatch \(request.candidateID)"
            )
        }
        return RenderedOutput(
            data: data,
            width: width,
            height: height,
            resourceIDs: resourceIDs.sorted(),
            visualPlanRevision: visualPlanRevision,
            runtimeState: runtimeState
        )
    }

    func content(
        _ view: AnyView,
        request: ThemeCanonicalRenderRequest
    ) throws -> AnyView {
        guard request.width > 0, request.height > 0,
              request.locale == "en-US",
              request.timeZone == "UTC",
              request.colorScheme == "dark",
              request.dynamicType == "large",
              !request.themeID.isEmpty,
              !request.seedID.isEmpty
        else { throw ThemeCanonicalRegistryError.invalidCatalog(request.candidateID) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dimensionedView: AnyView
        if request.renderMode == .canonicalProductionComponent
            || request.renderMode == .resolvedResourceExport
        {
            dimensionedView = AnyView(
                view
                    .ignoresSafeArea()
                    .frame(
                        width: CGFloat(request.width),
                        height: CGFloat(request.height)
                    )
                    .clipped()
            )
        } else {
            dimensionedView = AnyView(
                view
                    .frame(
                        width: CGFloat(request.width),
                        height: CGFloat(request.height)
                    )
                    .clipped()
            )
        }
        let sizedView = dimensionedView
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(request.wrapperID)
            .runtimeViewportFrameProbe(request.wrapperID)
            .environment(\.locale, Locale(identifier: request.locale))
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .environment(\.dynamicTypeSize, .large)
            .environment(
                \.runtimeAccessibilityPreferences,
                RuntimeAccessibilityPreferences(
                    forcesReduceMotion: request.reduceMotion,
                    forcesIncreasedContrast: request.contrastMode == .increased
                )
            )
            .preferredColorScheme(.dark)
            .transaction { transaction in
                transaction.disablesAnimations = !request.animationsEnabled
                if !request.animationsEnabled {
                    transaction.animation = nil
                }
            }

        return AnyView(sizedView)
    }
}

final class ThemeCanonicalRenderCatalogTests: XCTestCase {
    func testCanonicalCatalogStrictlyDecodesAllSupportedWrappers() throws {
        let bundle = Bundle(for: Self.self)
        let registry = try ThemeCanonicalRenderRegistry.load(bundle: bundle)
        let seedRegistry = try ThemeCanonicalSeedRegistry.load(bundle: bundle)
        XCTAssertEqual(registry.catalog.candidates.count, 50)
        XCTAssertEqual(Set(registry.catalog.candidates.map(\.id)).count, 50)
        XCTAssertEqual(
            Set(registry.catalog.candidates.map(\.requiredCanonicalWrapperID)).count,
            50
        )
        XCTAssertEqual(
            registry.catalog.candidates.filter {
                $0.renderMode == .fullProductionScreen
            }.count,
            12
        )
        XCTAssertEqual(
            registry.catalog.candidates.filter {
                $0.renderMode == .canonicalProductionComponent
            }.count,
            32
        )
        XCTAssertEqual(
            registry.catalog.candidates.filter {
                $0.renderMode == .resolvedResourceExport
            }.count,
            6
        )
        let referencedSeedIDs = registry.catalog.candidates.flatMap(\.seedIDs)
        XCTAssertEqual(referencedSeedIDs.count, 115)
        XCTAssertEqual(Set(referencedSeedIDs).count, 71)
        XCTAssertEqual(
            ThemeCanonicalRenderRegistry.expectedReferenceIdentityByCandidate.count,
            50
        )
        XCTAssertEqual(Set(registry.catalog.candidates.map(\.recipeClass)), Set(
            ThemeCanonicalRecipe.allCases
        ))
        for candidate in registry.catalog.candidates {
            let request = try registry.request(
                candidateID: candidate.id,
                seedRegistry: seedRegistry
            )
            _ = try registry.productionBinding(candidateID: candidate.id)
            XCTAssertEqual(request.wrapperID, candidate.requiredCanonicalWrapperID)
            XCTAssertEqual(request.requiredCaptureElementIDs, [request.wrapperID])
            XCTAssertEqual(request.width, candidate.referenceDimensions[0])
            XCTAssertEqual(request.height, candidate.referenceDimensions[1])
            XCTAssertEqual(request.testClock.timeIntervalSince1970, 1_787_866_860)
            XCTAssertTrue(candidate.seedIDs.contains(request.seedID))
            XCTAssertEqual(
                try seedRegistry.seed(id: request.seedID).surface,
                candidate.recipeClass.preferredSurface
            )
            let environment = try seedRegistry.environment(
                seedID: request.seedID,
                destination: "iphone-portrait"
            )
            XCTAssertEqual(
                request.themeID,
                environment["RUNESCRIBE_QUALIFICATION_THEME_ID"]
            )
            XCTAssertEqual(
                request.codexID,
                environment["RUNESCRIBE_QUALIFICATION_CODEX_ID"]
            )
        }
    }

    func testCanonicalCatalogRejectsUnknownCandidate() throws {
        let bundle = Bundle(for: Self.self)
        let registry = try ThemeCanonicalRenderRegistry.load(bundle: bundle)
        let seedRegistry = try ThemeCanonicalSeedRegistry.load(bundle: bundle)
        XCTAssertThrowsError(try registry.request(
            candidateID: "canonical.unknown",
            seedRegistry: seedRegistry
        ))
    }

    func testCanonicalCatalogRejectsUnknownFields() throws {
        let data = Data("{\"candidates\":[],\"unexpected\":true}".utf8)
        XCTAssertThrowsError(try ThemeCanonicalRenderRegistry.decode(data: data)) { error in
            guard case ThemeCanonicalRegistryError.unknownKeys = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCanonicalSeedsCoverEveryCandidateWithoutOperatorInput() throws {
        let bundle = Bundle(for: Self.self)
        let registry = try ThemeCanonicalRenderRegistry.load(bundle: bundle)
        let seeds = try ThemeCanonicalSeedRegistry.load(bundle: bundle)
        XCTAssertEqual(seeds.catalog.seeds.count, 100)
        for candidate in registry.catalog.candidates {
            for seedID in candidate.seedIDs {
                let seed = try seeds.seed(id: seedID)
                XCTAssertTrue(candidate.surfaces.contains(seed.surface), seedID)
                let environment = try seeds.environment(
                    seedID: seedID,
                    destination: "macos-standard"
                )
                XCTAssertEqual(
                    environment["RUNESCRIBE_QUALIFICATION_DESTINATION"],
                    "macos-standard"
                )
            }
        }
    }

    func testCanonicalCatalogRejectsReferenceHashDrift() throws {
        var root = try canonicalCatalogJSONObject()
        var candidates = try XCTUnwrap(root["candidates"] as? [[String: Any]])
        let candidateID = try XCTUnwrap(candidates.first?["id"] as? String)
        candidates[0]["referenceSHA256"] = String(repeating: "0", count: 64)
        root["candidates"] = candidates

        XCTAssertThrowsError(try ThemeCanonicalRenderRegistry.decode(
            data: try JSONSerialization.data(withJSONObject: root)
        )) { error in
            XCTAssertEqual(
                error as? ThemeCanonicalRegistryError,
                .invalidCatalog("reference identity drift \(candidateID)")
            )
        }
    }

    func testCanonicalCatalogRejectsReferenceDimensionDrift() throws {
        var root = try canonicalCatalogJSONObject()
        var candidates = try XCTUnwrap(root["candidates"] as? [[String: Any]])
        let candidateID = try XCTUnwrap(candidates.first?["id"] as? String)
        let dimensions = try XCTUnwrap(candidates.first?["referenceDimensions"] as? [Int])
        let mutatedDimensions = [dimensions[0] + 1, dimensions[1]]
        candidates[0]["referenceDimensions"] = mutatedDimensions
        candidates[0]["requiredOutputDimensions"] = mutatedDimensions
        root["candidates"] = candidates

        XCTAssertThrowsError(try ThemeCanonicalRenderRegistry.decode(
            data: try JSONSerialization.data(withJSONObject: root)
        )) { error in
            XCTAssertEqual(
                error as? ThemeCanonicalRegistryError,
                .invalidCatalog("reference identity drift \(candidateID)")
            )
        }
    }

    func testResolvedResourceValidatorRejectsAlteredProductionBytes() throws {
        let original = Data("production-resource".utf8)
        let digest = SHA256.hash(data: original).map {
            String(format: "%02x", $0)
        }.joined()
        XCTAssertEqual(
            try ThemeCanonicalResolvedResourceValidator.validate(
                .resolvedProductionResource(original),
                candidateID: "canonical.resource",
                expectedByteCount: original.count,
                expectedSHA256: digest
            ),
            original
        )

        var altered = original
        altered[altered.startIndex] ^= 0x01
        XCTAssertThrowsError(try ThemeCanonicalResolvedResourceValidator.validate(
            .resolvedProductionResource(altered),
            candidateID: "canonical.resource",
            expectedByteCount: original.count,
            expectedSHA256: digest
        ))
    }

    func testResolvedResourceValidatorRejectsSystemSymbolSubstitution() {
        XCTAssertThrowsError(try ThemeCanonicalResolvedResourceValidator.validate(
            .systemSymbol("seal"),
            candidateID: "canonical.resource",
            expectedByteCount: 1,
            expectedSHA256: String(repeating: "0", count: 64)
        )) { error in
            XCTAssertEqual(
                error as? ThemeCanonicalRegistryError,
                .invalidCatalog("non-resource substitution canonical.resource")
            )
        }
    }

    private func canonicalCatalogJSONObject() throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(
            forResource: "Canonical-Render-Catalog-v1.3",
            withExtension: "json"
        ))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }
}
