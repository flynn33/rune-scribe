import RuneScribePlatform

/// Transitional write-only facade for existing views. Clipboard reads and import
/// recognition are owned by Core's lifecycle/input path.
@MainActor
enum Clipboard {
    private static let service = SystemClipboardService()

    static func copy(_ string: String) {
        try? service.setStringSynchronously(string)
    }
}
