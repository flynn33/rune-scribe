import Foundation

/// The semantic effect requested for one durable unlock reveal. The platform
/// adapter resolves this semantic ID to a provider resource or the bundled
/// fallback without exposing file paths to UI code.
public enum UnlockFeedbackSoundSemanticID: String, Codable, CaseIterable, Sendable {
    case micro = "effect.unlock.micro"
    case artifact = "effect.unlock.artifact"
    case codex = "effect.unlock.codex"
    case mastery = "effect.unlock.mastery"
}

/// Stable identifiers for the generic fallback resources. These IDs are not
/// Theme content and remain usable when no optional provider is active.
public enum UnlockFeedbackFallbackResourceID: String, Codable, CaseIterable, Sendable {
    case micro = "audio.unlock.micro.default"
    case artifact = "audio.unlock.artifact.default"
    case codex = "audio.unlock.codex.default"
    case mastery = "audio.unlock.mastery.default"
}

public struct UnlockFeedbackRequestDTO: Codable, Equatable, Sendable {
    public let tier: ProgressionRevealTier
    public let codexID: CodexID
    public let soundEnabled: Bool
    public let hapticEnabled: Bool

    public init(
        tier: ProgressionRevealTier,
        codexID: CodexID = RuneScribeCodexIDs.norse,
        soundEnabled: Bool,
        hapticEnabled: Bool
    ) {
        self.tier = tier
        self.codexID = codexID
        self.soundEnabled = soundEnabled
        self.hapticEnabled = hapticEnabled
    }

    public var soundSemanticID: UnlockFeedbackSoundSemanticID {
        switch tier {
        case .micro: .micro
        case .artifact: .artifact
        case .codex: .codex
        case .mastery: .mastery
        }
    }

    public var fallbackResourceID: UnlockFeedbackFallbackResourceID {
        switch tier {
        case .micro: .micro
        case .artifact: .artifact
        case .codex: .codex
        case .mastery: .mastery
        }
    }
}

/// Apple Platform is the only shipping implementation. UI sends this narrow
/// semantic request through RuntimeCore and never imports playback frameworks.
public protocol UnlockFeedbackProviding: Sendable {
    func perform(_ request: UnlockFeedbackRequestDTO) async
}

/// Optional platform refinement used when Forsetti has resolved and verified
/// a selected Theme's opaque sound cue. Implementations must retain their
/// generic fallback when the provider bytes are absent or unusable.
public protocol ThemeUnlockFeedbackProviding: UnlockFeedbackProviding {
    func perform(
        _ request: UnlockFeedbackRequestDTO,
        providerSoundData: Data?
    ) async
}

public enum RuneScribeUnlockFeedback {
    public static var serviceID: ServiceIdentifier {
        "UnlockFeedbackService"
    }

    public static var serviceKey: ServiceKey<any UnlockFeedbackProviding> {
        ServiceKey(serviceID)
    }
}
