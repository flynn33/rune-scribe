import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeNorseThemeModule
import RuneScribeProgressionModule
import RuneScribeTestSupport
import RuneScribeThemeCoordinatorModule
@testable import RuneScribeThemeMoonleafModule
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
import XCTest

final class MoonleafThemeProviderTests: XCTestCase {
    func testFrozenIdentityBindingsAndDescriptorConformance() throws {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        XCTAssertEqual(descriptor, try MoonleafThemeDescriptorFactory.make())
        XCTAssertEqual(descriptor.moduleID.rawValue, "com.runescribe.module.theme.moonleaf")
        XCTAssertEqual(descriptor.moduleRole.rawValue, "runescribe.theme.moonleaf")
        XCTAssertEqual(descriptor.policyClass.rawValue, "policy.theme-provider")
        XCTAssertEqual(descriptor.criticality, .optional)
        XCTAssertEqual(descriptor.fallbackCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(descriptor.codex.id.rawValue, "codex.moonleaf")
        XCTAssertEqual(descriptor.codex.entitlementID.rawValue, "unlock.codex.moonleaf")
        let binding = try authoritativeBinding(for: descriptor.codex.id)
        XCTAssertEqual(binding.moduleID, RuneScribeThemeMoonleafModuleBootstrap.moduleID)
        XCTAssertEqual(binding.entitlementID, RuneScribeThemeMoonleafModuleBootstrap.unlockID)
        XCTAssertEqual(
            binding.gateRuleID?.rawValue,
            "rule.codex.moonleaf.known-in-five-circles"
        )

        let script = try XCTUnwrap(descriptor.codex.scripts.only)
        XCTAssertEqual(script.id.rawValue, "script.moonleaf")
        XCTAssertEqual(script.portability, .fontDependent)
        XCTAssertEqual(script.glyphs.map { $0.canonicalValue }, Array(0 ..< 32).map(UInt8.init))
        XCTAssertEqual(script.glyphs.map { $0.textToken }, ThemeCanonicalSymbolSet.transportTokens)
        XCTAssertEqual(script.fontReferenceID?.rawValue, "rs-moonleaf")
        XCTAssertEqual(script.fontVersion, 1)
        XCTAssertEqual(script.fontPostScriptName?.rawValue, "RavenForgeMoonleafScript-Regular")
        XCTAssertEqual(
            script.rightsID.rawValue,
            "prov.Source.Masters.Glyphs.moonleaf.glyph.master.json"
        )

        XCTAssertEqual(
            descriptor.codex.shortDescription.fallbackValue,
            "Moonlit inscriptions shaped in silver vine and pale stone."
        )
        XCTAssertEqual(
            descriptor.codex.longDescription.fallbackValue,
            "A serene Elven Codex of moonstone, silverwood, and living vinework. Its script carries the quiet cadence of leaves beneath a night sky."
        )
        XCTAssertEqual(descriptor.codex.fallbackScriptID.rawValue, "script.base-runes")
        XCTAssertEqual(
            descriptor.codex.background.displayName.fallbackValue,
            "Moonlit Canopy"
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
            "#071A18",
            "#0D2925",
            "#102B28",
            "#173C36",
            "#F4EEE4",
            "#A9C1B8",
            "#102B28",
            "#7FD3B0",
            "#C8D6D0",
            "#756E64",
            "#8BA99E",
            "#5E6865",
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
            "A broad, serene inscription surface designed for the widest range of message lengths.",
            "A more intimate woodland Relic whose living border frames short and medium inscriptions.",
            "A prestige Relic optimized for narrow vertical inscriptions and ceremonial presentation.",
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
            "The Moonleaf Codex’s primary mark of calm, secrecy, and renewal.",
            "A dignified woodland emblem representing watchfulness and ancient paths.",
            "A quiet watcher earned through the first Moonleaf dispatch.",
            "A symbol of receiving, reflection, and messages returned.",
            "A luminous bloom awarded after sustained Moonleaf correspondence.",
            "An encounter mark showing that Moonleaf was discovered through another Scribe.",
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
            "resource.script.moonleaf.accessibility.label",
            "resource.relic.moonleaf.tablet.accessibility.label",
            "resource.relic.moonleaf.ivybound-plaque.accessibility.label",
            "resource.relic.moonleaf.whisperbark-stele.accessibility.label",
            "resource.seal.moonleaf.crescentleaf.accessibility.label",
            "resource.seal.moonleaf.woodland-stag.accessibility.label",
            "resource.seal.moonleaf.night-owl.accessibility.label",
            "resource.seal.moonleaf.moonwell.accessibility.label",
            "resource.seal.moonleaf.starflower.accessibility.label",
            "resource.seal.moonleaf.echo-firefly.accessibility.label",
            "resource.frame.moonleaf.silvervine.accessibility.label",
            "resource.crest.moonleaf.moonbloom.accessibility.label",
            "resource.background.moonleaf.moonlit-canopy.accessibility.label",
            "resource.vault.moonleaf.codex.accessibility.label",
        ]
        )
        XCTAssertEqual(
            acceptedAccessibility.map(\.label.fallbackValue),
            [
            "Moonleaf Codex script with complete static renderer fallback.",
            "A pale rectangular moonstone tablet framed by silver leaves, with a crescent crest and a blue-white gem.",
            "A weathered square plaque ringed by living ivy and antique silver, with a quiet crescent motif.",
            "A tall carved wooden stele with glowing grain, a branch crown, and roots gathered at its base.",
            "A silver crescent moon wrapped around a small leafy branch.",
            "A pale stag with branching antlers inside a circular leafy seal.",
            "A silver owl beneath a small crescent moon.",
            "A crescent moon reflected in a round pool with three ripples.",
            "A pale six-petal flower with a star at its center.",
            "A small firefly surrounded by two glow rings.",
            "Thin silver vines, four leaf clusters, one moon gem, and no intrusion into the inscription safe region.",
            "A crescent rising behind a three-leaf bloom in a small circular silver crest.",
            "Deep forest canopy, soft moonbeams, sparse fireflies, silver-green foliage, and no identifiable architecture.",
            "Moonleaf Codex locked, encountered, owned, and selected presentation.",
        ]
        )
        XCTAssertTrue(acceptedAccessibility.allSatisfy {
            $0.hint == nil
                && $0.hidesRedundantGlyphs
                && $0.noColorOnlyState
                && $0.dynamicTypeSafe
        })

        let acceptedLayouts = descriptor.codex.relics.flatMap(\.layouts)
        XCTAssertEqual(try canonicalSHA256(acceptedLayouts), "6756791f21060d0ce0af53340a795ce7a7ea43d1334d2bd3f600610f0f086038")
        XCTAssertEqual(try canonicalSHA256(descriptor.rights), "fd7ec9de7c554cb7c9ab8c57ab0607dc7c60534e5f768636aaa48081fb89f21f")
        XCTAssertEqual(descriptor.rights.count, 14)
        XCTAssertTrue(descriptor.rights.allSatisfy {
            $0.creationDate == "2026-08-21"
                && $0.origin == .derived
                && $0.rightsOwner == "Raven Forge Software"
                && $0.licenseNotice
                    == "Owner-supplied proprietary source and approved recovery authority"
        })
        let scriptRights = try XCTUnwrap(descriptor.rights.first { $0.id == script.rightsID })
        XCTAssertEqual(scriptRights.id.rawValue, "prov.Source.Masters.Glyphs.moonleaf.glyph.master.json")
        XCTAssertNotEqual(scriptRights.id.rawValue, scriptRights.id.rawValue.lowercased())
        XCTAssertEqual(scriptRights.creatorTool, "macOS byte-preserving canonicalization with Python 3.9.6 hashing")
        XCTAssertEqual(scriptRights.sourceReference, "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Glyphs/moonleaf/glyph-master.json")
        XCTAssertEqual(scriptRights.exportSettings, "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}")

        XCTAssertEqual(descriptor.codex.relics.count, 3)
        XCTAssertEqual(descriptor.codex.seals.count, 6)
        XCTAssertEqual(descriptor.codex.frames.count, 1)
        XCTAssertEqual(descriptor.codex.crests.count, 1)
        XCTAssertEqual(descriptor.codex.relics.filter { $0.isDefault }.count, 1)
        XCTAssertNil(descriptor.codex.background.optionalMotionResourceID)
        XCTAssertFalse(descriptor.codex.background.parallaxAllowed)
        XCTAssertEqual(MoonleafThemeResourceCatalog.productionDefinitions.count, 46)
        XCTAssertEqual(descriptor.resources.count, 47)
        XCTAssertTrue(descriptor.resources.allSatisfy { $0.requirement == .required })
        let localization = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: MoonleafThemeResourceCatalog.localizationPayload
            ) as? [String: Any]
        )
        XCTAssertEqual(localization["locale"] as? String, "en")
        XCTAssertNotNil(localization["strings"] as? [String: String])

        let references = Dictionary(uniqueKeysWithValues: descriptor.resources.map { ($0.id, $0) })
        for definition in MoonleafThemeResourceCatalog.productionDefinitions {
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
        let bundle = RuneScribeThemeMoonleafModuleBootstrap.resourceBundle
        let manifestURL = try XCTUnwrap(bundle.url(forResource: "module-manifest", withExtension: "json"))
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try ModuleManifestDecoder.decode(manifestData)
        XCTAssertEqual(manifest.moduleID, RuneScribeThemeMoonleafModuleBootstrap.moduleID)
        XCTAssertEqual(manifest.defaultRole, RuneScribeThemeMoonleafModuleBootstrap.role)
        XCTAssertEqual(manifest.effectivePolicyClass, RuneScribePolicyClasses.themeProvider)
        XCTAssertEqual(manifest.criticality, .optional)
        XCTAssertEqual(manifest.entitlementRequirement?.kind, .earned)
        XCTAssertEqual(manifest.entitlementRequirement?.identifier, RuneScribeThemeMoonleafModuleBootstrap.unlockID)
        XCTAssertEqual(Set(manifest.runtimeRequirements.requiredResources), MoonleafThemeBundledResourceCatalog.all)
        XCTAssertEqual(sha256Hex(manifestData), RuneScribeThemeMoonleafModuleBootstrap.manifestExpectedSHA256Hex)

        let integrityURL = try XCTUnwrap(bundle.url(forResource: "Resource-Integrity-Manifest-v1.0", withExtension: "json"))
        let integrityData = try Data(contentsOf: integrityURL)
        XCTAssertEqual(sha256Hex(integrityData), "e7222671993ad13ff4f3c72dd048f31f49295a1412e1f365d9fd904ef0b4c633")
        XCTAssertTrue(MoonleafThemeResourceCatalog.validateIntegrityManifest(integrityData))

        var shippingBytes = 0
        for definition in MoonleafThemeResourceCatalog.productionDefinitions {
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
        XCTAssertEqual(shippingBytes, 678743)
    }

    func testLockedDiscoveryPublishesPreviewResourcesAndRestartsSafely() async throws {
        let probe = MoonleafThemeReaderProbe()
        let runtime = try await makeRuntime(locator: MoonleafThemeBundleLocator())
        try await RuneScribeThemeMoonleafModuleBootstrap.register(with: runtime)
        try await registerReaderAndUI(with: runtime, probe: probe)

        try await runtime.start()
        var runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeMoonleafModuleBootstrap.moduleID], .active)
        var contributionSnapshot = try await probe.contributionSnapshot()
        let previewContribution = try XCTUnwrap(contributionSnapshot.entries.only)
        XCTAssertEqual(
            previewContribution.value,
            RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        )
        let previewResources = try await probe.resourceSnapshot()
        XCTAssertEqual(
            previewResources.resources.count,
            previewContribution.value.resources.count
        )

        try await runtime.reconcileEntitlements(try entitlementSnapshot())
        runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeMoonleafModuleBootstrap.moduleID], .active)

        contributionSnapshot = try await probe.contributionSnapshot()
        let contribution = try XCTUnwrap(contributionSnapshot.entries.only)
        XCTAssertEqual(contribution.owner.moduleID, RuneScribeThemeMoonleafModuleBootstrap.moduleID)
        XCTAssertEqual(contribution.value, RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor)
        let opaqueSnapshot = try await probe.resourceSnapshot()
        XCTAssertEqual(opaqueSnapshot.resources.count, contribution.value.resources.count)
        for reference in contribution.value.resources {
            let resource = try await probe.resolve(
                OpaqueResourceHandle(
                    namespace: RuntimeThemeContributionCatalog.resourceNamespace(for: contribution.value.codex.id),
                    resourceID: OpaqueResourceID(rawValue: reference.id.rawValue)
                )
            )
            XCTAssertEqual(resource.metadata.ownerModuleID, RuneScribeThemeMoonleafModuleBootstrap.moduleID)
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
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeMoonleafModuleBootstrap.moduleID], .active)
        contributionSnapshot = try await probe.contributionSnapshot()
        XCTAssertEqual(contributionSnapshot.entries.count, 1)
        await runtime.stop()
    }

    func testResourceFailuresRemainIsolatedFromTheRequiredUI() async throws {
        let first = try XCTUnwrap(MoonleafThemeResourceCatalog.productionDefinitions.first)
        for mode in MoonleafThemeBundleLocator.Mode.failureModes {
            let runtime = try await makeRuntime(locator: MoonleafThemeBundleLocator(mode: mode, target: first.resource, targetMaximumBytes: first.maximumByteCount))
            try await RuneScribeThemeMoonleafModuleBootstrap.register(with: runtime)
            try await registerUI(with: runtime, suffix: mode.rawValue)
            try await runtime.start()
            try await runtime.reconcileEntitlements(try entitlementSnapshot())
            let snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.status, .running, "mode=\(mode.rawValue)")
            XCTAssertEqual(snapshot.moduleStates[RuneScribeThemeMoonleafModuleBootstrap.moduleID], .failed, "mode=\(mode.rawValue)")
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
        let probe = MoonleafThemeCoordinatorProbe()
        let runtime = try await makeCoordinatorRuntime(
            locator: MoonleafThemeBundleLocator(),
            store: store
        )
        try await registerCoordinatorStack(with: runtime, probe: probe)
        try await runtime.start()

        let locked = try await probe.waitForSnapshot { snapshot in
            snapshot.providers.count == 2
                && snapshot.providers.contains {
                    $0.codexID == RuneScribeThemeMoonleafModuleBootstrap.codexID
                        && $0.state == .locked
                }
        }
        XCTAssertEqual(locked.effectiveCodexID, RuneScribeCodexIDs.norse)

        try await runtime.reconcileEntitlements(try entitlementSnapshot())
        let available = try await probe.waitForSnapshot { snapshot in
            snapshot.providers.contains {
                $0.codexID == RuneScribeThemeMoonleafModuleBootstrap.codexID
                    && $0.state == .available
                    && $0.isOwned
                    && $0.isSelectable
            }
        }
        let activeRuntimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(
            activeRuntimeSnapshot.moduleStates[RuneScribeThemeMoonleafModuleBootstrap.moduleID],
            .active
        )

        let selected = try await probe.select(
            SelectThemeCodexCommand(
                codexID: RuneScribeThemeMoonleafModuleBootstrap.codexID,
                expectedSnapshotRevision: available.revision
            )
        )
        XCTAssertEqual(selected.preferredCodexID, RuneScribeThemeMoonleafModuleBootstrap.codexID)
        XCTAssertEqual(selected.effectiveCodexID, RuneScribeThemeMoonleafModuleBootstrap.codexID)
        XCTAssertEqual(selected.fallbackReason, .none)
        let fontID = try XCTUnwrap(selected.effectiveTheme.codex.scripts.first?.fontResourceID)
        let resolved = try await probe.resolve(
            ResolveThemeResourceRequestDTO(
                codexID: RuneScribeThemeMoonleafModuleBootstrap.codexID,
                resourceID: fontID
            )
        )
        XCTAssertEqual(sha256Hex(resolved.data), resolved.integrity.sha256.rawValue)
        await runtime.stop()

        let failedProbe = MoonleafThemeCoordinatorProbe()
        let target = try XCTUnwrap(MoonleafThemeResourceCatalog.productionDefinitions.first)
        let failedRuntime = try await makeCoordinatorRuntime(
            locator: MoonleafThemeBundleLocator(
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
            snapshot.preferredCodexID == RuneScribeThemeMoonleafModuleBootstrap.codexID
                && snapshot.effectiveCodexID == RuneScribeCodexIDs.norse
                && snapshot.providers.contains {
                    $0.codexID == RuneScribeThemeMoonleafModuleBootstrap.codexID
                        && $0.isOwned
                        && !$0.isSelectable
                }
        }
        XCTAssertEqual(fallback.fallbackReason, .unavailable)
        XCTAssertEqual(fallback.effectiveTheme.codex.id, RuneScribeCodexIDs.norse)
        let failedSnapshot = await failedRuntime.snapshot()
        XCTAssertEqual(
            failedSnapshot.moduleStates[RuneScribeThemeMoonleafModuleBootstrap.moduleID],
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
            .appendingPathComponent("Sources/RuneScribeThemeMoonleafModule")
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

    private func makeRuntime(locator: MoonleafThemeBundleLocator) async throws -> RuneScribeRuntime {
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
        locator: MoonleafThemeBundleLocator,
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
        probe: MoonleafThemeCoordinatorProbe
    ) async throws {
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeMoonleafModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        let ui = ModuleDescriptor(
            moduleID: "com.runescribe.test.moonleaf.coordinator-ui",
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "MoonleafThemeCoordinatorUI",
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
                MoonleafThemeTestModule(descriptor: ui) { context in
                    await probe.capture(try await context.themeCoordinatorClient())
                }
            }
        )
    }

    private func registerReaderAndUI(
        with runtime: RuneScribeRuntime,
        probe: MoonleafThemeReaderProbe
    ) async throws {
        let reader = ModuleDescriptor(
            moduleID: "com.runescribe.test.moonleaf.reader",
            moduleVersion: Self.version,
            kind: .service,
            criticality: .required,
            entryPoint: "MoonleafThemeReader",
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
                MoonleafThemeTestModule(descriptor: reader) { context in
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
                MoonleafThemeTestModule(descriptor: ui) { _ in }
            }
        )
    }

    private func registerUI(with runtime: RuneScribeRuntime, suffix: String) async throws {
        let ui = uiDescriptor(suffix: suffix, requiredRole: nil)
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                MoonleafThemeTestModule(descriptor: ui) { _ in }
            }
        )
    }

    private func uiDescriptor(suffix: String, requiredRole: ModuleRole?) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: uiModuleID(suffix: suffix),
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "MoonleafThemeUI" + suffix.replacingOccurrences(of: "-", with: "_"),
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [RuneScribeCapabilities.rootUI],
            requiredModuleRoles: Set(requiredRole.map { [$0] } ?? [])
        )
    }

    private func uiModuleID(suffix: String) -> ModuleIdentifier {
        ModuleIdentifier(rawValue: "com.runescribe.test.moonleaf.ui.\(suffix)")
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
            earnedUnlockIDs: [RuneScribeThemeMoonleafModuleBootstrap.unlockID]
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

private struct MoonleafThemeTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    func start(context: ModuleContext) async throws { try await startAction(context) }
    func stop() async {}
}

private struct MoonleafThemeBundleLocator: ApplicationResourceLocator, Sendable {
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
            throw MoonleafThemeTestError.resourceUnavailable
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
        case RuneScribeThemeMoonleafModuleBootstrap.moduleID:
            bundle = RuneScribeThemeMoonleafModuleBootstrap.resourceBundle
        case RuneScribeModuleIDs.norseTheme:
            bundle = RuneScribeNorseThemeModuleBootstrap.resourceBundle
        default:
            throw MoonleafThemeTestError.resourceUnavailable
        }
        guard let url = bundle.url(
                  forResource: resource.name,
                  withExtension: resource.fileExtension,
                  subdirectory: resource.subdirectory
              )
        else { throw MoonleafThemeTestError.resourceUnavailable }
        return url
    }
}

private actor MoonleafThemeReaderProbe {
    private var reader: RuntimeContributionReaderClient?
    private var resolver: RuntimeOpaqueResourceResolverClient?

    func capture(reader: RuntimeContributionReaderClient, resolver: RuntimeOpaqueResourceResolverClient) {
        self.reader = reader
        self.resolver = resolver
    }

    func contributionSnapshot() async throws -> RuntimeContributionSnapshot<ThemeDescriptor> {
        guard let reader else { throw MoonleafThemeTestError.missingProbeClient }
        return try await reader.snapshot(for: RuntimeThemeContributionCatalog.descriptor)
    }

    func resourceSnapshot() async throws -> OpaqueResourceSnapshot {
        guard let resolver else { throw MoonleafThemeTestError.missingProbeClient }
        return try await resolver.snapshot()
    }

    func resolve(_ handle: OpaqueResourceHandle) async throws -> ResolvedOpaqueResource {
        guard let resolver else { throw MoonleafThemeTestError.missingProbeClient }
        return try await resolver.resolve(handle)
    }
}

private actor MoonleafThemeCoordinatorProbe {
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
        guard let client else { throw MoonleafThemeTestError.missingProbeClient }
        return try await client.selectCodex(command)
    }

    func resolve(_ request: ResolveThemeResourceRequestDTO) async throws -> ResolvedThemeResourceDTO {
        guard let client else { throw MoonleafThemeTestError.missingProbeClient }
        return try await client.resolveResource(request)
    }

    func waitForSnapshot(
        matching predicate: @escaping @Sendable (ThemeCoordinatorSnapshotDTO) -> Bool
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        for _ in 0 ..< 400 {
            if let snapshot = snapshots.last(where: predicate) { return snapshot }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw MoonleafThemeTestError.snapshotTimeout
    }
}

private enum MoonleafThemeTestError: Error {
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
