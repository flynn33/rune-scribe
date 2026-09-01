import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum ProgressionCatalogValidationError: Error, Equatable, Sendable {
    case resourceMissing(String)
    case resourceIntegrityMismatch(
        resource: String,
        expectedBytes: Int,
        actualBytes: Int,
        expectedSHA256: String,
        actualSHA256: String
    )
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case inputTooLarge(resource: String, maximumBytes: Int, actualBytes: Int)
    case invalidJSON(path: String)
    case duplicateJSONKey(path: String, key: String)
    case missingField(path: String, field: String)
    case unknownField(path: String, field: String)
    case invalidValue(path: String, reason: String)
    case duplicateIdentifier(kind: String, identifier: String)
    case unknownReference(path: String, identifier: String)
    case inventoryMismatch(name: String, expected: Int, actual: Int)
    case dependencyCycle([String])
}

public enum ProgressionCatalogResources {
    public static func loadValidatedBundle(
        using runtimeIO: RuntimeIOClient
    ) async throws -> ValidatedProgressionCatalogBundle {
        _ = try await read(
            ProgressionCatalogResourceCatalog.packageManifestDescriptor,
            using: runtimeIO
        )
        _ = try await read(
            ProgressionCatalogResourceCatalog.catalogSchemaDescriptor,
            using: runtimeIO
        )
        let catalogData = try await read(
            ProgressionCatalogResourceCatalog.catalogDescriptor,
            using: runtimeIO
        )
        let eventCatalogData = try await read(
            ProgressionCatalogResourceCatalog.eventCatalogDescriptor,
            using: runtimeIO
        )
        let bindingsData = try await read(
            ProgressionCatalogResourceCatalog.futureThemeBindingsDescriptor,
            using: runtimeIO
        )
        return try ProgressionCatalogDecoder.decodeAndValidateBundle(
            catalogData: catalogData,
            eventCatalogData: eventCatalogData,
            futureThemeBindingData: bindingsData,
            integrityMetadata: ProgressionCatalogResourceCatalog.integrityMetadata
        )
    }

    private static func read(
        _ descriptor: ProgressionCatalogResourceDescriptor,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data = try await runtimeIO.readVerifiedApplicationResource(
            descriptor.resource,
            expectedSHA256: descriptor.expectedSHA256,
            maximumByteCount: descriptor.maximumByteCount
        )
        guard data.count == descriptor.expectedByteCount else {
            throw ProgressionCatalogValidationError.resourceByteCountMismatch(
                resource: "\(descriptor.resource.name).\(descriptor.resource.fileExtension)",
                expected: descriptor.expectedByteCount,
                actual: data.count
            )
        }
        return data
    }
}

public struct ProgressionCatalogResourceDescriptor: Equatable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(expectedSHA256Hex.count / 2)
        var index = expectedSHA256Hex.startIndex
        while index < expectedSHA256Hex.endIndex {
            let next = expectedSHA256Hex.index(index, offsetBy: 2)
            bytes.append(UInt8(expectedSHA256Hex[index ..< next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    init(
        resource: ApplicationResource,
        expectedByteCount: Int,
        expectedSHA256Hex: String,
        maximumByteCount: Int
    ) {
        self.resource = resource
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256Hex = expectedSHA256Hex
        self.maximumByteCount = maximumByteCount
    }
}

public enum ProgressionCatalogResourceCatalog {
    private static let owner = RuneScribeModuleIDs.progression

    public static var integrityMetadata: ProgressionCatalogIntegrityMetadata {
        ProgressionCatalogIntegrityMetadata(
            catalogSHA256: ProgressionSHA256Digest(
                rawValue: catalogDescriptor.expectedSHA256Hex
            )!,
            eventCatalogSHA256: ProgressionSHA256Digest(
                rawValue: eventCatalogDescriptor.expectedSHA256Hex
            )!
        )
    }

    public static let moduleManifest = ApplicationResource(
        name: "module-manifest",
        fileExtension: "json",
        ownerModuleID: owner
    )
    public static let packageManifest = ApplicationResource(
        name: "PACKAGE-MANIFEST",
        fileExtension: "json",
        ownerModuleID: owner
    )
    public static let catalogSchema = ApplicationResource(
        name: "Rune-Scribe-Progression-Catalog-Schema-v1.0",
        fileExtension: "json",
        ownerModuleID: owner
    )
    public static let catalog = ApplicationResource(
        name: "Rune-Scribe-Progression-Catalog-v1.0",
        fileExtension: "json",
        ownerModuleID: owner
    )
    public static let eventCatalog = ApplicationResource(
        name: "Rune-Scribe-Progression-Event-Catalog-v1.0",
        fileExtension: "json",
        ownerModuleID: owner
    )
    public static let futureThemeBindings = ApplicationResource(
        name: "Rune-Scribe-Progression-Future-Theme-Binding-Contract-v1.0",
        fileExtension: "json",
        ownerModuleID: owner
    )

    public static let moduleManifestDescriptor = ProgressionCatalogResourceDescriptor(
        resource: moduleManifest,
        expectedByteCount: 2_494,
        expectedSHA256Hex: "565c942da781bbfd868a6c2f1e2fc904b5cadfc70eb9c0a04efe9b5ef0501af6",
        maximumByteCount: 4_096
    )
    public static let packageManifestDescriptor = ProgressionCatalogResourceDescriptor(
        resource: packageManifest,
        expectedByteCount: 2_064,
        expectedSHA256Hex: "a4fa1932d7be56980891efa6a841b8af03712f4a3155ca7cdbd439465fd9e0e8",
        maximumByteCount: 4_096
    )
    public static let catalogSchemaDescriptor = ProgressionCatalogResourceDescriptor(
        resource: catalogSchema,
        expectedByteCount: 3_108,
        expectedSHA256Hex: "4c0d538229877a035ad9444d4e89a6ae13ae46cb190f9677761b945c173ed6dd",
        maximumByteCount: 8_192
    )
    public static let catalogDescriptor = ProgressionCatalogResourceDescriptor(
        resource: catalog,
        expectedByteCount: 102_121,
        expectedSHA256Hex: "4a35fe2cff63731c47b8bf586b3be010ebc194ec48e56e81e235cb5ff671c68d",
        maximumByteCount: 128 * 1_024
    )
    public static let eventCatalogDescriptor = ProgressionCatalogResourceDescriptor(
        resource: eventCatalog,
        expectedByteCount: 8_950,
        expectedSHA256Hex: "0a06997167dfc86a835e89b42149cfb2a2dc0fb6de56e09ea6b4c80502bb5efc",
        maximumByteCount: 16 * 1_024
    )
    public static let futureThemeBindingsDescriptor = ProgressionCatalogResourceDescriptor(
        resource: futureThemeBindings,
        expectedByteCount: 2_684,
        expectedSHA256Hex: "83349a52999a9e78f5ffa0e3c557cb3d9d2c67b88cfd10d86f777d38b6a12d91",
        maximumByteCount: 8_192
    )

    public static let controllingInputs = [
        packageManifestDescriptor,
        catalogSchemaDescriptor,
        catalogDescriptor,
        eventCatalogDescriptor,
        futureThemeBindingsDescriptor,
    ]

    public static let allDescriptors = [moduleManifestDescriptor] + controllingInputs

    public static let all: Set<ApplicationResource> = Set(allDescriptors.map(\.resource))
}
