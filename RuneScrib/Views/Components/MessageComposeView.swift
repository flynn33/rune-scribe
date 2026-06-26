#if os(iOS)
import SwiftUI
import MessageUI

/// Thin SwiftUI bridge to the system Messages compose sheet. Presents a prefilled
/// draft (runes + import link); the user taps Send in Apple's own UI.
struct MessageComposeView: UIViewControllerRepresentable {
    var messageText: String
    var recipients: [String]?
    var onFinish: (() -> Void)?

    /// Whether this device can send texts at all (no SIM / Simulator → false).
    /// `canSendText()` is main-actor-isolated (MFMessageComposeViewController is a
    /// UIViewController), so this accessor is too; it is only read from the view body.
    @MainActor static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        vc.body = messageText
        if let recipients { vc.recipients = recipients }
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (() -> Void)?
        init(onFinish: (() -> Void)?) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            // Only treat an actual send as delivery; cancelled/failed leave state alone.
            // Call onFinish synchronously here (this delegate callback is already on the
            // main actor) rather than from the dismiss completion — passing a closure that
            // captures the non-Sendable onFinish into dismiss's completion is a Swift 6
            // data-race error.
            if result == .sent { onFinish?() }
            controller.dismiss(animated: true)
        }
    }
}
#endif
