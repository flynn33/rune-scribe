// RuneScrib/Services/LinkRouter.swift
//
// The single front door for inbound *URLs* (cipher QR / import links). Every URL
// entry point — `.onOpenURL`, the macOS AppDelegate's `open urls:`, and the
// clipboard sweep — funnels through here. Message sharing is file-based now and
// rides `FileRouter`, not this router.

import Foundation
import RuneScribeContracts

/// The kind of Rune Scribe link an inbound URL represents.
enum InboundLink: Equatable {
    case cipher(URL)
    case unknown
}

enum LinkRouter {

    /// Pure classification. Only cipher-import links are recognised; everything else
    /// (including any leftover `runescribe://m`) is `.unknown`.
    static func classify(_ url: URL) -> InboundLink {
        isCipherImportURL(url) ? .cipher(url) : .unknown
    }

    static func isCipherImportURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased()
        let path = components.path.lowercased()
        let isCustomScheme = scheme == RuneScribeWireFormat.URLScheme
            && ((host ?? path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == RuneScribeWireFormat.importHost)
        let isLegacyWebLink = scheme == "https"
            && (host == RuneScribeWireFormat.legacyWebHost
                || host == "www.\(RuneScribeWireFormat.legacyWebHost)")
            && path.hasPrefix(RuneScribeWireFormat.legacyImportPath)
        return isCustomScheme || isLegacyWebLink
    }

    /// Dispatches a classified URL to the owning coordinator. A no-op for
    /// links we don't recognise.
    @MainActor
    static func route(
        _ url: URL,
        coordinator: ImportCoordinator,
        source: InboundDeliverySourceDTO = .applicationOpen,
        isColdStart: Bool = false
    ) {
        switch classify(url) {
        case .cipher(let u):
            coordinator.ingest(url: u, source: source, isColdStart: isColdStart)
        case .unknown:        break
        }
    }

    /// Convenience for the clipboard path, which carries a raw string.
    /// Silently ignores anything that isn't a parseable URL.
    @MainActor
    static func route(
        urlString: String,
        coordinator: ImportCoordinator,
        source: InboundDeliverySourceDTO = .clipboard
    ) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return }
        route(url, coordinator: coordinator, source: source)
    }
}
