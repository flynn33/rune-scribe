import Foundation

public struct RuntimeSelectedCodexPreference: Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let codexID: CodexID

    public init(codexID: CodexID) throws {
        guard codexID.rawValue.hasPrefix("codex.") else {
            throw RuntimeArtifactSelectionContractError.invalidCodexID
        }
        self.codexID = codexID
    }
}

public enum RuntimeSelectedCodexPreferenceCodec {
    private static let rootKeys: Set<String> = ["schemaVersion", "codexID"]

    private struct Document: Decodable {
        let schemaVersion: Int
        let codexID: String
    }

    public static func encode(
        _ preference: RuntimeSelectedCodexPreference
    ) throws -> RuntimeSettingText {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": RuntimeSelectedCodexPreference.currentSchemaVersion,
                "codexID": preference.codexID.rawValue,
            ],
            options: [.sortedKeys]
        )
        guard let rawValue = String(data: data, encoding: .utf8),
              let text = RuntimeSettingText(rawValue: rawValue)
        else {
            throw RuntimeArtifactSelectionContractError.malformed
        }
        return text
    }

    public static func decodeForRead(
        _ text: RuntimeSettingText
    ) throws -> (value: RuntimeSelectedCodexPreference, encoding: RuntimeArtifactSelectionEncoding) {
        if text.rawValue.first != "{" {
            guard let codexID = CodexID(rawValue: text.rawValue) else {
                throw RuntimeArtifactSelectionContractError.invalidCodexID
            }
            return (
                try RuntimeSelectedCodexPreference(codexID: codexID),
                .legacyUnversioned
            )
        }
        return (try decodeCurrentValue(text), .current)
    }

    public static func decodeCurrentWrite(
        _ text: RuntimeSettingText
    ) throws -> RuntimeSelectedCodexPreference {
        let value = try decodeCurrentValue(text)
        guard try encode(value) == text else {
            throw RuntimeArtifactSelectionContractError.nonCanonical
        }
        return value
    }

    private static func decodeCurrentValue(
        _ text: RuntimeSettingText
    ) throws -> RuntimeSelectedCodexPreference {
        guard let data = text.rawValue.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw RuntimeArtifactSelectionContractError.malformed
        }
        guard Set(root.keys) == rootKeys else {
            throw RuntimeArtifactSelectionContractError.unexpectedFields
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data)
        else {
            throw RuntimeArtifactSelectionContractError.malformed
        }
        let version = document.schemaVersion
        guard version == RuntimeSelectedCodexPreference.currentSchemaVersion else {
            throw RuntimeArtifactSelectionContractError.unsupportedVersion(version)
        }
        guard let codexID = CodexID(rawValue: document.codexID)
        else {
            throw RuntimeArtifactSelectionContractError.invalidCodexID
        }
        return try RuntimeSelectedCodexPreference(codexID: codexID)
    }
}

public enum RuntimeArtifactSelectionKind: String, Codable, CaseIterable, Sendable {
    case relic
    case seal
    case frame

    public var settingID: RuntimeSettingID {
        switch self {
        case .relic: RuneScribeRuntimeSettings.selectedRelicByCodex
        case .seal: RuneScribeRuntimeSettings.selectedSealByCodex
        case .frame: RuneScribeRuntimeSettings.selectedFrameByCodex
        }
    }

    fileprivate var permitsExplicitNone: Bool {
        self == .seal || self == .frame
    }

    fileprivate func accepts(_ artifactID: ArtifactID) -> Bool {
        artifactID.rawValue.hasPrefix("\(rawValue).")
            && artifactID.rawValue != "\(rawValue).none"
    }

    fileprivate func accepts(_ artifactID: ArtifactID?) -> Bool {
        guard let artifactID else { return permitsExplicitNone }
        return accepts(artifactID)
    }
}

public enum RuntimeArtifactSelectionContractError: Error, Equatable, Sendable {
    case inputTooLarge(maximumUTF8Count: Int)
    case unsupportedVersion(Int)
    case malformed
    case unexpectedFields
    case kindMismatch
    case tooManySelections(maximum: Int)
    case duplicateCodexID
    case invalidCodexID
    case invalidArtifactID
    case artifactKindMismatch
    case nonCanonical
}

public struct RuntimeCodexArtifactSelection: Equatable, Hashable, Sendable {
    public let codexID: CodexID
    public let artifactID: ArtifactID?

    public init(
        codexID: CodexID,
        artifactID: ArtifactID?,
        kind: RuntimeArtifactSelectionKind
    ) throws {
        guard codexID.rawValue.hasPrefix("codex.") else {
            throw RuntimeArtifactSelectionContractError.invalidCodexID
        }
        guard kind.accepts(artifactID) else {
            throw RuntimeArtifactSelectionContractError.artifactKindMismatch
        }
        self.codexID = codexID
        self.artifactID = artifactID
    }
}

public enum RuntimeArtifactSelectionPreference: Equatable, Hashable, Sendable {
    case artifact(ArtifactID)
    case none
}

public struct RuntimeCodexArtifactSelectionMap: Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let maximumSelectionCount = 16
    public static let maximumEncodedUTF8Count = 2_048

    public let kind: RuntimeArtifactSelectionKind
    public let selections: [RuntimeCodexArtifactSelection]

    public init(
        kind: RuntimeArtifactSelectionKind,
        selections: [RuntimeCodexArtifactSelection] = []
    ) throws {
        guard selections.count <= Self.maximumSelectionCount else {
            throw RuntimeArtifactSelectionContractError.tooManySelections(
                maximum: Self.maximumSelectionCount
            )
        }
        guard Set(selections.map(\.codexID)).count == selections.count else {
            throw RuntimeArtifactSelectionContractError.duplicateCodexID
        }
        guard selections.allSatisfy({
            $0.codexID.rawValue.hasPrefix("codex.") && kind.accepts($0.artifactID)
        }) else {
            throw RuntimeArtifactSelectionContractError.artifactKindMismatch
        }
        self.kind = kind
        self.selections = selections.sorted { $0.codexID < $1.codexID }
    }

    public subscript(_ codexID: CodexID) -> ArtifactID? {
        selections.first { $0.codexID == codexID }?.artifactID
    }

    /// Distinguishes an explicit optional `None` from an absent preference.
    public func storedPreference(
        for codexID: CodexID
    ) -> RuntimeArtifactSelectionPreference? {
        guard let selection = selections.first(where: { $0.codexID == codexID }) else {
            return nil
        }
        guard let artifactID = selection.artifactID else {
            return RuntimeArtifactSelectionPreference.none
        }
        return .artifact(artifactID)
    }

    public func setting(
        _ artifactID: ArtifactID?,
        for codexID: CodexID
    ) throws -> RuntimeCodexArtifactSelectionMap {
        let replacement = try RuntimeCodexArtifactSelection(
            codexID: codexID,
            artifactID: artifactID,
            kind: kind
        )
        return try RuntimeCodexArtifactSelectionMap(
            kind: kind,
            selections: selections.filter { $0.codexID != codexID } + [replacement]
        )
    }

    /// Resolves a preference only against the caller's authoritative available set.
    /// A stale or unavailable preference can therefore never escape as a selection.
    public func resolvedArtifactID(
        for codexID: CodexID,
        availableArtifactIDs: Set<ArtifactID>,
        fallbackArtifactID: ArtifactID? = nil
    ) -> ArtifactID? {
        if let preference = storedPreference(for: codexID) {
            switch preference {
            case .artifact(let selected) where availableArtifactIDs.contains(selected):
                return selected
            case .none:
                return nil
            case .artifact:
                break
            }
        }
        if let fallbackArtifactID, availableArtifactIDs.contains(fallbackArtifactID) {
            return fallbackArtifactID
        }
        return availableArtifactIDs.sorted().first
    }
}

public enum RuntimeArtifactSelectionEncoding: Equatable, Sendable {
    case current
    case legacySchemaVersion(Int)
    case legacyUnversioned
}

public struct RuntimeArtifactSelectionDecodeResult: Equatable, Sendable {
    public let value: RuntimeCodexArtifactSelectionMap
    public let encoding: RuntimeArtifactSelectionEncoding

    public init(
        value: RuntimeCodexArtifactSelectionMap,
        encoding: RuntimeArtifactSelectionEncoding
    ) {
        self.value = value
        self.encoding = encoding
    }
}

public enum RuntimeArtifactSelectionCodec {
    private static let rootKeys: Set<String> = ["schemaVersion", "kind", "selections"]
    private static let selectionKeys: Set<String> = ["codexID", "artifactID"]

    private struct Document: Decodable {
        let schemaVersion: Int
        let kind: String
        let selections: [SelectionDocument]
    }

    private struct SelectionDocument: Decodable {
        let codexID: String
        let artifactID: String?
    }

    public static func encode(
        _ value: RuntimeCodexArtifactSelectionMap
    ) throws -> RuntimeSettingText {
        let encodedSelections: [[String: Any]] = value.selections.map { selection in
            var encoded: [String: Any] = ["codexID": selection.codexID.rawValue]
            encoded["artifactID"] = selection.artifactID?.rawValue ?? NSNull()
            return encoded
        }
        let object: [String: Any] = [
            "schemaVersion": RuntimeCodexArtifactSelectionMap.currentSchemaVersion,
            "kind": value.kind.rawValue,
            "selections": encodedSelections,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= RuntimeCodexArtifactSelectionMap.maximumEncodedUTF8Count,
              let rawValue = String(data: data, encoding: .utf8),
              let text = RuntimeSettingText(rawValue: rawValue)
        else {
            throw RuntimeArtifactSelectionContractError.inputTooLarge(
                maximumUTF8Count: RuntimeCodexArtifactSelectionMap.maximumEncodedUTF8Count
            )
        }
        return text
    }

    /// Reads schema v2 plus the supported v1 and unversioned migration forms.
    public static func decodeForRead(
        _ text: RuntimeSettingText,
        expectedKind: RuntimeArtifactSelectionKind
    ) throws -> RuntimeArtifactSelectionDecodeResult {
        guard text.rawValue.utf8.count
            <= RuntimeCodexArtifactSelectionMap.maximumEncodedUTF8Count
        else {
            throw RuntimeArtifactSelectionContractError.inputTooLarge(
                maximumUTF8Count: RuntimeCodexArtifactSelectionMap.maximumEncodedUTF8Count
            )
        }
        if text.rawValue.first == "{" {
            let decoded = try decodeVersionedValue(text, expectedKind: expectedKind)
            return RuntimeArtifactSelectionDecodeResult(
                value: decoded.value,
                encoding: decoded.schemaVersion
                    == RuntimeCodexArtifactSelectionMap.currentSchemaVersion
                    ? .current
                    : .legacySchemaVersion(decoded.schemaVersion)
            )
        }
        return RuntimeArtifactSelectionDecodeResult(
            value: try decodeLegacyValue(text.rawValue, expectedKind: expectedKind),
            encoding: .legacyUnversioned
        )
    }

    /// Accepts only byte-for-byte canonical current encoding for new writes.
    public static func decodeCurrentWrite(
        _ text: RuntimeSettingText,
        expectedKind: RuntimeArtifactSelectionKind
    ) throws -> RuntimeCodexArtifactSelectionMap {
        let decoded = try decodeVersionedValue(text, expectedKind: expectedKind)
        guard decoded.schemaVersion == RuntimeCodexArtifactSelectionMap.currentSchemaVersion,
              try encode(decoded.value) == text
        else {
            throw RuntimeArtifactSelectionContractError.nonCanonical
        }
        return decoded.value
    }

    private static func decodeVersionedValue(
        _ text: RuntimeSettingText,
        expectedKind: RuntimeArtifactSelectionKind
    ) throws -> (value: RuntimeCodexArtifactSelectionMap, schemaVersion: Int) {
        guard let data = text.rawValue.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw RuntimeArtifactSelectionContractError.malformed
        }
        guard Set(root.keys) == rootKeys else {
            throw RuntimeArtifactSelectionContractError.unexpectedFields
        }
        guard let rawSelections = root["selections"] as? [[String: Any]]
        else {
            throw RuntimeArtifactSelectionContractError.kindMismatch
        }
        guard rawSelections.allSatisfy({ Set($0.keys) == selectionKeys }) else {
            throw RuntimeArtifactSelectionContractError.unexpectedFields
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            throw RuntimeArtifactSelectionContractError.malformed
        }
        let schemaVersion = document.schemaVersion
        guard schemaVersion == 1
                || schemaVersion == RuntimeCodexArtifactSelectionMap.currentSchemaVersion
        else {
            throw RuntimeArtifactSelectionContractError.unsupportedVersion(schemaVersion)
        }
        guard let kind = RuntimeArtifactSelectionKind(rawValue: document.kind),
              kind == expectedKind,
              rawSelections.count == document.selections.count
        else {
            throw RuntimeArtifactSelectionContractError.kindMismatch
        }
        guard document.selections.count
                <= RuntimeCodexArtifactSelectionMap.maximumSelectionCount
        else {
            throw RuntimeArtifactSelectionContractError.tooManySelections(
                maximum: RuntimeCodexArtifactSelectionMap.maximumSelectionCount
            )
        }
        let selections = try document.selections.map { raw -> RuntimeCodexArtifactSelection in
            guard let codexID = CodexID(rawValue: raw.codexID)
            else {
                throw RuntimeArtifactSelectionContractError.invalidCodexID
            }
            let artifactID: ArtifactID?
            if let artifactRawValue = raw.artifactID {
                if schemaVersion == 1,
                   expectedKind.permitsExplicitNone,
                   artifactRawValue == "\(expectedKind.rawValue).none" {
                    artifactID = nil
                } else {
                    guard let decodedArtifactID = ArtifactID(rawValue: artifactRawValue) else {
                        throw RuntimeArtifactSelectionContractError.invalidArtifactID
                    }
                    artifactID = decodedArtifactID
                }
            } else {
                guard schemaVersion == RuntimeCodexArtifactSelectionMap.currentSchemaVersion else {
                    throw RuntimeArtifactSelectionContractError.invalidArtifactID
                }
                artifactID = nil
            }
            return try RuntimeCodexArtifactSelection(
                codexID: codexID,
                artifactID: artifactID,
                kind: expectedKind
            )
        }
        return (
            try RuntimeCodexArtifactSelectionMap(kind: expectedKind, selections: selections),
            schemaVersion
        )
    }

    private static func decodeLegacyValue(
        _ rawValue: String,
        expectedKind: RuntimeArtifactSelectionKind
    ) throws -> RuntimeCodexArtifactSelectionMap {
        let entries = rawValue.split(separator: ";", omittingEmptySubsequences: false)
        guard !entries.isEmpty,
              entries.count <= RuntimeCodexArtifactSelectionMap.maximumSelectionCount
        else {
            throw RuntimeArtifactSelectionContractError.malformed
        }
        let selections = try entries.map { rawEntry -> RuntimeCodexArtifactSelection in
            let parts = rawEntry.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let codexID = CodexID(rawValue: String(parts[0])),
                  let decodedArtifactID = ArtifactID(rawValue: String(parts[1]))
            else {
                throw RuntimeArtifactSelectionContractError.malformed
            }
            let artifactID: ArtifactID? = expectedKind.permitsExplicitNone
                && decodedArtifactID.rawValue == "\(expectedKind.rawValue).none"
                ? nil
                : decodedArtifactID
            return try RuntimeCodexArtifactSelection(
                codexID: codexID,
                artifactID: artifactID,
                kind: expectedKind
            )
        }
        return try RuntimeCodexArtifactSelectionMap(kind: expectedKind, selections: selections)
    }
}
