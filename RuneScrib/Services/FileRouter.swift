// RuneScrib/Services/FileRouter.swift
//
// The single front door for inbound `.runescribe` *files* (a tapped attachment,
// an AirDrop, a Finder/`Open in…` at cold launch). Message vs. cipher is
// disambiguated by the leading version byte — never by UTI — so both kinds ride
// the one exported type and one inbound rail.

import Foundation

/// Shared, single-source-of-truth constants for the file-based sharing rail. The
/// product link is referenced from both the message bubble and Settings so the two
/// can never diverge; the UTI / extension match `project.yml` and the attachment code.
enum RuneScribeShare {
    static let productLink = "https://ravenforgesoftware.com/rune-scribe/"
    static let uti = "com.runescribe.runescribe"
    static let fileExtension = "runescribe"
}

/// What a `.runescribe` file's bytes turned out to be, decided on its version byte.
enum InboundFile: Equatable {
    case cipher(Data)
    case message(Data)
    case unknown
}

/// The observable outcome of routing a file, so callers and tests can see what
/// happened instead of a silent no-op. `.unreadable`/`.unknown` also surface a
/// user-visible error (see `route`).
enum FileRouteResult: Equatable {
    case routedCipher
    case routedMessage
    case unreadable
    case unknown
}

enum FileRouter {

    /// Pure classification on the leading version byte. Empty or any unrecognised
    /// leading byte is `.unknown`; the bytes are not otherwise validated here.
    static func classify(_ data: Data) -> InboundFile {
        guard !data.isEmpty else { return .unknown }
        switch data[data.startIndex] {
        case CipherSharePayload.version:  return .cipher(data)
        case MessageSharePayload.version: return .message(data)
        default:                          return .unknown
        }
    }

    /// Dispatches classified file bytes to the owning coordinator and reports the
    /// outcome. Bytes we don't recognise are no longer a silent no-op: they set a
    /// plain, non-technical error the user can see (`ImportCoordinator.errorMessage`,
    /// which `RootView` already presents) so a bad file never looks like "nothing
    /// happened". The coordinators own their own dedupe and their own decode errors.
    @MainActor
    @discardableResult
    static func route(_ data: Data) -> FileRouteResult {
        switch classify(data) {
        case .cipher(let d):
            ImportCoordinator.shared.ingest(fileData: d)
            return .routedCipher
        case .message(let d):
            MessageCoordinator.shared.ingest(fileData: d)
            return .routedMessage
        case .unknown:
            ImportCoordinator.shared.errorMessage = "This is not a valid Rune Scribe file."
            return .unknown
        }
    }

    /// Reads a security-scoped file URL and routes its bytes. An unreadable URL is
    /// no longer swallowed: it sets a user-visible error and returns `.unreadable`.
    /// Balances `startAccessingSecurityScopedResource()` with a matching stop only
    /// when access was actually granted.
    @MainActor
    @discardableResult
    static func route(fileURL url: URL) -> FileRouteResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            ImportCoordinator.shared.errorMessage = "Rune Scribe could not open this file."
            return .unreadable
        }
        return route(data)
    }
}

// MARK: - Canonical inbound-open router

/// Where an inbound URL is headed. Pure, side-effect-free, `Equatable` — so the
/// routing decision can be asserted in tests without touching the singletons.
enum InboundOpenTarget: Equatable {
    case file(URL)
    case link(URL)
}

/// The one canonical front door for every inbound open, whichever platform callback
/// delivered it: SwiftUI `.onOpenURL`, the macOS/iOS app-delegate open methods, the
/// iOS scene delegate's URL contexts (active *and* cold-launch), and web-browsing user
/// activities. Each funnels a `URL` (or an array of them, or an `NSUserActivity`)
/// through here, so classification lives in exactly one place and can never drift
/// between entry points.
///
/// A `.runescribe` *file* (a tapped attachment / AirDrop / Open in…) goes to
/// `FileRouter`; a runescribe:// or legacy https import *link* goes to `LinkRouter`.
/// The coordinators behind both dedupe, so several handlers firing for the same item
/// still surfaces one sheet.
enum InboundOpenRouter {

    // MARK: Pure classification (safe off the main actor; used by tests)

    /// A file URL routes to `FileRouter`; anything else is a link for `LinkRouter`.
    static func target(for url: URL) -> InboundOpenTarget {
        url.isFileURL ? .file(url) : .link(url)
    }

    /// Classifies a batch, preserving order — the scene delegate hands several URL
    /// contexts through in one call and the order must be stable.
    static func targets(for urls: [URL]) -> [InboundOpenTarget] {
        urls.map(target(for:))
    }

    /// A web-browsing user activity carrying a `webpageURL` is a link (a legacy https
    /// import). Any other activity, or one without a URL, has no target.
    static func target(for userActivity: NSUserActivity) -> InboundOpenTarget? {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return nil }
        return .link(url)
    }

    // MARK: Dispatch (mutates the main-actor coordinators)

    /// Routes one URL to the owning coordinator.
    @MainActor
    static func route(url: URL) {
        switch target(for: url) {
        case .file(let u): FileRouter.route(fileURL: u)
        case .link(let u): LinkRouter.route(u)
        }
    }

    /// Routes a batch of URLs in order. This is the single `[URL]` seam every scene
    /// URL-context callback goes through.
    @MainActor
    static func route(urls: [URL]) {
        for url in urls { route(url: url) }
    }

    /// Routes a web-browsing user activity's `webpageURL`, if it has one.
    @MainActor
    static func route(userActivity: NSUserActivity) {
        if case .link(let u)? = target(for: userActivity) { LinkRouter.route(u) }
    }
}
