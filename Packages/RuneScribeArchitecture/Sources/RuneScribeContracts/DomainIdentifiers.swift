import Foundation

public protocol UUIDBackedIdentifier: RawRepresentable, Codable, Hashable, Sendable, Comparable
where RawValue == UUID {}

public extension UUIDBackedIdentifier {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

public struct CipherID: UUIDBackedIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ContactID: UUIDBackedIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct MessageID: UUIDBackedIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ImportID: UUIDBackedIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ShareArtifactID: UUIDBackedIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct InboundInputID: UUIDBackedIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct EventID: UUIDBackedIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct CorrelationID: UUIDBackedIdentifier {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct FontID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let bundledRuneFont = FontID(rawValue: "noto-sans-runic")
}

/// A bounded, wire-safe identifier used by roadmap contracts. Values consist
/// of lower-case ASCII letter or number segments separated by a single dot or
/// hyphen. The generic domain keeps otherwise identical identifier families
/// distinct at compile time.
public struct RoadmapStringIdentifier<Domain>: RawRepresentable, Codable, Hashable,
    Sendable, Comparable, CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard RoadmapIdentifierSyntax.isValidIdentifier(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let identifier = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid roadmap identifier."
                )
            )
        }
        self = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }
}

/// An opaque pseudonymous token representation. Token derivation and secret
/// management remain outside Contracts; this type enforces bounded wire syntax
/// and a minimum length. Callers must never construct it from raw identity.
public struct PrivacySafeToken<Domain>: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard RoadmapIdentifierSyntax.isValidPrivacyToken(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let token = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid privacy-safe token."
                )
            )
        }
        self = token
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }
}

public enum CodexIdentifierDomain: Sendable {}
public enum ScriptIdentifierDomain: Sendable {}
public enum ArtifactIdentifierDomain: Sendable {}
public enum RelicIdentifierDomain: Sendable {}
public enum SealIdentifierDomain: Sendable {}
public enum FrameIdentifierDomain: Sendable {}
public enum EffectIdentifierDomain: Sendable {}
public enum AchievementIdentifierDomain: Sendable {}
public enum RuleIdentifierDomain: Sendable {}
public enum UnlockIdentifierDomain: Sendable {}
public enum PackageKindIdentifierDomain: Sendable {}
public enum PackageVersionIdentifierDomain: Sendable {}
public enum EligibilityReasonIdentifierDomain: Sendable {}
public enum EntitlementSourceReferenceIdentifierDomain: Sendable {}
public enum CipherTokenDomain: Sendable {}
public enum MessageTokenDomain: Sendable {}
public enum PackageTokenDomain: Sendable {}
public enum RelationshipTokenDomain: Sendable {}

public typealias CodexID = RoadmapStringIdentifier<CodexIdentifierDomain>
public typealias ScriptID = RoadmapStringIdentifier<ScriptIdentifierDomain>
public typealias ArtifactID = RoadmapStringIdentifier<ArtifactIdentifierDomain>
public typealias RelicID = RoadmapStringIdentifier<RelicIdentifierDomain>
public typealias SealID = RoadmapStringIdentifier<SealIdentifierDomain>
public typealias FrameID = RoadmapStringIdentifier<FrameIdentifierDomain>
public typealias EffectID = RoadmapStringIdentifier<EffectIdentifierDomain>
public typealias AchievementID = RoadmapStringIdentifier<AchievementIdentifierDomain>
public typealias RuleID = RoadmapStringIdentifier<RuleIdentifierDomain>
public typealias UnlockID = RoadmapStringIdentifier<UnlockIdentifierDomain>
public typealias PackageKindID = RoadmapStringIdentifier<PackageKindIdentifierDomain>
public typealias PackageVersionID = RoadmapStringIdentifier<PackageVersionIdentifierDomain>
public typealias EligibilityReasonID = RoadmapStringIdentifier<EligibilityReasonIdentifierDomain>
public typealias EntitlementSourceReferenceID =
    RoadmapStringIdentifier<EntitlementSourceReferenceIdentifierDomain>

public typealias CipherToken = PrivacySafeToken<CipherTokenDomain>
public typealias MessageToken = PrivacySafeToken<MessageTokenDomain>
public typealias PackageToken = PrivacySafeToken<PackageTokenDomain>
public typealias RelationshipToken = PrivacySafeToken<RelationshipTokenDomain>

enum RoadmapIdentifierSyntax {
    static let maximumIdentifierUTF8Count = 96
    /// Tokens are encoded pseudonymous digests/UUID-derived values, never display
    /// strings. Requiring at least 128 bits in hexadecimal form also excludes
    /// E.164 phone numbers and other short identifiers at the wire boundary.
    static let minimumPrivacyTokenUTF8Count = 32
    static let maximumPrivacyTokenUTF8Count = 128

    static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumIdentifierUTF8Count else {
            return false
        }

        var previousWasSeparator = false
        for (index, byte) in bytes.enumerated() {
            if isLowercaseLetterOrNumber(byte) {
                previousWasSeparator = false
                continue
            }

            let isSeparator = byte == 0x2D || byte == 0x2E
            guard isSeparator,
                  index > 0,
                  index < bytes.count - 1,
                  !previousWasSeparator
            else {
                return false
            }
            previousWasSeparator = true
        }
        return true
    }

    static func isValidPrivacyToken(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= minimumPrivacyTokenUTF8Count,
              bytes.count <= maximumPrivacyTokenUTF8Count,
              bytes.first.map(isLowercaseLetterOrNumber) == true,
              bytes.last.map(isLowercaseLetterOrNumber) == true
        else {
            return false
        }

        var previousWasSeparator = false
        for byte in bytes {
            if isLowercaseLetterOrNumber(byte) {
                previousWasSeparator = false
            } else if byte == 0x2D, !previousWasSeparator {
                previousWasSeparator = true
            } else {
                return false
            }
        }
        return true
    }

    private static func isLowercaseLetterOrNumber(_ byte: UInt8) -> Bool {
        (0x61 ... 0x7A).contains(byte) || (0x30 ... 0x39).contains(byte)
    }
}
