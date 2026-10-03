// RuneScrib/Views/ContentView.swift

import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

struct MessageArtifactCompletionGate: Equatable, Sendable {
    private(set) var inFlightArtifactID: ShareArtifactID?

    mutating func begin(for artifactID: ShareArtifactID) -> Bool {
        guard inFlightArtifactID == nil else { return false }
        inFlightArtifactID = artifactID
        return true
    }

    mutating func finish(for artifactID: ShareArtifactID) {
        guard inFlightArtifactID == artifactID else { return }
        inFlightArtifactID = nil
    }

    func isCompleting(_ artifactID: ShareArtifactID) -> Bool {
        inFlightArtifactID == artifactID
    }
}

private struct MessageSharePreparation: Equatable, Sendable {
    let runes: String
    let senderName: String
    let cipherID: UUID
    let shareHandle: EncodedMessageHandle
}

struct ContentViewSettledArtifactSeed {
    let composition: ThemeArtifactCompositionPlan
    let presentation: ActiveThemeVisualPresentation

    init(
        composition: ThemeArtifactCompositionPlan,
        presentation: ActiveThemeVisualPresentation
    ) {
        self.composition = composition
        self.presentation = presentation
    }
}

enum ContentViewInitialViewport: String, Sendable {
    case resultActions = "workspace.result-actions"
}

@MainActor
private struct ContentViewInscriptionPreviewSource: Identifiable {
    let id = UUID()
    let descriptor: ThemeDescriptor
    let plan: ThemeArtifactCompositionPlan
    let presentation: ActiveThemeVisualPresentation
    let selectedLayout: ThemeInscriptionLayoutChoice

    init?(
        descriptor: ThemeDescriptor,
        plan: ThemeArtifactCompositionPlan,
        presentation: ActiveThemeVisualPresentation
    ) {
        let optionalImageIDs: [ThemeResourceID?] = [
            plan.relicResourceID,
            plan.sealResourceID,
            plan.frameResourceID,
            plan.backgroundResourceID,
        ]
        let requiredImageIDs = optionalImageIDs.compactMap { $0 }
        guard descriptor.codex.id == plan.selection.codexID,
              presentation.plan.codexID == plan.selection.codexID,
              presentation.revision == presentation.plan.revision,
              requiredImageIDs.allSatisfy({ presentation.image(for: $0) != nil })
        else { return nil }
        self.descriptor = descriptor
        self.plan = plan
        self.presentation = presentation
        selectedLayout = ThemeInscriptionLayoutChoice.recommended(for: plan)
    }
}

@MainActor
private struct ActiveThemeCodexCatalogSheet: View {
    @ObservedObject var session: RuneScribeUISession
    @Environment(\.dismiss) private var dismiss

    let initialTab: CodexCatalogTab

    var body: some View {
        Group {
            if let descriptor = session.themeSnapshot?.effectiveTheme,
               let presentation = session.activeThemeVisualPresentation,
               descriptor.codex.id == presentation.plan.codexID,
               descriptor.codex.id == session.themeSnapshot?.effectiveCodexID {
                CodexCatalogRoot(
                    descriptor: descriptor,
                    presentation: presentation,
                    initialTab: initialTab,
                    runtimeState: session.activeThemeArtifactCatalogRuntimeState,
                    onDismiss: { dismiss() },
                    onSelectRelic: { select($0, kind: .relic) },
                    onSelectSeal: { select($0, kind: .seal) },
                    onClearSeal: clearSeal,
                    onPrimaryAction: { dismiss() }
                )
            } else {
                ProgressView("Loading Codex…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .runeSemanticPresentationSurface()
        .preferredColorScheme(.dark)
        .task { await session.loadActiveThemeCatalogVisuals() }
    }

    private func select(_ artifactID: ArtifactID, kind: ThemeArtifactSelectionKind) {
        dismiss()
        Task { await session.selectThemeArtifact(artifactID, kind: kind) }
    }

    private func clearSeal() {
        dismiss()
        Task { await session.clearThemeSeal() }
    }
}

struct ContentView: View {

    // MARK: - Environment

    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.runtimeAccessibilityPreferences) private var accessibilityPreferences

    // MARK: - Types

    enum Mode: String, CaseIterable, Identifiable {
        case encode = "Encode"
        case decode = "Decode"
        var id: String { rawValue }
    }

    /// Drives the in-place transformation: the text box edits, then plays the
    /// inscription animation, then rests on the result — all in the same frame,
    /// which never changes size.
    private enum BoxPhase { case editing, transforming, result }

    private enum MessageShareDestination {
        case systemShare
        #if os(iOS)
        case messages
        #endif
    }

    private enum ArtifactBrowser: String, Identifiable {
        case relic
        case seal
        case frame

        var id: String { rawValue }

        var title: String { rawValue.capitalized }

        var selectionKind: ThemeArtifactSelectionKind {
            switch self {
            case .relic: .relic
            case .seal: .seal
            case .frame: .frame
            }
        }

        var visualKind: ThemeVisualArtifactKind {
            switch self {
            case .relic: .relic
            case .seal: .seal
            case .frame: .frame
            }
        }

        var captureKind: ThemeCaptureIdentifier.PickerKind? {
            switch self {
            case .relic: .relic
            case .seal: .seal
            case .frame: nil
            }
        }
    }

    // MARK: - State

    @State private var mode: Mode = .encode
    @State private var inputText: String = ""
    @FocusState private var inputIsFocused: Bool
    @State private var boxPhase: BoxPhase = .editing
    @State private var sourceSnapshot: String = ""
    @State private var targetSnapshot: String = ""
    @State private var transformStart: Date = .distantPast
    @State private var transformDirection: RuneInscriptionText.Direction = .encode
    @State private var actionTask: Task<Void, Never>?
    @State private var actionGeneration: UInt64 = 0
    @State private var settleTask: Task<Void, Never>?
    @State private var copyConfirmed = false
    @State private var showLibrary: Bool = false
    @State private var showSettings: Bool = false
    @State private var showVaultProgress: Bool = false
    @State private var artifactBrowser: ArtifactBrowser?
    @State private var resultArtifactComposition: ThemeArtifactCompositionPlan?
    @State private var resultThemeVisualPresentation: ActiveThemeVisualPresentation?
    @State private var inscriptionPreviewSource: ContentViewInscriptionPreviewSource?
    @State private var decodeError: String?
    @State private var showMessageCompose = false
    /// Scoped Core artifact for the canonical themed attachment. UI receives only the
    /// temporary file reference and completion handle, never payload or key bytes.
    @State private var pendingMessageArtifact: ShareArtifactDTO?
    @State private var pendingMessageTransfer: OpaqueShareTransfer?
    @State private var pendingMessagePreviewImageData: Data?
    @State private var messageSharePreparation: MessageSharePreparation?
    @State private var messageArtifactPreparationTask: Task<Void, Never>?
    @State private var messageShareLaunchID: UUID?
    @State private var messageArtifactCompletionGate = MessageArtifactCompletionGate()
    @State private var shareBuilderSource: ShareBuilderSource?
    @State private var initialScrollTarget: String?

    // Linking the active cipher to a recipient so its first message carries the key.
    @State private var showNewContact = false
    @State private var newContactName = ""
    @State private var newContactPhone = ""
    @State private var newContactEmail = ""

    /// One glyph size shared by the editor and the inscription so the text never
    /// changes size when it transforms — only the glyphs change.
    private let glyphSize: CGFloat = 20
    private let initialViewport: ContentViewInitialViewport?
    private let initialViewportProbeID: String
    private let initialComposeCaptureLength: ThemeCaptureIdentifier.ComposeLength?
    private let onInputTextChange: @MainActor (String) -> Void

    init(
        initialInputText: String = "",
        initialSettledArtifact: ContentViewSettledArtifactSeed? = nil,
        initialViewport: ContentViewInitialViewport? = nil,
        initialViewportProbeID: String = "workspace.text-frame",
        initialComposeCaptureLength: ThemeCaptureIdentifier.ComposeLength? = nil,
        onInputTextChange: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.initialViewport = initialViewport
        self.initialViewportProbeID = initialViewportProbeID
        self.initialComposeCaptureLength = initialComposeCaptureLength
        self.onInputTextChange = onInputTextChange
        _inputText = State(initialValue: initialInputText)
        _initialScrollTarget = State(initialValue: initialViewport?.rawValue)
        guard let initialSettledArtifact else { return }
        _boxPhase = State(initialValue: .result)
        _targetSnapshot = State(
            initialValue: initialSettledArtifact.composition.inscription
        )
        _transformDirection = State(initialValue: .encode)
        _resultArtifactComposition = State(
            initialValue: initialSettledArtifact.composition
        )
        _resultThemeVisualPresentation = State(
            initialValue: initialSettledArtifact.presentation
        )
    }

    private var isEditing: Bool { boxPhase == .editing }

    private var actionDisabled: Bool {
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return session.activeCipher == nil
    }

    private var isWorkspaceRevealBlocked: Bool {
        showLibrary
            || showSettings
            || showVaultProgress
            || artifactBrowser != nil
            || inscriptionPreviewSource != nil
            || showMessageCompose
            || shareBuilderSource != nil
            || showNewContact
            || decodeError != nil
    }

    /// The cipher used to produce the current result snapshot (encode only).
    private var resultCipher: CipherViewState? {
        transformDirection == .encode ? session.activeCipher : nil
    }

    /// Every delivery carries the canonical themed `.runescribe` message package.
    /// Its encrypted envelope and presentation metadata never include the cipher key.
    private var outgoingMessageText: String { targetSnapshot }

    // MARK: - Body

    var body: some View {
        ZStack {
            // The application-shell renderer owns the full-screen Theme
            // background. Keep workspace content transparent so the selected
            // provider remains visible without relying on child overdraw.
            Color.clear.ignoresSafeArea()

            VStack(spacing: 0) {
                RuneHeader(
                    slot: .workspace,
                    subtitle: "Rune Scribe",
                    trailingButtons: [
                        RuneHeaderButton(systemImage: "archivebox.fill",
                                         help: "Vault and Progress") { showVaultProgress = true },
                        RuneHeaderButton(systemImage: "gearshape.fill",
                                         help: "Settings") { showSettings = true },
                        RuneHeaderButton(systemImage: "key.fill",
                                         help: "Manage your cipher library") { showLibrary = true }
                    ]
                )

                workspaceBodyContainer
                    .themeCaptureIdentifier(
                        ThemeCaptureIdentifier.workspacePrimarySurface
                    )
            }
        }
        .runeRootFrame()
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if inputIsFocused {
                HStack {
                    Spacer()
                    Button("Done") { inputIsFocused = false }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("workspace.keyboard.done")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        #endif
        .themeCaptureViewportIdentifier(ThemeCaptureIdentifier.screenWorkspace)
        .background { automaticMessageShareLauncher }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLibrary) {
            CipherLibraryView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showVaultProgress) {
            VaultProgressView()
        }
        .sheet(item: $artifactBrowser) { browser in
            artifactBrowserSheet(browser)
        }
        .sheet(item: $inscriptionPreviewSource) { source in
            ThemeInscriptionPreviewView(
                descriptor: source.descriptor,
                plan: source.plan,
                selectedLayout: source.selectedLayout,
                image: { resourceID in
                    source.presentation.image(for: resourceID)
                        ?? Image(systemName: "exclamationmark.triangle.fill")
                },
                controls: .settledResult,
                backAction: { inscriptionPreviewSource = nil },
                libraryAction: openCodexFromInscriptionPreview,
                applyLayout: { inscriptionPreviewSource = nil }
            )
            .runeSemanticPresentationSurface()
            .preferredColorScheme(.dark)
        }
        .sheet(item: $shareBuilderSource) { source in
            ShareBuilderView(
                source: source,
                onLifecycleEnded: handleMessageShareBuilderLifecycleEnded
            )
        }
        #if os(iOS)
        .sheet(isPresented: $showMessageCompose) {
            MessageComposeView(messageText: outgoingMessageText,
                               recipients: messageRecipients(),
                               attachment: pendingMessageTransfer,
                               previewImageData: pendingMessagePreviewImageData,
                               onFinish: handleMessageFinished)
        }
        #endif
        .alert("Couldn't Complete", isPresented: Binding(
            get: { decodeError != nil },
            set: { if !$0 { decodeError = nil } }
        )) {
            Button("OK") { decodeError = nil }
        } message: {
            Text(decodeError ?? "")
        }
        .alert("New Contact", isPresented: $showNewContact) {
            TextField("Name", text: $newContactName)
            TextField("Phone (optional)", text: $newContactPhone)
            TextField("Email (optional)", text: $newContactEmail)
            Button("Add") { addAndAssignContact() }
            Button("Cancel", role: .cancel) { resetNewContact() }
        } message: {
            Text("Link this cipher to a person so your first message shares the key with them.")
        }
        .onChange(of: session.route, initial: true) { _, request in
            handleRoute(request)
        }
        .onChange(of: session.isLocked) { _, isLocked in
            if isLocked { dismissPresentedContentForLock() }
        }
        .onChange(of: inputText, initial: true) { _, value in
            onInputTextChange(value)
        }
        .onChange(of: isWorkspaceRevealBlocked, initial: true) { _, isBlocked in
            session.setRevealBlocker(.workspaceModal, active: isBlocked)
        }
        // Changing the mode or the active cipher invalidates a shown result, so
        // drop back to editing rather than leaving stale output on screen.
        .onChange(of: mode) { _, _ in handleEditingContextChange() }
        .onChange(of: session.activeCipher?.id) { _, _ in handleEditingContextChange() }
    }

    private var workspaceBodyContainer: some View {
        GeometryReader { proxy in
            let maximumCanvasWidth = Self.workspaceMaximumCanvasWidth(
                availableSize: proxy.size,
                pageCount: resultArtifactComposition?.pages.count
            )
            ScrollView {
                workspaceBody(maximumCanvasWidth: maximumCanvasWidth)
                    .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .defaultScrollAnchor(initialViewport == nil ? .top : .bottom)
            .scrollPosition(id: $initialScrollTarget, anchor: .bottom)
            .scrollDismissesKeyboard(.immediately)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    nonisolated static func workspaceMaximumCanvasWidth(
        availableSize: CGSize,
        pageCount: Int?
    ) -> CGFloat {
        let width = availableSize.width.isFinite ? max(1, availableSize.width) : 1
        let height = availableSize.height.isFinite ? max(1, availableSize.height) : 1
        let horizontalLimit = max(1, width - (2 * RuneMetrics.pad) - 20)
        let verticalLimit = max(
            1,
            height - workspaceCanvasVerticalInset(pageCount: pageCount)
        )
            * CGFloat(ShareArtifactRenderPlan.outputWidth)
            / CGFloat(ShareArtifactRenderPlan.outputHeight)
        return max(1, min(horizontalLimit, verticalLimit))
    }

    nonisolated static func workspaceCanvasVerticalInset(pageCount: Int?) -> CGFloat {
        let previewPadding: CGFloat = 20
        let fitMargin: CGFloat = 4
        let pagerSpacing: CGFloat = 8
        let pagerMinimumHeight: CGFloat = 46
        let pagerChrome = (pageCount ?? 0) > 1
            ? pagerSpacing + pagerMinimumHeight
            : 0
        return previewPadding + fitMargin + pagerChrome
    }

    nonisolated static func workspaceTextFrameMinimumHeight(
        maximumCanvasWidth: CGFloat?,
        pageCount: Int?
    ) -> CGFloat? {
        guard let maximumCanvasWidth else { return nil }
        let canvasHeight = max(1, maximumCanvasWidth)
            * CGFloat(ShareArtifactRenderPlan.outputHeight)
            / CGFloat(ShareArtifactRenderPlan.outputWidth)
        return canvasHeight + workspaceCanvasVerticalInset(pageCount: pageCount)
    }

    private func workspaceBody(maximumCanvasWidth: CGFloat?) -> some View {
        // Fixed layout — only the content inside `textFrame` changes when
        // converting. Nothing here appears, disappears, or resizes.
        VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
            activeCipherBar

            if mode == .encode, boxPhase == .editing {
                artifactSelectionBar

                if let active = session.activeCipher {
                    if let contact = session.contact(id: active.contactID) {
                        composeRecipient(contact)
                    } else {
                        recipientPicker(for: active)
                    }
                }
            }

            modePicker

            textFrame(maximumCanvasWidth: maximumCanvasWidth)
                .frame(
                    minHeight: Self.workspaceTextFrameMinimumHeight(
                        maximumCanvasWidth: maximumCanvasWidth,
                        pageCount: resultArtifactComposition?.pages.count
                    ),
                    maxHeight: .infinity
                )

            // At least the 46pt button-row height. The transforming-phase
            // placeholder is pinned to exactly 46pt so the parchment text frame
            // keeps its size through the inscription animation; only the taller
            // .result row (Share/iMessage + key indicator) is allowed to grow.
            actionArea
                .frame(minHeight: 46)
                .id(ContentViewInitialViewport.resultActions.rawValue)
        }
        .padding(RuneMetrics.pad)
        .scrollTargetLayout()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Text Frame (fixed size; only the inner content changes)

    private func artifactBrowserSheet(_ browser: ArtifactBrowser) -> AnyView {
        let codexID = session.themeSnapshot?.effectiveTheme.codex.id
        let captureIdentifier = browser.captureKind.flatMap { kind in
            codexID.map { ThemeCaptureIdentifier.artifactPicker(kind: kind, codexID: $0) }
        }
        let screenCaptureIdentifier = browser.captureKind.flatMap { kind in
            codexID.map { ThemeCaptureIdentifier.artifactPickerScreen(kind: kind, codexID: $0) }
        }
        if browser != .frame {
            return AnyView(
                ActiveThemeCodexCatalogSheet(
                    session: session,
                    initialTab: browser == .seal ? .seals : .relics
                )
                .themeCaptureViewportIdentifier(screenCaptureIdentifier)
            )
        }
        return AnyView(VStack(spacing: 0) {
            RuneHeader(
                slot: .frameBrowser,
                subtitle: "Choose Frame",
                trailingButtons: [
                    RuneHeaderButton(systemImage: "xmark", help: "Close") {
                        artifactBrowser = nil
                    }
                ]
            )

            ThemeArtifactBrowserView(
                title: "Choose \(browser.title)",
                items: artifactBrowserItems(browser),
                includesNone: browser != .relic,
                canSelectNone: session.activeThemeProviderIsAvailable,
                captureIdentifier: captureIdentifier,
                selectNone: {
                    artifactBrowser = nil
                    Task {
                        switch browser {
                        case .seal: await session.clearThemeSeal()
                        case .frame: await session.clearThemeFrame()
                        case .relic: break
                        }
                    }
                },
                select: { item in
                    artifactBrowser = nil
                    Task {
                        await session.selectThemeArtifact(
                            item.id,
                            kind: browser.selectionKind
                        )
                    }
                },
                artwork: { item in
                    artifactArtwork(
                        for: item.id,
                        kind: item.kind,
                        showsScriptSpecimen: true
                    )
                }
            )
        }
        .runeSheetFrame()
        .runeSemanticPresentationSurface()
        .preferredColorScheme(.dark)
        .task { await session.loadActiveThemeCatalogVisuals() }
        .themeCaptureViewportIdentifier(screenCaptureIdentifier))
    }

    private func textFrame(maximumCanvasWidth: CGFloat?) -> some View {
        ZStack(alignment: .topLeading) {
            RuneGlassSurface(
                cornerRadius: RuneMetrics.corner,
                accent: .runeGold,
                tintOpacity: 0.82,
                shadowRadius: 16,
                shadowY: 7
            )

            GeometryReader { geometry in
                let protectedInsets = ThemeChromePanelContentGeometry.protectedInsets(
                    pixelSize: panelBorderPixelSize,
                    renderedWidth: geometry.size.width,
                    minimumInsets: EdgeInsets()
                )
                let protectedMaximumCanvasWidth = maximumCanvasWidth.map {
                    max(
                        1,
                        min(
                            $0,
                            geometry.size.width
                                - protectedInsets.leading
                                - protectedInsets.trailing
                                - 20
                        )
                    )
                }
                ThemeChromeProtectedContentLayout(
                    panelPixelSize: panelBorderPixelSize,
                    minimumInsets: EdgeInsets(
                        top: 0,
                        leading: 0,
                        bottom: 0,
                        trailing: 0
                    )
                ) {
                    ZStack(alignment: .topLeading) {
                        switch boxPhase {
                        case .editing:
                            TextEditor(text: $inputText)
                                .font(.system(size: glyphSize, design: .monospaced))
                                .foregroundColor(.runeTextPrimary)
                                .scrollContentBackground(.hidden)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .accessibilityLabel(
                                    mode == .encode
                                        ? "Message to encode"
                                        : "Runes to decode"
                                )
                                #if os(iOS)
                                .focused($inputIsFocused)
                                #endif

                            if inputText.isEmpty {
                                Text(
                                    mode == .encode
                                        ? "Type or paste your message here…"
                                        : "Paste runes to decode…"
                                )
                                .font(.system(size: glyphSize, design: .monospaced))
                                .foregroundColor(.runeSilver.opacity(0.45))
                                .padding(.horizontal, 15)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                            }

                        case .transforming:
                            ScrollView {
                                RuneInscriptionText(
                                    source: sourceSnapshot,
                                    target: targetSnapshot,
                                    start: transformStart,
                                    direction: transformDirection,
                                    fontSize: glyphSize,
                                    fontName: session.inscriptionFontPostScriptName,
                                    fontResourceID: session.inscriptionFontResourceID,
                                    vectorDataByToken:
                                        session.inscriptionVectorDataByToken,
                                    vectorResourceIDByToken:
                                        session.inscriptionVectorResourceIDByToken,
                                    settled: boxPhase == .result
                                )
                                .padding(.horizontal, 15)
                                .padding(.vertical, 15)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        case .result:
                            if transformDirection == .encode,
                               let resultArtifactComposition,
                               let presentation = resultThemeVisualPresentation,
                               presentation.revision == presentation.plan.revision {
                                productionMessagePresentation(
                                    composition: resultArtifactComposition,
                                    presentation: presentation,
                                    maximumCanvasWidth: protectedMaximumCanvasWidth
                                )
                            } else {
                                ScrollView {
                                    RuneInscriptionText(
                                        source: sourceSnapshot,
                                        target: targetSnapshot,
                                        start: transformStart,
                                        direction: transformDirection,
                                        fontSize: glyphSize,
                                        fontName: session.inscriptionFontPostScriptName,
                                        fontResourceID: session.inscriptionFontResourceID,
                                        vectorDataByToken:
                                            session.inscriptionVectorDataByToken,
                                        vectorResourceIDByToken:
                                            session.inscriptionVectorResourceIDByToken,
                                        settled: true
                                    )
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 15)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous))
        .overlay {
            ThemeChromeImage(slot: .panelBorder)
                .opacity(0.42)
                .allowsHitTesting(false)
        }
        .runtimeViewportFrameProbe(initialViewportProbeID)
        .themeCaptureViewportIdentifier(composeCaptureIdentifier)
    }

    private var panelBorderPixelSize: ThemePixelSize? {
        session.activeThemeVisualPresentation?
            .chromeImageReference(for: .panelBorder)?
            .integrity.pixelSize
    }

    @ViewBuilder
    private func productionMessagePresentation(
        composition: ThemeArtifactCompositionPlan,
        presentation: ActiveThemeVisualPresentation,
        maximumCanvasWidth: CGFloat?
    ) -> some View {
        ThemeArtifactPreview(
            plan: composition,
            maximumCanvasWidth: maximumCanvasWidth,
            image: { presentation.image(for: $0) }
        )
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composeCaptureIdentifier: String? {
        guard let initialComposeCaptureLength,
              let codexID = session.themeSnapshot?.effectiveTheme.codex.id
        else { return nil }
        return ThemeCaptureIdentifier.compose(
            length: initialComposeCaptureLength,
            codexID: codexID
        )
    }

    // MARK: - Action Area

    @ViewBuilder
    private var actionArea: some View {
        switch boxPhase {
        case .editing:
            HStack {
                if !inputText.isEmpty && !session.isLoading {
                    Button {
                        reset()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())
                }
                Spacer()
                if session.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading cipher…")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.runeSilver)
                    }
                } else {
                    Button {
                        beginAction()
                    } label: {
                        Label(mode == .encode ? "RUNE SCRIBE" : "DECODE",
                              systemImage: mode == .encode ? "bolt.fill" : "wand.and.rays")
                    }
                    .buttonStyle(RuneScribButtonStyle())
                    .keyboardShortcut(
                        RuneScribeCommandCatalog.primaryAction.key.keyEquivalent,
                        modifiers: RuneScribeCommandCatalog.primaryAction.modifiers.eventModifiers
                    )
                    .disabled(actionDisabled || actionTask != nil)
                }
                Spacer()
            }

        case .transforming:
            // No spinner or indicator — the inscription in the frame is the feedback.
            // Pinned to the button-row height so the text frame doesn't resize mid-animation.
            Color.clear.frame(height: 46)

        case .result:
            VStack(spacing: 8) {
                resultEditCopyActions

                if transformDirection == .encode,
                   resultArtifactComposition != nil,
                   resultThemeVisualPresentation != nil {
                    inscriptionPreviewButton
                }

                if transformDirection == .encode, let cipher = resultCipher {
                    #if os(iOS)
                    resultShareActions
                    #else
                    shareButton()
                    #endif

                    customizeShareButton

                    keyIndicator(for: cipher)
                }

                Button {
                    reset()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())
                .accessibilityIdentifier("workspace.result.clear")
                .runtimeViewportFrameProbe("workspace.result.clear")
            }
        }
    }

    private var resultEditCopyActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                resultEditButton(resistsCompression: true)
                resultCopyButton(resistsCompression: true)
            }

            VStack(spacing: 8) {
                resultEditButton(resistsCompression: false)
                resultCopyButton(resistsCompression: false)
            }
        }
    }

    private var inscriptionPreviewButton: some View {
        Button(action: openInscriptionPreview) {
            Label("Full Inscription Preview", systemImage: "rectangle.inset.filled")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
        .accessibilityIdentifier("workspace.result.inscription-preview")
        .runtimeViewportFrameProbe("workspace.result.inscription-preview")
    }

    private func resultEditButton(resistsCompression: Bool) -> some View {
        Button {
            returnToEditing()
        } label: {
            Label("Edit", systemImage: "pencil")
                .lineLimit(1)
                .fixedSize(horizontal: resistsCompression, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
        .accessibilityIdentifier("workspace.result.edit")
        .runtimeViewportFrameProbe("workspace.result.edit")
    }

    private func resultCopyButton(resistsCompression: Bool) -> some View {
        Button {
            confirmCopy()
        } label: {
            Label(
                copyButtonTitle,
                systemImage: copyConfirmed
                    ? "checkmark.circle.fill"
                    : "doc.on.clipboard"
            )
            .lineLimit(1)
            .fixedSize(horizontal: resistsCompression, vertical: false)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneScribButtonStyle())
        .disabled(!allowsPlainResultCopy)
        .accessibilityIdentifier("workspace.result.copy")
        .runtimeViewportFrameProbe("workspace.result.copy")
    }

    #if os(iOS)
    private var resultShareActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                resultShareButton(resistsCompression: true)
                resultMessageButton(resistsCompression: true)
            }

            VStack(spacing: 8) {
                resultShareButton(resistsCompression: false)
                resultMessageButton(resistsCompression: false)
            }
        }
    }

    private func resultShareButton(resistsCompression: Bool) -> some View {
        shareButton()
            .lineLimit(1)
            .fixedSize(horizontal: resistsCompression, vertical: false)
            .frame(maxWidth: .infinity)
    }

    /// Always present so it is never "missing"; disabled (not hidden) when the
    /// device cannot send (Simulator / no iMessage account).
    private func resultMessageButton(resistsCompression: Bool) -> some View {
        Button {
            if !MessageComposeView.canSend(requiredAttachment: true) {
                decodeError = "This device can’t attach Rune Scribe files to Messages. Use Share instead."
                return
            }
            beginMessageArtifactPreparation(destination: .messages)
        } label: {
            Label(
                messageArtifactPreparationTask == nil
                    ? "Send via iMessage"
                    : "Preparing…",
                systemImage: messageArtifactPreparationTask == nil
                    ? "message.fill"
                    : "clock"
            )
                .lineLimit(1)
                .fixedSize(horizontal: resistsCompression, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneScribButtonStyle())
        .disabled(
            !MessageComposeView.canSend(requiredAttachment: true)
                || messageSharePreparation == nil
                || messageArtifactPreparationTask != nil
                || pendingMessageArtifact != nil
        )
        .accessibilityIdentifier("message.imessage-share")
        .runtimeViewportFrameProbe("message.imessage-share")
    }
    #endif

    private var customizeShareButton: some View {
        Button {
            openMessageShareBuilder()
        } label: {
            Label(
                "Customize Share",
                systemImage: "slider.horizontal.3"
            )
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
        .disabled(
            messageSharePreparation == nil
                || pendingMessageArtifact != nil
                || messageArtifactPreparationTask != nil
        )
        .accessibilityIdentifier("message.customize-share")
        .runtimeViewportFrameProbe("message.customize-share")
    }

    // MARK: - Active Cipher Bar

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.24)) {
                        mode = option
                    }
                } label: {
                    Label(
                        option.rawValue,
                        systemImage: option == .encode
                            ? "character.book.closed.fill"
                            : "text.viewfinder"
                    )
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        mode == option ? Color.runeTextInverse : Color.runeTextPrimary
                    )
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if mode == option {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.runeGoldBright, Color.runeGold],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                            }
                            .shadow(color: Color.runeGold.opacity(0.22), radius: 9, y: 4)
                    }
                }
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
        .padding(4)
        .background {
            RuneGlassSurface(
                cornerRadius: 15,
                accent: .runeAccentSecondary,
                tintOpacity: 0.58,
                shadowRadius: 8,
                shadowY: 3
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }

    private var activeCipherBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12))
                .foregroundColor(.runeGold)

            Menu {
                ForEach(session.ciphers) { cipher in
                    Button { selectActiveCipher(cipher.id) } label: {
                        if cipher.id == session.activeCipher?.id {
                            Label(cipher.label, systemImage: "checkmark")
                        } else {
                            Text(cipher.label)
                        }
                    }
                }
                Divider()
                Button { showLibrary = true } label: {
                    Label("Manage Ciphers…", systemImage: "books.vertical")
                }
            } label: {
                HStack(spacing: 6) {
                    Text(session.activeCipher?.label ?? "No Cipher")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.runeTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.runeSilver)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Active cipher: \(session.activeCipher?.label ?? "No Cipher")")
            }
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())

            Text("\(session.ciphers.count) cipher\(session.ciphers.count == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.runeSilver)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0)
        .background {
            ZStack {
                RuneGlassSurface(
                    cornerRadius: RuneMetrics.corner,
                    accent: .runeGold,
                    tintOpacity: 0.70,
                    shadowRadius: 10,
                    shadowY: 4
                )
                ThemeChromeImage(slot: .tabSelector)
                    .opacity(0.28)
                    .allowsHitTesting(false)
            }
        }
    }

    private var artifactSelectionBar: some View {
        let usesExpandedLayout = dynamicTypeSize.isAccessibilitySize
            || horizontalSizeClass == .compact
        let controlLayout = usesExpandedLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))

        return HStack(alignment: .top, spacing: 10) {
            controlLayout {
                artifactSelectionControl(
                    title: "Relic",
                    items: session.themeRelicItems,
                    browser: .relic
                )
                .fixedSize(horizontal: false, vertical: true)

                Divider().frame(height: usesExpandedLayout ? nil : 22)

                artifactSelectionControl(
                    title: "Seal",
                    items: session.themeSealItems,
                    browser: .seal
                )
                .fixedSize(horizontal: false, vertical: true)

                Divider().frame(height: usesExpandedLayout ? nil : 22)

                artifactSelectionControl(
                    title: "Frame",
                    items: session.themeFrameItems,
                    browser: .frame
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background {
            ZStack {
                RuneGlassSurface(
                    cornerRadius: RuneMetrics.corner,
                    accent: .runeAccentSecondary,
                    tintOpacity: 0.70,
                    shadowRadius: 12,
                    shadowY: 5
                )
                ThemeChromeImage(slot: .tabSelector)
                    .opacity(0.24)
                    .allowsHitTesting(false)
            }
        }
        .disabled(actionTask != nil || boxPhase != .editing)
    }

    private func artifactSelectionControl(
        title: String,
        items: [ThemeArtifactPickerItem],
        browser: ArtifactBrowser
    ) -> some View {
        let selectedItem = items.first(where: \.isSelected)
        return ThemeArtifactSelectionControl(
            title: title,
            item: selectedItem,
            kind: browser.visualKind,
            state: artifactSelectionState(selectedItem, browser: browser),
            allowsNone: browser != .relic,
            action: { artifactBrowser = browser }
        ) {
            if let selectedItem {
                artifactArtwork(for: selectedItem.id, kind: browser.visualKind)
            } else if browser == .frame {
                AnyView(ThemeEmptyFrameArtwork())
            } else {
                AnyView(ThemeVisualPlaceholder(
                    systemImage: browser.visualKind.systemImage,
                    label: "No \(title.lowercased()) selected"
                ))
            }
        }
    }

    private func artifactSelectionState(
        _ item: ThemeArtifactPickerItem?,
        browser: ArtifactBrowser
    ) -> ThemeVisualContentState {
        guard let item else { return browser == .relic ? .unavailable : .selected }
        return item.visualState
    }

    private func artifactBrowserItems(_ browser: ArtifactBrowser) -> [ThemeArtifactBrowserItem] {
        let items: [ThemeArtifactPickerItem] = switch browser {
        case .relic: session.themeRelicItems
        case .seal: session.themeSealItems
        case .frame: session.themeFrameItems
        }
        return items.enumerated().compactMap { index, item in
            guard let visual = session.activeThemeVisualPresentation?.plan.catalog.first(where: {
                $0.id == item.id && $0.kind == browser.visualKind
            }) else { return nil }
            return ThemeArtifactBrowserItem(
                id: item.id,
                resourceID: visual.thumbnail.id,
                name: item.name,
                description: item.description,
                facets: visual.facets,
                kind: browser.visualKind,
                rarity: item.rarity,
                state: item.visualState,
                accessibilityLabel: visual.accessibilityLabel,
                accessibilityHint: visual.accessibilityHint,
                provenance: nil,
                isSelectable: item.isSelectable,
                ordinal: index + 1,
                availability: visual.availability
            )
        }
    }

    private func artifactArtwork(
        for artifactID: ArtifactID,
        kind: ThemeVisualArtifactKind,
        showsScriptSpecimen: Bool = false
    ) -> AnyView {
        guard let presentation = session.activeThemeVisualPresentation,
              let visual = presentation.plan.catalog.first(where: {
                  $0.id == artifactID && $0.kind == kind
              })
        else {
            return AnyView(ThemeVisualPlaceholder(
                systemImage: kind.systemImage,
                label: "\(kind.rawValue) artwork unavailable"
            ))
        }
        guard let image = presentation.imageReference(for: visual.thumbnail)?.image else {
            return AnyView(ThemeVisualPlaceholder(
                systemImage: kind.systemImage,
                label: "\(kind.rawValue) artwork unavailable"
            ))
        }
        if showsScriptSpecimen,
           kind == .relic,
           let descriptor = session.themeSnapshot?.effectiveTheme,
           let relic = descriptor.codex.relics.first(where: {
               $0.metadata.id == artifactID
           }),
           let layout = relic.layouts.first(where: { $0.id == relic.defaultLayoutID }),
           let script = descriptor.codex.scripts.first(where: {
               $0.id == descriptor.codex.primaryScriptID
           }) {
            let pixelSize = visual.thumbnail.pixelSize
            let artworkAspectRatio = pixelSize.map {
                Double($0.width) / Double($0.height)
            } ?? (Double(layout.aspectRatio.width) / Double(layout.aspectRatio.height))
            let accessibilityDescription = [
                relic.metadata.accessibility.label.fallbackValue,
                relic.metadata.accessibility.hint?.fallbackValue ?? "",
            ].joined(separator: " ").lowercased()
            return AnyView(ThemeRelicSpecimenArtwork(
                image: image,
                plan: ThemeRelicSpecimenPlan(
                    inscription: catalogSpecimenInscription(
                        script: script,
                        layout: layout,
                        isRequiredBase: descriptor.criticality == .requiredBase,
                        enabled: descriptor.criticality == .requiredBase
                            || artifactID == descriptor.codex.defaultRelicID
                    ),
                    fontPostScriptName: script.fontPostScriptName?.rawValue
                        ?? RuneThemePaletteInterpreter.fontPostScriptName,
                    glyphSafeRegion: layout.glyphSafeRegion,
                    artworkAspectRatio: artworkAspectRatio,
                    minimumGlyphScale: layout.minimumGlyphScale,
                    usesPrimaryTextColor: accessibilityDescription.contains("dark")
                        || accessibilityDescription.contains("charcoal")
                        || accessibilityDescription.contains("obsidian")
                )
            ))
        }
        return AnyView(image.resizable().scaledToFit())
    }

    private func catalogSpecimenInscription(
        script: ThemeScriptDescriptor,
        layout: ThemeShareLayoutPreset,
        isRequiredBase: Bool,
        enabled: Bool
    ) -> String {
        guard enabled else { return "" }
        let rows = Int(layout.catalogSpecimenRows ?? 3)
        let columns = Int(layout.catalogSpecimenColumns ?? (isRequiredBase ? 5 : 8))
        let tokens = Array(script.glyphs.prefix(rows * columns).map(\.textToken))
        return stride(from: 0, to: tokens.count, by: columns).map { start in
            tokens[start ..< min(start + columns, tokens.count)].joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func interactiveComposition(
        inscription: String,
        presentation: ActiveThemeVisualPresentation,
        descriptor: ThemeDescriptor,
        fontPostScriptNameOverride: ThemeFontPostScriptName?
    ) -> ThemeArtifactCompositionPlan? {
        guard descriptor.codex.id == presentation.plan.codex.codexID,
              let selection = try? SharePresentationSelection(
                  codexID: presentation.plan.codex.codexID,
                  scriptID: presentation.plan.scriptID,
                  relicID: presentation.plan.selectedRelicID,
                  sealID: presentation.plan.selectedSealID,
                  frameID: presentation.plan.selectedFrameID,
                  presentationVersion: SharePresentationSelection.supportedPresentationVersion
              )
        else { return nil }
        let artifactNames = [
            presentation.plan.selectedRelic?.displayName,
            presentation.plan.selectedSeal?.displayName,
            presentation.plan.selectedFrame?.displayName,
        ].compactMap { $0 }.joined(separator: ", ")
        return try? ThemeArtifactCompositionPolicy.interactivePlan(
            selection: selection,
            inscription: inscription,
            descriptor: descriptor,
            colorMode: usesIncreasedContrast ? .highContrast : .standard,
            reduceMotion: effectiveReduceMotion
                || session.effectiveEffectsPreference(
                    systemReduceMotion: effectiveReduceMotion
                ) != .full,
            accessibilityLabel: "Encoded rune artifact using \(artifactNames)",
            provenanceLabel: "Source details included",
            fontPostScriptNameOverride: fontPostScriptNameOverride
        )
    }

    // MARK: - Compose Recipient

    /// Shows who the active cipher is organized under, so the user knows the recipient.
    private func composeRecipient(_ contact: ContactViewState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.runeBlue)
            Text("To: \(contact.displayName)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.runeSilver)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    /// Shown when the active cipher isn't linked to anyone yet: pick (or add) the
    /// recipient so the first message to them carries the cipher key.
    private func recipientPicker(for cipher: CipherViewState) -> some View {
        Menu {
            ForEach(session.contacts) { contact in
                Button(contact.displayName) {
                    linkCipher(cipher.id, to: contact.id)
                }
            }
            if !session.contacts.isEmpty { Divider() }
            Button {
                resetNewContact(); showNewContact = true
            } label: {
                Label("New Contact…", systemImage: "person.badge.plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 11))
                    .foregroundColor(.runeBlue)
                Text("Set recipient to include the key")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.runeBlue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.runeBlue)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Set recipient to include the key")
        }
    }

    // MARK: - Actions

    private func beginAction() {
        guard actionTask == nil else { return }
        let generation = actionGeneration
        actionTask = Task { @MainActor in
            await performAction(generation: generation)
            actionTask = nil
        }
    }

    private func performAction(generation: UInt64) async {
        guard boxPhase == .editing, let activeCipher = session.activeCipher else { return }
        let visualPresentationSnapshot = session.activeThemeVisualPresentation
        let themeDescriptorSnapshot = session.themeSnapshot?.effectiveTheme
        let fontPostScriptNameOverrideSnapshot: ThemeFontPostScriptName? =
            activeCipher.fontSource == .imported && activeCipher.fontIsRegistered
                ? ThemeFontPostScriptName(rawValue: session.inscriptionFontPostScriptName)
                : nil
        let source = inputText
        let target: String
        let direction: RuneInscriptionText.Direction
        var preparedShare: MessageSharePreparation?
        do {
            switch mode {
            case .encode:
                let result = try await session.encode(source, cipherID: activeCipher.id)
                guard let shareHandle = result.shareHandle else {
                    throw OpaqueSharePresentationError.unavailable
                }
                target = result.runes
                direction = .encode
                let share = MessageSharePreparation(
                    runes: result.runes,
                    senderName: activeCipher.label,
                    cipherID: result.cipherID.rawValue,
                    shareHandle: shareHandle
                )
                preparedShare = share
            case .decode:
                target = try await session.decode(source).plaintext
                direction = .decode
            }
        } catch {
            guard actionGeneration == generation,
                  !Task.isCancelled,
                  !session.isLocked else { return }
            presentFailure(error)
            return
        }

        guard actionGeneration == generation, !Task.isCancelled else {
            return
        }
        guard !session.isLocked else {
            dismissPresentedContentForLock()
            return
        }

        releaseMessageArtifact()
        messageSharePreparation = preparedShare
        if direction == .encode,
           let visualPresentationSnapshot,
           let themeDescriptorSnapshot {
            resultThemeVisualPresentation = visualPresentationSnapshot
            resultArtifactComposition = interactiveComposition(
                inscription: target,
                presentation: visualPresentationSnapshot,
                descriptor: themeDescriptorSnapshot,
                fontPostScriptNameOverride: fontPostScriptNameOverrideSnapshot
            )
        } else {
            resultThemeVisualPresentation = nil
            resultArtifactComposition = nil
        }
        sourceSnapshot = source
        targetSnapshot = target
        transformDirection = direction
        transformStart = Date()
        copyConfirmed = false
        boxPhase = .transforming

        settleTask?.cancel()
        let duration = RuneInscriptionText.totalDuration(count: Array(target).count)
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            boxPhase = .result
        }
    }

    private func returnToEditing() {
        settleTask?.cancel()
        releaseMessageArtifact()
        inscriptionPreviewSource = nil
        resultArtifactComposition = nil
        resultThemeVisualPresentation = nil
        copyConfirmed = false
        boxPhase = .editing
    }

    private func openInscriptionPreview() {
        guard let descriptor = session.themeSnapshot?.effectiveTheme,
              let plan = resultArtifactComposition,
              let presentation = resultThemeVisualPresentation,
              let source = ContentViewInscriptionPreviewSource(
                  descriptor: descriptor,
                  plan: plan,
                  presentation: presentation
              )
        else {
            decodeError = "The current inscription preview is unavailable."
            return
        }
        inscriptionPreviewSource = source
    }

    private func openCodexFromInscriptionPreview() {
        inscriptionPreviewSource = nil
        Task { @MainActor in
            await Task.yield()
            artifactBrowser = .relic
        }
    }

    private func handleEditingContextChange() {
        if actionTask != nil {
            actionGeneration &+= 1
            actionTask?.cancel()
        }
        if !isEditing { returnToEditing() }
    }

    /// Wipes the composer back to a pristine, empty editing state (the user changed their
    /// mind). Cancels any in-flight inscription and clears the text and result snapshots.
    private func reset() {
        settleTask?.cancel()
        inputText = ""
        sourceSnapshot = ""
        targetSnapshot = ""
        inscriptionPreviewSource = nil
        resultArtifactComposition = nil
        resultThemeVisualPresentation = nil
        releaseMessageArtifact()
        copyConfirmed = false
        decodeError = nil
        boxPhase = .editing
    }

    private var copyButtonTitle: String {
        if copyConfirmed { return "Copied!" }
        return transformDirection == .encode ? "Copy Runes" : "Copy Text"
    }

    private func confirmCopy() {
        // Copy is plain runes only. Share and Send via iMessage attach the
        // canonical message package without the cipher.
        guard allowsPlainResultCopy else { return }
        Task {
            guard await session.copyToClipboard(targetSnapshot) else { return }
            withAnimation { copyConfirmed = true }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { copyConfirmed = false }
        }
    }

    private var allowsPlainResultCopy: Bool {
        MessageResultActionPolicy.allowsPlainCopy(
            artifactPreparationInFlight: messageArtifactPreparationTask != nil,
            hasPendingArtifact: pendingMessageArtifact != nil
        )
    }

    /// Adds a manual contact from the New Contact fields and links the active cipher to
    /// it, so the next message bootstraps the key to that person.
    private func addAndAssignContact() {
        defer { resetNewContact() }
        guard let active = session.activeCipher else { return }
        let name = newContactName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let phones = [newContactPhone.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        let emails = [newContactEmail.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        let contact = ContactViewState(
            displayName: name,
            phones: phones,
            emails: emails,
            source: .manual
        )
        Task {
            do {
                let persisted = try await session.createContact(contact)
                try await session.setContact(cipherID: active.id, contactID: persisted.id)
            } catch {
                presentFailure(error)
            }
        }
    }

    private func resetNewContact() {
        newContactName = ""; newContactPhone = ""; newContactEmail = ""
    }

    private func handleRoute(_ request: RuneScribeUIRouteRequest?) {
        guard let request else { return }
        defer { session.consumeRoute(id: request.id) }
        guard !session.isLocked else { return }

        switch request.route {
        case .openCipherLibrary:
            showLibrary = true
        case .openSettings:
            showSettings = true
        case .replyToMessage(let cipherID):
            guard session.ciphers.contains(where: { $0.id == cipherID }) else { return }
            Task {
                do {
                    try await session.setActive(id: cipherID)
                    mode = .encode
                    if !isEditing { returnToEditing() }
                } catch {
                    presentFailure(error)
                }
            }
        }
    }

    private func dismissPresentedContentForLock() {
        actionGeneration &+= 1
        actionTask?.cancel()
        settleTask?.cancel()
        settleTask = nil
        inputText = ""
        sourceSnapshot = ""
        targetSnapshot = ""
        inscriptionPreviewSource = nil
        resultArtifactComposition = nil
        resultThemeVisualPresentation = nil
        decodeError = nil
        copyConfirmed = false
        boxPhase = .editing
        showLibrary = false
        showSettings = false
        showVaultProgress = false
        artifactBrowser = nil
        shareBuilderSource = nil
        showMessageCompose = false
        showNewContact = false
        resetNewContact()
        session.setRevealBlocker(.systemShare, active: false)
        releaseMessageArtifact()
    }

    /// Quick Share prepares the canonical package only after the user acts. The
    /// runtime therefore resolves and validates the latest appearance defaults,
    /// ownership, provider availability, and compatibility for this operation.
    private func shareButton() -> some View {
        Button {
            beginMessageArtifactPreparation(destination: .systemShare)
        } label: {
            Label(
                messageArtifactPreparationTask == nil ? "Share" : "Preparing…",
                systemImage: messageArtifactPreparationTask == nil
                    ? "square.and.arrow.up"
                    : "clock"
            )
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
        .disabled(
            messageSharePreparation == nil
                || messageArtifactPreparationTask != nil
                || pendingMessageArtifact != nil
        )
        .accessibilityIdentifier("message.quick-share")
        .runtimeViewportFrameProbe("message.quick-share")
    }

    @ViewBuilder
    private var automaticMessageShareLauncher: some View {
        if let artifact = pendingMessageArtifact,
           let transfer = pendingMessageTransfer,
           let messageShareLaunchID,
           case .file = artifact.reference {
            RuneScribePreparedFileShareLauncher(
                transfer: transfer,
                launchID: messageShareLaunchID,
                onPresented: {
                    session.setRevealBlocker(.systemShare, active: true)
                },
                onFinish: handleNativeShareFinished
            )
        }
    }

    /// A light line reminding the sender how to share the cipher separately.
    @ViewBuilder
    private func keyIndicator(for cipher: CipherViewState?) -> some View {
        if cipher != nil {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.runeBlue)
                Text("Share cipher separately from Cipher Manager")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.runeSilver)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    #if os(iOS)
    /// Phone numbers + emails of the active cipher's linked contact, if any.
    private func messageRecipients() -> [String]? {
        guard let contact = session.contact(id: resultCipher?.contactID) else { return nil }
        let all = contact.phones + contact.emails
        return all.isEmpty ? nil : all
    }

    private func handleMessageFinished(_ completion: SharePresentationCompletion) {
        showMessageCompose = false
        handleShareCompletion(completion)
    }
    #endif

    private func handleShareCompletion(_ completion: SharePresentationCompletion) {
        switch completion {
        case .success(let evidence):
            beginMessageArtifactCompletion(evidence: evidence)
        case .failure(let error):
            guard let artifact = pendingMessageArtifact else {
                presentFailure(error)
                return
            }
            recoverMessageArtifactAfterTerminalFailure(
                artifact: artifact,
                error: error
            )
        }
    }

    private func handleNativeShareFinished(_ completion: SharePresentationCompletion) {
        session.setRevealBlocker(.systemShare, active: false)
        handleShareCompletion(completion)
    }

    private func openMessageShareBuilder() {
        guard let preparation = messageSharePreparation,
              pendingMessageArtifact == nil,
              messageArtifactPreparationTask == nil,
              !session.isLocked
        else {
            decodeError = "Rune Scribe is still preparing this message for sharing."
            return
        }
        let source = ShareBuilderSource.encryptedMessage(
            runes: preparation.runes,
            senderName: preparation.senderName,
            cipherID: preparation.cipherID,
            messageHandle: preparation.shareHandle
        )
        shareBuilderSource = source
    }

    private func handleMessageShareBuilderLifecycleEnded() {
        shareBuilderSource = nil
    }

    private func recoverMessageArtifactAfterTerminalFailure(
        artifact: ShareArtifactDTO,
        error: any Error
    ) {
        guard pendingMessageArtifact?.id == artifact.id else { return }
        presentFailure(error)
        pendingMessageArtifact = nil
        let transfer = pendingMessageTransfer
        pendingMessageTransfer = nil
        pendingMessagePreviewImageData = nil
        messageShareLaunchID = nil
        Task {
            await transfer?.close()
            await session.releaseShareArtifact(id: artifact.id)
        }
    }

    private func beginMessageArtifactCompletion(
        evidence: ShareArtifactCompletionEvidenceDTO
    ) {
        guard let artifact = pendingMessageArtifact,
              artifact.id == evidence.artifactID,
              messageArtifactCompletionGate.begin(for: evidence.artifactID)
        else { return }
        Task {
            await completePreparedArtifact(artifact: artifact, evidence: evidence)
        }
    }

    private func completePreparedArtifact(
        artifact: ShareArtifactDTO,
        evidence: ShareArtifactCompletionEvidenceDTO
    ) async {
        defer { messageArtifactCompletionGate.finish(for: artifact.id) }
        do {
            _ = try await session.completeShareArtifact(evidence: evidence)
        } catch {
            await session.releaseShareArtifact(id: artifact.id)
            if pendingMessageArtifact?.id == artifact.id {
                presentFailure(error)
            }
        }

        guard pendingMessageArtifact?.id == artifact.id else { return }
        pendingMessageArtifact = nil
        let transfer = pendingMessageTransfer
        pendingMessageTransfer = nil
        pendingMessagePreviewImageData = nil
        messageShareLaunchID = nil
        await transfer?.close()
    }

    private func beginMessageArtifactPreparation(
        destination: MessageShareDestination
    ) {
        guard messageArtifactPreparationTask == nil,
              let preparation = messageSharePreparation
        else { return }
        messageArtifactPreparationTask = Task { @MainActor in
            await prepareMessageArtifact(
                using: preparation,
                destination: destination
            )
            messageArtifactPreparationTask = nil
        }
    }

    private func prepareMessageArtifact(
        using preparation: MessageSharePreparation,
        destination: MessageShareDestination
    ) async {
        guard messageSharePreparation == preparation,
              pendingMessageArtifact == nil,
              transformDirection == .encode,
              boxPhase != .editing,
              !session.isLocked
        else { return }

        var artifact: ShareArtifactDTO?
        var transfer: OpaqueShareTransfer?
        var previewImageData: Data?
        do {
            let preparedDelivery = try await session.prepareMessageShareDelivery(
                runes: preparation.runes,
                senderName: preparation.senderName,
                cipherID: preparation.cipherID,
                shareHandle: preparation.shareHandle,
                colorMode: usesIncreasedContrast ? .highContrast : .standard,
                systemReduceMotion: effectiveReduceMotion
            )
            artifact = preparedDelivery.artifact
            previewImageData = preparedDelivery.previewImageData
            transfer = try await canonicalMessageTransfer(for: preparedDelivery.artifact)
        } catch {
            if let artifact {
                await session.releaseShareArtifact(id: artifact.id)
            }
            guard messageSharePreparation == preparation,
                  !session.isLocked else { return }
            presentFailure(error)
            return
        }

        guard let artifact,
              let transfer,
              messageSharePreparation == preparation,
              pendingMessageArtifact == nil,
              transformDirection == .encode,
              boxPhase != .editing,
              !session.isLocked
        else {
            await transfer?.close()
            if let artifact {
                await session.releaseShareArtifact(id: artifact.id)
            }
            return
        }
        pendingMessageArtifact = artifact
        pendingMessageTransfer = transfer
        pendingMessagePreviewImageData = previewImageData
        switch destination {
        case .systemShare:
            messageShareLaunchID = UUID()
        #if os(iOS)
        case .messages:
            showMessageCompose = true
        #endif
        }
    }

    private func canonicalMessageTransfer(
        for artifact: ShareArtifactDTO
    ) async throws -> OpaqueShareTransfer {
        guard CanonicalMessageArtifactPolicy.accepts(artifact) else {
            throw OpaqueSharePresentationError.unavailable
        }
        return try await session.shareTransfer(for: artifact.id)
    }

    private func selectActiveCipher(_ id: UUID) {
        Task {
            do {
                try await session.setActive(id: id)
            } catch {
                presentFailure(error)
            }
        }
    }

    private var effectiveReduceMotion: Bool {
        accessibilityReduceMotion || accessibilityPreferences.forcesReduceMotion
    }

    private var usesIncreasedContrast: Bool {
        colorSchemeContrast == .increased
            || accessibilityPreferences.forcesIncreasedContrast
    }

    private func linkCipher(_ cipherID: UUID, to contactID: UUID) {
        Task {
            do {
                try await session.setContact(cipherID: cipherID, contactID: contactID)
            } catch {
                presentFailure(error)
            }
        }
    }

    private func presentFailure(_ error: Error) {
        decodeError = RuneScribeUISession.message(for: error)
    }

    private func releaseMessageArtifact() {
        messageArtifactPreparationTask?.cancel()
        messageArtifactPreparationTask = nil
        messageSharePreparation = nil
        pendingMessagePreviewImageData = nil
        guard let artifact = pendingMessageArtifact else { return }
        guard !messageArtifactCompletionGate.isCompleting(artifact.id) else { return }
        pendingMessageArtifact = nil
        let transfer = pendingMessageTransfer
        pendingMessageTransfer = nil
        messageShareLaunchID = nil
        Task {
            await transfer?.close()
            await session.releaseShareArtifact(id: artifact.id)
        }
    }
}
