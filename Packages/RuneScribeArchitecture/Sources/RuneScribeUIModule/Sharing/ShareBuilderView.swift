import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

enum ShareBuilderKeyboardFocusTarget: String, CaseIterable, Hashable, Sendable {
    case codex
    case relic
    case seal
    case frame
    case effects
    case reset
    case save
    case share

}

enum ShareBuilderInitialViewport: String, Sendable {
    case controls
    case preview
}

struct ShareBuilderView: View {
    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.runtimeAccessibilityPreferences) private var accessibilityPreferences

    let source: ShareBuilderSource
    private let onLifecycleEnded: () -> Void
    private let initialCatalog: ShareBuilderCatalog?
    private let onKeyboardFocusChanged: (ShareBuilderKeyboardFocusTarget?) -> Void
    private let initialViewport: ShareBuilderInitialViewport?

    init(
        source: ShareBuilderSource,
        onLifecycleEnded: @escaping () -> Void = {},
        initialCatalog: ShareBuilderCatalog? = nil,
        initialViewport: ShareBuilderInitialViewport? = nil,
        onKeyboardFocusChanged: @escaping (ShareBuilderKeyboardFocusTarget?) -> Void = { _ in }
    ) {
        self.source = source
        self.onLifecycleEnded = onLifecycleEnded
        self.initialCatalog = initialCatalog
        self.initialViewport = initialViewport
        self.onKeyboardFocusChanged = onKeyboardFocusChanged
        _catalog = State(initialValue: initialCatalog)
        _isLoadingCatalog = State(initialValue: initialCatalog == nil)
    }

    @State private var catalog: ShareBuilderCatalog?
    @State private var artwork: [ArtifactID: RuntimeThemeImageReference] = [:]
    @State private var renderedPreview: RenderedShareBuilderPreview?
    @State private var renderedPreviewImage: Image?
    @State private var previewError: String?
    @State private var actionError: String?
    @State private var isLoadingCatalog = true
    @State private var isRenderingPreview = false
    @State private var isSaving = false
    @State private var saveGeneration = ShareBuilderPreparationGenerationGate()
    @State private var catalogLoadGeneration = ShareBuilderCatalogLoadGenerationGate()
    @State private var shareTerminalGeneration = ShareBuilderTerminalGenerationGate()
    @State private var isPreparingShare = false
    @State private var sharePreparationGeneration = ShareBuilderPreparationGenerationGate()
    @State private var previewGeneration = ShareBuilderPreviewGenerationGate()
    @State private var themeReconciliationGeneration: UInt64 = 0
    @State private var preparedShare: PreparedShareBuilderArtifact?
    @State private var shareLaunchID: UUID?
    @State private var previewTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var catalogLoadTask: Task<Void, Never>?
    @State private var themeReconciliationTask: Task<Void, Never>?
    @State private var sharePreparationTask: Task<Void, Never>?
    @State private var shareCompletionTask: Task<Void, Never>?
    @State private var isViewActive = false
    @State private var hasEndedLifecycle = false
    @FocusState private var keyboardFocus: ShareBuilderKeyboardFocusTarget?

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                slot: .workspace,
                subtitle: "Share Builder",
                trailingButtons: [
                    RuneHeaderButton(systemImage: "xmark", help: "Close") {
                        dismiss()
                    },
                ]
            )

            if isLoadingCatalog {
                ProgressView("Loading appearance defaults…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let catalog {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
                            codexPanel(catalog)
                                .id(ShareBuilderInitialViewport.controls.rawValue)
                            artifactPanel(catalog)
                            extrasPanel(catalog)
                            previewPanel
                                .id(ShareBuilderInitialViewport.preview.rawValue)
                            securitySummary
                            defaultsActions(catalog)
                            shareAction
                        }
                        .padding(RuneMetrics.pad)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .task(id: initialViewport) {
                        guard let initialViewport else { return }
                        await Task.yield()
                        proxy.scrollTo(initialViewport.rawValue, anchor: .top)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Share Builder Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(actionError ?? "A valid appearance is not available.")
                )
            }
        }
        .runeSheetFrame()
        .runeSemanticPresentationSurface()
        .preferredColorScheme(.dark)
        .background { automaticShareLauncher }
        .onAppear {
            isViewActive = true
            beginInitialCatalogLoad()
        }
        .onChange(of: colorSchemeContrast) { _, _ in
            invalidatePreparedShareForPresentationChange()
            refreshPreview()
        }
        .onChange(of: accessibilityReduceMotion) { _, _ in
            invalidatePreparedShareForPresentationChange()
            refreshPreview()
        }
        .onChange(of: accessibilityPreferences) { _, _ in
            invalidatePreparedShareForPresentationChange()
            refreshPreview()
        }
        .onChange(of: session.themeSnapshot?.revision) { _, revision in
            beginThemeSnapshotReconciliation(for: revision)
        }
        .onChange(of: session.activeThemeVisualPresentation?.revision) { _, _ in
            beginThemeSnapshotReconciliation(for: session.themeSnapshot?.revision)
        }
        .onChange(of: keyboardFocus) { _, focus in
            onKeyboardFocusChanged(focus)
        }
        .onDisappear { endLifecycle() }
        .accessibilityIdentifier("share-builder")
        .runtimeViewportFrameProbe("share-builder")
        .themeCaptureViewportIdentifier(ThemeCaptureIdentifier.screenShareBuilder)
    }

    private func codexPanel(_ catalog: ShareBuilderCatalog) -> some View {
        RunePanel(title: "1. Codex", systemImage: "books.vertical", accent: .runeGold) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose an available Codex for this share. This does not change the cipher or its key.")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)

                ForEach(session.themeSnapshot?.providers ?? [], id: \.codexID) { provider in
                    ThemeCodexCardView(
                        codexID: provider.codexID,
                        displayName: provider.displayName,
                        summary: providerSummary(provider),
                        state: providerState(provider, selected: catalog.draft.codexID),
                        accessibilityLabel: provider.displayName,
                        accessibilityHint: provider.isSelectable
                            ? "Uses this Codex for the current share"
                            : providerSummary(provider),
                        isEnabled: provider.isSelectable && !isShareSelectionLocked,
                        action: {
                            beginCodexSelection(provider.codexID)
                        }
                    ) {
                        if let image = session.themeCodexCardImageReferences[provider.codexID]?.image {
                            AnyView(image.resizable().scaledToFit())
                        } else {
                            AnyView(ThemeVisualPlaceholder(
                                systemImage: "books.vertical",
                                label: "\(provider.displayName) artwork unavailable"
                            ))
                        }
                    }
                    .focusable()
                    .focused($keyboardFocus, equals: .codex)
                }
            }
        }
    }

    private func artifactPanel(_ catalog: ShareBuilderCatalog) -> some View {
        RunePanel(title: "2–3. Artifact", systemImage: "photo.artframe", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                artifactMenu(
                    title: "Relic",
                    selection: catalog.draft.relicID,
                    choices: catalog.relics,
                    includesNone: false
                ) { selectRelic($0) }

                artifactMenu(
                    title: "Seal",
                    selection: catalog.draft.sealID,
                    choices: catalog.seals,
                    includesNone: true
                ) { selectSeal($0) }
            }
        }
    }

    private func extrasPanel(_ catalog: ShareBuilderCatalog) -> some View {
        RunePanel(title: "4. Extras", systemImage: "sparkles", accent: .runeGold) {
            VStack(alignment: .leading, spacing: 14) {
                artifactMenu(
                    title: "Frame",
                    selection: catalog.draft.frameID,
                    choices: catalog.frames,
                    includesNone: true
                ) { selectFrame($0) }

                Picker("Effects", selection: Binding(
                    get: { catalog.draft.effects },
                    set: { selectEffects($0) }
                )) {
                    ForEach(RuntimeEffectsPreference.allCases, id: \.self) { preference in
                        Text(preference.rawValue.capitalized)
                            .tag(preference)
                            .accessibilityIdentifier(
                                "share-builder.effects.option.\(preference.rawValue)"
                            )
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityValue(
                    "\(catalog.draft.effects.rawValue.capitalized), selected, available"
                )
                .accessibilityHint("Controls optional decorative motion only")
                .accessibilityIdentifier("share-builder.effects")
                .disabled(isShareSelectionLocked)
                .focusable()
                .focused($keyboardFocus, equals: .effects)

                Text(effectsDetail(catalog.draft.effects))
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
            }
        }
    }

    private var previewPanel: some View {
        RunePanel(title: "5. Live Preview", systemImage: "rectangle.inset.filled", accent: .runeBlue) {
            ZStack {
                RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                    .fill(Color.runeParchment)
                    .aspectRatio(4 / 3, contentMode: .fit)

                if let image = renderedPreviewImage {
                    image
                        .resizable()
                        .scaledToFit()
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .clipShape(RoundedRectangle(
                            cornerRadius: RuneMetrics.corner,
                            style: .continuous
                        ))
                } else if isRenderingPreview {
                    ProgressView("Refreshing preview…")
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("Preview unavailable")
                            .font(.headline)
                        if let previewError {
                            Text(previewError)
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .foregroundColor(.runeSilver)
                    .padding()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Four by three preview of the current share appearance")
            .accessibilityValue(previewAccessibilityValue)
            .accessibilityIdentifier("share-builder.preview")
            .themeCaptureIdentifier(catalog.map {
                ThemeCaptureIdentifier.shareBuilderPreview(codexID: $0.draft.codexID)
            })
        }
    }

    private var securitySummary: some View {
        RunePanel(title: "6. Security Summary", systemImage: "lock.shield", accent: .runeGold) {
            Label(source.purpose.securitySummary, systemImage: "lock.shield.fill")
                .font(.body.weight(.semibold))
                .foregroundColor(.runeTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Security summary")
                .accessibilityValue(source.purpose.securitySummary)
                .accessibilityIdentifier(source.purpose.securityAccessibilityIdentifier)
        }
    }

    private func defaultsActions(_ catalog: ShareBuilderCatalog) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                resetButton(catalog)
                saveDefaultsButton(catalog)
            }
            VStack(spacing: 8) {
                resetButton(catalog)
                saveDefaultsButton(catalog)
            }
        }
    }

    private func resetButton(_ catalog: ShareBuilderCatalog) -> some View {
        Button {
            guard var updated = self.catalog else { return }
            updated.resetToDefaults()
            self.catalog = updated
            refreshPreview()
        } label: {
            Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
        .disabled(!catalog.hasChangesFromDefaults || isSaving || isShareSelectionLocked)
        .accessibilityIdentifier("share-builder.reset-defaults")
        .runtimeViewportFrameProbe("share-builder.reset-defaults")
        .focusable()
        .focused($keyboardFocus, equals: .reset)
    }

    private func saveDefaultsButton(_ catalog: ShareBuilderCatalog) -> some View {
        Button {
            beginSaveDefaults()
        } label: {
            Label(isSaving ? "Saving…" : "Save as Defaults", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
        .disabled(!catalog.hasChangesFromDefaults || isSaving || isShareSelectionLocked)
        .accessibilityIdentifier("share-builder.save-defaults")
        .runtimeViewportFrameProbe("share-builder.save-defaults")
        .focusable()
        .focused($keyboardFocus, equals: .save)
    }

    private var shareAction: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(.runeWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                beginSharePreparation()
            } label: {
                Label(
                    shareActionTitle,
                    systemImage: isShareSelectionLocked
                        ? "clock" : "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneScribButtonStyle())
            .disabled(!isShareReady || isShareSelectionLocked)
            .accessibilityIdentifier("share-builder.share")
            .runtimeViewportFrameProbe("share-builder.share")
            .focusable()
            .focused($keyboardFocus, equals: .share)
        }
    }

    @ViewBuilder
    private var automaticShareLauncher: some View {
        if let preparedShare,
           let shareLaunchID,
           let catalog,
           isPreparedShareAuthorized(preparedShare, catalog: catalog)
        {
            switch preparedShare.artifact.reference {
            case .file:
                RuneScribePreparedFileShareLauncher(
                    transfer: preparedShare.transfer,
                    launchID: shareLaunchID,
                    onPresented: {
                        markSharePresented(
                            artifactID: preparedShare.artifact.id,
                            launchID: shareLaunchID
                        )
                    },
                    onFinish: {
                        handleShareCompletion(
                            $0,
                            artifactID: preparedShare.artifact.id,
                            launchID: shareLaunchID
                        )
                    }
                )
            case .opaque:
                RuneScribePreparedTextShareLauncher(
                    transfer: preparedShare.transfer,
                    launchID: shareLaunchID,
                    onPresented: {
                        markSharePresented(
                            artifactID: preparedShare.artifact.id,
                            launchID: shareLaunchID
                        )
                    },
                    onFinish: {
                        handleShareCompletion(
                            $0,
                            artifactID: preparedShare.artifact.id,
                            launchID: shareLaunchID
                        )
                    }
                )
            }
        }
    }

    private func markSharePresented(
        artifactID: ShareArtifactID,
        launchID: UUID
    ) {
        guard preparedShare?.artifact.id == artifactID,
              shareLaunchID == launchID
        else { return }
        session.setRevealBlocker(.systemShare, active: true)
    }

    private func artifactMenu(
        title: String,
        selection: ArtifactID?,
        choices: [ShareBuilderArtifactChoice],
        includesNone: Bool,
        select: @escaping (ArtifactID?) -> Void
    ) -> some View {
        let selectedChoice = choices.first(where: { $0.id == selection })
        let controlID = title.lowercased()
        let focusTarget = ShareBuilderKeyboardFocusTarget(rawValue: controlID) ?? .relic
        return Menu {
            if includesNone {
                Button {
                    select(nil)
                } label: {
                    if selection == nil {
                        Label("None", systemImage: "checkmark")
                    } else {
                        Text("None")
                    }
                }
                .accessibilityLabel("None")
                .accessibilityValue(
                    selection == nil
                        ? "Selected, available"
                        : "Not selected, available"
                )
                .accessibilityIdentifier("share-builder.\(controlID).option.none")
            }
            ForEach(choices) { choice in
                Button {
                    select(choice.id)
                } label: {
                    Label(
                        choice.displayName + choiceStateSuffix(choice),
                        systemImage: selection == choice.id
                            ? "checkmark"
                            : choice.access == .owned ? "circle" : "lock"
                    )
                }
                .disabled(!choice.isSelectable)
                .accessibilityLabel(
                    "\(choice.displayName), "
                        + choice.accessibilityValue(isSelected: selection == choice.id)
                )
                .accessibilityIdentifier(
                    "share-builder.\(controlID).option.\(choice.id.rawValue)"
                )
            }
        } label: {
            HStack(spacing: 12) {
                artifactThumbnail(selection, title: title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.runeSilver)
                    Text(selectedChoice?.displayName ?? "None")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.runeTextPrimary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundColor(.runeSilver)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .disabled(isShareSelectionLocked)
        .accessibilityLabel("\(title): \(selectedChoice?.displayName ?? "None")")
        .accessibilityValue(
            selectedChoice?.accessibilityValue(isSelected: true)
                ?? (selection == nil ? "Selected, available" : "Selected item unavailable")
        )
        .accessibilityIdentifier("share-builder.\(controlID)")
        .focusable()
        .focused($keyboardFocus, equals: focusTarget)
    }

    private func artifactThumbnail(_ artifactID: ArtifactID?, title: String) -> some View {
        Group {
            if let artifactID, let image = artwork[artifactID]?.image {
                image.resizable().scaledToFit()
            } else {
                ThemeVisualPlaceholder(
                    systemImage: artifactID == nil ? "nosign" : "photo",
                    label: artifactID == nil ? "No \(title.lowercased())" : "Artwork unavailable"
                )
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func beginInitialCatalogLoad() {
        guard let themeRevision = session.themeSnapshot?.revision else {
            actionError = "A validated share appearance could not be loaded."
            isLoadingCatalog = false
            return
        }
        var updatedGeneration = catalogLoadGeneration
        let token = updatedGeneration.begin(themeRevision: themeRevision)
        catalogLoadGeneration = updatedGeneration
        catalogLoadTask?.cancel()
        isLoadingCatalog = true
        catalogLoadTask = Task { @MainActor in
            await loadInitialCatalog(token: token)
            guard acceptsCatalogLoad(token) else { return }
            catalogLoadTask = nil
        }
    }

    private func loadInitialCatalog(
        token: ShareBuilderCatalogLoadToken
    ) async {
        do {
            await session.loadThemeCodexCardPreviews()
            try Task.checkCancellation()
            guard acceptsCatalogLoad(token) else { return }
            let loaded: ShareBuilderCatalog
            if let initialCatalog,
               let initialAuthority = try? session.shareBuilderThemeAuthorityRevision(
                   for: initialCatalog
               ),
               initialAuthority.coordinatorRevision == token.themeRevision
            {
                loaded = initialCatalog
            } else {
                loaded = try session.makeShareBuilderCatalog()
            }
            let loadedAuthority = try session.shareBuilderThemeAuthorityRevision(
                for: loaded
            )
            guard loadedAuthority.coordinatorRevision == token.themeRevision,
                  acceptsCatalogLoad(token)
            else { return }
            let loadedArtwork = await session.loadShareBuilderArtwork(for: loaded)
            try Task.checkCancellation()
            guard acceptsCatalogLoad(token),
                  (try? session.shareBuilderThemeAuthorityRevision(for: loaded))
                    == loadedAuthority
            else { return }
            catalog = loaded
            artwork = loadedArtwork
            actionError = nil
            isLoadingCatalog = false
            refreshPreview()
        } catch is CancellationError {
            return
        } catch {
            guard acceptsCatalogLoad(token) else { return }
            actionError = "A validated share appearance could not be loaded."
            isLoadingCatalog = false
        }
    }

    private func beginCodexSelection(_ codexID: CodexID) {
        guard !isShareSelectionLocked,
              catalog?.draft.codexID != codexID,
              let themeRevision = session.themeSnapshot?.revision
        else { return }
        var updatedGeneration = catalogLoadGeneration
        let token = updatedGeneration.begin(themeRevision: themeRevision)
        catalogLoadGeneration = updatedGeneration
        catalogLoadTask?.cancel()
        isLoadingCatalog = true
        catalogLoadTask = Task { @MainActor in
            await selectCodex(codexID, token: token)
            guard catalogLoadGeneration.accepts(
                token,
                currentThemeRevision: session.themeSnapshot?.revision
            ) else { return }
            catalogLoadTask = nil
        }
    }

    private func selectCodex(
        _ codexID: CodexID,
        token: ShareBuilderCatalogLoadToken
    ) async {
        do {
            let loaded = try await session.loadShareBuilderCatalog(codexID: codexID)
            try Task.checkCancellation()
            guard acceptsCatalogLoad(token) else { return }
            let loadedArtwork = await session.loadShareBuilderArtwork(for: loaded)
            try Task.checkCancellation()
            guard acceptsCatalogLoad(token) else { return }
            catalog = loaded
            artwork = loadedArtwork
            actionError = nil
            isLoadingCatalog = false
            refreshPreview()
        } catch is CancellationError {
            return
        } catch {
            guard acceptsCatalogLoad(token) else { return }
            actionError = "That Codex is not available for sharing."
            isLoadingCatalog = false
        }
    }

    private func acceptsCatalogLoad(_ token: ShareBuilderCatalogLoadToken) -> Bool {
        isViewActive
            && catalogLoadGeneration.accepts(
                token,
                currentThemeRevision: session.themeSnapshot?.revision
            )
    }

    private func beginThemeSnapshotReconciliation(for revision: UInt64?) {
        guard isViewActive else { return }
        invalidateCatalogLoad()
        invalidateSaveDefaults()
        invalidatePreparedShareForPresentationChange()
        themeReconciliationGeneration &+= 1
        let generation = themeReconciliationGeneration
        themeReconciliationTask?.cancel()
        themeReconciliationTask = nil
        previewTask?.cancel()
        previewTask = nil
        var invalidatedGeneration = previewGeneration
        invalidatedGeneration.invalidate()
        previewGeneration = invalidatedGeneration
        renderedPreview = nil
        renderedPreviewImage = nil
        previewError = nil
        isRenderingPreview = false
        guard let revision else {
            catalog = nil
            artwork = [:]
            actionError = "The selected appearance is no longer available for sharing."
            isLoadingCatalog = false
            themeReconciliationTask = nil
            return
        }
        guard catalog != nil else {
            beginInitialCatalogLoad()
            return
        }
        isLoadingCatalog = true
        themeReconciliationTask = Task { @MainActor in
            await reconcileThemeSnapshotChange(
                expectedRevision: revision,
                generation: generation
            )
            guard themeReconciliationGeneration == generation,
                  session.themeSnapshot?.revision == revision
            else { return }
            themeReconciliationTask = nil
        }
    }

    private func reconcileThemeSnapshotChange(
        expectedRevision: UInt64,
        generation: UInt64
    ) async {
        guard !Task.isCancelled,
              themeReconciliationGeneration == generation,
              session.themeSnapshot?.revision == expectedRevision,
              let previousCatalog = catalog
        else { return }
        let refreshed: ShareBuilderCatalog?
        if let sameCodex = try? await session.loadShareBuilderCatalog(
            codexID: previousCatalog.draft.codexID
        ) {
            refreshed = sameCodex
        } else {
            refreshed = try? session.makeShareBuilderCatalog()
        }
        guard !Task.isCancelled,
              themeReconciliationGeneration == generation,
              session.themeSnapshot?.revision == expectedRevision
        else { return }
        guard let refreshed else {
            catalog = nil
            artwork = [:]
            actionError = "The selected appearance is no longer available for sharing."
            isLoadingCatalog = false
            return
        }
        let refreshedArtwork = await session.loadShareBuilderArtwork(for: refreshed)
        guard !Task.isCancelled,
              themeReconciliationGeneration == generation,
              session.themeSnapshot?.revision == expectedRevision
        else { return }
        catalog = refreshed
        artwork = refreshedArtwork
        actionError = refreshed.draft.codexID == previousCatalog.draft.codexID
            ? nil
            : "The selected appearance became unavailable. The available fallback is shown."
        isLoadingCatalog = false
        refreshPreview()
    }

    private func selectRelic(_ artifactID: ArtifactID?) {
        guard let artifactID else { return }
        mutateCatalog { try $0.selectRelic(artifactID) }
    }

    private func selectSeal(_ artifactID: ArtifactID?) {
        mutateCatalog { try $0.selectSeal(artifactID) }
    }

    private func selectFrame(_ artifactID: ArtifactID?) {
        mutateCatalog { try $0.selectFrame(artifactID) }
    }

    private func selectEffects(_ effects: RuntimeEffectsPreference) {
        mutateCatalog { $0.selectEffects(effects) }
    }

    private func mutateCatalog(
        _ mutation: (inout ShareBuilderCatalog) throws -> Void
    ) {
        guard !isShareSelectionLocked, var updated = catalog else { return }
        do {
            try mutation(&updated)
            _ = try updated.validatedSelection()
            catalog = updated
            actionError = nil
            refreshPreview()
        } catch {
            actionError = "That appearance choice is locked, unavailable, or incompatible."
        }
    }

    private func refreshPreview() {
        guard let catalog else { return }
        var updatedGeneration = previewGeneration
        let generation = updatedGeneration.begin()
        previewGeneration = updatedGeneration
        renderedPreview = nil
        renderedPreviewImage = nil
        previewError = nil
        isRenderingPreview = true
        replaceShareBuilderPreviewTask(&previewTask) {
            Task { @MainActor in
                do {
                    let preview = try await session.renderShareBuilderPreview(
                        source: source,
                        catalog: catalog,
                        colorMode: shareColorMode,
                        systemReduceMotion: effectiveReduceMotion
                    )
                    try Task.checkCancellation()
                    guard isViewActive, previewGeneration.accepts(generation) else { return }
                    guard let previewData = preview.safePreviewData,
                          let previewImage = ValidatedSafePreviewImageDecoder.image(
                              from: previewData
                          )
                    else { throw ShareArtifactRenderError.renderingFailed }
                    renderedPreview = preview
                    renderedPreviewImage = previewImage
                    previewError = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard isViewActive, previewGeneration.accepts(generation) else { return }
                    renderedPreview = nil
                    renderedPreviewImage = nil
                    previewError = "The themed preview is unavailable. Sharing is disabled until it can be rendered."
                }
                guard isViewActive, previewGeneration.accepts(generation) else { return }
                isRenderingPreview = false
                previewTask = nil
            }
        }
    }

    private func beginSaveDefaults() {
        guard saveTask == nil,
              !isSaving,
              !isShareSelectionLocked,
              catalog?.hasChangesFromDefaults == true
        else { return }
        var updatedGeneration = saveGeneration
        let generation = updatedGeneration.begin()
        saveGeneration = updatedGeneration
        isSaving = true
        saveTask = Task { @MainActor in
            await saveDefaults(generation: generation)
            guard saveGeneration.accepts(generation) else { return }
            saveTask = nil
            isSaving = false
        }
    }

    private func saveDefaults(generation: UInt64) async {
        guard var catalog,
              saveGeneration.accepts(generation)
        else { return }
        do {
            try await catalog.persistCurrentDraft { candidate in
                try await session.saveShareBuilderDefaults(candidate)
            }
            try Task.checkCancellation()
            guard isViewActive,
                  saveGeneration.accepts(generation),
                  self.catalog?.draft == catalog.draft,
                  self.catalog?.descriptor.id == catalog.descriptor.id
            else { return }
            self.catalog = catalog
            actionError = nil
        } catch is CancellationError {
            return
        } catch {
            guard isViewActive, saveGeneration.accepts(generation) else { return }
            actionError = "Defaults were not saved. Your current share choices are unchanged."
        }
    }

    private func beginSharePreparation() {
        guard sharePreparationTask == nil,
              !isShareSelectionLocked
        else { return }
        var updatedGeneration = sharePreparationGeneration
        let generation = updatedGeneration.begin()
        sharePreparationGeneration = updatedGeneration
        isPreparingShare = true
        sharePreparationTask = Task { @MainActor in
            await prepareAndLaunchShare(generation: generation)
            guard sharePreparationGeneration.accepts(generation) else { return }
            sharePreparationTask = nil
            isPreparingShare = false
        }
    }

    private func prepareAndLaunchShare(generation: UInt64) async {
        guard let catalog,
              let renderedPreview,
              isShareReady,
              preparedShare == nil,
              sharePreparationGeneration.accepts(generation)
        else {
            if isViewActive, sharePreparationGeneration.accepts(generation) {
                actionError = "Wait for the current preview before sharing."
            }
            return
        }
        actionError = nil
        do {
            let prepared = try await session.prepareShareBuilderArtifact(
                source: source,
                catalog: catalog,
                renderedPreview: renderedPreview,
                colorMode: shareColorMode,
                systemReduceMotion: effectiveReduceMotion
            )
            guard isViewActive,
                  !Task.isCancelled,
                  sharePreparationGeneration.accepts(generation),
                  isPreparedShareAuthorized(prepared, catalog: catalog)
            else {
                await prepared.transfer.close()
                await session.releaseShareArtifact(id: prepared.artifact.id)
                return
            }
            preparedShare = prepared
            shareLaunchID = UUID()
        } catch is CancellationError {
            // Dismissal cancels preparation; the session releases any artifact it created.
        } catch {
            if isViewActive, sharePreparationGeneration.accepts(generation) {
                actionError = "The share package could not be prepared."
            }
        }
    }

    private func handleShareCompletion(
        _ completion: SharePresentationCompletion,
        artifactID: ShareArtifactID,
        launchID: UUID
    ) {
        guard let prepared = preparedShare,
              prepared.artifact.id == artifactID,
              shareLaunchID == launchID
        else { return }
        preparedShare = nil
        shareLaunchID = nil
        session.setRevealBlocker(.systemShare, active: false)
        var updatedTerminalGeneration = shareTerminalGeneration
        guard let generation = updatedTerminalGeneration.begin() else { return }
        shareTerminalGeneration = updatedTerminalGeneration
        shareCompletionTask = Task { @MainActor in
            let disposition: ShareBuilderTerminalDisposition
            do {
                let routeResult = try await session.finishShareBuilderArtifact(
                    prepared,
                    completion: completion
                )
                disposition = ShareBuilderTerminalDisposition(routeResult: routeResult)
            } catch {
                disposition = .failed
            }
            var completedTerminalGeneration = shareTerminalGeneration
            guard completedTerminalGeneration.complete(generation) else { return }
            shareTerminalGeneration = completedTerminalGeneration
            shareCompletionTask = nil
            guard isViewActive else { return }
            switch disposition {
            case .completed:
                dismiss()
            case .cancelled:
                actionError = nil
            case .failed:
                actionError = "The share did not complete. No delivery was recorded."
            }
        }
    }

    private func endLifecycle() {
        guard !hasEndedLifecycle else { return }
        hasEndedLifecycle = true
        isViewActive = false
        previewTask?.cancel()
        previewTask = nil
        themeReconciliationTask?.cancel()
        themeReconciliationTask = nil
        renderedPreview = nil
        renderedPreviewImage = nil
        var invalidatedGeneration = previewGeneration
        invalidatedGeneration.invalidate()
        previewGeneration = invalidatedGeneration
        let inFlightSave = saveTask
        var invalidatedSaveGeneration = saveGeneration
        invalidatedSaveGeneration.invalidate()
        saveGeneration = invalidatedSaveGeneration
        inFlightSave?.cancel()
        saveTask = nil
        isSaving = false
        let inFlightCatalogLoad = catalogLoadTask
        var invalidatedCatalogLoadGeneration = catalogLoadGeneration
        invalidatedCatalogLoadGeneration.invalidate()
        catalogLoadGeneration = invalidatedCatalogLoadGeneration
        inFlightCatalogLoad?.cancel()
        catalogLoadTask = nil
        let inFlightPreparation = sharePreparationTask
        var invalidatedShareGeneration = sharePreparationGeneration
        invalidatedShareGeneration.invalidate()
        sharePreparationGeneration = invalidatedShareGeneration
        inFlightPreparation?.cancel()
        sharePreparationTask = nil
        isPreparingShare = false
        let terminalCompletion = shareCompletionTask
        var invalidatedTerminalGeneration = shareTerminalGeneration
        invalidatedTerminalGeneration.invalidate()
        shareTerminalGeneration = invalidatedTerminalGeneration
        shareCompletionTask = nil
        session.setRevealBlocker(.systemShare, active: false)
        Task { @MainActor in
            await inFlightCatalogLoad?.value
            await inFlightPreparation?.value
            await inFlightSave?.value
            await terminalCompletion?.value
            if let prepared = preparedShare {
                preparedShare = nil
                shareLaunchID = nil
                await prepared.transfer.close()
                await session.releaseShareArtifact(id: prepared.artifact.id)
            }
            onLifecycleEnded()
        }
    }

    private var isShareReady: Bool {
        guard let catalog,
              let renderedPreview,
              renderedPreviewImage != nil,
              let themeRevision = try? session.shareBuilderThemeAuthorityRevision(
                  for: catalog
              )
        else { return false }
        return renderedPreview.matches(
            source: source,
            catalog: catalog,
            themeRevision: themeRevision,
            colorMode: shareColorMode,
            systemReduceMotion: effectiveReduceMotion
        )
    }

    private var isShareSelectionLocked: Bool {
        isSaving
            || isPreparingShare
            || preparedShare != nil
            || shareTerminalGeneration.isActive
    }

    private var shareActionTitle: String {
        if isSaving { return "Saving Defaults…" }
        if isPreparingShare { return "Preparing Share…" }
        if shareTerminalGeneration.isActive { return "Finishing Share…" }
        return "7. Share"
    }

    private func isPreparedShareAuthorized(
        _ prepared: PreparedShareBuilderArtifact,
        catalog: ShareBuilderCatalog
    ) -> Bool {
        ShareBuilderPreparedPresentationPolicy.isAuthorized(
            capturedThemeRevision: prepared.themeRevision,
            capturedColorMode: prepared.colorMode,
            capturedSystemReduceMotion: prepared.systemReduceMotion,
            currentThemeRevision: try? session.shareBuilderThemeAuthorityRevision(
                for: catalog
            ),
            currentColorMode: shareColorMode,
            currentSystemReduceMotion: effectiveReduceMotion
        )
    }

    private func invalidatePreparedShareForPresentationChange() {
        var invalidatedShareGeneration = sharePreparationGeneration
        invalidatedShareGeneration.invalidate()
        sharePreparationGeneration = invalidatedShareGeneration
        let inFlightPreparation = sharePreparationTask
        inFlightPreparation?.cancel()
        sharePreparationTask = nil
        isPreparingShare = false

        let prepared = preparedShare
        preparedShare = nil
        shareLaunchID = nil
        session.setRevealBlocker(.systemShare, active: false)
        Task { @MainActor in
            await inFlightPreparation?.value
            if let prepared {
                await prepared.transfer.close()
                await session.releaseShareArtifact(id: prepared.artifact.id)
            }
        }
    }

    private func invalidateSaveDefaults() {
        var invalidatedGeneration = saveGeneration
        invalidatedGeneration.invalidate()
        saveGeneration = invalidatedGeneration
        saveTask?.cancel()
        saveTask = nil
        isSaving = false
    }

    private func invalidateCatalogLoad() {
        var invalidatedGeneration = catalogLoadGeneration
        invalidatedGeneration.invalidate()
        catalogLoadGeneration = invalidatedGeneration
        catalogLoadTask?.cancel()
        catalogLoadTask = nil
    }

    private var shareColorMode: ShareArtifactColorMode {
        usesIncreasedContrast ? .highContrast : .standard
    }

    private var previewAccessibilityValue: String {
        if let previewError { return previewError }
        if isRenderingPreview { return "Refreshing" }
        guard let previewCompatibility = renderedPreview?.metadata.compatibility else {
            return "Unavailable"
        }
        var values = ["Ready"]
        values.append(
            previewCompatibility.contains(.highContrastPreviewAvailable)
                ? "High contrast output verified"
                : "Standard contrast output verified"
        )
        values.append(effectiveReduceMotion ? "Reduced motion" : "Full motion")
        return values.joined(separator: ", ")
    }

    private var effectiveReduceMotion: Bool {
        accessibilityReduceMotion || accessibilityPreferences.forcesReduceMotion
    }

    private var usesIncreasedContrast: Bool {
        colorSchemeContrast == .increased
            || accessibilityPreferences.forcesIncreasedContrast
    }

    private func providerSummary(_ provider: ThemeProviderSummaryDTO) -> String {
        switch provider.state {
        case .available: provider.isOwned ? "Available" : "Locked"
        case .locked: "Locked"
        case .unavailable: "Temporarily unavailable"
        case .incompatible: "Requires a newer app or system"
        case .invalidResources: "Required resources failed validation"
        }
    }

    private func providerState(
        _ provider: ThemeProviderSummaryDTO,
        selected: CodexID
    ) -> ThemeVisualContentState {
        ShareBuilderProviderPresentationPolicy.state(
            for: provider,
            selectedCodexID: selected
        )
    }

    private func choiceStateSuffix(_ choice: ShareBuilderArtifactChoice) -> String {
        if !choice.isCompatible { return " — incompatible" }
        switch choice.access {
        case .owned: return ""
        case .encountered: return " — encountered"
        case .locked: return " — locked"
        case .unavailable: return " — unavailable"
        }
    }

    private func effectsDetail(_ preference: RuntimeEffectsPreference) -> String {
        if effectiveReduceMotion && preference == .full {
            return "Full is saved; Reduce Motion limits the effective preview to Reduced. No additional effect is supplied by this Codex."
        }
        return "Effective behavior: \(preference.rawValue.capitalized). No additional effect is supplied by this Codex."
    }
}
