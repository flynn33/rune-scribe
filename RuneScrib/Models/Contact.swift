import Foundation
import RuneScribeContracts

/// Key-free presentation model used by the hosted views during the UI migration.
/// Authoritative contact state lives behind `RuneScribeApplicationService`.
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
        id: UUID = UUID(),
        displayName: String,
        phones: [String] = [],
        emails: [String] = [],
        appleContactID: String? = nil,
        source: Source,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.phones = phones
        self.emails = emails
        self.appleContactID = appleContactID
        self.source = source
        self.createdAt = createdAt
    }

    init(summary: ContactSummary, systemIdentifier: String? = nil) {
        id = summary.id.rawValue
        displayName = summary.displayName
        phones = summary.phoneNumbers
        emails = summary.emailAddresses
        appleContactID = systemIdentifier
        source = summary.source == .manual ? .manual : .imported
        createdAt = summary.createdAt
    }
}
