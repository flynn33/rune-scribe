// RuneScrib/Services/ImportCoordinator.swift

import Foundation
import CryptoKit

/// App-wide intake for ciphers arriving over the wire — deep links (`.onOpenURL`),
/// scanned QR codes, the clipboard, and `.runescribe` cipher files. It decodes the
/// payload and publishes a `PendingImport`; `RootView` observes it and shows the
/// one-tap confirmation sheet (gated so it never appears over the lock screen).
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

    /// The most recently ingested source (a URL's string or a file's content hash),
    /// used to drop a duplicate delivery — e.g. the macOS AppDelegate's
    /// `application(_:open:)` and SwiftUI's `.onOpenURL` both firing for the same source.
    private var lastHandledKey: String?

    private init() {}

    struct PendingImport: Identifiable, Equatable {
        let id = UUID()
        let payload: CipherSharePayload
        let suggestedName: String
        /// The font bytes that rode along in a file form, if any. Nil for URL imports.
        let fontBytes: Data?
    }

    /// Decodes a `runescribe://import` URL and, on success, surfaces it for
    /// confirmation; on failure, surfaces a readable error.
    func ingest(url: URL) {
        // Drop a duplicate delivery of the same link while one is already pending.
        let key = url.absoluteString
        if key == lastHandledKey, pending != nil { return }
        lastHandledKey = key
        do {
            let payload = try CipherSharePayload(url: url)
            errorMessage = nil
            pending = PendingImport(payload: payload,
                                    suggestedName: payload.parsedName ?? "Imported Cipher",
                                    fontBytes: nil)
        } catch {
            pending = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "This isn't a valid Rune Scribe cipher link."
        }
    }

    /// Decodes cipher file bytes (compact payload + optional font) and surfaces a
    /// `PendingImport` carrying the font, so confirmation can install font + cipher
    /// atomically; on failure, surfaces a readable error.
    func ingest(fileData data: Data) {
        // Drop a duplicate delivery of the same file while one is already pending.
        let key = Data(SHA256.hash(data: data)).base64EncodedString()
        if key == lastHandledKey, pending != nil { return }
        lastHandledKey = key
        do {
            let (payload, fontBytes) = try CipherSharePayload.decodeFile(data)
            errorMessage = nil
            pending = PendingImport(payload: payload,
                                    suggestedName: payload.parsedName ?? "Imported Cipher",
                                    fontBytes: fontBytes)
        } catch {
            pending = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "This isn't a valid Rune Scribe cipher file."
        }
    }

    /// Same as `ingest(url:)` but from a raw string (clipboard / scanned payload).
    /// Silently ignores anything that isn't one of our links. Accepts both the host
    /// form (`runescribe://import`) and the path form (`runescribe:import`), matching
    /// `RuneCipherLink.decodeURL`.
    func ingest(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CipherSharePayload.isShareURL(trimmed), let url = URL(string: trimmed) else { return }
        ingest(url: url)
    }
}
