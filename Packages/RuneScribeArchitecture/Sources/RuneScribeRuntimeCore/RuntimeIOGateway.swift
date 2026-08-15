import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts

public struct RuntimeClipboardSnapshot: Equatable, Sendable {
    public let changeCount: Int
    public let string: String?

    public init(changeCount: Int, string: String?) {
        self.changeCount = changeCount
        self.string = string
    }
}

public struct RuntimeInboundFileReadRequest: Equatable, Sendable {
    public let fileURL: URL
    public let requiresSecurityScopedAccess: Bool
    public let maximumByteCount: Int

    public init(
        fileURL: URL,
        requiresSecurityScopedAccess: Bool,
        maximumByteCount: Int
    ) {
        self.fileURL = fileURL
        self.requiresSecurityScopedAccess = requiresSecurityScopedAccess
        self.maximumByteCount = maximumByteCount
    }
}

public enum RuntimeBundledFontFailure: Error, Equatable, Sendable {
    case resourceUnavailable
    case integrityMismatch
    case unreadableFont
    case registrationFailed
}

public enum RuntimeVerifiedApplicationResourceFailure: Error, Equatable, Sendable {
    case invalidMaximumByteCount
    case resourceUnavailable
    case contentTooLarge
    case integrityMismatch
}

public struct RuntimeApplicationResourceSession: Sendable {
    private let acquireOperation: @Sendable () async throws
        -> RuntimeApplicationResourceLease

    init(
        acquire: @escaping @Sendable () async throws
            -> RuntimeApplicationResourceLease
    ) {
        acquireOperation = acquire
    }

    @_spi(RuntimeResourceHost)
    public func acquire() async throws -> RuntimeApplicationResourceLease {
        try await acquireOperation()
    }
}

public struct RuntimeSharePresentationSession: Sendable {
    private let acquireOperation: @Sendable () async throws
        -> RuntimeSharePresentationLease

    init(
        acquire: @escaping @Sendable () async throws
            -> RuntimeSharePresentationLease
    ) {
        acquireOperation = acquire
    }

    @_spi(RuntimeResourceHost)
    public func acquire() async throws -> RuntimeSharePresentationLease {
        try await acquireOperation()
    }
}

/// Opaque authority for one UI-owned native file selection flow. Only the
/// runtime presentation target can supply a platform URL; callers outside that
/// SPI can retain and pass the session without observing the selected file.
public struct RuntimeInboundFileImportSession: Sendable {
    public static let unavailable = RuntimeInboundFileImportSession { _ in
        throw RuneScribeRuntimeError.serviceUnavailable(
            RuneScribeServiceIDs.inboundFileReader
        )
    }

    private let importOperation: @Sendable (URL) async throws -> ImportResultDTO

    init(
        importSelectedFile: @escaping @Sendable (URL) async throws
            -> ImportResultDTO
    ) {
        importOperation = importSelectedFile
    }

    @_spi(RuntimeFileImportHost)
    public func importSelectedFile(_ fileURL: URL) async throws -> ImportResultDTO {
        try await importOperation(fileURL)
    }
}

struct RuntimeInboundFileImportDelivery: Sendable {
    let operation: @Sendable (InboundFileDTO) async throws -> ImportResultDTO

    func deliver(_ input: InboundFileDTO) async throws -> ImportResultDTO {
        try await operation(input)
    }
}

@_spi(RuntimeResourceHost)
public enum RuntimeApplicationResourceEvent: Equatable, Sendable {
    case revoked
    case completed(ShareArtifactOutcomeDTO)
}

@_spi(RuntimeResourceHost)
public enum RuntimeSharePresentationEvent: Equatable, Sendable {
    case presented(SharePresentationReportDTO)
    case completed(ShareArtifactCompletionEvidenceDTO)
    case revoked
}

@_spi(RuntimeResourceHost)
public enum RuntimeResolvedShareContent: Equatable, Sendable {
    case artifact(URL)
    case text(String)
}

private final class RuntimeApplicationResourceLeaseStorage: Sendable {
    let url: URL
    let eventSignal: RuntimeApplicationResourceEventSignal
    let closeOperation: @Sendable () async -> Void

    fileprivate init(
        url: URL,
        eventSignal: RuntimeApplicationResourceEventSignal,
        close: @escaping @Sendable () async -> Void
    ) {
        self.url = url
        self.eventSignal = eventSignal
        closeOperation = close
    }

    deinit {
        let closeOperation = self.closeOperation
        Task {
            await closeOperation()
        }
    }
}

private actor RuntimeApplicationResourceEventSignal {
    typealias Continuation = AsyncStream<RuntimeApplicationResourceEvent>.Continuation

    private var terminalEvent: RuntimeApplicationResourceEvent?
    private var isTerminated = false
    private var continuations: [UUID: Continuation] = [:]

    func makeStream() -> AsyncStream<RuntimeApplicationResourceEvent> {
        let continuationID = UUID()
        return AsyncStream { continuation in
            if isTerminated {
                if let terminalEvent {
                    continuation.yield(terminalEvent)
                }
                continuation.finish()
                return
            }
            continuations[continuationID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    await self?.removeContinuation(continuationID)
                }
            }
        }
    }

    func terminate(with event: RuntimeApplicationResourceEvent?) {
        guard !isTerminated else { return }
        isTerminated = true
        terminalEvent = event
        let currentContinuations = continuations.values
        continuations.removeAll(keepingCapacity: false)
        for continuation in currentContinuations {
            if let event {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private func removeContinuation(_ continuationID: UUID) {
        continuations.removeValue(forKey: continuationID)
    }
}

private actor RuntimeSharePresentationEventSignal {
    typealias Continuation = AsyncStream<RuntimeSharePresentationEvent>.Continuation

    private var terminalEvent: RuntimeSharePresentationEvent?
    private var isTerminated = false
    private var continuations: [UUID: Continuation] = [:]

    func makeStream() -> AsyncStream<RuntimeSharePresentationEvent> {
        let continuationID = UUID()
        return AsyncStream { continuation in
            if isTerminated {
                if let terminalEvent { continuation.yield(terminalEvent) }
                continuation.finish()
                return
            }
            continuations[continuationID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(continuationID) }
            }
        }
    }

    func yield(_ event: RuntimeSharePresentationEvent) {
        guard !isTerminated else { return }
        for continuation in continuations.values { continuation.yield(event) }
    }

    func terminate(with event: RuntimeSharePresentationEvent?) {
        guard !isTerminated else { return }
        isTerminated = true
        terminalEvent = event
        let current = continuations.values
        continuations.removeAll(keepingCapacity: false)
        for continuation in current {
            if let event { continuation.yield(event) }
            continuation.finish()
        }
    }

    private func removeContinuation(_ continuationID: UUID) {
        continuations.removeValue(forKey: continuationID)
    }
}

private final class RuntimeSharePresentationLeaseStorage: Sendable {
    let content: RuntimeResolvedShareContent
    let eventSignal: RuntimeApplicationResourceEventSignal
    let presentationEventSignal: RuntimeSharePresentationEventSignal
    let finishOperation: @Sendable (ShareArtifactOutcomeDTO) async throws -> Void
    let reportPresentedOperation: @Sendable (ShareRouteClassDTO) async throws -> Void
    let finishReportOperation: @Sendable (
        SharePresentationReportDTO
    ) async throws -> ShareArtifactCompletionEvidenceDTO
    let closeOperation: @Sendable () async -> Void

    fileprivate init(
        content: RuntimeResolvedShareContent,
        eventSignal: RuntimeApplicationResourceEventSignal,
        presentationEventSignal: RuntimeSharePresentationEventSignal,
        finish: @escaping @Sendable (ShareArtifactOutcomeDTO) async throws -> Void,
        reportPresented: @escaping @Sendable (ShareRouteClassDTO) async throws -> Void,
        finishReport: @escaping @Sendable (
            SharePresentationReportDTO
        ) async throws -> ShareArtifactCompletionEvidenceDTO,
        close: @escaping @Sendable () async -> Void
    ) {
        self.content = content
        self.eventSignal = eventSignal
        self.presentationEventSignal = presentationEventSignal
        finishOperation = finish
        reportPresentedOperation = reportPresented
        finishReportOperation = finishReport
        closeOperation = close
    }

    deinit {
        let closeOperation = self.closeOperation
        Task {
            await closeOperation()
        }
    }
}

@_spi(RuntimeResourceHost)
public struct RuntimeApplicationResourceLease: Sendable {
    private let storage: RuntimeApplicationResourceLeaseStorage

    public var url: URL { storage.url }
    public func events() async -> AsyncStream<RuntimeApplicationResourceEvent> {
        await storage.eventSignal.makeStream()
    }

    fileprivate init(
        url: URL,
        eventSignal: RuntimeApplicationResourceEventSignal,
        close: @escaping @Sendable () async -> Void
    ) {
        storage = RuntimeApplicationResourceLeaseStorage(
            url: url,
            eventSignal: eventSignal,
            close: close
        )
    }

    public func close() async {
        await storage.closeOperation()
    }
}

@_spi(RuntimeResourceHost)
public struct RuntimeSharePresentationLease: Sendable {
    private let storage: RuntimeSharePresentationLeaseStorage

    public var content: RuntimeResolvedShareContent { storage.content }
    public func events() async -> AsyncStream<RuntimeApplicationResourceEvent> {
        await storage.eventSignal.makeStream()
    }
    public func presentationEvents() async -> AsyncStream<RuntimeSharePresentationEvent> {
        await storage.presentationEventSignal.makeStream()
    }

    fileprivate init(
        content: RuntimeResolvedShareContent,
        eventSignal: RuntimeApplicationResourceEventSignal,
        presentationEventSignal: RuntimeSharePresentationEventSignal,
        finish: @escaping @Sendable (ShareArtifactOutcomeDTO) async throws -> Void,
        reportPresented: @escaping @Sendable (ShareRouteClassDTO) async throws -> Void,
        finishReport: @escaping @Sendable (
            SharePresentationReportDTO
        ) async throws -> ShareArtifactCompletionEvidenceDTO,
        close: @escaping @Sendable () async -> Void
    ) {
        storage = RuntimeSharePresentationLeaseStorage(
            content: content,
            eventSignal: eventSignal,
            presentationEventSignal: presentationEventSignal,
            finish: finish,
            reportPresented: reportPresented,
            finishReport: finishReport,
            close: close
        )
    }

    public func finish(_ outcome: ShareArtifactOutcomeDTO) async throws {
        try await storage.finishOperation(outcome)
    }

    public func reportPresented(on routeClass: ShareRouteClassDTO) async throws {
        try await storage.reportPresentedOperation(routeClass)
    }

    public func finish(
        _ report: SharePresentationReportDTO
    ) async throws -> ShareArtifactCompletionEvidenceDTO {
        try await storage.finishReportOperation(report)
    }

    public func close() async {
        await storage.closeOperation()
    }
}

struct RuntimeIOLease: Sendable {
    let runtimeGeneration: UInt64
    let sourceModuleID: ModuleIdentifier
    let sourceModuleGeneration: UInt64
}

public struct RuntimeIOClient: Sendable {
    public static let unavailable = RuntimeIOClient()

    private let secureValueDataOperation: @Sendable (
        String,
        String
    ) async throws -> Data?
    private let setSecureValueOperation: @Sendable (
        Data,
        String,
        String
    ) async throws -> Void
    private let deleteSecureValueOperation: @Sendable (
        String,
        String
    ) async throws -> Void
    private let readProtectedFileOperation: @Sendable (
        ProtectedPath
    ) async throws -> Data?
    private let writeProtectedFileOperation: @Sendable (
        Data,
        ProtectedPath
    ) async throws -> Void
    private let removeProtectedFileOperation: @Sendable (
        ProtectedPath
    ) async throws -> Void
    private let protectedFileExistsOperation: @Sendable (
        ProtectedPath
    ) async throws -> Bool
    private let protectedFileContentsOperation: @Sendable (
        ProtectedPath,
        String?
    ) async throws -> [ProtectedPath]
    private let nowOperation: @Sendable () async throws -> Date
    private let nextUUIDOperation: @Sendable () async throws -> UUID
    private let clipboardSnapshotOperation: @Sendable () async throws
        -> RuntimeClipboardSnapshot
    private let setClipboardStringOperation: @Sendable (String) async throws -> Void
    private let setClipboardShareOperation: @Sendable (
        String,
        ShareArtifactID
    ) async throws -> ShareArtifactCompletionEvidenceDTO
    private let contactAuthorizationStatusOperation: @Sendable () async throws
        -> ContactAuthorizationDTO
    private let requestContactAccessOperation: @Sendable () async throws -> Bool
    private let fetchSystemContactsOperation: @Sendable () async throws
        -> [SystemContactDTO]
    private let readInboundFileOperation: @Sendable (
        RuntimeInboundFileReadRequest
    ) async throws -> Data
    private let inboundFileImportSessionOperation: @Sendable (
        RuntimeInboundFileImportDelivery
    ) async throws -> RuntimeInboundFileImportSession
    private let applicationResourceSessionOperation: @Sendable (
        ApplicationResource
    ) async throws -> RuntimeApplicationResourceSession
    private let readVerifiedApplicationResourceOperation: @Sendable (
        ApplicationResource,
        Data,
        Int
    ) async throws -> Data
    private let sharePresentationSessionOperation: @Sendable (
        ShareArtifactID
    ) async throws -> RuntimeSharePresentationSession
    private let textSharePresentationSessionOperation: @Sendable (
        String
    ) async throws -> RuntimeSharePresentationSession
    private let textSharePresentationSessionWithArtifactOperation: @Sendable (
        String,
        ShareArtifactID
    ) async throws -> RuntimeSharePresentationSession
    private let registerBundledSystemFontOperation: @Sendable (
        ApplicationResource,
        Data
    ) async throws -> RegisteredFontDTO
    private let systemFontPostScriptNameOperation: @Sendable (
        Data
    ) async throws -> String
    private let registerSystemFontOperation: @Sendable (
        Data
    ) async throws -> RegisteredFontDTO
    private let createShareArtifactOperation: @Sendable (
        Data,
        ShareArtifactID,
        String,
        String
    ) async throws -> Void
    private let storeShareArtifactLinkOperation: @Sendable (
        URL,
        ShareArtifactID
    ) async throws -> Void
    private let removeShareArtifactLinkOperation: @Sendable (
        ShareArtifactID
    ) async throws -> Void
    private let removeShareArtifactOperation: @Sendable (
        ShareArtifactID
    ) async throws -> Void
    private let removeAllShareArtifactsOperation: @Sendable () async throws -> Void

    init(gateway: RuntimeIOGateway, lease: RuntimeIOLease) {
        secureValueDataOperation = {
            try await gateway.secureValueData(
                service: $0,
                account: $1,
                lease: lease
            )
        }
        setSecureValueOperation = {
            try await gateway.setSecureValue(
                $0,
                service: $1,
                account: $2,
                lease: lease
            )
        }
        deleteSecureValueOperation = {
            try await gateway.deleteSecureValue(
                service: $0,
                account: $1,
                lease: lease
            )
        }
        readProtectedFileOperation = {
            try await gateway.readProtectedFile($0, lease: lease)
        }
        writeProtectedFileOperation = {
            try await gateway.writeProtectedFile($0, path: $1, lease: lease)
        }
        removeProtectedFileOperation = {
            try await gateway.removeProtectedFile($0, lease: lease)
        }
        protectedFileExistsOperation = {
            try await gateway.protectedFileExists($0, lease: lease)
        }
        protectedFileContentsOperation = {
            try await gateway.protectedFileContents(
                of: $0,
                matchingExtension: $1,
                lease: lease
            )
        }
        nowOperation = {
            try await gateway.now(lease: lease)
        }
        nextUUIDOperation = {
            try await gateway.nextUUID(lease: lease)
        }
        clipboardSnapshotOperation = {
            try await gateway.clipboardSnapshot(lease: lease)
        }
        setClipboardStringOperation = {
            try await gateway.setClipboardString($0, lease: lease)
        }
        setClipboardShareOperation = {
            try await gateway.setClipboardString(
                $0,
                artifactID: $1,
                lease: lease
            )
        }
        contactAuthorizationStatusOperation = {
            try await gateway.contactAuthorizationStatus(lease: lease)
        }
        requestContactAccessOperation = {
            try await gateway.requestContactAccess(lease: lease)
        }
        fetchSystemContactsOperation = {
            try await gateway.fetchSystemContacts(lease: lease)
        }
        readInboundFileOperation = {
            try await gateway.readInboundFile($0, lease: lease)
        }
        inboundFileImportSessionOperation = {
            try await gateway.inboundFileImportSession(
                delivery: $0,
                lease: lease
            )
        }
        applicationResourceSessionOperation = {
            try await gateway.applicationResourceSession($0, lease: lease)
        }
        readVerifiedApplicationResourceOperation = {
            try await gateway.readVerifiedApplicationResource(
                $0,
                expectedSHA256: $1,
                maximumByteCount: $2,
                lease: lease
            )
        }
        sharePresentationSessionOperation = {
            try await gateway.sharePresentationSession($0, lease: lease)
        }
        textSharePresentationSessionOperation = {
            try await gateway.textSharePresentationSession($0, lease: lease)
        }
        textSharePresentationSessionWithArtifactOperation = {
            try await gateway.textSharePresentationSession(
                $0,
                artifactID: $1,
                lease: lease
            )
        }
        registerBundledSystemFontOperation = {
            try await gateway.registerBundledSystemFont(
                $0,
                expectedSHA256: $1,
                lease: lease
            )
        }
        systemFontPostScriptNameOperation = {
            try await gateway.systemFontPostScriptName($0, lease: lease)
        }
        registerSystemFontOperation = {
            try await gateway.registerSystemFont($0, lease: lease)
        }
        createShareArtifactOperation = {
            try await gateway.createShareArtifact(
                $0,
                artifactID: $1,
                filename: $2,
                fileExtension: $3,
                lease: lease
            )
        }
        storeShareArtifactLinkOperation = {
            try await gateway.storeShareArtifactLink($0, artifactID: $1, lease: lease)
        }
        removeShareArtifactLinkOperation = {
            try await gateway.removeShareArtifactLink(artifactID: $0, lease: lease)
        }
        removeShareArtifactOperation = {
            try await gateway.removeShareArtifact(artifactID: $0, lease: lease)
        }
        removeAllShareArtifactsOperation = {
            try await gateway.removeAllShareArtifacts(lease: lease)
        }
    }

    init(
        secureValueData: @escaping @Sendable (
            String,
            String
        ) async throws -> Data? = { _, _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.secureValueStore
            )
        },
        setSecureValue: @escaping @Sendable (
            Data,
            String,
            String
        ) async throws -> Void = { _, _, _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.secureValueStore
            )
        },
        deleteSecureValue: @escaping @Sendable (
            String,
            String
        ) async throws -> Void = { _, _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.secureValueStore
            )
        },
        readProtectedFile: @escaping @Sendable (
            ProtectedPath
        ) async throws -> Data? = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.protectedFileStore
            )
        },
        writeProtectedFile: @escaping @Sendable (
            Data,
            ProtectedPath
        ) async throws -> Void = { _, _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.protectedFileStore
            )
        },
        removeProtectedFile: @escaping @Sendable (
            ProtectedPath
        ) async throws -> Void = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.protectedFileStore
            )
        },
        protectedFileExists: @escaping @Sendable (
            ProtectedPath
        ) async throws -> Bool = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.protectedFileStore
            )
        },
        protectedFileContents: @escaping @Sendable (
            ProtectedPath,
            String?
        ) async throws -> [ProtectedPath] = { _, _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.protectedFileStore
            )
        },
        now: @escaping @Sendable () async throws -> Date = {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.clock
            )
        },
        nextUUID: @escaping @Sendable () async throws -> UUID = {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.uuid
            )
        },
        clipboardSnapshot: @escaping @Sendable () async throws
            -> RuntimeClipboardSnapshot = {
                throw RuneScribeRuntimeError.serviceUnavailable(
                    RuneScribeServiceIDs.clipboardRead
                )
            },
        setClipboardString: @escaping @Sendable (String) async throws -> Void = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.clipboardWrite
            )
        },
        contactAuthorizationStatus: @escaping @Sendable () async throws
            -> ContactAuthorizationDTO = {
                throw RuneScribeRuntimeError.serviceUnavailable(
                    RuneScribeServiceIDs.contactAccess
                )
            },
        requestContactAccess: @escaping @Sendable () async throws -> Bool = {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.contactAccess
            )
        },
        fetchSystemContacts: @escaping @Sendable () async throws
            -> [SystemContactDTO] = {
                throw RuneScribeRuntimeError.serviceUnavailable(
                    RuneScribeServiceIDs.contactAccess
                )
            },
        readInboundFile: @escaping @Sendable (
            RuntimeInboundFileReadRequest
        ) async throws -> Data = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.inboundFileReader
            )
        },
        inboundFileImportSession: @escaping @Sendable (
            RuntimeInboundFileImportDelivery
        ) async throws -> RuntimeInboundFileImportSession = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.inboundFileReader
            )
        },
        applicationResourceSession: @escaping @Sendable (
            ApplicationResource
        ) async throws -> RuntimeApplicationResourceSession = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.applicationResourceLocator
            )
        },
        readVerifiedApplicationResource: @escaping @Sendable (
            ApplicationResource,
            Data,
            Int
        ) async throws -> Data = { _, _, _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.applicationResourceLocator
            )
        },
        sharePresentationSession: @escaping @Sendable (
            ShareArtifactID
        ) async throws -> RuntimeSharePresentationSession = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.sharePresentation
            )
        },
        textSharePresentationSession: @escaping @Sendable (
            String
        ) async throws -> RuntimeSharePresentationSession = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.sharePresentation
            )
        },
        registerBundledSystemFont: @escaping @Sendable (
            ApplicationResource,
            Data
        ) async throws -> RegisteredFontDTO = { _, _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.applicationResourceLocator
            )
        },
        systemFontPostScriptName: @escaping @Sendable (
            Data
        ) async throws -> String = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.systemFontRegistrar
            )
        },
        registerSystemFont: @escaping @Sendable (
            Data
        ) async throws -> RegisteredFontDTO = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.systemFontRegistrar
            )
        },
        createShareArtifact: @escaping @Sendable (
            Data,
            ShareArtifactID,
            String,
            String
        ) async throws -> Void = { _, _, _, _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.shareArtifactStore
            )
        },
        storeShareArtifactLink: @escaping @Sendable (
            URL,
            ShareArtifactID
        ) async throws -> Void = { _, _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.shareArtifactStore
            )
        },
        removeShareArtifactLink: @escaping @Sendable (
            ShareArtifactID
        ) async throws -> Void = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.shareArtifactStore
            )
        },
        removeShareArtifact: @escaping @Sendable (
            ShareArtifactID
        ) async throws -> Void = { _ in
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.shareArtifactStore
            )
        },
        removeAllShareArtifacts: @escaping @Sendable () async throws -> Void = {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.shareArtifactStore
            )
        }
    ) {
        secureValueDataOperation = secureValueData
        setSecureValueOperation = setSecureValue
        deleteSecureValueOperation = deleteSecureValue
        readProtectedFileOperation = readProtectedFile
        writeProtectedFileOperation = writeProtectedFile
        removeProtectedFileOperation = removeProtectedFile
        protectedFileExistsOperation = protectedFileExists
        protectedFileContentsOperation = protectedFileContents
        nowOperation = now
        nextUUIDOperation = nextUUID
        clipboardSnapshotOperation = clipboardSnapshot
        setClipboardStringOperation = setClipboardString
        setClipboardShareOperation = { value, _ in
            try await setClipboardString(value)
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.sharePresentation
            )
        }
        contactAuthorizationStatusOperation = contactAuthorizationStatus
        requestContactAccessOperation = requestContactAccess
        fetchSystemContactsOperation = fetchSystemContacts
        readInboundFileOperation = readInboundFile
        inboundFileImportSessionOperation = inboundFileImportSession
        applicationResourceSessionOperation = applicationResourceSession
        readVerifiedApplicationResourceOperation = readVerifiedApplicationResource
        sharePresentationSessionOperation = sharePresentationSession
        textSharePresentationSessionOperation = textSharePresentationSession
        textSharePresentationSessionWithArtifactOperation = { text, _ in
            try await textSharePresentationSession(text)
        }
        registerBundledSystemFontOperation = registerBundledSystemFont
        systemFontPostScriptNameOperation = systemFontPostScriptName
        registerSystemFontOperation = registerSystemFont
        createShareArtifactOperation = createShareArtifact
        storeShareArtifactLinkOperation = storeShareArtifactLink
        removeShareArtifactLinkOperation = removeShareArtifactLink
        removeShareArtifactOperation = removeShareArtifact
        removeAllShareArtifactsOperation = removeAllShareArtifacts
    }

    public func secureValueData(
        service: String,
        account: String
    ) async throws -> Data? {
        try await secureValueDataOperation(service, account)
    }

    public func setSecureValue(
        _ data: Data,
        service: String,
        account: String
    ) async throws {
        try await setSecureValueOperation(data, service, account)
    }

    public func deleteSecureValue(
        service: String,
        account: String
    ) async throws {
        try await deleteSecureValueOperation(service, account)
    }

    public func readProtectedFile(_ path: ProtectedPath) async throws -> Data? {
        try await readProtectedFileOperation(path)
    }

    public func writeProtectedFile(
        _ data: Data,
        path: ProtectedPath
    ) async throws {
        try await writeProtectedFileOperation(data, path)
    }

    public func removeProtectedFile(_ path: ProtectedPath) async throws {
        try await removeProtectedFileOperation(path)
    }

    public func protectedFileExists(_ path: ProtectedPath) async throws -> Bool {
        try await protectedFileExistsOperation(path)
    }

    public func protectedFileContents(
        of directory: ProtectedPath,
        matchingExtension fileExtension: String?
    ) async throws -> [ProtectedPath] {
        try await protectedFileContentsOperation(directory, fileExtension)
    }

    public func now() async throws -> Date {
        try await nowOperation()
    }

    public func nextUUID() async throws -> UUID {
        try await nextUUIDOperation()
    }

    public func clipboardSnapshot() async throws -> RuntimeClipboardSnapshot {
        try await clipboardSnapshotOperation()
    }

    public func setClipboardString(_ value: String) async throws {
        try await setClipboardStringOperation(value)
    }

    public func setClipboardString(
        _ value: String,
        artifactID: ShareArtifactID
    ) async throws -> ShareArtifactCompletionEvidenceDTO {
        try await setClipboardShareOperation(value, artifactID)
    }

    public func contactAuthorizationStatus() async throws -> ContactAuthorizationDTO {
        try await contactAuthorizationStatusOperation()
    }

    public func requestContactAccess() async throws -> Bool {
        try await requestContactAccessOperation()
    }

    public func fetchSystemContacts() async throws -> [SystemContactDTO] {
        try await fetchSystemContactsOperation()
    }

    public func readInboundFile(
        _ request: RuntimeInboundFileReadRequest
    ) async throws -> Data {
        try await readInboundFileOperation(request)
    }

    public func inboundFileImportSession(
        delivery: @escaping @Sendable (InboundFileDTO) async throws
            -> ImportResultDTO
    ) async throws -> RuntimeInboundFileImportSession {
        try await inboundFileImportSessionOperation(
            RuntimeInboundFileImportDelivery(operation: delivery)
        )
    }

    public func applicationResourceSession(
        _ resource: ApplicationResource
    ) async throws -> RuntimeApplicationResourceSession {
        try await applicationResourceSessionOperation(resource)
    }

    public func readVerifiedApplicationResource(
        _ resource: ApplicationResource,
        expectedSHA256: Data,
        maximumByteCount: Int
    ) async throws -> Data {
        try await readVerifiedApplicationResourceOperation(
            resource,
            expectedSHA256,
            maximumByteCount
        )
    }

    public func sharePresentationSession(
        artifactID: ShareArtifactID
    ) async throws -> RuntimeSharePresentationSession {
        try await sharePresentationSessionOperation(artifactID)
    }

    public func textSharePresentationSession(
        _ text: String
    ) async throws -> RuntimeSharePresentationSession {
        try await textSharePresentationSessionOperation(text)
    }

    public func textSharePresentationSession(
        _ text: String,
        artifactID: ShareArtifactID
    ) async throws -> RuntimeSharePresentationSession {
        try await textSharePresentationSessionWithArtifactOperation(text, artifactID)
    }

    public func registerBundledSystemFont(
        _ resource: ApplicationResource,
        expectedSHA256: Data
    ) async throws -> RegisteredFontDTO {
        try await registerBundledSystemFontOperation(resource, expectedSHA256)
    }

    public func systemFontPostScriptName(for data: Data) async throws -> String {
        try await systemFontPostScriptNameOperation(data)
    }

    public func registerSystemFont(_ data: Data) async throws -> RegisteredFontDTO {
        try await registerSystemFontOperation(data)
    }

    public func createShareArtifact(
        _ data: Data,
        artifactID: ShareArtifactID,
        filename: String,
        fileExtension: String
    ) async throws {
        try await createShareArtifactOperation(
            data,
            artifactID,
            filename,
            fileExtension
        )
    }

    public func storeShareArtifactLink(
        _ url: URL,
        artifactID: ShareArtifactID
    ) async throws {
        try await storeShareArtifactLinkOperation(url, artifactID)
    }

    public func removeShareArtifactLink(artifactID: ShareArtifactID) async throws {
        try await removeShareArtifactLinkOperation(artifactID)
    }

    public func removeShareArtifact(artifactID: ShareArtifactID) async throws {
        try await removeShareArtifactOperation(artifactID)
    }

    public func removeAllShareArtifacts() async throws {
        try await removeAllShareArtifactsOperation()
    }
}

actor RuntimeIOGateway {
    static let maximumInboundFileByteCount = 16 * 1_024 * 1_024
    static let maximumApplicationResourceByteCount = 16 * 1_024 * 1_024
    static let maximumBundledFontByteCount = 8 * 1_024 * 1_024

    private struct ActiveSource: Sendable {
        let descriptor: ModuleDescriptor
        let generation: UInt64
    }

    private struct ClipboardReadHandlers: Sendable {
        let snapshot: @Sendable () async -> RuntimeClipboardSnapshot
    }

    private struct SecureValueHandlers: Sendable {
        let data: @Sendable (String, String) async throws -> Data?
        let set: @Sendable (Data, String, String) async throws -> Void
        let delete: @Sendable (String, String) async throws -> Void
    }

    private struct ProtectedFileHandlers: Sendable {
        let read: @Sendable (ProtectedPath) async throws -> Data?
        let write: @Sendable (Data, ProtectedPath) async throws -> Void
        let remove: @Sendable (ProtectedPath) async throws -> Void
        let exists: @Sendable (ProtectedPath) async throws -> Bool
        let contents: @Sendable (ProtectedPath, String?) async throws -> [ProtectedPath]
    }

    private struct ClockHandlers: Sendable {
        let now: @Sendable () -> Date
    }

    private struct UUIDHandlers: Sendable {
        let next: @Sendable () -> UUID
    }

    private struct ClipboardWriteHandlers: Sendable {
        let setString: @Sendable (String) async throws -> Void
    }

    private struct ContactHandlers: Sendable {
        let authorizationStatus: @Sendable () async -> ContactAuthorizationDTO
        let requestAccess: @Sendable () async throws -> Bool
        let fetchContacts: @Sendable () async throws -> [SystemContactDTO]
    }

    private struct InboundFileHandlers: Sendable {
        let read: @Sendable (RuntimeInboundFileReadRequest) async throws -> Data
    }

    private struct ResourceHandlers: Sendable {
        let data: @Sendable (ApplicationResource, Int) async throws -> Data
        let url: @Sendable (ApplicationResource) async throws -> URL
    }

    private struct SharePresentationHandlers: Sendable {
        let resolve: @Sendable (ShareArtifactID) async throws -> URL
    }

    private struct ResourceBinding: Sendable {
        let lease: RuntimeIOLease
        let isSharePresentation: Bool
        let shareArtifactID: ShareArtifactID?
        let eventSignal: RuntimeApplicationResourceEventSignal
        let presentationEventSignal: RuntimeSharePresentationEventSignal?
        let shareOperationID: RuntimeOperationID?
        let shareCorrelationID: RuntimeCorrelationID?
        var hasReportedPresentation: Bool
    }

    private struct FontHandlers: Sendable {
        let postScriptName: @Sendable (Data) async throws -> String
        let register: @Sendable (Data) async throws -> RegisteredFontDTO
    }

    private struct ShareArtifactHandlers: Sendable {
        let create: @Sendable (
            Data,
            ShareArtifactID,
            String,
            String
        ) async throws -> Void
        let storeLink: @Sendable (URL, ShareArtifactID) async throws -> Void
        let removeLink: @Sendable (ShareArtifactID) async throws -> Void
        let remove: @Sendable (ShareArtifactID) async throws -> Void
        let removeAll: @Sendable () async throws -> Void
    }

    private let policy: RuntimePolicy
    private let environment: RuntimeEnvironment
    private let operationContextAuthority: RuntimeProgressionOutbox?
    private var runtimeGeneration: UInt64 = 0
    private var runtimeIsActive = false
    private var sources: [ModuleIdentifier: ActiveSource] = [:]
    private var secureValues: SecureValueHandlers?
    private var protectedFiles: ProtectedFileHandlers?
    private var clock: ClockHandlers?
    private var uuid: UUIDHandlers?
    private var clipboardRead: ClipboardReadHandlers?
    private var clipboardWrite: ClipboardWriteHandlers?
    private var contacts: ContactHandlers?
    private var inboundFiles: InboundFileHandlers?
    private var resources: ResourceHandlers?
    private var sharePresentations: SharePresentationHandlers?
    private var fonts: FontHandlers?
    private var shareArtifacts: ShareArtifactHandlers?
    private var nextResourceBindingID: UInt64 = 0
    private var resourceBindings: [UInt64: ResourceBinding] = [:]

    init(
        policy: RuntimePolicy,
        environment: RuntimeEnvironment = .live,
        operationContextAuthority: RuntimeProgressionOutbox? = nil
    ) {
        self.policy = policy
        self.environment = environment
        self.operationContextAuthority = operationContextAuthority
    }

    func install(_ provider: any SecureValueStore) {
        secureValues = SecureValueHandlers(
            data: { try await provider.data(service: $0, account: $1) },
            set: { try await provider.set($0, service: $1, account: $2) },
            delete: { try await provider.delete(service: $0, account: $1) }
        )
    }

    func install(_ provider: any ProtectedFileStore) {
        protectedFiles = ProtectedFileHandlers(
            read: { try await provider.read(relativePath: $0) },
            write: { try await provider.write($0, relativePath: $1) },
            remove: { try await provider.remove(relativePath: $0) },
            exists: { try await provider.exists(relativePath: $0) },
            contents: {
                try await provider.contents(
                    of: $0,
                    matchingExtension: $1
                )
            }
        )
    }

    func install(_ provider: any ClockProviding) {
        clock = ClockHandlers(now: { provider.now() })
    }

    func install(_ provider: any UUIDProviding) {
        uuid = UUIDHandlers(next: { provider.nextUUID() })
    }

    func install(_ provider: any ClipboardReading) {
        clipboardRead = ClipboardReadHandlers(snapshot: {
            let initialChangeCount = await provider.changeCount()
            let initialString = await provider.string()
            let finalChangeCount = await provider.changeCount()
            guard initialChangeCount != finalChangeCount else {
                return RuntimeClipboardSnapshot(
                    changeCount: finalChangeCount,
                    string: initialString
                )
            }
            return RuntimeClipboardSnapshot(
                changeCount: finalChangeCount,
                string: await provider.string()
            )
        })
    }

    func install(_ provider: any ClipboardWriting) {
        clipboardWrite = ClipboardWriteHandlers(
            setString: { try await provider.setString($0) }
        )
    }

    func install(_ provider: any ContactAccessService) {
        contacts = ContactHandlers(
            authorizationStatus: { await provider.authorizationStatus() },
            requestAccess: { try await provider.requestAccess() },
            fetchContacts: { try await provider.fetchContacts() }
        )
    }

    func install(_ provider: any InboundFileReader) {
        inboundFiles = InboundFileHandlers(
            read: {
                try await provider.read(
                    $0.fileURL,
                    requiresSecurityScope: $0.requiresSecurityScopedAccess,
                    maximumByteCount: $0.maximumByteCount
                )
            }
        )
    }

    func install(_ provider: any ApplicationResourceLocator) {
        resources = ResourceHandlers(
            data: {
                try await provider.data(for: $0, maximumByteCount: $1)
            },
            url: { try await provider.url(for: $0) }
        )
    }

    func install(_ provider: any SharePresentationProviding) {
        sharePresentations = SharePresentationHandlers(
            resolve: { try await provider.presentationURL(for: $0) }
        )
    }

    func install(_ provider: any SystemFontRegistrar) {
        fonts = FontHandlers(
            postScriptName: { try await provider.postScriptName(forFontData: $0) },
            register: { try await provider.registerFont($0) }
        )
    }

    func install(_ provider: any ShareArtifactStore) {
        shareArtifacts = ShareArtifactHandlers(
            create: {
                try await provider.create(
                    $0,
                    artifactID: $1,
                    filename: $2,
                    fileExtension: $3
                )
            },
            storeLink: { try await provider.storeLink($0, artifactID: $1) },
            removeLink: { try await provider.removeLink(artifactID: $0) },
            remove: { try await provider.remove(artifactID: $0) },
            removeAll: { try await provider.removeAll() }
        )
    }

    @discardableResult
    func activateRuntime() async -> UInt64 {
        await revokeAllResourceBindings()
        runtimeGeneration &+= 1
        runtimeIsActive = true
        sources.removeAll(keepingCapacity: true)
        return runtimeGeneration
    }

    func deactivateRuntime() async {
        await revokeAllResourceBindings()
        runtimeIsActive = false
        sources.removeAll(keepingCapacity: true)
    }

    func currentGeneration() -> UInt64 {
        runtimeGeneration
    }

    func activateModule(
        descriptor: ModuleDescriptor,
        generation: UInt64
    ) async throws {
        guard runtimeIsActive else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        await revokeResourceBindings(moduleID: descriptor.moduleID)
        sources[descriptor.moduleID] = ActiveSource(
            descriptor: descriptor,
            generation: generation
        )
    }

    func invalidateModule(
        _ moduleID: ModuleIdentifier,
        generation: UInt64
    ) async {
        guard sources[moduleID]?.generation == generation else { return }
        sources.removeValue(forKey: moduleID)
        await revokeResourceBindings(moduleID: moduleID, generation: generation)
    }

    func makeClient(
        sourceModuleID: ModuleIdentifier,
        sourceModuleGeneration: UInt64,
        runtimeGeneration: UInt64
    ) throws -> RuntimeIOClient {
        let lease = RuntimeIOLease(
            runtimeGeneration: runtimeGeneration,
            sourceModuleID: sourceModuleID,
            sourceModuleGeneration: sourceModuleGeneration
        )
        try validateLifecycle(lease)
        return RuntimeIOClient(gateway: self, lease: lease)
    }

    func secureValueData(
        service: String,
        account: String,
        lease: RuntimeIOLease
    ) async throws -> Data? {
        let handler = try authorizedSecureValueHandlers(lease: lease).data
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.secureValueStore,
            operation: { try await handler(service, account) }
        )
    }

    func setSecureValue(
        _ data: Data,
        service: String,
        account: String,
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedSecureValueHandlers(lease: lease).set
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.secureValueStore,
            operation: { try await handler(data, service, account) }
        )
    }

    func deleteSecureValue(
        service: String,
        account: String,
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedSecureValueHandlers(lease: lease).delete
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.secureValueStore,
            operation: { try await handler(service, account) }
        )
    }

    func readProtectedFile(
        _ path: ProtectedPath,
        lease: RuntimeIOLease
    ) async throws -> Data? {
        let handler = try authorizedProtectedFileHandlers(lease: lease).read
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.protectedFileStore,
            operation: { try await handler(path) }
        )
    }

    func writeProtectedFile(
        _ data: Data,
        path: ProtectedPath,
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedProtectedFileHandlers(lease: lease).write
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.protectedFileStore,
            operation: { try await handler(data, path) }
        )
    }

    func removeProtectedFile(
        _ path: ProtectedPath,
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedProtectedFileHandlers(lease: lease).remove
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.protectedFileStore,
            operation: { try await handler(path) }
        )
    }

    func protectedFileExists(
        _ path: ProtectedPath,
        lease: RuntimeIOLease
    ) async throws -> Bool {
        let handler = try authorizedProtectedFileHandlers(lease: lease).exists
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.protectedFileStore,
            operation: { try await handler(path) }
        )
    }

    func protectedFileContents(
        of directory: ProtectedPath,
        matchingExtension fileExtension: String?,
        lease: RuntimeIOLease
    ) async throws -> [ProtectedPath] {
        let handler = try authorizedProtectedFileHandlers(lease: lease).contents
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.protectedFileStore,
            operation: { try await handler(directory, fileExtension) }
        )
    }

    func now(lease: RuntimeIOLease) async throws -> Date {
        let handler = try authorizedClockHandler(lease: lease)
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.clock,
            operation: { handler() }
        )
    }

    func nextUUID(lease: RuntimeIOLease) async throws -> UUID {
        let handler = try authorizedUUIDHandler(lease: lease)
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.uuid,
            operation: { handler() }
        )
    }

    func clipboardSnapshot(
        lease: RuntimeIOLease
    ) async throws -> RuntimeClipboardSnapshot {
        let handler = try authorizedClipboardReadHandler(lease: lease)
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.clipboardRead,
            operation: { await handler() }
        )
    }

    func setClipboardString(
        _ value: String,
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedClipboardWriteHandler(lease: lease)
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.clipboardWrite,
            operation: { try await handler(value) }
        )
    }

    func setClipboardString(
        _ value: String,
        artifactID: ShareArtifactID,
        lease: RuntimeIOLease
    ) async throws -> ShareArtifactCompletionEvidenceDTO {
        guard let operationContextAuthority else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.sharePresentation
            )
        }
        do {
            try await operationContextAuthority.reserveShareCompletion(
                for: artifactID
            )
        } catch ModuleStateStoreError.unavailable {
            // Clipboard utility remains available when optional persistence is
            // absent; the terminal handoff below will surface degraded state.
        }
        let report = try SharePresentationReportDTO(
            routeClass: .clipboard,
            result: .completionUnavailable
        )
        let context = try await operationContextAuthority.issueOperationContext(
            operationID: RuntimeOperationID(
                "\(environment.nextUUID().uuidString.lowercased())-share"
            ),
            correlationID: RuntimeCorrelationID(
                environment.nextUUID().uuidString.lowercased()
            ),
            occurredAtUTC: environment.now(),
            operationIdentifier: "io.share.clipboard.complete",
            runtimeGeneration: lease.runtimeGeneration
        )
        let evidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifactID,
            report: report,
            operationContext: context
        )
        do {
            try await setClipboardString(value, lease: lease)
        } catch {
            await operationContextAuthority.cancelShareCompletionReservation(
                for: artifactID
            )
            throw error
        }
        // Once clipboard utility succeeds, retain the reservation across a
        // transient journal failure so an exact caller retry can finish it.
        try await operationContextAuthority.journalShareCompletion(evidence)
        return evidence
    }

    func contactAuthorizationStatus(
        lease: RuntimeIOLease
    ) async throws -> ContactAuthorizationDTO {
        let handler = try authorizedContactHandlers(lease: lease).authorizationStatus
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.contactAccess,
            operation: { await handler() }
        )
    }

    func requestContactAccess(
        lease: RuntimeIOLease
    ) async throws -> Bool {
        let handler = try authorizedContactHandlers(lease: lease).requestAccess
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.contactAccess,
            operation: { try await handler() }
        )
    }

    func fetchSystemContacts(
        lease: RuntimeIOLease
    ) async throws -> [SystemContactDTO] {
        let handler = try authorizedContactHandlers(lease: lease).fetchContacts
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.contactAccess,
            operation: { try await handler() }
        )
    }

    func readInboundFile(
        _ request: RuntimeInboundFileReadRequest,
        lease: RuntimeIOLease
    ) async throws -> Data {
        let handler = try authorizedInboundFileHandler(lease: lease)
        guard request.fileURL.isFileURL else {
            throw InboundFileReaderError.notFileURL
        }
        guard request.maximumByteCount > 0,
              request.maximumByteCount <= Self.maximumInboundFileByteCount
        else {
            throw InboundFileReaderError.contentTooLarge
        }
        let data = try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.inboundFileReader,
            operation: { try await handler(request) }
        )
        guard data.count <= request.maximumByteCount else {
            throw InboundFileReaderError.contentTooLarge
        }
        return data
    }

    func inboundFileImportSession(
        delivery: RuntimeInboundFileImportDelivery,
        lease: RuntimeIOLease
    ) throws -> RuntimeInboundFileImportSession {
        _ = try authorizedInboundFileImportHandler(lease: lease)
        return RuntimeInboundFileImportSession { [self] fileURL in
            try await importSelectedFile(
                fileURL,
                delivery: delivery,
                lease: lease
            )
        }
    }

    func readHostInboundFile(
        _ request: RuntimeInboundFileReadRequest
    ) async throws -> Data {
        guard runtimeIsActive else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard request.fileURL.isFileURL else {
            throw InboundFileReaderError.notFileURL
        }
        guard request.maximumByteCount > 0,
              request.maximumByteCount <= Self.maximumInboundFileByteCount
        else {
            throw InboundFileReaderError.contentTooLarge
        }
        guard let handler = inboundFiles?.read else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.inboundFileReader
            )
        }
        let generation = runtimeGeneration
        let data = try await handler(request)
        guard runtimeIsActive, runtimeGeneration == generation else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard data.count <= request.maximumByteCount else {
            throw InboundFileReaderError.contentTooLarge
        }
        return data
    }

    func applicationResourceSession(
        _ resource: ApplicationResource,
        lease: RuntimeIOLease
    ) throws -> RuntimeApplicationResourceSession {
        _ = try authorizedResourceHandlers(resource, lease: lease)
        return RuntimeApplicationResourceSession { [self] in
            try await acquireApplicationResource(resource, lease: lease)
        }
    }

    func readVerifiedApplicationResource(
        _ resource: ApplicationResource,
        expectedSHA256: Data,
        maximumByteCount: Int,
        lease: RuntimeIOLease
    ) async throws -> Data {
        let handler = try authorizedResourceHandlers(resource, lease: lease).data
        return try await verifiedApplicationResourceData(
            expectedSHA256: expectedSHA256,
            maximumByteCount: maximumByteCount,
            read: {
                try await self.invoke(
                    lease: lease,
                    serviceID: RuneScribeServiceIDs.applicationResourceLocator,
                    operation: { try await handler(resource, maximumByteCount) }
                )
            }
        )
    }

    func readHostVerifiedApplicationResource(
        _ resource: ApplicationResource,
        expectedSHA256: Data,
        maximumByteCount: Int,
        descriptor: ModuleDescriptor
    ) async throws -> Data {
        let handler = try authorizedHostResourceHandlers(
            resource,
            descriptor: descriptor
        ).data
        return try await verifiedApplicationResourceData(
            expectedSHA256: expectedSHA256,
            maximumByteCount: maximumByteCount,
            read: { try await handler(resource, maximumByteCount) }
        )
    }

    func sharePresentationSession(
        _ artifactID: ShareArtifactID,
        lease: RuntimeIOLease
    ) throws -> RuntimeSharePresentationSession {
        _ = try authorizedSharePresentationHandler(lease: lease)
        return RuntimeSharePresentationSession { [self] in
            try await acquireSharePresentation(artifactID, lease: lease)
        }
    }

    func textSharePresentationSession(
        _ text: String,
        lease: RuntimeIOLease
    ) throws -> RuntimeSharePresentationSession {
        _ = try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.sharePresentation
        )
        return RuntimeSharePresentationSession { [self] in
            try await acquireTextSharePresentation(text, artifactID: nil, lease: lease)
        }
    }

    func textSharePresentationSession(
        _ text: String,
        artifactID: ShareArtifactID,
        lease: RuntimeIOLease
    ) throws -> RuntimeSharePresentationSession {
        _ = try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.sharePresentation
        )
        return RuntimeSharePresentationSession { [self] in
            try await acquireTextSharePresentation(
                text,
                artifactID: artifactID,
                lease: lease
            )
        }
    }

    func registerBundledSystemFont(
        _ resource: ApplicationResource,
        expectedSHA256: Data,
        lease: RuntimeIOLease
    ) async throws -> RegisteredFontDTO {
        let data: Data
        do {
            data = try await readVerifiedApplicationResource(
                resource,
                expectedSHA256: expectedSHA256,
                maximumByteCount: Self.maximumBundledFontByteCount,
                lease: lease,
            )
        } catch let error as RuneScribeRuntimeError {
            throw error
        } catch let failure as RuntimeVerifiedApplicationResourceFailure {
            switch failure {
            case .integrityMismatch:
                throw RuntimeBundledFontFailure.integrityMismatch
            case .invalidMaximumByteCount, .resourceUnavailable, .contentTooLarge:
                throw RuntimeBundledFontFailure.resourceUnavailable
            }
        }
        let fontHandlers = try authorizedFontHandlers(lease: lease)
        let postScriptName: String
        do {
            postScriptName = try await invoke(
                lease: lease,
                serviceID: RuneScribeServiceIDs.systemFontRegistrar,
                operation: { try await fontHandlers.postScriptName(data) }
            )
        } catch let error as RuneScribeRuntimeError {
            throw error
        } catch {
            throw RuntimeBundledFontFailure.unreadableFont
        }
        guard !postScriptName.isEmpty else {
            throw RuntimeBundledFontFailure.unreadableFont
        }
        do {
            let registered = try await invoke(
                lease: lease,
                serviceID: RuneScribeServiceIDs.systemFontRegistrar,
                operation: { try await fontHandlers.register(data) }
            )
            guard !registered.postScriptName.isEmpty else {
                throw RuntimeBundledFontFailure.registrationFailed
            }
            return registered
        } catch let error as RuneScribeRuntimeError {
            throw error
        } catch let error as RuntimeBundledFontFailure {
            throw error
        } catch {
            throw RuntimeBundledFontFailure.registrationFailed
        }
    }

    private func importSelectedFile(
        _ fileURL: URL,
        delivery: RuntimeInboundFileImportDelivery,
        lease: RuntimeIOLease
    ) async throws -> ImportResultDTO {
        let handler = try authorizedInboundFileImportHandler(lease: lease)
        guard fileURL.isFileURL else {
            throw InboundFileReaderError.notFileURL
        }
        let request = RuntimeInboundFileReadRequest(
            fileURL: fileURL,
            requiresSecurityScopedAccess: true,
            maximumByteCount: Self.maximumInboundFileByteCount
        )
        let data: Data
        do {
            data = try await handler(request)
            _ = try authorizedInboundFileImportHandler(lease: lease)
        } catch {
            do {
                _ = try authorizedInboundFileImportHandler(lease: lease)
            } catch let lifecycleOrAuthorizationError {
                throw lifecycleOrAuthorizationError
            }
            throw error
        }
        guard data.count <= Self.maximumInboundFileByteCount else {
            throw InboundFileReaderError.contentTooLarge
        }
        try Task.checkCancellation()
        _ = try authorizedInboundFileImportHandler(lease: lease)

        let input = InboundFileDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: environment.nextUUID()),
                receivedAt: environment.now(),
                source: .fileImporter,
                isColdStart: false
            ),
            data: data,
            declaredContentType: RuneScribeWireFormat.contentType
        )
        do {
            let result = try await delivery.deliver(input)
            _ = try authorizedInboundFileImportHandler(lease: lease)
            return result
        } catch {
            do {
                _ = try authorizedInboundFileImportHandler(lease: lease)
            } catch let lifecycleOrAuthorizationError {
                throw lifecycleOrAuthorizationError
            }
            throw error
        }
    }

    private func acquireApplicationResource(
        _ resource: ApplicationResource,
        lease: RuntimeIOLease
    ) async throws -> RuntimeApplicationResourceLease {
        let handler = try authorizedResourceHandlers(resource, lease: lease).url
        let url = try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.applicationResourceLocator,
            operation: { try await handler(resource) }
        )
        try Task.checkCancellation()

        nextResourceBindingID &+= 1
        let bindingID = nextResourceBindingID
        let eventSignal = RuntimeApplicationResourceEventSignal()
        resourceBindings[bindingID] = ResourceBinding(
            lease: lease,
            isSharePresentation: false,
            shareArtifactID: nil,
            eventSignal: eventSignal,
            presentationEventSignal: nil,
            shareOperationID: nil,
            shareCorrelationID: nil,
            hasReportedPresentation: false
        )
        return RuntimeApplicationResourceLease(
            url: url,
            eventSignal: eventSignal,
            close: { [self] in
                await closeApplicationResourceBinding(bindingID)
            }
        )
    }

    private func acquireSharePresentation(
        _ artifactID: ShareArtifactID,
        lease: RuntimeIOLease
    ) async throws -> RuntimeSharePresentationLease {
        let handler = try authorizedSharePresentationHandler(lease: lease)
        try Task.checkCancellation()

        if let operationContextAuthority {
            do {
                try await operationContextAuthority.reserveShareCompletion(
                    for: artifactID
                )
            } catch ModuleStateStoreError.unavailable {
                // The optional instrumentation store must not disable sharing.
            }
        }

        nextResourceBindingID &+= 1
        let bindingID = nextResourceBindingID
        let eventSignal = RuntimeApplicationResourceEventSignal()
        let presentationEventSignal = RuntimeSharePresentationEventSignal()
        resourceBindings[bindingID] = ResourceBinding(
            lease: lease,
            isSharePresentation: true,
            shareArtifactID: artifactID,
            eventSignal: eventSignal,
            presentationEventSignal: presentationEventSignal,
            shareOperationID: RuntimeOperationID(
                "\(environment.nextUUID().uuidString.lowercased())-share"
            ),
            shareCorrelationID: RuntimeCorrelationID(
                environment.nextUUID().uuidString.lowercased()
            ),
            hasReportedPresentation: false
        )
        do {
            let url = try await invoke(
                lease: lease,
                serviceID: RuneScribeServiceIDs.sharePresentation,
                operation: { try await handler(artifactID) }
            )
            try Task.checkCancellation()
            guard resourceBindings[bindingID] != nil else {
                throw RuneScribeRuntimeError.serviceUnavailable(
                    RuneScribeServiceIDs.sharePresentation
                )
            }
            return RuntimeSharePresentationLease(
                content: .artifact(url),
                eventSignal: eventSignal,
                presentationEventSignal: presentationEventSignal,
                finish: { [self] outcome in
                    try await finishSharePresentationBinding(
                        bindingID,
                        outcome: outcome
                    )
                },
                reportPresented: { [self] routeClass in
                    try await reportSharePresentationBinding(
                        bindingID,
                        routeClass: routeClass
                    )
                },
                finishReport: { [self] report in
                    try await finishSharePresentationBinding(
                        bindingID,
                        report: report
                    )
                },
                close: { [self] in
                    await closeApplicationResourceBinding(bindingID)
                }
            )
        } catch {
            await closeApplicationResourceBinding(bindingID)
            throw error
        }
    }

    private func acquireTextSharePresentation(
        _ text: String,
        artifactID: ShareArtifactID?,
        lease: RuntimeIOLease
    ) async throws -> RuntimeSharePresentationLease {
        _ = try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.sharePresentation
        )
        try Task.checkCancellation()

        if let artifactID, let operationContextAuthority {
            do {
                try await operationContextAuthority.reserveShareCompletion(
                    for: artifactID
                )
            } catch ModuleStateStoreError.unavailable {
                // The optional instrumentation store must not disable sharing.
            }
        }

        nextResourceBindingID &+= 1
        let bindingID = nextResourceBindingID
        let eventSignal = RuntimeApplicationResourceEventSignal()
        let presentationEventSignal = RuntimeSharePresentationEventSignal()
        resourceBindings[bindingID] = ResourceBinding(
            lease: lease,
            isSharePresentation: true,
            shareArtifactID: artifactID,
            eventSignal: eventSignal,
            presentationEventSignal: presentationEventSignal,
            shareOperationID: RuntimeOperationID(
                "\(environment.nextUUID().uuidString.lowercased())-share"
            ),
            shareCorrelationID: RuntimeCorrelationID(
                environment.nextUUID().uuidString.lowercased()
            ),
            hasReportedPresentation: false
        )
        do {
            _ = try validateAuthorization(
                lease,
                serviceID: RuneScribeServiceIDs.sharePresentation
            )
            try Task.checkCancellation()
            return RuntimeSharePresentationLease(
                content: .text(text),
                eventSignal: eventSignal,
                presentationEventSignal: presentationEventSignal,
                finish: { [self] outcome in
                    try await finishSharePresentationBinding(
                        bindingID,
                        outcome: outcome
                    )
                },
                reportPresented: { [self] routeClass in
                    try await reportSharePresentationBinding(
                        bindingID,
                        routeClass: routeClass
                    )
                },
                finishReport: { [self] report in
                    try await finishSharePresentationBinding(
                        bindingID,
                        report: report
                    )
                },
                close: { [self] in
                    await closeApplicationResourceBinding(bindingID)
                }
            )
        } catch {
            await closeApplicationResourceBinding(bindingID)
            throw error
        }
    }

    private func closeApplicationResourceBinding(_ bindingID: UInt64) async {
        guard let binding = resourceBindings.removeValue(forKey: bindingID) else {
            return
        }
        if let artifactID = binding.shareArtifactID {
            await operationContextAuthority?.cancelShareCompletionReservation(
                for: artifactID
            )
        }
        await binding.eventSignal.terminate(with: nil)
        await binding.presentationEventSignal?.terminate(with: nil)
    }

    private func reportSharePresentationBinding(
        _ bindingID: UInt64,
        routeClass: ShareRouteClassDTO
    ) async throws {
        guard var binding = resourceBindings[bindingID],
              binding.isSharePresentation
        else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.sharePresentation
            )
        }
        _ = try validateAuthorization(
            binding.lease,
            serviceID: RuneScribeServiceIDs.sharePresentation
        )
        guard !binding.hasReportedPresentation else { return }
        binding.hasReportedPresentation = true
        resourceBindings[bindingID] = binding
        let report = try SharePresentationReportDTO(
            routeClass: routeClass,
            result: .presented
        )
        await binding.presentationEventSignal?.yield(.presented(report))
    }

    private func finishSharePresentationBinding(
        _ bindingID: UInt64,
        outcome: ShareArtifactOutcomeDTO
    ) async throws {
        guard let binding = resourceBindings[bindingID],
              binding.isSharePresentation
        else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.sharePresentation
            )
        }
        do {
            _ = try validateAuthorization(
                binding.lease,
                serviceID: RuneScribeServiceIDs.sharePresentation
            )
        } catch {
            resourceBindings.removeValue(forKey: bindingID)
            await binding.eventSignal.terminate(with: .revoked)
            await binding.presentationEventSignal?.terminate(with: .revoked)
            throw error
        }
        resourceBindings.removeValue(forKey: bindingID)
        if let artifactID = binding.shareArtifactID {
            await operationContextAuthority?.cancelShareCompletionReservation(
                for: artifactID
            )
        }
        await binding.eventSignal.terminate(with: .completed(outcome))
        await binding.presentationEventSignal?.terminate(with: nil)
    }

    private func finishSharePresentationBinding(
        _ bindingID: UInt64,
        report: SharePresentationReportDTO
    ) async throws -> ShareArtifactCompletionEvidenceDTO {
        guard report.isTerminal else {
            throw ShareCompletionContractError.nonterminalEvidence
        }
        guard let binding = resourceBindings[bindingID],
              binding.isSharePresentation,
              let artifactID = binding.shareArtifactID,
              let operationID = binding.shareOperationID,
              let correlationID = binding.shareCorrelationID,
              let operationContextAuthority
        else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.sharePresentation
            )
        }
        do {
            _ = try validateAuthorization(
                binding.lease,
                serviceID: RuneScribeServiceIDs.sharePresentation
            )
        } catch {
            resourceBindings.removeValue(forKey: bindingID)
            await binding.eventSignal.terminate(with: .revoked)
            await binding.presentationEventSignal?.terminate(with: .revoked)
            throw error
        }
        let context = try await operationContextAuthority.issueOperationContext(
            operationID: operationID,
            correlationID: correlationID,
            occurredAtUTC: environment.now(),
            operationIdentifier: "io.share.presentation.complete",
            runtimeGeneration: binding.lease.runtimeGeneration
        )
        let evidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifactID,
            report: report,
            operationContext: context
        )
        // A transient journal failure leaves the binding and its reservation
        // intact so the exact terminal callback can be retried.
        try await operationContextAuthority.journalShareCompletion(evidence)
        resourceBindings.removeValue(forKey: bindingID)
        await binding.eventSignal.terminate(
            with: .completed(legacyOutcome(for: report))
        )
        await binding.presentationEventSignal?.terminate(
            with: .completed(evidence)
        )
        return evidence
    }

    private func legacyOutcome(
        for report: SharePresentationReportDTO
    ) -> ShareArtifactOutcomeDTO {
        switch report.result {
        case .sentConfirmed:
            .messageSent(
                requiredAttachmentAccepted:
                    report.requiredAttachmentAccepted ?? false
            )
        case .completedBySystem:
            .handedOff
        case .failed:
            .failed
        case .cancelled, .completionUnavailable, .presented:
            .cancelled
        }
    }

    func activeApplicationResourceBindingCount() -> Int {
        resourceBindings.count
    }

    private func revokeAllResourceBindings() async {
        let bindings = resourceBindings.values
        resourceBindings.removeAll(keepingCapacity: true)
        for binding in bindings {
            if let artifactID = binding.shareArtifactID {
                await operationContextAuthority?.cancelShareCompletionReservation(
                    for: artifactID
                )
            }
            await binding.eventSignal.terminate(with: .revoked)
            await binding.presentationEventSignal?.terminate(with: .revoked)
        }
    }

    private func revokeResourceBindings(
        moduleID: ModuleIdentifier,
        generation: UInt64? = nil
    ) async {
        let revokedIDs: [UInt64] = resourceBindings.compactMap { entry in
            let bindingID = entry.key
            let binding = entry.value
            guard binding.lease.sourceModuleID == moduleID,
                  generation == nil
                    || binding.lease.sourceModuleGeneration == generation
            else { return nil }
            return bindingID
        }
        for bindingID in revokedIDs {
            guard let binding = resourceBindings.removeValue(forKey: bindingID) else {
                continue
            }
            if let artifactID = binding.shareArtifactID {
                await operationContextAuthority?.cancelShareCompletionReservation(
                    for: artifactID
                )
            }
            await binding.eventSignal.terminate(with: .revoked)
            await binding.presentationEventSignal?.terminate(with: .revoked)
        }
    }

    private func revokeSharePresentationBindings(
        artifactID: ShareArtifactID
    ) async {
        let revokedIDs = resourceBindings.compactMap { entry in
            entry.value.shareArtifactID == artifactID ? entry.key : nil
        }
        for bindingID in revokedIDs {
            guard let binding = resourceBindings.removeValue(forKey: bindingID) else {
                continue
            }
            if let artifactID = binding.shareArtifactID {
                await operationContextAuthority?.cancelShareCompletionReservation(
                    for: artifactID
                )
            }
            await binding.eventSignal.terminate(with: .revoked)
            await binding.presentationEventSignal?.terminate(with: .revoked)
        }
    }

    private func revokeAllSharePresentationBindings() async {
        let revokedIDs = resourceBindings.compactMap { entry in
            entry.value.isSharePresentation ? entry.key : nil
        }
        for bindingID in revokedIDs {
            guard let binding = resourceBindings.removeValue(forKey: bindingID) else {
                continue
            }
            if let artifactID = binding.shareArtifactID {
                await operationContextAuthority?.cancelShareCompletionReservation(
                    for: artifactID
                )
            }
            await binding.eventSignal.terminate(with: .revoked)
            await binding.presentationEventSignal?.terminate(with: .revoked)
        }
    }

    func systemFontPostScriptName(
        _ data: Data,
        lease: RuntimeIOLease
    ) async throws -> String {
        let handler = try authorizedFontHandlers(lease: lease).postScriptName
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.systemFontRegistrar,
            operation: { try await handler(data) }
        )
    }

    func registerSystemFont(
        _ data: Data,
        lease: RuntimeIOLease
    ) async throws -> RegisteredFontDTO {
        let handler = try authorizedFontHandlers(lease: lease).register
        return try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.systemFontRegistrar,
            operation: { try await handler(data) }
        )
    }

    func createShareArtifact(
        _ data: Data,
        artifactID: ShareArtifactID,
        filename: String,
        fileExtension: String,
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedShareArtifactHandlers(lease: lease).create
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.shareArtifactStore,
            operation: {
                try await handler(data, artifactID, filename, fileExtension)
            }
        )
    }

    func storeShareArtifactLink(
        _ url: URL,
        artifactID: ShareArtifactID,
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedShareArtifactHandlers(lease: lease).storeLink
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.shareArtifactStore,
            operation: { try await handler(url, artifactID) }
        )
    }

    func removeShareArtifactLink(
        artifactID: ShareArtifactID,
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedShareArtifactHandlers(lease: lease).removeLink
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.shareArtifactStore,
            operation: { try await handler(artifactID) }
        )
        await revokeSharePresentationBindings(artifactID: artifactID)
    }

    func removeShareArtifact(
        artifactID: ShareArtifactID,
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedShareArtifactHandlers(lease: lease).remove
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.shareArtifactStore,
            operation: { try await handler(artifactID) }
        )
        await revokeSharePresentationBindings(artifactID: artifactID)
    }

    func removeAllShareArtifacts(
        lease: RuntimeIOLease
    ) async throws {
        let handler = try authorizedShareArtifactHandlers(lease: lease).removeAll
        try await invoke(
            lease: lease,
            serviceID: RuneScribeServiceIDs.shareArtifactStore,
            operation: { try await handler() }
        )
        await revokeAllSharePresentationBindings()
    }

    private func authorizedClipboardReadHandler(
        lease: RuntimeIOLease
    ) throws -> @Sendable () async -> RuntimeClipboardSnapshot {
        try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.clipboardRead
        )
        guard let handler = clipboardRead?.snapshot else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.clipboardRead
            )
        }
        return handler
    }

    private func authorizedSecureValueHandlers(
        lease: RuntimeIOLease
    ) throws -> SecureValueHandlers {
        try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.secureValueStore
        )
        guard let secureValues else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.secureValueStore
            )
        }
        return secureValues
    }

    private func authorizedProtectedFileHandlers(
        lease: RuntimeIOLease
    ) throws -> ProtectedFileHandlers {
        try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.protectedFileStore
        )
        guard let protectedFiles else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.protectedFileStore
            )
        }
        return protectedFiles
    }

    private func authorizedClockHandler(
        lease: RuntimeIOLease
    ) throws -> @Sendable () -> Date {
        try validateAuthorization(lease, serviceID: RuneScribeServiceIDs.clock)
        guard let handler = clock?.now else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.clock
            )
        }
        return handler
    }

    private func authorizedUUIDHandler(
        lease: RuntimeIOLease
    ) throws -> @Sendable () -> UUID {
        try validateAuthorization(lease, serviceID: RuneScribeServiceIDs.uuid)
        guard let handler = uuid?.next else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.uuid
            )
        }
        return handler
    }

    private func authorizedClipboardWriteHandler(
        lease: RuntimeIOLease
    ) throws -> @Sendable (String) async throws -> Void {
        try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.clipboardWrite
        )
        guard let handler = clipboardWrite?.setString else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.clipboardWrite
            )
        }
        return handler
    }

    private func authorizedContactHandlers(
        lease: RuntimeIOLease
    ) throws -> ContactHandlers {
        try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.contactAccess
        )
        guard let contacts else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.contactAccess
            )
        }
        return contacts
    }

    private func authorizedInboundFileHandler(
        lease: RuntimeIOLease
    ) throws -> @Sendable (RuntimeInboundFileReadRequest) async throws -> Data {
        try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.inboundFileReader
        )
        guard let handler = inboundFiles?.read else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.inboundFileReader
            )
        }
        return handler
    }

    private func authorizedInboundFileImportHandler(
        lease: RuntimeIOLease
    ) throws -> @Sendable (RuntimeInboundFileReadRequest) async throws -> Data {
        let source = try validateLifecycle(lease)
        let serviceID = RuneScribeServiceIDs.inboundFileReader
        guard source.descriptor.requestedCapabilities.contains(
            RuneScribeCapabilities.fileImportUI
        ) else {
            throw RuneScribeRuntimeError.serviceCapabilityMissing(
                moduleID: lease.sourceModuleID,
                service: serviceID
            )
        }
        guard source.descriptor.role == RuneScribeRoles.primaryUI,
              policy.capabilities.allows(
                RuneScribeCapabilities.fileImportUI,
                for: source.descriptor.policyClass
              )
        else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: lease.sourceModuleID,
                service: serviceID
            )
        }
        guard let handler = inboundFiles?.read else {
            throw RuneScribeRuntimeError.serviceUnavailable(serviceID)
        }
        return handler
    }

    private func authorizedResourceHandlers(
        _ resource: ApplicationResource,
        lease: RuntimeIOLease
    ) throws -> ResourceHandlers {
        let source = try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.applicationResourceLocator
        )
        guard source.descriptor.requiredResources.contains(resource) else {
            throw RuneScribeRuntimeError.resourceNotDeclared(
                moduleID: lease.sourceModuleID,
                resource: resource
            )
        }
        guard resource.ownerModuleID == nil
                || resource.ownerModuleID == source.descriptor.moduleID
        else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: lease.sourceModuleID,
                service: RuneScribeServiceIDs.applicationResourceLocator
            )
        }
        guard let resources else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.applicationResourceLocator
            )
        }
        return resources
    }

    private func authorizedHostResourceHandlers(
        _ resource: ApplicationResource,
        descriptor: ModuleDescriptor
    ) throws -> ResourceHandlers {
        let serviceID = RuneScribeServiceIDs.applicationResourceLocator
        guard descriptor.requiredServices.contains(serviceID) else {
            throw RuneScribeRuntimeError.serviceNotDeclared(
                moduleID: descriptor.moduleID,
                service: serviceID
            )
        }
        guard let rule = policy.services.rule(for: serviceID) else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: descriptor.moduleID,
                service: serviceID
            )
        }
        guard descriptor.requestedCapabilities.contains(rule.requiredCapability) else {
            throw RuneScribeRuntimeError.serviceCapabilityMissing(
                moduleID: descriptor.moduleID,
                service: serviceID
            )
        }
        guard policy.capabilities.allows(
            rule.requiredCapability,
            for: descriptor.policyClass
        ), rule.allowsConsumer(descriptor) else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: descriptor.moduleID,
                service: serviceID
            )
        }
        guard descriptor.requiredResources.contains(resource) else {
            throw RuneScribeRuntimeError.resourceNotDeclared(
                moduleID: descriptor.moduleID,
                resource: resource
            )
        }
        guard resource.ownerModuleID == descriptor.moduleID else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: descriptor.moduleID,
                service: serviceID
            )
        }
        guard let resources else {
            throw RuneScribeRuntimeError.serviceUnavailable(serviceID)
        }
        return resources
    }

    private func verifiedApplicationResourceData(
        expectedSHA256: Data,
        maximumByteCount: Int,
        read: @Sendable () async throws -> Data
    ) async throws -> Data {
        guard maximumByteCount > 0,
              maximumByteCount <= Self.maximumApplicationResourceByteCount
        else {
            throw RuntimeVerifiedApplicationResourceFailure.invalidMaximumByteCount
        }
        let value: Data
        do {
            value = try await read()
        } catch let error as RuneScribeRuntimeError {
            throw error
        } catch let failure as RuntimeVerifiedApplicationResourceFailure {
            throw failure
        } catch let readError as ApplicationResourceReadError {
            switch readError {
            case .invalidMaximumByteCount:
                throw RuntimeVerifiedApplicationResourceFailure.invalidMaximumByteCount
            case .contentTooLarge:
                throw RuntimeVerifiedApplicationResourceFailure.contentTooLarge
            }
        } catch {
            throw RuntimeVerifiedApplicationResourceFailure.resourceUnavailable
        }
        guard value.count <= maximumByteCount else {
            throw RuntimeVerifiedApplicationResourceFailure.contentTooLarge
        }
        guard RuntimeBundledResourceIntegrity.matchesSHA256(
            expectedSHA256,
            data: value
        ) else {
            throw RuntimeVerifiedApplicationResourceFailure.integrityMismatch
        }
        return value
    }

    private func authorizedSharePresentationHandler(
        lease: RuntimeIOLease
    ) throws -> @Sendable (ShareArtifactID) async throws -> URL {
        try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.sharePresentation
        )
        guard let handler = sharePresentations?.resolve else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.sharePresentation
            )
        }
        return handler
    }

    private func authorizedFontHandlers(
        lease: RuntimeIOLease
    ) throws -> FontHandlers {
        try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.systemFontRegistrar
        )
        guard let fonts else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.systemFontRegistrar
            )
        }
        return fonts
    }

    private func authorizedShareArtifactHandlers(
        lease: RuntimeIOLease
    ) throws -> ShareArtifactHandlers {
        try validateAuthorization(
            lease,
            serviceID: RuneScribeServiceIDs.shareArtifactStore
        )
        guard let shareArtifacts else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.shareArtifactStore
            )
        }
        return shareArtifacts
    }

    private func invoke<Result: Sendable>(
        lease: RuntimeIOLease,
        serviceID: ServiceIdentifier,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        do {
            let result = try await operation()
            try validateAuthorization(lease, serviceID: serviceID)
            return result
        } catch {
            do {
                try validateAuthorization(lease, serviceID: serviceID)
            } catch let lifecycleOrAuthorizationError {
                throw lifecycleOrAuthorizationError
            }
            throw error
        }
    }

    @discardableResult
    private func validateAuthorization(
        _ lease: RuntimeIOLease,
        serviceID: ServiceIdentifier
    ) throws -> ActiveSource {
        let source = try validateLifecycle(lease)
        guard source.descriptor.requiredServices.contains(serviceID) else {
            throw RuneScribeRuntimeError.serviceNotDeclared(
                moduleID: lease.sourceModuleID,
                service: serviceID
            )
        }
        guard let rule = policy.services.rule(for: serviceID) else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: lease.sourceModuleID,
                service: serviceID
            )
        }
        guard source.descriptor.requestedCapabilities.contains(
            rule.requiredCapability
        ) else {
            throw RuneScribeRuntimeError.serviceCapabilityMissing(
                moduleID: lease.sourceModuleID,
                service: serviceID
            )
        }
        guard policy.capabilities.allows(
            rule.requiredCapability,
            for: source.descriptor.policyClass
        ), rule.allowsConsumer(source.descriptor) else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: lease.sourceModuleID,
                service: serviceID
            )
        }
        return source
    }

    @discardableResult
    private func validateLifecycle(
        _ lease: RuntimeIOLease
    ) throws -> ActiveSource {
        guard runtimeIsActive else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard runtimeGeneration == lease.runtimeGeneration else {
            throw RuneScribeRuntimeError.staleClient(lease.sourceModuleID)
        }
        guard let source = sources[lease.sourceModuleID],
              source.generation == lease.sourceModuleGeneration
        else {
            throw RuneScribeRuntimeError.staleClient(lease.sourceModuleID)
        }
        return source
    }
}
