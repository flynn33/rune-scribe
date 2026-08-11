import Foundation
import RuneScribeContracts

enum ContactPresentationError: Error, Equatable, Sendable {
    case contactNotCreated
}

extension RuneScribeUISession {
    func addContact(_ contact: ContactViewState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await createContact(contact)
            } catch {
                recordPresentationError(error)
            }
        }
    }

    @discardableResult
    func createContact(_ contact: ContactViewState) async throws -> ContactViewState {
        if contact.source == .imported {
            let systemContact = SystemContactDTO(
                systemIdentifier: contact.systemIdentifier ?? "local-\(contact.id.uuidString)",
                displayName: contact.displayName,
                phoneNumbers: contact.phones,
                emailAddresses: contact.emails
            )
            let imported = try await importContacts([ContactViewState(systemContact: systemContact)])
            if let result = imported.first {
                return result
            }
            if let existing = contacts.first(where: {
                $0.systemIdentifier == systemContact.systemIdentifier
                    || ($0.source == .imported
                        && $0.displayName == systemContact.displayName
                        && $0.phones == systemContact.phoneNumbers
                        && $0.emails == systemContact.emailAddresses)
            }) {
                return existing
            }
            throw ContactPresentationError.contactNotCreated
        }

        let summary = try await perform {
            try await requireApplicationClient().createContact(
                CreateContactCommand(
                    displayName: contact.displayName,
                    phoneNumbers: contact.phones,
                    emailAddresses: contact.emails
                )
            )
        }
        return ContactViewState(summary: summary)
    }

    @discardableResult
    func updateContact(_ contact: ContactViewState) async throws -> ContactViewState {
        let summary = try await perform {
            try await requireApplicationClient().updateContact(
                UpdateContactCommand(
                    contactID: ContactID(rawValue: contact.id),
                    displayName: contact.displayName,
                    phoneNumbers: contact.phones,
                    emailAddresses: contact.emails
                )
            )
        }
        return ContactViewState(
            summary: summary,
            systemIdentifier: contact.systemIdentifier
        )
    }

    func deleteContact(id: UUID) async throws {
        try await deleteContacts(ids: [id])
    }

    func deleteContacts(ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        try await perform {
            try await requireApplicationClient().deleteContacts(
                ids: Set(ids.map(ContactID.init(rawValue:)))
            )
        }
    }

    func deleteAllImportedContacts() async throws {
        try await perform {
            try await requireApplicationClient().deleteAllImportedContacts()
        }
    }

    @discardableResult
    func importContacts(
        _ contacts: [ContactViewState]
    ) async throws -> [ContactViewState] {
        guard !contacts.isEmpty else { return [] }
        let inputs = contacts.map { contact in
            SystemContactDTO(
                systemIdentifier: contact.systemIdentifier ?? "local-\(contact.id.uuidString)",
                displayName: contact.displayName,
                phoneNumbers: contact.phones,
                emailAddresses: contact.emails
            )
        }
        let summaries = try await perform {
            try await requireApplicationClient().importContacts(
                ImportContactsCommand(contacts: inputs)
            )
        }
        rememberSystemIdentifiers(for: summaries, matching: inputs)
        return summaries.map { summary in
            ContactViewState(
                summary: summary,
                systemIdentifier: contactSystemIdentifiers[summary.id.rawValue]
            )
        }
    }

    func fetchSystemContacts() async throws -> [ContactViewState] {
        let contacts = try await perform {
            try await requireApplicationClient().requestSystemContacts()
        }
        return contacts.map(ContactViewState.init(systemContact:))
    }

    private func rememberSystemIdentifiers(
        for summaries: [ContactSummary],
        matching inputs: [SystemContactDTO]
    ) {
        var remaining = inputs
        for summary in summaries {
            guard let index = remaining.firstIndex(where: {
                $0.displayName == summary.displayName
                    && $0.phoneNumbers == summary.phoneNumbers
                    && $0.emailAddresses == summary.emailAddresses
            }) else { continue }
            contactSystemIdentifiers[summary.id.rawValue] = remaining.remove(at: index).systemIdentifier
        }

        for input in remaining {
            guard let existing = contacts.first(where: {
                $0.source == .imported
                    && $0.displayName == input.displayName
                    && $0.phones == input.phoneNumbers
                    && $0.emails == input.emailAddresses
            }) else { continue }
            contactSystemIdentifiers[existing.id] = input.systemIdentifier
        }
        objectWillChange.send()
    }
}
