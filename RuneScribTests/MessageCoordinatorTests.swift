import Combine
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import XCTest
@testable import RuneScrib

@MainActor
final class MessageCoordinatorTests: XCTestCase {
    private struct Context {
        let keyManager: KeyManager
        let coordinator: MessageCoordinator
        let snapshots: CurrentValueSubject<RuneScribeApplicationSnapshot?, Never>
    }

    func testKeyFreeSnapshotSurfacesPendingMessage() async throws {
        let context = await makeContext()
        let cipher = try await context.keyManager.addCipher(label: "Sender")
        await waitUntil { context.keyManager.ciphers.contains { $0.id == cipher.id } }

        let message = ReceivedMessageDTO(
            id: MessageID(rawValue: UUID()),
            plaintext: "rendezvous at dusk",
            senderName: "Astrid",
            cipherID: cipher.contractID,
            cipherName: cipher.label
        )
        context.snapshots.send(snapshot(from: try XCTUnwrap(context.keyManager.snapshot), message: message))

        await waitUntil { context.coordinator.pending?.id == message.id }
        XCTAssertEqual(context.coordinator.pending?.plaintext, "rendezvous at dusk")
        XCTAssertEqual(context.coordinator.pending?.senderName, "Astrid")
        XCTAssertEqual(context.coordinator.pending?.cipherID, cipher.id)
        XCTAssertEqual(context.coordinator.pending?.cipherName, "Sender")
    }

    func testRepeatingSameMessageKeepsOnePresentationProjection() async throws {
        let context = await makeContext()
        let cipher = try await context.keyManager.addCipher(label: "Sender")
        let message = ReceivedMessageDTO(
            id: MessageID(rawValue: UUID()),
            plaintext: "once only",
            senderName: "Eira",
            cipherID: cipher.contractID,
            cipherName: cipher.label
        )
        let state = snapshot(from: try XCTUnwrap(context.keyManager.snapshot), message: message)

        context.snapshots.send(state)
        await waitUntil { context.coordinator.pending?.id == message.id }
        context.snapshots.send(state)
        await Task.yield()

        XCTAssertEqual(context.coordinator.pending?.id, message.id)
        XCTAssertEqual(context.coordinator.pending?.senderName, "Eira")
    }

    func testNilMessageStateClearsPendingPresentation() async throws {
        let context = await makeContext()
        let cipher = try await context.keyManager.addCipher(label: "Sender")
        let message = ReceivedMessageDTO(
            id: MessageID(rawValue: UUID()),
            plaintext: "hello",
            senderName: "Bjorn",
            cipherID: cipher.contractID,
            cipherName: cipher.label
        )
        let base = try XCTUnwrap(context.keyManager.snapshot)

        context.snapshots.send(snapshot(from: base, message: message))
        await waitUntil { context.coordinator.pending != nil }
        context.snapshots.send(snapshot(from: base, message: nil))
        await waitUntil { context.coordinator.pending == nil }
    }

    private func makeContext() async -> Context {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: InMemorySecureValueStore(),
            clock: SystemClock(),
            uuid: SystemUUIDProvider()
        )
        let keyManager = KeyManager(service: service)
        await waitUntil { keyManager.snapshot != nil && !keyManager.isLoading }
        let snapshots = CurrentValueSubject<RuneScribeApplicationSnapshot?, Never>(nil)
        let coordinator = MessageCoordinator(
            keyManager: keyManager,
            snapshotPublisher: snapshots.eraseToAnyPublisher()
        )
        return Context(
            keyManager: keyManager,
            coordinator: coordinator,
            snapshots: snapshots
        )
    }

    private func snapshot(
        from base: RuneScribeApplicationSnapshot,
        message: ReceivedMessageDTO?
    ) -> RuneScribeApplicationSnapshot {
        RuneScribeApplicationSnapshot(
            revision: base.revision + 1,
            capturedAt: Date(),
            cipherLibrary: base.cipherLibrary,
            contactLibrary: base.contactLibrary,
            fonts: base.fonts,
            importState: base.importState,
            messageState: MessageStateDTO(
                phase: message == nil ? .idle : .received,
                pendingMessage: message
            ),
            lockState: base.lockState,
            lastFailure: base.lastFailure
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for application state", file: file, line: line)
    }
}
