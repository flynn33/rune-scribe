#if os(iOS)
import Foundation
import RuneScribeContracts
import RuneScribeMessagesShared

@MainActor
final class MessagesImportInboxDrainer {
    typealias Delivery = @MainActor (URL) -> InboundInputDispositionDTO

    private let inbox: MessagesAppGroupInbox?
    private var isDraining = false
    private var deliveredHandoffIDs: Set<String> = []

    init(inbox: MessagesAppGroupInbox? = try? MessagesAppGroupInbox()) {
        self.inbox = inbox
    }

    func drain(deliver: Delivery) async {
        guard !isDraining, let inbox else { return }
        isDraining = true
        defer { isDraining = false }

        guard let envelopes = try? await inbox.pendingEnvelopes() else { return }
        for envelope in envelopes {
            guard !deliveredHandoffIDs.contains(envelope.handoffID) else {
                continue
            }
            let disposition = deliver(envelope.invitationURL)
            guard disposition == .accepted else { continue }
            deliveredHandoffIDs.insert(envelope.handoffID)
            _ = try? await inbox.recordAppState(
                handoffID: envelope.handoffID,
                state: .presented
            )
        }
    }

    func acknowledgeDirectDelivery(
        of URL: URL,
        disposition: InboundInputDispositionDTO
    ) async {
        guard disposition == .accepted,
              let inbox,
              let invitation = try? MessagesInvitationValidator.validate(URL)
        else { return }
        guard (try? await inbox.envelope(handoffID: invitation.handoffID)) != nil
        else { return }
        deliveredHandoffIDs.insert(invitation.handoffID)
        _ = try? await inbox.recordAppState(
            handoffID: invitation.handoffID,
            state: .presented
        )
    }

    func recordTerminalState(
        handoffID: String,
        state: MessagesImportAppState
    ) async {
        guard state == .completed || state == .declined,
              let inbox
        else { return }
        _ = try? await inbox.recordAppState(
            handoffID: handoffID,
            state: state
        )
        deliveredHandoffIDs.remove(handoffID)
    }
}
#endif
