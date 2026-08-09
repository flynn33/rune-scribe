import Foundation
import RuneScribeContracts

enum FileRouterError: Error, Equatable, Sendable {
    case empty
    case malformedContainer
    case unsupportedVersion(UInt8)
    case unsupportedContainerVersion(UInt16)
    case unsupportedPayloadKind(UInt16)
    case unsupportedPayloadVersion(kind: UInt16, version: UInt16)
    case unknownRequiredSection(UInt16)
    case unsupportedRequiredSectionVersion(type: UInt16, version: UInt16)
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
        if RuneScribePackage.hasMagic(data) || RuneScribePackage.hasPartialMagic(data) {
            return try decodePackage(data)
        }
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

    private static func decodePackage(_ data: Data) throws -> RoutedInboundFile {
        do {
            let package = try RuneScribePackage(decoding: data)
            switch package.kind {
            case .cipherInvitation:
                let payload = try CipherSharePayload(decoding: package.corePayload)
                let fontBytes = try package.legacyFontBytes(matching: payload.fontRef)
                return .cipher(payload: payload, fontBytes: fontBytes)
            case .encryptedMessage:
                let payload = try MessageSharePayload(decoding: package.corePayload)
                let fontBytes = try package.legacyFontBytes(
                    matching: payload.embeddedCipher?.fontRef
                )
                return .message(payload: payload, fontBytes: fontBytes)
            }
        } catch let packageError as RuneScribePackageError {
            switch packageError {
            case .unsupportedContainerVersion(let version):
                throw FileRouterError.unsupportedContainerVersion(version)
            case .unsupportedPayloadKind(let kind):
                throw FileRouterError.unsupportedPayloadKind(kind)
            case .unsupportedPayloadVersion(let kind, let version):
                throw FileRouterError.unsupportedPayloadVersion(kind: kind, version: version)
            case .unknownRequiredSection(let type):
                throw FileRouterError.unknownRequiredSection(type)
            case .unsupportedRequiredSectionVersion(let type, let version):
                throw FileRouterError.unsupportedRequiredSectionVersion(
                    type: type,
                    version: version
                )
            default:
                throw FileRouterError.malformedContainer
            }
        } catch {
            throw FileRouterError.malformedContainer
        }
    }
}
