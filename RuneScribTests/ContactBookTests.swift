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

    func testRemovingIdsLeavesTheComplement() {
        let a = Contact(displayName: "A", source: .manual)
        let b = Contact(displayName: "B", source: .manual)
        let c = Contact(displayName: "C", source: .manual)
        let book = ContactBook(contacts: [a, b, c]).removing(ids: [a.id, c.id])
        XCTAssertEqual(book.contacts.map(\.id), [b.id], "only the unselected contact remains")
    }

    func testRemovingImportedSparesManual() {
        let manual = Contact(displayName: "Manual", source: .manual)
        let imported = Contact(displayName: "Imported", appleContactID: "imp", source: .imported)
        let book = ContactBook(contacts: [manual, imported]).removingImported()
        XCTAssertEqual(book.contacts.map(\.id), [manual.id], "manual contacts are kept; imported are removed")
    }

    func testRemovingEmptySetIsNoOp() {
        let a = Contact(displayName: "A", source: .manual)
        let book = ContactBook(contacts: [a])
        XCTAssertEqual(book.removing(ids: []).contacts, book.contacts, "removing an empty set changes nothing")
    }
}
