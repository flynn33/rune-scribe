import Foundation
import RuneScribeContracts
import SwiftUI

enum ThemeInscriptionLayoutChoice: String, CaseIterable, Identifiable, Sendable {
    case short = "Short"
    case medium = "Medium"
    case long = "Long"

    var id: String { rawValue }

    var guidance: String {
        switch self {
        case .short: "Optimized for concise messages"
        case .medium: "Balanced for everyday messages"
        case .long: "Optimized for longer messages"
        }
    }

    static func recommended(for plan: ThemeArtifactCompositionPlan) -> Self {
        let capacity = max(1, Int(plan.layout.maximumGlyphLines) * 24)
        let glyphCount = plan.pages.first?.inscription.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        } ?? 0
        let occupancy = Double(glyphCount) / Double(capacity)
        if occupancy <= 0.34 { return .short }
        if occupancy <= 0.67 { return .medium }
        return .long
    }
}

enum ThemeInscriptionPreviewControls: Equatable, Sendable {
    case layoutSelection
    case settledResult

    var showsLayoutPicker: Bool { self == .layoutSelection }

    var primaryActionTitle: String {
        switch self {
        case .layoutSelection: "Apply Layout"
        case .settledResult: "Done"
        }
    }
}

enum ReceivedCipherPresentationState: String, Equatable, Sendable {
    case primary
    case shareCard = "share-card"

    var captureIdentifier: String {
        switch self {
        case .primary: ThemeCaptureIdentifier.screenReceivedCipher
        case .shareCard: ThemeCaptureIdentifier.screenShareBuilder
        }
    }

    var accessibilityValue: String {
        switch self {
        case .primary: "Primary received presentation"
        case .shareCard: "Received share card"
        }
    }
}

struct ReceivedCipherPresentationResourcePlan: Equatable, Sendable {
    let primaryResourceIDs: Set<ThemeResourceID>
    let shareCardResourceIDs: Set<ThemeResourceID>

    init?(_ descriptor: ThemeDescriptor) {
        guard let presentation = descriptor.codex.receivedPresentation else {
            return nil
        }
        primaryResourceIDs = [
            presentation.primarySenderAvatarResourceID,
            presentation.primaryMedallion.resourceID,
        ]
        shareCardResourceIDs = [
            presentation.shareSenderAvatarResourceID,
            presentation.shareCodexBadgeResourceID,
            presentation.shareMedallion.resourceID,
        ]
    }

    func resourceIDs(
        for state: ReceivedCipherPresentationState
    ) -> Set<ThemeResourceID> {
        switch state {
        case .primary:
            primaryResourceIDs
        case .shareCard:
            shareCardResourceIDs
        }
    }

    var allResourceIDs: Set<ThemeResourceID> {
        primaryResourceIDs.union(shareCardResourceIDs)
    }
}

struct ReceivedCipherPresentationContent: Equatable, Sendable {
    let state: ReceivedCipherPresentationState
    let descriptor: ThemeDescriptor
    let plan: ThemeArtifactCompositionPlan
    let identityResources: ReceivedCipherPresentationResourcePlan

    var requiredImageResourceIDs: Set<ThemeResourceID> {
        plan.requiredImageResourceIDs.union(
            identityResources.resourceIDs(for: state)
        )
    }

    static func resolve(
        state: ReceivedCipherPresentationState,
        pending: PendingMessageViewState,
        descriptor: ThemeDescriptor,
        reduceMotion: Bool = false
    ) throws -> Self? {
        guard pending.senderIdentityStatus != .awaitingCipherConfirmation,
              let received = pending.presentation,
              received.providerAvailability == .available,
              received.renderMode == .requestedCodex,
              let selection = received.effectiveSelection,
              selection.codexID == descriptor.codex.id,
              let identityResources = ReceivedCipherPresentationResourcePlan(
                  descriptor
              )
        else { return nil }

        let plan = try ThemeArtifactCompositionPolicy.interactivePlan(
            selection: selection,
            inscription: pending.plaintext,
            descriptor: descriptor,
            colorMode: .standard,
            reduceMotion: reduceMotion,
            accessibilityLabel: "Received \(descriptor.codex.displayName.fallbackValue) inscription",
            provenanceLabel: "Incoming presentation"
        )
        return Self(
            state: state,
            descriptor: descriptor,
            plan: plan,
            identityResources: identityResources
        )
    }
}

@MainActor
struct ReceivedCipherPresentationBinding {
    let content: ReceivedCipherPresentationContent
    let pending: PendingMessageViewState
    let receivedAt: Date
    let relativeDate: Date
    let presentation: ActiveThemeVisualPresentation

    init?(
        content: ReceivedCipherPresentationContent,
        pending: PendingMessageViewState,
        receivedAt: Date,
        relativeDate: Date,
        presentation: ActiveThemeVisualPresentation
    ) {
        guard content.descriptor.codex.id == presentation.plan.codexID,
              content.plan.selection.codexID == presentation.plan.codexID,
              content.requiredImageResourceIDs.allSatisfy({
                  presentation.image(for: $0) != nil
              })
        else { return nil }
        self.content = content
        self.pending = pending
        self.receivedAt = receivedAt
        self.relativeDate = relativeDate
        self.presentation = presentation
    }

    func requiredImage(_ resourceID: ThemeResourceID) -> Image {
        guard content.requiredImageResourceIDs.contains(resourceID),
              let image = presentation.image(for: resourceID)
        else {
            preconditionFailure("Required received Theme resource was not prepared.")
        }
        return image
    }
}

struct ReceivedCipherPresentationStyle: Equatable, Sendable {
    let plaintextPointSize: Double

    static func style(for state: ReceivedCipherPresentationState) -> Self {
        switch state {
        case .primary:
            Self(plaintextPointSize: 40)
        case .shareCard:
            Self(plaintextPointSize: 42)
        }
    }
}

struct ThemePresentationSelectionSummary: Equatable, Sendable {
    let codexName: String
    let receivedCodexName: String
    let scriptName: String
    let relicName: String
    let sealName: String?
    let frameName: String?

    init(descriptor: ThemeDescriptor, plan: ThemeArtifactCompositionPlan) {
        let codex = descriptor.codex
        codexName = codex.displayName.fallbackValue
        receivedCodexName = codex.receivedPresentation?.familyDisplayName.fallbackValue
            ?? Self.receivedCodexName(
                codexName: codex.displayName.fallbackValue,
                vaultGrouping: codex.vault.grouping.fallbackValue
            )
        scriptName = codex.scripts.first(where: { $0.id == plan.selection.scriptID })?
            .displayName.fallbackValue ?? plan.selection.scriptID.rawValue
        relicName = codex.relics.first(where: { $0.metadata.id == plan.selection.relicID })?
            .metadata.displayName.fallbackValue ?? plan.selection.relicID.rawValue
        sealName = plan.selection.sealID.map { sealID in
            codex.seals.first(where: { $0.metadata.id == sealID })?
                .metadata.displayName.fallbackValue ?? sealID.rawValue
        }
        frameName = plan.selection.frameID.map { frameID in
            codex.frames.first(where: { $0.metadata.id == frameID })?
            .metadata.displayName.fallbackValue ?? frameID.rawValue
        }
    }

    static func receivedCodexName(
        codexName: String,
        vaultGrouping: String
    ) -> String {
        let grouping = vaultGrouping.trimmingCharacters(in: .whitespacesAndNewlines)
        let seriesSuffix = " Series"
        guard grouping.hasSuffix(seriesSuffix) else { return codexName }
        let family = grouping.dropLast(seriesSuffix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty else { return codexName }
        return "\(family) Codex"
    }
}

enum ReceivedCipherTimestampFormatter {
    static func string(
        receivedAt: Date,
        relativeTo now: Date,
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = localCalendar
        formatter.timeZone = timeZone
        if localCalendar.isDate(receivedAt, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
            return "Received Today at \(formatter.string(from: receivedAt))"
        }
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return "Received \(formatter.string(from: receivedAt))"
    }
}

struct ThemePresentationScreenMetrics {
    static let referenceSize = CGSize(width: 941, height: 1672)
    static let minimumInteractiveDimension: CGFloat = 44

    let size: CGSize
    let scale: CGFloat
    let dynamicTypeScale: CGFloat
    let usesAccessibleLayout: Bool

    init(
        size: CGSize,
        dynamicTypeScale: CGFloat = 1,
        usesAccessibleLayout: Bool = false
    ) {
        self.size = size
        scale = max(
            0.36,
            min(
                size.width / Self.referenceSize.width,
                size.height / Self.referenceSize.height
            )
        )
        self.dynamicTypeScale = max(1, dynamicTypeScale)
        self.usesAccessibleLayout = usesAccessibleLayout
    }

    func fontSize(_ referencePointSize: CGFloat) -> CGFloat {
        referencePointSize * scale * dynamicTypeScale
    }

    func interactiveDimension(_ referenceDimension: CGFloat) -> CGFloat {
        max(Self.minimumInteractiveDimension, referenceDimension * scale)
    }

    var horizontalPadding: CGFloat { 32 * scale }
    var contentWidth: CGFloat { max(1, size.width - horizontalPadding * 2) }
    var headerHeight: CGFloat {
        let canonicalHeight = 142 * scale
        guard usesAccessibleLayout else { return canonicalHeight }
        return max(
            canonicalHeight,
            fontSize(24) * 1.25 + fontSize(46) * 1.35 + 7 * scale
        )
    }
    var headerButtonSize: CGFloat { interactiveDimension(76) }
    var cornerRadius: CGFloat { 24 * scale }
    var rowHeight: CGFloat {
        let canonicalHeight = 105 * scale
        guard usesAccessibleLayout else { return canonicalHeight }
        return max(canonicalHeight, fontSize(28) * 2.8)
    }
    var canonicalWidth: CGFloat { min(size.width, Self.referenceSize.width * scale) }
    var inscriptionCanvasHeight: CGFloat { canonicalWidth * 2 / 3 }
    var receivedCanvasWidth: CGFloat {
        max(1, size.width - (horizontalPadding + 16 * scale) * 2)
    }
    var receivedCanvasHeight: CGFloat { receivedCanvasWidth * 2 / 3 }
    var shareCardCanvasHeight: CGFloat { contentWidth * 2 / 3 + 40 * scale }
    var primaryActionHeight: CGFloat {
        let minimumHeight = interactiveDimension(112)
        guard usesAccessibleLayout else { return minimumHeight }
        return max(minimumHeight, fontSize(40) * 1.6)
    }
    var layoutChoiceHeight: CGFloat {
        let minimumHeight = interactiveDimension(82)
        guard usesAccessibleLayout else { return minimumHeight }
        return max(minimumHeight, fontSize(29) * 1.7)
    }
    var layoutPickerHeight: CGFloat {
        usesAccessibleLayout
            ? layoutChoiceHeight * CGFloat(ThemeInscriptionLayoutChoice.allCases.count)
                + CGFloat(ThemeInscriptionLayoutChoice.allCases.count - 1)
            : layoutChoiceHeight
    }
    var receivedPrimaryActionHeight: CGFloat {
        receivedActionHeight(referenceHeight: 112)
    }
    var receivedShareCardActionHeight: CGFloat {
        receivedActionHeight(referenceHeight: 104)
    }
    var receivedActionSpacing: CGFloat { 18 * scale }
    var usesStackedControls: Bool { usesAccessibleLayout }

    func receivedActionRowHeight(for state: ReceivedCipherPresentationState) -> CGFloat {
        let actionHeight = switch state {
        case .primary: receivedPrimaryActionHeight
        case .shareCard: receivedShareCardActionHeight
        }
        guard usesStackedControls else { return actionHeight }
        return actionHeight * 3 + receivedActionSpacing * 2
    }

    private func receivedActionHeight(referenceHeight: CGFloat) -> CGFloat {
        let minimumHeight = interactiveDimension(referenceHeight)
        guard usesAccessibleLayout else { return minimumHeight }
        return max(minimumHeight, fontSize(30) * 1.7)
    }
}

private struct ThemePresentationScreenHeader: View {
    let title: String
    let metrics: ThemePresentationScreenMetrics
    let backAction: () -> Void
    let libraryAction: () -> Void

    var body: some View {
        HStack(spacing: 10 * metrics.scale) {
            circularButton(
                systemImage: "arrow.left",
                accessibilityLabel: "Back",
                action: backAction
            )

            VStack(spacing: 7 * metrics.scale) {
                Text("Rune Scribe")
                    .font(.system(
                        size: metrics.fontSize(24),
                        weight: .regular,
                        design: .serif
                    ))
                    .foregroundStyle(Color.runeSilver)
                Text(title)
                    .font(.system(
                        size: metrics.fontSize(46),
                        weight: .regular,
                        design: .serif
                    ))
                    .minimumScaleFactor(0.72)
                    .lineLimit(metrics.usesAccessibleLayout ? 2 : 1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.runeTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            circularButton(
                systemImage: "book",
                accessibilityLabel: "Open Codex",
                action: libraryAction
            )
        }
        .frame(height: metrics.headerHeight)
        .padding(.horizontal, metrics.horizontalPadding)
    }

    private func circularButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.fontSize(28), weight: .light))
                .foregroundStyle(Color.runeTextPrimary)
                .frame(width: metrics.headerButtonSize, height: metrics.headerButtonSize)
                .background(Circle().fill(Color.runeNavy.opacity(0.58)))
                .overlay {
                    Circle().strokeBorder(Color.runeGold.opacity(0.56), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ThemePresentationMetadataRow: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let systemImage: String
}

private struct ThemePresentationDetailRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
}

private struct ThemePresentationMetadataPanel: View {
    let rows: [ThemePresentationMetadataRow]
    let metrics: ThemePresentationScreenMetrics
    var showsDisclosure = false
    var encirclesIcons = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                metadataRow(row)
                .frame(minHeight: metrics.rowHeight)
                .frame(height: metrics.usesAccessibleLayout ? nil : metrics.rowHeight)
                .padding(.vertical, metrics.usesAccessibleLayout ? 8 * metrics.scale : 0)
                .padding(.horizontal, 28 * metrics.scale)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.title)
                .accessibilityValue(row.value)

                if index < rows.count - 1 {
                    Rectangle()
                        .fill(Color.runeSilver.opacity(0.20))
                        .frame(height: 1)
                        .padding(.leading, 92 * metrics.scale)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(Color.runeNavy.opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.runeGold.opacity(0.34), lineWidth: 1)
        }
        .overlay {
            ThemeChromeImage(slot: .panelBorder)
                .opacity(0.04)
                .clipShape(RoundedRectangle(
                    cornerRadius: metrics.cornerRadius,
                    style: .continuous
                ))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func metadataRow(_ row: ThemePresentationMetadataRow) -> some View {
        if metrics.usesAccessibleLayout {
            HStack(alignment: .top, spacing: 18 * metrics.scale) {
                metadataIcon(row.systemImage)
                VStack(alignment: .leading, spacing: 4 * metrics.scale) {
                    metadataTitle(row.title)
                    metadataValue(row.value, lineLimit: nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                disclosureIndicator
            }
        } else {
            HStack(spacing: 18 * metrics.scale) {
                metadataIcon(row.systemImage)
                metadataTitle(row.title)
                Spacer(minLength: 10 * metrics.scale)
                metadataValue(row.value, lineLimit: 1)
                disclosureIndicator
            }
        }
    }

    private func metadataTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(
                size: metrics.fontSize(28),
                weight: .regular,
                design: .serif
            ))
            .foregroundStyle(Color.runeTextPrimary)
    }

    private func metadataValue(_ value: String, lineLimit: Int?) -> some View {
        Text(value)
            .font(.system(
                size: metrics.fontSize(27),
                weight: .regular,
                design: .serif
            ))
            .foregroundStyle(Color.runeSilver)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.68)
            .fixedSize(horizontal: false, vertical: metrics.usesAccessibleLayout)
    }

    @ViewBuilder
    private var disclosureIndicator: some View {
        if showsDisclosure {
            Image(systemName: "chevron.right")
                .font(.system(size: metrics.fontSize(20), weight: .medium))
                .foregroundStyle(Color.runeSilver)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func metadataIcon(_ systemImage: String) -> some View {
        if encirclesIcons {
            Image(systemName: systemImage)
                .font(.system(size: metrics.fontSize(25), weight: .regular))
                .foregroundStyle(Color.runeGold)
                .frame(width: 58 * metrics.scale, height: 58 * metrics.scale)
                .background(Circle().fill(Color.runeNavy.opacity(0.72)))
                .overlay {
                    Circle().strokeBorder(Color.runeAccentSecondary.opacity(0.52), lineWidth: 1)
                }
                .accessibilityHidden(true)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: metrics.fontSize(25), weight: .regular))
                .foregroundStyle(Color.runeGold)
                .frame(width: 42 * metrics.scale)
                .accessibilityHidden(true)
        }
    }
}

private struct ThemePresentationPrimaryButton: View {
    let title: String
    let systemImage: String
    let metrics: ThemePresentationScreenMetrics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 22 * metrics.scale) {
                Image(systemName: systemImage)
                    .font(.system(size: metrics.fontSize(30), weight: .regular))
                Text(title)
                    .font(.system(
                        size: metrics.fontSize(40),
                        weight: .regular,
                        design: .serif
                    ))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.runeTextPrimary)
            .frame(
                maxWidth: .infinity,
                minHeight: ThemePresentationScreenMetrics.minimumInteractiveDimension,
                maxHeight: .infinity
            )
            .background {
                ZStack {
                    Color.runeBackgroundSecondary.opacity(0.94)
                    Color.runeGold.opacity(0.18)
                    ThemeChromeImage(slot: .primaryButton)
                        .opacity(0.92)
                }
                .clipShape(Capsule())
            }
            .overlay {
                Capsule().strokeBorder(Color.runeGold.opacity(0.72), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: ThemePresentationScreenMetrics.minimumInteractiveDimension,
            minHeight: ThemePresentationScreenMetrics.minimumInteractiveDimension
        )
    }
}

struct ThemeInscriptionPreviewView: View {
    let descriptor: ThemeDescriptor
    let plan: ThemeArtifactCompositionPlan
    let selectedLayout: ThemeInscriptionLayoutChoice
    let image: (ThemeResourceID) -> Image
    var controls: ThemeInscriptionPreviewControls = .layoutSelection
    var backAction: () -> Void = {}
    var libraryAction: () -> Void = {}
    var selectLayout: (ThemeInscriptionLayoutChoice) -> Void = { _ in }
    var applyLayout: () -> Void = {}

    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var summary: ThemePresentationSelectionSummary {
        ThemePresentationSelectionSummary(descriptor: descriptor, plan: plan)
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ThemePresentationScreenMetrics(
                size: geometry.size,
                dynamicTypeScale: dynamicTypeScale,
                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize
            )
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ThemePresentationScreenHeader(
                        title: "Inscription Preview",
                        metrics: metrics,
                        backAction: backAction,
                        libraryAction: libraryAction
                    )

                    ThemeArtifactPreview(
                        plan: plan,
                        maximumCanvasWidth: metrics.canonicalWidth,
                        image: { image($0) }
                    )
                    .frame(
                        width: metrics.canonicalWidth,
                        height: metrics.inscriptionCanvasHeight
                    )
                    .padding(.top, 56 * metrics.scale)
                    .themeCaptureIdentifier(
                        ThemeCaptureIdentifier.artifactPreview(
                            relicID: plan.selection.relicID
                        )
                    )

                    ThemePresentationMetadataPanel(
                        rows: inscriptionRows,
                        metrics: metrics,
                        encirclesIcons: true
                    )
                    .padding(.horizontal, metrics.horizontalPadding + 48 * metrics.scale)
                    .padding(.top, 49 * metrics.scale)

                    if controls.showsLayoutPicker {
                        layoutPicker(metrics: metrics)
                            .padding(.horizontal, metrics.horizontalPadding + 48 * metrics.scale)
                            .padding(.top, 38 * metrics.scale)
                    }

                    HStack(spacing: 14 * metrics.scale) {
                        Image(systemName: "leaf")
                        Text(selectedLayout.guidance)
                        Image(systemName: "leaf")
                            .scaleEffect(x: -1, y: 1)
                    }
                    .font(.system(
                        size: metrics.fontSize(28),
                        weight: .regular,
                        design: .serif
                    ))
                    .foregroundStyle(Color.runeSilver)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: metrics.usesAccessibleLayout)
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, 30 * metrics.scale)

                    ThemePresentationPrimaryButton(
                        title: controls.primaryActionTitle,
                        systemImage: controls == .layoutSelection
                            ? "wand.and.stars" : "checkmark",
                        metrics: metrics,
                        action: applyLayout
                    )
                    .frame(height: metrics.primaryActionHeight)
                    .padding(.horizontal, metrics.horizontalPadding + 43 * metrics.scale)
                    .padding(.top, 48 * metrics.scale)
                    .padding(.bottom, 52 * metrics.scale)
                    .accessibilityIdentifier("inscription-preview.apply-layout")
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("inscription-preview.presentation")
    }

    private var inscriptionRows: [ThemePresentationMetadataRow] {
        [
            ThemePresentationMetadataRow(
                id: "relic",
                title: "Relic:",
                value: summary.relicName,
                systemImage: "leaf"
            ),
            ThemePresentationMetadataRow(
                id: "layout",
                title: "Layout:",
                value: "\(selectedLayout.rawValue) Message",
                systemImage: "list.bullet"
            ),
            ThemePresentationMetadataRow(
                id: "seal",
                title: "Seal:",
                value: summary.sealName ?? "None",
                systemImage: "moon.stars"
            ),
        ]
    }

    private func layoutPicker(metrics: ThemePresentationScreenMetrics) -> some View {
        Group {
            if metrics.usesStackedControls {
                VStack(spacing: 0) {
                    ForEach(ThemeInscriptionLayoutChoice.allCases) { choice in
                        layoutChoiceButton(choice, metrics: metrics)
                            .frame(height: metrics.layoutChoiceHeight)
                        if choice != ThemeInscriptionLayoutChoice.allCases.last {
                            Rectangle()
                                .fill(Color.runeGold.opacity(0.26))
                                .frame(height: 1)
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(ThemeInscriptionLayoutChoice.allCases) { choice in
                        layoutChoiceButton(choice, metrics: metrics)
                        if choice != ThemeInscriptionLayoutChoice.allCases.last {
                            Rectangle()
                                .fill(Color.runeGold.opacity(0.26))
                                .frame(width: 1)
                                .padding(.vertical, 8 * metrics.scale)
                        }
                    }
                }
            }
        }
        .frame(height: metrics.layoutPickerHeight)
        .padding(4 * metrics.scale)
        .background(Capsule().fill(Color.runeNavy.opacity(0.76)))
        .overlay {
            Capsule().strokeBorder(Color.runeGold.opacity(0.34), lineWidth: 1)
        }
        .overlay {
            ThemeChromeImage(slot: .tabSelector)
                .opacity(0.48)
                .clipShape(Capsule())
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inscription layout")
    }

    private func layoutChoiceButton(
        _ choice: ThemeInscriptionLayoutChoice,
        metrics: ThemePresentationScreenMetrics
    ) -> some View {
        Button { selectLayout(choice) } label: {
            Text(choice.rawValue)
                .font(.system(
                    size: metrics.fontSize(29),
                    weight: choice == selectedLayout ? .semibold : .regular,
                    design: .serif
                ))
                .foregroundStyle(
                    choice == selectedLayout
                        ? Color.runeTextPrimary : Color.runeSilver
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if choice == selectedLayout {
                        Capsule()
                            .fill(Color.runeAccentSecondary.opacity(0.34))
                            .overlay {
                                Capsule().strokeBorder(
                                    Color.runeAccentSecondary.opacity(0.88),
                                    lineWidth: 1
                                )
                            }
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: ThemePresentationScreenMetrics.minimumInteractiveDimension,
            minHeight: ThemePresentationScreenMetrics.minimumInteractiveDimension
        )
        .accessibilityAddTraits(choice == selectedLayout ? .isSelected : [])
        .accessibilityValue(choice == selectedLayout ? "Selected" : "Not selected")
    }
}

enum ReceivedCipherDecodeActionPolicy {
    static let isEnabled = false
    static let accessibilityValue = "Already decoded"
    static let accessibilityHint = "No further decoding is needed."
}

enum ReceivedCipherCompletionActionPolicy {
    static let title = "Done"
    static let systemImage = "checkmark"
    static let accessibilityHint =
        "Closes this message and clears it from pending messages."
}

struct ReceivedCipherPresentationView: View {
    let state: ReceivedCipherPresentationState
    let pending: PendingMessageViewState
    let receivedAt: Date
    let relativeDate: Date
    let descriptor: ThemeDescriptor
    let plan: ThemeArtifactCompositionPlan
    let image: (ThemeResourceID) -> Image
    var backAction: () -> Void = {}
    var libraryAction: () -> Void = {}
    var doneAction: () -> Void = {}
    var replyAction: () -> Void = {}

    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    private var summary: ThemePresentationSelectionSummary {
        ThemePresentationSelectionSummary(descriptor: descriptor, plan: plan)
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ThemePresentationScreenMetrics(
                size: geometry.size,
                dynamicTypeScale: dynamicTypeScale,
                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize
            )
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ThemePresentationScreenHeader(
                        title: "Received Cipher",
                        metrics: metrics,
                        backAction: backAction,
                        libraryAction: libraryAction
                    )

                    senderCard(metrics: metrics)
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.top, senderTopPadding(metrics))

                    receivedPreview(metrics: metrics)
                        .padding(.horizontal, previewHorizontalPadding(metrics))
                        .padding(.top, previewTopPadding(metrics))

                    receivedMetadata(metrics: metrics)
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.top, metadataTopPadding(metrics))

                    if state == .shareCard {
                        Text(receivedTimestamp)
                            .font(.system(
                                size: metrics.fontSize(21),
                                weight: .regular,
                                design: .serif
                            ))
                            .foregroundStyle(Color.runeSilver)
                            .padding(.top, 25 * metrics.scale)
                    }

                    actionRow(metrics: metrics)
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.top, actionTopPadding(metrics))
                        .padding(.bottom, 46 * metrics.scale)
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Received Cipher")
        .accessibilityValue(state.accessibilityValue)
        .themeCaptureViewportIdentifier(state.captureIdentifier)
    }

    private var receivedRows: [ThemePresentationMetadataRow] {
        [
            ThemePresentationMetadataRow(
                id: "cipher",
                title: "Cipher",
                value: pending.cipherName,
                systemImage: "hexagon"
            ),
            ThemePresentationMetadataRow(
                id: "codex",
                title: "Codex",
                value: summary.receivedCodexName,
                systemImage: "book"
            ),
            ThemePresentationMetadataRow(
                id: "font",
                title: scriptMetadataTitle,
                value: summary.scriptName,
                systemImage: "character"
            ),
        ]
    }

    private var receivedDetailRows: [ThemePresentationDetailRow] {
        [
            ThemePresentationDetailRow(
                id: "cipher",
                title: "Cipher",
                detail: pending.cipherName,
                systemImage: "cube.transparent"
            ),
            ThemePresentationDetailRow(
                id: "codex",
                title: "Codex",
                detail: summary.receivedCodexName,
                systemImage: "book"
            ),
            ThemePresentationDetailRow(
                id: "font",
                title: scriptMetadataTitle,
                detail: summary.scriptName,
                systemImage: "character"
            ),
        ]
    }

    private var receivedTimestamp: String {
        ReceivedCipherTimestampFormatter.string(
            receivedAt: receivedAt,
            relativeTo: relativeDate,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )
    }

    private var senderAvatarResourceID: ThemeResourceID? {
        if let presentation = descriptor.codex.receivedPresentation {
            switch state {
            case .primary:
                return presentation.primarySenderAvatarResourceID
            case .shareCard:
                return presentation.shareSenderAvatarResourceID
            }
        }
        guard let sealID = plan.selection.sealID,
              let seal = descriptor.codex.seals.first(where: {
                  $0.metadata.id == sealID
              })
        else { return plan.sealResourceID }
        return seal.thumbnailResourceID
    }

    private var shareCodexBadgeResourceID: ThemeResourceID? {
        guard state == .shareCard else { return nil }
        return descriptor.codex.receivedPresentation?.shareCodexBadgeResourceID
    }

    private var receivedMedallion: ThemeReceivedMedallionDescriptor? {
        guard let presentation = descriptor.codex.receivedPresentation else { return nil }
        switch state {
        case .primary:
            return presentation.primaryMedallion
        case .shareCard:
            return presentation.shareMedallion
        }
    }

    @ViewBuilder
    private func receivedMetadata(metrics: ThemePresentationScreenMetrics) -> some View {
        switch state {
        case .primary:
            ThemePresentationMetadataPanel(
                rows: receivedRows,
                metrics: metrics,
                showsDisclosure: false
            )
        case .shareCard:
            shareCardMetadataPanel(metrics: metrics)
        }
    }

    private func shareCardMetadataPanel(
        metrics: ThemePresentationScreenMetrics
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(receivedDetailRows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 18 * metrics.scale) {
                    shareCardMetadataIcon(row: row, metrics: metrics)

                    VStack(alignment: .leading, spacing: 2 * metrics.scale) {
                        Text(row.title)
                            .font(.system(
                                size: metrics.fontSize(27),
                                weight: .regular,
                                design: .serif
                            ))
                            .foregroundStyle(Color.runeTextPrimary)
                        Text(row.detail)
                            .font(.system(
                                size: metrics.fontSize(23),
                                weight: .regular,
                                design: .serif
                            ))
                            .foregroundStyle(Color.runeGold)
                            .lineLimit(metrics.usesAccessibleLayout ? nil : 1)
                            .minimumScaleFactor(0.72)
                            .fixedSize(
                                horizontal: false,
                                vertical: metrics.usesAccessibleLayout
                            )
                    }

                    Spacer(minLength: 12 * metrics.scale)
                }
                .frame(
                    minHeight: metrics.usesAccessibleLayout
                        ? metrics.rowHeight : 100 * metrics.scale
                )
                .frame(height: metrics.usesAccessibleLayout ? nil : 100 * metrics.scale)
                .padding(.vertical, metrics.usesAccessibleLayout ? 8 * metrics.scale : 0)
                .padding(.horizontal, 24 * metrics.scale)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.title)
                .accessibilityValue(row.detail)

                if index < receivedDetailRows.count - 1 {
                    Rectangle()
                        .fill(Color.runeSilver.opacity(0.20))
                        .frame(height: 1)
                        .padding(.leading, 92 * metrics.scale)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(Color.runeNavy.opacity(0.84))
        }
        .overlay {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.runeAccentSecondary.opacity(0.34), lineWidth: 1)
        }
        .overlay {
            ThemeChromeImage(slot: .panelBorder)
                .opacity(0.035)
                .clipShape(RoundedRectangle(
                    cornerRadius: metrics.cornerRadius,
                    style: .continuous
                ))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func shareCardMetadataIcon(
        row: ThemePresentationDetailRow,
        metrics: ThemePresentationScreenMetrics
    ) -> some View {
        if row.id == "codex", let senderAvatarResourceID {
            image(senderAvatarResourceID)
                .resizable()
                .scaledToFill()
                .frame(width: 54 * metrics.scale, height: 54 * metrics.scale)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(Color.runeAccentSecondary.opacity(0.50), lineWidth: 1)
                }
                .accessibilityHidden(true)
        } else {
            Image(systemName: row.systemImage)
                .font(.system(size: metrics.fontSize(28), weight: .light))
                .foregroundStyle(Color.runeAccentSecondary)
                .frame(width: 54 * metrics.scale, height: 54 * metrics.scale)
                .accessibilityHidden(true)
        }
    }

    private func senderCard(metrics: ThemePresentationScreenMetrics) -> some View {
        let layout = metrics.usesAccessibleLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12 * metrics.scale))
            : AnyLayout(HStackLayout(spacing: 24 * metrics.scale))
        let canonicalHeight = state == .primary ? 148 * metrics.scale : 150 * metrics.scale
        return layout {
            senderAvatar(metrics: metrics)
            senderIdentity(metrics: metrics)
            senderCodexBadge(metrics: metrics)
        }
        .padding(.horizontal, 26 * metrics.scale)
        .padding(.vertical, metrics.usesAccessibleLayout ? 16 * metrics.scale : 0)
        .frame(minHeight: canonicalHeight)
        .frame(height: metrics.usesAccessibleLayout ? nil : canonicalHeight)
        .background {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(Color.runeNavy.opacity(0.74))
        }
        .overlay {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.runeGold.opacity(0.32), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From \(pending.senderName)")
        .accessibilityValue(summary.receivedCodexName)
    }

    private func senderAvatar(metrics: ThemePresentationScreenMetrics) -> some View {
        ZStack {
            Circle().fill(Color.runeNavy.opacity(0.72))
            if let senderAvatarResourceID {
                image(senderAvatarResourceID)
                    .resizable()
                    .scaledToFit()
                    .padding(
                        descriptor.codex.receivedPresentation == nil
                            ? 7 * metrics.scale
                            : 0
                    )
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: metrics.fontSize(45), weight: .light))
                    .foregroundStyle(Color.runeGold)
            }
        }
        .frame(
            width: senderAvatarDiameter(metrics),
            height: senderAvatarDiameter(metrics)
        )
        .overlay { Circle().strokeBorder(Color.runeGold.opacity(0.52), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private func senderIdentity(metrics: ThemePresentationScreenMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4 * metrics.scale) {
            Text(state == .primary ? "From" : "FROM")
                .font(.system(size: metrics.fontSize(18), weight: .medium, design: .rounded))
                .tracking(1.4 * metrics.scale)
                .foregroundStyle(Color.runeSilver)
            Text(pending.senderName)
                .font(.system(size: metrics.fontSize(39), weight: .regular, design: .serif))
                .lineLimit(metrics.usesAccessibleLayout ? nil : 1)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: metrics.usesAccessibleLayout)
                .foregroundStyle(Color.runeTextPrimary)
            if state == .shareCard {
                Text(relativeSenderTime)
                    .font(.system(size: metrics.fontSize(21), design: .serif))
                    .foregroundStyle(Color.runeAccentSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func senderCodexBadge(metrics: ThemePresentationScreenMetrics) -> some View {
        HStack(spacing: 9 * metrics.scale) {
            if let shareCodexBadgeResourceID {
                image(shareCodexBadgeResourceID)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36 * metrics.scale, height: 36 * metrics.scale)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "leaf")
                    .accessibilityHidden(true)
            }
            Text(summary.receivedCodexName)
                .lineLimit(metrics.usesAccessibleLayout ? nil : 1)
                .minimumScaleFactor(0.68)
                .fixedSize(horizontal: false, vertical: metrics.usesAccessibleLayout)
        }
        .font(.system(size: metrics.fontSize(25), weight: .regular, design: .serif))
        .foregroundStyle(Color.runeSilver)
        .padding(.horizontal, 24 * metrics.scale)
        .frame(minHeight: 58 * metrics.scale)
        .frame(height: metrics.usesAccessibleLayout ? nil : 58 * metrics.scale)
        .background(Capsule().fill(Color.runeAccentSecondary.opacity(0.16)))
        .overlay {
            Capsule().strokeBorder(Color.runeAccentSecondary.opacity(0.48), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func receivedPreview(metrics: ThemePresentationScreenMetrics) -> some View {
        switch state {
        case .primary:
            VStack(alignment: .leading, spacing: 12 * metrics.scale) {
                HStack(spacing: 14 * metrics.scale) {
                    Image(systemName: "leaf")
                        .foregroundStyle(Color.runeGold)
                    Text("Message Preview")
                        .font(.system(size: metrics.fontSize(37), design: .serif))
                        .foregroundStyle(Color.runeAccentSecondary)
                    Rectangle()
                        .fill(Color.runeGold.opacity(0.26))
                        .frame(height: 1)
                }
                .padding(.horizontal, metrics.horizontalPadding + 16 * metrics.scale)
                artifactCanvas(metrics: metrics, height: metrics.inscriptionCanvasHeight)
                accessiblePlaintext(metrics: metrics)
            }
        case .shareCard:
            VStack(alignment: .leading, spacing: 8 * metrics.scale) {
                Text("MESSAGE PREVIEW")
                    .font(.system(
                        size: metrics.fontSize(18),
                        weight: .medium,
                        design: .rounded
                    ))
                    .tracking(1.2 * metrics.scale)
                    .foregroundStyle(Color.runeSilver)
                    .padding(.horizontal, 24 * metrics.scale)
                    .padding(.top, 22 * metrics.scale)
                artifactCanvas(metrics: metrics, height: metrics.shareCardCanvasHeight)
                    .padding(.bottom, 16 * metrics.scale)
                accessiblePlaintext(metrics: metrics)
                    .padding(.bottom, 16 * metrics.scale)
            }
            .background {
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(Color.runeNavy.opacity(0.54))
            }
            .overlay {
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.runeGold.opacity(0.34), lineWidth: 1)
            }
        }
    }

    private func artifactCanvas(
        metrics: ThemePresentationScreenMetrics,
        height: CGFloat
    ) -> some View {
        return ZStack {
            if let page = plan.pages.first {
                ThemeArtifactCanvas(
                    plan: plan,
                    page: page,
                    context: .receivedPreview,
                    sealResourceIDOverride: receivedMedallion?.resourceID,
                    sealAnchorOverride: receivedMedallion?.anchor,
                    sealScaleOverride: receivedMedallion?.scale,
                    image: image
                )
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Message preview")
        .accessibilityValue(
            metrics.usesAccessibleLayout
                ? plan.inscription
                : "\(pending.plaintext). \(plan.inscription)"
        )
        .themeCaptureIdentifier(
            ThemeCaptureIdentifier.receivedArtifactPreview(
                relicID: plan.selection.relicID
            )
        )
    }

    @ViewBuilder
    private func accessiblePlaintext(metrics: ThemePresentationScreenMetrics) -> some View {
        let style = ReceivedCipherPresentationStyle.style(for: state)
        Text(pending.plaintext)
            .font(.system(
                size: metrics.fontSize(CGFloat(style.plaintextPointSize)),
                weight: .regular,
                design: .rounded
            ))
            .textSelection(.enabled)
            .foregroundStyle(Color.runeTextPrimary)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(max(12, 24 * metrics.scale))
            .background {
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(Color.runeNavy.opacity(0.84))
            }
            .overlay {
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.runeGold.opacity(0.34), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Decoded message")
            .accessibilityValue(pending.plaintext)
    }

    @ViewBuilder
    private func actionRow(metrics: ThemePresentationScreenMetrics) -> some View {
        let actionHeight = state == .primary
            ? metrics.receivedPrimaryActionHeight
            : metrics.receivedShareCardActionHeight
        if metrics.usesStackedControls {
            VStack(spacing: metrics.receivedActionSpacing) {
                decodeButton(metrics: metrics)
                    .frame(height: actionHeight)
                doneButton(metrics: metrics)
                    .frame(height: actionHeight)
                replyButton(metrics: metrics)
                    .frame(height: actionHeight)
            }
            .frame(height: metrics.receivedActionRowHeight(for: state))
        } else {
            HStack(spacing: metrics.receivedActionSpacing) {
                decodeButton(metrics: metrics)
                doneButton(metrics: metrics)
                    .frame(width: max(
                        ThemePresentationScreenMetrics.minimumInteractiveDimension,
                        340 * metrics.scale
                    ))
                replyButton(metrics: metrics)
            }
            .frame(height: metrics.receivedActionRowHeight(for: state))
        }
    }

    private func decodeButton(metrics: ThemePresentationScreenMetrics) -> some View {
        receivedAction(
            title: "Decode",
            systemImage: "sparkles",
            metrics: metrics,
            isEnabled: ReceivedCipherDecodeActionPolicy.isEnabled,
            accessibilityValue: ReceivedCipherDecodeActionPolicy.accessibilityValue,
            accessibilityHint: ReceivedCipherDecodeActionPolicy.accessibilityHint,
            action: {}
        )
    }

    private func doneButton(metrics: ThemePresentationScreenMetrics) -> some View {
        ThemePresentationPrimaryButton(
            title: ReceivedCipherCompletionActionPolicy.title,
            systemImage: ReceivedCipherCompletionActionPolicy.systemImage,
            metrics: metrics,
            action: doneAction
        )
        .accessibilityLabel(ReceivedCipherCompletionActionPolicy.title)
        .accessibilityHint(ReceivedCipherCompletionActionPolicy.accessibilityHint)
        .accessibilityIdentifier("received-cipher.action.done")
    }

    private func replyButton(metrics: ThemePresentationScreenMetrics) -> some View {
        receivedAction(
            title: "Reply",
            systemImage: "paperplane",
            metrics: metrics,
            action: replyAction
        )
    }

    private func receivedAction(
        title: String,
        systemImage: String,
        metrics: ThemePresentationScreenMetrics,
        isEnabled: Bool = true,
        accessibilityValue: String = "",
        accessibilityHint: String = "",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(
                    size: metrics.fontSize(30),
                    weight: .regular,
                    design: .serif
                ))
                .foregroundStyle(Color.runeSilver)
                .frame(
                    maxWidth: .infinity,
                    minHeight: ThemePresentationScreenMetrics.minimumInteractiveDimension,
                    maxHeight: .infinity
                )
                .background {
                    RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                        .fill(Color.runeNavy.opacity(0.74))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                        .strokeBorder(Color.runeGold.opacity(0.50), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: ThemePresentationScreenMetrics.minimumInteractiveDimension,
            minHeight: ThemePresentationScreenMetrics.minimumInteractiveDimension
        )
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("received-cipher.action.\(title.lowercased())")
    }

    private func previewHorizontalPadding(
        _ metrics: ThemePresentationScreenMetrics
    ) -> CGFloat {
        switch state {
        case .primary: 0
        case .shareCard: metrics.horizontalPadding
        }
    }

    private func previewTopPadding(
        _ metrics: ThemePresentationScreenMetrics
    ) -> CGFloat {
        switch state {
        case .primary: 42 * metrics.scale
        case .shareCard: 22 * metrics.scale
        }
    }

    private func metadataTopPadding(
        _ metrics: ThemePresentationScreenMetrics
    ) -> CGFloat {
        switch state {
        case .primary: 46 * metrics.scale
        case .shareCard: 21 * metrics.scale
        }
    }

    private func senderTopPadding(
        _ metrics: ThemePresentationScreenMetrics
    ) -> CGFloat {
        28 * metrics.scale
    }

    private func actionTopPadding(
        _ metrics: ThemePresentationScreenMetrics
    ) -> CGFloat {
        switch state {
        case .primary: 34 * metrics.scale
        case .shareCard: 40 * metrics.scale
        }
    }

    private func senderAvatarDiameter(
        _ metrics: ThemePresentationScreenMetrics
    ) -> CGFloat {
        switch state {
        case .primary: 92 * metrics.scale
        case .shareCard: 88 * metrics.scale
        }
    }

    private var relativeSenderTime: String {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        if localCalendar.isDate(receivedAt, inSameDayAs: relativeDate) {
            return "Sent just now"
        }
        return "Sent earlier"
    }

    private var scriptMetadataTitle: String {
        summary.scriptName.hasSuffix(" Script") ? "Script" : "Font"
    }
}
