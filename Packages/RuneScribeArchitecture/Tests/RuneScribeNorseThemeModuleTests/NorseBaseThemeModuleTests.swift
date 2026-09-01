import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeNorseThemeModule
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import XCTest

final class NorseBaseThemeModuleTests: XCTestCase {
    func testDiscoveryDescriptorPreservesFrozenBaseIdentityAndScript() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        XCTAssertEqual(descriptor, try NorseBaseThemeDescriptorFactory.make())
        XCTAssertEqual(descriptor.moduleID.rawValue, "com.runescribe.module.theme.norse")
        XCTAssertEqual(descriptor.moduleRole.rawValue, "runescribe.theme.norse")
        XCTAssertEqual(descriptor.policyClass.rawValue, "policy.theme-provider")
        XCTAssertEqual(descriptor.criticality, .requiredBase)
        XCTAssertEqual(descriptor.fallbackCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(descriptor.codex.id, RuneScribeCodexIDs.norse)
        XCTAssertEqual(descriptor.codex.entitlementID, RuneScribeUnlockIDs.norseCodex)

        let script = try XCTUnwrap(descriptor.codex.scripts.only)
        XCTAssertEqual(script.id.rawValue, "script.base-runes")
        XCTAssertEqual(script.portability, .unicodePortable)
        XCTAssertEqual(script.glyphs.map(\.canonicalValue), Array(0 ..< 32).map(UInt8.init))
        XCTAssertEqual(script.glyphs.map(\.textToken), ThemeCanonicalSymbolSet.transportTokens)
        XCTAssertEqual(
            script.glyphs.map { $0.glyphID.rawValue },
            (0 ..< 32).map { String(format: "glyph.base-runes.%02d", $0) }
        )
        XCTAssertEqual(script.fontReferenceID?.rawValue, "noto-sans-runic")
        XCTAssertEqual(script.fontVersion, 1)
        XCTAssertEqual(script.fontPostScriptName?.rawValue, "NotoSansRunic-Regular")

        XCTAssertEqual(
            descriptor.codex.relics.map { $0.metadata.id.rawValue },
            [
                "relic.norse.runestone-tablet",
                "relic.norse.dragonwood-plaque",
                "relic.norse.stormforged-stele",
            ]
        )
        XCTAssertEqual(
            descriptor.codex.seals.map { $0.metadata.id.rawValue },
            [
                "seal.norse.valknut",
                "seal.norse.ravenshield",
                "seal.norse.mjolnir",
                "seal.norse.wolkin",
                "seal.norse.yggdrasil",
                "seal.norse.berserk",
            ]
        )
        XCTAssertEqual(descriptor.codex.frames.map { $0.metadata.id.rawValue }, [
            "frame.norse.carved-knotwork",
        ])
        XCTAssertEqual(descriptor.codex.crests.map { $0.metadata.id.rawValue }, [
            "crest.norse.raven-mastery",
        ])
        XCTAssertEqual(
            descriptor.codex.relics.first?.metadata.availability,
            .included
        )
        XCTAssertNil(descriptor.codex.background.optionalMotionResourceID)
        XCTAssertNil(descriptor.codex.background.rendererParametersResourceID)
        XCTAssertEqual(
            descriptor.codex.background.macOSWideResourceID,
            NorseBaseThemeResourceIDs.backgroundMacOSWide
        )
        XCTAssertEqual(descriptor.resources.count, 70)
        XCTAssertEqual(
            descriptor.resources.filter { $0.requirement == .optional }.map(\.id.rawValue),
            []
        )
    }

    func testDiscoveryDescriptorMatchesApprovedNorseV2CatalogNamesAndStates() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor

        XCTAssertEqual(descriptor.id.rawValue, "theme.norse.base")
        XCTAssertEqual(descriptor.codex.displayName.fallbackValue, "Norse Codex")
        XCTAssertEqual(
            descriptor.codex.background.id.rawValue,
            "background.norse.cold-sea-hall"
        )
        XCTAssertEqual(
            descriptor.codex.background.displayName.fallbackValue,
            "Cold Sea and Ancient Hall"
        )
        XCTAssertEqual(
            descriptor.codex.relics.map(\.metadata.displayName.fallbackValue),
            ["Runestone Tablet", "Dragonwood Plaque", "Stormforged Stele"]
        )
        XCTAssertEqual(
            descriptor.codex.relics.map(\.metadata.description.fallbackValue),
            [
                "Weathered stone with carved runes and iron knotwork. The canonical Norse canvas.",
                "Dark dragonwood framed in forged iron. Ancient and resilient.",
                "Tall war-stele of stone and iron. Marked by storms and victories.",
            ]
        )
        XCTAssertEqual(
            descriptor.codex.relics.map(\.metadata.availability),
            [.included, .earned, .earned]
        )
        XCTAssertEqual(descriptor.codex.relics.map(\.isDefault), [true, false, false])
        XCTAssertEqual(
            descriptor.codex.seals.map(\.metadata.displayName.fallbackValue),
            [
                "Valknut Seal",
                "Ravenshield Seal",
                "Mjolnir Seal",
                "Wolkin Seal",
                "Yggdrasil Seal",
                "Berserk Seal",
            ]
        )
        XCTAssertEqual(
            descriptor.codex.seals.map(\.metadata.availability),
            [.included, .included, .earned, .earned, .earned, .earned]
        )
        XCTAssertEqual(
            descriptor.codex.frames.only?.metadata.displayName.fallbackValue,
            "Norse Mastery Frame"
        )
        XCTAssertEqual(
            descriptor.codex.crests.only?.metadata.displayName.fallbackValue,
            "Raven Mastery Crest"
        )

        let currentArtifactIDs = Set(
            descriptor.codex.relics.map(\.metadata.id.rawValue)
                + descriptor.codex.seals.map(\.metadata.id.rawValue)
                + descriptor.codex.frames.map(\.metadata.id.rawValue)
                + descriptor.codex.crests.map(\.metadata.id.rawValue)
        )
        XCTAssertTrue(currentArtifactIDs.isDisjoint(with: [
            "relic.norse.runestone.weathered",
            "relic.norse.raven-medallion",
            "relic.norse.ironbound-shield",
            "relic.norse.sealed-parchment",
            "relic.norse.runestone.blackstone",
            "relic.norse.runestone.frozen",
            "seal.norse.knotwork",
            "seal.norse.forge-flame",
            "seal.norse.raven",
            "seal.norse.longship",
            "seal.norse.forge-hammer",
            "seal.norse.echo-rune",
            "crest.norse.forge-master",
        ]))
    }

    func testDiscoveryDescriptorUsesExactSemanticResourceBindings() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let resources = Dictionary(uniqueKeysWithValues: descriptor.resources.map { ($0.id, $0) })
        let script = try XCTUnwrap(descriptor.codex.scripts.only)

        assertResource(script.fontResourceID, role: ThemeResourceRoles.scriptFont, media: .ttf, in: resources)
        assertResource(
            script.staticFallbackResourceID,
            role: ThemeResourceRoles.scriptStaticFallback,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.background.staticBaseResourceID,
            role: ThemeResourceRoles.backgroundStaticBase,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.background.reduceMotionResourceID,
            role: ThemeResourceRoles.backgroundReduceMotion,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.background.highContrastResourceID,
            role: ThemeResourceRoles.backgroundHighContrast,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.background.macOSWideResourceID,
            role: ThemeResourceRoles.backgroundMacOSWideCrop,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.vault.cardResourceID,
            role: ThemeResourceRoles.vaultCard,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.vault.lockedSilhouetteResourceID,
            role: ThemeResourceRoles.vaultLockedSilhouette,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.vault.encounteredResourceID,
            role: ThemeResourceRoles.vaultEncountered,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.vault.selectedResourceID,
            role: ThemeResourceRoles.vaultSelected,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.vault.unavailableResourceID,
            role: ThemeResourceRoles.vaultUnavailable,
            media: .png,
            in: resources
        )
        for relic in descriptor.codex.relics {
            assertResource(relic.primaryResourceID, role: ThemeResourceRoles.relicMaster, media: .png, in: resources)
            XCTAssertNotEqual(relic.thumbnailResourceID, relic.primaryResourceID)
            assertResource(relic.thumbnailResourceID, role: ThemeResourceRoles.relicThumbnail, media: .png, in: resources)
            assertResource(
                relic.staticFallbackResourceID,
                role: ThemeResourceRoles.relicStaticShareFallback,
                media: .png,
                in: resources
            )
            assertResource(
                relic.highContrastResourceID,
                role: ThemeResourceRoles.relicHighContrast,
                media: .png,
                in: resources
            )
        }
        for seal in descriptor.codex.seals {
            let colorResourceID = try XCTUnwrap(seal.colorResourceID)
            assertResource(colorResourceID, role: ThemeResourceRoles.sealColorMaster, media: .png, in: resources)
            XCTAssertEqual(seal.standardResourceID, colorResourceID)
            XCTAssertNil(seal.vectorResourceID)
            XCTAssertNotEqual(seal.monochromeFallbackResourceID, seal.thumbnailResourceID)
            assertResource(
                seal.monochromeFallbackResourceID,
                role: ThemeResourceRoles.sealMonochromeFallback,
                media: .png,
                in: resources
            )
            assertResource(seal.thumbnailResourceID, role: ThemeResourceRoles.sealThumbnail, media: .png, in: resources)
        }
        let localization = try XCTUnwrap(descriptor.localizations.only)
        assertResource(
            localization.stringsResourceID,
            role: ThemeResourceRoles.localizationStrings,
            media: .json,
            in: resources
        )
        assertResource(
            NorseBaseThemeResourceIDs.scriptMapping,
            role: ThemeResourceRoleID(rawValue: "script.mapping")!,
            media: .json,
            in: resources
        )
        let font = try XCTUnwrap(resources[NorseBaseThemeResourceIDs.font])
        XCTAssertEqual(
            font.integrity.sha256.rawValue,
            "615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b"
        )
        XCTAssertEqual(font.integrity.byteLength, 55_800)
    }

    func testManifestResourcesAndCopiedFontRemainExact() throws {
        let bundle = RuneScribeNorseThemeModuleBootstrap.resourceBundle
        let manifestURL = try XCTUnwrap(
            bundle.url(forResource: "module-manifest", withExtension: "json")
        )
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try ModuleManifestDecoder.decode(manifestData)
        XCTAssertEqual(manifest.moduleID, RuneScribeModuleIDs.norseTheme)
        XCTAssertEqual(manifest.defaultRole, RuneScribeRoles.norseTheme)
        XCTAssertEqual(manifest.effectivePolicyClass, RuneScribePolicyClasses.themeProvider)
        XCTAssertEqual(manifest.criticality, .required)
        XCTAssertEqual(manifest.entitlementRequirement?.kind, .always)
        XCTAssertEqual(manifest.entitlementRequirement?.identifier, RuneScribeUnlockIDs.norseCodex)
        XCTAssertEqual(
            Set(manifest.runtimeRequirements.requiredResources),
            NorseBaseBundledResourceCatalog.all
        )
        XCTAssertEqual(NorseApplicationResourceCatalog.resourcesByHandle.count, 70)
        XCTAssertEqual(
            Set(NorseApplicationResourceCatalog.resourcesByHandle.values),
            Set(NorseBaseThemeResourceCatalog.definitions.map(\.resource))
        )
        XCTAssertEqual(
            sha256Hex(manifestData),
            RuneScribeNorseThemeModuleBootstrap.manifestExpectedSHA256Hex
        )
        let copiedFontURL = try XCTUnwrap(
            bundle.url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
        )
        let copiedFont = try Data(contentsOf: copiedFontURL)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let legacyFont = repositoryRoot
            .appendingPathComponent("RuneScrib/Resources/Fonts/NotoSansRunic-Regular.ttf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFont.path))
        XCTAssertEqual(
            sha256Hex(copiedFont),
            "615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b"
        )
    }

    func testProductionProvenanceCoversEveryShippingThemeResource() throws {
        let bundle = RuneScribeNorseThemeModuleBootstrap.resourceBundle
        let provenanceURL = try XCTUnwrap(
            bundle.url(
                forResource: "Norse-Production-Asset-Provenance-v2.0",
                withExtension: "json"
            )
        )
        let data = try Data(contentsOf: provenanceURL)
        XCTAssertEqual(data.count, 82_579)
        XCTAssertEqual(
            sha256Hex(data),
            "810126e4109dc5686cf0dd9b1c38d9cc13bf6f76c5e0eceb108db2d6e9ed3175"
        )

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["schemaVersion"] as? String, "2.0")
        XCTAssertEqual(root["resourceCount"] as? Int, 70)
        let authority = try XCTUnwrap(
            root["authority"] as? [String: Any]
        )
        XCTAssertEqual(
            authority["scope"] as? String,
            "Norse v2 production resources under v4.3 local qualification"
        )
        XCTAssertEqual(authority["publicDistributionAuthorized"] as? Bool, false)
        let rightsSources = try XCTUnwrap(root["rightsSources"] as? [[String: Any]])
        XCTAssertEqual(
            Set(rightsSources.compactMap { $0["statementReference"] as? String }),
            [
                "EULA.md#4-ownership-and-intellectual-property",
                "RuneScrib/Resources/Fonts/OFL.txt",
            ]
        )
        let resources = try XCTUnwrap(root["resources"] as? [[String: Any]])
        XCTAssertEqual(resources.count, 70)
        XCTAssertEqual(
            Set(resources.compactMap { $0["resourceID"] as? String }),
            Set(NorseApplicationResourceCatalog.resourcesByHandle.keys)
        )
        XCTAssertTrue(resources.allSatisfy { resource in
            resource["qualificationStatus"] as? String == "local-qualification-candidate"
                && resource["activeInCurrentCatalog"] as? Bool == true
                && (resource["normalizedProductionPath"] as? String)?.isEmpty == false
                && (resource["sha256"] as? String)?.count == 64
                && (resource["byteCount"] as? Int ?? 0) > 0
                && (resource["rightsProvenanceID"] as? String)?.isEmpty == false
                && (resource["licenseOrOwnershipStatementReference"] as? String)?.isEmpty
                    == false
                && (resource["accessibilityDescriptionKey"] as? String)?.isEmpty == false
        })
    }

    func testApprovedNorseSealColorMastersRetainExactAuthorityBytes() throws {
        struct ExpectedSeal {
            let sha256: String
            let width: UInt32
            let height: UInt32
        }

        let expected: [String: ExpectedSeal] = [
            "seal.norse.berserk": .init(
                sha256: "9594aeec80db4e554461374690365bf0d932b251873aacf055072bb18992c996",
                width: 1_024,
                height: 981
            ),
            "seal.norse.mjolnir": .init(
                sha256: "db76bb110f59353341e698b55a7c4884c9ead1ad091751f7e89b7970356324de",
                width: 1_003,
                height: 1_024
            ),
            "seal.norse.ravenshield": .init(
                sha256: "59dd542f4e79854e3d979ae002a04f422844db385812ae52e4ca28d66d9e5292",
                width: 1_024,
                height: 1_015
            ),
            "seal.norse.valknut": .init(
                sha256: "5e6c584ed9825316f964e87277fa02f9e493ca6201e17a5278952a4f5c4f7e30",
                width: 1_015,
                height: 1_024
            ),
            "seal.norse.wolkin": .init(
                sha256: "61acc4bf6bb77396f3dde400f0b55518e946454f0f1df3717ecc435530e6d87e",
                width: 1_013,
                height: 1_024
            ),
            "seal.norse.yggdrasil": .init(
                sha256: "2f8593cd6b23d18f92666a2abd7c707ec045116efc99fafbb5d8dff0205e094b",
                width: 1_024,
                height: 991
            ),
        ]
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let resources = Dictionary(uniqueKeysWithValues: descriptor.resources.map { ($0.id, $0) })
        let definitions = Dictionary(
            uniqueKeysWithValues: NorseBaseThemeResourceCatalog.definitions.map { ($0.id, $0) }
        )

        XCTAssertEqual(Set(descriptor.codex.seals.map(\.metadata.id.rawValue)), Set(expected.keys))
        for seal in descriptor.codex.seals {
            let authority = try XCTUnwrap(expected[seal.metadata.id.rawValue])
            let colorResourceID = try XCTUnwrap(seal.colorResourceID)
            let reference = try XCTUnwrap(resources[colorResourceID])
            let definition = try XCTUnwrap(definitions[colorResourceID])
            let data = try bundledData(definition.resource)

            XCTAssertEqual(reference.role, ThemeResourceRoles.sealColorMaster)
            XCTAssertEqual(reference.integrity.sha256.rawValue, authority.sha256)
            XCTAssertEqual(reference.integrity.pixelSize?.width, authority.width)
            XCTAssertEqual(reference.integrity.pixelSize?.height, authority.height)
            XCTAssertEqual(sha256Hex(data), authority.sha256)
        }
    }

    func testRuntimePublishesExactDiscoveryAndVerifiedOpaquePayloads() async throws {
        let probe = NorsePublicationProbe()
        let runtime = RuneScribeRuntime(
            runtimeVersion: Self.version,
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { Date(timeIntervalSince1970: 1_776_211_200) },
                nextUUID: {
                    UUID(uuidString: "00000000-0000-0000-0000-000000000411")!
                }
            )
        )
        defer { Task { await runtime.stop() } }
        try await runtime.installPlatformAdapter(
            NorsePositiveBundleResourceLocator(),
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)

        let coordinator = positiveCoordinatorDescriptor()
        let ui = positiveUIDescriptor(requiredRole: coordinator.role)
        try await runtime.register(
            manifest: manifest(for: coordinator),
            factory: AnyModuleFactory(descriptor: coordinator) {
                NorsePositiveTestModule(descriptor: coordinator) { context in
                    let reader = try await context.contributionReaderClient()
                    let resolver = try await context.opaqueResourceResolverClient()
                    let contributions = try await reader.snapshot(
                        for: RuntimeThemeContributionCatalog.descriptor
                    )
                    let resourceSnapshot = try await resolver.snapshot()
                    var resolved: [OpaqueResourceHandle: ResolvedOpaqueResource] = [:]
                    for resource in resourceSnapshot.resources {
                        resolved[resource.handle] = try await resolver.resolve(resource.handle)
                    }
                    await probe.capture(
                        contributions: contributions,
                        resources: resourceSnapshot,
                        resolved: resolved
                    )
                }
            }
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                NorsePositiveTestModule(descriptor: ui) { _ in }
            }
        )

        try await runtime.start()
        let capturedValue = await probe.value()
        let captured = try XCTUnwrap(capturedValue)
        let entry = try XCTUnwrap(captured.contributions.entries.only)
        XCTAssertEqual(entry.owner.moduleID, RuneScribeModuleIDs.norseTheme)
        XCTAssertEqual(entry.value, RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor)

        let descriptor = entry.value
        XCTAssertEqual(captured.resources.resources.count, descriptor.resources.count)
        XCTAssertEqual(captured.resolved.count, descriptor.resources.count)
        for reference in descriptor.resources {
            let handle = OpaqueResourceHandle(
                namespace: RuntimeThemeContributionCatalog.resourceNamespace(for: descriptor.codex.id),
                resourceID: OpaqueResourceID(rawValue: reference.id.rawValue)
            )
            let resource = try XCTUnwrap(captured.resolved[handle])
            XCTAssertEqual(resource.metadata.ownerModuleID, RuneScribeModuleIDs.norseTheme)
            XCTAssertEqual(resource.metadata.semanticRole, reference.role.rawValue)
            XCTAssertEqual(resource.metadata.mediaType.rawValue, reference.mediaType.rawValue)
            XCTAssertEqual(resource.metadata.byteCount, Int(reference.integrity.byteLength))
            XCTAssertEqual(resource.metadata.sha256, reference.integrity.sha256.rawValue)
            XCTAssertEqual(resource.data.count, Int(reference.integrity.byteLength))
            XCTAssertEqual(sha256Hex(resource.data), reference.integrity.sha256.rawValue)
        }
        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
    }

    func testProductionResourcesPassPhysicalBudgetsWithoutChargingLogicalReuseTwice() throws {
        let bundle = RuneScribeNorseThemeModuleBootstrap.resourceBundle
        var payloads: [ApplicationResource: Data] = [:]
        for definition in NorseBaseThemeResourceCatalog.definitions {
            guard payloads[definition.resource] == nil else { continue }
            let url = try XCTUnwrap(bundle.url(
                forResource: definition.resource.name,
                withExtension: definition.resource.fileExtension
            ))
            payloads[definition.resource] = try Data(contentsOf: url)
        }
        let report = try NorseBaseThemeResources.budgetReport(
            physicalPayloads: payloads
        )
        XCTAssertEqual(report.uniquePhysicalBytes, 86_409_000)
        XCTAssertEqual(report.staticImageBytes, 84_989_635)
        XCTAssertEqual(report.fontBytes, 55_800)
        XCTAssertEqual(report.animationBytes, 3_279)
        XCTAssertEqual(report.soundBytes, 1_334_576)
        XCTAssertEqual(report.largestResourceBytes, 7_462_801)
    }

    func testBundledNorseV2ResourcesLoadAsOneValidatedRevision() async throws {
        let bundledResources = try bundledResourceData()
        let runtimeIO = RuntimeIOClient(
            readVerifiedApplicationResource: { resource, _, _ in
                guard let data = bundledResources[resource] else {
                    throw RuntimeVerifiedApplicationResourceFailure.resourceUnavailable
                }
                return data
            }
        )

        let validated = try await NorseBaseThemeResources.loadValidated(using: runtimeIO)

        XCTAssertEqual(validated.descriptor.contentVersion, 2)
        XCTAssertEqual(validated.resourcePayloads.count, 70)
    }

    func testProgressionBindingsUseOnlyLiveAchievementIdentifiers() throws {
        let bindingsURL = try XCTUnwrap(
            RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                forResource: "Norse-Progression-Bindings-v2.0",
                withExtension: "json"
            )
        )
        let bindingsRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: bindingsURL)
            ) as? [String: Any]
        )
        let grants = try XCTUnwrap(bindingsRoot["grants"] as? [[String: Any]])
        let boundAchievements = Set(
            grants.compactMap { $0["trigger"] as? String }
                .filter { $0.hasPrefix("achievement.") }
        )

        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        let progressionURL = repositoryRoot.appendingPathComponent(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/Resources/Rune-Scribe-Progression-Catalog-v1.0.json"
        )
        let progressionRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: progressionURL)
            ) as? [String: Any]
        )
        let achievements = try XCTUnwrap(
            progressionRoot["achievements"] as? [[String: Any]]
        )
        let liveAchievementIDs = Set(
            achievements.compactMap { $0["achievementID"] as? String }
        )

        XCTAssertTrue(boundAchievements.isSubset(of: liveAchievementIDs))
        XCTAssertEqual(boundAchievements.count, 7)
        XCTAssertTrue(
            boundAchievements.isDisjoint(with: [
                "achievement.the-correspondent",
                "achievement.courier-i",
                "achievement.courier-ii",
                "achievement.archivist-i",
                "achievement.archivist-ii",
            ])
        )
    }

    func testRequiredResourceReadFailureRetainsStructuredIdentity() async throws {
        let manifestData = try bundledData(
            NorseBaseBundledResourceCatalog.integrityManifest
        )
        let runtimeIO = RuntimeIOClient(
            readVerifiedApplicationResource: { resource, _, _ in
                if resource == NorseBaseBundledResourceCatalog.integrityManifest {
                    return manifestData
                }
                throw RuntimeVerifiedApplicationResourceFailure.resourceUnavailable
            }
        )

        do {
            _ = try await NorseBaseThemeResources.loadValidated(using: runtimeIO)
            XCTFail("A missing required resource must activate structured fallback.")
        } catch let failure as RequiredThemeResourceFailureDTO {
            XCTAssertEqual(failure.moduleID, RuneScribeModuleIDs.norseTheme)
            XCTAssertEqual(failure.codexID, RuneScribeCodexIDs.norse)
            XCTAssertEqual(failure.stage, .resourceRead)
            XCTAssertNotNil(failure.resourceID)
            XCTAssertEqual(failure.errorCode, .resourceUnavailable)
            XCTAssertNotNil(failure.expectedByteCount)
            XCTAssertNotNil(failure.expectedSHA256)
            XCTAssertNotNil(failure.mediaType)
        }
    }

    func testRequiredResourceDigestFailureRetainsExpectedAndActualDetails() async throws {
        let target = try XCTUnwrap(
            NorseBaseThemeResourceCatalog.definitions.first(where: {
                $0.requirement == .required
            })
        )
        let bundledResources = try bundledResourceData()
        let actualDigest = Data(repeating: 0xA7, count: SHA256.Digest.byteCount)
        let runtimeIO = RuntimeIOClient(
            readVerifiedApplicationResource: { resource, _, _ in
                if resource == target.resource {
                    throw RuntimeVerifiedApplicationResourceFailure.integrityMismatch(
                        actualSHA256: actualDigest,
                        actualByteCount: target.byteCount
                    )
                }
                guard let data = bundledResources[resource] else {
                    throw RuntimeVerifiedApplicationResourceFailure.resourceUnavailable
                }
                return data
            }
        )

        do {
            _ = try await NorseBaseThemeResources.loadValidated(using: runtimeIO)
            XCTFail("A digest mismatch must activate structured fallback.")
        } catch let failure as RequiredThemeResourceFailureDTO {
            XCTAssertEqual(failure.stage, .digest)
            XCTAssertNotNil(failure.resourceID)
            XCTAssertEqual(failure.errorCode, .digestMismatch)
            XCTAssertNotNil(failure.expectedSHA256)
            XCTAssertEqual(
                failure.actualSHA256?.rawValue,
                actualDigest.map { String(format: "%02x", $0) }.joined()
            )
            XCTAssertEqual(failure.actualByteCount, UInt64(target.byteCount))
        }
    }

    func testRequiredResourceByteCountFailureIsNotMisclassifiedAsDigest() async throws {
        let target = try XCTUnwrap(
            NorseBaseThemeResourceCatalog.definitions.first(where: {
                $0.requirement == .required
            })
        )
        let bundledResources = try bundledResourceData()
        let actualDigest = Data(repeating: 0xB4, count: SHA256.Digest.byteCount)
        let actualByteCount = target.byteCount + 1
        let runtimeIO = RuntimeIOClient(
            readVerifiedApplicationResource: { resource, _, _ in
                if resource == target.resource {
                    throw RuntimeVerifiedApplicationResourceFailure.integrityMismatch(
                        actualSHA256: actualDigest,
                        actualByteCount: actualByteCount
                    )
                }
                guard let data = bundledResources[resource] else {
                    throw RuntimeVerifiedApplicationResourceFailure.resourceUnavailable
                }
                return data
            }
        )

        do {
            _ = try await NorseBaseThemeResources.loadValidated(using: runtimeIO)
            XCTFail("A byte-count mismatch must activate structured fallback.")
        } catch let failure as RequiredThemeResourceFailureDTO {
            XCTAssertEqual(failure.stage, .byteCount)
            XCTAssertEqual(failure.resourceID, target.id)
            XCTAssertEqual(failure.errorCode, .byteCountMismatch)
            XCTAssertEqual(failure.expectedByteCount, UInt64(target.byteCount))
            XCTAssertEqual(failure.actualByteCount, UInt64(actualByteCount))
            XCTAssertEqual(
                failure.actualSHA256?.rawValue,
                actualDigest.map { String(format: "%02x", $0) }.joined()
            )
        }
    }

    func testEveryNorseV2ResourceIsRequiredForTheCurrentCatalog() throws {
        let optionalDefinitions = NorseBaseThemeResourceCatalog.definitions.filter {
            $0.requirement == .optional
        }
        XCTAssertTrue(optionalDefinitions.isEmpty)
        XCTAssertEqual(NorseBaseThemeResourceCatalog.definitions.count, 70)
        XCTAssertEqual(
            Set(NorseBaseThemeResourceCatalog.definitions.map(\.id)),
            Set(RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor.resources.map(\.id))
        )
    }

    func testUnlockSoundsUseTheRuntimeSemanticRoleContract() {
        let sounds = NorseBaseThemeResourceCatalog.definitions.filter {
            $0.mediaType == .wav
        }

        XCTAssertEqual(sounds.count, 4)
        XCTAssertEqual(Set(sounds.map(\.role)), [ThemeResourceRoles.unlockSound])
        XCTAssertEqual(
            Set(sounds.map { $0.id.rawValue }),
            [
                "resource.sound.norse.unlock-minor",
                "resource.sound.norse.unlock-relic",
                "resource.sound.norse.unlock-codex",
                "resource.sound.norse.unlock-mastery",
            ]
        )
    }

    func testCancellationFromManifestOrRequiredResourceReadPropagates() async throws {
        enum Scenario: CaseIterable, Equatable { case manifest, requiredResource }

        let required = try XCTUnwrap(
            NorseBaseThemeResourceCatalog.definitions.first(where: {
                $0.requirement == .required
            })
        )
        let bundledResources = try bundledResourceData()

        for scenario in Scenario.allCases {
            let runtimeIO = RuntimeIOClient(
                readVerifiedApplicationResource: { resource, _, _ in
                    if scenario == .manifest,
                       resource == NorseBaseBundledResourceCatalog.integrityManifest {
                        throw CancellationError()
                    }
                    if scenario == .requiredResource, resource == required.resource {
                        throw CancellationError()
                    }
                    guard let data = bundledResources[resource] else {
                        throw RuntimeVerifiedApplicationResourceFailure.resourceUnavailable
                    }
                    return data
                }
            )

            do {
                _ = try await NorseBaseThemeResources.loadValidated(using: runtimeIO)
                XCTFail("Cancellation must not be translated into a resource failure.")
            } catch is CancellationError {
                continue
            } catch {
                XCTFail("Expected CancellationError for \(scenario), received \(error).")
            }
        }
    }

    func testRequiredResourceMediaMetadataFailureIsStructured() throws {
        let definition = try XCTUnwrap(
            NorseBaseThemeResourceCatalog.definitions.first(where: {
                $0.id == NorseBaseThemeResourceIDs.backgroundStatic
            })
        )
        var data = try bundledData(definition.resource)
        data[16] = 0
        data[17] = 0
        data[18] = 0
        data[19] = 1

        XCTAssertThrowsError(
            try NorseBaseThemeResources.validateMediaMetadata(
                data,
                definition: definition
            )
        ) { error in
            guard let failure = error as? RequiredThemeResourceFailureDTO else {
                return XCTFail("Expected a structured required-resource failure.")
            }
            XCTAssertEqual(failure.stage, .mediaMetadata)
            XCTAssertEqual(failure.resourceID, definition.id)
            XCTAssertEqual(failure.errorCode, .mediaMetadataMismatch)
            XCTAssertEqual(failure.mediaType, .png)
            XCTAssertNotNil(failure.actualSHA256)
        }
    }

    func testDeferredRequiredResourceFailurePreservesDescriptorAndFailsClosedOnResolution()
        async throws
    {
        let missingDefinition = try XCTUnwrap(
            NorseBaseThemeResourceCatalog.definitions.first(where: {
                $0.id == NorseBaseThemeResourceIDs.backgroundStatic
            })
        )
        let probe = NorseFailurePublicationProbe()
        let runtime = RuneScribeRuntime(
            runtimeVersion: Self.version,
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { Date(timeIntervalSince1970: 1_776_211_201) },
                nextUUID: {
                    UUID(uuidString: "00000000-0000-0000-0000-000000000412")!
                }
            )
        )
        try await runtime.installPlatformAdapter(
            NorseSelectiveBundleResourceLocator(
                missingResource: missingDefinition.resource
            ),
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)

        let coordinator = positiveCoordinatorDescriptor()
        let ui = positiveUIDescriptor(requiredRole: coordinator.role)
        try await runtime.register(
            manifest: manifest(for: coordinator),
            factory: AnyModuleFactory(descriptor: coordinator) {
                NorsePositiveTestModule(descriptor: coordinator) { context in
                    let reader = try await context.contributionReaderClient()
                    await probe.capture(
                        descriptors: try await reader.snapshot(
                            for: RuntimeThemeContributionCatalog.descriptor
                        ),
                        failures: try await reader.snapshot(
                            for: RuntimeThemeContributionCatalog.requiredBaseResourceFailure
                        ),
                        resolver: try await context.opaqueResourceResolverClient()
                    )
                }
            }
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                NorsePositiveTestModule(descriptor: ui) { _ in }
            }
        )

        try await runtime.start()
        let capturedValue = await probe.value()
        let captured = try XCTUnwrap(capturedValue)
        XCTAssertEqual(captured.descriptors.entries.count, 1)
        XCTAssertEqual(
            captured.descriptors.entries.only?.value,
            RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        )
        XCTAssertTrue(captured.failures.entries.isEmpty)
        let handle = OpaqueResourceHandle(
            namespace: RuntimeThemeContributionCatalog.resourceNamespace(
                for: RuneScribeCodexIDs.norse
            ),
            resourceID: OpaqueResourceID(rawValue: missingDefinition.id.rawValue)
        )
        do {
            _ = try await probe.resolve(handle)
            XCTFail("A deferred missing required resource must not be returned.")
        } catch let failure as RequiredThemeResourceFailureDTO {
            XCTAssertEqual(failure.stage, .resourceRead)
            XCTAssertEqual(failure.resourceID, missingDefinition.id)
            XCTAssertEqual(failure.errorCode, .resourceUnavailable)
            XCTAssertEqual(
                failure.expectedByteCount,
                UInt64(missingDefinition.byteCount)
            )
            XCTAssertEqual(
                failure.expectedSHA256?.rawValue,
                missingDefinition.sha256Hex
            )
            XCTAssertEqual(failure.mediaType, missingDefinition.mediaType)
        }

        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(
            runtimeSnapshot.moduleStates[RuneScribeModuleIDs.norseTheme],
            .active
        )
        await runtime.stop()
    }

    private func bundledData(_ resource: ApplicationResource) throws -> Data {
        let url = try XCTUnwrap(
            RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                forResource: resource.name,
                withExtension: resource.fileExtension,
                subdirectory: resource.subdirectory
            )
        )
        return try Data(contentsOf: url)
    }

    private func bundledResourceData() throws -> [ApplicationResource: Data] {
        var result: [ApplicationResource: Data] = [:]
        let manifest = NorseBaseBundledResourceCatalog.integrityManifest
        result[manifest] = try bundledData(manifest)
        for definition in NorseBaseThemeResourceCatalog.definitions {
            result[definition.resource] = try bundledData(definition.resource)
        }
        return result
    }

    private func assertResource(
        _ id: ThemeResourceID?,
        role: ThemeResourceRoleID,
        media: ThemeResourceMediaType,
        in resources: [ThemeResourceID: ThemeResourceReference],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let id, let resource = resources[id] else {
            XCTFail("Missing resource", file: file, line: line)
            return
        }
        XCTAssertEqual(resource.role, role, file: file, line: line)
        XCTAssertEqual(resource.mediaType, media, file: file, line: line)
        XCTAssertEqual(resource.requirement, .required, file: file, line: line)
    }

    private func positiveCoordinatorDescriptor() -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: "com.runescribe.test.norse-positive-coordinator",
            moduleVersion: Self.version,
            kind: .service,
            criticality: .required,
            entryPoint: "NorsePositiveCoordinator",
            role: RuneScribeRoles.themeCoordinator,
            policyClass: RuneScribePolicyClasses.themeCoordinator,
            requestedCapabilities: [
                RuneScribeCapabilities.contributionRead,
                RuneScribeCapabilities.opaqueResourceResolve,
            ],
            requiredModuleRoles: [RuneScribeRoles.norseTheme]
        )
    }

    private func positiveUIDescriptor(requiredRole: ModuleRole) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: "com.runescribe.test.norse-positive-ui",
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "NorsePositiveUI",
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [RuneScribeCapabilities.rootUI],
            requiredModuleRoles: [requiredRole]
        )
    }

    private func manifest(for descriptor: ModuleDescriptor) -> ModuleManifest {
        ModuleManifest(
            runtimeVersion: Self.version,
            moduleID: descriptor.moduleID,
            displayName: descriptor.entryPoint,
            moduleVersion: descriptor.moduleVersion,
            moduleType: descriptor.kind,
            criticality: descriptor.criticality,
            supportedPlatforms: [.macOS],
            capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
            entryPoint: descriptor.entryPoint,
            runtimeRequirements: ModuleRuntimeRequirements(
                requiredServices: descriptor.requiredServices.sorted(),
                requiredResources: Array(descriptor.requiredResources),
                requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
            ),
            defaultRole: descriptor.role,
            policyClass: descriptor.policyClass,
            consumedEndpoints: descriptor.consumedEndpoints.sorted(),
            publishedEndpoints: descriptor.publishedEndpoints.sorted()
        )
    }

    private static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
}

private struct NorsePositiveTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    func start(context: ModuleContext) async throws { try await startAction(context) }
    func stop() async {}
}

private struct NorsePositiveBundleResourceLocator: ApplicationResourceLocator, Sendable {
    func data(for resource: ApplicationResource) async throws -> Data {
        try Data(contentsOf: try location(for: resource))
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        try location(for: resource)
    }

    private func location(for resource: ApplicationResource) throws -> URL {
        guard resource.ownerModuleID == RuneScribeModuleIDs.norseTheme,
              let url = RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                  forResource: resource.name,
                  withExtension: resource.fileExtension,
                  subdirectory: resource.subdirectory
              )
        else { throw NorsePositiveTestError.resourceUnavailable }
        return url
    }
}

private actor NorsePublicationProbe {
    struct Captured: Sendable {
        let contributions: RuntimeContributionSnapshot<ThemeDescriptor>
        let resources: OpaqueResourceSnapshot
        let resolved: [OpaqueResourceHandle: ResolvedOpaqueResource]
    }

    private var captured: Captured?

    func capture(
        contributions: RuntimeContributionSnapshot<ThemeDescriptor>,
        resources: OpaqueResourceSnapshot,
        resolved: [OpaqueResourceHandle: ResolvedOpaqueResource]
    ) {
        captured = Captured(
            contributions: contributions,
            resources: resources,
            resolved: resolved
        )
    }

    func value() -> Captured? { captured }
}

private struct NorseSelectiveBundleResourceLocator: ApplicationResourceLocator,
    Sendable
{
    let missingResource: ApplicationResource

    func data(for resource: ApplicationResource) async throws -> Data {
        guard resource != missingResource else {
            throw NorsePositiveTestError.resourceUnavailable
        }
        return try Data(contentsOf: try location(for: resource))
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        guard resource != missingResource else {
            throw NorsePositiveTestError.resourceUnavailable
        }
        return try location(for: resource)
    }

    private func location(for resource: ApplicationResource) throws -> URL {
        guard resource.ownerModuleID == RuneScribeModuleIDs.norseTheme,
              let url = RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                  forResource: resource.name,
                  withExtension: resource.fileExtension,
                  subdirectory: resource.subdirectory
              )
        else { throw NorsePositiveTestError.resourceUnavailable }
        return url
    }
}

private actor NorseFailurePublicationProbe {
    struct Captured: Sendable {
        let descriptors: RuntimeContributionSnapshot<ThemeDescriptor>
        let failures: RuntimeContributionSnapshot<RequiredThemeResourceFailureDTO>
    }

    private var captured: Captured?
    private var resolver: RuntimeOpaqueResourceResolverClient?

    func capture(
        descriptors: RuntimeContributionSnapshot<ThemeDescriptor>,
        failures: RuntimeContributionSnapshot<RequiredThemeResourceFailureDTO>,
        resolver: RuntimeOpaqueResourceResolverClient
    ) {
        captured = Captured(descriptors: descriptors, failures: failures)
        self.resolver = resolver
    }

    func value() -> Captured? { captured }

    func resolve(_ handle: OpaqueResourceHandle) async throws -> ResolvedOpaqueResource {
        guard let resolver else { throw NorsePositiveTestError.missingProbeClient }
        return try await resolver.resolve(handle)
    }
}

private enum NorsePositiveTestError: Error {
    case resourceUnavailable
    case missingProbeClient
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
