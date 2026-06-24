import XCTest
@testable import RuneScrib

final class ContactTests: XCTestCase {
    func testManualContactShape() {
        let c = Contact(displayName: "Bjorn", phones: ["+15551234"], source: .manual)
        XCTAssertEqual(c.displayName, "Bjorn")
        XCTAssertEqual(c.phones, ["+15551234"])
        XCTAssertEqual(c.emails, [])
        XCTAssertNil(c.appleContactID)
        XCTAssertEqual(c.source, .manual)
    }
    func testCodableRoundTrip() throws {
        let c = Contact(displayName: "Ada", emails: ["a@x.com"], appleContactID: "ABC", source: .imported)
        XCTAssertEqual(try JSONDecoder().decode(Contact.self, from: JSONEncoder().encode(c)), c)
    }
}
