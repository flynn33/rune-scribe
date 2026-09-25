import CryptoKit
import Foundation
import RuneScribeContracts

public enum MessagesInvitationValidationError: Error, Equatable, Sendable {
    case URLTooLarge
    case invalidRoute
    case invalidQuery
    case invalidPayload
}

public struct MessagesValidatedInvitation: Equatable, Sendable {
    public let URL: Foundation.URL
    public let handoffID: String

    fileprivate init(URL: Foundation.URL, handoffID: String) {
        self.URL = URL
        self.handoffID = handoffID
    }
}

/// Extension-safe validation for the exact HTTPS invitation accepted by the
/// containing app. This type validates transport shape only; it never creates a
/// cipher model or mutates the user's library.
public enum MessagesInvitationValidator {
    public static let maximumURLByteCount = 4_096
    public static let maximumNameByteCount = 256
    public static let cipherPayloadByteCount = 129

    public static func validate(_ URL: URL) throws -> MessagesValidatedInvitation {
        let absoluteString = URL.absoluteString
        guard absoluteString.utf8.count <= maximumURLByteCount else {
            throw MessagesInvitationValidationError.URLTooLarge
        }
        guard let components = URLComponents(
            url: URL,
            resolvingAgainstBaseURL: false
        ), components.scheme?.lowercased() == "https",
           components.host?.lowercased() == RuneScribeWireFormat.legacyWebHost,
           components.path.lowercased() == RuneScribeWireFormat.webLandingPath,
           components.user == nil,
           components.password == nil,
           components.port == nil,
           components.fragment == nil
        else {
            throw MessagesInvitationValidationError.invalidRoute
        }

        let items = components.queryItems ?? []
        let markers = items.filter {
            $0.name == RuneScribeWireFormat.webImportQueryName
        }
        let versions = items.filter { $0.name == "v" }
        let payloads = items.filter { $0.name == "p" }
        let names = items.filter { $0.name == "n" }
        guard items.allSatisfy({
                  $0.name == RuneScribeWireFormat.webImportQueryName
                    || $0.name == "v" || $0.name == "p" || $0.name == "n"
              }),
              markers.count == 1,
              markers[0].value == RuneScribeWireFormat.webImportQueryValue,
              versions.count == 1,
              versions[0].value == String(RuneScribeWireFormat.cipherVersion),
              payloads.count == 1,
              let payloadValue = payloads[0].value,
              !payloadValue.isEmpty,
              names.count <= 1,
              names.first?.value?.utf8.count ?? 0 <= maximumNameByteCount
        else {
            throw MessagesInvitationValidationError.invalidQuery
        }

        guard let payload = decodeBase64URL(payloadValue),
              payload.count == cipherPayloadByteCount,
              payload.first == UInt8(RuneScribeWireFormat.cipherVersion),
              hasValidChecksum(payload),
              hasValidMapping(payload),
              hasValidFontReference(payload)
        else {
            throw MessagesInvitationValidationError.invalidPayload
        }

        return MessagesValidatedInvitation(
            URL: URL,
            handoffID: handoffID(for: absoluteString)
        )
    }

    public static func handoffID(forValidatedURL URL: URL) throws -> String {
        try validate(URL).handoffID
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard value.utf8.count <= 172,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 48...57, 65...90, 95, 97...122:
                      true
                  default:
                      false
                  }
              })
        else { return nil }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func hasValidChecksum(_ payload: Data) -> Bool {
        let body = payload.dropLast(4)
        return Data(SHA256.hash(data: body).prefix(4)) == payload.suffix(4)
    }

    private static func hasValidMapping(_ payload: Data) -> Bool {
        let start = 1 + 8 + 32
        let end = start + 32
        return Set(payload[start..<end]) == Set(UInt8(0)...UInt8(31))
    }

    private static func hasValidFontReference(_ payload: Data) -> Bool {
        let fontIDStart = 1 + 8 + 32 + 32
        let fontIDEnd = fontIDStart + 16
        let fontIDBytes = payload[fontIDStart..<fontIDEnd]
        guard let zero = fontIDBytes.firstIndex(of: 0) else {
            return String(data: fontIDBytes, encoding: .utf8) != nil
        }
        let identifierBytes = fontIDBytes[..<zero]
        guard !identifierBytes.isEmpty,
              String(data: identifierBytes, encoding: .utf8) != nil,
              fontIDBytes[zero...].allSatisfy({ $0 == 0 })
        else { return false }

        let versionStart = fontIDEnd
        let versionEnd = versionStart + 4
        let version = payload[versionStart..<versionEnd].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        return version > 0
    }

    private static func handoffID(for absoluteString: String) -> String {
        var bytes = Data("runescribe-messages-v1\0".utf8)
        bytes.append(contentsOf: absoluteString.utf8)
        return SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
