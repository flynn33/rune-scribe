@testable import RuneScribeUIModule
import XCTest

final class MessageAttachmentPolicyTests: XCTestCase {
    func testDecisionTruthTablePreservesRequiredAttachmentGate() {
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: true,
                canSendAttachments: false,
                utiSupported: false,
                requiredAttachment: false
            ),
            .allowed
        )
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: false,
                canSendAttachments: true,
                utiSupported: true,
                requiredAttachment: false
            ),
            .blockedCannotSendText
        )
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: true,
                canSendAttachments: false,
                utiSupported: true,
                requiredAttachment: true
            ),
            .blockedNeedsAttachment
        )
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: true,
                canSendAttachments: true,
                utiSupported: false,
                requiredAttachment: true
            ),
            .blockedNeedsAttachment
        )
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: true,
                canSendAttachments: true,
                utiSupported: true,
                requiredAttachment: true
            ),
            .allowed
        )
    }

    func testDeliveryIsConsumedOnlyAfterRequiredAttachmentAcceptance() {
        XCTAssertFalse(
            MessageAttachmentPolicy.shouldConsumeDelivery(
                sent: false,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            )
        )
        XCTAssertFalse(
            MessageAttachmentPolicy.shouldConsumeDelivery(
                sent: false,
                requiredAttachmentWasPresent: false,
                requiredAttachmentAccepted: false
            )
        )
        XCTAssertTrue(
            MessageAttachmentPolicy.shouldConsumeDelivery(
                sent: true,
                requiredAttachmentWasPresent: false,
                requiredAttachmentAccepted: false
            )
        )
        XCTAssertTrue(
            MessageAttachmentPolicy.shouldConsumeDelivery(
                sent: true,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            )
        )
        XCTAssertFalse(
            MessageAttachmentPolicy.shouldConsumeDelivery(
                sent: true,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: false
            )
        )
    }
}
