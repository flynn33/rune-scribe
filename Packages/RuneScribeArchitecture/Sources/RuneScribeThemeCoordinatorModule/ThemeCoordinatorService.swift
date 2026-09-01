import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

typealias ThemeCoordinatorEventPublisher = @Sendable (
    EventIdentifier,
    ThemeRuntimeEventPayloadDTO
) async throws -> Void

typealias ThemeCoordinatorReconcileCommitHook = @Sendable (UInt64) async -> Void
typealias ThemeCoordinatorSelectionDidWriteHook = @Sendable (CodexID) async -> Void

actor ThemeCoordinatorService: RuneScribeThemeCoordinatorService {
    private struct ProviderResourceValidationKey: Hashable, Sendable {
        let codexID: CodexID
        let ownerModuleID: ModuleIdentifier
        let moduleGeneration: UInt64
        let runtimeGeneration: UInt64
        let contributionRevision: UInt64
        let resources: [OpaqueResourceMetadata]
    }

    private struct ProviderRecord: Sendable {
        let descriptor: ThemeDescriptor
        let ownerModuleID: ModuleIdentifier
        let state: ThemeProviderState
        let isOwned: Bool
        let diagnosticCode: ThemeProviderDiagnosticCode
        let resourceValidationKey: ProviderResourceValidationKey?
        let supportsReceivedPresentationResolution: Bool

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
        let requiredBaseResourceFailures: [RequiredThemeResourceFailureDTO]
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
    private let selectionDidWrite: ThemeCoordinatorSelectionDidWriteHook

    private var revision: UInt64 = 0
    private var reconcileGeneration: UInt64 = 0
    private var latestSnapshot: ThemeCoordinatorSnapshotDTO?
    private var latestContent: SnapshotContent?
    private var latestDiagnostics: ThemeCoordinatorDiagnosticsDTO?
    private var providersByCodexID: [CodexID: ProviderRecord] = [:]
    private var resourceValidationResults: [
        ProviderResourceValidationKey: ThemeProviderDiagnosticCode
    ] = [:]
    private var requiredBaseValidationFailures: [
        ProviderResourceValidationKey: RequiredThemeResourceFailureDTO
    ] = [:]
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
        reconcileWillCommit: @escaping ThemeCoordinatorReconcileCommitHook,
        selectionDidWrite: @escaping ThemeCoordinatorSelectionDidWriteHook
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
        self.selectionDidWrite = selectionDidWrite
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
        reconcileWillCommit: @escaping ThemeCoordinatorReconcileCommitHook = { _ in },
        selectionDidWrite: @escaping ThemeCoordinatorSelectionDidWriteHook = { _ in }
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
            reconcileWillCommit: reconcileWillCommit,
            selectionDidWrite: selectionDidWrite
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
        guard let provider = providersByCodexID[command.codexID],
              provider.isSelectable,
              let validationKey = provider.resourceValidationKey
        else {
            throw ThemeCoordinatorModuleError.codexNotSelectable(command.codexID)
        }
        let resourceCode = try await validateProviderResources(
            provider.descriptor,
            ownerModuleID: provider.ownerModuleID,
            validationKey: validationKey,
            reuseAcceptedResult: false
        )
        guard resourceCode == .accepted else {
            resourceValidationResults[validationKey] = resourceCode
            try await reconcile()
            throw ThemeCoordinatorModuleError.codexNotSelectable(command.codexID)
        }
        resourceValidationResults[validationKey] = .accepted
        try await reconcile()
        guard let refreshedSnapshot = latestSnapshot else {
            throw ThemeCoordinatorModuleError.baseProviderUnavailable
        }
        if let expected = command.expectedSnapshotRevision,
           expected != refreshedSnapshot.revision
        {
            throw ThemeCoordinatorModuleError.revisionConflict(
                expected: expected,
                actual: refreshedSnapshot.revision
            )
        }
        guard let refreshedProvider = providersByCodexID[command.codexID],
              refreshedProvider.isSelectable,
              refreshedProvider.resourceValidationKey == validationKey
        else {
            throw ThemeCoordinatorModuleError.codexNotSelectable(command.codexID)
        }
        _ = try await settings.setSelectedCodex(
            command.codexID,
            expectedRevision: settingsRecordRevision
        )
        await selectionDidWrite(command.codexID)
        try await reconcile()
        guard let updated = latestSnapshot else {
            throw ThemeCoordinatorModuleError.baseProviderUnavailable
        }
        guard updated.preferredCodexID == command.codexID,
              updated.effectiveCodexID == command.codexID,
              updated.fallbackReason == .none,
              let updatedProvider = providersByCodexID[command.codexID],
              updatedProvider.isSelectable,
              updated.providers.contains(where: {
                  $0.codexID == command.codexID
                      && $0.state == .available
                      && $0.isSelectable
                      && $0.isSelected
              })
        else {
            throw ThemeCoordinatorModuleError.codexNotSelectable(command.codexID)
        }
        return updated
    }

    func providerDescriptor(
        _ request: ThemeProviderDescriptorRequestDTO,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ThemeDescriptor {
        try await reconcile()
        guard let provider = providersByCodexID[request.codexID] else {
            throw ThemeCoordinatorModuleError.codexNotSelectable(request.codexID)
        }
        let isAuthorized = switch request.purpose {
        case .selection:
            provider.state == .available
                && (provider.isOwned
                    || provider.descriptor.criticality == .requiredBase)
        case .receivedPresentation:
            provider.supportsReceivedPresentationResolution
        }
        guard isAuthorized else {
            throw ThemeCoordinatorModuleError.codexNotSelectable(request.codexID)
        }
        return provider.descriptor
    }

    func resolveResource(
        _ request: ResolveThemeResourceRequestDTO,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ResolvedThemeResourceDTO {
        try await reconcile()
        guard let snapshot = latestSnapshot,
              let provider = providersByCodexID[request.codexID],
              let reference = provider.descriptor.resources.first(where: {
                  $0.id == request.resourceID
              }),
              Self.canResolve(
                  reference,
                  from: provider,
                  purpose: request.purpose,
                  effectiveCodexID: snapshot.effectiveCodexID
              ),
              Self.isPermittedResourceRequest(
                  request,
                  reference: reference,
                  descriptor: provider.descriptor
              )
        else {
            throw ThemeCoordinatorModuleError.resourceUnavailable(request)
        }
        let handle = OpaqueResourceHandle(
            namespace: RuntimeThemeContributionCatalog.resourceNamespace(
                for: request.codexID
            ),
            resourceID: OpaqueResourceID(rawValue: request.resourceID.rawValue)
        )
        let resolved: ResolvedOpaqueResource
        do {
            resolved = try await resourceResolver.resolve(handle)
        } catch {
            if !Self.isPermittedOptionalAbsence(error, reference: reference) {
                if let failure = error as? RequiredThemeResourceFailureDTO,
                   reference.requirement == .required,
                   provider.descriptor.codex.id == RuneScribeCodexIDs.norse,
                   provider.ownerModuleID == RuneScribeModuleIDs.norseTheme,
                   let validationKey = provider.resourceValidationKey
                {
                    requiredBaseValidationFailures[validationKey] = failure
                }
                await invalidateProviderResources(
                    provider,
                    code: Self.resourceDiagnosticCode(for: error)
                )
            }
            throw ThemeCoordinatorModuleError.resourceUnavailable(request)
        }
        try await reconcile()
        guard let currentSnapshot = latestSnapshot,
              let currentProvider = providersByCodexID[request.codexID],
              currentProvider.resourceValidationKey == provider.resourceValidationKey,
              let currentReference = currentProvider.descriptor.resources.first(where: {
                  $0.id == request.resourceID
              }),
              currentReference == reference,
              Self.canResolve(
                  currentReference,
                  from: currentProvider,
                  purpose: request.purpose,
                  effectiveCodexID: currentSnapshot.effectiveCodexID
              ),
              Self.isPermittedResourceRequest(
                  request,
                  reference: currentReference,
                  descriptor: currentProvider.descriptor
              )
        else {
            throw ThemeCoordinatorModuleError.resourceUnavailable(request)
        }
        guard Self.matches(
            resolved.metadata,
            reference: currentReference,
            codexID: request.codexID,
            ownerModuleID: currentProvider.ownerModuleID
        ) else {
            await invalidateProviderResources(currentProvider, code: .resourceMismatch)
            throw ThemeCoordinatorModuleError.resourceUnavailable(request)
        }
        return try ResolvedThemeResourceDTO(
            codexID: request.codexID,
            resourceID: request.resourceID,
            role: currentReference.role,
            mediaType: currentReference.mediaType,
            integrity: currentReference.integrity,
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
        resourceValidationResults.removeAll()
        requiredBaseValidationFailures.removeAll()
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
        let requiredBaseFailureContributions = try await contributionReader.snapshot(
            for: RuntimeThemeContributionCatalog.requiredBaseResourceFailure
        )
        let resources = try await resourceResolver.snapshot()
        let availabilitySnapshot = try? await availability.snapshot()
        let settingsSnapshot = try? await settings.snapshot()
        let entitlements = availabilitySnapshot?.entitlementSnapshot.allUnlockIDs
            ?? [RuneScribeUnlockIDs.norseCodex]
        let preference = Self.preference(from: settingsSnapshot)
        var diagnostics: [ThemeProviderDiagnosticDTO] = []
        var records: [CodexID: ProviderRecord] = [:]
        var currentValidationKeys = Set<ProviderResourceValidationKey>()
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
            let validationKey = liveEntry.map {
                Self.resourceValidationKey(
                    descriptor: descriptor,
                    contribution: $0,
                    resources: resources
                )
            }
            if let validationKey {
                currentValidationKeys.insert(validationKey)
            }
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
                var resourceCode = Self.validateResources(
                    for: descriptor,
                    ownerModuleID: owner,
                    snapshot: resources
                )
                if resourceCode == .accepted,
                   let validationKey,
                   let priorPayloadCode = resourceValidationResults[validationKey]
                {
                    resourceCode = priorPayloadCode
                }
                let shouldValidatePayloads = isBase
                    || preference.codexID == codexID
                if resourceCode == .accepted,
                   shouldValidatePayloads,
                   let validationKey,
                   resourceValidationResults[validationKey] == nil
                {
                    resourceCode = try await validateProviderResources(
                        descriptor,
                        ownerModuleID: owner,
                        validationKey: validationKey
                    )
                    resourceValidationResults[validationKey] = resourceCode
                }
                if resourceCode == .accepted {
                    state = .available
                    diagnosticCode = .accepted
                } else {
                    state = .invalidResources
                    diagnosticCode = resourceCode
                }
            }
            let hasCurrentRegisteredProvider = installed.lifecycleState == .active
                && liveEntry?.owner.moduleID == owner
                && liveEntry?.key
                    == RuntimeThemeContributionCatalog.key(for: codexID)
                && liveEntry?.value == descriptor
                && validationKey != nil
                && Self.validateResources(
                    for: descriptor,
                    ownerModuleID: owner,
                    snapshot: resources
                ) == .accepted
            let hasNoKnownPayloadFailure = validationKey.map {
                resourceValidationResults[$0] == nil
                    || resourceValidationResults[$0] == .accepted
            } ?? false
            let supportsReceivedPresentationResolution =
                (state == .available || state == .locked)
                    && hasCurrentRegisteredProvider
                    && hasNoKnownPayloadFailure
            records[codexID] = ProviderRecord(
                descriptor: descriptor,
                ownerModuleID: owner,
                state: state,
                isOwned: owned,
                diagnosticCode: diagnosticCode,
                resourceValidationKey: validationKey,
                supportsReceivedPresentationResolution:
                    supportsReceivedPresentationResolution
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

        let reconciledSettingsRecordRevision = settingsSnapshot?.settings.first(where: {
            $0.settingID == RuneScribeRuntimeSettings.selectedCodex
        })?.revision ?? 0
        let isEmergencyPresentation = base.state == .invalidResources
        var requiredBaseResourceFailures = Self.requiredBaseResourceFailures(
            from: requiredBaseFailureContributions
        )
        requiredBaseResourceFailures.append(
            contentsOf: Self.requiredBaseResourceFailures(from: resources)
        )
        if let validationKey = base.resourceValidationKey,
           let validationFailure = requiredBaseValidationFailures[validationKey]
        {
            requiredBaseResourceFailures.append(validationFailure)
        }
        requiredBaseResourceFailures = Self.normalizedRequiredBaseResourceFailures(
            requiredBaseResourceFailures
        )
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
            presentationInventories: presentationInventories,
            requiredBaseResourceFailures: requiredBaseResourceFailures
        )
        let reconciledDiagnostics = try ThemeCoordinatorDiagnosticsDTO(
            capturedAt: now(),
            contributionRevision: contributions.revision,
            resourceRevision: resources.revision,
            preferredCodexID: content.preferredCodexID,
            effectiveCodexID: content.effectiveCodexID,
            fallbackReason: content.fallbackReason,
            providers: diagnostics,
            requiredBaseResourceFailures: content.requiredBaseResourceFailures
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
                isEmergencyPresentation: content.isEmergencyPresentation,
                requiredBaseResourceFailures: content.requiredBaseResourceFailures
            )
            latestContent = content
            latestSnapshot = snapshot
            continuations.values.forEach { $0.yield(snapshot) }
        }
        settingsRecordRevision = reconciledSettingsRecordRevision
        providersByCodexID = records
        resourceValidationResults = resourceValidationResults.filter {
            currentValidationKeys.contains($0.key)
        }
        requiredBaseValidationFailures = requiredBaseValidationFailures.filter {
            currentValidationKeys.contains($0.key)
        }
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

    private static func requiredBaseResourceFailures(
        from snapshot: RuntimeContributionSnapshot<RequiredThemeResourceFailureDTO>
    ) -> [RequiredThemeResourceFailureDTO] {
        let values: [RequiredThemeResourceFailureDTO] = snapshot.entries.compactMap {
            entry -> RequiredThemeResourceFailureDTO? in
            guard entry.key == RuntimeThemeContributionCatalog
                .requiredBaseResourceFailureKey,
                  entry.owner.moduleID == RuneScribeModuleIDs.norseTheme,
                  entry.value.moduleID == RuneScribeModuleIDs.norseTheme,
                  entry.value.codexID == RuneScribeCodexIDs.norse
            else { return nil }
            return entry.value
        }
        return normalizedRequiredBaseResourceFailures(values)
    }

    private static func requiredBaseResourceFailures(
        from snapshot: OpaqueResourceSnapshot
    ) -> [RequiredThemeResourceFailureDTO] {
        let namespace = RuntimeThemeContributionCatalog.resourceNamespace(
            for: RuneScribeCodexIDs.norse
        )
        let metadataByHandle = Dictionary(
            uniqueKeysWithValues: snapshot.resources.map { ($0.handle, $0) }
        )
        let values: [RequiredThemeResourceFailureDTO] = snapshot.validationFaults.compactMap {
            fault -> RequiredThemeResourceFailureDTO? in
            guard fault.ownerModuleID == RuneScribeModuleIDs.norseTheme,
                  fault.handle.namespace == namespace,
                  metadataByHandle[fault.handle]?.registrationID == fault.registrationID,
                  let failure = fault.requiredBaseFailure,
                  failure.moduleID == RuneScribeModuleIDs.norseTheme,
                  failure.codexID == RuneScribeCodexIDs.norse
            else { return nil }
            return failure
        }
        return normalizedRequiredBaseResourceFailures(values)
    }

    private static func normalizedRequiredBaseResourceFailures(
        _ values: [RequiredThemeResourceFailureDTO]
    ) -> [RequiredThemeResourceFailureDTO] {
        let sorted = Array(Set(values)).sorted {
            requiredBaseResourceFailureOrderingKey($0)
                .lexicographicallyPrecedes(
                    requiredBaseResourceFailureOrderingKey($1)
                )
        }
        return Array(
            sorted.prefix(
                ThemeCoordinatorDiagnosticsDTO.maximumRequiredBaseResourceFailureCount
            )
        )
    }

    private static func requiredBaseResourceFailureOrderingKey(
        _ failure: RequiredThemeResourceFailureDTO
    ) -> [String] {
        [
            failure.moduleID.rawValue,
            failure.codexID.rawValue,
            failure.stage.rawValue,
            failure.resourceID?.rawValue ?? "",
            failure.errorCode.rawValue,
            failure.expectedByteCount.map { String($0) } ?? "",
            failure.actualByteCount.map { String($0) } ?? "",
            failure.expectedSHA256?.rawValue ?? "",
            failure.actualSHA256?.rawValue ?? "",
            failure.mediaType?.rawValue ?? "",
        ]
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

    private static func resourceValidationKey(
        descriptor: ThemeDescriptor,
        contribution: RuntimeContributionSnapshotEntry<ThemeDescriptor>,
        resources: OpaqueResourceSnapshot
    ) -> ProviderResourceValidationKey {
        ProviderResourceValidationKey(
            codexID: descriptor.codex.id,
            ownerModuleID: contribution.owner.moduleID,
            moduleGeneration: contribution.owner.moduleGeneration,
            runtimeGeneration: contribution.owner.runtimeGeneration,
            contributionRevision: contribution.publishedRevision,
            resources: resources.resources
                .filter { $0.ownerModuleID == contribution.owner.moduleID }
                .sorted { $0.handle < $1.handle }
        )
    }

    private func validateProviderResources(
        _ descriptor: ThemeDescriptor,
        ownerModuleID: ModuleIdentifier,
        validationKey: ProviderResourceValidationKey,
        reuseAcceptedResult: Bool = true
    ) async throws -> ThemeProviderDiagnosticCode {
        if let cached = resourceValidationResults[validationKey],
           cached != .accepted || reuseAcceptedResult
        {
            return cached
        }
        let namespace = RuntimeThemeContributionCatalog.resourceNamespace(
            for: descriptor.codex.id
        )
        for reference in descriptor.resources.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            do {
                let resolved = try await resourceResolver.resolve(
                    OpaqueResourceHandle(
                        namespace: namespace,
                        resourceID: OpaqueResourceID(
                            rawValue: reference.id.rawValue
                        )
                    )
                )
                guard Self.matches(
                    resolved.metadata,
                    reference: reference,
                    codexID: descriptor.codex.id,
                    ownerModuleID: ownerModuleID
                ) else {
                    return .resourceMismatch
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as RequiredThemeResourceFailureDTO {
                if descriptor.codex.id == RuneScribeCodexIDs.norse {
                    requiredBaseValidationFailures[validationKey] = failure
                }
                return Self.resourceDiagnosticCode(for: failure)
            } catch {
                if Self.isPermittedOptionalAbsence(error, reference: reference) {
                    continue
                }
                return Self.resourceDiagnosticCode(for: error)
            }
        }
        requiredBaseValidationFailures.removeValue(forKey: validationKey)
        return .accepted
    }

    private func invalidateProviderResources(
        _ provider: ProviderRecord,
        code: ThemeProviderDiagnosticCode
    ) async {
        guard code != .accepted,
              let validationKey = provider.resourceValidationKey
        else { return }
        resourceValidationResults[validationKey] = code
        try? await reconcile()
    }

    private static func isPermittedOptionalAbsence(
        _ error: Error,
        reference: ThemeResourceReference
    ) -> Bool {
        guard reference.requirement == .optional,
              let error = error as? RuntimeOpaqueResourceError
        else { return false }
        if case .resourceUnavailable = error {
            return true
        }
        return false
    }

    private static func resourceDiagnosticCode(
        for error: Error
    ) -> ThemeProviderDiagnosticCode {
        if let failure = error as? RequiredThemeResourceFailureDTO {
            return failure.errorCode == .resourceUnavailable
                ? .missingResource
                : .resourceMismatch
        }
        if let failure = error as? RuntimeVerifiedApplicationResourceFailure {
            if case .resourceUnavailable = failure {
                return .missingResource
            }
            return .resourceMismatch
        }
        guard let error = error as? RuntimeOpaqueResourceError else {
            return .resourceMismatch
        }
        switch error {
        case .missingRequiredResource, .namespaceUnavailable, .resourceUnavailable:
            return .missingResource
        default:
            return .resourceMismatch
        }
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
        let metadataByHandle = Dictionary(
            uniqueKeysWithValues: ownedResources.map { ($0.handle, $0) }
        )
        let currentFaults = snapshot.validationFaults.filter { fault in
            fault.ownerModuleID == ownerModuleID
                && fault.handle.namespace == namespace
                && metadataByHandle[fault.handle]?.registrationID == fault.registrationID
        }
        if currentFaults.contains(where: { $0.code == .resourceMismatch }) {
            return .resourceMismatch
        }
        if currentFaults.contains(where: { $0.code == .missingRequiredResource }) {
            return .missingResource
        }
        return .accepted
    }

    private static func canResolve(
        _ reference: ThemeResourceReference,
        from provider: ProviderRecord,
        purpose: ThemeResourceResolutionPurpose,
        effectiveCodexID: CodexID
    ) -> Bool {
        switch purpose {
        case .activePresentation:
            return provider.state == .available
                && provider.descriptor.codex.id == effectiveCodexID
        case .catalogPreview:
            return (provider.state == .available || provider.state == .locked)
                && isCatalogPreviewResource(
                    reference,
                    descriptor: provider.descriptor
                )
        case .receivedPresentation:
            return provider.supportsReceivedPresentationResolution
        case .shareRendering:
            return provider.state == .available
                && provider.isOwned
                && isShareRenderingResource(
                    reference,
                    descriptor: provider.descriptor
                )
        }
    }

    private static func isPermittedResourceRequest(
        _ request: ResolveThemeResourceRequestDTO,
        reference: ThemeResourceReference,
        descriptor: ThemeDescriptor
    ) -> Bool {
        switch request.purpose {
        case .receivedPresentation:
            guard let selection = request.receivedPresentationSelection else {
                return false
            }
            return isReceivedPresentationResource(
                reference,
                descriptor: descriptor,
                selection: selection
            )
        case .activePresentation, .catalogPreview, .shareRendering:
            return request.receivedPresentationSelection == nil
        }
    }

    static func isReceivedPresentationResource(
        _ reference: ThemeResourceReference,
        descriptor: ThemeDescriptor,
        selection: SharePresentationSelection
    ) -> Bool {
        guard descriptor.resources.contains(reference),
              selection.presentationVersion
                == SharePresentationSelection.supportedPresentationVersion,
              let selection = SharePresentationProviderCompatibilityResolver
                .effectiveSelection(for: selection),
              selection.codexID == descriptor.codex.id,
              selection.scriptID == descriptor.codex.primaryScriptID,
              let script = descriptor.codex.scripts.first(where: {
                  $0.id == selection.scriptID
              }),
              let relic = descriptor.codex.relics.first(where: {
                  $0.metadata.id == selection.relicID
                      && $0.metadata.availability != .reservedInactive
              }),
              let received = descriptor.codex.receivedPresentation
        else { return false }

        let seal: ThemeSealDescriptor?
        if let sealID = selection.sealID {
            guard let selected = descriptor.codex.seals.first(where: {
                $0.metadata.id == sealID
                    && $0.metadata.availability != .reservedInactive
            }) else { return false }
            seal = selected
        } else {
            seal = nil
        }

        let frame: ThemeFrameDescriptor?
        if let frameID = selection.frameID {
            guard let selected = descriptor.codex.frames.first(where: {
                $0.metadata.id == frameID
                    && $0.metadata.availability != .reservedInactive
                    && $0.allowsStaticShare
                    && $0.compatibleRelicIDs.contains(relic.metadata.id)
            }) else { return false }
            frame = selected
        } else {
            frame = nil
        }

        let background = descriptor.codex.background
        if reference.id == script.fontResourceID {
            return reference.role == ThemeResourceRoles.scriptFont
        }
        if reference.id == background.staticBaseResourceID {
            return reference.role == ThemeResourceRoles.backgroundStaticBase
        }
        if reference.id == background.reduceMotionResourceID {
            return [
                ThemeResourceRoles.backgroundReduceMotion,
                ThemeResourceRoles.backgroundStaticBase,
            ].contains(reference.role)
        }
        if reference.id == relic.staticFallbackResourceID {
            return reference.role == ThemeResourceRoles.relicStaticShareFallback
        }
        if let seal {
            if reference.id == seal.standardResourceID {
                return reference.role == (seal.colorResourceID == reference.id
                    ? ThemeResourceRoles.sealColorMaster
                    : ThemeResourceRoles.sealVectorMaster)
            }
        }
        if let frame, reference.id == frame.staticFallbackResourceID {
            return reference.role == ThemeResourceRoles.frameStaticFallback
        }

        let receivedResources: [ThemeResourceID: ThemeResourceRoleID] = [
            received.primarySenderAvatarResourceID:
                ThemeResourceRoles.receivedPrimarySenderAvatar,
            received.shareSenderAvatarResourceID:
                ThemeResourceRoles.receivedShareSenderAvatar,
            received.shareCodexBadgeResourceID:
                ThemeResourceRoles.receivedShareCodexBadge,
            received.primaryMedallion.resourceID:
                ThemeResourceRoles.receivedPrimaryMedallion,
            received.shareMedallion.resourceID:
                ThemeResourceRoles.receivedShareMedallion,
        ]
        return receivedResources[reference.id] == reference.role
    }

    static func isShareRenderingResource(
        _ reference: ThemeResourceReference,
        descriptor: ThemeDescriptor
    ) -> Bool {
        let codex = descriptor.codex
        let background = codex.background
        if reference.id == background.staticBaseResourceID {
            return reference.role == ThemeResourceRoles.backgroundStaticBase
        }
        if reference.id == background.reduceMotionResourceID {
            return [
                ThemeResourceRoles.backgroundReduceMotion,
                ThemeResourceRoles.backgroundStaticBase,
            ].contains(reference.role)
        }
        if reference.id == background.highContrastResourceID {
            return reference.role == ThemeResourceRoles.backgroundHighContrast
        }

        for script in codex.scripts where script.id == codex.primaryScriptID {
            if let fontResourceID = script.fontResourceID,
               reference.id == fontResourceID
            {
                return reference.role == ThemeResourceRoles.scriptFont
            }
        }
        for relic in codex.relics
            where relic.metadata.availability != .reservedInactive
        {
            if reference.id == relic.staticFallbackResourceID {
                return reference.role == ThemeResourceRoles.relicStaticShareFallback
            }
            if reference.id == relic.highContrastResourceID {
                return [
                    ThemeResourceRoles.relicHighContrast,
                    ThemeResourceRoles.relicStaticShareFallback,
                ].contains(reference.role)
            }
        }
        for seal in codex.seals
            where seal.metadata.availability != .reservedInactive
        {
            if let colorResourceID = seal.colorResourceID,
               reference.id == colorResourceID
            {
                return reference.role == ThemeResourceRoles.sealColorMaster
            }
            if let vectorResourceID = seal.vectorResourceID,
               reference.id == vectorResourceID
            {
                return reference.role == ThemeResourceRoles.sealVectorMaster
            }
            if reference.id == seal.monochromeFallbackResourceID {
                return reference.role == ThemeResourceRoles.sealMonochromeFallback
            }
        }
        for frame in codex.frames
            where frame.metadata.availability != .reservedInactive
        {
            if reference.id == frame.staticFallbackResourceID {
                return reference.role == ThemeResourceRoles.frameStaticFallback
            }
        }
        return false
    }

    static func isCatalogPreviewResource(
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
        if let unavailableResourceID = codex.vault.unavailableResourceID {
            declaredPreviewResourceIDs.insert(unavailableResourceID)
        }
        for relic in codex.relics
            where relic.metadata.availability != .reservedInactive
        {
            declaredPreviewResourceIDs.formUnion([
                relic.primaryResourceID,
                relic.thumbnailResourceID,
                relic.staticFallbackResourceID,
                relic.highContrastResourceID,
            ])
        }
        for seal in codex.seals
            where seal.metadata.availability != .reservedInactive
        {
            declaredPreviewResourceIDs.formUnion([
                seal.monochromeFallbackResourceID,
                seal.thumbnailResourceID,
            ])
            if let vectorResourceID = seal.vectorResourceID {
                declaredPreviewResourceIDs.insert(vectorResourceID)
            }
            if let colorResourceID = seal.colorResourceID {
                declaredPreviewResourceIDs.insert(colorResourceID)
            }
        }
        for frame in codex.frames
            where frame.metadata.availability != .reservedInactive
        {
            declaredPreviewResourceIDs.formUnion([
                frame.vectorResourceID,
                frame.staticFallbackResourceID,
            ])
            if let thumbnailResourceID = frame.thumbnailResourceID {
                declaredPreviewResourceIDs.insert(thumbnailResourceID)
            }
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
            ThemeResourceRoles.vaultUnavailable,
            ThemeResourceRoles.relicMaster,
            ThemeResourceRoles.relicThumbnail,
            ThemeResourceRoles.relicStaticShareFallback,
            ThemeResourceRoles.relicHighContrast,
            ThemeResourceRoles.sealColorMaster,
            ThemeResourceRoles.sealVectorMaster,
            ThemeResourceRoles.sealMonochromeFallback,
            ThemeResourceRoles.sealThumbnail,
            ThemeResourceRoles.frameVectorMaster,
            ThemeResourceRoles.frameStaticFallback,
            ThemeResourceRoles.frameThumbnail,
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
