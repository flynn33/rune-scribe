import Messages
import RuneScribeMessagesShared
import UIKit

@MainActor
final class MessagesViewController: MSMessagesAppViewController {
    private let titleLabel = UILabel()
    private let continueButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    private var invitation: MessagesValidatedInvitation?
    private var handoffIsInFlight = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        showUnavailableState()
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        configure(for: conversation.selectedMessage)
    }

    override func didSelect(
        _ message: MSMessage,
        conversation: MSConversation
    ) {
        super.didSelect(message, conversation: conversation)
        configure(for: message)
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Rune Scribe invitation"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center

        continueButton.translatesAutoresizingMaskIntoConstraints = false
        continueButton.configuration = .filled()
        continueButton.configuration?.title = "Continue to Rune Scribe"
        continueButton.addTarget(
            self,
            action: #selector(continueToRuneScribe),
            for: .touchUpInside
        )
        continueButton.accessibilityIdentifier = "messages.continue"

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            continueButton,
            statusLabel,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -24
            ),
            stack.centerYAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.centerYAnchor
            ),
            continueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func configure(for message: MSMessage?) {
        guard !handoffIsInFlight,
              let URL = message?.url,
              let validated = try? MessagesInvitationValidator.validate(URL)
        else {
            if !handoffIsInFlight { showUnavailableState() }
            return
        }
        invitation = validated
        continueButton.isEnabled = true
        statusLabel.text = nil
    }

    private func showUnavailableState() {
        invitation = nil
        continueButton.isEnabled = false
        statusLabel.text = "This invitation cannot be opened."
    }

    @objc private func continueToRuneScribe() {
        guard !handoffIsInFlight, let invitation else { return }
        handoffIsInFlight = true
        continueButton.isEnabled = false
        statusLabel.text = "Opening Rune Scribe…"

        Task {
            do {
                let inbox = try MessagesAppGroupInbox()
                _ = try await inbox.recordConfirmation(
                    for: invitation,
                    at: Date()
                )
                _ = try await inbox.recordOpenAttempt(
                    handoffID: invitation.handoffID,
                    at: Date()
                )
                openContainingApp(invitation, inbox: inbox)
            } catch {
                handoffIsInFlight = false
                continueButton.isEnabled = true
                statusLabel.text = "Rune Scribe could not be opened. Try again."
            }
        }
    }

    private func openContainingApp(
        _ invitation: MessagesValidatedInvitation,
        inbox: MessagesAppGroupInbox
    ) {
        guard let extensionContext else {
            recordOpenResult(.unknown, invitation: invitation, inbox: inbox)
            return
        }
        extensionContext.open(invitation.URL) { [weak self] opened in
            Task { @MainActor in
                self?.recordOpenResult(
                    opened ? .accepted : .rejected,
                    invitation: invitation,
                    inbox: inbox
                )
            }
        }
    }

    private func recordOpenResult(
        _ result: MessagesOpenResult,
        invitation: MessagesValidatedInvitation,
        inbox: MessagesAppGroupInbox
    ) {
        Task {
            _ = try? await inbox.recordOpenResult(
                handoffID: invitation.handoffID,
                result: result
            )
            guard result != .accepted else { return }
            handoffIsInFlight = false
            continueButton.isEnabled = true
            statusLabel.text = "Open Rune Scribe from the Home Screen to continue."
        }
    }
}
