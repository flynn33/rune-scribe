import Foundation

/// Owns the user's contacts (loaded/saved via `ContactStore`) and keeps cipher links consistent
/// when a contact is deleted. Published for SwiftUI; all state on the main actor.
@MainActor
final class ContactManager: ObservableObject {
    static let shared = ContactManager()
    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var lastError: String?
    private let store: ContactStore
    private let keyManager: KeyManager

    init(store: ContactStore = .shared, keyManager: KeyManager = .shared) {
        self.store = store
        self.keyManager = keyManager
        contacts = store.load().contacts
    }

    func add(_ c: Contact) { persist(book().adding(c)) }
    func update(_ c: Contact) { persist(book().updating(c)) }

    /// Deletes a contact and unlinks (never deletes) its ciphers.
    func delete(id: UUID) {
        keyManager.unlinkContact(id)
        persist(book().removing(id: id))
    }

    func contact(id: UUID?) -> Contact? { id.flatMap { id in contacts.first { $0.id == id } } }

    private func book() -> ContactBook { ContactBook(contacts: contacts) }
    private func persist(_ updated: ContactBook) {
        contacts = updated.contacts
        do {
            try store.save(updated)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
