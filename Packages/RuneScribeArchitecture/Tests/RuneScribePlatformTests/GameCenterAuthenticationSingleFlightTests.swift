#if canImport(GameKit)
import RuneScribeContracts
@testable import RuneScribePlatform
import XCTest

final class GameCenterAuthenticationSingleFlightTests: XCTestCase {
    func testConcurrentRequestsShareOneOperationAndAllReceiveSuccess() async throws {
        let probe = ControlledGameCenterAuthenticationOperation()
        let singleFlight = GameCenterAuthenticationSingleFlight {
            try await probe.run()
        }

        let first = Task { try await singleFlight.run() }
        await probe.waitForInvocationCount(1)
        let second = Task { try await singleFlight.run() }

        let joined = await waitForRequestCount(2, in: singleFlight)
        XCTAssertTrue(joined)
        let invocationCount = await probe.currentInvocationCount()
        XCTAssertEqual(invocationCount, 1)
        let completed = await probe.complete(returning: .authenticated)
        XCTAssertTrue(completed)

        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, .authenticated)
        XCTAssertEqual(secondResult, .authenticated)

        let successor = Task { try await singleFlight.run() }
        await probe.waitForInvocationCount(2)
        let successorCompleted = await probe.complete(returning: .notAuthenticated)
        XCTAssertTrue(successorCompleted)
        let successorResult = try await successor.value
        XCTAssertEqual(successorResult, .notAuthenticated)
    }

    func testConcurrentRequestsShareOneFailureAndLaterRequestCanRetry() async throws {
        let probe = ControlledGameCenterAuthenticationOperation()
        let singleFlight = GameCenterAuthenticationSingleFlight {
            try await probe.run()
        }

        let first = Task { try await singleFlight.run() }
        await probe.waitForInvocationCount(1)
        let second = Task { try await singleFlight.run() }

        let joined = await waitForRequestCount(2, in: singleFlight)
        XCTAssertTrue(joined)
        let failed = await probe.complete(throwing: AuthenticationProbeError.denied)
        XCTAssertTrue(failed)

        await assertDenied(first)
        await assertDenied(second)

        let retry = Task { try await singleFlight.run() }
        await probe.waitForInvocationCount(2)
        let retryCompleted = await probe.complete(returning: .authenticated)
        XCTAssertTrue(retryCompleted)
        let retryResult = try await retry.value
        XCTAssertEqual(retryResult, .authenticated)
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        in singleFlight: GameCenterAuthenticationSingleFlight
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await singleFlight.currentRequestCount() == expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func assertDenied(
        _ task: Task<GameCenterAuthenticationStateDTO, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected authentication to fail", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AuthenticationProbeError, .denied, file: file, line: line)
        }
    }
}

private enum AuthenticationProbeError: Error, Equatable {
    case denied
}

private actor ControlledGameCenterAuthenticationOperation {
    private var invocationCount = 0
    private var continuation: CheckedContinuation<GameCenterAuthenticationStateDTO, Error>?
    private var invocationWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    func run() async throws -> GameCenterAuthenticationStateDTO {
        invocationCount += 1
        let readyWaiters = invocationWaiters.filter { $0.count <= invocationCount }
        invocationWaiters.removeAll { $0.count <= invocationCount }
        readyWaiters.forEach { $0.continuation.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
        }
    }

    func waitForInvocationCount(_ expectedCount: Int) async {
        guard invocationCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append((expectedCount, continuation))
        }
    }

    func currentInvocationCount() -> Int {
        invocationCount
    }

    func complete(returning state: GameCenterAuthenticationStateDTO) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: state)
        return true
    }

    func complete(throwing error: AuthenticationProbeError) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(throwing: error)
        return true
    }
}
#endif
