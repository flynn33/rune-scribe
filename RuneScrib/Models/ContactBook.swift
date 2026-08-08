import Foundation

/// Presentation-only collection retained until the hosted contact views move to
/// snapshot DTOs. It is never persisted and is not an authoritative repository.
struct ContactBook: Codable, Equatable, Sendable {
    var version: Int = 1
    var contacts: [Contact]

    static let empty = ContactBook(contacts: [])

    func contact(id: UUID) -> Contact? {
        contacts.first { $0.id == id }
    }

    func adding(_ contact: Contact) -> ContactBook {
        var copy = self
        copy.contacts.append(contact)
        return copy
    }

    func updating(_ contact: Contact) -> ContactBook {
        var copy = self
        if let index = copy.contacts.firstIndex(where: { $0.id == contact.id }) {
            copy.contacts[index] = contact
        }
        return copy
    }

    func removing(id: UUID) -> ContactBook {
        removing(ids: [id])
    }

    func removing(ids: Set<UUID>) -> ContactBook {
        var copy = self
        copy.contacts.removeAll { ids.contains($0.id) }
        return copy
    }

    func removingImported() -> ContactBook {
        var copy = self
        copy.contacts.removeAll { $0.source == .imported }
        return copy
    }
}
