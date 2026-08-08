import Combine
import Foundation
import RuneScribeContracts

/// Temporary UI presenter for Core-owned import state. It retains only key-free
/// summaries and delegates every validation/persistence operation to the application
/// service. Migration owner: UIMigration. Removal phase: P5.
@MainActor
final class ImportCoordinator: ObservableObject {
    @Published var pending: PendingImportSummary?
    @Published var errorMessage: String?

    private let keyManager: KeyManager
    private var lastHandledKey: String?
    private var snapshotCancellable: AnyCancellable?

    init(
        keyManager: KeyManager,
        snapshotPublisher: AnyPublisher<RuneScribeApplicationSnapshot?, Never>? = nil
    ) {
        self.keyManager = keyManager
        let snapshots = snapshotPublisher ?? keyManager.$snapshot.eraseToAnyPublisher()
        snapshotCancellable = snapshots.sink { [weak self] snapshot in
            self?.apply(snapshot?.importState)
        }
    }

    func ingest(
        url: URL,
        source: InboundDeliverySourceDTO = .applicationOpen,
        isColdStart: Bool = false
    ) {
        let key = url.absoluteString
        guard key != lastHandledKey || pending == nil else { return }
        lastHandledKey = key
        Task {
            do {
                let result = try await keyManager.importURL(
                    url,
                    source: source,
                    isColdStart: isColdStart
                )
                pending = result.pendingImport
                errorMessage = nil
            } catch {
                pending = nil
                errorMessage = keyManager.lastError ?? "This isn't a valid Rune Scribe cipher link."
            }
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
                let result = try await keyManager.importFile(
                    fileURL,
                    source: source,
                    isColdStart: isColdStart
                )
                pending = result.pendingImport
                errorMessage = nil
            } catch {
                pending = nil
                errorMessage = keyManager.lastError ?? "This isn't a valid Rune Scribe cipher file."
            }
        }
    }

    func ingest(
        urlString: String,
        source: InboundDeliverySourceDTO = .clipboard
    ) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return }
        ingest(url: url, source: source)
    }

    func confirm(name: String) async throws -> CipherViewState {
        guard let pending else {
            throw RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .itemNotFound)
            )
        }
        let imported = try await keyManager.confirmImport(id: pending.id, name: name)
        self.pending = nil
        return imported
    }

    func cancelPending() {
        guard let id = pending?.id else { return }
        pending = nil
        Task { await keyManager.cancelImport(id: id) }
    }

    private func apply(_ state: ImportStateDTO?) {
        pending = state?.pending
        guard let state, state.phase == .failed, let failure = state.lastFailure else {
            if state?.phase != .failed { errorMessage = nil }
            return
        }
        switch failure.code {
        case .invalidInput, .unsupportedFormat, .corruptedContent:
            errorMessage = "This isn't a valid Rune Scribe import."
        case .protectedFileUnavailable:
            errorMessage = "Rune Scribe could not open this file."
        case .noMatchingCipher:
            errorMessage = "This message couldn't be read with your ciphers."
        default:
            errorMessage = "Rune Scribe could not complete the import."
        }
    }
}
