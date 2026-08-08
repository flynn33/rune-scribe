import Foundation
import RuneScribePlatform

/// Transitional facade for existing views. Pasteboard access is isolated in the
/// Platform product; link recognition remains in the legacy input layer until P4B.
@MainActor
enum Clipboard {
    private static let service = SystemClipboardService()

    static func copy(_ string: String) {
        try? service.setStringSynchronously(string)
    }

    static var changeCount: Int {
        service.changeCountSynchronously()
    }

    static func runeScribeURLString() -> String? {
        guard let raw = service.stringSynchronously() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return CipherSharePayload.isShareURL(trimmed) ? trimmed : nil
    }
}
