import Foundation
import RuneScribeContracts
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class ProgressionPresentationTests: XCTestCase {
    func testJourneyLayoutAdaptsAndAchievementGroupsAreStable() throws {
        XCTAssertEqual(VaultProgressPresentation.journeyColumnCount(for: 390), 1)
        XCTAssertEqual(VaultProgressPresentation.journeyColumnCount(for: 719), 1)
        XCTAssertEqual(VaultProgressPresentation.journeyColumnCount(for: 720), 2)
        XCTAssertEqual(VaultProgressPresentation.journeyColumnCount(for: 1_024), 2)

        let expectations: [(String, ProgressionAchievementPath)] = [
            ("achievement.first-inscription", .scribe),
            ("achievement.archivist-2", .scribe),
            ("achievement.first-dispatch", .courier),
            ("achievement.five-circles", .courier),
            ("achievement.echo-returns", .archivist),
            ("achievement.explorer", .archivist),
            ("achievement.master-scribe", .crossPath),
        ]
        for (rawValue, path) in expectations {
            let identifier = try XCTUnwrap(AchievementID(rawValue: rawValue))
            XCTAssertEqual(VaultProgressPresentation.achievementPath(for: identifier), path)
        }
    }

    func testHiddenAchievementPlaceholderLeaksNoSecretTextOrProgress() throws {
        let hidden = try ProgressionAchievementDTO(
            achievementID: try XCTUnwrap(
                AchievementID(rawValue: "achievement.explorer")
            ),
            presentation: try ProgressionPresentationDTO(
                displayName: "Explorer",
                summary: nil,
                fallbackSystemImageName: "map.fill"
            ),
            completedRuleCount: 0,
            requiredRuleCount: 1,
            progress: try ProgressionNumericProgressDTO(current: 0, target: 8),
            completedAt: nil,
            isHidden: true,
            localPointWeight: 75,
            rewards: try ProgressionRewardSummaryDTO(
                titleIDs: [try XCTUnwrap(TitleID(rawValue: "title.secret-path"))]
            )
        )

        let card = VaultProgressPresentation.achievementCard(for: hidden)

        XCTAssertTrue(card.isSecretPlaceholder)
        XCTAssertEqual(card.title, "Hidden Achievement")
        XCTAssertEqual(card.status, "Undiscovered")
        XCTAssertEqual(card.progressValue, 0)
        XCTAssertEqual(card.progressTarget, 1)
        XCTAssertEqual(card.points, 0)
        XCTAssertEqual(card.rewardCount, 0)
        let rendered = [card.title, card.summary, card.systemImage, card.status]
            .joined(separator: " ")
            .lowercased()
        XCTAssertFalse(rendered.contains("explorer"))
        XCTAssertFalse(rendered.contains("secret-path"))
        XCTAssertFalse(rendered.contains("map.fill"))
    }

    func testVaultShowsOwnedOnlyAndDistinguishesProviderState() throws {
        let owned = try ownership(
            state: .owned,
            availability: .active,
            renderState: .providerAvailable,
            suffix: "owned"
        )
        let encountered = try ownership(
            state: .encountered,
            availability: .unavailable,
            renderState: .genericFallback,
            suffix: "encountered"
        )
        let locked = try ownership(
            state: .locked,
            availability: .unavailable,
            renderState: .locked,
            suffix: "locked"
        )

        XCTAssertEqual(
            VaultProgressPresentation.ownedContent(from: [locked, encountered, owned]),
            [owned]
        )
        XCTAssertEqual(
            VaultProgressPresentation.providerLabel(
                availability: .active,
                renderState: .providerAvailable
            ),
            "Provider active"
        )
        XCTAssertEqual(
            VaultProgressPresentation.providerLabel(
                availability: .failed,
                renderState: .providerFailed
            ),
            "Provider unavailable — standard presentation in use"
        )
    }

    func testArchiveUnknownIsGenericAndNeverNeedsOwnershipForItsLabel() throws {
        let entry = try ProgressionArchiveEntryDTO(
            kind: .unknown,
            reference: .unknown,
            presentation: try ProgressionPresentationDTO(
                displayName: "Provider secret name",
                summary: "Provider secret summary",
                fallbackSystemImageName: "questionmark"
            ),
            supportState: .unknown,
            ownershipState: .encountered,
            renderState: .genericFallback,
            firstEncounteredAt: Date(timeIntervalSince1970: 100),
            lastEncounteredAt: Date(timeIntervalSince1970: 200),
            encounterCount: 2,
            provenanceStatus: .unsupported
        )

        XCTAssertEqual(
            VaultProgressPresentation.archiveTitle(for: entry),
            "Unknown encountered content"
        )
        XCTAssertEqual(
            VaultProgressPresentation.archiveSupportLabel(entry.supportState),
            "Unknown — shown generically"
        )
        XCTAssertEqual(
            VaultProgressPresentation.provenanceLabel(entry.provenanceStatus),
            "Unsupported provenance"
        )

        let unsupported = try ProgressionArchiveEntryDTO(
            kind: .codex,
            reference: .codex(try XCTUnwrap(CodexID(rawValue: "codex.unsupported"))),
            presentation: try ProgressionPresentationDTO(
                displayName: "Provider-only name",
                summary: nil,
                fallbackSystemImageName: "book"
            ),
            supportState: .unsupported,
            ownershipState: .encountered,
            renderState: .genericFallback,
            firstEncounteredAt: Date(timeIntervalSince1970: 100),
            lastEncounteredAt: Date(timeIntervalSince1970: 100),
            encounterCount: 1,
            provenanceStatus: .unverified
        )
        XCTAssertEqual(
            VaultProgressPresentation.archiveTitle(for: unsupported),
            "Unsupported encountered content"
        )
    }

    func testEveryRequiredUnsafeSurfaceMapsToABlocker() {
        XCTAssertEqual(
            Set(ProgressionRevealUnsafeSurface.allCases.map(\.blocker)),
            [.rootPresentation, .workspaceModal, .systemShare]
        )
        for surface in ProgressionRevealUnsafeSurface.allCases {
            switch surface {
            case .systemShare:
                XCTAssertEqual(surface.blocker, .systemShare)
            case .messages, .qrCameraOrDisplay:
                XCTAssertEqual(surface.blocker, .workspaceModal)
            case .lockOrPIN, .fileImport, .importConfirmation,
                 .receivedMessageDecode, .securityWarning:
                XCTAssertEqual(surface.blocker, .rootPresentation)
            }
        }
    }

    func testRootSafePointIncludesImportDecodePendingAndWarningPhases() {
        XCTAssertFalse(rootShouldBlock())
        XCTAssertTrue(rootShouldBlock(showSplash: true))
        XCTAssertTrue(rootShouldBlock(isLocked: true))
        XCTAssertTrue(rootShouldBlock(importPhase: .validating))
        XCTAssertTrue(rootShouldBlock(importPhase: .importing))
        XCTAssertTrue(rootShouldBlock(importPhase: .awaitingConfirmation))
        XCTAssertTrue(rootShouldBlock(messagePhase: .receiving))
        XCTAssertTrue(rootShouldBlock(messagePhase: .received))
        XCTAssertTrue(rootShouldBlock(hasPendingImport: true))
        XCTAssertTrue(rootShouldBlock(hasPendingMessage: true))
        XCTAssertTrue(rootShouldBlock(hasWarning: true))
        XCTAssertFalse(rootShouldBlock(importPhase: .completed, messagePhase: .idle))
    }

    func testInterruptedRevealResumesWithoutRepeatingFeedbackOrAnnouncement() throws {
        let reveal = try makeReveal(suffix: "first", secondaryCount: 1)
        var queue = ProgressionRevealQueueModel()
        queue.adopt(head: reveal, canPresent: true)
        XCTAssertNil(queue.activeReveal, "The initial root blocker must delay presentation")

        queue.setBlocker(.rootPresentation, active: false)
        XCTAssertEqual(queue.activeReveal?.revealID, reveal.revealID)
        XCTAssertTrue(queue.beginPresentationMark(revealID: reveal.revealID))
        queue.presentationMarkSucceeded(revealID: reveal.revealID)
        XCTAssertEqual(
            queue.start(revealID: reveal.revealID),
            ProgressionRevealStartDisposition(
                shouldAnnounce: true,
                shouldPerformFeedback: true,
                isStatic: false
            )
        )

        queue.setBlocker(.systemShare, active: true)
        XCTAssertNil(queue.activeReveal)

        queue.setBlocker(.systemShare, active: false)
        XCTAssertEqual(queue.activeReveal?.revealID, reveal.revealID)
        XCTAssertEqual(
            queue.start(revealID: reveal.revealID),
            ProgressionRevealStartDisposition(
                shouldAnnounce: false,
                shouldPerformFeedback: false,
                isStatic: true
            )
        )
        XCTAssertTrue(queue.needsAcknowledgement(revealID: reveal.revealID))
    }

    func testPendingRevealCannotRunOneShotPresentationBeforeMarkSucceeds() throws {
        let reveal = try makeReveal(suffix: "mark-order")
        var queue = ProgressionRevealQueueModel()
        queue.setBlocker(.rootPresentation, active: false)
        queue.adopt(head: reveal, canPresent: true)

        XCTAssertNil(queue.start(revealID: reveal.revealID))
        XCTAssertTrue(queue.beginPresentationMark(revealID: reveal.revealID))
        XCTAssertEqual(queue.markInFlightRevealID, reveal.revealID)
        XCTAssertNil(queue.start(revealID: reveal.revealID))

        queue.presentationMarkFailed(revealID: reveal.revealID)
        XCTAssertNil(queue.start(revealID: reveal.revealID))
        XCTAssertTrue(queue.beginPresentationMark(revealID: reveal.revealID))
        queue.presentationMarkSucceeded(revealID: reveal.revealID)

        XCTAssertEqual(
            queue.start(revealID: reveal.revealID),
            ProgressionRevealStartDisposition(
                shouldAnnounce: true,
                shouldPerformFeedback: true,
                isStatic: false
            )
        )
    }

    func testFailedAcknowledgementRetainsStaticRevealAndFIFOAdvancesAfterSuccess() throws {
        let first = try makeReveal(suffix: "first")
        let second = try makeReveal(suffix: "second")
        var queue = ProgressionRevealQueueModel()
        queue.setBlocker(.rootPresentation, active: false)
        queue.adopt(head: first, canPresent: true)
        XCTAssertTrue(queue.beginPresentationMark(revealID: first.revealID))
        queue.presentationMarkSucceeded(revealID: first.revealID)
        _ = queue.start(revealID: first.revealID)
        XCTAssertTrue(queue.beginAcknowledgement(revealID: first.revealID))
        queue.acknowledgementFailed(revealID: first.revealID)

        XCTAssertEqual(queue.activeReveal?.revealID, first.revealID)
        XCTAssertTrue(queue.needsAcknowledgement(revealID: first.revealID))
        queue.setBlocker(.systemShare, active: true)
        queue.setBlocker(.systemShare, active: false)
        XCTAssertEqual(
            queue.start(revealID: first.revealID),
            ProgressionRevealStartDisposition(
                shouldAnnounce: false,
                shouldPerformFeedback: false,
                isStatic: true
            )
        )
        XCTAssertTrue(queue.beginAcknowledgement(revealID: first.revealID))
        queue.adopt(head: second, canPresent: true)
        XCTAssertEqual(
            queue.activeReveal?.revealID,
            first.revealID,
            "A newer durable head must wait for acknowledgement success"
        )
        queue.acknowledgementSucceeded(revealID: first.revealID)
        XCTAssertEqual(queue.activeReveal?.revealID, second.revealID)
        XCTAssertFalse(queue.needsAcknowledgement(revealID: first.revealID))

        XCTAssertTrue(queue.beginPresentationMark(revealID: second.revealID))
        queue.presentationMarkSucceeded(revealID: second.revealID)
        XCTAssertEqual(
            queue.start(revealID: second.revealID),
            ProgressionRevealStartDisposition(
                shouldAnnounce: true,
                shouldPerformFeedback: true,
                isStatic: false
            )
        )
    }

    func testDurablyPresentedHeadResumesStaticAndNeverAutomaticallyAcknowledges() throws {
        let reveal = try makeReveal(suffix: "presented", state: .presented)
        var queue = ProgressionRevealQueueModel()
        queue.setBlocker(.rootPresentation, active: false)
        queue.adopt(head: reveal, canPresent: true)

        XCTAssertEqual(queue.activeReveal?.revealID, reveal.revealID)
        XCTAssertFalse(queue.beginPresentationMark(revealID: reveal.revealID))
        XCTAssertEqual(
            queue.start(revealID: reveal.revealID),
            ProgressionRevealStartDisposition(
                shouldAnnounce: false,
                shouldPerformFeedback: false,
                isStatic: true
            )
        )
        XCTAssertTrue(queue.needsAcknowledgement(revealID: reveal.revealID))
        XCTAssertTrue(queue.beginAcknowledgement(revealID: reveal.revealID))
        queue.acknowledgementFailed(revealID: reveal.revealID)
        XCTAssertEqual(queue.activeReveal?.revealID, reveal.revealID)
        XCTAssertTrue(queue.needsAcknowledgement(revealID: reveal.revealID))
    }

    func testCombinedRevealTextMotionSettingsAndVoiceOverAreDeterministic() throws {
        let reveal = try makeReveal(suffix: "bundle", secondaryCount: 2)
        let announcement = ProgressionRevealPresentationPolicy.announcement(for: reveal)

        XCTAssertTrue(announcement.contains("Primary bundle"))
        XCTAssertTrue(announcement.contains("Artifact reward"))
        XCTAssertFalse(announcement.contains("secondary-1"))
        XCTAssertFalse(announcement.contains("secondary-2"))
        XCTAssertFalse(announcement.contains(reveal.revealID.rawValue))
        XCTAssertEqual(
            ProgressionRevealPresentationPolicy.visualMode(
                animationEnabled: true,
                reduceMotion: true
            ),
            .crossfadeHighlight
        )
        XCTAssertEqual(
            ProgressionRevealPresentationPolicy.visualMode(
                animationEnabled: false,
                reduceMotion: false
            ),
            .none
        )
        XCTAssertEqual(
            ProgressionRevealPresentationPolicy.visualMode(
                animationEnabled: true,
                reduceMotion: false
            ),
            .movement
        )
        XCTAssertLessThan(
            ProgressionRevealPresentationPolicy.sequenceDurationSeconds(for: .micro),
            ProgressionRevealPresentationPolicy.sequenceDurationSeconds(for: .artifact)
        )
    }

    func testFreshPlanFinishesAfterItsSequenceWhileStaticResumeWaitsForDismiss() throws {
        let revealID = try XCTUnwrap(RevealID(rawValue: "reveal.finish-policy"))
        let tierDurations: [(ProgressionRevealTier, Double)] = [
            (.micro, 0.75),
            (.artifact, 1.25),
            (.codex, 2.30),
            (.mastery, 2.40),
        ]
        for (tier, expectedDuration) in tierDurations {
            let duration = ProgressionRevealPresentationPolicy
                .sequenceDurationSeconds(for: tier)
            let fresh = UnlockRevealPresentationPlan(
                revealID: revealID,
                sequenceDurationSeconds: duration,
                visualMode: .movement,
                announcement: "Unlocked.",
                isStatic: false
            )
            XCTAssertEqual(fresh.automaticFinishDelaySeconds, expectedDuration)
        }
        let resumed = UnlockRevealPresentationPlan(
            revealID: revealID,
            sequenceDurationSeconds: 1.25,
            visualMode: .none,
            announcement: nil,
            isStatic: true
        )

        XCTAssertNil(resumed.automaticFinishDelaySeconds)
    }

    func testOptionalProgressionUnavailableNeverActivatesReveal() throws {
        let reveal = try makeReveal(suffix: "optional")
        var queue = ProgressionRevealQueueModel()
        queue.setBlocker(.rootPresentation, active: false)
        queue.adopt(head: reveal, canPresent: false)
        XCTAssertNil(queue.activeReveal)
    }

    private func makeReveal(
        suffix: String,
        state: ProgressionRevealState = .pending,
        secondaryCount: Int = 0
    ) throws -> ProgressionRevealSummaryDTO {
        let revealID = try XCTUnwrap(RevealID(rawValue: "reveal.\(suffix)"))
        let transactionID = try XCTUnwrap(
            GrantTransactionID(rawValue: "transaction.\(suffix)")
        )
        let primaryID = try XCTUnwrap(ArtifactID(rawValue: "artifact.primary-\(suffix)"))
        let secondary: [ProgressionContentReference] = try (0 ..< secondaryCount).map {
            .artifact(try XCTUnwrap(
                ArtifactID(rawValue: "artifact.secondary-\($0 + 1)")
            ))
        }
        return try ProgressionRevealSummaryDTO(
            revealID: revealID,
            transactionID: transactionID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            state: state,
            tier: .artifact,
            rarity: .inscribed,
            primaryRewardID: .artifact(primaryID),
            primaryRewardPresentation: try ProgressionPresentationDTO(
                displayName: "Primary \(suffix)",
                summary: "A combined local reward.",
                fallbackSystemImageName: "sparkles"
            ),
            secondaryRewardIDs: secondary,
            sourceAchievementIDs: [
                try XCTUnwrap(AchievementID(rawValue: "achievement.source-\(suffix)")),
            ]
        )
    }

    private func ownership(
        state: ProgressionContentOwnershipState,
        availability: ProgressionProviderAvailability,
        renderState: ProgressionContentRenderState,
        suffix: String
    ) throws -> ProgressionOwnershipDTO {
        let firstEncounteredAt: Date? = state == .locked
            ? nil
            : Date(timeIntervalSince1970: 100)
        let grantedAt: Date? = state == .owned
            ? Date(timeIntervalSince1970: 200)
            : nil
        return try ProgressionOwnershipDTO(
            kind: .relic,
            reference: .artifact(
                try XCTUnwrap(ArtifactID(rawValue: "artifact.\(suffix)"))
            ),
            presentation: try ProgressionPresentationDTO(
                displayName: suffix.capitalized,
                summary: nil,
                fallbackSystemImageName: "seal"
            ),
            state: state,
            firstEncounteredAt: firstEncounteredAt,
            grantedAt: grantedAt,
            sourceRuleIDs: state == .owned
                ? [try XCTUnwrap(RuleID(rawValue: "rule.\(suffix)"))]
                : [],
            providerAvailability: availability,
            renderState: renderState
        )
    }

    private func rootShouldBlock(
        showSplash: Bool = false,
        isLocked: Bool = false,
        importPhase: ImportPhaseDTO? = .idle,
        messagePhase: MessagePhaseDTO? = .idle,
        hasPendingImport: Bool = false,
        hasPendingMessage: Bool = false,
        hasWarning: Bool = false
    ) -> Bool {
        RootRevealSafetyPolicy.shouldBlock(
            showSplash: showSplash,
            isLocked: isLocked,
            importPhase: importPhase,
            messagePhase: messagePhase,
            hasPendingImport: hasPendingImport,
            hasPendingMessage: hasPendingMessage,
            hasSecurityOrFailurePresentation: hasWarning
        )
    }
}
