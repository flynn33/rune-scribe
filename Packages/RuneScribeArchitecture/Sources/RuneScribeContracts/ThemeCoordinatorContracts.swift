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

public enum RequiredThemeResourceFailureStage: String, Codable, CaseIterable,
    Hashable, Sendable
{
    case manifestRead = "manifest-read"
    case manifestIntegrity = "manifest-integrity"
    case resourceRead = "resource-read"
    case byteCount = "byte-count"
    case digest
    case mediaMetadata = "media-metadata"
    case semanticJSON = "semantic-json"
    case geometry
    case budget
    case contributionPublication = "contribution-publication"
}

public enum RequiredThemeResourceFailureCode: String, Codable, CaseIterable,
    Hashable, Sendable
{
    case resourceUnavailable = "resource-unavailable"
    case contentTooLarge = "content-too-large"
    case byteCountMismatch = "byte-count-mismatch"
    case digestMismatch = "digest-mismatch"
    case invalidIntegrityManifest = "invalid-integrity-manifest"
    case mediaMetadataMismatch = "media-metadata-mismatch"
    case invalidSemanticJSON = "invalid-semantic-json"
    case invalidGeometry = "invalid-geometry"
    case resourceBudgetExceeded = "resource-budget-exceeded"
    case resourceSetMismatch = "resource-set-mismatch"
    case contributionRejected = "contribution-rejected"
    case unexpectedFailure = "unexpected-failure"
}

/// Bounded, privacy-safe details for a required Theme provider failure. Every
/// string is represented by an existing validated identifier or fixed enum; the
/// value cannot carry paths, package bytes, plaintext, contacts, or arbitrary
/// error descriptions.
public struct RequiredThemeResourceFailureDTO: Error, Codable, Equatable, Hashable,
    Sendable
{
    public let moduleID: ModuleIdentifier
    public let codexID: CodexID
    public let stage: RequiredThemeResourceFailureStage
    public let resourceID: ThemeResourceID?
    public let errorCode: RequiredThemeResourceFailureCode
    public let expectedByteCount: UInt64?
    public let actualByteCount: UInt64?
    public let expectedSHA256: ThemeSHA256Digest?
    public let actualSHA256: ThemeSHA256Digest?
    public let mediaType: ThemeResourceMediaType?

    public init(
        moduleID: ModuleIdentifier,
        codexID: CodexID,
        stage: RequiredThemeResourceFailureStage,
        resourceID: ThemeResourceID? = nil,
        errorCode: RequiredThemeResourceFailureCode,
        expectedByteCount: UInt64? = nil,
        actualByteCount: UInt64? = nil,
        expectedSHA256: ThemeSHA256Digest? = nil,
        actualSHA256: ThemeSHA256Digest? = nil,
        mediaType: ThemeResourceMediaType? = nil
    ) {
        self.moduleID = moduleID
        self.codexID = codexID
        self.stage = stage
        self.resourceID = resourceID
        self.errorCode = errorCode
        self.expectedByteCount = expectedByteCount
        self.actualByteCount = actualByteCount
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.mediaType = mediaType
    }
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
    case invalidPresentationInventory
    case missingBaseProvider
    case invalidFallbackState
    case resourceIntegrityMismatch
    case invalidRequiredBaseResourceFailure
    case tooManyProviders(maximum: Int)
    case tooManyDiagnostics(maximum: Int)
    case tooManyRequiredBaseResourceFailures(maximum: Int)
}

public struct ThemeCoordinatorSnapshotDTO: Codable, Equatable, Sendable {
    public static let maximumProviderCount = 64
    public static let maximumRequiredBaseResourceFailureCount = 8

    public let revision: UInt64
    public let capturedAt: Date
    public let preferredCodexID: CodexID?
    public let effectiveCodexID: CodexID
    public let fallbackReason: ThemeSelectionFallbackReason
    public let isEmergencyPresentation: Bool
    public let effectiveTheme: ThemeDescriptor
    public let providers: [ThemeProviderSummaryDTO]
    public let presentationInventories: [SharePresentationProviderInventory]
    public let requiredBaseResourceFailures: [RequiredThemeResourceFailureDTO]

    public init(
        revision: UInt64,
        capturedAt: Date,
        preferredCodexID: CodexID?,
        effectiveCodexID: CodexID,
        fallbackReason: ThemeSelectionFallbackReason,
        effectiveTheme: ThemeDescriptor,
        providers: [ThemeProviderSummaryDTO],
        presentationInventories: [SharePresentationProviderInventory] = [],
        isEmergencyPresentation: Bool = false,
        requiredBaseResourceFailures: [RequiredThemeResourceFailureDTO] = []
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
        let effectiveInventory = try SharePresentationProviderInventory(
            descriptor: effectiveTheme
        )
        let normalizedInventories = presentationInventories.isEmpty
            ? [effectiveInventory]
            : presentationInventories
        guard normalizedInventories.count <= Self.maximumProviderCount,
              Set(normalizedInventories.map(\.codexID)).count
                == normalizedInventories.count,
              normalizedInventories.allSatisfy({ inventory in
                  providers.contains { $0.codexID == inventory.codexID }
              }),
              normalizedInventories.first(where: {
                  $0.codexID == effectiveCodexID
              }) == effectiveInventory
        else {
            throw ThemeCoordinatorContractError.invalidPresentationInventory
        }
        guard providers.allSatisfy({ provider in
            !provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (!provider.isSelectable
                    || (provider.isOwned && provider.state == .available))
                && (!provider.isSelected
                    || (provider.isOwned
                        && ((provider.isSelectable && provider.state == .available)
                            || (isEmergencyPresentation
                                && provider.codexID == RuneScribeCodexIDs.norse
                                && provider.state == .invalidResources
                                && !provider.isSelectable))))
        }) else {
            throw ThemeCoordinatorContractError.invalidProviderState
        }
        let selected = providers.filter(\.isSelected)
        guard selected.count == 1,
              selected[0].codexID == effectiveCodexID,
              (selected[0].isSelectable || isEmergencyPresentation),
              selected[0].moduleID.rawValue == effectiveTheme.moduleID.rawValue
        else {
            throw ThemeCoordinatorContractError.invalidSelectionState
        }
        guard let base = providers.first(where: {
            $0.codexID == RuneScribeCodexIDs.norse
        }),
            base.moduleID == RuneScribeModuleIDs.norseTheme,
            base.isOwned,
            isEmergencyPresentation
                ? (base.state == .invalidResources && !base.isSelectable)
                : (base.state == .available && base.isSelectable)
        else {
            throw ThemeCoordinatorContractError.missingBaseProvider
        }
        if isEmergencyPresentation {
            guard effectiveCodexID == RuneScribeCodexIDs.norse,
                  fallbackReason == .invalidResources
            else {
                throw ThemeCoordinatorContractError.invalidFallbackState
            }
        } else {
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
            case .unknownCodex, .locked, .unavailable, .incompatible,
                 .invalidResources:
                guard let preferredCodexID,
                      preferredCodexID != effectiveCodexID,
                      effectiveCodexID == RuneScribeCodexIDs.norse
                else {
                    throw ThemeCoordinatorContractError.invalidFallbackState
                }
            }
        }

        let normalizedFailures = Self.normalizedRequiredBaseFailures(
            requiredBaseResourceFailures
        )
        guard normalizedFailures.count <= Self.maximumRequiredBaseResourceFailureCount else {
            throw ThemeCoordinatorContractError.tooManyRequiredBaseResourceFailures(
                maximum: Self.maximumRequiredBaseResourceFailureCount
            )
        }
        guard normalizedFailures.allSatisfy({ failure in
            failure.moduleID == RuneScribeModuleIDs.norseTheme
                && failure.codexID == RuneScribeCodexIDs.norse
        }), normalizedFailures.isEmpty || isEmergencyPresentation
        else {
            throw ThemeCoordinatorContractError.invalidRequiredBaseResourceFailure
        }

        self.revision = revision
        self.capturedAt = capturedAt
        self.preferredCodexID = preferredCodexID
        self.effectiveCodexID = effectiveCodexID
        self.fallbackReason = fallbackReason
        self.isEmergencyPresentation = isEmergencyPresentation
        self.effectiveTheme = effectiveTheme
        self.providers = providers.sorted { $0.codexID < $1.codexID }
        self.presentationInventories = normalizedInventories.sorted {
            $0.codexID < $1.codexID
        }
        self.requiredBaseResourceFailures = normalizedFailures
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
            providers: container.decode([ThemeProviderSummaryDTO].self, forKey: .providers),
            presentationInventories: try container.decodeIfPresent(
                [SharePresentationProviderInventory].self,
                forKey: .presentationInventories
            ) ?? [],
            isEmergencyPresentation: try container.decodeIfPresent(
                Bool.self,
                forKey: .isEmergencyPresentation
            ) ?? false,
            requiredBaseResourceFailures: try container.decodeIfPresent(
                [RequiredThemeResourceFailureDTO].self,
                forKey: .requiredBaseResourceFailures
            ) ?? []
        )
    }

    private static func normalizedRequiredBaseFailures(
        _ failures: [RequiredThemeResourceFailureDTO]
    ) -> [RequiredThemeResourceFailureDTO] {
        Array(Set(failures)).sorted(by: requiredThemeResourceFailureOrdering)
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

/// Requests one provider descriptor for an operation-local presentation draft.
/// Reading this value never changes the persisted selected Codex.
public struct ThemeProviderDescriptorRequestDTO: Codable, Equatable, Sendable {
    public let codexID: CodexID

    public init(codexID: CodexID) {
        self.codexID = codexID
    }
}

public enum ThemeResourceResolutionPurpose: String, Codable, Hashable, Sendable {
    case activePresentation = "active-presentation"
    case catalogPreview = "catalog-preview"
}

public struct ResolveThemeResourceRequestDTO: Codable, Equatable, Hashable, Sendable {
    public let codexID: CodexID
    public let resourceID: ThemeResourceID
    public let purpose: ThemeResourceResolutionPurpose

    public init(
        codexID: CodexID,
        resourceID: ThemeResourceID,
        purpose: ThemeResourceResolutionPurpose = .activePresentation
    ) {
        self.codexID = codexID
        self.resourceID = resourceID
        self.purpose = purpose
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            codexID: try container.decode(CodexID.self, forKey: .codexID),
            resourceID: try container.decode(
                ThemeResourceID.self,
                forKey: .resourceID
            ),
            purpose: try container.decodeIfPresent(
                ThemeResourceResolutionPurpose.self,
                forKey: .purpose
            ) ?? .activePresentation
        )
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
    public static let maximumRequiredBaseResourceFailureCount = 8

    public let capturedAt: Date
    public let contributionRevision: UInt64
    public let resourceRevision: UInt64
    public let preferredCodexID: CodexID?
    public let effectiveCodexID: CodexID
    public let fallbackReason: ThemeSelectionFallbackReason
    public let providers: [ThemeProviderDiagnosticDTO]
    public let requiredBaseResourceFailures: [RequiredThemeResourceFailureDTO]

    public init(
        capturedAt: Date,
        contributionRevision: UInt64,
        resourceRevision: UInt64,
        preferredCodexID: CodexID?,
        effectiveCodexID: CodexID,
        fallbackReason: ThemeSelectionFallbackReason,
        providers: [ThemeProviderDiagnosticDTO],
        requiredBaseResourceFailures: [RequiredThemeResourceFailureDTO] = []
    ) throws {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ThemeCoordinatorContractError.invalidCapturedAt
        }
        guard providers.count <= Self.maximumDiagnosticCount else {
            throw ThemeCoordinatorContractError.tooManyDiagnostics(
                maximum: Self.maximumDiagnosticCount
            )
        }
        let normalizedFailures = Array(Set(requiredBaseResourceFailures)).sorted(
            by: requiredThemeResourceFailureOrdering
        )
        guard normalizedFailures.count <= Self.maximumRequiredBaseResourceFailureCount else {
            throw ThemeCoordinatorContractError.tooManyRequiredBaseResourceFailures(
                maximum: Self.maximumRequiredBaseResourceFailureCount
            )
        }
        guard normalizedFailures.allSatisfy({ failure in
            failure.moduleID == RuneScribeModuleIDs.norseTheme
                && failure.codexID == RuneScribeCodexIDs.norse
        }), normalizedFailures.isEmpty || fallbackReason == .invalidResources
        else {
            throw ThemeCoordinatorContractError.invalidRequiredBaseResourceFailure
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
        self.requiredBaseResourceFailures = normalizedFailures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            capturedAt: container.decode(Date.self, forKey: .capturedAt),
            contributionRevision: container.decode(
                UInt64.self,
                forKey: .contributionRevision
            ),
            resourceRevision: container.decode(
                UInt64.self,
                forKey: .resourceRevision
            ),
            preferredCodexID: container.decodeIfPresent(
                CodexID.self,
                forKey: .preferredCodexID
            ),
            effectiveCodexID: container.decode(
                CodexID.self,
                forKey: .effectiveCodexID
            ),
            fallbackReason: container.decode(
                ThemeSelectionFallbackReason.self,
                forKey: .fallbackReason
            ),
            providers: container.decode(
                [ThemeProviderDiagnosticDTO].self,
                forKey: .providers
            ),
            requiredBaseResourceFailures: try container.decodeIfPresent(
                [RequiredThemeResourceFailureDTO].self,
                forKey: .requiredBaseResourceFailures
            ) ?? []
        )
    }
}

private func requiredThemeResourceFailureOrdering(
    _ lhs: RequiredThemeResourceFailureDTO,
    _ rhs: RequiredThemeResourceFailureDTO
) -> Bool {
    let left: [String] = [
        lhs.moduleID.rawValue,
        lhs.codexID.rawValue,
        lhs.stage.rawValue,
        lhs.resourceID?.rawValue ?? "",
        lhs.errorCode.rawValue,
        lhs.expectedByteCount.map { String($0) } ?? "",
        lhs.actualByteCount.map { String($0) } ?? "",
        lhs.expectedSHA256?.rawValue ?? "",
        lhs.actualSHA256?.rawValue ?? "",
        lhs.mediaType?.rawValue ?? "",
    ]
    let right: [String] = [
        rhs.moduleID.rawValue,
        rhs.codexID.rawValue,
        rhs.stage.rawValue,
        rhs.resourceID?.rawValue ?? "",
        rhs.errorCode.rawValue,
        rhs.expectedByteCount.map { String($0) } ?? "",
        rhs.actualByteCount.map { String($0) } ?? "",
        rhs.expectedSHA256?.rawValue ?? "",
        rhs.actualSHA256?.rawValue ?? "",
        rhs.mediaType?.rawValue ?? "",
    ]
    return left.lexicographicallyPrecedes(right)
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
