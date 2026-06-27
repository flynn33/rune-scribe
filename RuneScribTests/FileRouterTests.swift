import XCTest
@testable import RuneScrib

final class FileRouterTests: XCTestCase {

    /// A message file's leading version byte routes it to `.message`.
    func testClassifiesMessageVersionAsMessage() {
        let data = Data([MessageSharePayload.version, 0x00, 0x00])
        guard case .message(let d) = FileRouter.classify(data) else {
            return XCTFail("expected .message for leading 0x\(String(MessageSharePayload.version, radix: 16))")
        }
        XCTAssertEqual(d, data)
    }

    /// A cipher file's leading version byte routes it to `.cipher`.
    func testClassifiesCipherVersionAsCipher() {
        let data = Data([CipherSharePayload.version, 0x00, 0x00])
        guard case .cipher(let d) = FileRouter.classify(data) else {
            return XCTFail("expected .cipher for leading 0x\(String(CipherSharePayload.version, radix: 16))")
        }
        XCTAssertEqual(d, data)
    }

    func testClassifiesEmptyAsUnknown() {
        guard case .unknown = FileRouter.classify(Data()) else {
            return XCTFail("expected .unknown for empty data")
        }
    }

    func testClassifiesOtherLeadingByteAsUnknown() {
        guard case .unknown = FileRouter.classify(Data([0x7F, 0x01, 0x02])) else {
            return XCTFail("expected .unknown for an unrecognised leading byte")
        }
    }

    /// The classifier relies on the two version bytes being distinct; pin that invariant.
    func testMessageAndCipherVersionsAreDistinct() {
        XCTAssertNotEqual(MessageSharePayload.version, CipherSharePayload.version)
    }
}
