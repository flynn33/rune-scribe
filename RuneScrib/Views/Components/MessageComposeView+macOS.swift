// RuneScrib/Views/Components/MessageComposeView+macOS.swift

#if os(macOS)
import AppKit

/// macOS analog to the iOS `MessageComposeView`: there is no `MFMessageComposeViewController`
/// on the Mac, so the outbound `.runescribe` message file is handed to the system Messages
/// composer via `NSSharingService(named: .composeMessage)`. The key rides in the attachment,
/// exactly as on iOS.
enum MacMessageComposer {

    /// Whether the Messages compose sharing service is available on this Mac.
    static var canSend: Bool { NSSharingService(named: .composeMessage) != nil }

    /// Writes the attachment to a temp `.runescribe` file (inside the sandbox container) and
    /// opens the Messages composer prefilled with `body` and the file. `delivered` is left to
    /// the recipient-confirmed iOS path; we deliberately don't flip it here because
    /// NSSharingService has no reliable per-send completion, and re-sending the key is harmless.
    @MainActor
    static func send(body: String, attachmentData: Data?) {
        guard let service = NSSharingService(named: .composeMessage) else { return }

        var items: [Any] = [body]
        if let attachmentData {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                let url = dir
                    .appendingPathComponent("RuneScrib-Message")
                    .appendingPathExtension(RuneScribeShare.fileExtension)
                if (try? attachmentData.write(to: url, options: .atomic)) != nil {
                    items.append(url)
                }
            }
        }
        service.perform(withItems: items)
    }
}
#endif
