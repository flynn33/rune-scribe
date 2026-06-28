import XCTest
@testable import RuneScrib

final class LinkRouterTests: XCTestCase {

    // MARK: cipher links

    func testClassifiesGeneratedShareURLAsCipher() throws {
        // url(name:) now generates the offline runescribe:// form; it must classify as cipher.
        let url = try CipherSharePayload(cipher: .generated(label: "A")).url(name: nil)
        guard case .cipher = LinkRouter.classify(url) else {
            return XCTFail("expected .cipher for \(url.absoluteString)")
        }
    }

    func testClassifiesCustomSchemeCipherImportAsCipher() throws {
        let url = try XCTUnwrap(URL(string: "runescribe://import?v=3&p=AAAA"))
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
    func testClassifiesHTTPSImportAsCipher() throws {
        let url = try XCTUnwrap(URL(string: "https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAAA"))
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
