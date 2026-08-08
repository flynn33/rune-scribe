import XCTest
@testable import RuneScrib

final class LinkRouterTests: XCTestCase {
    private static let cipherV3Token = "AwABAgMEBQYHEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8fHh0cGxoZGBcWFRQTEhEQDw4NDAsKCQgHBgUEAwIBAG5vdG8tc2Fucy1ydW5pYwAAAAABYVtsEWaoxRgW3BU2eErL9IZUfjvtA9v91wkQ4QBmeTsMHGhN"

    // MARK: cipher links

    func testClassifiesCompatibleCustomSchemeCipherImportAsCipher() throws {
        let url = try XCTUnwrap(
            URL(
                string: "runescribe://import?v=3&p=\(Self.cipherV3Token)"
                    + "&n=Baseline%20Custom"
            )
        )
        guard case .cipher = LinkRouter.classify(url) else {
            return XCTFail("expected .cipher for \(url.absoluteString)")
        }
    }

    // MARK: unknown

    func testClassifiesUnrelatedHTTPSAsUnknown() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/hello"))
        guard case .unknown = LinkRouter.classify(url) else {
            return XCTFail("expected .unknown for \(url.absoluteString)")
        }
    }

    // MARK: router-level discrimination invariants (hardening)

    /// A cipher-import https link still classifies as `.cipher` now that messages are
    /// file-based and no longer compete for the URL rail.
    func testClassifiesCompatibleLegacyHTTPSImportAsCipher() throws {
        let url = try XCTUnwrap(
            URL(
                string: "https://www.ravenforgesoftware.com/rune-scribe/import"
                    + "?v=3&p=\(Self.cipherV3Token)&n=Baseline%20Legacy"
            )
        )
        guard case .cipher = LinkRouter.classify(url) else {
            return XCTFail("expected .cipher for \(url.absoluteString)")
        }
    }

    /// A leftover `runescribe://m` message link is no longer routed as a cipher (it was
    /// never a cipher) — it is simply `.unknown` on the URL rail.
    func testClassifiesLegacyMessageURLAsUnknown() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/rune-scribe/m?v=1&p=AAAA"))
        guard case .unknown = LinkRouter.classify(url) else {
            return XCTFail("expected .unknown for \(url.absoluteString)")
        }
    }
}
