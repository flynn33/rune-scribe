import Foundation

/// Owns the user's contacts (loaded/saved via `ContactStore`) and keeps cipher links consistent
/// when a contact is deleted. Published for SwiftUI; all state on the main actor.
@MainActor
final class ContactManager: ObservableObject {
    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var lastError: String?
    private let store: ContactStore
    private let keyManager: KeyManager

    init(store: ContactStore = .shared, keyManager: KeyManager) {
        self.store = store
        self.keyManager = keyManager
        contacts = store.load().contacts
    }

    func add(_ c: Contact) { persist(book().adding(c)) }
    func update(_ c: Contact) { persist(book().updating(c)) }

    /// Adds imported snapshots, skipping any whose Apple identifier is already present —
    /// deduping against existing contacts AND within the batch. Manual snapshots (nil
    /// identifier) are always added. Each newly-added contact is given one auto-assigned,
    /// non-activating cipher (import-only; manual `add(_:)` never auto-generates).
    func addImported(_ snapshots: [Contact]) {
        var seen = Set(contacts.compactMap(\.appleContactID))
        var added: [Contact] = []
        for snap in snapshots {
            if let id = snap.appleContactID {
                if seen.contains(id) { continue }
                seen.insert(id)
            }
            added.append(snap)
        }
        guard !added.isEmpty else { return }
        persist(ContactBook(contacts: contacts + added))
        for contact in added {
            Task { try? await keyManager.ensureLinkedCipher(forImportedContact: contact) }
        }
    }

    /// Deletes a contact and unlinks (never deletes) its ciphers.
    func delete(id: UUID) {
        Task { try? await keyManager.unlinkContact(id) }
        persist(book().removing(id: id))
    }

    /// Bulk-deletes contacts and unlinks (never deletes) their ciphers in one batched persist.
    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        Task { try? await keyManager.unlinkContacts(ids) }
        persist(book().removing(ids: ids))
    }

    /// Removes every imported contact (sparing manual ones) and unlinks their ciphers, keeping
    /// them. Undoes an accidental import; it is not a block list — a later inbound message from a
    /// removed sender legitimately re-creates that contact (see `MessageCoordinator.autoAssociate`).
    func deleteAllImported() {
        let importedIDs = contacts.filter { $0.source == .imported }.map(\.id)
        guard !importedIDs.isEmpty else { return }
        Task { try? await keyManager.unlinkContacts(Set(importedIDs)) }
        persist(book().removingImported())
    }

    /// The number of imported contacts currently held.
    var importedCount: Int { contacts.lazy.filter { $0.source == .imported }.count }

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
