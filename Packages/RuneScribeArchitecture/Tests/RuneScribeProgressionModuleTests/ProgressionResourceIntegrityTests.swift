import CryptoKit
import Foundation
import RuneScribeContracts
import Testing
@testable import RuneScribeRuntimeCore
@testable import RuneScribeProgressionModule

@Test
func bundledResourcesMatchControllingBytesAndSHA256() throws {
    for descriptor in ProgressionCatalogResourceCatalog.controllingInputs {
        let data = try bundledData(descriptor)
        #expect(data.count == descriptor.expectedByteCount)
        #expect(sha256Hex(data) == descriptor.expectedSHA256Hex)
        #expect(Data(SHA256.hash(data: data)) == descriptor.expectedSHA256)
    }
}

@Test
func packageManifestPinsEveryBundledControllingInput() throws {
    let data = try bundledData(
        ProgressionCatalogResourceCatalog.packageManifestDescriptor
    )
    let root = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(root["schemaVersion"] as? String == "1.0")
    #expect(root["packageID"] as? String ==
        "runescribe.progression-achievement.codex-package")
    #expect(root["packageVersion"] as? String == "1.0.0")
    let files = try #require(root["files"] as? [[String: Any]])
    let entries: [String: [String: Any]] = Dictionary(
        uniqueKeysWithValues: files.compactMap { entry -> (String, [String: Any])? in
            guard let path = entry["path"] as? String else { return nil }
            return (path, entry)
        }
    )
    for descriptor in [
        ProgressionCatalogResourceCatalog.catalogSchemaDescriptor,
        ProgressionCatalogResourceCatalog.catalogDescriptor,
        ProgressionCatalogResourceCatalog.eventCatalogDescriptor,
        ProgressionCatalogResourceCatalog.futureThemeBindingsDescriptor,
    ] {
        let path = "\(descriptor.resource.name).\(descriptor.resource.fileExtension)"
        let entry = try #require(entries[path])
        #expect(entry["bytes"] as? Int == descriptor.expectedByteCount)
        #expect(entry["sha256"] as? String == descriptor.expectedSHA256Hex)
    }
}

@Test
func moduleManifestIntegrityMetadataMatchesBundle() throws {
    let descriptor = ProgressionCatalogResourceCatalog.moduleManifestDescriptor
    let data = try bundledData(descriptor)
    #expect(data.count == descriptor.expectedByteCount)
    #expect(sha256Hex(data) == descriptor.expectedSHA256Hex)
    #expect(RuneScribeProgressionModuleBootstrap.manifestResource == descriptor.resource)
    #expect(RuneScribeProgressionModuleBootstrap.manifestExpectedSHA256 ==
        descriptor.expectedSHA256)
    #expect(RuneScribeProgressionModuleBootstrap.manifestMaximumByteCount ==
        descriptor.maximumByteCount)
}

@Test
func resourceLoaderUsesVerifiedRuntimeIORail() async throws {
    let runtimeIO = RuntimeIOClient(
        readVerifiedApplicationResource: { resource, expectedSHA256, maximumBytes in
            let descriptor = try #require(
                ProgressionCatalogResourceCatalog.controllingInputs.first {
                    $0.resource == resource
                }
            )
            #expect(expectedSHA256 == descriptor.expectedSHA256)
            #expect(maximumBytes == descriptor.maximumByteCount)
            let data = try bundledData(descriptor)
            #expect(data.count <= maximumBytes)
            #expect(Data(SHA256.hash(data: data)) == expectedSHA256)
            return data
        }
    )

    let bundle = try await ProgressionCatalogResources.loadValidatedBundle(
        using: runtimeIO
    )
    #expect(bundle.catalog.catalogVersion.rawValue == 2)
    #expect(bundle.eventCatalog.catalogVersion.rawValue == 2)
    #expect(bundle.futureThemeBindings.version.rawValue == 2)
}

@Test
func resourceLoaderFailsClosedForMissingOrIntegrityRejectedBytes() async {
    for failure in [
        RuntimeVerifiedApplicationResourceFailure.resourceUnavailable,
        RuntimeVerifiedApplicationResourceFailure.integrityMismatch(
            actualSHA256: Data(repeating: 0xAB, count: SHA256.Digest.byteCount),
            actualByteCount: 1
        ),
    ] {
        let runtimeIO = RuntimeIOClient(
            readVerifiedApplicationResource: { _, _, _ in throw failure }
        )
        do {
            _ = try await ProgressionCatalogResources.loadValidatedBundle(using: runtimeIO)
            Issue.record("Expected verified resource failure \(failure).")
        } catch let actual as RuntimeVerifiedApplicationResourceFailure {
            #expect(actual == failure)
        } catch {
            Issue.record("Unexpected failure type: \(error).")
        }
    }
}

@Test
func resourceLoaderRejectsUnexpectedByteCountAfterRuntimeVerification() async {
    let runtimeIO = RuntimeIOClient(
        readVerifiedApplicationResource: { _, _, _ in Data() }
    )
    do {
        _ = try await ProgressionCatalogResources.loadValidatedBundle(using: runtimeIO)
        Issue.record("Expected byte-count rejection.")
    } catch let error as ProgressionCatalogValidationError {
        guard case .resourceByteCountMismatch = error else {
            Issue.record("Expected resourceByteCountMismatch, received \(error).")
            return
        }
    } catch {
        Issue.record("Unexpected failure type: \(error).")
    }
}

private func bundledData(
    _ descriptor: ProgressionCatalogResourceDescriptor
) throws -> Data {
    let resource = descriptor.resource
    let url = try #require(RuneScribeProgressionModuleBootstrap.resourceBundle.url(
        forResource: resource.name,
        withExtension: resource.fileExtension,
        subdirectory: resource.subdirectory
    ))
    return try Data(contentsOf: url)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
