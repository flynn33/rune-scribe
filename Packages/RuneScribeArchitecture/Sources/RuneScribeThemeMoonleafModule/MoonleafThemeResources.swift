import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum MoonleafThemeResourceError: Error, Equatable, Sendable {
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case invalidIntegrityManifest
    case resourcePayloadSetMismatch
    case resourceBudgetExceeded(String)
}

public struct MoonleafThemeBundledResourceDescriptor: Equatable, Hashable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data { Data(hexadecimal: expectedSHA256Hex) }
}

public enum MoonleafThemeBundledResourceCatalog {
    public static let moduleManifest = ApplicationResource(
        name: "module-manifest",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.moonleaf"
    )
    public static let integrityManifest = ApplicationResource(
        name: "Resource-Integrity-Manifest-v1.0",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.moonleaf"
    )
    public static let integrityManifestDescriptor = MoonleafThemeBundledResourceDescriptor(
        resource: integrityManifest,
        expectedByteCount: MoonleafV43ResourcePins.integrityManifestByteCount,
        expectedSHA256Hex: MoonleafV43ResourcePins.integrityManifestSHA256Hex,
        maximumByteCount: 64 * 1_024
    )

    public static var all: Set<ApplicationResource> {
        Set([moduleManifest, integrityManifest] + MoonleafThemeResourceCatalog.productionDefinitions.map { $0.resource })
    }
}

public struct ValidatedMoonleafTheme: Sendable {
    public let descriptor: ThemeDescriptor
    public let resourcePayloads: [ThemeResourceID: Data]
}

public struct MoonleafThemeResourceBudgetReport: Equatable, Sendable {
    public let shippingBytes: Int
    public let staticImageBytes: Int
    public let fontBytes: Int
    public let largestResourceBytes: Int
}

public enum MoonleafThemeResources {
    public static func loadDescriptorValidated(
        using runtimeIO: RuntimeIOClient
    ) async throws -> ThemeDescriptor {
        let manifestData = try await read(
            MoonleafThemeBundledResourceCatalog.integrityManifestDescriptor,
            using: runtimeIO
        )
        guard MoonleafThemeResourceCatalog.validateIntegrityManifest(manifestData) else {
            throw MoonleafThemeResourceError.invalidIntegrityManifest
        }
        let descriptor = MoonleafThemeDescriptorFactory.discoveryDescriptor
        guard Set(MoonleafThemeResourceCatalog.definitions.map(\.id))
                == Set(descriptor.resources.map(\.id))
        else { throw MoonleafThemeResourceError.resourcePayloadSetMismatch }
        let production = MoonleafThemeResourceCatalog.productionDefinitions
        let shipping = production.reduce(0) { $0 + $1.byteCount }
        let staticBytes = production.filter {
            [.png, .heif, .pdf].contains($0.mediaType)
        }.reduce(0) { $0 + $1.byteCount }
        let fontBytes = production.filter {
            [.ttf, .otf].contains($0.mediaType)
        }.reduce(0) { $0 + $1.byteCount }
        let largest = production.map(\.byteCount).max() ?? 0
        guard shipping == MoonleafV43ResourcePins.productionShippingByteCount,
              staticBytes <= 96 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else { throw MoonleafThemeResourceError.resourceBudgetExceeded("complete-theme") }
        return descriptor
    }

    public static func loadValidatedResource(
        id: ThemeResourceID,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data? {
        if id == MoonleafThemeResourceCatalog.localizationDefinition.id {
            return MoonleafThemeResourceCatalog.localizationPayload
        }
        guard let definition = MoonleafThemeResourceCatalog.productionDefinitions.first(
            where: { $0.id == id }
        ) else { return nil }
        return try await read(definition.bundledDescriptor, using: runtimeIO)
    }

    public static func loadValidated(using runtimeIO: RuntimeIOClient) async throws -> ValidatedMoonleafTheme {
        let descriptor = try await loadDescriptorValidated(using: runtimeIO)

        var payloads: [ThemeResourceID: Data] = [:]
        var physicalPayloads: [ApplicationResource: Data] = [:]
        for definition in MoonleafThemeResourceCatalog.productionDefinitions {
            let data: Data
            if let cached = physicalPayloads[definition.resource] {
                data = cached
            } else {
                data = try await read(definition.bundledDescriptor, using: runtimeIO)
                physicalPayloads[definition.resource] = data
            }
            payloads[definition.id] = data
        }
        payloads[MoonleafThemeResourceCatalog.localizationDefinition.id] =
            MoonleafThemeResourceCatalog.localizationPayload

        _ = try budgetReport(payloads: payloads)
        guard Set(payloads.keys) == Set(descriptor.resources.map { $0.id }),
              MoonleafThemeResourceCatalog.validates(payloads)
        else {
            throw MoonleafThemeResourceError.resourcePayloadSetMismatch
        }
        return ValidatedMoonleafTheme(descriptor: descriptor, resourcePayloads: payloads)
    }

    public static func budgetReport(
        payloads: [ThemeResourceID: Data]
    ) throws -> MoonleafThemeResourceBudgetReport {
        let production = MoonleafThemeResourceCatalog.productionDefinitions
        let values = try production.map { definition -> (MoonleafThemeResourceDefinition, Data) in
            guard let data = payloads[definition.id], data.count <= definition.maximumByteCount else {
                throw MoonleafThemeResourceError.resourceBudgetExceeded(definition.id.rawValue)
            }
            return (definition, data)
        }
        let shipping = values.reduce(0) { $0 + $1.1.count }
        let staticBytes = values.filter { [.png, .heif, .pdf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let fontBytes = values.filter { [.ttf, .otf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let largest = values.map { $0.1.count }.max() ?? 0
        guard shipping == MoonleafV43ResourcePins.productionShippingByteCount,
              staticBytes <= 96 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else {
            throw MoonleafThemeResourceError.resourceBudgetExceeded("complete-theme")
        }
        return MoonleafThemeResourceBudgetReport(
            shippingBytes: shipping,
            staticImageBytes: staticBytes,
            fontBytes: fontBytes,
            largestResourceBytes: largest
        )
    }

    private static func read(
        _ descriptor: MoonleafThemeBundledResourceDescriptor,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data = try await runtimeIO.readVerifiedApplicationResource(
            descriptor.resource,
            expectedSHA256: descriptor.expectedSHA256,
            maximumByteCount: descriptor.maximumByteCount
        )
        guard data.count == descriptor.expectedByteCount else {
            throw MoonleafThemeResourceError.resourceByteCountMismatch(
                resource: "\(descriptor.resource.name).\(descriptor.resource.fileExtension)",
                expected: descriptor.expectedByteCount,
                actual: data.count
            )
        }
        return data
    }
}

struct MoonleafThemeResourceDefinition: Equatable, Sendable {
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

    var bundledDescriptor: MoonleafThemeBundledResourceDescriptor {
        MoonleafThemeBundledResourceDescriptor(
            resource: resource,
            expectedByteCount: byteCount,
            expectedSHA256Hex: sha256Hex,
            maximumByteCount: maximumByteCount
        )
    }
}

enum MoonleafThemeResourceCatalog {
    static let productionDefinitions = MoonleafV43ResourcePins.productionDefinitions

    static let localizationPayload = Data(#"{"locale":"en","strings":{}}"#.utf8)

    static let localizationDefinition = MoonleafThemeResourceDefinition(
        id: ThemeResourceID(rawValue: "resource.localization.moonleaf.control")!,
        resource: ApplicationResource(
            name: "moonleaf-localization-en",
            fileExtension: "json",
            ownerModuleID: "com.runescribe.module.theme.moonleaf"
        ),
        relativePath: "embedded/moonleaf-localization-en.json",
        role: ThemeResourceRoles.localizationStrings,
        mediaType: .json,
        requirement: .required,
        sha256Hex: sha256Hex(localizationPayload),
        byteCount: localizationPayload.count,
        maximumByteCount: 64 * 1_024,
        pixelWidth: nil,
        pixelHeight: nil,
        rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json")!
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
              manifest.codexID == "codex.moonleaf",
              manifest.moduleID == "com.runescribe.module.theme.moonleaf",
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
