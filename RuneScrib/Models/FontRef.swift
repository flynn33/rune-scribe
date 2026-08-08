import Foundation
import CryptoKit
import RuneScribeContracts
import RuneScribePlatform

/// A non-secret reference to the rune font a cipher uses: a stable id, a version, and the
/// SHA-256 of the font file. Carried in the compact share payload; the actual font bytes
/// travel only in the file form of the package.
struct FontRef: Codable, Equatable {
    let id: String
    let version: Int
    let sha256: Data

    /// The single bundled font, hashed from the app bundle at first use (identical on every
    /// install, so sender and receiver agree).
    static let bundled: FontRef = {
        let data = bundledFontData()
        return FontRef(id: "noto-sans-runic", version: 1, sha256: Data(SHA256.hash(data: data)))
    }()

    /// Raw bytes of the bundled font (empty Data if somehow missing — the hash then simply
    /// won't match a real font, which surfaces as a validation failure rather than a crash).
    static func bundledFontData() -> Data {
        let locator = BundleApplicationResourceLocator(bundle: .main)
        return (try? locator.dataSynchronously(for: .bundledRuneFont)) ?? Data()
    }
}
