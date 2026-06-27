// RuneScrib/Services/MessageCoordinator.swift

import Foundation
import CryptoKit

/// App-wide intake for *messages* arriving over the wire — a tapped `.runescribe`
/// attachment, an AirDrop/Finder-opened file, or a scanned QR. It decodes the file's
/// bytes to a `MessageSharePayload`, opportunistically imports an embedded cipher (and
/// its font, if one rode along), decrypts the envelope by trying every candidate key,
/// auto-associates the matching cipher with a contact (by sender name), and publishes a
/// `PendingMessage`; `RootView` observes it and shows the decrypted-message sheet (gated
/// so it never appears over the lock screen).
///
/// Mirrors `ImportCoordinator`. Published as a singleton and injected as an
/// `@EnvironmentObject`; all state mutates on the main actor. Dependencies are
/// injectable so the intake logic is unit-testable.
@MainActor
final class MessageCoordinator: ObservableObject {

    static let shared = MessageCoordinator()

    /// A decoded, decrypted message awaiting the user's view/reply.
    @Published var pending: PendingMessage?

    /// A human-readable reason a link couldn't be read.
    @Published var errorMessage: String?

    /// Content hash of the most recently ingested file, used to drop a duplicate
    /// delivery — e.g. the macOS AppDelegate's `application(_:open:)` and SwiftUI's
    /// `.onOpenURL` both firing for the same file.
    private var lastHandledKey: String?

    private let keyManager: KeyManager
    private let contactManager: ContactManager

    init(keyManager: KeyManager = .shared, contactManager: ContactManager = .shared) {
        self.keyManager = keyManager
        self.contactManager = contactManager
    }

    struct PendingMessage: Identifiable, Equatable {
        let id = UUID()
        let plaintext: String
        let senderName: String
        let cipher: Cipher
    }

    /// Decodes message file bytes and, on success, surfaces the decrypted text for viewing;
    /// on failure, surfaces a readable error and leaves `pending` untouched-to-nil.
    func ingest(fileData data: Data) {
        // Drop a duplicate delivery of the *same* file only while a message is still
        // pending — e.g. the macOS `AppDelegate.application(_:open:)` and SwiftUI's
        // `.onOpenURL` both firing for one file. Once that message is dismissed, or a
        // prior ingest failed (`pending == nil`), re-ingesting the same file is allowed.
        let key = Data(SHA256.hash(data: data)).base64EncodedString()
        if key == lastHandledKey, pending != nil { return }
        lastHandledKey = key
        do {
            let (payload, fontBytes) = try MessageSharePayload.decodeFile(data)

            // If the sender embedded their key, ingest it as a decrypt candidate. This
            // deduplicates by publicID (a key re-sent on every message never piles up
            // duplicates) and does NOT change the active cipher — merely receiving a message
            // must not hijack the one the user is composing with; Reply switches it explicitly.
            var candidate: Cipher?
            if let embedded = payload.embeddedCipher {
                // If the embedded cipher's font rode along and we don't already hold it,
                // install it best-effort so the imported cipher renders correctly.
                if let fontBytes, FontStore.shared.resolve(embedded.fontRef) == nil {
                    try? FontStore.shared.importFont(fontBytes, expecting: embedded.fontRef)
                }
                candidate = keyManager.ingestMessageCipher(embedded, label: payload.senderName)
            }

            // Try the freshly-imported key first, then every cipher already in the library.
            let pool = [candidate].compactMap { $0 } + keyManager.ciphers
            let (plaintext, cipher) = try MessageService().read(envelope: payload.envelope,
                                                                tryingCiphers: pool)

            autoAssociate(cipher, senderName: payload.senderName)
            errorMessage = nil
            pending = PendingMessage(plaintext: plaintext, senderName: payload.senderName, cipher: cipher)
        } catch {
            pending = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "This message couldn't be read."
        }
    }

    /// Files the matching cipher under a contact named after the sender: reuses an existing
    /// contact whose display name matches, else creates an `.imported` one, then links the
    /// cipher to it unless it's already linked. Never changes key material.
    /// By design this re-creates a contact a bulk-remove had deleted — bulk-remove undoes an
    /// accidental import, it is not a block list.
    private func autoAssociate(_ cipher: Cipher, senderName: String) {
        let contact: Contact
        if let existing = contactManager.contacts.first(where: { $0.displayName == senderName }) {
            contact = existing
        } else {
            let made = Contact(displayName: senderName, source: .imported)
            contactManager.add(made)
            contact = made
        }
        if cipher.contactID != contact.id {
            keyManager.setContact(cipherID: cipher.id, contactID: contact.id)
        }
    }
}
