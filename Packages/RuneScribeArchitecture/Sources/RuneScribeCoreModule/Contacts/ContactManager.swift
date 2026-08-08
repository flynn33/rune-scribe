import Foundation
import RuneScribeContracts

enum ContactManagerError: Error, Equatable, Sendable {
    case contactNotFound
    case preparedContactConflict
    case associationRecoveryRequired
}

struct ContactMutation<Value: Sendable>: Sendable {
    let value: Value
    let book: ContactBook
}

struct ContactImportMutation: Sendable {
    let added: [Contact]
    /// Every persisted imported contact matching this command, including
    /// pre-existing duplicates. Retrying after a later cipher-store failure can
    /// therefore repair missing links instead of becoming a permanent no-op.
    let linkCandidates: [Contact]
    let book: ContactBook
}

struct ContactRemovalMutation: Sendable {
    let removed: [Contact]
    let book: ContactBook
}

struct PreparedMessageContact: Sendable {
    let contact: Contact
    let requiresCommit: Bool
}

struct MessageContactAssociationIntent: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let cipherID: UUID
    let preparedContactID: UUID
    let previousContactID: UUID?
    let requiresContactCommit: Bool

    init(
        cipherID: UUID,
        preparedContactID: UUID,
        previousContactID: UUID?,
        requiresContactCommit: Bool
    ) {
        version = Self.currentVersion
        self.cipherID = cipherID
        self.preparedContactID = preparedContactID
        self.previousContactID = previousContactID
        self.requiresContactCommit = requiresContactCommit
    }
}

struct MessageContactAssociationRecovery: Sendable {
    let intent: MessageContactAssociationIntent
    let book: ContactBook
}

/// Serializes Core contact use cases over the encrypted repository. Cipher
/// association remains an application-use-case concern so contact persistence
/// never needs access to key-bearing cipher values.
actor ContactManager: CoreMessageContactAssociating {
    private let repository: EncryptedContactRepository
    private let contactAccess: any ContactAccessService
    private let clock: any ClockProviding
    private let uuid: any UUIDProviding

    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        repository: EncryptedContactRepository,
        contactAccess: any ContactAccessService,
        clock: any ClockProviding,
        uuid: any UUIDProviding
    ) {
        self.repository = repository
        self.contactAccess = contactAccess
        self.clock = clock
        self.uuid = uuid
    }

    func snapshot() async throws -> ContactBook {
        try await repository.snapshot()
    }

    func authorizationStatus() async -> ContactAuthorizationDTO {
        await contactAccess.authorizationStatus()
    }

    func requestAccess() async throws -> Bool {
        try await contactAccess.requestAccess()
    }

    func fetchSystemContacts() async throws -> [SystemContactDTO] {
        try await contactAccess.fetchContacts()
    }

    func create(_ command: CreateContactCommand) async throws -> ContactMutation<Contact> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await repository.snapshot()
        let contact = Contact(
            id: uuid.nextUUID(),
            displayName: command.displayName,
            phones: command.phoneNumbers,
            emails: command.emailAddresses,
            source: .manual,
            createdAt: clock.now()
        )
        let committed = try await repository.replace(current.adding(contact))
        return ContactMutation(value: contact, book: committed)
    }

    func update(_ command: UpdateContactCommand) async throws -> ContactMutation<Contact> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await repository.snapshot()
        guard var contact = current.contact(id: command.contactID.rawValue) else {
            throw ContactManagerError.contactNotFound
        }
        contact.displayName = command.displayName
        contact.phones = command.phoneNumbers
        contact.emails = command.emailAddresses
        let committed = try await repository.replace(current.updating(contact))
        return ContactMutation(value: contact, book: committed)
    }

    /// Deduplicates imported contacts both against the persisted book and within
    /// this batch, preserving first-seen order and the exact system identifier.
    func importContacts(_ command: ImportContactsCommand) async throws -> ContactImportMutation {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await repository.snapshot()
        var seen = Set(current.contacts.compactMap(\.appleContactID))
        let requestedIdentifiers = Set(command.contacts.map(\.systemIdentifier))
        var added: [Contact] = []
        for source in command.contacts {
            guard seen.insert(source.systemIdentifier).inserted else {
                continue
            }
            added.append(
                Contact(
                    id: uuid.nextUUID(),
                    displayName: source.displayName,
                    phones: source.phoneNumbers,
                    emails: source.emailAddresses,
                    appleContactID: source.systemIdentifier,
                    source: .imported,
                    createdAt: clock.now()
                )
            )
        }

        guard !added.isEmpty else {
            return ContactImportMutation(
                added: [],
                linkCandidates: current.contacts.filter {
                    $0.source == .imported
                        && $0.appleContactID.map(requestedIdentifiers.contains) == true
                },
                book: current
            )
        }
        let committed = try await repository.replace(current.adding(contentsOf: added))
        return ContactImportMutation(
            added: added,
            linkCandidates: committed.contacts.filter {
                $0.source == .imported
                    && $0.appleContactID.map(requestedIdentifiers.contains) == true
            },
            book: committed
        )
    }

    func delete(ids: Set<UUID>) async throws -> ContactRemovalMutation {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await repository.snapshot()
        guard !ids.isEmpty else {
            return ContactRemovalMutation(removed: [], book: current)
        }
        let removed = current.contacts.filter { ids.contains($0.id) }
        let committed = try await repository.replace(current.removing(ids: ids))
        return ContactRemovalMutation(removed: removed, book: committed)
    }

    func deleteAllImported() async throws -> ContactRemovalMutation {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await repository.snapshot()
        let removed = current.contacts.filter { $0.source == .imported }
        guard !removed.isEmpty else {
            return ContactRemovalMutation(removed: [], book: current)
        }
        let committed = try await repository.replace(current.removingImported())
        return ContactRemovalMutation(removed: removed, book: committed)
    }

    func firstContact(displayName: String) async throws -> Contact? {
        try await repository.snapshot().contacts.first { $0.displayName == displayName }
    }

    /// Resolves the legacy exact-name association without committing a new
    /// contact. Message import first makes the cipher association durable, then
    /// commits this prepared contact so an interrupted operation can always be
    /// repaired by unlinking a cipher whose contact is absent from the book.
    func prepareImportedContact(named displayName: String) async throws -> PreparedMessageContact {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await repository.snapshot()
        if let existing = current.contacts.first(where: { $0.displayName == displayName }) {
            return PreparedMessageContact(contact: existing, requiresCommit: false)
        }
        let contact = Contact(
            id: uuid.nextUUID(),
            displayName: displayName,
            source: .imported,
            createdAt: clock.now()
        )
        return PreparedMessageContact(contact: contact, requiresCommit: true)
    }

    /// Persists a small encrypted rollback intent before any cipher association
    /// is changed. A prior unfinished operation must be recovered rather than
    /// overwritten, preserving its original contact association across launch.
    func stageMessageAssociation(
        _ prepared: PreparedMessageContact,
        cipherID: UUID,
        previousContactID: UUID?
    ) async throws -> MessageContactAssociationIntent {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard try await repository.messageAssociationIntent() == nil else {
            throw ContactManagerError.associationRecoveryRequired
        }
        let current = try await repository.snapshot()
        if prepared.requiresCommit {
            guard current.contact(id: prepared.contact.id) == nil,
                  !current.contacts.contains(where: {
                      $0.displayName == prepared.contact.displayName
                  })
            else {
                throw ContactManagerError.preparedContactConflict
            }
        } else {
            guard current.contact(id: prepared.contact.id) != nil else {
                throw ContactManagerError.contactNotFound
            }
        }

        let intent = MessageContactAssociationIntent(
            cipherID: cipherID,
            preparedContactID: prepared.contact.id,
            previousContactID: previousContactID,
            requiresContactCommit: prepared.requiresCommit
        )
        try await repository.storeMessageAssociationIntent(intent)
        return intent
    }

    /// Commits a contact prepared for message association. Existing plans are
    /// returned unchanged; new plans re-read the book immediately before the
    /// write so unrelated committed contacts are never overwritten.
    func commitPreparedImportedContact(
        _ prepared: PreparedMessageContact
    ) async throws -> ContactMutation<Contact> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await repository.snapshot()
        guard prepared.requiresCommit else {
            let contact = current.contact(id: prepared.contact.id) ?? prepared.contact
            return ContactMutation(value: contact, book: current)
        }
        if let existing = current.contact(id: prepared.contact.id) {
            return ContactMutation(value: existing, book: current)
        }
        guard !current.contacts.contains(where: {
            $0.displayName == prepared.contact.displayName
        }) else {
            throw ContactManagerError.preparedContactConflict
        }
        let committed = try await repository.replace(current.adding(prepared.contact))
        return ContactMutation(value: prepared.contact, book: committed)
    }

    /// Rolls back only the contact created for the pending message operation.
    /// The encrypted intent remains until AppService restores the prior cipher
    /// association and completes full-book reconciliation.
    func prepareMessageAssociationRecovery() async throws
        -> MessageContactAssociationRecovery? {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let intent = try await repository.messageAssociationIntent() else {
            return nil
        }
        var current = try await repository.snapshot()
        if intent.requiresContactCommit,
           current.contact(id: intent.preparedContactID) != nil {
            current = try await repository.replace(
                current.removing(ids: [intent.preparedContactID])
            )
        }
        return MessageContactAssociationRecovery(intent: intent, book: current)
    }

    /// Clears exactly the recovered intent, and only after cipher restoration
    /// and full-book reconciliation have succeeded.
    func completeMessageAssociationRecovery(
        _ intent: MessageContactAssociationIntent
    ) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard try await repository.messageAssociationIntent() == intent else {
            throw ContactManagerError.associationRecoveryRequired
        }
        try await repository.removeMessageAssociationIntent()
    }

    /// Success uses the same exact-match clear so a stale task cannot remove a
    /// newer operation's durable recovery record.
    func completeMessageAssociation(
        _ intent: MessageContactAssociationIntent
    ) async throws {
        try await completeMessageAssociationRecovery(intent)
    }

    static func summaries(
        for book: ContactBook,
        linkedCipherCounts: [UUID: Int]
    ) -> [ContactSummary] {
        book.contacts.map { contact in
            ContactSummary(
                id: ContactID(rawValue: contact.id),
                displayName: contact.displayName,
                phoneNumbers: contact.phones,
                emailAddresses: contact.emails,
                source: contact.source == .manual ? .manual : .imported,
                createdAt: contact.createdAt,
                linkedCipherCount: linkedCipherCounts[contact.id, default: 0]
            )
        }
    }

    private func acquireMutationPermit() async {
        if !mutationInProgress {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationPermit() {
        if mutationWaiters.isEmpty {
            mutationInProgress = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }
}
