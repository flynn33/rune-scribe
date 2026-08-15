import Foundation

enum ProgressionProjectionComparison {
    static func hasEquivalentDomainState(
        _ lhs: ProgressionProjection,
        _ rhs: ProgressionProjection
    ) throws -> Bool {
        guard lhs.metadata.catalogID == rhs.metadata.catalogID,
              lhs.metadata.catalogVersion == rhs.metadata.catalogVersion,
              lhs.metadata.initializedAt == rhs.metadata.initializedAt,
              lhs.metadata.appliedEventCount == rhs.metadata.appliedEventCount,
              lhs.metadata.lastAppliedRevision == rhs.metadata.lastAppliedRevision,
              lhs.metadata.appliedEventDigest == rhs.metadata.appliedEventDigest,
              lhs.metadata.processedEventCount == rhs.metadata.processedEventCount,
              lhs.metadata.terminalProcessedEventDigest ==
                rhs.metadata.terminalProcessedEventDigest,
              lhs.metadata.distinctTokenCount == rhs.metadata.distinctTokenCount,
              lhs.metadata.acknowledgedRevealCount == rhs.metadata.acknowledgedRevealCount,
              lhs.metadata.acknowledgedRevealDigest == rhs.metadata.acknowledgedRevealDigest,
              lhs.metadata.commandReceiptCount == rhs.metadata.commandReceiptCount,
              lhs.metadata.commandReceiptDigest == rhs.metadata.commandReceiptDigest
        else { return false }
        return try lhs.logicalRecords().map(normalizedRecord) ==
            rhs.logicalRecords().map(normalizedRecord)
    }

    static func hasEquivalentLogicalRecord(
        _ lhs: ProgressionLogicalRecord,
        _ rhs: ProgressionLogicalRecord
    ) throws -> Bool {
        try normalizedRecord(lhs) == normalizedRecord(rhs)
    }

    private static func normalizedRecord(_ record: ProgressionLogicalRecord) throws -> Data {
        let encoded = try ProgressionDeterminism.encoder().encode(record)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let normalized = normalize(object)
        return try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
    }

    private static func normalize(_ value: Any) -> Any {
        if let values = value as? [Any] {
            return values.map(normalize)
        }
        if let values = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, nested) in values {
                result[key] = key == "generation"
                    ? "00000000000000000000000000000000"
                    : normalize(nested)
            }
            return result
        }
        return value
    }
}
