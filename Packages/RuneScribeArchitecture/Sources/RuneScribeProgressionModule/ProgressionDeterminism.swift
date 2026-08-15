import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ProgressionDeterminism {
    static func digest128(_ value: String) -> String {
        digest128(Data(value.utf8))
    }

    static func digest128(_ data: Data) -> String {
        let bytes = [UInt8](data)
        let first = hash64(bytes, seed: 0xcbf29ce484222325)
        let second = hash64(bytes.reversed(), seed: 0x84222325cbf29ce4)
        return hex(first) + hex(second)
    }

    static func transactionUUID(_ material: String) -> UUID {
        let digest = digest128(material)
        var bytes = stride(from: 0, to: 32, by: 2).map { offset -> UInt8 in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            let end = digest.index(start, offsetBy: 2)
            return UInt8(digest[start ..< end], radix: 16)!
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func encodedDigest<T: Encodable>(_ value: T) throws -> String {
        digest128(try encoder().encode(value))
    }

    static func encodedIntegrityDigest<T: Encodable>(_ value: T) throws -> String {
        RuntimeIntegrityDigest.sha256Hex(try encoder().encode(value))
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    static func isIntegrityDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    static func xorDigest(_ current: String?, with value: String) -> String {
        precondition(current.map(isIntegrityDigest) ?? true)
        precondition(isIntegrityDigest(value))
        let left = current ?? String(repeating: "0", count: 64)
        return stride(from: 0, to: 64, by: 2).map { offset in
            let leftStart = left.index(left.startIndex, offsetBy: offset)
            let valueStart = value.index(value.startIndex, offsetBy: offset)
            let leftByte = UInt8(left[leftStart ..< left.index(leftStart, offsetBy: 2)], radix: 16)!
            let valueByte = UInt8(
                value[valueStart ..< value.index(valueStart, offsetBy: 2)],
                radix: 16
            )!
            let raw = String(leftByte ^ valueByte, radix: 16)
            return raw.count == 1 ? "0\(raw)" : raw
        }.joined()
    }

    static func canonicalAcknowledgementDigest(
        _ value: PendingRevealRecord
    ) throws -> String {
        try encodedIntegrityDigest(PendingRevealRecord(
            generation: String(repeating: "0", count: 32),
            revealID: value.revealID,
            transactionID: value.transactionID,
            createdRevision: value.createdRevision,
            createdAt: value.createdAt,
            state: value.state,
            presentedAt: value.presentedAt,
            acknowledgedAt: value.acknowledgedAt,
            tier: value.tier,
            primaryContentID: value.primaryContentID,
            secondaryContentIDs: value.secondaryContentIDs,
            sourceAchievementIDs: value.sourceAchievementIDs,
            sourceRuleIDs: value.sourceRuleIDs,
            nextRevealID: value.nextRevealID
        ))
    }

    static func isBoundedRuntimeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 192 && value.utf8.allSatisfy {
            $0 >= 0x21 && $0 <= 0x7e
        }
    }

    private static func hash64<S: Sequence>(
        _ bytes: S,
        seed: UInt64
    ) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
            hash ^= hash >> 32
        }
        return hash
    }

    private static func hex(_ value: UInt64) -> String {
        let raw = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: 16 - raw.count) + raw
    }
}
