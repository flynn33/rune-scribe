import Foundation
import RuneScribeContracts

enum RuntimeCloudSettingsAction: Equatable, Sendable {
    case rebindAccount
}

struct RuntimeExternalServicesSettingsPresentation: Equatable, Sendable {
    let cloudStatus: String
    let cloudDetail: String
    let cloudLastSuccessfulSyncAt: Date?
    let cloudDataScopeDetail: String
    let cloudActionTitle: String?
    let cloudAction: RuntimeCloudSettingsAction?
    let gameCenterStatus: String
    let gameCenterDetail: String
    let gameCenterActionTitle: String?
    let gameCenterActionIsEnabled: Bool
    let gameCenterAction: RuntimeGameCenterParticipationIntentDTO?

    init(snapshot: RuntimeCloudGameCenterStatusSnapshotDTO?) {
        guard let snapshot else {
            cloudStatus = "Status unavailable"
            cloudDetail = Self.localProgressionMessage
            cloudLastSuccessfulSyncAt = nil
            cloudDataScopeDetail = Self.cloudDataScopeMessage
            cloudActionTitle = nil
            cloudAction = nil
            gameCenterStatus = "Status unavailable"
            gameCenterDetail = Self.localProgressionMessage
            gameCenterActionTitle = nil
            gameCenterActionIsEnabled = false
            gameCenterAction = nil
            return
        }

        (cloudStatus, cloudDetail, cloudActionTitle, cloudAction) = Self.cloudPresentation(
            snapshot.cloudSync
        )
        cloudLastSuccessfulSyncAt = snapshot.cloudSync.lastSuccessfulSyncAt
        cloudDataScopeDetail = Self.cloudDataScopeMessage
        (
            gameCenterStatus,
            gameCenterDetail,
            gameCenterActionTitle,
            gameCenterActionIsEnabled,
            gameCenterAction
        ) = Self.gameCenterPresentation(snapshot.gameCenter)
    }

    private static let localProgressionMessage =
        "Your local progress remains available on this device."
    private static let cloudDataScopeMessage =
        "Sync includes progression and appearance choices. Cipher keys, messages, contacts, QR content, and package bytes stay on this device."

    private static func cloudPresentation(
        _ status: RuntimeCloudSyncStatusDTO
    ) -> (String, String, String?, RuntimeCloudSettingsAction?) {
        switch status.phase {
        case .disabled:
            return ("Unavailable", localProgressionMessage, nil, nil)
        case .localOnly:
            return ("On this device", "Cloud sync will resume when it is available.", nil, nil)
        case .waitingForNetwork:
            return ("Waiting for network", "Changes are queued safely on this device.", nil, nil)
        case .waitingForAccount:
            return ("Waiting for iCloud", "Sign in to iCloud to resume sync. \(localProgressionMessage)", nil, nil)
        case .queued:
            return ("Sync queued", "Local changes will upload automatically.", nil, nil)
        case .synchronizing:
            return ("Syncing", "Rune Scribe is reconciling progression changes.", nil, nil)
        case .awaitingLocalApply:
            return ("Applying changes", "Cloud progress is waiting for local validation.", nil, nil)
        case .current:
            return ("Up to date", "Progression is current in iCloud.", nil, nil)
        case .quarantinedRemote:
            return (
                "Protected local progress",
                "An invalid cloud record was ignored. \(localProgressionMessage)",
                nil,
                nil
            )
        case .accountChangeRequiresRebind:
            return (
                "iCloud account changed",
                "Cloud sync is paused to protect progress. \(localProgressionMessage)",
                "Resume with This iCloud Account",
                .rebindAccount
            )
        case .persistenceDegraded:
            return ("Sync storage unavailable", localProgressionMessage, nil, nil)
        case .retryExhausted:
            return (
                "Sync paused after retries",
                "Local progress is safe. Rune Scribe will probe the service again.",
                nil,
                nil
            )
        }
    }

    private static func gameCenterPresentation(
        _ status: RuntimeGameCenterStatusDTO
    ) -> (String, String, String?, Bool, RuntimeGameCenterParticipationIntentDTO?) {
        let pending = status.pendingReportCount == 0
            ? ""
            : " \(status.pendingReportCount) achievement update(s) are queued."
        switch status.connection {
        case .disabled:
            return (
                "Not connected",
                "Game Center is optional. \(localProgressionMessage)",
                "Connect to Game Center",
                true,
                .optIn
            )
        case .authenticationAvailable:
            return (
                "Ready to connect",
                "Connect only when you choose.\(pending)",
                "Connect to Game Center",
                true,
                .optIn
            )
        case .authenticating:
            return ("Connecting", "Waiting for Game Center…", "Connecting…", false, nil)
        case .connected:
            let detail = pending.isEmpty
                ? "Eligible achievements are mirrored to Game Center."
                : "Connected.\(pending)"
            return ("Connected", detail, "Stop Mirroring", true, .optOut)
        case .declined:
            return (
                "Not connected",
                "Game Center permission was declined. \(localProgressionMessage)",
                "Try Game Center Again",
                true,
                .optIn
            )
        case .cancelled:
            return (
                "Connection cancelled",
                localProgressionMessage,
                "Try Game Center Again",
                true,
                .optIn
            )
        case .restricted:
            return ("Restricted", localProgressionMessage, nil, false, nil)
        case .offline:
            return (
                "Offline",
                "Achievement updates remain queued. \(localProgressionMessage)",
                "Try Game Center Again",
                true,
                .optIn
            )
        case .unavailable:
            return (
                "Unavailable",
                localProgressionMessage,
                "Try Game Center Again",
                true,
                .optIn
            )
        }
    }
}
