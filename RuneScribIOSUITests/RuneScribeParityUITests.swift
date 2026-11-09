import CryptoKit
import Foundation
import RuneScribeNorseThemeModule
import RuneScribeThemeMoonleafModule
import XCTest

@MainActor
final class RuneScribeParityUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testEmergencyBaseThemeLaunchShowsAccessibleNonblockingWarning() throws {
        let app = makeIsolatedApplication()
        app.launchEnvironment[
            "RUNESCRIBE_QUALIFICATION_BASE_RESOURCE_FAILURE"
        ] = "missing-norse-font"
        app.launch()

        if app.windows.firstMatch.waitForExistence(timeout: 5),
           app.windows.firstMatch.frame.width >= 700 {
            throw XCTSkip("The emergency Base launch configuration is qualified on iPhone.")
        }

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }

        let warning = app.descendants(matching: .any)[
            "required-base-theme-warning"
        ].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(
            warning.label,
            "Appearance resources could not be verified. Rune Scribe is using a "
                + "standard emergency appearance. Your ciphers and messages remain available."
        )
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)

        let editor = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(editor.isHittable, app.debugDescription)

        let details = app.buttons["Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(details.isHittable, app.debugDescription)
        details.tap()
        XCTAssertTrue(
            app.staticTexts["Stage: resource-read"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertTrue(app.staticTexts["Code: resource-unavailable"].exists)
        keepScreenshot(app, named: "iphone-base-failure-banner")

        let dismiss = app.buttons["Dismiss appearance warning"]
        XCTAssertTrue(dismiss.isHittable, app.debugDescription)
        dismiss.tap()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(editor.isHittable, app.debugDescription)
    }

    func testMessageShareComposerContainsArtworkAndRunesOnly() throws {
        let app = makeIsolatedApplication()
        app.launch()
        dismissSplashIfPresent(in: app)

        let editor = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        editor.tap()
        editor.typeText("The mountains remember our stories.")
        let encode = app.buttons["RUNE SCRIBE"]
        XCTAssertTrue(encode.waitForExistence(timeout: 5), app.debugDescription)
        encode.tap()
        let share = app.buttons["message.quick-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), app.debugDescription)
        let artwork = app.descendants(matching: .any)[
            "theme.artifact-preview.relic.norse.runestone-tablet"
        ].firstMatch
        XCTAssertTrue(artwork.waitForExistence(timeout: 8), app.debugDescription)
        keepScreenshot(app, named: "message-artwork-and-runes-before-sharing")
        share.tap()
        let activityList = app.otherElements["ActivityListView"]
        XCTAssertTrue(activityList.waitForExistence(timeout: 15), app.debugDescription)
        keepScreenshot(app, named: "message-share-destinations")

        let messages = app.cells.matching(
            NSPredicate(format: "label IN %@", ["Messages", "Message"])
        ).firstMatch
        guard messages.waitForExistence(timeout: 8) else {
            throw XCTSkip(
                "This simulator has no Messages share destination. NativeShareOutcomeTests "
                    + "verifies the concrete image/text payload; a device is required "
                    + "for the native composer screenshot."
            )
        }
        messages.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", ".runescribe")
            ).firstMatch.exists,
            app.debugDescription
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", "message.rune")
            ).firstMatch.exists,
            app.debugDescription
        )
        keepScreenshot(app, named: "message-composer-artwork-and-runes-only")
        app.buttons["Cancel"].tap()
    }

    func testNorseVisualPresentationAndScreenshots() throws {
        let app = makeIsolatedApplication()
        app.launch()

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["SETTINGS"].waitForExistence(timeout: 5))
        let codexCard = app.descendants(matching: .any)[
            "theme.codex-card.codex.norse"
        ].firstMatch
        XCTAssertTrue(codexCard.waitForExistence(timeout: 8), app.debugDescription)
        let expectedTheme = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        XCTAssertEqual(expectedTheme.id.rawValue, "theme.norse.base")
        XCTAssertEqual(expectedTheme.codex.id.rawValue, "codex.norse")
        XCTAssertEqual(
            codexCard.identifier,
            "theme.codex-card.\(expectedTheme.codex.id.rawValue)"
        )
        XCTAssertTrue(codexCard.label.localizedCaseInsensitiveContains("Norse"))
        XCTAssertEqual(codexCard.value as? String, "Selected")
        let activePresentation = app.descendants(matching: .any)[
            "theme.presentation.theme.norse.base.standard"
        ].firstMatch
        XCTAssertTrue(activePresentation.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(activePresentation.value as? String, "Standard")
        XCTAssertFalse(
            app.staticTexts[
                "Your preferred Codex is unavailable. The Base appearance is active."
            ].exists
        )
        XCTAssertFalse(app.staticTexts["Codex appearances are temporarily unavailable."].exists)
        let isPad = app.windows.firstMatch.frame.width >= 700

        let appearanceDefaults = app.descendants(matching: .any)[
            "appearance.selected-codex-defaults"
        ].firstMatch
        let defaultRelic = app.descendants(matching: .any)[
            "appearance.default-relic"
        ].firstMatch
        let defaultSeal = app.descendants(matching: .any)[
            "appearance.default-seal"
        ].firstMatch
        let defaultFrame = app.descendants(matching: .any)[
            "appearance.default-frame"
        ].firstMatch
        let effects = app.descendants(matching: .any)[
            "appearance.effects"
        ].firstMatch
        let defaultsPreview = app.descendants(matching: .any)[
            "appearance.defaults-preview"
        ].firstMatch
        scrollUntilVisible(defaultsPreview, in: app)
        XCTAssertTrue(appearanceDefaults.exists, app.debugDescription)
        XCTAssertTrue(defaultRelic.exists, app.debugDescription)
        XCTAssertTrue(defaultSeal.exists, app.debugDescription)
        XCTAssertTrue(defaultFrame.exists, app.debugDescription)
        XCTAssertTrue(effects.exists, app.debugDescription)
        XCTAssertTrue(defaultsPreview.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(defaultRelic.label, "Default Relic")
        XCTAssertEqual(defaultRelic.value as? String, "Runestone Tablet")
        XCTAssertEqual(defaultSeal.label, "Default Seal")
        XCTAssertEqual(defaultSeal.value as? String, "Valknut Seal")
        XCTAssertEqual(defaultFrame.label, "Default Frame")
        XCTAssertEqual(defaultFrame.value as? String, "None")
        assertFourByThree(defaultsPreview)

        let offEffects = effects.buttons["Off"].firstMatch
        XCTAssertTrue(offEffects.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(offEffects.isHittable, app.debugDescription)
        offEffects.tap()
        XCTAssertTrue(
            app.staticTexts["Effective behavior: Off."].waitForExistence(timeout: 8),
            app.debugDescription
        )
        assertFourByThree(defaultsPreview)

        let fullEffects = effects.buttons["Full"].firstMatch
        XCTAssertTrue(fullEffects.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(fullEffects.isHittable, app.debugDescription)
        fullEffects.tap()
        XCTAssertTrue(
            app.staticTexts["Effective behavior: Full."].waitForExistence(timeout: 8),
            app.debugDescription
        )
        assertFourByThree(defaultsPreview)
        try auditAccessibility(in: app)
        keepScreenshot(
            app,
            named: isPad ? "ipad-appearance-defaults" : "iphone-appearance-defaults"
        )

        if !isPad {
            keepScreenshot(app, named: "iphone-settings-norse")
        }
        tapCloseControl(in: app)

        let relicThumbnail = app.descendants(matching: .any)[
            "theme.artifact-thumbnail.relic.norse.runestone-tablet"
        ].firstMatch
        let sealThumbnail = app.descendants(matching: .any)[
            "theme.artifact-thumbnail.seal.norse.valknut"
        ].firstMatch
        XCTAssertTrue(relicThumbnail.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(sealThumbnail.waitForExistence(timeout: 8), app.debugDescription)

        let workspaceWindow = app.windows.firstMatch
        let viewportBounds = workspaceWindow.frame
        let headerActions = [
            app.buttons["Vault and Progress"],
            app.buttons["Settings"],
            app.buttons["Manage your cipher library"]
        ]
        for action in headerActions {
            XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(action.isHittable, app.debugDescription)
            assertUsableHitRegion(action)
        }
        let workspaceElements = [
            headerActions[0],
            headerActions[1],
            headerActions[2],
            relicThumbnail,
            sealThumbnail,
            app.segmentedControls.buttons["Encode"],
            app.segmentedControls.buttons["Decode"],
            app.textViews.matching(
                NSPredicate(format: "label == %@", "Message to encode")
            ).firstMatch,
            app.buttons["RUNE SCRIBE"]
        ]
        for element in workspaceElements {
            XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
            assertHorizontallyContained(element, in: viewportBounds)
        }

        relicThumbnail.tap()
        let codexCatalog = app.descendants(matching: .any)[
            "codex.catalog.root"
        ].firstMatch
        XCTAssertTrue(codexCatalog.waitForExistence(timeout: 8), app.debugDescription)
        let catalogFeaturedRelic = app.descendants(matching: .any)[
            "codex.catalog.featured-relic"
        ].firstMatch
        XCTAssertTrue(catalogFeaturedRelic.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(catalogFeaturedRelic.elementType, .button, app.debugDescription)
        XCTAssertTrue(catalogFeaturedRelic.isHittable, app.debugDescription)
        XCTAssertFalse(
            catalogFeaturedRelic.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            app.debugDescription
        )
        let catalogFrame = codexCatalog.frame
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(catalogFrame.width, 0)
        XCTAssertGreaterThan(catalogFrame.height, 0)
        XCTAssertGreaterThanOrEqual(catalogFrame.minX, windowFrame.minX - 1)
        XCTAssertGreaterThanOrEqual(catalogFrame.minY, windowFrame.minY - 1)
        XCTAssertLessThanOrEqual(catalogFrame.maxX, windowFrame.maxX + 1)
        XCTAssertLessThanOrEqual(catalogFrame.maxY, windowFrame.maxY + 1)
        let catalogBack = app.buttons["Back"]
        XCTAssertTrue(catalogBack.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(catalogBack.isHittable, app.debugDescription)
        let catalogGuide = app.buttons["Codex guide"]
        let catalogRelicsTab = app.buttons["codex.catalog.tab.relics"]
        let catalogSealsTab = app.buttons["codex.catalog.tab.seals"]
        let catalogSupportingRelic = app.descendants(matching: .any)[
            "codex.catalog.artifact.2"
        ].firstMatch
        let catalogPrimaryAction = app.buttons["codex.catalog.primary-action"]
        let catalogElements = [
            catalogBack,
            catalogGuide,
            catalogRelicsTab,
            catalogSealsTab,
            catalogFeaturedRelic,
            catalogSupportingRelic,
            catalogPrimaryAction
        ]
        for element in catalogElements {
            XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
            assertHorizontallyContained(element, in: windowFrame)
        }
        if isPad {
            XCTAssertGreaterThanOrEqual(catalogFrame.width, 500)
            XCTAssertGreaterThanOrEqual(catalogFrame.height, 500)
        }
        try auditAccessibility(in: app)
        if !isPad {
            keepScreenshot(app, named: "iphone-artifact-picker-norse")
        }
        catalogBack.tap()

        let editor = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        editor.tap()
        editor.typeText("Norse")
        let encodeButton = app.buttons["RUNE SCRIBE"]
        XCTAssertTrue(encodeButton.waitForExistence(timeout: 5), app.debugDescription)
        encodeButton.tap()

        let preview = app.descendants(matching: .any)["theme.artifact-preview"].firstMatch
        let relicPreview = app.descendants(matching: .any)[
            "theme.artifact-preview.relic.norse.runestone-tablet"
        ].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(relicPreview.waitForExistence(timeout: 10), app.debugDescription)
        assertFourByThree(relicPreview)
        assertHorizontallyContained(relicPreview, in: viewportBounds)
        XCTAssertGreaterThanOrEqual(relicPreview.frame.minY, viewportBounds.minY - 1)
        XCTAssertLessThanOrEqual(relicPreview.frame.maxY, viewportBounds.maxY + 1)
        let resultElements = [
            app.buttons["Edit"],
            app.buttons["Copy Runes"],
            app.buttons["Share"],
            app.buttons["message.customize-share"],
            app.buttons["Clear"]
        ]
        for element in resultElements {
            XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
            assertHorizontallyContained(element, in: viewportBounds)
        }
        XCTAssertFalse(
            app.alerts["Standard Share Appearance Used"].exists,
            app.debugDescription
        )
        try auditAccessibility(in: app)
        keepScreenshot(
            app,
            named: isPad ? "ipad-workspace-norse" : "iphone-workspace-norse"
        )

        app.buttons["Vault and Progress"].tap()
        XCTAssertTrue(app.staticTexts["VAULT & PROGRESS"].waitForExistence(timeout: 5))
        selectVaultProgressVaultSection(in: app)
        XCTAssertTrue(app.staticTexts["Active Codex Collection"].waitForExistence(timeout: 8))
        let vaultCodex = app.descendants(matching: .any)[
            "theme.vault.codex.norse"
        ].firstMatch
        XCTAssertTrue(vaultCodex.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Provider available"].exists)
        let vaultRelic = app.descendants(matching: .any)[
            "theme.vault-artifact.relic.norse.runestone-tablet"
        ].firstMatch
        scrollUntilVisible(vaultRelic, in: app)
        XCTAssertTrue(vaultRelic.waitForExistence(timeout: 8), app.debugDescription)
        let selectedVaultState = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Norse Codex, Selected"))
            .firstMatch
        XCTAssertTrue(
            selectedVaultState.waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertEqual(selectedVaultState.value as? String, "Active Codex")
        try auditAccessibility(in: app)
        keepScreenshot(app, named: isPad ? "ipad-vault-norse" : "iphone-vault-norse")
    }

    func testLongArtifactPagesRemainContainedAcrossPagingAndRotation() {
        let app = makeIsolatedApplication()
        app.launch()

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }

        let relicThumbnail = app.descendants(matching: .any)[
            "theme.artifact-thumbnail.relic.norse.runestone-tablet"
        ].firstMatch
        XCTAssertTrue(relicThumbnail.waitForExistence(timeout: 15), app.debugDescription)

        let editor = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        editor.tap()
        editor.typeText(String(repeating: "A", count: 300))

        let encode = app.buttons["RUNE SCRIBE"]
        XCTAssertTrue(encode.waitForExistence(timeout: 8), app.debugDescription)
        encode.tap()

        let preview = app.descendants(matching: .any)["theme.artifact-preview"].firstMatch
        let relicPreview = app.descendants(matching: .any)[
            "theme.artifact-preview.relic.norse.runestone-tablet"
        ].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(relicPreview.waitForExistence(timeout: 15), app.debugDescription)
        assertFourByThree(relicPreview)
        assertHorizontallyContained(relicPreview, in: app.windows.firstMatch.frame)

        let firstPage = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Page 1 of ")
        ).firstMatch
        XCTAssertTrue(firstPage.waitForExistence(timeout: 8), app.debugDescription)
        let nextPage = app.buttons["theme.artifact-preview.next-page"]
        let previousPage = app.buttons["theme.artifact-preview.previous-page"]
        XCTAssertTrue(nextPage.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(previousPage.waitForExistence(timeout: 5), app.debugDescription)
        assertUsableHitRegion(nextPage)
        assertUsableHitRegion(previousPage)
        XCTAssertFalse(previousPage.isEnabled)

        nextPage.tap()
        let secondPage = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Page 2 of ")
        ).firstMatch
        XCTAssertTrue(secondPage.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(previousPage.isEnabled)

        let isPad = app.windows.firstMatch.frame.width >= 700
        keepScreenshot(
            app,
            named: isPad ? "ipad-long-artifact-page-2" : "iphone-long-artifact-page-2"
        )

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeWindow = app.windows.firstMatch
        let rotationDeadline = Date().addingTimeInterval(5)
        while landscapeWindow.frame.width <= landscapeWindow.frame.height,
              Date() < rotationDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(
            landscapeWindow.frame.width,
            landscapeWindow.frame.height,
            app.debugDescription
        )
        scrollUntilVisible(preview, in: app)
        XCTAssertTrue(secondPage.exists, app.debugDescription)
        assertFourByThree(relicPreview)
        assertHorizontallyContained(relicPreview, in: landscapeWindow.frame)
        assertUsableHitRegion(nextPage)
        assertUsableHitRegion(previousPage)
        keepScreenshot(
            app,
            named: isPad
                ? "ipad-long-artifact-landscape"
                : "iphone-long-artifact-landscape"
        )
    }

    func testShareBuilderControlsExposeStableAccessibilityState() throws {
        let app = makeIsolatedApplication()
        app.launch()

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), app.debugDescription)
        let editor = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        editor.tap()
        editor.typeText("Accessible share builder")

        let encodeButton = app.buttons["RUNE SCRIBE"]
        XCTAssertTrue(encodeButton.waitForExistence(timeout: 5), app.debugDescription)
        encodeButton.tap()

        let customizeShare = app.buttons["message.customize-share"]
        XCTAssertTrue(customizeShare.waitForExistence(timeout: 12), app.debugDescription)
        let unlockDismiss = app.buttons["Dismiss"]
        if unlockDismiss.waitForExistence(timeout: 2), unlockDismiss.isHittable {
            unlockDismiss.tap()
        }
        scrollUntilVisible(customizeShare, in: app)
        XCTAssertTrue(customizeShare.isHittable, app.debugDescription)
        customizeShare.tap()

        let builder = app.descendants(matching: .any)["share-builder"].firstMatch
        XCTAssertTrue(builder.waitForExistence(timeout: 12), app.debugDescription)
        let relic = app.buttons["share-builder.relic"].firstMatch
        let seal = app.buttons["share-builder.seal"].firstMatch
        let frame = app.buttons["share-builder.frame"].firstMatch
        let effects = app.descendants(matching: .any)["share-builder.effects"].firstMatch
        XCTAssertTrue(relic.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(seal.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(frame.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(effects.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(relic.value as? String, "Selected, Owned, available")
        XCTAssertEqual(seal.value as? String, "Selected, Owned, available")
        XCTAssertEqual(frame.value as? String, "Selected, available")
        XCTAssertEqual(effects.value as? String, "Full, selected, available")

        seal.tap()
        let lockedSeal = app.buttons[
            "share-builder.seal.option.seal.norse.yggdrasil"
        ].firstMatch
        XCTAssertTrue(lockedSeal.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(
            lockedSeal.label,
            "Yggdrasil Seal, Not selected, Locked, unavailable"
        )
        XCTAssertFalse(lockedSeal.isEnabled)

        let noSeal = app.buttons["share-builder.seal.option.none"].firstMatch
        XCTAssertTrue(noSeal.waitForExistence(timeout: 5), app.debugDescription)
        noSeal.tap()
        XCTAssertTrue(seal.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(seal.label, "Seal: None")
        XCTAssertEqual(seal.value as? String, "Selected, available")

        let share = app.buttons.matching(identifier: "share-builder.share").firstMatch
        scrollUntilVisible(share, in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(share.isHittable, app.debugDescription)
        share.tap()
        let activityList = app.otherElements["ActivityListView"]
        XCTAssertTrue(activityList.waitForExistence(timeout: 12), app.debugDescription)
        dismissSystemShareSheet(in: app, activityList: activityList)
        XCTAssertTrue(activityList.waitForNonExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(builder.waitForNonExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(app.alerts["Couldn't Complete"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Settings"].exists, app.debugDescription)
    }

    func testCipherLibraryContactsImportCanBeSkipped() {
        let app = makeIsolatedApplication()
        app.launch()
        dismissSplashIfPresent(in: app)

        openCipherLibrary(in: app, dismissContactsPrompt: false)
        let skip = app.buttons["Skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(skip.isHittable, app.debugDescription)
        XCTAssertTrue(app.buttons["Import from Contacts"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Add Manually"].exists, app.debugDescription)
        let deviceName = app.windows.firstMatch.frame.width >= 700 ? "ipad" : "iphone"
        keepScreenshot(app, named: "\(deviceName)-contacts-import-skip")
        skip.tap()

        XCTAssertTrue(skip.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["CONTACTS"].exists, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)

        let newCipher = app.buttons["New Cipher"]
        XCTAssertTrue(newCipher.isHittable, app.debugDescription)
        newCipher.tap()
        let createCipher = app.alerts["New Cipher"]
        XCTAssertTrue(createCipher.waitForExistence(timeout: 5), app.debugDescription)
        createCipher.textFields["Label"].tap()
        createCipher.textFields["Label"].typeText("Skipped Contacts Cipher")
        createCipher.buttons["Create"].tap()
        XCTAssertTrue(
            app.staticTexts["Skipped Contacts Cipher"].waitForExistence(timeout: 8),
            app.debugDescription
        )
        XCTAssertTrue(app.staticTexts["2 ciphers"].exists, app.debugDescription)
        keepScreenshot(app, named: "\(deviceName)-cipher-library-after-skip")

        tapCloseControl(in: app)
        openCipherLibrary(in: app, dismissContactsPrompt: false)
        XCTAssertFalse(skip.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(newCipher.isHittable, app.debugDescription)

        app.terminate()
        app.launch()
        dismissSplashIfPresent(in: app)
        openCipherLibrary(in: app, dismissContactsPrompt: false)
        XCTAssertFalse(skip.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(newCipher.isHittable, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Skipped Contacts Cipher"].exists, app.debugDescription)
    }

    func testProductionCipherLibraryContactsPromptCanBeSkipped() throws {
        let app = XCUIApplication()
        app.launch()
        dismissSplashIfPresent(in: app)
        openCipherLibrary(in: app, dismissContactsPrompt: false)
        guard app.staticTexts["Organize ciphers by contact?"].waitForExistence(timeout: 5) else {
            throw XCTSkip(
                "The first-use production prompt requires a fresh app installation. "
                    + "The isolated contacts test exercises it on every run."
            )
        }
        let skip = app.buttons["Skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(skip.isHittable, app.debugDescription)
        keepScreenshot(app, named: "production-contacts-import-skip")
        skip.tap()
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["New Cipher"].isHittable, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        keepScreenshot(app, named: "production-cipher-library-after-skip")
    }

    func testCipherLibraryShareActionsExposeUsableHitRegions() {
        let app = makeIsolatedApplication()
        app.launch()

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), app.debugDescription)
        openCipherLibrary(in: app)

        let share = app.buttons.matching(identifier: "cipher.primary-share").firstMatch
        let customize = app.buttons.matching(identifier: "cipher.customize-share").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(customize.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(share.elementType, .button)
        XCTAssertEqual(customize.elementType, .button)
        assertUsableHitRegion(share)
        assertUsableHitRegion(customize)
    }

    func testIsolatedNormalRouteReadsInboundCipherFiles() throws {
        let app = makeIsolatedApplication()
        app.open(try makeCipherFixtureFile())
        dismissSplashIfPresent(in: app)

        XCTAssertTrue(
            app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8),
            app.debugDescription
        )
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Imported Cipher")
        app.buttons["Import"].tap()
        XCTAssertTrue(app.buttons["Active cipher: Imported Cipher"].waitForExistence(timeout: 8))

        app.open(Self.legacyImportURL)
        dismissSplashIfPresent(in: app)
        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8))
        app.buttons["Import"].tap()
        XCTAssertTrue(app.buttons["Active cipher: Baseline Legacy"].waitForExistence(timeout: 8))
        openCipherLibrary(in: app)
        XCTAssertTrue(app.staticTexts["3 ciphers"].waitForExistence(timeout: 8), app.debugDescription)
    }

    func testFreshInstallExercisesPrimaryProductFlows() throws {
        let app = makeIsolatedApplication()
        app.open(Self.customImportURL)
        dismissSplashIfPresent(in: app)

        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Baseline Custom")
        replaceText(in: app.textFields["Cipher name"], with: "Baseline Custom")
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Baseline Custom")
        let done = app.keyboards.buttons["Done"]
        if done.exists { done.tap() }
        try auditAccessibility(in: app)
        app.buttons.matching(identifier: "xmark").firstMatch.tap()

        XCTAssertTrue(
            app.buttons["Settings"].waitForExistence(timeout: 15),
            app.debugDescription
        )
        XCTAssertTrue(
            app.buttons["Manage your cipher library"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertTrue(
            app.buttons["Active cipher: My Cipher"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertTrue(
            app.buttons["Set recipient to include the key"].waitForExistence(timeout: 5),
            app.debugDescription
        )

        try auditAccessibility(in: app)

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["SETTINGS"].waitForExistence(timeout: 5))
        let setPIN = app.buttons["Set a PIN…"]
        scrollUntilVisible(setPIN, in: app)
        XCTAssertTrue(setPIN.exists, app.debugDescription)
        let manageContacts = app.buttons["Manage Contacts"]
        scrollUntilVisible(manageContacts, in: app)
        XCTAssertTrue(manageContacts.exists, app.debugDescription)
        let viewLicense = app.buttons["View License"]
        scrollUntilVisible(viewLicense, in: app)
        XCTAssertTrue(viewLicense.exists, app.debugDescription)
        try auditAccessibility(in: app)

        XCTAssertTrue(viewLicense.isHittable, app.debugDescription)
        viewLicense.tap()
        let licenseAgreement = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "RUNE SCRIBE\nAPACHE LICENSE, VERSION 2.0"
            )
        ).firstMatch
        XCTAssertTrue(licenseAgreement.waitForExistence(timeout: 5))
        tapCloseControl(in: app)

        scrollUntilVisible(manageContacts, in: app, direction: .towardTop)
        XCTAssertTrue(manageContacts.isHittable, app.debugDescription)
        manageContacts.tap()
        XCTAssertTrue(app.staticTexts["CONTACTS"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No contacts yet"].exists)
        try auditAccessibility(in: app)
        app.buttons["Add Manually"].tap()
        let newContact = app.alerts["New Contact"]
        XCTAssertTrue(newContact.waitForExistence(timeout: 5))
        newContact.textFields["Name"].tap()
        newContact.textFields["Name"].typeText("Parity Contact")
        newContact.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Parity Contact"].waitForExistence(timeout: 5))

        app.buttons["Rename Parity Contact"].tap()
        let renameContact = app.alerts["Rename Contact"]
        XCTAssertTrue(renameContact.waitForExistence(timeout: 5))
        appendTextAtEnd(
            in: renameContact.textFields["Name"],
            suffix: " Edited",
            expectedValue: "Parity Contact Edited"
        )
        renameContact.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Parity Contact Edited"].waitForExistence(timeout: 5))
        tapCloseControl(in: app)

        scrollUntilVisible(setPIN, in: app, direction: .towardBottom)
        XCTAssertTrue(setPIN.isHittable, app.debugDescription)
        setPIN.tap()
        XCTAssertTrue(app.staticTexts["SET PIN"].waitForExistence(timeout: 5))
        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["Confirm PIN"].waitForExistence(timeout: 5))
        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["PIN set"].waitForExistence(timeout: 8))

        tapCloseControl(in: app)
        let protectedDraft = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        XCTAssertTrue(protectedDraft.waitForExistence(timeout: 8), app.debugDescription)
        replaceText(in: protectedDraft, with: "Protected draft")
        let doneAfterDraft = app.buttons.matching(
            identifier: "workspace.keyboard.done"
        ).firstMatch
        if doneAfterDraft.exists { doneAfterDraft.tap() }

        XCUIDevice.shared.press(.home)
        let backgroundDeadline = Date().addingTimeInterval(8)
        while app.state != .runningBackground, Date() < backgroundDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(app.state, .runningBackground)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.activate()
        XCTAssertTrue(
            app.staticTexts["Enter PIN"].waitForExistence(timeout: 8),
            app.debugDescription
        )
        XCTAssertFalse(app.buttons["Settings"].exists, app.debugDescription)
        XCTAssertFalse(
            app.textViews.matching(
                NSPredicate(format: "label == %@", "Message to encode")
            ).firstMatch.exists,
            app.debugDescription
        )
        enterPIN("1234", in: app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))
        let restoredDraft = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        XCTAssertEqual(restoredDraft.value as? String, "Protected draft")
        replaceText(in: restoredDraft, with: "")
        let doneAfterRestore = app.buttons.matching(
            identifier: "workspace.keyboard.done"
        ).firstMatch
        if doneAfterRestore.exists { doneAfterRestore.tap() }
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["SETTINGS"].waitForExistence(timeout: 5))
        let changePIN = app.buttons["Change PIN"]
        scrollUntilVisible(changePIN, in: app)
        XCTAssertTrue(changePIN.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(changePIN.isHittable, app.debugDescription)
        changePIN.tap()
        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["Enter New PIN"].waitForExistence(timeout: 5))
        enterPIN("5678", in: app)
        XCTAssertTrue(app.staticTexts["Confirm PIN"].waitForExistence(timeout: 5))
        enterPIN("5678", in: app)
        XCTAssertTrue(app.staticTexts["PIN set"].waitForExistence(timeout: 8))

        let disablePIN = app.buttons["Disable"]
        scrollUntilVisible(disablePIN, in: app)
        XCTAssertTrue(disablePIN.isHittable, app.debugDescription)
        disablePIN.tap()
        XCTAssertTrue(app.staticTexts["Enter Current PIN"].waitForExistence(timeout: 5))
        enterPIN("5678", in: app)
        XCTAssertTrue(app.staticTexts["No PIN"].waitForExistence(timeout: 8))
        tapCloseControl(in: app)

        openCipherLibrary(in: app)
        XCTAssertTrue(app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import…"].exists)
        XCTAssertTrue(app.buttons["Scan QR Code"].exists)
        try auditAccessibility(in: app)
        let shareButton = app.buttons.matching(identifier: "cipher.primary-share").firstMatch
        XCTAssertTrue(shareButton.waitForExistence(timeout: 8), app.debugDescription)
        shareButton.tap()
        let activityList = app.otherElements["ActivityListView"]
        XCTAssertTrue(activityList.waitForExistence(timeout: 8), app.debugDescription)
        keepScreenshot(
            app,
            named: app.windows.firstMatch.frame.width >= 700
                ? "ipad-cipher-primary-share"
                : "iphone-cipher-primary-share"
        )
        dismissSystemShareSheet(in: app, activityList: activityList)
        XCTAssertTrue(activityList.waitForNonExistence(timeout: 8))

        let customizeCipherShare = app.buttons.matching(
            identifier: "cipher.customize-share"
        ).firstMatch
        XCTAssertTrue(customizeCipherShare.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(customizeCipherShare.isHittable, app.debugDescription)
        customizeCipherShare.tap()
        let isPad = app.windows.firstMatch.frame.width >= 700
        try assertShareBuilder(
            in: app,
            securityIdentifier: "share-builder.security.cipher-invitation",
            expectedNotice: "Contains shared cipher — anyone who imports this invitation receives the decoder for this cipher.",
            screenshotName: isPad
                ? "ipad-share-builder-cipher"
                : "iphone-share-builder-cipher",
            validatesAdaptiveRotation: false
        )
        tapCloseControl(in: app)

        let newCipherButton = app.buttons["New Cipher"]
        XCTAssertTrue(newCipherButton.isHittable, app.debugDescription)
        newCipherButton.tap()
        let newCipher = app.alerts["New Cipher"]
        XCTAssertTrue(newCipher.waitForExistence(timeout: 5))
        newCipher.textFields["Label"].tap()
        newCipher.textFields["Label"].typeText("Parity Cipher")
        newCipher.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Parity Cipher"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["2 ciphers"].exists)

        chooseCipherAction("Rename", for: "Parity Cipher", in: app)
        let renameCipher = app.alerts["Rename Cipher"]
        XCTAssertTrue(renameCipher.waitForExistence(timeout: 5))
        appendTextAtEnd(
            in: renameCipher.textFields["Label"],
            suffix: " Renamed",
            expectedValue: "Parity Cipher Renamed"
        )
        renameCipher.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Parity Cipher Renamed"].waitForExistence(timeout: 8))

        app.buttons["Use My Cipher"].tap()
        XCTAssertTrue(app.buttons["Active My Cipher"].waitForExistence(timeout: 8))
        app.buttons["Use Parity Cipher Renamed"].tap()
        XCTAssertTrue(app.buttons["Active Parity Cipher Renamed"].waitForExistence(timeout: 8))

        let contactMenu = app.buttons["Contact for Parity Cipher Renamed: No contact"]
        XCTAssertTrue(contactMenu.waitForExistence(timeout: 5))
        contactMenu.tap()
        app.buttons["Parity Contact Edited"].tap()
        let linkedContactMenu = app.buttons["Contact for Parity Cipher Renamed: Parity Contact Edited"]
        XCTAssertTrue(linkedContactMenu.waitForExistence(timeout: 8))

        tapCloseControl(in: app)
        let firstDeliveryEditor = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        XCTAssertTrue(firstDeliveryEditor.waitForExistence(timeout: 8), app.debugDescription)
        firstDeliveryEditor.tap()
        firstDeliveryEditor.typeText("First delivery builder")
        let firstDeliveryEncode = app.buttons["RUNE SCRIBE"]
        XCTAssertTrue(firstDeliveryEncode.waitForExistence(timeout: 5), app.debugDescription)
        firstDeliveryEncode.tap()

        let firstDeliveryShare = app.buttons["message.customize-share"]
        XCTAssertTrue(firstDeliveryShare.waitForExistence(timeout: 12), app.debugDescription)
        scrollUntilVisible(firstDeliveryShare, in: app, direction: .towardBottom)
        XCTAssertTrue(firstDeliveryShare.isHittable, app.debugDescription)
        firstDeliveryShare.tap()
        let firstDeliveryIsPad = app.windows.firstMatch.frame.width >= 700
        try assertShareBuilder(
            in: app,
            securityIdentifier: "share-builder.security.first-delivery",
            expectedNotice: "Key included — this first delivery contains the shared cipher.",
            screenshotName: firstDeliveryIsPad
                ? "ipad-share-builder-first-delivery"
                : "iphone-share-builder-first-delivery",
            validatesAdaptiveRotation: firstDeliveryIsPad
        )
        let builderShare = app.buttons.matching(
            identifier: "share-builder.share"
        ).firstMatch
        scrollUntilVisible(builderShare, in: app)
        XCTAssertTrue(builderShare.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(builderShare.isHittable, app.debugDescription)
        builderShare.tap()
        let builderActivityList = app.otherElements["ActivityListView"]
        XCTAssertTrue(builderActivityList.waitForExistence(timeout: 12), app.debugDescription)
        dismissSystemShareSheet(in: app, activityList: builderActivityList)
        XCTAssertTrue(
            builderActivityList.waitForNonExistence(timeout: 12),
            app.debugDescription
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["share-builder"].firstMatch
                .waitForNonExistence(timeout: 12),
            app.debugDescription
        )

        let clearFirstDelivery = app.buttons["Clear"]
        XCTAssertTrue(clearFirstDelivery.waitForExistence(timeout: 8), app.debugDescription)
        scrollUntilVisible(clearFirstDelivery, in: app)
        XCTAssertTrue(clearFirstDelivery.isHittable, app.debugDescription)
        clearFirstDelivery.tap()

        if !firstDeliveryIsPad {
            let establishedDeliveryEditor = app.textViews.matching(
                NSPredicate(format: "label == %@", "Message to encode")
            ).firstMatch
            XCTAssertTrue(
                establishedDeliveryEditor.waitForExistence(timeout: 8),
                app.debugDescription
            )
            establishedDeliveryEditor.tap()
            establishedDeliveryEditor.typeText("Established delivery builder")
            let establishedDeliveryEncode = app.buttons["RUNE SCRIBE"]
            XCTAssertTrue(
                establishedDeliveryEncode.waitForExistence(timeout: 5),
                app.debugDescription
            )
            establishedDeliveryEncode.tap()

            let establishedDeliveryShare = app.buttons["message.customize-share"]
            XCTAssertTrue(
                establishedDeliveryShare.waitForExistence(timeout: 12),
                app.debugDescription
            )
            scrollUntilVisible(establishedDeliveryShare, in: app, direction: .towardBottom)
            XCTAssertTrue(establishedDeliveryShare.isHittable, app.debugDescription)
            establishedDeliveryShare.tap()
            try assertShareBuilder(
                in: app,
                securityIdentifier: "share-builder.security.established",
                expectedNotice: "Uses your shared key — this message does not resend the cipher.",
                screenshotName: "iphone-share-builder-established",
                validatesAdaptiveRotation: false
            )
            tapCloseControl(in: app)

            let clearEstablishedDelivery = app.buttons["Clear"]
            XCTAssertTrue(
                clearEstablishedDelivery.waitForExistence(timeout: 8),
                app.debugDescription
            )
            scrollUntilVisible(clearEstablishedDelivery, in: app, direction: .towardBottom)
            XCTAssertTrue(clearEstablishedDelivery.isHittable, app.debugDescription)
            clearEstablishedDelivery.tap()
        }

        openCipherLibrary(in: app)
        XCTAssertTrue(app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 8))
        let relinkedContactMenu = app.buttons[
            "Contact for Parity Cipher Renamed: Parity Contact Edited"
        ]
        XCTAssertTrue(relinkedContactMenu.waitForExistence(timeout: 8), app.debugDescription)
        relinkedContactMenu.tap()
        app.buttons["No contact"].tap()
        XCTAssertTrue(contactMenu.waitForExistence(timeout: 8))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 5))

        chooseCipherAction("Delete", for: "Parity Cipher Renamed", in: app)
        let deleteCipher = app.alerts["Delete “Parity Cipher Renamed”?"]
        XCTAssertTrue(deleteCipher.waitForExistence(timeout: 5))
        deleteCipher.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Parity Cipher Renamed"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["1 cipher"].waitForExistence(timeout: 8))

        tapCloseControl(in: app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["SETTINGS"].waitForExistence(timeout: 5))
        let reopenedManageContacts = app.buttons["Manage Contacts"]
        scrollUntilVisible(reopenedManageContacts, in: app)
        XCTAssertTrue(reopenedManageContacts.isHittable, app.debugDescription)
        reopenedManageContacts.tap()
        XCTAssertTrue(app.staticTexts["Parity Contact Edited"].waitForExistence(timeout: 5))
        app.buttons["Delete Parity Contact Edited"].tap()
        let deleteContact = app.alerts["Delete “Parity Contact Edited”?"]
        XCTAssertTrue(deleteContact.waitForExistence(timeout: 5))
        deleteContact.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["No contacts yet"].waitForExistence(timeout: 8))

        tapCloseControl(in: app)
        tapCloseControl(in: app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))

        app.open(Self.malformedImportURL)
        dismissSplashIfPresent(in: app)
        let importFailure = app.alerts["Import Failed"]
        XCTAssertTrue(importFailure.waitForExistence(timeout: 8), app.debugDescription)
        importFailure.buttons["OK"].tap()

        app.open(Self.legacyImportURL)
        dismissSplashIfPresent(in: app)
        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Baseline Legacy")
        try auditAccessibility(in: app)
        app.buttons["Import"].tap()
        XCTAssertTrue(app.buttons["Active cipher: Baseline Legacy"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["SHARED CIPHER"].waitForNonExistence(timeout: 8),
            app.debugDescription
        )

        let cipherFile = try makeCipherFixtureFile()
        app.open(cipherFile)
        dismissSplashIfPresent(in: app)
        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Imported Cipher")
        app.buttons["Import"].tap()
        XCTAssertTrue(app.buttons["Active cipher: Imported Cipher"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["SHARED CIPHER"].waitForNonExistence(timeout: 8),
            app.debugDescription
        )

        let customFontFile = try makeCustomFontFixtureFile(validFontBytes: true)
        app.open(customFontFile)
        dismissSplashIfPresent(in: app)
        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Imported Cipher")
        app.buttons["Import"].tap()
        XCTAssertTrue(app.buttons["Active cipher: Imported Cipher"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["SHARED CIPHER"].waitForNonExistence(timeout: 8),
            app.debugDescription
        )
        openCipherLibrary(in: app)
        XCTAssertTrue(app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["4 ciphers"].waitForExistence(timeout: 8), app.debugDescription)
        tapCloseControl(in: app)

        let invalidFontFile = try makeCustomFontFixtureFile(validFontBytes: false)
        app.open(invalidFontFile)
        dismissSplashIfPresent(in: app)
        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Imported Cipher")
        app.buttons["Import"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(identifier: "import-confirmation-error")
                .firstMatch.waitForExistence(timeout: 8),
            app.debugDescription
        )
        app.buttons.matching(identifier: "xmark").firstMatch.tap()
        let terminalImportAlert = app.alerts["Couldn't Complete"]
        if terminalImportAlert.waitForExistence(timeout: 3) {
            XCTAssertTrue(
                terminalImportAlert.staticTexts[
                    "This Rune Scribe item is damaged or incomplete."
                ].exists,
                app.debugDescription
            )
            let dismissTerminalImportAlert = terminalImportAlert.buttons["OK"]
            XCTAssertTrue(dismissTerminalImportAlert.isHittable, app.debugDescription)
            dismissTerminalImportAlert.tap()
            XCTAssertTrue(
                terminalImportAlert.waitForNonExistence(timeout: 5),
                app.debugDescription
            )
        }
        XCTAssertTrue(app.buttons["Active cipher: Imported Cipher"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["SHARED CIPHER"].waitForNonExistence(timeout: 8),
            app.debugDescription
        )
        openCipherLibrary(in: app)
        XCTAssertTrue(app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["4 ciphers"].waitForExistence(timeout: 8), app.debugDescription)
        tapCloseControl(in: app)

        let messageFile = try makeMessageFixtureFile()
        app.open(messageFile)
        dismissSplashIfPresent(in: app)
        XCTAssertTrue(app.staticTexts["DECODED MESSAGE"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["LOCALLY STORED CIPHER"].exists)
        XCTAssertTrue(app.staticTexts["Imported Cipher"].exists)
        XCTAssertFalse(app.staticTexts["Parity Sender"].exists)
        XCTAssertTrue(app.staticTexts["Parity reply message"].exists)
        try auditAccessibility(in: app)
        app.buttons["Reply"].tap()
        XCTAssertTrue(app.buttons["RUNE SCRIBE"].waitForExistence(timeout: 8))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "fresh-install-primary-flows"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOptionalProviderMaintainsSettingsAndVaultRootBackgroundContinuity()
        throws
    {
        let app = makeIsolatedApplication()
        app.launchEnvironment["RUNESCRIBE_QUALIFICATION_UNLOCK_CODEX"] = "moonleaf"
        app.launch()

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        if app.windows.firstMatch.frame.width >= 700 {
            throw XCTSkip("Optional-provider root-background continuity is qualified on iPhone.")
        }

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["SETTINGS"].waitForExistence(timeout: 8))

        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let codexCard = app.descendants(matching: .any)[
            "theme.codex-card.\(descriptor.codex.id.rawValue)"
        ].firstMatch
        XCTAssertTrue(codexCard.waitForExistence(timeout: 15), app.debugDescription)
        scrollUntilVisible(codexCard, in: app)
        if codexCard.value as? String != "Selected" {
            XCTAssertTrue(codexCard.isEnabled, app.debugDescription)
            XCTAssertTrue(codexCard.isHittable, app.debugDescription)
            codexCard.tap()
        }
        let selectedMoonleaf = NSPredicate(format: "value == %@", "Selected")
        let selectionExpectation = expectation(
            for: selectedMoonleaf,
            evaluatedWith: codexCard
        )
        wait(for: [selectionExpectation], timeout: 15)

        let presentation = app.descendants(matching: .any)[
            "theme.presentation.\(descriptor.id.rawValue).standard"
        ].firstMatch
        XCTAssertTrue(presentation.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(presentation.value as? String, "Standard")
        XCTAssertFalse(
            app.staticTexts[
                "Your preferred Codex is unavailable. The Base appearance is active."
            ].exists
        )

        let rootBackgroundIdentifier =
            "theme.root-background.\(descriptor.id.rawValue).standard"
        let rootBackground = app.descendants(matching: .any)[
            rootBackgroundIdentifier
        ].firstMatch
        XCTAssertTrue(rootBackground.waitForExistence(timeout: 12), app.debugDescription)
        keepScreenshot(app, named: "iphone-settings-moonleaf")

        tapCloseControl(in: app)
        XCTAssertTrue(rootBackground.waitForExistence(timeout: 8), app.debugDescription)
        let moonleafRelic = app.descendants(matching: .any)[
            "theme.artifact-thumbnail.relic.moonleaf.tablet"
        ].firstMatch
        XCTAssertTrue(moonleafRelic.waitForExistence(timeout: 12), app.debugDescription)
        keepScreenshot(app, named: "iphone-workspace-moonleaf")

        let vaultAndProgress = app.buttons["Vault and Progress"]
        XCTAssertTrue(vaultAndProgress.waitForExistence(timeout: 8), app.debugDescription)
        vaultAndProgress.tap()
        XCTAssertTrue(app.staticTexts["VAULT & PROGRESS"].waitForExistence(timeout: 8))
        selectVaultProgressVaultSection(in: app)
        XCTAssertTrue(app.staticTexts["Active Codex Collection"].waitForExistence(timeout: 8))

        let vaultCodex = app.descendants(matching: .any)[
            "theme.vault.\(descriptor.codex.id.rawValue)"
        ].firstMatch
        XCTAssertTrue(vaultCodex.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(vaultCodex.value as? String, "Selected")
        XCTAssertTrue(app.staticTexts["Provider available"].exists)
        XCTAssertTrue(rootBackground.exists, app.debugDescription)
        keepScreenshot(app, named: "iphone-vault-moonleaf")
    }

    func testAccessibility5HighContrastReducedMotionKeepsLayoutAndRenderedOutputUsable()
        throws
    {
        let app = makeIsolatedApplication()
        app.launchEnvironment["RUNESCRIBE_QUALIFICATION_ACCESSIBILITY"] =
            "accessibility5-high-contrast-reduced-motion"
        app.launch()

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        if window.frame.width >= 700 {
            throw XCTSkip("Accessibility-size and contrast layout qualification is on iPhone.")
        }

        let highContrastRoot = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "theme.root-background.",
                ".high-contrast"
            )
        ).firstMatch
        XCTAssertTrue(highContrastRoot.waitForExistence(timeout: 15), app.debugDescription)

        let editor = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        let encodeButton = app.buttons["RUNE SCRIBE"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(encodeButton.waitForExistence(timeout: 8), app.debugDescription)
        assertUsableHitRegion(editor)
        assertUsableHitRegion(encodeButton)
        XCTAssertLessThanOrEqual(
            editor.frame.maxY,
            encodeButton.frame.minY + 1,
            "Accessibility-size editor and Encode action overlap."
        )

        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 8), app.debugDescription)
        assertUsableHitRegion(settingsButton)
        assertHorizontallyContained(settingsButton, in: window.frame)
        XCTAssertGreaterThanOrEqual(settingsButton.frame.minY, window.frame.minY - 1)
        XCTAssertLessThanOrEqual(settingsButton.frame.maxY, window.frame.maxY + 1)
        XCTAssertTrue(settingsButton.isHittable, app.debugDescription)
        settingsButton.tap()
        XCTAssertTrue(app.staticTexts["SETTINGS"].waitForExistence(timeout: 8))
        let highContrastPresentation = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "theme.presentation.",
                ".high-contrast"
            )
        ).firstMatch
        XCTAssertTrue(
            highContrastPresentation.waitForExistence(timeout: 15),
            app.debugDescription
        )
        XCTAssertEqual(highContrastPresentation.value as? String, "High Contrast")

        let effects = app.descendants(matching: .any)["appearance.effects"].firstMatch
        scrollUntilVisible(effects, in: app)
        XCTAssertTrue(effects.waitForExistence(timeout: 8), app.debugDescription)
        let fullEffects = effects.buttons["Full"].firstMatch
        XCTAssertTrue(fullEffects.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(fullEffects.isHittable, app.debugDescription)
        fullEffects.tap()
        XCTAssertTrue(
            app.staticTexts[
                "Full is saved; Reduce Motion limits effective behavior to Reduced."
            ].waitForExistence(timeout: 8),
            app.debugDescription
        )

        let defaultsPreview = app.descendants(matching: .any)[
            "theme.artifact-preview.relic.norse.runestone-tablet"
        ].firstMatch
        scrollUntilVisible(defaultsPreview, in: app)
        XCTAssertTrue(defaultsPreview.waitForExistence(timeout: 8), app.debugDescription)
        assertUsableHitRegion(defaultsPreview)
        try auditAccessibility(in: app)
        keepScreenshot(app, named: "iphone-accessibility5-high-contrast-settings")
        tapCloseControl(in: app)

        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        editor.tap()
        editor.typeText("Accessible high contrast share")
        let workspaceDone = app.buttons["workspace.keyboard.done"]
        XCTAssertTrue(workspaceDone.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(workspaceDone.isHittable, app.debugDescription)
        workspaceDone.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
            app.debugDescription
        )
        scrollUntilVisible(encodeButton, in: app)
        XCTAssertTrue(encodeButton.isHittable, app.debugDescription)
        encodeButton.tap()

        let unlockDismiss = app.buttons["Dismiss"]
        if unlockDismiss.waitForExistence(timeout: 2) {
            XCTAssertTrue(
                unlockDismiss.waitForNonExistence(timeout: 8),
                "The reduced-motion unlock reveal did not complete automatically.\n\(app.debugDescription)"
            )
        }

        let workspacePreview = app.descendants(matching: .any)[
            "theme.artifact-preview.relic.norse.runestone-tablet"
        ].firstMatch
        XCTAssertTrue(workspacePreview.waitForExistence(timeout: 8), app.debugDescription)
        let workspacePreviewScrollFrame = try XCTUnwrap(
            scrollUntilContained(workspacePreview, in: app)
        )
        assertFourByThree(workspacePreview)
        assertHorizontallyContained(workspacePreview, in: window.frame)
        XCTAssertGreaterThanOrEqual(
            workspacePreview.frame.minY,
            workspacePreviewScrollFrame.minY - 1
        )
        XCTAssertLessThanOrEqual(
            workspacePreview.frame.maxY,
            workspacePreviewScrollFrame.maxY + 1
        )

        let customizeShare = app.buttons["message.customize-share"]
        XCTAssertTrue(customizeShare.waitForExistence(timeout: 12), app.debugDescription)
        scrollUntilVisible(customizeShare, in: app)
        XCTAssertTrue(customizeShare.isHittable, app.debugDescription)
        customizeShare.tap()

        let builder = app.descendants(matching: .any)["share-builder"].firstMatch
        XCTAssertTrue(builder.waitForExistence(timeout: 12), app.debugDescription)
        let preview = app.descendants(matching: .any)["share-builder.preview"].firstMatch
        scrollUntilVisible(preview, in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 8), app.debugDescription)
        let verifiedOutput = NSPredicate(
            format: "value CONTAINS %@ AND value CONTAINS %@",
            "High contrast output verified",
            "Reduced motion"
        )
        let previewExpectation = expectation(for: verifiedOutput, evaluatedWith: preview)
        wait(for: [previewExpectation], timeout: 15)
        assertFourByThree(preview)

        let reducedMotionDetail = app.staticTexts[
            "Full is saved; Reduce Motion limits the effective preview to Reduced. "
                + "No additional effect is supplied by this Codex."
        ]
        scrollUntilVisible(reducedMotionDetail, in: app, direction: .towardTop)
        XCTAssertTrue(
            reducedMotionDetail.waitForExistence(timeout: 8),
            app.debugDescription
        )
        try auditAccessibility(in: app)
        keepScreenshot(app, named: "iphone-accessibility5-high-contrast-share-builder")
    }

    func testAccessibility5WorkspacePreviewFitsIPadViewport() throws {
        let app = makeIsolatedApplication()
        app.launchEnvironment["RUNESCRIBE_QUALIFICATION_ACCESSIBILITY"] =
            "accessibility5-high-contrast-reduced-motion"
        app.launch()

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), app.debugDescription)
        guard window.frame.width >= 700 else {
            throw XCTSkip("The iPad accessibility workspace is qualified on iPad.")
        }

        let editor = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        let encodeButton = app.buttons["RUNE SCRIBE"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(encodeButton.waitForExistence(timeout: 8), app.debugDescription)
        editor.tap()
        editor.typeText("Accessible iPad preview")

        let workspaceDone = app.buttons["workspace.keyboard.done"]
        XCTAssertTrue(workspaceDone.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(workspaceDone.isHittable, app.debugDescription)
        workspaceDone.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
            app.debugDescription
        )

        scrollUntilVisible(encodeButton, in: app)
        XCTAssertTrue(encodeButton.isHittable, app.debugDescription)
        encodeButton.tap()

        let unlockDismiss = app.buttons["Dismiss"]
        if unlockDismiss.waitForExistence(timeout: 2), unlockDismiss.isHittable {
            unlockDismiss.tap()
        }

        let preview = app.descendants(matching: .any)[
            "theme.artifact-preview.relic.norse.runestone-tablet"
        ].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 12), app.debugDescription)
        let scrollFrame = try XCTUnwrap(scrollUntilContained(preview, in: app))
        assertFourByThree(preview)
        assertHorizontallyContained(preview, in: window.frame)
        XCTAssertGreaterThanOrEqual(preview.frame.minY, scrollFrame.minY - 1)
        XCTAssertLessThanOrEqual(preview.frame.maxY, scrollFrame.maxY + 1)
        keepScreenshot(app, named: "ipad-accessibility5-workspace-preview")
    }

    private func makeIsolatedApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RUNESCRIBE_ISOLATED_NORMAL_ROUTE"] = "1"
        app.launchEnvironment["RUNESCRIBE_ISOLATED_NORMAL_ROUTE_ID"] = UUID().uuidString
        return app
    }

    private func assertShareBuilder(
        in app: XCUIApplication,
        securityIdentifier: String,
        expectedNotice: String,
        screenshotName: String,
        validatesAdaptiveRotation: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let builder = app.descendants(matching: .any)["share-builder"].firstMatch
        XCTAssertTrue(
            builder.waitForExistence(timeout: 12),
            app.debugDescription,
            file: file,
            line: line
        )
        XCTAssertTrue(
            app.staticTexts["1. CODEX"].waitForExistence(timeout: 12),
            app.debugDescription,
            file: file,
            line: line
        )
        XCTAssertTrue(app.staticTexts["2–3. ARTIFACT"].exists, file: file, line: line)
        XCTAssertTrue(app.staticTexts["4. EXTRAS"].exists, file: file, line: line)
        XCTAssertTrue(app.staticTexts["5. LIVE PREVIEW"].exists, file: file, line: line)
        XCTAssertTrue(app.staticTexts["6. SECURITY SUMMARY"].exists, file: file, line: line)

        let codex = app.descendants(matching: .any)[
            "theme.codex-card.codex.norse"
        ].firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(codex.value as? String, "Selected", file: file, line: line)

        let relic = app.buttons["share-builder.relic"].firstMatch
        let seal = app.buttons["share-builder.seal"].firstMatch
        let frame = app.buttons["share-builder.frame"].firstMatch
        let effects = app.descendants(matching: .any)[
            "share-builder.effects"
        ].firstMatch
        XCTAssertTrue(relic.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(seal.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(frame.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(effects.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(relic.label, "Relic: Runestone Tablet", file: file, line: line)
        XCTAssertEqual(seal.label, "Seal: Valknut Seal", file: file, line: line)
        XCTAssertEqual(frame.label, "Frame: None", file: file, line: line)
        XCTAssertEqual(
            relic.value as? String,
            "Selected, Owned, available",
            file: file,
            line: line
        )
        XCTAssertEqual(
            seal.value as? String,
            "Selected, Owned, available",
            file: file,
            line: line
        )
        XCTAssertEqual(frame.value as? String, "Selected, available", file: file, line: line)
        XCTAssertEqual(
            effects.value as? String,
            "Full, selected, available",
            file: file,
            line: line
        )

        let preview = app.descendants(matching: .any)[
            "share-builder.preview"
        ].firstMatch
        scrollUntilVisible(preview, in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(
            preview.label,
            "Four by three preview of the current share appearance",
            file: file,
            line: line
        )
        assertFourByThree(preview, file: file, line: line)

        let security = app.descendants(matching: .any)[securityIdentifier].firstMatch
        scrollUntilVisible(security, in: app)
        XCTAssertTrue(security.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(security.label, "Security summary", file: file, line: line)
        XCTAssertEqual(security.value as? String, expectedNotice, file: file, line: line)
        XCTAssertGreaterThan(security.frame.minY, preview.frame.minY, file: file, line: line)

        let reset = app.buttons.matching(
            identifier: "share-builder.reset-defaults"
        ).firstMatch
        let save = app.buttons.matching(
            identifier: "share-builder.save-defaults"
        ).firstMatch
        let share = app.buttons.matching(identifier: "share-builder.share").firstMatch
        scrollUntilVisible(share, in: app)
        XCTAssertTrue(reset.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(share.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(reset.isEnabled, file: file, line: line)
        XCTAssertFalse(save.isEnabled, file: file, line: line)
        XCTAssertTrue(share.isEnabled, file: file, line: line)
        XCTAssertTrue(share.isHittable, app.debugDescription, file: file, line: line)

        scrollUntilVisible(seal, in: app, direction: .towardTop)
        XCTAssertTrue(seal.isHittable, app.debugDescription)
        seal.tap()
        let noneButton = try XCTUnwrap(
            waitForHittableButton(named: "None", in: app),
            "The optional Seal menu did not expose None.",
            file: file,
            line: line
        )
        noneButton.tap()

        let noSeal = app.buttons["share-builder.seal"].firstMatch
        XCTAssertTrue(noSeal.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(noSeal.label, "Seal: None", file: file, line: line)
        XCTAssertEqual(
            noSeal.value as? String,
            "Selected, available",
            file: file,
            line: line
        )
        scrollUntilVisible(reset, in: app)
        XCTAssertTrue(reset.isEnabled, file: file, line: line)
        XCTAssertTrue(save.isEnabled, file: file, line: line)
        XCTAssertTrue(reset.isHittable, app.debugDescription, file: file, line: line)
        reset.tap()
        XCTAssertTrue(
            app.buttons["share-builder.seal"].firstMatch.waitForExistence(timeout: 8),
            app.debugDescription
        )
        XCTAssertFalse(reset.isEnabled, file: file, line: line)
        XCTAssertFalse(save.isEnabled, file: file, line: line)

        scrollUntilVisible(preview, in: app, direction: .towardTop)
        assertFourByThree(preview, file: file, line: line)
        try auditAccessibility(in: app)
        keepScreenshot(app, named: screenshotName)

        let window = app.windows.firstMatch
        XCTAssertGreaterThan(builder.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(builder.frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(builder.frame.minX, window.frame.minX - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(builder.frame.maxX, window.frame.maxX + 1, file: file, line: line)

        guard validatesAdaptiveRotation else { return }
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(builder.waitForExistence(timeout: 8), app.debugDescription)
        let rotatedWindow = app.windows.firstMatch
        waitForWindowRotation(rotatedWindow, landscape: true)
        XCTAssertGreaterThan(rotatedWindow.frame.width, rotatedWindow.frame.height)
        XCTAssertGreaterThanOrEqual(
            builder.frame.minX,
            rotatedWindow.frame.minX - 1,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            builder.frame.maxX,
            rotatedWindow.frame.maxX + 1,
            file: file,
            line: line
        )
        scrollUntilVisible(preview, in: app, direction: .towardTop)
        assertFourByThree(preview, file: file, line: line)
        keepScreenshot(app, named: "\(screenshotName)-landscape")
        XCUIDevice.shared.orientation = .portrait
        let restoredWindow = app.windows.firstMatch
        waitForWindowRotation(restoredWindow, landscape: false)
        XCTAssertGreaterThan(
            restoredWindow.frame.height,
            restoredWindow.frame.width,
            file: file,
            line: line
        )
    }

    private func waitForWindowRotation(
        _ window: XCUIElement,
        landscape: Bool,
        timeout: TimeInterval = 8
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = window.frame
            if landscape ? frame.width > frame.height : frame.height > frame.width {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func assertFourByThree(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = element.frame
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertEqual(
            frame.width / frame.height,
            4.0 / 3.0,
            accuracy: 0.08,
            file: file,
            line: line
        )
    }

    private func assertUsableHitRegion(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, file: file, line: line)
    }

    private func assertHorizontallyContained(
        _ element: XCUIElement,
        in bounds: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(element.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(element.frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            element.frame.minX,
            bounds.minX - 1,
            "Workspace element extends beyond the leading window edge: \(element)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            element.frame.maxX,
            bounds.maxX + 1,
            "Workspace element extends beyond the trailing window edge: \(element)",
            file: file,
            line: line
        )
    }

    private func waitForHittableButton(
        named label: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let button = app.buttons.matching(
                NSPredicate(format: "label == %@", label)
            ).allElementsBoundByIndex.first(where: \.isHittable) {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return nil
    }

    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        for digit in pin {
            let button = app.buttons[String(digit)]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
        }
    }

    private func keepScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapCloseControl(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let popUpButtons = app.popUpButtons.matching(identifier: "Close")
            .allElementsBoundByIndex
        if let popUpButton = popUpButtons.reversed().first(where: { $0.isHittable }) {
            popUpButton.tap()
            return
        }

        let buttons = app.buttons.matching(identifier: "Close").allElementsBoundByIndex
        if let button = buttons.reversed().first(where: { $0.isHittable }) {
            button.tap()
            return
        }

        XCTFail("No hittable Close control", file: file, line: line)
    }

    private func selectVaultProgressVaultSection(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let picker = app.scrollViews["vault-progress.section-picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8),
            app.debugDescription,
            file: file,
            line: line
        )

        let vault = app.buttons["vault-progress.section.vault"]
        XCTAssertTrue(vault.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        for _ in 0..<4 {
            let pickerFrame = picker.frame
            let vaultFrame = vault.frame
            if vaultFrame.width > 0,
               vaultFrame.height > 0,
               vaultFrame.minX >= pickerFrame.minX - 1,
               vaultFrame.maxX <= pickerFrame.maxX + 1 {
                break
            }
            picker.swipeLeft(velocity: .slow)
        }
        XCTAssertGreaterThanOrEqual(
            vault.frame.minX,
            picker.frame.minX - 1,
            app.debugDescription,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            vault.frame.maxX,
            picker.frame.maxX + 1,
            app.debugDescription,
            file: file,
            line: line
        )
        vault.tap()

        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Selected"),
            object: vault
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selected], timeout: 5),
            .completed,
            app.debugDescription,
            file: file,
            line: line
        )
    }

    private func openCipherLibrary(
        in app: XCUIApplication,
        dismissContactsPrompt: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let headerButton = waitForHittableButton(
            named: "Manage your cipher library",
            in: app,
            timeout: 2
        ) {
            headerButton.tap()
        } else {
            let activeCipherButtons = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Active cipher:")
            )
            let deadline = Date().addingTimeInterval(5)
            var activeCipherButton: XCUIElement?
            repeat {
                activeCipherButton = activeCipherButtons.allElementsBoundByIndex
                    .first(where: \.isHittable)
                if activeCipherButton == nil {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            } while activeCipherButton == nil && Date() < deadline

            guard let activeCipherButton else {
                XCTFail(
                    "Neither cipher-library navigation route is hittable",
                    file: file,
                    line: line
                )
                return
            }
            activeCipherButton.tap()
            guard let menuButton = waitForHittableButton(
                named: "Manage Ciphers…",
                in: app,
                timeout: 5
            ) else {
                XCTFail("The active-cipher menu did not expose Manage Ciphers", file: file, line: line)
                return
            }
            menuButton.tap()
        }

        XCTAssertTrue(
            app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 8),
            app.debugDescription,
            file: file,
            line: line
        )
        if dismissContactsPrompt {
            dismissContactsPromptIfPresent(in: app)
        }
    }

    private func dismissContactsPromptIfPresent(in app: XCUIApplication) {
        let skip = app.buttons["Skip"]
        guard skip.waitForExistence(timeout: 3) else { return }
        XCTAssertTrue(skip.isHittable, app.debugDescription)
        skip.tap()
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    private func chooseCipherAction(
        _ action: String,
        for cipherLabel: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let moreActions = app.buttons["More actions for \(cipherLabel)"]
        XCTAssertTrue(
            moreActions.waitForExistence(timeout: 8),
            app.debugDescription,
            file: file,
            line: line
        )
        scrollUntilVisible(moreActions, in: app)
        XCTAssertTrue(moreActions.isHittable, app.debugDescription, file: file, line: line)
        moreActions.tap()

        guard let actionButton = waitForHittableButton(named: action, in: app, timeout: 5) else {
            XCTFail(
                "The More actions menu did not expose \(action) for \(cipherLabel)",
                file: file,
                line: line
            )
            return
        }
        actionButton.tap()
    }

    private enum ScrollDirection {
        case towardTop
        case towardBottom
    }

    private func scrollUntilVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        direction: ScrollDirection = .towardBottom
    ) {
        if element.exists, element.isHittable { return }

        guard let scrollSurface = app.scrollViews.allElementsBoundByIndex
            .filter({ $0.isHittable })
            .max(by: { $0.frame.height < $1.frame.height })
        else { return }

        for _ in 0..<12 where !element.exists || !element.isHittable {
            if element.exists {
                if element.frame.maxY > scrollSurface.frame.maxY {
                    scrollSurface.swipeUp(velocity: .slow)
                    continue
                }
                if element.frame.minY < scrollSurface.frame.minY {
                    scrollSurface.swipeDown(velocity: .slow)
                    continue
                }
            }

            switch direction {
            case .towardTop:
                scrollSurface.swipeDown(velocity: .slow)
            case .towardBottom:
                scrollSurface.swipeUp(velocity: .slow)
            }
        }
    }

    private func scrollUntilContained(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> CGRect? {
        guard element.exists, !element.identifier.isEmpty else { return nil }
        let containingScrollViews = app.scrollViews.allElementsBoundByIndex.filter {
            $0.exists
                && $0.descendants(matching: .any)
                    .matching(identifier: element.identifier).count == 1
        }
        guard let scrollSurface = containingScrollViews.max(by: {
            $0.frame.height < $1.frame.height
        }) else { return nil }

        let permittedFrame = scrollSurface.frame.insetBy(dx: -1, dy: -1)
        for _ in 0..<12 {
            let elementFrame = element.frame
            if permittedFrame.contains(elementFrame) {
                return scrollSurface.frame
            }
            if elementFrame.minY < permittedFrame.minY {
                scrollSurface.swipeDown(velocity: .slow)
            } else if elementFrame.maxY > permittedFrame.maxY {
                scrollSurface.swipeUp(velocity: .slow)
            } else {
                return scrollSurface.frame
            }
        }
        return scrollSurface.frame
    }

    private func auditAccessibility(in app: XCUIApplication) throws {
        try app.performAccessibilityAudit(
            for: [.sufficientElementDescription, .hitRegion, .trait, .textClipped]
        )
    }

    private func dismissSplashIfPresent(in app: XCUIApplication) {
        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }
        let guide = app.staticTexts["How Rune Scribe Works"]
        if guide.waitForExistence(timeout: 5) {
            let skip = app.buttons["Skip"]
            XCTAssertTrue(skip.isHittable, app.debugDescription)
            skip.tap()
            XCTAssertTrue(guide.waitForNonExistence(timeout: 5), app.debugDescription)
        }
    }

    private func dismissSystemShareSheet(
        in app: XCUIApplication,
        activityList: XCUIElement
    ) {
        let sharingService = XCUIApplication(
            bundleIdentifier: "com.apple.SharingUIService"
        )
        let serviceCopy = sharingService.buttons["Copy"].firstMatch
        let activityCopy = activityList.buttons["Copy"].firstMatch
        let systemClose = sharingService.buttons["header.closeButton"].firstMatch
        let caseInsensitiveClose = sharingService.buttons.matching(
            NSPredicate(format: "label ==[c] %@", "close")
        ).firstMatch
        let popUpClose = sharingService.popUpButtons["Close"].firstMatch
        let cancel = activityList.buttons["Cancel"]
        let close = activityList.buttons["Close"]
        let done = activityList.buttons["Done"]
        if serviceCopy.exists {
            serviceCopy.tap()
            return
        } else if activityCopy.exists {
            activityCopy.tap()
            return
        } else if activityList.frame.width < 700 {
            activityList.coordinate(
                withNormalizedOffset: CGVector(dx: 0.17, dy: 0.83)
            ).tap()
            if activityList.waitForNonExistence(timeout: 5) {
                return
            }
        }

        if systemClose.exists {
            systemClose.tap()
        } else if popUpClose.exists {
            popUpClose.tap()
        } else if caseInsensitiveClose.exists {
            caseInsensitiveClose.tap()
        } else if cancel.exists {
            cancel.tap()
        } else if close.exists {
            close.tap()
        } else if done.exists {
            done.tap()
        } else if app.otherElements["PopoverDismissRegion"].firstMatch.exists {
            app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        } else if app.sheets.containing(
            .other,
            identifier: "ActivityListView"
        ).firstMatch.exists {
            let shareSheet = app.sheets.containing(
                .other,
                identifier: "ActivityListView"
            ).firstMatch
            shareSheet.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)
            ).press(
                forDuration: 0.1,
                thenDragTo: shareSheet.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)
                )
            )
        } else {
            activityList.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)
            ).press(
                forDuration: 0.1,
                thenDragTo: activityList.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)
                )
            )
        }
    }

    private func replaceText(in field: XCUIElement, with replacement: String) {
        let existingCharacterCount = (field.value as? String)?.count ?? 0
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if existingCharacterCount > 0 {
            field.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingCharacterCount)
            )
        }
        field.typeText(replacement)
    }

    private func appendTextAtEnd(
        in field: XCUIElement,
        suffix: String,
        expectedValue: String
    ) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(suffix)
        XCTAssertEqual(field.value as? String, expectedValue)
    }

    private func makeMessageFixtureFile() throws -> URL {
        let data = try XCTUnwrap(Data(base64Encoded: Self.messageFixtureBase64))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-message")
            .appendingPathExtension("runescribe")
        try data.write(to: fileURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        return fileURL
    }

    private func makeCipherFixtureFile() throws -> URL {
        let data = try XCTUnwrap(Self.decodeBase64URL(Self.cipherToken))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-cipher")
            .appendingPathExtension("runescribe")
        try data.write(to: fileURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        return fileURL
    }

    private func makeCustomFontFixtureFile(validFontBytes: Bool) throws -> URL {
        let fontURL = try XCTUnwrap(
            RuneScribeNorseThemeModuleBootstrap.resourceBundle
                .url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
        )
        let fontBytes = try Data(contentsOf: fontURL)
        var payload = try XCTUnwrap(Self.decodeBase64URL(Self.cipherToken))
        XCTAssertEqual(payload.count, 129)
        payload.replaceSubrange(
            1..<9,
            with: Data([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7])
        )
        var customID = Data("custom-runes".utf8)
        customID.append(Data(repeating: 0, count: 16 - customID.count))
        payload.replaceSubrange(73..<89, with: customID)
        payload.replaceSubrange(89..<93, with: Data([0, 0, 0, 1]))
        payload.replaceSubrange(93..<125, with: Data(SHA256.hash(data: fontBytes)))
        payload.replaceSubrange(
            125..<129,
            with: Data(SHA256.hash(data: payload.prefix(125)).prefix(4))
        )
        payload.append(validFontBytes ? fontBytes : Data("invalid-font".utf8))

        let basename = validFontBytes ? "parity-custom-font" : "parity-invalid-font"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(basename)
            .appendingPathExtension("runescribe")
        try payload.write(to: fileURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        return fileURL
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static let customImportURL = URL(
        string: "runescribe://import?v=3&p="
            + cipherToken
            + "&n=Baseline%20Custom"
    )!

    private static let legacyImportURL = URL(
        string: "https://www.ravenforgesoftware.com/rune-scribe/import?v=3&p="
            + legacyCipherToken
            + "&n=Baseline%20Legacy"
    )!

    private static let malformedImportURL = URL(
        string: "runescribe://import?v=3&p=bad&n=Malformed"
    )!

    private static let cipherToken =
        "AwABAgMEBQYHEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8f"
        + "Hh0cGxoZGBcWFRQTEhEQDw4NDAsKCQgHBgUEAwIBAG5vdG8tc2Fucy1y"
        + "dW5pYwAAAAABYVtsEWaoxRgW3BU2eErL9IZUfjvtA9v91wkQ4QBmeTsMHGhN"

    private static let legacyCipherToken =
        "AzAxMjM0NTY3QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8fHh0c"
        + "GxoZGBcWFRQTEhEQDw4NDAsKCQgHBgUEAwIBAG5vdG8tc2Fucy1ydW5pYwAA"
        + "AAABYVtsEWaoxRgW3BU2eErL9IZUfjvtA9v91wkQ4QBmeTtJJeEj"

    private static let messageFixtureBase64 =
        "AQENUGFyaXR5IFNlbmRlcgAxAQABAgMEBQYHCAkKC4rdH81Aghvz+aCot80+"
        + "leMkcZX+n/pirKycXb4K0iODmYRkywMAAQIDBAUGBxAREhMUFRYXGBkaGxwd"
        + "Hh8gISIjJCUmJygpKissLS4vHx4dHBsaGRgXFhUUExIREA8ODQwLCgkIBwYF"
        + "BAMCAQBub3RvLXNhbnMtcnVuaWMAAAAAAWFbbBFmqMUYFtwVNnhKy/SGVH47"
        + "7QPb/dcJEOEAZnk7DBxoTa7N8lY="
}
