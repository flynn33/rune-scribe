import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import XCTest

private let probeMarker = "FONT_REGISTRATION_RESULT="

private struct ProbeInput: Decodable {
    let schemaVersion: Int
    let expectedFontCount: Int
    let fonts: [DeclaredFont]
}

private struct DeclaredFont: Decodable {
    let resourceID: String
    let filename: String
    let bundleFilename: String
    let sha256: String
    let expectedPostScriptName: String
}

private struct FontResult: Codable {
    let resourceID: String
    let filename: String
    let sha256: String
    let expectedPostScriptName: String
    let resolvedPostScriptName: String?
    let registered: Bool
    let status: String
    let errorCode: String?
}

private struct ProbeResult: Codable {
    let status: String
    let fonts: [FontResult]
}

final class FontRegistrationProbeTests: XCTestCase {
    func testDeclaredFontsRegisterThroughCoreText() {
        let result = runProbe()
        emit(result)
        XCTAssertEqual(result.status, "PASS", "CoreText font registration did not pass.")
    }

    private func runProbe() -> ProbeResult {
        guard let inputURL = Bundle(for: Self.self).url(
            forResource: "probe-input",
            withExtension: "json"
        ), let data = try? Data(contentsOf: inputURL),
        let input = try? JSONDecoder().decode(ProbeInput.self, from: data),
        input.schemaVersion == 1,
        input.expectedFontCount == 4,
        input.fonts.count == input.expectedFontCount,
        Set(input.fonts.map(\.resourceID)).count == input.expectedFontCount,
        Set(input.fonts.map(\.filename)).count == input.expectedFontCount,
        Set(input.fonts.map(\.expectedPostScriptName)).count == input.expectedFontCount
        else {
            return ProbeResult(status: "FAIL", fonts: [])
        }

        let fonts = input.fonts
            .sorted { $0.resourceID < $1.resourceID }
            .map(probeFont)
        let passed = fonts.allSatisfy {
            $0.status == "PASS"
                && $0.registered
                && $0.errorCode == nil
                && $0.resolvedPostScriptName == $0.expectedPostScriptName
        }
        return ProbeResult(status: passed ? "PASS" : "FAIL", fonts: fonts)
    }

    private func probeFont(_ font: DeclaredFont) -> FontResult {
        guard let url = Bundle(for: Self.self).url(
            forResource: font.bundleFilename,
            withExtension: nil
        ), let bytes = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            return failure(font, sha256: font.sha256, code: "BUNDLED_FONT_MISSING")
        }

        let actualSHA256 = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA256 == font.sha256 else {
            return failure(font, sha256: actualSHA256, code: "BUNDLED_FONT_SHA256_MISMATCH")
        }

        guard let provider = CGDataProvider(url: url as CFURL),
              let graphicsFont = CGFont(provider)
        else {
            return failure(font, sha256: actualSHA256, code: "FONT_UNREADABLE")
        }
        let inspectedName = graphicsFont.postScriptName as String?
        guard inspectedName == font.expectedPostScriptName else {
            return FontResult(
                resourceID: font.resourceID,
                filename: font.filename,
                sha256: actualSHA256,
                expectedPostScriptName: font.expectedPostScriptName,
                resolvedPostScriptName: inspectedName,
                registered: false,
                status: "FAIL",
                errorCode: "POSTSCRIPT_NAME_MISMATCH"
            )
        }

        let registered = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            nil
        )
        guard registered else {
            return FontResult(
                resourceID: font.resourceID,
                filename: font.filename,
                sha256: actualSHA256,
                expectedPostScriptName: font.expectedPostScriptName,
                resolvedPostScriptName: inspectedName,
                registered: false,
                status: "FAIL",
                errorCode: "CORETEXT_REGISTRATION_FAILED"
            )
        }

        let runtimeFont = CTFontCreateWithName(
            font.expectedPostScriptName as CFString,
            16,
            nil
        )
        let resolvedName = CTFontCopyPostScriptName(runtimeFont) as String
        guard resolvedName == font.expectedPostScriptName else {
            return FontResult(
                resourceID: font.resourceID,
                filename: font.filename,
                sha256: actualSHA256,
                expectedPostScriptName: font.expectedPostScriptName,
                resolvedPostScriptName: resolvedName,
                registered: true,
                status: "FAIL",
                errorCode: "REGISTERED_POSTSCRIPT_NAME_MISMATCH"
            )
        }

        return FontResult(
            resourceID: font.resourceID,
            filename: font.filename,
            sha256: actualSHA256,
            expectedPostScriptName: font.expectedPostScriptName,
            resolvedPostScriptName: resolvedName,
            registered: true,
            status: "PASS",
            errorCode: nil
        )
    }

    private func failure(
        _ font: DeclaredFont,
        sha256: String,
        code: String
    ) -> FontResult {
        FontResult(
            resourceID: font.resourceID,
            filename: font.filename,
            sha256: sha256,
            expectedPostScriptName: font.expectedPostScriptName,
            resolvedPostScriptName: nil,
            registered: false,
            status: "FAIL",
            errorCode: code
        )
    }

    private func emit(_ result: ProbeResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(result),
              let json = String(data: data, encoding: .utf8)
        else {
            XCTFail("Probe evidence could not be encoded.")
            return
        }
        print(probeMarker + json)
    }
}
