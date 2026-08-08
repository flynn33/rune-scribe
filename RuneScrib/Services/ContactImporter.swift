import Contacts
import Foundation
import RuneScribeContracts
import RuneScribePlatform

enum ContactImportError: Error {
    case accessDenied
}

/// Transitional presentation facade. Permission and store-wide fetch operations
/// are delegated to the value-only Platform adapter; the system picker remains a
/// UI concern until it moves into the UI module.
enum ContactImporter {
    static func snapshot(from contact: CNContact) -> Contact {
        let name = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Contact(
            displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed",
            phones: contact.phoneNumbers.map(\.value.stringValue),
            emails: contact.emailAddresses.map { String($0.value) },
            appleContactID: contact.identifier,
            source: .imported
        )
    }

    static func fetchAll() async throws -> [Contact] {
        let service = SystemContactAccessService()
        guard try await service.requestAccess() else {
            throw ContactImportError.accessDenied
        }
        return try await service.fetchContacts().map { contact in
            Contact(
                displayName: contact.displayName,
                phones: contact.phoneNumbers,
                emails: contact.emailAddresses,
                appleContactID: contact.systemIdentifier,
                source: .imported
            )
        }
    }
}

#if os(iOS)
import ContactsUI
import SwiftUI

struct ContactPicker: UIViewControllerRepresentable {
    var onPicked: ([Contact]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let controller = CNContactPickerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ controller: CNContactPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onPicked: ([Contact]) -> Void

        init(_ onPicked: @escaping ([Contact]) -> Void) {
            self.onPicked = onPicked
        }

        func contactPicker(
            _ picker: CNContactPickerViewController,
            didSelect contacts: [CNContact]
        ) {
            onPicked(contacts.map(ContactImporter.snapshot(from:)))
        }

        func contactPicker(
            _ picker: CNContactPickerViewController,
            didSelect contact: CNContact
        ) {
            onPicked([ContactImporter.snapshot(from: contact)])
        }
    }
}
#endif
