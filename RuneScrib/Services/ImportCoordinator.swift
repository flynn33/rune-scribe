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

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
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
        guard let url = URL(string: trimmed), LinkRouter.isCipherImportURL(url) else { return }
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
}
