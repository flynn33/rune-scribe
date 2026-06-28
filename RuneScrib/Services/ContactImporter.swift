import Foundation
import Contacts

/// Errors from a Contacts import action.
enum ContactImportError: Error { case accessDenied }

/// Bridges Apple Contacts into local `Contact` snapshots: the pure `snapshot(from:)` mapping,
/// the permission-gated `importAll()`, and (on iOS) the out-of-process system `ContactPicker`.
enum ContactImporter {
    /// Snapshots a `CNContact` into a local `Contact` (`.imported`, keeping the identifier
    /// for reference only — never auto-resynced).
    static func snapshot(from cn: CNContact) -> Contact {
        let name = CNContactFormatter.string(from: cn, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Contact(
            displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed",
            phones: cn.phoneNumbers.map { $0.value.stringValue },
            emails: cn.emailAddresses.map { $0.value as String },
            appleContactID: cn.identifier,
            source: .imported
        )
    }

    /// Requests Contacts access and returns snapshots of every contact that has a usable name.
    /// The caller decides what to do with them (import all, or let the user pick a subset).
    /// Works on iOS and macOS. Throws `ContactImportError.accessDenied` if the user denies access.
    static func fetchAll() async throws -> [Contact] {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { throw ContactImportError.accessDenied }
        let keys: [any CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        var out: [Contact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try store.enumerateContacts(with: request) { cn, _ in
            let snap = snapshot(from: cn)
            if snap.displayName != "Unnamed" { out.append(snap) }
        }
        return out
    }
}

#if os(iOS)
import SwiftUI
import ContactsUI

/// The system contact picker — no Contacts permission needed (it runs out-of-process).
/// Returns local snapshots of the chosen contacts. Present via `.sheet`.
struct ContactPicker: UIViewControllerRepresentable {
    var onPicked: ([Contact]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPicked: ([Contact]) -> Void
        init(_ onPicked: @escaping ([Contact]) -> Void) { self.onPicked = onPicked }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onPicked(contacts.map(ContactImporter.snapshot(from:)))
        }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPicked([ContactImporter.snapshot(from: contact)])
        }
    }
}
#endif
