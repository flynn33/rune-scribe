import Foundation

public enum ThemeProviderState: String, Codable, CaseIterable, Hashable, Sendable {
    case available
    case locked
    case unavailable
    case incompatible
    case invalidResources = "invalid-resources"
}

public enum ThemeSelectionFallbackReason: String, Codable, Hashable, Sendable {
    case none
    case missingPreference = "missing-preference"
    case invalidPreference = "invalid-preference"
    case unknownCodex = "unknown-codex"
    case locked
    case unavailable
    case incompatible
    case invalidResources = "invalid-resources"
}

public struct ThemeProviderSummaryDTO: Codable, Equatable, Hashable, Sendable {
    public let codexID: CodexID
    public let moduleID: ModuleIdentifier
    public let displayName: String
    public let state: ThemeProviderState
    public let isOwned: Bool
    public let isSelectable: Bool
    public let isSelected: Bool

    public init(
        codexID: CodexID,
        moduleID: ModuleIdentifier,
        displayName: String,
        state: ThemeProviderState,
        isOwned: Bool,
        isSelectable: Bool,
        isSelected: Bool
    ) {
        self.codexID = codexID
        self.moduleID = moduleID
        self.displayName = displayName
        self.state = state
        self.isOwned = isOwned
        self.isSelectable = isSelectable
        self.isSelected = isSelected
    }
}

public enum ThemeCoordinatorContractError: Error, Equatable, Sendable {
    case invalidCapturedAt
    case duplicateCodexID
    case invalidEffectiveTheme
    case invalidSelectionState
    case invalidProviderState
    case missingBaseProvider
    case invalidFallbackState
    case resourceIntegrityMismatch
    case tooManyProviders(maximum: Int)
    case tooManyDiagnostics(maximum: Int)
}

public struct ThemeCoordinatorSnapshotDTO: Codable, Equatable, Sendable {
    public static let maximumProviderCount = 64

    public let revision: UInt64
    public let capturedAt: Date
    public let preferredCodexID: CodexID?
    public let effectiveCodexID: CodexID
    public let fallbackReason: ThemeSelectionFallbackReason
    public let effectiveTheme: ThemeDescriptor
    public let providers: [ThemeProviderSummaryDTO]

    public init(
        revision: UInt64,
        capturedAt: Date,
        preferredCodexID: CodexID?,
        effectiveCodexID: CodexID,
        fallbackReason: ThemeSelectionFallbackReason,
        effectiveTheme: ThemeDescriptor,
        providers: [ThemeProviderSummaryDTO]
    ) throws {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ThemeCoordinatorContractError.invalidCapturedAt
        }
        guard providers.count <= Self.maximumProviderCount else {
            throw ThemeCoordinatorContractError.tooManyProviders(
                maximum: Self.maximumProviderCount
            )
        }
        guard Set(providers.map(\.codexID)).count == providers.count else {
            throw ThemeCoordinatorContractError.duplicateCodexID
        }
        guard Set(providers.map(\.moduleID)).count == providers.count else {
            throw ThemeCoordinatorContractError.invalidProviderState
        }
        guard effectiveTheme.codex.id == effectiveCodexID else {
            throw ThemeCoordinatorContractError.invalidEffectiveTheme
        }
        guard providers.allSatisfy({ provider in
            !provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (!provider.isSelectable
                    || (provider.isOwned && provider.state == .available))
                && (!provider.isSelected
                    || (provider.isOwned
                        && provider.isSelectable
                        && provider.state == .available))
        }) else {
            throw ThemeCoordinatorContractError.invalidProviderState
        }
        let selected = providers.filter(\.isSelected)
        guard selected.count == 1,
              selected[0].codexID == effectiveCodexID,
              selected[0].isSelectable,
              selected[0].moduleID.rawValue == effectiveTheme.moduleID.rawValue
        else {
            throw ThemeCoordinatorContractError.invalidSelectionState
        }
        guard let base = providers.first(where: {
            $0.codexID == RuneScribeCodexIDs.norse
        }),
            base.moduleID == RuneScribeModuleIDs.norseTheme,
            base.state == .available,
            base.isOwned,
            base.isSelectable
        else {
            throw ThemeCoordinatorContractError.missingBaseProvider
        }
        switch fallbackReason {
        case .none:
            guard preferredCodexID == effectiveCodexID else {
                throw ThemeCoordinatorContractError.invalidFallbackState
            }
        case .missingPreference, .invalidPreference:
            guard preferredCodexID == nil,
                  effectiveCodexID == RuneScribeCodexIDs.norse
            else {
                throw ThemeCoordinatorContractError.invalidFallbackState
            }
        case .unknownCodex, .locked, .unavailable, .incompatible, .invalidResources:
            guard let preferredCodexID,
                  preferredCodexID != effectiveCodexID,
                  effectiveCodexID == RuneScribeCodexIDs.norse
            else {
                throw ThemeCoordinatorContractError.invalidFallbackState
            }
        }

        self.revision = revision
        self.capturedAt = capturedAt
        self.preferredCodexID = preferredCodexID
        self.effectiveCodexID = effectiveCodexID
        self.fallbackReason = fallbackReason
        self.effectiveTheme = effectiveTheme
        self.providers = providers.sorted { $0.codexID < $1.codexID }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            revision: container.decode(UInt64.self, forKey: .revision),
            capturedAt: container.decode(Date.self, forKey: .capturedAt),
            preferredCodexID: container.decodeIfPresent(
                CodexID.self,
                forKey: .preferredCodexID
            ),
            effectiveCodexID: container.decode(CodexID.self, forKey: .effectiveCodexID),
            fallbackReason: container.decode(
                ThemeSelectionFallbackReason.self,
                forKey: .fallbackReason
            ),
            effectiveTheme: container.decode(ThemeDescriptor.self, forKey: .effectiveTheme),
            providers: container.decode([ThemeProviderSummaryDTO].self, forKey: .providers)
        )
    }
}

public struct SelectThemeCodexCommand: Codable, Equatable, Sendable {
    public let codexID: CodexID
    public let expectedSnapshotRevision: UInt64?

    public init(
        codexID: CodexID,
        expectedSnapshotRevision: UInt64? = nil
    ) {
        self.codexID = codexID
        self.expectedSnapshotRevision = expectedSnapshotRevision
    }
}

public struct ResolveThemeResourceRequestDTO: Codable, Equatable, Hashable, Sendable {
    public let codexID: CodexID
    public let resourceID: ThemeResourceID

    public init(codexID: CodexID, resourceID: ThemeResourceID) {
        self.codexID = codexID
        self.resourceID = resourceID
    }
}

public struct ResolvedThemeResourceDTO: Equatable, Sendable {
    public let codexID: CodexID
    public let resourceID: ThemeResourceID
    public let role: ThemeResourceRoleID
    public let mediaType: ThemeResourceMediaType
    public let integrity: ThemeResourceIntegrity
    public let data: Data

    public init(
        codexID: CodexID,
        resourceID: ThemeResourceID,
        role: ThemeResourceRoleID,
        mediaType: ThemeResourceMediaType,
        integrity: ThemeResourceIntegrity,
        verifiedSHA256: ThemeSHA256Digest,
        data: Data
    ) throws {
        guard integrity.byteLength == UInt64(data.count),
              verifiedSHA256 == integrity.sha256
        else {
            throw ThemeCoordinatorContractError.resourceIntegrityMismatch
        }
        self.codexID = codexID
        self.resourceID = resourceID
        self.role = role
        self.mediaType = mediaType
        self.integrity = integrity
        self.data = data
    }
}

public enum ThemeProviderDiagnosticCode: String, Codable, Hashable, Sendable {
    case accepted
    case descriptorTooLarge = "descriptor-too-large"
    case identityMismatch = "identity-mismatch"
    case duplicateCodex = "duplicate-codex"
    case stableIDCollision = "stable-id-collision"
    case incompatible
    case lifecycleUnavailable = "lifecycle-unavailable"
    case missingContribution = "missing-contribution"
    case descriptorMismatch = "descriptor-mismatch"
    case missingResource = "missing-resource"
    case resourceMismatch = "resource-mismatch"
    case unexpectedResource = "unexpected-resource"
}

public struct ThemeProviderDiagnosticDTO: Codable, Equatable, Hashable, Sendable {
    public let moduleID: ModuleIdentifier
    public let codexID: CodexID?
    public let code: ThemeProviderDiagnosticCode

    public init(
        moduleID: ModuleIdentifier,
        codexID: CodexID?,
        code: ThemeProviderDiagnosticCode
    ) {
        self.moduleID = moduleID
        self.codexID = codexID
        self.code = code
    }
}

public struct ThemeCoordinatorDiagnosticsDTO: Codable, Equatable, Sendable {
    public static let maximumDiagnosticCount = 128

    public let capturedAt: Date
    public let contributionRevision: UInt64
    public let resourceRevision: UInt64
    public let preferredCodexID: CodexID?
    public let effectiveCodexID: CodexID
    public let fallbackReason: ThemeSelectionFallbackReason
    public let providers: [ThemeProviderDiagnosticDTO]

    public init(
        capturedAt: Date,
        contributionRevision: UInt64,
        resourceRevision: UInt64,
        preferredCodexID: CodexID?,
        effectiveCodexID: CodexID,
        fallbackReason: ThemeSelectionFallbackReason,
        providers: [ThemeProviderDiagnosticDTO]
    ) throws {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ThemeCoordinatorContractError.invalidCapturedAt
        }
        guard providers.count <= Self.maximumDiagnosticCount else {
            throw ThemeCoordinatorContractError.tooManyDiagnostics(
                maximum: Self.maximumDiagnosticCount
            )
        }
        self.capturedAt = capturedAt
        self.contributionRevision = contributionRevision
        self.resourceRevision = resourceRevision
        self.preferredCodexID = preferredCodexID
        self.effectiveCodexID = effectiveCodexID
        self.fallbackReason = fallbackReason
        self.providers = providers.sorted { lhs, rhs in
            if lhs.moduleID != rhs.moduleID { return lhs.moduleID < rhs.moduleID }
            return (lhs.codexID?.rawValue ?? "") < (rhs.codexID?.rawValue ?? "")
        }
    }
}

public enum RuneScribeThemeEventIDs {
    public static let providerAvailable: EventIdentifier =
        "runescribe.theme.providerAvailable"
    public static let providerUnavailable: EventIdentifier =
        "runescribe.theme.providerUnavailable"
    public static let catalogChanged: EventIdentifier =
        "runescribe.theme.catalogChanged"
    public static let selectionChanged: EventIdentifier =
        "runescribe.theme.selectionChanged"
    public static let validationFailed: EventIdentifier =
        "runescribe.theme.validationFailed"
}

public struct ThemeRuntimeEventPayloadDTO: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let snapshotRevision: UInt64
    public let codexID: CodexID?
    public let diagnosticCode: ThemeProviderDiagnosticCode?

    public init(
        schemaVersion: UInt16 = 1,
        snapshotRevision: UInt64,
        codexID: CodexID?,
        diagnosticCode: ThemeProviderDiagnosticCode? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.snapshotRevision = snapshotRevision
        self.codexID = codexID
        self.diagnosticCode = diagnosticCode
    }
}
