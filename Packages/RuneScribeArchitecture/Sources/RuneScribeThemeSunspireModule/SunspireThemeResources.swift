import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum SunspireThemeResourceError: Error, Equatable, Sendable {
    case resourceByteCountMismatch(resource: String, expected: Int, actual: Int)
    case invalidIntegrityManifest
    case resourcePayloadSetMismatch
    case resourceBudgetExceeded(String)
}

public struct SunspireThemeBundledResourceDescriptor: Equatable, Hashable, Sendable {
    public let resource: ApplicationResource
    public let expectedByteCount: Int
    public let expectedSHA256Hex: String
    public let maximumByteCount: Int

    public var expectedSHA256: Data { Data(hexadecimal: expectedSHA256Hex) }
}

public enum SunspireThemeBundledResourceCatalog {
    public static let moduleManifest = ApplicationResource(
        name: "module-manifest",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.sunspire"
    )
    public static let integrityManifest = ApplicationResource(
        name: "Resource-Integrity-Manifest-v1.0",
        fileExtension: "json",
        ownerModuleID: "com.runescribe.module.theme.sunspire"
    )
    public static let integrityManifestDescriptor = SunspireThemeBundledResourceDescriptor(
        resource: integrityManifest,
        expectedByteCount: SunspireV43ResourcePins.integrityManifestByteCount,
        expectedSHA256Hex: SunspireV43ResourcePins.integrityManifestSHA256Hex,
        maximumByteCount: 64 * 1_024
    )

    public static var all: Set<ApplicationResource> {
        Set([moduleManifest, integrityManifest] + SunspireThemeResourceCatalog.productionDefinitions.map { $0.resource })
    }
}

public struct ValidatedSunspireTheme: Sendable {
    public let descriptor: ThemeDescriptor
    public let resourcePayloads: [ThemeResourceID: Data]
}

public struct SunspireThemeResourceBudgetReport: Equatable, Sendable {
    public let shippingBytes: Int
    public let staticImageBytes: Int
    public let fontBytes: Int
    public let largestResourceBytes: Int
}

public enum SunspireThemeResources {
    public static func loadDescriptorValidated(
        using runtimeIO: RuntimeIOClient
    ) async throws -> ThemeDescriptor {
        let manifestData = try await read(
            SunspireThemeBundledResourceCatalog.integrityManifestDescriptor,
            using: runtimeIO
        )
        guard SunspireThemeResourceCatalog.validateIntegrityManifest(manifestData) else {
            throw SunspireThemeResourceError.invalidIntegrityManifest
        }
        let descriptor = SunspireThemeDescriptorFactory.discoveryDescriptor
        guard Set(SunspireThemeResourceCatalog.definitions.map(\.id))
                == Set(descriptor.resources.map(\.id))
        else { throw SunspireThemeResourceError.resourcePayloadSetMismatch }
        let production = SunspireThemeResourceCatalog.productionDefinitions
        let shipping = production.reduce(0) { $0 + $1.byteCount }
        let staticBytes = production.filter {
            [.png, .heif, .pdf].contains($0.mediaType)
        }.reduce(0) { $0 + $1.byteCount }
        let fontBytes = production.filter {
            [.ttf, .otf].contains($0.mediaType)
        }.reduce(0) { $0 + $1.byteCount }
        let largest = production.map(\.byteCount).max() ?? 0
        guard shipping == SunspireV43ResourcePins.productionShippingByteCount,
              staticBytes <= 96 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else { throw SunspireThemeResourceError.resourceBudgetExceeded("complete-theme") }
        return descriptor
    }

    public static func loadValidatedResource(
        id: ThemeResourceID,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data? {
        if id == SunspireThemeResourceCatalog.localizationDefinition.id {
            return SunspireThemeResourceCatalog.localizationPayload
        }
        guard let definition = SunspireThemeResourceCatalog.productionDefinitions.first(
            where: { $0.id == id }
        ) else { return nil }
        return try await read(definition.bundledDescriptor, using: runtimeIO)
    }

    public static func loadValidated(using runtimeIO: RuntimeIOClient) async throws -> ValidatedSunspireTheme {
        let descriptor = try await loadDescriptorValidated(using: runtimeIO)

        var payloads: [ThemeResourceID: Data] = [:]
        var physicalPayloads: [ApplicationResource: Data] = [:]
        for definition in SunspireThemeResourceCatalog.productionDefinitions {
            let data: Data
            if let cached = physicalPayloads[definition.resource] {
                data = cached
            } else {
                data = try await read(definition.bundledDescriptor, using: runtimeIO)
                physicalPayloads[definition.resource] = data
            }
            payloads[definition.id] = data
        }
        payloads[SunspireThemeResourceCatalog.localizationDefinition.id] =
            SunspireThemeResourceCatalog.localizationPayload

        _ = try budgetReport(payloads: payloads)
        guard Set(payloads.keys) == Set(descriptor.resources.map { $0.id }),
              SunspireThemeResourceCatalog.validates(payloads)
        else {
            throw SunspireThemeResourceError.resourcePayloadSetMismatch
        }
        return ValidatedSunspireTheme(descriptor: descriptor, resourcePayloads: payloads)
    }

    public static func budgetReport(
        payloads: [ThemeResourceID: Data]
    ) throws -> SunspireThemeResourceBudgetReport {
        let production = SunspireThemeResourceCatalog.productionDefinitions
        let values = try production.map { definition -> (SunspireThemeResourceDefinition, Data) in
            guard let data = payloads[definition.id], data.count <= definition.maximumByteCount else {
                throw SunspireThemeResourceError.resourceBudgetExceeded(definition.id.rawValue)
            }
            return (definition, data)
        }
        let shipping = values.reduce(0) { $0 + $1.1.count }
        let staticBytes = values.filter { [.png, .heif, .pdf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let fontBytes = values.filter { [.ttf, .otf].contains($0.0.mediaType) }
            .reduce(0) { $0 + $1.1.count }
        let largest = values.map { $0.1.count }.max() ?? 0
        guard shipping == SunspireV43ResourcePins.productionShippingByteCount,
              staticBytes <= 96 * 1_024 * 1_024,
              fontBytes <= 16 * 1_024 * 1_024,
              largest <= 8 * 1_024 * 1_024
        else {
            throw SunspireThemeResourceError.resourceBudgetExceeded("complete-theme")
        }
        return SunspireThemeResourceBudgetReport(
            shippingBytes: shipping,
            staticImageBytes: staticBytes,
            fontBytes: fontBytes,
            largestResourceBytes: largest
        )
    }

    private static func read(
        _ descriptor: SunspireThemeBundledResourceDescriptor,
        using runtimeIO: RuntimeIOClient
    ) async throws -> Data {
        let data = try await runtimeIO.readVerifiedApplicationResource(
            descriptor.resource,
            expectedSHA256: descriptor.expectedSHA256,
            maximumByteCount: descriptor.maximumByteCount
        )
        guard data.count == descriptor.expectedByteCount else {
            throw SunspireThemeResourceError.resourceByteCountMismatch(
                resource: "\(descriptor.resource.name).\(descriptor.resource.fileExtension)",
                expected: descriptor.expectedByteCount,
                actual: data.count
            )
        }
        return data
    }
}

struct SunspireThemeResourceDefinition: Equatable, Sendable {
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

    var bundledDescriptor: SunspireThemeBundledResourceDescriptor {
        SunspireThemeBundledResourceDescriptor(
            resource: resource,
            expectedByteCount: byteCount,
            expectedSHA256Hex: sha256Hex,
            maximumByteCount: maximumByteCount
        )
    }
}

enum SunspireThemeResourceCatalog {
    static let productionDefinitions = SunspireV43ResourcePins.productionDefinitions

    static let localizationPayload = Data(#"{"locale":"en","strings":{}}"#.utf8)

    static let localizationDefinition = SunspireThemeResourceDefinition(
        id: ThemeResourceID(rawValue: "resource.localization.sunspire.control")!,
        resource: ApplicationResource(
            name: "sunspire-localization-en",
            fileExtension: "json",
            ownerModuleID: "com.runescribe.module.theme.sunspire"
        ),
        relativePath: "embedded/sunspire-localization-en.json",
        role: ThemeResourceRoles.localizationStrings,
        mediaType: .json,
        requirement: .required,
        sha256Hex: sha256Hex(localizationPayload),
        byteCount: localizationPayload.count,
        maximumByteCount: 64 * 1_024,
        pixelWidth: nil,
        pixelHeight: nil,
        rightsID: ThemeProvenanceID(rawValue: "prov.Production.Sources.sunspire.sunspire.background.recipe.json")!
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
              manifest.codexID == "codex.sunspire",
              manifest.moduleID == "com.runescribe.module.theme.sunspire",
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
