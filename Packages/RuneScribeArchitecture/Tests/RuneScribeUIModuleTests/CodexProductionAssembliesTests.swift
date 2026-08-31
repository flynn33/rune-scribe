import Foundation
import RuneScribeContracts
import RuneScribeNorseThemeModule
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class CodexProductionAssembliesTests: XCTestCase {
    func testWorkspaceAndMessageModelsExposeDescriptorResolvedResources() throws {
        let plan = try compositionPlan()
        let workspace = CodexComposeWorkspacePanelModel(
            composition: plan,
            cipherName: "Odin's Ravens",
            relicName: "Runestone Tablet",
            sealName: "Valknut Seal",
            primaryActionTitle: "Preview Message"
        )
        let message = CodexMessagePanelModel(
            format: .short,
            composition: plan
        )

        let expected = Set([
            plan.relicResourceID,
            plan.sealResourceID,
            plan.frameResourceID,
            plan.backgroundResourceID,
        ].compactMap { $0 })
        XCTAssertEqual(workspace.requiredImageResourceIDs, expected)
        XCTAssertEqual(message.requiredImageResourceIDs, expected)
        XCTAssertEqual(message.page, plan.pages[0])
        XCTAssertEqual(message.format.title, "Short Message")
        XCTAssertEqual(message.format.lineCountLabel, "2 Lines")
    }

    func testMessageAndShareModelsFallBackToFirstCompositionPage() throws {
        let plan = try compositionPlan()
        let message = CodexMessagePanelModel(
            format: .long,
            composition: plan,
            pageIndex: 500
        )
        let share = CodexSharePreviewCardModel(
            heading: "Share Preview",
            productName: "Rune Scribe Cipher",
            attribution: "Sent with Rune Scribe",
            deepLinkLabel: "runescribe://message",
            composition: plan,
            pageIndex: -1
        )

        XCTAssertEqual(message.page, plan.pages[0])
        XCTAssertEqual(share.page, plan.pages[0])
        XCTAssertEqual(share.requiredImageResourceIDs, message.requiredImageResourceIDs)
        XCTAssertEqual(message.format.title, "Long Message")
        XCTAssertEqual(message.format.lineCountLabel, "6 Lines")
    }

    func testRelicMessageCanvasUsesTheSharedArtifactRenderer() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/CodexProductionAssemblies.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct CodexRelicMessageCanvas"))
        let end = try XCTUnwrap(
            source.range(of: "struct CodexComposeWorkspacePanel", range: start.upperBound..<source.endIndex)
        )
        let implementation = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(implementation.contains("ThemeArtifactCanvas("))
        XCTAssertTrue(implementation.contains("context: .interactivePreview"))
        XCTAssertTrue(implementation.contains("CodexRelicMessageCanvasGeometry("))
        XCTAssertTrue(
            implementation.contains(
                ".frame(width: canvasRect.width, height: canvasRect.height)"
            )
        )
        XCTAssertTrue(
            implementation.contains(
                ".position(x: canvasRect.midX, y: canvasRect.midY)"
            )
        )
        XCTAssertTrue(implementation.contains("artifactCanvasAccessibilityElement"))
        XCTAssertTrue(implementation.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(implementation.contains(".fill(Color.clear)"))
        XCTAssertTrue(implementation.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(implementation.contains(".accessibilityIdentifier("))
        XCTAssertTrue(implementation.contains(".runtimeViewportFrameProbe("))
        XCTAssertTrue(implementation.contains("ThemeCaptureIdentifier.artifactPreview("))
        XCTAssertFalse(implementation.contains(".font(.custom"))
        XCTAssertFalse(implementation.contains("runeTextInverse"))
    }

    func testMessagePresentationBranchesExposeGenericPreviewWithoutHidingSpecificCanvas() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/CodexProductionAssemblies.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let workspaceStart = try XCTUnwrap(
            source.range(of: "struct CodexComposeWorkspacePanel: View")
        )
        let messageStart = try XCTUnwrap(
            source.range(
                of: "struct CodexMessagePanel: View",
                range: workspaceStart.upperBound..<source.endIndex
            )
        )
        let shareStart = try XCTUnwrap(
            source.range(
                of: "struct CodexSharePreviewCard: View",
                range: messageStart.upperBound..<source.endIndex
            )
        )
        let workspaceImplementation = String(
            source[workspaceStart.lowerBound..<messageStart.lowerBound]
        )
        let messageImplementation = String(
            source[messageStart.lowerBound..<shareStart.lowerBound]
        )

        XCTAssertTrue(messageImplementation.contains("CodexRelicMessageCanvas("))
        for implementation in [workspaceImplementation, messageImplementation] {
            XCTAssertTrue(implementation.contains(".accessibilityElement(children: .contain)"))
            XCTAssertTrue(
                implementation.contains(".accessibilityIdentifier(\"theme.artifact-preview\")")
            )
            XCTAssertTrue(
                implementation.contains(".runtimeViewportFrameProbe(\"theme.artifact-preview\")")
            )
        }
    }

    func testMessageFormatsExposeAuthorityGroundedLayoutMetrics() {
        XCTAssertEqual(CodexMessagePanelFormat.short.headingSpacingFraction, 0.012)
        XCTAssertEqual(CodexMessagePanelFormat.short.artworkSpacingFraction, 0.028)
        XCTAssertEqual(CodexMessagePanelFormat.short.topPaddingFraction, 0.036)
        XCTAssertEqual(CodexMessagePanelFormat.long.headingSpacingFraction, 0.004)
        XCTAssertEqual(CodexMessagePanelFormat.long.artworkVerticalOffsetFraction, -0.036)
    }

    func testWideComposeWorkspaceScaleKeepsControlsInsideResizedViewport() {
        let containerSize = CGSize(width: 764, height: 592)
        let horizontalPadding = containerSize.width * 0.0415
        let railWidth = max(82, containerSize.width * 0.127)
        let railSpacing = containerSize.width * 0.046
        let workspaceWidth = containerSize.width
            - (horizontalPadding * 2)
            - railWidth
            - railSpacing
        let scale = CodexComposeWorkspaceLayout.scale(
            containerSize: containerSize,
            workspaceWidth: workspaceWidth
        )

        XCTAssertEqual(scale, 0.782_341, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            CodexComposeWorkspaceLayout.wideRequiredWorkspaceHeight(
                workspaceWidth: workspaceWidth,
                scale: scale
            ),
            CodexComposeWorkspaceLayout.wideAvailableWorkspaceHeight(
                containerHeight: containerSize.height,
                scale: scale
            ) + 0.001
        )
    }

    func testRelicMessageCanvasPreservesDescriptorGeometryInEveryHostTreatment() throws {
        let layout = try compositionPlan().layout
        let hostSizes: [(name: String, size: CGSize)] = [
            ("canonical", CGSize(width: 1_200, height: 900)),
            ("four-by-three", CGSize(width: 400, height: 300)),
            ("portrait", CGSize(width: 390, height: 844)),
            ("wide", CGSize(width: 980, height: 720)),
            ("resized", CGSize(width: 237, height: 319)),
        ]
        let expectedAspect = CGFloat(layout.aspectRatio.width)
            / CGFloat(layout.aspectRatio.height)

        for sizing in CodexRelicMessageCanvasSizing.allCases {
            for host in hostSizes {
                let geometry = CodexRelicMessageCanvasGeometry(
                    hostSize: host.size,
                    descriptorAspectRatio: layout.aspectRatio,
                    sizing: sizing
                )
                let canvas = geometry.canvasRect
                assertContained(
                    canvas,
                    in: host.size,
                    context: "\(sizing) \(host.name) canvas"
                )
                XCTAssertEqual(
                    canvas.width / canvas.height,
                    expectedAspect,
                    accuracy: 0.000_001,
                    "\(sizing) \(host.name) descriptor aspect"
                )

                for (name, region) in [
                    ("relic", layout.relicBounds),
                    ("glyph", layout.glyphSafeRegion),
                ] {
                    let frame = geometry.rect(for: region)
                    assertContained(
                        frame,
                        in: host.size,
                        context: "\(sizing) \(host.name) \(name)"
                    )
                    XCTAssertEqual(
                        (frame.minX - canvas.minX) / canvas.width,
                        CGFloat(region.x),
                        accuracy: 0.000_001
                    )
                    XCTAssertEqual(
                        (frame.minY - canvas.minY) / canvas.height,
                        CGFloat(region.y),
                        accuracy: 0.000_001
                    )
                    XCTAssertEqual(
                        frame.width / canvas.width,
                        CGFloat(region.width),
                        accuracy: 0.000_001
                    )
                    XCTAssertEqual(
                        frame.height / canvas.height,
                        CGFloat(region.height),
                        accuracy: 0.000_001
                    )
                }

                let relicFrame = geometry.rect(for: layout.relicBounds)
                let sealSide = geometry.sealSideLength(
                    in: relicFrame,
                    normalizedScale: 0.18
                )
                XCTAssertEqual(
                    sealSide / min(relicFrame.width, relicFrame.height),
                    0.18,
                    accuracy: 0.000_001,
                    "\(sizing) \(host.name) descriptor seal scale"
                )

                for anchor in layout.sealAnchors {
                    let point = geometry.point(for: anchor.point)
                    XCTAssertEqual(
                        (point.x - canvas.minX) / canvas.width,
                        CGFloat(anchor.point.x),
                        accuracy: 0.000_001
                    )
                    XCTAssertEqual(
                        (point.y - canvas.minY) / canvas.height,
                        CGFloat(anchor.point.y),
                        accuracy: 0.000_001
                    )
                }
            }
        }

        let messageSlot = CodexRelicMessageCanvasGeometry(
            hostSize: CGSize(width: 50, height: 100.0 / 3.0),
            canvasAspectRatio: CGFloat(ShareArtifactRenderPlan.outputWidth)
                / CGFloat(ShareArtifactRenderPlan.outputHeight),
            sizing: .fillComponentSlot
        ).canvasRect
        XCTAssertEqual(messageSlot.width / messageSlot.height, 4.0 / 3.0, accuracy: 0.000_001)
        XCTAssertLessThan(messageSlot.width, 50)
        XCTAssertEqual(messageSlot.height, 100.0 / 3.0, accuracy: 0.000_001)
    }

    func testMasteryAndBackgroundModelsRequireOnlyDeclaredProductionImages() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let frame = try XCTUnwrap(descriptor.codex.frames.first)
        let crest = try XCTUnwrap(descriptor.codex.crests.first)
        let background = CodexBackgroundTreatmentPanelModel(
            title: descriptor.codex.background.displayName.fallbackValue,
            summary: descriptor.codex.background.accessibility.label.fallbackValue,
            backgroundResourceID: descriptor.codex.background.staticBaseResourceID
        )
        let mastery = CodexMasteryRewardsPanelModel(
            heading: "Mastery Rewards",
            frameName: frame.metadata.displayName.fallbackValue,
            crestName: crest.metadata.displayName.fallbackValue,
            titleName: "Mastery Title",
            titleInscription: "Master of Runes",
            accomplishment: "Awarded for completing Codex mastery.",
            frameResourceID: frame.staticFallbackResourceID,
            crestResourceID: crest.staticFallbackResourceID
        )

        XCTAssertEqual(background.requiredImageResourceIDs, [
            descriptor.codex.background.staticBaseResourceID,
        ])
        XCTAssertEqual(mastery.requiredImageResourceIDs, [
            frame.staticFallbackResourceID,
            crest.staticFallbackResourceID,
        ])
    }

    func testVaultStackPreservesCallerDeclaredStateTruthAndResources() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let vault = descriptor.codex.vault
        let cards = [
            CodexVaultCardStateModel(
                state: .owned,
                heading: "Owned",
                detail: "Owned",
                resourceID: vault.cardResourceID,
                isApplicable: true
            ),
            CodexVaultCardStateModel(
                state: .encountered,
                heading: "Encountered",
                detail: "Encountered",
                resourceID: vault.encounteredResourceID,
                isApplicable: false
            ),
            CodexVaultCardStateModel(
                state: .locked,
                heading: "Locked State (Not Applicable)",
                detail: "Not applicable",
                resourceID: vault.lockedSilhouetteResourceID,
                isApplicable: false
            ),
        ]
        let stack = CodexVaultCardStateStackModel(
            heading: "Vault Codex Card",
            codexName: descriptor.codex.displayName.fallbackValue,
            codexSubtitle: "The Raven Forge",
            cards: cards
        )

        XCTAssertEqual(stack.cards.map(\.state), [.owned, .encountered, .locked])
        XCTAssertEqual(stack.cards.map(\.isApplicable), [true, false, false])
        XCTAssertEqual(stack.requiredImageResourceIDs, [
            vault.cardResourceID,
            vault.encounteredResourceID,
            vault.lockedSilhouetteResourceID,
        ])
        XCTAssertEqual(Set(stack.cards.map(\.id)).count, cards.count)
    }

    func testComposeNavigationIsProviderNeutralAndStable() {
        XCTAssertEqual(
            CodexComposeNavigationItem.allCases.map(\.rawValue),
            ["Compose", "Cipher", "Vault", "Settings"]
        )
        XCTAssertEqual(CodexComposeNavigationItem.compose.systemImage, "square.and.pencil")
    }

    func testArtifactSpecimenLayoutClassifiesDescriptorSemantics() {
        XCTAssertEqual(
            CodexArtifactSpecimenLayout(
                kind: .relic,
                maximumGlyphLines: 5
            ).family,
            .tablet
        )
        XCTAssertEqual(
            CodexArtifactSpecimenLayout(
                kind: .relic,
                maximumGlyphLines: 4
            ).family,
            .plaque
        )
        XCTAssertEqual(
            CodexArtifactSpecimenLayout(
                kind: .relic,
                maximumGlyphLines: 7
            ).family,
            .stele
        )
        XCTAssertEqual(
            CodexArtifactSpecimenLayout(
                kind: .seal,
                maximumGlyphLines: nil
            ).family,
            .seal
        )
    }

    func testArtifactSpecimenNormalizedFramesStayContainedAndArtworkScaleStaysUniform() {
        let layouts: [(name: String, layout: CodexArtifactSpecimenLayout, aspect: Double)] = [
            (
                "tablet",
                CodexArtifactSpecimenLayout(kind: .relic, maximumGlyphLines: 5),
                4.0 / 3.0
            ),
            (
                "plaque",
                CodexArtifactSpecimenLayout(kind: .relic, maximumGlyphLines: 4),
                4.0 / 3.0
            ),
            (
                "stele",
                CodexArtifactSpecimenLayout(kind: .relic, maximumGlyphLines: 7),
                3.0 / 4.0
            ),
            (
                "seal",
                CodexArtifactSpecimenLayout(kind: .seal, maximumGlyphLines: nil),
                1
            ),
        ]
        let hostSizes: [(name: String, size: CGSize)] = [
            ("canonical", CGSize(width: 525, height: 535)),
            ("four-by-three", CGSize(width: 1_200, height: 900)),
            ("portrait", CGSize(width: 390, height: 844)),
            ("wide", CGSize(width: 980, height: 720)),
            ("resized", CGSize(width: 237, height: 319)),
        ]

        for specimen in layouts {
            for host in hostSizes {
                let artwork = specimen.layout.artworkFrame(
                    in: host.size,
                    artworkAspectRatio: specimen.aspect
                )
                let panel = specimen.layout.panelFrame(in: host.size)
                let context = "\(specimen.name) \(host.name)"
                assertContained(artwork, in: host.size, context: "\(context) artwork")
                assertContained(panel, in: host.size, context: "\(context) panel")
                assertContained(
                    normalizedFrame(artwork, in: host.size),
                    in: CGSize(width: 1, height: 1),
                    context: "\(context) normalized artwork"
                )
                assertContained(
                    normalizedFrame(panel, in: host.size),
                    in: CGSize(width: 1, height: 1),
                    context: "\(context) normalized panel"
                )
                XCTAssertEqual(
                    artwork.width / artwork.height,
                    specimen.aspect,
                    accuracy: 0.000_001,
                    "\(context) uniform artwork scale"
                )
            }
        }
    }

    func testProductionAssembliesDoNotBranchOnProviderOrReadComparisonAssets() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/CodexProductionAssemblies.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for forbidden in [
            "theme.norse",
            "codex.norse",
            "relic.norse",
            "seal.norse",
            "04-ASSETS",
            "referenceSHA",
            "NSImage(contentsOf",
            "UIImage(contentsOfFile",
            "Image(systemName: \"sparkle\")",
            "Text(\"✦\")",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Forbidden production marker: \(forbidden)")
        }

        XCTAssertTrue(source.contains("ThemeChromeImage(slot: .panelBorder)"))
        XCTAssertTrue(source.contains("ThemeChromeImage(slot: .tabSelector)"))
        let titleRewardStart = try XCTUnwrap(
            source.range(of: "private func titleReward(width: CGFloat, unit: CGFloat)")
        )
        let vaultStackStart = try XCTUnwrap(
            source.range(
                of: "struct CodexVaultCardStateStack: View",
                range: titleRewardStart.upperBound..<source.endIndex
            )
        )
        let titleRewardSource = String(
            source[titleRewardStart.lowerBound..<vaultStackStart.lowerBound]
        )
        XCTAssertTrue(titleRewardSource.contains("ThemeChromeProtectedContentLayout("))
        XCTAssertTrue(titleRewardSource.contains("panelPixelSize: panelBorderPixelSize"))
        XCTAssertTrue(titleRewardSource.contains("leading: unit * 0.025"))
        XCTAssertTrue(titleRewardSource.contains("trailing: unit * 0.025"))
        XCTAssertFalse(titleRewardSource.contains(".padding(.horizontal, unit * 0.025)"))
        XCTAssertTrue(source.contains("private func vaultCardAspectRatio"))
        XCTAssertTrue(source.contains("16 / 9"))
        XCTAssertFalse(source.contains("case .encountered: 2.10"))
        XCTAssertFalse(source.contains("case .owned, .selected, .progress, .locked, .unavailable: 1.94"))
        XCTAssertFalse(source.contains("sealScaleMultiplier"))
        XCTAssertFalse(source.contains("outwardShift"))
    }

    func testVaultStateArtworkCapsDynamicTypeWithoutHidingCardSemantics() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/CodexProductionAssemblies.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let stateCardStart = try XCTUnwrap(source.range(of: "private func stateCard("))
        let contentStart = try XCTUnwrap(
            source.range(
                of: "private func stateCardContent(",
                range: stateCardStart.upperBound..<source.endIndex
            )
        )
        let aspectRatioStart = try XCTUnwrap(
            source.range(
                of: "private func vaultCardAspectRatio(",
                range: contentStart.upperBound..<source.endIndex
            )
        )
        let stateCardSource = String(
            source[stateCardStart.lowerBound..<contentStart.lowerBound]
        )
        let contentSource = String(
            source[contentStart.lowerBound..<aspectRatioStart.lowerBound]
        )

        XCTAssertTrue(contentSource.contains(".dynamicTypeSize(.medium)"))
        XCTAssertTrue(stateCardSource.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(stateCardSource.contains(".accessibilityLabel(\"\\(model.codexName), \\(card.heading)\")"))
        XCTAssertTrue(stateCardSource.contains(".accessibilityValue(card.detail)"))
    }

    func testOrdinaryAndCanonicalObjectArtworkUsesContainedAspectFitGeometry() throws {
        let moduleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule")
        let visualComponents = try String(
            contentsOf: moduleRoot.appendingPathComponent(
                "Views/ThemeVisualComponents.swift"
            ),
            encoding: .utf8
        )
        let catalog = try String(
            contentsOf: moduleRoot.appendingPathComponent(
                "Views/CodexCatalogRoot.swift"
            ),
            encoding: .utf8
        )
        let assemblies = try String(
            contentsOf: moduleRoot.appendingPathComponent(
                "Views/CodexProductionAssemblies.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(visualComponents.contains("CodexArtifactSpecimenLayout("))
        XCTAssertTrue(visualComponents.contains("layout.artworkFrame("))
        XCTAssertTrue(
            visualComponents.contains("pixelsPerPoint: renderPlan.pixelsPerPoint")
        )
        XCTAssertTrue(catalog.contains("pixelsPerPoint: renderPlan.pixelsPerPoint"))
        XCTAssertFalse(visualComponents.contains("size.width * 1.21"))
        XCTAssertFalse(visualComponents.contains("size.width * 1.065"))

        XCTAssertFalse(catalog.contains(".scaleEffect(metrics.heroArtworkScale)"))
        XCTAssertFalse(catalog.contains(".scaleEffect(1.12)"))
        XCTAssertTrue(catalog.contains(".scaledToFit()"))

        XCTAssertFalse(assemblies.contains(".scaleEffect(artworkScale)"))
        XCTAssertFalse(assemblies.contains("artworkOffsetY"))
        XCTAssertTrue(assemblies.contains("containedAspectFitFrame"))
        XCTAssertTrue(assemblies.contains("image(resourceID)\n                .resizable()\n                .scaledToFit()"))
        XCTAssertTrue(assemblies.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(
            assemblies.contains("minHeight: geometry.size.height * 0.16")
        )
        XCTAssertFalse(
            assemblies.contains(".frame(height: geometry.size.height * 0.16)")
        )
    }

    func testCanonicalAssembliesUseProductionSourcesAndOrdinaryPathsWhereApplicable() throws {
        let moduleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule")
        let bindings: [(file: String, type: String)] = [
            ("Views/CodexCatalogRoot.swift", "CodexArtifactSpecimenCard("),
            ("Views/ContentView.swift", "CodexComposeWorkspacePanel("),
            ("Views/ContentView.swift", "CodexMessagePanel("),
            ("Views/SettingsView.swift", "CodexBackgroundTreatmentPanel("),
            ("Views/UnlockRevealView.swift", "CodexMasteryRewardsPanel("),
            ("Views/VaultProgressView.swift", "CodexVaultCardStateStack("),
            ("Views/ReceivedMessageView.swift", "ReceivedCipherPresentationView("),
        ]

        for binding in bindings {
            let source = try String(
                contentsOf: moduleRoot.appendingPathComponent(binding.file),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains(binding.type),
                "Missing ordinary call site for \(binding.type) in \(binding.file)"
            )
            XCTAssertFalse(source.contains("ThemeCanonicalRenderRequest"))
        }

        let shareBuilder = try String(
            contentsOf: moduleRoot.appendingPathComponent("Sharing/ShareBuilderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(shareBuilder.contains("if let image = renderedPreviewImage"))
        XCTAssertFalse(shareBuilder.contains("CodexSharePreviewCard("))
        XCTAssertFalse(shareBuilder.contains("runescribe://message"))

        let qualificationRoute = try String(
            contentsOf: moduleRoot.appendingPathComponent(
                "Views/ThemeFidelityQualificationRoute.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            qualificationRoute.contains("ReceivedCipherPresentationView(")
        )
        XCTAssertTrue(
            qualificationRoute.contains(
                "ReceivedCipherPresentationResourcePlan(descriptor)"
            )
        )

        let root = try String(
            contentsOf: moduleRoot.appendingPathComponent("Views/RootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            root.contains("activeReceivedCipherPresentationBinding(")
        )
        XCTAssertTrue(
            root.contains("prepareActiveReceivedCipherPresentation(")
        )
    }

    private func assertContained(
        _ frame: CGRect,
        in hostSize: CGSize,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tolerance: CGFloat = 0.000_001
        XCTAssertGreaterThanOrEqual(frame.minX, -tolerance, context, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, -tolerance, context, file: file, line: line)
        XCTAssertLessThanOrEqual(
            frame.maxX,
            hostSize.width + tolerance,
            context,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxY,
            hostSize.height + tolerance,
            context,
            file: file,
            line: line
        )
    }

    private func normalizedFrame(_ frame: CGRect, in hostSize: CGSize) -> CGRect {
        CGRect(
            x: frame.minX / hostSize.width,
            y: frame.minY / hostSize.height,
            width: frame.width / hostSize.width,
            height: frame.height / hostSize.height
        )
    }

    private func compositionPlan() throws -> ThemeArtifactCompositionPlan {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let seal = try XCTUnwrap(descriptor.codex.seals.first(where: {
            $0.metadata.availability == .included
        }))
        let selection = try SharePresentationSelection(
            codexID: descriptor.codex.id,
            scriptID: descriptor.codex.primaryScriptID,
            relicID: descriptor.codex.defaultRelicID,
            sealID: seal.metadata.id,
            frameID: nil
        )
        return try ThemeArtifactCompositionPolicy.interactivePlan(
            selection: selection,
            inscription: "ᚠᚢᚦᚨᚱᚲ\nᚷᚹᚺᚾᛁᛃ",
            descriptor: descriptor,
            colorMode: .standard,
            reduceMotion: true,
            accessibilityLabel: "Runic inscription"
        )
    }
}
