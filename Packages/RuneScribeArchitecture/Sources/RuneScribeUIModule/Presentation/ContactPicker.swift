#if os(iOS)
import Contacts
import ContactsUI
import Foundation
import RuneScribeContracts
import SwiftUI

enum ContactImporter {
    static func snapshot(from contact: CNContact) -> ContactViewState {
        let name = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ContactViewState(
            displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed",
            phones: contact.phoneNumbers.map(\.value.stringValue),
            emails: contact.emailAddresses.map { String($0.value) },
            systemIdentifier: contact.identifier,
            source: .imported
        )
    }
}

struct ContactPicker: UIViewControllerRepresentable {
    var onPicked: ([ContactViewState]) -> Void

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
        private let onPicked: ([ContactViewState]) -> Void

        init(_ onPicked: @escaping ([ContactViewState]) -> Void) {
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
