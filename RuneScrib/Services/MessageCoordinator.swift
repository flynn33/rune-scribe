// RuneScrib/Services/MessageCoordinator.swift

import Foundation

/// App-wide intake for *messages* arriving over the wire — deep links (`.onOpenURL`),
/// scanned QR codes, the clipboard, and Universal Links. It decodes a
/// `runescribe://m` / `https://ravenforgesoftware.com/rune-scribe/m` URL to a
/// `MessageSharePayload`, opportunistically imports an embedded cipher, decrypts the
/// envelope by trying every candidate key, auto-associates the matching cipher with a
/// contact (by sender name), and publishes a `PendingMessage`; `RootView` observes it
/// and shows the decrypted-message sheet (gated so it never appears over the lock screen).
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

    /// The most recently ingested URL, used to drop a duplicate delivery — e.g. the
    /// macOS AppDelegate's `application(_:open:)` and SwiftUI's `.onOpenURL` both
    /// firing for the same link.
    private var lastHandledURL: String?

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

    /// Decodes a message URL and, on success, surfaces the decrypted text for viewing;
    /// on failure, surfaces a readable error and leaves `pending` untouched-to-nil.
    func ingest(url: URL) {
        // Drop a duplicate delivery of the *same* link only while a message is still
        // pending — e.g. the macOS `AppDelegate.application(_:open:)` and SwiftUI's
        // `.onOpenURL` both firing for one link. Once that message is dismissed, or a
        // prior ingest failed (`pending == nil`), re-ingesting the same link is allowed.
        let key = url.absoluteString
        if key == lastHandledURL, pending != nil { return }
        lastHandledURL = key
        do {
            let payload = try MessageSharePayload(url: url)

            // If the sender embedded their key, import (persist) it so it's saved for future
            // messages and selectable when the user taps Reply. Prefer the persisted library
            // cipher; if persisting fails but a stored cipher already holds the same key, use
            // that; only if the Keychain is wholly unavailable fall back to an in-memory copy
            // so THIS message still opens instead of failing with "no matching cipher".
            var candidate: Cipher?
            if let embedded = payload.embeddedCipher {
                if let imported = try? keyManager.importCipher(embedded, label: payload.senderName) {
                    candidate = imported
                } else if let stored = keyManager.ciphers.first(where: { $0.keyMaterial == embedded.keyMaterial }) {
                    candidate = stored
                } else {
                    candidate = embedded.cipher(label: payload.senderName)
                }
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

    /// Same as `ingest(url:)` but from a raw string (clipboard / scanned payload).
    /// Silently ignores anything that isn't one of our message links.
    func ingest(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MessageSharePayload.isMessageURL(trimmed), let url = URL(string: trimmed) else { return }
        ingest(url: url)
    }

    /// Files the matching cipher under a contact named after the sender: reuses an existing
    /// contact whose display name matches, else creates an `.imported` one, then links the
    /// cipher to it unless it's already linked. Never changes key material.
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
