import Combine
import CryptoKit
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import XCTest
@testable import RuneScrib

@MainActor
final class MessageCoordinatorTests: XCTestCase {
    private struct Context {
        let keyManager: KeyManager
        let contactManager: ContactManager
        let coordinator: MessageCoordinator
        let snapshots: CurrentValueSubject<RuneScribeApplicationSnapshot?, Never>
        let directory: URL
    }

    func testKeyFreeSnapshotSurfacesPendingMessageAndAssociatesContact() async throws {
        let context = await makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
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

        await waitUntil {
            context.contactManager.contacts.contains { $0.displayName == "Astrid" }
        }
        let contact = try XCTUnwrap(
            context.contactManager.contacts.first { $0.displayName == "Astrid" }
        )
        XCTAssertEqual(contact.source, .imported)
        await waitUntil {
            context.keyManager.ciphers.first { $0.id == cipher.id }?.contactID == contact.id
        }
    }

    func testRepeatingSameMessageDoesNotDuplicateContact() async throws {
        let context = await makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
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
        await waitUntil { context.contactManager.contacts.contains { $0.displayName == "Eira" } }
        context.snapshots.send(state)
        await Task.yield()

        XCTAssertEqual(
            context.contactManager.contacts.filter { $0.displayName == "Eira" }.count,
            1
        )
    }

    func testNilMessageStateClearsPendingPresentation() async throws {
        let context = await makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let contactManager = ContactManager(
            store: ContactStore(key: SymmetricKey(size: .bits256), directory: directory),
            keyManager: keyManager
        )
        let snapshots = CurrentValueSubject<RuneScribeApplicationSnapshot?, Never>(nil)
        let coordinator = MessageCoordinator(
            keyManager: keyManager,
            contactManager: contactManager,
            snapshotPublisher: snapshots.eraseToAnyPublisher()
        )
        return Context(
            keyManager: keyManager,
            contactManager: contactManager,
            coordinator: coordinator,
            snapshots: snapshots,
            directory: directory
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
