#if os(iOS)
import Contacts
import ContactsUI
import Foundation
import RuneScribeContracts
import SwiftUI

public struct RuntimeContactPicker: View {
    private let onPicked: ([SystemContactDTO]) -> Void

    public init(
        onPicked: @escaping ([SystemContactDTO]) -> Void
    ) {
        self.onPicked = onPicked
    }

    public var body: some View {
        RuntimeNativeContactPicker(onPicked: onPicked)
    }
}

private struct RuntimeNativeContactPicker: UIViewControllerRepresentable {
    let onPicked: ([SystemContactDTO]) -> Void

    func makeCoordinator() -> RuntimeContactPickerCoordinator {
        RuntimeContactPickerCoordinator(onPicked: onPicked)
    }

    func makeUIViewController(
        context: Context
    ) -> CNContactPickerViewController {
        let controller = CNContactPickerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ controller: CNContactPickerViewController,
        context: Context
    ) {}
}

@MainActor
private final class RuntimeContactPickerCoordinator: NSObject,
    @preconcurrency CNContactPickerDelegate
{
    private let onPicked: ([SystemContactDTO]) -> Void

    init(onPicked: @escaping ([SystemContactDTO]) -> Void) {
        self.onPicked = onPicked
    }

    func contactPicker(
        _ picker: CNContactPickerViewController,
        didSelect contacts: [CNContact]
    ) {
        onPicked(contacts.map(RuntimeSystemContactSnapshot.makeDTO(from:)))
    }

    func contactPicker(
        _ picker: CNContactPickerViewController,
        didSelect contact: CNContact
    ) {
        onPicked([RuntimeSystemContactSnapshot.makeDTO(from: contact)])
    }
}

enum RuntimeSystemContactSnapshot {
    static func makeDTO(from contact: CNContact) -> SystemContactDTO {
        let name = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SystemContactDTO(
            systemIdentifier: contact.identifier,
            displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed",
            phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
            emailAddresses: contact.emailAddresses.map { String($0.value) }
        )
    }
}
#endif
