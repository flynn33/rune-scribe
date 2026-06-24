import Foundation

/// A local, on-device snapshot of a person a cipher can be organized under. Imported contacts
/// keep the Apple `CNContact` identifier for reference only — the snapshot is never
/// automatically re-synced, so editing or deleting the Apple contact never changes this record
/// or any cipher.
struct Contact: Codable, Equatable, Identifiable {
    enum Source: String, Codable { case manual, imported }

    let id: UUID
    var displayName: String
    var phones: [String]
    var emails: [String]
    var appleContactID: String?
    let source: Source
    let createdAt: Date

    init(id: UUID = UUID(), displayName: String, phones: [String] = [], emails: [String] = [],
         appleContactID: String? = nil, source: Source, createdAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.phones = phones
        self.emails = emails
        self.appleContactID = appleContactID
        self.source = source
        self.createdAt = createdAt
    }
}
