import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
import XCTest

final class CoreProgressionFactFactoryTests: XCTestCase {
    func testDomainFactsMatchAllCanonicalPayloadShapes() throws {
        let cipher = token(CipherToken.self, "11")
        let message = token(MessageToken.self, "22")
        let package = token(PackageToken.self, "33")
        let relationship = token(RelationshipToken.self, "44")
        let norse = CoreProgressionFactFactory.implicitNorseCodexID

        let facts = try [
            CoreProgressionFactFactory.cipherCreated(cipherToken: cipher),
            CoreProgressionFactFactory.cipherImported(
                cipherToken: cipher,
                routeClass: .file
            ),
            CoreProgressionFactFactory.messageEncoded(
                messageToken: message,
                cipherToken: cipher
            ),
            CoreProgressionFactFactory.firstDeliveryCompleted(
                cipherToken: cipher,
                relationshipToken: relationship
            ),
            CoreProgressionFactFactory.messageImported(
                packageToken: package,
                routeClass: .file,
                embeddedCipher: true
            ),
            CoreProgressionFactFactory.messageDecoded(
                packageToken: package,
                relationshipToken: relationship
            ),
            CoreProgressionFactFactory.bidirectionalEstablished(
                relationshipToken: relationship
            ),
            CoreProgressionFactFactory.presentationObserved(
                packageToken: package,
                codexIDs: [norse]
            ),
        ]

        XCTAssertEqual(
            facts.map(\.eventType.rawValue),
            [
                "runescribe.cipher.created",
                "runescribe.cipher.imported",
                "runescribe.message.encoded",
                "runescribe.cipher.first-delivery-completed",
                "runescribe.message.imported",
                "runescribe.message.decoded",
                "runescribe.exchange.bidirectional-established",
                "runescribe.presentation.observed",
            ]
        )
        XCTAssertTrue(facts.allSatisfy {
            $0.eligibility == DomainEventEligibilityMetadata(
                state: .eligible,
                reason: EligibilityReasonID(
                    rawValue: "eligibility.eligible.domain-commit"
                )!
            )
        })
        XCTAssertEqual(facts[2].payload.codexIDs, [norse])
        XCTAssertEqual(facts[4].payload.codexIDs, [norse])
        XCTAssertEqual(facts[5].payload.codexIDs, [norse])
        XCTAssertTrue(facts.flatMap(\.payload.artifactIDs).isEmpty)
    }

    func testEligibleShareRoutesProduceExactReasonsAndRoutes() throws {
        let message = token(MessageToken.self, "55")
        let relationship = token(RelationshipToken.self, "66")
        let cases: [(SharePresentationReportDTO, DomainEventRouteClass, String)] = [
            (
                try SharePresentationReportDTO(
                    routeClass: .messages,
                    result: .sentConfirmed,
                    requiredAttachmentAccepted: true
                ),
                .messages,
                "eligibility.eligible.message-sent-confirmed"
            ),
            (
                try SharePresentationReportDTO(
                    routeClass: .shareSheet,
                    result: .completedBySystem
                ),
                .shareSheet,
                "eligibility.eligible.share-completed-by-system"
            ),
            (
                try SharePresentationReportDTO(
                    routeClass: .airDrop,
                    result: .completedBySystem
                ),
                .airDrop,
                "eligibility.eligible.share-completed-by-system"
            ),
        ]

        for (report, route, reason) in cases {
            let fact = try XCTUnwrap(CoreProgressionFactFactory.shareCompleted(
                report: report,
                messageToken: message,
                keyIncluded: true,
                relationshipToken: relationship,
                linkedRelationship: true
            ))
            XCTAssertEqual(fact.eventType.rawValue, "runescribe.share.completed")
            XCTAssertEqual(fact.payload.routeClass, route)
            XCTAssertEqual(fact.eligibility.state, .eligible)
            XCTAssertEqual(fact.eligibility.reason.rawValue, reason)
        }
    }

    func testIneligibleTerminalRoutesNeverProduceShareFact() throws {
        let message = token(MessageToken.self, "77")
        let reports = [
            try SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: false
            ),
            try SharePresentationReportDTO(
                routeClass: .fileExport,
                result: .completionUnavailable
            ),
            try SharePresentationReportDTO(
                routeClass: .clipboard,
                result: .completionUnavailable
            ),
            try SharePresentationReportDTO(
                routeClass: .qrDisplay,
                result: .completionUnavailable
            ),
            try SharePresentationReportDTO(
                routeClass: .shareSheet,
                result: .cancelled
            ),
            try SharePresentationReportDTO(
                routeClass: .airDrop,
                result: .failed
            ),
        ]

        for report in reports {
            XCTAssertNil(try CoreProgressionFactFactory.shareCompleted(
                report: report,
                messageToken: message,
                keyIncluded: true,
                relationshipToken: nil,
                linkedRelationship: false
            ))
        }
    }

    func testEligibleShareRequiresConsistentRelationshipEvidence() throws {
        let report = try SharePresentationReportDTO(
            routeClass: .shareSheet,
            result: .completedBySystem
        )
        let message = token(MessageToken.self, "88")
        let relationship = token(RelationshipToken.self, "99")

        XCTAssertThrowsError(try CoreProgressionFactFactory.shareCompleted(
            report: report,
            messageToken: message,
            keyIncluded: false,
            relationshipToken: relationship,
            linkedRelationship: false
        )) { error in
            XCTAssertEqual(error as? CoreProgressionFactError, .invalidRelationshipEvidence)
        }
        let linkedWithoutToken = try CoreProgressionFactFactory.shareCompleted(
            report: report,
            messageToken: message,
            keyIncluded: false,
            relationshipToken: nil,
            linkedRelationship: true
        )
        XCTAssertEqual(linkedWithoutToken?.payload.linkedRelationship, true)
        XCTAssertNil(linkedWithoutToken?.payload.relationshipToken)
    }

    func testSerializedFactsContainNoSourceIdentityOrPayloadMaterial() throws {
        let forbidden = [
            "cipher-id-sentinel",
            "contact-id-sentinel",
            "phone-sentinel",
            "email-sentinel",
            "plaintext-sentinel",
            "runes-sentinel",
            "key-sentinel",
            "package-bytes-sentinel",
        ]
        let fact = try CoreProgressionFactFactory.messageImported(
            packageToken: token(PackageToken.self, "aa"),
            routeClass: .file,
            embeddedCipher: false
        )
        let encoded = String(decoding: try JSONEncoder().encode(fact), as: UTF8.self)

        for value in forbidden {
            XCTAssertFalse(encoded.contains(value))
        }
        XCTAssertTrue(fact.payload.artifactIDs.isEmpty)
        XCTAssertNil(fact.payload.relationshipToken)
    }

    private func token<Domain>(
        _ type: PrivacySafeToken<Domain>.Type,
        _ pair: String
    ) -> PrivacySafeToken<Domain> {
        PrivacySafeToken(rawValue: String(repeating: pair, count: 32))!
    }
}
