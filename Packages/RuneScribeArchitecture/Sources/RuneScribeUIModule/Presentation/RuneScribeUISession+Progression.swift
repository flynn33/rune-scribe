import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum OptionalProgressionRailState: Equatable, Sendable {
    case loading
    case available
    case degraded
    case unavailable
}

struct UnlockFeedbackPreferences: Equatable, Sendable {
    var soundEnabled: Bool
    var hapticEnabled: Bool
    var animationEnabled: Bool

    static let defaults = Self(
        soundEnabled: true,
        hapticEnabled: true,
        animationEnabled: true
    )

    init(
        soundEnabled: Bool,
        hapticEnabled: Bool,
        animationEnabled: Bool
    ) {
        self.soundEnabled = soundEnabled
        self.hapticEnabled = hapticEnabled
        self.animationEnabled = animationEnabled
    }

    init(snapshot: RuntimeSettingsSnapshotDTO) {
        soundEnabled = snapshot[
            RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled
        ]?.booleanValue ?? Self.defaults.soundEnabled
        hapticEnabled = snapshot[
            RuneScribeRuntimeSettings.unlockFeedbackHapticsEnabled
        ]?.booleanValue ?? Self.defaults.hapticEnabled
        animationEnabled = snapshot[
            RuneScribeRuntimeSettings.unlockFeedbackAnimationEnabled
        ]?.booleanValue ?? Self.defaults.animationEnabled
    }
}

enum ProgressionRevealBlocker: Hashable, Sendable {
    case rootPresentation
    case workspaceModal
    case systemShare
}

enum ProgressionRevealUnsafeSurface: CaseIterable, Sendable {
    case lockOrPIN
    case systemShare
    case messages
    case fileImport
    case qrCameraOrDisplay
    case importConfirmation
    case receivedMessageDecode
    case securityWarning

    var blocker: ProgressionRevealBlocker {
        switch self {
        case .systemShare:
            .systemShare
        case .lockOrPIN, .fileImport, .importConfirmation,
             .receivedMessageDecode, .securityWarning:
            .rootPresentation
        case .messages, .qrCameraOrDisplay:
            .workspaceModal
        }
    }
}

enum UnlockRevealVisualMode: Equatable, Sendable {
    case movement
    case crossfadeHighlight
    case none
}

struct UnlockRevealPresentationPlan: Equatable, Sendable {
    let revealID: RevealID
    let sequenceDurationSeconds: Double
    let visualMode: UnlockRevealVisualMode
    let announcement: String?
    let isStatic: Bool

    var automaticFinishDelaySeconds: Double? {
        isStatic ? nil : sequenceDurationSeconds
    }
}

struct ProgressionRevealStartDisposition: Equatable, Sendable {
    let shouldAnnounce: Bool
    let shouldPerformFeedback: Bool
    let isStatic: Bool
}

struct ProgressionRevealQueueModel: Sendable {
    private(set) var blockers: Set<ProgressionRevealBlocker> = [.rootPresentation]
    private(set) var activeReveal: ProgressionRevealSummaryDTO?
    private(set) var startedRevealID: RevealID?
    private(set) var markInFlightRevealID: RevealID?

    private var head: ProgressionRevealSummaryDTO?
    private var canPresent = false
    private var durablyPresentedRevealIDs: Set<RevealID> = []
    private var freshlyMarkedRevealIDs: Set<RevealID> = []
    private var acknowledgedRevealIDs: Set<RevealID> = []
    private var announcedRevealIDs: Set<RevealID> = []
    private var feedbackRevealIDs: Set<RevealID> = []
    private var acknowledgementInFlightRevealID: RevealID?

    mutating func setBlocker(
        _ blocker: ProgressionRevealBlocker,
        active: Bool
    ) {
        if active {
            if blockers.insert(blocker).inserted {
                interrupt()
            }
        } else {
            blockers.remove(blocker)
            presentNextIfSafe()
        }
    }

    mutating func adopt(
        head: ProgressionRevealSummaryDTO?,
        canPresent: Bool
    ) {
        self.head = head
        self.canPresent = canPresent
        if let acknowledgementInFlightRevealID,
           activeReveal?.revealID == acknowledgementInFlightRevealID
        {
            if !canPresent { interrupt() }
            return
        }
        let headID = head?.revealID
        pruneIdentitySets(to: headID)

        if let head {
            switch head.state {
            case .pending:
                break
            case .presented:
                durablyPresentedRevealIDs.insert(head.revealID)
            case .acknowledged:
                acknowledgedRevealIDs.insert(head.revealID)
                durablyPresentedRevealIDs.remove(head.revealID)
                freshlyMarkedRevealIDs.remove(head.revealID)
            }
        }

        if activeReveal?.revealID != headID {
            interrupt()
        } else if activeReveal != nil {
            activeReveal = head
        }
        if !canPresent {
            interrupt()
        } else {
            presentNextIfSafe()
        }
    }

    mutating func beginPresentationMark(revealID: RevealID) -> Bool {
        guard blockers.isEmpty,
              activeReveal?.revealID == revealID,
              head?.state == .pending,
              !durablyPresentedRevealIDs.contains(revealID),
              markInFlightRevealID == nil
        else { return false }
        markInFlightRevealID = revealID
        return true
    }

    mutating func presentationMarkSucceeded(revealID: RevealID) {
        guard markInFlightRevealID == revealID else { return }
        markInFlightRevealID = nil
        durablyPresentedRevealIDs.insert(revealID)
        freshlyMarkedRevealIDs.insert(revealID)
    }

    mutating func presentationMarkFailed(revealID: RevealID) {
        guard markInFlightRevealID == revealID else { return }
        markInFlightRevealID = nil
    }

    mutating func start(
        revealID: RevealID
    ) -> ProgressionRevealStartDisposition? {
        guard blockers.isEmpty,
              activeReveal?.revealID == revealID,
              startedRevealID == nil,
              durablyPresentedRevealIDs.contains(revealID)
        else { return nil }
        startedRevealID = revealID
        let shouldRunOneShotPresentation = freshlyMarkedRevealIDs.remove(revealID) != nil
        return ProgressionRevealStartDisposition(
            shouldAnnounce: shouldRunOneShotPresentation
                && announcedRevealIDs.insert(revealID).inserted,
            shouldPerformFeedback: shouldRunOneShotPresentation
                && feedbackRevealIDs.insert(revealID).inserted,
            isStatic: !shouldRunOneShotPresentation
        )
    }

    mutating func beginAcknowledgement(revealID: RevealID) -> Bool {
        guard activeReveal?.revealID == revealID,
              durablyPresentedRevealIDs.contains(revealID),
              acknowledgementInFlightRevealID == nil
        else { return false }
        acknowledgementInFlightRevealID = revealID
        return true
    }

    mutating func acknowledgementSucceeded(revealID: RevealID) {
        guard acknowledgementInFlightRevealID == revealID else { return }
        acknowledgementInFlightRevealID = nil
        acknowledgedRevealIDs.insert(revealID)
        durablyPresentedRevealIDs.remove(revealID)
        freshlyMarkedRevealIDs.remove(revealID)
        if activeReveal?.revealID == revealID {
            activeReveal = nil
            startedRevealID = nil
        }
        pruneIdentitySets(to: head?.revealID)
        presentNextIfSafe()
    }

    mutating func acknowledgementFailed(revealID: RevealID) {
        guard acknowledgementInFlightRevealID == revealID else { return }
        acknowledgementInFlightRevealID = nil
        durablyPresentedRevealIDs.insert(revealID)
        if activeReveal == nil, head?.revealID == revealID {
            presentNextIfSafe()
        }
    }

    func needsAcknowledgement(revealID: RevealID) -> Bool {
        durablyPresentedRevealIDs.contains(revealID)
            && !acknowledgedRevealIDs.contains(revealID)
    }

    mutating func reset() {
        blockers = [.rootPresentation]
        head = nil
        canPresent = false
        activeReveal = nil
        startedRevealID = nil
        markInFlightRevealID = nil
        durablyPresentedRevealIDs.removeAll()
        freshlyMarkedRevealIDs.removeAll()
        acknowledgedRevealIDs.removeAll()
        announcedRevealIDs.removeAll()
        feedbackRevealIDs.removeAll()
        acknowledgementInFlightRevealID = nil
    }

    mutating func interrupt() {
        activeReveal = nil
        startedRevealID = nil
    }

    private mutating func pruneIdentitySets(to headID: RevealID?) {
        guard let headID else {
            acknowledgedRevealIDs.removeAll()
            announcedRevealIDs.removeAll()
            feedbackRevealIDs.removeAll()
            acknowledgementInFlightRevealID = nil
            markInFlightRevealID = nil
            durablyPresentedRevealIDs.removeAll()
            freshlyMarkedRevealIDs.removeAll()
            return
        }
        acknowledgedRevealIDs = acknowledgedRevealIDs.filter { $0 == headID }
        announcedRevealIDs = announcedRevealIDs.filter { $0 == headID }
        feedbackRevealIDs = feedbackRevealIDs.filter { $0 == headID }
        if acknowledgementInFlightRevealID != headID {
            acknowledgementInFlightRevealID = nil
        }
        if markInFlightRevealID != headID { markInFlightRevealID = nil }
        durablyPresentedRevealIDs = durablyPresentedRevealIDs.filter { $0 == headID }
        freshlyMarkedRevealIDs = freshlyMarkedRevealIDs.filter { $0 == headID }
    }

    private mutating func presentNextIfSafe() {
        guard blockers.isEmpty,
              canPresent,
              activeReveal == nil,
              let head,
              head.state != .acknowledged,
              !acknowledgedRevealIDs.contains(head.revealID),
              acknowledgementInFlightRevealID == nil
        else { return }
        activeReveal = head
    }
}

enum ProgressionRevealPresentationPolicy {
    static func sequenceDurationSeconds(for tier: ProgressionRevealTier) -> Double {
        switch tier {
        case .micro: 0.75
        case .artifact: 1.25
        case .codex: 2.30
        case .mastery: 2.40
        }
    }

    static func visualMode(
        animationEnabled: Bool,
        reduceMotion: Bool
    ) -> UnlockRevealVisualMode {
        guard animationEnabled else { return .none }
        return reduceMotion ? .crossfadeHighlight : .movement
    }

    static func announcement(for reveal: ProgressionRevealSummaryDTO) -> String {
        let primary = reveal.primaryRewardPresentation.displayName
        let secondary = secondaryRewardAnnouncement(reveal.secondaryRewardIDs)
        return secondary.isEmpty
            ? "Unlocked \(primary)."
            : "Unlocked \(primary). \(secondary)"
    }

    static func secondaryRewardAnnouncement(
        _ references: [ProgressionContentReference]
    ) -> String {
        guard !references.isEmpty else { return "" }
        guard references.count <= 3 else {
            return "Includes \(references.count) additional rewards."
        }
        let names = references.map(contentName)
        return "Also includes " + names.joined(separator: ", ") + "."
    }

    static func contentName(_ reference: ProgressionContentReference) -> String {
        switch reference {
        case .codex: "Codex reward"
        case .artifact: "Artifact reward"
        case .title: "Title reward"
        case .entitlement: "Entitlement reward"
        case .crest: "Crest reward"
        case .unknown: "Additional reward"
        }
    }
}

extension RuneScribeUISession {
    func startOptionalProgressionObservation(generation: UInt64) {
        guard let progressionClientHandle else {
            progressionRailState = .unavailable
            return
        }
        progressionRailState = .loading
        progressionTask = Task { @MainActor [weak self, progressionClientHandle] in
            for await envelope in progressionClientHandle.progressionStateEnvelopes {
                guard !Task.isCancelled,
                      let self,
                      observationGeneration == generation
                else { return }
                adoptProgressionSnapshot(envelope.payload)
            }
            guard !Task.isCancelled,
                  let self,
                  observationGeneration == generation
            else { return }
            progressionRailState = .unavailable
            revealQueue.adopt(
                head: progressionSnapshot?.nextReveal,
                canPresent: false
            )
            syncActiveReveal()
        }
    }

    func startOptionalSettingsObservation(generation: UInt64) {
        guard let runtimeSettingsClientHandle else {
            settingsRailState = .unavailable
            runtimePresentationSettingsReady = true
            return
        }
        settingsRailState = .loading
        settingsTask = Task { @MainActor [weak self, runtimeSettingsClientHandle] in
            do {
                let initial = try await runtimeSettingsClientHandle.snapshot()
                guard !Task.isCancelled,
                      let self,
                      observationGeneration == generation
                else { return }
                adoptRuntimeSettingsSnapshot(initial)

                let snapshots = try await runtimeSettingsClientHandle.snapshots()
                for await snapshot in snapshots {
                    guard !Task.isCancelled,
                          observationGeneration == generation
                    else { return }
                    adoptRuntimeSettingsSnapshot(snapshot)
                }
            } catch {
                guard !Task.isCancelled,
                      let self,
                      observationGeneration == generation
                else { return }
                settingsRailState = .unavailable
                runtimePresentationSettingsReady = true
            }
        }
    }

    func selectProgressionTitle(_ titleID: TitleID?) async {
        guard let progressionClientHandle else {
            progressionCommandError = "Progress is temporarily unavailable."
            return
        }
        do {
            try await progressionClientHandle.selectTitle(
                SelectProgressionTitleCommand(titleID: titleID)
            )
            progressionCommandError = nil
        } catch {
            progressionCommandError = "Progress is temporarily unavailable."
        }
    }

    func setUnlockFeedbackSetting(
        _ settingID: RuntimeSettingID,
        enabled: Bool
    ) async {
        guard let runtimeSettingsClientHandle else {
            settingsRailState = .unavailable
            return
        }
        let previous = unlockFeedbackPreferences
        applyFeedbackPreference(settingID, enabled: enabled)
        let expectedRevision = runtimeSettingsSnapshot?.settings.first {
            $0.settingID == settingID
        }?.revision
        do {
            _ = try await runtimeSettingsClientHandle.set(
                SetRuntimeSettingCommand(
                    settingID: settingID,
                    value: .boolean(enabled),
                    expectedRevision: expectedRevision
                )
            )
            settingsRailState = .available
        } catch {
            unlockFeedbackPreferences = previous
            settingsRailState = .degraded
        }
    }

    func markContactsImportPrompted() async {
        guard !contactsImportPrompted,
              let runtimeSettingsClientHandle
        else { return }
        contactsImportPrompted = true
        let expectedRevision = runtimeSettingsSnapshot?.settings.first {
            $0.settingID == RuneScribeRuntimeSettings.contactsImportPrompted
        }?.revision
        do {
            _ = try await runtimeSettingsClientHandle.setContactsImportPrompted(
                true,
                expectedRevision: expectedRevision
            )
            settingsRailState = .available
        } catch {
            contactsImportPrompted = false
            settingsRailState = .degraded
        }
    }

    func markSplashShown(at date: Date) async {
        guard let runtimeSettingsClientHandle else {
            settingsRailState = .unavailable
            return
        }
        let previous = splashLastShownAt
        splashLastShownAt = date
        let expectedRevision = runtimeSettingsSnapshot?.settings.first {
            $0.settingID == RuneScribeRuntimeSettings.splashLastShownEpochMilliseconds
        }?.revision
        do {
            _ = try await runtimeSettingsClientHandle.setSplashLastShown(
                at: date,
                expectedRevision: expectedRevision
            )
            settingsRailState = .available
        } catch {
            splashLastShownAt = previous
            settingsRailState = .degraded
        }
    }

    func setRevealBlocker(
        _ blocker: ProgressionRevealBlocker,
        active: Bool
    ) {
        revealQueue.setBlocker(blocker, active: active)
        syncActiveReveal()
    }

    func revealPresentationDidStart(
        revealID: RevealID,
        reduceMotion: Bool
    ) async -> UnlockRevealPresentationPlan? {
        guard activeReveal?.revealID == revealID else { return nil }

        if !revealQueue.needsAcknowledgement(revealID: revealID) {
            guard revealQueue.beginPresentationMark(revealID: revealID),
                  let progressionClientHandle
            else { return nil }
            do {
                try await progressionClientHandle.markRevealPresented(
                    MarkProgressionRevealPresentedCommand(revealID: revealID)
                )
                revealQueue.presentationMarkSucceeded(revealID: revealID)
            } catch {
                revealQueue.presentationMarkFailed(revealID: revealID)
                return nil
            }
        }

        guard let reveal = activeReveal,
              let disposition = revealQueue.start(revealID: revealID)
        else { return nil }

        let announcement = disposition.shouldAnnounce
            ? ProgressionRevealPresentationPolicy.announcement(for: reveal)
            : nil
        if disposition.shouldPerformFeedback,
           unlockFeedbackPreferences.soundEnabled || unlockFeedbackPreferences.hapticEnabled,
           let unlockFeedbackClientHandle {
            let request = UnlockFeedbackRequestDTO(
                tier: reveal.tier,
                codexID: themeSnapshot?.effectiveCodexID
                    ?? RuneScribeCodexIDs.norse,
                soundEnabled: unlockFeedbackPreferences.soundEnabled,
                hapticEnabled: unlockFeedbackPreferences.hapticEnabled
            )
            Task {
                try? await unlockFeedbackClientHandle.perform(request)
            }
        }
        return UnlockRevealPresentationPlan(
            revealID: revealID,
            sequenceDurationSeconds: ThemeUnlockCueSelector.animationDuration(
                themeUnlockAnimationDataByTier[reveal.tier.rawValue]
            ) ?? ProgressionRevealPresentationPolicy.sequenceDurationSeconds(
                for: reveal.tier
            ),
            visualMode: disposition.isStatic
                ? .none
                : ProgressionRevealPresentationPolicy.visualMode(
                    animationEnabled: unlockFeedbackPreferences.animationEnabled,
                    reduceMotion: reduceMotion
                ),
            announcement: announcement,
            isStatic: disposition.isStatic
        )
    }

    func finishRevealPresentation(revealID: RevealID) async {
        await acknowledgePresentedReveal(revealID)
    }

    func dismissProgressionCommandError() {
        progressionCommandError = nil
    }

    func resetRevealPresentationState() {
        revealQueue.reset()
        syncActiveReveal()
    }

    private func adoptProgressionSnapshot(_ snapshot: ProgressionSnapshotDTO) {
        progressionSnapshot = snapshot
        progressionRailState = railState(for: snapshot)
        let canPresent = progressionRailState == .available
            || progressionRailState == .degraded
        revealQueue.adopt(head: snapshot.nextReveal, canPresent: canPresent)
        syncActiveReveal()
        if progressionRailState == .unavailable {
            interruptActiveReveal()
        }
        reconcileThemeArtifactSelections()
    }

    private func adoptRuntimeSettingsSnapshot(_ snapshot: RuntimeSettingsSnapshotDTO) {
        runtimeSettingsSnapshot = snapshot
        unlockFeedbackPreferences = UnlockFeedbackPreferences(snapshot: snapshot)
        contactsImportPrompted = snapshot.contactsImportPrompted
        splashLastShownAt = snapshot.splashLastShownAt
        runtimePresentationSettingsReady = true
        settingsRailState = .available
        reconcileThemeArtifactSelections()
    }

    private func applyFeedbackPreference(
        _ settingID: RuntimeSettingID,
        enabled: Bool
    ) {
        switch settingID {
        case RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled:
            unlockFeedbackPreferences.soundEnabled = enabled
        case RuneScribeRuntimeSettings.unlockFeedbackHapticsEnabled:
            unlockFeedbackPreferences.hapticEnabled = enabled
        case RuneScribeRuntimeSettings.unlockFeedbackAnimationEnabled:
            unlockFeedbackPreferences.animationEnabled = enabled
        default:
            break
        }
    }

    private func railState(
        for snapshot: ProgressionSnapshotDTO
    ) -> OptionalProgressionRailState {
        switch snapshot.availability {
        case .unavailable:
            return .unavailable
        case .degraded:
            return .degraded
        case .available:
            switch snapshot.storeHealth {
            case .absent, .loaded, .migrated: return .available
            case .quarantined, .unreadable, .corrupt: return .degraded
            }
        }
    }

    private func interruptActiveReveal() {
        revealQueue.interrupt()
        syncActiveReveal()
    }

    private func acknowledgePresentedReveal(_ revealID: RevealID) async {
        guard revealQueue.beginAcknowledgement(revealID: revealID),
              let progressionClientHandle
        else { return }

        do {
            try await progressionClientHandle.acknowledgeReveal(
                AcknowledgeProgressionRevealCommand(revealID: revealID)
            )
            revealQueue.acknowledgementSucceeded(revealID: revealID)
            progressionCommandError = nil
        } catch {
            revealQueue.acknowledgementFailed(revealID: revealID)
        }
        syncActiveReveal()
    }

    private func syncActiveReveal() {
        activeReveal = revealQueue.activeReveal
    }
}
