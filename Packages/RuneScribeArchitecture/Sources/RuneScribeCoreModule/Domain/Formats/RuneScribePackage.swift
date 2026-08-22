import CryptoKit
import Foundation
import RuneScribeContracts

enum RuneScribePackageError: Error, Equatable, Sendable {
    case truncatedMagic
    case badMagic
    case truncatedHeader
    case unsupportedContainerVersion(UInt16)
    case unsupportedFlags(UInt16)
    case invalidHeaderLength
    case lengthMismatch
    case packageTooLarge
    case tooManySections
    case invalidDirectory
    case nonCanonicalSectionOrder
    case duplicateSection(UInt16)
    case nonContiguousSections
    case sectionTooLarge(UInt16)
    case missingCorePayload
    case invalidCorePayload
    case unknownRequiredSection(UInt16)
    case unsupportedRequiredSectionVersion(type: UInt16, version: UInt16)
    case unsupportedPayloadKind(UInt16)
    case unsupportedPayloadVersion(kind: UInt16, version: UInt16)
    case badChecksum
    case invalidResourceTable
    case tooManyResources
    case invalidResourceKind
    case invalidResourceIdentifier
    case invalidResourceVersion
    case invalidResourceMediaType
    case resourceTooLarge
    case duplicateResource
    case resourceHashMismatch
    case missingLegacyFontResource
    case legacyFontResourceReferenceMismatch
}

enum RuneScribePackageKind: UInt16, Codable, Equatable, Sendable {
    case cipherInvitation = 1
    case encryptedMessage = 2
}

enum RuneScribePackageSectionType: UInt16, Codable, Equatable, Sendable {
    case corePayload = 0x0001
    case presentationMetadata = 0x0002
    case safePreview = 0x0003
    case resourceTable = 0x0004
    case signedProvenance = 0x0005
}

struct RuneScribePackageSection: Equatable, Sendable {
    static let requiredFlag: UInt16 = 0x0001

    let type: UInt16
    let version: UInt16
    let required: Bool
    let data: Data

    init(type: UInt16, version: UInt16 = 1, required: Bool = false, data: Data) {
        self.type = type
        self.version = version
        self.required = required
        self.data = data
    }
}

enum RuneScribePackageResourceKind: UInt16, Codable, Equatable, Sendable {
    case legacyFont = 1
}

/// Decoder-owned variable-size allocation accounting. The input buffer remains
/// caller-owned; events are emitted only after structural limits and bounds pass.
enum RuneScribePackageDecodeAllocation: Equatable, Sendable {
    case sectionArrayCapacity(Int)
    case sectionPayload(Int)
    case resourceArrayCapacity(Int)
    case resourceMetadata(Int)
    case resourcePayload(Int)
}

struct RuneScribePackageResource: Equatable, Sendable {
    static let maximumIdentifierUTF8Count = 128
    static let maximumMediaTypeUTF8Count = 127
    static let maximumDataLength = 8 * 1024 * 1024

    let kind: UInt16
    let id: String
    let version: UInt32
    let mediaType: String
    let data: Data
    let sha256: Data

    init(
        kind: RuneScribePackageResourceKind,
        id: String,
        version: UInt32,
        mediaType: String,
        data: Data
    ) throws {
        guard !data.isEmpty, data.count <= Self.maximumDataLength else {
            throw RuneScribePackageError.resourceTooLarge
        }
        try self.init(
            kind: kind.rawValue,
            id: id,
            version: version,
            mediaType: mediaType,
            data: data,
            sha256: Data(SHA256.hash(data: data))
        )
    }

    fileprivate init(
        kind: UInt16,
        id: String,
        version: UInt32,
        mediaType: String,
        data: Data,
        sha256: Data
    ) throws {
        guard RuneScribePackageResourceKind(rawValue: kind) != nil else {
            throw RuneScribePackageError.invalidResourceKind
        }
        guard Self.hasValidIdentifier(id) else {
            throw RuneScribePackageError.invalidResourceIdentifier
        }
        guard version > 0 else { throw RuneScribePackageError.invalidResourceVersion }
        guard Self.hasAllowedMediaType(mediaType, for: kind) else {
            throw RuneScribePackageError.invalidResourceMediaType
        }
        guard !data.isEmpty, data.count <= Self.maximumDataLength else {
            throw RuneScribePackageError.resourceTooLarge
        }
        guard sha256.count == SHA256.Digest.byteCount,
              sha256 == Data(SHA256.hash(data: data))
        else {
            throw RuneScribePackageError.resourceHashMismatch
        }
        self.kind = kind
        self.id = id
        self.version = version
        self.mediaType = mediaType
        self.data = data
        self.sha256 = sha256
    }

    fileprivate var uniquenessKey: String {
        "\(kind):\(id):\(version)"
    }

    private static func hasValidIdentifier(_ value: String) -> Bool {
        hasValidIdentifierBytes(value.utf8)
    }

    fileprivate static func hasValidIdentifierBytes<Bytes>(
        _ bytes: Bytes
    ) -> Bool where Bytes: BidirectionalCollection, Bytes.Element == UInt8 {
        guard !bytes.isEmpty,
              bytes.count <= maximumIdentifierUTF8Count,
              bytes.first.map(isLowercaseLetterOrNumber) == true,
              bytes.last.map(isLowercaseLetterOrNumber) == true
        else {
            return false
        }
        var priorWasSeparator = false
        for byte in bytes {
            if isLowercaseLetterOrNumber(byte) {
                priorWasSeparator = false
            } else if (byte == 0x2D || byte == 0x2E), !priorWasSeparator {
                priorWasSeparator = true
            } else {
                return false
            }
        }
        return true
    }

    fileprivate static func hasAllowedMediaType(_ value: String, for kind: UInt16) -> Bool {
        hasAllowedMediaTypeBytes(value.utf8, for: kind)
    }

    fileprivate static func hasAllowedMediaTypeBytes<Bytes>(
        _ bytes: Bytes,
        for kind: UInt16
    ) -> Bool where Bytes: BidirectionalCollection, Bytes.Element == UInt8 {
        guard !bytes.isEmpty,
              bytes.count <= maximumMediaTypeUTF8Count,
              bytes.filter({ $0 == 0x2F }).count == 1,
              bytes.first != 0x2F,
              bytes.last != 0x2F
        else {
            return false
        }
        guard bytes.allSatisfy({
            isLowercaseLetterOrNumber($0)
                || $0 == 0x2F
                || $0 == 0x2B
                || $0 == 0x2D
                || $0 == 0x2E
        }) else {
            return false
        }
        switch RuneScribePackageResourceKind(rawValue: kind) {
        case .legacyFont:
            return bytes.elementsEqual("font/otf".utf8)
                || bytes.elementsEqual("font/ttf".utf8)
        case nil:
            return false
        }
    }

    private static func isLowercaseLetterOrNumber(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
    }
}

/// Section-version 1 resource table. It is intentionally bounded and self-verifying;
/// Wave 1B uses it only for validated legacy font compatibility resources.
struct RuneScribePackageResourceTable: Equatable, Sendable {
    static let version: UInt16 = 1
    static let maximumResourceCount = 8
    static let maximumAggregateDataLength = 12 * 1024 * 1024
    private static let fixedHeaderLength = 4
    private static let entryHeaderLength = 48

    private struct RecordLayout {
        let kind: UInt16
        let version: UInt32
        let hashRange: Range<Int>
        let idRange: Range<Int>
        let mediaTypeRange: Range<Int>
        let contentRange: Range<Int>

        var endOffset: Int { contentRange.upperBound }
    }

    let resources: [RuneScribePackageResource]

    init(resources: [RuneScribePackageResource]) throws {
        guard resources.count <= Self.maximumResourceCount else {
            throw RuneScribePackageError.tooManyResources
        }
        guard Set(resources.map(\.uniquenessKey)).count == resources.count else {
            throw RuneScribePackageError.duplicateResource
        }
        let aggregateLength = resources.reduce(UInt64(0)) {
            $0 + UInt64($1.data.count)
        }
        guard aggregateLength <= UInt64(Self.maximumAggregateDataLength) else {
            throw RuneScribePackageError.resourceTooLarge
        }
        self.resources = resources
    }

    func encoded() throws -> Data {
        _ = try Self(resources: resources)
        var output = Data()
        output.appendBigEndian(UInt16(resources.count))
        output.appendBigEndian(UInt16(0))
        for resource in resources {
            let id = Data(resource.id.utf8)
            let mediaType = Data(resource.mediaType.utf8)
            output.appendBigEndian(resource.kind)
            output.appendBigEndian(UInt16(0))
            output.appendBigEndian(resource.version)
            output.appendBigEndian(UInt16(id.count))
            output.appendBigEndian(UInt16(mediaType.count))
            output.appendBigEndian(UInt32(resource.data.count))
            output.append(resource.sha256)
            output.append(id)
            output.append(mediaType)
            output.append(resource.data)
        }
        guard output.count <= RuneScribePackage.maximumResourceTableLength else {
            throw RuneScribePackageError.resourceTooLarge
        }
        return output
    }

    init(decoding data: Data) throws {
        try self.init(decoding: data, allocationObserver: nil)
    }

    init(
        decoding data: Data,
        allocationObserver: ((RuneScribePackageDecodeAllocation) -> Void)?
    ) throws {
        let range = data.startIndex..<data.endIndex
        try Self.preflight(decoding: data, in: range)

        let count = Int(data.uint16(at: range.lowerBound))
        var cursor = range.lowerBound + Self.fixedHeaderLength
        var decoded: [RuneScribePackageResource] = []
        allocationObserver?(.resourceArrayCapacity(count))
        decoded.reserveCapacity(count)
        for _ in 0..<count {
            let record = try Self.recordLayout(
                in: data,
                at: cursor,
                upperBound: range.upperBound
            )
            allocationObserver?(.resourceMetadata(
                SHA256.Digest.byteCount
                    + record.idRange.count
                    + record.mediaTypeRange.count
            ))
            let hash = data.subdata(in: record.hashRange)
            let idData = data.subdata(in: record.idRange)
            let mediaTypeData = data.subdata(in: record.mediaTypeRange)
            allocationObserver?(.resourcePayload(record.contentRange.count))
            let content = data.subdata(in: record.contentRange)
            guard let id = String(data: idData, encoding: .utf8),
                  let mediaType = String(data: mediaTypeData, encoding: .ascii)
            else {
                throw RuneScribePackageError.invalidResourceTable
            }
            decoded.append(try RuneScribePackageResource(
                kind: record.kind,
                id: id,
                version: record.version,
                mediaType: mediaType,
                data: content,
                sha256: hash
            ))
            cursor = record.endOffset
        }
        try self.init(resources: decoded)
    }

    /// Validates every record against the original input buffer before the decoder
    /// reserves output capacity, copies metadata, or copies resource payload bytes.
    fileprivate static func preflight(
        decoding data: Data,
        in range: Range<Int>
    ) throws {
        guard range.lowerBound >= data.startIndex,
              range.upperBound <= data.endIndex,
              range.count >= Self.fixedHeaderLength,
              range.count <= RuneScribePackage.maximumResourceTableLength
        else {
            throw RuneScribePackageError.invalidResourceTable
        }
        let count = Int(data.uint16(at: range.lowerBound))
        guard count <= Self.maximumResourceCount else {
            throw RuneScribePackageError.tooManyResources
        }
        guard data.uint16(at: range.lowerBound + 2) == 0 else {
            throw RuneScribePackageError.invalidResourceTable
        }

        let firstRecordOffset = range.lowerBound + Self.fixedHeaderLength
        var cursor = firstRecordOffset
        var aggregateContentLength = 0
        for index in 0..<count {
            let record = try Self.recordLayout(
                in: data,
                at: cursor,
                upperBound: range.upperBound
            )
            try Self.validateRecord(record, in: data)
            guard record.contentRange.count
                    <= Self.maximumAggregateDataLength - aggregateContentLength
            else {
                throw RuneScribePackageError.resourceTooLarge
            }
            aggregateContentLength += record.contentRange.count

            var priorCursor = firstRecordOffset
            for _ in 0..<index {
                let prior = try Self.recordLayout(
                    in: data,
                    at: priorCursor,
                    upperBound: range.upperBound
                )
                if prior.kind == record.kind,
                   prior.version == record.version,
                   data[prior.idRange].elementsEqual(data[record.idRange]) {
                    throw RuneScribePackageError.duplicateResource
                }
                priorCursor = prior.endOffset
            }
            cursor = record.endOffset
        }
        guard cursor == range.upperBound else {
            throw RuneScribePackageError.invalidResourceTable
        }
    }

    private static func recordLayout(
        in data: Data,
        at cursor: Int,
        upperBound: Int
    ) throws -> RecordLayout {
        guard cursor <= upperBound,
              Self.entryHeaderLength <= upperBound - cursor
        else {
            throw RuneScribePackageError.invalidResourceTable
        }
        let kind = data.uint16(at: cursor)
        let flags = data.uint16(at: cursor + 2)
        let version = data.uint32(at: cursor + 4)
        let idLength = Int(data.uint16(at: cursor + 8))
        let mediaTypeLength = Int(data.uint16(at: cursor + 10))
        let contentLength = Int(data.uint32(at: cursor + 12))
        guard flags == 0,
              idLength > 0,
              idLength <= RuneScribePackageResource.maximumIdentifierUTF8Count,
              mediaTypeLength > 0,
              mediaTypeLength <= RuneScribePackageResource.maximumMediaTypeUTF8Count,
              contentLength > 0,
              contentLength <= RuneScribePackageResource.maximumDataLength
        else {
            throw RuneScribePackageError.invalidResourceTable
        }

        let hashRange = (cursor + 16)..<(cursor + Self.entryHeaderLength)
        let idStart = cursor + Self.entryHeaderLength
        guard idLength <= upperBound - idStart else {
            throw RuneScribePackageError.invalidResourceTable
        }
        let idRange = idStart..<(idStart + idLength)
        guard mediaTypeLength <= upperBound - idRange.upperBound else {
            throw RuneScribePackageError.invalidResourceTable
        }
        let mediaTypeRange = idRange.upperBound..<(idRange.upperBound + mediaTypeLength)
        guard contentLength <= upperBound - mediaTypeRange.upperBound else {
            throw RuneScribePackageError.invalidResourceTable
        }
        let contentRange = mediaTypeRange.upperBound..<(mediaTypeRange.upperBound + contentLength)
        return RecordLayout(
            kind: kind,
            version: version,
            hashRange: hashRange,
            idRange: idRange,
            mediaTypeRange: mediaTypeRange,
            contentRange: contentRange
        )
    }

    private static func validateRecord(_ record: RecordLayout, in data: Data) throws {
        guard RuneScribePackageResourceKind(rawValue: record.kind) != nil else {
            throw RuneScribePackageError.invalidResourceKind
        }
        guard record.version > 0 else {
            throw RuneScribePackageError.invalidResourceVersion
        }
        guard RuneScribePackageResource.hasValidIdentifierBytes(data[record.idRange]) else {
            throw RuneScribePackageError.invalidResourceIdentifier
        }
        guard RuneScribePackageResource.hasAllowedMediaTypeBytes(
            data[record.mediaTypeRange],
            for: record.kind
        ) else {
            throw RuneScribePackageError.invalidResourceMediaType
        }
        let digest = SHA256.hash(data: data[record.contentRange])
        guard data[record.hashRange].elementsEqual(digest) else {
            throw RuneScribePackageError.resourceHashMismatch
        }
    }
}

/// Typed vNext `.runescribe` container. Public sharing remains on the frozen legacy
/// formats until compatibility policy review; this codec supplies the bounded intake
/// and fixture foundation without changing current outbound behavior.
struct RuneScribePackage: Equatable, Sendable {
    static let magic = RuneScribeWireFormat.containerMagic // RSCRPKG\n
    static let containerVersion = UInt16(RuneScribeWireFormat.containerVersion)
    static let fixedHeaderLength = 32
    static let directoryRecordLength = 16
    static let checksumLength = 32
    static let maximumTotalLength = 16 * 1024 * 1024
    static let maximumSectionCount = 16
    static let maximumResourceTableLength = 12 * 1024 * 1024

    let kind: RuneScribePackageKind
    let payloadVersion: UInt16
    let sections: [RuneScribePackageSection]

    init(
        kind: RuneScribePackageKind,
        payloadVersion: UInt16,
        sections: [RuneScribePackageSection]
    ) throws {
        self.kind = kind
        self.payloadVersion = payloadVersion
        self.sections = sections.sorted { $0.type < $1.type }
        try Self.validateSemanticShape(
            kind: kind,
            payloadVersion: payloadVersion,
            sections: self.sections
        )
    }

    var corePayload: Data {
        sections.first { $0.type == RuneScribePackageSectionType.corePayload.rawValue }?.data
            ?? Data()
    }

    /// Resolves the one legacy-font resource required by the Core payload. The
    /// resource table verifies its own content hashes; this additional binding
    /// prevents a valid but unrelated font resource from satisfying the payload's
    /// `FontRef`.
    func legacyFontBytes(matching reference: FontRef?) throws -> Data? {
        guard let reference, reference != .bundled else { return nil }
        guard let section = sections.first(where: {
            $0.type == RuneScribePackageSectionType.resourceTable.rawValue
        }), section.version == RuneScribePackageResourceTable.version else {
            throw RuneScribePackageError.missingLegacyFontResource
        }

        let table = try RuneScribePackageResourceTable(decoding: section.data)
        guard let expectedVersion = UInt32(exactly: reference.version),
              let resource = table.resources.first(where: {
                  $0.kind == RuneScribePackageResourceKind.legacyFont.rawValue
                      && $0.id == reference.id
                      && $0.version == expectedVersion
              })
        else {
            throw RuneScribePackageError.missingLegacyFontResource
        }
        guard RuneScribePackageResource.hasAllowedMediaType(
            resource.mediaType,
            for: resource.kind
        ) else {
            throw RuneScribePackageError.invalidResourceMediaType
        }
        guard resource.sha256 == reference.sha256 else {
            throw RuneScribePackageError.legacyFontResourceReferenceMismatch
        }
        return resource.data
    }

    func encoded() throws -> Data {
        try Self.validateSemanticShape(
            kind: kind,
            payloadVersion: payloadVersion,
            sections: sections
        )
        let directoryLength = sections.count * Self.directoryRecordLength
        let headerLength = Self.fixedHeaderLength + directoryLength
        let bodyLength = sections.reduce(0) { $0 + $1.data.count }
        let totalLength = headerLength + bodyLength + Self.checksumLength
        guard totalLength <= Self.maximumTotalLength,
              totalLength <= Int(UInt32.max)
        else {
            throw RuneScribePackageError.packageTooLarge
        }

        var output = Data()
        output.reserveCapacity(totalLength)
        output.append(Self.magic)
        output.appendBigEndian(Self.containerVersion)
        output.appendBigEndian(UInt16(headerLength))
        output.appendBigEndian(UInt32(totalLength))
        output.appendBigEndian(kind.rawValue)
        output.appendBigEndian(payloadVersion)
        output.appendBigEndian(UInt16(sections.count))
        output.appendBigEndian(UInt16(0))
        output.appendBigEndian(UInt32(directoryLength))
        output.appendBigEndian(UInt32(0))

        var offset = headerLength
        for section in sections {
            output.appendBigEndian(section.type)
            output.appendBigEndian(section.version)
            output.appendBigEndian(section.required ? RuneScribePackageSection.requiredFlag : 0)
            output.appendBigEndian(UInt16(0))
            output.appendBigEndian(UInt32(offset))
            output.appendBigEndian(UInt32(section.data.count))
            offset += section.data.count
        }
        for section in sections {
            output.append(section.data)
        }
        output.append(Data(SHA256.hash(data: output)))
        return output
    }

    init(decoding data: Data) throws {
        try self.init(decoding: data, allocationObserver: nil)
    }

    init(
        decoding data: Data,
        allocationObserver: ((RuneScribePackageDecodeAllocation) -> Void)?
    ) throws {
        if data.count < Self.magic.count {
            if Self.magic.starts(with: data) {
                throw RuneScribePackageError.truncatedMagic
            }
            throw RuneScribePackageError.badMagic
        }
        guard data.prefix(Self.magic.count) == Self.magic else {
            throw RuneScribePackageError.badMagic
        }
        guard data.count >= Self.fixedHeaderLength + Self.checksumLength else {
            throw RuneScribePackageError.truncatedHeader
        }
        guard data.count <= Self.maximumTotalLength else {
            throw RuneScribePackageError.packageTooLarge
        }

        let version = data.uint16(at: 8)
        guard version == Self.containerVersion else {
            throw RuneScribePackageError.unsupportedContainerVersion(version)
        }
        let headerLength = Int(data.uint16(at: 10))
        let declaredTotalLength = Int(data.uint32(at: 12))
        let rawKind = data.uint16(at: 16)
        let payloadVersion = data.uint16(at: 18)
        let sectionCount = Int(data.uint16(at: 20))
        let flags = data.uint16(at: 22)
        let directoryLength = Int(data.uint32(at: 24))
        let reserved = data.uint32(at: 28)

        guard flags == 0 else { throw RuneScribePackageError.unsupportedFlags(flags) }
        guard reserved == 0 else { throw RuneScribePackageError.invalidDirectory }
        guard declaredTotalLength == data.count else {
            throw RuneScribePackageError.lengthMismatch
        }
        guard sectionCount <= Self.maximumSectionCount else {
            throw RuneScribePackageError.tooManySections
        }
        let expectedDirectoryLength = sectionCount * Self.directoryRecordLength
        guard directoryLength == expectedDirectoryLength,
              headerLength == Self.fixedHeaderLength + expectedDirectoryLength,
              headerLength <= data.count - Self.checksumLength
        else {
            throw RuneScribePackageError.invalidHeaderLength
        }

        let checksumStart = data.count - Self.checksumLength
        let expectedChecksum = Data(SHA256.hash(data: data.prefix(checksumStart)))
        guard expectedChecksum == data.suffix(Self.checksumLength) else {
            throw RuneScribePackageError.badChecksum
        }

        guard let kind = RuneScribePackageKind(rawValue: rawKind) else {
            throw RuneScribePackageError.unsupportedPayloadKind(rawKind)
        }

        switch kind {
        case .cipherInvitation:
            guard payloadVersion == UInt16(CipherSharePayload.version) else {
                throw RuneScribePackageError.unsupportedPayloadVersion(
                    kind: kind.rawValue,
                    version: payloadVersion
                )
            }
        case .encryptedMessage:
            guard payloadVersion == UInt16(MessageSharePayload.version) else {
                throw RuneScribePackageError.unsupportedPayloadVersion(
                    kind: kind.rawValue,
                    version: payloadVersion
                )
            }
        }

        // Pass one validates the complete directory before reserving the output
        // array or copying any section. A malformed late record therefore cannot
        // cause an earlier valid payload to be allocated first.
        var expectedOffset = headerLength
        var priorType: UInt16?
        var coreCount = 0
        for index in 0..<sectionCount {
            let base = Self.fixedHeaderLength + index * Self.directoryRecordLength
            let type = data.uint16(at: base)
            let sectionVersion = data.uint16(at: base + 2)
            let sectionFlags = data.uint16(at: base + 4)
            let sectionReserved = data.uint16(at: base + 6)
            let offset = Int(data.uint32(at: base + 8))
            let length = Int(data.uint32(at: base + 12))

            guard sectionReserved == 0,
                  sectionFlags & ~RuneScribePackageSection.requiredFlag == 0
            else {
                throw RuneScribePackageError.invalidDirectory
            }
            if let priorType {
                guard type > priorType else {
                    if type == priorType {
                        throw RuneScribePackageError.duplicateSection(type)
                    }
                    throw RuneScribePackageError.nonCanonicalSectionOrder
                }
            }
            guard offset == expectedOffset,
                  length <= checksumStart - offset
            else {
                throw RuneScribePackageError.nonContiguousSections
            }
            try Self.validateSectionLength(type: type, length: length)
            let required = sectionFlags & RuneScribePackageSection.requiredFlag != 0
            if let knownType = RuneScribePackageSectionType(rawValue: type) {
                if sectionVersion != 1, required {
                    throw RuneScribePackageError.unsupportedRequiredSectionVersion(
                        type: type,
                        version: sectionVersion
                    )
                }
                _ = knownType
            } else if required {
                throw RuneScribePackageError.unknownRequiredSection(type)
            }
            let end = offset + length
            if type == RuneScribePackageSectionType.corePayload.rawValue {
                coreCount += 1
                guard required, sectionVersion == 1, length > 0 else {
                    throw RuneScribePackageError.invalidCorePayload
                }
            }
            priorType = type
            expectedOffset = end
        }
        guard expectedOffset == checksumStart else {
            throw RuneScribePackageError.nonContiguousSections
        }
        guard coreCount == 1 else {
            throw RuneScribePackageError.missingCorePayload
        }

        // Pass two preflights nested resource records directly in the caller's
        // buffer. Invalid resource metadata is rejected before any section copy.
        for index in 0..<sectionCount {
            let base = Self.fixedHeaderLength + index * Self.directoryRecordLength
            let type = data.uint16(at: base)
            let sectionVersion = data.uint16(at: base + 2)
            guard type == RuneScribePackageSectionType.resourceTable.rawValue,
                  sectionVersion == RuneScribePackageResourceTable.version
            else { continue }
            let offset = Int(data.uint32(at: base + 8))
            let length = Int(data.uint32(at: base + 12))
            try RuneScribePackageResourceTable.preflight(
                decoding: data,
                in: offset..<(offset + length)
            )
        }

        var decodedSections: [RuneScribePackageSection] = []
        allocationObserver?(.sectionArrayCapacity(sectionCount))
        decodedSections.reserveCapacity(sectionCount)
        for index in 0..<sectionCount {
            let base = Self.fixedHeaderLength + index * Self.directoryRecordLength
            let type = data.uint16(at: base)
            let sectionVersion = data.uint16(at: base + 2)
            let sectionFlags = data.uint16(at: base + 4)
            let offset = Int(data.uint32(at: base + 8))
            let length = Int(data.uint32(at: base + 12))
            let end = offset + length
            allocationObserver?(.sectionPayload(length))
            decodedSections.append(RuneScribePackageSection(
                type: type,
                version: sectionVersion,
                required: sectionFlags & RuneScribePackageSection.requiredFlag != 0,
                data: data.subdata(in: offset..<end)
            ))
        }
        try Self.validateSemanticShape(
            kind: kind,
            payloadVersion: payloadVersion,
            sections: decodedSections,
            allocationObserver: allocationObserver
        )
        self.kind = kind
        self.payloadVersion = payloadVersion
        self.sections = decodedSections
    }

    static func hasMagic(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    static func hasPartialMagic(_ data: Data) -> Bool {
        !data.isEmpty && data.count < magic.count && magic.starts(with: data)
    }

    private static func validateSemanticShape(
        kind: RuneScribePackageKind,
        payloadVersion: UInt16,
        sections: [RuneScribePackageSection],
        allocationObserver: ((RuneScribePackageDecodeAllocation) -> Void)? = nil
    ) throws {
        guard sections.count <= maximumSectionCount else {
            throw RuneScribePackageError.tooManySections
        }
        var priorType: UInt16?
        var coreCount = 0
        for section in sections {
            if let priorType {
                guard section.type > priorType else {
                    if section.type == priorType {
                        throw RuneScribePackageError.duplicateSection(section.type)
                    }
                    throw RuneScribePackageError.nonCanonicalSectionOrder
                }
            }
            try validateSectionLength(type: section.type, length: section.data.count)
            if section.type == RuneScribePackageSectionType.corePayload.rawValue {
                coreCount += 1
                guard section.required, section.version == 1, !section.data.isEmpty else {
                    throw RuneScribePackageError.invalidCorePayload
                }
            } else if let knownType = RuneScribePackageSectionType(rawValue: section.type) {
                if section.version != 1, section.required {
                    throw RuneScribePackageError.unsupportedRequiredSectionVersion(
                        type: section.type,
                        version: section.version
                    )
                }
                if knownType == .resourceTable, section.version == 1 {
                    _ = try RuneScribePackageResourceTable(
                        decoding: section.data,
                        allocationObserver: allocationObserver
                    )
                }
            } else if section.required {
                throw RuneScribePackageError.unknownRequiredSection(section.type)
            }
            priorType = section.type
        }
        guard coreCount == 1 else { throw RuneScribePackageError.missingCorePayload }
        switch kind {
        case .cipherInvitation:
            guard payloadVersion == UInt16(CipherSharePayload.version) else {
                throw RuneScribePackageError.unsupportedPayloadVersion(
                    kind: kind.rawValue,
                    version: payloadVersion
                )
            }
            do {
                _ = try CipherSharePayload(decoding: sections.first {
                    $0.type == RuneScribePackageSectionType.corePayload.rawValue
                }!.data)
            } catch {
                throw RuneScribePackageError.invalidCorePayload
            }
        case .encryptedMessage:
            guard payloadVersion == UInt16(MessageSharePayload.version) else {
                throw RuneScribePackageError.unsupportedPayloadVersion(
                    kind: kind.rawValue,
                    version: payloadVersion
                )
            }
            do {
                _ = try MessageSharePayload(decoding: sections.first {
                    $0.type == RuneScribePackageSectionType.corePayload.rawValue
                }!.data)
            } catch {
                throw RuneScribePackageError.invalidCorePayload
            }
        }
    }

    private static func validateSectionLength(type: UInt16, length: Int) throws {
        let maximum: Int
        switch RuneScribePackageSectionType(rawValue: type) {
        case .corePayload: maximum = 1 * 1024 * 1024
        case .presentationMetadata: maximum = 64 * 1024
        case .safePreview: maximum = 4 * 1024 * 1024
        case .resourceTable: maximum = maximumResourceTableLength
        case .signedProvenance: maximum = 64 * 1024
        case nil: maximum = 1 * 1024 * 1024
        }
        guard length <= maximum else {
            throw RuneScribePackageError.sectionTooLarge(type)
        }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        var encoded = value.bigEndian
        append(Data(bytes: &encoded, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        var encoded = value.bigEndian
        append(Data(bytes: &encoded, count: MemoryLayout<UInt32>.size))
    }

    func uint16(at offset: Int) -> UInt16 {
        self[offset..<(offset + 2)].reduce(0) { ($0 << 8) | UInt16($1) }
    }

    func uint32(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
