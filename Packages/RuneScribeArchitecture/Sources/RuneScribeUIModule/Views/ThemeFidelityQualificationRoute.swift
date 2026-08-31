import Foundation
@_spi(ThemeFidelityQualification) import RuneScribeContracts
import RuneScribeRuntimeCore
import RuneScribeUIRuntime
import SwiftUI

#if os(iOS)
import UIKit
#endif

enum ThemeFidelityQualificationRouteError: Error, Equatable, Sendable {
    case destinationMismatch
    case invalidDescriptor
    case missingResource(ThemeResourceID)
    case runtimeDidNotSettle
    case safePreviewUnavailable
}

struct ThemeFidelityQualificationCatalogBinding: Equatable, Sendable {
    let initialTab: CodexCatalogTab
    let variant: CodexCatalogVariant

    static func resolve(
        surface: ThemeFidelityQualificationLaunch.Surface
    ) -> Self? {
        switch surface {
        case .relicPicker:
            Self(initialTab: .relics, variant: .featuredSelected)
        case .sealPicker:
            Self(initialTab: .seals, variant: .featuredSelected)
        case .vaultEncountered, .vaultOwned:
            Self(initialTab: .relics, variant: .acquisition)
        default:
            nil
        }
    }
}

struct ThemeFidelityQualificationHostView: View {
    let launch: ThemeFidelityQualificationLaunch
    @ObservedObject var session: RuneScribeUISession
    @State private var settledContent: AnyView?

    var body: some View {
        Group {
            if let settledContent {
                settledContent
            } else {
                RuntimeMetalBackground()
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
        .task(id: taskID) {
            let deadline = Date().addingTimeInterval(8)
            while !Task.isCancelled, Date() < deadline {
                do {
                    try await session.prepareQualificationTheme(codexID: launch.codexID)
                    let content = try await ThemeFidelityQualificationRoute.make(
                        launch: launch,
                        session: session
                    )
                    guard !Task.isCancelled else { return }
                    settledContent = content
                    return
                } catch RuneScribeRuntimeError.runtimeNotRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
        }
    }

    private var taskID: String {
        "\(launch.codexID.rawValue)|\(launch.surface.rawValue)|\(launch.destination.rawValue)"
    }
}

@MainActor
enum ThemeFidelityQualificationRoute {
    static func make(
        launch: ThemeFidelityQualificationLaunch,
        session: RuneScribeUISession
    ) async throws -> AnyView {
        try validateDestination(launch.destination)
        guard await applicationStateSettled(session) else {
            throw ThemeFidelityQualificationRouteError.runtimeDidNotSettle
        }
        await session.loadActiveThemeCatalogVisuals()
        if launch.surface.requiresCodexCardImages {
            await session.loadThemeCodexCardPreviews()
        }
        guard let descriptor = session.themeSnapshot?.effectiveTheme,
              descriptor.id == launch.themeID,
              descriptor.codex.id == launch.codexID
        else {
            throw ThemeFidelityQualificationRouteError.invalidDescriptor
        }
        try await session.loadThemeFidelityQualificationVisuals(
            codexID: launch.codexID,
            resourceIDs: requiredSurfaceResourceIDs(
                surface: launch.surface,
                descriptor: descriptor
            )
        )

        let model = try await ThemeFidelityQualificationRenderModel.load(
            launch: launch,
            session: session
        )
        try configureProgression(
            launch: launch,
            model: model,
            session: session
        )
        let content = try content(
            launch: launch,
            model: model,
            session: session
        )
        let diagnosticWitnesses = try diagnosticWitnesses(
            launch: launch,
            model: model,
            session: session
        )
        let accessibilityPreferences = RuntimeAccessibilityPreferences(
            forcesReduceMotion: launch.appearance == .reduceMotion,
            forcesIncreasedContrast: launch.appearance == .highContrast
        )
        let backgroundVariant: ThemeCaptureIdentifier.BackgroundVariant = switch launch.appearance {
        case .highContrast: .highContrast
        case .reduceMotion: .reduceMotion
        case .accessibilityXXXL, .standard: .standard
        }
        let backgroundIdentifier = ThemeCaptureIdentifier.background(
            themeID: launch.themeID,
            variant: backgroundVariant
        )

        return AnyView(
            ZStack {
                if launch.surface != .workspaceEmpty {
                    RuntimeMetalBackground()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .clipped()
                        .themeCaptureViewportIdentifier(backgroundIdentifier)
                }
                content
                ThemeFidelityQualificationDiagnosticOverlay(
                    witnesses: diagnosticWitnesses
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environmentObject(session)
            .environment(
                \.runtimeApplicationResourcePresentation,
                session.resourcePresentation
            )
            .environment(
                \.runtimeAccessibilityPreferences,
                accessibilityPreferences
            )
            .environment(\.themeCaptureIdentifiersEnabled, true)
            .environment(
                \.dynamicTypeSize,
                launch.appearance == .accessibilityXXXL ? .accessibility5 : .large
            )
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .preferredColorScheme(.dark)
        )
    }

    static func requiredSurfaceResourceIDs(
        surface: ThemeFidelityQualificationLaunch.Surface,
        descriptor: ThemeDescriptor
    ) -> Set<ThemeResourceID> {
        switch surface {
        case .relicPicker, .sealPicker, .vaultEncountered, .vaultOwned:
            return catalogResourceIDs(descriptor: descriptor)
        case .receivedCipher:
            return ReceivedCipherPresentationResourcePlan(descriptor)?
                .resourceIDs(for: .primary) ?? []
        case .shareBuilder, .staticShare:
            return ReceivedCipherPresentationResourcePlan(descriptor)?
                .resourceIDs(for: .shareCard) ?? []
        case .mastery:
            return Set(
                descriptor.codex.frames.prefix(1).map(\.staticFallbackResourceID)
                    + descriptor.codex.crests.prefix(1).map {
                        $0.thumbnailResourceID ?? $0.staticFallbackResourceID
                    }
            )
        default:
            return []
        }
    }

    fileprivate static func catalogResourceIDs(
        descriptor: ThemeDescriptor
    ) -> Set<ThemeResourceID> {
        var resourceIDs = Set(descriptor.codex.relics.compactMap {
            $0.metadata.availability == .reservedInactive
                ? nil : $0.thumbnailResourceID
        })
        resourceIDs.formUnion(descriptor.codex.seals.compactMap {
            $0.metadata.availability == .reservedInactive
                ? nil : $0.thumbnailResourceID
        })
        if let defaultRelic = descriptor.codex.relics.first(where: {
            $0.metadata.id == descriptor.codex.defaultRelicID
        }) {
            resourceIDs.insert(defaultRelic.staticFallbackResourceID)
        }
        return resourceIDs
    }

    private static func content(
        launch: ThemeFidelityQualificationLaunch,
        model: ThemeFidelityQualificationRenderModel,
        session: RuneScribeUISession
    ) throws -> AnyView {
        let workspaceViewportWidth = qualificationWorkspaceViewportWidth(
            for: launch.destination
        )
        switch launch.surface {
        case .workspaceEmpty:
            return AnyView(RootView(
                session: session,
                allowsColdLaunchSplash: false
            ))
        case .composeShort:
            return AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.shortPlan,
                    presentation: model.presentation
                ),
                initialComposeCaptureLength: .short,
                forcesScrollableWorkspaceLayout: true,
                qualificationViewportWidth: workspaceViewportWidth
            ))
        case .composeLong:
            return AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.longPlan,
                    presentation: model.presentation
                ),
                initialComposeCaptureLength: .long,
                forcesScrollableWorkspaceLayout: true,
                qualificationViewportWidth: workspaceViewportWidth
            ))
        case .inscriptionPreview:
            return AnyView(ThemeInscriptionPreviewView(
                descriptor: model.descriptor,
                plan: model.inscriptionPlan,
                selectedLayout: .long,
                image: model.requiredImage
            ))
        case .receivedCipher:
            return AnyView(ReceivedCipherPresentationView(
                state: .primary,
                pending: try receivedMessage(model: model),
                receivedAt: receivedPresentationDate,
                relativeDate: receivedPresentationRelativeDate,
                descriptor: model.descriptor,
                plan: model.receivedPlan,
                image: model.requiredImage
            ))
        case .shareBuilder:
            guard let cipher = session.activeCipher else {
                throw ThemeFidelityQualificationRouteError.runtimeDidNotSettle
            }
            var catalog = try session.makeShareBuilderCatalog()
            let originalEffects = catalog.draft.effects
            catalog.selectEffects(originalEffects == .full ? .reduced : .full)
            catalog.markCurrentDraftAsDefaults()
            catalog.selectEffects(originalEffects)
            return AnyView(ShareBuilderView(
                source: .cipherInvitation(
                    cipherID: cipher.id,
                    displayName: cipher.label
                ),
                initialCatalog: catalog,
                initialViewport: .controls
            ))
        case .staticShare:
            return AnyView(ThemeFidelityQualificationStaticShareView(
                image: model.safePreviewImage
            ))
        case .settingsCodexCard:
            return AnyView(SettingsView(initialViewport: .codexCard))
        case .settingsDefaultsPreview:
            return AnyView(SettingsView(initialViewport: .defaultsPreview))
        case .vaultLocked:
            return AnyView(VaultProgressView(
                initialSection: .vault,
                initialCodexCardFixture: model.descriptor.criticality == .requiredBase
                    ? nil
                    : VaultProgressCodexCardFixture(
                        visualState: .locked,
                        providerIsAvailable: true,
                        ownership: .unowned,
                        isSelectable: false,
                        showsSelectedArtifacts: false
                    )
            ))
        case .vaultEncountered, .vaultOwned:
            guard let binding = ThemeFidelityQualificationCatalogBinding.resolve(
                surface: launch.surface
            ) else { throw ThemeFidelityQualificationRouteError.invalidDescriptor }
            return codexCatalog(
                initialTab: binding.initialTab,
                variant: binding.variant,
                launch: launch,
                model: model,
                session: session
            )
        case .vaultSelected:
            return AnyView(VaultProgressView(
                initialSection: .vault,
                initialCodexCardFixture: VaultProgressCodexCardFixture(
                    visualState: .selected,
                    providerIsAvailable: true,
                    ownership: .selected,
                    isSelectable: false,
                    showsSelectedArtifacts: true
                )
            ))
        case .vaultProgress:
            return AnyView(VaultProgressView(
                initialSection: .journey,
                initialViewport: .journey(launch.codexID)
            ))
        case .relicPicker:
            guard let binding = ThemeFidelityQualificationCatalogBinding.resolve(
                surface: launch.surface
            ) else { throw ThemeFidelityQualificationRouteError.invalidDescriptor }
            return codexCatalog(
                initialTab: binding.initialTab,
                variant: binding.variant,
                launch: launch,
                model: model,
                session: session
            )
        case .sealPicker:
            guard let binding = ThemeFidelityQualificationCatalogBinding.resolve(
                surface: launch.surface
            ) else { throw ThemeFidelityQualificationRouteError.invalidDescriptor }
            return codexCatalog(
                initialTab: binding.initialTab,
                variant: binding.variant,
                launch: launch,
                model: model,
                session: session
            )
        case .mastery:
            let reveal = try masteryReveal(
                model: model,
                titleID: launch.masteryTitleID,
                titlePresentation: model.masteryTitlePresentation
            )
            session.revealQueue.adopt(head: reveal, canPresent: true)
            session.setRevealBlocker(.rootPresentation, active: false)
            return AnyView(UnlockRevealView(
                reveal: reveal,
                initialPlan: UnlockRevealPresentationPlan(
                    revealID: reveal.revealID,
                    sequenceDurationSeconds: 0,
                    visualMode: .none,
                    announcement: nil,
                    isStatic: true
                ),
                initialThemeVisualPresentation: model.presentation
            ))
        case .highContrast:
            return AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.highContrastPlan,
                    presentation: model.presentation
                ),
                forcesScrollableWorkspaceLayout: true,
                qualificationViewportWidth: workspaceViewportWidth
            ))
        case .reduceMotion:
            return AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.reduceMotionPlan,
                    presentation: model.presentation
                ),
                forcesScrollableWorkspaceLayout: true,
                qualificationViewportWidth: workspaceViewportWidth
            ))
        case .largeText:
            return AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.shortPlan,
                    presentation: model.presentation
                ),
                initialViewport: .resultActions,
                forcesScrollableWorkspaceLayout: true,
                qualificationViewportWidth: workspaceViewportWidth
            ))
        }
    }

    private static func qualificationWorkspaceViewportWidth(
        for destination: ThemeFidelityQualificationLaunch.Destination
    ) -> CGFloat? {
        #if os(macOS)
        switch destination {
        case .macOSStandard: 720
        case .macOSResized: 980
        case .iPhonePortrait, .iPadPortrait: nil
        }
        #else
        nil
        #endif
    }

    private static let receivedCipherID = UUID(
        uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    )!
    private static let receivedCipherName = "Moonrise Meeting"
    private static let receivedPresentationDate = Date(
        timeIntervalSinceReferenceDate: 809_299_200
    )
    private static let receivedPresentationRelativeDate = Date(
        timeIntervalSinceReferenceDate: 809_299_500
    )
    private static func applicationStateSettled(
        _ session: RuneScribeUISession
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if session.snapshot != nil, !session.isLoading { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return session.snapshot != nil && !session.isLoading
    }

    private static func validateDestination(
        _ destination: ThemeFidelityQualificationLaunch.Destination
    ) throws {
        #if os(iOS)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        guard (isPad && destination == .iPadPortrait)
                || (!isPad && destination == .iPhonePortrait)
        else { throw ThemeFidelityQualificationRouteError.destinationMismatch }
        #elseif os(macOS)
        guard destination == .macOSStandard || destination == .macOSResized else {
            throw ThemeFidelityQualificationRouteError.destinationMismatch
        }
        #endif
    }

    private static func receivedMessage(
        model: ThemeFidelityQualificationRenderModel
    ) throws -> PendingMessageViewState {
        let presentation = try ReceivedSharePresentation(
            requestedSelection: model.selection,
            effectiveCodexID: model.descriptor.codex.id,
            providerAvailability: .available,
            renderMode: .requestedCodex,
            safePreviewStatus: .valid,
            provenanceStatus: .verified,
            encounterRecordingStatus: .recorded,
            resourceMetadata: model.safePreviewResourceMetadata
        )
        return PendingMessageViewState(try ReceivedMessageDTO(
            id: MessageID(rawValue: UUID(
                uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
            )!),
            receivedAt: Date(timeIntervalSinceReferenceDate: 809_299_200),
            plaintext: "Meet beneath the silver bough at moonrise.",
            senderName: "Lunawen",
            cipherID: CipherID(rawValue: receivedCipherID),
            cipherName: receivedCipherName,
            senderIdentityStatus: .trustedLocalCipher,
            presentation: presentation,
            safePreviewData: model.safePreviewData
        ))
    }

    private static func codexCatalog(
        initialTab: CodexCatalogTab,
        variant: CodexCatalogVariant,
        launch: ThemeFidelityQualificationLaunch,
        model: ThemeFidelityQualificationRenderModel,
        session: RuneScribeUISession
    ) -> AnyView {
        let root = CodexCatalogRoot(
            descriptor: model.descriptor,
            presentation: model.presentation,
            initialTab: initialTab,
            variant: variant,
            runtimeState: session.activeThemeArtifactCatalogRuntimeState
        )
        switch launch.surface {
        case .relicPicker:
            return AnyView(root.themeCaptureViewportIdentifier(
                ThemeCaptureIdentifier.artifactPickerScreen(
                    kind: .relic,
                    codexID: model.descriptor.codex.id
                )
            ))
        case .sealPicker:
            return AnyView(root.themeCaptureViewportIdentifier(
                ThemeCaptureIdentifier.artifactPickerScreen(
                    kind: .seal,
                    codexID: model.descriptor.codex.id
                )
            ))
        default:
            return AnyView(root)
        }
    }

    private static func configureProgression(
        launch: ThemeFidelityQualificationLaunch,
        model: ThemeFidelityQualificationRenderModel,
        session: RuneScribeUISession
    ) throws {
        let surface = launch.surface
        session.resetRevealPresentationState()
        var ownership: [ProgressionOwnershipDTO] = []
        var gates: [ProgressionCodexGateDTO] = []

        if surface == .vaultEncountered,
           model.descriptor.criticality == .requiredBase {
            let artifactID = try focusedVaultArtifactID(surface: surface, model: model)
            let metadata = try metadata(for: artifactID, model: model)
            ownership = [try ProgressionOwnershipDTO(
                kind: contentKind(for: artifactID, model: model),
                reference: .artifact(artifactID),
                presentation: try ProgressionPresentationDTO(
                    displayName: metadata.displayName.fallbackValue,
                    summary: metadata.description.fallbackValue,
                    fallbackSystemImageName: "sparkles"
                ),
                state: .encountered,
                firstEncounteredAt: Date(timeIntervalSince1970: 1_699_999_000),
                grantedAt: nil,
                providerAvailability: .unavailable,
                renderState: .genericFallback
            )]
        }

        if surface == .vaultProgress {
            guard let snapshot = session.themeSnapshot,
                  let baseProvider = snapshot.providers.first(where: {
                      $0.codexID == model.descriptor.fallbackCodexID
                  })
            else { throw ThemeFidelityQualificationRouteError.invalidDescriptor }

            let baseComponent = try ProgressionGateComponentDTO(
                componentID: "journey.\(baseProvider.codexID.rawValue).included",
                label: "Included",
                current: 1,
                target: 1,
                isComplete: true
            )
            let baseGate = try ProgressionCodexGateDTO(
                codexID: baseProvider.codexID,
                presentation: try ProgressionPresentationDTO(
                    displayName: baseProvider.displayName,
                    summary: "Included with Rune Scribe.",
                    fallbackSystemImageName: "books.vertical.fill"
                ),
                journeyOrder: model.descriptor.criticality == .requiredBase ? 0 : 1,
                completedRuleCount: 1,
                requiredRuleCount: 1,
                progress: try ProgressionNumericProgressDTO(current: 1, target: 1),
                components: [baseComponent],
                unlockedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            if model.descriptor.criticality == .requiredBase {
                gates = [baseGate]
            } else {
                guard let progressProvider = snapshot.providers.first(where: {
                    $0.codexID == launch.codexID
                }) else { throw ThemeFidelityQualificationRouteError.invalidDescriptor }
                let milestoneComponents = try (1 ... 5).map { index in
                    try ProgressionGateComponentDTO(
                        componentID: "journey.\(progressProvider.codexID.rawValue).milestone-\(index)",
                        label: "Requirement \(index)",
                        current: index <= 3 ? 1 : 0,
                        target: 1,
                        isComplete: index <= 3
                    )
                }
                gates = [
                    try ProgressionCodexGateDTO(
                        codexID: progressProvider.codexID,
                        presentation: try ProgressionPresentationDTO(
                            displayName: progressProvider.displayName,
                            summary: "Complete all five requirements to unlock this Codex.",
                            fallbackSystemImageName: "circle.grid.2x2.fill"
                        ),
                        journeyOrder: 0,
                        completedRuleCount: 3,
                        requiredRuleCount: 5,
                        progress: try ProgressionNumericProgressDTO(current: 3, target: 5),
                        components: milestoneComponents,
                        unlockedAt: nil
                    ),
                    baseGate,
                ]
            }
            ownership.append(try ProgressionOwnershipDTO(
                kind: .codex,
                reference: .codex(baseProvider.codexID),
                presentation: try ProgressionPresentationDTO(
                    displayName: baseProvider.displayName,
                    summary: "Included with Rune Scribe.",
                    fallbackSystemImageName: "books.vertical.fill"
                ),
                state: .owned,
                firstEncounteredAt: Date(timeIntervalSince1970: 1_699_999_000),
                grantedAt: Date(timeIntervalSince1970: 1_700_000_000),
                providerAvailability: .active,
                renderState: .providerAvailable
            ))
        }

        let revision = UInt64(
            10_000 + surface.rawValue.utf8.reduce(0) { $0 + Int($1) }
        )
        let seededTitles: [ProgressionTitleDTO]
        if surface == .mastery {
            seededTitles = [try ProgressionTitleDTO(
                titleID: launch.masteryTitleID,
                presentation: model.masteryTitlePresentation,
                isOwned: true,
                isSelected: false
            )]
        } else {
            seededTitles = []
        }
        session.progressionSnapshot = try ProgressionSnapshotDTO(
            revision: revision,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            availability: .available,
            storeHealth: .loaded,
            catalogID: nil,
            catalogVersion: nil,
            codexGates: gates,
            achievements: [],
            ownership: ownership,
            titles: seededTitles
        )
        session.progressionRailState = .available
    }

    private static func focusedVaultArtifactID(
        surface: ThemeFidelityQualificationLaunch.Surface,
        model: ThemeFidelityQualificationRenderModel
    ) throws -> ArtifactID {
        if surface == .vaultSelected { return model.selection.relicID }
        guard let artifactID = model.descriptor.codex.relics.first(where: {
            $0.metadata.availability != .included
                && $0.metadata.availability != .reservedInactive
        })?.metadata.id else {
            throw ThemeFidelityQualificationRouteError.invalidDescriptor
        }
        return artifactID
    }

    private static func metadata(
        for artifactID: ArtifactID,
        model: ThemeFidelityQualificationRenderModel
    ) throws -> ThemeArtifactMetadata {
        if let relic = model.descriptor.codex.relics.first(where: {
            $0.metadata.id == artifactID
        }) {
            return relic.metadata
        }
        if let seal = model.descriptor.codex.seals.first(where: {
            $0.metadata.id == artifactID
        }) {
            return seal.metadata
        }
        throw ThemeFidelityQualificationRouteError.invalidDescriptor
    }

    private static func contentKind(
        for artifactID: ArtifactID,
        model: ThemeFidelityQualificationRenderModel
    ) -> ProgressionContentKind {
        model.descriptor.codex.seals.contains(where: {
            $0.metadata.id == artifactID
        }) ? .seal : .relic
    }

    private static func masteryReveal(
        model: ThemeFidelityQualificationRenderModel,
        titleID: TitleID,
        titlePresentation: ProgressionPresentationDTO
    ) throws -> ProgressionRevealSummaryDTO {
        var secondary: [ProgressionContentReference] = []
        if let frame = model.descriptor.codex.frames.first {
            secondary.append(.artifact(frame.metadata.id))
        }
        if let crest = model.descriptor.codex.crests.first,
           let crestID = CrestID(rawValue: crest.metadata.id.rawValue) {
            secondary.append(.crest(crestID))
        }
        secondary.append(.title(titleID))
        let codexComponent = model.descriptor.codex.id.rawValue
        return try ProgressionRevealSummaryDTO(
            revealID: RevealID(rawValue: "reveal.\(codexComponent).mastery")!,
            transactionID: GrantTransactionID(
                rawValue: "transaction.\(codexComponent).mastery"
            )!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .presented,
            tier: .mastery,
            rarity: .mythic,
            primaryRewardID: .codex(model.descriptor.codex.id),
            primaryRewardPresentation: try ProgressionPresentationDTO(
                displayName: "\(model.descriptor.codex.displayName.fallbackValue) Mastery",
                summary: "Frame, crest, and \(titlePresentation.displayName) earned.",
                fallbackSystemImageName: "crown.fill"
            ),
            secondaryRewardIDs: secondary,
            sourceAchievementIDs: [AchievementID(
                rawValue: "achievement.\(codexComponent).mastery"
            )!]
        )
    }

    private static func diagnosticWitnesses(
        launch: ThemeFidelityQualificationLaunch,
        model: ThemeFidelityQualificationRenderModel,
        session: RuneScribeUISession
    ) throws -> [ThemeFidelityQualificationDiagnosticWitness] {
        let interactivePlan = model.plan(for: launch.surface)
        guard let capturedAt = session.snapshot?.capturedAt else {
            throw ThemeFidelityQualificationRouteError.runtimeDidNotSettle
        }
        let staticRequest = try ShareArtifactRenderRequest(
            selection: interactivePlan.selection,
            inscription: interactivePlan.inscription,
            operationID: RuntimeOperationID(
                rawValue: "operation.theme-fidelity.plan-parity"
            ),
            capturedAt: capturedAt,
            localeIdentifier: "en_US_POSIX",
            scale: 1,
            colorMode: interactivePlan.colorMode,
            reduceMotion: interactivePlan.backgroundResourceID
                == model.descriptor.codex.background.reduceMotionResourceID,
            accessibilityLabel: interactivePlan.accessibilityLabel,
            provenanceLabel: interactivePlan.provenanceLabel
        )
        let staticPlan = try ShareArtifactRenderPolicy.plan(
            request: staticRequest,
            descriptor: model.descriptor
        ).composition

        let requiredResourceIDs = requiredResourceIDs(
            launch: launch,
            model: model,
            plan: interactivePlan
        )
        let resolvedResourceIDs = Set(requiredResourceIDs.filter { resourceID in
            if model.presentation.image(for: resourceID) != nil { return true }
            return session.themeCodexCardImageReferences.values.contains(where: {
                $0.resourceID == resourceID && $0.image != nil
            })
        })
        let pickerArtworkResourceIDs: Set<ThemeResourceID> = switch launch.surface {
        case .relicPicker, .sealPicker, .vaultEncountered, .vaultOwned:
            catalogResourceIDs(descriptor: model.descriptor)
        default:
            []
        }

        var witnesses = [
            ThemeFidelityQualificationDiagnosticWitness(
                id: "theme-fidelity.diagnostic.state",
                label: "Settled qualification launch state",
                value: try jsonString(stateObject(
                    launch: launch,
                    model: model,
                    session: session
                ))
            ),
            ThemeFidelityQualificationDiagnosticWitness(
                id: "theme-fidelity.diagnostic.plan.interactive",
                label: "Live interactive composition plan",
                value: try jsonString(planObject(interactivePlan))
            ),
            ThemeFidelityQualificationDiagnosticWitness(
                id: "theme-fidelity.diagnostic.plan.static",
                label: "Live static composition plan",
                value: try jsonString(planObject(staticPlan))
            ),
            ThemeFidelityQualificationDiagnosticWitness(
                id: "theme-fidelity.diagnostic.resources",
                label: "Live resolved resource inventory",
                value: try jsonString([
                    "schemaVersion": "1.0",
                    "requiredResourceIDs": requiredResourceIDs.map(\.rawValue).sorted(),
                    "resolvedResourceIDs": resolvedResourceIDs.map(\.rawValue).sorted(),
                    "pickerArtworkResourceIDs": pickerArtworkResourceIDs
                        .map(\.rawValue).sorted(),
                ])
            ),
        ]
        let unresolved = requiredResourceIDs.subtracting(resolvedResourceIDs)
        witnesses.append(contentsOf: unresolved.sorted().map {
            ThemeFidelityQualificationDiagnosticWitness(
                id: "theme-fidelity.missing-resource.\($0.rawValue)",
                label: "Missing required Theme resource",
                value: $0.rawValue
            )
        })
        let missingPickerArtwork = pickerArtworkResourceIDs.subtracting(resolvedResourceIDs)
        witnesses.append(contentsOf: missingPickerArtwork.sorted().map {
            ThemeFidelityQualificationDiagnosticWitness(
                id: "theme-fidelity.missing-picker-artwork.\($0.rawValue)",
                label: "Missing picker artwork resource",
                value: $0.rawValue
            )
        })
        return witnesses.sorted { $0.id < $1.id }
    }

    private static func requiredResourceIDs(
        launch: ThemeFidelityQualificationLaunch,
        model: ThemeFidelityQualificationRenderModel,
        plan: ThemeArtifactCompositionPlan
    ) -> Set<ThemeResourceID> {
        var identifiers = Set([
            plan.relicResourceID,
            plan.backgroundResourceID,
        ])
        identifiers.formUnion([
            plan.sealResourceID,
            plan.frameResourceID,
        ].compactMap { $0 })
        if let relic = model.descriptor.codex.relics.first(where: {
            $0.metadata.id == model.selection.relicID
        }) {
            identifiers.insert(relic.thumbnailResourceID)
        }
        if let sealID = model.selection.sealID,
           let seal = model.descriptor.codex.seals.first(where: {
               $0.metadata.id == sealID
           }) {
            identifiers.insert(seal.thumbnailResourceID)
        }
        if launch.surface == .settingsCodexCard {
            identifiers.insert(model.descriptor.codex.vault.selectedResourceID)
        }
        if [.relicPicker, .sealPicker, .vaultEncountered, .vaultOwned]
            .contains(launch.surface) {
            identifiers.formUnion(catalogResourceIDs(descriptor: model.descriptor))
        }
        if launch.surface == .mastery {
            identifiers.formUnion(
                model.descriptor.codex.frames.prefix(1).map(\.staticFallbackResourceID)
            )
            identifiers.formUnion(model.descriptor.codex.crests.prefix(1).map {
                $0.thumbnailResourceID ?? $0.staticFallbackResourceID
            })
        }
        return identifiers
    }

    private static func stateObject(
        launch: ThemeFidelityQualificationLaunch,
        model: ThemeFidelityQualificationRenderModel,
        session: RuneScribeUISession
    ) throws -> [String: Any] {
        guard let snapshot = session.themeSnapshot,
              let provider = snapshot.providers.first(where: {
                  $0.codexID == launch.codexID
              })
        else { throw ThemeFidelityQualificationRouteError.runtimeDidNotSettle }

        var providerState = provider.state.rawValue
        var providerIsOwned = provider.isOwned
        var providerIsSelectable = provider.isSelectable
        var providerIsSelected = provider.isSelected
        var renderedVaultState: Any = NSNull()
        var showsSelectedArtifacts = provider.isSelected
        var focusedArtifactID: Any = NSNull()
        var focusedArtifactState: Any = NSNull()
        var focusedArtifactIsOwned: Any = NSNull()
        var focusedArtifactIsSelectable: Any = NSNull()

        switch launch.surface {
        case .vaultLocked where model.descriptor.criticality != .requiredBase:
            providerState = ThemeProviderState.available.rawValue
            providerIsOwned = false
            providerIsSelectable = false
            providerIsSelected = false
            renderedVaultState = "locked"
            showsSelectedArtifacts = false
        case .vaultEncountered where model.descriptor.criticality != .requiredBase:
            providerState = ThemeProviderState.unavailable.rawValue
            providerIsOwned = false
            providerIsSelectable = false
            providerIsSelected = false
            renderedVaultState = "encountered"
            showsSelectedArtifacts = false
        case .vaultEncountered:
            let artifactID = try focusedVaultArtifactID(surface: launch.surface, model: model)
            providerState = ThemeProviderState.available.rawValue
            providerIsOwned = true
            providerIsSelectable = false
            providerIsSelected = true
            renderedVaultState = "selected"
            showsSelectedArtifacts = false
            focusedArtifactID = artifactID.rawValue
            focusedArtifactState = "encountered"
            focusedArtifactIsOwned = false
            focusedArtifactIsSelectable = false
        case .vaultOwned:
            providerState = ThemeProviderState.available.rawValue
            providerIsOwned = true
            providerIsSelectable = true
            providerIsSelected = false
            renderedVaultState = "owned"
            showsSelectedArtifacts = false
        case .vaultSelected:
            providerState = ThemeProviderState.available.rawValue
            providerIsOwned = true
            providerIsSelectable = false
            providerIsSelected = true
            renderedVaultState = "selected"
            showsSelectedArtifacts = true
        case .vaultProgress:
            renderedVaultState = model.descriptor.criticality == .requiredBase
                ? "owned" : "progress"
            showsSelectedArtifacts = false
        case .vaultLocked:
            renderedVaultState = "selected"
            showsSelectedArtifacts = true
        default:
            break
        }

        let gate = session.progressionSnapshot?.codexGates.first(where: {
            $0.codexID == launch.codexID
        })
        return [
            "schemaVersion": "1.0",
            "surface": launch.surface.rawValue,
            "destination": launch.destination.rawValue,
            "themeID": launch.themeID.rawValue,
            "codexID": launch.codexID.rawValue,
            "activeThemeID": snapshot.effectiveTheme.id.rawValue,
            "effectiveCodexID": snapshot.effectiveCodexID.rawValue,
            "appearance": launch.appearance.rawValue,
            "messageProfile": launch.messageProfile.rawValue,
            "vaultState": jsonValue(launch.vaultState?.rawValue),
            "providerState": providerState,
            "providerIsOwned": providerIsOwned,
            "providerIsSelectable": providerIsSelectable,
            "providerIsSelected": providerIsSelected,
            "renderedVaultState": renderedVaultState,
            "showsSelectedArtifacts": showsSelectedArtifacts,
            "focusedArtifactID": focusedArtifactID,
            "focusedArtifactState": focusedArtifactState,
            "focusedArtifactIsOwned": focusedArtifactIsOwned,
            "focusedArtifactIsSelectable": focusedArtifactIsSelectable,
            "safePreviewStatus": "valid",
            "safePreviewByteCount": model.safePreviewData.count,
            "highContrastBackgroundResourceID": model.descriptor.codex.background
                .highContrastResourceID.rawValue,
            "progressCurrent": jsonValue(gate.map { Int($0.progress.current) }),
            "progressTarget": jsonValue(gate.map { Int($0.progress.target) }),
        ]
    }

    private static func planObject(
        _ plan: ThemeArtifactCompositionPlan
    ) throws -> [String: Any] {
        let sealAnchor = try plan.sealAnchor.map { try encodedJSONObject($0) }
        let selection: [String: Any] = [
            "codexID": plan.selection.codexID.rawValue,
            "scriptID": plan.selection.scriptID.rawValue,
            "relicID": plan.selection.relicID.rawValue,
            "sealID": jsonValue(plan.selection.sealID?.rawValue),
            "frameID": jsonValue(plan.selection.frameID?.rawValue),
            "presentationVersion": plan.selection.presentationVersion,
        ]
        return [
            "schemaVersion": "1.0",
            "selection": selection,
            "inscription": plan.inscription,
            "palette": try encodedJSONObject(plan.palette),
            "layout": try encodedJSONObject(plan.layout),
            "pages": plan.pages.map {
                [
                    "index": $0.index,
                    "count": $0.count,
                    "inscription": $0.inscription,
                ]
            },
            "relicResourceID": plan.relicResourceID.rawValue,
            "sealResourceID": jsonValue(plan.sealResourceID?.rawValue),
            "frameResourceID": jsonValue(plan.frameResourceID?.rawValue),
            "backgroundResourceID": plan.backgroundResourceID.rawValue,
            "glyphSafeRegion": try encodedJSONObject(plan.layout.glyphSafeRegion),
            "sealAnchor": jsonValue(sealAnchor),
            "sealScale": plan.sealScale,
            "fontPostScriptName": plan.fontPostScriptName,
            "fontResourceID": jsonValue(plan.fontResourceID?.rawValue),
            "usesExternalFontOverride": plan.usesExternalFontOverride,
            "colorMode": plan.colorMode.rawValue,
            "accessibilityLabel": plan.accessibilityLabel,
            "provenanceLabel": jsonValue(plan.provenanceLabel),
        ]
    }

    private static func jsonValue<Value>(_ value: Value?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func encodedJSONObject<Value: Encodable>(
        _ value: Value
    ) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let result = String(data: data, encoding: .utf8) else {
            throw ThemeFidelityQualificationRouteError.invalidDescriptor
        }
        return result
    }
}

@MainActor
private struct ThemeFidelityQualificationRenderModel {
    let descriptor: ThemeDescriptor
    let selection: SharePresentationSelection
    let previewText: String
    let shortPlan: ThemeArtifactCompositionPlan
    let longPlan: ThemeArtifactCompositionPlan
    let previewPlan: ThemeArtifactCompositionPlan
    let inscriptionPlan: ThemeArtifactCompositionPlan
    let receivedPlan: ThemeArtifactCompositionPlan
    let highContrastPlan: ThemeArtifactCompositionPlan
    let reduceMotionPlan: ThemeArtifactCompositionPlan
    let presentation: ActiveThemeVisualPresentation
    let masteryTitlePresentation: ProgressionPresentationDTO
    let safePreviewData: Data
    let safePreviewImage: Image
    let safePreviewResourceMetadata: [SharePresentationResourceMetadata]

    func plan(
        for surface: ThemeFidelityQualificationLaunch.Surface
    ) -> ThemeArtifactCompositionPlan {
        switch surface {
        case .composeShort, .largeText:
            shortPlan
        case .composeLong:
            longPlan
        case .highContrast:
            highContrastPlan
        case .reduceMotion:
            reduceMotionPlan
        case .inscriptionPreview:
            inscriptionPlan
        case .receivedCipher:
            receivedPlan
        default:
            previewPlan
        }
    }

    static func load(
        launch: ThemeFidelityQualificationLaunch,
        session: RuneScribeUISession
    ) async throws -> Self {
        guard let descriptor = session.themeSnapshot?.effectiveTheme,
              descriptor.id == launch.themeID,
              descriptor.codex.id == launch.codexID,
              descriptor.codex.defaultRelicID == launch.defaultRelicID,
              session.selectedThemeRelicID == launch.defaultRelicID,
              session.selectedThemeSealID == launch.defaultSealID,
              let presentation = session.activeThemeVisualPresentation,
              presentation.plan.codexID == launch.codexID
        else { throw ThemeFidelityQualificationRouteError.invalidDescriptor }

        let selection = try SharePresentationSelection(
            codexID: descriptor.codex.id,
            scriptID: descriptor.codex.primaryScriptID,
            relicID: launch.defaultRelicID,
            sealID: launch.defaultSealID,
            frameID: nil
        )
        guard let script = descriptor.codex.scripts.first(where: {
            $0.id == descriptor.codex.primaryScriptID
        }) else { throw ThemeFidelityQualificationRouteError.invalidDescriptor }
        let glyphTokens = script.glyphs.prefix(14).map(\.textToken)
        let availableGlyphs = glyphTokens.isEmpty ? ["RUNESCRIBE"] : glyphTokens

        func specimen(rows: Int, columns: Int) -> String {
            (0 ..< rows).map { row in
                (0 ..< columns).map { column in
                    availableGlyphs[(row * columns + column) % availableGlyphs.count]
                }
                .joined(separator: " ")
            }
            .joined(separator: "\n")
        }

        let short = specimen(rows: 2, columns: 5)
        let long = specimen(rows: 6, columns: 9)
        let preview = specimen(rows: 2, columns: 5)
        let inscription = specimen(rows: 4, columns: 10)
        let received = specimen(rows: 1, columns: 10)

        func plan(
            inscription: String = preview,
            mode: ShareArtifactColorMode = .standard,
            reduceMotion: Bool = false
        ) throws -> ThemeArtifactCompositionPlan {
            try ThemeArtifactCompositionPolicy.interactivePlan(
                selection: selection,
                inscription: inscription,
                descriptor: descriptor,
                colorMode: mode,
                reduceMotion: reduceMotion,
                accessibilityLabel: "\(descriptor.codex.displayName.fallbackValue) inscription",
                provenanceLabel: "Runtime-admitted presentation"
            )
        }

        let shortPlan = try plan(inscription: short)
        let longPlan = try plan(inscription: long)
        let previewPlan = try plan()
        let inscriptionPlan = try plan(inscription: inscription)
        let receivedPlan = try plan(inscription: received)
        let highContrastPlan = try plan(mode: .highContrast)
        let reduceMotionPlan = try plan(reduceMotion: true)
        let masteryTitlePresentation = session.progressionSnapshot?.titles.first(where: {
            $0.titleID == launch.masteryTitleID
        })?.presentation ?? launch.masteryTitlePresentation
        try validateImages(
            surface: launch.surface,
            descriptor: descriptor,
            plans: [
                shortPlan,
                longPlan,
                previewPlan,
                inscriptionPlan,
                receivedPlan,
                highContrastPlan,
                reduceMotionPlan,
            ],
            presentation: presentation
        )
        if launch.surface.requiresCodexCardImages {
            guard session.themeSnapshot?.providers.allSatisfy({
                session.themeCodexCardImageReferences[$0.codexID]?.image != nil
            }) == true else {
                throw ThemeFidelityQualificationRouteError.runtimeDidNotSettle
            }
        }

        guard let capturedAt = session.snapshot?.capturedAt else {
            throw ThemeFidelityQualificationRouteError.runtimeDidNotSettle
        }
        let outbound = try await session.makeOutboundSharePresentation(
            inscription: preview,
            accessibilityLabel: "\(descriptor.codex.displayName.fallbackValue) inscription",
            operationID: RuntimeOperationID(
                rawValue: "operation.theme-fidelity.received.\(descriptor.codex.id.rawValue)"
            ),
            capturedAt: capturedAt,
            selection: selection,
            descriptor: descriptor
        )
        guard outbound.metadata.safePreview != nil,
              let safePreviewData = outbound.safePreviewData,
              let safePreviewImage = ValidatedSafePreviewImageDecoder.image(
                  from: safePreviewData
              )
        else { throw ThemeFidelityQualificationRouteError.safePreviewUnavailable }

        return Self(
            descriptor: descriptor,
            selection: selection,
            previewText: preview,
            shortPlan: shortPlan,
            longPlan: longPlan,
            previewPlan: previewPlan,
            inscriptionPlan: inscriptionPlan,
            receivedPlan: receivedPlan,
            highContrastPlan: highContrastPlan,
            reduceMotionPlan: reduceMotionPlan,
            presentation: presentation,
            masteryTitlePresentation: masteryTitlePresentation,
            safePreviewData: safePreviewData,
            safePreviewImage: safePreviewImage,
            safePreviewResourceMetadata: outbound.metadata.resources
        )
    }

    func requiredImage(_ resourceID: ThemeResourceID) -> Image {
        guard let image = presentation.image(for: resourceID) else {
            preconditionFailure("Required Theme resource was not prepared.")
        }
        return image
    }

    private static func validateImages(
        surface: ThemeFidelityQualificationLaunch.Surface,
        descriptor: ThemeDescriptor,
        plans: [ThemeArtifactCompositionPlan],
        presentation: ActiveThemeVisualPresentation
    ) throws {
        var resourceIDs = ThemeFidelityQualificationRoute.requiredSurfaceResourceIDs(
            surface: surface,
            descriptor: descriptor
        )
        if [.relicPicker, .sealPicker, .vaultEncountered, .vaultOwned]
            .contains(surface) {
            resourceIDs.formUnion(
                ThemeFidelityQualificationRoute.catalogResourceIDs(
                    descriptor: descriptor
                )
            )
        }
        if surface == .mastery {
            resourceIDs.formUnion(
                descriptor.codex.frames.prefix(1).map(\.staticFallbackResourceID)
            )
            resourceIDs.formUnion(descriptor.codex.crests.prefix(1).map {
                $0.thumbnailResourceID ?? $0.staticFallbackResourceID
            })
        }
        for plan in plans {
            resourceIDs.formUnion([
                plan.relicResourceID,
                plan.sealResourceID,
                plan.frameResourceID,
                plan.backgroundResourceID,
            ].compactMap { $0 })
        }
        if let missing = resourceIDs.sorted().first(where: {
            presentation.image(for: $0) == nil
        }) {
            throw ThemeFidelityQualificationRouteError.missingResource(missing)
        }
    }
}

private extension ThemeFidelityQualificationLaunch.Surface {
    var requiresCodexCardImages: Bool {
        switch self {
        case .settingsCodexCard,
             .settingsDefaultsPreview,
             .vaultLocked,
             .vaultProgress,
             .vaultSelected:
            return true
        default:
            return false
        }
    }
}

private struct ThemeFidelityQualificationDiagnosticWitness: Identifiable {
    let id: String
    let label: String
    let value: String
}

private struct ThemeFidelityQualificationDiagnosticOverlay: View {
    let witnesses: [ThemeFidelityQualificationDiagnosticWitness]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(witnesses) { witness in
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(witness.label)
                    .accessibilityValue(witness.value)
                    .accessibilityIdentifier(witness.id)
                    .accessibilityAddTraits(.isStaticText)
            }
            Rectangle()
                .fill(Color.black.opacity(0.001))
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Live dynamic type size")
                .accessibilityValue(dynamicTypeValue)
                .accessibilityIdentifier("theme-fidelity.diagnostic.dynamic-type")
                .accessibilityAddTraits(.isStaticText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var dynamicTypeValue: String {
        switch dynamicTypeSize {
        case .xSmall: "xSmall"
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        case .xLarge: "xLarge"
        case .xxLarge: "xxLarge"
        case .xxxLarge: "xxxLarge"
        case .accessibility1: "accessibility1"
        case .accessibility2: "accessibility2"
        case .accessibility3: "accessibility3"
        case .accessibility4: "accessibility4"
        case .accessibility5: "accessibility5"
        default: "unknown"
        }
    }
}

private struct ThemeFidelityQualificationStaticShareView: View {
    let image: Image

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Static share rendered by Rune Scribe")
    }
}
