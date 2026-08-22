import Foundation
import RuneScribeProgressionSyncDomain
import Testing
@testable import RuneScribeCloudSyncModule

@Test
func resetIsFormallyOmittedAndNonzeroGenerationIsRejected() throws {
    #expect(!CloudResetPolicy.isResetSupported)
    #expect(CloudResetPolicy.current == .omittedUntilSynchronizedTombstonesAreAccepted)
    #expect(throws: CloudProgressionSchemaError.resetIsNotSupported) {
        try CloudResetPolicy.validate(resetGeneration: 1)
    }
    #expect(throws: CloudProgressionSchemaError.resetIsNotSupported) {
        _ = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: 1,
            resetGeneration: 1
        )
    }
}

@Test
func offlineQueueCoalescesRevisionsAndAcknowledgesIdempotently() throws {
    let empty = try CloudSyncQueue()
    let queued = try empty.enqueue(localRevision: 4).enqueue(localRevision: 7)
    #expect(queued.pendingRevision == 7)
    #expect(try queued.acknowledge(uploadedRevision: 6) == queued)
    #expect(try queued.acknowledge(uploadedRevision: 7) == CloudSyncQueue())

    let failed = try queued.recordFailure(.serviceUnavailable, now: date(100))
    #expect(failed.failedAttemptCount == 1)
    #expect(failed.nextEligibleAttemptAt == date(110))
    let offline = try failed.recordFailure(.offline, now: date(101))
    #expect(offline.pendingRevision == 7)
    #expect(offline.failedAttemptCount == 1)
    #expect(offline.nextEligibleAttemptAt == nil)

    let repeatedlyOffline = try (0 ..< 32).reduce(queued) { value, index in
        try value.recordFailure(.offline, now: date(TimeInterval(index)))
    }
    #expect(repeatedlyOffline.pendingRevision == 7)
    #expect(repeatedlyOffline.failedAttemptCount == 0)
    #expect(throws: CloudProgressionSchemaError.invalidCounter) {
        _ = try CloudSyncQueue(pendingRevision: 0)
    }
}

@Test
func accountChangesNeverRequestLocalDeletion() {
    let first = CloudOpaqueIdentifier(rawValue: String(repeating: "a", count: 64))!
    let second = CloudOpaqueIdentifier(rawValue: String(repeating: "b", count: 64))!
    #expect(CloudAccountChangePolicy.disposition(previous: first, current: first) == .unchanged)
    #expect(
        CloudAccountChangePolicy.disposition(previous: first, current: second)
            == .preserveLocalAndAwaitExplicitRebind
    )
    #expect(
        CloudAccountChangePolicy.disposition(previous: first, current: nil)
            == .preserveLocalAndAwaitExplicitRebind
    )
}

private func date(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: value) }
