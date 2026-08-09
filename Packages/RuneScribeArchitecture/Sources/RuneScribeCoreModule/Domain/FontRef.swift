import Foundation

/// A non-secret reference to the rune font a cipher uses: a stable id, a version, and the
/// SHA-256 of the font file. Carried in the compact share payload; the actual font bytes
/// travel only in the file form of the package.
struct FontRef: Codable, Equatable, Sendable {
    let id: String
    let version: Int
    let sha256: Data

    /// Stable identity of the shipping Noto Sans Runic resource. Core never reads a bundle;
    /// hosts and tests inject bytes and validate them against this fixed digest.
    static let bundled = FontRef(
        id: "noto-sans-runic",
        version: 1,
        sha256: Data([
            0x61, 0x5b, 0x6c, 0x11, 0x66, 0xa8, 0xc5, 0x18,
            0x16, 0xdc, 0x15, 0x36, 0x78, 0x4a, 0xcb, 0xf4,
            0x86, 0x54, 0x7e, 0x3b, 0xed, 0x03, 0xdb, 0xfd,
            0xd7, 0x09, 0x10, 0xe1, 0x00, 0x66, 0x79, 0x3b,
        ])
    )

    var hasValidWireShape: Bool {
        let idLength = id.lengthOfBytes(using: .utf8)
        return (1...16).contains(idLength)
            && (1...Int(UInt32.max)).contains(version)
            && sha256.count == 32
    }
}
