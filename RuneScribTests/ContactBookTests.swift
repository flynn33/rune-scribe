import XCTest
@testable import RuneScrib

final class ContactBookTests: XCTestCase {
    func testAddUpdateRemove() {
        let a = Contact(displayName: "A", source: .manual)
        var book = ContactBook.empty.adding(a)
        XCTAssertEqual(book.contacts.count, 1)
        var a2 = a; a2.displayName = "A2"
        book = book.updating(a2)
        XCTAssertEqual(book.contact(id: a.id)?.displayName, "A2")
        book = book.removing(id: a.id)
        XCTAssertTrue(book.contacts.isEmpty)
    }
    func testCodableRoundTrip() throws {
        let book = ContactBook.empty.adding(Contact(displayName: "X", source: .manual))
        XCTAssertEqual(try JSONDecoder().decode(ContactBook.self, from: JSONEncoder().encode(book)), book)
    }
}
