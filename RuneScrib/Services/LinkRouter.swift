// RuneScrib/Services/LinkRouter.swift
//
// The single front door for inbound URLs. Every entry point — `.onOpenURL`,
// the web-browsing `NSUserActivity`, the macOS AppDelegate's `open urls:`, and
// the clipboard sweep — funnels through here, so the cipher-import vs. message
// decision lives in exactly one place.

import Foundation

/// The kind of Rune Scribe link an inbound URL represents.
enum InboundLink: Equatable {
    case cipher(URL)
    case message(URL)
    case unknown
}

enum LinkRouter {

    /// Pure classification. Message links are tested *before* cipher links:
    /// `CipherSharePayload.isShareURL` returns `true` for any `runescribe:` URL
    /// (including `runescribe://m`), so the more specific message check must win.
    static func classify(_ url: URL) -> InboundLink {
        let s = url.absoluteString
        if MessageSharePayload.isMessageURL(s) { return .message(url) }
        if CipherSharePayload.isShareURL(s)    { return .cipher(url) }
        return .unknown
    }

    /// Dispatches a classified URL to the owning coordinator. A no-op for
    /// links we don't recognise.
    @MainActor
    static func route(_ url: URL) {
        switch classify(url) {
        case .cipher(let u):  ImportCoordinator.shared.ingest(url: u)
        case .message(let u): MessageCoordinator.shared.ingest(url: u)
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
