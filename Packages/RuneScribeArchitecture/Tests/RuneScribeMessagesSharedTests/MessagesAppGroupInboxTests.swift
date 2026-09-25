import Foundation
import XCTest
@testable import RuneScribeMessagesShared

final class MessagesAppGroupInboxTests: XCTestCase {
    func testInboxPersistsIdempotentConfirmationAndLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuneScribeMessagesInboxTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = MessagesAppGroupInbox(directoryURL: directory)
        let invitation = try MessagesInvitationValidator.validate(try fixtureURL())

        let first = try await inbox.recordConfirmation(
            for: invitation,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let duplicate = try await inbox.recordConfirmation(
            for: invitation,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(first, duplicate)

        _ = try await inbox.recordOpenAttempt(
            handoffID: invitation.handoffID,
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )
        _ = try await inbox.recordOpenResult(
            handoffID: invitation.handoffID,
            result: .accepted
        )
        _ = try await inbox.recordAppState(
            handoffID: invitation.handoffID,
            state: .presented
        )

        let stored = try await inbox.envelope(handoffID: invitation.handoffID)
        XCTAssertEqual(stored?.openResult, .accepted)
        XCTAssertEqual(stored?.appState, .presented)
        let recoverable = try await inbox.pendingEnvelopes()
        XCTAssertEqual(recoverable.map(\.handoffID), [invitation.handoffID])

        _ = try await inbox.recordAppState(
            handoffID: invitation.handoffID,
            state: .completed
        )
        let completed = try await inbox.pendingEnvelopes()
        XCTAssertTrue(completed.isEmpty)

        try await inbox.remove(handoffID: invitation.handoffID)
        let removed = try await inbox.envelope(handoffID: invitation.handoffID)
        XCTAssertNil(removed)
    }

    func testInboxRejectsTraversalIdentifier() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuneScribeMessagesInboxTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = MessagesAppGroupInbox(directoryURL: directory)

        do {
            _ = try await inbox.envelope(handoffID: "../escape")
            XCTFail("Expected traversal identifier rejection")
        } catch let error as MessagesAppGroupInboxError {
            XCTAssertEqual(error, .invalidEnvelope)
        }
    }
}
