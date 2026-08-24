import Foundation
import RuneScribeContracts
@testable import RuneScribeUIModule
import XCTest

final class MessageAttachmentPolicyTests: XCTestCase {
    func testShareBuilderTerminalDispositionDistinguishesCompletionCancellationAndFailure() {
        XCTAssertEqual(
            ShareBuilderTerminalDisposition(routeResult: .completedBySystem),
            .completed
        )
        XCTAssertEqual(
            ShareBuilderTerminalDisposition(routeResult: .sentConfirmed),
            .completed
        )
        XCTAssertEqual(
            ShareBuilderTerminalDisposition(routeResult: .cancelled),
            .cancelled
        )
        for routeResult in [
            ShareRouteResultDTO.presented,
            .failed,
            .completionUnavailable,
        ] {
            XCTAssertEqual(
                ShareBuilderTerminalDisposition(routeResult: routeResult),
                .failed
            )
        }
    }

    func testPlainCopyCannotConsumeAnInFlightTypedShareArtifact() {
        XCTAssertTrue(
            MessageResultActionPolicy.allowsPlainCopy(
                artifactPreparationInFlight: false,
                hasPendingArtifact: false
            )
        )
        XCTAssertFalse(
            MessageResultActionPolicy.allowsPlainCopy(
                artifactPreparationInFlight: true,
                hasPendingArtifact: false
            )
        )
        XCTAssertFalse(
            MessageResultActionPolicy.allowsPlainCopy(
                artifactPreparationInFlight: false,
                hasPendingArtifact: true
            )
        )
        XCTAssertFalse(
            MessageResultActionPolicy.allowsPlainCopy(
                artifactPreparationInFlight: true,
                hasPendingArtifact: true
            )
        )
    }

    func testCanonicalMessageArtifactRequiresTypedRuneScribeFile() {
        let artifactID = ShareArtifactID(rawValue: UUID())
        let canonical = ShareArtifactDTO(
            id: artifactID,
            reference: .file(artifactID),
            displayName: "Rune Scribe Message",
            contentType: RuneScribeWireFormat.contentType,
            fileExtension: RuneScribeWireFormat.fileExtension,
            lifetime: .singleUse,
            requiresKeyDelivery: false
        )
        XCTAssertTrue(CanonicalMessageArtifactPolicy.accepts(canonical))

        let opaque = ShareArtifactDTO(
            id: artifactID,
            reference: .opaque(artifactID),
            displayName: canonical.displayName,
            contentType: "text/plain",
            fileExtension: nil,
            lifetime: .singleUse,
            requiresKeyDelivery: false
        )
        XCTAssertFalse(CanonicalMessageArtifactPolicy.accepts(opaque))

        let wrongContentType = ShareArtifactDTO(
            id: artifactID,
            reference: .file(artifactID),
            displayName: canonical.displayName,
            contentType: "application/octet-stream",
            fileExtension: RuneScribeWireFormat.fileExtension,
            lifetime: .singleUse,
            requiresKeyDelivery: true
        )
        XCTAssertFalse(CanonicalMessageArtifactPolicy.accepts(wrongContentType))

        let wrongReferenceID = ShareArtifactDTO(
            id: artifactID,
            reference: .file(ShareArtifactID(rawValue: UUID())),
            displayName: canonical.displayName,
            contentType: RuneScribeWireFormat.contentType,
            fileExtension: RuneScribeWireFormat.fileExtension,
            lifetime: .singleUse,
            requiresKeyDelivery: true
        )
        XCTAssertFalse(CanonicalMessageArtifactPolicy.accepts(wrongReferenceID))
    }

    func testDecisionTruthTableRequiresCanonicalPackageCapability() {
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: true,
                canSendAttachments: false,
                utiSupported: false
            ),
            .blockedNeedsAttachment
        )
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: false,
                canSendAttachments: true,
                utiSupported: true
            ),
            .blockedCannotSendText
        )
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: true,
                canSendAttachments: false,
                utiSupported: true
            ),
            .blockedNeedsAttachment
        )
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: true,
                canSendAttachments: true,
                utiSupported: false
            ),
            .blockedNeedsAttachment
        )
        XCTAssertEqual(
            MessageAttachmentPolicy.decide(
                canSendText: true,
                canSendAttachments: true,
                utiSupported: true
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
        XCTAssertFalse(
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
