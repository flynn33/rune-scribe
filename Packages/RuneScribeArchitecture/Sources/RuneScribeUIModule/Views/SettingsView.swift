// RuneScrib/Views/SettingsView.swift

import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

enum SettingsInitialViewport: String, Sendable {
    case codexCard
    case defaultsPreview

    var scrollTargetID: String {
        switch self {
        case .codexCard: rawValue
        case .defaultsPreview: "settings.defaults-preview-end"
        }
    }
}

enum SettingsThemeProviderPresentationPolicy {
    static func status(_ provider: ThemeProviderSummaryDTO) -> String {
        switch provider.state {
        case .available:
            return provider.isOwned ? "Available" : "Not owned"
        case .locked:
            return "Locked"
        case .unavailable:
            return "Temporarily unavailable"
        case .incompatible:
            return "Requires a newer app or system"
        case .invalidResources:
            return "Unavailable because required resources could not be verified"
        }
    }

    static func visualState(
        _ provider: ThemeProviderSummaryDTO
    ) -> ThemeVisualContentState {
        switch provider.state {
        case .available:
            if provider.isSelected { return .selected }
            return provider.isOwned ? .owned : .locked
        case .locked:
            return .locked
        case .unavailable, .incompatible, .invalidResources:
            return .unavailable
        }
    }

    static func icon(_ provider: ThemeProviderSummaryDTO) -> String {
        switch provider.state {
        case .available:
            return provider.isSelected ? "checkmark.circle.fill" : "circle"
        case .locked:
            return "lock.fill"
        case .unavailable, .invalidResources:
            return "exclamationmark.circle"
        case .incompatible:
            return "arrow.up.circle"
        }
    }
}

/// App settings: the 4-digit app-lock PIN, an About section attributing the app
/// to Raven Forge Software, and access to the End-User License Agreement.
struct SettingsView: View {

    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.runtimeAccessibilityPreferences) private var accessibilityPreferences
    @Environment(\.themeCaptureIdentifiersEnabled) private var themeCaptureIdentifiersEnabled

    @State private var pinFlow: PINFlowView.Mode?
    @State private var showLicense = false
    @State private var showContacts = false
    @State private var showVaultProgress = false
    @State private var showThemeFailureDetails = false
    @State private var initialScrollTarget: String?

    init(initialViewport: SettingsInitialViewport? = nil) {
        _initialScrollTarget = State(initialValue: initialViewport?.scrollTargetID)
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                slot: .settings,
                subtitle: "Settings",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
                    appearancePanel
                    progressAndFeedbackPanel
                    cloudAndGameCenterPanel
                    appLockPanel
                    contactsPanel
                    aboutPanel
                    licensePanel
                }
                .padding(RuneMetrics.pad)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $initialScrollTarget, anchor: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .runeSheetFrame()
        .runeSemanticPresentationSurface()
        .preferredColorScheme(.dark)
        .themeCaptureViewportIdentifier(ThemeCaptureIdentifier.screenSettingsAppearance)
        .sheet(item: $pinFlow) { mode in
            PINFlowView(mode: mode)
        }
        .sheet(isPresented: $showLicense) {
            LicenseView()
        }
        .sheet(isPresented: $showContacts) {
            ContactsView()
        }
        .sheet(isPresented: $showVaultProgress) {
            VaultProgressView()
        }
    }

    // MARK: - Appearance

    private var appearancePanel: some View {
        RunePanel(title: "Appearance", systemImage: "paintpalette", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose one available Codex. This changes presentation only; your ciphers and messages stay the same.")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)

                if let snapshot = session.themeSnapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(snapshot.providers, id: \.codexID) { provider in
                            ThemeCodexCardView(
                                codexID: provider.codexID,
                                displayName: provider.displayName,
                                summary: providerStatus(provider),
                                state: providerVisualState(provider),
                                accessibilityLabel: provider.displayName,
                                accessibilityHint: provider.isSelectable && !provider.isSelected
                                    ? "Selects this Codex appearance"
                                    : "",
                                isEnabled: provider.isSelectable && !provider.isSelected,
                                action: {
                                    Task { await session.selectCodex(provider.codexID) }
                                }
                            ) {
                                providerArtwork(provider)
                            }
                        }

                        if snapshot.fallbackReason != .none {
                            Label(
                                "Your preferred Codex is unavailable. The Base appearance is active.",
                                systemImage: "arrow.uturn.backward.circle"
                            )
                            .font(.footnote)
                            .foregroundColor(.runeWarning)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        if !snapshot.requiredBaseResourceFailures.isEmpty {
                            DisclosureGroup(
                                isExpanded: $showThemeFailureDetails,
                                content: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(
                                            Array(snapshot.requiredBaseResourceFailures.enumerated()),
                                            id: \.offset
                                        ) { _, failure in
                                            themeFailureDetails(failure)
                                        }
                                    }
                                    .padding(.top, 8)
                                },
                                label: {
                                    Label(
                                        "Required Base Resource Failure Details",
                                        systemImage: "exclamationmark.triangle.fill"
                                    )
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(.runeWarning)
                                }
                            )
                            .accessibilityIdentifier("theme.required-resource-failure-details")
                        }

                        if session.activeThemeProviderIsAvailable {
                            Divider().overlay(Color.runeSilver.opacity(0.25))
                            selectedCodexDefaults
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Active theme presentation")
                    .accessibilityValue(themePresentationAccessibilityValue)
                    .accessibilityIdentifier(
                        ThemeCaptureIdentifier.presentation(
                            themeID: snapshot.effectiveTheme.id,
                            variant: themePresentationVariant
                        )
                    )
                    .runtimeViewportFrameProbe(
                        ThemeCaptureIdentifier.presentation(
                            themeID: snapshot.effectiveTheme.id,
                            variant: themePresentationVariant
                        )
                    )
                    .scrollTargetLayout()
                } else {
                    Label(
                        "Codex appearances are temporarily unavailable.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                }

                if let error = session.themeSelectionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundColor(.runeWarning)
                }
            }
        }
        .task {
            await session.loadThemeCodexCardPreviews()
            await session.loadActiveThemeCatalogVisuals()
        }
        .id(SettingsInitialViewport.codexCard.rawValue)
    }

    private var selectedCodexDefaults: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DEFAULTS FOR \(session.themeSnapshot?.effectiveTheme.codex.displayName.fallbackValue.uppercased() ?? "SELECTED CODEX")")
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundColor(.runeGold)

            Text("Workspace choices, Quick Share, and Share Builder initialization use these same runtime-owned defaults.")
                .font(.footnote)
                .foregroundColor(.runeSilver)
                .fixedSize(horizontal: false, vertical: true)

            appearanceArtifactMenu(
                title: "Relic",
                items: session.themeRelicItems,
                selectedID: session.selectedThemeRelicID,
                includesNone: false,
                kind: .relic
            )
            appearanceArtifactMenu(
                title: "Seal",
                items: session.themeSealItems,
                selectedID: session.selectedThemeSealID,
                includesNone: true,
                kind: .seal
            )
            appearanceArtifactMenu(
                title: "Frame",
                items: session.themeFrameItems,
                selectedID: session.selectedThemeFrameID,
                includesNone: true,
                kind: .frame
            )

            Picker("Effects", selection: Binding(
                get: { session.appearanceEffectsPreference },
                set: { preference in
                    Task { await session.setEffectsPreference(preference) }
                }
            )) {
                ForEach(RuntimeEffectsPreference.allCases, id: \.self) { preference in
                    Text(preference.rawValue.capitalized).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Controls optional decorative motion only")
            .accessibilityIdentifier("appearance.effects")

            Text(appearanceEffectsDetail)
                .font(.footnote)
                .foregroundColor(.runeSilver)
                .fixedSize(horizontal: false, vertical: true)

            appearanceDefaultsPreview
                .id(SettingsInitialViewport.defaultsPreview.rawValue)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance.selected-codex-defaults")
        .id(SettingsInitialViewport.defaultsPreview.scrollTargetID)
    }

    private func appearanceArtifactMenu(
        title: String,
        items: [ThemeArtifactPickerItem],
        selectedID: ArtifactID?,
        includesNone: Bool,
        kind: ThemeArtifactSelectionKind
    ) -> some View {
        let selected = items.first(where: { $0.id == selectedID })
        return Menu {
            if includesNone {
                Button {
                    Task {
                        switch kind {
                        case .seal: await session.clearThemeSeal()
                        case .frame: await session.clearThemeFrame()
                        case .relic: break
                        }
                    }
                } label: {
                    if selectedID == nil {
                        Label("None", systemImage: "checkmark")
                    } else {
                        Text("None")
                    }
                }
            }
            ForEach(items) { item in
                Button {
                    Task { await session.selectThemeArtifact(item.id, kind: kind) }
                } label: {
                    Label(
                        item.name + (item.isOwned ? "" : " — locked"),
                        systemImage: item.id == selectedID
                            ? "checkmark"
                            : item.isOwned ? "circle" : "lock"
                    )
                }
                .disabled(!item.isSelectable)
            }
        } label: {
            HStack(spacing: 12) {
                appearanceArtwork(selectedID, kind: kind)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.runeSilver)
                    Text(selected?.name ?? "None")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.runeTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                        .layoutPriority(1)
                }
                .layoutPriority(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundColor(.runeSilver)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .menuIndicator(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Default \(title)")
        .accessibilityValue(selected?.name ?? "None")
        .accessibilityHint("Choose the default \(title.lowercased())")
        .accessibilityIdentifier("appearance.default-\(title.lowercased())")
    }

    @ViewBuilder
    private var appearanceDefaultsPreview: some View {
        if let plan = appearancePreviewPlan,
           let presentation = session.activeThemeVisualPresentation {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                        .fill(Color.runeParchment)
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Preview of the selected Codex defaults")
                        .accessibilityValue(plan.accessibilityLabel)
                        .accessibilityIdentifier("appearance.defaults-preview")
                        .runtimeViewportFrameProbe("appearance.defaults-preview")

                    ThemeArtifactPreview(
                        plan: plan,
                        image: { presentation.image(for: $0) }
                    )
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .themeCaptureAccessibilityHiddenWhenDisabled()
                    .themeCaptureViewportIdentifier(
                        ThemeCaptureIdentifier.workspacePrimarySurface
                    )
                }
                .clipShape(RoundedRectangle(
                    cornerRadius: RuneMetrics.corner,
                    style: .continuous
                ))
                .themeCaptureIdentifier(
                    ThemeCaptureIdentifier.settingsDefaultsPreview(
                        codexID: plan.selection.codexID
                    )
                )

                appearanceBackgroundPreview(presentation: presentation)
            }
        } else {
            Color.clear
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                ThemeVisualPlaceholder(
                    systemImage: "rectangle.inset.filled",
                    label: "Appearance preview unavailable"
                )
            }
        }
    }

    @ViewBuilder
    private func appearanceBackgroundPreview(
        presentation: ActiveThemeVisualPresentation
    ) -> some View {
        let imagePlan = appearanceBackgroundImagePlan(presentation)
        if presentation.image(for: imagePlan.id) != nil,
           let descriptor = session.themeSnapshot?.effectiveTheme {
            CodexBackgroundTreatmentPanel(
                model: CodexBackgroundTreatmentPanelModel(
                    title: descriptor.codex.background.displayName.fallbackValue,
                    summary: descriptor.codex.background.accessibility.label.fallbackValue,
                    backgroundResourceID: imagePlan.id
                ),
                image: { requiredProductionImage($0, from: presentation) }
            )
            .aspectRatio(910.0 / 460.0, contentMode: .fit)
            .accessibilityIdentifier("appearance.background-preview")
        }
    }

    private func appearanceBackgroundImagePlan(
        _ presentation: ActiveThemeVisualPresentation
    ) -> ThemeVisualImagePlan {
        if usesIncreasedContrast { return presentation.plan.backgroundHighContrast }
        if effectiveReduceMotion { return presentation.plan.backgroundReduceMotion }
        return presentation.plan.backgroundStatic
    }

    private func requiredProductionImage(
        _ resourceID: ThemeResourceID,
        from presentation: ActiveThemeVisualPresentation
    ) -> Image {
        guard let image = presentation.image(for: resourceID) else {
            preconditionFailure("Missing admitted production image: \(resourceID.rawValue)")
        }
        return image
    }

    private var appearancePreviewPlan: ThemeArtifactCompositionPlan? {
        guard session.activeThemeVisualPresentation != nil,
              let descriptor = session.themeSnapshot?.effectiveTheme,
              let relicID = session.selectedThemeRelicID,
              let selection = try? SharePresentationSelection(
                  codexID: descriptor.codex.id,
                  scriptID: descriptor.codex.primaryScriptID,
                  relicID: relicID,
                  sealID: session.selectedThemeSealID,
                  frameID: session.selectedThemeFrameID
              )
        else { return nil }
        guard let primaryScript = descriptor.codex.scripts.first(where: {
            $0.id == descriptor.codex.primaryScriptID
        }) else { return nil }
        let specimen = primaryScript.glyphs.prefix(12).map(\.textToken).joined()
        guard !specimen.isEmpty else { return nil }
        return try? ThemeArtifactCompositionPolicy.interactivePlan(
            selection: selection,
            inscription: specimen,
            descriptor: descriptor,
            colorMode: usesIncreasedContrast ? .highContrast : .standard,
            reduceMotion: session.effectiveEffectsPreference(
                systemReduceMotion: effectiveReduceMotion
            ) != .full,
            accessibilityLabel: "Rune Scribe appearance defaults preview"
        )
    }

    private func appearanceArtwork(
        _ artifactID: ArtifactID?,
        kind: ThemeArtifactSelectionKind
    ) -> AnyView {
        guard let artifactID,
              let presentation = session.activeThemeVisualPresentation,
              let visual = presentation.plan.catalog.first(where: {
                  $0.id == artifactID && $0.kind == kind.visualKind
              }),
              let image = presentation.imageReference(for: visual.thumbnail)?.image
        else {
            return AnyView(ThemeVisualPlaceholder(
                systemImage: artifactID == nil ? "nosign" : "photo",
                label: artifactID == nil ? "No artifact selected" : "Artwork unavailable"
            ))
        }
        return AnyView(image.resizable().scaledToFit())
    }

    private var appearanceEffectsDetail: String {
        if effectiveReduceMotion && session.appearanceEffectsPreference == .full {
            return "Full is saved; Reduce Motion limits effective behavior to Reduced."
        }
        return "Effective behavior: \(session.effectiveEffectsPreference(systemReduceMotion: effectiveReduceMotion).rawValue.capitalized)."
    }

    private var effectiveReduceMotion: Bool {
        accessibilityReduceMotion || accessibilityPreferences.forcesReduceMotion
    }

    private var usesIncreasedContrast: Bool {
        colorSchemeContrast == .increased
            || accessibilityPreferences.forcesIncreasedContrast
    }

    private var themePresentationVariant: ThemeCaptureIdentifier.PresentationVariant {
        if session.themeSnapshot?.isEmergencyPresentation == true { return .emergency }
        if usesIncreasedContrast { return .highContrast }
        guard themeCaptureIdentifiersEnabled else { return .standard }
        if effectiveReduceMotion { return .reduceMotion }
        if dynamicTypeSize.isAccessibilitySize { return .largeText }
        return .standard
    }

    private var themePresentationAccessibilityValue: String {
        switch themePresentationVariant {
        case .standard: "Standard"
        case .emergency: "Emergency"
        case .highContrast: "High Contrast"
        case .reduceMotion: "Reduce Motion"
        case .largeText: "Large Text"
        }
    }

    private func providerStatus(_ provider: ThemeProviderSummaryDTO) -> String {
        SettingsThemeProviderPresentationPolicy.status(provider)
    }

    private func themeFailureDetails(
        _ failure: RequiredThemeResourceFailureDTO
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(failure.stage.rawValue) · \(failure.errorCode.rawValue)")
                .font(.caption.weight(.bold))
                .foregroundColor(.runeTextPrimary)
            Text("Codex: \(failure.codexID.rawValue)")
            Text("Module: \(failure.moduleID.rawValue)")
            if let resourceID = failure.resourceID {
                Text("Resource: \(resourceID.rawValue)")
            }
            if let mediaType = failure.mediaType {
                Text("Media type: \(mediaType.rawValue)")
            }
            if failure.expectedByteCount != nil || failure.actualByteCount != nil {
                Text(
                    "Bytes — expected: \(failure.expectedByteCount.map(String.init) ?? "n/a"), "
                        + "actual: \(failure.actualByteCount.map(String.init) ?? "n/a")"
                )
            }
            if failure.expectedSHA256 != nil || failure.actualSHA256 != nil {
                Text(
                    "SHA-256 — expected: \(failure.expectedSHA256?.rawValue ?? "n/a"), "
                        + "actual: \(failure.actualSHA256?.rawValue ?? "n/a")"
                )
                    .textSelection(.enabled)
            }
        }
        .font(.caption.monospaced())
        .foregroundColor(.runeSilver)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func providerVisualState(
        _ provider: ThemeProviderSummaryDTO
    ) -> ThemeVisualContentState {
        SettingsThemeProviderPresentationPolicy.visualState(provider)
    }

    private func providerArtwork(_ provider: ThemeProviderSummaryDTO) -> AnyView {
        if let image = session.themeCodexCardImageReferences[provider.codexID]?.image {
            return AnyView(image.resizable().scaledToFit())
        }
        return AnyView(ThemeVisualPlaceholder(
            systemImage: providerIcon(provider),
            label: "\(provider.displayName) artwork unavailable"
        ))
    }

    private func providerIcon(_ provider: ThemeProviderSummaryDTO) -> String {
        SettingsThemeProviderPresentationPolicy.icon(provider)
    }

    // MARK: - Progress and Feedback

    private var progressAndFeedbackPanel: some View {
        RunePanel(title: "Progress & Feedback", systemImage: "medal", accent: .runeGold) {
            VStack(alignment: .leading, spacing: 12) {
                Button { showVaultProgress = true } label: {
                    Label("Open Vault & Progress", systemImage: "archivebox.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())

                Text("Unlock text always remains visible. These switches independently control optional feedback.")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)

                if session.settingsRailState == .unavailable {
                    Label(
                        "Feedback settings are temporarily unavailable. Current defaults remain in effect.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    feedbackToggle(
                        "Sound",
                        systemImage: "speaker.wave.2",
                        settingID: RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled,
                        value: session.unlockFeedbackPreferences.soundEnabled
                    )
                    feedbackToggle(
                        "Haptic",
                        systemImage: "waveform.path",
                        settingID: RuneScribeRuntimeSettings.unlockFeedbackHapticsEnabled,
                        value: session.unlockFeedbackPreferences.hapticEnabled
                    )
                    feedbackToggle(
                        "Animation",
                        systemImage: "sparkles",
                        settingID: RuneScribeRuntimeSettings.unlockFeedbackAnimationEnabled,
                        value: session.unlockFeedbackPreferences.animationEnabled
                    )

                    if session.settingsRailState == .degraded {
                        Label("A setting could not be saved. Try again.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(.runeGoldBright)
                    }
                }
            }
        }
    }

    private func feedbackToggle(
        _ title: String,
        systemImage: String,
        settingID: RuntimeSettingID,
        value: Bool
    ) -> some View {
        Toggle(isOn: Binding(
            get: { value },
            set: { enabled in
                Task {
                    await session.setUnlockFeedbackSetting(settingID, enabled: enabled)
                }
            }
        )) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .foregroundColor(.runeTextPrimary)
        }
        .toggleStyle(.switch)
        .accessibilityHint("Does not hide unlock text")
    }

    // MARK: - Cloud and Game Center

    private var cloudAndGameCenterPanel: some View {
        let presentation = RuntimeExternalServicesSettingsPresentation(
            snapshot: session.cloudGameCenterStatus
        )
        return RunePanel(
            title: "Cloud & Game Center",
            systemImage: "icloud",
            accent: .runeBlue
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cloud sync and Game Center are optional. Rune Scribe keeps local progression usable when either service is unavailable.")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)

                infoRow("iCloud", presentation.cloudStatus)
                Text(presentation.cloudDetail)
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)

                infoRow(
                    "Last successful sync",
                    presentation.cloudLastSuccessfulSyncAt?.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ) ?? "Not yet"
                )
                Text(presentation.cloudDataScopeDetail)
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)

                if let cloudActionTitle = presentation.cloudActionTitle,
                   presentation.cloudAction == .rebindAccount
                {
                    Button {
                        Task { await session.rebindCloudAccount() }
                    } label: {
                        Label(cloudActionTitle, systemImage: "arrow.triangle.2.circlepath.icloud")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())
                    .accessibilityHint(
                        "Keeps local progress and resumes sync with the current iCloud account"
                    )
                }

                Divider().overlay(Color.runeSilver.opacity(0.25))

                infoRow("Game Center", presentation.gameCenterStatus)
                Text(presentation.gameCenterDetail)
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle = presentation.gameCenterActionTitle,
                   let action = presentation.gameCenterAction
                {
                    Button {
                        Task { await session.submitGameCenterParticipation(action) }
                    } label: {
                        Label(actionTitle, systemImage: "trophy.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())
                    .disabled(!presentation.gameCenterActionIsEnabled)
                    .accessibilityHint(
                        action == .optIn
                            ? "Opens Apple Game Center authentication only after you choose this action"
                            : "Stops Rune Scribe mirroring without signing out of Game Center"
                    )
                }

                if let error = session.cloudGameCenterError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundColor(.runeWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - App Lock

    private var appLockPanel: some View {
        RunePanel(title: "App Lock", systemImage: "lock.fill", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.isPINSet
                     ? "A 4-digit PIN is required each time Rune Scribe launches or returns from the background."
                     : "Protect Rune Scribe with a 4-digit PIN, required on launch and when returning from the background.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                infoRow("Status",
                        session.isPINSet ? "PIN set" : "No PIN",
                        color: session.isPINSet ? .runeSuccess : .runeSilver)

                if session.isPINSet {
                    HStack(spacing: 12) {
                        Button { pinFlow = .change } label: {
                            Label("Change PIN", systemImage: "lock.rotation")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneSecondaryButtonStyle())

                        Button(role: .destructive) { pinFlow = .disable } label: {
                            Label("Disable", systemImage: "lock.open")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneSecondaryButtonStyle())
                    }
                } else {
                    Button { pinFlow = .set } label: {
                        Label("Set a PIN…", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneScribButtonStyle())
                }
            }
        }
    }

    // MARK: - Contacts

    private var contactsPanel: some View {
        RunePanel(title: "Contacts", systemImage: "person.2.fill", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Organize your ciphers by contact. Import people from Apple Contacts or add them manually. Contacts stay encrypted on this device.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showContacts = true } label: {
                    Label("Manage Contacts", systemImage: "person.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())
            }
        }
    }

    // MARK: - About

    private var aboutPanel: some View {
        RunePanel(title: "About", systemImage: "info.circle", accent: .runeGold) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Rune Scribe")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.runeTextPrimary)
                    Spacer()
                    Text("v\(appVersion) (\(buildNumber))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.runeSilver)
                }

                Text("A \(AppLicense.company) product.")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.runeGold)

                Text("Rune Scribe turns your messages into private symbolic inscriptions that stay encrypted on your device.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = URL(string: RuneScribeShare.productLink) {
                    Link(destination: url) {
                        Label("ravenforgesoftware.com", systemImage: "globe")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.runeBlue)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Raven Forge Software website")
                }
            }
        }
    }

    // MARK: - License

    private var licensePanel: some View {
        RunePanel(title: "License", systemImage: "doc.text", accent: .runeSilver) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rune Scribe is licensed, not sold. Your use is governed by the End-User License Agreement.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Button { showLicense = true } label: {
                    Label("View License", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())
            }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        session.appVersion
    }

    private var buildNumber: String {
        session.buildNumber
    }

    @ViewBuilder
    private func infoRow(
        _ label: String,
        _ value: String,
        color: Color = .runeTextPrimary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundColor(.runeSilver)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(color)
            Spacer()
        }
    }
}
