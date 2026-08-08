import Foundation
import CryptoKit
import RuneScribeContracts
import RuneScribePlatform

enum FontStoreError: Error, Equatable, LocalizedError {
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

protocol FontRegistrationService: Sendable {
    func postScriptName(for data: Data) throws -> String
    func register(_ data: Data) throws
}

struct LiveFontRegistrationService: FontRegistrationService {
    private let registrar = CoreTextFontRegistrar()

    func postScriptName(for data: Data) throws -> String {
        try registrar.postScriptNameSynchronously(forFontData: data)
    }

    func register(_ data: Data) throws {
        _ = try registrar.registerFontSynchronously(data)
    }
}

/// Owns the rune fonts available for rendering: registers the bundled font and any previously
/// imported fonts, validates and stores fonts that arrive inside a shared cipher, and resolves
/// a `FontRef` to a registered font name. Device-only; never downloads.
final class FontStore: Sendable {
    static let shared = FontStore()
    private let registrar: any FontRegistrationService
    private let files: AppleProtectedFileStore

    init(
        registrar: any FontRegistrationService = LiveFontRegistrationService(),
        files: AppleProtectedFileStore = AppleProtectedFileStore()
    ) {
        self.registrar = registrar
        self.files = files
    }

    /// Display/PostScript name a `FontRef` resolves to, or nil if that font isn't present.
    func resolve(_ ref: FontRef) -> String? {
        if ref == .bundled { return "Noto Sans Runic" }
        guard let path = try? importedFontPath(ref) else { return nil }
        guard let data = try? files.readSynchronously(relativePath: path),
              Data(SHA256.hash(data: data)) == ref.sha256 else { return nil }
        return try? registrar.postScriptName(for: data)
    }

    /// The raw bytes of the font a ref points to (bundled or imported), or nil if absent.
    func fontData(for ref: FontRef) -> Data? {
        if ref == .bundled { return FontRef.bundledFontData() }
        guard let path = try? importedFontPath(ref) else { return nil }
        guard let data = try? files.readSynchronously(relativePath: path),
              Data(SHA256.hash(data: data)) == ref.sha256 else { return nil }
        return data
    }

    /// Validates and registers font bytes before persisting them in app-support.
    /// Throws without writing on invalid data, hash mismatch, or registration failure.
    func importFont(_ bytes: Data, expecting ref: FontRef) throws {
        guard Data(SHA256.hash(data: bytes)) == ref.sha256 else { throw FontStoreError.hashMismatch }
        guard (try? registrar.postScriptName(for: bytes)) != nil else {
            throw FontStoreError.unreadableFont
        }
        if ref == .bundled { return }
        do {
            try registrar.register(bytes)
        } catch {
            throw FontStoreError.cannotRegister
        }
        try files.writeSynchronously(bytes, relativePath: importedFontPath(ref))
    }

    /// Registers the bundled font and every previously-imported font. Call once at launch.
    func registerBundledAndImportedFonts() {
        let locator = BundleApplicationResourceLocator(bundle: .main)
        if let data = try? locator.dataSynchronously(for: .bundledRuneFont) {
            try? registrar.register(data)
        }
        let paths = (try? files.contentsSynchronously(
            of: .fontsDirectory,
            matchingExtension: "ttf"
        )) ?? []
        for path in paths {
            guard let data = try? files.readSynchronously(relativePath: path) else { continue }
            try? registrar.register(data)
        }
    }

    // MARK: helpers

    /// Content-addressed by the font's SHA-256 hex so an attacker-controlled `ref.id`
    /// (parsed from a shared cipher) can't escape the fonts directory via path components.
    private func importedFontPath(_ ref: FontRef) throws -> ProtectedPath {
        let name = ref.sha256.map { String(format: "%02x", $0) }.joined()
        return try .fontsDirectory.appending("\(name).ttf")
    }

    static func postScriptName(of data: Data) -> String? {
        try? CoreTextFontRegistrar().postScriptNameSynchronously(forFontData: data)
    }
}
