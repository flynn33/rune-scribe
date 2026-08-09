import Foundation

enum RuneCodecError: Error, Equatable, Sendable {
    case foreignCharacter
    case invalidLength
    case invalidScript
    case invalidPermutation
}

/// Reversible decorative encoding of bytes through a cipher's symbol permutation and
/// an independently selected Script. The default overload remains the Base Rune Script
/// and is byte-for-byte compatible with the legacy codec.
struct RuneCodec {

    func encode(_ data: Data, with cipher: Cipher) -> String {
        // Base Rune is a statically validated portable Script.
        (try? encode(data, with: cipher, script: .baseRune)) ?? ""
    }

    func encode(
        _ data: Data,
        with cipher: Cipher,
        script: ScriptDescriptor
    ) throws -> String {
        guard Self.isValidPermutation(cipher.symbolPermutation) else {
            throw RuneCodecError.invalidPermutation
        }
        guard let alphabet = script.portableAlphabet else {
            throw RuneCodecError.invalidScript
        }
        var output = String()
        output.reserveCapacity((data.count * 8 + 4) / 5)
        for value in fiveBitGroups(of: data) {
            output.append(alphabet[cipher.symbolPermutation[value]])
        }
        return output
    }

    func decode(_ runes: String, with cipher: Cipher) throws -> Data {
        try decode(runes, with: cipher, script: .baseRune)
    }

    func decode(
        _ encoded: String,
        with cipher: Cipher,
        script: ScriptDescriptor
    ) throws -> Data {
        guard Self.isValidPermutation(cipher.symbolPermutation) else {
            throw RuneCodecError.invalidPermutation
        }
        guard let alphabet = script.portableAlphabet else {
            throw RuneCodecError.invalidScript
        }
        var alphabetIndexByToken: [Character: Int] = [:]
        for (index, token) in alphabet.enumerated() {
            alphabetIndexByToken[token] = index
        }
        var valueByAlphabetIndex = [Int](repeating: 0, count: 32)
        for (value, alphabetIndex) in cipher.symbolPermutation.enumerated() {
            valueByAlphabetIndex[alphabetIndex] = value
        }

        var groups: [Int] = []
        groups.reserveCapacity(encoded.count)
        for token in encoded {
            guard let alphabetIndex = alphabetIndexByToken[token] else {
                throw RuneCodecError.foreignCharacter
            }
            groups.append(valueByAlphabetIndex[alphabetIndex])
        }
        return try bytes(fromFiveBitGroups: groups)
    }

    // MARK: - Canonical unpadded base-32 (RFC 4648 bit order)

    private func fiveBitGroups(of data: Data) -> [Int] {
        var output: [Int] = []
        var buffer: UInt32 = 0
        var bitCount = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                output.append(Int((buffer >> UInt32(bitCount)) & 0x1F))
            }
        }
        if bitCount > 0 {
            output.append(Int((buffer << UInt32(5 - bitCount)) & 0x1F))
        }
        return output
    }

    private func bytes(fromFiveBitGroups groups: [Int]) throws -> Data {
        guard [0, 2, 4, 5, 7].contains(groups.count % 8) else {
            throw RuneCodecError.invalidLength
        }
        var output = Data()
        var buffer: UInt32 = 0
        var bitCount = 0
        for group in groups {
            buffer = (buffer << 5) | UInt32(group & 0x1F)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((buffer >> UInt32(bitCount)) & 0xFF))
            }
        }
        if bitCount > 0,
           (buffer & ((1 << UInt32(bitCount)) - 1)) != 0 {
            throw RuneCodecError.invalidLength
        }
        return output
    }

    private static func isValidPermutation(_ permutation: [Int]) -> Bool {
        permutation.count == 32 && Set(permutation) == Set(0..<32)
    }
}
