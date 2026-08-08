import Combine
import Foundation
import RuneScribeContracts

/// Temporary UI presenter for Core-owned inbound-message state. It observes only
/// key-free snapshots; decrypt/import/contact association all remain in Core.
@MainActor
final class MessageCoordinator: ObservableObject {
    struct PendingMessage: Identifiable, Equatable {
        let id: MessageID
        let plaintext: String
        let senderName: String
        let cipherID: UUID
        let cipherName: String
    }

    @Published var pending: PendingMessage?
    @Published var errorMessage: String?

    private let keyManager: KeyManager
    private var lastHandledKey: String?
    private var snapshotCancellable: AnyCancellable?

    init(
        keyManager: KeyManager,
        snapshotPublisher: AnyPublisher<RuneScribeApplicationSnapshot?, Never>? = nil
    ) {
        self.keyManager = keyManager
        let snapshots = snapshotPublisher
            ?? keyManager.$snapshot.eraseToAnyPublisher()
        snapshotCancellable = snapshots.sink { [weak self] snapshot in
            self?.apply(snapshot?.messageState.pendingMessage)
        }
    }

    func ingest(
        fileURL: URL,
        source: InboundDeliverySourceDTO = .applicationOpen,
        isColdStart: Bool = false
    ) {
        let key = fileURL.standardizedFileURL.absoluteString
        guard key != lastHandledKey || pending == nil else { return }
        lastHandledKey = key
        Task {
            do {
                _ = try await keyManager.importFile(
                    fileURL,
                    source: source,
                    isColdStart: isColdStart
                )
                errorMessage = nil
            } catch {
                pending = nil
                errorMessage = keyManager.lastError ?? "This message couldn't be read."
            }
        }
    }

    func dismissPending() {
        guard let id = pending?.id else { return }
        pending = nil
        Task { await keyManager.dismissReceivedMessage(id: id) }
    }

    private func apply(_ message: ReceivedMessageDTO?) {
        guard let message else {
            pending = nil
            return
        }
        pending = PendingMessage(
            id: message.id,
            plaintext: message.plaintext,
            senderName: message.senderName,
            cipherID: message.cipherID.rawValue,
            cipherName: message.cipherName
        )
    }
}
