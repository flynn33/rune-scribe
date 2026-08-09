import Contacts
import Foundation
import RuneScribeContracts

/// Value-only bridge to Apple Contacts. It requests exactly the fields used by
/// the shipping import flow and excludes contacts without a usable full name.
public struct SystemContactAccessService: ContactAccessService, Sendable {
    private let operations: ContactOperations

    public init() {
        operations = .system
    }

    init(operations: ContactOperations) {
        self.operations = operations
    }

    public func authorizationStatus() async -> ContactAuthorizationDTO {
        switch operations.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        }
    }

    public func requestAccess() async throws -> Bool {
        try await operations.requestAccess()
    }

    public func fetchContacts() async throws -> [SystemContactDTO] {
        try operations.fetchContacts().compactMap { contact in
            let displayName = contact.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let displayName,
                  !displayName.isEmpty,
                  displayName != "Unnamed"
            else { return nil }
            return SystemContactDTO(
                systemIdentifier: contact.systemIdentifier,
                displayName: displayName,
                phoneNumbers: contact.phoneNumbers,
                emailAddresses: contact.emailAddresses
            )
        }
    }
}

enum ContactAuthorizationStatus: Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
}

struct ContactRecord: Sendable {
    let systemIdentifier: String
    let displayName: String?
    let phoneNumbers: [String]
    let emailAddresses: [String]
}

struct ContactOperations: Sendable {
    let authorizationStatus: @Sendable () -> ContactAuthorizationStatus
    let requestAccess: @Sendable () async throws -> Bool
    let fetchContacts: @Sendable () throws -> [ContactRecord]

    static let system = ContactOperations(
        authorizationStatus: {
            Self.authorizationStatus(from: CNContactStore.authorizationStatus(for: .contacts))
        },
        requestAccess: {
            try await CNContactStore().requestAccess(for: .contacts)
        },
        fetchContacts: {
            let store = CNContactStore()
            let keys: [any CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var contacts: [ContactRecord] = []
            try store.enumerateContacts(with: request) { contact, _ in
                contacts.append(
                    ContactRecord(
                        systemIdentifier: contact.identifier,
                        displayName: CNContactFormatter.string(from: contact, style: .fullName),
                        phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
                        emailAddresses: contact.emailAddresses.map { String($0.value) }
                    )
                )
            }
            return contacts
        }
    )

    private static func authorizationStatus(
        from status: CNAuthorizationStatus
    ) -> ContactAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        default:
            #if os(iOS)
            if #available(iOS 18.0, *), status == .limited {
                return .limited
            }
            #endif
            return .denied
        }
    }
}
