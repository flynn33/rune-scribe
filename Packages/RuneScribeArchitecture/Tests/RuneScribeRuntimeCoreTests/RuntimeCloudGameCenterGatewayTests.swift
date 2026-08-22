import Foundation
import RuneScribeContracts
@_spi(RuntimeOperationAuthority) @testable import RuneScribeRuntimeCore
import XCTest

final class RuntimeCloudGameCenterGatewayTests: XCTestCase {
    func testCloudTransportRequiresMatchingRuntimeOwnedSessionAndRevokesOnStop() async throws {
        let payload = Data("{\"schemaVersion\":1}".utf8)
        let adapter = CloudTransportProbe(
            accountState: try CloudAccountStateDTO(
                state: .available,
                accountScopeDigest: CloudAccountScopeDigestDTO(
                    rawValue: String(repeating: "a", count: 64)
                )!
            ),
            fetch: try CloudSyncFetchResultDTO(payload: payload, changeTag: "change-1")
        )
        let gateway = RuntimeCloudGameCenterGateway(environment: deterministicEnvironment())
        try await gateway.install(adapter)
        await gateway.activateRuntime()
        let client = try await gateway.cloudClient()

        let accountSession = try await client.issueSession(for: .accountState)
        let accountState = try await client.accountState(session: accountSession)
        XCTAssertEqual(accountState.state, .available)
        XCTAssertEqual(accountSession.issuedAt, Date(timeIntervalSince1970: 1_000))

        do {
            _ = try await client.fetchPrivateProgression(session: accountSession)
            XCTFail("Expected operation-scoped session validation")
        } catch {
            XCTAssertEqual(error as? RuneScribeRuntimeError, .runtimeNotRunning)
        }

        let fetchSession = try await client.issueSession(for: .fetchPrivateProgression)
        let fetched = try await client.fetchPrivateProgression(session: fetchSession)
        XCTAssertEqual(fetched.payload, payload)
        let saveSession = try await client.issueSession(for: .savePrivateProgression)
        let saved = try await client.savePrivateProgression(
            CloudSyncSaveRequestDTO(payload: payload, expectedChangeTag: "change-1"),
            session: saveSession
        )
        XCTAssertEqual(saved.changeTag, "change-2")
        let fetchCount = await adapter.fetchCount()
        let savedPayloads = await adapter.savedPayloads()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(savedPayloads, [payload])

        await gateway.deactivateRuntime()
        do {
            _ = try await client.accountState(session: accountSession)
            XCTFail("Expected a stopped runtime to revoke the client")
        } catch {
            XCTAssertEqual(error as? RuneScribeRuntimeError, .runtimeNotRunning)
        }
    }

    func testGameCenterTransportHasStatusAndReportingOnlyWithRevocableSession() async throws {
        let adapter = GameCenterReportingProbe(state: .authenticated)
        let gateway = RuntimeCloudGameCenterGateway(environment: deterministicEnvironment())
        try await gateway.install(adapter)
        await gateway.activateRuntime()
        let client = try await gateway.gameCenterClient()

        let statusSession = try await client.issueSession(for: .authenticationState)
        let authenticationState = try await client.authenticationState(session: statusSession)
        XCTAssertEqual(authenticationState, .authenticated)
        let authenticationSession = try await client.issueSession(for: .requestAuthentication)
        let requestedState = try await client.requestAuthentication(
            session: authenticationSession
        )
        XCTAssertEqual(requestedState, .authenticated)
        let authenticationRequestCount = await adapter.authenticationRequestCount()
        XCTAssertEqual(authenticationRequestCount, 1)
        let reportSession = try await client.issueSession(for: .reportAchievements)
        let report = try GameCenterAchievementReportDTO(
            identifier: "com.runescribe.achievement.first-inscription",
            percentage: 100
        )
        try await client.report([report], session: reportSession)
        let reported = await adapter.reported()
        XCTAssertEqual(reported, [[report]])

        do {
            try await client.report([report], session: statusSession)
            XCTFail("Expected operation-scoped session validation")
        } catch {
            XCTAssertEqual(error as? RuneScribeRuntimeError, .runtimeNotRunning)
        }
    }
}

private actor CloudTransportProbe: CloudSyncTransport {
    private let state: CloudAccountStateDTO
    private let fetchResult: CloudSyncFetchResultDTO
    private var fetches = 0
    private var saves: [Data] = []

    init(accountState: CloudAccountStateDTO, fetch: CloudSyncFetchResultDTO) {
        state = accountState
        fetchResult = fetch
    }

    func accountState() async throws -> CloudAccountStateDTO { state }

    func fetchPrivateProgression() async throws -> CloudSyncFetchResultDTO {
        fetches += 1
        return fetchResult
    }

    func savePrivateProgression(
        _ request: CloudSyncSaveRequestDTO
    ) async throws -> CloudSyncSaveResultDTO {
        saves.append(request.payload)
        return try CloudSyncSaveResultDTO(changeTag: "change-2")
    }

    func fetchCount() -> Int { fetches }
    func savedPayloads() -> [Data] { saves }
}

private actor GameCenterReportingProbe: GameCenterReporting {
    private let state: GameCenterAuthenticationStateDTO
    private var authenticationRequests = 0
    private var reports: [[GameCenterAchievementReportDTO]] = []

    init(state: GameCenterAuthenticationStateDTO) {
        self.state = state
    }

    func authenticationState() async -> GameCenterAuthenticationStateDTO { state }

    func requestAuthentication() async throws -> GameCenterAuthenticationStateDTO {
        authenticationRequests += 1
        return state
    }

    func report(_ achievements: [GameCenterAchievementReportDTO]) async throws {
        reports.append(achievements)
    }

    func reported() -> [[GameCenterAchievementReportDTO]] { reports }
    func authenticationRequestCount() -> Int { authenticationRequests }
}

private func deterministicEnvironment() -> RuntimeEnvironment {
    RuntimeEnvironment(
        now: { Date(timeIntervalSince1970: 1_000) },
        nextUUID: {
            UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!
        }
    )
}
