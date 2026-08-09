import Foundation
import RuneScribeContracts

enum ScriptValidationError: Error, Equatable, Sendable {
    case invalidVersion
    case invalidGlyphCount
    case duplicateGlyphID
    case duplicateTextToken
    case invalidGlyphID
    case invalidTextToken
    case invalidRenderingFont
}

enum ScriptPortabilityClass: String, Codable, Equatable, Sendable {
    case unicodePortable
    case fontDependent
    case vectorRendered
}

struct ScriptGlyphDescriptor: Codable, Equatable, Sendable {
    let id: String
    let textToken: Character?

    init(id: String, textToken: Character?) {
        self.id = id
        self.textToken = textToken
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case textToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guard let encodedToken = try container.decodeIfPresent(String.self, forKey: .textToken)
        else {
            textToken = nil
            return
        }
        guard encodedToken.count == 1, let token = encodedToken.first else {
            throw ScriptValidationError.invalidTextToken
        }
        textToken = token
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(textToken.map(String.init), forKey: .textToken)
    }
}

/// A Core-owned description of the ordered 32-symbol presentation alphabet.
/// It contains no SwiftUI, artwork, unlock rules, or executable theme behavior.
struct ScriptDescriptor: Codable, Equatable, Sendable {
    let id: ScriptID
    let version: UInt16
    let portability: ScriptPortabilityClass
    let glyphs: [ScriptGlyphDescriptor]
    let renderingFont: FontRef?

    init(
        id: ScriptID,
        version: UInt16,
        portability: ScriptPortabilityClass,
        glyphs: [ScriptGlyphDescriptor],
        renderingFont: FontRef? = nil
    ) throws {
        guard version > 0 else { throw ScriptValidationError.invalidVersion }
        guard glyphs.count == 32 else { throw ScriptValidationError.invalidGlyphCount }
        guard glyphs.allSatisfy({
            let count = $0.id.lengthOfBytes(using: .utf8)
            return (1...64).contains(count) && Self.hasValidGlyphID($0.id)
        }) else {
            throw ScriptValidationError.invalidGlyphID
        }
        guard Set(glyphs.map(\.id)).count == glyphs.count else {
            throw ScriptValidationError.duplicateGlyphID
        }
        let textTokens = glyphs.compactMap(\.textToken)
        if portability != .vectorRendered {
            guard textTokens.count == 32 else { throw ScriptValidationError.invalidGlyphCount }
            guard Set(textTokens).count == textTokens.count else {
                throw ScriptValidationError.duplicateTextToken
            }
        } else {
            guard textTokens.isEmpty || textTokens.count == 32 else {
                throw ScriptValidationError.invalidTextToken
            }
            guard Set(textTokens).count == textTokens.count else {
                throw ScriptValidationError.duplicateTextToken
            }
        }
        if portability == .fontDependent {
            guard let renderingFont, renderingFont.hasValidWireShape else {
                throw ScriptValidationError.invalidRenderingFont
            }
        } else if let renderingFont, !renderingFont.hasValidWireShape {
            throw ScriptValidationError.invalidRenderingFont
        }
        self.id = id
        self.version = version
        self.portability = portability
        self.glyphs = glyphs
        self.renderingFont = renderingFont
    }

    var portableAlphabet: [Character]? {
        let tokens = glyphs.compactMap(\.textToken)
        return tokens.count == 32 ? tokens : nil
    }

    static let baseRune: ScriptDescriptor = {
        try! ScriptDescriptor(
            id: ScriptID(rawValue: "script.base-runes")!,
            version: 1,
            portability: .unicodePortable,
            glyphs: RuneCharacterSet.decorativeAlphabet.enumerated().map { index, token in
                ScriptGlyphDescriptor(
                    id: String(format: "base-rune-%02d", index),
                    textToken: token
                )
            },
            renderingFont: .bundled
        )
    }()

    static func legacyCompatibility(fontRef: FontRef) throws -> ScriptDescriptor {
        try ScriptDescriptor(
            id: ScriptID(rawValue: "script.legacy-font")!,
            version: 1,
            portability: .fontDependent,
            glyphs: Self.baseRune.glyphs,
            renderingFont: fontRef
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case portability
        case glyphs
        case renderingFont
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ScriptID.self, forKey: .id),
            version: container.decode(UInt16.self, forKey: .version),
            portability: container.decode(ScriptPortabilityClass.self, forKey: .portability),
            glyphs: container.decode([ScriptGlyphDescriptor].self, forKey: .glyphs),
            renderingFont: container.decodeIfPresent(FontRef.self, forKey: .renderingFont)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(portability, forKey: .portability)
        try container.encode(glyphs, forKey: .glyphs)
        try container.encodeIfPresent(renderingFont, forKey: .renderingFont)
    }

    private static func hasValidGlyphID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first,
              let last = bytes.last,
              isLowercaseLetterOrNumber(first),
              isLowercaseLetterOrNumber(last)
        else {
            return false
        }
        var priorWasSeparator = false
        for byte in bytes {
            if isLowercaseLetterOrNumber(byte) {
                priorWasSeparator = false
            } else if (byte == 0x2D || byte == 0x2E), !priorWasSeparator {
                priorWasSeparator = true
            } else {
                return false
            }
        }
        return true
    }

    private static func isLowercaseLetterOrNumber(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
    }
}
