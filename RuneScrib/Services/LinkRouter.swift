// RuneScrib/Services/LinkRouter.swift
//
// The single front door for inbound *URLs* (cipher QR / import links). Every URL
// entry point — `.onOpenURL`, the macOS AppDelegate's `open urls:`, and the
// clipboard sweep — funnels through here. Message sharing is file-based now and
// rides `FileRouter`, not this router.

import Foundation

/// The kind of Rune Scribe link an inbound URL represents.
enum InboundLink: Equatable {
    case cipher(URL)
    case unknown
}

enum LinkRouter {

    /// Pure classification. Only cipher-import links are recognised; everything else
    /// (including any leftover `runescribe://m`) is `.unknown`.
    static func classify(_ url: URL) -> InboundLink {
        CipherSharePayload.isShareURL(url.absoluteString) ? .cipher(url) : .unknown
    }

    /// Dispatches a classified URL to the owning coordinator. A no-op for
    /// links we don't recognise.
    @MainActor
    static func route(_ url: URL) {
        switch classify(url) {
        case .cipher(let u):  ImportCoordinator.shared.ingest(url: u)
        case .unknown:        break
        }
    }

    /// Convenience for the clipboard path, which carries a raw string.
    /// Silently ignores anything that isn't a parseable URL.
    @MainActor
    static func route(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return }
        route(url)
    }
}
