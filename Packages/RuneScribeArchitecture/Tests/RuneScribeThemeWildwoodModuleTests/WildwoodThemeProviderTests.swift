import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeNorseThemeModule
import RuneScribeProgressionModule
import RuneScribeTestSupport
import RuneScribeThemeCoordinatorModule
@testable import RuneScribeThemeWildwoodModule
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
import XCTest

final class WildwoodThemeProviderTests: XCTestCase {
    func testFrozenIdentityBindingsAndDescriptorConformance() throws {
        let descriptor = RuneScribeThemeWildwoodModuleBootstrap.discoveryDescriptor
        XCTAssertEqual(descriptor, try WildwoodThemeDescriptorFactory.make())
        XCTAssertEqual(descriptor.moduleID.rawValue, "com.runescribe.module.theme.wildwood")
        XCTAssertEqual(descriptor.moduleRole.rawValue, "runescribe.theme.wildwood")
        XCTAssertEqual(descriptor.policyClass.rawValue, "policy.theme-provider")
        XCTAssertEqual(descriptor.criticality, .optional)
        XCTAssertEqual(descriptor.fallbackCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(descriptor.codex.id.rawValue, "codex.wildwood")
        XCTAssertEqual(descriptor.codex.entitlementID.rawValue, "unlock.codex.wildwood")
        let binding = try authoritativeBinding(for: descriptor.codex.id)
        XCTAssertEqual(binding.moduleID, RuneScribeThemeWildwoodModuleBootstrap.moduleID)
        XCTAssertEqual(binding.entitlementID, RuneScribeThemeWildwoodModuleBootstrap.unlockID)
        XCTAssertEqual(
            binding.gateRuleID?.rawValue,
            "rule.codex.wildwood.roots-of-memory"
        )

        let script = try XCTUnwrap(descriptor.codex.scripts.only)
        XCTAssertEqual(script.id.rawValue, "script.wildwood")
        XCTAssertEqual(script.portability, .fontDependent)
        XCTAssertEqual(script.glyphs.map { $0.canonicalValue }, Array(0 ..< 32).map(UInt8.init))
        XCTAssertEqual(script.glyphs.map { $0.textToken }, ThemeCanonicalSymbolSet.transportTokens)
        XCTAssertEqual(script.fontReferenceID?.rawValue, "rs-wildwood")
        XCTAssertEqual(script.fontVersion, 1)
        XCTAssertEqual(script.fontPostScriptName?.rawValue, "RavenForgeWildwoodScript-Regular")
        XCTAssertEqual(
            script.rightsID.rawValue,
            "prov.Source.Masters.Glyphs.wildwood.glyph.master.json"
        )

        XCTAssertEqual(
            descriptor.codex.shortDescription.fallbackValue,
            "Living inscriptions rooted in bark, moss, and ancient memory."
        )
        XCTAssertEqual(
            descriptor.codex.longDescription.fallbackValue,
            "An earthy Elven Codex of elderbark, moss, roots, and patient growth. Its script feels carved by hand and shaped by the memory of the forest."
        )
        XCTAssertEqual(descriptor.codex.fallbackScriptID.rawValue, "script.base-runes")
        XCTAssertEqual(
            descriptor.codex.background.displayName.fallbackValue,
            "Oldgrowth Hollow"
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
            "#0D160E",
            "#172117",
            "#1D2A1C",
            "#293726",
            "#E7E0CF",
            "#A8B396",
            "#1D2A1C",
            "#9FB77B",
            "#B7A57D",
            "#706B5B",
            "#8F9F73",
            "#5C6659",
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
            "A grounded default Relic combining broad inscription capacity with unmistakable living-forest material.",
            "A quiet, time-worn plaque optimized for short and medium inscriptions.",
            "An ancient prestige Relic with a tall inscription field and the visual weight of an old tree.",
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
            "The central Wildwood mark of continuity, memory, and belonging.",
            "A gentle nocturnal guide through old forest paths.",
            "A first-dispatch mark representing small beginnings and durable growth.",
            "A receiving mark symbolizing messages that unfurl over time.",
            "A clever woodland emblem earned through sustained Wildwood use.",
            "An encounter mark showing a Wildwood idea carried from another Scribe.",
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
            "resource.script.wildwood.accessibility.label",
            "resource.relic.wildwood.rootsong-tablet.accessibility.label",
            "resource.relic.wildwood.mossbound-plaque.accessibility.label",
            "resource.relic.wildwood.elderbark-stele.accessibility.label",
            "resource.seal.wildwood.rooted-tree.accessibility.label",
            "resource.seal.wildwood.lantern-moth.accessibility.label",
            "resource.seal.wildwood.acorn-knot.accessibility.label",
            "resource.seal.wildwood.fern-spiral.accessibility.label",
            "resource.seal.wildwood.wild-fox.accessibility.label",
            "resource.seal.wildwood.echo-seed.accessibility.label",
            "resource.frame.wildwood.living-root.accessibility.label",
            "resource.crest.wildwood.heartwood-crown.accessibility.label",
            "resource.background.wildwood.oldgrowth-hollow.accessibility.label",
            "resource.vault.wildwood.codex.accessibility.label",
        ]
        )
        XCTAssertEqual(
            acceptedAccessibility.map(\.label.fallbackValue),
            [
            "Wildwood Codex script with complete static renderer fallback.",
            "A broad bark tablet wrapped in roots and moss, with a carved tree emblem above the inscription.",
            "A rounded square plaque softened by moss and lichen, with a small leaf crest at the top.",
            "A tall dark wooden stele carved with branches and roots, standing on a rooted base.",
            "A tree with spreading branches and visible roots inside a circle.",
            "A moth with wide wings and a small lantern hanging below it.",
            "An acorn wrapped in a three-loop root knot.",
            "A curled fern frond forming a spiral.",
            "A fox head with a leaf-shaped mark on its forehead.",
            "A seed with one root inside two circular rings.",
            "Thin interlaced roots, small moss patches, four leaf buds, and strict clearance around the safe region.",
            "A small crown formed from three root arches above a central seed.",
            "Dense old forest, massive roots, moss, small fungi, filtered green-gold light, and no architectural structures.",
            "Wildwood Codex locked, encountered, owned, and selected presentation.",
        ]
        )
        XCTAssertTrue(acceptedAccessibility.allSatisfy {
            $0.hint == nil
                && $0.hidesRedundantGlyphs
                && $0.noColorOnlyState
                && $0.dynamicTypeSafe
        })

        let acceptedLayouts = descriptor.codex.relics.flatMap(\.layouts)
        XCTAssertEqual(try canonicalSHA256(acceptedLayouts), "70bc7f08db68f15d444983e6a8f2244505608e66e8d3ddf08be87ce037940e7e")
        XCTAssertEqual(try canonicalSHA256(descriptor.rights), "20db4632926c43f563f1aab9682b45fe7fc44a475aeab1ff4db9c1fa793bb8f7")
        XCTAssertEqual(descriptor.rights.count, 15)
        let acceptedMasterRightsID = ThemeProvenanceID(
            rawValue: "prov.Production.Sources.wildwood.accepted.source.masters.recipe.json"
        )!
        XCTAssertTrue(descriptor.rights.filter { $0.id != acceptedMasterRightsID }.allSatisfy {
            $0.creationDate == "2026-08-21"
                && $0.origin == .derived
                && $0.rightsOwner == "Raven Forge Software"
                && $0.licenseNotice
                    == "Owner-supplied proprietary source and approved recovery authority"
        })
        let acceptedMasterRights = try XCTUnwrap(
            descriptor.rights.first { $0.id == acceptedMasterRightsID }
        )
        XCTAssertEqual(acceptedMasterRights.creationDate, "2026-08-27")
        XCTAssertTrue(acceptedMasterRights.exportSettings.contains("\"ownerReview\":\"PENDING\""))
        let scriptRights = try XCTUnwrap(descriptor.rights.first { $0.id == script.rightsID })
        XCTAssertEqual(scriptRights.id.rawValue, "prov.Source.Masters.Glyphs.wildwood.glyph.master.json")
        XCTAssertNotEqual(scriptRights.id.rawValue, scriptRights.id.rawValue.lowercased())
        XCTAssertEqual(scriptRights.creatorTool, "macOS byte-preserving canonicalization with Python 3.9.6 hashing")
        XCTAssertEqual(scriptRights.sourceReference, "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Glyphs/wildwood/glyph-master.json")
        XCTAssertEqual(scriptRights.exportSettings, "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}")

        XCTAssertEqual(descriptor.codex.relics.count, 3)
        XCTAssertEqual(descriptor.codex.seals.count, 6)
        XCTAssertEqual(descriptor.codex.frames.count, 1)
        XCTAssertEqual(descriptor.codex.crests.count, 1)
        XCTAssertEqual(descriptor.codex.relics.filter { $0.isDefault }.count, 1)
        XCTAssertNil(descriptor.codex.background.optionalMotionResourceID)
        XCTAssertFalse(descriptor.codex.background.parallaxAllowed)
        XCTAssertEqual(WildwoodThemeResourceCatalog.productionDefinitions.count, 60)
        XCTAssertEqual(descriptor.resources.count, 61)
        XCTAssertEqual(descriptor.codex.seals.compactMap(\.colorResourceID).count, 6)
        XCTAssertTrue(descriptor.codex.seals.allSatisfy {
            $0.colorResourceID == Optional($0.standardResourceID)
        })
        XCTAssertTrue(descriptor.resources.allSatisfy { $0.requirement == .required })
        let localization = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: WildwoodThemeResourceCatalog.localizationPayload
            ) as? [String: Any]
        )
        XCTAssertEqual(localization["locale"] as? String, "en")
        XCTAssertNotNil(localization["strings"] as? [String: String])

        let references = Dictionary(uniqueKeysWithValues: descriptor.resources.map { ($0.id, $0) })
        for definition in WildwoodThemeResourceCatalog.productionDefinitions {
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
        let bundle = RuneScribeThemeWildwoodModuleBootstrap.resourceBundle
        let manifestURL = try XCTUnwrap(bundle.url(forResource: "module-manifest", withExtension: "json"))
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try ModuleManifestDecoder.decode(manifestData)
        XCTAssertEqual(manifest.moduleID, RuneScribeThemeWildwoodModuleBootstrap.moduleID)
        XCTAssertEqual(manifest.defaultRole, RuneScribeThemeWildwoodModuleBootstrap.role)
        XCTAssertEqual(manifest.effectivePolicyClass, RuneScribePolicyClasses.themeProvider)
        XCTAssertEqual(manifest.criticality, .optional)
        XCTAssertEqual(manifest.entitlementRequirement?.kind, .earned)
        XCTAssertEqual(manifest.entitlementRequirement?.identifier, RuneScribeThemeWildwoodModuleBootstrap.unlockID)
        XCTAssertEqual(Set(manifest.runtimeRequirements.requiredResources), WildwoodThemeBundledResourceCatalog.all)
        XCTAssertEqual(sha256Hex(manifestData), RuneScribeThemeWildwoodModuleBootstrap.manifestExpectedSHA256Hex)

        let integrityURL = try XCTUnwrap(bundle.url(forResource: "Resource-Integrity-Manifest-v1.0", withExtension: "json"))
        let integrityData = try Data(contentsOf: integrityURL)
        XCTAssertEqual(sha256Hex(integrityData), WildwoodV43ResourcePins.integrityManifestSHA256Hex)
        XCTAssertTrue(WildwoodThemeResourceCatalog.validateIntegrityManifest(integrityData))

        var shippingBytes = 0
        for definition in WildwoodThemeResourceCatalog.productionDefinitions {
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
        XCTAssertEqual(shippingBytes, WildwoodV43ResourcePins.productionShippingByteCount)
    }

    func testV43RoleCoverageAndExternalProvenance() throws {
        let definitions = WildwoodThemeResourceCatalog.productionDefinitions
        let roles = Set(definitions.map { $0.role.rawValue })
        XCTAssertTrue(Set([
            "background.macos-wide-crop", "panel.card-border", "panel.corner-ornament",
            "panel.divider", "panel.primary-button", "panel.tab-selector",
            "script.specimen-high-contrast", "vault.unavailable",
        ]).isSubset(of: roles))
        XCTAssertEqual(definitions.filter { $0.role.rawValue == "relic.master" }.count, 3)
        XCTAssertTrue(definitions.filter { $0.role.rawValue == "relic.master" }.allSatisfy {
            max($0.pixelWidth ?? 0, $0.pixelHeight ?? 0) >= 1_600 && $0.mediaType == .png
        })
        XCTAssertTrue(definitions.filter { $0.role.rawValue == "seal.thumbnail" }.allSatisfy {
            $0.pixelWidth == 512 && $0.pixelHeight == 512 && $0.mediaType == .png
        })
        XCTAssertFalse(definitions.contains { $0.mediaType == .heif })

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let provenanceURL = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/verification/theme-fidelity-v4-3/inventory/Wildwood-Production-Asset-Provenance-v4.3.json")
        let provenance = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)) as? [String: Any]
        )
        XCTAssertEqual(provenance["theme"] as? String, "Wildwood")
        XCTAssertEqual((provenance["outputs"] as? [[String: Any]])?.count, definitions.count)
        XCTAssertEqual(
            (provenance["targetScaleReview"] as? [String: Any])?["ownerReview"] as? String,
            "PENDING"
        )
    }

    func testLockedDiscoveryPublishesPreviewResourcesAndRestartsSafely() async throws {
        let probe = WildwoodThemeReaderProbe()
        let runtime = try await makeRuntime(locator: WildwoodThemeBundleLocator())
        try await RuneScribeThemeWildwoodModuleBootstrap.register(with: runtime)
        try await registerReaderAndUI(with: runtime, probe: probe)

        try await runtime.start()
        var runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeWildwoodModuleBootstrap.moduleID], .active)
        var contributionSnapshot = try await probe.contributionSnapshot()
        let previewContribution = try XCTUnwrap(contributionSnapshot.entries.only)
        XCTAssertEqual(
            previewContribution.value,
            RuneScribeThemeWildwoodModuleBootstrap.discoveryDescriptor
        )
        let previewResources = try await probe.resourceSnapshot()
        XCTAssertEqual(
            previewResources.resources.count,
            previewContribution.value.resources.count
        )

        try await runtime.reconcileEntitlements(try entitlementSnapshot())
        runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeWildwoodModuleBootstrap.moduleID], .active)

        contributionSnapshot = try await probe.contributionSnapshot()
        let contribution = try XCTUnwrap(contributionSnapshot.entries.only)
        XCTAssertEqual(contribution.owner.moduleID, RuneScribeThemeWildwoodModuleBootstrap.moduleID)
        XCTAssertEqual(contribution.value, RuneScribeThemeWildwoodModuleBootstrap.discoveryDescriptor)
        let opaqueSnapshot = try await probe.resourceSnapshot()
        XCTAssertEqual(opaqueSnapshot.resources.count, contribution.value.resources.count)
        for reference in contribution.value.resources {
            let resource = try await probe.resolve(
                OpaqueResourceHandle(
                    namespace: RuntimeThemeContributionCatalog.resourceNamespace(for: contribution.value.codex.id),
                    resourceID: OpaqueResourceID(rawValue: reference.id.rawValue)
                )
            )
            XCTAssertEqual(resource.metadata.ownerModuleID, RuneScribeThemeWildwoodModuleBootstrap.moduleID)
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
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeWildwoodModuleBootstrap.moduleID], .active)
        contributionSnapshot = try await probe.contributionSnapshot()
        XCTAssertEqual(contributionSnapshot.entries.count, 1)
        await runtime.stop()
    }

    func testDeferredResourceFailuresRemainIsolatedFromTheRequiredUI() async throws {
        let target = try XCTUnwrap(WildwoodThemeResourceCatalog.productionDefinitions.first)
        let handle = OpaqueResourceHandle(
            namespace: RuntimeThemeContributionCatalog.resourceNamespace(
                for: RuneScribeThemeWildwoodModuleBootstrap.codexID
            ),
            resourceID: OpaqueResourceID(rawValue: target.id.rawValue)
        )
        for mode in WildwoodThemeBundleLocator.Mode.failureModes {
            let probe = WildwoodThemeReaderProbe()
            let runtime = try await makeRuntime(locator: WildwoodThemeBundleLocator(
                mode: mode,
                target: target.resource,
                targetMaximumBytes: target.maximumByteCount
            ))
            try await RuneScribeThemeWildwoodModuleBootstrap.register(with: runtime)
            try await registerReaderAndUI(with: runtime, probe: probe)
            try await runtime.start()
            try await runtime.reconcileEntitlements(try entitlementSnapshot())
            var snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.status, .running, "mode=\(mode.rawValue)")
            XCTAssertEqual(snapshot.moduleStates[RuneScribeThemeWildwoodModuleBootstrap.moduleID], .active, "mode=\(mode.rawValue)")
            XCTAssertEqual(snapshot.moduleStates[uiModuleID(suffix: "publication")], .active, "mode=\(mode.rawValue)")
            let deferredResources = try await probe.resourceSnapshot()
            XCTAssertTrue(
                deferredResources.resources.contains { $0.handle == handle },
                "mode=\(mode.rawValue)"
            )

            do {
                _ = try await probe.resolve(handle)
                XCTFail("Deferred required resource must fail closed for mode=\(mode.rawValue)")
            } catch let failure as RuntimeVerifiedApplicationResourceFailure {
                switch (mode, failure) {
                case (.missing, .resourceUnavailable), (.overBudget, .contentTooLarge):
                    break
                case (.corrupt, .integrityMismatch(_, let actualByteCount)):
                    XCTAssertEqual(actualByteCount, 1)
                case (.wrongHash, .integrityMismatch(_, let actualByteCount)):
                    XCTAssertEqual(actualByteCount, target.byteCount)
                default:
                    XCTFail("Unexpected deferred failure \(failure) for mode=\(mode.rawValue)")
                }
            }

            snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.status, .running, "mode=\(mode.rawValue)")
            XCTAssertEqual(snapshot.moduleStates[RuneScribeThemeWildwoodModuleBootstrap.moduleID], .active, "mode=\(mode.rawValue)")
            XCTAssertEqual(snapshot.moduleStates[uiModuleID(suffix: "publication")], .active, "mode=\(mode.rawValue)")
            await runtime.stop()
        }
    }

    func testThemeCoordinatorRestoresOwnedPreferenceAndDeferredCorruptionFailsClosed()
        async throws
    {
        let store = InMemoryModuleStateStore(
            now: { Date(timeIntervalSince1970: 1_776_211_200) }
        )
        let probe = WildwoodThemeCoordinatorProbe()
        let runtime = try await makeCoordinatorRuntime(
            locator: WildwoodThemeBundleLocator(),
            store: store
        )
        try await registerCoordinatorStack(with: runtime, probe: probe)
        try await runtime.start()

        let locked = try await probe.waitForSnapshot { snapshot in
            snapshot.providers.count == 2
                && snapshot.providers.contains {
                    $0.codexID == RuneScribeThemeWildwoodModuleBootstrap.codexID
                        && $0.state == .locked
                }
        }
        XCTAssertEqual(locked.effectiveCodexID, RuneScribeCodexIDs.norse)

        try await runtime.reconcileEntitlements(try entitlementSnapshot())
        let available = try await probe.waitForSnapshot { snapshot in
            snapshot.providers.contains {
                $0.codexID == RuneScribeThemeWildwoodModuleBootstrap.codexID
                    && $0.state == .available
                    && $0.isOwned
                    && $0.isSelectable
            }
        }
        let activeRuntimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(
            activeRuntimeSnapshot.moduleStates[RuneScribeThemeWildwoodModuleBootstrap.moduleID],
            .active
        )

        let selected = try await probe.select(
            SelectThemeCodexCommand(
                codexID: RuneScribeThemeWildwoodModuleBootstrap.codexID,
                expectedSnapshotRevision: available.revision
            )
        )
        XCTAssertEqual(selected.preferredCodexID, RuneScribeThemeWildwoodModuleBootstrap.codexID)
        XCTAssertEqual(selected.effectiveCodexID, RuneScribeThemeWildwoodModuleBootstrap.codexID)
        XCTAssertEqual(selected.fallbackReason, .none)
        let fontID = try XCTUnwrap(selected.effectiveTheme.codex.scripts.first?.fontResourceID)
        let resolved = try await probe.resolve(
            ResolveThemeResourceRequestDTO(
                codexID: RuneScribeThemeWildwoodModuleBootstrap.codexID,
                resourceID: fontID
            )
        )
        XCTAssertEqual(sha256Hex(resolved.data), resolved.integrity.sha256.rawValue)
        await runtime.stop()

        let failedProbe = WildwoodThemeCoordinatorProbe()
        let target = try XCTUnwrap(WildwoodThemeResourceCatalog.productionDefinitions.first)
        let failedRuntime = try await makeCoordinatorRuntime(
            locator: WildwoodThemeBundleLocator(
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
            snapshot.preferredCodexID == RuneScribeThemeWildwoodModuleBootstrap.codexID
                && snapshot.effectiveCodexID == RuneScribeCodexIDs.norse
                && snapshot.providers.contains {
                    $0.codexID == RuneScribeThemeWildwoodModuleBootstrap.codexID
                        && $0.isOwned
                        && !$0.isSelectable
                        && $0.state == .invalidResources
                }
        }
        XCTAssertEqual(fallback.fallbackReason, .invalidResources)
        XCTAssertEqual(fallback.effectiveTheme.codex.id, RuneScribeCodexIDs.norse)
        let failedSnapshot = await failedRuntime.snapshot()
        XCTAssertEqual(
            failedSnapshot.moduleStates[RuneScribeThemeWildwoodModuleBootstrap.moduleID],
            .active
        )
        XCTAssertEqual(failedSnapshot.moduleStates[RuneScribeModuleIDs.norseTheme], .active)
        XCTAssertEqual(failedSnapshot.moduleStates[RuneScribeModuleIDs.themeCoordinator], .active)

        let failedRequest = ResolveThemeResourceRequestDTO(
            codexID: RuneScribeThemeWildwoodModuleBootstrap.codexID,
            resourceID: target.id
        )
        do {
            _ = try await failedProbe.resolve(failedRequest)
            XCTFail("Deferred corrupt resource must not be returned by the coordinator.")
        } catch let failure as ThemeCoordinatorModuleError {
            XCTAssertEqual(failure, .resourceUnavailable(failedRequest))
        }

        let afterFailure = try await failedProbe.snapshot()
        XCTAssertEqual(
            afterFailure.preferredCodexID,
            RuneScribeThemeWildwoodModuleBootstrap.codexID
        )
        XCTAssertEqual(afterFailure.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(afterFailure.fallbackReason, .invalidResources)
        await failedRuntime.stop()
    }

    func testProviderSourcesDoNotImportOrEvaluateProgressionOrPlatformLayers() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = packageRoot
            .appendingPathComponent("Sources/RuneScribeThemeWildwoodModule")
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        XCTAssertEqual(sourceURLs.count, 4)
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

    private func makeRuntime(locator: WildwoodThemeBundleLocator) async throws -> RuneScribeRuntime {
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
        locator: WildwoodThemeBundleLocator,
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
        probe: WildwoodThemeCoordinatorProbe
    ) async throws {
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeWildwoodModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        let ui = ModuleDescriptor(
            moduleID: "com.runescribe.test.wildwood.coordinator-ui",
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "WildwoodThemeCoordinatorUI",
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
                WildwoodThemeTestModule(descriptor: ui) { context in
                    await probe.capture(try await context.themeCoordinatorClient())
                }
            }
        )
    }

    private func registerReaderAndUI(
        with runtime: RuneScribeRuntime,
        probe: WildwoodThemeReaderProbe
    ) async throws {
        let reader = ModuleDescriptor(
            moduleID: "com.runescribe.test.wildwood.reader",
            moduleVersion: Self.version,
            kind: .service,
            criticality: .required,
            entryPoint: "WildwoodThemeReader",
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
                WildwoodThemeTestModule(descriptor: reader) { context in
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
                WildwoodThemeTestModule(descriptor: ui) { _ in }
            }
        )
    }

    private func registerUI(with runtime: RuneScribeRuntime, suffix: String) async throws {
        let ui = uiDescriptor(suffix: suffix, requiredRole: nil)
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                WildwoodThemeTestModule(descriptor: ui) { _ in }
            }
        )
    }

    private func uiDescriptor(suffix: String, requiredRole: ModuleRole?) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: uiModuleID(suffix: suffix),
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "WildwoodThemeUI" + suffix.replacingOccurrences(of: "-", with: "_"),
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [RuneScribeCapabilities.rootUI],
            requiredModuleRoles: Set(requiredRole.map { [$0] } ?? [])
        )
    }

    private func uiModuleID(suffix: String) -> ModuleIdentifier {
        ModuleIdentifier(rawValue: "com.runescribe.test.wildwood.ui.\(suffix)")
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
            earnedUnlockIDs: [RuneScribeThemeWildwoodModuleBootstrap.unlockID]
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

private struct WildwoodThemeTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    func start(context: ModuleContext) async throws { try await startAction(context) }
    func stop() async {}
}

private struct WildwoodThemeBundleLocator: ApplicationResourceLocator, Sendable {
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
            throw WildwoodThemeTestError.resourceUnavailable
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
        case RuneScribeThemeWildwoodModuleBootstrap.moduleID:
            bundle = RuneScribeThemeWildwoodModuleBootstrap.resourceBundle
        case RuneScribeModuleIDs.norseTheme:
            bundle = RuneScribeNorseThemeModuleBootstrap.resourceBundle
        default:
            throw WildwoodThemeTestError.resourceUnavailable
        }
        guard let url = bundle.url(
                  forResource: resource.name,
                  withExtension: resource.fileExtension,
                  subdirectory: resource.subdirectory
              )
        else { throw WildwoodThemeTestError.resourceUnavailable }
        return url
    }
}

private actor WildwoodThemeReaderProbe {
    private var reader: RuntimeContributionReaderClient?
    private var resolver: RuntimeOpaqueResourceResolverClient?

    func capture(reader: RuntimeContributionReaderClient, resolver: RuntimeOpaqueResourceResolverClient) {
        self.reader = reader
        self.resolver = resolver
    }

    func contributionSnapshot() async throws -> RuntimeContributionSnapshot<ThemeDescriptor> {
        guard let reader else { throw WildwoodThemeTestError.missingProbeClient }
        return try await reader.snapshot(for: RuntimeThemeContributionCatalog.descriptor)
    }

    func resourceSnapshot() async throws -> OpaqueResourceSnapshot {
        guard let resolver else { throw WildwoodThemeTestError.missingProbeClient }
        return try await resolver.snapshot()
    }

    func resolve(_ handle: OpaqueResourceHandle) async throws -> ResolvedOpaqueResource {
        guard let resolver else { throw WildwoodThemeTestError.missingProbeClient }
        return try await resolver.resolve(handle)
    }
}

private actor WildwoodThemeCoordinatorProbe {
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
        guard let client else { throw WildwoodThemeTestError.missingProbeClient }
        return try await client.selectCodex(command)
    }

    func resolve(_ request: ResolveThemeResourceRequestDTO) async throws -> ResolvedThemeResourceDTO {
        guard let client else { throw WildwoodThemeTestError.missingProbeClient }
        return try await client.resolveResource(request)
    }

    func snapshot() async throws -> ThemeCoordinatorSnapshotDTO {
        guard let client else { throw WildwoodThemeTestError.missingProbeClient }
        return try await client.snapshot()
    }

    func waitForSnapshot(
        matching predicate: @escaping @Sendable (ThemeCoordinatorSnapshotDTO) -> Bool
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        for _ in 0 ..< 400 {
            if let snapshot = snapshots.last(where: predicate) { return snapshot }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw WildwoodThemeTestError.snapshotTimeout
    }
}

private enum WildwoodThemeTestError: Error {
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
