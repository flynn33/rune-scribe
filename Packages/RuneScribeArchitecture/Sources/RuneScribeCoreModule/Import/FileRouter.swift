import Foundation
import RuneScribeContracts

enum FileRouterError: Error, Equatable, Sendable {
    case empty
    case unsupportedVersion(UInt8)
    case malformedCipher
    case malformedMessage
}

enum RoutedInboundFile: Sendable {
    case cipher(payload: CipherSharePayload, fontBytes: Data?)
    case message(payload: MessageSharePayload, fontBytes: Data?)
}

/// Strict Core parser for the shared `.runescribe` file rail. The leading byte
/// selects a format, then the complete format decoder validates the payload.
enum FileRouter {
    static func decode(_ data: Data) throws -> RoutedInboundFile {
        guard let version = data.first else { throw FileRouterError.empty }
        switch version {
        case UInt8(RuneScribeWireFormat.cipherVersion):
            do {
                let decoded = try CipherSharePayload.decodeFile(data)
                return .cipher(payload: decoded.0, fontBytes: decoded.1)
            } catch {
                throw FileRouterError.malformedCipher
            }

        case UInt8(RuneScribeWireFormat.messageVersion):
            do {
                let decoded = try MessageSharePayload.decodeFile(data)
                return .message(payload: decoded.0, fontBytes: decoded.fontBytes)
            } catch {
                throw FileRouterError.malformedMessage
            }

        default:
            throw FileRouterError.unsupportedVersion(version)
        }
    }
}
