import Foundation
import RuneScribeContracts

enum ShareBuilderPurpose: Equatable, Sendable {
    case encryptedMessage(requiresKeyDelivery: Bool)
    case cipherInvitation

    var securitySummary: String {
        switch self {
        case .encryptedMessage(true):
            "Key included — this first delivery contains the shared cipher."
        case .encryptedMessage(false):
            "Uses your shared key — this message does not resend the cipher."
        case .cipherInvitation:
            "Contains shared cipher — anyone who imports this invitation receives the decoder for this cipher."
        }
    }

    var securityAccessibilityIdentifier: String {
        switch self {
        case .encryptedMessage(true): "share-builder.security.first-delivery"
        case .encryptedMessage(false): "share-builder.security.established"
        case .cipherInvitation: "share-builder.security.cipher-invitation"
        }
    }
}

struct ShareBuilderSource: Identifiable, Equatable, Sendable {
    let purpose: ShareBuilderPurpose
    let inscription: String
    let displayName: String
    let cipherID: UUID
    let messageHandle: EncodedMessageHandle?

    var id: String {
        let purposeID: String = switch purpose {
        case .encryptedMessage: "message"
        case .cipherInvitation: "cipher"
        }
        return "\(purposeID).\(cipherID.uuidString.lowercased())."
            + (messageHandle?.rawValue.uuidString.lowercased() ?? "invitation")
    }

    static func encryptedMessage(
        runes: String,
        senderName: String,
        cipherID: UUID,
        messageHandle: EncodedMessageHandle,
        requiresKeyDelivery: Bool
    ) -> Self {
        Self(
            purpose: .encryptedMessage(requiresKeyDelivery: requiresKeyDelivery),
            inscription: runes,
            displayName: senderName,
            cipherID: cipherID,
            messageHandle: messageHandle
        )
    }

    static func cipherInvitation(cipherID: UUID, displayName: String) -> Self {
        Self(
            purpose: .cipherInvitation,
            inscription: displayName,
            displayName: displayName,
            cipherID: cipherID,
            messageHandle: nil
        )
    }
}

struct ShareBuilderDraft: Equatable, Sendable {
    let codexID: CodexID
    var relicID: ArtifactID
    var sealID: ArtifactID?
    var frameID: ArtifactID?
    var effects: RuntimeEffectsPreference

    func selection(
        descriptor: ThemeDescriptor,
        provider: ThemeProviderSummaryDTO,
        ownedArtifactIDs: Set<ArtifactID>
    ) throws -> SharePresentationSelection {
        guard descriptor.codex.id == codexID,
              provider.codexID == codexID
        else { throw ShareArtifactRenderError.unavailableSelection }
        return try ShareBuilderPolicy.selection(
            descriptor: descriptor,
            codexOwned: provider.isOwned,
            providerAvailable: provider.state == .available,
            ownedArtifactIDs: ownedArtifactIDs,
            relicID: relicID,
            sealID: sealID,
            frameID: frameID
        )
    }
}

enum ShareBuilderChoiceAccess: String, Equatable, Sendable {
    case owned
    case locked
    case encountered
    case unavailable
}

struct ShareBuilderArtifactChoice: Identifiable, Equatable, Sendable {
    let id: ArtifactID
    let displayName: String
    let detail: String
    let rarity: ThemeRarityToken
    let access: ShareBuilderChoiceAccess
    let isCompatible: Bool

    var isSelectable: Bool { access == .owned && isCompatible }

    var accessibilityAvailability: String {
        guard isCompatible else {
            return access == .owned
                ? "Owned, incompatible, unavailable"
                : "\(access.accessibilityLabel), incompatible, unavailable"
        }
        return access.accessibilityLabel
    }

    func accessibilityValue(isSelected: Bool) -> String {
        "\(isSelected ? "Selected" : "Not selected"), \(accessibilityAvailability)"
    }
}

private extension ShareBuilderChoiceAccess {
    var accessibilityLabel: String {
        switch self {
        case .owned: "Owned, available"
        case .locked: "Locked, unavailable"
        case .encountered: "Encountered, locked, unavailable"
        case .unavailable: "Unavailable"
        }
    }
}

struct ShareBuilderCatalog: Equatable, Sendable {
    let descriptor: ThemeDescriptor
    let provider: ThemeProviderSummaryDTO
    let ownedArtifactIDs: Set<ArtifactID>
    let encounteredArtifactIDs: Set<ArtifactID>
    private(set) var defaults: ShareBuilderDraft
    private(set) var draft: ShareBuilderDraft

    init(
        descriptor: ThemeDescriptor,
        provider: ThemeProviderSummaryDTO,
        settings: RuntimeSettingsSnapshotDTO?,
        ownedArtifactIDs: Set<ArtifactID>,
        encounteredArtifactIDs: Set<ArtifactID>
    ) throws {
        guard descriptor.codex.id == provider.codexID else {
            throw ShareArtifactRenderError.unavailableSelection
        }
        self.descriptor = descriptor
        self.provider = provider
        self.ownedArtifactIDs = ownedArtifactIDs
        self.encounteredArtifactIDs = encounteredArtifactIDs
        let resolved = try Self.resolveDefaults(
            descriptor: descriptor,
            provider: provider,
            settings: settings,
            ownedArtifactIDs: ownedArtifactIDs
        )
        defaults = resolved
        draft = resolved
    }

    var relics: [ShareBuilderArtifactChoice] {
        descriptor.codex.relics.compactMap { relic in
            guard relic.metadata.availability != .reservedInactive else { return nil }
            return choice(relic.metadata, isCompatible: true)
        }
    }

    var seals: [ShareBuilderArtifactChoice] {
        descriptor.codex.seals.compactMap { seal in
            guard seal.metadata.availability != .reservedInactive else { return nil }
            return choice(seal.metadata, isCompatible: true)
        }
    }

    var frames: [ShareBuilderArtifactChoice] {
        descriptor.codex.frames.compactMap { frame in
            guard frame.metadata.availability != .reservedInactive else { return nil }
            return choice(
                frame.metadata,
                isCompatible: frame.allowsStaticShare
                    && frame.compatibleRelicIDs.contains(draft.relicID)
            )
        }
    }

    var hasChangesFromDefaults: Bool { draft != defaults }

    mutating func resetToDefaults() {
        draft = defaults
    }

    mutating func markCurrentDraftAsDefaults() {
        defaults = draft
    }

    @MainActor
    mutating func persistCurrentDraft(
        using persist: @MainActor (ShareBuilderCatalog) async throws -> Void
    ) async throws {
        let candidate = self
        try await persist(candidate)
        defaults = draft
    }

    mutating func selectRelic(_ artifactID: ArtifactID) throws {
        guard relics.contains(where: { $0.id == artifactID && $0.isSelectable }) else {
            throw ShareArtifactRenderError.lockedSelection(artifactID)
        }
        draft.relicID = artifactID
        if let frameID = draft.frameID,
           !descriptor.codex.frames.contains(where: {
               $0.metadata.id == frameID
                   && $0.allowsStaticShare
                   && $0.compatibleRelicIDs.contains(artifactID)
           }) {
            draft.frameID = nil
        }
    }

    mutating func selectSeal(_ artifactID: ArtifactID?) throws {
        guard let artifactID else {
            draft.sealID = nil
            return
        }
        guard seals.contains(where: { $0.id == artifactID && $0.isSelectable }) else {
            throw ShareArtifactRenderError.lockedSelection(artifactID)
        }
        draft.sealID = artifactID
    }

    mutating func selectFrame(_ artifactID: ArtifactID?) throws {
        guard let artifactID else {
            draft.frameID = nil
            return
        }
        guard frames.contains(where: { $0.id == artifactID && $0.isSelectable }) else {
            throw ShareArtifactRenderError.incompatibleFrame
        }
        draft.frameID = artifactID
    }

    mutating func selectEffects(_ effects: RuntimeEffectsPreference) {
        draft.effects = effects
    }

    func validatedSelection() throws -> SharePresentationSelection {
        try draft.selection(
            descriptor: descriptor,
            provider: provider,
            ownedArtifactIDs: ownedArtifactIDs
        )
    }

    private func choice(
        _ metadata: ThemeArtifactMetadata,
        isCompatible: Bool
    ) -> ShareBuilderArtifactChoice {
        let access: ShareBuilderChoiceAccess
        if provider.state != .available {
            access = .unavailable
        } else if metadata.availability == .included
                    || ownedArtifactIDs.contains(metadata.id) {
            access = .owned
        } else if metadata.availability == .encountered
                    || encounteredArtifactIDs.contains(metadata.id) {
            access = .encountered
        } else {
            access = .locked
        }
        return ShareBuilderArtifactChoice(
            id: metadata.id,
            displayName: metadata.displayName.fallbackValue,
            detail: metadata.description.fallbackValue,
            rarity: metadata.rarity,
            access: access,
            isCompatible: isCompatible
        )
    }

    private static func resolveDefaults(
        descriptor: ThemeDescriptor,
        provider: ThemeProviderSummaryDTO,
        settings: RuntimeSettingsSnapshotDTO?,
        ownedArtifactIDs: Set<ArtifactID>
    ) throws -> ShareBuilderDraft {
        guard provider.state == .available,
              provider.isOwned || descriptor.criticality == .requiredBase
        else { throw ShareArtifactRenderError.unavailableSelection }
        func selectable(_ metadata: ThemeArtifactMetadata) -> Bool {
            metadata.availability != .reservedInactive
                && (metadata.availability == .included
                    || ownedArtifactIDs.contains(metadata.id))
        }

        let codexID = descriptor.codex.id
        let relicPreference = settings?.artifactSelections(for: .relic)[codexID]
        let relicID = relicPreference.flatMap { preferred in
            descriptor.codex.relics.first(where: {
                $0.metadata.id == preferred && selectable($0.metadata)
            })?.metadata.id
        } ?? descriptor.codex.relics.first(where: {
            $0.metadata.id == descriptor.codex.defaultRelicID
                && selectable($0.metadata)
        })?.metadata.id
        guard let relicID else { throw ShareArtifactRenderError.unavailableSelection }

        let selectableSealIDs = Set(descriptor.codex.seals.compactMap {
            selectable($0.metadata) ? $0.metadata.id : nil
        })
        let fallbackSealID = descriptor.codex.seals.first(where: {
            selectable($0.metadata)
        })?.metadata.id
        let sealID: ArtifactID?
        if let settings {
            sealID = settings.artifactSelections(for: .seal).resolvedArtifactID(
                for: codexID,
                availableArtifactIDs: selectableSealIDs,
                fallbackArtifactID: fallbackSealID
            )
        } else {
            sealID = fallbackSealID
        }

        let compatibleFrameIDs = Set(descriptor.codex.frames.compactMap { frame in
            selectable(frame.metadata)
                && frame.allowsStaticShare
                && frame.compatibleRelicIDs.contains(relicID)
                ? frame.metadata.id
                : nil
        })
        let fallbackFrameID = descriptor.codex.frames.first(where: {
            compatibleFrameIDs.contains($0.metadata.id)
        })?.metadata.id
        let frameID: ArtifactID?
        if let settings {
            frameID = settings.artifactSelections(for: .frame).resolvedArtifactID(
                for: codexID,
                availableArtifactIDs: compatibleFrameIDs,
                fallbackArtifactID: fallbackFrameID
            )
        } else {
            frameID = fallbackFrameID
        }

        let draft = ShareBuilderDraft(
            codexID: codexID,
            relicID: relicID,
            sealID: sealID,
            frameID: frameID,
            effects: settings?.effectsPreference ?? .full
        )
        _ = try draft.selection(
            descriptor: descriptor,
            provider: provider,
            ownedArtifactIDs: ownedArtifactIDs
        )
        return draft
    }
}

struct ShareBuilderPreviewGenerationGate: Equatable, Sendable {
    private(set) var current: UInt64 = 0

    mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    mutating func invalidate() {
        current &+= 1
    }

    func accepts(_ generation: UInt64) -> Bool {
        generation == current
    }
}

@MainActor
func replaceShareBuilderPreviewTask(
    _ current: inout Task<Void, Never>?,
    createReplacement: () -> Task<Void, Never>
) {
    current?.cancel()
    current = createReplacement()
}
