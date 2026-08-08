import Foundation
import RuneScribeContracts
import RuneScribePlatform

/// Transitional launch hook that registers bundled and previously imported fonts.
/// Validation, catalog policy, and persistence now belong to the Core application
/// service; this host adapter is removed with the legacy bootstrap in P6.
final class FontStore: Sendable {
    static let shared = FontStore()
    private let registrar: CoreTextFontRegistrar
    private let files: AppleProtectedFileStore

    init(
        registrar: CoreTextFontRegistrar = CoreTextFontRegistrar(),
        files: AppleProtectedFileStore = AppleProtectedFileStore()
    ) {
        self.registrar = registrar
        self.files = files
    }

    /// Registers the bundled font and every previously-imported font. Call once at launch.
    func registerBundledAndImportedFonts() {
        let locator = BundleApplicationResourceLocator(bundle: .main)
        if let data = try? locator.dataSynchronously(for: .bundledRuneFont) {
            _ = try? registrar.registerFontSynchronously(data)
        }
        let paths = (try? files.contentsSynchronously(
            of: .fontsDirectory,
            matchingExtension: "ttf"
        )) ?? []
        for path in paths {
            guard let data = try? files.readSynchronously(relativePath: path) else { continue }
            _ = try? registrar.registerFontSynchronously(data)
        }
    }
}
