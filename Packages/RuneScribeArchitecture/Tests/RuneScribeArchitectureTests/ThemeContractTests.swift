import CryptoKit
import Foundation
import RuneScribeContracts
import XCTest

final class ThemeContractTests: XCTestCase {
    func testCompleteDescriptorRoundTripsAndIsValueSemantic() throws {
        let descriptor = try makeDescriptor()
        let encoded = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(ThemeDescriptor.self, from: encoded)

        XCTAssertEqual(decoded, descriptor)
        XCTAssertEqual(Set([descriptor]).count, 1)
        XCTAssertEqual(decoded.codex.scripts.first?.glyphs.count, 32)
        XCTAssertEqual(
            Set(decoded.codex.scripts[0].glyphs.map(\.canonicalValue)),
            Set((0 ..< 32).map(UInt8.init))
        )
        XCTAssertEqual(Set(decoded.codex.palette.rarityAccents.map(\.rarity)), Set(ThemeRarityToken.allCases))
        requireSendable(decoded)
    }

    func testStableThemeIdentifiersRejectUnsafeSyntax() {
        XCTAssertNil(ThemeID(rawValue: "Theme.test"))
        XCTAssertNil(ThemeModuleID(rawValue: "theme/module"))
        XCTAssertNil(ThemeResourceID(rawValue: "resource_theme"))
        XCTAssertNil(ThemeGlyphID(rawValue: "glyph..test"))
        XCTAssertNotNil(ThemeID(rawValue: "theme.test"))
        XCTAssertNotNil(ThemeResourceID(rawValue: "resource.theme.test"))
    }

    func testDescriptorRejectsUnsupportedSchemaAndUIContracts() throws {
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var version = object["schemaVersion"] as! [String: Any]
                version["major"] = 2
                object["schemaVersion"] = version
            }
        )
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var version = object["minimumUIContractVersion"] as! [String: Any]
                version["major"] = 2
                object["minimumUIContractVersion"] = version
            }
        )
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var platforms = object["platformCompatibility"] as! [[String: Any]]
                platforms[0]["minimumMajorVersion"] = 0
                object["platformCompatibility"] = platforms
            }
        )
    }

    func testDescriptorRejectsDuplicateResourceAndArtifactIDs() throws {
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var resources = object["resources"] as! [[String: Any]]
                resources.append(resources[0])
                object["resources"] = resources
            }
        )

        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                let relics = codex["relics"] as! [[String: Any]]
                var seals = codex["seals"] as! [[String: Any]]
                let relicMetadata = relics[0]["metadata"] as! [String: Any]
                var sealMetadata = seals[0]["metadata"] as! [String: Any]
                sealMetadata["id"] = relicMetadata["id"]
                seals[0]["metadata"] = sealMetadata
                codex["seals"] = seals
                object["codex"] = codex
            }
        )
    }

    func testSemanticPaletteRejectsInsufficientTextAndFocusContrast() throws {
        for field in [
            "textPrimary",
            "textSecondary",
            "textInverse",
            "selected",
            "keyboardFocus",
        ] {
            XCTAssertThrowsError(
                try decodeDescriptor { object in
                    var codex = object["codex"] as! [String: Any]
                    var palette = codex["palette"] as! [String: Any]
                    palette[field] = field == "textInverse"
                        ? palette["accentPrimary"]
                        : palette["backgroundPrimary"]
                    codex["palette"] = palette
                    object["codex"] = codex
                },
                "Expected low-contrast \(field) to be rejected"
            )
        }
    }

    func testScriptRequiresExactlyOneMappingForEachCanonicalValue() throws {
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var scripts = codex["scripts"] as! [[String: Any]]
                var glyphs = scripts[0]["glyphs"] as! [[String: Any]]
                glyphs.removeLast()
                scripts[0]["glyphs"] = glyphs
                codex["scripts"] = scripts
                object["codex"] = codex
            }
        )

        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var scripts = codex["scripts"] as! [[String: Any]]
                var glyphs = scripts[0]["glyphs"] as! [[String: Any]]
                glyphs.swapAt(0, 1)
                scripts[0]["glyphs"] = glyphs
                codex["scripts"] = scripts
                object["codex"] = codex
            }
        )

        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var scripts = codex["scripts"] as! [[String: Any]]
                var glyphs = scripts[0]["glyphs"] as! [[String: Any]]
                glyphs[1]["canonicalValue"] = glyphs[0]["canonicalValue"]
                scripts[0]["glyphs"] = glyphs
                codex["scripts"] = scripts
                object["codex"] = codex
            }
        )
    }

    func testScriptUsesCanonicalRunicTransportTokensAndCompleteFontIdentity() throws {
        let script = try XCTUnwrap(makeDescriptor().codex.scripts.first)

        XCTAssertEqual(
            script.glyphs.map(\.textToken),
            (0 ..< ThemeCanonicalSymbolSet.symbolCount).map {
                String(UnicodeScalar(0x16A0 + $0)!)
            }
        )
        XCTAssertEqual(script.glyphs.first?.textToken, "\u{16A0}")
        XCTAssertEqual(script.glyphs.last?.textToken, "\u{16BF}")
        XCTAssertEqual(script.fontResourceID, resourceID("script.font"))
        XCTAssertEqual(script.fontReferenceID?.rawValue, "font-test")
        XCTAssertEqual(script.fontVersion, 1)
        XCTAssertEqual(script.fontPostScriptName?.rawValue, "RuneScribeTest-Regular")
    }

    func testScriptRejectsTransportTokenAndPartialFontIdentityMutations() throws {
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var scripts = codex["scripts"] as! [[String: Any]]
                var glyphs = scripts[0]["glyphs"] as! [[String: Any]]
                glyphs[0]["textToken"] = "\u{16A1}"
                scripts[0]["glyphs"] = glyphs
                codex["scripts"] = scripts
                object["codex"] = codex
            }
        )

        for field in [
            "fontResourceID",
            "fontReferenceID",
            "fontVersion",
            "fontPostScriptName",
        ] {
            XCTAssertThrowsError(
                try decodeDescriptor { object in
                    var codex = object["codex"] as! [String: Any]
                    var scripts = codex["scripts"] as! [[String: Any]]
                    scripts[0].removeValue(forKey: field)
                    codex["scripts"] = scripts
                    object["codex"] = codex
                },
                "Expected removal of \(field) to invalidate the font identity"
            )
        }

        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var scripts = codex["scripts"] as! [[String: Any]]
                scripts[0]["fontVersion"] = 0
                codex["scripts"] = scripts
                object["codex"] = codex
            }
        )
    }

    func testCoordinatorSnapshotEnforcesCrossFieldAndBaseIdentity() throws {
        let baseTheme = try makeDescriptor(
            codexRawValue: RuneScribeCodexIDs.norse.rawValue,
            moduleRawValue: RuneScribeModuleIDs.norseTheme.rawValue
        )
        let baseProvider = ThemeProviderSummaryDTO(
            codexID: RuneScribeCodexIDs.norse,
            moduleID: RuneScribeModuleIDs.norseTheme,
            displayName: "Norse",
            state: .available,
            isOwned: true,
            isSelectable: true,
            isSelected: true
        )

        let snapshot = try ThemeCoordinatorSnapshotDTO(
            revision: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            preferredCodexID: RuneScribeCodexIDs.norse,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            fallbackReason: .none,
            effectiveTheme: baseTheme,
            providers: [baseProvider]
        )
        XCTAssertEqual(snapshot.effectiveTheme.codex.id, snapshot.effectiveCodexID)
        XCTAssertEqual(snapshot.providers.first?.moduleID, RuneScribeModuleIDs.norseTheme)

        let otherCodexID = identifier(CodexID.self, "codex.other")
        XCTAssertThrowsError(
            try ThemeCoordinatorSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                preferredCodexID: otherCodexID,
                effectiveCodexID: otherCodexID,
                fallbackReason: .none,
                effectiveTheme: baseTheme,
                providers: [baseProvider]
            )
        ) { error in
            XCTAssertEqual(error as? ThemeCoordinatorContractError, .invalidEffectiveTheme)
        }

        let mismatchedProvider = ThemeProviderSummaryDTO(
            codexID: RuneScribeCodexIDs.norse,
            moduleID: RuneScribeModuleIDs.themeCoordinator,
            displayName: "Norse",
            state: .available,
            isOwned: true,
            isSelectable: true,
            isSelected: true
        )
        XCTAssertThrowsError(
            try ThemeCoordinatorSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                preferredCodexID: RuneScribeCodexIDs.norse,
                effectiveCodexID: RuneScribeCodexIDs.norse,
                fallbackReason: .none,
                effectiveTheme: baseTheme,
                providers: [mismatchedProvider]
            )
        ) { error in
            XCTAssertEqual(error as? ThemeCoordinatorContractError, .invalidSelectionState)
        }

        let customTheme = try makeDescriptor()
        let customProvider = ThemeProviderSummaryDTO(
            codexID: customTheme.codex.id,
            moduleID: identifier(ModuleIdentifier.self, customTheme.moduleID.rawValue),
            displayName: "Custom",
            state: .available,
            isOwned: true,
            isSelectable: true,
            isSelected: true
        )
        XCTAssertThrowsError(
            try ThemeCoordinatorSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                preferredCodexID: customTheme.codex.id,
                effectiveCodexID: customTheme.codex.id,
                fallbackReason: .none,
                effectiveTheme: customTheme,
                providers: [customProvider]
            )
        ) { error in
            XCTAssertEqual(error as? ThemeCoordinatorContractError, .missingBaseProvider)
        }
    }

    func testCoordinatorSnapshotEnforcesFallbackCrossFields() throws {
        let baseTheme = try makeDescriptor(
            codexRawValue: RuneScribeCodexIDs.norse.rawValue,
            moduleRawValue: RuneScribeModuleIDs.norseTheme.rawValue
        )
        let baseProvider = ThemeProviderSummaryDTO(
            codexID: RuneScribeCodexIDs.norse,
            moduleID: RuneScribeModuleIDs.norseTheme,
            displayName: "Norse",
            state: .available,
            isOwned: true,
            isSelectable: true,
            isSelected: true
        )
        let unavailableCodexID = identifier(CodexID.self, "codex.unavailable")

        XCTAssertNoThrow(
            try ThemeCoordinatorSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                preferredCodexID: nil,
                effectiveCodexID: RuneScribeCodexIDs.norse,
                fallbackReason: .missingPreference,
                effectiveTheme: baseTheme,
                providers: [baseProvider]
            )
        )
        XCTAssertNoThrow(
            try ThemeCoordinatorSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                preferredCodexID: unavailableCodexID,
                effectiveCodexID: RuneScribeCodexIDs.norse,
                fallbackReason: .unavailable,
                effectiveTheme: baseTheme,
                providers: [baseProvider]
            )
        )

        for invalid in [
            (preferred: nil, reason: ThemeSelectionFallbackReason.none),
            (preferred: RuneScribeCodexIDs.norse, reason: .missingPreference),
            (preferred: RuneScribeCodexIDs.norse, reason: .locked),
        ] {
            XCTAssertThrowsError(
                try ThemeCoordinatorSnapshotDTO(
                    revision: 1,
                    capturedAt: Date(timeIntervalSince1970: 1),
                    preferredCodexID: invalid.preferred,
                    effectiveCodexID: RuneScribeCodexIDs.norse,
                    fallbackReason: invalid.reason,
                    effectiveTheme: baseTheme,
                    providers: [baseProvider]
                )
            ) { error in
                XCTAssertEqual(error as? ThemeCoordinatorContractError, .invalidFallbackState)
            }
        }
    }

    func testResolvedThemeResourceValidatesLengthAndDigest() throws {
        let data = Data("resolved-theme-resource".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let integrity = try ThemeResourceIntegrity(
            sha256: try XCTUnwrap(ThemeSHA256Digest(rawValue: digest)),
            byteLength: UInt64(data.count)
        )
        let codexID = identifier(CodexID.self, "codex.test")
        let resolved = try ResolvedThemeResourceDTO(
            codexID: codexID,
            resourceID: resourceID("resolved"),
            role: identifier(ThemeResourceRoleID.self, "role.resolved"),
            mediaType: .json,
            integrity: integrity,
            verifiedSHA256: integrity.sha256,
            data: data
        )
        XCTAssertEqual(resolved.data, data)
        XCTAssertEqual(resolved.integrity, integrity)

        let wrongLength = try ThemeResourceIntegrity(
            sha256: integrity.sha256,
            byteLength: integrity.byteLength + 1
        )
        XCTAssertThrowsError(
            try ResolvedThemeResourceDTO(
                codexID: codexID,
                resourceID: resourceID("resolved"),
                role: identifier(ThemeResourceRoleID.self, "role.resolved"),
                mediaType: .json,
                integrity: wrongLength,
                verifiedSHA256: integrity.sha256,
                data: data
            )
        ) { error in
            XCTAssertEqual(error as? ThemeCoordinatorContractError, .resourceIntegrityMismatch)
        }

        let wrongDigest = try ThemeResourceIntegrity(
            sha256: ThemeSHA256Digest(rawValue: String(repeating: "0", count: 64))!,
            byteLength: UInt64(data.count)
        )
        XCTAssertThrowsError(
            try ResolvedThemeResourceDTO(
                codexID: codexID,
                resourceID: resourceID("resolved"),
                role: identifier(ThemeResourceRoleID.self, "role.resolved"),
                mediaType: .json,
                integrity: wrongDigest,
                verifiedSHA256: integrity.sha256,
                data: data
            )
        ) { error in
            XCTAssertEqual(error as? ThemeCoordinatorContractError, .resourceIntegrityMismatch)
        }
    }

    func testThemeResourceResolutionPurposeDefaultsActiveForLegacyPayloads() throws {
        let legacy = Data(
            #"{"codexID":"codex.test","resourceID":"resource.test.resolved"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            ResolveThemeResourceRequestDTO.self,
            from: legacy
        )
        XCTAssertEqual(decoded.purpose, .activePresentation)

        let catalog = ResolveThemeResourceRequestDTO(
            codexID: identifier(CodexID.self, "codex.test"),
            resourceID: resourceID("resolved"),
            purpose: .catalogPreview
        )
        let roundTrip = try JSONDecoder().decode(
            ResolveThemeResourceRequestDTO.self,
            from: JSONEncoder().encode(catalog)
        )
        XCTAssertEqual(roundTrip, catalog)
    }

    func testGeometryRejectsOutOfBoundsOrDegenerateValues() {
        XCTAssertThrowsError(
            try ThemeNormalizedRegion(x: 0.8, y: 0, width: 0.3, height: 1)
        )
        XCTAssertThrowsError(
            try ThemeNormalizedRegion(x: 0, y: 0, width: 0, height: 1)
        )
        XCTAssertThrowsError(try ThemeNormalizedPoint(x: -0.01, y: 0.5))
        XCTAssertThrowsError(try ThemeAspectRatio(width: 0, height: 1))
        XCTAssertThrowsError(try ThemePixelSize(width: 4097, height: 1))
        XCTAssertThrowsError(try ThemeScalarRange(minimum: 1, maximum: 0.5))
    }

    func testLayoutRejectsSealAnchorCentersInsideGlyphSafeRegion() throws {
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var relics = codex["relics"] as! [[String: Any]]
                var layouts = relics[0]["layouts"] as! [[String: Any]]
                var anchors = layouts[0]["sealAnchors"] as! [[String: Any]]
                anchors[0]["point"] = ["x": 0.5, "y": 0.4]
                layouts[0]["sealAnchors"] = anchors
                relics[0]["layouts"] = layouts
                codex["relics"] = relics
                object["codex"] = codex
            }
        )
    }

    func testDescriptorRejectsMissingDefaultsFallbacksAndAccessibility() throws {
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var relics = codex["relics"] as! [[String: Any]]
                relics[0]["isDefault"] = false
                codex["relics"] = relics
                object["codex"] = codex
            }
        )
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var scripts = codex["scripts"] as! [[String: Any]]
                scripts[0].removeValue(forKey: "staticFallbackResourceID")
                codex["scripts"] = scripts
                object["codex"] = codex
            }
        )
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                codex.removeValue(forKey: "accessibility")
                object["codex"] = codex
            }
        )
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var accessibility = codex["accessibility"] as! [String: Any]
                accessibility["noColorOnlyState"] = false
                codex["accessibility"] = accessibility
                object["codex"] = codex
            }
        )
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var accessibility = codex["accessibility"] as! [String: Any]
                accessibility["dynamicTypeSafe"] = false
                codex["accessibility"] = accessibility
                object["codex"] = codex
            }
        )
        XCTAssertThrowsError(
            try ThemeLocalizedText(
                key: identifier(ThemeLocalizationKey.self, "text.empty"),
                fallbackValue: "   "
            )
        )
    }

    func testDescriptorRejectsUnknownOrOptionalRequiredResources() throws {
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var background = codex["background"] as! [String: Any]
                background["staticBaseResourceID"] = "resource.missing"
                codex["background"] = background
                object["codex"] = codex
            }
        )
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var resources = object["resources"] as! [[String: Any]]
                let index = resources.firstIndex {
                    $0["id"] as? String == "resource.relic.primary"
                }!
                resources[index]["requirement"] = "optional"
                object["resources"] = resources
            }
        )
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var resources = object["resources"] as! [[String: Any]]
                resources[0]["rightsID"] = "rights.missing"
                object["resources"] = resources
            }
        )
    }

    func testSemanticResourceReuseAllowsOnlyExplicitlyCompatibleRoles() throws {
        let reusedThumbnail = try decodeDescriptor { object in
            var codex = object["codex"] as! [String: Any]
            var relics = codex["relics"] as! [[String: Any]]
            relics[0]["thumbnailResourceID"] = relics[0]["primaryResourceID"]
            codex["relics"] = relics
            object["codex"] = codex
        }
        XCTAssertEqual(
            reusedThumbnail.codex.relics[0].thumbnailResourceID,
            reusedThumbnail.codex.relics[0].primaryResourceID
        )

        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var relics = codex["relics"] as! [[String: Any]]
                let background = codex["background"] as! [String: Any]
                relics[0]["thumbnailResourceID"] = background["staticBaseResourceID"]
                codex["relics"] = relics
                object["codex"] = codex
            }
        ) { error in
            XCTAssertNotNil(error as? DecodingError)
        }
    }

    func testDescriptorBindsEverySemanticResourceFamilyToRoleAndMedia() throws {
        let mutations: [(resourceID: String, invalidMedia: String)] = [
            ("resource.script.font", ThemeResourceMediaType.json.rawValue),
            ("resource.script.static", ThemeResourceMediaType.ttf.rawValue),
            ("resource.relic.primary", ThemeResourceMediaType.json.rawValue),
            ("resource.seal.vector", ThemeResourceMediaType.json.rawValue),
            ("resource.frame.vector", ThemeResourceMediaType.json.rawValue),
            ("resource.crest.vector", ThemeResourceMediaType.json.rawValue),
            ("resource.background.static", ThemeResourceMediaType.mp4.rawValue),
            ("resource.vault.card", ThemeResourceMediaType.json.rawValue),
            ("resource.localization.en-us", ThemeResourceMediaType.mp4.rawValue),
        ]
        for mutation in mutations {
            XCTAssertThrowsError(
                try decodeDescriptor { object in
                    var resources = object["resources"] as! [[String: Any]]
                    let index = resources.firstIndex {
                        $0["id"] as? String == mutation.resourceID
                    }!
                    resources[index]["mediaType"] = mutation.invalidMedia
                    object["resources"] = resources
                },
                "Expected semantic media rejection for \(mutation.resourceID)"
            )
        }

        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var resources = object["resources"] as! [[String: Any]]
                let index = resources.firstIndex {
                    $0["id"] as? String == "resource.script.font"
                }!
                resources[index]["role"] = ThemeResourceRoles.relicMaster.rawValue
                object["resources"] = resources
            }
        )
    }

    func testDescriptorFreezesNorseFallbackAndRequiredBaseIdentity() throws {
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                object["fallbackCodexID"] = "codex.not-norse"
            }
        )

        let base = try makeDescriptor(
            codexRawValue: RuneScribeCodexIDs.norse.rawValue,
            moduleRawValue: RuneScribeModuleIDs.norseTheme.rawValue
        )
        for mutation: (inout [String: Any]) -> Void in [
            { $0["moduleRole"] = "runescribe.theme.wrong" },
            { object in
                var codex = object["codex"] as! [String: Any]
                codex["entitlementID"] = "unlock.codex.wrong"
                object["codex"] = codex
            },
        ] {
            XCTAssertThrowsError(try decodeDescriptor(base, mutating: mutation))
        }
    }

    func testDescriptorRejectsUnknownTopLevelFields() throws {
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                object["navigationDestination"] = "not-a-contract-field"
            }
        )
    }

    func testSealScaleReferenceIsRequired() throws {
        XCTAssertEqual(
            try makeDescriptor().codex.seals.first?.scaleReference,
            .relicShortEdge
        )
        XCTAssertThrowsError(
            try decodeDescriptor { object in
                var codex = object["codex"] as! [String: Any]
                var seals = codex["seals"] as! [[String: Any]]
                seals[0].removeValue(forKey: "scaleReference")
                codex["seals"] = seals
                object["codex"] = codex
            }
        )
    }

    func testContractSourceHasNoUIFrameworkDependency() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeContracts/ThemeContracts.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.hasPrefix("import Foundation\n"))
        XCTAssertFalse(source.contains("import SwiftUI"))
        XCTAssertFalse(source.contains("import UIKit"))
        XCTAssertFalse(source.contains("import AppKit"))
        XCTAssertFalse(source.contains("NavigationStack"))
        XCTAssertFalse(source.contains("NavigationLink"))
    }

    private func decodeDescriptor(
        mutating mutation: (inout [String: Any]) -> Void
    ) throws -> ThemeDescriptor {
        try decodeDescriptor(makeDescriptor(), mutating: mutation)
    }

    private func decodeDescriptor(
        _ source: ThemeDescriptor,
        mutating mutation: (inout [String: Any]) -> Void
    ) throws -> ThemeDescriptor {
        let encoded = try JSONEncoder().encode(source)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        mutation(&object)
        let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(ThemeDescriptor.self, from: mutated)
    }

    private func makeDescriptor(
        codexRawValue: String = "codex.test",
        moduleRawValue: String = "com.runescribe.theme.test"
    ) throws -> ThemeDescriptor {
        let codexID = identifier(CodexID.self, codexRawValue)
        let isBase = codexID == RuneScribeCodexIDs.norse
        let rightsID = identifier(ThemeProvenanceID.self, "rights.theme.test")
        let relicID = identifier(ArtifactID.self, "artifact.relic.test")
        let scriptID = identifier(ScriptID.self, "script.test")
        let fallbackScriptID = identifier(ScriptID.self, "script.base-runes")

        let glyphs = try (0 ..< 32).map { index in
            try ThemeScriptGlyph(
                canonicalValue: UInt8(index),
                glyphID: identifier(
                    ThemeGlyphID.self,
                    String(format: "glyph.test.%02d", index)
                ),
                textToken: String(UnicodeScalar(0x16A0 + index)!)
            )
        }
        let script = try ThemeScriptDescriptor(
            id: scriptID,
            displayName: localized("script.test.name", "Test Script"),
            portability: .fontDependent,
            glyphs: glyphs,
            fontResourceID: resourceID("script.font"),
            fontReferenceID: identifier(
                ThemeFontReferenceID.self,
                "font-test"
            ),
            fontVersion: 1,
            fontPostScriptName: ThemeFontPostScriptName(
                rawValue: "RuneScribeTest-Regular"
            ),
            staticFallbackResourceID: resourceID("script.static"),
            fallbackScriptID: fallbackScriptID,
            recommendedPointSizes: ThemeScalarRange(minimum: 12, maximum: 64),
            accessibility: accessibility("script.test", "Test script"),
            rightsID: rightsID
        )
        let layout = try ThemeShareLayoutPreset(
            id: identifier(ThemeLayoutPresetID.self, "layout.relic.test"),
            aspectRatio: ThemeAspectRatio(width: 4, height: 5),
            relicBounds: ThemeNormalizedRegion(x: 0, y: 0, width: 1, height: 1),
            contentSafeRegion: ThemeNormalizedRegion(x: 0.05, y: 0.05, width: 0.9, height: 0.85),
            glyphSafeRegion: ThemeNormalizedRegion(x: 0.1, y: 0.1, width: 0.8, height: 0.5),
            sealAnchors: [
                ThemeSealAnchor(
                    category: .lowerLeft,
                    point: try ThemeNormalizedPoint(x: 0.12, y: 0.82)
                ),
                ThemeSealAnchor(
                    category: .lowerRight,
                    point: try ThemeNormalizedPoint(x: 0.88, y: 0.82)
                ),
            ],
            maximumGlyphLines: 8,
            minimumGlyphScale: 0.5,
            overflowBehavior: .standardAlternate,
            attributionRegion: ThemeNormalizedRegion(x: 0.05, y: 0.92, width: 0.9, height: 0.05),
            provenanceRegion: ThemeNormalizedRegion(x: 0.05, y: 0.86, width: 0.4, height: 0.04),
            serialNumberRegion: ThemeNormalizedRegion(x: 0.55, y: 0.86, width: 0.4, height: 0.04),
            qrSafeRegion: ThemeNormalizedRegion(x: 0.75, y: 0.65, width: 0.15, height: 0.15),
            thumbnailCrop: ThemeNormalizedRegion(x: 0, y: 0, width: 1, height: 1)
        )
        let relic = try ThemeRelicDescriptor(
            metadata: artifactMetadata(
                id: relicID,
                codexID: codexID,
                nameKey: "relic.test",
                rightsID: rightsID
            ),
            isDefault: true,
            primaryResourceID: resourceID("relic.primary"),
            thumbnailResourceID: resourceID("relic.thumbnail"),
            staticFallbackResourceID: resourceID("relic.static"),
            highContrastResourceID: resourceID("relic.contrast"),
            defaultLayoutID: layout.id,
            layouts: [layout]
        )
        let seal = try ThemeSealDescriptor(
            metadata: artifactMetadata(
                id: identifier(ArtifactID.self, "artifact.seal.test"),
                codexID: codexID,
                nameKey: "seal.test",
                rightsID: rightsID
            ),
            vectorResourceID: resourceID("seal.vector"),
            monochromeFallbackResourceID: resourceID("seal.monochrome"),
            thumbnailResourceID: resourceID("seal.thumbnail"),
            allowedScale: ThemeScalarRange(minimum: 0.25, maximum: 1),
            scaleReference: .relicShortEdge,
            allowedAnchors: [.lowerLeft, .lowerRight]
        )
        let frame = try ThemeFrameDescriptor(
            metadata: artifactMetadata(
                id: identifier(ArtifactID.self, "artifact.frame.test"),
                codexID: codexID,
                nameKey: "frame.test",
                rightsID: rightsID
            ),
            vectorResourceID: resourceID("frame.vector"),
            staticFallbackResourceID: resourceID("frame.static"),
            compatibleRelicIDs: [relicID],
            allowsStaticShare: true
        )
        let crest = try ThemeCrestDescriptor(
            metadata: artifactMetadata(
                id: identifier(ArtifactID.self, "artifact.crest.test"),
                codexID: codexID,
                nameKey: "crest.test",
                rightsID: rightsID
            ),
            vectorResourceID: resourceID("crest.vector"),
            staticFallbackResourceID: resourceID("crest.static")
        )
        let background = try ThemeBackgroundDescriptor(
            id: identifier(ThemeBackgroundID.self, "background.test"),
            displayName: localized("background.test.name", "Test Background"),
            staticBaseResourceID: resourceID("background.static"),
            reduceMotionResourceID: resourceID("background.reduce"),
            highContrastResourceID: resourceID("background.contrast"),
            motionIntensity: .subtle,
            performanceClass: .standard,
            parallaxAllowed: true,
            accessibility: accessibility("background.test", "Test background"),
            rightsID: rightsID
        )
        let vault = try ThemeVaultDescriptor(
            id: identifier(ThemeVaultID.self, "vault.test"),
            grouping: localized("vault.test.grouping", "Test Collection"),
            cardResourceID: resourceID("vault.card"),
            lockedSilhouetteResourceID: resourceID("vault.locked"),
            encounteredResourceID: resourceID("vault.encountered"),
            selectedResourceID: resourceID("vault.selected"),
            accessibility: accessibility("vault.test", "Test collection"),
            rightsID: rightsID
        )
        let codex = try ThemeCodexDescriptor(
            id: codexID,
            entitlementID: isBase
                ? RuneScribeUnlockIDs.norseCodex
                : identifier(UnlockID.self, "unlock.codex.test"),
            displayName: localized("codex.test.name", "Test Codex"),
            shortDescription: localized("codex.test.short", "A test Codex."),
            longDescription: localized("codex.test.long", "A complete test Codex descriptor."),
            accessibility: accessibility("codex.test", "Test Codex"),
            palette: palette(),
            primaryScriptID: scriptID,
            fallbackScriptID: fallbackScriptID,
            defaultRelicID: relicID,
            scripts: [script],
            relics: [relic],
            seals: [seal],
            frames: [frame],
            crests: [crest],
            background: background,
            vault: vault,
            rightsID: rightsID
        )
        let localizationResource = resourceID("localization.en-us")
        let resourceNames = [
            "script.font", "script.static",
            "relic.primary", "relic.thumbnail", "relic.static", "relic.contrast",
            "seal.vector", "seal.monochrome", "seal.thumbnail",
            "frame.vector", "frame.static", "crest.vector", "crest.static",
            "background.static", "background.reduce", "background.contrast",
            "vault.card", "vault.locked", "vault.encountered", "vault.selected",
            "localization.en-us",
        ]
        let resources = try resourceNames.map { name in
            try resource(
                name,
                mediaType: name == "script.font" ? .ttf :
                    (name == "localization.en-us" ? .json :
                        (["seal.vector", "frame.vector", "crest.vector"].contains(name)
                            ? .pdf : .png)),
                rightsID: rightsID
            )
        }

        return try ThemeDescriptor(
            id: identifier(ThemeID.self, "theme.test"),
            moduleID: identifier(ThemeModuleID.self, moduleRawValue),
            moduleRole: identifier(
                ThemeModuleRoleID.self,
                isBase
                    ? RuneScribeRoles.norseTheme.rawValue
                    : "runescribe.theme.test"
            ),
            criticality: isBase ? .requiredBase : .optional,
            schemaVersion: ThemeContractVersion.current,
            contentVersion: 1,
            minimumUIContractVersion: ThemeContractVersion.current,
            platformCompatibility: [
                try ThemePlatformCompatibility(platform: .iOS, minimumMajorVersion: 17),
                try ThemePlatformCompatibility(platform: .macOS, minimumMajorVersion: 15),
            ],
            fallbackCodexID: RuneScribeCodexIDs.norse,
            codex: codex,
            resources: resources,
            localizations: [
                try ThemeLocalizationDescriptor(
                    localeIdentifier: "en-US",
                    stringsResourceID: localizationResource
                ),
            ],
            defaultLocaleIdentifier: "en-US",
            rights: [
                try ThemeRightsMetadata(
                    id: rightsID,
                    creatorTool: "Vector Editor",
                    creationDate: "2026-08-15",
                    origin: .original,
                    rightsOwner: "Raven Forge Studios",
                    sourceReference: "source/theme-test",
                    exportSettings: "deterministic-test-export",
                    licenseNotice: "All rights reserved."
                ),
            ]
        )
    }

    private func resource(
        _ name: String,
        mediaType: ThemeResourceMediaType,
        rightsID: ThemeProvenanceID
    ) throws -> ThemeResourceReference {
        try ThemeResourceReference(
            id: resourceID(name),
            role: resourceRole(for: name),
            mediaType: mediaType,
            requirement: .required,
            integrity: ThemeResourceIntegrity(
                sha256: ThemeSHA256Digest(rawValue: String(repeating: "a", count: 64))!,
                byteLength: 128
            ),
            rightsID: rightsID
        )
    }

    private func resourceRole(for name: String) -> ThemeResourceRoleID {
        switch name {
        case "script.font": ThemeResourceRoles.scriptFont
        case "script.static": ThemeResourceRoles.scriptStaticFallback
        case "relic.primary": ThemeResourceRoles.relicMaster
        case "relic.thumbnail": ThemeResourceRoles.relicThumbnail
        case "relic.static": ThemeResourceRoles.relicStaticShareFallback
        case "relic.contrast": ThemeResourceRoles.relicHighContrast
        case "seal.vector": ThemeResourceRoles.sealVectorMaster
        case "seal.monochrome": ThemeResourceRoles.sealMonochromeFallback
        case "seal.thumbnail": ThemeResourceRoles.sealThumbnail
        case "frame.vector": ThemeResourceRoles.frameVectorMaster
        case "frame.static": ThemeResourceRoles.frameStaticFallback
        case "crest.vector": ThemeResourceRoles.crestVectorMaster
        case "crest.static": ThemeResourceRoles.crestStaticFallback
        case "background.static": ThemeResourceRoles.backgroundStaticBase
        case "background.reduce": ThemeResourceRoles.backgroundReduceMotion
        case "background.contrast": ThemeResourceRoles.backgroundHighContrast
        case "vault.card": ThemeResourceRoles.vaultCard
        case "vault.locked": ThemeResourceRoles.vaultLockedSilhouette
        case "vault.encountered": ThemeResourceRoles.vaultEncountered
        case "vault.selected": ThemeResourceRoles.vaultSelected
        case "localization.en-us": ThemeResourceRoles.localizationStrings
        default: preconditionFailure("Unknown test Theme resource role: \(name)")
        }
    }

    private func artifactMetadata(
        id: ArtifactID,
        codexID: CodexID,
        nameKey: String,
        rightsID: ThemeProvenanceID
    ) throws -> ThemeArtifactMetadata {
        try ThemeArtifactMetadata(
            id: id,
            codexID: codexID,
            displayName: localized("\(nameKey).name", "Test Artifact"),
            description: localized("\(nameKey).description", "A test artifact."),
            rarity: .forged,
            availability: .included,
            accessibility: accessibility(nameKey, "Test artifact"),
            rightsID: rightsID
        )
    }

    private func accessibility(
        _ keyPrefix: String,
        _ fallback: String
    ) throws -> ThemeAccessibilityMetadata {
        try ThemeAccessibilityMetadata(
            label: localized("\(keyPrefix).accessibility-label", fallback),
            hint: localized("\(keyPrefix).accessibility-hint", "Displays \(fallback.lowercased()).")
        )
    }

    private func localized(_ key: String, _ fallback: String) throws -> ThemeLocalizedText {
        try ThemeLocalizedText(
            key: identifier(ThemeLocalizationKey.self, key),
            fallbackValue: fallback
        )
    }

    private func palette() throws -> ThemeSemanticPalette {
        let background = ThemeSemanticColor(rawValue: "#080A1E")!
        let surface = ThemeSemanticColor(rawValue: "#1A1E30")!
        let text = ThemeSemanticColor(rawValue: "#FFFFFF")!
        let textInverse = ThemeSemanticColor(rawValue: "#080A1E")!
        let accent = ThemeSemanticColor(rawValue: "#D4971A")!
        let focus = ThemeSemanticColor(rawValue: "#EEBE45")!
        let keyboardFocus = ThemeSemanticColor(rawValue: "#3A7FD5")!
        return try ThemeSemanticPalette(
            backgroundPrimary: background,
            backgroundSecondary: surface,
            surfacePrimary: surface,
            surfaceElevated: surface,
            textPrimary: text,
            textSecondary: text,
            textInverse: textInverse,
            accentPrimary: accent,
            accentSecondary: keyboardFocus,
            success: text,
            warning: accent,
            danger: text,
            information: keyboardFocus,
            locked: text,
            encountered: keyboardFocus,
            unavailable: text,
            selected: accent,
            focus: focus,
            keyboardFocus: keyboardFocus,
            rarityAccents: ThemeRarityToken.allCases.map {
                ThemeRarityAccent(rarity: $0, color: accent)
            }
        )
    }

    private func resourceID(_ suffix: String) -> ThemeResourceID {
        identifier(ThemeResourceID.self, "resource.\(suffix)")
    }

    private func identifier<ID: RawRepresentable>(
        _ type: ID.Type,
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ID where ID.RawValue == String {
        guard let result = ID(rawValue: value) else {
            XCTFail("Invalid test identifier: \(value)", file: file, line: line)
            fatalError("Invalid test identifier")
        }
        return result
    }

    private func requireSendable<Value: Sendable>(_: Value) {}
}
