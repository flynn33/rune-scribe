import Foundation
import RuneScribeContracts

public protocol RuneScribeThemeCoordinatorService: Sendable {
    func snapshot(
        metadata: RuntimeOperationMetadata
    ) async throws -> ThemeCoordinatorSnapshotDTO
    func stateStream(
        metadata: RuntimeOperationMetadata
    ) -> AsyncStream<ThemeCoordinatorSnapshotDTO>
    func selectCodex(
        _ command: SelectThemeCodexCommand,
        metadata: RuntimeOperationMetadata
    ) async throws -> ThemeCoordinatorSnapshotDTO
    func providerDescriptor(
        _ request: ThemeProviderDescriptorRequestDTO,
        metadata: RuntimeOperationMetadata
    ) async throws -> ThemeDescriptor
    func resolveResource(
        _ request: ResolveThemeResourceRequestDTO,
        metadata: RuntimeOperationMetadata
    ) async throws -> ResolvedThemeResourceDTO
    func diagnostics(
        metadata: RuntimeOperationMetadata
    ) async throws -> ThemeCoordinatorDiagnosticsDTO
}

public enum RuntimeThemeDiagnosticsError: Error, Equatable, Sendable {
    case disabled
}

public enum RuntimeThemeEndpointCatalog {
    private static let destination = RuntimeEndpointDestination.role(
        RuneScribeRoles.themeCoordinator
    )
    private static let version = RuntimeSchemaVersions.v1
    private static let commandLimit: UInt64 = 16 * 1_024
    private static let stateLimit: UInt64 = 4 * 1_024 * 1_024
    private static let resourceLimit: UInt64 = 8 * 1_024 * 1_024 + 64 * 1_024

    private static func endpoint<Request: Sendable, Response: Sendable>(
        _ id: RuntimeEndpointIdentifier,
        kind: RuntimeEndpointKind,
        capability: CapabilityIdentifier,
        maximumRequestBytes: UInt64 = commandLimit,
        maximumResponseBytes: UInt64 = stateLimit
    ) -> RuntimeEndpointKey<Request, Response> {
        RuntimeEndpointDescriptor(
            endpointID: id,
            kind: kind,
            destination: destination,
            requestSchemaVersion: version,
            responseSchemaVersion: version,
            requiredCapability: capability,
            privacyClass: .publicData,
            maximumRequestBytes: maximumRequestBytes,
            maximumResponseBytes: maximumResponseBytes
        ).key
    }

    public static let state = RuntimeStateEndpointDescriptor<ThemeCoordinatorSnapshotDTO>(
        endpointID: "theme.state",
        destination: destination,
        subscriptionSchemaVersion: version,
        stateSchemaVersion: version,
        requiredCapability: RuneScribeCapabilities.themeStateRead,
        privacyClass: .publicData,
        maximumSubscriptionBytes: 0,
        maximumStateBytes: stateLimit,
        bufferingPolicy: .bufferingNewest(1)
    )

    public static let snapshot: RuntimeEndpointKey<
        RuntimeEmptyPayload,
        ThemeCoordinatorSnapshotDTO
    > = endpoint(
        "theme.state.current",
        kind: .query,
        capability: RuneScribeCapabilities.themeStateRead
    )

    public static let selectCodex: RuntimeEndpointKey<
        SelectThemeCodexCommand,
        ThemeCoordinatorSnapshotDTO
    > = endpoint(
        "theme.codex.select",
        kind: .command,
        capability: RuneScribeCapabilities.themeSelection
    )

    public static let resolveResource: RuntimeEndpointKey<
        ResolveThemeResourceRequestDTO,
        ResolvedThemeResourceDTO
    > = endpoint(
        "theme.resource.resolve",
        kind: .query,
        capability: RuneScribeCapabilities.themeResourceRead,
        maximumResponseBytes: resourceLimit
    )

    public static let providerDescriptor: RuntimeEndpointKey<
        ThemeProviderDescriptorRequestDTO,
        ThemeDescriptor
    > = endpoint(
        "theme.provider.descriptor",
        kind: .query,
        capability: RuneScribeCapabilities.themeStateRead
    )

    public static let diagnostics: RuntimeEndpointKey<
        RuntimeEmptyPayload,
        ThemeCoordinatorDiagnosticsDTO
    > = endpoint(
        "theme.diagnostics.summary",
        kind: .query,
        capability: RuneScribeCapabilities.themeDiagnostics
    )

    public static let publishedEndpointIDs: Set<RuntimeEndpointIdentifier> = [
        state.endpointID,
        selectCodex.descriptor.endpointID,
        resolveResource.descriptor.endpointID,
        providerDescriptor.descriptor.endpointID,
        diagnostics.descriptor.endpointID,
        snapshot.descriptor.endpointID,
    ]

    public static let UIEndpointIDs: Set<RuntimeEndpointIdentifier> = [
        state.endpointID,
        selectCodex.descriptor.endpointID,
        resolveResource.descriptor.endpointID,
        providerDescriptor.descriptor.endpointID,
        snapshot.descriptor.endpointID,
    ]
}

public extension ModuleContext {
    func registerThemeCoordinatorEndpoints(
        _ service: any RuneScribeThemeCoordinatorService
    ) async throws {
        let diagnosticsEnabled = permitsThemeDiagnostics
        try await registerStateEndpoint(
            RuntimeThemeEndpointCatalog.state,
            handler: { metadata in service.stateStream(metadata: metadata) }
        )
        try await registerEndpoint(RuntimeThemeEndpointCatalog.snapshot) {
            metadata, _ in
            try await service.snapshot(metadata: metadata)
        }
        try await registerEndpoint(RuntimeThemeEndpointCatalog.selectCodex) {
            metadata, command in
            try await service.selectCodex(command, metadata: metadata)
        }
        try await registerEndpoint(RuntimeThemeEndpointCatalog.resolveResource) {
            metadata, request in
            try await service.resolveResource(request, metadata: metadata)
        }
        try await registerEndpoint(RuntimeThemeEndpointCatalog.providerDescriptor) {
            metadata, request in
            try await service.providerDescriptor(request, metadata: metadata)
        }
        try await registerEndpoint(RuntimeThemeEndpointCatalog.diagnostics) {
            metadata, _ in
            guard diagnosticsEnabled else {
                throw RuntimeThemeDiagnosticsError.disabled
            }
            return try await service.diagnostics(metadata: metadata)
        }
    }

    func themeCoordinatorClient() async throws -> RuntimeThemeCoordinatorClient {
        let destination = RuntimeEndpointDestination.role(
            RuneScribeRoles.themeCoordinator
        )
        let command = try await commandClient(to: destination)
        let query = try await queryClient(to: destination)
        let state = try await stateClient(to: destination)
        return RuntimeThemeCoordinatorClient(
            command: command,
            query: query,
            stateEnvelopes: try await state.subscribe(
                to: RuntimeThemeEndpointCatalog.state
            )
        )
    }
}

public struct RuntimeThemeCoordinatorClient: Sendable {
    private let command: RuntimeCommandClient
    private let query: RuntimeQueryClient
    public let stateEnvelopes: RuntimeStateStream<ThemeCoordinatorSnapshotDTO>

    init(
        command: RuntimeCommandClient,
        query: RuntimeQueryClient,
        stateEnvelopes: RuntimeStateStream<ThemeCoordinatorSnapshotDTO>
    ) {
        self.command = command
        self.query = query
        self.stateEnvelopes = stateEnvelopes
    }

    public func selectCodex(
        _ commandValue: SelectThemeCodexCommand
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        try await command.send(
            commandValue,
            to: RuntimeThemeEndpointCatalog.selectCodex
        )
    }

    public func snapshot() async throws -> ThemeCoordinatorSnapshotDTO {
        try await query.fetch(
            RuntimeEmptyPayload(),
            from: RuntimeThemeEndpointCatalog.snapshot
        )
    }

    public func resolveResource(
        _ request: ResolveThemeResourceRequestDTO
    ) async throws -> ResolvedThemeResourceDTO {
        try await query.fetch(
            request,
            from: RuntimeThemeEndpointCatalog.resolveResource
        )
    }

    public func providerDescriptor(
        for codexID: CodexID
    ) async throws -> ThemeDescriptor {
        try await query.fetch(
            ThemeProviderDescriptorRequestDTO(codexID: codexID),
            from: RuntimeThemeEndpointCatalog.providerDescriptor
        )
    }

    public func resolveCatalogPreviewResource(
        codexID: CodexID,
        resourceID: ThemeResourceID
    ) async throws -> ResolvedThemeResourceDTO {
        try await resolveResource(
            ResolveThemeResourceRequestDTO(
                codexID: codexID,
                resourceID: resourceID,
                purpose: .catalogPreview
            )
        )
    }

    public func diagnostics() async throws -> ThemeCoordinatorDiagnosticsDTO {
        try await query.fetch(
            RuntimeEmptyPayload(),
            from: RuntimeThemeEndpointCatalog.diagnostics
        )
    }
}

extension ThemeResourceMediaType {
    public var opaqueMediaType: OpaqueResourceMediaType {
        switch self {
        case .json: .json
        case .png: .png
        case .heif: .heif
        case .pdf: .pdf
        case .ttf: .trueTypeFont
        case .otf: .openTypeFont
        case .mp4: .mp4
        case .quickTime: .quickTime
        case .m4a: .m4a
        case .caf: .caf
        case .wav: .wav
        }
    }
}
