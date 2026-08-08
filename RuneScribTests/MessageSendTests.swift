import XCTest
@testable import RuneScrib

final class MessageSendTests: XCTestCase {
}

// MARK: - Outbound attachment policy (F-003 / AC-011, AC-012, AC-014)

extension MessageSendTests {

    // A message with no required attachment only needs text capability.
    func testDecideNoAttachmentAllowedWhenCanSendText() {
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(canSendText: true, canSendAttachments: false,
                                           utiSupported: false, requiredAttachment: false),
            .allowed)
    }

    // No text capability at all blocks the composer regardless of attachments.
    func testDecideBlockedWhenCannotSendText() {
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(canSendText: false, canSendAttachments: true,
                                           utiSupported: true, requiredAttachment: false),
            .blockedCannotSendText)
    }

    // A key-bearing message is blocked when the device can't send attachments…
    func testDecideRequiredAttachmentBlockedWhenAttachmentsUnavailable() {
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(canSendText: true, canSendAttachments: false,
                                           utiSupported: true, requiredAttachment: true),
            .blockedNeedsAttachment)
    }

    // …or when our UTI isn't supported for attachments.
    func testDecideRequiredAttachmentBlockedWhenUTIUnsupported() {
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(canSendText: true, canSendAttachments: true,
                                           utiSupported: false, requiredAttachment: true),
            .blockedNeedsAttachment)
    }

    // With full support present, a key-bearing message may be presented.
    func testDecideRequiredAttachmentAllowedWhenSupported() {
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(canSendText: true, canSendAttachments: true,
                                           utiSupported: true, requiredAttachment: true),
            .allowed)
    }

    // Delivery is consumed only on a real send; a key-bearing message additionally requires
    // the attachment to have been accepted — the core invariant protecting the one-time key.
    func testShouldConsumeDeliveryTruthTable() {
        // Not sent (cancelled/failed) → never consume.
        XCTAssertFalse(MessageAttachmentPolicy.shouldConsumeDelivery(
            sent: false, requiredAttachmentWasPresent: true, requiredAttachmentAccepted: true))
        XCTAssertFalse(MessageAttachmentPolicy.shouldConsumeDelivery(
            sent: false, requiredAttachmentWasPresent: false, requiredAttachmentAccepted: false))

        // Sent, no required attachment (a follow-up message) → consume.
        XCTAssertTrue(MessageAttachmentPolicy.shouldConsumeDelivery(
            sent: true, requiredAttachmentWasPresent: false, requiredAttachmentAccepted: false))

        // Sent with the key attachment accepted → consume.
        XCTAssertTrue(MessageAttachmentPolicy.shouldConsumeDelivery(
            sent: true, requiredAttachmentWasPresent: true, requiredAttachmentAccepted: true))

        // Sent but the required key attachment was NOT accepted → must NOT consume, so the
        // key isn't marked delivered when the recipient never actually received it.
        XCTAssertFalse(MessageAttachmentPolicy.shouldConsumeDelivery(
            sent: true, requiredAttachmentWasPresent: true, requiredAttachmentAccepted: false))
    }
}
