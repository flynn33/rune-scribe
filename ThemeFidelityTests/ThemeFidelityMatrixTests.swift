import CoreGraphics
import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
import RuneScribeNorseThemeModule
import RuneScribePlatform
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
import RuneScribeThemeCoordinatorModule
import RuneScribeThemeGloamthornModule
import RuneScribeThemeMoonleafModule
import RuneScribeThemeSunspireModule
import RuneScribeThemeWildwoodModule
@testable import RuneScribeUIModule
@testable import RuneScribeUIRuntime
import SwiftUI
import XCTest

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class ThemeFidelityMatrixTests: XCTestCase {
    func testCaptureThemeFidelityMatrix() async throws {
        try await capture(
            themes: ThemeFidelityTheme.allCases,
            surfaces: ThemeFidelitySurface.allCases,
            destinations: ThemeFidelityDestination.currentDestinations,
            requireUnclippedViewport: false,
            distinctCaptureSurfaces: []
        )
    }

    func testCaptureThemeFidelitySmoke() async throws {
        try await capture(
            themes: [.norse],
            surfaces: [.workspaceEmpty, .shareBuilder, .staticShare],
            destinations: ThemeFidelityDestination.smokeDestinations,
            requireUnclippedViewport: true,
            distinctCaptureSurfaces: [.workspaceEmpty, .shareBuilder, .staticShare]
        )
    }

    func testCaptureThemeFidelityStateSmoke() async throws {
        var distinctSurfaces: Set<ThemeFidelitySurface> = [
            .composeShort,
            .composeLong,
            .inscriptionPreview,
            .settingsCodexCard,
            .settingsDefaultsPreview,
            .vaultLocked,
            .vaultProgress,
            .vaultEncountered,
            .vaultOwned,
            .vaultSelected,
            .highContrast,
        ]
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            distinctSurfaces.remove(.vaultSelected)
        }
        #endif
        try await capture(
            themes: [.norse],
            surfaces: [
                .composeShort,
                .composeLong,
                .inscriptionPreview,
                .settingsCodexCard,
                .settingsDefaultsPreview,
                .vaultLocked,
                .vaultProgress,
                .vaultEncountered,
                .vaultOwned,
                .vaultSelected,
                .highContrast,
                .reduceMotion,
            ],
            destinations: ThemeFidelityDestination.smokeDestinations,
            requireUnclippedViewport: false,
            distinctCaptureSurfaces: distinctSurfaces
        )
    }

    func testCaptureThemeFidelityReceivedSmoke() async throws {
        try await capture(
            themes: [.norse, .moonleaf],
            surfaces: [.receivedCipher],
            destinations: ThemeFidelityDestination.smokeDestinations,
            requireUnclippedViewport: false,
            distinctCaptureSurfaces: [.receivedCipher]
        )
    }

    func testCaptureThemeFidelityRequiredViewportSmoke() async throws {
        try await capture(
            themes: [.norse],
            surfaces: [.composeShort, .composeLong, .mastery, .largeText],
            destinations: ThemeFidelityDestination.smokeDestinations,
            requireUnclippedViewport: true,
            distinctCaptureSurfaces: [.composeShort, .composeLong, .mastery, .largeText]
        )
    }

    private func capture(
        themes: [ThemeFidelityTheme],
        surfaces: [ThemeFidelitySurface],
        destinations: [ThemeFidelityDestination],
        requireUnclippedViewport: Bool,
        distinctCaptureSurfaces: Set<ThemeFidelitySurface>
    ) async throws {
        continueAfterFailure = false
        let fixture = try await ThemeFidelityRuntimeFixture.start()
        let renderer = ThemeFidelityPersistentRenderer()
        addTeardownBlock {
            await renderer.close()
            await fixture.stop()
        }

        XCTAssertFalse(destinations.isEmpty)

        var declaredResourceIDsByCodexID: [CodexID: Set<ThemeResourceID>] = [:]
        for registeredTheme in ThemeFidelityTheme.allCases {
            let descriptor = try await fixture.themeClient.providerDescriptor(
                for: registeredTheme.codexID
            )
            declaredResourceIDsByCodexID[descriptor.codex.id] = Set(
                descriptor.resources.map(\.id)
            )
        }
        XCTAssertEqual(declaredResourceIDsByCodexID.count, ThemeFidelityTheme.allCases.count)

        var attachmentNames = Set<String>()
        var digestOwners: [String: String] = [:]
        var renderedCount = 0
        for theme in themes {
            try await fixture.select(theme)
            let descriptor = try await fixture.themeClient.providerDescriptor(for: theme.codexID)
            let model = try await ThemeFidelityRenderModel.load(
                theme: theme,
                descriptor: descriptor,
                session: fixture.session
            )
            let activeDescriptorResourceIDs = Set(descriptor.resources.map(\.id))
            for destination in destinations {
                for surface in surfaces {
                    let name = ThemeFidelityCaptureName(
                        theme: theme,
                        surface: surface,
                        destination: destination
                    )
                    XCTAssertTrue(attachmentNames.insert(name.png).inserted, name.png)
                    let route = try ThemeFidelityRoute.make(
                        surface: surface,
                        model: model,
                        session: fixture.session
                    )
                    let contentSeed = ThemeFidelityContentSeed.make(
                        surface: surface,
                        model: model,
                        session: fixture.session
                    )
                    var observedResourceBindings = Set<ThemeFidelityRenderedResourceBinding>()
                    var unexpectedResourceBindings = Set<ThemeFidelityRenderedResourceBinding>()
                    let activeBinding: (ThemeResourceID) -> ThemeFidelityRenderedResourceBinding = {
                        resourceID in
                        ThemeFidelityRenderedResourceBinding(
                            codexID: descriptor.codex.id.rawValue,
                            resourceID: resourceID.rawValue,
                            visualPlanRevision: model.visualPlanRevision
                        )
                    }
                    let validateActiveResourceID: (ThemeResourceID) -> Bool = { resourceID in
                        guard activeDescriptorResourceIDs.contains(resourceID) else {
                            unexpectedResourceBindings.insert(activeBinding(resourceID))
                            return false
                        }
                        return true
                    }
                    let renderedWithoutResources: ThemeFidelityRenderedPNG
                    do {
                        fixture.session.resourcePresentation.beginRenderedResourceObservation {
                            identity in
                            let binding = ThemeFidelityRenderedResourceBinding(
                                codexID: identity.codexID.rawValue,
                                resourceID: identity.resourceID.rawValue,
                                visualPlanRevision: identity.contentRevision
                            )
                            guard identity.contentRevision == model.visualPlanRevision,
                                  declaredResourceIDsByCodexID[identity.codexID]?
                                      .contains(identity.resourceID) == true
                            else {
                                unexpectedResourceBindings.insert(binding)
                                return
                            }
                            observedResourceBindings.insert(binding)
                        }
                        RuntimeThemeSemanticResourceUseObservation.begin {
                            guard validateActiveResourceID($0) else { return }
                            observedResourceBindings.insert(activeBinding($0))
                        }
                        defer {
                            RuntimeThemeSemanticResourceUseObservation.end()
                            fixture.session.resourcePresentation.endRenderedResourceObservation()
                        }
                        renderedWithoutResources = try renderer.render(
                            route.view,
                            identity: name.png,
                            destination: destination,
                            requiredElementIDs: route.requiredElementIDs,
                            coveringElementIDs: route.coveringElementIDs,
                            warmup: route.warmup
                        )
                    }
                    if surface == .receivedCipher,
                       renderedWithoutResources.elementFrames.frames.contains(where: {
                           $0.elementID == "received.safe-preview"
                       }) {
                        model.safePreviewRenderedResourceIDs.compactMap(
                            ThemeResourceID.init(rawValue:)
                        ).forEach { resourceID in
                            guard validateActiveResourceID(resourceID) else { return }
                            observedResourceBindings.insert(activeBinding(resourceID))
                        }
                    }
                    let unexpectedResourceIDs = unexpectedResourceBindings
                        .map(\.description)
                        .sorted()
                    XCTAssertTrue(
                        unexpectedResourceIDs.isEmpty,
                        "Observed resources lack owning Codex or revision authority for \(name.png): "
                            + unexpectedResourceIDs.joined(separator: ", ")
                    )
                    guard unexpectedResourceIDs.isEmpty else {
                        throw ThemeFidelityCaptureError.unexpectedRenderedResourceIDs(
                            captureName: name.png,
                            resourceIDs: unexpectedResourceIDs
                        )
                    }
                    let rendered = renderedWithoutResources.recording(
                        renderedResourceBindings: Array(observedResourceBindings)
                    )
                    XCTAssertEqual(rendered.width, destination.pixelWidth)
                    XCTAssertEqual(rendered.height, destination.pixelHeight)
                    XCTAssertGreaterThan(rendered.data.count, 4_096)
                    XCTAssertFalse(
                        rendered.renderedResourceIDs.isEmpty,
                        "No runtime-rendered theme resources observed for \(name.png)"
                    )
                    XCTAssertTrue(
                        rendered.renderedResourceBindings.contains(where: {
                            $0.codexID == descriptor.codex.id.rawValue
                        }),
                        "No active-Codex theme resources observed for \(name.png)"
                    )
                    if requireUnclippedViewport {
                        XCTAssertTrue(
                            rendered.viewportAssertions.clippedElementIDs.isEmpty,
                            "Missing or clipped viewport elements for \(name.png): "
                                + rendered.viewportAssertions.clippedElementIDs.joined(separator: ", ")
                        )
                    }
                    let digest = Self.sha256(rendered.data)
                    if distinctCaptureSurfaces.contains(surface),
                       let priorCapture = digestOwners.updateValue(name.png, forKey: digest) {
                        XCTFail(
                            "Capture bytes are identical: \(priorCapture) and \(name.png)"
                        )
                    }
                    attach(rendered.data, name: name.png, type: "public.png")
                    let record = try ThemeFidelityCaptureRecord(
                        theme: theme,
                        descriptor: descriptor,
                        surface: surface,
                        destination: destination,
                        model: model,
                        contentSeed: contentSeed,
                        renderedResourceIDs: rendered.renderedResourceIDs,
                        renderedResourceBindings: rendered.renderedResourceBindings,
                        viewportAssertions: rendered.viewportAssertions,
                        elementFrames: rendered.elementFrames,
                        safePreviewEvidence: try ThemeFidelitySafePreviewEvidence.make(
                            surface: surface,
                            model: model,
                            rendered: rendered
                        ),
                        pngSHA256: digest,
                        byteCount: rendered.data.count
                    )
                    let recordData = try JSONEncoder.themeFidelity.encode(record)
                    guard let recordObject = try JSONSerialization.jsonObject(
                        with: recordData
                    ) as? [String: Any],
                    recordObject.keys.contains("sealID"),
                    recordObject.keys.contains("frameID")
                    else { throw ThemeFidelityCaptureError.renderFailed }
                    attach(recordData, name: name.record, type: "public.json")
                    renderedCount += 1
                }
            }
        }
        XCTAssertEqual(renderedCount, themes.count * surfaces.count * destinations.count)
    }

    private func attach(_ data: Data, name: String, type: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum ThemeFidelityCaptureError: Error {
    case clientUnavailable
    case invalidDescriptor
    case missingResource(ThemeResourceID)
    case renderFailed
    case runtimeDidNotSettle
    case safePreviewUnavailable(String)
    case unexpectedRenderedResourceIDs(captureName: String, resourceIDs: [String])
}

private enum ThemeFidelityPhase {
    static var current: String {
        ProcessInfo.processInfo.environment["RUNESCRIBE_THEME_FIDELITY_PHASE"]
            ?? "baseline"
    }

    static var requiresValidSafePreview: Bool { current == "final" }
}

private enum ThemeFidelitySurface: String, CaseIterable, Codable, Sendable {
    case workspaceEmpty = "workspace-empty"
    case composeShort = "compose-short"
    case composeLong = "compose-long"
    case inscriptionPreview = "inscription-preview"
    case receivedCipher = "received-cipher"
    case shareBuilder = "share-builder"
    case staticShare = "static-share"
    case settingsCodexCard = "settings-codex-card"
    case settingsDefaultsPreview = "settings-defaults-preview"
    case vaultLocked = "vault-locked"
    case vaultProgress = "vault-progress"
    case vaultEncountered = "vault-encountered"
    case vaultOwned = "vault-owned"
    case vaultSelected = "vault-selected"
    case relicPicker = "relic-picker"
    case sealPicker = "seal-picker"
    case mastery = "mastery"
    case highContrast = "high-contrast"
    case reduceMotion = "reduce-motion"
    case largeText = "large-text"
}

private enum ThemeFidelityTheme: String, CaseIterable, Codable, Sendable {
    case norse = "Norse"
    case moonleaf = "Moonleaf"
    case sunspire = "Sunspire"
    case wildwood = "Wildwood"
    case gloamthorn = "Gloamthorn"

    var slug: String { rawValue.lowercased() }
    var descriptor: ThemeDescriptor {
        switch self {
        case .norse: RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        case .moonleaf: RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        case .sunspire: RuneScribeThemeSunspireModuleBootstrap.discoveryDescriptor
        case .wildwood: RuneScribeThemeWildwoodModuleBootstrap.discoveryDescriptor
        case .gloamthorn: RuneScribeThemeGloamthornModuleBootstrap.discoveryDescriptor
        }
    }
    var codexID: CodexID { descriptor.codex.id }
    var masteryTitleID: TitleID {
        switch self {
        case .norse:
            TitleID(rawValue: "title.norse.master-of-runes")!
        case .moonleaf, .sunspire, .wildwood, .gloamthorn:
            TitleID(rawValue: "title.\(slug).mastery")!
        }
    }
}

private struct ThemeFidelityDestination: Equatable, Sendable {
    let name: String
    let slug: String
    let pointSize: CGSize
    let scale: CGFloat
    var pixelWidth: Int { Int((pointSize.width * scale).rounded()) }
    var pixelHeight: Int { Int((pointSize.height * scale).rounded()) }

    @MainActor static var currentDestinations: [Self] {
        #if os(macOS)
        return [
            Self(name: "macOS standard", slug: "macos-standard",
                 pointSize: CGSize(width: 720, height: 900), scale: 1),
            Self(name: "macOS resized", slug: "macos-resized",
                 pointSize: CGSize(width: 980, height: 720), scale: 1),
        ]
        #elseif os(iOS)
        let screen = UIScreen.main
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        return [Self(
            name: isPad ? "iPad portrait" : "iPhone portrait",
            slug: isPad ? "ipad-portrait" : "iphone-portrait",
            pointSize: CGSize(
                width: min(screen.bounds.width, screen.bounds.height),
                height: max(screen.bounds.width, screen.bounds.height)
            ),
            scale: screen.scale
        )]
        #endif
    }

    @MainActor static var smokeDestinations: [Self] {
        #if os(macOS)
        currentDestinations
        #else
        Array(currentDestinations.prefix(1))
        #endif
    }
}

private struct ThemeFidelityCaptureName {
    let png: String
    let record: String
    init(theme: ThemeFidelityTheme, surface: ThemeFidelitySurface,
         destination: ThemeFidelityDestination) {
        let stem = "\(theme.slug)--\(surface.rawValue)--\(destination.slug)"
        png = "\(stem).png"
        record = "\(stem).capture.json"
    }
}

private struct ThemeFidelityViewportAssertions: Codable, Equatable {
    let requiredElementCount: Int
    let requiredElementIDs: [String]
    let clippedElementIDs: [String]
}

private struct ThemeFidelityRenderedPNG {
    let data: Data
    let width: Int
    let height: Int
    let viewportAssertions: ThemeFidelityViewportAssertions
    let elementFrames: ThemeFidelityElementFrames
    let renderedResourceIDs: [String]
    let renderedResourceBindings: [ThemeFidelityRenderedResourceBinding]

    func recording(
        renderedResourceBindings: [ThemeFidelityRenderedResourceBinding]
    ) -> Self {
        let bindings = Array(Set(renderedResourceBindings)).sorted()
        return Self(
            data: data,
            width: width,
            height: height,
            viewportAssertions: viewportAssertions,
            elementFrames: elementFrames,
            renderedResourceIDs: Array(Set(bindings.map(\.resourceID))).sorted(),
            renderedResourceBindings: bindings
        )
    }
}

private struct ThemeFidelityRenderedResourceBinding: Codable, Hashable, Comparable {
    let codexID: String
    let resourceID: String
    let visualPlanRevision: UInt64

    var description: String {
        "\(codexID)/\(resourceID)@\(visualPlanRevision)"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.codexID, lhs.resourceID, lhs.visualPlanRevision)
            < (rhs.codexID, rhs.resourceID, rhs.visualPlanRevision)
    }
}

private struct ThemeFidelityElementFrames: Codable, Equatable {
    struct Frame: Codable, Equatable {
        let elementID: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let coordinateOrigin: String
    let units: String
    let scale: Double
    let frames: [Frame]

    init(pointFrames: [String: CGRect], scale: CGFloat) {
        coordinateOrigin = "top-left"
        units = "pixels"
        self.scale = Double(scale)
        frames = pointFrames.compactMap { identifier, frame in
            guard !frame.isNull, !frame.isEmpty,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite
            else { return nil }
            return Frame(
                elementID: identifier,
                x: Double(frame.origin.x * scale),
                y: Double(frame.origin.y * scale),
                width: Double(frame.width * scale),
                height: Double(frame.height * scale)
            )
        }
        .sorted { $0.elementID < $1.elementID }
    }
}

private struct ThemeFidelityContentSeed: Encodable {
    struct Sender: Encodable {
        let name: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let name {
                try container.encode(name, forKey: .name)
            } else {
                try container.encodeNil(forKey: .name)
            }
        }

        private enum CodingKeys: String, CodingKey { case name }
    }

    struct Cipher: Encodable {
        let id: String?
        let name: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let id {
                try container.encode(id, forKey: .id)
            } else {
                try container.encodeNil(forKey: .id)
            }
            if let name {
                try container.encode(name, forKey: .name)
            } else {
                try container.encodeNil(forKey: .name)
            }
        }

        private enum CodingKeys: String, CodingKey { case id, name }
    }

    struct SelectedResources: Encodable {
        let codexID: String
        let relicID: String
        let sealID: String?
        let frameID: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(codexID, forKey: .codexID)
            try container.encode(relicID, forKey: .relicID)
            if let sealID {
                try container.encode(sealID, forKey: .sealID)
            } else {
                try container.encodeNil(forKey: .sealID)
            }
            if let frameID {
                try container.encode(frameID, forKey: .frameID)
            } else {
                try container.encodeNil(forKey: .frameID)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case codexID, relicID, sealID, frameID
        }
    }

    struct Progression: Encodable {
        let ownershipState: String?
        let achievementID: String?
        let completedRuleCount: Int?
        let requiredRuleCount: Int?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let ownershipState {
                try container.encode(ownershipState, forKey: .ownershipState)
            } else {
                try container.encodeNil(forKey: .ownershipState)
            }
            if let achievementID {
                try container.encode(achievementID, forKey: .achievementID)
            } else {
                try container.encodeNil(forKey: .achievementID)
            }
            if let completedRuleCount {
                try container.encode(completedRuleCount, forKey: .completedRuleCount)
            } else {
                try container.encodeNil(forKey: .completedRuleCount)
            }
            if let requiredRuleCount {
                try container.encode(requiredRuleCount, forKey: .requiredRuleCount)
            } else {
                try container.encodeNil(forKey: .requiredRuleCount)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case ownershipState, achievementID, completedRuleCount, requiredRuleCount
        }
    }

    struct Accessibility: Encodable {
        let increasedContrast: Bool
        let reduceMotion: Bool
        let dynamicTypeSize: String
    }

    let fixtureID: String
    let fixtureVersion: Int
    let surface: String
    let plaintext: String?
    let glyphTokens: [String]
    let sender: Sender
    let cipher: Cipher
    let timestamp: String
    let selectedResources: SelectedResources
    let progression: Progression
    let locale: String
    let calendar: String
    let timeZone: String
    let accessibility: Accessibility

    @MainActor
    static func make(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel,
        session: RuneScribeUISession
    ) -> Self {
        let plaintext: String? = switch surface {
        case .composeShort:
            model.shortText
        case .composeLong, .largeText:
            model.longText
        case .inscriptionPreview, .staticShare, .highContrast, .reduceMotion:
            model.previewText
        case .receivedCipher:
            model.previewText
        default:
            nil
        }

        let sender = Sender(
            name: surface == .receivedCipher ? ThemeFidelityRoute.receivedSenderName : nil
        )
        let cipher: Cipher
        if surface == .receivedCipher {
            cipher = Cipher(
                id: ThemeFidelityRoute.receivedCipherID.uuidString.lowercased(),
                name: ThemeFidelityRoute.receivedCipherName
            )
        } else if surface.presentsActiveCipher, let activeCipher = session.activeCipher {
            cipher = Cipher(
                id: activeCipher.id.uuidString.lowercased(),
                name: activeCipher.label
            )
        } else {
            cipher = Cipher(id: nil, name: nil)
        }

        return Self(
            fixtureID: ThemeFidelityRuntimeFixture.stateSeed,
            fixtureVersion: ThemeFidelityRuntimeFixture.fixtureVersion,
            surface: surface.rawValue,
            plaintext: plaintext,
            glyphTokens: model.glyphTokens,
            sender: sender,
            cipher: cipher,
            timestamp: ThemeFidelityRuntimeFixture.timestamp,
            selectedResources: SelectedResources(
                codexID: model.selection.codexID.rawValue,
                relicID: model.selection.relicID.rawValue,
                sealID: model.selection.sealID?.rawValue,
                frameID: model.selection.frameID?.rawValue
            ),
            progression: surface.contentSeedProgression,
            locale: "en_US_POSIX",
            calendar: "gregorian",
            timeZone: "GMT",
            accessibility: surface.contentSeedAccessibility
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fixtureID, forKey: .fixtureID)
        try container.encode(fixtureVersion, forKey: .fixtureVersion)
        try container.encode(surface, forKey: .surface)
        if let plaintext {
            try container.encode(plaintext, forKey: .plaintext)
        } else {
            try container.encodeNil(forKey: .plaintext)
        }
        try container.encode(glyphTokens, forKey: .glyphTokens)
        try container.encode(sender, forKey: .sender)
        try container.encode(cipher, forKey: .cipher)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(selectedResources, forKey: .selectedResources)
        try container.encode(progression, forKey: .progression)
        try container.encode(locale, forKey: .locale)
        try container.encode(calendar, forKey: .calendar)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encode(accessibility, forKey: .accessibility)
    }

    private enum CodingKeys: String, CodingKey {
        case fixtureID, fixtureVersion, surface, plaintext, glyphTokens, sender, cipher
        case timestamp, selectedResources, progression, locale, calendar, timeZone
        case accessibility
    }
}

private extension ThemeFidelitySurface {
    var presentsActiveCipher: Bool {
        switch self {
        case .workspaceEmpty, .composeShort, .composeLong, .inscriptionPreview,
             .shareBuilder, .highContrast, .reduceMotion, .largeText:
            true
        default:
            false
        }
    }

    var contentSeedProgression: ThemeFidelityContentSeed.Progression {
        switch self {
        case .vaultLocked:
            ThemeFidelityContentSeed.Progression(
                ownershipState: "locked", achievementID: nil,
                completedRuleCount: nil, requiredRuleCount: nil
            )
        case .vaultEncountered:
            ThemeFidelityContentSeed.Progression(
                ownershipState: "encountered", achievementID: nil,
                completedRuleCount: nil, requiredRuleCount: nil
            )
        case .vaultOwned:
            ThemeFidelityContentSeed.Progression(
                ownershipState: "owned", achievementID: nil,
                completedRuleCount: nil, requiredRuleCount: nil
            )
        case .vaultSelected:
            ThemeFidelityContentSeed.Progression(
                ownershipState: "selected", achievementID: nil,
                completedRuleCount: nil, requiredRuleCount: nil
            )
        case .vaultProgress:
            ThemeFidelityContentSeed.Progression(
                ownershipState: nil,
                achievementID: "achievement.first-inscription",
                completedRuleCount: 0,
                requiredRuleCount: 1
            )
        default:
            ThemeFidelityContentSeed.Progression(
                ownershipState: nil, achievementID: nil,
                completedRuleCount: nil, requiredRuleCount: nil
            )
        }
    }

    var contentSeedAccessibility: ThemeFidelityContentSeed.Accessibility {
        ThemeFidelityContentSeed.Accessibility(
            increasedContrast: self == .highContrast,
            reduceMotion: self == .reduceMotion,
            dynamicTypeSize: self == .largeText ? "accessibility2" : "large"
        )
    }

    var runtimeAccessibilityPreferences: RuntimeAccessibilityPreferences {
        switch self {
        case .highContrast:
            RuntimeAccessibilityPreferences(forcesIncreasedContrast: true)
        case .reduceMotion:
            RuntimeAccessibilityPreferences(forcesReduceMotion: true)
        default:
            RuntimeAccessibilityPreferences()
        }
    }
}

private struct ThemeFidelitySafePreviewEvidence: Encodable {
    let status: String
    let byteCount: Int?
    let sha256: String?
    let resourceIDs: [String]
    let decodedPreviewElementID: String?
    let failureCode: String?

    @MainActor
    static func make(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel,
        rendered: ThemeFidelityRenderedPNG
    ) throws -> Self? {
        guard surface == .receivedCipher else { return nil }
        if model.safePreviewStatus == .valid {
            guard let data = model.safePreviewData,
                  rendered.elementFrames.frames.contains(where: {
                      $0.elementID == "received.safe-preview"
                  }),
                  !model.safePreviewRenderedResourceIDs.isEmpty
            else { throw ThemeFidelityCaptureError.renderFailed }
            return Self(
                status: "valid",
                byteCount: data.count,
                sha256: SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined(),
                resourceIDs: Array(Set(model.safePreviewRenderedResourceIDs)).sorted(),
                decodedPreviewElementID: "received.safe-preview",
                failureCode: nil
            )
        }
        let failed = model.safePreviewDiagnostic.hasSuffix("rendering-unavailable")
            || model.safePreviewDiagnostic.hasSuffix("invalid-presentation")
        return Self(
            status: failed ? "generation-failed" : "unavailable",
            byteCount: nil,
            sha256: nil,
            resourceIDs: [],
            decodedPreviewElementID: nil,
            failureCode: model.safePreviewDiagnostic
        )
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case byteCount
        case sha256
        case resourceIDs
        case decodedPreviewElementID
        case failureCode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        if let byteCount {
            try container.encode(byteCount, forKey: .byteCount)
        } else {
            try container.encodeNil(forKey: .byteCount)
        }
        if let sha256 {
            try container.encode(sha256, forKey: .sha256)
        } else {
            try container.encodeNil(forKey: .sha256)
        }
        try container.encode(resourceIDs, forKey: .resourceIDs)
        if let decodedPreviewElementID {
            try container.encode(decodedPreviewElementID, forKey: .decodedPreviewElementID)
        } else {
            try container.encodeNil(forKey: .decodedPreviewElementID)
        }
        if let failureCode {
            try container.encode(failureCode, forKey: .failureCode)
        } else {
            try container.encodeNil(forKey: .failureCode)
        }
    }
}

private struct ThemeFidelityCaptureRecord: Encodable {
    let schemaVersion: String
    let stateSeed: String
    let stateSeedSHA256: String
    let contentSeed: ThemeFidelityContentSeed
    let stateID: String
    let themeName: String
    let themeID: String
    let codexID: String
    let relicID: String
    let sealID: String?
    let frameID: String?
    let surface: String
    let destination: String
    let pointWidth: Double
    let pointHeight: Double
    let scale: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let visualPlanRevision: UInt64
    let pngSHA256: String
    let byteCount: Int
    let renderedResourceIDs: [String]
    let renderedResourceBindings: [ThemeFidelityRenderedResourceBinding]
    let viewportAssertions: ThemeFidelityViewportAssertions
    let elementFrames: ThemeFidelityElementFrames
    let safePreviewEvidence: ThemeFidelitySafePreviewEvidence?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case stateSeed
        case stateSeedSHA256
        case contentSeed
        case stateID
        case themeName
        case themeID
        case codexID
        case relicID
        case sealID
        case frameID
        case surface
        case destination
        case pointWidth
        case pointHeight
        case scale
        case pixelWidth
        case pixelHeight
        case visualPlanRevision
        case pngSHA256
        case byteCount
        case renderedResourceIDs
        case renderedResourceBindings
        case viewportAssertions
        case elementFrames
        case safePreviewEvidence
    }

    @MainActor
    init(theme: ThemeFidelityTheme, descriptor: ThemeDescriptor,
         surface: ThemeFidelitySurface, destination: ThemeFidelityDestination,
         model: ThemeFidelityRenderModel, contentSeed: ThemeFidelityContentSeed,
         renderedResourceIDs: [String],
         renderedResourceBindings: [ThemeFidelityRenderedResourceBinding],
         viewportAssertions: ThemeFidelityViewportAssertions,
         elementFrames: ThemeFidelityElementFrames,
         safePreviewEvidence: ThemeFidelitySafePreviewEvidence?,
         pngSHA256: String, byteCount: Int) throws {
        schemaVersion = "1.0"
        stateSeed = ThemeFidelityRuntimeFixture.stateSeed
        self.contentSeed = contentSeed
        stateSeedSHA256 = SHA256.hash(
            data: try JSONEncoder.themeFidelityCanonical.encode(contentSeed)
        ).map { String(format: "%02x", $0) }.joined()
        stateID = surface.rawValue
        themeName = theme.rawValue
        themeID = descriptor.id.rawValue
        codexID = descriptor.codex.id.rawValue
        relicID = model.selection.relicID.rawValue
        sealID = model.selection.sealID?.rawValue
        frameID = model.selection.frameID?.rawValue
        self.surface = surface.rawValue
        self.destination = destination.name
        pointWidth = Double(destination.pointSize.width)
        pointHeight = Double(destination.pointSize.height)
        scale = Double(destination.scale)
        pixelWidth = destination.pixelWidth
        pixelHeight = destination.pixelHeight
        visualPlanRevision = model.visualPlanRevision
        self.pngSHA256 = pngSHA256
        self.byteCount = byteCount
        self.renderedResourceIDs = Array(Set(renderedResourceIDs)).sorted()
        self.renderedResourceBindings = Array(Set(renderedResourceBindings)).sorted()
        self.viewportAssertions = viewportAssertions
        self.elementFrames = elementFrames
        self.safePreviewEvidence = safePreviewEvidence
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(stateSeed, forKey: .stateSeed)
        try container.encode(stateSeedSHA256, forKey: .stateSeedSHA256)
        try container.encode(contentSeed, forKey: .contentSeed)
        try container.encode(stateID, forKey: .stateID)
        try container.encode(themeName, forKey: .themeName)
        try container.encode(themeID, forKey: .themeID)
        try container.encode(codexID, forKey: .codexID)
        try container.encode(relicID, forKey: .relicID)
        if let sealID {
            try container.encode(sealID, forKey: .sealID)
        } else {
            try container.encodeNil(forKey: .sealID)
        }
        if let frameID {
            try container.encode(frameID, forKey: .frameID)
        } else {
            try container.encodeNil(forKey: .frameID)
        }
        try container.encode(surface, forKey: .surface)
        try container.encode(destination, forKey: .destination)
        try container.encode(pointWidth, forKey: .pointWidth)
        try container.encode(pointHeight, forKey: .pointHeight)
        try container.encode(scale, forKey: .scale)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        try container.encode(visualPlanRevision, forKey: .visualPlanRevision)
        try container.encode(pngSHA256, forKey: .pngSHA256)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(renderedResourceIDs, forKey: .renderedResourceIDs)
        try container.encode(renderedResourceBindings, forKey: .renderedResourceBindings)
        try container.encode(viewportAssertions, forKey: .viewportAssertions)
        try container.encode(elementFrames, forKey: .elementFrames)
        if let safePreviewEvidence {
            try container.encode(safePreviewEvidence, forKey: .safePreviewEvidence)
        }
    }
}

private extension JSONEncoder {
    static var themeFidelityCanonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var themeFidelity: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private final class ThemeFidelityUUIDProvider: UUIDProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64 = 1

    func nextUUID() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let value = nextValue
        nextValue += 1
        return UUID(
            uuidString: String(
                format: "00000000-0000-4000-8000-%012llx",
                value
            )
        )!
    }
}

@MainActor
private final class ThemeFidelityRuntimeFixture {
    nonisolated static let stateSeed = "theme-fidelity-v4-real-session-01"
    nonisolated static let fixtureVersion = 1
    nonisolated static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    nonisolated static let timestamp = "2023-11-14T22:13:20Z"

    let session: RuneScribeUISession
    let themeClient: RuntimeThemeCoordinatorClient
    private let service: RuneScribeCoreApplicationService
    private let runtime: RuneScribeRuntime
    private let shareArtifacts: AppleShareArtifactStore
    private let temporaryRoot: URL

    private init(
        session: RuneScribeUISession,
        themeClient: RuntimeThemeCoordinatorClient,
        service: RuneScribeCoreApplicationService,
        runtime: RuneScribeRuntime,
        shareArtifacts: AppleShareArtifactStore,
        temporaryRoot: URL
    ) {
        self.session = session
        self.themeClient = themeClient
        self.service = service
        self.runtime = runtime
        self.shareArtifacts = shareArtifacts
        self.temporaryRoot = temporaryRoot
    }

    static func start() async throws -> ThemeFidelityRuntimeFixture {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeThemeFidelity", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot,
                                                withIntermediateDirectories: true)

        let secureValues = InMemorySecureValueStore()
        let protectedFiles = InMemoryProtectedFileStore()
        let inboundFiles = InMemoryInboundFileReader()
        let contacts = InMemoryContactAccessService(authorizationStatus: .denied)
        let clipboard = InMemoryClipboardService()
        let clock = FixedClock(fixedDate)
        let uuid = ThemeFidelityUUIDProvider()
        let shareArtifacts = AppleShareArtifactStore(
            temporaryDirectory: temporaryRoot.appendingPathComponent("share", isDirectory: true)
        )
        let fontRegistrar = CoreTextFontRegistrar()
        let coreResources = MappedApplicationResourceLocator(
            locations: [.bundledRuneFont: try requireBundledFontURL()]
        )
        let themeResources = BundleApplicationResourceLocator(
            bundle: .main,
            moduleBundles: themeResourceBundles
        )
        let runtimeIO = RuntimeIOClient(
            secureValueData: { try await secureValues.data(service: $0, account: $1) },
            setSecureValue: { try await secureValues.set($0, service: $1, account: $2) },
            deleteSecureValue: { try await secureValues.delete(service: $0, account: $1) },
            readProtectedFile: {
                try await protectedFiles.read(relativePath: $0, maximumByteCount: $1)
            },
            writeProtectedFile: { try await protectedFiles.write($0, relativePath: $1) },
            removeProtectedFile: { try await protectedFiles.remove(relativePath: $0) },
            protectedFileExists: { try await protectedFiles.exists(relativePath: $0) },
            protectedFileContents: {
                try await protectedFiles.contents(of: $0, matchingExtension: $1)
            },
            now: { clock.now() },
            nextUUID: { uuid.nextUUID() },
            clipboardSnapshot: {
                RuntimeClipboardSnapshot(
                    changeCount: await clipboard.changeCount(),
                    string: await clipboard.string()
                )
            },
            contactAuthorizationStatus: { await contacts.authorizationStatus() },
            requestContactAccess: { try await contacts.requestAccess() },
            fetchSystemContacts: { try await contacts.fetchContacts() },
            readInboundFile: {
                try await inboundFiles.read(
                    $0.fileURL,
                    requiresSecurityScope: $0.requiresSecurityScopedAccess,
                    maximumByteCount: $0.maximumByteCount
                )
            },
            registerBundledSystemFont: {
                let data = try await coreResources.data(for: $0)
                guard Data(SHA256.hash(data: data)) == $1 else {
                    throw RuntimeBundledFontFailure.integrityMismatch
                }
                return try await fontRegistrar.registerFont(data)
            },
            systemFontPostScriptName: {
                try await fontRegistrar.postScriptName(forFontData: $0)
            },
            registerSystemFont: { try await fontRegistrar.registerFont($0) },
            createShareArtifact: {
                try await shareArtifacts.create(
                    $0, artifactID: $1, filename: $2, fileExtension: $3
                )
            },
            storeShareArtifactLink: {
                try await shareArtifacts.storeLink($0, artifactID: $1)
            },
            removeShareArtifactLink: {
                try await shareArtifacts.removeLink(artifactID: $0)
            },
            removeShareArtifact: { try await shareArtifacts.remove(artifactID: $0) },
            removeAllShareArtifacts: { try await shareArtifacts.removeAll() }
        )

        let service = RuneScribeCoreApplicationService(runtimeIO: runtimeIO)
        let runtime = RuneScribeRuntime(
            runtimeVersion: ThemeFidelityRuntimeModules.version,
            platform: ThemeFidelityRuntimeModules.platform
        )
        let capture = ThemeFidelityClientCapture()
        try await runtime.installPlatformAdapter(
            themeResources,
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.installPlatformAdapter(
            fontRegistrar,
            for: RuneScribeServiceKeys.systemFontRegistrar
        )
        try await runtime.installPlatformAdapter(
            clipboard,
            for: RuneScribeServiceKeys.clipboardWrite
        )
        try await runtime.installPlatformAdapter(
            shareArtifacts,
            for: RuneScribeServiceKeys.sharePresentation
        )
        try await runtime.installPlatformAdapter(
            shareArtifacts,
            for: RuneScribeServiceKeys.shareArtifactStore
        )
        try await runtime.installPlatformAdapter(
            InMemoryModuleStateStore(now: { fixedDate }),
            for: RuneScribeServiceKeys.moduleStateStore
        )
        try await runtime.installPlatformAdapter(
            inboundFiles,
            for: RuneScribeServiceKeys.inboundFileReader
        )
        try await runtime.register(
            manifest: ThemeFidelityRuntimeModules.coreManifest,
            factory: AnyModuleFactory(descriptor: ThemeFidelityRuntimeModules.coreDescriptor) {
                ThemeFidelityApplicationPublishingModule(service: service)
            }
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeMoonleafModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeSunspireModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeWildwoodModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeGloamthornModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: AnyModuleFactory(descriptor: RuneScribeUIModuleBootstrap.descriptor) {
                ThemeFidelityClientModule(capture: capture)
            }
        )
        try await runtime.reconcileEntitlements(
            try ProgressionEntitlementSnapshotDTO(
                revision: 4_000,
                capturedAt: fixedDate,
                includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
                earnedUnlockIDs: [
                    RuneScribeThemeMoonleafModuleBootstrap.unlockID,
                    RuneScribeThemeSunspireModuleBootstrap.unlockID,
                    RuneScribeThemeWildwoodModuleBootstrap.unlockID,
                    RuneScribeThemeGloamthornModuleBootstrap.unlockID,
                ]
            )
        )
        try await runtime.start()

        let session = RuneScribeUISession(
            applicationClient: try await capture.requireApplicationClient(),
            runtimeIO: try await capture.requireRuntimeIO(),
            availabilityClient: try await capture.requireAvailabilityClient(),
            themeCoordinatorClient: try await capture.requireThemeClient(),
            runtimeSettingsClient: try await capture.requireSettingsClient(),
            resourcePresentation: RuntimeApplicationResourcePresentation(
                splashVideo: nil,
                metalLibrary: nil
            ),
            productMetadata: RuneScribeUIProductMetadata(
                version: "Theme Fidelity",
                buildNumber: "4"
            )
        )
        try await session.prepareInitialTheme()
        try session.start()
        await service.startInboundProcessing()
        guard await eventually({
            session.activeCipher != nil
                && !session.isLoading
                && session.activeThemeVisualPresentation != nil
        }) else {
            await session.stop()
            await runtime.stop()
            throw ThemeFidelityCaptureError.runtimeDidNotSettle
        }
        return ThemeFidelityRuntimeFixture(
            session: session,
            themeClient: try await capture.requireThemeClient(),
            service: service,
            runtime: runtime,
            shareArtifacts: shareArtifacts,
            temporaryRoot: temporaryRoot
        )
    }

    func select(_ theme: ThemeFidelityTheme) async throws {
        var snapshot = try await themeClient.snapshot()
        if snapshot.effectiveCodexID != theme.codexID {
            snapshot = try await themeClient.selectCodex(
                SelectThemeCodexCommand(
                    codexID: theme.codexID,
                    expectedSnapshotRevision: snapshot.revision
                )
            )
        }
        guard snapshot.effectiveCodexID == theme.codexID,
              await Self.eventually({
                  self.session.themeSnapshot?.effectiveCodexID == theme.codexID
                      && self.session.activeThemeVisualPresentation?.plan.codexID == theme.codexID
              })
        else { throw ThemeFidelityCaptureError.runtimeDidNotSettle }
        await session.loadActiveThemeCatalogVisuals()
        await session.loadThemeCodexCardPreviews()
    }

    func stop() async {
        await service.stopInboundProcessing()
        await session.stop()
        await runtime.stop()
        try? await shareArtifacts.removeAll()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private static func requireBundledFontURL() throws -> URL {
        guard let url = RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
            forResource: "NotoSansRunic-Regular",
            withExtension: "ttf"
        ) else { throw ThemeFidelityCaptureError.invalidDescriptor }
        return url
    }

    private static var themeResourceBundles: [ModuleIdentifier: Bundle] {
        RuneScribeNorseThemeModuleBootstrap.ownerScopedResourceBundles
            .merging(RuneScribeThemeMoonleafModuleBootstrap.ownerScopedResourceBundles) {
                _, replacement in replacement
            }
            .merging(RuneScribeThemeSunspireModuleBootstrap.ownerScopedResourceBundles) {
                _, replacement in replacement
            }
            .merging(RuneScribeThemeWildwoodModuleBootstrap.ownerScopedResourceBundles) {
                _, replacement in replacement
            }
            .merging(RuneScribeThemeGloamthornModuleBootstrap.ownerScopedResourceBundles) {
                _, replacement in replacement
            }
    }

    private static func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 8
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

private enum ThemeFidelityRuntimeModules {
    static let version = SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0))
    static let coreID: ModuleIdentifier = "com.runescribe.test.theme-fidelity-core"
    static var platform: SupportedPlatform {
        #if os(macOS)
        .macOS
        #elseif os(iOS)
        .iOS
        #endif
    }
    static let coreDescriptor = ModuleDescriptor(
        moduleID: coreID,
        moduleVersion: version,
        kind: .service,
        entryPoint: "RuneScribeThemeFidelityCoreModule",
        role: RuneScribeRoles.core,
        requestedCapabilities: [RuneScribeCapabilities.inboundInput],
        publishedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs.union(
            RuntimeApplicationEndpointCatalog.ingressEndpointIDs
        )
    )
    static let coreManifest = ModuleManifest(
        runtimeVersion: version,
        moduleID: coreID,
        displayName: "Rune Scribe Theme Fidelity Core",
        moduleVersion: version,
        moduleType: .service,
        supportedPlatforms: [.iOS, .macOS],
        capabilitiesRequested: [RuneScribeCapabilities.inboundInput],
        entryPoint: coreDescriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(),
        defaultRole: RuneScribeRoles.core,
        consumedEndpoints: coreDescriptor.consumedEndpoints.sorted(),
        publishedEndpoints: coreDescriptor.publishedEndpoints.sorted()
    )
}

private struct ThemeFidelityApplicationPublishingModule: RuneScribeModule {
    let descriptor = ThemeFidelityRuntimeModules.coreDescriptor
    let service: RuneScribeCoreApplicationService
    func start(context: ModuleContext) async throws {
        try await context.registerApplicationEndpoints(service)
        try await context.registerInboundInputEndpoint(service)
    }
    func stop() async {}
}

private actor ThemeFidelityClientCapture {
    private var applicationClient: RuntimeApplicationClient?
    private var runtimeIO: RuntimeIOClient?
    private var availabilityClient: RuntimeAvailabilityClient?
    private var themeClient: RuntimeThemeCoordinatorClient?
    private var settingsClient: RuntimeSettingsClient?

    func store(applicationClient: RuntimeApplicationClient, runtimeIO: RuntimeIOClient,
               availabilityClient: RuntimeAvailabilityClient,
               themeClient: RuntimeThemeCoordinatorClient,
               settingsClient: RuntimeSettingsClient) {
        self.applicationClient = applicationClient
        self.runtimeIO = runtimeIO
        self.availabilityClient = availabilityClient
        self.themeClient = themeClient
        self.settingsClient = settingsClient
    }
    func requireApplicationClient() throws -> RuntimeApplicationClient {
        guard let applicationClient else { throw ThemeFidelityCaptureError.clientUnavailable }
        return applicationClient
    }
    func requireRuntimeIO() throws -> RuntimeIOClient {
        guard let runtimeIO else { throw ThemeFidelityCaptureError.clientUnavailable }
        return runtimeIO
    }
    func requireAvailabilityClient() throws -> RuntimeAvailabilityClient {
        guard let availabilityClient else { throw ThemeFidelityCaptureError.clientUnavailable }
        return availabilityClient
    }
    func requireThemeClient() throws -> RuntimeThemeCoordinatorClient {
        guard let themeClient else { throw ThemeFidelityCaptureError.clientUnavailable }
        return themeClient
    }
    func requireSettingsClient() throws -> RuntimeSettingsClient {
        guard let settingsClient else { throw ThemeFidelityCaptureError.clientUnavailable }
        return settingsClient
    }
}

private struct ThemeFidelityClientModule: RuneScribeModule {
    let descriptor = RuneScribeUIModuleBootstrap.descriptor
    let capture: ThemeFidelityClientCapture
    func start(context: ModuleContext) async throws {
        await capture.store(
            applicationClient: try await context.applicationClient(),
            runtimeIO: try await context.runtimeIOClient(),
            availabilityClient: try await context.runtimeAvailabilityClient(),
            themeClient: try await context.themeCoordinatorClient(),
            settingsClient: try await context.runtimeSettingsClient()
        )
    }
    func stop() async {}
}

@MainActor
private struct ThemeFidelityRenderModel {
    let theme: ThemeFidelityTheme
    let descriptor: ThemeDescriptor
    let selection: SharePresentationSelection
    let glyphTokens: [String]
    let shortText: String
    let longText: String
    let previewText: String
    let previewPlan: ThemeArtifactCompositionPlan
    let highContrastPlan: ThemeArtifactCompositionPlan
    let reduceMotionPlan: ThemeArtifactCompositionPlan
    let presentation: ActiveThemeVisualPresentation
    let safePreviewData: Data?
    let safePreviewStatus: ShareSafePreviewStatus
    let safePreviewDiagnostic: String
    let safePreviewResourceMetadata: [SharePresentationResourceMetadata]
    let safePreviewRenderedResourceIDs: [String]

    var visualPlanRevision: UInt64 { presentation.revision }

    static func load(
        theme: ThemeFidelityTheme,
        descriptor: ThemeDescriptor,
        session: RuneScribeUISession
    ) async throws -> Self {
        guard let presentation = session.activeThemeVisualPresentation,
              presentation.plan.codexID == descriptor.codex.id
        else { throw ThemeFidelityCaptureError.runtimeDidNotSettle }
        let selection = try SharePresentationSelection(
            codexID: descriptor.codex.id,
            scriptID: descriptor.codex.primaryScriptID,
            relicID: session.selectedThemeRelicID ?? descriptor.codex.defaultRelicID,
            sealID: session.selectedThemeSealID,
            frameID: session.selectedThemeFrameID
        )
        guard let script = descriptor.codex.scripts.first(where: {
            $0.id == descriptor.codex.primaryScriptID
        }) else { throw ThemeFidelityCaptureError.invalidDescriptor }
        let glyphTokens = script.glyphs.prefix(14).map(\.textToken)
        let specimen = glyphTokens.joined()
        let short = specimen.isEmpty ? "RUNESCRIBE" : specimen
        let long = Array(repeating: short, count: 18).joined(separator: " ")
        let preview = Array(repeating: short, count: 4).joined(separator: " ")

        func plan(
            mode: ShareArtifactColorMode = .standard,
            reduceMotion: Bool = false
        ) throws -> ThemeArtifactCompositionPlan {
            try ThemeArtifactCompositionPolicy.interactivePlan(
                selection: selection,
                inscription: preview,
                descriptor: descriptor,
                colorMode: mode,
                reduceMotion: reduceMotion,
                accessibilityLabel: "\(descriptor.codex.displayName.fallbackValue) inscription",
                provenanceLabel: "Runtime-admitted presentation"
            )
        }

        let previewPlan = try plan()
        let safePreview = try await prepareSafePreview(
            inscription: preview,
            selection: selection,
            descriptor: descriptor,
            session: session
        )
        return try Self(
            theme: theme,
            descriptor: descriptor,
            selection: selection,
            glyphTokens: glyphTokens,
            shortText: short,
            longText: long,
            previewText: preview,
            previewPlan: previewPlan,
            highContrastPlan: plan(mode: .highContrast),
            reduceMotionPlan: plan(reduceMotion: true),
            presentation: presentation,
            safePreviewData: safePreview.data,
            safePreviewStatus: safePreview.status,
            safePreviewDiagnostic: safePreview.diagnostic,
            safePreviewResourceMetadata: safePreview.resourceMetadata,
            safePreviewRenderedResourceIDs: safePreview.resourceIDs
        )
    }

    func artwork(_ resourceID: ThemeResourceID, label: String) -> AnyView {
        if let image = presentation.image(for: resourceID) {
            return AnyView(image.resizable().scaledToFill())
        }
        return AnyView(ThemeVisualPlaceholder(systemImage: "photo", label: label))
    }

    private static func prepareSafePreview(
        inscription: String,
        selection: SharePresentationSelection,
        descriptor: ThemeDescriptor,
        session: RuneScribeUISession
    ) async throws -> (
        data: Data?,
        status: ShareSafePreviewStatus,
        diagnostic: String,
        resourceMetadata: [SharePresentationResourceMetadata],
        resourceIDs: [String]
    ) {
        let preparation = await session.makeOutboundSharePresentationWithLegacyFallback(
            inscription: inscription,
            accessibilityLabel: "\(descriptor.codex.displayName.fallbackValue) inscription",
            operationID: RuntimeOperationID(
                rawValue: "operation.theme-fidelity.received.\(descriptor.codex.id.rawValue)"
            ),
            selection: selection,
            descriptor: descriptor
        )
        let diagnostic = preparation.status.diagnosticCode
            ?? "share.presentation.status-unavailable"
        if case .themed = preparation.status,
           let outbound = preparation.presentation,
           outbound.metadata.safePreview != nil,
           let data = outbound.safePreviewData {
            return (
                data,
                .valid,
                diagnostic,
                outbound.metadata.resources,
                Array(Set(outbound.metadata.resources.map {
                    $0.resourceID.rawValue
                })).sorted()
            )
        }
        if ThemeFidelityPhase.requiresValidSafePreview {
            throw ThemeFidelityCaptureError.safePreviewUnavailable(diagnostic)
        }
        return (nil, .absent, diagnostic, [], [])
    }

}

private enum ThemeFidelityViewport {
    static let rootID = "theme-fidelity.viewport"
}

@MainActor
private struct ThemeFidelityRoute {
    static let receivedSenderName = "Freya"
    static let receivedCipherID = UUID(
        uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    )!
    static let receivedCipherName = "Cedar Key"

    let view: AnyView
    let requiredElementIDs: [String]
    let coveringElementIDs: Set<String>
    let warmup: TimeInterval

    static func make(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel,
        session: RuneScribeUISession
    ) throws -> Self {
        try configureProgression(surface: surface, model: model, session: session)
        let rootID = ThemeFidelityViewport.rootID
        var requiredIDs = [rootID]
        var coveringIDs = Set<String>()
        var warmup: TimeInterval = 0.25
        let routeAccessibilityPreferences = surface.runtimeAccessibilityPreferences
        let content: AnyView

        switch surface {
        case .workspaceEmpty:
            content = AnyView(RootView(session: session))
            let variant = "standard"
            let identifier = "theme.root-background.\(model.descriptor.id.rawValue).\(variant)"
            requiredIDs.append(identifier)
            coveringIDs.insert(identifier)
        case .composeShort:
            content = AnyView(ContentView(
                initialInputText: model.shortText,
                initialViewportProbeID: "workspace.input.compose-short"
            ))
            requiredIDs.append("workspace.input.compose-short")
        case .composeLong:
            content = AnyView(ContentView(
                initialInputText: model.longText,
                initialViewportProbeID: "workspace.input.compose-long"
            ))
            requiredIDs.append("workspace.input.compose-long")
        case .inscriptionPreview:
            content = AnyView(ContentView(initialSettledArtifact: ContentViewSettledArtifactSeed(
                composition: model.previewPlan,
                presentation: model.presentation
            )))
            let identifier = "theme.artifact-preview"
            requiredIDs.append(identifier)
        case .receivedCipher:
            content = AnyView(ReceivedMessageView(pending: try receivedMessage(model: model)))
            if model.safePreviewStatus == .valid {
                requiredIDs.append("received.safe-preview")
            }
            warmup = 0.8
        case .shareBuilder:
            let cipher = try requireActiveCipher(session)
            content = AnyView(ShareBuilderView(
                source: .cipherInvitation(cipherID: cipher.id, displayName: cipher.label),
                initialCatalog: try session.makeShareBuilderCatalog(),
                initialViewport: .controls
            ))
            let identifier = "share-builder"
            requiredIDs.append(identifier)
            warmup = 0.8
        case .staticShare:
            guard let page = model.previewPlan.pages.first else {
                throw ThemeFidelityCaptureError.renderFailed
            }
            content = AnyView(
                GeometryReader { geometry in
                    let availableWidth = max(0, geometry.size.width - 40)
                    let availableHeight = max(0, geometry.size.height - 40)
                    let canvasWidth = min(availableWidth, availableHeight * 4 / 3)
                    let canvasHeight = canvasWidth * 3 / 4
                    ZStack {
                        ZStack {
                            ThemeArtifactCanvas(
                                plan: model.previewPlan,
                                page: page,
                                context: .staticShare,
                                image: {
                                    model.presentation.image(for: $0)
                                        ?? Image(systemName: "photo")
                                }
                            )
                            .frame(width: 1_600, height: 1_200)
                            .scaleEffect(canvasWidth / 1_600, anchor: .center)
                        }
                        .frame(width: canvasWidth, height: canvasHeight)
                        .clipped()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Static share rendered by Rune Scribe")
                        .accessibilityIdentifier("theme.static-share")
                        .runtimeViewportFrameProbe("theme.static-share")
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            )
            requiredIDs.append("theme.static-share")
        case .settingsCodexCard:
            content = AnyView(SettingsView(initialViewport: .codexCard))
            let identifier = "theme.codex-card.\(model.descriptor.codex.id.rawValue)"
            requiredIDs.append(identifier)
            warmup = 0.8
        case .settingsDefaultsPreview:
            content = AnyView(SettingsView(initialViewport: .defaultsPreview))
            let identifier = "appearance.defaults-preview"
            requiredIDs.append(identifier)
            warmup = 0.8
        case .vaultLocked, .vaultEncountered, .vaultOwned, .vaultSelected:
            let artifactID = focusedVaultArtifactID(surface: surface, model: model)
            content = AnyView(VaultProgressView(
                initialSection: .vault,
                initialViewport: .artifact(artifactID)
            ))
            let identifier = "theme.vault-artifact.\(artifactID.rawValue)"
            requiredIDs.append(identifier)
            warmup = 0.8
        case .vaultProgress:
            let achievementID = AchievementID(rawValue: "achievement.first-inscription")!
            content = AnyView(VaultProgressView(
                initialSection: .achievements,
                initialViewport: .achievement(achievementID)
            ))
            requiredIDs.append("progression.achievement.\(achievementID.rawValue)")
            warmup = 0.8
        case .relicPicker:
            content = AnyView(artifactBrowser(kind: .relic, model: model))
            let identifier = "theme.artifact-picker"
            requiredIDs.append(identifier)
        case .sealPicker:
            content = AnyView(artifactBrowser(kind: .seal, model: model))
            let identifier = "theme.artifact-picker"
            requiredIDs.append(identifier)
        case .mastery:
            let reveal = try masteryReveal(model: model)
            session.revealQueue.adopt(head: reveal, canPresent: true)
            session.setRevealBlocker(.rootPresentation, active: false)
            content = AnyView(UnlockRevealView(reveal: reveal))
            requiredIDs.append("progression.unlock-reveal")
            warmup = 0.4
        case .highContrast:
            content = AnyView(ContentView(initialSettledArtifact: ContentViewSettledArtifactSeed(
                composition: model.highContrastPlan,
                presentation: model.presentation
            )))
            let identifier = "theme.artifact-preview"
            requiredIDs.append(identifier)
        case .reduceMotion:
            content = AnyView(ContentView(initialSettledArtifact: ContentViewSettledArtifactSeed(
                composition: model.reduceMotionPlan,
                presentation: model.presentation
            )))
            let identifier = "theme.artifact-preview"
            requiredIDs.append(identifier)
        case .largeText:
            content = AnyView(ContentView(
                initialInputText: model.longText,
                initialViewportProbeID: "workspace.input.large-text"
            )
                .environment(\.dynamicTypeSize, .accessibility2))
            requiredIDs.append("workspace.input.large-text")
        }

        let hosted = AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RuntimeMetalBackground()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .clipped()
                }
                .environmentObject(session)
                .environment(
                    \.runtimeApplicationResourcePresentation,
                    session.resourcePresentation
                )
                .environment(
                    \.runtimeAccessibilityPreferences,
                    routeAccessibilityPreferences
                )
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .preferredColorScheme(.dark)
                .accessibilityIdentifier(rootID)
        )
        return Self(
            view: hosted,
            requiredElementIDs: Array(Set(requiredIDs)).sorted(),
            coveringElementIDs: coveringIDs,
            warmup: warmup
        )
    }

    private static func requireActiveCipher(_ session: RuneScribeUISession) throws -> CipherViewState {
        guard let cipher = session.activeCipher else {
            throw ThemeFidelityCaptureError.runtimeDidNotSettle
        }
        return cipher
    }

    private static func receivedMessage(
        model: ThemeFidelityRenderModel
    ) throws -> PendingMessageViewState {
        let presentation = try ReceivedSharePresentation(
            requestedSelection: model.selection,
            effectiveCodexID: model.descriptor.codex.id,
            providerAvailability: .available,
            renderMode: .requestedCodex,
            safePreviewStatus: model.safePreviewStatus,
            provenanceStatus: .verified,
            encounterRecordingStatus: .recorded,
            resourceMetadata: model.safePreviewResourceMetadata
        )
        return PendingMessageViewState(try ReceivedMessageDTO(
            id: MessageID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!),
            plaintext: model.previewText,
            senderName: receivedSenderName,
            cipherID: CipherID(rawValue: receivedCipherID),
            cipherName: receivedCipherName,
            senderIdentityStatus: .trustedLocalCipher,
            presentation: presentation,
            safePreviewData: model.safePreviewData
        ))
    }

    private static func artifactBrowser(
        kind: ThemeVisualArtifactKind,
        model: ThemeFidelityRenderModel
    ) -> some View {
        let items: [ThemeArtifactBrowserItem]
        switch kind {
        case .relic:
            items = model.descriptor.codex.relics.compactMap {
                guard $0.metadata.availability != .reservedInactive else { return nil }
                return browserItem(
                    metadata: $0.metadata,
                    resourceID: $0.thumbnailResourceID,
                    kind: .relic,
                    selectedID: model.selection.relicID
                )
            }
        case .seal:
            items = model.descriptor.codex.seals.compactMap {
                guard $0.metadata.availability != .reservedInactive else { return nil }
                return browserItem(
                    metadata: $0.metadata,
                    resourceID: $0.thumbnailResourceID,
                    kind: .seal,
                    selectedID: model.selection.sealID
                )
            }
        case .frame, .crest:
            items = []
        }
        return NavigationStack {
            ThemeArtifactBrowserView(
                title: kind == .relic ? "Choose Relic" : "Choose Seal",
                items: items,
                includesNone: false,
                canSelectNone: false,
                selectNone: {},
                select: { _ in }
            ) { item in
                model.artwork(item.resourceID, label: item.accessibilityLabel)
            }
        }
    }

    private static func browserItem(
        metadata: ThemeArtifactMetadata,
        resourceID: ThemeResourceID,
        kind: ThemeVisualArtifactKind,
        selectedID: ArtifactID?
    ) -> ThemeArtifactBrowserItem {
        let state: ThemeVisualContentState = if metadata.id == selectedID {
            .selected
        } else if metadata.availability == .included {
            .owned
        } else {
            .locked
        }
        return ThemeArtifactBrowserItem(
            id: metadata.id,
            resourceID: resourceID,
            name: metadata.displayName.fallbackValue,
            description: metadata.description.fallbackValue,
            kind: kind,
            rarity: metadata.rarity,
            state: state,
            accessibilityLabel: metadata.accessibility.label.fallbackValue,
            accessibilityHint: metadata.accessibility.hint?.fallbackValue,
            provenance: nil,
            isSelectable: state == .owned || state == .selected
        )
    }

    private static func configureProgression(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel,
        session: RuneScribeUISession
    ) throws {
        session.resetRevealPresentationState()
        var ownership: [ProgressionOwnershipDTO] = []
        let gates: [ProgressionCodexGateDTO] = []
        var achievements: [ProgressionAchievementDTO] = []
        if surface == .vaultEncountered || surface == .vaultOwned {
            let artifact = focusedVaultArtifactID(surface: surface, model: model)
            let metadata = metadata(for: artifact, model: model)
            ownership = [try ProgressionOwnershipDTO(
                kind: contentKind(for: artifact, model: model),
                reference: .artifact(artifact),
                presentation: try ProgressionPresentationDTO(
                    displayName: metadata.displayName.fallbackValue,
                    summary: metadata.description.fallbackValue,
                    fallbackSystemImageName: "sparkles"
                ),
                state: surface == .vaultEncountered ? .encountered : .owned,
                firstEncounteredAt: Date(timeIntervalSince1970: 1_699_999_000),
                grantedAt: surface == .vaultOwned
                    ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
                providerAvailability: surface == .vaultOwned ? .active : .unavailable,
                renderState: surface == .vaultOwned ? .providerAvailable : .genericFallback
            )]
        }
        if surface == .vaultProgress {
            achievements = [try ProgressionAchievementDTO(
                achievementID: AchievementID(rawValue: "achievement.first-inscription")!,
                presentation: try ProgressionPresentationDTO(
                    displayName: "First Inscription",
                    summary: "Complete your first unique inscription.",
                    fallbackSystemImageName: "pencil.and.scribble"
                ),
                completedRuleCount: 0,
                requiredRuleCount: 1,
                progress: try ProgressionNumericProgressDTO(current: 0, target: 1),
                completedAt: nil,
                isHidden: false,
                localPointWeight: 5,
                rewards: try ProgressionRewardSummaryDTO(
                    contentIDs: [ArtifactID(rawValue: "seal.norse.mjolnir")!]
                )
            )]
        }
        let revision = UInt64(10_000 + surface.rawValue.utf8.reduce(0) { $0 + Int($1) })
        session.progressionSnapshot = try ProgressionSnapshotDTO(
            revision: revision,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            availability: .available,
            storeHealth: .loaded,
            catalogID: nil,
            catalogVersion: nil,
            codexGates: gates,
            achievements: achievements,
            ownership: ownership
        )
        session.progressionRailState = .available
    }

    private static func focusedVaultArtifactID(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel
    ) -> ArtifactID {
        if surface == .vaultSelected { return model.selection.relicID }
        return model.descriptor.codex.relics.first(where: {
            $0.metadata.availability != .included
                && $0.metadata.availability != .reservedInactive
        })?.metadata.id ?? model.selection.relicID
    }

    private static func metadata(
        for artifactID: ArtifactID,
        model: ThemeFidelityRenderModel
    ) -> ThemeArtifactMetadata {
        if let relic = model.descriptor.codex.relics.first(where: {
            $0.metadata.id == artifactID
        }) { return relic.metadata }
        if let seal = model.descriptor.codex.seals.first(where: {
            $0.metadata.id == artifactID
        }) { return seal.metadata }
        return model.descriptor.codex.relics[0].metadata
    }

    private static func contentKind(
        for artifactID: ArtifactID,
        model: ThemeFidelityRenderModel
    ) -> ProgressionContentKind {
        model.descriptor.codex.seals.contains(where: { $0.metadata.id == artifactID })
            ? .seal : .relic
    }

    private static func masteryReveal(
        model: ThemeFidelityRenderModel
    ) throws -> ProgressionRevealSummaryDTO {
        var secondary: [ProgressionContentReference] = []
        if let frame = model.descriptor.codex.frames.first {
            secondary.append(.artifact(frame.metadata.id))
        }
        if let crest = model.descriptor.codex.crests.first,
           let crestID = CrestID(rawValue: crest.metadata.id.rawValue) {
            secondary.append(.crest(crestID))
        }
        secondary.append(.title(model.theme.masteryTitleID))
        return try ProgressionRevealSummaryDTO(
            revealID: RevealID(rawValue: "reveal.\(model.theme.slug).mastery")!,
            transactionID: GrantTransactionID(
                rawValue: "transaction.\(model.theme.slug).mastery"
            )!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .presented,
            tier: .mastery,
            rarity: .mythic,
            primaryRewardID: .codex(model.descriptor.codex.id),
            primaryRewardPresentation: try ProgressionPresentationDTO(
                displayName: "\(model.descriptor.codex.displayName.fallbackValue) Mastery",
                summary: "Frame, crest, and Keeper title earned.",
                fallbackSystemImageName: "crown.fill"
            ),
            secondaryRewardIDs: secondary,
            sourceAchievementIDs: [
                AchievementID(rawValue: "achievement.\(model.theme.slug).mastery")!,
            ]
        )
    }
}

@MainActor
private final class ThemeFidelityViewportProbeStore {
    private(set) var frames: [String: CGRect] = [:]

    func reset() {
        frames.removeAll(keepingCapacity: true)
    }

    func record(identifier: String, frame: CGRect) {
        frames[identifier] = frame
    }

    func record(_ reportedFrames: [String: CGRect]) {
        frames.merge(reportedFrames, uniquingKeysWith: { _, latest in latest })
    }
}

#if os(macOS)
@MainActor
private struct ThemeFidelityNativeViewportProbe: NSViewRepresentable {
    let identifier: String
    let store: ThemeFidelityViewportProbeStore

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.probeIdentifier = identifier
        view.store = store
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.probeIdentifier = identifier
        view.store = store
        view.needsLayout = true
    }

    final class ProbeView: NSView {
        var probeIdentifier = ""
        weak var store: ThemeFidelityViewportProbeStore?

        override func layout() {
            super.layout()
            store?.record(
                identifier: probeIdentifier,
                frame: CGRect(origin: .zero, size: bounds.size)
            )
        }
    }
}
#elseif os(iOS)
@MainActor
private struct ThemeFidelityNativeViewportProbe: UIViewRepresentable {
    let identifier: String
    let store: ThemeFidelityViewportProbeStore

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.identifier = identifier
        view.store = store
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.identifier = identifier
        view.store = store
        view.setNeedsLayout()
    }

    final class ProbeView: UIView {
        var identifier = ""
        weak var store: ThemeFidelityViewportProbeStore?

        override func layoutSubviews() {
            super.layoutSubviews()
            store?.record(
                identifier: identifier,
                frame: CGRect(origin: .zero, size: bounds.size)
            )
        }
    }
}
#endif

@MainActor
private final class ThemeFidelityPersistentRenderer {
    #if os(macOS)
    private let hostingView: NSHostingView<AnyView>
    private let window: NSWindow
    #elseif os(iOS)
    private let controller: UIHostingController<AnyView>
    private let window: UIWindow
    #endif

    init() {
        #if os(macOS)
        _ = NSApplication.shared
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderBack(nil)
        #elseif os(iOS)
        controller = UIHostingController(rootView: AnyView(EmptyView()))
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.rootViewController = controller
        window.isHidden = false
        #endif
    }

    func render(
        _ view: AnyView,
        identity: String,
        destination: ThemeFidelityDestination,
        requiredElementIDs: [String],
        coveringElementIDs: Set<String>,
        warmup: TimeInterval
    ) throws -> ThemeFidelityRenderedPNG {
        let probeStore = ThemeFidelityViewportProbeStore()
        probeStore.reset()
        #if os(macOS)
        let bounds = NSRect(origin: .zero, size: destination.pointSize)
        window.setContentSize(destination.pointSize)
        hostingView.frame = bounds
        hostingView.rootView = probedView(
            view.id(identity)
                .frame(width: destination.pointSize.width,
                       height: destination.pointSize.height),
            store: probeStore
        )
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: warmup))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let refreshProbes = { [self] in
            self.hostingView.layoutSubtreeIfNeeded()
            self.hostingView.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            self.hostingView.layoutSubtreeIfNeeded()
        }
        refreshProbes()
        revealRequiredElementIfNeeded(
            root: hostingView,
            store: probeStore,
            requiredElementIDs: requiredElementIDs,
            coveringElementIDs: coveringElementIDs,
            refreshProbes: refreshProbes
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        else { throw ThemeFidelityCaptureError.renderFailed }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:])
        else { throw ThemeFidelityCaptureError.renderFailed }
        return ThemeFidelityRenderedPNG(
            data: png,
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh,
            viewportAssertions: viewportAssertions(
                viewportBounds: hostingView.bounds,
                frames: probeStore.frames,
                requiredElementIDs: requiredElementIDs,
                coveringElementIDs: coveringElementIDs
            ),
            elementFrames: ThemeFidelityElementFrames(
                pointFrames: probeStore.frames,
                scale: destination.scale
            ),
            renderedResourceIDs: [],
            renderedResourceBindings: []
        )
        #elseif os(iOS)
        let bounds = CGRect(origin: .zero, size: destination.pointSize)
        window.frame = bounds
        controller.rootView = probedView(
            view.id(identity)
                .frame(width: destination.pointSize.width,
                       height: destination.pointSize.height),
            store: probeStore
        )
        controller.view.frame = bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: warmup))
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = destination.scale
        format.opaque = true
        let probeFormat = UIGraphicsImageRendererFormat()
        probeFormat.scale = 0.1
        probeFormat.opaque = true
        let refreshProbes = { [self] in
            _ = UIGraphicsImageRenderer(
                size: destination.pointSize,
                format: probeFormat
            ).image {
                _ in self.controller.view.drawHierarchy(
                    in: bounds,
                    afterScreenUpdates: true
                )
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            self.controller.view.layoutIfNeeded()
        }
        refreshProbes()
        revealRequiredElementIfNeeded(
            root: controller.view,
            store: probeStore,
            requiredElementIDs: requiredElementIDs,
            coveringElementIDs: coveringElementIDs,
            refreshProbes: refreshProbes
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: destination.pointSize, format: format).image {
            _ in controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        guard let cgImage = image.cgImage, let png = image.pngData()
        else { throw ThemeFidelityCaptureError.renderFailed }
        return ThemeFidelityRenderedPNG(
            data: png,
            width: cgImage.width,
            height: cgImage.height,
            viewportAssertions: viewportAssertions(
                viewportBounds: controller.view.bounds,
                frames: probeStore.frames,
                requiredElementIDs: requiredElementIDs,
                coveringElementIDs: coveringElementIDs
            ),
            elementFrames: ThemeFidelityElementFrames(
                pointFrames: probeStore.frames,
                scale: destination.scale
            ),
            renderedResourceIDs: [],
            renderedResourceBindings: []
        )
        #endif
    }

    func close() {
        #if os(macOS)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        #elseif os(iOS)
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }

    private func probedView<V: View>(
        _ view: V,
        store: ThemeFidelityViewportProbeStore
    ) -> AnyView {
        AnyView(
            view
                .environment(\.runtimeViewportFrameProbeEnabled, true)
                .coordinateSpace(name: RuntimeViewportFrameProbeCoordinateSpace.name)
                .overlay {
                    ThemeFidelityNativeViewportProbe(
                        identifier: ThemeFidelityViewport.rootID,
                        store: store
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
                .onPreferenceChange(RuntimeViewportFramePreferenceKey.self) {
                    store.record($0)
                }
        )
    }

    private func viewportAssertions(
        viewportBounds: CGRect,
        frames: [String: CGRect],
        requiredElementIDs: [String],
        coveringElementIDs: Set<String>
    ) -> ThemeFidelityViewportAssertions {
        let toleranceBounds = viewportBounds.insetBy(dx: -0.5, dy: -0.5)
        let required = Array(Set(requiredElementIDs)).sorted()
        let clipped = required.filter { identifier in
            guard let frame = frames[identifier] else { return true }
            guard !frame.isNull, !frame.isEmpty else { return true }
            if coveringElementIDs.contains(identifier) {
                return !frame.insetBy(dx: -0.5, dy: -0.5).contains(viewportBounds)
            }
            return !toleranceBounds.contains(frame)
        }
        return ThemeFidelityViewportAssertions(
            requiredElementCount: required.count,
            requiredElementIDs: required,
            clippedElementIDs: clipped
        )
    }

    #if os(macOS)
    private func revealRequiredElementIfNeeded(
        root: NSView,
        store: ThemeFidelityViewportProbeStore,
        requiredElementIDs: [String],
        coveringElementIDs: Set<String>,
        refreshProbes: () -> Void
    ) {
        let viewportBounds = root.bounds.insetBy(dx: -0.5, dy: -0.5)
        guard let targetID = requiredElementIDs.first(where: { identifier in
            guard !coveringElementIDs.contains(identifier),
                  identifier != ThemeFidelityViewport.rootID
            else { return false }
            guard let frame = store.frames[identifier] else { return true }
            return frame.isNull || frame.isEmpty || !viewportBounds.contains(frame)
        }) else { return }

        let scrollViews = descendants(of: root).compactMap { $0 as? NSScrollView }
        guard let scrollView = scrollViews.max(by: {
            verticalScrollRange($0) < verticalScrollRange($1)
        }), verticalScrollRange(scrollView) > 1,
              let documentView = scrollView.documentView
        else { return }

        let clipView = scrollView.contentView
        let documentBounds = documentView.bounds
        let viewportHeight = clipView.bounds.height
        let minimumY = documentBounds.minY
        let maximumY = max(minimumY, documentBounds.maxY - viewportHeight)
        let scanDirection: CGFloat = documentView.isFlipped ? 1 : -1

        func scroll(to proposedPoint: NSPoint) {
            let maximumX = max(documentBounds.minX,
                               documentBounds.maxX - clipView.bounds.width)
            let point = NSPoint(
                x: min(max(proposedPoint.x, documentBounds.minX), maximumX),
                y: min(max(proposedPoint.y, minimumY), maximumY)
            )
            clipView.scroll(to: point)
            scrollView.reflectScrolledClipView(clipView)
            refreshProbes()
        }

        if store.frames[targetID] == nil {
            let step = max(1, viewportHeight * 0.7)
            let maximumSteps = min(
                24,
                Int(ceil(verticalScrollRange(scrollView) / step)) + 2
            )
            var point = clipView.bounds.origin
            for _ in 0..<maximumSteps {
                point.y += scanDirection * step
                scroll(to: point)
                if store.frames[targetID] != nil { break }
                let reachedEnd = documentView.isFlipped
                    ? clipView.bounds.origin.y >= maximumY - 0.5
                    : clipView.bounds.origin.y <= minimumY + 0.5
                if reachedEnd { break }
            }
        }

        for _ in 0..<3 {
            guard let frame = store.frames[targetID],
                  !frame.isNull, !frame.isEmpty
            else { break }
            let deltaY = frame.midY - root.bounds.midY
            let deltaX = frame.midX - root.bounds.midX
            if abs(deltaY) <= 0.5, abs(deltaX) <= 0.5 { break }
            let current = clipView.bounds.origin
            scroll(to: NSPoint(
                x: current.x + deltaX,
                y: current.y + scanDirection * deltaY
            ))
        }
    }

    private func verticalScrollRange(_ scrollView: NSScrollView) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        return max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.reduce(into: [NSView]()) { result, child in
            result.append(child)
            result.append(contentsOf: descendants(of: child))
        }
    }
    #endif

    #if os(iOS)
    private func revealRequiredElementIfNeeded(
        root: UIView,
        store: ThemeFidelityViewportProbeStore,
        requiredElementIDs: [String],
        coveringElementIDs: Set<String>,
        refreshProbes: () -> Void
    ) {
        let viewportBounds = root.bounds.insetBy(dx: -0.5, dy: -0.5)
        guard let targetID = requiredElementIDs.first(where: { identifier in
            guard !coveringElementIDs.contains(identifier),
                  identifier != ThemeFidelityViewport.rootID
            else { return false }
            guard let frame = store.frames[identifier] else { return true }
            return frame.isNull || frame.isEmpty || !viewportBounds.contains(frame)
        }) else { return }

        let scrollViews = descendants(of: root).compactMap { $0 as? UIScrollView }
            .filter { $0.isScrollEnabled && $0.contentSize.height > $0.bounds.height + 1 }
        guard let scrollView = scrollViews.max(by: {
            ($0.contentSize.height - $0.bounds.height)
                < ($1.contentSize.height - $1.bounds.height)
        }) else { return }

        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let step = max(1, scrollView.bounds.height * 0.7)
        var proposedY = min(maximumY, max(minimumY, scrollView.contentOffset.y))
        while store.frames[targetID] == nil && proposedY < maximumY {
            proposedY = min(maximumY, proposedY + step)
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: proposedY),
                animated: false
            )
            scrollView.layoutIfNeeded()
            refreshProbes()
        }

        for _ in 0..<3 {
            guard let targetFrame = store.frames[targetID],
                  !targetFrame.isNull, !targetFrame.isEmpty
            else { return }
            let visibleFrame = scrollView.convert(scrollView.bounds, to: root)
            guard !viewportBounds.contains(targetFrame) else { return }
            let delta = targetFrame.midY - visibleFrame.midY
            proposedY = min(
                maximumY,
                max(minimumY, scrollView.contentOffset.y + delta)
            )
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: proposedY),
                animated: false
            )
            scrollView.layoutIfNeeded()
            refreshProbes()
        }
    }

    private func descendants(of root: UIView) -> [UIView] {
        root.subviews.reduce(into: [root]) { result, child in
            result.append(contentsOf: descendants(of: child))
        }
    }
    #endif
}
