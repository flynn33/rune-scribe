import XCTest
@testable import RuneScrib

final class LinkRouterTests: XCTestCase {

    // MARK: cipher links

    func testClassifiesHTTPSCipherImportAsCipher() throws {
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

    // MARK: message links

    func testClassifiesHTTPSMessageAsMessage() throws {
        let url = try XCTUnwrap(URL(string: "https://ravenforgesoftware.com/rune-scribe/m?v=1&p=AAAA"))
        guard case .message = LinkRouter.classify(url) else {
            return XCTFail("expected .message for \(url.absoluteString)")
        }
    }

    func testClassifiesCustomSchemeMessageAsMessage() throws {
        let url = try XCTUnwrap(URL(string: "runescribe://m?v=1&p=AAAA"))
        guard case .message = LinkRouter.classify(url) else {
            return XCTFail("expected .message for \(url.absoluteString)")
        }
    }

    // MARK: unknown

    func testClassifiesUnrelatedHTTPSAsUnknown() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/hello"))
        guard case .unknown = LinkRouter.classify(url) else {
            return XCTFail("expected .unknown for \(url.absoluteString)")
        }
    }
}
