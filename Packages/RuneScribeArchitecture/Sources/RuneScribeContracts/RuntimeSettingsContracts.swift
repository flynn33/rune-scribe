import Foundation

public enum RuntimeSettingsContractError: Error, Equatable, Sendable {
    case tooManySettings(maximum: Int)
    case duplicateSettingID
    case invalidCapturedAt
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
}

public struct RuntimeSettingText: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public static let maximumUTF8Count = 256

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
            defaultValue: .text(
                RuntimeSettingText(rawValue: RuneScribeCodexIDs.norse.rawValue)!
            )
        ),
        RuntimeSettingDescriptor(
            settingID: selectedRelicByCodex,
            defaultValue: .text(
                RuntimeSettingText(
                    rawValue: "codex.norse=relic.norse.runestone.weathered"
                )!
            )
        ),
        RuntimeSettingDescriptor(
            settingID: selectedSealByCodex,
            defaultValue: .text(
                RuntimeSettingText(rawValue: "codex.norse=seal.norse.knotwork")!
            )
        ),
    ]
}
