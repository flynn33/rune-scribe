import CryptoKit
import Foundation
import XCTest

@MainActor
final class RuneScribeParityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFreshInstallExercisesPrimaryProductFlows() throws {
        let app = XCUIApplication()
        app.open(Self.customImportURL)

        let skipIntro = app.buttons["Skip intro"]
        if skipIntro.waitForExistence(timeout: 12) {
            skipIntro.tap()
        }

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
        XCTAssertTrue(app.buttons["Manage your cipher library"].exists)
        XCTAssertTrue(app.buttons["Active cipher: My Cipher"].exists)
        XCTAssertTrue(app.buttons["Set recipient to include the key"].exists)

        try auditAccessibility(in: app)

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["SETTINGS"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Set a PIN…"].exists)
        XCTAssertTrue(app.buttons["Manage Contacts"].exists)
        XCTAssertTrue(app.buttons["View License"].exists)
        try auditAccessibility(in: app)

        app.buttons["View License"].tap()
        XCTAssertTrue(app.staticTexts["LICENSE"].waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()

        app.buttons["Manage Contacts"].tap()
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
        app.buttons["Close"].firstMatch.tap()

        app.buttons["Set a PIN…"].tap()
        XCTAssertTrue(app.staticTexts["SET PIN"].waitForExistence(timeout: 5))
        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["Confirm PIN"].waitForExistence(timeout: 5))
        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["PIN set"].waitForExistence(timeout: 8))

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
        enterPIN("1234", in: app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Change PIN"].waitForExistence(timeout: 5))
        app.buttons["Change PIN"].tap()
        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["Enter New PIN"].waitForExistence(timeout: 5))
        enterPIN("5678", in: app)
        XCTAssertTrue(app.staticTexts["Confirm PIN"].waitForExistence(timeout: 5))
        enterPIN("5678", in: app)
        XCTAssertTrue(app.staticTexts["PIN set"].waitForExistence(timeout: 8))

        app.buttons["Disable"].tap()
        XCTAssertTrue(app.staticTexts["Enter Current PIN"].waitForExistence(timeout: 5))
        enterPIN("5678", in: app)
        XCTAssertTrue(app.staticTexts["No PIN"].waitForExistence(timeout: 8))
        app.buttons["Close"].firstMatch.tap()

        app.buttons["Manage your cipher library"].tap()
        let contactsPrompt = app.sheets["Organize ciphers by contact?"]
        if contactsPrompt.waitForExistence(timeout: 3) {
            let notNow = contactsPrompt.buttons["Not Now"]
            if notNow.exists {
                notNow.tap()
            } else if app.otherElements["PopoverDismissRegion"].exists {
                app.otherElements["PopoverDismissRegion"].firstMatch.tap()
            } else {
                contactsPrompt.swipeDown()
            }
            XCTAssertTrue(contactsPrompt.waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import…"].exists)
        XCTAssertTrue(app.buttons["Scan QR Code"].exists)
        try auditAccessibility(in: app)
        let shareButton = app.buttons["Share My Cipher"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 8), app.debugDescription)
        shareButton.tap()
        let activityList = app.otherElements["ActivityListView"]
        XCTAssertTrue(activityList.waitForExistence(timeout: 8), app.debugDescription)
        dismissSystemShareSheet(in: app, activityList: activityList)
        XCTAssertTrue(activityList.waitForNonExistence(timeout: 8))
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

        app.buttons["Rename Parity Cipher"].tap()
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
        linkedContactMenu.tap()
        app.buttons["No contact"].tap()
        XCTAssertTrue(contactMenu.waitForExistence(timeout: 8))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["CIPHER LIBRARY"].waitForExistence(timeout: 5))

        app.buttons["Delete Parity Cipher Renamed"].tap()
        let deleteCipher = app.alerts["Delete “Parity Cipher Renamed”?"]
        XCTAssertTrue(deleteCipher.waitForExistence(timeout: 5))
        deleteCipher.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Parity Cipher Renamed"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["1 cipher"].waitForExistence(timeout: 8))

        app.buttons["Close"].firstMatch.tap()
        app.buttons["Settings"].tap()
        app.buttons["Manage Contacts"].tap()
        XCTAssertTrue(app.staticTexts["Parity Contact Edited"].waitForExistence(timeout: 5))
        app.buttons["Delete Parity Contact Edited"].tap()
        let deleteContact = app.alerts["Delete “Parity Contact Edited”?"]
        XCTAssertTrue(deleteContact.waitForExistence(timeout: 5))
        deleteContact.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["No contacts yet"].waitForExistence(timeout: 8))

        app.buttons["Close"].firstMatch.tap()
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))

        app.open(Self.malformedImportURL)
        let importFailure = app.alerts["Import Failed"]
        XCTAssertTrue(importFailure.waitForExistence(timeout: 8), app.debugDescription)
        importFailure.buttons["OK"].tap()

        app.open(Self.legacyImportURL)
        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Baseline Legacy")
        try auditAccessibility(in: app)
        app.buttons["Import"].tap()
        XCTAssertTrue(app.buttons["Active cipher: Baseline Legacy"].waitForExistence(timeout: 8))

        let cipherFile = try makeCipherFixtureFile()
        app.open(cipherFile)
        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Imported Cipher")
        app.buttons["Import"].tap()
        XCTAssertTrue(app.buttons["Active cipher: Imported Cipher"].waitForExistence(timeout: 8))

        let customFontFile = try makeCustomFontFixtureFile(validFontBytes: true)
        app.open(customFontFile)
        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Imported Cipher")
        app.buttons["Import"].tap()
        XCTAssertTrue(app.buttons["Active cipher: Imported Cipher"].waitForExistence(timeout: 8))
        app.buttons["Manage your cipher library"].tap()
        XCTAssertTrue(app.staticTexts["4 ciphers"].waitForExistence(timeout: 8), app.debugDescription)
        app.buttons["Close"].firstMatch.tap()

        let invalidFontFile = try makeCustomFontFixtureFile(validFontBytes: false)
        app.open(invalidFontFile)
        XCTAssertTrue(app.staticTexts["SHARED CIPHER"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(app.textFields["Cipher name"].value as? String, "Imported Cipher")
        app.buttons["Import"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(identifier: "import-confirmation-error")
                .firstMatch.waitForExistence(timeout: 8),
            app.debugDescription
        )
        app.buttons.matching(identifier: "xmark").firstMatch.tap()
        XCTAssertTrue(app.buttons["Active cipher: Imported Cipher"].waitForExistence(timeout: 8))
        app.buttons["Manage your cipher library"].tap()
        XCTAssertTrue(app.staticTexts["4 ciphers"].waitForExistence(timeout: 8), app.debugDescription)
        app.buttons["Close"].firstMatch.tap()

        let messageFile = try makeMessageFixtureFile()
        app.open(messageFile)
        XCTAssertTrue(app.staticTexts["DECODED MESSAGE"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Parity Sender"].exists)
        XCTAssertTrue(app.staticTexts["Parity reply message"].exists)
        try auditAccessibility(in: app)
        app.buttons["Reply"].tap()
        XCTAssertTrue(app.buttons["RUNE SCRIBE"].waitForExistence(timeout: 8))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "fresh-install-primary-flows"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        for digit in pin {
            let button = app.buttons[String(digit)]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
        }
    }

    private func auditAccessibility(in app: XCUIApplication) throws {
        try app.performAccessibilityAudit(
            for: [.sufficientElementDescription, .hitRegion, .trait, .textClipped]
        )
    }

    private func dismissSystemShareSheet(
        in app: XCUIApplication,
        activityList: XCUIElement
    ) {
        let systemClose = app.buttons["header.closeButton"].firstMatch
        let caseInsensitiveClose = app.buttons.matching(
            NSPredicate(format: "label ==[c] %@", "close")
        ).firstMatch
        let cancel = activityList.buttons["Cancel"]
        let close = activityList.buttons["Close"]
        let done = activityList.buttons["Done"]
        if systemClose.exists {
            systemClose.tap()
        } else if caseInsensitiveClose.exists {
            caseInsensitiveClose.tap()
        } else if cancel.exists {
            cancel.tap()
        } else if close.exists {
            close.tap()
        } else if done.exists {
            done.tap()
        } else if app.buttons["Close"].firstMatch.isHittable {
            app.buttons["Close"].firstMatch.tap()
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
        field.tap()
        let existingCharacterCount = (field.value as? String)?.count ?? 0
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        if (field.value as? String)?.isEmpty != true {
            for _ in 0..<existingCharacterCount {
                field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            }
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
            Bundle(for: RuneScribeParityUITests.self)
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
