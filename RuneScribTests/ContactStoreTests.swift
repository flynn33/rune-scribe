import XCTest
@testable import RuneScrib

final class ContactStoreTests: XCTestCase {
    func testHostedCompatibilityShellOwnsNoStateAndCannotWrite() {
        let store = ContactStore()
        let book = ContactBook.empty.adding(
            Contact(displayName: "Presentation Only", source: .manual)
        )

        XCTAssertEqual(store.load(), .empty)
        XCTAssertThrowsError(try store.save(book)) { error in
            XCTAssertEqual(
                error as? ContactStoreMigrationError,
                .applicationServiceRequired
            )
        }
        XCTAssertEqual(store.load(), .empty)
    }
}
