import Combine
import Foundation
import RuneScribeContracts

enum ContactPresentationError: Error, Equatable, Sendable {
    case contactNotCreated
}

/// Presentation-only bridge for hosted views. Every mutation delegates to the
/// injected application service and state changes arrive through its snapshot
/// stream; this object owns no persistence or authoritative contact state.
@MainActor
final class ContactManager: ObservableObject {
    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var lastError: String?

    private let applicationService: any RuneScribeApplicationService
    private var systemIdentifiers: [UUID: String] = [:]
    private var observationTask: Task<Void, Never>?

    init(applicationService: any RuneScribeApplicationService) {
        self.applicationService = applicationService
        let stream = applicationService.stateStream()
        observationTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                adopt(snapshot)
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    func add(_ contact: Contact) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.create(contact)
            } catch {
                // `create(_:)` records the presentation-safe failure.
            }
        }
    }

    /// Returns the authoritative persisted identity. Callers that immediately
    /// associate another entity must use this result rather than the temporary
    /// UUID of a view-created `Contact` value.
    func create(_ contact: Contact) async throws -> Contact {
        do {
            if contact.source == .imported {
                let input = SystemContactDTO(
                    systemIdentifier: contact.appleContactID ?? "local-\(contact.id.uuidString)",
                    displayName: contact.displayName,
                    phoneNumbers: contact.phones,
                    emailAddresses: contact.emails
                )
                let added = try await applicationService.importContacts(
                    ImportContactsCommand(contacts: [input])
                )
                rememberSystemIdentifiers(for: added, matching: [input])
                if let summary = added.first {
                    lastError = nil
                    return Contact(summary: summary, systemIdentifier: input.systemIdentifier)
                }
                if let existing = contacts.first(where: {
                    $0.appleContactID == input.systemIdentifier
                        || ($0.source == .imported
                            && $0.displayName == input.displayName
                            && $0.phones == input.phoneNumbers
                            && $0.emails == input.emailAddresses)
                }) {
                    lastError = nil
                    return existing
                }
                throw ContactPresentationError.contactNotCreated
            }

            let summary = try await applicationService.createContact(
                CreateContactCommand(
                    displayName: contact.displayName,
                    phoneNumbers: contact.phones,
                    emailAddresses: contact.emails
                )
            )
            lastError = nil
            return Contact(summary: summary)
        } catch {
            record(error)
            throw error
        }
    }

    func update(_ contact: Contact) {
        let service = applicationService
        Task { @MainActor [weak self] in
            do {
                _ = try await service.updateContact(
                    UpdateContactCommand(
                        contactID: ContactID(rawValue: contact.id),
                        displayName: contact.displayName,
                        phoneNumbers: contact.phones,
                        emailAddresses: contact.emails
                    )
                )
                self?.lastError = nil
            } catch {
                self?.record(error)
            }
        }
    }

    func addImported(_ snapshots: [Contact]) {
        guard !snapshots.isEmpty else { return }
        let inputs = snapshots.map { contact in
            SystemContactDTO(
                systemIdentifier: contact.appleContactID ?? "local-\(contact.id.uuidString)",
                displayName: contact.displayName,
                phoneNumbers: contact.phones,
                emailAddresses: contact.emails
            )
        }
        let service = applicationService
        Task { @MainActor [weak self] in
            do {
                let added = try await service.importContacts(ImportContactsCommand(contacts: inputs))
                self?.rememberSystemIdentifiers(for: added, matching: inputs)
                self?.lastError = nil
            } catch {
                self?.record(error)
            }
        }
    }

    func delete(id: UUID) {
        delete(ids: [id])
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let service = applicationService
        Task { @MainActor [weak self] in
            do {
                try await service.deleteContacts(
                    ids: Set(ids.map(ContactID.init(rawValue:)))
                )
                self?.lastError = nil
            } catch {
                self?.record(error)
            }
        }
    }

    func deleteAllImported() {
        let service = applicationService
        Task { @MainActor [weak self] in
            do {
                try await service.deleteAllImportedContacts()
                self?.lastError = nil
            } catch {
                self?.record(error)
            }
        }
    }

    var importedCount: Int {
        contacts.lazy.filter { $0.source == .imported }.count
    }

    func contact(id: UUID?) -> Contact? {
        id.flatMap { id in contacts.first { $0.id == id } }
    }

    private func adopt(_ snapshot: RuneScribeApplicationSnapshot) {
        let retainedIDs = Set(snapshot.contactLibrary.contacts.map { $0.id.rawValue })
        systemIdentifiers = systemIdentifiers.filter { retainedIDs.contains($0.key) }
        contacts = snapshot.contactLibrary.contacts.map { summary in
            Contact(
                summary: summary,
                systemIdentifier: systemIdentifiers[summary.id.rawValue]
            )
        }
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
            systemIdentifiers[summary.id.rawValue] = remaining.remove(at: index).systemIdentifier
        }
        contacts = contacts.map { contact in
            guard let identifier = systemIdentifiers[contact.id] else { return contact }
            var projected = contact
            projected.appleContactID = identifier
            return projected
        }
    }

    private func record(_ error: Error) {
        if let productError = error as? RuneScribeProductError,
           case .failure(let failure) = productError {
            lastError = "The operation could not be completed (\(failure.code.rawValue))."
        } else {
            lastError = "The operation could not be completed."
        }
    }
}
