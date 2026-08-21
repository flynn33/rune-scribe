import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeNorseThemeModule
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
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
        XCTAssertNil(
            bundle.url(
                forResource: "make_norse_base_placeholders",
                withExtension: "swift",
                subdirectory: "Source"
            )
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
        await runtime.stop()
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

private enum NorsePositiveTestError: Error {
    case resourceUnavailable
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
