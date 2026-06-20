// RuneScrib/Services/ImportCoordinator.swift

import Foundation

/// App-wide intake for ciphers arriving over the wire — deep links (`.onOpenURL`),
/// scanned QR codes, and the clipboard. It decodes the `runescribe://import` URL to
/// a permutation and publishes a `PendingImport`; `RootView` observes it and shows
/// the one-tap confirmation sheet (gated so it never appears over the lock screen).
///
/// Published as a singleton and injected as an `@EnvironmentObject`; all state
/// mutates on the main actor.
@MainActor
final class ImportCoordinator: ObservableObject {

    static let shared = ImportCoordinator()

    /// A decoded cipher awaiting the user's confirmation.
    @Published var pending: PendingImport?

    /// A human-readable reason a link/QR couldn't be imported.
    @Published var errorMessage: String?

    /// The most recently ingested URL, used to drop a duplicate delivery — e.g. the
    /// macOS AppDelegate's `application(_:open:)` and SwiftUI's `.onOpenURL` both
    /// firing for the same link.
    private var lastHandledURL: String?

    private init() {}

    struct PendingImport: Identifiable, Equatable {
        let id = UUID()
        let perm: [UInt8]
        let suggestedName: String
    }

    /// Decodes a `runescribe://import` URL and, on success, surfaces it for
    /// confirmation; on failure, surfaces a readable error.
    func ingest(url: URL) {
        // Drop a duplicate delivery of the same link while one is already pending.
        let key = url.absoluteString
        if key == lastHandledURL, pending != nil { return }
        lastHandledURL = key
        do {
            let (perm, name) = try RuneCipherLink.decodeURL(url)
            errorMessage = nil
            pending = PendingImport(perm: perm, suggestedName: name ?? "Imported Cipher")
        } catch {
            pending = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "This isn't a valid Rune Scribe cipher link."
        }
    }

    /// Same as `ingest(url:)` but from a raw string (clipboard / scanned payload).
    /// Silently ignores anything that isn't one of our links. Accepts both the host
    /// form (`runescribe://import`) and the path form (`runescribe:import`), matching
    /// `RuneCipherLink.decodeURL`.
    func ingest(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\(RuneCipherLink.scheme):"), let url = URL(string: trimmed) else { return }
        ingest(url: url)
    }
}
