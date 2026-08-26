import RuneScribeContracts
@testable import RuneScribeUIModule
import XCTest

final class ThemeCaptureIdentifierTests: XCTestCase {
    private struct ThemeFixture {
        let themeID: String
        let codexID: String
        let relicID: String
        let sealID: String
        let frameID: String
        let crestID: String
    }

    private let fixtures = [
        ThemeFixture(
            themeID: "theme.gloamthorn.production",
            codexID: "codex.gloamthorn",
            relicID: "relic.gloamthorn.nightthorn-tablet",
            sealID: "seal.gloamthorn.thornmoon",
            frameID: "frame.gloamthorn.briar-court",
            crestID: "crest.gloamthorn.gloam-sovereign"
        ),
        ThemeFixture(
            themeID: "theme.moonleaf.production",
            codexID: "codex.moonleaf",
            relicID: "relic.moonleaf.tablet",
            sealID: "seal.moonleaf.crescentleaf",
            frameID: "frame.moonleaf.silvervine",
            crestID: "crest.moonleaf.moonbloom"
        ),
        ThemeFixture(
            themeID: "theme.norse.base",
            codexID: "codex.norse",
            relicID: "relic.norse.runestone-tablet",
            sealID: "seal.norse.valknut",
            frameID: "frame.norse.carved-knotwork",
            crestID: "crest.norse.raven-mastery"
        ),
        ThemeFixture(
            themeID: "theme.sunspire.production",
            codexID: "codex.sunspire",
            relicID: "relic.sunspire.dawnfire-tablet",
            sealID: "seal.sunspire.sunleaf-crest",
            frameID: "frame.sunspire.laurel-of-dawn",
            crestID: "crest.sunspire.first-light"
        ),
        ThemeFixture(
            themeID: "theme.wildwood.production",
            codexID: "codex.wildwood",
            relicID: "relic.wildwood.rootsong-tablet",
            sealID: "seal.wildwood.rooted-tree",
            frameID: "frame.wildwood.living-root",
            crestID: "crest.wildwood.heartwood-crown"
        ),
    ]

    func testCatalogIdentifierFamiliesResolveToExactContracts() throws {
        var identifiers: Set<String> = [
            ThemeCaptureIdentifier.screenReceivedCipher,
            ThemeCaptureIdentifier.screenSettingsAppearance,
            ThemeCaptureIdentifier.screenShareBuilder,
            ThemeCaptureIdentifier.screenVaultProgress,
            ThemeCaptureIdentifier.screenWorkspace,
            ThemeCaptureIdentifier.workspacePrimarySurface,
        ]

        for fixture in fixtures {
            let themeID = try XCTUnwrap(ThemeID(rawValue: fixture.themeID))
            let codexID = try XCTUnwrap(CodexID(rawValue: fixture.codexID))
            let relicID = try XCTUnwrap(ArtifactID(rawValue: fixture.relicID))
            let sealID = try XCTUnwrap(ArtifactID(rawValue: fixture.sealID))
            let frameID = try XCTUnwrap(ArtifactID(rawValue: fixture.frameID))
            let crestID = try XCTUnwrap(CrestID(rawValue: fixture.crestID))

            XCTAssertEqual(
                ThemeCaptureIdentifier.artifactPreview(relicID: relicID),
                "theme.artifact-preview.\(fixture.relicID)"
            )
            identifiers.insert(ThemeCaptureIdentifier.settingsDefaultsPreview(codexID: codexID))
            identifiers.insert(ThemeCaptureIdentifier.staticShareRendererOutput(
                codexID: codexID,
                relicID: relicID,
                sealID: sealID,
                colorMode: .standard
            ))
            for kind in [ThemeCaptureIdentifier.PickerKind.relic, .seal] {
                identifiers.insert(ThemeCaptureIdentifier.artifactPickerScreen(
                    kind: kind,
                    codexID: codexID
                ))
                identifiers.insert(ThemeCaptureIdentifier.artifactPicker(
                    kind: kind,
                    codexID: codexID
                ))
            }
            identifiers.insert(ThemeCaptureIdentifier.masteryScreen(codexID: codexID))
            identifiers.insert(ThemeCaptureIdentifier.shareBuilderPreview(codexID: codexID))
            for variant in [
                ThemeCaptureIdentifier.BackgroundVariant.standard,
                .highContrast,
                .reduceMotion,
            ] {
                identifiers.insert(ThemeCaptureIdentifier.background(
                    themeID: themeID,
                    variant: variant
                ))
            }
            for length in [ThemeCaptureIdentifier.ComposeLength.short, .long] {
                identifiers.insert(ThemeCaptureIdentifier.compose(
                    length: length,
                    codexID: codexID
                ))
            }
            identifiers.insert(ThemeCaptureIdentifier.mastery(codexID: codexID))
            identifiers.insert(ThemeCaptureIdentifier.masteryFrame(artifactID: frameID))
            identifiers.insert(ThemeCaptureIdentifier.masteryCrest(crestID: crestID))
            for variant in [
                ThemeCaptureIdentifier.PresentationVariant.highContrast,
                .largeText,
                .reduceMotion,
            ] {
                identifiers.insert(ThemeCaptureIdentifier.presentation(
                    themeID: themeID,
                    variant: variant
                ))
            }
            identifiers.insert(ThemeCaptureIdentifier.receivedArtifactPreview(relicID: relicID))
            for state in [
                ThemeVisualContentState.encountered,
                .locked,
                .owned,
                .progress,
                .selected,
            ] {
                identifiers.insert(try XCTUnwrap(
                    ThemeCaptureIdentifier.vault(codexID: codexID, state: state)
                ))
            }
        }

        XCTAssertEqual(identifiers.count, 131)
        XCTAssertTrue(identifiers.contains("theme.compose.short.codex.norse"))
        XCTAssertTrue(identifiers.contains("theme.mastery.crest.crest.norse.raven-mastery"))
        XCTAssertTrue(identifiers.contains("theme.mastery.frame.frame.norse.carved-knotwork"))
        XCTAssertTrue(identifiers.contains(
            "renderer.static-share.codex.norse.relic.norse.runestone-tablet."
                + "seal.norse.valknut.standard"
        ))
    }

    func testCompatibilityVariantsAndUnavailableVaultStateRemainExplicit() throws {
        let themeID = try XCTUnwrap(ThemeID(rawValue: "theme.norse.base"))
        let codexID = try XCTUnwrap(CodexID(rawValue: "codex.norse"))
        let relicID = try XCTUnwrap(ArtifactID(rawValue: "relic.norse.runestone-tablet"))

        XCTAssertEqual(
            ThemeCaptureIdentifier.presentation(themeID: themeID, variant: .standard),
            "theme.presentation.theme.norse.base.standard"
        )
        XCTAssertEqual(
            ThemeCaptureIdentifier.presentation(themeID: themeID, variant: .emergency),
            "theme.presentation.theme.norse.base.emergency"
        )
        XCTAssertNil(ThemeCaptureIdentifier.vault(codexID: codexID, state: .unavailable))
        XCTAssertEqual(
            ThemeCaptureIdentifier.staticShareRendererOutput(
                codexID: codexID,
                relicID: relicID,
                sealID: nil,
                colorMode: .standard
            ),
            "renderer.static-share.codex.norse.relic.norse.runestone-tablet."
                + "seal.none.standard"
        )
    }
}
