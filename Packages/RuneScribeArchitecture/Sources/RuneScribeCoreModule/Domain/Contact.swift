import Foundation

/// Core's encrypted, on-device snapshot of a person. Imported records keep the
/// platform contact identifier only for local deduplication; it never crosses
/// the public application-service boundary.
struct Contact: Codable, Equatable, Identifiable, Sendable {
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
}
