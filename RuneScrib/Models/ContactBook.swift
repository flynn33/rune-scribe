import Foundation

/// The persisted collection of the user's contacts. Stored AES-GCM-encrypted in a file
/// (see `ContactStore`). Pure mutations return a new book and are unit-testable.
struct ContactBook: Codable, Equatable {
    var version: Int = 1
    var contacts: [Contact]

    static let empty = ContactBook(contacts: [])

    private enum CodingKeys: String, CodingKey { case version, contacts }
}

extension ContactBook {
    func contact(id: UUID) -> Contact? { contacts.first { $0.id == id } }

    func adding(_ c: Contact) -> ContactBook {
        var copy = self; copy.contacts.append(c); return copy
    }
    func updating(_ c: Contact) -> ContactBook {
        var copy = self
        if let i = copy.contacts.firstIndex(where: { $0.id == c.id }) { copy.contacts[i] = c }
        return copy
    }
    func removing(id: UUID) -> ContactBook {
        var copy = self; copy.contacts.removeAll { $0.id == id }; return copy
    }
}
