import Foundation
import RuneScribeContracts

public protocol RuneScribeProgressionService: Sendable {
    func applyEvent(
        _ envelope: DomainEventEnvelope,
        metadata: RuntimeOperationMetadata
    ) async throws -> ProgressionEventApplyResult
    func stateStream(
        metadata: RuntimeOperationMetadata
    ) -> AsyncStream<ProgressionSnapshotDTO>
    func entitlementStream(
        metadata: RuntimeOperationMetadata
    ) -> AsyncStream<ProgressionEntitlementSnapshotDTO>
    func markRevealPresented(
        _ command: MarkProgressionRevealPresentedCommand,
        metadata: RuntimeOperationMetadata
    ) async throws
    func acknowledgeReveal(
        _ command: AcknowledgeProgressionRevealCommand,
        metadata: RuntimeOperationMetadata
    ) async throws
    func selectTitle(
        _ command: SelectProgressionTitleCommand,
        metadata: RuntimeOperationMetadata
    ) async throws
    func diagnosticsSummary(
        metadata: RuntimeOperationMetadata
    ) async throws -> ProgressionDiagnosticsSummaryDTO
    func rebuild(
        _ request: ProgressionRecoveryRequest,
        metadata: RuntimeOperationMetadata
    ) async throws -> ProgressionRecoveryResult
}

public enum RuntimeProgressionRevealPresentationError: Error, Equatable, Sendable {
    case unsupported
}

public extension RuneScribeProgressionService {
    func markRevealPresented(
        _: MarkProgressionRevealPresentedCommand,
        metadata _: RuntimeOperationMetadata
    ) async throws {
        throw RuntimeProgressionRevealPresentationError.unsupported
    }
}

/// Separate opt-in seam for PRG-5 so existing Progression service fakes and
/// older providers remain source-compatible until they adopt migration.
public protocol RuneScribeExistingUserMigrationApplying: Sendable {
    func applyExistingUserMigration(
        _ delivery: ExistingUserMigrationDeliveryDTO,
        metadata: RuntimeOperationMetadata
    ) async throws -> ExistingUserMigrationApplyResult
    func applyExistingUserMigrationPage(
        _ delivery: ExistingUserMigrationPageDeliveryDTO,
        metadata: RuntimeOperationMetadata
    ) async throws -> ExistingUserMigrationPageApplyResult
}

public extension RuneScribeExistingUserMigrationApplying {
    func applyExistingUserMigrationPage(
        _: ExistingUserMigrationPageDeliveryDTO,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ExistingUserMigrationPageApplyResult {
        .outcome(.deferredUnsupportedSchema)
    }
}

public enum RuntimeProgressionRecoveryError: Error, Equatable, Sendable {
    case disabled
}

public enum RuntimeProgressionEndpointCatalog {
    private static let destination = RuntimeEndpointDestination.role(
        RuneScribeRoles.progression
    )
    private static let version = RuntimeSchemaVersions.v1
    private static let commandLimit: UInt64 = 64 * 1_024
    private static let stateLimit: UInt64 = 4 * 1_024 * 1_024

    private static func endpoint<Request: Sendable, Response: Sendable>(
        _ id: RuntimeEndpointIdentifier,
        kind: RuntimeEndpointKind = .command,
        capability: CapabilityIdentifier,
        maximumRequestBytes: UInt64 = commandLimit
    ) -> RuntimeEndpointKey<Request, Response> {
        RuntimeEndpointDescriptor(
            endpointID: id,
            kind: kind,
            destination: destination,
            requestSchemaVersion: version,
            responseSchemaVersion: version,
            requiredCapability: capability,
            privacyClass: .sensitiveRedacted,
            maximumRequestBytes: maximumRequestBytes,
            maximumResponseBytes: stateLimit
        ).key
    }

    private static func state<State: Sendable>(
        _ id: RuntimeEndpointIdentifier
    ) -> RuntimeStateEndpointDescriptor<State> {
        RuntimeStateEndpointDescriptor(
            endpointID: id,
            destination: destination,
            subscriptionSchemaVersion: version,
            stateSchemaVersion: version,
            requiredCapability: RuneScribeCapabilities.progressionStateRead,
            privacyClass: .sensitiveRedacted,
            maximumSubscriptionBytes: 0,
            maximumStateBytes: stateLimit,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    public static let applyEvent: RuntimeEndpointKey<
        DomainEventEnvelope,
        ProgressionEventApplyResult
    > = endpoint(
        "progression.event.apply",
        capability: RuneScribeCapabilities.progressionEventApply
    )

    public static let progressionState: RuntimeStateEndpointDescriptor<ProgressionSnapshotDTO> =
        state("progression.state")

    public static let entitlements: RuntimeStateEndpointDescriptor<
        ProgressionEntitlementSnapshotDTO
    > = state("progression.entitlements")

    public static let acknowledgeReveal: RuntimeEndpointKey<
        AcknowledgeProgressionRevealCommand,
        RuntimeEmptyPayload
    > = endpoint(
        "progression.reveal.acknowledge",
        capability: RuneScribeCapabilities.progressionCommands
    )

    public static let markRevealPresented: RuntimeEndpointKey<
        MarkProgressionRevealPresentedCommand,
        RuntimeEmptyPayload
    > = endpoint(
        "progression.reveal.mark-presented",
        capability: RuneScribeCapabilities.progressionCommands
    )

    public static let selectTitle: RuntimeEndpointKey<
        SelectProgressionTitleCommand,
        RuntimeEmptyPayload
    > = endpoint(
        "progression.title.select",
        capability: RuneScribeCapabilities.progressionCommands
    )

    public static let diagnosticsSummary: RuntimeEndpointKey<
        RuntimeEmptyPayload,
        ProgressionDiagnosticsSummaryDTO
    > = endpoint(
        "progression.diagnostics.summary",
        kind: .query,
        capability: RuneScribeCapabilities.progressionStateRead
    )

    public static let rebuild: RuntimeEndpointKey<
        ProgressionRecoveryRequest,
        ProgressionRecoveryResult
    > = endpoint(
        "progression.recovery.rebuild",
        capability: RuneScribeCapabilities.progressionRecovery
    )

    public static let applyExistingUserMigration: RuntimeEndpointKey<
        ExistingUserMigrationDeliveryDTO,
        ExistingUserMigrationApplyResult
    > = endpoint(
        "progression.migration.existing-user.apply",
        capability: RuneScribeCapabilities.progressionMigrationApply,
        maximumRequestBytes: 1_048_576
    )

    public static let applyExistingUserMigrationPage: RuntimeEndpointKey<
        ExistingUserMigrationPageDeliveryDTO,
        ExistingUserMigrationPageApplyResult
    > = endpoint(
        "progression.migration.existing-user.page.apply",
        capability: RuneScribeCapabilities.progressionMigrationApply,
        maximumRequestBytes: 1_048_576
    )

    /// Added to a Progression provider's declarations only when that provider
    /// adopts `RuneScribeExistingUserMigrationApplying`.
    public static let existingUserMigrationEndpointIDs: Set<
        RuntimeEndpointIdentifier
    > = [
        applyExistingUserMigration.descriptor.endpointID,
        applyExistingUserMigrationPage.descriptor.endpointID,
    ]

    public static let publishedEndpointIDs: Set<RuntimeEndpointIdentifier> = [
        applyEvent.descriptor.endpointID,
        progressionState.endpointID,
        entitlements.endpointID,
        markRevealPresented.descriptor.endpointID,
        acknowledgeReveal.descriptor.endpointID,
        selectTitle.descriptor.endpointID,
        diagnosticsSummary.descriptor.endpointID,
        rebuild.descriptor.endpointID,
    ]

    public static let UIEndpointIDs: Set<RuntimeEndpointIdentifier> = [
        progressionState.endpointID,
        entitlements.endpointID,
        markRevealPresented.descriptor.endpointID,
        acknowledgeReveal.descriptor.endpointID,
        selectTitle.descriptor.endpointID,
        diagnosticsSummary.descriptor.endpointID,
    ]
}

public extension ModuleContext {
    func registerProgressionEndpoints(
        _ service: any RuneScribeProgressionService
    ) async throws {
        try await registerEndpoint(RuntimeProgressionEndpointCatalog.applyEvent) {
            metadata, envelope in
            try await service.applyEvent(envelope, metadata: metadata)
        }
        try await registerStateEndpoint(
            RuntimeProgressionEndpointCatalog.progressionState,
            handler: { metadata in service.stateStream(metadata: metadata) }
        )
        try await registerStateEndpoint(
            RuntimeProgressionEndpointCatalog.entitlements,
            handler: { metadata in service.entitlementStream(metadata: metadata) }
        )
        try await registerEndpoint(RuntimeProgressionEndpointCatalog.markRevealPresented) {
            metadata, command in
            try await service.markRevealPresented(command, metadata: metadata)
            return RuntimeEmptyPayload()
        }
        try await registerEndpoint(RuntimeProgressionEndpointCatalog.acknowledgeReveal) {
            metadata, command in
            try await service.acknowledgeReveal(command, metadata: metadata)
            return RuntimeEmptyPayload()
        }
        try await registerEndpoint(RuntimeProgressionEndpointCatalog.selectTitle) {
            metadata, command in
            try await service.selectTitle(command, metadata: metadata)
            return RuntimeEmptyPayload()
        }
        try await registerEndpoint(RuntimeProgressionEndpointCatalog.diagnosticsSummary) {
            metadata, _ in
            let summary = try await service.diagnosticsSummary(metadata: metadata)
            let outbox = try await progressionOutboxSnapshotForDiagnostics()
            let pendingOutboxCount = [
                outbox.pendingCount, outbox.readyCount, outbox.inFlightCount,
            ].reduce(UInt64(0)) { partial, count in
                let sum = partial.addingReportingOverflow(count)
                return sum.overflow ? UInt64.max : sum.partialValue
            }
            return try ProgressionDiagnosticsSummaryDTO(
                capturedAt: summary.capturedAt,
                availability: summary.availability,
                storeHealth: summary.storeHealth,
                catalogID: summary.catalogID,
                catalogVersion: summary.catalogVersion,
                stateNamespaceSchemaVersion: summary.stateNamespaceSchemaVersion,
                logicalRecordSchemaVersion: summary.logicalRecordSchemaVersion,
                pendingOutboxCount: min(
                    pendingOutboxCount,
                    ProgressionDiagnosticRecordCountDTO.maximumRecordCount
                ),
                recordCounts: summary.recordCounts,
                hashes: summary.hashes,
                errors: summary.errors
            )
        }
        try await registerEndpoint(RuntimeProgressionEndpointCatalog.rebuild) {
            metadata, request in
            guard environment.permitsProgressionRecovery else {
                throw RuntimeProgressionRecoveryError.disabled
            }
            return try await service.rebuild(request, metadata: metadata)
        }
        if let migrationService = service as? any RuneScribeExistingUserMigrationApplying {
            try await registerEndpoint(
                RuntimeProgressionEndpointCatalog.applyExistingUserMigration
            ) { metadata, delivery in
                try await migrationService.applyExistingUserMigration(
                    delivery,
                    metadata: metadata
                )
            }
            try await registerEndpoint(
                RuntimeProgressionEndpointCatalog.applyExistingUserMigrationPage
            ) { metadata, delivery in
                try await migrationService.applyExistingUserMigrationPage(
                    delivery,
                    metadata: metadata
                )
            }
        }
    }

    func progressionClient() async throws -> RuntimeProgressionClient {
        let destination = RuntimeEndpointDestination.role(RuneScribeRoles.progression)
        let command = try await commandClient(to: destination)
        let query = try await queryClient(to: destination)
        let state = try await stateClient(to: destination)
        return RuntimeProgressionClient(
            command: command,
            query: query,
            progressionStateEnvelopes: try await state.subscribe(
                to: RuntimeProgressionEndpointCatalog.progressionState
            ),
            entitlementEnvelopes: try await state.subscribe(
                to: RuntimeProgressionEndpointCatalog.entitlements
            )
        )
    }
}

public struct RuntimeProgressionClient: Sendable {
    private let command: RuntimeCommandClient
    private let query: RuntimeQueryClient
    public let progressionStateEnvelopes: RuntimeStateStream<ProgressionSnapshotDTO>
    public let entitlementEnvelopes: RuntimeStateStream<ProgressionEntitlementSnapshotDTO>

    init(
        command: RuntimeCommandClient,
        query: RuntimeQueryClient,
        progressionStateEnvelopes: RuntimeStateStream<ProgressionSnapshotDTO>,
        entitlementEnvelopes: RuntimeStateStream<ProgressionEntitlementSnapshotDTO>
    ) {
        self.command = command
        self.query = query
        self.progressionStateEnvelopes = progressionStateEnvelopes
        self.entitlementEnvelopes = entitlementEnvelopes
    }

    public func acknowledgeReveal(
        _ commandValue: AcknowledgeProgressionRevealCommand
    ) async throws {
        _ = try await command.send(
            commandValue,
            to: RuntimeProgressionEndpointCatalog.acknowledgeReveal
        )
    }

    public func markRevealPresented(
        _ commandValue: MarkProgressionRevealPresentedCommand
    ) async throws {
        _ = try await command.send(
            commandValue,
            to: RuntimeProgressionEndpointCatalog.markRevealPresented
        )
    }

    public func selectTitle(_ commandValue: SelectProgressionTitleCommand) async throws {
        _ = try await command.send(
            commandValue,
            to: RuntimeProgressionEndpointCatalog.selectTitle
        )
    }

    public func diagnosticsSummary() async throws -> ProgressionDiagnosticsSummaryDTO {
        try await query.fetch(
            RuntimeEmptyPayload(),
            from: RuntimeProgressionEndpointCatalog.diagnosticsSummary
        )
    }
}
