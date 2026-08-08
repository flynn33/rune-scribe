import Combine
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import XCTest
@testable import RuneScrib

@MainActor
enum TestApplicationFactory {
    static func makeKeyManager() -> KeyManager {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: InMemorySecureValueStore(),
            clock: SystemClock(),
            uuid: SystemUUIDProvider()
        )
        return KeyManager(service: service)
    }
}

@MainActor
extension XCTestCase {
    @discardableResult
    func waitForApplicationSnapshot(
        from keyManager: KeyManager,
        timeout: TimeInterval = 3,
        satisfying predicate: @escaping (RuneScribeApplicationSnapshot) -> Bool
    ) async throws -> RuneScribeApplicationSnapshot {
        if let snapshot = keyManager.snapshot, predicate(snapshot) {
            return snapshot
        }

        let snapshotExpectation = expectation(description: "Application snapshot satisfies predicate")
        var matchingSnapshot: RuneScribeApplicationSnapshot?
        var subscription: AnyCancellable?
        subscription = keyManager.$snapshot.sink { snapshot in
            guard let snapshot, predicate(snapshot), matchingSnapshot == nil else { return }
            matchingSnapshot = snapshot
            snapshotExpectation.fulfill()
            subscription?.cancel()
        }

        await fulfillment(of: [snapshotExpectation], timeout: timeout)
        subscription?.cancel()
        return try XCTUnwrap(matchingSnapshot)
    }
}
