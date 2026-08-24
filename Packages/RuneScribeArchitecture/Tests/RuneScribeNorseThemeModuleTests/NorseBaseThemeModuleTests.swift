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
                "relic.norse.runestone.weathered",
                "relic.norse.raven-medallion",
                "relic.norse.ironbound-shield",
                "relic.norse.sealed-parchment",
                "relic.norse.runestone.blackstone",
                "relic.norse.runestone.frozen",
            ]
        )
        XCTAssertEqual(
            descriptor.codex.seals.map { $0.metadata.id.rawValue },
            [
                "seal.norse.knotwork",
                "seal.norse.forge-flame",
                "seal.norse.raven",
                "seal.norse.longship",
                "seal.norse.forge-hammer",
                "seal.norse.echo-rune",
            ]
        )
        XCTAssertEqual(descriptor.codex.frames.map { $0.metadata.id.rawValue }, [
            "frame.norse.carved-knotwork",
        ])
        XCTAssertEqual(descriptor.codex.crests.map { $0.metadata.id.rawValue }, [
            "crest.norse.forge-master",
        ])
        XCTAssertEqual(
            descriptor.codex.relics.last?.metadata.availability,
            .reservedInactive
        )
        XCTAssertNil(descriptor.codex.background.optionalMotionResourceID)
        XCTAssertEqual(descriptor.resources.count, 55)
        XCTAssertEqual(
            descriptor.resources.filter { $0.requirement == .optional }.map(\.id.rawValue),
            ["resource.relic.norse.runestone.frozen.geometry"]
        )
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
            role: ThemeResourceRoles.backgroundStaticBase,
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
            role: ThemeResourceRoles.vaultCard,
            media: .png,
            in: resources
        )
        assertResource(
            descriptor.codex.vault.selectedResourceID,
            role: ThemeResourceRoles.vaultCard,
            media: .png,
            in: resources
        )
        for relic in descriptor.codex.relics {
            assertResource(relic.primaryResourceID, role: ThemeResourceRoles.relicMaster, media: .png, in: resources)
            XCTAssertEqual(relic.thumbnailResourceID, relic.primaryResourceID)
            assertResource(relic.thumbnailResourceID, role: ThemeResourceRoles.relicMaster, media: .png, in: resources)
            assertResource(
                relic.staticFallbackResourceID,
                role: ThemeResourceRoles.relicStaticShareFallback,
                media: .png,
                in: resources
            )
            assertResource(
                relic.highContrastResourceID,
                role: ThemeResourceRoles.relicStaticShareFallback,
                media: .png,
                in: resources
            )
        }
        for seal in descriptor.codex.seals {
            assertResource(seal.vectorResourceID, role: ThemeResourceRoles.sealVectorMaster, media: .pdf, in: resources)
            XCTAssertEqual(seal.monochromeFallbackResourceID, seal.thumbnailResourceID)
            assertResource(
                seal.monochromeFallbackResourceID,
                role: ThemeResourceRoles.sealThumbnail,
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
            role: ThemeResourceRoleID(rawValue: "script-mapping")!,
            media: .json,
            in: resources
        )
        assertResource(
            NorseBaseThemeResourceIDs.backgroundParameters,
            role: ThemeResourceRoleID(rawValue: "background.parameters")!,
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
        XCTAssertEqual(NorseApplicationResourceCatalog.resourcesByHandle.count, 55)
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
                forResource: "Norse-Production-Asset-Provenance-v1.0",
                withExtension: "json"
            )
        )
        let data = try Data(contentsOf: provenanceURL)
        XCTAssertEqual(data.count, 54_597)
        XCTAssertEqual(
            sha256Hex(data),
            "105fb4f5f966e3071f1e75d2f2aa590279f30ed1368dfd613d7045575c6b9f8c"
        )

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["releaseStatus"] as? String, "release-candidate")
        XCTAssertEqual(root["resourceCount"] as? Int, 55)
        let approval = try XCTUnwrap(
            root["releaseCandidateBaselineApproval"] as? [String: Any]
        )
        XCTAssertEqual(
            approval["status"] as? String,
            "approved-as-release-candidate-baseline"
        )
        XCTAssertEqual(approval["publicDistributionAuthorized"] as? Bool, false)
        let rightsSources = try XCTUnwrap(root["rightsSources"] as? [[String: Any]])
        XCTAssertEqual(
            Set(rightsSources.compactMap { $0["statementReference"] as? String }),
            [
                "EULA.md#4-ownership-and-intellectual-property",
                "RuneScrib/Resources/Fonts/OFL.txt",
            ]
        )
        let resources = try XCTUnwrap(root["resources"] as? [[String: Any]])
        XCTAssertEqual(resources.count, 55)
        XCTAssertEqual(
            Set(resources.compactMap { $0["resourceID"] as? String }),
            Set(NorseApplicationResourceCatalog.resourcesByHandle.keys)
        )
        XCTAssertTrue(resources.allSatisfy { resource in
            resource["releaseStatus"] as? String == "release-candidate"
                && (resource["normalizedProductionPath"] as? String)?.isEmpty == false
                && (resource["sha256"] as? String)?.count == 64
                && (resource["byteCount"] as? Int ?? 0) > 0
                && (resource["rightsProvenanceID"] as? String)?.isEmpty == false
                && (resource["licenseOrOwnershipStatementReference"] as? String)?.isEmpty
                    == false
                && (resource["accessibilityDescriptionKey"] as? String)?.isEmpty == false
        })
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
        XCTAssertEqual(report.uniquePhysicalBytes, 31_879_723)
        XCTAssertEqual(report.staticImageBytes, 30_455_573)
        XCTAssertEqual(report.fontBytes, 55_800)
        XCTAssertEqual(report.animationBytes, 3_277)
        XCTAssertEqual(report.soundBytes, 1_334_576)
        XCTAssertEqual(report.largestResourceBytes, 2_568_492)
    }

    func testProgressionBindingsUseOnlyLiveAchievementIdentifiers() throws {
        let bindingsURL = try XCTUnwrap(
            RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                forResource: "Norse-Progression-Bindings-v1.0",
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

    func testMissingOrCorruptOptionalResourceIsOmittedWithoutBaseFailure() async throws {
        enum Scenario: CaseIterable { case missing, corrupt }

        let optionalDefinitions = NorseBaseThemeResourceCatalog.definitions.filter {
            $0.requirement == .optional
        }
        XCTAssertEqual(optionalDefinitions.count, 1)
        let optional = try XCTUnwrap(optionalDefinitions.first)
        let bundledResources = try bundledResourceData()
        let requiredIDs = Set(
            RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor.resources
                .filter { $0.requirement == .required }
                .map(\.id)
        )

        for scenario in Scenario.allCases {
            let runtimeIO = RuntimeIOClient(
                readVerifiedApplicationResource: { resource, _, _ in
                    if resource == optional.resource {
                        switch scenario {
                        case .missing:
                            throw RuntimeVerifiedApplicationResourceFailure.resourceUnavailable
                        case .corrupt:
                            throw RuntimeVerifiedApplicationResourceFailure.integrityMismatch(
                                actualSHA256: Data(
                                    repeating: 0xC3,
                                    count: SHA256.Digest.byteCount
                                ),
                                actualByteCount: optional.byteCount
                            )
                        }
                    }
                    guard let data = bundledResources[resource] else {
                        throw RuntimeVerifiedApplicationResourceFailure.resourceUnavailable
                    }
                    return data
                }
            )

            let validated = try await NorseBaseThemeResources.loadValidated(using: runtimeIO)
            XCTAssertEqual(Set(validated.resourcePayloads.keys), requiredIDs)
            XCTAssertNil(validated.resourcePayloads[optional.id])
        }
    }

    func testCancellationFromManifestOrOptionalResourceReadPropagates() async throws {
        enum Scenario: CaseIterable, Equatable { case manifest, optionalResource }

        let optional = try XCTUnwrap(
            NorseBaseThemeResourceCatalog.definitions.first(where: {
                $0.requirement == .optional
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
                    if scenario == .optionalResource, resource == optional.resource {
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

    func testEmergencyPublicationRetainsDiagnosticBeforeDescriptor() async throws {
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
                        )
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
        let failure = try XCTUnwrap(captured.failures.entries.only?.value)
        XCTAssertEqual(failure.stage, .resourceRead)
        XCTAssertEqual(failure.resourceID, missingDefinition.id)
        XCTAssertEqual(failure.errorCode, .resourceUnavailable)
        let failureRevision = try XCTUnwrap(
            captured.failures.entries.only?.publishedRevision
        )
        let descriptorRevision = try XCTUnwrap(
            captured.descriptors.entries.only?.publishedRevision
        )
        XCTAssertLessThan(failureRevision, descriptorRevision)
        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
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

    func capture(
        descriptors: RuntimeContributionSnapshot<ThemeDescriptor>,
        failures: RuntimeContributionSnapshot<RequiredThemeResourceFailureDTO>
    ) {
        captured = Captured(descriptors: descriptors, failures: failures)
    }

    func value() -> Captured? { captured }
}

private enum NorsePositiveTestError: Error {
    case resourceUnavailable
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
