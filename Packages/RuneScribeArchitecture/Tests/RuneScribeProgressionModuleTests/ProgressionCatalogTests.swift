import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import Testing
@testable import RuneScribeProgressionModule

@Test
func bundledCatalogDecodesWithExactInventory() throws {
    let bundle = try validatedBundle()

    #expect(bundle.catalog.content.count == 80)
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
