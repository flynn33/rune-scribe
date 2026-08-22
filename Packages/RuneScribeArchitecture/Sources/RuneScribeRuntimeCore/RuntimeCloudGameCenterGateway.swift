import Foundation
import RuneScribeContracts

public enum RuntimeCloudSyncOperation: String, Codable, CaseIterable, Sendable {
    case accountState = "account-state"
    case fetchPrivateProgression = "fetch-private-progression"
    case savePrivateProgression = "save-private-progression"
}

public struct RuntimeCloudSyncOperationSession: Equatable, Sendable {
    public let operationID: RuntimeOperationID
    public let correlationID: RuntimeCorrelationID
    public let runtimeGeneration: UInt64
    public let issuedAt: Date
    public let operation: RuntimeCloudSyncOperation

    init(
        operationID: RuntimeOperationID,
        correlationID: RuntimeCorrelationID,
        runtimeGeneration: UInt64,
        issuedAt: Date,
        operation: RuntimeCloudSyncOperation
    ) {
        self.operationID = operationID
        self.correlationID = correlationID
        self.runtimeGeneration = runtimeGeneration
        self.issuedAt = issuedAt
        self.operation = operation
    }
}

public enum RuntimeGameCenterOperation: String, Codable, CaseIterable, Sendable {
    case authenticationState = "authentication-state"
    case accountScope = "account-scope"
    case requestAuthentication = "request-authentication"
    case reportAchievements = "report-achievements"
}

public struct RuntimeGameCenterOperationSession: Equatable, Sendable {
    public let operationID: RuntimeOperationID
    public let correlationID: RuntimeCorrelationID
    public let runtimeGeneration: UInt64
    public let issuedAt: Date
    public let operation: RuntimeGameCenterOperation

    init(
        operationID: RuntimeOperationID,
        correlationID: RuntimeCorrelationID,
        runtimeGeneration: UInt64,
        issuedAt: Date,
        operation: RuntimeGameCenterOperation
    ) {
        self.operationID = operationID
        self.correlationID = correlationID
        self.runtimeGeneration = runtimeGeneration
        self.issuedAt = issuedAt
        self.operation = operation
    }
}

public struct RuntimeCloudSyncClient: Sendable {
    private let gateway: RuntimeCloudGameCenterGateway?
    private let generation: UInt64

    init(gateway: RuntimeCloudGameCenterGateway, generation: UInt64) {
        self.gateway = gateway
        self.generation = generation
    }

    public func issueSession(
        for operation: RuntimeCloudSyncOperation
    ) async throws -> RuntimeCloudSyncOperationSession {
        guard let gateway else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await gateway.issueCloudSession(operation, generation: generation)
    }

    public func accountState(
        session: RuntimeCloudSyncOperationSession
    ) async throws -> CloudAccountStateDTO {
        guard let gateway else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await gateway.cloudAccountState(session: session, generation: generation)
    }

    public func fetchPrivateProgression(
        session: RuntimeCloudSyncOperationSession
    ) async throws -> CloudSyncFetchResultDTO {
        guard let gateway else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await gateway.cloudFetch(session: session, generation: generation)
    }

    public func savePrivateProgression(
        _ request: CloudSyncSaveRequestDTO,
        session: RuntimeCloudSyncOperationSession
    ) async throws -> CloudSyncSaveResultDTO {
        guard let gateway else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await gateway.cloudSave(
            request,
            session: session,
            generation: generation
        )
    }
}

public struct RuntimeGameCenterClient: Sendable {
    private let gateway: RuntimeCloudGameCenterGateway?
    private let generation: UInt64

    init(gateway: RuntimeCloudGameCenterGateway, generation: UInt64) {
        self.gateway = gateway
        self.generation = generation
    }

    public func issueSession(
        for operation: RuntimeGameCenterOperation
    ) async throws -> RuntimeGameCenterOperationSession {
        guard let gateway else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await gateway.issueGameCenterSession(operation, generation: generation)
    }

    public func authenticationState(
        session: RuntimeGameCenterOperationSession
    ) async throws -> GameCenterAuthenticationStateDTO {
        guard let gateway else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await gateway.gameCenterAuthenticationState(
            session: session,
            generation: generation
        )
    }

    public func requestAuthentication(
        session: RuntimeGameCenterOperationSession
    ) async throws -> GameCenterAuthenticationStateDTO {
        guard let gateway else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await gateway.gameCenterRequestAuthentication(
            session: session,
            generation: generation
        )
    }

    public func accountScopeDigest(
        session: RuntimeGameCenterOperationSession
    ) async throws -> GameCenterAccountScopeDigestDTO? {
        guard let gateway else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await gateway.gameCenterAccountScopeDigest(
            session: session,
            generation: generation
        )
    }

    public func report(
        _ achievements: [GameCenterAchievementReportDTO],
        session: RuntimeGameCenterOperationSession
    ) async throws {
        guard let gateway else { throw RuneScribeRuntimeError.runtimeNotRunning }
        try await gateway.gameCenterReport(
            achievements,
            session: session,
            generation: generation
        )
    }
}

actor RuntimeCloudGameCenterGateway {
    private let environment: RuntimeEnvironment
    private var cloudTransport: (any CloudSyncTransport)?
    private var gameCenterReporting: (any GameCenterReporting)?
    private var generation: UInt64 = 0
    private var active = false

    init(environment: RuntimeEnvironment) {
        self.environment = environment
    }

    func install(_ value: any CloudSyncTransport) throws {
        guard !active else { throw RuneScribeRuntimeError.runtimeBusy }
        guard cloudTransport == nil else {
            throw RuneScribeRuntimeError.duplicateService(
                RuneScribeServiceIDs.cloudSyncTransport
            )
        }
        cloudTransport = value
    }

    func install(_ value: any GameCenterReporting) throws {
        guard !active else { throw RuneScribeRuntimeError.runtimeBusy }
        guard gameCenterReporting == nil else {
            throw RuneScribeRuntimeError.duplicateService(
                RuneScribeServiceIDs.gameCenterReporting
            )
        }
        gameCenterReporting = value
    }

    func activateRuntime() {
        generation &+= 1
        active = true
    }

    func deactivateRuntime() {
        active = false
    }

    func cloudClient() throws -> RuntimeCloudSyncClient {
        try validate(generation, serviceID: RuneScribeServiceIDs.cloudSyncTransport)
        return RuntimeCloudSyncClient(gateway: self, generation: generation)
    }

    func gameCenterClient() throws -> RuntimeGameCenterClient {
        try validate(generation, serviceID: RuneScribeServiceIDs.gameCenterReporting)
        return RuntimeGameCenterClient(gateway: self, generation: generation)
    }

    func issueCloudSession(
        _ operation: RuntimeCloudSyncOperation,
        generation: UInt64
    ) throws -> RuntimeCloudSyncOperationSession {
        try validate(generation, serviceID: RuneScribeServiceIDs.cloudSyncTransport)
        return RuntimeCloudSyncOperationSession(
            operationID: operationID(prefix: "cloud"),
            correlationID: correlationID(prefix: "cloud"),
            runtimeGeneration: generation,
            issuedAt: environment.now(),
            operation: operation
        )
    }

    func issueGameCenterSession(
        _ operation: RuntimeGameCenterOperation,
        generation: UInt64
    ) throws -> RuntimeGameCenterOperationSession {
        try validate(generation, serviceID: RuneScribeServiceIDs.gameCenterReporting)
        return RuntimeGameCenterOperationSession(
            operationID: operationID(prefix: "game-center"),
            correlationID: correlationID(prefix: "game-center"),
            runtimeGeneration: generation,
            issuedAt: environment.now(),
            operation: operation
        )
    }

    func cloudAccountState(
        session: RuntimeCloudSyncOperationSession,
        generation: UInt64
    ) async throws -> CloudAccountStateDTO {
        try validate(session, operation: .accountState, generation: generation)
        guard let cloudTransport else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.cloudSyncTransport
            )
        }
        let result = try await cloudTransport.accountState()
        try validate(session, operation: .accountState, generation: generation)
        return result
    }

    func cloudFetch(
        session: RuntimeCloudSyncOperationSession,
        generation: UInt64
    ) async throws -> CloudSyncFetchResultDTO {
        try validate(session, operation: .fetchPrivateProgression, generation: generation)
        guard let cloudTransport else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.cloudSyncTransport
            )
        }
        let result = try await cloudTransport.fetchPrivateProgression()
        try validate(session, operation: .fetchPrivateProgression, generation: generation)
        return result
    }

    func cloudSave(
        _ request: CloudSyncSaveRequestDTO,
        session: RuntimeCloudSyncOperationSession,
        generation: UInt64
    ) async throws -> CloudSyncSaveResultDTO {
        try validate(session, operation: .savePrivateProgression, generation: generation)
        guard let cloudTransport else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.cloudSyncTransport
            )
        }
        let result = try await cloudTransport.savePrivateProgression(request)
        try validate(session, operation: .savePrivateProgression, generation: generation)
        return result
    }

    func gameCenterAuthenticationState(
        session: RuntimeGameCenterOperationSession,
        generation: UInt64
    ) async throws -> GameCenterAuthenticationStateDTO {
        try validate(session, operation: .authenticationState, generation: generation)
        guard let gameCenterReporting else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.gameCenterReporting
            )
        }
        let result = await gameCenterReporting.authenticationState()
        try validate(session, operation: .authenticationState, generation: generation)
        return result
    }

    func gameCenterRequestAuthentication(
        session: RuntimeGameCenterOperationSession,
        generation: UInt64
    ) async throws -> GameCenterAuthenticationStateDTO {
        try validate(session, operation: .requestAuthentication, generation: generation)
        guard let gameCenterReporting else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.gameCenterReporting
            )
        }
        let result = try await gameCenterReporting.requestAuthentication()
        try validate(session, operation: .requestAuthentication, generation: generation)
        return result
    }

    func gameCenterAccountScopeDigest(
        session: RuntimeGameCenterOperationSession,
        generation: UInt64
    ) async throws -> GameCenterAccountScopeDigestDTO? {
        try validate(session, operation: .accountScope, generation: generation)
        guard let gameCenterReporting else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.gameCenterReporting
            )
        }
        let result = await gameCenterReporting.accountScopeDigest()
        try validate(session, operation: .accountScope, generation: generation)
        return result
    }

    func gameCenterReport(
        _ achievements: [GameCenterAchievementReportDTO],
        session: RuntimeGameCenterOperationSession,
        generation: UInt64
    ) async throws {
        try validate(session, operation: .reportAchievements, generation: generation)
        guard let gameCenterReporting else {
            throw RuneScribeRuntimeError.serviceUnavailable(
                RuneScribeServiceIDs.gameCenterReporting
            )
        }
        try await gameCenterReporting.report(achievements)
        try validate(session, operation: .reportAchievements, generation: generation)
    }

    private func validate(
        _ session: RuntimeCloudSyncOperationSession,
        operation: RuntimeCloudSyncOperation,
        generation: UInt64
    ) throws {
        guard session.runtimeGeneration == generation, session.operation == operation else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        try validate(generation, serviceID: RuneScribeServiceIDs.cloudSyncTransport)
    }

    private func validate(
        _ session: RuntimeGameCenterOperationSession,
        operation: RuntimeGameCenterOperation,
        generation: UInt64
    ) throws {
        guard session.runtimeGeneration == generation, session.operation == operation else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        try validate(generation, serviceID: RuneScribeServiceIDs.gameCenterReporting)
    }

    private func validate(_ expected: UInt64, serviceID: ServiceIdentifier) throws {
        guard active, generation == expected else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        if serviceID == RuneScribeServiceIDs.cloudSyncTransport {
            guard cloudTransport != nil else {
                throw RuneScribeRuntimeError.serviceUnavailable(serviceID)
            }
        } else if serviceID == RuneScribeServiceIDs.gameCenterReporting {
            guard gameCenterReporting != nil else {
                throw RuneScribeRuntimeError.serviceUnavailable(serviceID)
            }
        }
    }

    private func operationID(prefix: String) -> RuntimeOperationID {
        RuntimeOperationID("runtime.\(prefix).\(environment.nextUUID().uuidString.lowercased())")
    }

    private func correlationID(prefix: String) -> RuntimeCorrelationID {
        RuntimeCorrelationID(
            "runtime.\(prefix).correlation.\(environment.nextUUID().uuidString.lowercased())"
        )
    }
}
