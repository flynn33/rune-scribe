import Foundation
import RuneScribeContracts

enum LinkRouterError: Error, Equatable, Sendable {
    case invalidRoute
    case invalidQuery
    case invalidPayload
}

/// Strictly validates the route and query shape before allowing the key-bearing
/// payload into Core. No raw URL is retained after decoding.
enum LinkRouter {
    static let maximumURLByteCount = 4_096
    static let maximumNameByteCount = 256

    static func decodeCipher(_ url: URL) throws -> CipherSharePayload {
        guard url.absoluteString.utf8.count <= maximumURLByteCount else {
            throw LinkRouterError.invalidQuery
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              isSupportedRoute(components)
        else { throw LinkRouterError.invalidRoute }

        let items = components.queryItems ?? []
        let versions = items.filter { $0.name == "v" }
        let payloads = items.filter { $0.name == "p" }
        let names = items.filter { $0.name == "n" }
        let webMarkers = items.filter {
            $0.name == RuneScribeWireFormat.webImportQueryName
        }
        let isWebLandingRoute = components.scheme?.lowercased() == "https"
            && components.path.lowercased() == RuneScribeWireFormat.webLandingPath
        guard items.allSatisfy({
                  $0.name == "v" || $0.name == "p" || $0.name == "n"
                    || $0.name == RuneScribeWireFormat.webImportQueryName
              }),
              versions.count == 1,
              versions[0].value == String(RuneScribeWireFormat.cipherVersion),
              payloads.count == 1,
              payloads[0].value?.isEmpty == false,
              names.count <= 1,
              names.first?.value?.utf8.count ?? 0 <= maximumNameByteCount,
              isWebLandingRoute
                ? (webMarkers.count == 1
                    && webMarkers[0].value == RuneScribeWireFormat.webImportQueryValue)
                : webMarkers.isEmpty
        else { throw LinkRouterError.invalidQuery }

        do {
            return try CipherSharePayload(url: url)
        } catch {
            throw LinkRouterError.invalidPayload
        }
    }

    static func isSupportedRoute(_ components: URLComponents) -> Bool {
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased()
        let path = components.path.lowercased()

        if scheme == RuneScribeWireFormat.URLScheme {
            return host == RuneScribeWireFormat.importHost && (path.isEmpty || path == "/")
        }

        return scheme == "https"
            && (host == RuneScribeWireFormat.legacyWebHost
                || host == "www.\(RuneScribeWireFormat.legacyWebHost)")
            && (path == RuneScribeWireFormat.webLandingPath
                || path == RuneScribeWireFormat.legacyImportPath
                || path == RuneScribeWireFormat.legacyImportPath + "/")
    }
}
