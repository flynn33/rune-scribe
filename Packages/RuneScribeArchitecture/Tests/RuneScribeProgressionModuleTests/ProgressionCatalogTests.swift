import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import Testing
@testable import RuneScribeProgressionModule

@Test
func bundledCatalogDecodesWithExactInventory() throws {
    let bundle = try validatedBundle()

    #expect(bundle.catalog.content.count == 84)
    #expect(bundle.catalog.statistics.count == 18)
    #expect(bundle.catalog.achievements.count == 15)
    #expect(bundle.catalog.milestones.count == 30)
    #expect(bundle.catalog.grantGroups.count == 45)
    #expect(bundle.eventCatalog.events.count == 9)
    #expect(bundle.futureThemeBindings.bindings.count == 5)
    #expect(bundle.catalog.orderedJourneyNodes.map(\.order) == [0, 1, 2, 3, 4])
    #expect(bundle.integrityMetadata.catalogSHA256.rawValue ==
        ProgressionCatalogResourceCatalog.catalogDescriptor.expectedSHA256Hex)
    #expect(bundle.integrityMetadata.eventCatalogSHA256.rawValue ==
        ProgressionCatalogResourceCatalog.eventCatalogDescriptor.expectedSHA256Hex)
}

@Test
func elvenMasteryTitlesAndGrantBindingsMatchCanonicalAuthority() throws {
    let bundle = try validatedBundle()
    let expected: [String: (name: String, codexID: String, grantGroupID: String)] = [
        "title.gloamthorn.mastery": (
            "Sovereign of the Gloam",
            "codex.gloamthorn",
            "grant-group.codex.gloamthorn.mastery"
        ),
        "title.moonleaf.mastery": (
            "Moonleaf Master",
            "codex.moonleaf",
            "grant-group.codex.moonleaf.mastery"
        ),
        "title.sunspire.mastery": (
            "Bearer of First Light",
            "codex.sunspire",
            "grant-group.codex.sunspire.mastery"
        ),
        "title.wildwood.mastery": (
            "Keeper of the Heartwood",
            "codex.wildwood",
            "grant-group.codex.wildwood.mastery"
        ),
    ]

    for (rawTitleID, value) in expected {
        let titleID = try #require(ProgressionContentID(rawValue: rawTitleID))
        let title = try #require(bundle.catalog.content(id: titleID))
        #expect(title.kind == .title)
        #expect(title.displayName == value.name)
        #expect(title.countsAsArtifact == false)
        #expect(title.availability == .permanentMastery)
        #expect(title.rarity == .mythic)
        #expect(title.codexID?.rawValue == value.codexID)

        let grantGroupID = try #require(GrantGroupID(rawValue: value.grantGroupID))
        let group = try #require(bundle.catalog.grantGroup(id: grantGroupID))
        #expect(group.items.last?.contentID == titleID)
        #expect(group.items.last?.grantKind == .permanent)
        #expect(group.revealTier == .mastery)
        #expect(group.primaryContentID != titleID)
    }

    let fingerprints = try ProgressionCatalogCompatibility.fingerprints(for: bundle)
    #expect(fingerprints.count == 318)
    let indexed = Dictionary(uniqueKeysWithValues: fingerprints.map {
        ($0.stableKey, $0.semanticDigest)
    })
    #expect(indexed["content:title.gloamthorn.mastery"] ==
        "7dd81dfcee4195faf62b30906f200b8c")
    #expect(indexed["content:title.moonleaf.mastery"] ==
        "4f06f1c85fe23bdf16175c5ca30c8087")
    #expect(indexed["content:title.sunspire.mastery"] ==
        "648d15c70634ad1165e76f3104dbc65f")
    #expect(indexed["content:title.wildwood.mastery"] ==
        "c4d5e77a6aa2d51895b477c0b388f4f6")
}

@Test
func moduleManifestMatchesDescriptorAndPolicy() throws {
    let data = try resourceData(
        ProgressionCatalogResourceCatalog.moduleManifestDescriptor
    )
    let manifest = try ModuleManifestDecoder.decode(data)
    try ModuleManifestValidator.validate(
        manifest: manifest,
        descriptor: RuneScribeProgressionModuleBootstrap.descriptor,
        runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        platform: .macOS,
        policy: .patternBFoundation
    )
    #expect(manifest.criticality == .optional)
    #expect(Set(manifest.publishedEndpoints) ==
        RuntimeProgressionEndpointCatalog.publishedEndpointIDs.union(
            RuntimeProgressionEndpointCatalog.existingUserMigrationEndpointIDs
        ))
    #expect(!manifest.diagnosticsVisibleInProduction)
}

private func validatedBundle() throws -> ValidatedProgressionCatalogBundle {
    try ProgressionCatalogDecoder.decodeAndValidateBundle(
        catalogData: resourceData(ProgressionCatalogResourceCatalog.catalogDescriptor),
        eventCatalogData: resourceData(
            ProgressionCatalogResourceCatalog.eventCatalogDescriptor
        ),
        futureThemeBindingData: resourceData(
            ProgressionCatalogResourceCatalog.futureThemeBindingsDescriptor
        ),
        integrityMetadata: ProgressionCatalogResourceCatalog.integrityMetadata
    )
}

private func resourceData(
    _ descriptor: ProgressionCatalogResourceDescriptor
) throws -> Data {
    let resource = descriptor.resource
    let url = try #require(RuneScribeProgressionModuleBootstrap.resourceBundle.url(
        forResource: resource.name,
        withExtension: resource.fileExtension,
        subdirectory: resource.subdirectory
    ))
    let data = try Data(contentsOf: url)
    #expect(data.count == descriptor.expectedByteCount)
    return data
}
