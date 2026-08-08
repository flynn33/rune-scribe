import Foundation

enum ContactStoreMigrationError: Error, Equatable, Sendable {
    case applicationServiceRequired
}

/// Neutral compatibility shell retained for target membership during migration.
/// It owns no key, file path, singleton, cached state, or write capability.
final class ContactStore: Sendable {
    init() {}

    func load() -> ContactBook {
        .empty
    }

    func save(_ book: ContactBook) throws {
        _ = book
        throw ContactStoreMigrationError.applicationServiceRequired
    }
}
