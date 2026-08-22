import Foundation

enum ContactBookValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case tooManyContacts
    case tooManyPhoneNumbers
    case tooManyEmailAddresses
    case displayNameTooLong
    case phoneNumberTooLong
    case emailAddressTooLong
    case appleContactIDTooLong
}

/// Version 1 is the shipping encrypted-contact JSON schema. Its field names and
/// deferred-date representation remain stable for compatibility with existing
/// `contacts.enc` files.
struct ContactBook: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Keeps decoded collection growth bounded independently of the encrypted
    /// file and plaintext byte ceilings enforced by the repository.
    static let maximumContactCount = 4_096
    static let empty = ContactBook(contacts: [])

    var version: Int
    var contacts: [Contact]

    init(version: Int = Self.currentVersion, contacts: [Contact]) {
        self.version = version
        self.contacts = contacts
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case contacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw ContactBookValidationError.unsupportedVersion(version)
        }
        var encodedContacts = try container.nestedUnkeyedContainer(
            forKey: .contacts
        )
        if let count = encodedContacts.count, count > Self.maximumContactCount {
            throw ContactBookValidationError.tooManyContacts
        }

        var decodedContacts: [Contact] = []
        decodedContacts.reserveCapacity(
            min(encodedContacts.count ?? 0, Self.maximumContactCount)
        )
        while !encodedContacts.isAtEnd {
            guard decodedContacts.count < Self.maximumContactCount else {
                throw ContactBookValidationError.tooManyContacts
            }
            decodedContacts.append(try encodedContacts.decode(Contact.self))
        }
        contacts = decodedContacts
    }

    func validatePersistenceBounds() throws {
        guard contacts.count <= Self.maximumContactCount else {
            throw ContactBookValidationError.tooManyContacts
        }
        for contact in contacts {
            try contact.validatePersistenceBounds()
        }
    }
}

extension ContactBook {
    func contact(id: UUID) -> Contact? {
        contacts.first { $0.id == id }
    }

    func contact(systemIdentifier: String) -> Contact? {
        contacts.first { $0.appleContactID == systemIdentifier }
    }

    func adding(_ contact: Contact) -> ContactBook {
        var copy = self
        copy.contacts.append(contact)
        return copy
    }

    func adding(contentsOf contacts: [Contact]) -> ContactBook {
        var copy = self
        copy.contacts.append(contentsOf: contacts)
        return copy
    }

    func updating(_ contact: Contact) -> ContactBook {
        var copy = self
        if let index = copy.contacts.firstIndex(where: { $0.id == contact.id }) {
            copy.contacts[index] = contact
        }
        return copy
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
