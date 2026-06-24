import Foundation
import CryptoKit
import CoreText

enum FontStoreError: Error, LocalizedError {
    case unreadableFont
    case hashMismatch
    case cannotRegister
    var errorDescription: String? {
        switch self {
        case .unreadableFont: return "The font data is not a valid font."
        case .hashMismatch:   return "The font doesn't match the cipher's font reference."
        case .cannotRegister: return "The font could not be installed."
        }
    }
}

/// Owns the rune fonts available for rendering: registers the bundled font and any previously
/// imported fonts, validates and stores fonts that arrive inside a shared cipher, and resolves
/// a `FontRef` to a registered font name. Device-only; never downloads.
final class FontStore: @unchecked Sendable {
    static let shared = FontStore()
    private init() {}

    /// Display/PostScript name a `FontRef` resolves to, or nil if that font isn't present.
    func resolve(_ ref: FontRef) -> String? {
        if ref == .bundled { return "Noto Sans Runic" }
        let url = importedFontURL(ref)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              Data(SHA256.hash(data: data)) == ref.sha256 else { return nil }
        return Self.postScriptName(of: data)
    }

    /// Validates font bytes against `ref`, stores them in app-support, and registers them.
    /// Throws (changing nothing) on invalid font or hash mismatch.
    func importFont(_ bytes: Data, expecting ref: FontRef) throws {
        guard Data(SHA256.hash(data: bytes)) == ref.sha256 else { throw FontStoreError.hashMismatch }
        guard Self.postScriptName(of: bytes) != nil else { throw FontStoreError.unreadableFont }
        if ref == .bundled { return }
        let url = importedFontURL(ref)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        register(url)
    }

    /// Registers the bundled font and every previously-imported font. Call once at launch.
    func registerBundledAndImportedFonts() {
        if let url = Bundle.main.url(forResource: "NotoSansRunic-Regular", withExtension: "ttf") {
            register(url)
        }
        let dir = importedFontsDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "ttf" { register(url) }
    }

    // MARK: helpers

    private func register(_ url: URL) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    private func importedFontsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RuneScribFonts", isDirectory: true)
    }

    private func importedFontURL(_ ref: FontRef) -> URL {
        importedFontsDirectory().appendingPathComponent("\(ref.id)-v\(ref.version).ttf")
    }

    static func postScriptName(of data: Data) -> String? {
        guard let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else { return nil }
        return (cgFont.postScriptName as String?)
    }
}
