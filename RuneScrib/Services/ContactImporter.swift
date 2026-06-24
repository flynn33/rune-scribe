import Foundation
import Contacts

/// Bridges Apple Contacts into local `Contact` snapshots. This file holds the pure mapping;
/// the system picker (iOS) and "import all" live in the UI/permission layer (added later).
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
}
