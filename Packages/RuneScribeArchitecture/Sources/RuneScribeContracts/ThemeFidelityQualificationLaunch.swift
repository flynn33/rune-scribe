import Foundation

@_spi(ThemeFidelityQualification)
public struct ThemeFidelityQualificationLaunch: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        case notRequested
        case invalid
        case validated(ThemeFidelityQualificationLaunch)
    }

    public enum Surface: String, CaseIterable, Equatable, Sendable {
        case composeLong = "compose-long"
        case composeShort = "compose-short"
        case highContrast = "high-contrast"
        case inscriptionPreview = "inscription-preview"
        case largeText = "large-text"
        case mastery
        case receivedCipher = "received-cipher"
        case reduceMotion = "reduce-motion"
        case relicPicker = "relic-picker"
        case sealPicker = "seal-picker"
        case settingsCodexCard = "settings-codex-card"
        case settingsDefaultsPreview = "settings-defaults-preview"
        case shareBuilder = "share-builder"
        case staticShare = "static-share"
        case vaultEncountered = "vault-encountered"
        case vaultLocked = "vault-locked"
        case vaultOwned = "vault-owned"
        case vaultProgress = "vault-progress"
        case vaultSelected = "vault-selected"
        case workspaceEmpty = "workspace-empty"
    }

    public enum Appearance: String, Equatable, Sendable {
        case accessibilityXXXL = "accessibility-xxxl"
        case highContrast = "high-contrast"
        case reduceMotion = "reduce-motion"
        case standard
    }

    public enum MessageProfile: String, Equatable, Sendable {
        case empty
        case longSixLines = "long-six-lines"
        case receivedSixLines = "received-six-lines"
        case shortTwoLines = "short-two-lines"
    }

    public enum VaultState: String, Equatable, Sendable {
        case encountered
        case locked
        case owned
        case progress
        case selected
    }

    public enum Destination: String, CaseIterable, Equatable, Sendable {
        case iPhonePortrait = "iphone-portrait"
        case iPadPortrait = "ipad-portrait"
        case macOSStandard = "macos-standard"
        case macOSResized = "macos-resized"
    }

    public let themeID: ThemeID
    public let codexID: CodexID
    public let defaultRelicID: ArtifactID
    public let defaultSealID: ArtifactID
    public let masteryTitleID: TitleID
    public let masteryTitlePresentation: ProgressionPresentationDTO
    public let surface: Surface
    public let appearance: Appearance
    public let messageProfile: MessageProfile
    public let vaultState: VaultState?
    public let destination: Destination

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hostAuthorizationOverride: Bool? = nil
    ) -> Resolution {
        guard let marker = environment[Keys.marker] else { return .notRequested }
        guard hostAuthorizationOverride ?? hostIsAuthorized else { return .notRequested }
        guard marker == "theme-fidelity-v4.2",
              environment[Keys.resetState] == "1",
              let surfaceRawValue = environment[Keys.surface],
              let surface = Surface(rawValue: surfaceRawValue),
              let appearanceRawValue = environment[Keys.appearance],
              let appearance = Appearance(rawValue: appearanceRawValue),
              let messageProfileRawValue = environment[Keys.messageProfile],
              let messageProfile = MessageProfile(rawValue: messageProfileRawValue),
              let destinationRawValue = environment[Keys.destination],
              let destination = Destination(rawValue: destinationRawValue),
              destination.isSupportedHostPlatform,
              let themeIDRawValue = environment[Keys.themeID],
              let providerRecord = ProviderRecord.record(themeID: themeIDRawValue),
              environment[Keys.codexID] == providerRecord.codexID,
              environment[Keys.defaultRelicID] == providerRecord.defaultRelicID,
              environment[Keys.defaultSealID] == providerRecord.defaultSealID,
              appearance == surface.expectedAppearance,
              messageProfile == surface.expectedMessageProfile,
              environment[Keys.vaultState] == surface.expectedVaultState?.rawValue,
              qualificationKeys(in: environment) == surface.expectedEnvironmentKeys,
              let themeID = ThemeID(rawValue: themeIDRawValue),
              let codexID = CodexID(rawValue: providerRecord.codexID),
              let defaultRelicID = ArtifactID(rawValue: providerRecord.defaultRelicID),
              let defaultSealID = ArtifactID(rawValue: providerRecord.defaultSealID),
              let masteryTitleID = TitleID(rawValue: providerRecord.masteryTitleID),
              let masteryTitlePresentation = ProviderRecord.titlePresentation(
                  titleID: providerRecord.masteryTitleID
              )
        else { return .invalid }

        return .validated(Self(
            themeID: themeID,
            codexID: codexID,
            defaultRelicID: defaultRelicID,
            defaultSealID: defaultSealID,
            masteryTitleID: masteryTitleID,
            masteryTitlePresentation: masteryTitlePresentation,
            surface: surface,
            appearance: appearance,
            messageProfile: messageProfile,
            vaultState: surface.expectedVaultState,
            destination: destination
        ))
    }
}

private extension ThemeFidelityQualificationLaunch {
    enum Keys {
        static let marker = "RUNESCRIBE_QUALIFICATION"
        static let resetState = "RUNESCRIBE_QUALIFICATION_RESET_STATE"
        static let themeID = "RUNESCRIBE_QUALIFICATION_THEME_ID"
        static let codexID = "RUNESCRIBE_QUALIFICATION_CODEX_ID"
        static let defaultRelicID = "RUNESCRIBE_QUALIFICATION_DEFAULT_RELIC_ID"
        static let defaultSealID = "RUNESCRIBE_QUALIFICATION_DEFAULT_SEAL_ID"
        static let surface = "RUNESCRIBE_QUALIFICATION_SURFACE"
        static let appearance = "RUNESCRIBE_QUALIFICATION_APPEARANCE"
        static let messageProfile = "RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE"
        static let vaultState = "RUNESCRIBE_QUALIFICATION_VAULT_STATE"
        static let destination = "RUNESCRIBE_QUALIFICATION_DESTINATION"

        static let required: Set<String> = [
            marker,
            resetState,
            themeID,
            codexID,
            defaultRelicID,
            defaultSealID,
            surface,
            appearance,
            messageProfile,
            destination,
        ]
    }

    struct ProviderRecord {
        let codexID: String
        let defaultRelicID: String
        let defaultSealID: String
        let masteryTitleID: String

        static func record(themeID: String) -> Self? {
            switch themeID {
            case "theme.gloamthorn.production":
                Self(
                    codexID: "codex.gloamthorn",
                    defaultRelicID: "relic.gloamthorn.nightthorn-tablet",
                    defaultSealID: "seal.gloamthorn.thornmoon",
                    masteryTitleID: "title.gloamthorn.mastery"
                )
            case "theme.moonleaf.production":
                Self(
                    codexID: "codex.moonleaf",
                    defaultRelicID: "relic.moonleaf.tablet",
                    defaultSealID: "seal.moonleaf.crescentleaf",
                    masteryTitleID: "title.moonleaf.mastery"
                )
            case "theme.norse.base":
                Self(
                    codexID: "codex.norse",
                    defaultRelicID: "relic.norse.runestone-tablet",
                    defaultSealID: "seal.norse.valknut",
                    masteryTitleID: "title.norse.master-of-runes"
                )
            case "theme.sunspire.production":
                Self(
                    codexID: "codex.sunspire",
                    defaultRelicID: "relic.sunspire.dawnfire-tablet",
                    defaultSealID: "seal.sunspire.sunleaf-crest",
                    masteryTitleID: "title.sunspire.mastery"
                )
            case "theme.wildwood.production":
                Self(
                    codexID: "codex.wildwood",
                    defaultRelicID: "relic.wildwood.rootsong-tablet",
                    defaultSealID: "seal.wildwood.rooted-tree",
                    masteryTitleID: "title.wildwood.mastery"
                )
            default:
                nil
            }
        }

        static func titlePresentation(
            titleID: String
        ) -> ProgressionPresentationDTO? {
            switch titleID {
            case "title.gloamthorn.mastery":
                try? ProgressionPresentationDTO(
                    displayName: "Sovereign of the Gloam",
                    summary: "Gloamthorn mastery distinction.",
                    fallbackSystemImageName: "person.text.rectangle"
                )
            case "title.moonleaf.mastery":
                try? ProgressionPresentationDTO(
                    displayName: "Moonleaf Master",
                    summary: "Moonleaf mastery distinction.",
                    fallbackSystemImageName: "person.text.rectangle"
                )
            case "title.sunspire.mastery":
                try? ProgressionPresentationDTO(
                    displayName: "Bearer of First Light",
                    summary: "Sunspire mastery distinction.",
                    fallbackSystemImageName: "person.text.rectangle"
                )
            case "title.wildwood.mastery":
                try? ProgressionPresentationDTO(
                    displayName: "Keeper of the Heartwood",
                    summary: "Wildwood mastery distinction.",
                    fallbackSystemImageName: "person.text.rectangle"
                )
            case "title.norse.master-of-runes":
                try? ProgressionPresentationDTO(
                    displayName: "Master of Runes",
                    summary: nil,
                    fallbackSystemImageName: "person.text.rectangle"
                )
            default:
                nil
            }
        }
    }

    static func qualificationKeys(in environment: [String: String]) -> Set<String> {
        Set(environment.keys.filter {
            $0 == Keys.marker || $0.hasPrefix("RUNESCRIBE_QUALIFICATION_")
        })
    }

    static var hostIsAuthorized: Bool {
        #if os(iOS) && targetEnvironment(simulator)
        true
        #elseif os(macOS)
        Bundle.main.bundleIdentifier == "com.runescribe.app.macos-parity-host"
        #else
        false
        #endif
    }
}

private extension ThemeFidelityQualificationLaunch.Destination {
    var isSupportedHostPlatform: Bool {
        #if os(iOS) && targetEnvironment(simulator)
        self == .iPhonePortrait || self == .iPadPortrait
        #elseif os(macOS)
        self == .macOSStandard || self == .macOSResized
        #else
        false
        #endif
    }
}

private extension ThemeFidelityQualificationLaunch.Surface {
    var expectedAppearance: ThemeFidelityQualificationLaunch.Appearance {
        switch self {
        case .highContrast: .highContrast
        case .largeText: .accessibilityXXXL
        case .reduceMotion: .reduceMotion
        default: .standard
        }
    }

    var expectedMessageProfile: ThemeFidelityQualificationLaunch.MessageProfile {
        switch self {
        case .composeLong:
            .longSixLines
        case .composeShort, .highContrast, .inscriptionPreview, .largeText,
             .reduceMotion, .settingsDefaultsPreview:
            .shortTwoLines
        case .receivedCipher, .shareBuilder, .staticShare:
            .receivedSixLines
        default:
            .empty
        }
    }

    var expectedVaultState: ThemeFidelityQualificationLaunch.VaultState? {
        switch self {
        case .vaultEncountered: .encountered
        case .vaultLocked: .locked
        case .vaultOwned: .owned
        case .vaultProgress: .progress
        case .vaultSelected: .selected
        default: nil
        }
    }

    var expectedEnvironmentKeys: Set<String> {
        var keys = ThemeFidelityQualificationLaunch.Keys.required
        if expectedVaultState != nil {
            keys.insert(ThemeFidelityQualificationLaunch.Keys.vaultState)
        }
        return keys
    }
}
