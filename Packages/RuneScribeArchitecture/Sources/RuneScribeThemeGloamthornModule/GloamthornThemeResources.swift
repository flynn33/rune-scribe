import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum GloamthornThemeResourceError: Error, Equatable, Sendable {
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case invalidIntegrityManifest
    case resourcePayloadSetMismatch
    case resourceBudgetExceeded(String)
}

public struct GloamthornThemeBundledResourceDescriptor: Equatable, Hashable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data { Data(hexadecimal: expectedSHA256Hex) }
}

public enum GloamthornThemeBundledResourceCatalog {
    public static let moduleManifest = ApplicationResource(
        name: "module-manifest",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.gloamthorn"
    )
    public static let integrityManifest = ApplicationResource(
        name: "Resource-Integrity-Manifest-v1.0",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.gloamthorn"
    )
    public static let integrityManifestDescriptor = GloamthornThemeBundledResourceDescriptor(
        resource: integrityManifest,
        expectedByteCount: GloamthornV43ResourcePins.integrityManifestByteCount,
        expectedSHA256Hex: GloamthornV43ResourcePins.integrityManifestSHA256Hex,
        maximumByteCount: 64 * 1_024
    )

    public static var all: Set<ApplicationResource> {
        Set([moduleManifest, integrityManifest] + GloamthornThemeResourceCatalog.productionDefinitions.map { $0.resource })
    }
}

public struct ValidatedGloamthornTheme: Sendable {
    public let descriptor: ThemeDescriptor
    public let resourcePayloads: [ThemeResourceID: Data]
}

public struct GloamthornThemeResourceBudgetReport: Equatable, Sendable {
    public let shippingBytes: Int
    public let staticImageBytes: Int
    public let fontBytes: Int
    public let largestResourceBytes: Int
}

public enum GloamthornThemeResources {
    public static func loadDescriptorValidated(
        using runtimeIO: RuntimeIOClient
    ) async throws -> ThemeDescriptor {
        let manifestData = try await read(
            GloamthornThemeBundledResourceCatalog.integrityManifestDescriptor,
            using: runtimeIO
        )
        guard GloamthornThemeResourceCatalog.validateIntegrityManifest(manifestData) else {
            throw GloamthornThemeResourceError.invalidIntegrityManifest
        }
        let descriptor = GloamthornThemeDescriptorFactory.discoveryDescriptor
        guard Set(GloamthornThemeResourceCatalog.definitions.map(\.id))
                == Set(descriptor.resources.map(\.id))
        else { throw GloamthornThemeResourceError.resourcePayloadSetMismatch }
        let production = GloamthornThemeResourceCatalog.productionDefinitions
        let shipping = production.reduce(0) { $0 + $1.byteCount }
        let staticBytes = production.filter {
            [.png, .heif, .pdf].contains($0.mediaType)
        }.reduce(0) { $0 + $1.byteCount }
        let fontBytes = production.filter {
            [.ttf, .otf].contains($0.mediaType)
        }.reduce(0) { $0 + $1.byteCount }
        let largest = production.map(\.byteCount).max() ?? 0
        guard shipping == GloamthornV43ResourcePins.productionShippingByteCount,
              staticBytes <= 96 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else { throw GloamthornThemeResourceError.resourceBudgetExceeded("complete-theme") }
        return descriptor
    }

    public static func loadValidatedResource(
        id: ThemeResourceID,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data? {
        if id == GloamthornThemeResourceCatalog.localizationDefinition.id {
            return GloamthornThemeResourceCatalog.localizationPayload
        }
        guard let definition = GloamthornThemeResourceCatalog.productionDefinitions.first(
            where: { $0.id == id }
        ) else { return nil }
        return try await read(definition.bundledDescriptor, using: runtimeIO)
    }

    public static func loadValidated(using runtimeIO: RuntimeIOClient) async throws -> ValidatedGloamthornTheme {
        let descriptor = try await loadDescriptorValidated(using: runtimeIO)

        var payloads: [ThemeResourceID: Data] = [:]
        var physicalPayloads: [ApplicationResource: Data] = [:]
        for definition in GloamthornThemeResourceCatalog.productionDefinitions {
            let data: Data
            if let cached = physicalPayloads[definition.resource] {
                data = cached
            } else {
                data = try await read(definition.bundledDescriptor, using: runtimeIO)
                physicalPayloads[definition.resource] = data
            }
            payloads[definition.id] = data
        }
        payloads[GloamthornThemeResourceCatalog.localizationDefinition.id] =
            GloamthornThemeResourceCatalog.localizationPayload

        _ = try budgetReport(payloads: payloads)
        guard Set(payloads.keys) == Set(descriptor.resources.map { $0.id }),
              GloamthornThemeResourceCatalog.validates(payloads)
        else {
            throw GloamthornThemeResourceError.resourcePayloadSetMismatch
        }
        return ValidatedGloamthornTheme(descriptor: descriptor, resourcePayloads: payloads)
    }

    public static func budgetReport(
        payloads: [ThemeResourceID: Data]
    ) throws -> GloamthornThemeResourceBudgetReport {
        let production = GloamthornThemeResourceCatalog.productionDefinitions
        let values = try production.map { definition -> (GloamthornThemeResourceDefinition, Data) in
            guard let data = payloads[definition.id], data.count <= definition.maximumByteCount else {
                throw GloamthornThemeResourceError.resourceBudgetExceeded(definition.id.rawValue)
            }
            return (definition, data)
        }
        let shipping = values.reduce(0) { $0 + $1.1.count }
        let staticBytes = values.filter { [.png, .heif, .pdf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let fontBytes = values.filter { [.ttf, .otf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let largest = values.map { $0.1.count }.max() ?? 0
        guard shipping == GloamthornV43ResourcePins.productionShippingByteCount,
              staticBytes <= 96 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else {
            throw GloamthornThemeResourceError.resourceBudgetExceeded("complete-theme")
        }
        return GloamthornThemeResourceBudgetReport(
            shippingBytes: shipping,
            staticImageBytes: staticBytes,
            fontBytes: fontBytes,
            largestResourceBytes: largest
        )
    }

    private static func read(
        _ descriptor: GloamthornThemeBundledResourceDescriptor,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data = try await runtimeIO.readVerifiedApplicationResource(
            descriptor.resource,
            expectedSHA256: descriptor.expectedSHA256,
            maximumByteCount: descriptor.maximumByteCount
        )
        guard data.count == descriptor.expectedByteCount else {
            throw GloamthornThemeResourceError.resourceByteCountMismatch(
                resource: "\(descriptor.resource.name).\(descriptor.resource.fileExtension)",
                expected: descriptor.expectedByteCount,
                actual: data.count
            )
        }
        return data
    }
}

struct GloamthornThemeResourceDefinition: Equatable, Sendable {
    let id: ThemeResourceID
    let resource: ApplicationResource
    let relativePath: String
    let role: ThemeResourceRoleID
    let mediaType: ThemeResourceMediaType
    let requirement: ThemeResourceRequirement
    let sha256Hex: String
    let byteCount: Int
    let maximumByteCount: Int
    let pixelWidth: Int?
    let pixelHeight: Int?
    let rightsID: ThemeProvenanceID

    var bundledDescriptor: GloamthornThemeBundledResourceDescriptor {
        GloamthornThemeBundledResourceDescriptor(
            resource: resource,
            expectedByteCount: byteCount,
            expectedSHA256Hex: sha256Hex,
            maximumByteCount: maximumByteCount
        )
    }
}

enum GloamthornThemeResourceCatalog {
    static let productionDefinitions = GloamthornV43ResourcePins.productionDefinitions

    static let localizationPayload = Data(#"{"locale":"en","strings":{}}"#.utf8)

    static let localizationDefinition = GloamthornThemeResourceDefinition(
        id: ThemeResourceID(rawValue: "resource.localization.gloamthorn.control")!,
        resource: ApplicationResource(
            name: "gloamthorn-localization-en",
            fileExtension: "json",
            ownerModuleID: "com.runescribe.module.theme.gloamthorn"
        ),
        relativePath: "embedded/gloamthorn-localization-en.json",
        role: ThemeResourceRoles.localizationStrings,
        mediaType: .json,
        requirement: .required,
        sha256Hex: sha256Hex(localizationPayload),
        byteCount: localizationPayload.count,
        maximumByteCount: 64 * 1_024,
        pixelWidth: nil,
        pixelHeight: nil,
        rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.gloamthorn.gloamthorn.background.recipe.json")!
    )

    static let definitions = productionDefinitions + [localizationDefinition]

    static func references() throws -> [ThemeResourceReference] {
        try definitions.map { definition in
            let pixelSize: ThemePixelSize?
            if let width = definition.pixelWidth, let height = definition.pixelHeight {
                pixelSize = try ThemePixelSize(width: UInt32(width), height: UInt32(height))
            } else {
                pixelSize = nil
            }
            return try ThemeResourceReference(
                id: definition.id,
                role: definition.role,
                mediaType: definition.mediaType,
                requirement: definition.requirement,
                integrity: ThemeResourceIntegrity(
                    sha256: ThemeSHA256Digest(rawValue: definition.sha256Hex)!,
                    byteLength: UInt64(definition.byteCount),
                    pixelSize: pixelSize
                ),
                rightsID: definition.rightsID
            )
        }
    }

    static func validates(_ payloads: [ThemeResourceID: Data]) -> Bool {
        Set(payloads.keys) == Set(definitions.map { $0.id }) && definitions.allSatisfy { definition in
            guard let data = payloads[definition.id] else { return false }
            return data.count == definition.byteCount && sha256Hex(data) == definition.sha256Hex
        }
    }

    static func validateIntegrityManifest(_ data: Data) -> Bool {
        guard let manifest = try? JSONDecoder().decode(IntegrityManifest.self, from: data),
              manifest.schemaVersion == "1.0",
              manifest.codexID == "codex.gloamthorn",
              manifest.moduleID == "com.runescribe.module.theme.gloamthorn",
              manifest.acceptedPackageVersion == "4.3.0"
        else { return false }
        return manifest.files == productionDefinitions.map {
            IntegrityManifest.FileRecord(
                path: $0.relativePath,
                bytes: $0.byteCount,
                sha256: $0.sha256Hex,
                resourceID: $0.id.rawValue,
                role: $0.role.rawValue
            )
        }
    }

    private struct IntegrityManifest: Decodable {
        struct FileRecord: Decodable, Equatable {
            let path: String
            let bytes: Int
            let sha256: String
            let resourceID: String
            let role: String
        }
        let schemaVersion: String
        let codexID: String
        let moduleID: String
        let acceptedPackageVersion: String
        let files: [FileRecord]
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    init(hexadecimal value: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            bytes.append(UInt8(value[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
