import Foundation

/// Core's encrypted, on-device snapshot of a person. Imported records keep the
/// platform contact identifier only for local deduplication; it never crosses
/// the public application-service boundary.
struct Contact: Codable, Equatable, Identifiable, Sendable {
    static let maximumDisplayNameUTF8Count = 512
    static let maximumPhoneCount = 32
    static let maximumPhoneUTF8Count = 512
    static let maximumEmailCount = 32
    static let maximumEmailUTF8Count = 512
    static let maximumAppleContactIDUTF8Count = 1_024

    enum Source: String, Codable, Sendable {
        case manual
        case imported
    }

    let id: UUID
    var displayName: String
    var phones: [String]
    var emails: [String]
    var appleContactID: String?
    let source: Source
    let createdAt: Date

    init(
        id: UUID,
        displayName: String,
        phones: [String] = [],
        emails: [String] = [],
        appleContactID: String? = nil,
        source: Source,
        createdAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.phones = phones
        self.emails = emails
        self.appleContactID = appleContactID
        self.source = source
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case phones
        case emails
        case appleContactID
        case source
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        phones = try Self.decodeBoundedStrings(
            from: container,
            forKey: .phones,
            maximumCount: Self.maximumPhoneCount,
            maximumUTF8Count: Self.maximumPhoneUTF8Count,
            tooManyError: .tooManyPhoneNumbers,
            tooLongError: .phoneNumberTooLong
        )
        emails = try Self.decodeBoundedStrings(
            from: container,
            forKey: .emails,
            maximumCount: Self.maximumEmailCount,
            maximumUTF8Count: Self.maximumEmailUTF8Count,
            tooManyError: .tooManyEmailAddresses,
            tooLongError: .emailAddressTooLong
        )
        appleContactID = try container.decodeIfPresent(
            String.self,
            forKey: .appleContactID
        )
        source = try container.decode(Source.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        try validatePersistenceBounds()
    }

    func validatePersistenceBounds() throws {
        guard displayName.utf8.count <= Self.maximumDisplayNameUTF8Count else {
            throw ContactBookValidationError.displayNameTooLong
        }
        guard phones.count <= Self.maximumPhoneCount else {
            throw ContactBookValidationError.tooManyPhoneNumbers
        }
        guard phones.allSatisfy({ $0.utf8.count <= Self.maximumPhoneUTF8Count }) else {
            throw ContactBookValidationError.phoneNumberTooLong
        }
        guard emails.count <= Self.maximumEmailCount else {
            throw ContactBookValidationError.tooManyEmailAddresses
        }
        guard emails.allSatisfy({ $0.utf8.count <= Self.maximumEmailUTF8Count }) else {
            throw ContactBookValidationError.emailAddressTooLong
        }
        guard appleContactID?.utf8.count ?? 0 <= Self.maximumAppleContactIDUTF8Count else {
            throw ContactBookValidationError.appleContactIDTooLong
        }
    }

    private static func decodeBoundedStrings(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        maximumCount: Int,
        maximumUTF8Count: Int,
        tooManyError: ContactBookValidationError,
        tooLongError: ContactBookValidationError
    ) throws -> [String] {
        var values = try container.nestedUnkeyedContainer(forKey: key)
        if let count = values.count, count > maximumCount {
            throw tooManyError
        }

        var decoded: [String] = []
        decoded.reserveCapacity(min(values.count ?? 0, maximumCount))
        while !values.isAtEnd {
            guard decoded.count < maximumCount else { throw tooManyError }
            let value = try values.decode(String.self)
            guard value.utf8.count <= maximumUTF8Count else {
                throw tooLongError
            }
            decoded.append(value)
        }
        return decoded
    }
}
