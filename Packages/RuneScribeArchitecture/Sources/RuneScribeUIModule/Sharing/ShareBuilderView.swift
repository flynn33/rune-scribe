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
    @State private var previewData: Data?
    @State private var previewCompatibility: SharePresentationCompatibilityFlags?
    @State private var previewError: String?
    @State private var actionError: String?
    @State private var isLoadingCatalog = true
    @State private var isRenderingPreview = false
    @State private var isSaving = false
    @State private var isPreparingShare = false
    @State private var previewGeneration = ShareBuilderPreviewGenerationGate()
    @State private var preparedShare: PreparedShareBuilderArtifact?
    @State private var shareLaunchID: UUID?
    @State private var previewTask: Task<Void, Never>?
    @State private var sharePreparationTask: Task<Void, Never>?
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
        .onAppear { isViewActive = true }
        .task { await loadInitialCatalog() }
        .onChange(of: colorSchemeContrast) { _, _ in refreshPreview() }
        .onChange(of: accessibilityReduceMotion) { _, _ in refreshPreview() }
        .onChange(of: accessibilityPreferences) { _, _ in refreshPreview() }
        .onChange(of: keyboardFocus) { _, focus in
            onKeyboardFocusChanged(focus)
        }
        .onDisappear { endLifecycle() }
        .accessibilityIdentifier("share-builder")
        .runtimeViewportFrameProbe("share-builder")
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
                        isEnabled: provider.isSelectable && !isPreparingShare,
                        action: {
                            Task { await selectCodex(provider.codexID) }
                        }
                    ) {
                        if let image = session.themeCodexCardImageReferences[provider.codexID]?.image {
                            AnyView(image.resizable().scaledToFill())
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

                if let image = previewImage {
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
                        Text("Static fallback preview")
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
        .disabled(!catalog.hasChangesFromDefaults || isSaving || isPreparingShare)
        .accessibilityIdentifier("share-builder.reset-defaults")
        .focusable()
        .focused($keyboardFocus, equals: .reset)
    }

    private func saveDefaultsButton(_ catalog: ShareBuilderCatalog) -> some View {
        Button {
            Task { await saveDefaults() }
        } label: {
            Label(isSaving ? "Saving…" : "Save as Defaults", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
        .disabled(!catalog.hasChangesFromDefaults || isSaving || isPreparingShare)
        .accessibilityIdentifier("share-builder.save-defaults")
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
                    isPreparingShare ? "Preparing Share…" : "7. Share",
                    systemImage: isPreparingShare ? "clock" : "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneScribButtonStyle())
            .disabled(catalog == nil || isPreparingShare || preparedShare != nil)
            .accessibilityIdentifier("share-builder.share")
            .focusable()
            .focused($keyboardFocus, equals: .share)
        }
    }

    @ViewBuilder
    private var automaticShareLauncher: some View {
        if let preparedShare, let shareLaunchID {
            switch preparedShare.artifact.reference {
            case .file:
                RuneScribePreparedFileShareLauncher(
                    transfer: preparedShare.transfer,
                    launchID: shareLaunchID,
                    onPresented: markSharePresented,
                    onFinish: handleShareCompletion
                )
            case .opaque:
                RuneScribePreparedTextShareLauncher(
                    transfer: preparedShare.transfer,
                    launchID: shareLaunchID,
                    onPresented: markSharePresented,
                    onFinish: handleShareCompletion
                )
            }
        }
    }

    private func markSharePresented() {
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
                image.resizable().scaledToFill()
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

    private func loadInitialCatalog() async {
        await session.loadThemeCodexCardPreviews()
        do {
            let loaded = try initialCatalog ?? session.makeShareBuilderCatalog()
            catalog = loaded
            artwork = await session.loadShareBuilderArtwork(for: loaded)
            actionError = nil
            isLoadingCatalog = false
            refreshPreview()
        } catch {
            actionError = "A validated share appearance could not be loaded."
            isLoadingCatalog = false
        }
    }

    private func selectCodex(_ codexID: CodexID) async {
        guard catalog?.draft.codexID != codexID else { return }
        isLoadingCatalog = true
        do {
            let loaded = try await session.loadShareBuilderCatalog(codexID: codexID)
            catalog = loaded
            artwork = await session.loadShareBuilderArtwork(for: loaded)
            actionError = nil
            isLoadingCatalog = false
            refreshPreview()
        } catch {
            actionError = "That Codex is not available for sharing."
            isLoadingCatalog = false
        }
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
        guard var updated = catalog else { return }
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
        previewData = nil
        previewCompatibility = nil
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
                    previewData = preview.safePreviewData
                    previewCompatibility = preview.metadata.compatibility
                    previewError = preview.safePreviewData == nil
                        ? "The themed preview is unavailable; the secure package can still be shared."
                        : nil
                } catch is CancellationError {
                    return
                } catch {
                    guard isViewActive, previewGeneration.accepts(generation) else { return }
                    previewData = nil
                    previewCompatibility = nil
                    previewError = "The themed preview is unavailable; the secure package can still be shared."
                }
                guard isViewActive, previewGeneration.accepts(generation) else { return }
                isRenderingPreview = false
                previewTask = nil
            }
        }
    }

    private func saveDefaults() async {
        guard var catalog else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await catalog.persistCurrentDraft { candidate in
                try await session.saveShareBuilderDefaults(candidate)
            }
            self.catalog = catalog
            actionError = nil
        } catch {
            actionError = "Defaults were not saved. Your current share choices are unchanged."
        }
    }

    private func beginSharePreparation() {
        guard sharePreparationTask == nil else { return }
        sharePreparationTask = Task { @MainActor in
            await prepareAndLaunchShare()
            sharePreparationTask = nil
        }
    }

    private func prepareAndLaunchShare() async {
        guard let catalog, preparedShare == nil else { return }
        isPreparingShare = true
        actionError = nil
        do {
            let prepared = try await session.prepareShareBuilderArtifact(
                source: source,
                catalog: catalog,
                colorMode: shareColorMode,
                systemReduceMotion: effectiveReduceMotion
            )
            guard isViewActive, !Task.isCancelled else {
                await prepared.transfer.close()
                await session.releaseShareArtifact(id: prepared.artifact.id)
                isPreparingShare = false
                return
            }
            preparedShare = prepared
            shareLaunchID = UUID()
        } catch is CancellationError {
            // Dismissal cancels preparation; the session releases any artifact it created.
        } catch {
            if isViewActive {
                actionError = "The share package could not be prepared."
            }
        }
        isPreparingShare = false
    }

    private func handleShareCompletion(_ completion: SharePresentationCompletion) {
        guard let prepared = preparedShare else { return }
        preparedShare = nil
        shareLaunchID = nil
        session.setRevealBlocker(.systemShare, active: false)
        Task {
            do {
                let routeResult = try await session.finishShareBuilderArtifact(
                    prepared,
                    completion: completion
                )
                switch ShareBuilderTerminalDisposition(routeResult: routeResult) {
                case .completed:
                    dismiss()
                case .cancelled:
                    actionError = nil
                case .failed:
                    actionError = "The share did not complete. No delivery was recorded."
                }
            } catch {
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
        var invalidatedGeneration = previewGeneration
        invalidatedGeneration.invalidate()
        previewGeneration = invalidatedGeneration
        let inFlightPreparation = sharePreparationTask
        inFlightPreparation?.cancel()
        sharePreparationTask = nil
        session.setRevealBlocker(.systemShare, active: false)
        Task { @MainActor in
            await inFlightPreparation?.value
            if let prepared = preparedShare {
                preparedShare = nil
                shareLaunchID = nil
                await prepared.transfer.close()
                await session.releaseShareArtifact(id: prepared.artifact.id)
            }
            onLifecycleEnded()
        }
    }

    private var previewImage: Image? {
        guard let previewData else { return nil }
        return ValidatedSafePreviewImageDecoder.image(from: previewData)
    }

    private var shareColorMode: ShareArtifactColorMode {
        usesIncreasedContrast ? .highContrast : .standard
    }

    private var previewAccessibilityValue: String {
        if let previewError { return previewError }
        if isRenderingPreview { return "Refreshing" }
        guard let previewCompatibility else { return "Ready" }
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
        if provider.codexID == selected { return .selected }
        switch provider.state {
        case .available: return provider.isOwned ? .owned : .locked
        case .locked: return .locked
        case .unavailable, .incompatible, .invalidResources: return .unavailable
        }
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
