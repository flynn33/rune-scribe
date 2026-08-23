import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeNorseThemeModule
import RuneScribeProgressionModule
import RuneScribeTestSupport
import RuneScribeThemeCoordinatorModule
@testable import RuneScribeThemeSunspireModule
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
import XCTest

final class SunspireThemeProviderTests: XCTestCase {
    func testFrozenIdentityBindingsAndDescriptorConformance() throws {
        let descriptor = RuneScribeThemeSunspireModuleBootstrap.discoveryDescriptor
        XCTAssertEqual(descriptor, try SunspireThemeDescriptorFactory.make())
        XCTAssertEqual(descriptor.moduleID.rawValue, "com.runescribe.module.theme.sunspire")
        XCTAssertEqual(descriptor.moduleRole.rawValue, "runescribe.theme.sunspire")
        XCTAssertEqual(descriptor.policyClass.rawValue, "policy.theme-provider")
        XCTAssertEqual(descriptor.criticality, .optional)
        XCTAssertEqual(descriptor.fallbackCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(descriptor.codex.id.rawValue, "codex.sunspire")
        XCTAssertEqual(descriptor.codex.entitlementID.rawValue, "unlock.codex.sunspire")
        let binding = try authoritativeBinding(for: descriptor.codex.id)
        XCTAssertEqual(binding.moduleID, RuneScribeThemeSunspireModuleBootstrap.moduleID)
        XCTAssertEqual(binding.entitlementID, RuneScribeThemeSunspireModuleBootstrap.unlockID)
        XCTAssertEqual(
            binding.gateRuleID?.rawValue,
            "rule.codex.sunspire.reciprocal-light"
        )

        let script = try XCTUnwrap(descriptor.codex.scripts.only)
        XCTAssertEqual(script.id.rawValue, "script.sunspire")
        XCTAssertEqual(script.portability, .fontDependent)
        XCTAssertEqual(script.glyphs.map { $0.canonicalValue }, Array(0 ..< 32).map(UInt8.init))
        XCTAssertEqual(script.glyphs.map { $0.textToken }, ThemeCanonicalSymbolSet.transportTokens)
        XCTAssertEqual(script.fontReferenceID?.rawValue, "rs-sunspire")
        XCTAssertEqual(script.fontVersion, 1)
        XCTAssertEqual(script.fontPostScriptName?.rawValue, "RavenForgeSunspireScript-Regular")
        XCTAssertEqual(
            script.rightsID.rawValue,
            "prov.Source.Masters.Glyphs.sunspire.glyph.master.json"
        )

        XCTAssertEqual(
            descriptor.codex.shortDescription.fallbackValue,
            "Dawnlit inscriptions carried in ivory, gold, and living radiance."
        )
        XCTAssertEqual(
            descriptor.codex.longDescription.fallbackValue,
            "A noble Elven Codex of sun-touched ivory, gilded leaves, and measured light. Its script rises with the ordered clarity of dawn."
        )
        XCTAssertEqual(descriptor.codex.fallbackScriptID.rawValue, "script.base-runes")
        XCTAssertEqual(
            descriptor.codex.background.displayName.fallbackValue,
            "Hall of First Light"
        )
        let acceptedPalette = descriptor.codex.palette
        XCTAssertEqual(
            [
                acceptedPalette.backgroundPrimary.rawValue,
                acceptedPalette.backgroundSecondary.rawValue,
                acceptedPalette.surfacePrimary.rawValue,
                acceptedPalette.surfaceElevated.rawValue,
                acceptedPalette.textPrimary.rawValue,
                acceptedPalette.textSecondary.rawValue,
                acceptedPalette.textInverse.rawValue,
                acceptedPalette.accentPrimary.rawValue,
                acceptedPalette.accentSecondary.rawValue,
                acceptedPalette.locked.rawValue,
                acceptedPalette.encountered.rawValue,
                acceptedPalette.unavailable.rawValue,
            ],
            [
            "#1C160D",
            "#2B2112",
            "#2D2417",
            "#3B2F1E",
            "#FFF3D6",
            "#D7BF8C",
            "#2D2417",
            "#F2C66D",
            "#FFF0C8",
            "#85765E",
            "#D3A953",
            "#6A6255",
        ]
        )
        XCTAssertNotEqual(acceptedPalette.backgroundPrimary.rawValue, "#0B0B0D")
        XCTAssertEqual(script.fallbackScriptID.rawValue, "script.base-runes")
        XCTAssertEqual(
            descriptor.codex.relics.map(\.metadata.availability),
            [.included, .earned, .earned]
        )
        XCTAssertEqual(
            descriptor.codex.relics.map(\.metadata.rarity),
            [.forged, .inscribed, .rare]
        )
        XCTAssertEqual(
            descriptor.codex.relics.map(\.metadata.description.fallbackValue),
            [
            "A luminous default Relic balancing ceremonial stature with generous inscription capacity.",
            "A compact radiant plaque for short and medium messages with stronger ornamental density.",
            "A prestigious vertical Relic designed for formal long inscriptions.",
        ]
        )
        XCTAssertEqual(
            descriptor.codex.seals.map(\.metadata.availability),
            [.included, .included, .earned, .earned, .earned, .encountered]
        )
        XCTAssertEqual(
            descriptor.codex.seals.map(\.metadata.rarity),
            [.forged, .forged, .inscribed, .inscribed, .rare, .rare]
        )
        XCTAssertEqual(
            descriptor.codex.seals.map(\.metadata.description.fallbackValue),
            [
            "The foundational Sunspire emblem of light joined with living growth.",
            "A mark of messages carried openly and joyfully into the dawn.",
            "A first-dispatch reward representing the beginning of radiant correspondence.",
            "A receiving mark representing reciprocal light and returned words.",
            "A noble mark for sustained Sunspire use and elevated standing.",
            "An encounter mark carried from another Scribe’s Sunspire presentation.",
        ]
        )
        XCTAssertEqual(descriptor.codex.frames.map(\.metadata.availability), [.mastery])
        XCTAssertEqual(descriptor.codex.crests.map(\.metadata.availability), [.mastery])

        let acceptedAccessibility = [script.accessibility]
            + descriptor.codex.relics.map(\.metadata.accessibility)
            + descriptor.codex.seals.map(\.metadata.accessibility)
            + descriptor.codex.frames.map(\.metadata.accessibility)
            + descriptor.codex.crests.map(\.metadata.accessibility)
            + [descriptor.codex.background.accessibility, descriptor.codex.vault.accessibility]
        XCTAssertEqual(
            acceptedAccessibility.map(\.label.key.rawValue),
            [
            "resource.script.sunspire.accessibility.label",
            "resource.relic.sunspire.dawnfire-tablet.accessibility.label",
            "resource.relic.sunspire.solvine-plaque.accessibility.label",
            "resource.relic.sunspire.auric-stele.accessibility.label",
            "resource.seal.sunspire.sunleaf-crest.accessibility.label",
            "resource.seal.sunspire.golden-lark.accessibility.label",
            "resource.seal.sunspire.dawnflower.accessibility.label",
            "resource.seal.sunspire.sunwheel.accessibility.label",
            "resource.seal.sunspire.radiant-spire.accessibility.label",
            "resource.seal.sunspire.echo-ember.accessibility.label",
            "resource.frame.sunspire.laurel-of-dawn.accessibility.label",
            "resource.crest.sunspire.first-light.accessibility.label",
            "resource.background.sunspire.hall-of-first-light.accessibility.label",
            "resource.vault.sunspire.codex.accessibility.label",
        ]
        )
        XCTAssertEqual(
            acceptedAccessibility.map(\.label.fallbackValue),
            [
            "Sunspire Codex script with complete static renderer fallback.",
            "A warm ivory tablet framed in gold leaves and crowned by a radiant sun medallion.",
            "A square ivory plaque covered in gold sunleaf vines and a small sun emblem.",
            "A tall arched ivory stele glowing with gold rays and resting on a small pedestal.",
            "A round sun surrounded by eight leaf-shaped rays.",
            "A small golden songbird inside a ring with two leaves.",
            "A five-petal flower opening around a small sun.",
            "An eight-spoke sun wheel with leaves at the ends.",
            "A slender golden spire with three sun rays rising behind it.",
            "A glowing ember inside two circular rings.",
            "Thin gold laurel branches, four sun nodes, restrained ivory enamel, and no intrusion into safe regions.",
            "A rising sun above one open leaf crown, contained in a clean circular gold crest.",
            "Abstracted sunlit court: warm shafts, ivory-gold botanical forms, distant arches without identifiable franchise architecture.",
            "Sunspire Codex locked, encountered, owned, and selected presentation.",
        ]
        )
        XCTAssertTrue(acceptedAccessibility.allSatisfy {
            $0.hint == nil
                && $0.hidesRedundantGlyphs
                && $0.noColorOnlyState
                && $0.dynamicTypeSafe
        })

        let acceptedLayouts = descriptor.codex.relics.flatMap(\.layouts)
        XCTAssertEqual(try canonicalSHA256(acceptedLayouts), "d008ad29df078f7bef3bc5df4008fcc79e2acb2eac2ab91cee06fbe3d2f0a48e")
        XCTAssertEqual(try canonicalSHA256(descriptor.rights), "41b4433ed37b848781f549234dea7e3d296db825e535b1bd94a40d550aedba45")
        XCTAssertEqual(descriptor.rights.count, 14)
        XCTAssertTrue(descriptor.rights.allSatisfy {
            $0.creationDate == "2026-08-21"
                && $0.origin == .derived
                && $0.rightsOwner == "Raven Forge Software"
                && $0.licenseNotice
                    == "Owner-supplied proprietary source and approved recovery authority"
        })
        let scriptRights = try XCTUnwrap(descriptor.rights.first { $0.id == script.rightsID })
        XCTAssertEqual(scriptRights.id.rawValue, "prov.Source.Masters.Glyphs.sunspire.glyph.master.json")
        XCTAssertNotEqual(scriptRights.id.rawValue, scriptRights.id.rawValue.lowercased())
        XCTAssertEqual(scriptRights.creatorTool, "macOS byte-preserving canonicalization with Python 3.9.6 hashing")
        XCTAssertEqual(scriptRights.sourceReference, "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Glyphs/sunspire/glyph-master.json")
        XCTAssertEqual(scriptRights.exportSettings, "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}")

        XCTAssertEqual(descriptor.codex.relics.count, 3)
        XCTAssertEqual(descriptor.codex.seals.count, 6)
        XCTAssertEqual(descriptor.codex.frames.count, 1)
        XCTAssertEqual(descriptor.codex.crests.count, 1)
        XCTAssertEqual(descriptor.codex.relics.filter { $0.isDefault }.count, 1)
        XCTAssertNil(descriptor.codex.background.optionalMotionResourceID)
        XCTAssertFalse(descriptor.codex.background.parallaxAllowed)
        XCTAssertEqual(SunspireThemeResourceCatalog.productionDefinitions.count, 46)
        XCTAssertEqual(descriptor.resources.count, 47)
        XCTAssertTrue(descriptor.resources.allSatisfy { $0.requirement == .required })
        let localization = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: SunspireThemeResourceCatalog.localizationPayload
            ) as? [String: Any]
        )
        XCTAssertEqual(localization["locale"] as? String, "en")
        XCTAssertNotNil(localization["strings"] as? [String: String])

        let references = Dictionary(uniqueKeysWithValues: descriptor.resources.map { ($0.id, $0) })
        for definition in SunspireThemeResourceCatalog.productionDefinitions {
            let reference = try XCTUnwrap(references[definition.id])
            XCTAssertEqual(reference.role, definition.role)
            XCTAssertEqual(reference.mediaType, definition.mediaType)
            XCTAssertEqual(reference.integrity.byteLength, UInt64(definition.byteCount))
            XCTAssertEqual(reference.integrity.sha256.rawValue, definition.sha256Hex)
            XCTAssertEqual(reference.rightsID, definition.rightsID)
        }
        for relic in descriptor.codex.relics {
            XCTAssertTrue(relic.layouts.allSatisfy { layout in
                layout.relicBounds.contains(layout.contentSafeRegion)
                    && layout.contentSafeRegion.contains(layout.glyphSafeRegion)
                    && layout.sealAnchors.allSatisfy { !layout.glyphSafeRegion.contains($0.point) }
            })
        }
        XCTAssertTrue(descriptor.codex.seals.allSatisfy {
            !$0.allowedAnchors.isEmpty && $0.allowedScale.maximum <= 1
        })
    }

    func testModuleManifestAndImmutableResourcesRemainExact() throws {
        let bundle = RuneScribeThemeSunspireModuleBootstrap.resourceBundle
        let manifestURL = try XCTUnwrap(bundle.url(forResource: "module-manifest", withExtension: "json"))
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try ModuleManifestDecoder.decode(manifestData)
        XCTAssertEqual(manifest.moduleID, RuneScribeThemeSunspireModuleBootstrap.moduleID)
        XCTAssertEqual(manifest.defaultRole, RuneScribeThemeSunspireModuleBootstrap.role)
        XCTAssertEqual(manifest.effectivePolicyClass, RuneScribePolicyClasses.themeProvider)
        XCTAssertEqual(manifest.criticality, .optional)
        XCTAssertEqual(manifest.entitlementRequirement?.kind, .earned)
        XCTAssertEqual(manifest.entitlementRequirement?.identifier, RuneScribeThemeSunspireModuleBootstrap.unlockID)
        XCTAssertEqual(Set(manifest.runtimeRequirements.requiredResources), SunspireThemeBundledResourceCatalog.all)
        XCTAssertEqual(sha256Hex(manifestData), RuneScribeThemeSunspireModuleBootstrap.manifestExpectedSHA256Hex)

        let integrityURL = try XCTUnwrap(bundle.url(forResource: "Resource-Integrity-Manifest-v1.0", withExtension: "json"))
        let integrityData = try Data(contentsOf: integrityURL)
        XCTAssertEqual(sha256Hex(integrityData), "da391cc35e89ad0606099e50e98bb2e28591420f68ec745efc2878411e9b1edc")
        XCTAssertTrue(SunspireThemeResourceCatalog.validateIntegrityManifest(integrityData))

        var shippingBytes = 0
        for definition in SunspireThemeResourceCatalog.productionDefinitions {
            let url = try XCTUnwrap(bundle.url(
                forResource: definition.resource.name,
                withExtension: definition.resource.fileExtension,
                subdirectory: definition.resource.subdirectory
            ))
            let data = try Data(contentsOf: url)
            shippingBytes += data.count
            XCTAssertEqual(data.count, definition.byteCount)
            XCTAssertLessThanOrEqual(data.count, definition.maximumByteCount)
            XCTAssertEqual(sha256Hex(data), definition.sha256Hex)
        }
        XCTAssertEqual(shippingBytes, 666458)
    }

    func testLockedDiscoveryPublishesPreviewResourcesAndRestartsSafely() async throws {
        let probe = SunspireThemeReaderProbe()
        let runtime = try await makeRuntime(locator: SunspireThemeBundleLocator())
        try await RuneScribeThemeSunspireModuleBootstrap.register(with: runtime)
        try await registerReaderAndUI(with: runtime, probe: probe)

        try await runtime.start()
        var runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeSunspireModuleBootstrap.moduleID], .active)
        var contributionSnapshot = try await probe.contributionSnapshot()
        let previewContribution = try XCTUnwrap(contributionSnapshot.entries.only)
        XCTAssertEqual(
            previewContribution.value,
            RuneScribeThemeSunspireModuleBootstrap.discoveryDescriptor
        )
        let previewResources = try await probe.resourceSnapshot()
        XCTAssertEqual(
            previewResources.resources.count,
            previewContribution.value.resources.count
        )

        try await runtime.reconcileEntitlements(try entitlementSnapshot())
        runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeSunspireModuleBootstrap.moduleID], .active)

        contributionSnapshot = try await probe.contributionSnapshot()
        let contribution = try XCTUnwrap(contributionSnapshot.entries.only)
        XCTAssertEqual(contribution.owner.moduleID, RuneScribeThemeSunspireModuleBootstrap.moduleID)
        XCTAssertEqual(contribution.value, RuneScribeThemeSunspireModuleBootstrap.discoveryDescriptor)
        let opaqueSnapshot = try await probe.resourceSnapshot()
        XCTAssertEqual(opaqueSnapshot.resources.count, contribution.value.resources.count)
        for reference in contribution.value.resources {
            let resource = try await probe.resolve(
                OpaqueResourceHandle(
                    namespace: RuntimeThemeContributionCatalog.resourceNamespace(for: contribution.value.codex.id),
                    resourceID: OpaqueResourceID(rawValue: reference.id.rawValue)
                )
            )
            XCTAssertEqual(resource.metadata.ownerModuleID, RuneScribeThemeSunspireModuleBootstrap.moduleID)
            XCTAssertEqual(resource.metadata.semanticRole, reference.role.rawValue)
            XCTAssertEqual(resource.metadata.mediaType.rawValue, reference.mediaType.rawValue)
            XCTAssertEqual(resource.metadata.byteCount, Int(reference.integrity.byteLength))
            XCTAssertEqual(resource.metadata.sha256, reference.integrity.sha256.rawValue)
            XCTAssertEqual(sha256Hex(resource.data), reference.integrity.sha256.rawValue)
        }

        await runtime.stop()
        try await runtime.start()
        runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeSunspireModuleBootstrap.moduleID], .active)
        contributionSnapshot = try await probe.contributionSnapshot()
        XCTAssertEqual(contributionSnapshot.entries.count, 1)
        await runtime.stop()
    }

    func testResourceFailuresRemainIsolatedFromTheRequiredUI() async throws {
        let first = try XCTUnwrap(SunspireThemeResourceCatalog.productionDefinitions.first)
        for mode in SunspireThemeBundleLocator.Mode.failureModes {
            let runtime = try await makeRuntime(locator: SunspireThemeBundleLocator(mode: mode, target: first.resource, targetMaximumBytes: first.maximumByteCount))
            try await RuneScribeThemeSunspireModuleBootstrap.register(with: runtime)
            try await registerUI(with: runtime, suffix: mode.rawValue)
            try await runtime.start()
            try await runtime.reconcileEntitlements(try entitlementSnapshot())
            let snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.status, .running, "mode=\(mode.rawValue)")
            XCTAssertEqual(snapshot.moduleStates[RuneScribeThemeSunspireModuleBootstrap.moduleID], .failed, "mode=\(mode.rawValue)")
            XCTAssertEqual(snapshot.moduleStates[uiModuleID(suffix: mode.rawValue)], .active, "mode=\(mode.rawValue)")
            await runtime.stop()
        }
    }

    func testThemeCoordinatorActivatesLiveAndPreservesOwnedPreferenceDuringProviderFailure()
        async throws
    {
        let store = InMemoryModuleStateStore(
            now: { Date(timeIntervalSince1970: 1_776_211_200) }
        )
        let probe = SunspireThemeCoordinatorProbe()
        let runtime = try await makeCoordinatorRuntime(
            locator: SunspireThemeBundleLocator(),
            store: store
        )
        try await registerCoordinatorStack(with: runtime, probe: probe)
        try await runtime.start()

        let locked = try await probe.waitForSnapshot { snapshot in
            snapshot.providers.count == 2
                && snapshot.providers.contains {
                    $0.codexID == RuneScribeThemeSunspireModuleBootstrap.codexID
                        && $0.state == .locked
                }
        }
        XCTAssertEqual(locked.effectiveCodexID, RuneScribeCodexIDs.norse)

        try await runtime.reconcileEntitlements(try entitlementSnapshot())
        let available = try await probe.waitForSnapshot { snapshot in
            snapshot.providers.contains {
                $0.codexID == RuneScribeThemeSunspireModuleBootstrap.codexID
                    && $0.state == .available
                    && $0.isOwned
                    && $0.isSelectable
            }
        }
        let activeRuntimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(
            activeRuntimeSnapshot.moduleStates[RuneScribeThemeSunspireModuleBootstrap.moduleID],
            .active
        )

        let selected = try await probe.select(
            SelectThemeCodexCommand(
                codexID: RuneScribeThemeSunspireModuleBootstrap.codexID,
                expectedSnapshotRevision: available.revision
            )
        )
        XCTAssertEqual(selected.preferredCodexID, RuneScribeThemeSunspireModuleBootstrap.codexID)
        XCTAssertEqual(selected.effectiveCodexID, RuneScribeThemeSunspireModuleBootstrap.codexID)
        XCTAssertEqual(selected.fallbackReason, .none)
        let fontID = try XCTUnwrap(selected.effectiveTheme.codex.scripts.first?.fontResourceID)
        let resolved = try await probe.resolve(
            ResolveThemeResourceRequestDTO(
                codexID: RuneScribeThemeSunspireModuleBootstrap.codexID,
                resourceID: fontID
            )
        )
        XCTAssertEqual(sha256Hex(resolved.data), resolved.integrity.sha256.rawValue)
        await runtime.stop()

        let failedProbe = SunspireThemeCoordinatorProbe()
        let target = try XCTUnwrap(SunspireThemeResourceCatalog.productionDefinitions.first)
        let failedRuntime = try await makeCoordinatorRuntime(
            locator: SunspireThemeBundleLocator(
                mode: .corrupt,
                target: target.resource,
                targetMaximumBytes: target.maximumByteCount
            ),
            store: store
        )
        try await registerCoordinatorStack(with: failedRuntime, probe: failedProbe)
        try await failedRuntime.reconcileEntitlements(try entitlementSnapshot())
        try await failedRuntime.start()
        let fallback = try await failedProbe.waitForSnapshot { snapshot in
            snapshot.preferredCodexID == RuneScribeThemeSunspireModuleBootstrap.codexID
                && snapshot.effectiveCodexID == RuneScribeCodexIDs.norse
                && snapshot.providers.contains {
                    $0.codexID == RuneScribeThemeSunspireModuleBootstrap.codexID
                        && $0.isOwned
                        && !$0.isSelectable
                }
        }
        XCTAssertEqual(fallback.fallbackReason, .unavailable)
        XCTAssertEqual(fallback.effectiveTheme.codex.id, RuneScribeCodexIDs.norse)
        let failedSnapshot = await failedRuntime.snapshot()
        XCTAssertEqual(
            failedSnapshot.moduleStates[RuneScribeThemeSunspireModuleBootstrap.moduleID],
            .failed
        )
        XCTAssertEqual(failedSnapshot.moduleStates[RuneScribeModuleIDs.norseTheme], .active)
        XCTAssertEqual(failedSnapshot.moduleStates[RuneScribeModuleIDs.themeCoordinator], .active)
        await failedRuntime.stop()
    }

    func testProviderSourcesDoNotImportOrEvaluateProgressionOrPlatformLayers() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = packageRoot
            .appendingPathComponent("Sources/RuneScribeThemeSunspireModule")
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        XCTAssertEqual(sourceURLs.count, 3)
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(source.contains("Progression"), sourceURL.lastPathComponent)
            XCTAssertFalse(source.contains("evaluate"), sourceURL.lastPathComponent)
            XCTAssertFalse(source.contains("import RuneScribePlatform"), sourceURL.lastPathComponent)
            XCTAssertFalse(source.contains("import SwiftUI"), sourceURL.lastPathComponent)
            XCTAssertFalse(source.contains("import AppKit"), sourceURL.lastPathComponent)
            XCTAssertFalse(source.contains("import UIKit"), sourceURL.lastPathComponent)
        }
    }

    private func makeRuntime(locator: SunspireThemeBundleLocator) async throws -> RuneScribeRuntime {
        let runtime = RuneScribeRuntime(
            runtimeVersion: Self.version,
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { Date(timeIntervalSince1970: 1_776_211_200) },
                nextUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000521")! }
            )
        )
        try await runtime.installPlatformAdapter(
            locator,
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        return runtime
    }

    private func makeCoordinatorRuntime(
        locator: SunspireThemeBundleLocator,
        store: InMemoryModuleStateStore
    ) async throws -> RuneScribeRuntime {
        let runtime = RuneScribeRuntime(
            runtimeVersion: Self.version,
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { Date(timeIntervalSince1970: 1_776_211_200) },
                nextUUID: { UUID() },
                operatingSystemVersion: {
                    RuntimeOperatingSystemVersion(major: 15, minor: 0, patch: 0)
                }
            )
        )
        try await runtime.installPlatformAdapter(
            locator,
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.installPlatformAdapter(
            store,
            for: RuneScribeServiceKeys.moduleStateStore
        )
        return runtime
    }

    private func registerCoordinatorStack(
        with runtime: RuneScribeRuntime,
        probe: SunspireThemeCoordinatorProbe
    ) async throws {
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeSunspireModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        let ui = ModuleDescriptor(
            moduleID: "com.runescribe.test.sunspire.coordinator-ui",
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "SunspireThemeCoordinatorUI",
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [
                RuneScribeCapabilities.rootUI,
                RuneScribeCapabilities.themeStateRead,
                RuneScribeCapabilities.themeSelection,
                RuneScribeCapabilities.themeResourceRead,
            ],
            requiredModuleRoles: [RuneScribeRoles.themeCoordinator],
            consumedEndpoints: RuntimeThemeEndpointCatalog.UIEndpointIDs
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                SunspireThemeTestModule(descriptor: ui) { context in
                    await probe.capture(try await context.themeCoordinatorClient())
                }
            }
        )
    }

    private func registerReaderAndUI(
        with runtime: RuneScribeRuntime,
        probe: SunspireThemeReaderProbe
    ) async throws {
        let reader = ModuleDescriptor(
            moduleID: "com.runescribe.test.sunspire.reader",
            moduleVersion: Self.version,
            kind: .service,
            criticality: .required,
            entryPoint: "SunspireThemeReader",
            role: RuneScribeRoles.themeCoordinator,
            policyClass: RuneScribePolicyClasses.themeCoordinator,
            requestedCapabilities: [
                RuneScribeCapabilities.contributionRead,
                RuneScribeCapabilities.opaqueResourceResolve,
            ]
        )
        try await runtime.register(
            manifest: manifest(for: reader),
            factory: AnyModuleFactory(descriptor: reader) {
                SunspireThemeTestModule(descriptor: reader) { context in
                    await probe.capture(
                        reader: try await context.contributionReaderClient(),
                        resolver: try await context.opaqueResourceResolverClient()
                    )
                }
            }
        )
        let ui = uiDescriptor(suffix: "publication", requiredRole: reader.role)
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                SunspireThemeTestModule(descriptor: ui) { _ in }
            }
        )
    }

    private func registerUI(with runtime: RuneScribeRuntime, suffix: String) async throws {
        let ui = uiDescriptor(suffix: suffix, requiredRole: nil)
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                SunspireThemeTestModule(descriptor: ui) { _ in }
            }
        )
    }

    private func uiDescriptor(suffix: String, requiredRole: ModuleRole?) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: uiModuleID(suffix: suffix),
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "SunspireThemeUI" + suffix.replacingOccurrences(of: "-", with: "_"),
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [RuneScribeCapabilities.rootUI],
            requiredModuleRoles: Set(requiredRole.map { [$0] } ?? [])
        )
    }

    private func uiModuleID(suffix: String) -> ModuleIdentifier {
        ModuleIdentifier(rawValue: "com.runescribe.test.sunspire.ui.\(suffix)")
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

    private func entitlementSnapshot() throws -> ProgressionEntitlementSnapshotDTO {
        try ProgressionEntitlementSnapshotDTO(
            revision: 1,
            capturedAt: Date(timeIntervalSince1970: 1_776_211_201),
            includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
            earnedUnlockIDs: [RuneScribeThemeSunspireModuleBootstrap.unlockID]
        )
    }

    private func authoritativeBinding(for codexID: CodexID) throws -> ProgressionThemeBinding {
        let url = try XCTUnwrap(
            RuneScribeProgressionModuleBootstrap.resourceBundle.url(
                forResource: "Rune-Scribe-Progression-Future-Theme-Binding-Contract-v1.0",
                withExtension: "json"
            )
        )
        let contract = try JSONDecoder().decode(
            ProgressionFutureThemeBindingContract.self,
            from: Data(contentsOf: url)
        )
        return try XCTUnwrap(contract.bindings.first { $0.codexID == codexID })
    }

    private static let version = SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0))
}

private struct SunspireThemeTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    func start(context: ModuleContext) async throws { try await startAction(context) }
    func stop() async {}
}

private struct SunspireThemeBundleLocator: ApplicationResourceLocator, Sendable {
    enum Mode: String, Sendable {
        case valid
        case missing
        case corrupt
        case overBudget = "over-budget"
        case wrongHash = "wrong-hash"

        static let failureModes: [Self] = [.missing, .corrupt, .overBudget, .wrongHash]
    }

    let mode: Mode
    let target: ApplicationResource?
    let targetMaximumBytes: Int

    init(mode: Mode = .valid, target: ApplicationResource? = nil, targetMaximumBytes: Int = 0) {
        self.mode = mode
        self.target = target
        self.targetMaximumBytes = targetMaximumBytes
    }

    func data(for resource: ApplicationResource) async throws -> Data {
        let url = try location(for: resource)
        if resource == target, mode == .missing {
            throw SunspireThemeTestError.resourceUnavailable
        }
        var data = try Data(contentsOf: url)
        guard resource == target else { return data }
        switch mode {
        case .valid, .missing:
            return data
        case .corrupt:
            return Data("{".utf8)
        case .wrongHash:
            data[0] ^= 0x01
            return data
        case .overBudget:
            data.append(Data(repeating: 0, count: max(1, targetMaximumBytes + 1 - data.count)))
            return data
        }
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        try location(for: resource)
    }

    private func location(for resource: ApplicationResource) throws -> URL {
        let bundle: Bundle
        switch resource.ownerModuleID {
        case RuneScribeThemeSunspireModuleBootstrap.moduleID:
            bundle = RuneScribeThemeSunspireModuleBootstrap.resourceBundle
        case RuneScribeModuleIDs.norseTheme:
            bundle = RuneScribeNorseThemeModuleBootstrap.resourceBundle
        default:
            throw SunspireThemeTestError.resourceUnavailable
        }
        guard let url = bundle.url(
                  forResource: resource.name,
                  withExtension: resource.fileExtension,
                  subdirectory: resource.subdirectory
              )
        else { throw SunspireThemeTestError.resourceUnavailable }
        return url
    }
}

private actor SunspireThemeReaderProbe {
    private var reader: RuntimeContributionReaderClient?
    private var resolver: RuntimeOpaqueResourceResolverClient?

    func capture(reader: RuntimeContributionReaderClient, resolver: RuntimeOpaqueResourceResolverClient) {
        self.reader = reader
        self.resolver = resolver
    }

    func contributionSnapshot() async throws -> RuntimeContributionSnapshot<ThemeDescriptor> {
        guard let reader else { throw SunspireThemeTestError.missingProbeClient }
        return try await reader.snapshot(for: RuntimeThemeContributionCatalog.descriptor)
    }

    func resourceSnapshot() async throws -> OpaqueResourceSnapshot {
        guard let resolver else { throw SunspireThemeTestError.missingProbeClient }
        return try await resolver.snapshot()
    }

    func resolve(_ handle: OpaqueResourceHandle) async throws -> ResolvedOpaqueResource {
        guard let resolver else { throw SunspireThemeTestError.missingProbeClient }
        return try await resolver.resolve(handle)
    }
}

private actor SunspireThemeCoordinatorProbe {
    private var client: RuntimeThemeCoordinatorClient?
    private var snapshots: [ThemeCoordinatorSnapshotDTO] = []
    private var observation: Task<Void, Never>?

    func capture(_ client: RuntimeThemeCoordinatorClient) {
        self.client = client
        observation?.cancel()
        observation = Task { [weak self] in
            for await envelope in client.stateEnvelopes {
                guard !Task.isCancelled else { return }
                await self?.record(envelope.payload)
            }
        }
    }

    private func record(_ snapshot: ThemeCoordinatorSnapshotDTO) {
        snapshots.append(snapshot)
    }

    func select(_ command: SelectThemeCodexCommand) async throws -> ThemeCoordinatorSnapshotDTO {
        guard let client else { throw SunspireThemeTestError.missingProbeClient }
        return try await client.selectCodex(command)
    }

    func resolve(_ request: ResolveThemeResourceRequestDTO) async throws -> ResolvedThemeResourceDTO {
        guard let client else { throw SunspireThemeTestError.missingProbeClient }
        return try await client.resolveResource(request)
    }

    func waitForSnapshot(
        matching predicate: @escaping @Sendable (ThemeCoordinatorSnapshotDTO) -> Bool
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        for _ in 0 ..< 400 {
            if let snapshot = snapshots.last(where: predicate) { return snapshot }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw SunspireThemeTestError.snapshotTimeout
    }
}

private enum SunspireThemeTestError: Error {
    case resourceUnavailable
    case missingProbeClient
    case snapshotTimeout
}

private func canonicalSHA256<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256Hex(try encoder.encode(value))
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
