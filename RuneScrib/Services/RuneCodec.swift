import Foundation

enum RuneCodecError: Error { case foreignCharacter, invalidLength }

/// Reversible DECORATIVE encoding of bytes to a rune string and back, using a cipher's
/// `decorativeMapping`. This is base-32 (5 bits/rune, RFC 4648 bit order, no padding)
/// over `RuneCharacterSet.decorativeAlphabet`, with the per-cipher permutation applied.
/// It carries NO security — the security is the AES-GCM layer beneath it.
struct RuneCodec {

    func encode(_ data: Data, with cipher: Cipher) -> String {
        let alphabet = RuneCharacterSet.decorativeAlphabet
        var out = String()
        for value in fiveBitGroups(of: data) {
            out.append(alphabet[cipher.decorativeMapping[value]])
        }
        return out
    }

    func decode(_ runes: String, with cipher: Cipher) throws -> Data {
        var indexOfRune: [Character: Int] = [:]
        for (i, ch) in RuneCharacterSet.decorativeAlphabet.enumerated() { indexOfRune[ch] = i }
        var valueForAlphabetIndex = [Int](repeating: 0, count: 32)
        for (value, alphaIndex) in cipher.decorativeMapping.enumerated() { valueForAlphabetIndex[alphaIndex] = value }

        var groups: [Int] = []
        for ch in runes {
            guard let alphaIndex = indexOfRune[ch] else { throw RuneCodecError.foreignCharacter }
            groups.append(valueForAlphabetIndex[alphaIndex])
        }
        return try bytes(fromFiveBitGroups: groups)
    }

    // MARK: base-32 bit packing (RFC 4648 order, no padding)

    private func fiveBitGroups(of data: Data) -> [Int] {
        var out: [Int] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(Int((buffer >> UInt32(bits)) & 0x1F))
            }
        }
        if bits > 0 { out.append(Int((buffer << UInt32(5 - bits)) & 0x1F)) }
        return out
    }

    private func bytes(fromFiveBitGroups groups: [Int]) throws -> Data {
        var out = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for g in groups {
            buffer = (buffer << 5) | UInt32(g & 0x1F)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        if bits > 0, (buffer & ((1 << UInt32(bits)) - 1)) != 0 { throw RuneCodecError.invalidLength }
        return out
    }
}
