import Foundation
import XCTest
@testable import RuneScribeMessagesShared

final class MessagesImportEnvelopeTests: XCTestCase {
    func testEnvelopeEncodesOnlyAcceptedRecoveryFields() throws {
        let invitation = try MessagesInvitationValidator.validate(try fixtureURL())
        var envelope = MessagesImportEnvelope(
            invitation: invitation,
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        envelope.recordOpenAttempt(at: Date(timeIntervalSince1970: 1_700_000_001))
        envelope.recordOpenResult(.accepted)
        envelope.recordAppState(.presented)

        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "schemaVersion",
            "handoffID",
            "invitationURL",
            "confirmedAtEpochMilliseconds",
            "openAttemptedAtEpochMilliseconds",
            "openResult",
            "appState",
        ])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["openResult"] as? String, "accepted")
        XCTAssertEqual(object["appState"] as? String, "presented")
        XCTAssertEqual(
            (object["confirmedAtEpochMilliseconds"] as? NSNumber)?.int64Value,
            1_700_000_000_000
        )
        XCTAssertEqual(
            (object["openAttemptedAtEpochMilliseconds"] as? NSNumber)?.int64Value,
            1_700_000_001_000
        )
        XCTAssertNoThrow(try envelope.validate())
    }
}
