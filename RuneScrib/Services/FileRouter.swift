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

    /// Dispatches classified file bytes to the owning coordinator. A no-op for
    /// bytes we don't recognise.
    @MainActor
    static func route(_ data: Data) {
        switch classify(data) {
        case .cipher(let d):  ImportCoordinator.shared.ingest(fileData: d)
        case .message(let d): MessageCoordinator.shared.ingest(fileData: d)
        case .unknown:        break
        }
    }

    /// Reads a security-scoped file URL and routes its bytes. Silently ignores an
    /// unreadable URL. Balances `startAccessingSecurityScopedResource()` with a
    /// matching stop only when access was actually granted.
    @MainActor
    static func route(fileURL url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        route(data)
    }
}
