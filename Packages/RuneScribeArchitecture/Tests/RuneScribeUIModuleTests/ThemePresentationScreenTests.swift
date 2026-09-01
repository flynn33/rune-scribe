import Foundation
@_spi(ThemeFidelityQualification) import RuneScribeContracts
import RuneScribeNorseThemeModule
import RuneScribeThemeMoonleafModule
import RuneScribeUIRuntime
import SwiftUI
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class ThemePresentationScreenTests: XCTestCase {
    func testSelectionSummaryComesFromDescriptorAndComposition() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let seal = try XCTUnwrap(descriptor.codex.seals.first(where: {
            $0.metadata.availability == .included
        }))
        let plan = try composition(
            descriptor: descriptor,
            sealID: seal.metadata.id,
            inscription: "ᚠᚢᚦᚨ"
        )

        let summary = ThemePresentationSelectionSummary(
            descriptor: descriptor,
            plan: plan
        )

        XCTAssertEqual(summary.codexName, descriptor.codex.displayName.fallbackValue)
        XCTAssertEqual(summary.receivedCodexName, descriptor.codex.displayName.fallbackValue)
        XCTAssertEqual(
            summary.scriptName,
            descriptor.codex.scripts.first(where: {
                $0.id == descriptor.codex.primaryScriptID
            })?.displayName.fallbackValue
        )
        XCTAssertEqual(
            summary.relicName,
            descriptor.codex.relics.first(where: {
                $0.metadata.id == descriptor.codex.defaultRelicID
            })?.metadata.displayName.fallbackValue
        )
        XCTAssertEqual(summary.sealName, seal.metadata.displayName.fallbackValue)
        XCTAssertNil(summary.frameName)
    }

    func testReceivedCodexNameUsesProviderFamilyGroupingWithoutIdentityBranches() {
        XCTAssertEqual(
            ThemePresentationSelectionSummary.receivedCodexName(
                codexName: "Moonleaf Codex",
                vaultGrouping: "Elven Series"
            ),
            "Elven Codex"
        )
        XCTAssertEqual(
            ThemePresentationSelectionSummary.receivedCodexName(
                codexName: "Norse Codex",
                vaultGrouping: "Norse Collection"
            ),
            "Norse Codex"
        )
    }

    func testReceivedPresentationUsesProviderAuthoredFamilyIdentity() throws {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let presentation = try XCTUnwrap(descriptor.codex.receivedPresentation)
        let plan = try composition(
            descriptor: descriptor,
            sealID: descriptor.codex.seals.first?.metadata.id,
            inscription: "ᚠᚢᚦᚨ"
        )
        let summary = ThemePresentationSelectionSummary(
            descriptor: descriptor,
            plan: plan
        )

        XCTAssertEqual(
            summary.receivedCodexName,
            presentation.familyDisplayName.fallbackValue
        )
        XCTAssertEqual(summary.receivedCodexName, "Elven Codex")
        XCTAssertNotEqual(
            presentation.primarySenderAvatarResourceID,
            presentation.shareSenderAvatarResourceID
        )
        XCTAssertNotEqual(
            presentation.primaryMedallion.resourceID,
            presentation.shareMedallion.resourceID
        )
    }

    func testMoonleafReceivedIdentityResourcesArePartitionedByProductionState()
        throws
    {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let authored = try XCTUnwrap(descriptor.codex.receivedPresentation)
        let resources = try XCTUnwrap(
            ReceivedCipherPresentationResourcePlan(descriptor)
        )

        XCTAssertEqual(
            resources.primaryResourceIDs,
            [
                authored.primarySenderAvatarResourceID,
                authored.primaryMedallion.resourceID,
            ]
        )
        XCTAssertEqual(
            resources.shareCardResourceIDs,
            [
                authored.shareSenderAvatarResourceID,
                authored.shareCodexBadgeResourceID,
                authored.shareMedallion.resourceID,
            ]
        )
        XCTAssertEqual(resources.allResourceIDs.count, 5)
        XCTAssertEqual(
            resources.resourceIDs(for: .primary),
            resources.primaryResourceIDs
        )
        XCTAssertEqual(
            resources.resourceIDs(for: .shareCard),
            resources.shareCardResourceIDs
        )
    }

    func testQualificationReceivedSurfacesLoadTheirExactIdentityResources()
        throws
    {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let resources = try XCTUnwrap(
            ReceivedCipherPresentationResourcePlan(descriptor)
        )

        XCTAssertEqual(
            ThemeFidelityQualificationRoute.requiredSurfaceResourceIDs(
                surface: .receivedCipher,
                descriptor: descriptor
            ),
            resources.primaryResourceIDs
        )
        XCTAssertEqual(
            ThemeFidelityQualificationRoute.requiredSurfaceResourceIDs(
                surface: .shareBuilder,
                descriptor: descriptor
            ),
            resources.shareCardResourceIDs
        )
        XCTAssertEqual(
            ThemeFidelityQualificationRoute.requiredSurfaceResourceIDs(
                surface: .staticShare,
                descriptor: descriptor
            ),
            resources.shareCardResourceIDs
        )
    }

    func testReceivedContentUsesIncomingSelectionAndRequiresIdentityArtwork()
        throws
    {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let selection = try SharePresentationSelection(
            codexID: descriptor.codex.id,
            scriptID: descriptor.codex.primaryScriptID,
            relicID: descriptor.codex.defaultRelicID,
            sealID: descriptor.codex.seals.first?.metadata.id
        )
        let receivedPresentation = try ReceivedSharePresentation(
            requestedSelection: selection,
            effectiveCodexID: descriptor.codex.id,
            providerAvailability: .available,
            renderMode: .requestedCodex,
            safePreviewStatus: .absent,
            provenanceStatus: .verified
        )
        let pending = PendingMessageViewState(try ReceivedMessageDTO(
            id: MessageID(rawValue: UUID()),
            receivedAt: Date(timeIntervalSince1970: 1_000),
            plaintext: "Meet beneath the silver bough at moonrise.",
            senderName: "Lunawen",
            cipherID: CipherID(rawValue: UUID()),
            cipherName: "Moonrise Meeting",
            presentation: receivedPresentation,
            safePreviewData: nil
        ))
        let primary = try XCTUnwrap(
            ReceivedCipherPresentationContent.resolve(
                state: .primary,
                pending: pending,
                descriptor: descriptor
            )
        )
        let share = try XCTUnwrap(
            ReceivedCipherPresentationContent.resolve(
                state: .shareCard,
                pending: pending,
                descriptor: descriptor
            )
        )

        XCTAssertEqual(primary.plan.selection, selection)
        XCTAssertEqual(share.plan.selection, selection)
        XCTAssertTrue(
            primary.requiredImageResourceIDs.isSuperset(
                of: primary.identityResources.primaryResourceIDs
            )
        )
        XCTAssertTrue(
            share.requiredImageResourceIDs.isSuperset(
                of: share.identityResources.shareCardResourceIDs
            )
        )
        XCTAssertEqual(
            primary.identityResources.allResourceIDs
                .union(share.identityResources.allResourceIDs).count,
            5
        )
    }

    func testMoonleafReceivedIdentityAssetsDecodeThroughRuntimePresentation()
        throws
    {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let received = try XCTUnwrap(descriptor.codex.receivedPresentation)
        let names: [ThemeResourceID: String] = [
            received.primarySenderAvatarResourceID:
                "moonleaf-received-primary-sender-avatar",
            received.shareSenderAvatarResourceID:
                "moonleaf-received-share-sender-avatar",
            received.shareCodexBadgeResourceID:
                "moonleaf-received-share-codex-badge",
            received.primaryMedallion.resourceID:
                "moonleaf-received-primary-medallion",
            received.shareMedallion.resourceID:
                "moonleaf-received-share-medallion",
        ]
        let references = Dictionary(
            uniqueKeysWithValues: descriptor.resources.map { ($0.id, $0) }
        )
        let runtimePresentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )

        for resourceID in names.keys.sorted() {
            let expected = try XCTUnwrap(references[resourceID])
            let name = try XCTUnwrap(names[resourceID])
            let url = try XCTUnwrap(
                RuneScribeThemeMoonleafModuleBootstrap.resourceBundle.url(
                    forResource: name,
                    withExtension: "png"
                )
            )
            let data = try Data(contentsOf: url)
            let resolved = try ResolvedThemeResourceDTO(
                codexID: descriptor.codex.id,
                resourceID: resourceID,
                role: expected.role,
                mediaType: expected.mediaType,
                integrity: expected.integrity,
                verifiedSHA256: expected.integrity.sha256,
                data: data
            )
            let image = try runtimePresentation.makeThemeImageReference(
                resolvedResource: resolved,
                expectedReference: expected,
                expectedCodexID: descriptor.codex.id,
                contentRevision: 43
            )

            XCTAssertNotNil(image.image, resourceID.rawValue)
            XCTAssertEqual(image.pixelSize, expected.integrity.pixelSize)
        }
    }

    func testLayoutRecommendationUsesCompositionCapacity() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let short = try composition(
            descriptor: descriptor,
            sealID: nil,
            inscription: "ᚠ"
        )
        let capacity = Int(short.layout.maximumGlyphLines) * 24
        let medium = try composition(
            descriptor: descriptor,
            sealID: nil,
            inscription: String(repeating: "ᚠ", count: max(2, capacity / 2))
        )
        let long = try composition(
            descriptor: descriptor,
            sealID: nil,
            inscription: String(repeating: "ᚠ", count: capacity)
        )

        XCTAssertEqual(ThemeInscriptionLayoutChoice.recommended(for: short), .short)
        XCTAssertEqual(ThemeInscriptionLayoutChoice.recommended(for: medium), .medium)
        XCTAssertEqual(ThemeInscriptionLayoutChoice.recommended(for: long), .long)
    }

    func testSettledProductPreviewDoesNotOfferSyntheticLayoutMutation() {
        XCTAssertTrue(ThemeInscriptionPreviewControls.layoutSelection.showsLayoutPicker)
        XCTAssertEqual(
            ThemeInscriptionPreviewControls.layoutSelection.primaryActionTitle,
            "Apply Layout"
        )
        XCTAssertFalse(ThemeInscriptionPreviewControls.settledResult.showsLayoutPicker)
        XCTAssertEqual(
            ThemeInscriptionPreviewControls.settledResult.primaryActionTitle,
            "Done"
        )
    }

    func testPresentationMetricsPreserveCanonicalDefaultGeometry() {
        let metrics = ThemePresentationScreenMetrics(
            size: ThemePresentationScreenMetrics.referenceSize
        )

        XCTAssertEqual(metrics.scale, 1, accuracy: 0.001)
        XCTAssertEqual(metrics.dynamicTypeScale, 1, accuracy: 0.001)
        XCTAssertFalse(metrics.usesAccessibleLayout)
        XCTAssertFalse(metrics.usesStackedControls)
        XCTAssertEqual(metrics.headerHeight, 142, accuracy: 0.001)
        XCTAssertEqual(metrics.headerButtonSize, 76, accuracy: 0.001)
        XCTAssertEqual(metrics.primaryActionHeight, 112, accuracy: 0.001)
        XCTAssertEqual(metrics.layoutPickerHeight, 82, accuracy: 0.001)
        XCTAssertEqual(metrics.receivedPrimaryActionHeight, 112, accuracy: 0.001)
        XCTAssertEqual(metrics.receivedShareCardActionHeight, 104, accuracy: 0.001)
        XCTAssertEqual(metrics.fontSize(46), 46, accuracy: 0.001)
    }

    func testPresentationMetricsClampPhoneTargetsToFortyFourPoints() {
        let metrics = ThemePresentationScreenMetrics(
            size: CGSize(width: 320, height: 568)
        )

        XCTAssertEqual(metrics.headerButtonSize, 44, accuracy: 0.001)
        XCTAssertEqual(metrics.primaryActionHeight, 44, accuracy: 0.001)
        XCTAssertEqual(metrics.layoutChoiceHeight, 44, accuracy: 0.001)
        XCTAssertEqual(metrics.layoutPickerHeight, 44, accuracy: 0.001)
        XCTAssertEqual(metrics.receivedPrimaryActionHeight, 44, accuracy: 0.001)
        XCTAssertEqual(metrics.receivedShareCardActionHeight, 44, accuracy: 0.001)
    }

    func testPresentationMetricsScaleAndReflowAtAccessibilitySizes() {
        let standard = ThemePresentationScreenMetrics(
            size: CGSize(width: 320, height: 568)
        )
        let accessible = ThemePresentationScreenMetrics(
            size: CGSize(width: 320, height: 568),
            dynamicTypeScale: 3,
            usesAccessibleLayout: true
        )

        XCTAssertTrue(accessible.usesStackedControls)
        XCTAssertGreaterThan(accessible.fontSize(46), standard.fontSize(46))
        XCTAssertGreaterThan(accessible.headerHeight, standard.headerHeight)
        XCTAssertGreaterThan(accessible.primaryActionHeight, standard.primaryActionHeight)
        XCTAssertGreaterThan(accessible.layoutPickerHeight, standard.layoutPickerHeight)
        XCTAssertGreaterThan(
            accessible.receivedActionRowHeight(for: .primary),
            standard.receivedActionRowHeight(for: .primary)
        )
        XCTAssertEqual(
            accessible.layoutPickerHeight,
            accessible.layoutChoiceHeight * 3 + 2,
            accuracy: 0.001
        )
    }

    func testReceivedDecodeActionTruthfullyReportsAlreadyDecodedState() throws {
        XCTAssertFalse(ReceivedCipherDecodeActionPolicy.isEnabled)
        XCTAssertEqual(
            ReceivedCipherDecodeActionPolicy.accessibilityValue,
            "Already decoded"
        )
        XCTAssertFalse(ReceivedCipherDecodeActionPolicy.accessibilityHint.isEmpty)

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/ThemePresentationScreens.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("isEnabled: ReceivedCipherDecodeActionPolicy.isEnabled")
        )
        XCTAssertTrue(source.contains(".disabled(!isEnabled)"))
        XCTAssertTrue(
            source.contains(
                "accessibilityValue: ReceivedCipherDecodeActionPolicy.accessibilityValue"
            )
        )
    }

    func testReceivedCompletionActionTruthfullyReportsDismissalSemantics() throws {
        XCTAssertEqual(ReceivedCipherCompletionActionPolicy.title, "Done")
        XCTAssertEqual(
            ReceivedCipherCompletionActionPolicy.systemImage,
            "checkmark"
        )
        XCTAssertEqual(
            ReceivedCipherCompletionActionPolicy.accessibilityHint,
            "Closes this message and clears it from pending messages."
        )

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/ThemePresentationScreens.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func doneButton("))
        let end = try XCTUnwrap(
            source.range(
                of: "private func replyButton(",
                range: start.upperBound..<source.endIndex
            )
        )
        let doneButton = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            doneButton.contains("title: ReceivedCipherCompletionActionPolicy.title")
        )
        XCTAssertTrue(doneButton.contains("action: doneAction"))
        XCTAssertTrue(
            doneButton.contains(
                ".accessibilityHint(ReceivedCipherCompletionActionPolicy.accessibilityHint)"
            )
        )
        XCTAssertFalse(doneButton.contains("Save"))

        let receivedMessageSourceURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("ReceivedMessageView.swift")
        let receivedMessageSource = try String(
            contentsOf: receivedMessageSourceURL,
            encoding: .utf8
        )
        XCTAssertTrue(receivedMessageSource.contains("doneAction: { dismiss() }"))
        XCTAssertFalse(receivedMessageSource.contains("saveAction:"))
    }

    func testAccessibilityReceivedPlaintextReflowsOutsideTheFixedCanvas() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/ThemePresentationScreens.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private func accessiblePlaintext(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private func actionRow(",
                range: start.upperBound..<source.endIndex
            )
        )
        let accessiblePlaintext = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(accessiblePlaintext.contains("metrics.fontSize("))
        XCTAssertTrue(accessiblePlaintext.contains(".lineLimit(nil)"))
        XCTAssertTrue(
            accessiblePlaintext.contains(
                ".fixedSize(horizontal: false, vertical: true)"
            )
        )
        XCTAssertTrue(accessiblePlaintext.contains("Decoded message"))
        XCTAssertFalse(accessiblePlaintext.contains(".clipped()"))
    }

    func testReceivedStatesHaveDistinctProductionCaptureIdentity() {
        XCTAssertNotEqual(
            ReceivedCipherPresentationState.primary.captureIdentifier,
            ReceivedCipherPresentationState.shareCard.captureIdentifier
        )
        XCTAssertEqual(
            ReceivedCipherPresentationState.primary.captureIdentifier,
            ThemeCaptureIdentifier.screenReceivedCipher
        )
        XCTAssertEqual(
            ReceivedCipherPresentationState.shareCard.captureIdentifier,
            ThemeCaptureIdentifier.screenShareBuilder
        )
        XCTAssertNotEqual(
            ReceivedCipherPresentationState.primary.accessibilityValue,
            ReceivedCipherPresentationState.shareCard.accessibilityValue
        )

        let primary = ReceivedCipherPresentationStyle.style(for: .primary)
        let shareCard = ReceivedCipherPresentationStyle.style(for: .shareCard)
        XCTAssertEqual(primary.plaintextPointSize, 40)
        XCTAssertEqual(primary.plaintextMaximumWidth, 560)
        XCTAssertEqual(primary.plaintextLineLimit, 2)
        XCTAssertEqual(primary.plaintextVerticalOffset, -52)
        XCTAssertEqual(shareCard.plaintextPointSize, 42)
        XCTAssertEqual(shareCard.plaintextMaximumWidth, 460)
        XCTAssertEqual(shareCard.plaintextLineLimit, 2)
        XCTAssertEqual(shareCard.plaintextVerticalOffset, -82)
        XCTAssertNotEqual(primary, shareCard)
    }

    func testReceivedTimestampIsDeterministicForInjectedClockAndEnvironment() throws {
        let calendar = Calendar(identifier: .gregorian)
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let receivedAt = try date(
            year: 2026,
            month: 8,
            day: 27,
            hour: 21,
            minute: 40,
            calendar: calendar,
            timeZone: timeZone
        )
        let sameDay = try date(
            year: 2026,
            month: 8,
            day: 27,
            hour: 21,
            minute: 45,
            calendar: calendar,
            timeZone: timeZone
        )
        let nextDay = try date(
            year: 2026,
            month: 8,
            day: 28,
            hour: 1,
            minute: 0,
            calendar: calendar,
            timeZone: timeZone
        )

        XCTAssertEqual(
            ReceivedCipherTimestampFormatter.string(
                receivedAt: receivedAt,
                relativeTo: sameDay,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            ),
            "Received Today at 9:40 PM"
        )
        XCTAssertEqual(
            ReceivedCipherTimestampFormatter.string(
                receivedAt: receivedAt,
                relativeTo: nextDay,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            ),
            "Received Aug 27, 2026 at 9:40 PM"
        )
    }

    func testProductionAssembliesAcceptInjectedContentAndResourceResolution() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let plan = try composition(
            descriptor: descriptor,
            sealID: descriptor.codex.seals.first?.metadata.id,
            inscription: "ᚠᚢᚦᚨ"
        )
        let message = PendingMessageViewState(ReceivedMessageDTO(
            id: MessageID(rawValue: UUID()),
            receivedAt: Date(timeIntervalSince1970: 1_000),
            plaintext: "Injected plaintext",
            senderName: "Injected sender",
            cipherID: CipherID(rawValue: UUID()),
            cipherName: "Injected cipher"
        ))
        let image: (ThemeResourceID) -> Image = { _ in Image(systemName: "photo") }

        _ = ThemeInscriptionPreviewView(
            descriptor: descriptor,
            plan: plan,
            selectedLayout: .long,
            image: image
        )
        _ = ReceivedMessageView(
            pending: message,
            onOpenCodex: {},
            onReply: { _ in }
        )
    }

    func testReceivedPreparationRequestTracksEveryAuthorityInput() throws {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let selection = try SharePresentationSelection(
            codexID: descriptor.codex.id,
            scriptID: descriptor.codex.primaryScriptID,
            relicID: descriptor.codex.defaultRelicID
        )
        let receivedPresentation = try ReceivedSharePresentation(
            requestedSelection: selection,
            effectiveCodexID: descriptor.codex.id,
            providerAvailability: .available,
            renderMode: .requestedCodex,
            safePreviewStatus: .absent,
            provenanceStatus: .verified
        )
        let messageID = MessageID(rawValue: UUID())
        let receivedAt = Date(timeIntervalSince1970: 1_000)

        func pending(
            status: ReceivedSenderIdentityStatusDTO = .awaitingCipherConfirmation,
            plaintext: String = "Moonrise",
            senderName: String = "Lunawen",
            includesPresentation: Bool = true
        ) throws -> PendingMessageViewState {
            try PendingMessageViewState(ReceivedMessageDTO(
                id: messageID,
                receivedAt: receivedAt,
                plaintext: plaintext,
                senderName: senderName,
                cipherID: CipherID(rawValue: UUID()),
                cipherName: "Moonrise Meeting",
                senderIdentityStatus: status,
                presentation: includesPresentation ? receivedPresentation : nil,
                safePreviewData: nil
            ))
        }

        let awaiting = try pending()
        let baseline = ReceivedCipherPresentationRequest(
            pending: awaiting,
            themeSnapshotRevision: 7,
            state: .primary,
            reduceMotion: false
        )
        XCTAssertEqual(
            baseline,
            ReceivedCipherPresentationRequest(
                pending: try pending(senderName: "Updated display name"),
                themeSnapshotRevision: 7,
                state: .primary,
                reduceMotion: false
            )
        )
        XCTAssertNotEqual(
            baseline,
            ReceivedCipherPresentationRequest(
                pending: try pending(status: .confirmedCipher),
                themeSnapshotRevision: 7,
                state: .primary,
                reduceMotion: false
            )
        )
        XCTAssertNotEqual(
            baseline,
            ReceivedCipherPresentationRequest(
                pending: try pending(plaintext: "Changed inscription"),
                themeSnapshotRevision: 7,
                state: .primary,
                reduceMotion: false
            )
        )
        XCTAssertNotEqual(
            baseline,
            ReceivedCipherPresentationRequest(
                pending: try pending(includesPresentation: false),
                themeSnapshotRevision: 7,
                state: .primary,
                reduceMotion: false
            )
        )
        XCTAssertNotEqual(
            baseline,
            ReceivedCipherPresentationRequest(
                pending: awaiting,
                themeSnapshotRevision: 8,
                state: .primary,
                reduceMotion: false
            )
        )
        XCTAssertNotEqual(
            baseline,
            ReceivedCipherPresentationRequest(
                pending: awaiting,
                themeSnapshotRevision: 7,
                state: .shareCard,
                reduceMotion: false
            )
        )
        XCTAssertNotEqual(
            baseline,
            ReceivedCipherPresentationRequest(
                pending: awaiting,
                themeSnapshotRevision: 7,
                state: .primary,
                reduceMotion: true
            )
        )
    }

    func testProductionSourceDoesNotBranchOnProviderOrReadReferencePixels() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/ThemePresentationScreens.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8).lowercased()

        for forbidden in [
            "theme.moonleaf",
            "theme.norse",
            "relic.moonleaf",
            "relic.norse",
            "referenceasset",
            "controlling-goldens",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(source.contains("themeartifactcanvas("))
        XCTAssertTrue(source.contains("themeartifactpreview("))
    }

    private func composition(
        descriptor: ThemeDescriptor,
        sealID: ArtifactID?,
        inscription: String
    ) throws -> ThemeArtifactCompositionPlan {
        let selection = try SharePresentationSelection(
            codexID: descriptor.codex.id,
            scriptID: descriptor.codex.primaryScriptID,
            relicID: descriptor.codex.defaultRelicID,
            sealID: sealID
        )
        return try ThemeArtifactCompositionPolicy.interactivePlan(
            selection: selection,
            inscription: inscription,
            descriptor: descriptor,
            colorMode: .standard,
            reduceMotion: true,
            accessibilityLabel: "Injected inscription"
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        calendar: Calendar,
        timeZone: TimeZone
    ) throws -> Date {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        return try XCTUnwrap(localCalendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
