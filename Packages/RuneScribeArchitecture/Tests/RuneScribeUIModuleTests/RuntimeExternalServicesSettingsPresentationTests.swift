import Foundation
import RuneScribeContracts
@testable import RuneScribeUIModule
import XCTest

final class RuntimeExternalServicesSettingsPresentationTests: XCTestCase {
    func testUnavailableSnapshotRetainsLocalFirstMessageWithoutOfferingAnAction() {
        let presentation = RuntimeExternalServicesSettingsPresentation(snapshot: nil)

        XCTAssertEqual(presentation.cloudStatus, "Status unavailable")
        XCTAssertEqual(
            presentation.cloudDetail,
            "Your local progress remains available on this device."
        )
        XCTAssertNil(presentation.cloudLastSuccessfulSyncAt)
        XCTAssertEqual(
            presentation.cloudDataScopeDetail,
            "Sync includes progression and appearance choices. Cipher keys, messages, contacts, QR content, and package bytes stay on this device."
        )
        XCTAssertEqual(presentation.gameCenterStatus, "Status unavailable")
        XCTAssertEqual(
            presentation.gameCenterDetail,
            "Your local progress remains available on this device."
        )
        XCTAssertNil(presentation.gameCenterActionTitle)
        XCTAssertFalse(presentation.gameCenterActionIsEnabled)
    }

    func testLocalOnlyCloudStatusExplainsAutomaticRecovery() throws {
        let presentation = RuntimeExternalServicesSettingsPresentation(
            snapshot: try makeSnapshot(cloudPhase: .localOnly)
        )

        XCTAssertEqual(presentation.cloudStatus, "On this device")
        XCTAssertEqual(
            presentation.cloudDetail,
            "Cloud sync will resume when it is available."
        )
    }

    func testQueuedAndOfflineCloudStatusesDescribeDurableLocalQueue() throws {
        let queued = RuntimeExternalServicesSettingsPresentation(
            snapshot: try makeSnapshot(cloudPhase: .queued)
        )
        XCTAssertEqual(queued.cloudStatus, "Sync queued")
        XCTAssertEqual(
            queued.cloudDetail,
            "Local changes will upload automatically."
        )

        let offline = RuntimeExternalServicesSettingsPresentation(
            snapshot: try makeSnapshot(cloudPhase: .waitingForNetwork)
        )
        XCTAssertEqual(offline.cloudStatus, "Waiting for network")
        XCTAssertEqual(
            offline.cloudDetail,
            "Changes are queued safely on this device."
        )
    }

    func testAccountChangeOffersRebindAndRetainsLastSuccessfulSync() throws {
        let lastSuccessfulSyncAt = Date(timeIntervalSince1970: 1_700_000_100)
        let presentation = RuntimeExternalServicesSettingsPresentation(
            snapshot: try makeSnapshot(
                cloudPhase: .accountChangeRequiresRebind,
                lastSuccessfulSyncAt: lastSuccessfulSyncAt
            )
        )

        XCTAssertEqual(presentation.cloudStatus, "iCloud account changed")
        XCTAssertEqual(
            presentation.cloudDetail,
            "Cloud sync is paused to protect progress. Your local progress remains available on this device."
        )
        XCTAssertEqual(presentation.cloudLastSuccessfulSyncAt, lastSuccessfulSyncAt)
        XCTAssertEqual(
            presentation.cloudActionTitle,
            "Resume with This iCloud Account"
        )
        XCTAssertEqual(presentation.cloudAction, .rebindAccount)
    }

    func testRetryExhaustedExplainsProbeAndPreservesScopeCopy() throws {
        let presentation = RuntimeExternalServicesSettingsPresentation(
            snapshot: try makeSnapshot(cloudPhase: .retryExhausted)
        )

        XCTAssertEqual(presentation.cloudStatus, "Sync paused after retries")
        XCTAssertEqual(
            presentation.cloudDetail,
            "Local progress is safe. Rune Scribe will probe the service again."
        )
        XCTAssertNil(presentation.cloudActionTitle)
        XCTAssertNil(presentation.cloudAction)
        XCTAssertTrue(presentation.cloudDataScopeDetail.contains("Cipher keys"))
        XCTAssertTrue(presentation.cloudDataScopeDetail.contains("stay on this device"))
    }

    func testGameCenterAvailableStateOffersExplicitUserAction() throws {
        let presentation = RuntimeExternalServicesSettingsPresentation(
            snapshot: try makeSnapshot(
                gameCenterConnection: .authenticationAvailable,
                pendingReportCount: 2
            )
        )

        XCTAssertEqual(presentation.gameCenterStatus, "Ready to connect")
        XCTAssertEqual(
            presentation.gameCenterDetail,
            "Connect only when you choose. 2 achievement update(s) are queued."
        )
        XCTAssertEqual(presentation.gameCenterActionTitle, "Connect to Game Center")
        XCTAssertTrue(presentation.gameCenterActionIsEnabled)
    }

    func testGameCenterAuthenticatingStateDisablesRepeatedAction() throws {
        let presentation = RuntimeExternalServicesSettingsPresentation(
            snapshot: try makeSnapshot(
                gameCenterConnection: .authenticating,
                authenticationWasUserInitiated: true
            )
        )

        XCTAssertEqual(presentation.gameCenterStatus, "Connecting")
        XCTAssertEqual(presentation.gameCenterDetail, "Waiting for Game Center…")
        XCTAssertEqual(presentation.gameCenterActionTitle, "Connecting…")
        XCTAssertFalse(presentation.gameCenterActionIsEnabled)
    }

    func testGameCenterConnectedStateOffersStopMirroringAction() throws {
        let presentation = RuntimeExternalServicesSettingsPresentation(
            snapshot: try makeSnapshot(gameCenterConnection: .connected)
        )

        XCTAssertEqual(presentation.gameCenterStatus, "Connected")
        XCTAssertEqual(
            presentation.gameCenterDetail,
            "Eligible achievements are mirrored to Game Center."
        )
        XCTAssertEqual(presentation.gameCenterActionTitle, "Stop Mirroring")
        XCTAssertTrue(presentation.gameCenterActionIsEnabled)
    }

    private func makeSnapshot(
        cloudPhase: RuntimeCloudSyncPhaseDTO = .localOnly,
        lastSuccessfulSyncAt: Date? = nil,
        gameCenterConnection: RuntimeGameCenterConnectionDTO = .disabled,
        pendingReportCount: UInt16 = 0,
        authenticationWasUserInitiated: Bool = false
    ) throws -> RuntimeCloudGameCenterStatusSnapshotDTO {
        try RuntimeCloudGameCenterStatusSnapshotDTO(
            revision: 7,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            cloudSync: RuntimeCloudSyncStatusDTO(
                phase: cloudPhase,
                accountStatus: .unknown,
                localRevision: 6,
                pendingRevision: 6,
                lastSuccessfulSyncAt: lastSuccessfulSyncAt,
                persistenceIsDurable: true
            ),
            gameCenter: RuntimeGameCenterStatusDTO(
                connection: gameCenterConnection,
                reportStatus: pendingReportCount == 0 ? .localOnly : .pending,
                pendingReportCount: pendingReportCount,
                isOptedIn: gameCenterConnection != .disabled,
                authenticationWasUserInitiated: authenticationWasUserInitiated,
                persistenceIsDurable: true
            )
        )
    }
}
