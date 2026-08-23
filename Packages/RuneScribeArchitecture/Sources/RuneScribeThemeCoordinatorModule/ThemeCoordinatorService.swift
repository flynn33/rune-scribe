import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

typealias ThemeCoordinatorEventPublisher = @Sendable (
    EventIdentifier,
    ThemeRuntimeEventPayloadDTO
) async throws -> Void

typealias ThemeCoordinatorReconcileCommitHook = @Sendable (UInt64) async -> Void

actor ThemeCoordinatorService: RuneScribeThemeCoordinatorService {
    private struct ProviderRecord: Sendable {
        let descriptor: ThemeDescriptor
        let ownerModuleID: ModuleIdentifier
        let state: ThemeProviderState
        let isOwned: Bool
        let diagnosticCode: ThemeProviderDiagnosticCode

        var isSelectable: Bool {
            state == .available && isOwned
        }
    }

    private struct SnapshotContent: Equatable, Sendable {
        let preferredCodexID: CodexID?
        let effectiveCodexID: CodexID
        let fallbackReason: ThemeSelectionFallbackReason
        let isEmergencyPresentation: Bool
        let effectiveTheme: ThemeDescriptor
        let providers: [ThemeProviderSummaryDTO]
        let presentationInventories: [SharePresentationProviderInventory]
    }

    private let contributionReader: RuntimeContributionReaderClient
    private let resourceResolver: RuntimeOpaqueResourceResolverClient
    private let settings: RuntimeSettingsClient
    private let availability: RuntimeAvailabilityClient
    private let platform: SupportedPlatform
    private let operatingSystemVersion: RuntimeOperatingSystemVersion
    private let now: @Sendable () -> Date
    private let publishEvent: ThemeCoordinatorEventPublisher
    private let reconcileWillCommit: ThemeCoordinatorReconcileCommitHook

    private var revision: UInt64 = 0
    private var reconcileGeneration: UInt64 = 0
    private var latestSnapshot: ThemeCoordinatorSnapshotDTO?
    private var latestContent: SnapshotContent?
    private var latestDiagnostics: ThemeCoordinatorDiagnosticsDTO?
    private var providersByCodexID: [CodexID: ProviderRecord] = [:]
    private var settingsRecordRevision: UInt64 = 0
    private var activeReconcileTask: Task<Void, Error>?
    private var reconcileRequested = false
    private var continuations: [
        String: AsyncStream<ThemeCoordinatorSnapshotDTO>.Continuation
    ] = [:]
    private var observationTasks: [Task<Void, Never>] = []
    private var isShutdown = false

    private init(
        contributionReader: RuntimeContributionReaderClient,
        resourceResolver: RuntimeOpaqueResourceResolverClient,
        settings: RuntimeSettingsClient,
        availability: RuntimeAvailabilityClient,
        platform: SupportedPlatform,
        operatingSystemVersion: RuntimeOperatingSystemVersion,
        now: @escaping @Sendable () -> Date,
        publishEvent: @escaping ThemeCoordinatorEventPublisher,
        reconcileWillCommit: @escaping ThemeCoordinatorReconcileCommitHook
    ) {
        self.contributionReader = contributionReader
        self.resourceResolver = resourceResolver
        self.settings = settings
        self.availability = availability
        self.platform = platform
        self.operatingSystemVersion = operatingSystemVersion
        self.now = now
        self.publishEvent = publishEvent
        self.reconcileWillCommit = reconcileWillCommit
    }

    static func bootstrap(
        contributionReader: RuntimeContributionReaderClient,
        resourceResolver: RuntimeOpaqueResourceResolverClient,
        settings: RuntimeSettingsClient,
        availability: RuntimeAvailabilityClient,
        platform: SupportedPlatform,
        operatingSystemVersion: RuntimeOperatingSystemVersion,
        now: @escaping @Sendable () -> Date,
        publishEvent: @escaping ThemeCoordinatorEventPublisher,
        reconcileWillCommit: @escaping ThemeCoordinatorReconcileCommitHook = { _ in }
    ) async throws -> ThemeCoordinatorService {
        let service = ThemeCoordinatorService(
            contributionReader: contributionReader,
            resourceResolver: resourceResolver,
            settings: settings,
            availability: availability,
            platform: platform,
            operatingSystemVersion: operatingSystemVersion,
            now: now,
            publishEvent: publishEvent,
            reconcileWillCommit: reconcileWillCommit
        )
        try await service.reconcile()
        try await service.startObserving()
        return service
    }

    nonisolated func stateStream(
        metadata: RuntimeOperationMetadata
    ) -> AsyncStream<ThemeCoordinatorSnapshotDTO> {
        let id = metadata.operationID.rawValue
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
            Task { await self.addContinuation(id, continuation: continuation) }
        }
    }

    func snapshot(
        metadata _: RuntimeOperationMetadata
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        try await reconcile()
        guard let latestSnapshot else {
            throw ThemeCoordinatorModuleError.baseProviderUnavailable
        }
        return latestSnapshot
    }

    func selectCodex(
        _ command: SelectThemeCodexCommand,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        try await reconcile()
        guard let snapshot = latestSnapshot else {
            throw ThemeCoordinatorModuleError.baseProviderUnavailable
        }
        if let expected = command.expectedSnapshotRevision,
           expected != snapshot.revision
        {
            throw ThemeCoordinatorModuleError.revisionConflict(
                expected: expected,
                actual: snapshot.revision
            )
        }
        guard snapshot.providers.contains(where: {
            $0.codexID == command.codexID && $0.isSelectable
        }) else {
            throw ThemeCoordinatorModuleError.codexNotSelectable(command.codexID)
        }
        _ = try await settings.setSelectedCodex(
            command.codexID,
            expectedRevision: settingsRecordRevision
        )
        try await reconcile()
        guard let updated = latestSnapshot else {
            throw ThemeCoordinatorModuleError.baseProviderUnavailable
        }
        return updated
    }

    func resolveResource(
        _ request: ResolveThemeResourceRequestDTO,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ResolvedThemeResourceDTO {
        try await reconcile()
        guard let provider = providersByCodexID[request.codexID],
              let reference = provider.descriptor.resources.first(where: {
                  $0.id == request.resourceID
              }),
              Self.canResolve(
                  reference,
                  from: provider,
                  purpose: request.purpose
              )
        else {
            throw ThemeCoordinatorModuleError.resourceUnavailable(request)
        }
        let resolved = try await resourceResolver.resolve(
            OpaqueResourceHandle(
                namespace: RuntimeThemeContributionCatalog.resourceNamespace(
                    for: request.codexID
                ),
                resourceID: OpaqueResourceID(rawValue: request.resourceID.rawValue)
            )
        )
        guard Self.matches(
            resolved.metadata,
            reference: reference,
            codexID: request.codexID,
            ownerModuleID: provider.ownerModuleID
        ) else {
            throw ThemeCoordinatorModuleError.resourceUnavailable(request)
        }
        return try ResolvedThemeResourceDTO(
            codexID: request.codexID,
            resourceID: request.resourceID,
            role: reference.role,
            mediaType: reference.mediaType,
            integrity: reference.integrity,
            verifiedSHA256: ThemeSHA256Digest(
                rawValue: RuntimeIntegrityDigest.sha256Hex(resolved.data)
            )!,
            data: resolved.data
        )
    }

    func diagnostics(
        metadata _: RuntimeOperationMetadata
    ) async throws -> ThemeCoordinatorDiagnosticsDTO {
        guard let latestDiagnostics else {
            throw ThemeCoordinatorModuleError.baseProviderUnavailable
        }
        return latestDiagnostics
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()
        activeReconcileTask?.cancel()
        activeReconcileTask = nil
        reconcileRequested = false
        let activeContinuations = continuations.values
        continuations.removeAll()
        activeContinuations.forEach { $0.finish() }
        providersByCodexID.removeAll()
        latestSnapshot = nil
        latestContent = nil
        latestDiagnostics = nil
    }

    private func startObserving() async throws {
        let availabilityStream = try await availability.snapshots()
        let settingsStream = try await settings.snapshots()
        let contributionStream = try await contributionReader.changes()
        let resourceStream = try await resourceResolver.changes()
        observationTasks = [
            Task { [weak self] in
                for await _ in availabilityStream {
                    guard !Task.isCancelled else { return }
                    try? await self?.reconcile()
                }
            },
            Task { [weak self] in
                for await _ in settingsStream {
                    guard !Task.isCancelled else { return }
                    try? await self?.reconcile()
                }
            },
            Task { [weak self] in
                for await _ in contributionStream {
                    guard !Task.isCancelled else { return }
                    try? await self?.reconcile()
                }
            },
            Task { [weak self] in
                for await _ in resourceStream {
                    guard !Task.isCancelled else { return }
                    try? await self?.reconcile()
                }
            },
        ]
    }

    func reconcile() async throws {
        try await reconcile(reconcileWillCommit: reconcileWillCommit)
    }

    func reconcile(
        reconcileWillCommit: @escaping ThemeCoordinatorReconcileCommitHook
    ) async throws {
        guard !isShutdown else { return }
        reconcileRequested = true
        if let activeReconcileTask {
            try await activeReconcileTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.drainReconcileRequests(
                reconcileWillCommit: reconcileWillCommit
            )
        }
        activeReconcileTask = task
        try await task.value
    }

    private func drainReconcileRequests(
        reconcileWillCommit: @escaping ThemeCoordinatorReconcileCommitHook
    ) async throws {
        defer { activeReconcileTask = nil }
        while !isShutdown {
            reconcileRequested = false
            try await reconcilePass(reconcileWillCommit: reconcileWillCommit)
            guard reconcileRequested else { return }
        }
    }

    private func reconcilePass(
        reconcileWillCommit: @escaping ThemeCoordinatorReconcileCommitHook
    ) async throws {
        guard !isShutdown else { return }
        reconcileGeneration &+= 1
        let generation = reconcileGeneration
        let contributions = try await contributionReader.snapshot(
            for: RuntimeThemeContributionCatalog.descriptor
        )
        let resources = try await resourceResolver.snapshot()
        let availabilitySnapshot = try? await availability.snapshot()
        let settingsSnapshot = try? await settings.snapshot()
        let entitlements = availabilitySnapshot?.entitlementSnapshot.allUnlockIDs
            ?? [RuneScribeUnlockIDs.norseCodex]
        var diagnostics: [ThemeProviderDiagnosticDTO] = []
        var records: [CodexID: ProviderRecord] = [:]
        var contributionsByCodex: [
            CodexID: [RuntimeContributionSnapshotEntry<ThemeDescriptor>]
        ] = [:]
        for entry in contributions.entries {
            contributionsByCodex[entry.value.codex.id, default: []].append(entry)
        }
        let installedProviders = availabilitySnapshot?.themeProviders ?? []
        let collidingCodices = Self.collidingCodexIDs(in: installedProviders)

        for installed in installedProviders.sorted(by: {
            if $0.descriptor.codex.id == RuneScribeCodexIDs.norse { return true }
            if $1.descriptor.codex.id == RuneScribeCodexIDs.norse { return false }
            return $0.descriptor.codex.id < $1.descriptor.codex.id
        }) {
            let descriptor = installed.descriptor
            let codexID = descriptor.codex.id
            let owner = ModuleIdentifier(rawValue: descriptor.moduleID.rawValue)
            guard records[codexID] == nil else {
                diagnostics.append(
                    ThemeProviderDiagnosticDTO(
                        moduleID: owner,
                        codexID: codexID,
                        code: .duplicateCodex
                    )
                )
                continue
            }

            let isBase = codexID == RuneScribeCodexIDs.norse
            let owned = isBase || entitlements.contains(descriptor.codex.entitlementID)
            let matchingContributions = contributionsByCodex[codexID] ?? []
            let liveEntry = matchingContributions.count == 1
                ? matchingContributions[0]
                : nil
            let state: ThemeProviderState
            let diagnosticCode: ThemeProviderDiagnosticCode
            if collidingCodices.contains(codexID) {
                state = .unavailable
                diagnosticCode = .stableIDCollision
            } else if !isCompatible(descriptor) {
                state = .incompatible
                diagnosticCode = .incompatible
            } else if !owned {
                state = .locked
                diagnosticCode = .accepted
            } else if installed.lifecycleState != .active {
                state = .unavailable
                diagnosticCode = .lifecycleUnavailable
            } else if liveEntry == nil {
                state = .unavailable
                diagnosticCode = matchingContributions.isEmpty
                    ? .missingContribution
                    : .duplicateCodex
            } else if liveEntry?.owner.moduleID != owner
                || liveEntry?.key != RuntimeThemeContributionCatalog.key(for: codexID)
                || liveEntry?.value != descriptor
            {
                state = .unavailable
                diagnosticCode = .descriptorMismatch
            } else {
                let resourceCode = Self.validateResources(
                    for: descriptor,
                    ownerModuleID: owner,
                    snapshot: resources
                )
                if resourceCode == .accepted {
                    state = .available
                    diagnosticCode = .accepted
                } else {
                    state = .invalidResources
                    diagnosticCode = resourceCode
                }
            }
            records[codexID] = ProviderRecord(
                descriptor: descriptor,
                ownerModuleID: owner,
                state: state,
                isOwned: owned,
                diagnosticCode: diagnosticCode
            )
            diagnostics.append(
                ThemeProviderDiagnosticDTO(
                    moduleID: owner,
                    codexID: codexID,
                    code: diagnosticCode
                )
            )
        }

        let discoveredCodices = Set(installedProviders.map { $0.descriptor.codex.id })
        for entry in contributions.entries
            where !discoveredCodices.contains(entry.value.codex.id)
        {
            diagnostics.append(
                ThemeProviderDiagnosticDTO(
                    moduleID: entry.owner.moduleID,
                    codexID: entry.value.codex.id,
                    code: .identityMismatch
                )
            )
        }

        guard let base = records[RuneScribeCodexIDs.norse],
              base.ownerModuleID == RuneScribeModuleIDs.norseTheme,
              base.isOwned,
              (base.isSelectable || base.state == .invalidResources)
        else {
            throw ThemeCoordinatorModuleError.baseProviderUnavailable
        }

        let preference = Self.preference(from: settingsSnapshot)
        let reconciledSettingsRecordRevision = settingsSnapshot?.settings.first(where: {
            $0.settingID == RuneScribeRuntimeSettings.selectedCodex
        })?.revision ?? 0
        let isEmergencyPresentation = base.state == .invalidResources
        let selection: (
            effectiveCodexID: CodexID,
            reason: ThemeSelectionFallbackReason
        ) = isEmergencyPresentation
            ? (
                effectiveCodexID: RuneScribeCodexIDs.norse,
                reason: .invalidResources
            )
            : Self.effectiveSelection(preference: preference, providers: records)
        let summaries = records.values.map { provider in
            ThemeProviderSummaryDTO(
                codexID: provider.descriptor.codex.id,
                moduleID: provider.ownerModuleID,
                displayName: provider.descriptor.codex.displayName.fallbackValue,
                state: provider.state,
                isOwned: provider.isOwned,
                isSelectable: provider.isSelectable,
                isSelected: provider.descriptor.codex.id == selection.effectiveCodexID
            )
        }.sorted { $0.codexID < $1.codexID }
        let effectiveTheme = records[selection.effectiveCodexID]!.descriptor
        let presentationInventories = try records.values.map {
            try SharePresentationProviderInventory(descriptor: $0.descriptor)
        }.sorted { $0.codexID < $1.codexID }
        let content = SnapshotContent(
            preferredCodexID: preference.codexID,
            effectiveCodexID: selection.effectiveCodexID,
            fallbackReason: selection.reason,
            isEmergencyPresentation: isEmergencyPresentation,
            effectiveTheme: effectiveTheme,
            providers: summaries,
            presentationInventories: presentationInventories
        )
        let reconciledDiagnostics = try ThemeCoordinatorDiagnosticsDTO(
            capturedAt: now(),
            contributionRevision: contributions.revision,
            resourceRevision: resources.revision,
            preferredCodexID: content.preferredCodexID,
            effectiveCodexID: content.effectiveCodexID,
            fallbackReason: content.fallbackReason,
            providers: diagnostics
        )

        await reconcileWillCommit(generation)
        guard !isShutdown, generation == reconcileGeneration else { return }
        guard !reconcileRequested else { return }

        let priorContent = latestContent
        var committedRevision: UInt64?
        if content != priorContent {
            revision &+= 1
            committedRevision = revision
            let snapshot = try ThemeCoordinatorSnapshotDTO(
                revision: revision,
                capturedAt: now(),
                preferredCodexID: content.preferredCodexID,
                effectiveCodexID: content.effectiveCodexID,
                fallbackReason: content.fallbackReason,
                effectiveTheme: content.effectiveTheme,
                providers: content.providers,
                presentationInventories: content.presentationInventories,
                isEmergencyPresentation: content.isEmergencyPresentation
            )
            latestContent = content
            latestSnapshot = snapshot
            continuations.values.forEach { $0.yield(snapshot) }
        }
        settingsRecordRevision = reconciledSettingsRecordRevision
        providersByCodexID = records
        latestDiagnostics = reconciledDiagnostics

        if let committedRevision {
            await publishEvents(
                previous: priorContent,
                current: content,
                providers: records,
                snapshotRevision: committedRevision,
                reconcileGeneration: generation
            )
        }
    }

    private func addContinuation(
        _ id: String,
        continuation: AsyncStream<ThemeCoordinatorSnapshotDTO>.Continuation
    ) {
        guard !isShutdown else {
            continuation.finish()
            return
        }
        continuations[id] = continuation
        if let latestSnapshot { continuation.yield(latestSnapshot) }
    }

    private func removeContinuation(_ id: String) {
        continuations.removeValue(forKey: id)
    }

    private func publishEvents(
        previous: SnapshotContent?,
        current: SnapshotContent,
        providers: [CodexID: ProviderRecord],
        snapshotRevision: UInt64,
        reconcileGeneration generation: UInt64
    ) async {
        let currentStates = Dictionary(
            uniqueKeysWithValues: current.providers.map { ($0.codexID, $0.state) }
        )
        let previousStates = Dictionary(
            uniqueKeysWithValues: (previous?.providers ?? []).map {
                ($0.codexID, $0.state)
            }
        )
        if previous?.providers != current.providers {
            guard generation == reconcileGeneration, !isShutdown else { return }
            try? await publishEvent(
                RuneScribeThemeEventIDs.catalogChanged,
                ThemeRuntimeEventPayloadDTO(
                    snapshotRevision: snapshotRevision,
                    codexID: nil
                )
            )
        }
        for (codexID, state) in currentStates where previousStates[codexID] != state {
            guard generation == reconcileGeneration, !isShutdown else { return }
            let type = state == .available
                ? RuneScribeThemeEventIDs.providerAvailable
                : RuneScribeThemeEventIDs.providerUnavailable
            try? await publishEvent(
                type,
                ThemeRuntimeEventPayloadDTO(
                    snapshotRevision: snapshotRevision,
                    codexID: codexID
                )
            )
        }
        if let previous,
           previous.effectiveCodexID != current.effectiveCodexID
        {
            guard generation == reconcileGeneration, !isShutdown else { return }
            try? await publishEvent(
                RuneScribeThemeEventIDs.selectionChanged,
                ThemeRuntimeEventPayloadDTO(
                    snapshotRevision: snapshotRevision,
                    codexID: current.effectiveCodexID
                )
            )
        }
        for provider in providers.values
            where provider.diagnosticCode != .accepted
        {
            guard generation == reconcileGeneration, !isShutdown else { return }
            try? await publishEvent(
                RuneScribeThemeEventIDs.validationFailed,
                ThemeRuntimeEventPayloadDTO(
                    snapshotRevision: snapshotRevision,
                    codexID: provider.descriptor.codex.id,
                    diagnosticCode: provider.diagnosticCode
                )
            )
        }
    }

    private static func preference(
        from snapshot: RuntimeSettingsSnapshotDTO?
    ) -> (codexID: CodexID?, invalid: Bool) {
        guard let value = snapshot?[RuneScribeRuntimeSettings.selectedCodex] else {
            return (nil, false)
        }
        guard case .text(let text) = value,
              let decoded = try? RuntimeSelectedCodexPreferenceCodec.decodeForRead(text)
        else {
            return (nil, true)
        }
        return (decoded.value.codexID, false)
    }

    private static func effectiveSelection(
        preference: (codexID: CodexID?, invalid: Bool),
        providers: [CodexID: ProviderRecord]
    ) -> (effectiveCodexID: CodexID, reason: ThemeSelectionFallbackReason) {
        guard !preference.invalid else {
            return (RuneScribeCodexIDs.norse, .invalidPreference)
        }
        guard let preferred = preference.codexID else {
            return (RuneScribeCodexIDs.norse, .missingPreference)
        }
        guard let provider = providers[preferred] else {
            return (RuneScribeCodexIDs.norse, .unknownCodex)
        }
        guard provider.isSelectable else {
            let reason: ThemeSelectionFallbackReason = switch provider.state {
            case .locked: .locked
            case .unavailable: .unavailable
            case .incompatible: .incompatible
            case .invalidResources: .invalidResources
            case .available: .unavailable
            }
            return (RuneScribeCodexIDs.norse, reason)
        }
        return (preferred, .none)
    }

    private static func collidingCodexIDs(
        in providers: [RuntimeThemeProviderAvailabilitySnapshot]
    ) -> Set<CodexID> {
        var result = Set<CodexID>()
        var codexCounts: [CodexID: Int] = [:]
        var claims: [String: Set<CodexID>] = [:]
        for provider in providers {
            let codexID = provider.descriptor.codex.id
            codexCounts[codexID, default: 0] += 1
            for stableID in provider.descriptor.globallyUniqueStableIDs {
                claims[stableID, default: []].insert(codexID)
            }
        }
        for (codexID, count) in codexCounts where count > 1 {
            result.insert(codexID)
        }
        for codices in claims.values where codices.count > 1 {
            for codexID in codices where codexID != RuneScribeCodexIDs.norse {
                result.insert(codexID)
            }
        }
        return result
    }

    private func isCompatible(_ descriptor: ThemeDescriptor) -> Bool {
        let themePlatform: ThemePlatform = switch platform {
        case .iOS: .iOS
        case .macOS: .macOS
        }
        guard let requirement = descriptor.platformCompatibility.first(where: {
            $0.platform == themePlatform
        }) else { return false }
        let required = (
            Int(requirement.minimumMajorVersion),
            Int(requirement.minimumMinorVersion),
            Int(requirement.minimumPatchVersion)
        )
        if operatingSystemVersion.major != required.0 {
            return operatingSystemVersion.major > required.0
        }
        if operatingSystemVersion.minor != required.1 {
            return operatingSystemVersion.minor > required.1
        }
        return operatingSystemVersion.patch >= required.2
    }

    private static func validateResources(
        for descriptor: ThemeDescriptor,
        ownerModuleID: ModuleIdentifier,
        snapshot: OpaqueResourceSnapshot
    ) -> ThemeProviderDiagnosticCode {
        let namespace = RuntimeThemeContributionCatalog.resourceNamespace(
            for: descriptor.codex.id
        )
        let expectedByID = Dictionary(
            uniqueKeysWithValues: descriptor.resources.map { ($0.id, $0) }
        )
        let ownedResources = snapshot.resources.filter {
            $0.ownerModuleID == ownerModuleID
        }
        guard ownedResources.allSatisfy({ metadata in
            guard metadata.handle.namespace == namespace,
                  let resourceID = ThemeResourceID(
                      rawValue: metadata.handle.resourceID.rawValue
                  )
            else { return false }
            return expectedByID[resourceID] != nil
        }) else {
            return .unexpectedResource
        }
        let metadataByID = Dictionary(
            uniqueKeysWithValues: ownedResources.map {
                ($0.handle.resourceID.rawValue, $0)
            }
        )
        for reference in descriptor.resources {
            guard let metadata = metadataByID[reference.id.rawValue] else {
                if reference.requirement == .required { return .missingResource }
                continue
            }
            guard matches(
                metadata,
                reference: reference,
                codexID: descriptor.codex.id,
                ownerModuleID: ownerModuleID
            ) else {
                return .resourceMismatch
            }
        }
        return .accepted
    }

    private static func canResolve(
        _ reference: ThemeResourceReference,
        from provider: ProviderRecord,
        purpose: ThemeResourceResolutionPurpose
    ) -> Bool {
        switch purpose {
        case .activePresentation:
            return provider.state == .available
        case .catalogPreview:
            return (provider.state == .available || provider.state == .locked)
                && isCatalogPreviewResource(
                    reference,
                    descriptor: provider.descriptor
                )
        }
    }

    private static func isCatalogPreviewResource(
        _ reference: ThemeResourceReference,
        descriptor: ThemeDescriptor
    ) -> Bool {
        let codex = descriptor.codex
        var declaredPreviewResourceIDs: Set<ThemeResourceID> = [
            codex.vault.cardResourceID,
            codex.vault.lockedSilhouetteResourceID,
            codex.vault.encounteredResourceID,
            codex.vault.selectedResourceID,
        ]
        for relic in codex.relics
            where relic.metadata.availability != .reservedInactive
        {
            declaredPreviewResourceIDs.formUnion([
                relic.thumbnailResourceID,
                relic.staticFallbackResourceID,
                relic.highContrastResourceID,
            ])
        }
        for seal in codex.seals
            where seal.metadata.availability != .reservedInactive
        {
            declaredPreviewResourceIDs.formUnion([
                seal.vectorResourceID,
                seal.monochromeFallbackResourceID,
                seal.thumbnailResourceID,
            ])
        }
        for frame in codex.frames
            where frame.metadata.availability != .reservedInactive
        {
            declaredPreviewResourceIDs.formUnion([
                frame.vectorResourceID,
                frame.staticFallbackResourceID,
            ])
        }
        for crest in codex.crests
            where crest.metadata.availability != .reservedInactive
        {
            declaredPreviewResourceIDs.formUnion([
                crest.vectorResourceID,
                crest.staticFallbackResourceID,
            ])
        }

        let previewRoles: Set<ThemeResourceRoleID> = [
            ThemeResourceRoles.vaultCard,
            ThemeResourceRoles.vaultLockedSilhouette,
            ThemeResourceRoles.vaultEncountered,
            ThemeResourceRoles.vaultSelected,
            ThemeResourceRoles.relicThumbnail,
            ThemeResourceRoles.relicStaticShareFallback,
            ThemeResourceRoles.relicHighContrast,
            ThemeResourceRoles.sealVectorMaster,
            ThemeResourceRoles.sealMonochromeFallback,
            ThemeResourceRoles.sealThumbnail,
            ThemeResourceRoles.frameVectorMaster,
            ThemeResourceRoles.frameStaticFallback,
            ThemeResourceRoles.crestVectorMaster,
            ThemeResourceRoles.crestStaticFallback,
        ]
        return declaredPreviewResourceIDs.contains(reference.id)
            && previewRoles.contains(reference.role)
    }

    private static func matches(
        _ metadata: OpaqueResourceMetadata,
        reference: ThemeResourceReference,
        codexID: CodexID,
        ownerModuleID: ModuleIdentifier
    ) -> Bool {
        let expectedPixelSize = reference.integrity.pixelSize.map {
            OpaqueResourcePixelSize(width: Int($0.width), height: Int($0.height))
        }
        return metadata.handle.namespace
                == RuntimeThemeContributionCatalog.resourceNamespace(for: codexID)
            && metadata.handle.resourceID.rawValue == reference.id.rawValue
            && metadata.ownerModuleID == ownerModuleID
            && metadata.semanticRole == reference.role.rawValue
            && metadata.mediaType == reference.mediaType.opaqueMediaType
            && metadata.byteCount == Int(reference.integrity.byteLength)
            && metadata.sha256 == reference.integrity.sha256.rawValue
            && metadata.pixelSize == expectedPixelSize
    }
}
