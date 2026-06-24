import XCTest
import CryptoKit
@testable import RuneScrib

final class ContactStoreTests: XCTestCase {
    func testEncryptedSaveReloadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        let store = ContactStore(key: key, directory: dir)
        let book = ContactBook.empty.adding(Contact(displayName: "Saga", source: .manual))
        try store.save(book)
        XCTAssertEqual(ContactStore(key: key, directory: dir).load(), book)
        try? FileManager.default.removeItem(at: dir)
    }
    func testWrongKeyCannotDecrypt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ContactStore(key: SymmetricKey(size: .bits256), directory: dir)
        try store.save(ContactBook.empty.adding(Contact(displayName: "Z", source: .manual)))
        XCTAssertEqual(ContactStore(key: SymmetricKey(size: .bits256), directory: dir).load(), .empty,
                       "a wrong key yields the empty book, never garbage")
        try? FileManager.default.removeItem(at: dir)
    }
}
