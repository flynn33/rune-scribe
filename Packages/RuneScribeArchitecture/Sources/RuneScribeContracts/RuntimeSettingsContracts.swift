import Foundation

public enum RuntimeSettingsContractError: Error, Equatable, Sendable {
    case tooManySettings(maximum: Int)
    case duplicateSettingID
    case invalidCapturedAt
    case invalidSplashLastShownAt
}

public enum RuntimeSettingValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case integer(Int64)
    case text(RuntimeSettingText)

    public var booleanValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }

    public var textValue: RuntimeSettingText? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    public var integerValue: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }
}

public struct RuntimeSettingText: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public static let maximumUTF8Count = 2_048

    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumUTF8Count,
              rawValue.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7F
              })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let text = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid setting text.")
            )
        }
        self = text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RuntimeSettingDescriptor: Codable, Equatable, Sendable {
    public let settingID: RuntimeSettingID
    public let defaultValue: RuntimeSettingValue

    public init(settingID: RuntimeSettingID, defaultValue: RuntimeSettingValue) {
        self.settingID = settingID
        self.defaultValue = defaultValue
    }
}

/// The persisted preference for optional decorative motion and presentation
/// effects. Required security feedback and readable text never depend on this
/// value.
public enum RuntimeEffectsPreference: String, Codable, CaseIterable, Sendable {
    case full
    case reduced
    case off

    public var settingValue: RuntimeSettingValue {
        .text(RuntimeSettingText(rawValue: rawValue)!)
    }

    public static func storedValue(_ value: RuntimeSettingValue?) -> Self {
        guard let rawValue = value?.textValue?.rawValue,
              let preference = Self(rawValue: rawValue)
        else { return .full }
        return preference
    }

    /// System Reduce Motion is an upper bound. It changes effective behavior,
    /// not the value saved by the user.
    public func effective(systemReduceMotion: Bool) -> Self {
        guard systemReduceMotion, self == .full else { return self }
        return .reduced
    }
}

public struct RuntimeSettingDTO: Codable, Equatable, Sendable {
    public let settingID: RuntimeSettingID
    public let value: RuntimeSettingValue
    public let revision: UInt64
    public let updatedAt: Date?

    public init(
        settingID: RuntimeSettingID,
        value: RuntimeSettingValue,
        revision: UInt64,
        updatedAt: Date?
    ) {
        self.settingID = settingID
        self.value = value
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct RuntimeSettingsSnapshotDTO: Codable, Equatable, Sendable {
    public static let maximumSettingCount = 64

    public let revision: UInt64
    public let capturedAt: Date
    public let settings: [RuntimeSettingDTO]

    public init(
        revision: UInt64,
        capturedAt: Date,
        settings: [RuntimeSettingDTO]
    ) throws {
        guard settings.count <= Self.maximumSettingCount else {
            throw RuntimeSettingsContractError.tooManySettings(
                maximum: Self.maximumSettingCount
            )
        }
        guard Set(settings.map(\.settingID)).count == settings.count else {
            throw RuntimeSettingsContractError.duplicateSettingID
        }
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RuntimeSettingsContractError.invalidCapturedAt
        }
        self.revision = revision
        self.capturedAt = capturedAt
        self.settings = settings.sorted { $0.settingID < $1.settingID }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            revision: container.decode(UInt64.self, forKey: .revision),
            capturedAt: container.decode(Date.self, forKey: .capturedAt),
            settings: container.decode([RuntimeSettingDTO].self, forKey: .settings)
        )
    }

    public subscript(_ settingID: RuntimeSettingID) -> RuntimeSettingValue? {
        settings.first { $0.settingID == settingID }?.value
    }
}

public struct SetRuntimeSettingCommand: Codable, Equatable, Sendable {
    public let settingID: RuntimeSettingID
    public let value: RuntimeSettingValue
    public let expectedRevision: UInt64?

    public init(
        settingID: RuntimeSettingID,
        value: RuntimeSettingValue,
        expectedRevision: UInt64? = nil
    ) {
        self.settingID = settingID
        self.value = value
        self.expectedRevision = expectedRevision
    }
}

public enum RuneScribeRuntimeSettings {
    public static let unlockFeedbackSoundEnabled = RuntimeSettingID(
        rawValue: "setting.unlock-feedback.sound-enabled"
    )!
    public static let unlockFeedbackHapticsEnabled = RuntimeSettingID(
        rawValue: "setting.unlock-feedback.haptics-enabled"
    )!
    public static let unlockFeedbackAnimationEnabled = RuntimeSettingID(
        rawValue: "setting.unlock-feedback.animation-enabled"
    )!
    public static let selectedCodex = RuntimeSettingID(
        rawValue: "setting.appearance.selected-codex"
    )!
    public static let selectedRelicByCodex = RuntimeSettingID(
        rawValue: "setting.appearance.selected-relic-by-codex"
    )!
    public static let selectedSealByCodex = RuntimeSettingID(
        rawValue: "setting.appearance.selected-seal-by-codex"
    )!
    public static let selectedFrameByCodex = RuntimeSettingID(
        rawValue: "setting.appearance.selected-frame-by-codex"
    )!
    public static let effectsPreference = RuntimeSettingID(
        rawValue: "setting.appearance.effects-preference"
    )!
    public static let contactsImportPrompted = RuntimeSettingID(
        rawValue: "setting.presentation.contacts-import-prompted"
    )!
    public static let splashLastShownEpochMilliseconds = RuntimeSettingID(
        rawValue: "setting.presentation.splash-last-shown-epoch-milliseconds"
    )!
    public static let tutorialCompletedVersion = RuntimeSettingID(
        rawValue: "setting.presentation.tutorial-completed-version"
    )!

    public static func defaultArtifactSelections(
        for kind: RuntimeArtifactSelectionKind
    ) -> RuntimeCodexArtifactSelectionMap {
        let artifactID: ArtifactID? = switch kind {
        case .relic:
            NorseArtifactCompatibilityAuthority.defaultArtifactID(for: .relic)
        case .seal:
            NorseArtifactCompatibilityAuthority.defaultArtifactID(for: .seal)
        case .frame:
            NorseArtifactCompatibilityAuthority.defaultArtifactID(for: .frame)
        }
        let selection = try! RuntimeCodexArtifactSelection(
            codexID: RuneScribeCodexIDs.norse,
            artifactID: artifactID,
            kind: kind
        )
        return try! RuntimeCodexArtifactSelectionMap(kind: kind, selections: [selection])
    }

    public static func defaultArtifactSelectionValue(
        for kind: RuntimeArtifactSelectionKind
    ) -> RuntimeSettingValue {
        .text(try! RuntimeArtifactSelectionCodec.encode(defaultArtifactSelections(for: kind)))
    }

    public static let defaultSelectedCodexPreference = try! RuntimeSelectedCodexPreference(
        codexID: RuneScribeCodexIDs.norse
    )

    public static let defaultSelectedCodexValue = RuntimeSettingValue.text(
        try! RuntimeSelectedCodexPreferenceCodec.encode(defaultSelectedCodexPreference)
    )

    public static let descriptors: [RuntimeSettingDescriptor] = [
        RuntimeSettingDescriptor(
            settingID: unlockFeedbackSoundEnabled,
            defaultValue: .boolean(true)
        ),
        RuntimeSettingDescriptor(
            settingID: unlockFeedbackHapticsEnabled,
            defaultValue: .boolean(true)
        ),
        RuntimeSettingDescriptor(
            settingID: unlockFeedbackAnimationEnabled,
            defaultValue: .boolean(true)
        ),
        RuntimeSettingDescriptor(
            settingID: selectedCodex,
            defaultValue: defaultSelectedCodexValue
        ),
        RuntimeSettingDescriptor(
            settingID: selectedRelicByCodex,
            defaultValue: defaultArtifactSelectionValue(for: .relic)
        ),
        RuntimeSettingDescriptor(
            settingID: selectedSealByCodex,
            defaultValue: defaultArtifactSelectionValue(for: .seal)
        ),
        RuntimeSettingDescriptor(
            settingID: selectedFrameByCodex,
            defaultValue: defaultArtifactSelectionValue(for: .frame)
        ),
        RuntimeSettingDescriptor(
            settingID: effectsPreference,
            defaultValue: RuntimeEffectsPreference.full.settingValue
        ),
        RuntimeSettingDescriptor(
            settingID: contactsImportPrompted,
            defaultValue: .boolean(false)
        ),
        RuntimeSettingDescriptor(
            settingID: splashLastShownEpochMilliseconds,
            defaultValue: .integer(0)
        ),
        RuntimeSettingDescriptor(
            settingID: tutorialCompletedVersion,
            defaultValue: .integer(0)
        ),
    ]
}

public extension RuntimeSettingsSnapshotDTO {
    var selectedCodexID: CodexID {
        guard let text = self[RuneScribeRuntimeSettings.selectedCodex]?.textValue,
              let decoded = try? RuntimeSelectedCodexPreferenceCodec.decodeForRead(text)
        else { return RuneScribeRuntimeSettings.defaultSelectedCodexPreference.codexID }
        return decoded.value.codexID
    }

    var contactsImportPrompted: Bool {
        self[RuneScribeRuntimeSettings.contactsImportPrompted]?.booleanValue ?? false
    }

    var splashLastShownAt: Date? {
        guard case .integer(let milliseconds)? =
            self[RuneScribeRuntimeSettings.splashLastShownEpochMilliseconds],
            milliseconds > 0
        else { return nil }
        let seconds = Double(milliseconds) / 1_000
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    var tutorialCompletedVersion: Int {
        guard let value = self[
            RuneScribeRuntimeSettings.tutorialCompletedVersion
        ]?.integerValue,
            value >= 0,
            value <= Int64(Int.max)
        else { return 0 }
        return Int(value)
    }

    func artifactSelections(
        for kind: RuntimeArtifactSelectionKind
    ) -> RuntimeCodexArtifactSelectionMap {
        guard let text = self[kind.settingID]?.textValue,
              let decoded = try? RuntimeArtifactSelectionCodec.decodeForRead(
                  text,
                  expectedKind: kind
              )
        else {
            return RuneScribeRuntimeSettings.defaultArtifactSelections(for: kind)
        }
        return decoded.value
    }

    var effectsPreference: RuntimeEffectsPreference {
        RuntimeEffectsPreference.storedValue(self[RuneScribeRuntimeSettings.effectsPreference])
    }
}

public enum RuntimePresentationSettingCodec {
    public static func splashLastShownValue(at date: Date) throws -> RuntimeSettingValue {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > 0,
              milliseconds <= Double(Int64.max),
              milliseconds.rounded() >= Double(Int64.min)
        else {
            throw RuntimeSettingsContractError.invalidSplashLastShownAt
        }
        return .integer(Int64(milliseconds.rounded()))
    }
}
