import CryptoKit
import Foundation

public enum CloudProgressionCodecError: Error, Equatable, Sendable {
    case inputTooLarge(maximum: Int, actual: Int)
    case invalidJSON
    case invalidTopLevel
    case unknownField(path: String, field: String)
    case missingField(path: String, field: String)
    case prohibitedField(path: String, field: String)
}

public enum CloudProgressionCodec {
    public static let maximumEncodedByteCount = 2 * 1_024 * 1_024

    public static func encode(_ replica: CloudProgressionReplica) throws -> Data {
        try replica.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(replica)
        guard data.count <= maximumEncodedByteCount else {
            throw CloudProgressionCodecError.inputTooLarge(
                maximum: maximumEncodedByteCount,
                actual: data.count
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> CloudProgressionReplica {
        guard data.count <= maximumEncodedByteCount else {
            throw CloudProgressionCodecError.inputTooLarge(
                maximum: maximumEncodedByteCount,
                actual: data.count
            )
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CloudProgressionCodecError.invalidJSON
        }
        guard let top = object as? [String: Any] else {
            throw CloudProgressionCodecError.invalidTopLevel
        }
        try CloudProgressionWireSchema.validate(top)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let replica = try decoder.decode(CloudProgressionReplica.self, from: data)
        try replica.validate()
        return replica
    }

    public static func digest(of data: Data) -> CloudOpaqueIdentifier {
        let value = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return CloudOpaqueIdentifier(rawValue: value)!
    }
}

private enum CloudProgressionWireSchema {
    private static let prohibitedNormalizedFieldFragments = [
        "cipherkey",
        "cipherbytes",
        "plaintext",
        "contact",
        "phonenumber",
        "emailaddress",
        "rawrelationship",
        "messagetext",
        "messagebytes",
        "qrcode",
        "keychain",
        "privatelog",
        "packagebytes",
        "encryptedpackage",
    ]

    private static let topLevelRequired: Set<String> = [
        "schemaVersion",
        "catalogVersion",
        "logicalClock",
        "resetGeneration",
        "achievementCompletions",
        "milestoneCompletions",
        "grants",
        "ownedContentIDs",
        "unlockIDs",
        "titleIDs",
        "encounters",
        "deviceCounterShards",
        "distinctStatisticTokens",
        "achievementProgress",
        "pendingGameCenterReports",
        "provenanceReferences",
        "quarantineDiagnostics",
    ]
    private static let topLevelOptional: Set<String> = ["selectedCodex", "selectedTitle"]

    static func validate(_ top: [String: Any]) throws {
        try validateNoProhibitedFields(top, path: "$")
        try validateKeys(
            top,
            required: topLevelRequired,
            optional: topLevelOptional,
            path: "$"
        )
        try validateArray(
            top["achievementCompletions"],
            keys: ["achievementID", "firstCompletedAt"],
            path: "$.achievementCompletions"
        )
        try validateArray(
            top["milestoneCompletions"],
            keys: ["ruleID", "firstCompletedAt"],
            path: "$.milestoneCompletions"
        )
        try validateArray(
            top["grants"],
            required: ["grantID", "contentID", "firstGrantedAt"],
            optional: ["provenanceReference"],
            path: "$.grants"
        )
        try validateArray(
            top["encounters"],
            required: [
                "encounterID", "codexID", "artifactIDs", "firstEncounteredAt",
                "lastEncounteredAt", "encounterCount",
            ],
            optional: ["provenanceReference"],
            path: "$.encounters"
        )
        try validateArray(
            top["deviceCounterShards"],
            required: ["statisticID", "deviceID", "value", "lastUpdatedAt"],
            optional: ["codexID"],
            path: "$.deviceCounterShards"
        )
        try validateArray(
            top["distinctStatisticTokens"],
            required: ["statisticID", "token", "firstObservedAt"],
            optional: ["codexID"],
            path: "$.distinctStatisticTokens"
        )
        try validateArray(
            top["achievementProgress"],
            keys: ["achievementID", "current", "target", "lastUpdatedAt"],
            path: "$.achievementProgress"
        )
        try validateArray(
            top["pendingGameCenterReports"],
            keys: ["achievementID", "percentage", "firstQueuedAt", "lastUpdatedAt"],
            path: "$.pendingGameCenterReports"
        )
        try validateArray(
            top["quarantineDiagnostics"],
            keys: ["recordDigest", "category", "quarantinedAt"],
            path: "$.quarantineDiagnostics"
        )
        if let selectedCodex = top["selectedCodex"] as? [String: Any] {
            try validateKeys(
                selectedCodex,
                required: ["codexID", "logicalTimestamp", "writerDeviceID", "updatedAt"],
                optional: [],
                path: "$.selectedCodex"
            )
        } else if top["selectedCodex"] != nil {
            throw CloudProgressionCodecError.invalidJSON
        }
        if let selectedTitle = top["selectedTitle"] as? [String: Any] {
            try validateKeys(
                selectedTitle,
                required: ["logicalTimestamp", "writerDeviceID", "updatedAt"],
                optional: ["titleID"],
                path: "$.selectedTitle"
            )
        } else if top["selectedTitle"] != nil {
            throw CloudProgressionCodecError.invalidJSON
        }
    }

    private static func validateArray(
        _ value: Any?,
        keys: Set<String>,
        path: String
    ) throws {
        try validateArray(value, required: keys, optional: [], path: path)
    }

    private static func validateArray(
        _ value: Any?,
        required: Set<String>,
        optional: Set<String>,
        path: String
    ) throws {
        guard let values = value as? [Any] else {
            throw CloudProgressionCodecError.invalidJSON
        }
        for (index, value) in values.enumerated() {
            guard let record = value as? [String: Any] else {
                throw CloudProgressionCodecError.invalidJSON
            }
            try validateKeys(
                record,
                required: required,
                optional: optional,
                path: "\(path)[\(index)]"
            )
        }
    }

    private static func validateKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String>,
        path: String
    ) throws {
        let actual = Set(object.keys)
        if let missing = required.subtracting(actual).sorted().first {
            throw CloudProgressionCodecError.missingField(path: path, field: missing)
        }
        let allowed = required.union(optional)
        if let unknown = actual.subtracting(allowed).sorted().first {
            throw CloudProgressionCodecError.unknownField(path: path, field: unknown)
        }
    }

    private static func validateNoProhibitedFields(_ value: Any, path: String) throws {
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if prohibitedNormalizedFieldFragments.contains(where: normalized.contains) {
                    throw CloudProgressionCodecError.prohibitedField(path: path, field: key)
                }
                try validateNoProhibitedFields(nested, path: "\(path).\(key)")
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                try validateNoProhibitedFields(nested, path: "\(path)[\(index)]")
            }
        }
    }
}
