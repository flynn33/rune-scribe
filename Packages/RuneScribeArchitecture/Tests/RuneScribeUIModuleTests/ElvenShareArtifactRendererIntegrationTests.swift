import CryptoKit
import Foundation
import ImageIO
import RuneScribeContracts
import RuneScribeThemeGloamthornModule
import RuneScribeThemeMoonleafModule
import RuneScribeThemeSunspireModule
import RuneScribeThemeWildwoodModule
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class ElvenShareArtifactRendererIntegrationTests: XCTestCase {
    func testEveryElvenRelicAndSealProducesAnOwnedApprovedRenderPlan() throws {
        var relicCount = 0
        var sealCount = 0
        var planCount = 0

        for provider in providers {
            let descriptor = provider.descriptor
            let relics = descriptor.codex.relics
            let seals = descriptor.codex.seals
            let ownedArtifactIDs = Set(
                relics.map(\.metadata.id)
                    + seals.map(\.metadata.id)
                    + descriptor.codex.frames.map(\.metadata.id)
            )
            let builderRelics = ShareBuilderPolicy.relics(
                in: descriptor,
                ownedArtifactIDs: ownedArtifactIDs,
                providerAvailable: true
            )
            let builderSeals = ShareBuilderPolicy.seals(
                in: descriptor,
                ownedArtifactIDs: ownedArtifactIDs,
                providerAvailable: true
            )

            XCTAssertEqual(builderRelics.count, 3, provider.name)
            XCTAssertEqual(builderSeals.count, 6, provider.name)
            XCTAssertTrue(builderRelics.allSatisfy { $0.access == .owned }, provider.name)
            XCTAssertTrue(builderSeals.allSatisfy { $0.access == .owned }, provider.name)
            XCTAssertEqual(Set(builderRelics.map(\.id)), Set(relics.map(\.metadata.id)))
            XCTAssertEqual(Set(builderSeals.map(\.id)), Set(seals.map(\.metadata.id)))

            relicCount += relics.count
            sealCount += seals.count

            for relic in relics {
                for approvedLayout in relic.layouts {
                    assertApprovedBounds(approvedLayout, provider: provider.name)
                }
                let defaultLayout = try XCTUnwrap(relic.layouts.first {
                    $0.id == relic.defaultLayoutID
                })
                let pageCapacity = Int(defaultLayout.maximumGlyphLines) * 24

                for seal in seals {
                    let approvedAnchor = try XCTUnwrap(defaultLayout.sealAnchors.first {
                        seal.allowedAnchors.contains($0.category)
                    })
                    let selection = try ShareBuilderPolicy.selection(
                        descriptor: descriptor,
                        codexOwned: true,
                        providerAvailable: true,
                        ownedArtifactIDs: ownedArtifactIDs,
                        relicID: relic.metadata.id,
                        sealID: seal.metadata.id,
                        frameID: nil
                    )
                    let lengthClass = planCount % 4
                    let characterCount: Int
                    let expectedPageCount: Int
                    switch lengthClass {
                    case 0:
                        characterCount = 12
                        expectedPageCount = 1
                    case 1:
                        characterCount = max(25, pageCapacity / 2)
                        expectedPageCount = 1
                    case 2:
                        characterCount = pageCapacity
                        expectedPageCount = 1
                    default:
                        characterCount = pageCapacity + 1
                        expectedPageCount = 2
                    }
                    let inscription = String(repeating: "ᚠ", count: characterCount)
                    let request = try ShareArtifactRenderRequest(
                        selection: selection,
                        inscription: inscription,
                        operationID: RuntimeOperationID(
                            "operation.elven.plan.\(provider.name).\(planCount)"
                        ),
                        capturedAt: fixedDate,
                        localeIdentifier: fixedLocale,
                        scale: fixedScale,
                        colorMode: .standard,
                        reduceMotion: true,
                        accessibilityLabel: "An encoded \(provider.name) inscription."
                    )
                    let plan = try ShareArtifactRenderPolicy.plan(
                        request: request,
                        descriptor: descriptor,
                        preferredSealAnchor: approvedAnchor.category
                    )

                    XCTAssertEqual(plan.request.selection.relicID, relic.metadata.id)
                    XCTAssertEqual(plan.request.selection.sealID, seal.metadata.id)
                    XCTAssertEqual(plan.layout, defaultLayout)
                    XCTAssertEqual(plan.sealAnchor, approvedAnchor.point)
                    XCTAssertTrue(defaultLayout.relicBounds.contains(approvedAnchor.point))
                    XCTAssertFalse(defaultLayout.glyphSafeRegion.contains(approvedAnchor.point))
                    XCTAssertEqual(plan.pages.count, expectedPageCount)
                    XCTAssertTrue(plan.pages.allSatisfy { $0.count == expectedPageCount })
                    XCTAssertEqual(
                        plan.pages.map(\.inscription).joined()
                            .replacingOccurrences(of: "\n", with: ""),
                        inscription
                    )
                    XCTAssertEqual(plan.request.localeIdentifier, fixedLocale)
                    XCTAssertEqual(plan.request.scale, fixedScale)
                    planCount += 1
                }
            }
        }

        XCTAssertEqual(relicCount, 12)
        XCTAssertEqual(sealCount, 24)
        XCTAssertEqual(planCount, 72)
    }

    func testEveryElvenProviderRendersExactBundleResourcesAcrossAccessibilityVariants()
        throws
    {
        let variants: [(name: String, colorMode: ShareArtifactColorMode, reduceMotion: Bool)] = [
            ("standard", .standard, false),
            ("high-contrast", .highContrast, false),
            ("reduce-motion", .standard, true),
            ("monochrome", .monochrome, false),
        ]
        var renderCount = 0

        for provider in providers {
            let manifest = try loadIntegrityManifest(for: provider)
            XCTAssertEqual(manifest.schemaVersion, "1.0", provider.name)
            XCTAssertEqual(manifest.codexID, provider.descriptor.codex.id.rawValue)
            XCTAssertEqual(manifest.moduleID, provider.descriptor.moduleID.rawValue)
            XCTAssertEqual(manifest.acceptedPackageVersion, "3.1.0", provider.name)
            XCTAssertEqual(manifest.files.count, 46, provider.name)
            let entriesByID = try Dictionary(uniqueKeysWithValues: manifest.files.map { entry in
                (try XCTUnwrap(ThemeResourceID(rawValue: entry.resourceID)), entry)
            })

            let relics = provider.descriptor.codex.relics
            let seals = provider.descriptor.codex.seals
            let ownedArtifactIDs = Set(relics.map(\.metadata.id) + seals.map(\.metadata.id))

            for (variantIndex, variant) in variants.enumerated() {
                let relic = relics[variantIndex % relics.count]
                let seal = seals[(variantIndex + 1) % seals.count]
                let selection = try ShareBuilderPolicy.selection(
                    descriptor: provider.descriptor,
                    codexOwned: true,
                    providerAvailable: true,
                    ownedArtifactIDs: ownedArtifactIDs,
                    relicID: relic.metadata.id,
                    sealID: seal.metadata.id,
                    frameID: nil
                )
                let layout = try XCTUnwrap(relic.layouts.first {
                    $0.id == relic.defaultLayoutID
                })
                let approvedAnchor = try XCTUnwrap(layout.sealAnchors.first {
                    seal.allowedAnchors.contains($0.category)
                })
                let request = try ShareArtifactRenderRequest(
                    selection: selection,
                    inscription: "ELVEN \(provider.name.uppercased()) \(variant.name.uppercased())",
                    operationID: RuntimeOperationID(
                        "operation.elven.static.\(provider.name).\(variant.name)"
                    ),
                    capturedAt: fixedDate,
                    localeIdentifier: fixedLocale,
                    scale: fixedScale,
                    colorMode: variant.colorMode,
                    reduceMotion: variant.reduceMotion,
                    accessibilityLabel: "A static \(provider.name) Artifact preview."
                )
                let plan = try ShareArtifactRenderPolicy.plan(
                    request: request,
                    descriptor: provider.descriptor,
                    preferredSealAnchor: approvedAnchor.category
                )

                XCTAssertEqual(plan.pages.count, 1)
                XCTAssertEqual(plan.layout, layout)
                XCTAssertEqual(plan.sealAnchor, approvedAnchor.point)
                XCTAssertEqual(
                    plan.backgroundResourceID,
                    expectedBackgroundResourceID(
                        descriptor: provider.descriptor,
                        variant: variant
                    )
                )
                XCTAssertEqual(
                    plan.relicResourceID,
                    variant.colorMode == .highContrast
                        ? relic.highContrastResourceID
                        : relic.staticFallbackResourceID
                )
                XCTAssertEqual(
                    plan.sealResourceID,
                    variant.colorMode == .standard
                        ? seal.vectorResourceID
                        : seal.monochromeFallbackResourceID
                )

                let resourceData = try loadPlanResources(
                    plan: plan,
                    provider: provider,
                    entriesByID: entriesByID
                )
                let output = try ShareArtifactStaticRenderer.render(
                    plan: plan,
                    resourceData: resourceData
                )
                let png = try XCTUnwrap(output.pagePNGData.only)
                let metadata = output.safePreviewMetadata
                let expectedWidth = UInt32(ShareArtifactRenderPlan.outputWidth)
                let expectedHeight = UInt32(ShareArtifactRenderPlan.outputHeight)

                XCTAssertEqual(metadata.mediaType, .png)
                XCTAssertEqual(metadata.byteLength, UInt32(png.count))
                XCTAssertLessThanOrEqual(metadata.byteLength, ShareSafePreviewMetadata.maximumByteLength)
                XCTAssertEqual(metadata.pixelSize.width, expectedWidth)
                XCTAssertEqual(metadata.pixelSize.height, expectedHeight)
                XCTAssertEqual(
                    UInt64(metadata.pixelSize.width) * 3,
                    UInt64(metadata.pixelSize.height) * 4
                )
                XCTAssertEqual(metadata.sha256.rawValue, sha256Hex(png))
                try assertRenderedImageBounds(
                    png,
                    expectedWidth: expectedWidth,
                    expectedHeight: expectedHeight,
                    provider: provider.name,
                    variant: variant.name
                )

                let presentation = try output.presentationMetadata(for: plan)
                XCTAssertEqual(presentation.selection, selection)
                XCTAssertTrue(presentation.compatibility.contains(.safePreviewPresent))
                XCTAssertEqual(
                    presentation.compatibility.contains(.highContrastPreviewAvailable),
                    variant.colorMode == .highContrast
                )
                XCTAssertEqual(
                    presentation.compatibility.contains(.monochromePreviewAvailable),
                    variant.colorMode == .monochrome
                )
                renderCount += 1
            }
        }

        XCTAssertEqual(renderCount, 16)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_500)
    private let fixedLocale = "en-US"
    private let fixedScale = 1.0

    private var providers: [ElvenProviderFixture] {
        [
            ElvenProviderFixture(
                name: "moonleaf",
                descriptor: RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor,
                bundle: RuneScribeThemeMoonleafModuleBootstrap.resourceBundle
            ),
            ElvenProviderFixture(
                name: "sunspire",
                descriptor: RuneScribeThemeSunspireModuleBootstrap.discoveryDescriptor,
                bundle: RuneScribeThemeSunspireModuleBootstrap.resourceBundle
            ),
            ElvenProviderFixture(
                name: "wildwood",
                descriptor: RuneScribeThemeWildwoodModuleBootstrap.discoveryDescriptor,
                bundle: RuneScribeThemeWildwoodModuleBootstrap.resourceBundle
            ),
            ElvenProviderFixture(
                name: "gloamthorn",
                descriptor: RuneScribeThemeGloamthornModuleBootstrap.discoveryDescriptor,
                bundle: RuneScribeThemeGloamthornModuleBootstrap.resourceBundle
            ),
        ]
    }

    private func loadIntegrityManifest(
        for provider: ElvenProviderFixture
    ) throws -> ElvenIntegrityManifest {
        let url = try XCTUnwrap(provider.bundle.url(
            forResource: "Resource-Integrity-Manifest-v1.0",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(
            ElvenIntegrityManifest.self,
            from: Data(contentsOf: url)
        )
    }

    private func loadPlanResources(
        plan: ShareArtifactRenderPlan,
        provider: ElvenProviderFixture,
        entriesByID: [ThemeResourceID: ElvenIntegrityManifest.FileEntry]
    ) throws -> [ThemeResourceID: Data] {
        let descriptorReferences = Dictionary(uniqueKeysWithValues:
            provider.descriptor.resources.map { ($0.id, $0) }
        )
        var result: [ThemeResourceID: Data] = [:]

        for metadata in plan.resourceMetadata {
            let entry = try XCTUnwrap(entriesByID[metadata.resourceID])
            let reference = try XCTUnwrap(descriptorReferences[metadata.resourceID])
            XCTAssertEqual(entry.bytes, Int(metadata.byteLength), metadata.resourceID.rawValue)
            XCTAssertEqual(entry.sha256, metadata.sha256.rawValue, metadata.resourceID.rawValue)
            XCTAssertEqual(entry.role, metadata.role.rawValue, metadata.resourceID.rawValue)
            XCTAssertEqual(reference.integrity.byteLength, metadata.byteLength)
            XCTAssertEqual(reference.integrity.sha256, metadata.sha256)

            let relativeURL = URL(fileURLWithPath: entry.path)
            let resourceName = relativeURL.deletingPathExtension().lastPathComponent
            let resourceURL = try XCTUnwrap(provider.bundle.url(
                forResource: resourceName,
                withExtension: relativeURL.pathExtension
            ))
            let data = try Data(contentsOf: resourceURL)
            XCTAssertEqual(data.count, entry.bytes, entry.path)
            XCTAssertEqual(sha256Hex(data), entry.sha256, entry.path)
            result[metadata.resourceID] = data
        }

        XCTAssertEqual(Set(result.keys), Set(plan.resourceMetadata.map(\.resourceID)))
        return result
    }

    private func expectedBackgroundResourceID(
        descriptor: ThemeDescriptor,
        variant: (name: String, colorMode: ShareArtifactColorMode, reduceMotion: Bool)
    ) -> ThemeResourceID {
        if variant.colorMode == .highContrast {
            return descriptor.codex.background.highContrastResourceID
        }
        if variant.reduceMotion {
            return descriptor.codex.background.reduceMotionResourceID
        }
        return descriptor.codex.background.staticBaseResourceID
    }

    private func assertApprovedBounds(
        _ layout: ThemeShareLayoutPreset,
        provider: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let width = UInt32(layout.aspectRatio.width)
        let height = UInt32(layout.aspectRatio.height)
        XCTAssertTrue(
            width * 3 == height * 4 || width * 4 == height * 3,
            provider,
            file: file,
            line: line
        )
        XCTAssertTrue(
            layout.relicBounds.contains(layout.contentSafeRegion),
            provider,
            file: file,
            line: line
        )
        XCTAssertTrue(
            layout.contentSafeRegion.contains(layout.glyphSafeRegion),
            provider,
            file: file,
            line: line
        )
        XCTAssertTrue(
            layout.relicBounds.contains(layout.thumbnailCrop),
            provider,
            file: file,
            line: line
        )
        XCTAssertTrue(layout.sealAnchors.allSatisfy {
            layout.relicBounds.contains($0.point)
                && !layout.glyphSafeRegion.contains($0.point)
        }, provider, file: file, line: line)
    }

    private func assertRenderedImageBounds(
        _ data: Data,
        expectedWidth: UInt32,
        expectedHeight: UInt32,
        provider: String,
        variant: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1, provider, file: file, line: line)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber)
        XCTAssertEqual(width.uint32Value, expectedWidth, "\(provider):\(variant)", file: file, line: line)
        XCTAssertEqual(height.uint32Value, expectedHeight, "\(provider):\(variant)", file: file, line: line)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ElvenProviderFixture {
    let name: String
    let descriptor: ThemeDescriptor
    let bundle: Bundle
}

private struct ElvenIntegrityManifest: Decodable {
    struct FileEntry: Decodable {
        let path: String
        let bytes: Int
        let sha256: String
        let resourceID: String
        let role: String
    }

    let schemaVersion: String
    let codexID: String
    let moduleID: String
    let acceptedPackageVersion: String
    let files: [FileEntry]
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
