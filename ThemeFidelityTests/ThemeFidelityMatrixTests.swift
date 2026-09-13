import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@_spi(ThemeFidelityQualification) import RuneScribeContracts
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
    func testViewportRevealPrefersOutermostClippedRequiredElement() {
        let viewport = CGRect(x: 0, y: 0, width: 980, height: 720)
        let composeID = "theme.compose.short.codex.norse"
        let previewID = "theme.artifact-preview.relic.norse.runestone-tablet"
        let frames = [
            composeID: CGRect(x: 24, y: 150, width: 932, height: 612),
            previewID: CGRect(x: 230, y: 400, width: 504, height: 378),
        ]

        XCTAssertEqual(
            ThemeFidelityViewportRevealPolicy.targetID(
                viewportBounds: viewport,
                frames: frames,
                requiredElementIDs: [previewID, composeID],
                coveringElementIDs: []
            ),
            composeID
        )
    }

    func testExportCanonicalNorseSealResources() async throws {
        continueAfterFailure = false

        let bundle = Bundle(for: Self.self)
        let registry = try ThemeCanonicalRenderRegistry.load(bundle: bundle)
        let seedRegistry = try ThemeCanonicalSeedRegistry.load(bundle: bundle)
        let candidates = registry.catalog.candidates.filter {
            $0.renderMode == .resolvedResourceExport
        }.sorted { $0.id < $1.id }
        XCTAssertEqual(candidates.count, 6)
        var requestsByID: [String: ThemeCanonicalRenderRequest] = [:]
        for candidate in candidates {
            requestsByID[candidate.id] = try registry.request(
                candidateID: candidate.id,
                seedRegistry: seedRegistry
            )
        }
        XCTAssertEqual(requestsByID.count, 6)

        func resolveAll() async throws -> (
            outputs: [String: Data],
            resourceIDs: [String: String],
            visualPlanRevision: UInt64
        ) {
            let fixture = try await ThemeFidelityRuntimeFixture.start()
            do {
                let firstCandidate = try XCTUnwrap(candidates.first)
                let firstRequest = try XCTUnwrap(requestsByID[firstCandidate.id])
                let firstSeedState = try ThemeCanonicalResolvedSeedState(
                    candidate: firstCandidate,
                    request: firstRequest,
                    registry: seedRegistry
                )
                try await fixture.select(firstSeedState.primary)
                let descriptor = try await fixture.themeClient.providerDescriptor(
                    for: firstSeedState.primary.codexID
                )
                XCTAssertEqual(descriptor.id.rawValue, firstRequest.themeID)
                let boundSealIDs = try Set(candidates.map {
                    try registry.resolvedResourceArtifactID(candidateID: $0.id)
                })
                XCTAssertEqual(
                    boundSealIDs,
                    Set(descriptor.codex.seals.map { $0.metadata.id.rawValue })
                )
                guard let revision = fixture.session.activeThemeVisualPresentation?.revision
                else { throw ThemeFidelityCaptureError.runtimeDidNotSettle }
                var outputs: [String: Data] = [:]
                var resourceIDs: [String: String] = [:]
                for candidate in candidates {
                    let request = try XCTUnwrap(requestsByID[candidate.id])
                    let seedState = try ThemeCanonicalResolvedSeedState(
                        candidate: candidate,
                        request: request,
                        registry: seedRegistry
                    )
                    guard seedState.primary == firstSeedState.primary,
                          let sealID = ArtifactID(rawValue:
                              try registry.resolvedResourceArtifactID(
                                  candidateID: candidate.id
                              ))
                    else { throw ThemeFidelityCaptureError.invalidDescriptor }
                    guard let seal = descriptor.codex.seals.first(where: {
                        $0.metadata.id == sealID
                    }) else { throw ThemeFidelityCaptureError.invalidDescriptor }
                    let resourceID = seal.standardResourceID
                    let resolved = try await fixture.themeClient.resolveCatalogPreviewResource(
                        codexID: descriptor.codex.id,
                        resourceID: resourceID
                    )
                    let data = try ThemeCanonicalResolvedResourceValidator.validate(
                        .resolvedProductionResource(resolved.data),
                        candidateID: candidate.id,
                        expectedByteCount: candidate.referenceByteCount,
                        expectedSHA256: candidate.referenceSHA256
                    )
                    try verifyResolvedResourceWrapper(
                        data: data,
                        request: request
                    )
                    let digest = SHA256.hash(data: data).map {
                        String(format: "%02x", $0)
                    }.joined()
                    let dimensions = try ThemeFidelityEvidence.pngDimensions(data)
                    XCTAssertEqual(data.count, candidate.referenceByteCount)
                    XCTAssertEqual(digest, candidate.referenceSHA256)
                    XCTAssertEqual(dimensions.width, request.width)
                    XCTAssertEqual(dimensions.height, request.height)
                    outputs[candidate.id] = data
                    resourceIDs[candidate.id] = resourceID.rawValue
                }
                await fixture.stop()
                return (outputs, resourceIDs, revision)
            } catch {
                await fixture.stop()
                throw error
            }
        }

        let first = try await resolveAll()
        let second = try await resolveAll()
        XCTAssertEqual(first.outputs.keys.sorted(), candidates.map(\.id))
        XCTAssertEqual(first.resourceIDs, second.resourceIDs)
        for candidate in candidates {
            let firstData = try XCTUnwrap(first.outputs[candidate.id])
            let secondData = try XCTUnwrap(second.outputs[candidate.id])
            XCTAssertEqual(firstData, secondData, candidate.id)
        }

        guard let outputRootValue = ProcessInfo.processInfo.environment[
            "RUNESCRIBE_THEME_FIDELITY_CANONICAL_ROOT"
        ], !outputRootValue.isEmpty else { return }
        let sourceSHA = try XCTUnwrap(
            ProcessInfo.processInfo.environment["RUNESCRIBE_THEME_FIDELITY_SOURCE_SHA"]
        )
        XCTAssertFalse(sourceSHA.isEmpty)
        let outputRoot = URL(fileURLWithPath: outputRootValue, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        for candidate in candidates {
            let request = try XCTUnwrap(requestsByID[candidate.id])
            let data = try XCTUnwrap(first.outputs[candidate.id])
            let outputURL = outputRoot.appendingPathComponent(request.outputPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
            let sidecar = ThemeFidelityCanonicalResourceSidecar(
                schemaVersion: "1.0",
                candidateID: candidate.id,
                wrapperID: request.wrapperID,
                sourceSHA: sourceSHA,
                seedID: request.seedID,
                renderMode: "resolved-resource-export",
                resourceID: try XCTUnwrap(first.resourceIDs[candidate.id]),
                visualPlanRevisions: [
                    first.visualPlanRevision,
                    second.visualPlanRevision,
                ],
                width: request.width,
                height: request.height,
                byteCount: data.count,
                sha256: candidate.referenceSHA256,
                determinism: first.outputs[candidate.id] == second.outputs[candidate.id],
                outputPath: request.outputPath
            )
            let sidecarURL = outputURL
                .deletingPathExtension()
                .appendingPathExtension("sidecar.json")
            try encoder.encode(sidecar).write(to: sidecarURL, options: .atomic)
        }
    }

    private func verifyResolvedResourceWrapper(
        data: Data,
        request: ThemeCanonicalRenderRequest
    ) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ThemeFidelityCaptureError.renderFailed }
        let content = try ThemeCanonicalQualificationHost().content(
            AnyView(
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            ),
            request: request
        )
        let destination = ThemeFidelityDestination(
            name: "Canonical resolved resource wrapper",
            slug: "canonical-resolved-resource-wrapper",
            pointSize: CGSize(width: request.width, height: request.height),
            scale: 1
        )
        let renderer = ThemeFidelityPersistentRenderer(ignoresSafeAreaInsets: true)
        defer { renderer.close() }
        let rendered = try renderer.render(
            content,
            identity: request.wrapperID,
            destination: destination,
            requiredElementIDs: request.requiredCaptureElementIDs,
            coveringElementIDs: [],
            warmup: 0
        )
        XCTAssertEqual(
            rendered.viewportAssertions.requiredElementIDs,
            [request.wrapperID]
        )
        XCTAssertTrue(rendered.viewportAssertions.clippedElementIDs.isEmpty)
    }

    func testExportCanonicalProductionRenders() async throws {
        #if os(iOS)
        guard let outputRootValue = ProcessInfo.processInfo.environment[
            "RUNESCRIBE_THEME_FIDELITY_CANONICAL_ROOT"
        ], !outputRootValue.isEmpty else { return }
        let sourceSHA = try XCTUnwrap(
            ProcessInfo.processInfo.environment["RUNESCRIBE_THEME_FIDELITY_SOURCE_SHA"]
        )
        XCTAssertFalse(sourceSHA.isEmpty)

        let registry = try ThemeCanonicalRenderRegistry.load(bundle: Bundle(for: Self.self))
        let seedRegistry = try ThemeCanonicalSeedRegistry.load(bundle: Bundle(for: Self.self))
        let requestedCandidateID = ProcessInfo.processInfo.environment[
            "RUNESCRIBE_THEME_FIDELITY_CANONICAL_CANDIDATE"
        ].flatMap { $0.isEmpty ? nil : $0 }
        let candidates = registry.catalog.candidates.filter { candidate in
            candidate.renderMode != .resolvedResourceExport
                && (requestedCandidateID == nil || requestedCandidateID == candidate.id)
        }
        XCTAssertFalse(candidates.isEmpty)
        let outputRoot = URL(fileURLWithPath: outputRootValue, isDirectory: true)

        for candidate in candidates {
            let request = try registry.request(
                candidateID: candidate.id,
                seedRegistry: seedRegistry
            )
            let binding = try registry.productionBinding(candidateID: candidate.id)
            let first = try await canonicalProductionRender(
                candidate: candidate,
                request: request,
                binding: binding
            )
            let second = try await canonicalProductionRender(
                candidate: candidate,
                request: request,
                binding: binding
            )
            XCTAssertEqual(first.resourceIDs, second.resourceIDs, candidate.id)
            XCTAssertEqual(first.visualPlanRevision, second.visualPlanRevision, candidate.id)
            _ = try ThemeCanonicalOutputRecorder.record(
                request: ThemeCanonicalRenderRequest(
                    candidateID: request.candidateID,
                    wrapperID: request.wrapperID,
                    themeName: request.themeName,
                    themeID: request.themeID,
                    codexID: request.codexID,
                    seedID: request.seedID,
                    seedIDs: request.seedIDs,
                    recipe: request.recipe,
                    renderMode: request.renderMode,
                    width: request.width,
                    height: request.height,
                    locale: request.locale,
                    timeZone: request.timeZone,
                    colorScheme: request.colorScheme,
                    dynamicType: request.dynamicType,
                    contrastMode: request.contrastMode,
                    reduceMotion: request.reduceMotion,
                    animationsEnabled: request.animationsEnabled,
                    testClock: request.testClock,
                    expectedProductionResourceIDs: first.resourceIDs,
                    outputPath: request.outputPath
                ),
                first: first.data,
                second: second.data,
                sourceSHA: sourceSHA,
                visualPlanRevision: first.visualPlanRevision,
                runtimeState: first.runtimeState,
                outputRoot: outputRoot
            )
        }
        #endif
    }

    #if os(iOS)
    private func canonicalProductionRender(
        candidate: ThemeCanonicalCatalog.Candidate,
        request: ThemeCanonicalRenderRequest,
        binding: ThemeCanonicalProductionBinding
    ) async throws -> ThemeCanonicalQualificationHost.RenderedOutput {
        guard let theme = ThemeFidelityTheme.allCases.first(where: {
            $0.slug == request.themeName
        }) else { throw ThemeFidelityCaptureError.invalidDescriptor }

        let seedRegistry = try ThemeCanonicalSeedRegistry.load(bundle: Bundle(for: Self.self))
        let seedState = try ThemeCanonicalResolvedSeedState(
            candidate: candidate,
            request: request,
            registry: seedRegistry
        )
        guard seedState.primary.codexID == theme.codexID else {
            throw ThemeFidelityCaptureError.invalidDescriptor
        }

        let fixture = try await ThemeFidelityRuntimeFixture.start()
        let renderer = ThemeFidelityPersistentRenderer(
            ignoresSafeAreaInsets: request.renderMode != .fullProductionScreen
        )
        do {
            try await fixture.select(seedState.primary)
            let descriptor = try await fixture.themeClient.providerDescriptor(
                for: theme.codexID
            )
            let route: ThemeFidelityCanonicalProductionRoute.Route
            switch binding {
            case .fullScreen:
                var content = try await ThemeFidelityQualificationRoute.make(
                    launch: seedState.primary,
                    session: fixture.session
                )
                if candidate.recipeClass == .fullScreenReceivedShareCard {
                    let model = try await ThemeFidelityRenderModel.load(
                        theme: theme,
                        descriptor: descriptor,
                        session: fixture.session
                    )
                    content = try ThemeFidelityCanonicalProductionRoute.receivedShareCard(
                        model: model,
                        session: fixture.session
                    )
                }
                route = try ThemeFidelityCanonicalProductionRoute.fullScreenRoute(
                    candidate: candidate,
                    content: content,
                    seedState: seedState,
                    session: fixture.session
                )
            case .resolvedResource, .artifactSpecimen, .productionComponent:
                let resourceIDs = try ThemeFidelityCanonicalProductionRoute.requiredResourceIDs(
                    candidate: candidate,
                    binding: binding,
                    descriptor: descriptor
                )
                let imageResourceIDs = Set(resourceIDs.filter { resourceID in
                    guard let reference = descriptor.resources.first(where: {
                        $0.id == resourceID
                    }) else { return false }
                    return reference.mediaType == .png
                        || reference.mediaType == .heif
                        || reference.mediaType == .pdf
                })
                try await fixture.session.loadThemeFidelityQualificationVisuals(
                    codexID: descriptor.codex.id,
                    resourceIDs: imageResourceIDs
                )
                let model = try await ThemeFidelityRenderModel.load(
                    theme: theme,
                    descriptor: descriptor,
                    session: fixture.session
                )
                route = try ThemeFidelityCanonicalProductionRoute.make(
                    candidate: candidate,
                    binding: binding,
                    model: model,
                    session: fixture.session,
                    resourceIDs: resourceIDs,
                    seedState: seedState
                )
            }
            let destination = ThemeFidelityDestination(
                name: "Canonical production host",
                slug: "canonical-production-host",
                pointSize: CGSize(width: request.width, height: request.height),
                scale: 1
            )
            let canonicalView = try ThemeCanonicalQualificationHost().content(
                route.view,
                request: request
            )
            var observedResourceIDs = Set<ThemeResourceID>()
            fixture.session.resourcePresentation.beginRenderedResourceObservation {
                observedResourceIDs.insert($0.resourceID)
            }
            RuntimeThemeSemanticResourceUseObservation.begin {
                observedResourceIDs.insert($0)
            }
            let rendered: ThemeFidelityRenderedPNG
            do {
                rendered = try renderer.render(
                    canonicalView,
                    identity: request.wrapperID,
                    destination: destination,
                    requiredElementIDs: request.requiredCaptureElementIDs,
                    coveringElementIDs: [],
                    warmup: route.warmup
                )
            } catch {
                RuntimeThemeSemanticResourceUseObservation.end()
                fixture.session.resourcePresentation.endRenderedResourceObservation()
                throw error
            }
            RuntimeThemeSemanticResourceUseObservation.end()
            fixture.session.resourcePresentation.endRenderedResourceObservation()
            let finalResourceIDs = Set(route.resourceIDs).union(
                observedResourceIDs.map(\.rawValue)
            ).sorted()
            guard let visualPlanRevision = fixture.session.activeThemeVisualPresentation?
                .revision
            else { throw ThemeFidelityCaptureError.runtimeDidNotSettle }
            renderer.close()
            await fixture.stop()
            return ThemeCanonicalQualificationHost.RenderedOutput(
                data: rendered.data,
                width: rendered.width,
                height: rendered.height,
                resourceIDs: finalResourceIDs,
                visualPlanRevision: visualPlanRevision,
                runtimeState: route.runtimeState
            )
        } catch {
            renderer.close()
            await fixture.stop()
            throw error
        }
    }
    #endif

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
        var reduceMotionAttachmentCount = 0
        var rendererOutputAttachmentCount = 0
        var optionalLockedAttachmentCount = 0
        for theme in themes {
            try await fixture.select(theme)
            let descriptor = try await fixture.themeClient.providerDescriptor(for: theme.codexID)
            let model = try await ThemeFidelityRenderModel.load(
                theme: theme,
                descriptor: descriptor,
                session: fixture.session
            )
            guard let snapshot = fixture.session.themeSnapshot,
                  snapshot.effectiveCodexID == descriptor.codex.id,
                  snapshot.effectiveTheme.id == descriptor.id
            else { throw ThemeFidelityCaptureError.runtimeDidNotSettle }
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
                    var stabilityCaptureB: ThemeFidelityImageCapture?
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
                        if surface == .reduceMotion {
                            try await Task.sleep(for: .milliseconds(1_550))
                            stabilityCaptureB = try renderer.recapture(
                                destination: destination
                            )
                        }
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

                    let reduceMotionStability: ThemeFidelityReduceMotionStability?
                    if surface == .reduceMotion {
                        guard let captureB = stabilityCaptureB else {
                            throw ThemeFidelityCaptureError.renderFailed
                        }
                        let separation = captureB.capturedAt.timeIntervalSince(
                            rendered.capturedAt
                        )
                        XCTAssertGreaterThanOrEqual(separation, 1.5)
                        XCTAssertEqual(captureB.width, rendered.width)
                        XCTAssertEqual(captureB.height, rendered.height)
                        XCTAssertTrue(
                            attachmentNames.insert(name.reduceMotionCaptureB).inserted,
                            name.reduceMotionCaptureB
                        )
                        attach(
                            captureB.data,
                            name: name.reduceMotionCaptureB,
                            type: "public.png"
                        )
                        reduceMotionAttachmentCount += 1
                        reduceMotionStability = try ThemeFidelityReduceMotionStability(
                            captureATimestamp: ThemeFidelityEvidence.iso8601(
                                rendered.capturedAt
                            ),
                            captureBTimestamp: ThemeFidelityEvidence.iso8601(
                                captureB.capturedAt
                            ),
                            separationSeconds: separation,
                            captureASHA256: digest,
                            captureBSHA256: Self.sha256(captureB.data),
                            captureBAttachmentName: name.reduceMotionCaptureB,
                            luminanceSSIM: ThemeFidelityEvidence.luminanceSSIM(
                                rendered.data,
                                captureB.data
                            )
                        )
                    } else {
                        reduceMotionStability = nil
                    }

                    var rendererOutputs: [ThemeFidelityRendererOutput] = []
                    if surface == .staticShare {
                        guard let outputData = model.safePreviewData else {
                            throw ThemeFidelityCaptureError.safePreviewUnavailable(
                                model.safePreviewDiagnostic
                            )
                        }
                        let dimensions = try ThemeFidelityEvidence.pngDimensions(outputData)
                        XCTAssertTrue(
                            attachmentNames.insert(name.rendererOutput).inserted,
                            name.rendererOutput
                        )
                        attach(outputData, name: name.rendererOutput, type: "public.png")
                        rendererOutputAttachmentCount += 1
                        rendererOutputs = [ThemeFidelityRendererOutput(
                            outputID: try model.requireSafePreviewRendererOutputID(),
                            attachmentName: name.rendererOutput,
                            usesPrimaryCapture: false,
                            sha256: Self.sha256(outputData),
                            byteCount: outputData.count,
                            pixelWidth: dimensions.width,
                            pixelHeight: dimensions.height
                        )]
                    }

                    var optionalLockedRendererCovered = false
                    if theme == .norse, surface == .vaultLocked {
                        let lockedFixture = try await fixture.makeOptionalLockedCodexFixture()
                        let lockedRendered = try renderer.render(
                            lockedFixture.view,
                            identity: name.optionalLockedCodex,
                            destination: destination,
                            requiredElementIDs: [lockedFixture.elementID],
                            coveringElementIDs: [],
                            warmup: 0.25
                        )
                        optionalLockedRendererCovered =
                            lockedRendered.data.count > 4_096
                            && lockedRendered.viewportAssertions.clippedElementIDs.isEmpty
                            && lockedRendered.elementFrames.frames.contains(where: {
                                $0.elementID == lockedFixture.elementID
                            })
                        XCTAssertTrue(optionalLockedRendererCovered)
                        XCTAssertTrue(
                            attachmentNames.insert(name.optionalLockedCodex).inserted,
                            name.optionalLockedCodex
                        )
                        attach(
                            lockedRendered.data,
                            name: name.optionalLockedCodex,
                            type: "public.png"
                        )
                        optionalLockedAttachmentCount += 1
                        _ = lockedFixture.imageReference
                    }

                    guard let captureSnapshot = fixture.session.themeSnapshot,
                          captureSnapshot.effectiveCodexID == descriptor.codex.id,
                          captureSnapshot.effectiveTheme.id == descriptor.id
                    else { throw ThemeFidelityCaptureError.runtimeDidNotSettle }
                    let runtimeDiagnostics = ThemeFidelityEvidence.runtimeDiagnostics(
                        surface: surface,
                        model: model,
                        snapshot: captureSnapshot,
                        session: fixture.session,
                        destination: destination,
                        rendered: rendered,
                        optionalLockedRendererCovered: optionalLockedRendererCovered
                    )
                    let runtimeProbeObservations = ThemeFidelityEvidence
                        .runtimeProbeObservations(
                            theme: theme,
                            surface: surface,
                            diagnostics: runtimeDiagnostics,
                            stability: reduceMotionStability
                        )
                    let expectedRuntimeProbeCount = if theme == .norse,
                                                       surface == .vaultLocked {
                        4
                    } else if surface == .reduceMotion {
                        6
                    } else {
                        1
                    }
                    XCTAssertEqual(
                        runtimeProbeObservations.count,
                        expectedRuntimeProbeCount
                    )
                    XCTAssertEqual(
                        Set(runtimeProbeObservations.map(\.probeID)).count,
                        expectedRuntimeProbeCount
                    )
                    let structuralAssertionObservations = try ThemeFidelityEvidence
                        .structuralAssertionObservations(
                            surface: surface,
                            model: model,
                            snapshot: captureSnapshot,
                            destination: destination,
                            route: route,
                            rendered: rendered,
                            runtimeDiagnostics: runtimeDiagnostics,
                            rendererOutputs: rendererOutputs
                        )
                    XCTAssertEqual(
                        Set(structuralAssertionObservations.keys),
                        Set(ThemeFidelityEvidence.structuralAssertionIDs(for: surface))
                    )
                    ThemeFidelityEvidence.assertRuntimeRequirements(
                        theme: theme,
                        surface: surface,
                        diagnostics: runtimeDiagnostics,
                        stability: reduceMotionStability,
                        file: #filePath,
                        line: #line
                    )
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
                        runtimeDiagnostics: runtimeDiagnostics,
                        reduceMotionStability: reduceMotionStability,
                        rendererOutputs: rendererOutputs,
                        runtimeProbeObservations: runtimeProbeObservations,
                        structuralAssertionObservations: structuralAssertionObservations,
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
        XCTAssertEqual(
            reduceMotionAttachmentCount,
            surfaces.contains(.reduceMotion) ? themes.count * destinations.count : 0
        )
        XCTAssertEqual(
            rendererOutputAttachmentCount,
            surfaces.contains(.staticShare) ? themes.count * destinations.count : 0
        )
        XCTAssertEqual(
            optionalLockedAttachmentCount,
            surfaces.contains(.vaultLocked) && themes.contains(.norse)
                ? destinations.count : 0
        )
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

private struct ThemeFidelityCanonicalResourceSidecar: Encodable {
    let schemaVersion: String
    let candidateID: String
    let wrapperID: String
    let sourceSHA: String
    let seedID: String
    let renderMode: String
    let resourceID: String
    let visualPlanRevisions: [UInt64]
    let width: Int
    let height: Int
    let byteCount: Int
    let sha256: String
    let determinism: Bool
    let outputPath: String
}

@MainActor
private struct ThemeCanonicalResolvedSeedState {
    let primary: ThemeFidelityQualificationLaunch
    let launches: [ThemeFidelityQualificationLaunch]
    let seedIDs: [String]

    init(
        candidate: ThemeCanonicalCatalog.Candidate,
        request: ThemeCanonicalRenderRequest,
        registry: ThemeCanonicalSeedRegistry
    ) throws {
        let preferredSurface = candidate.recipeClass.preferredSurface
        guard candidate.surfaces.contains(preferredSurface) else {
            throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id)
        }

        var resolved: [(id: String, launch: ThemeFidelityQualificationLaunch)] = []
        let destination: ThemeFidelityQualificationLaunch.Destination
        #if os(macOS)
        destination = .macOSStandard
        #elseif os(iOS)
        destination = UIDevice.current.userInterfaceIdiom == .pad
            ? .iPadPortrait : .iPhonePortrait
        #endif
        for seedID in candidate.seedIDs {
            let seed = try registry.seed(id: seedID)
            let environment = try registry.environment(
                seedID: seedID,
                destination: destination.rawValue
            )
            guard case let .validated(launch) = ThemeFidelityQualificationLaunch.resolve(
                environment: environment,
                hostAuthorizationOverride: true
            ) else { throw ThemeCanonicalRegistryError.invalidCatalog(seedID) }
            guard launch.destination == destination else {
                throw ThemeCanonicalRegistryError.invalidCatalog(seedID)
            }
            guard seed.surface == launch.surface.rawValue else {
                throw ThemeCanonicalRegistryError.invalidCatalog(seedID)
            }
            resolved.append((seedID, launch))
        }
        guard request.candidateID == candidate.id,
              request.seedIDs == candidate.seedIDs,
              let selected = resolved.first(where: { $0.id == request.seedID }),
              selected.launch.surface.rawValue == preferredSurface,
              selected.launch.themeID.rawValue == request.themeID,
              selected.launch.codexID.rawValue == request.codexID,
              request.contrastMode == (
                  selected.launch.appearance == .highContrast ? .increased : .standard
              ),
              request.reduceMotion == (selected.launch.appearance == .reduceMotion),
              let authority = resolved.first?.launch,
        resolved.allSatisfy({
            $0.launch.themeID == authority.themeID
                && $0.launch.codexID == authority.codexID
                && $0.launch.defaultRelicID == authority.defaultRelicID
                && $0.launch.defaultSealID == authority.defaultSealID
        }) else { throw ThemeCanonicalRegistryError.invalidCatalog(candidate.id) }

        primary = selected.launch
        launches = resolved.map(\.launch)
        seedIDs = resolved.map(\.id)
    }

    func runtimeState(
        candidate: ThemeCanonicalCatalog.Candidate,
        visualPlanRevision: UInt64
    ) throws -> String {
        let state: [String: Any] = [
            "candidateID": candidate.id,
            "codexID": primary.codexID.rawValue,
            "themeID": primary.themeID.rawValue,
            "recipe": candidate.recipeClass.rawValue,
            "primarySurface": primary.surface.rawValue,
            "seedIDs": seedIDs,
            "seedSurfaces": launches.map { $0.surface.rawValue },
            "visualPlanRevision": String(visualPlanRevision),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: state,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw ThemeFidelityCaptureError.renderFailed
        }
        return value
    }
}

@MainActor
private enum ThemeFidelityCanonicalProductionRoute {
    struct Route {
        let view: AnyView
        let resourceIDs: [String]
        let visualPlanRevision: UInt64
        let runtimeState: String
        let warmup: TimeInterval
    }

    static func requiredResourceIDs(
        candidate: ThemeCanonicalCatalog.Candidate,
        binding: ThemeCanonicalProductionBinding,
        descriptor: ThemeDescriptor
    ) throws -> Set<ThemeResourceID> {
        var result = Set<ThemeResourceID>()
        switch binding {
        case let .artifactSpecimen(kind, artifactID):
            result.insert(descriptor.codex.background.staticBaseResourceID)
            guard let id = ArtifactID(rawValue: artifactID) else {
                throw ThemeFidelityCaptureError.invalidDescriptor
            }
            if kind == "relic" {
                guard let relic = descriptor.codex.relics.first(where: {
                    $0.metadata.id == id
                }) else { throw ThemeFidelityCaptureError.invalidDescriptor }
                result.insert(
                    descriptor.criticality == .requiredBase
                        ? relic.thumbnailResourceID : relic.primaryResourceID
                )
                if let script = descriptor.codex.scripts.first(where: {
                    $0.id == descriptor.codex.primaryScriptID
                }), let fontResourceID = script.fontResourceID {
                    result.insert(fontResourceID)
                }
            } else {
                guard let seal = descriptor.codex.seals.first(where: {
                    $0.metadata.id == id
                }) else { throw ThemeFidelityCaptureError.invalidDescriptor }
                result.insert(seal.standardResourceID)
            }
        case let .productionComponent(recipe):
            if recipe == .masteryOverviewPanel || recipe == .masteryDetailPanel {
                result.formUnion(
                    descriptor.codex.frames.prefix(1).map(\.staticFallbackResourceID)
                )
                result.formUnion(descriptor.codex.crests.prefix(1).map {
                    $0.thumbnailResourceID ?? $0.staticFallbackResourceID
                })
            }
        case .fullScreen, .resolvedResource:
            break
        }
        return result
    }

    static func make(
        candidate: ThemeCanonicalCatalog.Candidate,
        binding: ThemeCanonicalProductionBinding,
        model: ThemeFidelityRenderModel,
        session: RuneScribeUISession,
        resourceIDs: Set<ThemeResourceID>,
        seedState: ThemeCanonicalResolvedSeedState
    ) throws -> Route {
        let content: AnyView
        let warmup: TimeInterval
        switch binding {
        case let .fullScreen(surfaceName):
            guard let surface = ThemeFidelitySurface(rawValue: surfaceName) else {
                throw ThemeFidelityCaptureError.invalidDescriptor
            }
            let route = try ThemeFidelityRoute.make(
                surface: surface,
                model: model,
                session: session
            )
            content = route.view
            warmup = route.warmup
        case .resolvedResource:
            throw ThemeFidelityCaptureError.invalidDescriptor
        case let .artifactSpecimen(kind, artifactID):
            content = try artifactSpecimen(
                candidate: candidate,
                kind: kind,
                artifactID: artifactID,
                model: model,
                session: session
            )
            warmup = 0.25
        case let .productionComponent(recipe):
            let route = try productionComponent(
                recipe: recipe,
                model: model,
                session: session,
                seedState: seedState
            )
            content = route.view
            warmup = route.warmup
        }

        let runtimeState = try seedState.runtimeState(
            candidate: candidate,
            visualPlanRevision: model.visualPlanRevision
        )
        return Route(
            view: content,
            resourceIDs: resourceIDs.map(\.rawValue).sorted(),
            visualPlanRevision: model.visualPlanRevision,
            runtimeState: runtimeState,
            warmup: warmup
        )
    }

    static func fullScreenRoute(
        candidate: ThemeCanonicalCatalog.Candidate,
        content: AnyView,
        seedState: ThemeCanonicalResolvedSeedState,
        session: RuneScribeUISession
    ) throws -> Route {
        guard let revision = session.activeThemeVisualPresentation?.revision else {
            throw ThemeFidelityCaptureError.runtimeDidNotSettle
        }
        return Route(
            view: content,
            resourceIDs: [],
            visualPlanRevision: revision,
            runtimeState: try seedState.runtimeState(
                candidate: candidate,
                visualPlanRevision: revision
            ),
            warmup: 0.8
        )
    }

    static func receivedShareCard(
        model: ThemeFidelityRenderModel,
        session: RuneScribeUISession
    ) throws -> AnyView {
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
        let pending = PendingMessageViewState(try ReceivedMessageDTO(
            id: MessageID(rawValue: UUID(
                uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
            )!),
            receivedAt: Date(timeIntervalSinceReferenceDate: 809_299_200),
            plaintext: "Meet at moonrise by the old oak.",
            senderName: "Lunawen",
            cipherID: CipherID(rawValue: UUID(
                uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
            )!),
            cipherName: "Moonrise Meeting",
            senderIdentityStatus: .trustedLocalCipher,
            presentation: presentation,
            safePreviewData: model.safePreviewData
        ))
        return hostedFullScreen(
            ReceivedCipherPresentationView(
                state: .shareCard,
                pending: pending,
                receivedAt: Date(timeIntervalSinceReferenceDate: 809_299_200),
                relativeDate: Date(timeIntervalSinceReferenceDate: 809_299_500),
                descriptor: model.descriptor,
                plan: model.receivedPlan,
                image: { resourceID in
                    guard let image = model.presentation.image(for: resourceID) else {
                        preconditionFailure(
                            "Required received Theme resource was not prepared."
                        )
                    }
                    return image
                }
            ),
            session: session
        )
    }

    private static func productionComponent(
        recipe: ThemeCanonicalRecipe,
        model: ThemeFidelityRenderModel,
        session: RuneScribeUISession,
        seedState: ThemeCanonicalResolvedSeedState
    ) throws -> (view: AnyView, warmup: TimeInterval) {
        switch recipe {
        case .relicCatalogPanel:
            return (
                hosted(
                    CodexCatalogRoot(
                        descriptor: model.descriptor,
                        presentation: model.presentation,
                        initialTab: .relics
                    ),
                    session: session
                ),
                0.25
            )
        case .sealCatalogPanel:
            return (
                hosted(
                    CodexCatalogRoot(
                        descriptor: model.descriptor,
                        presentation: model.presentation,
                        initialTab: .seals
                    ),
                    session: session
                ),
                0.25
            )
        case .norseComposeWorkspacePanel:
            let cipherName = session.activeCipher?.label ?? "Cipher"
            return (
                hosted(
                    CodexComposeWorkspacePanel(
                        model: CodexComposeWorkspacePanelModel(
                            composition: model.shortPlan,
                            cipherName: cipherName,
                            relicName: artifactName(
                                id: model.selection.relicID,
                                descriptor: model.descriptor
                            ),
                            sealName: model.selection.sealID.map {
                                artifactName(id: $0, descriptor: model.descriptor)
                            } ?? "None",
                            primaryActionTitle: "Preview Message"
                        ),
                        image: { requiredImage($0, model: model) }
                    ),
                    session: session
                ),
                0.25
            )
        case .shortMessagePanel:
            return (
                hosted(
                    CodexMessagePanel(
                        model: CodexMessagePanelModel(
                            format: .short,
                            composition: model.shortPlan
                        ),
                        image: { requiredImage($0, model: model) }
                    ),
                    session: session
                ),
                0.25
            )
        case .longMessagePanel:
            return (
                hosted(
                    CodexMessagePanel(
                        model: CodexMessagePanelModel(
                            format: .long,
                            composition: model.longPlan
                        ),
                        image: { requiredImage($0, model: model) }
                    ),
                    session: session
                ),
                0.25
            )
        case .receivedCipherPanel:
            let route = try ThemeFidelityRoute.make(
                surface: .receivedCipher,
                model: model,
                session: session
            )
            return (route.view, route.warmup)
        case .sharePreviewCard:
            return (
                hosted(
                    CodexSharePreviewCard(
                        model: CodexSharePreviewCardModel(
                            heading: "Share Preview",
                            productName: "Rune Scribe Cipher",
                            attribution: "Sent with Rune Scribe",
                            deepLinkLabel: "runescribe://message",
                            composition: model.previewPlan
                        ),
                        image: { requiredImage($0, model: model) }
                    ),
                    session: session
                ),
                0.25
            )
        case .themeBackgroundPanel:
            return (
                hosted(
                    CodexBackgroundTreatmentPanel(
                        model: CodexBackgroundTreatmentPanelModel(
                            title: "Background Treatment",
                            summary: "Cold seas, ancient halls, iron and stone. Subtle motion in firelight and mist.",
                            backgroundResourceID: model.descriptor.codex.background
                                .staticBaseResourceID
                        ),
                        image: { requiredImage($0, model: model) }
                    ),
                    session: session
                ),
                0.25
            )
        case .masteryOverviewPanel, .masteryDetailPanel:
            guard let frame = model.descriptor.codex.frames.first,
                  let crest = model.descriptor.codex.crests.first
            else { throw ThemeFidelityCaptureError.invalidDescriptor }
            let titleName = session.progressionSnapshot?.titles.first(where: {
                $0.titleID == model.theme.masteryTitleID
            })?.presentation.displayName
                ?? seedState.primary.masteryTitlePresentation.displayName
            let masteryModel = CodexMasteryRewardsPanelModel(
                heading: "Mastery Rewards",
                frameName: frame.metadata.displayName.fallbackValue,
                crestName: crest.metadata.displayName.fallbackValue,
                titleName: titleName,
                titleInscription: titleName.uppercased(),
                titleGlyphInscription: model.glyphTokens.prefix(7).joined(separator: " "),
                accomplishment: "Awarded for completing \(model.descriptor.codex.displayName.fallbackValue) Mastery.",
                frameResourceID: frame.staticFallbackResourceID,
                crestResourceID: crest.thumbnailResourceID ?? crest.staticFallbackResourceID
            )
            return (
                hosted(
                    CodexMasteryRewardsPanel(
                        model: masteryModel,
                        style: recipe == .masteryOverviewPanel ? .overview : .detail,
                        image: { requiredImage($0, model: model) }
                    ),
                    session: session
                ),
                0.25
            )
        case .vaultCardStateStack:
            let vault = model.descriptor.codex.vault
            return (
                hosted(
                    CodexVaultCardStateStack(
                        model: CodexVaultCardStateStackModel(
                            heading: "Vault Codex Card",
                            codexName: model.descriptor.codex.displayName.fallbackValue,
                            codexSubtitle: model.descriptor.codex.shortDescription.fallbackValue,
                            cards: [
                                CodexVaultCardStateModel(
                                    state: .owned,
                                    heading: "Owned (Base Theme)",
                                    detail: "Selected",
                                    resourceID: vault.cardResourceID,
                                    isApplicable: true
                                ),
                                CodexVaultCardStateModel(
                                    state: .encountered,
                                    heading: "Encountered",
                                    detail: "Encountered",
                                    resourceID: vault.encounteredResourceID,
                                    isApplicable: true
                                ),
                                CodexVaultCardStateModel(
                                    state: .locked,
                                    heading: "Locked State (Not Applicable)",
                                    detail: "Always available",
                                    resourceID: vault.lockedSilhouetteResourceID,
                                    isApplicable: false
                                ),
                            ]
                        ),
                        image: { requiredImage($0, model: model) }
                    ),
                    session: session
                ),
                0.25
            )
        default:
            throw ThemeFidelityCaptureError.invalidDescriptor
        }
    }

    private static func artifactSpecimen(
        candidate: ThemeCanonicalCatalog.Candidate,
        kind: String,
        artifactID: String,
        model: ThemeFidelityRenderModel,
        session: RuneScribeUISession
    ) throws -> AnyView {
        guard let id = ArtifactID(rawValue: artifactID) else {
            throw ThemeFidelityCaptureError.invalidDescriptor
        }
        if kind == "relic" {
            guard let relic = model.descriptor.codex.relics.first(where: {
                $0.metadata.id == id
            }) else { throw ThemeFidelityCaptureError.invalidDescriptor }
            guard let ordinalIndex = model.descriptor.codex.relics.firstIndex(where: {
                $0.metadata.id == id
            }),
            let layout = relic.layouts.first(where: { $0.id == relic.defaultLayoutID }),
            let script = model.descriptor.codex.scripts.first(where: {
                $0.id == model.descriptor.codex.primaryScriptID
            }) else { throw ThemeFidelityCaptureError.invalidDescriptor }
            let resourceID = model.descriptor.criticality == .requiredBase
                ? relic.thumbnailResourceID : relic.primaryResourceID
            guard let reference = model.descriptor.resources.first(where: {
                $0.id == resourceID
            }) else { throw ThemeFidelityCaptureError.invalidDescriptor }
            let pixelSize = reference.integrity.pixelSize
            let artworkAspectRatio = pixelSize.map {
                Double($0.width) / Double($0.height)
            } ?? (Double(layout.aspectRatio.width) / Double(layout.aspectRatio.height))
            let specimenRows = Int(
                layout.catalogSpecimenRows
                    ?? (model.descriptor.criticality == .requiredBase ? 3 : 0)
            )
            let specimenColumns = Int(
                layout.catalogSpecimenColumns
                    ?? (model.descriptor.criticality == .requiredBase ? 5 : 0)
            )
            let inscription = specimenInscription(
                script: script,
                rows: specimenRows,
                columns: specimenColumns,
                enabled: specimenRows > 0 && specimenColumns > 0
            )
            let accessibilityDescription = [
                relic.metadata.accessibility.label.fallbackValue,
                relic.metadata.accessibility.hint?.fallbackValue ?? "",
            ].joined(separator: " ").lowercased()
            let item = browserItem(
                metadata: relic.metadata,
                resourceID: resourceID,
                kind: .relic,
                selectedID: model.selection.relicID,
                ordinal: ordinalIndex + 1
            )
            return hosted(
                CodexArtifactSpecimenCard(
                    item: item,
                    relicLayout: layout,
                    artworkAspectRatio: artworkAspectRatio,
                    backgroundImage: requiredImage(
                        model.descriptor.codex.background.staticBaseResourceID,
                        model: model
                    )
                ) {
                    ThemeRelicSpecimenArtwork(
                        image: requiredImage(resourceID, model: model),
                        plan: ThemeRelicSpecimenPlan(
                            inscription: inscription,
                            fontPostScriptName: script.fontPostScriptName?.rawValue
                                ?? RuneThemePaletteInterpreter.fontPostScriptName,
                            glyphSafeRegion: layout.glyphSafeRegion,
                            artworkAspectRatio: artworkAspectRatio,
                            minimumGlyphScale: layout.minimumGlyphScale,
                            usesPrimaryTextColor: accessibilityDescription.contains("dark")
                                || accessibilityDescription.contains("charcoal")
                                || accessibilityDescription.contains("obsidian")
                        )
                    )
                },
                session: session
            )
        }
        guard kind == "seal",
              let seal = model.descriptor.codex.seals.first(where: {
                  $0.metadata.id == id
              })
        else { throw ThemeFidelityCaptureError.invalidDescriptor }
        let resourceID = seal.standardResourceID
        guard
              let reference = model.descriptor.resources.first(where: {
                  $0.id == resourceID
              })
        else { throw ThemeFidelityCaptureError.invalidDescriptor }
        let artworkAspectRatio = reference.integrity.pixelSize.map {
            Double($0.width) / Double($0.height)
        } ?? 1
        let item = browserItem(
            metadata: seal.metadata,
            resourceID: resourceID,
            kind: .seal,
            selectedID: model.selection.sealID
        )
        return hosted(
            CodexArtifactSpecimenCard(
                item: item,
                artworkAspectRatio: artworkAspectRatio,
                backgroundImage: requiredImage(
                    model.descriptor.codex.background.staticBaseResourceID,
                    model: model
                )
            ) {
                requiredImage(resourceID, model: model)
                    .resizable()
                    .scaledToFit()
            },
            session: session
        )
    }

    private static func hostedPreview(
        plan: ThemeArtifactCompositionPlan,
        model: ThemeFidelityRenderModel,
        session: RuneScribeUISession
    ) -> AnyView {
        hosted(
            ThemeArtifactPreview(
                plan: plan,
                maximumCanvasWidth: nil,
                image: { model.presentation.image(for: $0) }
            ),
            session: session
        )
    }

    private static func hosted<Content: View>(
        _ content: Content,
        session: RuneScribeUISession
    ) -> AnyView {
        AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environmentObject(session)
            .environment(
                \.runtimeApplicationResourcePresentation,
                session.resourcePresentation
            )
            .environment(
                \.runtimeAccessibilityPreferences,
                RuntimeAccessibilityPreferences()
            )
            .environment(\.themeCaptureIdentifiersEnabled, true)
            .preferredColorScheme(.dark)
        )
    }

    private static func hostedFullScreen<Content: View>(
        _ content: Content,
        session: RuneScribeUISession
    ) -> AnyView {
        hosted(
            ZStack {
                RuntimeMetalBackground()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .clipped()
                content
            },
            session: session
        )
    }

    private static func requiredImage(
        _ resourceID: ThemeResourceID,
        model: ThemeFidelityRenderModel
    ) -> Image {
        guard let image = model.presentation.image(for: resourceID) else {
            preconditionFailure("Required canonical production resource was not prepared.")
        }
        return image
    }

    private static func artifactName(
        id: ArtifactID,
        descriptor: ThemeDescriptor
    ) -> String {
        if let relic = descriptor.codex.relics.first(where: { $0.metadata.id == id }) {
            return relic.metadata.displayName.fallbackValue
        }
        if let seal = descriptor.codex.seals.first(where: { $0.metadata.id == id }) {
            return seal.metadata.displayName.fallbackValue
        }
        return id.rawValue
    }

    private static func browserItem(
        metadata: ThemeArtifactMetadata,
        resourceID: ThemeResourceID,
        kind: ThemeVisualArtifactKind,
        selectedID: ArtifactID?,
        ordinal: Int? = nil
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
            facets: metadata.facets?.map(\.fallbackValue) ?? [],
            kind: kind,
            rarity: metadata.rarity,
            state: state,
            accessibilityLabel: metadata.accessibility.label.fallbackValue,
            accessibilityHint: metadata.accessibility.hint?.fallbackValue,
            provenance: nil,
            isSelectable: state == .owned || state == .selected,
            ordinal: ordinal,
            availability: metadata.availability
        )
    }

    private static func specimenInscription(
        script: ThemeScriptDescriptor,
        rows: Int,
        columns: Int,
        enabled: Bool
    ) -> String {
        guard enabled, rows > 0, columns > 0 else { return "" }
        let tokens = Array(script.glyphs.prefix(rows * columns).map(\.textToken))
        return stride(from: 0, to: tokens.count, by: columns).map { start in
            tokens[start ..< min(start + columns, tokens.count)].joined(separator: " ")
        }.joined(separator: "\n")
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
    let reduceMotionCaptureB: String
    let rendererOutput: String
    let optionalLockedCodex: String
    init(theme: ThemeFidelityTheme, surface: ThemeFidelitySurface,
         destination: ThemeFidelityDestination) {
        let stem = "\(theme.slug)--\(surface.rawValue)--\(destination.slug)"
        png = "\(stem).png"
        record = "\(stem).capture.json"
        reduceMotionCaptureB = "\(stem)--stability-b.png"
        rendererOutput = "\(stem)--renderer-output.png"
        optionalLockedCodex = "\(stem)--optional-codex-locked.png"
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
    let capturedAt: Date
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
            capturedAt: capturedAt,
            viewportAssertions: viewportAssertions,
            elementFrames: elementFrames,
            renderedResourceIDs: Array(Set(bindings.map(\.resourceID))).sorted(),
            renderedResourceBindings: bindings
        )
    }
}

private struct ThemeFidelityImageCapture {
    let data: Data
    let width: Int
    let height: Int
    let capturedAt: Date
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
        case .composeLong:
            model.longText
        case .largeText:
            model.shortText
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
            progression: surface.contentSeedProgression(for: model.theme),
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

    func contentSeedProgression(
        for theme: ThemeFidelityTheme
    ) -> ThemeFidelityContentSeed.Progression {
        switch self {
        case .vaultLocked:
            ThemeFidelityContentSeed.Progression(
                ownershipState: theme == .norse ? "owned" : "locked", achievementID: nil,
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
            dynamicTypeSize: self == .largeText ? "accessibility5" : "large"
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

private enum ThemeFidelityJSONValue: Encodable, Equatable {
    case bool(Bool)
    case integer(Int)
    case unsignedInteger(UInt64)
    case number(Double)
    case string(String)
    case strings([String])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .unsignedInteger(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .strings(value):
            try container.encode(value)
        }
    }
}

private struct ThemeFidelityRuntimeDiagnostics: Encodable {
    struct Preview: Encodable {
        let elementID: String
        let exists: Bool
        let visible: Bool
        let viewportContained: Bool
    }

    struct NorseBase: Encodable {
        let owned: Bool
        let selectable: Bool
        let fallbackAvailable: Bool
        let lockedElementCount: Int
        let optionalLockedRendererCovered: Bool
    }

    let activeThemeID: String
    let activeCodexID: String
    let effectiveMotionMode: String
    let activeThemeAnimationCount: Int
    let effectiveBackgroundResourceID: String
    let declaredReduceMotionBackgroundResourceID: String
    let visualPlanRevision: UInt64
    let preview: Preview
    let norseBase: NorseBase
}

private struct ThemeFidelityReduceMotionStability: Encodable {
    let captureATimestamp: String
    let captureBTimestamp: String
    let separationSeconds: Double
    let captureASHA256: String
    let captureBSHA256: String
    let captureBAttachmentName: String
    let luminanceSSIM: Double
}

private struct ThemeFidelityRendererOutput: Encodable {
    let outputID: String
    let attachmentName: String
    let usesPrimaryCapture: Bool
    let sha256: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct ThemeFidelityRuntimeProbeObservation: Encodable {
    let probeID: String
    let source: String
    let observed: ThemeFidelityJSONValue
}

private struct ThemeFidelityStructuralAssertionObservation: Encodable {
    let source: String
    let observed: ThemeFidelityJSONValue
    let details: [String: ThemeFidelityJSONValue]
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
    let runtimeDiagnostics: ThemeFidelityRuntimeDiagnostics
    let reduceMotionStability: ThemeFidelityReduceMotionStability?
    let rendererOutputs: [ThemeFidelityRendererOutput]
    let runtimeProbeObservations: [ThemeFidelityRuntimeProbeObservation]
    let structuralAssertionObservations:
        [String: ThemeFidelityStructuralAssertionObservation]

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
        case runtimeDiagnostics
        case reduceMotionStability
        case rendererOutputs
        case runtimeProbeObservations
        case structuralAssertionObservations
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
         runtimeDiagnostics: ThemeFidelityRuntimeDiagnostics,
         reduceMotionStability: ThemeFidelityReduceMotionStability?,
         rendererOutputs: [ThemeFidelityRendererOutput],
         runtimeProbeObservations: [ThemeFidelityRuntimeProbeObservation],
         structuralAssertionObservations:
             [String: ThemeFidelityStructuralAssertionObservation],
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
        self.runtimeDiagnostics = runtimeDiagnostics
        self.reduceMotionStability = reduceMotionStability
        self.rendererOutputs = rendererOutputs
        self.runtimeProbeObservations = runtimeProbeObservations
        self.structuralAssertionObservations = structuralAssertionObservations
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
        try container.encode(runtimeDiagnostics, forKey: .runtimeDiagnostics)
        if let reduceMotionStability {
            try container.encode(reduceMotionStability, forKey: .reduceMotionStability)
        }
        try container.encode(rendererOutputs, forKey: .rendererOutputs)
        try container.encode(runtimeProbeObservations, forKey: .runtimeProbeObservations)
        try container.encode(
            structuralAssertionObservations,
            forKey: .structuralAssertionObservations
        )
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
private struct ThemeFidelityLockedCodexFixture {
    let view: AnyView
    let elementID: String
    let imageReference: RuntimeThemeImageReference
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
        try await session.prepareQualificationTheme(codexID: theme.codexID)
        let snapshot = try await themeClient.snapshot()
        guard snapshot.effectiveCodexID == theme.codexID,
              await Self.eventually({
                  self.session.themeSnapshot?.effectiveCodexID == theme.codexID
                      && self.session.activeThemeVisualPresentation?.plan.codexID
                          == theme.codexID
                      && self.session.activeThemeVisualPresentation?.revision
                          == self.session.activeThemeVisualPresentation?.plan.revision
              })
        else { throw ThemeFidelityCaptureError.runtimeDidNotSettle }
        await session.loadActiveThemeCatalogVisuals()
        await session.loadThemeCodexCardPreviews()
    }

    func select(_ launch: ThemeFidelityQualificationLaunch) async throws {
        try await session.prepareQualificationTheme(codexID: launch.codexID)
        let snapshot = try await themeClient.snapshot()
        guard snapshot.effectiveCodexID == launch.codexID,
              await Self.eventually({
                  self.session.themeSnapshot?.effectiveCodexID == launch.codexID
                      && self.session.themeSnapshot?.effectiveTheme.id == launch.themeID
                      && self.session.selectedThemeRelicID == launch.defaultRelicID
                      && self.session.selectedThemeSealID == launch.defaultSealID
                      && self.session.activeThemeVisualPresentation?.plan.codexID
                          == launch.codexID
                      && self.session.activeThemeVisualPresentation?.revision
                          == self.session.activeThemeVisualPresentation?.plan.revision
              })
        else { throw ThemeFidelityCaptureError.runtimeDidNotSettle }
        await session.loadActiveThemeCatalogVisuals()
        await session.loadThemeCodexCardPreviews()
    }

    func makeOptionalLockedCodexFixture() async throws -> ThemeFidelityLockedCodexFixture {
        let descriptor = try await themeClient.providerDescriptor(
            for: ThemeFidelityTheme.moonleaf.codexID
        )
        let resourceID = descriptor.codex.vault.lockedSilhouetteResourceID
        guard let expectedReference = descriptor.resources.first(where: {
            $0.id == resourceID
        }) else {
            throw ThemeFidelityCaptureError.missingResource(resourceID)
        }
        let resolved = try await themeClient.resolveCatalogPreviewResource(
            codexID: descriptor.codex.id,
            resourceID: resourceID
        )
        let contentRevision = session.activeThemeVisualPresentation?.revision ?? 1
        let imageReference = try session.resourcePresentation.makeThemeImageReference(
            resolvedResource: resolved,
            expectedReference: expectedReference,
            expectedCodexID: descriptor.codex.id,
            contentRevision: contentRevision
        )
        guard let image = imageReference.image else {
            throw ThemeFidelityCaptureError.renderFailed
        }
        guard let elementID = ThemeCaptureIdentifier.vault(
            codexID: descriptor.codex.id,
            state: .locked
        ) else { throw ThemeFidelityCaptureError.renderFailed }
        let view = AnyView(
            ScrollView {
                ThemeCodexCardView(
                    codexID: descriptor.codex.id,
                    displayName: descriptor.codex.displayName.fallbackValue,
                    summary: descriptor.codex.shortDescription.fallbackValue,
                    state: .locked,
                    accessibilityLabel: descriptor.codex.accessibility.label.fallbackValue,
                    accessibilityHint: "Locked optional Codex fixture",
                    isEnabled: false,
                    identifierPrefix: "theme-fidelity.optional-locked",
                    captureIdentifier: elementID,
                    action: {}
                ) {
                    image.resizable().scaledToFill()
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RuntimeMetalBackground()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            .environmentObject(session)
            .environment(
                \.runtimeApplicationResourcePresentation,
                session.resourcePresentation
            )
            .environment(
                \.runtimeAccessibilityPreferences,
                RuntimeAccessibilityPreferences(forcesReduceMotion: true)
            )
            .environment(\.themeCaptureIdentifiersEnabled, true)
            .preferredColorScheme(.dark)
        )
        return ThemeFidelityLockedCodexFixture(
            view: view,
            elementID: elementID,
            imageReference: imageReference
        )
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
    let shortPlan: ThemeArtifactCompositionPlan
    let longPlan: ThemeArtifactCompositionPlan
    let previewPlan: ThemeArtifactCompositionPlan
    let receivedPlan: ThemeArtifactCompositionPlan
    let highContrastPlan: ThemeArtifactCompositionPlan
    let reduceMotionPlan: ThemeArtifactCompositionPlan
    let presentation: ActiveThemeVisualPresentation
    let safePreviewData: Data?
    let safePreviewRendererOutputID: String?
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

        let previewPlan = try plan()
        let receivedPlan = try plan(inscription: received)
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
            shortPlan: plan(inscription: short),
            longPlan: plan(inscription: long),
            previewPlan: previewPlan,
            receivedPlan: receivedPlan,
            highContrastPlan: plan(mode: .highContrast),
            reduceMotionPlan: plan(reduceMotion: true),
            presentation: presentation,
            safePreviewData: safePreview.data,
            safePreviewRendererOutputID: safePreview.rendererOutputID,
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
        resourceIDs: [String],
        rendererOutputID: String?
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
                })).sorted(),
                preparation.rendererOutputID
            )
        }
        if ThemeFidelityPhase.requiresValidSafePreview {
            throw ThemeFidelityCaptureError.safePreviewUnavailable(diagnostic)
        }
        return (nil, .absent, diagnostic, [], [], nil)
    }

    func requireSafePreviewRendererOutputID() throws -> String {
        guard let safePreviewRendererOutputID else {
            throw ThemeFidelityCaptureError.safePreviewUnavailable(
                "share.renderer-output-id-unavailable"
            )
        }
        return safePreviewRendererOutputID
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
    let authorityElementIDs: [String]
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
        var authorityIDs: [String] = []
        var coveringIDs = Set<String>()
        var warmup: TimeInterval = 0.25
        let routeAccessibilityPreferences = surface.runtimeAccessibilityPreferences
        let content: AnyView

        switch surface {
        case .workspaceEmpty:
            content = AnyView(RootView(session: session))
            let identifiers = [
                ThemeCaptureIdentifier.screenWorkspace,
                ThemeCaptureIdentifier.workspacePrimarySurface,
            ]
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
        case .composeShort:
            content = AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.shortPlan,
                    presentation: model.presentation
                ),
                initialViewportProbeID: "workspace.input.compose-short",
                initialComposeCaptureLength: .short
            ))
            let identifiers = [
                ThemeCaptureIdentifier.screenWorkspace,
                ThemeCaptureIdentifier.compose(
                    length: .short,
                    codexID: model.descriptor.codex.id
                ),
                ThemeCaptureIdentifier.artifactPreview(
                    relicID: model.selection.relicID
                ),
            ]
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
        case .composeLong:
            content = AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.longPlan,
                    presentation: model.presentation
                ),
                initialViewportProbeID: "workspace.input.compose-long",
                initialComposeCaptureLength: .long
            ))
            let identifiers = [
                ThemeCaptureIdentifier.screenWorkspace,
                ThemeCaptureIdentifier.compose(
                    length: .long,
                    codexID: model.descriptor.codex.id
                ),
                ThemeCaptureIdentifier.artifactPreview(
                    relicID: model.selection.relicID
                ),
            ]
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
        case .inscriptionPreview:
            content = AnyView(ThemeInscriptionPreviewView(
                descriptor: model.descriptor,
                plan: model.previewPlan,
                selectedLayout: .long,
                image: { resourceID in
                    guard let image = model.presentation.image(for: resourceID) else {
                        preconditionFailure(
                            "Missing admitted production image: \(resourceID.rawValue)"
                        )
                    }
                    return image
                }
            ))
            let identifiers = [
                ThemeCaptureIdentifier.artifactPreview(
                    relicID: model.selection.relicID
                ),
            ]
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
        case .receivedCipher:
            content = AnyView(ReceivedMessageView(pending: try receivedMessage(model: model)))
            requiredIDs.append(ThemeCaptureIdentifier.screenReceivedCipher)
            authorityIDs.append(ThemeCaptureIdentifier.screenReceivedCipher)
            if model.safePreviewStatus == .valid {
                requiredIDs.append("received.safe-preview")
                let identifier = ThemeCaptureIdentifier.receivedArtifactPreview(
                    relicID: model.selection.relicID
                )
                requiredIDs.append(identifier)
                authorityIDs.append(identifier)
            }
            warmup = 0.8
        case .shareBuilder:
            let cipher = try requireActiveCipher(session)
            var catalog = try session.makeShareBuilderCatalog()
            let originalEffects = catalog.draft.effects
            catalog.selectEffects(originalEffects == .full ? .reduced : .full)
            catalog.markCurrentDraftAsDefaults()
            catalog.selectEffects(originalEffects)
            content = AnyView(ShareBuilderView(
                source: .cipherInvitation(cipherID: cipher.id, displayName: cipher.label),
                initialCatalog: catalog,
                initialViewport: .controls
            ))
            let identifier = "share-builder"
            requiredIDs.append(identifier)
            let identifiers = [
                ThemeCaptureIdentifier.screenShareBuilder,
                ThemeCaptureIdentifier.shareBuilderPreview(
                    codexID: model.descriptor.codex.id
                ),
            ]
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
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
            authorityIDs.append("theme.static-share")
        case .settingsCodexCard:
            content = AnyView(SettingsView(initialViewport: .codexCard))
            let identifier = "theme.codex-card.\(model.descriptor.codex.id.rawValue)"
            let identifiers = [identifier, ThemeCaptureIdentifier.screenSettingsAppearance]
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
            warmup = 0.8
        case .settingsDefaultsPreview:
            content = AnyView(SettingsView(initialViewport: .defaultsPreview))
            let identifiers = [
                ThemeCaptureIdentifier.screenSettingsAppearance,
                ThemeCaptureIdentifier.workspacePrimarySurface,
                ThemeCaptureIdentifier.settingsDefaultsPreview(
                    codexID: model.descriptor.codex.id
                ),
                ThemeCaptureIdentifier.artifactPreview(
                    relicID: model.selection.relicID
                ),
            ]
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
            warmup = 0.8
        case .vaultLocked:
            if model.theme == .norse {
                content = AnyView(VaultProgressView(initialSection: .vault))
            } else {
                content = AnyView(VaultProgressView(
                    initialSection: .vault,
                    initialCodexCardState: .locked
                ))
            }
            requiredIDs.append(ThemeCaptureIdentifier.screenVaultProgress)
            authorityIDs.append(ThemeCaptureIdentifier.screenVaultProgress)
            if model.theme != .norse,
               let identifier = ThemeCaptureIdentifier.vault(
                   codexID: model.descriptor.codex.id,
                   state: .locked
               ) {
                requiredIDs.append(identifier)
                authorityIDs.append(identifier)
            }
            warmup = 0.8
        case .vaultEncountered, .vaultOwned, .vaultSelected:
            let visualState: ThemeVisualContentState = switch surface {
            case .vaultEncountered: .encountered
            case .vaultOwned: .owned
            case .vaultSelected: .selected
            default: .selected
            }
            content = AnyView(VaultProgressView(
                initialSection: .vault,
                initialCodexCardState: visualState
            ))
            requiredIDs.append(ThemeCaptureIdentifier.screenVaultProgress)
            authorityIDs.append(ThemeCaptureIdentifier.screenVaultProgress)
            if let identifier = ThemeCaptureIdentifier.vault(
                codexID: model.descriptor.codex.id,
                state: visualState
            ) {
                requiredIDs.append(identifier)
                authorityIDs.append(identifier)
            }
            warmup = 0.8
        case .vaultProgress:
            let achievementID = AchievementID(rawValue: "achievement.first-inscription")!
            content = AnyView(VaultProgressView(
                initialSection: .achievements,
                initialViewport: .achievement(achievementID)
            ))
            requiredIDs.append("progression.achievement.\(achievementID.rawValue)")
            requiredIDs.append(ThemeCaptureIdentifier.screenVaultProgress)
            authorityIDs.append(ThemeCaptureIdentifier.screenVaultProgress)
            warmup = 0.8
        case .relicPicker:
            content = AnyView(artifactBrowser(kind: .relic, model: model))
            var identifiers = [
                ThemeCaptureIdentifier.artifactPicker(
                    kind: .relic,
                    codexID: model.descriptor.codex.id
                ),
                ThemeCaptureIdentifier.artifactPickerScreen(
                    kind: .relic,
                    codexID: model.descriptor.codex.id
                ),
            ]
            identifiers.append(contentsOf: model.descriptor.codex.relics
                .filter { $0.metadata.availability != .reservedInactive }
                .map { "theme.artifact-picker.\($0.metadata.id.rawValue)" })
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
        case .sealPicker:
            content = AnyView(artifactBrowser(kind: .seal, model: model))
            var identifiers = [
                ThemeCaptureIdentifier.artifactPicker(
                    kind: .seal,
                    codexID: model.descriptor.codex.id
                ),
                ThemeCaptureIdentifier.artifactPickerScreen(
                    kind: .seal,
                    codexID: model.descriptor.codex.id
                ),
            ]
            identifiers.append(contentsOf: model.descriptor.codex.seals
                .filter { $0.metadata.availability != .reservedInactive }
                .map { "theme.artifact-picker.\($0.metadata.id.rawValue)" })
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
        case .mastery:
            let reveal = try masteryReveal(model: model)
            session.revealQueue.adopt(head: reveal, canPresent: true)
            session.setRevealBlocker(.rootPresentation, active: false)
            content = AnyView(UnlockRevealView(
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
            requiredIDs.append("progression.unlock-reveal")
            let identifiers = [
                ThemeCaptureIdentifier.mastery(codexID: model.descriptor.codex.id),
                ThemeCaptureIdentifier.masteryScreen(codexID: model.descriptor.codex.id),
            ] + model.descriptor.codex.frames.prefix(1).map {
                ThemeCaptureIdentifier.masteryFrame(artifactID: $0.metadata.id)
            } + model.descriptor.codex.crests.prefix(1).compactMap {
                CrestID(rawValue: $0.metadata.id.rawValue).map {
                    ThemeCaptureIdentifier.masteryCrest(crestID: $0)
                }
            }
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
            warmup = 0.4
        case .highContrast:
            content = AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.highContrastPlan,
                    presentation: model.presentation
                )
            ))
            let identifiers = [
                ThemeCaptureIdentifier.screenWorkspace,
                ThemeCaptureIdentifier.artifactPreview(
                    relicID: model.selection.relicID
                ),
            ]
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
        case .reduceMotion:
            content = AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.reduceMotionPlan,
                    presentation: model.presentation
                )
            ))
            let identifiers = [
                ThemeCaptureIdentifier.screenWorkspace,
                ThemeCaptureIdentifier.artifactPreview(
                    relicID: model.selection.relicID
                ),
            ]
            requiredIDs.append(contentsOf: identifiers)
            authorityIDs.append(contentsOf: identifiers)
        case .largeText:
            content = AnyView(ContentView(
                initialSettledArtifact: ContentViewSettledArtifactSeed(
                    composition: model.shortPlan,
                    presentation: model.presentation
                ),
                initialViewport: .resultActions,
                initialViewportProbeID: "workspace.input.large-text"
            )
                .environment(\.dynamicTypeSize, .accessibility5))
            let identifiers = [
                ThemeCaptureIdentifier.screenWorkspace,
                ThemeCaptureIdentifier.artifactPreview(
                    relicID: model.selection.relicID
                ),
            ]
            requiredIDs.append(contentsOf: identifiers)
            requiredIDs.append(contentsOf: ThemeFidelityEvidence.largeTextControlIDs)
            authorityIDs.append(contentsOf: identifiers)
        }

        let backgroundVariant: ThemeCaptureIdentifier.BackgroundVariant = switch surface {
        case .reduceMotion: .reduceMotion
        case .highContrast: .highContrast
        default: .standard
        }
        let backgroundIdentifier = ThemeCaptureIdentifier.background(
            themeID: model.descriptor.id,
            variant: backgroundVariant
        )
        if surface == .workspaceEmpty || surface == .reduceMotion {
            requiredIDs.append(backgroundIdentifier)
            authorityIDs.append(backgroundIdentifier)
            coveringIDs.insert(backgroundIdentifier)
        }

        let hosted = AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if surface != .workspaceEmpty {
                        RuntimeMetalBackground()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea()
                            .clipped()
                            .themeCaptureIdentifier(backgroundIdentifier)
                    }
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
                .environment(\.themeCaptureIdentifiersEnabled, true)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .preferredColorScheme(.dark)
                .accessibilityIdentifier(rootID)
        )
        return Self(
            view: hosted,
            requiredElementIDs: Array(Set(requiredIDs)).sorted(),
            authorityElementIDs: Array(Set(authorityIDs)).sorted(),
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
            receivedAt: Date(timeIntervalSinceReferenceDate: 809_299_200),
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
        let captureKind: ThemeCaptureIdentifier.PickerKind = kind == .relic
            ? .relic : .seal
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
                captureIdentifier: ThemeCaptureIdentifier.artifactPicker(
                    kind: captureKind,
                    codexID: model.descriptor.codex.id
                ),
                selectNone: {},
                select: { _ in }
            ) { item in
                model.artwork(item.resourceID, label: item.accessibilityLabel)
            }
        }
        .themeCaptureIdentifier(ThemeCaptureIdentifier.artifactPickerScreen(
            kind: captureKind,
            codexID: model.descriptor.codex.id
        ))
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
            facets: metadata.facets?.map(\.fallbackValue) ?? [],
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
private enum ThemeFidelityEvidence {
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func pngDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ThemeFidelityCaptureError.renderFailed }
        return (image.width, image.height)
    }

    static func luminanceSSIM(_ first: Data, _ second: Data) throws -> Double {
        if first == second { return 1 }
        let firstPixels = try luminancePixels(first)
        let secondPixels = try luminancePixels(second)
        guard firstPixels.width == secondPixels.width,
              firstPixels.height == secondPixels.height,
              firstPixels.values.count == secondPixels.values.count,
              !firstPixels.values.isEmpty
        else { throw ThemeFidelityCaptureError.renderFailed }

        let count = Double(firstPixels.values.count)
        let firstMean = firstPixels.values.reduce(0, +) / count
        let secondMean = secondPixels.values.reduce(0, +) / count
        var firstVariance = 0.0
        var secondVariance = 0.0
        var covariance = 0.0
        for index in firstPixels.values.indices {
            let firstDelta = firstPixels.values[index] - firstMean
            let secondDelta = secondPixels.values[index] - secondMean
            firstVariance += firstDelta * firstDelta
            secondVariance += secondDelta * secondDelta
            covariance += firstDelta * secondDelta
        }
        let varianceDivisor = max(1, count - 1)
        firstVariance /= varianceDivisor
        secondVariance /= varianceDivisor
        covariance /= varianceDivisor
        let c1 = 0.0001
        let c2 = 0.0009
        let numerator = (2 * firstMean * secondMean + c1) * (2 * covariance + c2)
        let denominator = (firstMean * firstMean + secondMean * secondMean + c1)
            * (firstVariance + secondVariance + c2)
        guard denominator > 0 else { return firstMean == secondMean ? 1 : 0 }
        return Swift.min(1.0, Swift.max(-1.0, numerator / denominator))
    }

    static func runtimeDiagnostics(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel,
        snapshot: ThemeCoordinatorSnapshotDTO,
        session: RuneScribeUISession,
        destination: ThemeFidelityDestination,
        rendered: ThemeFidelityRenderedPNG,
        optionalLockedRendererCovered: Bool
    ) -> ThemeFidelityRuntimeDiagnostics {
        let variant = session.resourcePresentation.themeBackgroundPresentationVariant(
            reduceMotion: surface == .reduceMotion,
            increasedContrast: surface == .highContrast
        )
        let background = model.descriptor.codex.background
        let configuredBackgroundResourceID: ThemeResourceID? = switch variant {
        case .semanticFallback:
            nil
        case .staticBase:
            background.staticBaseResourceID
        case .reduceMotion:
            background.reduceMotionResourceID
        case .highContrast:
            background.highContrastResourceID
        case .animated:
            background.optionalMotionResourceID
                ?? background.rendererParametersResourceID
                ?? background.staticBaseResourceID
        }
        let observedResourceIDs = Set(rendered.renderedResourceIDs)
        let effectiveBackgroundResourceID = configuredBackgroundResourceID.map {
            observedResourceIDs.contains($0.rawValue)
                ? $0.rawValue : "unobserved:\($0.rawValue)"
        } ?? "semantic-fallback"
        let effectiveMotionMode: String = switch variant {
        case .semanticFallback:
            "semantic-fallback"
        case .staticBase:
            "static"
        case .reduceMotion:
            "reduce-motion"
        case .highContrast:
            "high-contrast"
        case .animated:
            "full-motion"
        }
        let previewID = ThemeCaptureIdentifier.artifactPreview(
            relicID: model.selection.relicID
        )
        let previewFrame = rendered.elementFrames.frames.first(where: {
            $0.elementID == previewID
        })
        let viewport = CGRect(
            x: 0,
            y: 0,
            width: destination.pixelWidth,
            height: destination.pixelHeight
        )
        let previewRect = previewFrame.map(frameRect)
        let previewExists = previewRect.map { !$0.isNull && !$0.isEmpty } ?? false
        let previewVisible = previewRect.map {
            !$0.intersection(viewport).isNull && !$0.intersection(viewport).isEmpty
        } ?? false
        let tolerance = destination.scale
        let previewContained = previewRect.map {
            viewport.insetBy(dx: -tolerance, dy: -tolerance).contains($0)
        } ?? false

        let norseCodexID = ThemeFidelityTheme.norse.codexID
        let norseProvider = snapshot.providers.first(where: {
            $0.codexID == norseCodexID
        })
        let norseInventoryExists = snapshot.presentationInventories.contains(where: {
            $0.codexID == norseCodexID
        })
        let reportedLockedNorseElements = rendered.elementFrames.frames.filter {
            $0.elementID.contains(norseCodexID.rawValue)
                && $0.elementID.localizedCaseInsensitiveContains("locked")
        }.count
        let providerLockedCount = norseProvider?.state == .locked ? 1 : 0

        return ThemeFidelityRuntimeDiagnostics(
            activeThemeID: snapshot.effectiveTheme.id.rawValue,
            activeCodexID: snapshot.effectiveCodexID.rawValue,
            effectiveMotionMode: effectiveMotionMode,
            activeThemeAnimationCount: session.resourcePresentation
                .activeThemeAnimationCount,
            effectiveBackgroundResourceID: effectiveBackgroundResourceID,
            declaredReduceMotionBackgroundResourceID:
                background.reduceMotionResourceID.rawValue,
            visualPlanRevision: model.visualPlanRevision,
            preview: ThemeFidelityRuntimeDiagnostics.Preview(
                elementID: previewID,
                exists: previewExists,
                visible: previewVisible,
                viewportContained: previewContained
            ),
            norseBase: ThemeFidelityRuntimeDiagnostics.NorseBase(
                owned: norseProvider?.isOwned == true,
                selectable: norseProvider?.isSelectable == true,
                fallbackAvailable: norseProvider?.state == .available
                    && norseProvider?.isOwned == true
                    && norseInventoryExists
                    && !snapshot.requiredBaseResourceFailures.contains(where: {
                        $0.codexID == norseCodexID
                    }),
                lockedElementCount: reportedLockedNorseElements + providerLockedCount,
                optionalLockedRendererCovered: optionalLockedRendererCovered
            )
        )
    }

    static func runtimeProbeObservations(
        theme: ThemeFidelityTheme,
        surface: ThemeFidelitySurface,
        diagnostics: ThemeFidelityRuntimeDiagnostics,
        stability: ThemeFidelityReduceMotionStability?
    ) -> [ThemeFidelityRuntimeProbeObservation] {
        if theme == .norse, surface == .vaultLocked {
            return [
                probe(
                    "probe.norse.base-owned",
                    source: "hosted-progression-diagnostic",
                    .bool(diagnostics.norseBase.owned)
                ),
                probe(
                    "probe.norse.base-selectable",
                    source: "hosted-theme-diagnostic",
                    .bool(diagnostics.norseBase.selectable)
                ),
                probe(
                    "probe.norse.fallback-available",
                    source: "hosted-theme-diagnostic",
                    .bool(diagnostics.norseBase.fallbackAvailable)
                ),
                probe(
                    "probe.optional-codex.locked-renderer-covered",
                    source: "hosted-ui-fixture",
                    .bool(diagnostics.norseBase.optionalLockedRendererCovered)
                ),
            ]
        }

        let themeProbeSuffix = diagnostics.activeThemeID
        var observations = [probe(
            "probe.theme.active.\(themeProbeSuffix)",
            source: "hosted-runtime-diagnostic",
            .string(diagnostics.activeThemeID)
        )]
        guard surface == .reduceMotion, let stability else { return observations }
        observations.append(contentsOf: [
            probe(
                "probe.motion.mode.\(themeProbeSuffix)",
                source: "hosted-runtime-diagnostic",
                .string(diagnostics.effectiveMotionMode)
            ),
            probe(
                "probe.motion.active-animation-count.\(themeProbeSuffix)",
                source: "hosted-runtime-diagnostic",
                .integer(diagnostics.activeThemeAnimationCount)
            ),
            probe(
                "probe.motion.background-resource.\(themeProbeSuffix)",
                source: "hosted-runtime-diagnostic",
                .bool(
                    diagnostics.effectiveBackgroundResourceID
                        == diagnostics.declaredReduceMotionBackgroundResourceID
                )
            ),
            probe(
                "probe.motion.visual-plan-revision.\(themeProbeSuffix)",
                source: "hosted-runtime-diagnostic",
                .unsignedInteger(diagnostics.visualPlanRevision)
            ),
            probe(
                "probe.motion.frame-stability.\(themeProbeSuffix)",
                source: "visual-runner",
                .number(stability.luminanceSSIM)
            ),
        ])
        return observations
    }

    static func structuralAssertionObservations(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel,
        snapshot: ThemeCoordinatorSnapshotDTO,
        destination: ThemeFidelityDestination,
        route: ThemeFidelityRoute,
        rendered: ThemeFidelityRenderedPNG,
        runtimeDiagnostics: ThemeFidelityRuntimeDiagnostics,
        rendererOutputs: [ThemeFidelityRendererOutput]
    ) throws -> [String: ThemeFidelityStructuralAssertionObservation] {
        let assertionIDs = structuralAssertionIDs(for: surface)
        let targetIDs = structuralElementIDs(
            surface: surface,
            route: route,
            rendererOutputs: rendererOutputs
        )
        let frameMap = Dictionary(uniqueKeysWithValues: rendered.elementFrames.frames.map {
            ($0.elementID, frameRect($0))
        })
        let rendererOutputIDs = Set(rendererOutputs.map(\.outputID))
        let frameTargetIDs = targetIDs.filter { frameMap[$0] != nil }
        let missingTargetIDs = targetIDs.filter {
            frameMap[$0] == nil && !rendererOutputIDs.contains($0)
        }
        let viewport = CGRect(
            x: 0,
            y: 0,
            width: destination.pixelWidth,
            height: destination.pixelHeight
        )
        let tolerance = destination.scale
        let visibleTargetIDs = frameTargetIDs.filter {
            guard let frame = frameMap[$0] else { return false }
            let intersection = frame.intersection(viewport)
            return !intersection.isNull && !intersection.isEmpty
        }
        let containedTargetIDs = frameTargetIDs.filter {
            guard let frame = frameMap[$0] else { return false }
            return viewport.insetBy(dx: -tolerance, dy: -tolerance).contains(frame)
        }
        let usesRendererOutput = surface == .staticShare && !rendererOutputs.isEmpty
        let elementExists = usesRendererOutput
            ? !rendererOutputs.isEmpty
            : missingTargetIDs.isEmpty && !targetIDs.isEmpty
        let elementVisible = missingTargetIDs.isEmpty
            && visibleTargetIDs.count == targetIDs.count
        let elementContained = usesRendererOutput
            ? true
            : missingTargetIDs.isEmpty && containedTargetIDs.count == targetIDs.count

        var result: [String: ThemeFidelityStructuralAssertionObservation] = [:]
        for assertionID in assertionIDs {
            switch assertionID {
            case "assert.element.exists":
                result[assertionID] = assertion(
                    source: usesRendererOutput
                        ? "production-static-renderer" : "hosted-frame-geometry",
                    observed: .bool(elementExists),
                    details: [
                        "targetElementIDs": .strings(targetIDs),
                        "missingElementIDs": .strings(missingTargetIDs),
                    ]
                )
            case "assert.element.visible":
                result[assertionID] = assertion(
                    source: "hosted-frame-geometry",
                    observed: .bool(elementVisible),
                    details: [
                        "targetElementIDs": .strings(targetIDs),
                        "visibleElementIDs": .strings(visibleTargetIDs),
                    ]
                )
            case "assert.element.viewport-contained":
                result[assertionID] = assertion(
                    source: "hosted-frame-geometry",
                    observed: .bool(elementContained),
                    details: [
                        "targetElementIDs": .strings(targetIDs),
                        "containedElementIDs": .strings(containedTargetIDs),
                        "tolerancePoints": .number(1),
                    ]
                )
            case "assert.no-horizontal-overflow":
                let overflowing = frameTargetIDs.filter {
                    guard let frame = frameMap[$0] else { return true }
                    return frame.minX < -tolerance
                        || frame.maxX > viewport.maxX + tolerance
                }
                result[assertionID] = assertion(
                    source: "hosted-frame-geometry",
                    observed: .bool(!overflowing.isEmpty || !missingTargetIDs.isEmpty),
                    details: [
                        "overflowingElementIDs": .strings(overflowing),
                        "missingElementIDs": .strings(missingTargetIDs),
                    ]
                )
            case "assert.mobile-hit-targets":
                let controlIDs = hitTargetElementIDs(surface: surface)
                let measuredControlIDs = controlIDs.filter { frameMap[$0] != nil }
                let missingControlIDs = controlIDs.filter { frameMap[$0] == nil }
                let minimumPoints = measuredControlIDs.compactMap { frameMap[$0] }.map {
                    min($0.width, $0.height) / destination.scale
                }.min() ?? 0
                result[assertionID] = assertion(
                    source: "hosted-exact-control-geometry",
                    observed: .number(minimumPoints),
                    details: [
                        "requiredControlIDs": .strings(controlIDs),
                        "measuredElementIDs": .strings(measuredControlIDs),
                        "missingElementIDs": .strings(missingControlIDs),
                        "minimumMeasuredPoints": .number(minimumPoints),
                    ]
                )
            case "assert.no-placeholder-art":
                let missingResources = missingVisualResources(
                    surface: surface,
                    model: model,
                    rendered: rendered,
                    rendererOutputs: rendererOutputs
                )
                result[assertionID] = assertion(
                    source: "hosted-resource-binding",
                    observed: .integer(missingResources.count),
                    details: ["missingResourceIDs": .strings(missingResources)]
                )
            case "assert.no-system-symbol-artifact":
                let missingResources = missingPickerArtworkResources(
                    surface: surface,
                    model: model,
                    rendered: rendered
                )
                result[assertionID] = assertion(
                    source: "hosted-resource-binding",
                    observed: .integer(missingResources.count),
                    details: ["missingArtworkResourceIDs": .strings(missingResources)]
                )
            case "assert.safe-region-no-overlap":
                let plan = compositionPlan(surface: surface, model: model)
                let overlaps = plan.sealAnchor.map {
                    plan.layout.glyphSafeRegion.contains($0)
                } ?? false
                result[assertionID] = assertion(
                    source: "active-composition-plan",
                    observed: .bool(overlaps),
                    details: [
                        "layoutID": .string(plan.layout.id.rawValue),
                        "sealPresent": .bool(plan.sealAnchor != nil),
                    ]
                )
            case "assert.state-text-shape-truthful":
                let truth = stateTruth(
                    surface: surface,
                    model: model,
                    snapshot: snapshot,
                    rendered: rendered,
                    runtimeDiagnostics: runtimeDiagnostics
                )
                result[assertionID] = assertion(
                    source: "hosted-runtime-state",
                    observed: .bool(truth.value),
                    details: truth.details
                )
            case "assert.interactive-static-plan-parity":
                let request = try ShareArtifactRenderRequest(
                    selection: model.selection,
                    inscription: model.previewText,
                    operationID: RuntimeOperationID(
                        rawValue: "operation.theme-fidelity.plan-parity"
                    ),
                    capturedAt: ThemeFidelityRuntimeFixture.fixedDate,
                    accessibilityLabel: model.previewPlan.accessibilityLabel,
                    provenanceLabel: model.previewPlan.provenanceLabel
                )
                let staticPlan = try ShareArtifactRenderPolicy.plan(
                    request: request,
                    descriptor: model.descriptor
                ).composition
                result[assertionID] = assertion(
                    source: "production-composition-policy",
                    observed: .bool(staticPlan == model.previewPlan),
                    details: [
                        "interactiveBackgroundResourceID": .string(
                            model.previewPlan.backgroundResourceID.rawValue
                        ),
                        "staticBackgroundResourceID": .string(
                            staticPlan.backgroundResourceID.rawValue
                        ),
                    ]
                )
            case "assert.all-three-relics-present":
                let expectedRelicIDs = model.descriptor.codex.relics
                    .filter { $0.metadata.availability != .reservedInactive }
                    .map(\.metadata.id.rawValue)
                    .sorted()
                let relicIDs = expectedRelicIDs.filter {
                    frameMap["theme.artifact-picker.\($0)"] != nil
                }
                result[assertionID] = assertion(
                    source: "hosted-exact-picker-tile-geometry",
                    observed: .strings(relicIDs),
                    details: [
                        "observedCount": .integer(relicIDs.count),
                        "expectedArtifactIDs": .strings(expectedRelicIDs),
                        "missingArtifactIDs": .strings(
                            expectedRelicIDs.filter { !relicIDs.contains($0) }
                        ),
                    ]
                )
            case "assert.all-six-seals-present":
                let expectedSealIDs = model.descriptor.codex.seals
                    .filter { $0.metadata.availability != .reservedInactive }
                    .map(\.metadata.id.rawValue)
                    .sorted()
                let sealIDs = expectedSealIDs.filter {
                    frameMap["theme.artifact-picker.\($0)"] != nil
                }
                result[assertionID] = assertion(
                    source: "hosted-exact-picker-tile-geometry",
                    observed: .strings(sealIDs),
                    details: [
                        "observedCount": .integer(sealIDs.count),
                        "expectedArtifactIDs": .strings(expectedSealIDs),
                        "missingArtifactIDs": .strings(
                            expectedSealIDs.filter { !sealIDs.contains($0) }
                        ),
                    ]
                )
            case "assert.mastery-frame-crest-title-present":
                let frame = model.descriptor.codex.frames.first
                let crest = model.descriptor.codex.crests.first
                let frameID = frame?.metadata.id.rawValue
                let crestID = crest?.metadata.id.rawValue
                let frameObserved = frame.map {
                    frameMap[ThemeCaptureIdentifier.masteryFrame(
                        artifactID: $0.metadata.id
                    )] != nil
                } ?? false
                let crestObserved = crest.flatMap {
                    CrestID(rawValue: $0.metadata.id.rawValue)
                }.map {
                    frameMap[ThemeCaptureIdentifier.masteryCrest(crestID: $0)] != nil
                } ?? false
                let panelObserved = frameMap[ThemeCaptureIdentifier.mastery(
                    codexID: model.descriptor.codex.id
                )] != nil || frameMap[ThemeCaptureIdentifier.masteryScreen(
                    codexID: model.descriptor.codex.id
                )] != nil
                var components: [String] = []
                if frameObserved, let frameID { components.append(frameID) }
                if crestObserved, let crestID { components.append(crestID) }
                if panelObserved { components.append(model.theme.masteryTitleID.rawValue) }
                result[assertionID] = assertion(
                    source: "hosted-mastery-geometry-and-reveal-model",
                    observed: .strings(components.sorted()),
                    details: [
                        "observedCount": .integer(components.count),
                        "frameVisualObserved": .bool(frameObserved),
                        "crestVisualObserved": .bool(crestObserved),
                        "titleModelObserved": .bool(panelObserved),
                    ]
                )
            case "assert.large-text-required-controls-visible":
                let controlIDs = largeTextControlIDs
                let missingControlIDs = controlIDs.filter { frameMap[$0] == nil }
                let visibleControlIDs = controlIDs.filter {
                    guard let frame = frameMap[$0] else { return false }
                    let intersection = frame.intersection(viewport)
                    return !intersection.isNull && !intersection.isEmpty
                }
                let containedControlIDs = controlIDs.filter {
                    guard let frame = frameMap[$0] else { return false }
                    return viewport.insetBy(dx: -tolerance, dy: -tolerance).contains(frame)
                }
                let controlsVisible = missingControlIDs.isEmpty
                    && visibleControlIDs.count == controlIDs.count
                    && containedControlIDs.count == controlIDs.count
                    && !model.shortText.isEmpty
                result[assertionID] = assertion(
                    source: "hosted-exact-large-text-control-geometry",
                    observed: .bool(controlsVisible),
                    details: [
                        "requiredControlIDs": .strings(controlIDs),
                        "missingControlIDs": .strings(missingControlIDs),
                        "visibleControlIDs": .strings(visibleControlIDs),
                        "containedControlIDs": .strings(containedControlIDs),
                        "dynamicTypeSize": .string("accessibility5"),
                    ]
                )
            default:
                break
            }
        }
        return result
    }

    static func assertRuntimeRequirements(
        theme: ThemeFidelityTheme,
        surface: ThemeFidelitySurface,
        diagnostics: ThemeFidelityRuntimeDiagnostics,
        stability: ThemeFidelityReduceMotionStability?,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(
            diagnostics.activeThemeID,
            theme.descriptor.id.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.activeCodexID,
            theme.codexID.rawValue,
            file: file,
            line: line
        )
        if surface == .reduceMotion {
            XCTAssertEqual(diagnostics.effectiveMotionMode, "reduce-motion", file: file, line: line)
            XCTAssertEqual(diagnostics.activeThemeAnimationCount, 0, file: file, line: line)
            XCTAssertEqual(
                diagnostics.effectiveBackgroundResourceID,
                diagnostics.declaredReduceMotionBackgroundResourceID,
                file: file,
                line: line
            )
            XCTAssertGreaterThan(diagnostics.visualPlanRevision, 0, file: file, line: line)
            XCTAssertTrue(diagnostics.preview.exists, file: file, line: line)
            XCTAssertTrue(diagnostics.preview.visible, file: file, line: line)
            XCTAssertTrue(diagnostics.preview.viewportContained, file: file, line: line)
            XCTAssertNotNil(stability, file: file, line: line)
            if let stability {
                XCTAssertGreaterThanOrEqual(
                    stability.separationSeconds,
                    1.5,
                    file: file,
                    line: line
                )
                XCTAssertGreaterThanOrEqual(
                    stability.luminanceSSIM,
                    0.995,
                    file: file,
                    line: line
                )
            }
        }
        if theme == .norse, surface == .vaultLocked {
            XCTAssertTrue(diagnostics.norseBase.owned, file: file, line: line)
            XCTAssertTrue(diagnostics.norseBase.selectable, file: file, line: line)
            XCTAssertTrue(diagnostics.norseBase.fallbackAvailable, file: file, line: line)
            XCTAssertEqual(diagnostics.norseBase.lockedElementCount, 0, file: file, line: line)
            XCTAssertTrue(
                diagnostics.norseBase.optionalLockedRendererCovered,
                file: file,
                line: line
            )
        }
    }

    private static func probe(
        _ id: String,
        source: String,
        _ observed: ThemeFidelityJSONValue
    ) -> ThemeFidelityRuntimeProbeObservation {
        ThemeFidelityRuntimeProbeObservation(
            probeID: id,
            source: source,
            observed: observed
        )
    }

    private static func assertion(
        source: String,
        observed: ThemeFidelityJSONValue,
        details: [String: ThemeFidelityJSONValue]
    ) -> ThemeFidelityStructuralAssertionObservation {
        ThemeFidelityStructuralAssertionObservation(
            source: source,
            observed: observed,
            details: details
        )
    }

    private static func frameRect(_ frame: ThemeFidelityElementFrames.Frame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    static func structuralAssertionIDs(
        for surface: ThemeFidelitySurface
    ) -> [String] {
        return switch surface {
        case .workspaceEmpty:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.no-horizontal-overflow",
             "assert.mobile-hit-targets", "assert.no-placeholder-art"]
        case .composeShort, .inscriptionPreview:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.safe-region-no-overlap",
             "assert.no-placeholder-art"]
        case .composeLong:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.safe-region-no-overlap",
             "assert.no-horizontal-overflow"]
        case .receivedCipher:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.state-text-shape-truthful"]
        case .shareBuilder:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.mobile-hit-targets",
             "assert.interactive-static-plan-parity"]
        case .staticShare:
            ["assert.element.exists", "assert.safe-region-no-overlap",
             "assert.interactive-static-plan-parity", "assert.no-placeholder-art"]
        case .settingsCodexCard:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.state-text-shape-truthful",
             "assert.no-placeholder-art"]
        case .settingsDefaultsPreview:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.interactive-static-plan-parity"]
        case .vaultLocked:
            ["assert.state-text-shape-truthful", "assert.element.viewport-contained"]
        case .vaultProgress, .vaultEncountered, .vaultOwned, .vaultSelected:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.state-text-shape-truthful"]
        case .relicPicker:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.all-three-relics-present",
             "assert.no-system-symbol-artifact"]
        case .sealPicker:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.all-six-seals-present",
             "assert.no-system-symbol-artifact"]
        case .mastery:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.mastery-frame-crest-title-present",
             "assert.safe-region-no-overlap"]
        case .highContrast:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.state-text-shape-truthful"]
        case .reduceMotion:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained"]
        case .largeText:
            ["assert.element.exists", "assert.element.visible",
             "assert.element.viewport-contained", "assert.no-horizontal-overflow",
             "assert.large-text-required-controls-visible"]
        }
    }

    private static func hitTargetElementIDs(
        surface: ThemeFidelitySurface
    ) -> [String] {
        switch surface {
        case .workspaceEmpty:
            [
                "workspace.artifact-control.relic",
                "workspace.artifact-control.seal",
                "workspace.artifact-control.frame",
            ]
        case .shareBuilder:
            [
                "share-builder.reset-defaults",
                "share-builder.save-defaults",
                "share-builder.share",
            ]
        default:
            []
        }
    }

    fileprivate static var largeTextControlIDs: [String] {
        var identifiers = [
            "workspace.result.edit",
            "workspace.result.copy",
            "message.quick-share",
            "message.customize-share",
            "workspace.result.clear",
        ]
        #if os(iOS)
        identifiers.append("message.imessage-share")
        #endif
        return identifiers
    }

    private static func structuralElementIDs(
        surface: ThemeFidelitySurface,
        route: ThemeFidelityRoute,
        rendererOutputs: [ThemeFidelityRendererOutput]
    ) -> [String] {
        if surface == .staticShare {
            return rendererOutputs.map(\.outputID)
        }
        return route.authorityElementIDs
    }

    private static func compositionPlan(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel
    ) -> ThemeArtifactCompositionPlan {
        switch surface {
        case .highContrast:
            model.highContrastPlan
        case .reduceMotion:
            model.reduceMotionPlan
        default:
            model.previewPlan
        }
    }

    private static func compositionResourceIDs(
        _ plan: ThemeArtifactCompositionPlan
    ) -> [ThemeResourceID] {
        [
            plan.relicResourceID,
            plan.sealResourceID,
            plan.frameResourceID,
            plan.backgroundResourceID,
        ].compactMap { $0 }
    }

    private static func missingVisualResources(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel,
        rendered: ThemeFidelityRenderedPNG,
        rendererOutputs: [ThemeFidelityRendererOutput]
    ) -> [String] {
        if surface == .staticShare {
            return rendererOutputs.isEmpty ? ["renderer-output"] : []
        }
        let requiredIDs: [ThemeResourceID] = switch surface {
        case .workspaceEmpty:
            [model.descriptor.codex.background.staticBaseResourceID]
        case .settingsCodexCard:
            [model.descriptor.codex.vault.selectedResourceID]
        default:
            compositionResourceIDs(compositionPlan(surface: surface, model: model))
        }
        let renderedIDs = Set(rendered.renderedResourceIDs)
        return Array(Set(requiredIDs)).filter { resourceID in
            !renderedIDs.contains(resourceID.rawValue)
        }.map(\.rawValue).sorted()
    }

    private static func missingPickerArtworkResources(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel,
        rendered: ThemeFidelityRenderedPNG
    ) -> [String] {
        let resourceIDs: [ThemeResourceID]
        switch surface {
        case .relicPicker:
            resourceIDs = model.descriptor.codex.relics
                .filter { $0.metadata.availability != .reservedInactive }
                .map(\.thumbnailResourceID)
        case .sealPicker:
            resourceIDs = model.descriptor.codex.seals
                .filter { $0.metadata.availability != .reservedInactive }
                .map(\.thumbnailResourceID)
        default:
            resourceIDs = []
        }
        let renderedIDs = Set(rendered.renderedResourceIDs)
        return Array(Set(resourceIDs)).filter { resourceID in
            !renderedIDs.contains(resourceID.rawValue)
        }.map(\.rawValue).sorted()
    }

    private static func stateTruth(
        surface: ThemeFidelitySurface,
        model: ThemeFidelityRenderModel,
        snapshot: ThemeCoordinatorSnapshotDTO,
        rendered: ThemeFidelityRenderedPNG,
        runtimeDiagnostics: ThemeFidelityRuntimeDiagnostics
    ) -> (value: Bool, details: [String: ThemeFidelityJSONValue]) {
        switch surface {
        case .highContrast:
            let truthful = model.highContrastPlan.colorMode == .highContrast
                && model.highContrastPlan.backgroundResourceID
                    == model.descriptor.codex.background.highContrastResourceID
            return (truthful, [
                "colorMode": .string(model.highContrastPlan.colorMode.rawValue),
                "backgroundResourceID": .string(
                    model.highContrastPlan.backgroundResourceID.rawValue
                ),
            ])
        case .receivedCipher:
            let renderedSafePreview = rendered.elementFrames.frames.contains(where: {
                $0.elementID == "received.safe-preview"
            })
            let truthful = model.safePreviewStatus == .valid
                ? renderedSafePreview && model.safePreviewData != nil
                : !renderedSafePreview
            return (truthful, [
                "safePreviewStatus": .string(String(describing: model.safePreviewStatus)),
                "safePreviewRendered": .bool(renderedSafePreview),
            ])
        case .settingsCodexCard:
            let provider = snapshot.providers.first(where: {
                $0.codexID == model.descriptor.codex.id
            })
            let truthful = provider?.isSelected == true
                && snapshot.effectiveCodexID == model.descriptor.codex.id
            return (truthful, [
                "providerSelected": .bool(provider?.isSelected == true),
                "providerState": .string(provider?.state.rawValue ?? "missing"),
            ])
        case .vaultLocked:
            let truthful = model.theme == .norse
                ? runtimeDiagnostics.norseBase.lockedElementCount == 0
                : ThemeCaptureIdentifier.vault(
                    codexID: model.descriptor.codex.id,
                    state: .locked
                ).map { lockedID in
                    rendered.elementFrames.frames.contains(where: {
                        $0.elementID == lockedID
                    })
                } ?? false
            return (truthful, [
                "themeID": .string(model.descriptor.id.rawValue),
                "norseLockedElementCount": .integer(
                    runtimeDiagnostics.norseBase.lockedElementCount
                ),
            ])
        case .vaultProgress, .vaultEncountered, .vaultOwned, .vaultSelected:
            let requiredVisible = rendered.viewportAssertions.clippedElementIDs.isEmpty
            return (requiredVisible, [
                "surface": .string(surface.rawValue),
                "clippedElementIDs": .strings(
                    rendered.viewportAssertions.clippedElementIDs
                ),
            ])
        default:
            return (true, ["surface": .string(surface.rawValue)])
        }
    }

    private static func luminancePixels(
        _ data: Data
    ) throws -> (width: Int, height: Int, values: [Double]) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ThemeFidelityCaptureError.renderFailed }
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ThemeFidelityCaptureError.renderFailed }
        var values = [Double]()
        values.reserveCapacity(width * height)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let red = Double(rgba[offset]) / 255
            let green = Double(rgba[offset + 1]) / 255
            let blue = Double(rgba[offset + 2]) / 255
            values.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        }
        return (width, height, values)
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

private enum ThemeFidelityViewportRevealPolicy {
    static func targetID(
        viewportBounds: CGRect,
        frames: [String: CGRect],
        requiredElementIDs: [String],
        coveringElementIDs: Set<String>
    ) -> String? {
        let candidates = Array(Set(requiredElementIDs)).filter {
            !coveringElementIDs.contains($0) && $0 != ThemeFidelityViewport.rootID
        }
        let clippedFrames = candidates.compactMap { identifier -> (String, CGRect)? in
            guard let frame = frames[identifier],
                  !frame.isNull,
                  !frame.isEmpty,
                  !viewportBounds.contains(frame)
            else { return nil }
            return (identifier, frame.standardized)
        }
        if let outermost = clippedFrames.sorted(by: { lhs, rhs in
            let lhsContains = lhs.1.contains(rhs.1)
            let rhsContains = rhs.1.contains(lhs.1)
            if lhsContains != rhsContains { return lhsContains }
            let lhsArea = lhs.1.width * lhs.1.height
            let rhsArea = rhs.1.width * rhs.1.height
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            return lhs.0 < rhs.0
        }).first {
            return outermost.0
        }
        return candidates.filter { identifier in
            guard let frame = frames[identifier] else { return true }
            return frame.isNull || frame.isEmpty
        }.sorted().first
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
    private let ignoresSafeAreaInsets: Bool
    #if os(macOS)
    private let hostingView: NSHostingView<AnyView>
    private let window: NSWindow
    #elseif os(iOS)
    private let controller: UIHostingController<AnyView>
    private let window: UIWindow
    #endif

    init(ignoresSafeAreaInsets: Bool = false) {
        self.ignoresSafeAreaInsets = ignoresSafeAreaInsets
        #if os(macOS)
        _ = NSApplication.shared
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
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
            capturedAt: Date(),
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
        if ignoresSafeAreaInsets {
            let insets = controller.view.safeAreaInsets
            controller.additionalSafeAreaInsets = UIEdgeInsets(
                top: controller.additionalSafeAreaInsets.top - insets.top,
                left: controller.additionalSafeAreaInsets.left - insets.left,
                bottom: controller.additionalSafeAreaInsets.bottom - insets.bottom,
                right: controller.additionalSafeAreaInsets.right - insets.right
            )
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
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
            capturedAt: Date(),
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

    func recapture(
        destination: ThemeFidelityDestination
    ) throws -> ThemeFidelityImageCapture {
        #if os(macOS)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        else { throw ThemeFidelityCaptureError.renderFailed }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:])
        else { throw ThemeFidelityCaptureError.renderFailed }
        return ThemeFidelityImageCapture(
            data: png,
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh,
            capturedAt: Date()
        )
        #elseif os(iOS)
        let bounds = CGRect(origin: .zero, size: destination.pointSize)
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = destination.scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: destination.pointSize, format: format).image {
            _ in controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage, let png = image.pngData()
        else { throw ThemeFidelityCaptureError.renderFailed }
        return ThemeFidelityImageCapture(
            data: png,
            width: cgImage.width,
            height: cgImage.height,
            capturedAt: Date()
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
        guard let targetID = ThemeFidelityViewportRevealPolicy.targetID(
            viewportBounds: viewportBounds,
            frames: store.frames,
            requiredElementIDs: requiredElementIDs,
            coveringElementIDs: coveringElementIDs
        ) else { return }

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
        guard let targetID = ThemeFidelityViewportRevealPolicy.targetID(
            viewportBounds: viewportBounds,
            frames: store.frames,
            requiredElementIDs: requiredElementIDs,
            coveringElementIDs: coveringElementIDs
        ) else { return }

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
