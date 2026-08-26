import RuneScribeContracts
import SwiftUI

enum ThemeCaptureIdentifier {
    enum PickerKind: String, Equatable, Hashable, Sendable {
        case relic
        case seal
    }

    enum BackgroundVariant: String, Equatable, Hashable, Sendable {
        case standard
        case highContrast = "high-contrast"
        case reduceMotion = "reduce-motion"
    }

    enum PresentationVariant: String, Equatable, Hashable, Sendable {
        case standard
        case emergency
        case highContrast = "high-contrast"
        case reduceMotion = "reduce-motion"
        case largeText = "large-text"
    }

    enum ComposeLength: String, Equatable, Hashable, Sendable {
        case short
        case long
    }

    static let screenReceivedCipher = "screen.received-cipher"
    static let screenSettingsAppearance = "screen.settings.appearance"
    static let screenShareBuilder = "screen.share-builder"
    static let screenVaultProgress = "screen.vault-progress"
    static let screenWorkspace = "screen.workspace"
    static let workspacePrimarySurface = "workspace.primary-surface"

    static func artifactPickerScreen(kind: PickerKind, codexID: CodexID) -> String {
        "screen.artifact-picker.\(kind.rawValue).\(codexID.rawValue)"
    }

    static func artifactPicker(kind: PickerKind, codexID: CodexID) -> String {
        "theme.artifact-picker.\(kind.rawValue).\(codexID.rawValue)"
    }

    static func artifactPreview(relicID: ArtifactID) -> String {
        "theme.artifact-preview.\(relicID.rawValue)"
    }

    static func background(themeID: ThemeID, variant: BackgroundVariant) -> String {
        "theme.background.\(themeID.rawValue).\(variant.rawValue)"
    }

    static func compose(length: ComposeLength, codexID: CodexID) -> String {
        "theme.compose.\(length.rawValue).\(codexID.rawValue)"
    }

    static func mastery(codexID: CodexID) -> String {
        "theme.mastery.\(codexID.rawValue)"
    }

    static func masteryScreen(codexID: CodexID) -> String {
        "screen.mastery.\(codexID.rawValue)"
    }

    static func masteryFrame(artifactID: ArtifactID) -> String {
        "theme.mastery.frame.\(artifactID.rawValue)"
    }

    static func masteryCrest(crestID: CrestID) -> String {
        "theme.mastery.crest.\(crestID.rawValue)"
    }

    static func masteryTitle(titleID: TitleID) -> String {
        "theme.mastery.title.\(titleID.rawValue)"
    }

    static func journeyProgress(codexID: CodexID) -> String {
        "progression.journey.\(codexID.rawValue).progress"
    }

    static func journeyRequirementCount(codexID: CodexID) -> String {
        "progression.journey.\(codexID.rawValue).requirement-count"
    }

    static func presentation(themeID: ThemeID, variant: PresentationVariant) -> String {
        "theme.presentation.\(themeID.rawValue).\(variant.rawValue)"
    }

    static func receivedArtifactPreview(relicID: ArtifactID) -> String {
        "theme.received.artifact-preview.\(relicID.rawValue)"
    }

    static func settingsDefaultsPreview(codexID: CodexID) -> String {
        "appearance.defaults-preview.\(codexID.rawValue)"
    }

    static func shareBuilderPreview(codexID: CodexID) -> String {
        "share-builder.preview.\(codexID.rawValue)"
    }

    static func vault(codexID: CodexID, state: ThemeVisualContentState) -> String? {
        switch state {
        case .encountered, .locked, .owned, .progress, .selected:
            "theme.vault.\(codexID.rawValue).\(state.rawValue.lowercased())"
        case .unavailable:
            nil
        }
    }

    static func vaultProviderState(codexID: CodexID) -> String {
        "theme.vault.\(codexID.rawValue).provider-state"
    }

    static func vaultOwnershipState(codexID: CodexID) -> String {
        "theme.vault.\(codexID.rawValue).ownership-state"
    }

    static func staticShareRendererOutput(
        codexID: CodexID,
        relicID: ArtifactID,
        sealID: ArtifactID?,
        colorMode: ShareArtifactColorMode
    ) -> String {
        let sealComponent = sealID?.rawValue ?? "seal.none"
        return "renderer.static-share.\(codexID.rawValue).\(relicID.rawValue)."
            + "\(sealComponent).\(colorMode.rawValue)"
    }
}

private struct ThemeCaptureIdentifierWrapper<Content: View>: View {
    let content: Content
    let identifier: String?
    @Environment(\.themeCaptureIdentifiersEnabled) private var isEnabled

    @ViewBuilder
    var body: some View {
        if isEnabled, let identifier {
            ZStack { content }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
                .runtimeViewportFrameProbe(identifier)
        } else {
            content
        }
    }
}

private struct ThemeCaptureIdentifiersEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var themeCaptureIdentifiersEnabled: Bool {
        get { self[ThemeCaptureIdentifiersEnabledKey.self] }
        set { self[ThemeCaptureIdentifiersEnabledKey.self] = newValue }
    }
}

private struct ThemeCaptureAccessibilityHiddenWhenDisabled<Content: View>: View {
    let content: Content
    @Environment(\.themeCaptureIdentifiersEnabled) private var isEnabled

    @ViewBuilder
    var body: some View {
        if isEnabled {
            content
        } else {
            content.accessibilityHidden(true)
        }
    }
}

extension View {
    func themeCaptureIdentifier(_ identifier: String?) -> some View {
        ThemeCaptureIdentifierWrapper(content: self, identifier: identifier)
    }

    func themeCaptureAccessibilityHiddenWhenDisabled() -> some View {
        ThemeCaptureAccessibilityHiddenWhenDisabled(content: self)
    }
}
