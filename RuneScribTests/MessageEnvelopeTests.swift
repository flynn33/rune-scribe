import XCTest
@testable import RuneScrib

final class MessageEnvelopeTests: XCTestCase {
    func testWrapUnwrapRoundTrip() throws {
        let sealed = Data([1, 2, 3, 4])
        let env = MessageEnvelope.wrap(sealed)
        XCTAssertEqual(env.first, MessageEnvelope.version)
        XCTAssertEqual(try MessageEnvelope.unwrap(env), sealed)
    }
    func testUnwrapRejectsEmpty() {
        XCTAssertThrowsError(try MessageEnvelope.unwrap(Data()))
    }
    func testUnwrapRejectsWrongVersion() {
        XCTAssertThrowsError(try MessageEnvelope.unwrap(Data([99, 1, 2])))
    }
}
