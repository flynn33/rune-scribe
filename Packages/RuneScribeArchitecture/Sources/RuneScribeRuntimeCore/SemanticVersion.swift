import Foundation

public enum SemanticVersionError: Error, Equatable, Sendable {
    case invalidFormat(String)
}

public struct SemanticVersion: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) throws {
        guard major >= 0, minor >= 0, patch >= 0 else {
            throw SemanticVersionError.invalidFormat("\(major).\(minor).\(patch)")
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(major: UInt, minor: UInt, patch: UInt) {
        self.major = Int(major)
        self.minor = Int(minor)
        self.patch = Int(patch)
    }

    public init(_ value: String) throws {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2])
        else {
            throw SemanticVersionError.invalidFormat(value)
        }
        try self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected semantic version major.minor.patch."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
