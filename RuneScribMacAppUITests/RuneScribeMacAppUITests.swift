import XCTest

@MainActor
final class RuneScribeMacAppUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    func testShippingAppNormalRouteSupportsLongArtifactPaging() {
        let app = XCUIApplication()
        app.launchEnvironment["RUNESCRIBE_ISOLATED_NORMAL_ROUTE"] = "1"
        app.launch()

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.click()
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertGreaterThanOrEqual(window.frame.width, 560)
        XCTAssertGreaterThanOrEqual(window.frame.height, 640)

        let relicThumbnail = app.descendants(matching: .any)[
            "theme.artifact-thumbnail.relic.norse.runestone-tablet"
        ].firstMatch
        XCTAssertTrue(relicThumbnail.waitForExistence(timeout: 15), app.debugDescription)

        let editor = app.textViews.matching(
            NSPredicate(format: "label == %@", "Message to encode")
        ).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(editor.isHittable, app.debugDescription)
        editor.click()
        editor.typeText(String(repeating: "A", count: 300))

        let encode = app.buttons["RUNE SCRIBE"]
        XCTAssertTrue(encode.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(encode.isHittable, app.debugDescription)
        encode.click()

        let preview = app.descendants(matching: .any)["theme.artifact-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15), app.debugDescription)
        let firstPage = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Page 1 of ")
        ).firstMatch
        XCTAssertTrue(firstPage.waitForExistence(timeout: 8), app.debugDescription)

        let nextPage = app.buttons["theme.artifact-preview.next-page"]
        let previousPage = app.buttons["theme.artifact-preview.previous-page"]
        XCTAssertTrue(nextPage.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(previousPage.waitForExistence(timeout: 5), app.debugDescription)
        assertMacControlSize(nextPage)
        assertMacControlSize(previousPage)
        XCTAssertFalse(previousPage.isEnabled)

        nextPage.click()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Page 2 of ")
            ).firstMatch.waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertTrue(previousPage.isEnabled)
        previousPage.click()
        XCTAssertTrue(firstPage.waitForExistence(timeout: 5), app.debugDescription)

        for action in ["Edit", "Copy Runes", "Share", "Clear"] {
            let button = app.buttons[action]
            XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(button.isHittable, app.debugDescription)
            assertMacControlSize(button)
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "macos-shipping-app-long-artifact"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertMacControlSize(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 28, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 28, file: file, line: line)
    }
}
