# Rune Scribe — Phase 3: Contacts & Per-Contact Ciphers

**Status:** Draft for review
**Date:** 2026-06-24
**Phase:** 3 of 4 (Phases 1 — encryption — and 2 — font package + universal links — are merged.)

## Programme context

1. Real encryption + new cipher model — merged.
2. Font in the cipher package + https Universal-Link sharing — merged.
3. **This phase:** organize ciphers by person — link a cipher to a contact, with optional
   Apple Contacts import, all encrypted at rest and device-only.
4. Apple Messages integration (prefilled compose; auto-share the cipher on the first message
   to a contact).

## Goals

- A cipher can optionally be **linked to a contact**, so the user can organize and identify
  ciphers by person.
- Contacts come in three ways: the **iOS system picker** (one or several, no permission),
  an explicit **"Import all"** (full Contacts permission), or **manual** people — and the app
  is fully usable with Contacts denied.
- A **one-time** prompt offers contacts import; if declined, import stays available in
  **Settings**.
- All contact data and cipher↔contact associations are **encrypted at rest**, never uploaded,
  never logged.
- **Safety:** contacts are snapshots — editing/deleting a person in Apple Contacts never
  touches a cipher or its key; unlinking or deleting an in-app contact never deletes a cipher;
  reassigning a cipher requires explicit confirmation.

## Non-goals (later / out of scope)

- Apple Messages send/compose (Phase 4); auto-share the cipher on the first message (Phase 4).
- Using the contact to *route which cipher decrypts a received message* — Phase 1's try-all
  stands; the contact link is organizational only.
- Live two-way Apple Contacts sync. Contacts are one-time snapshots.

## Data model

- **`Contact`** — `id: UUID`, `displayName: String`, `phones: [String]`, `emails: [String]`,
  `appleContactID: String?` (the `CNContact` identifier, **reference-only**, for a possible
  future manual re-sync), `source: .manual | .imported`, `createdAt: Date`. `Codable`,
  `Equatable`, `Identifiable`.
- **`Cipher` gains `contactID: UUID?`** (Codable **default `nil`** — Phase-1/2 ciphers load
  unchanged via the existing custom decoder). A cipher links to **at most one** contact (a new
  cipher is made per contact); a contact owns **zero or more** ciphers; a cipher may have none.

## Storage & encryption at rest

- **Contacts** persist as a single **AES-GCM-encrypted file** in app-support
  (`RuneScribContacts/contacts.enc`), encrypted with the **same Keychain-held symmetric key**
  the cipher library already uses. A `ContactBook { version, contacts: [Contact] }` is the
  encrypted payload.
- The cipher↔contact **link** (`contactID`) lives on the `Cipher`, inside the existing
  Keychain-encrypted `CipherLibrary` blob.
- **Testability:** `ContactStore`'s encryption is parameterized by an injected `SymmetricKey`
  (production passes the Keychain key; tests pass a throwaway key), so the encrypted
  save/reload round-trip is unit-testable **without touching the Keychain** (no auth prompt in
  headless tests, consistent with the Phase-1 test gate). `ContactStore` does no Keychain I/O
  at init.
- Contact PII and associations are never written to logs and never leave the device.

## Bringing contacts in

- **Pick (iOS): `CNContactPickerViewController`** (SwiftUI `UIViewControllerRepresentable`
  wrapper) — choose one or several; **no Contacts-permission prompt** (it runs out-of-process).
  Each picked `CNContact` is snapshotted to a `Contact` (`.imported`, with `appleContactID`).
- **Import all:** `CNContactStore.requestAccess(for: .contacts)`; on grant, enumerate contacts
  (with a non-empty name) and snapshot them. Works on iOS **and** macOS.
- **Manual:** create a `Contact` (`.manual`) with a name + optional phone/email, no Contacts
  access at all.
- The Contacts **permission is requested only on an explicit Contacts action** (Import all).
  The picker needs no permission. `NSContactsUsageDescription` is added to both Info.plists; the
  **sandboxed macOS** target also needs the `com.apple.security.personal-information.addressbook`
  entitlement to read Contacts (iOS needs only the usage string).

## One-time import prompt

- A flag `@AppStorage("rf.contacts.importPrompted")` (default `false`). The **first** time the
  user opens the Cipher Library (the natural place to organize ciphers) with the flag `false`,
  a one-time sheet offers: **Import from Contacts** / **Add manually** / **Not now**. The flag
  is set to `true` once the sheet has been shown (whatever the choice), so it **never appears
  again**.
- Whether accepted, declined, or dismissed, contacts import is **always available later** in
  **Settings → Contacts** (Import from Contacts, Import all, Manage contacts).

## Safety rules (the heart of the scope)

- Contacts are **snapshots**: `appleContactID` is reference-only; the app never re-reads or
  overwrites a `Contact` from Apple Contacts automatically. So **deleting or editing the Apple
  contact never changes a `Contact` or any cipher**.
- `contactID` is metadata: setting/clearing it **never alters `keyMaterial`**.
- Removing a cipher's link (`contactID = nil`) **keeps the cipher**.
- Deleting an in-app `Contact` **unlinks** its ciphers (sets their `contactID = nil`) but
  **never deletes them**.
- Reassigning a cipher that is **already linked** to contact A so it points to contact B
  requires an **explicit confirmation** — no silent reassignment.

## UI

- **Contacts manager** (list contacts; add manual; pick / import all; edit; delete with an
  "unlinks its ciphers, keeps them" warning) — reachable from **Settings**.
- In **`CipherLibraryView`**, each cipher card shows its linked contact (or "No contact") with
  a control to pick / change / remove (a change of an existing link confirms first).
- **`ContentView`** (compose) shows the active cipher's linked contact ("To: <name>") so the
  user knows who they're writing to before sending.
- **Settings → Contacts** section — always present, so import works even if the one-time prompt
  was declined.

## Components (new / changed)

- **`Contact`** (Model) — the snapshot.
- **`ContactBook`** (Model) — `{ version, contacts }` + pure mutations (add / update / remove),
  unit-testable.
- **`ContactStore`** (Service) — encrypted-file load/save (injected `SymmetricKey`), CRUD;
  `.shared` uses the Keychain key in production.
- **`ContactImporter`** (Service) — `CNContactPicker` wrapper (iOS), `import-all` via
  `CNContactStore` + permission, and `CNContact → Contact` snapshot mapping.
- **`Cipher.contactID`** (`UUID?`, default `nil`).
- **`KeyManager`** — `link(cipherID:contactID:)`, `unlink(cipherID:)`,
  `reassign(cipherID:to:)` (the confirmed path); and on contact delete, unlink that contact's
  ciphers.
- **Views** — Contacts manager, the library cipher-card contact control, the compose "To:"
  line, the Settings → Contacts section, and the one-time prompt.
- **Info.plist / entitlements** — `NSContactsUsageDescription` (both platforms) +
  `com.apple.security.personal-information.addressbook` on the sandboxed macOS target.

## Testing

- `Contact` Codable round-trip; `ContactBook` pure mutations (add / update / remove).
- `ContactStore` encrypted save → reload round-trip **with an injected key** (no Keychain).
- `Cipher.contactID` Codable **default nil**: a Phase-1/2-encoded cipher (no `contactID`) loads
  with `nil`.
- Link → unlink keeps the cipher; deleting a contact **unlinks all its ciphers and keeps them**.
- **Snapshot independence:** a `Contact` with an `appleContactID`, after a simulated
  Apple-contact change/delete, is unchanged (no auto-resync) and the linked cipher's
  `keyMaterial` is untouched.
- Reassigning an already-linked cipher goes only through the confirmed `reassign` path.
- `CNContact → Contact` snapshot mapping (name / phones / emails) via a constructed
  `CNMutableContact`.
- (Permission prompts, the system picker, and the one-time-prompt UI are build-verified +
  manual, not unit-tested.)

## Risks / decisions

- **macOS:** `CNContactPickerViewController` is **iOS-only**, so macOS gets **manual + Import
  all** (full-access enumeration works on macOS) but no no-permission system picker. The core
  (manual contacts, associations, snapshots, encrypted storage) works on both platforms.
- **Contacts framework** requires `NSContactsUsageDescription` (Info.plist / build).
- **Keychain in tests:** avoided by injecting `ContactStore`'s key (see Storage), so the
  headless suite never triggers a Keychain prompt.
- **Entitlements:** iOS needs only `NSContactsUsageDescription`. **Sandboxed macOS** also needs
  `com.apple.security.personal-information.addressbook`. This is a *sandbox* entitlement (not a
  managed capability like Phase 2's associated-domains), so it should not require a provisioning
  profile or break the ad-hoc test build — to be confirmed during implementation; if it does,
  apply the Phase-2 `CODE_SIGN_ENTITLEMENTS=""` fallback for the test build.
