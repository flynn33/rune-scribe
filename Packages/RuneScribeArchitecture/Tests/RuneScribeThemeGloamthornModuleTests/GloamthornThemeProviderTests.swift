import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeNorseThemeModule
import RuneScribeProgressionModule
import RuneScribeTestSupport
import RuneScribeThemeCoordinatorModule
@testable import RuneScribeThemeGloamthornModule
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
import XCTest

final class GloamthornThemeProviderTests: XCTestCase {
    func testFrozenIdentityBindingsAndDescriptorConformance() throws {
        let descriptor = RuneScribeThemeGloamthornModuleBootstrap.discoveryDescriptor
        XCTAssertEqual(descriptor, try GloamthornThemeDescriptorFactory.make())
        XCTAssertEqual(descriptor.moduleID.rawValue, "com.runescribe.module.theme.gloamthorn")
        XCTAssertEqual(descriptor.moduleRole.rawValue, "runescribe.theme.gloamthorn")
        XCTAssertEqual(descriptor.policyClass.rawValue, "policy.theme-provider")
        XCTAssertEqual(descriptor.criticality, .optional)
        XCTAssertEqual(descriptor.fallbackCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(descriptor.codex.id.rawValue, "codex.gloamthorn")
        XCTAssertEqual(descriptor.codex.entitlementID.rawValue, "unlock.codex.gloamthorn")
        let binding = try authoritativeBinding(for: descriptor.codex.id)
        XCTAssertEqual(binding.moduleID, RuneScribeThemeGloamthornModuleBootstrap.moduleID)
        XCTAssertEqual(binding.entitlementID, RuneScribeThemeGloamthornModuleBootstrap.unlockID)
        XCTAssertEqual(
            binding.gateRuleID?.rawValue,
            "rule.codex.gloamthorn.beyond-the-gloam"
        )

        let script = try XCTUnwrap(descriptor.codex.scripts.only)
        XCTAssertEqual(script.id.rawValue, "script.gloamthorn")
        XCTAssertEqual(script.portability, .fontDependent)
        XCTAssertEqual(script.glyphs.map { $0.canonicalValue }, Array(0 ..< 32).map(UInt8.init))
        XCTAssertEqual(script.glyphs.map { $0.textToken }, ThemeCanonicalSymbolSet.transportTokens)
        XCTAssertEqual(script.fontReferenceID?.rawValue, "rs-gloamthorn")
        XCTAssertEqual(script.fontVersion, 1)
        XCTAssertEqual(script.fontPostScriptName?.rawValue, "RavenForgeGloamthornScript-Regular")
        XCTAssertEqual(
            script.rightsID.rawValue,
            "prov.Source.Masters.Glyphs.gloamthorn.glyph.master.json"
        )

        XCTAssertEqual(
            descriptor.codex.shortDescription.fallbackValue,
            "Twilight inscriptions bound in thorn, silver, and shadow."
        )
        XCTAssertEqual(
            descriptor.codex.longDescription.fallbackValue,
            "A shadowed Elven Codex of charcoal stone, silver briar, and amethyst light. Its script is elegant, severe, and designed to feel ceremonial rather than monstrous."
        )
        XCTAssertEqual(descriptor.codex.fallbackScriptID.rawValue, "script.base-runes")
        XCTAssertEqual(
            descriptor.codex.background.displayName.fallbackValue,
            "Twilight Briar"
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
            "#090B13",
            "#111321",
            "#171A27",
            "#202437",
            "#EEE7F3",
            "#B6A9C2",
            "#171A27",
            "#A985D3",
            "#8CB6A8",
            "#67636D",
            "#8C75A3",
            "#555965",
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
            "A dark but highly legible default Relic that presents Gloamthorn as luxurious and ceremonial.",
            "A compact dark-court plaque with dense material detail and clear short-message presentation.",
            "A prestige Relic for formal long inscriptions, designed to feel aristocratic rather than hostile.",
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
            "The central Gloamthorn mark of beauty protected by restraint and consequence.",
            "An elegant nocturnal emblem suited to Gloamthorn’s refined darkness.",
            "A first-dispatch mark representing a message revealed from shadow.",
            "A receiving mark for knowledge returned carefully and deliberately.",
            "A dark-court prestige mark earned through sustained correspondence.",
            "An encounter mark showing Gloamthorn discovered through another Scribe.",
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
            "resource.script.gloamthorn.accessibility.label",
            "resource.relic.gloamthorn.nightthorn-tablet.accessibility.label",
            "resource.relic.gloamthorn.umbral-plaque.accessibility.label",
            "resource.relic.gloamthorn.duskbriar-stele.accessibility.label",
            "resource.seal.gloamthorn.thornmoon.accessibility.label",
            "resource.seal.gloamthorn.nightglass-moth.accessibility.label",
            "resource.seal.gloamthorn.eclipse-bloom.accessibility.label",
            "resource.seal.gloamthorn.veiled-serpent.accessibility.label",
            "resource.seal.gloamthorn.pact-crown.accessibility.label",
            "resource.seal.gloamthorn.echo-wisp.accessibility.label",
            "resource.frame.gloamthorn.briar-court.accessibility.label",
            "resource.crest.gloamthorn.gloam-sovereign.accessibility.label",
            "resource.background.gloamthorn.twilight-briar.accessibility.label",
            "resource.vault.gloamthorn.codex.accessibility.label",
        ]
        )
        XCTAssertEqual(
            acceptedAccessibility.map(\.label.fallbackValue),
            [
            "Gloamthorn Codex script with complete static renderer fallback.",
            "A wide charcoal tablet framed in silver thorns, with a purple crescent crest and pale violet inscription.",
            "A compact dark metal plaque with silver corners and a shadowleaf medallion.",
            "A tall black stone stele rising through silver briars with a small purple gem at its center.",
            "A silver crescent moon inside a circular thorn wreath.",
            "A dark moth with translucent violet wings.",
            "A six-petal dark flower surrounding a thin eclipse ring.",
            "A slender serpent curled around a single leaf.",
            "A narrow crown made from three silver thorns above a purple gem.",
            "A small violet wisp inside a broken silver ring.",
            "Thin silver briars, four amethyst nodes, inward-facing thorns kept outside all content safe regions.",
            "A narrow thorn crown over an eclipse ring and one central amethyst point.",
            "Deep night forest, silver thorn silhouettes, sparse amethyst glints, and a distant eclipse-like halo.",
            "Gloamthorn Codex locked, encountered, owned, and selected presentation.",
        ]
        )
        XCTAssertTrue(acceptedAccessibility.allSatisfy {
            $0.hint == nil
                && $0.hidesRedundantGlyphs
                && $0.noColorOnlyState
                && $0.dynamicTypeSafe
        })

        let acceptedLayouts = descriptor.codex.relics.flatMap(\.layouts)
        XCTAssertEqual(try canonicalSHA256(acceptedLayouts), "c7c843c351edc837170c335bbae4d853d482c2d1ca9dc4da68c36fef9be11b55")
        XCTAssertEqual(try canonicalSHA256(descriptor.rights), "3878adc01df01f5fdd8458c6ea6b458c21bd6272a4ad5cf1d23cf7da6080abe1")
        XCTAssertEqual(descriptor.rights.count, 15)
        let acceptedMasterRightsID = ThemeProvenanceID(
            rawValue: "prov.Production.Sources.gloamthorn.accepted.source.masters.recipe.json"
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
        XCTAssertEqual(scriptRights.id.rawValue, "prov.Source.Masters.Glyphs.gloamthorn.glyph.master.json")
        XCTAssertNotEqual(scriptRights.id.rawValue, scriptRights.id.rawValue.lowercased())
        XCTAssertEqual(scriptRights.creatorTool, "macOS byte-preserving canonicalization with Python 3.9.6 hashing")
        XCTAssertEqual(scriptRights.sourceReference, "/Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Elven-Series-Design-Package-v1.0/Source-Masters/Glyphs/gloamthorn/glyph-master.json")
        XCTAssertEqual(scriptRights.exportSettings, "{\"deterministic\":true,\"pipeline\":\"scripts/build-elven-production-assets.py\",\"pipelineSHA256\":\"3dd388a70763603b2f90e04ecf7de7115e050ba3bb4da69a96b35fcf727e2307\",\"toolVersions\":{\"fontTools\":\"4.60.2\",\"pillow\":\"11.3.0\",\"python\":\"3.9.6\",\"sips\":\"sips-316\"}}")

        XCTAssertEqual(descriptor.codex.relics.count, 3)
        XCTAssertEqual(descriptor.codex.seals.count, 6)
        XCTAssertEqual(descriptor.codex.frames.count, 1)
        XCTAssertEqual(descriptor.codex.crests.count, 1)
        XCTAssertEqual(descriptor.codex.relics.filter { $0.isDefault }.count, 1)
        XCTAssertNil(descriptor.codex.background.optionalMotionResourceID)
        XCTAssertFalse(descriptor.codex.background.parallaxAllowed)
        XCTAssertEqual(GloamthornThemeResourceCatalog.productionDefinitions.count, 60)
        XCTAssertEqual(descriptor.resources.count, 61)
        XCTAssertEqual(descriptor.codex.seals.compactMap(\.colorResourceID).count, 6)
        XCTAssertTrue(descriptor.codex.seals.allSatisfy {
            $0.colorResourceID == Optional($0.standardResourceID)
        })
        XCTAssertTrue(descriptor.resources.allSatisfy { $0.requirement == .required })
        let localization = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: GloamthornThemeResourceCatalog.localizationPayload
            ) as? [String: Any]
        )
        XCTAssertEqual(localization["locale"] as? String, "en")
        XCTAssertNotNil(localization["strings"] as? [String: String])

        let references = Dictionary(uniqueKeysWithValues: descriptor.resources.map { ($0.id, $0) })
        for definition in GloamthornThemeResourceCatalog.productionDefinitions {
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
        let bundle = RuneScribeThemeGloamthornModuleBootstrap.resourceBundle
        let manifestURL = try XCTUnwrap(bundle.url(forResource: "module-manifest", withExtension: "json"))
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try ModuleManifestDecoder.decode(manifestData)
        XCTAssertEqual(manifest.moduleID, RuneScribeThemeGloamthornModuleBootstrap.moduleID)
        XCTAssertEqual(manifest.defaultRole, RuneScribeThemeGloamthornModuleBootstrap.role)
        XCTAssertEqual(manifest.effectivePolicyClass, RuneScribePolicyClasses.themeProvider)
        XCTAssertEqual(manifest.criticality, .optional)
        XCTAssertEqual(manifest.entitlementRequirement?.kind, .earned)
        XCTAssertEqual(manifest.entitlementRequirement?.identifier, RuneScribeThemeGloamthornModuleBootstrap.unlockID)
        XCTAssertEqual(Set(manifest.runtimeRequirements.requiredResources), GloamthornThemeBundledResourceCatalog.all)
        XCTAssertEqual(sha256Hex(manifestData), RuneScribeThemeGloamthornModuleBootstrap.manifestExpectedSHA256Hex)

        let integrityURL = try XCTUnwrap(bundle.url(forResource: "Resource-Integrity-Manifest-v1.0", withExtension: "json"))
        let integrityData = try Data(contentsOf: integrityURL)
        XCTAssertEqual(sha256Hex(integrityData), GloamthornV43ResourcePins.integrityManifestSHA256Hex)
        XCTAssertTrue(GloamthornThemeResourceCatalog.validateIntegrityManifest(integrityData))

        var shippingBytes = 0
        for definition in GloamthornThemeResourceCatalog.productionDefinitions {
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
        XCTAssertEqual(shippingBytes, GloamthornV43ResourcePins.productionShippingByteCount)
    }

    func testV43RoleCoverageAndExternalProvenance() throws {
        let definitions = GloamthornThemeResourceCatalog.productionDefinitions
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
            .appendingPathComponent("docs/verification/theme-fidelity-v4-3/inventory/Gloamthorn-Production-Asset-Provenance-v4.3.json")
        let provenance = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)) as? [String: Any]
        )
        XCTAssertEqual(provenance["theme"] as? String, "Gloamthorn")
        XCTAssertEqual((provenance["outputs"] as? [[String: Any]])?.count, definitions.count)
        XCTAssertEqual(
            (provenance["targetScaleReview"] as? [String: Any])?["ownerReview"] as? String,
            "PENDING"
        )
        XCTAssertEqual((provenance["blockers"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((provenance["sealSourceMasters"] as? [String: Any])?.count, 6)
    }

    func testLockedDiscoveryPublishesPreviewResourcesAndRestartsSafely() async throws {
        let probe = GloamthornThemeReaderProbe()
        let runtime = try await makeRuntime(locator: GloamthornThemeBundleLocator())
        try await RuneScribeThemeGloamthornModuleBootstrap.register(with: runtime)
        try await registerReaderAndUI(with: runtime, probe: probe)

        try await runtime.start()
        var runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeGloamthornModuleBootstrap.moduleID], .active)
        var contributionSnapshot = try await probe.contributionSnapshot()
        let previewContribution = try XCTUnwrap(contributionSnapshot.entries.only)
        XCTAssertEqual(
            previewContribution.value,
            RuneScribeThemeGloamthornModuleBootstrap.discoveryDescriptor
        )
        let previewResources = try await probe.resourceSnapshot()
        XCTAssertEqual(
            previewResources.resources.count,
            previewContribution.value.resources.count
        )

        try await runtime.reconcileEntitlements(try entitlementSnapshot())
        runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeGloamthornModuleBootstrap.moduleID], .active)

        contributionSnapshot = try await probe.contributionSnapshot()
        let contribution = try XCTUnwrap(contributionSnapshot.entries.only)
        XCTAssertEqual(contribution.owner.moduleID, RuneScribeThemeGloamthornModuleBootstrap.moduleID)
        XCTAssertEqual(contribution.value, RuneScribeThemeGloamthornModuleBootstrap.discoveryDescriptor)
        let opaqueSnapshot = try await probe.resourceSnapshot()
        XCTAssertEqual(opaqueSnapshot.resources.count, contribution.value.resources.count)
        for reference in contribution.value.resources {
            let resource = try await probe.resolve(
                OpaqueResourceHandle(
                    namespace: RuntimeThemeContributionCatalog.resourceNamespace(for: contribution.value.codex.id),
                    resourceID: OpaqueResourceID(rawValue: reference.id.rawValue)
                )
            )
            XCTAssertEqual(resource.metadata.ownerModuleID, RuneScribeThemeGloamthornModuleBootstrap.moduleID)
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
        XCTAssertEqual(runtimeSnapshot.moduleStates[RuneScribeThemeGloamthornModuleBootstrap.moduleID], .active)
        contributionSnapshot = try await probe.contributionSnapshot()
        XCTAssertEqual(contributionSnapshot.entries.count, 1)
        await runtime.stop()
    }

    func testDeferredResourceFailuresRemainIsolatedFromTheRequiredUI() async throws {
        let target = try XCTUnwrap(GloamthornThemeResourceCatalog.productionDefinitions.first)
        let handle = OpaqueResourceHandle(
            namespace: RuntimeThemeContributionCatalog.resourceNamespace(
                for: RuneScribeThemeGloamthornModuleBootstrap.codexID
            ),
            resourceID: OpaqueResourceID(rawValue: target.id.rawValue)
        )
        for mode in GloamthornThemeBundleLocator.Mode.failureModes {
            let probe = GloamthornThemeReaderProbe()
            let runtime = try await makeRuntime(locator: GloamthornThemeBundleLocator(
                mode: mode,
                target: target.resource,
                targetMaximumBytes: target.maximumByteCount
            ))
            try await RuneScribeThemeGloamthornModuleBootstrap.register(with: runtime)
            try await registerReaderAndUI(with: runtime, probe: probe)
            try await runtime.start()
            try await runtime.reconcileEntitlements(try entitlementSnapshot())
            var snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.status, .running, "mode=\(mode.rawValue)")
            XCTAssertEqual(snapshot.moduleStates[RuneScribeThemeGloamthornModuleBootstrap.moduleID], .active, "mode=\(mode.rawValue)")
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
            XCTAssertEqual(snapshot.moduleStates[RuneScribeThemeGloamthornModuleBootstrap.moduleID], .active, "mode=\(mode.rawValue)")
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
        let probe = GloamthornThemeCoordinatorProbe()
        let runtime = try await makeCoordinatorRuntime(
            locator: GloamthornThemeBundleLocator(),
            store: store
        )
        try await registerCoordinatorStack(with: runtime, probe: probe)
        try await runtime.start()

        let locked = try await probe.waitForSnapshot { snapshot in
            snapshot.providers.count == 2
                && snapshot.providers.contains {
                    $0.codexID == RuneScribeThemeGloamthornModuleBootstrap.codexID
                        && $0.state == .locked
                }
        }
        XCTAssertEqual(locked.effectiveCodexID, RuneScribeCodexIDs.norse)

        try await runtime.reconcileEntitlements(try entitlementSnapshot())
        let available = try await probe.waitForSnapshot { snapshot in
            snapshot.providers.contains {
                $0.codexID == RuneScribeThemeGloamthornModuleBootstrap.codexID
                    && $0.state == .available
                    && $0.isOwned
                    && $0.isSelectable
            }
        }
        let activeRuntimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(
            activeRuntimeSnapshot.moduleStates[RuneScribeThemeGloamthornModuleBootstrap.moduleID],
            .active
        )

        let selected = try await probe.select(
            SelectThemeCodexCommand(
                codexID: RuneScribeThemeGloamthornModuleBootstrap.codexID,
                expectedSnapshotRevision: available.revision
            )
        )
        XCTAssertEqual(selected.preferredCodexID, RuneScribeThemeGloamthornModuleBootstrap.codexID)
        XCTAssertEqual(selected.effectiveCodexID, RuneScribeThemeGloamthornModuleBootstrap.codexID)
        XCTAssertEqual(selected.fallbackReason, .none)
        let fontID = try XCTUnwrap(selected.effectiveTheme.codex.scripts.first?.fontResourceID)
        let resolved = try await probe.resolve(
            ResolveThemeResourceRequestDTO(
                codexID: RuneScribeThemeGloamthornModuleBootstrap.codexID,
                resourceID: fontID
            )
        )
        XCTAssertEqual(sha256Hex(resolved.data), resolved.integrity.sha256.rawValue)
        await runtime.stop()

        let failedProbe = GloamthornThemeCoordinatorProbe()
        let target = try XCTUnwrap(GloamthornThemeResourceCatalog.productionDefinitions.first)
        let failedRuntime = try await makeCoordinatorRuntime(
            locator: GloamthornThemeBundleLocator(
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
            snapshot.preferredCodexID == RuneScribeThemeGloamthornModuleBootstrap.codexID
                && snapshot.effectiveCodexID == RuneScribeCodexIDs.norse
                && snapshot.providers.contains {
                    $0.codexID == RuneScribeThemeGloamthornModuleBootstrap.codexID
                        && $0.isOwned
                        && !$0.isSelectable
                        && $0.state == .invalidResources
                }
        }
        XCTAssertEqual(fallback.fallbackReason, .invalidResources)
        XCTAssertEqual(fallback.effectiveTheme.codex.id, RuneScribeCodexIDs.norse)
        let failedSnapshot = await failedRuntime.snapshot()
        XCTAssertEqual(
            failedSnapshot.moduleStates[RuneScribeThemeGloamthornModuleBootstrap.moduleID],
            .active
        )
        XCTAssertEqual(failedSnapshot.moduleStates[RuneScribeModuleIDs.norseTheme], .active)
        XCTAssertEqual(failedSnapshot.moduleStates[RuneScribeModuleIDs.themeCoordinator], .active)

        let failedRequest = ResolveThemeResourceRequestDTO(
            codexID: RuneScribeThemeGloamthornModuleBootstrap.codexID,
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
            RuneScribeThemeGloamthornModuleBootstrap.codexID
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
            .appendingPathComponent("Sources/RuneScribeThemeGloamthornModule")
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

    private func makeRuntime(locator: GloamthornThemeBundleLocator) async throws -> RuneScribeRuntime {
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
        locator: GloamthornThemeBundleLocator,
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
        probe: GloamthornThemeCoordinatorProbe
    ) async throws {
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeGloamthornModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        let ui = ModuleDescriptor(
            moduleID: "com.runescribe.test.gloamthorn.coordinator-ui",
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "GloamthornThemeCoordinatorUI",
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
                GloamthornThemeTestModule(descriptor: ui) { context in
                    await probe.capture(try await context.themeCoordinatorClient())
                }
            }
        )
    }

    private func registerReaderAndUI(
        with runtime: RuneScribeRuntime,
        probe: GloamthornThemeReaderProbe
    ) async throws {
        let reader = ModuleDescriptor(
            moduleID: "com.runescribe.test.gloamthorn.reader",
            moduleVersion: Self.version,
            kind: .service,
            criticality: .required,
            entryPoint: "GloamthornThemeReader",
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
                GloamthornThemeTestModule(descriptor: reader) { context in
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
                GloamthornThemeTestModule(descriptor: ui) { _ in }
            }
        )
    }

    private func registerUI(with runtime: RuneScribeRuntime, suffix: String) async throws {
        let ui = uiDescriptor(suffix: suffix, requiredRole: nil)
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                GloamthornThemeTestModule(descriptor: ui) { _ in }
            }
        )
    }

    private func uiDescriptor(suffix: String, requiredRole: ModuleRole?) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: uiModuleID(suffix: suffix),
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "GloamthornThemeUI" + suffix.replacingOccurrences(of: "-", with: "_"),
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [RuneScribeCapabilities.rootUI],
            requiredModuleRoles: Set(requiredRole.map { [$0] } ?? [])
        )
    }

    private func uiModuleID(suffix: String) -> ModuleIdentifier {
        ModuleIdentifier(rawValue: "com.runescribe.test.gloamthorn.ui.\(suffix)")
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
            earnedUnlockIDs: [RuneScribeThemeGloamthornModuleBootstrap.unlockID]
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

private struct GloamthornThemeTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    func start(context: ModuleContext) async throws { try await startAction(context) }
    func stop() async {}
}

private struct GloamthornThemeBundleLocator: ApplicationResourceLocator, Sendable {
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
            throw GloamthornThemeTestError.resourceUnavailable
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
        case RuneScribeThemeGloamthornModuleBootstrap.moduleID:
            bundle = RuneScribeThemeGloamthornModuleBootstrap.resourceBundle
        case RuneScribeModuleIDs.norseTheme:
            bundle = RuneScribeNorseThemeModuleBootstrap.resourceBundle
        default:
            throw GloamthornThemeTestError.resourceUnavailable
        }
        guard let url = bundle.url(
                  forResource: resource.name,
                  withExtension: resource.fileExtension,
                  subdirectory: resource.subdirectory
              )
        else { throw GloamthornThemeTestError.resourceUnavailable }
        return url
    }
}

private actor GloamthornThemeReaderProbe {
    private var reader: RuntimeContributionReaderClient?
    private var resolver: RuntimeOpaqueResourceResolverClient?

    func capture(reader: RuntimeContributionReaderClient, resolver: RuntimeOpaqueResourceResolverClient) {
        self.reader = reader
        self.resolver = resolver
    }

    func contributionSnapshot() async throws -> RuntimeContributionSnapshot<ThemeDescriptor> {
        guard let reader else { throw GloamthornThemeTestError.missingProbeClient }
        return try await reader.snapshot(for: RuntimeThemeContributionCatalog.descriptor)
    }

    func resourceSnapshot() async throws -> OpaqueResourceSnapshot {
        guard let resolver else { throw GloamthornThemeTestError.missingProbeClient }
        return try await resolver.snapshot()
    }

    func resolve(_ handle: OpaqueResourceHandle) async throws -> ResolvedOpaqueResource {
        guard let resolver else { throw GloamthornThemeTestError.missingProbeClient }
        return try await resolver.resolve(handle)
    }
}

private actor GloamthornThemeCoordinatorProbe {
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
        guard let client else { throw GloamthornThemeTestError.missingProbeClient }
        return try await client.selectCodex(command)
    }

    func resolve(_ request: ResolveThemeResourceRequestDTO) async throws -> ResolvedThemeResourceDTO {
        guard let client else { throw GloamthornThemeTestError.missingProbeClient }
        return try await client.resolveResource(request)
    }

    func snapshot() async throws -> ThemeCoordinatorSnapshotDTO {
        guard let client else { throw GloamthornThemeTestError.missingProbeClient }
        return try await client.snapshot()
    }

    func waitForSnapshot(
        matching predicate: @escaping @Sendable (ThemeCoordinatorSnapshotDTO) -> Bool
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        for _ in 0 ..< 400 {
            if let snapshot = snapshots.last(where: predicate) { return snapshot }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw GloamthornThemeTestError.snapshotTimeout
    }
}

private enum GloamthornThemeTestError: Error {
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
