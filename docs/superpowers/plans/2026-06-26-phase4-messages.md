# Rune Scribe — Phase 4: Apple Messages Send & Key Auto-Exchange — Implementation Plan

> **Historical plan.** Publication-sensitive bridge identifiers have been neutralized.
> Do not execute its site commands; current deployment records are authoritative. This
> historical snapshot records version 1.0.38 build 38. Hardware-only procedures in this plan
> are owner-operated optional observations outside Agent Coding scope and have no
> acceptance, completion, blocker, residual-work, PASS/FAIL, or pull-request-readiness
> effect.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send an encrypted Rune Scribe message over Apple Messages / the native Share sheet, auto-exchanging the cipher key on the first message to a contact, with a tap-to-open receive flow that imports the key, decrypts, and shows the message — falling back to the website for recipients without the app.

**Architecture:** Reuses the shipped Phase 1–3 stack unchanged — `MessageService` (AES-GCM `MessageCryptor` → `MessageEnvelope` → `RuneCodec` decorative runes), the `Cipher` pre-shared-key model, `ContactManager`, and the `CipherSharePayload` + `ImportCoordinator` deep-link rail. Phase 4 adds a parallel **message** rail: a `MessageSharePayload` wire format (envelope + optional embedded cipher) carried on an `https://ravenforgesoftware.com/rune-scribe/m` Universal Link, a `MessageCoordinator` intake mirroring `ImportCoordinator`, a `ReceivedMessageView`, a Share/iMessage send UI, per-contact key auto-assignment on contact import, a key-delivery marker so the key is embedded only once, and the `associated-domains` entitlement + an `apple-app-site-association` file on the website.

**Tech Stack:** Swift 6, SwiftUI, CryptoKit (AES-GCM), MessageUI (`MFMessageComposeViewController`, iOS only), ContactsUI, XcodeGen, XCTest. macOS 15+/iOS 17+.

**Spec:** `docs/superpowers/specs/2026-06-25-runescribe-phase4-messages-design.md`

---

## File structure

**New files (app):**
- `RuneScrib/Models/MessageSharePayload.swift` — message wire format (envelope + optional embedded `CipherSharePayload`; link + file forms; version + checksum). [Task 4]
- `RuneScrib/Services/MessageCoordinator.swift` — `@MainActor` intake: decode → import embedded cipher → decrypt → publish `PendingMessage` → auto-associate to a contact. [Task 5]
- `RuneScrib/Services/LinkRouter.swift` — classify an inbound URL as cipher vs message and route it. [Task 6]
- `RuneScrib/Services/MessageSend.swift` — build a `MessageSharePayload` for a composed message + the embed-key decision. [Task 8]
- `RuneScrib/Views/ReceivedMessageView.swift` — decrypted-incoming-message sheet (sender + text + Reply). [Task 7]
- `RuneScrib/Views/Components/MessageComposeView.swift` — iOS `MFMessageComposeViewController` wrapper. [Task 8]

**Modified files (app):**
- `RuneScrib/Models/Cipher.swift` — `+ var delivered: Bool` (Codable-safe). [Task 1]
- `RuneScrib/Models/CipherLibrary.swift` — `+ markingDelivered`, `+ addingWithoutActivating`. [Task 1]
- `RuneScrib/Services/KeyManager.swift` — `+ markDelivered`, `+ ensureLinkedCipher(forImportedContact:)`. [Tasks 1, 2]
- `RuneScrib/Services/ContactManager.swift` — `addImported` auto-generates a linked cipher per new contact. [Task 2]
- `RuneScrib/Services/MessageService.swift` — `+ read(envelope:tryingCiphers:)`. [Task 3]
- `RuneScrib/App/RuneScribApp.swift`, `RuneScrib/App/AppDelegate.swift` — route inbound URLs via `LinkRouter`; inject `MessageCoordinator`. [Task 6]
- `RuneScrib/Views/RootView.swift` — host `ReceivedMessageView` on `MessageCoordinator.pending` (gated behind splash/lock). [Task 7]
- `RuneScrib/Views/ContentView.swift` — Share (both platforms) + Send-via-iMessage (iOS) in the result row; key-included indicator. [Task 8]
- `Config/RuneScrib-iOS.entitlements`, `Config/RuneScrib-macOS.entitlements` — `+ associated-domains: applinks:ravenforgesoftware.com`. [Task 9]

**Cross-repo (website, site bridge):**
- `https://ravenforgesoftware.com/.well-known/apple-app-site-association` + `/rune-scribe/` no-app fallback. [Task 10]

**Order:** Tasks 1→8 are app code in dependency order (model → service → wire → intake → routing → views → send). Tasks 9–10 (entitlement + website) can land in parallel; end-to-end tap-to-open is verified on device after 6+9+10.

---
### Task 1: Cipher delivered marker + CipherLibrary mutations + KeyManager.markDelivered

Threads the per-cipher key-delivery marker through the whole model stack so later tasks can decide whether to embed a key in an outgoing message and stop re-sending it once delivered. `Cipher.delivered` is added in a Codable-evolution-safe way (old ciphers with no `delivered` key decode to `false`), `CipherLibrary` gains the two pure mutations the import/send flows need, and `KeyManager` exposes the `markDelivered` mutator.

**Files:**
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Models/Cipher.swift` — add stored prop (after `contactID`, ~line 37), memberwise-init param + assignment (~lines 43-56), `CodingKeys` (~line 59), `init(from:)` decode (~line 73-74).
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Models/CipherLibrary.swift` — add `markingDelivered` + `addingWithoutActivating` to the `extension CipherLibrary` (after `unlinkingContact`, ~line 95).
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/KeyManager.swift` — add `markDelivered` to the `// MARK: - Mutations` block (after `unlinkContact`, ~line 154).
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/CipherTests.swift` — append a `delivered` test extension.
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/CipherLibraryTests.swift` — append the two mutation tests.

No new files are created in this task, so `xcodegen generate` is not required.

---

1. [ ] **Write failing tests for `Cipher.delivered` (round-trip + old-cipher compat).** Append to `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/CipherTests.swift`:
   ```swift
   extension CipherTests {
       func testNewCipherIsNotDelivered() {
           XCTAssertFalse(Cipher.generated(label: "x").delivered)
       }

       func testDeliveredSurvivesCodableRoundTrip() throws {
           var c = Cipher.generated(label: "Bob")
           c.delivered = true
           let data = try JSONEncoder().encode(c)
           let back = try JSONDecoder().decode(Cipher.self, from: data)
           XCTAssertTrue(back.delivered)
           XCTAssertEqual(c, back)
       }

       func testLegacyCipherWithoutDeliveredDecodesFalse() throws {
           // Simulate a Phase-1/2/3 stored cipher: JSON object with no `delivered` key.
           let json = """
           {"id":"\(UUID().uuidString)","label":"old","origin":"generated","createdAt":0,
            "formatVersion":1,"publicID":"AAAAAAAAAAA=","keyMaterial":"\(Data(repeating:1,count:32).base64EncodedString())",
            "decorativeMapping":[\((0..<32).map(String.init).joined(separator: ","))]}
           """
           XCTAssertFalse(try JSONDecoder().decode(Cipher.self, from: Data(json.utf8)).delivered)
       }
   }
   ```

2. [ ] **Run — expect FAIL** (`delivered` is not yet a member of `Cipher`, so the test target fails to compile):
   ```
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
     -only-testing:RuneScribTests/CipherTests test 2>&1 | tail -20
   ```
   Expected: compile error `value of type 'Cipher' has no member 'delivered'` → `** TEST FAILED **`.

3. [ ] **Implement `Cipher.delivered` (all four evolution sites).** In `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Models/Cipher.swift`:

   (a) Add the stored property immediately after `contactID` (~line 37):
   ```swift
       var contactID: UUID?

       /// Whether this cipher's key has been delivered to its linked contact at least once.
       /// Drives Phase-4 key auto-exchange: a key is embedded in an outgoing message only while
       /// this is false. Codable default false so pre-Phase-4 ciphers load unchanged.
       var delivered: Bool
   ```

   (b) Add the memberwise-init parameter (defaulted) and assignment. Change the signature line and body:
   ```swift
       init(id: UUID = UUID(), label: String, origin: Origin, createdAt: Date = Date(),
            formatVersion: Int = Cipher.currentVersion, publicID: Data, keyMaterial: Data,
            decorativeMapping: [Int], fontRef: FontRef = .bundled, contactID: UUID? = nil,
            delivered: Bool = false) {
           self.id = id
           self.label = label
           self.origin = origin
           self.createdAt = createdAt
           self.formatVersion = formatVersion
           self.publicID = publicID
           self.keyMaterial = keyMaterial
           self.decorativeMapping = decorativeMapping
           self.fontRef = fontRef
           self.contactID = contactID
           self.delivered = delivered
       }
   ```

   (c) Add `delivered` to `CodingKeys` (~line 59):
   ```swift
       private enum CodingKeys: String, CodingKey {
           case id, label, origin, createdAt, formatVersion, publicID, keyMaterial, decorativeMapping, fontRef, contactID, delivered
       }
   ```

   (d) Add the evolution-safe decode in `init(from:)`, after the `contactID` line (~line 73):
   ```swift
           contactID = try c.decodeIfPresent(UUID.self, forKey: .contactID)
           delivered = try c.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
   ```

   `Cipher.generated(label:)` needs no change — it uses the memberwise init, which now defaults `delivered` to `false`.

4. [ ] **Run — expect PASS:**
   ```
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
     -only-testing:RuneScribTests/CipherTests test 2>&1 | tail -20
   ```
   Expected: `** TEST SUCCEEDED **`.

5. [ ] **Commit:**
   ```
   git add RuneScrib/Models/Cipher.swift RuneScribTests/CipherTests.swift
   git commit -m "feat: add Codable-safe delivered marker to Cipher"
   ```

6. [ ] **Write failing tests for the `CipherLibrary` mutations.** Append to `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/CipherLibraryTests.swift`:
   ```swift
   extension CipherLibraryTests {

       func testMarkingDeliveredFlipsOnlyTheTarget() {
           let a = Cipher.generated(label: "A")
           let b = Cipher.generated(label: "B")
           let library = CipherLibrary(ciphers: [a, b], activeID: a.id)

           let after = library.markingDelivered(cipherID: b.id)

           XCTAssertFalse(after.ciphers.first { $0.id == a.id }!.delivered)
           XCTAssertTrue(after.ciphers.first { $0.id == b.id }!.delivered)
           XCTAssertEqual(after.activeID, a.id, "marking delivered must not change the active cipher")
       }

       func testMarkingDeliveredUnknownIDIsNoOp() {
           let a = Cipher.generated(label: "A")
           let library = CipherLibrary(ciphers: [a], activeID: a.id)
           XCTAssertEqual(library.markingDelivered(cipherID: UUID()), library)
       }

       func testAddingWithoutActivatingAppendsAndKeepsActive() {
           let a = Cipher.generated(label: "A")
           let b = Cipher.generated(label: "B")
           let library = CipherLibrary(ciphers: [a], activeID: a.id)

           let after = library.addingWithoutActivating(b)

           XCTAssertEqual(after.ciphers.map(\.id), [a.id, b.id])
           XCTAssertEqual(after.activeID, a.id, "must not steal the active selection")
       }

       func testAddingWithoutActivatingSeedsActiveWhenNil() {
           let a = Cipher.generated(label: "A")
           let library = CipherLibrary(ciphers: [], activeID: nil)
           let after = library.addingWithoutActivating(a)
           XCTAssertEqual(after.activeID, a.id, "first cipher into an empty library becomes active")
       }
   }
   ```

7. [ ] **Run — expect FAIL** (the two methods don't exist yet → compile error):
   ```
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
     -only-testing:RuneScribTests/CipherLibraryTests test 2>&1 | tail -20
   ```
   Expected: `value of type 'CipherLibrary' has no member 'markingDelivered'` → `** TEST FAILED **`.

8. [ ] **Implement the two pure mutations.** In `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Models/CipherLibrary.swift`, add to the bottom of `extension CipherLibrary`, after `unlinkingContact` (~line 95, before the closing `}`):
   ```swift
       /// Marks the cipher with `cipherID` as delivered (no-op if not found). Touches nothing else.
       func markingDelivered(cipherID: UUID) -> CipherLibrary {
           var copy = self
           if let i = copy.ciphers.firstIndex(where: { $0.id == cipherID }) { copy.ciphers[i].delivered = true }
           return copy
       }

       /// Appends a cipher without changing the active selection. If the library had no active
       /// cipher (empty library), the new one becomes active so the invariant holds.
       func addingWithoutActivating(_ cipher: Cipher) -> CipherLibrary {
           var copy = self
           copy.ciphers.append(cipher)
           if copy.activeID == nil { copy.activeID = cipher.id }
           return copy
       }
   ```

9. [ ] **Run — expect PASS:**
   ```
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
     -only-testing:RuneScribTests/CipherLibraryTests test 2>&1 | tail -20
   ```
   Expected: `** TEST SUCCEEDED **`.

10. [ ] **Commit:**
    ```
    git add RuneScrib/Models/CipherLibrary.swift RuneScribTests/CipherLibraryTests.swift
    git commit -m "feat: add markingDelivered and addingWithoutActivating to CipherLibrary"
    ```

11. [ ] **Implement `KeyManager.markDelivered` (build-verified — KeyManager is the @MainActor singleton wired through the Keychain, not unit-tested per prior phases).** In `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/KeyManager.swift`, add inside the `// MARK: - Mutations` block, after `unlinkContact(_:)` (~line 154):
    ```swift
        /// Marks the cipher with `cipherID` as having had its key delivered, then persists.
        /// Idempotent and never touches key material. Called by the send flow after a message
        /// that embedded this cipher's key has been handed off to Messages.
        func markDelivered(cipherID: UUID) {
            library = library.markingDelivered(cipherID: cipherID)
            persist()
        }
    ```

12. [ ] **Build-verify the whole macOS target compiles with the new mutator** (also re-runs the unit tests, which must still pass):
    ```
    xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' test 2>&1 | tail -20
    ```
    Expected: `** TEST SUCCEEDED **`. Manual verification checklist:
    - `markDelivered` follows the exact `library = library.<pureMutation>(...); persist()` shape used by every other mutator in the file (compare `setContact`/`unlinkContact`).
    - `delivered` flag persists across a relaunch: it rides inside the AES-GCM-encrypted `CipherLibrary` JSON via the new `CodingKeys`/`init(from:)` entries, so no Keychain or `persist` change is needed.

13. [ ] **Commit:**
    ```
    git add RuneScrib/Services/KeyManager.swift
    git commit -m "feat: add KeyManager.markDelivered mutator"
    ```

---

### Task 2: Per-contact key auto-assign on import

When a contact is imported, the app should silently generate one cipher for that person and link it — but *not* steal the active selection, and *not* fire on a manual `add(_:)`. `ContactManager.addImported(_:)` is the single chokepoint (used by both the picker and import-all), so the auto-assign hangs off it. `KeyManager.ensureLinkedCipher(forImportedContact:)` does the idempotent generate-and-link, returning the new cipher or `nil` if the contact already has one.

**Dependency:** This task uses `CipherLibrary.addingWithoutActivating(_:)`, which is a **Task 1** deliverable (append; set `activeID` only if currently `nil`). Task 1 must land first. Everything else here is self-contained.

**Files:**
- Create `RuneScribTests/KeyManagerLinkTests.swift` — unit tests for `ensureLinkedCipher(forImportedContact:)` against the `KeyManager.shared` singleton (asserts on counts relative to a fresh contact id, so it is insensitive to singleton/Keychain state).
- Create `RuneScribTests/ContactManagerTests.swift` — unit tests for the `addImported` → auto-assign wiring and the `add(_:)` no-op, using an injected isolated `ContactStore` + `KeyManager.shared`.
- Modify `RuneScrib/Services/KeyManager.swift` — add `ensureLinkedCipher(forImportedContact:)` (after `ciphers(forContact:)`, ~line 157, in the `// MARK: - Mutations` region).
- Modify `RuneScrib/Services/ContactManager.swift` — in `addImported(_:)` (~lines 25-37), after the successful `persist(...)`, call `ensureLinkedCipher` for every snapshot that was actually added.

Steps:

- [ ] **1. Write failing test — KeyManager generates exactly one linked, non-activating cipher.** Create `RuneScribTests/KeyManagerLinkTests.swift`. `ensureLinkedCipher` does not exist yet, so this fails to compile (an expected red).

```swift
import XCTest
@testable import RuneScrib

@MainActor
final class KeyManagerLinkTests: XCTestCase {

    private var keyManager: KeyManager { KeyManager.shared }

    func testEnsureLinkedCipherGeneratesOneLinkedNonActiveCipher() {
        let contact = Contact(displayName: "Brynjar", appleContactID: "abc", source: .imported)
        let priorActive = keyManager.activeCipher?.id

        let created = keyManager.ensureLinkedCipher(forImportedContact: contact)

        let cipher = try! XCTUnwrap(created, "a contact with no ciphers must get one")
        XCTAssertEqual(cipher.label, "Brynjar", "the cipher is labelled with the contact's name")
        XCTAssertEqual(cipher.contactID, contact.id, "the cipher is linked to the contact")
        XCTAssertEqual(cipher.origin, .generated, "auto-assigned ciphers are generated, not imported")
        XCTAssertEqual(keyManager.ciphers(forContact: contact.id).map(\.id), [cipher.id],
                       "exactly one cipher is linked to this contact")
        XCTAssertNotEqual(keyManager.activeCipher?.id, cipher.id,
                          "auto-assign must NOT steal the active selection")
        XCTAssertEqual(keyManager.activeCipher?.id, priorActive,
                       "the active cipher is unchanged by auto-assign")
    }
}
```

- [ ] **2. Run — expect compile failure.** `xcodegen generate` first (a new test file was added; sources are globbed), then:
  ```
  xcodegen generate
  xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/KeyManagerLinkTests test 2>&1 | tail -20
  ```
  Expect a build error: `value of type 'KeyManager' has no member 'ensureLinkedCipher'`.

- [ ] **3. Minimal impl — add `ensureLinkedCipher` to KeyManager.** In `RuneScrib/Services/KeyManager.swift`, immediately after the `ciphers(forContact:)` method (~line 157):

```swift
    /// Ensures an imported contact has at least one linked cipher, generating and linking one
    /// (without changing the active selection) when it has none. Returns the new cipher, or
    /// `nil` when the contact already has a linked cipher. Import-only by design.
    @discardableResult
    func ensureLinkedCipher(forImportedContact contact: Contact) -> Cipher? {
        guard ciphers(forContact: contact.id).isEmpty else { return nil }
        var cipher = Cipher.generated(label: cleanLabel(contact.displayName, fallback: "Imported Cipher"))
        cipher.contactID = contact.id
        library = library.addingWithoutActivating(cipher)
        persist()
        return cipher
    }
```
(`Cipher.contactID` is a `var`; `cleanLabel` is the existing private helper that trims + caps at 40 chars; `addingWithoutActivating` is the Task 1 library mutation that appends and only sets `activeID` when nil.)

- [ ] **4. Run — expect pass.**
  ```
  xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/KeyManagerLinkTests test 2>&1 | tail -20
  ```
  Expect `** TEST SUCCEEDED **`.

- [ ] **5. Write failing test — re-ensuring the same contact is idempotent.** Append to `KeyManagerLinkTests` via an extension. `ensureLinkedCipher` now compiles, so this is a behavioural red until the guard is exercised (it already is from step 3, so this should pass once added — keep it as a regression guard and confirm green in step 6).

```swift
extension KeyManagerLinkTests {
    func testEnsureLinkedCipherIsIdempotentPerContact() {
        let contact = Contact(displayName: "Hilde", appleContactID: "dup-1", source: .imported)

        let first = keyManager.ensureLinkedCipher(forImportedContact: contact)
        XCTAssertNotNil(first, "first ensure creates the cipher")

        let second = keyManager.ensureLinkedCipher(forImportedContact: contact)
        XCTAssertNil(second, "a contact that already has a cipher gets no second one")

        XCTAssertEqual(keyManager.ciphers(forContact: contact.id).count, 1,
                       "still exactly one cipher linked after re-ensuring")
    }
}
```

- [ ] **6. Run — expect pass.**
  ```
  xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/KeyManagerLinkTests test 2>&1 | tail -20
  ```
  Expect `** TEST SUCCEEDED **` (both methods).

- [ ] **7. Commit the KeyManager half.**
  ```
  git add RuneScrib/Services/KeyManager.swift RuneScribTests/KeyManagerLinkTests.swift RuneScrib.xcodeproj
  git commit -m "feat: auto-assign a linked cipher for imported contacts"
  ```
  (No AI attribution — a CI guard rejects it.)

- [ ] **8. Write failing test — `addImported` auto-links new contacts; re-import does not duplicate; `add(_:)` does not.** Create `RuneScribTests/ContactManagerTests.swift`. `ContactManager.addImported` does not yet call `ensureLinkedCipher`, so the auto-link assertions fail (red). `ContactManager.init(store:keyManager:)` is injectable; we pass an isolated encrypted `ContactStore(key:directory:)` and the shared `KeyManager`.

```swift
import XCTest
import CryptoKit
@testable import RuneScrib

@MainActor
final class ContactManagerTests: XCTestCase {

    private func makeManager() -> (ContactManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ContactStore(key: SymmetricKey(size: .bits256), directory: dir)
        return (ContactManager(store: store, keyManager: .shared), dir)
    }

    func testAddImportedAutoLinksExactlyOneCipher() {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = Contact(displayName: "Sten", appleContactID: "imp-1", source: .imported)
        manager.addImported([snapshot])

        let stored = try! XCTUnwrap(manager.contacts.first { $0.appleContactID == "imp-1" })
        let linked = KeyManager.shared.ciphers(forContact: stored.id)
        XCTAssertEqual(linked.count, 1, "an imported contact gets exactly one auto-assigned cipher")
        XCTAssertEqual(linked.first?.label, "Sten", "the auto-assigned cipher is named for the contact")
        XCTAssertEqual(linked.first?.contactID, stored.id, "and is linked to it")
        XCTAssertNotEqual(KeyManager.shared.activeCipher?.id, linked.first?.id,
                          "import must not change the active cipher")
    }

    func testReimportingSameAppleIDDoesNotAddSecondCipher() {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = Contact(displayName: "Vala", appleContactID: "imp-2", source: .imported)
        manager.addImported([snapshot])
        let stored = try! XCTUnwrap(manager.contacts.first { $0.appleContactID == "imp-2" })

        manager.addImported([snapshot]) // dedup by appleContactID — no new contact, no new cipher

        XCTAssertEqual(manager.contacts.filter { $0.appleContactID == "imp-2" }.count, 1,
                       "the duplicate import is deduped by appleContactID")
        XCTAssertEqual(KeyManager.shared.ciphers(forContact: stored.id).count, 1,
                       "and no second cipher is auto-assigned")
    }

    func testManualAddDoesNotAutoGenerateCipher() {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manual = Contact(displayName: "Orm", source: .manual)
        manager.add(manual)

        let stored = try! XCTUnwrap(manager.contacts.first { $0.id == manual.id })
        XCTAssertTrue(KeyManager.shared.ciphers(forContact: stored.id).isEmpty,
                      "manual add is import-only-exempt: no cipher is auto-generated")
    }
}
```

- [ ] **9. Run — expect failure.**
  ```
  xcodegen generate
  xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/ContactManagerTests test 2>&1 | tail -20
  ```
  Expect failures in `testAddImportedAutoLinksExactlyOneCipher` (linked.count is 0) and `testReimportingSameAppleIDDoesNotAddSecondCipher`; `testManualAddDoesNotAutoGenerateCipher` already passes (no wiring on `add`). Overall result is **failed**.

- [ ] **10. Minimal impl — wire `addImported` to auto-link only the newly-added imports.** In `RuneScrib/Services/ContactManager.swift`, change `addImported(_:)` so it persists first, then auto-links each contact it actually added:

```swift
    /// Adds imported snapshots, skipping any whose Apple identifier is already present —
    /// deduping against existing contacts AND within the batch. Manual snapshots (nil
    /// identifier) are always added. Each newly-added contact is given one auto-assigned,
    /// non-activating cipher (import-only; manual `add(_:)` never auto-generates).
    func addImported(_ snapshots: [Contact]) {
        var seen = Set(contacts.compactMap(\.appleContactID))
        var added: [Contact] = []
        for snap in snapshots {
            if let id = snap.appleContactID {
                if seen.contains(id) { continue }
                seen.insert(id)
            }
            added.append(snap)
        }
        guard !added.isEmpty else { return }
        persist(ContactBook(contacts: contacts + added))
        for contact in added {
            keyManager.ensureLinkedCipher(forImportedContact: contact)
        }
    }
```
(The `for` loop runs only over `added`, so re-imports — which produce an empty `added` and early-return at the guard — never reach it. `keyManager` is the existing injected `private let keyManager: KeyManager`. `ensureLinkedCipher` is `@discardableResult`, so the bare call is clean.)

- [ ] **11. Run — expect pass.**
  ```
  xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/ContactManagerTests test 2>&1 | tail -20
  ```
  Expect `** TEST SUCCEEDED **` (all three methods).

- [ ] **12. Run the full suite — guard against regressions** (KeyManager singleton state is shared across tests; confirm nothing else broke).
  ```
  xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' test 2>&1 | tail -20
  ```
  Expect `** TEST SUCCEEDED **`. (Note: the macOS test host can be slow/hang when sandboxed-headless — a known prior issue; re-run unsandboxed if it stalls.)

- [ ] **13. Commit the ContactManager wiring.**
  ```
  git add RuneScrib/Services/ContactManager.swift RuneScribTests/ContactManagerTests.swift RuneScrib.xcodeproj
  git commit -m "feat: auto-assign per-contact cipher on contact import"
  ```
  (No AI attribution.)

---

### Task 3: MessageService.read(envelope:tryingCiphers:)

Add the envelope-level decrypt that message intake uses — parallel to the existing `read(_:tryingCiphers:)` but starting from a raw `MessageEnvelope` `Data` blob (the wire form carried inside a `MessageSharePayload`) rather than from a decorative rune string. The `MessageCoordinator` (later task) hands this an already-decoded `payload.envelope`, so there is no rune un-decoration step here: just unwrap the envelope framing and try each cipher's AES-GCM key. As with the rune path, exactly one cipher's key authenticates; wrong keys and tampered bytes fail closed (the AEAD tag guarantees no false-positive plaintext).

**Files:**
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/MessageService.swift` — add `read(envelope:tryingCiphers:)` after the existing `read(_:tryingCiphers:)` (currently ends ~line 44, just before the closing `}` of `struct MessageService`). Reuses the already-present `private let cryptor = MessageCryptor()`. `MessageError.noMatchingCipher` already exists (top of file) — reuse it, do NOT add a new case.
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageServiceTests.swift` — append the new tests in an `extension MessageServiceTests {}` after the existing `final class` (file currently ends ~line 36). Reuses the existing `private let svc = MessageService()`.

Steps:

- [ ] **1. Write the failing tests.** Append to `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageServiceTests.swift`, after the closing `}` of `final class MessageServiceTests`. These seal directly with `MessageCryptor()` + `MessageEnvelope.wrap` (the wire form), exactly what the coordinator will pass in — they do NOT go through the rune codec.

```swift
extension MessageServiceTests {
    /// Builds the on-the-wire envelope (version byte ‖ AES-GCM sealed box) for `cipher`,
    /// the same bytes a `MessageSharePayload.envelope` carries.
    private func envelope(_ plaintext: String, with cipher: Cipher) throws -> Data {
        let sealed = try MessageCryptor().seal(plaintext, with: cipher)
        return MessageEnvelope.wrap(sealed)
    }

    func testReadEnvelopeRecoversUnderCorrectCipherAmongCandidates() throws {
        let a = Cipher.generated(label: "a")
        let b = Cipher.generated(label: "b")
        let env = try envelope("rendezvous at dusk", with: a)
        // Wrong cipher first, correct one second: only A's key authenticates.
        let result = try svc.read(envelope: env, tryingCiphers: [b, a])
        XCTAssertEqual(result.plaintext, "rendezvous at dusk")
        XCTAssertEqual(result.cipher, a)
    }

    func testReadEnvelopeThrowsWhenNoCipherMatches() throws {
        let env = try envelope("nope", with: Cipher.generated(label: "a"))
        XCTAssertThrowsError(try svc.read(envelope: env, tryingCiphers: [Cipher.generated(label: "b")])) { error in
            XCTAssertEqual(error as? MessageError, .noMatchingCipher)
        }
    }

    func testReadEnvelopeRejectsTamperedBytesNoFalsePositive() throws {
        let a = Cipher.generated(label: "a")
        var env = try envelope("authentic", with: a)
        // Flip a byte inside the sealed box (skip the version byte at index 0) so the
        // GCM tag no longer verifies — the correct cipher must still refuse to open it.
        env[env.count - 1] ^= 0xFF
        XCTAssertThrowsError(try svc.read(envelope: env, tryingCiphers: [a])) { error in
            XCTAssertEqual(error as? MessageError, .noMatchingCipher)
        }
    }
}
```

Note: `MessageError` is `Equatable`-comparable here via `error as? MessageError`; it is a no-associated-value-mismatch single case, so `XCTAssertEqual(error as? MessageError, .noMatchingCipher)` compiles because `MessageError` synthesizes `Equatable` for its caseless-payload form. (If the build flags `MessageError` as not `Equatable`, fall back to `XCTAssertThrowsError(...)` with no closure — the throw itself is the assertion. Verify in step 2.)

- [ ] **2. Run — expect FAIL (does not compile: no `read(envelope:tryingCiphers:)`).**

```
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/MessageServiceTests test 2>&1 | tail -20
```

Expected: compilation failure — `value of type 'MessageService' has no member 'read(envelope:tryingCiphers:)'` (and possibly the `MessageError` Equatable note above). NOT "** TEST SUCCEEDED **".

- [ ] **3. Minimal impl.** In `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/MessageService.swift`, add this method inside `struct MessageService`, immediately after the existing `read(_:tryingCiphers:)` method and before the struct's closing brace:

```swift
    /// Raw `MessageEnvelope` bytes → (plaintext, cipher) by trying each candidate.
    /// Used by message intake, which already holds a decoded envelope (no rune layer).
    /// Unwraps the framing once per cipher and lets the AEAD tag pick the right key;
    /// a wrong key or any tampering throws rather than returning bogus plaintext.
    func read(envelope: Data, tryingCiphers ciphers: [Cipher]) throws -> (plaintext: String, cipher: Cipher) {
        for cipher in ciphers {
            guard let sealed = try? MessageEnvelope.unwrap(envelope),
                  let text = try? cryptor.open(sealed, with: cipher)
            else { continue }
            return (text, cipher)
        }
        throw MessageError.noMatchingCipher
    }
```

If step 1's note triggered (MessageError not `Equatable`), conform it once at its declaration in this same file: change `enum MessageError: Error, LocalizedError {` to `enum MessageError: Error, LocalizedError, Equatable {`. Otherwise leave it untouched.

- [ ] **4. Run — expect PASS.**

```
xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/MessageServiceTests test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. (No `xcodegen generate` needed — only existing files were modified, no new `.swift` added.)

- [ ] **5. Commit.**

```
git add RuneScrib/Services/MessageService.swift RuneScribTests/MessageServiceTests.swift
git commit -m "feat: add MessageService.read(envelope:tryingCiphers:) for message intake"
```

(No AI attribution — CI guard rejects `Co-Authored-By` / tool names.)

---

### Task 4: MessageSharePayload wire format (link + file forms)

The core new model for Phase 4. It bundles a sender name, the raw `MessageEnvelope` bytes (variable length), and an optional embedded `CipherSharePayload` (the 129-byte cipher-share blob) into one validated binary blob, and projects that blob onto an https universal link (with a legacy `runescribe://m` fallback). It mirrors `CipherSharePayload` exactly: a 4-byte `SHA256(body).prefix(4)` checksum, version gating, base64url query payload, and an `isMessageURL` classifier that must NOT collide with the cipher import URL.

Layout (`encoded()`):
```
version(1) | flags(1; bit0 = hasCipher) | nameLen(1, UInt8) | name(utf8, ≤255)
          | envLen(2, UInt16 BE) | envelope | [embeddedCipher.encoded() 129B if flag] | checksum(4)
```

**Files:**
- Create: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Models/MessageSharePayload.swift`
- Create: `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageSharePayloadTests.swift`
- Reference (read, do not modify): `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Models/CipherSharePayload.swift` (the format to mirror), `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Models/MessageEnvelope.swift` (envelope bytes), `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/CipherSharePayloadTests.swift` (test style).

---

1. - [ ] **Write the failing binary round-trip tests (with and without an embedded cipher).** Create `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageSharePayloadTests.swift`:

   ```swift
   import XCTest
   @testable import RuneScrib

   final class MessageSharePayloadTests: XCTestCase {
       /// Builds a real envelope (version byte + AES-GCM sealed box) for a known cipher.
       private func envelope(_ plaintext: String, with cipher: Cipher) throws -> Data {
           MessageEnvelope.wrap(try MessageCryptor().seal(plaintext, with: cipher))
       }

       func testBinaryRoundTripWithoutEmbeddedCipher() throws {
           let cipher = Cipher.generated(label: "Alice")
           let env = try envelope("hello runes", with: cipher)
           let payload = MessageSharePayload(senderName: "Alice", envelope: env, embeddedCipher: nil)

           let back = try MessageSharePayload(decoding: payload.encoded())
           XCTAssertEqual(back.senderName, "Alice")
           XCTAssertEqual(back.envelope, env)
           XCTAssertNil(back.embeddedCipher)
           // The recovered envelope still decrypts under the original cipher.
           let sealed = try MessageEnvelope.unwrap(back.envelope)
           XCTAssertEqual(try MessageCryptor().open(sealed, with: cipher), "hello runes")
       }

       func testBinaryRoundTripWithEmbeddedCipher() throws {
           let cipher = Cipher.generated(label: "Bob")
           let env = try envelope("with key", with: cipher)
           let embedded = CipherSharePayload(cipher: cipher)
           let payload = MessageSharePayload(senderName: "Bob", envelope: env, embeddedCipher: embedded)

           let back = try MessageSharePayload(decoding: payload.encoded())
           XCTAssertEqual(back.senderName, "Bob")
           XCTAssertEqual(back.envelope, env)
           XCTAssertEqual(back.embeddedCipher?.keyMaterial, cipher.keyMaterial)
           XCTAssertEqual(back.embeddedCipher?.decorativeMapping, cipher.decorativeMapping)
       }
   }
   ```

2. - [ ] **Run the tests — expect a compile failure (type does not exist yet).**

   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate && \
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
     -only-testing:RuneScribTests/MessageSharePayloadTests test 2>&1 | tail -20
   ```
   Expected: build fails — `cannot find 'MessageSharePayload' in scope`. (`xcodegen generate` is run here first so the not-yet-created file's absence is the only reason for failure; it will pick up the new file on the next run.)

3. - [ ] **Minimal implementation — binary form only.** Create `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Models/MessageSharePayload.swift` with the error type, fields, `encoded()`, and `init(decoding:)`:

   ```swift
   import Foundation
   import CryptoKit

   enum MessageShareError: Error, LocalizedError {
       case tooShort, unsupportedVersion(UInt8), badChecksum
       case invalidURL, badBase64, missingPayload
       var errorDescription: String? {
           switch self {
           case .tooShort, .badBase64:     return "The message's data is corrupted."
           case .badChecksum:              return "The message failed its integrity check."
           case .unsupportedVersion:       return "This message uses a newer format. Update Rune Scribe."
           case .invalidURL:               return "This isn't a Rune Scribe message link."
           case .missingPayload:           return "The message link is missing its data."
           }
       }
   }

   /// The wire format for sharing a single encrypted message (deep-link / iMessage).
   /// v1 layout:
   ///   version(1) | flags(1; bit0 = hasCipher) | nameLen(1, UInt8) | name(utf8, ≤255)
   ///   | envLen(2, UInt16 big-endian) | envelope | [embeddedCipher.encoded() 129B if flag] | checksum(4)
   struct MessageSharePayload: Equatable {
       static let version: UInt8 = 1
       static let scheme = "runescribe"
       static let host = "m"
       static let webHost = "ravenforgesoftware.com"
       static let webPath = "/rune-scribe/m"

       let senderName: String
       let envelope: Data
       let embeddedCipher: CipherSharePayload?

       init(senderName: String, envelope: Data, embeddedCipher: CipherSharePayload?) {
           self.senderName = senderName
           self.envelope = envelope
           self.embeddedCipher = embeddedCipher
       }

       // MARK: binary

       func encoded() -> Data {
           let nameBytes = Data(senderName.utf8).prefix(255)
           var body = Data([Self.version])
           body.append(embeddedCipher == nil ? 0x00 : 0x01)        // flags
           body.append(UInt8(nameBytes.count))                     // nameLen
           body.append(Data(nameBytes))                            // name
           var envLen = UInt16(envelope.count).bigEndian
           body.append(Data(bytes: &envLen, count: 2))             // envLen (BE)
           body.append(envelope)
           if let embeddedCipher { body.append(embeddedCipher.encoded()) }   // 129 bytes
           body.append(Self.checksum(of: body))
           return body
       }

       init(decoding data: Data) throws {
           // Minimum: version + flags + nameLen + envLen(2) + checksum(4) = 9 bytes.
           guard data.count >= 9 else { throw MessageShareError.tooShort }
           let body = data.prefix(data.count - 4)
           let given = Data(data.suffix(4))
           guard Self.checksum(of: body) == given else { throw MessageShareError.badChecksum }

           var i = data.startIndex
           guard data[i] == Self.version else { throw MessageShareError.unsupportedVersion(data[i]) }
           i = data.index(i, offsetBy: 1)
           let hasCipher = (data[i] & 0x01) != 0
           i = data.index(i, offsetBy: 1)
           let nameLen = Int(data[i])
           i = data.index(i, offsetBy: 1)
           guard data.distance(from: i, to: data.endIndex) >= nameLen + 2 + 4 else { throw MessageShareError.tooShort }
           let nameData = data.subdata(in: i ..< data.index(i, offsetBy: nameLen))
           i = data.index(i, offsetBy: nameLen)
           let envLen = Int(data.subdata(in: i ..< data.index(i, offsetBy: 2)).reduce(0) { ($0 << 8) | Int($1) })
           i = data.index(i, offsetBy: 2)
           let needed = envLen + (hasCipher ? CipherSharePayload.byteCount : 0) + 4
           guard data.distance(from: i, to: data.endIndex) >= needed else { throw MessageShareError.tooShort }
           let env = data.subdata(in: i ..< data.index(i, offsetBy: envLen))
           i = data.index(i, offsetBy: envLen)

           var embedded: CipherSharePayload?
           if hasCipher {
               let blob = data.subdata(in: i ..< data.index(i, offsetBy: CipherSharePayload.byteCount))
               embedded = try CipherSharePayload(decoding: blob)
           }
           self.init(senderName: String(decoding: nameData, as: UTF8.self),
                     envelope: Data(env), embeddedCipher: embedded)
       }

       private static func checksum(of data: Data) -> Data {
           Data(SHA256.hash(data: data).prefix(4))
       }
   }
   ```

4. - [ ] **Run the binary round-trip tests — expect pass.**

   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate && \
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
     -only-testing:RuneScribTests/MessageSharePayloadTests test 2>&1 | tail -20
   ```
   Expected: `** TEST SUCCEEDED **`. (Run `xcodegen generate` first so the globbed sources pick up the new `MessageSharePayload.swift`.)

5. - [ ] **Commit the binary form.**

   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && \
   git add RuneScrib/Models/MessageSharePayload.swift RuneScribTests/MessageSharePayloadTests.swift RuneScrib.xcodeproj && \
   git commit -m "feat: add MessageSharePayload binary wire format with checksum"
   ```

6. - [ ] **Write failing tests for checksum/version rejection and the long-envelope (UInt16) round-trip.** Append to `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageSharePayloadTests.swift`:

   ```swift
   extension MessageSharePayloadTests {
       func testFlippedByteRejectedByChecksum() throws {
           let cipher = Cipher.generated(label: "x")
           let env = MessageEnvelope.wrap(try MessageCryptor().seal("tamper", with: cipher))
           var bytes = MessageSharePayload(senderName: "x", envelope: env, embeddedCipher: nil).encoded()
           bytes[5] ^= 0x01
           XCTAssertThrowsError(try MessageSharePayload(decoding: bytes)) { error in
               XCTAssertEqual(error as? MessageShareError, .badChecksum)
           }
       }

       func testWrongVersionRejected() throws {
           let cipher = Cipher.generated(label: "x")
           let env = MessageEnvelope.wrap(try MessageCryptor().seal("v", with: cipher))
           var bytes = MessageSharePayload(senderName: "x", envelope: env, embeddedCipher: nil).encoded()
           bytes[0] = 9
           // Recompute checksum so we exercise the version guard, not the checksum guard.
           let body = bytes.prefix(bytes.count - 4)
           let fresh = Data(SHA256.hash(data: body).prefix(4))
           bytes.replaceSubrange((bytes.count - 4)..<bytes.count, with: fresh)
           XCTAssertThrowsError(try MessageSharePayload(decoding: bytes)) { error in
               guard case MessageShareError.unsupportedVersion(9) = error else {
                   return XCTFail("expected unsupportedVersion(9), got \(error)")
               }
           }
       }

       func testTooShortRejected() {
           XCTAssertThrowsError(try MessageSharePayload(decoding: Data([1, 0, 0]))) { error in
               XCTAssertEqual(error as? MessageShareError, .tooShort)
           }
       }

       func testLongEnvelopeRoundTripsViaUInt16Length() throws {
           let cipher = Cipher.generated(label: "Long")
           // A plaintext well past 255 bytes -> envelope length needs the 2-byte field.
           let long = String(repeating: "rune ", count: 400)   // 2000 chars
           let env = MessageEnvelope.wrap(try MessageCryptor().seal(long, with: cipher))
           XCTAssertGreaterThan(env.count, 255)
           let payload = MessageSharePayload(senderName: "Long", envelope: env, embeddedCipher: nil)

           let back = try MessageSharePayload(decoding: payload.encoded())
           XCTAssertEqual(back.envelope, env)
           let sealed = try MessageEnvelope.unwrap(back.envelope)
           XCTAssertEqual(try MessageCryptor().open(sealed, with: cipher), long)
       }
   }
   ```
   Add `Equatable` conformance to the error so `XCTAssertEqual(error as? MessageShareError, ...)` compiles. In `MessageSharePayload.swift` change the declaration to:
   ```swift
   enum MessageShareError: Error, LocalizedError, Equatable {
   ```

7. - [ ] **Run — expect pass (binary impl + checksum/version guards already cover these).**

   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate && \
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
     -only-testing:RuneScribTests/MessageSharePayloadTests test 2>&1 | tail -20
   ```
   Expected: `** TEST SUCCEEDED **`. (The `Equatable` conformance is the only impl change; the guards already throw the asserted cases.)

8. - [ ] **Commit the integrity tests.**

   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && \
   git add RuneScrib/Models/MessageSharePayload.swift RuneScribTests/MessageSharePayloadTests.swift && \
   git commit -m "test: cover MessageSharePayload checksum, version, and long-envelope cases"
   ```

9. - [ ] **Write failing tests for the URL forms and `isMessageURL` classification.** Append to `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageSharePayloadTests.swift`:

   ```swift
   extension MessageSharePayloadTests {
       func testHTTPSURLRoundTripPreservesEverything() throws {
           let cipher = Cipher.generated(label: "Sam")
           let env = MessageEnvelope.wrap(try MessageCryptor().seal("url me", with: cipher))
           let payload = MessageSharePayload(senderName: "Sam",
                                             envelope: env,
                                             embeddedCipher: CipherSharePayload(cipher: cipher))
           let url = try payload.url(name: "Sam")
           XCTAssertEqual(url.scheme, "https")
           XCTAssertEqual(url.host, "ravenforgesoftware.com")
           XCTAssertEqual(url.path, "/rune-scribe/m")

           let parsed = try MessageSharePayload(url: url)
           XCTAssertEqual(parsed.senderName, "Sam")
           XCTAssertEqual(parsed.envelope, env)
           XCTAssertEqual(parsed.embeddedCipher?.keyMaterial, cipher.keyMaterial)
       }

       func testLegacyCustomSchemeURLParses() throws {
           let cipher = Cipher.generated(label: "Leg")
           let env = MessageEnvelope.wrap(try MessageCryptor().seal("legacy", with: cipher))
           let payload = MessageSharePayload(senderName: "Leg", envelope: env, embeddedCipher: nil)
           let p = payload.encoded().base64EncodedString()
               .replacingOccurrences(of: "+", with: "-")
               .replacingOccurrences(of: "/", with: "_")
               .replacingOccurrences(of: "=", with: "")
           let legacy = URL(string: "runescribe://m?v=1&p=\(p)")!
           let parsed = try MessageSharePayload(url: legacy)
           XCTAssertEqual(parsed.senderName, "Leg")
           XCTAssertEqual(parsed.envelope, env)
       }

       func testIsMessageURLClassifies() {
           // message URLs
           XCTAssertTrue(MessageSharePayload.isMessageURL("https://ravenforgesoftware.com/rune-scribe/m?v=1&p=AAA"))
           XCTAssertTrue(MessageSharePayload.isMessageURL("runescribe://m?v=1&p=AAA"))
           // a cipher import URL must NOT be classified as a message
           XCTAssertFalse(MessageSharePayload.isMessageURL("https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAA"))
           XCTAssertFalse(MessageSharePayload.isMessageURL("runescribe://import?v=3&p=AAA"))
           // junk
           XCTAssertFalse(MessageSharePayload.isMessageURL("https://example.com/x"))
           XCTAssertFalse(MessageSharePayload.isMessageURL("hello world"))
       }
   }
   ```

10. - [ ] **Run — expect a compile failure (`url(name:)`, `init(url:)`, `isMessageURL` not implemented).**

    ```bash
    cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate && \
    xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
      -only-testing:RuneScribTests/MessageSharePayloadTests test 2>&1 | tail -20
    ```
    Expected: build fails — `value of type 'MessageSharePayload' has no member 'url'` / `type 'MessageSharePayload' has no member 'isMessageURL'`.

11. - [ ] **Implement the URL surface.** Add to `MessageSharePayload.swift`, after the `checksum(of:)` helper (still inside the struct). The `isMessageURL` classifier checks the `m` path exactly via a trailing boundary so it can never match `/rune-scribe/import`:

    ```swift
       // MARK: URL

       /// True for a Rune Scribe message link in either the https or legacy custom-scheme form.
       /// Deliberately does NOT match a cipher import link (`/rune-scribe/import`).
       static func isMessageURL(_ string: String) -> Bool {
           let s = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
           if s.hasPrefix("\(scheme)://\(host)?") || s == "\(scheme)://\(host)" || s.hasPrefix("\(scheme)://\(host)/") {
               return true
           }
           for base in ["https://\(webHost)\(webPath)", "https://www.\(webHost)\(webPath)"] {
               if s == base || s.hasPrefix("\(base)?") || s.hasPrefix("\(base)/") { return true }
           }
           return false
       }

       func url(name: String?) throws -> URL {
           var comps = URLComponents()
           comps.scheme = "https"; comps.host = Self.webHost; comps.path = Self.webPath
           var items = [URLQueryItem(name: "v", value: String(Self.version)),
                        URLQueryItem(name: "p", value: Self.base64url(encoded()))]
           if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
               items.append(URLQueryItem(name: "n", value: name))
           }
           comps.queryItems = items
           guard let url = comps.url else { throw MessageShareError.invalidURL }
           return url
       }

       /// Parse a Rune Scribe message URL in either the https universal-link or legacy `runescribe://m` form.
       init(url: URL) throws {
           guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw MessageShareError.invalidURL }
           let isHTTPS = url.scheme?.lowercased() == "https"
               && (comps.host?.lowercased() == Self.webHost || comps.host?.lowercased() == "www.\(Self.webHost)")
               && comps.path.lowercased().hasPrefix(Self.webPath)
           let isScheme = url.scheme?.lowercased() == Self.scheme
               && ((comps.host ?? comps.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == Self.host)
           guard isHTTPS || isScheme else { throw MessageShareError.invalidURL }
           let items = comps.queryItems ?? []
           guard let p = items.first(where: { $0.name == "p" })?.value, !p.isEmpty else { throw MessageShareError.missingPayload }
           try self.init(decoding: Self.bytesFromBase64url(p))
       }

       private static func base64url(_ data: Data) -> String {
           data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
               .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
       }
       private static func bytesFromBase64url(_ s: String) throws -> Data {
           var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
           let rem = b.count % 4; if rem > 0 { b += String(repeating: "=", count: 4 - rem) }
           guard let data = Data(base64Encoded: b) else { throw MessageShareError.badBase64 }
           return data
       }
   ```
   Note: `init(url:)` delegates to `init(decoding:)`; `n` is not stored (the sender name lives in the binary body, unlike `CipherSharePayload.parsedName`).

12. - [ ] **Run the full test class — expect pass.**

    ```bash
    cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate && \
    xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
      -only-testing:RuneScribTests/MessageSharePayloadTests test 2>&1 | tail -20
    ```
    Expected: `** TEST SUCCEEDED **` (all binary, integrity, and URL tests green).

13. - [ ] **Run the whole macOS suite to confirm no regression** (the new `MessageSharePayload.encoded()` reuses `CipherSharePayload.encoded()`/`byteCount`, so a passing run also proves the embedded-cipher framing matches Task-3 expectations).

    ```bash
    cd /Volumes/NVME/GitHub/rune-scrib && \
    xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' test 2>&1 | tail -20
    ```
    Expected: `** TEST SUCCEEDED **`. (If the sandboxed-headless test host hangs — the known prior issue — re-run with `-only-testing:RuneScribTests/MessageSharePayloadTests` and the prior `CipherSharePayloadTests` to confirm the affected areas.)

14. - [ ] **Commit the URL surface.**

    ```bash
    cd /Volumes/NVME/GitHub/rune-scrib && \
    git add RuneScrib/Models/MessageSharePayload.swift RuneScribTests/MessageSharePayloadTests.swift && \
    git commit -m "feat: add MessageSharePayload https/legacy URL forms and isMessageURL classifier"
    ```


---

### Task 5: MessageCoordinator intake + auto-associate

App-wide intake for inbound *message* links, mirroring `ImportCoordinator` (Task-4 prerequisite types already exist: `MessageSharePayload`, `Cipher.delivered`, `KeyManager.ensureLinkedCipher`, `MessageService.read(envelope:tryingCiphers:)`). It decodes a `MessageSharePayload` URL, opportunistically imports an embedded cipher, decrypts the envelope by trying every candidate key, auto-associates the matching cipher to a contact by sender name, and publishes a `PendingMessage` that `RootView` will present (presentation wired in a later task).

**Injection note:** `KeyManager` is a hard singleton (`private init`, `.shared` only) and *cannot* be re-instantiated, so tests exercise the real `KeyManager.shared`. `ContactManager` has a public `init(store:keyManager:)`, so each test injects a fresh `ContactManager` backed by an isolated, key-injected `ContactStore(key:directory:)` (no Keychain / app-support touch). `MessageCoordinator` therefore takes an injectable `init(keyManager:contactManager:)` defaulting to the shared singletons, but is *not* a `private init` singleton like `ImportCoordinator` — it still exposes `static let shared` for production env-injection.

**Files:**
- Create: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/MessageCoordinator.swift`
- Create: `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageCoordinatorTests.swift`
- (Reference only, do NOT modify here) `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/ImportCoordinator.swift` (template, lines 12–63), `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/KeyManager.swift` (`importCipher`, `ciphers`, `setContact`, `ciphers(forContact:)` at lines 99–157), `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/ContactManager.swift` (`add`, `contacts`, `init(store:keyManager:)` at lines 13–19), `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/MessageService.swift` (`read(envelope:tryingCiphers:)` from Task 4).

#### Steps

- [ ] **1. Write the failing test file.** Create `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageCoordinatorTests.swift`. It builds a real outbound `MessageSharePayload` (envelope = wrapped GCM seal of the plaintext, via the same leaf services the app uses) so the coordinator's decrypt path is exercised end-to-end. Every test runs on the main actor and injects a fresh, isolated `ContactManager`.

```swift
import XCTest
import CryptoKit
@testable import RuneScrib

@MainActor
final class MessageCoordinatorTests: XCTestCase {

    // A fresh ContactManager backed by an isolated, key-injected store — never
    // touches the Keychain or app-support, and starts with zero contacts.
    private func freshContactManager() -> ContactManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MsgCoordTests-\(UUID().uuidString)", isDirectory: true)
        let store = ContactStore(key: SymmetricKey(size: .bits256), directory: dir)
        return ContactManager(store: store, keyManager: .shared)
    }

    // Builds the wire envelope for `plaintext` under `cipher`, exactly as the app does:
    // GCM-seal → version-prefix. Mirrors MessageService.compose's framing minus the rune codec.
    private func envelope(_ plaintext: String, with cipher: Cipher) throws -> Data {
        let sealed = try MessageCryptor().seal(plaintext, with: cipher)
        return MessageEnvelope.wrap(sealed)
    }

    // MARK: - embedded-cipher message: imports key, decrypts, creates+links contact

    func testIngestEmbeddedCipherImportsDecryptsAndLinksNewContact() throws {
        let km = KeyManager.shared
        let cm = freshContactManager()
        let coordinator = MessageCoordinator(keyManager: km, contactManager: cm)

        // A cipher the recipient does NOT yet have — it rides along embedded in the message.
        let senderCipher = Cipher.generated(label: "Sender")
        let env = try envelope("rendezvous at dusk", with: senderCipher)
        let payload = MessageSharePayload(
            senderName: "Astrid",
            envelope: env,
            embeddedCipher: CipherSharePayload(cipher: senderCipher))
        let url = try payload.url(name: nil)

        coordinator.ingest(url: url)

        // Published a decrypted PendingMessage.
        XCTAssertNil(coordinator.errorMessage)
        let pending = try XCTUnwrap(coordinator.pending)
        XCTAssertEqual(pending.plaintext, "rendezvous at dusk")
        XCTAssertEqual(pending.senderName, "Astrid")

        // The embedded cipher was imported into the library (same key material, .imported).
        let imported = try XCTUnwrap(km.ciphers.first { $0.keyMaterial == senderCipher.keyMaterial })
        XCTAssertEqual(imported.origin, .imported)
        XCTAssertEqual(pending.cipher.id, imported.id)

        // A contact named after the sender was created and linked to the matching cipher.
        let contact = try XCTUnwrap(cm.contacts.first { $0.displayName == "Astrid" })
        XCTAssertEqual(contact.source, .imported)
        XCTAssertEqual(km.ciphers(forContact: contact.id).map(\.id), [imported.id])
    }

    // MARK: - already-stored cipher, no embed: decrypts via try-all

    func testIngestNoEmbedDecryptsViaAlreadyStoredCipher() throws {
        let km = KeyManager.shared
        let cm = freshContactManager()
        let coordinator = MessageCoordinator(keyManager: km, contactManager: cm)

        // Seed the library with the key, then send a message that carries NO embedded key.
        let shared = km.importCipher(CipherSharePayload(cipher: Cipher.generated(label: "Pre")),
                                     label: "Pre-shared")
        let env = try envelope("the eagle has landed", with: shared)
        let payload = MessageSharePayload(senderName: "Bjorn", envelope: env, embeddedCipher: nil)

        coordinator.ingest(url: try payload.url(name: nil))

        XCTAssertNil(coordinator.errorMessage)
        let pending = try XCTUnwrap(coordinator.pending)
        XCTAssertEqual(pending.plaintext, "the eagle has landed")
        XCTAssertEqual(pending.cipher.id, shared.id)          // matched the pre-shared key
        XCTAssertTrue(cm.contacts.contains { $0.displayName == "Bjorn" })
    }

    // MARK: - junk / undecryptable link: errorMessage set, pending stays nil

    func testIngestJunkSetsErrorAndLeavesPendingNil() {
        let coordinator = MessageCoordinator(keyManager: .shared, contactManager: freshContactManager())
        coordinator.ingest(url: URL(string: "https://ravenforgesoftware.com/rune-scribe/m?v=1&p=not-base64!!")!)
        XCTAssertNil(coordinator.pending)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testIngestUndecryptableMessageSetsErrorAndLeavesPendingNil() throws {
        let coordinator = MessageCoordinator(keyManager: .shared, contactManager: freshContactManager())
        // Valid wire payload, but encrypted under a key nobody holds and with no embed.
        let stranger = Cipher.generated(label: "Stranger")
        let env = try envelope("you cannot read this", with: stranger)
        let payload = MessageSharePayload(senderName: "Ghost", envelope: env, embeddedCipher: nil)
        coordinator.ingest(url: try payload.url(name: nil))
        XCTAssertNil(coordinator.pending)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    // MARK: - dedup: same URL ingested twice is a no-op the second time

    func testSameURLIngestedTwiceIsDeduped() throws {
        let cm = freshContactManager()
        let coordinator = MessageCoordinator(keyManager: .shared, contactManager: cm)
        let cipher = Cipher.generated(label: "Dup")
        let env = try envelope("once only", with: cipher)
        let url = try MessageSharePayload(
            senderName: "Eira", envelope: env,
            embeddedCipher: CipherSharePayload(cipher: cipher)).url(name: nil)

        coordinator.ingest(url: url)
        let firstPendingID = try XCTUnwrap(coordinator.pending).id
        let contactsAfterFirst = cm.contacts.count

        coordinator.ingest(url: url)   // duplicate delivery (e.g. AppDelegate + .onOpenURL)

        // Pending is unchanged (same instance) and no second contact was created.
        XCTAssertEqual(coordinator.pending?.id, firstPendingID)
        XCTAssertEqual(cm.contacts.count, contactsAfterFirst)
    }
}
```

- [ ] **2. Generate the project, then run the tests — expect a COMPILE failure** (`MessageCoordinator` does not exist yet):

```bash
cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate && \
  xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
  -only-testing:RuneScribTests/MessageCoordinatorTests test 2>&1 | tail -20
```

Expected: build fails with `cannot find 'MessageCoordinator' in scope`.

- [ ] **3. Minimal implementation.** Create `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/MessageCoordinator.swift`:

```swift
// RuneScrib/Services/MessageCoordinator.swift

import Foundation

/// App-wide intake for *messages* arriving over the wire — deep links (`.onOpenURL`),
/// scanned QR codes, the clipboard, and Universal Links. It decodes a
/// `runescribe://m` / `https://ravenforgesoftware.com/rune-scribe/m` URL to a
/// `MessageSharePayload`, opportunistically imports an embedded cipher, decrypts the
/// envelope by trying every candidate key, auto-associates the matching cipher with a
/// contact (by sender name), and publishes a `PendingMessage`; `RootView` observes it
/// and shows the decrypted-message sheet (gated so it never appears over the lock screen).
///
/// Mirrors `ImportCoordinator`. Published as a singleton and injected as an
/// `@EnvironmentObject`; all state mutates on the main actor. Dependencies are
/// injectable so the intake logic is unit-testable.
@MainActor
final class MessageCoordinator: ObservableObject {

    static let shared = MessageCoordinator()

    /// A decoded, decrypted message awaiting the user's view/reply.
    @Published var pending: PendingMessage?

    /// A human-readable reason a link couldn't be read.
    @Published var errorMessage: String?

    /// The most recently ingested URL, used to drop a duplicate delivery — e.g. the
    /// macOS AppDelegate's `application(_:open:)` and SwiftUI's `.onOpenURL` both
    /// firing for the same link.
    private var lastHandledURL: String?

    private let keyManager: KeyManager
    private let contactManager: ContactManager

    init(keyManager: KeyManager = .shared, contactManager: ContactManager = .shared) {
        self.keyManager = keyManager
        self.contactManager = contactManager
    }

    struct PendingMessage: Identifiable, Equatable {
        let id = UUID()
        let plaintext: String
        let senderName: String
        let cipher: Cipher
    }

    /// Decodes a message URL and, on success, surfaces the decrypted text for viewing;
    /// on failure, surfaces a readable error and leaves `pending` untouched-to-nil.
    func ingest(url: URL) {
        // Drop a duplicate delivery of the same link while one is already pending.
        let key = url.absoluteString
        if key == lastHandledURL, pending != nil { return }
        lastHandledURL = key
        do {
            let payload = try MessageSharePayload(url: url)

            // If the sender embedded their key, import it first so it's a decrypt candidate.
            var candidate: Cipher? = nil
            if let embedded = payload.embeddedCipher {
                candidate = try? keyManager.importCipher(embedded, label: payload.senderName)
            }

            // Try the freshly-imported key first, then every cipher already in the library.
            let pool = [candidate].compactMap { $0 } + keyManager.ciphers
            let (plaintext, cipher) = try MessageService().read(envelope: payload.envelope,
                                                                tryingCiphers: pool)

            autoAssociate(cipher, senderName: payload.senderName)
            errorMessage = nil
            pending = PendingMessage(plaintext: plaintext, senderName: payload.senderName, cipher: cipher)
        } catch {
            pending = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "This message couldn't be read."
        }
    }

    /// Same as `ingest(url:)` but from a raw string (clipboard / scanned payload).
    /// Silently ignores anything that isn't one of our message links.
    func ingest(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MessageSharePayload.isMessageURL(trimmed), let url = URL(string: trimmed) else { return }
        ingest(url: url)
    }

    /// Files the matching cipher under a contact named after the sender: reuses an existing
    /// contact whose display name matches, else creates an `.imported` one, then links the
    /// cipher to it unless it's already linked. Never changes key material.
    private func autoAssociate(_ cipher: Cipher, senderName: String) {
        let contact: Contact
        if let existing = contactManager.contacts.first(where: { $0.displayName == senderName }) {
            contact = existing
        } else {
            let made = Contact(displayName: senderName, source: .imported)
            contactManager.add(made)
            contact = made
        }
        if cipher.contactID != contact.id {
            keyManager.setContact(cipherID: cipher.id, contactID: contact.id)
        }
    }
}
```

- [ ] **4. Regenerate and run the tests — expect PASS:**

```bash
cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate && \
  xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
  -only-testing:RuneScribTests/MessageCoordinatorTests test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. (If the sandboxed-headless macOS test host hangs — the known prior issue — re-run; the logic under test is pure main-actor code with no UI.)

- [ ] **5. Run the full macOS suite to confirm no regression** (the coordinator mutates the real `KeyManager.shared` library, so verify nothing else broke):

```bash
cd /Volumes/NVME/GitHub/rune-scrib && \
  xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **6. Commit** (no AI attribution anywhere — a CI guard rejects it):

```bash
cd /Volumes/NVME/GitHub/rune-scrib && \
  git add RuneScrib/Services/MessageCoordinator.swift RuneScribTests/MessageCoordinatorTests.swift RuneScrib.xcodeproj/project.pbxproj && \
  git commit -m "feat: add MessageCoordinator intake with auto cipher import and contact association"
```


---

### Task 6: LinkRouter + wire the 4 URL entry points

A single inbound-link dispatcher classifies a tapped/pasted URL as a cipher-share link, a message link, or unknown, then routes it to the matching coordinator. `classify(_:)` is pure and unit-tested; `route(_:)` and the four scene-level call sites are build-verified + manually checked (per the prior phases' convention that scene-wired code is not unit-tested).

**Ordering is load-bearing:** `CipherSharePayload.isShareURL(_:)` returns `true` for *any* `runescribe:` URL (it early-returns `true` on the `runescribe:` prefix — see `CipherSharePayload.swift:112`), so a `runescribe://m` message link also satisfies it. `classify` MUST therefore test `MessageSharePayload.isMessageURL` **first**, then fall through to `CipherSharePayload.isShareURL`.

**Files:**
- Create: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/LinkRouter.swift`
- Create: `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/LinkRouterTests.swift`
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/App/RuneScribApp.swift` — `rootContent` (~lines 51–65): add `MessageCoordinator.shared` to the environment; repoint `.onOpenURL` (~line 60) and `.onContinueUserActivity` (~lines 61–64) at `LinkRouter.route(_:)`.
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/App/AppDelegate.swift` — macOS `application(_:open:)` (~lines 22–24): route each URL via `LinkRouter.route(_:)`.
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/Clipboard.swift` — `runeScribeURLString()` gate (~line 50): also accept message links so a pasted `https://…/rune-scribe/m` URL survives the filter.
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Views/RootView.swift` — `checkClipboardForCipher()` (~lines 88–90): hand the clipboard string to `LinkRouter.route(urlString:)` instead of `coordinator.ingest(urlString:)`.

---

#### Steps

1. - [ ] **Write the failing test** for `LinkRouter.classify(_:)`. Create `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/LinkRouterTests.swift`:

   ```swift
   import XCTest
   @testable import RuneScrib

   final class LinkRouterTests: XCTestCase {

       // MARK: cipher links

       func testClassifiesHTTPSCipherImportAsCipher() throws {
           let url = try CipherSharePayload(cipher: .generated(label: "A")).url(name: nil)
           guard case .cipher = LinkRouter.classify(url) else {
               return XCTFail("expected .cipher for \(url.absoluteString)")
           }
       }

       func testClassifiesCustomSchemeCipherImportAsCipher() throws {
           let url = try XCTUnwrap(URL(string: "runescribe://import?v=3&p=AAAA"))
           guard case .cipher = LinkRouter.classify(url) else {
               return XCTFail("expected .cipher for \(url.absoluteString)")
           }
       }

       // MARK: message links

       func testClassifiesHTTPSMessageAsMessage() throws {
           let url = try XCTUnwrap(URL(string: "https://ravenforgesoftware.com/rune-scribe/m?v=1&p=AAAA"))
           guard case .message = LinkRouter.classify(url) else {
               return XCTFail("expected .message for \(url.absoluteString)")
           }
       }

       func testClassifiesCustomSchemeMessageAsMessage() throws {
           let url = try XCTUnwrap(URL(string: "runescribe://m?v=1&p=AAAA"))
           guard case .message = LinkRouter.classify(url) else {
               return XCTFail("expected .message for \(url.absoluteString)")
           }
       }

       // MARK: unknown

       func testClassifiesUnrelatedHTTPSAsUnknown() throws {
           let url = try XCTUnwrap(URL(string: "https://example.com/hello"))
           guard case .unknown = LinkRouter.classify(url) else {
               return XCTFail("expected .unknown for \(url.absoluteString)")
           }
       }
   }
   ```

   This depends on `MessageSharePayload.isMessageURL` (Task introducing `MessageSharePayload`) already existing on the branch.

2. - [ ] **Generate the project** so the two new files are globbed into the target, then **run** the new test and watch it fail to compile (no `LinkRouter` type yet):

   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS \
     -destination 'platform=macOS' \
     -only-testing:RuneScribTests/LinkRouterTests test 2>&1 | tail -20
   ```

   Expected: build failure — `cannot find 'LinkRouter' in scope`.

3. - [ ] **Minimal implementation.** Create `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/LinkRouter.swift`:

   ```swift
   // RuneScrib/Services/LinkRouter.swift
   //
   // The single front door for inbound URLs. Every entry point — `.onOpenURL`,
   // the web-browsing `NSUserActivity`, the macOS AppDelegate's `open urls:`, and
   // the clipboard sweep — funnels through here, so the cipher-import vs. message
   // decision lives in exactly one place.

   import Foundation

   /// The kind of Rune Scribe link an inbound URL represents.
   enum InboundLink: Equatable {
       case cipher(URL)
       case message(URL)
       case unknown
   }

   enum LinkRouter {

       /// Pure classification. Message links are tested *before* cipher links:
       /// `CipherSharePayload.isShareURL` returns `true` for any `runescribe:` URL
       /// (including `runescribe://m`), so the more specific message check must win.
       static func classify(_ url: URL) -> InboundLink {
           let s = url.absoluteString
           if MessageSharePayload.isMessageURL(s) { return .message(url) }
           if CipherSharePayload.isShareURL(s)    { return .cipher(url) }
           return .unknown
       }

       /// Dispatches a classified URL to the owning coordinator. A no-op for
       /// links we don't recognise.
       @MainActor
       static func route(_ url: URL) {
           switch classify(url) {
           case .cipher(let u):  ImportCoordinator.shared.ingest(url: u)
           case .message(let u): MessageCoordinator.shared.ingest(url: u)
           case .unknown:        break
           }
       }

       /// Convenience for the clipboard path, which carries a raw string.
       /// Silently ignores anything that isn't a parseable URL.
       @MainActor
       static func route(urlString: String) {
           let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
           guard let url = URL(string: trimmed) else { return }
           route(url)
       }
   }
   ```

4. - [ ] **Run** the test again — expect pass:

   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && xcodebuild -project RuneScrib.xcodeproj \
     -scheme RuneScrib-macOS -destination 'platform=macOS' \
     -only-testing:RuneScribTests/LinkRouterTests test 2>&1 | tail -20
   ```

   Expected: `** TEST SUCCEEDED **` (5 tests pass).

5. - [ ] **Commit** the unit-tested classifier:

   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib
   git add RuneScrib/Services/LinkRouter.swift RuneScribTests/LinkRouterTests.swift RuneScrib.xcodeproj/project.pbxproj
   git commit -m "feat: add LinkRouter to classify inbound cipher vs message links"
   ```

6. - [ ] **Wire the scene entry points (build-verified).** Edit `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/App/RuneScribApp.swift` — replace the `rootContent` `else` branch (~lines 53–65) so the message coordinator is injected and both URL hooks route through `LinkRouter`:

   ```swift
           } else {
               RootView()
                   .environmentObject(KeyManager.shared)
                   .environmentObject(AppLock.shared)
                   .environmentObject(ImportCoordinator.shared)
                   .environmentObject(MessageCoordinator.shared)
                   .environmentObject(ContactManager.shared)
                   // A tapped runescribe:// link (cipher import or message) lands here
                   // on both platforms, even from a cold launch. LinkRouter decides which
                   // coordinator owns it.
                   .onOpenURL { LinkRouter.route($0) }
                   // A tapped https Universal Link arrives as a web-browsing NSUserActivity.
                   .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                       if let url = activity.webpageURL { LinkRouter.route(url) }
                   }
           }
   ```

7. - [ ] **Wire the macOS AppDelegate (build-verified).** Edit `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/App/AppDelegate.swift` — in `application(_:open:)` (~lines 22–24), route each URL and refresh the doc comment:

   ```swift
       /// Handles runescribe:// links on macOS, including cold launch — where SwiftUI's
       /// `.onOpenURL` can miss a URL that arrives before the scene is ready.
       /// `LinkRouter` dispatches to the right coordinator, which dedupes if
       /// `.onOpenURL` also delivers the same link.
       func application(_ application: NSApplication, open urls: [URL]) {
           for url in urls { LinkRouter.route(url) }
       }
   ```

8. - [ ] **Wire the clipboard path (build-verified).** Two edits so a pasted *message* link survives and routes correctly.

   First, widen the clipboard gate in `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/Clipboard.swift` — replace the return at ~line 50 (`runeScribeURLString()`):

   ```swift
           let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
           // Accept cipher-import links (host or path form) AND message links.
           let recognised = CipherSharePayload.isShareURL(trimmed)
               || MessageSharePayload.isMessageURL(trimmed)
           return recognised ? trimmed : nil
   ```

   Then repoint the consumer in `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Views/RootView.swift` — `checkClipboardForCipher()` at ~lines 88–90:

   ```swift
           if let urlString = Clipboard.runeScribeURLString() {
               LinkRouter.route(urlString: urlString)
           }
   ```

   (`coordinator.ingest(urlString:)` is left intact on `ImportCoordinator` — it's no longer called from the clipboard path, but stays as the cipher-side primitive `LinkRouter` ultimately drives via `ingest(url:)`.)

9. - [ ] **Build both platforms** to confirm the rewired call sites compile (no new files added, so no `xcodegen` rerun needed):

   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS \
     -destination 'platform=macOS' build 2>&1 | tail -10
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-iOS \
     -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
   ```

   Expected: `** BUILD SUCCEEDED **` for both.

   **Manual verification checklist:**
   - Tapping a `https://ravenforgesoftware.com/rune-scribe/import?…` link opens the **cipher import** confirm sheet (unchanged behaviour).
   - Tapping a `https://ravenforgesoftware.com/rune-scribe/m?…` link opens the **received-message** sheet (routes to `MessageCoordinator`).
   - Tapping a legacy `runescribe://m?…` link routes to `MessageCoordinator`, not the import sheet — confirms the message-before-cipher ordering.
   - Copying a `…/rune-scribe/m?…` URL and returning to the foreground surfaces the message (clipboard gate now admits it).
   - An unrelated `https://example.com/…` link is a silent no-op (no sheet, no error toast).

10. - [ ] **Commit** the scene wiring:

    ```bash
    cd /Volumes/NVME/GitHub/rune-scrib
    git add RuneScrib/App/RuneScribApp.swift RuneScrib/App/AppDelegate.swift \
            RuneScrib/Services/Clipboard.swift RuneScrib/Views/RootView.swift
    git commit -m "feat: route all inbound URL entry points through LinkRouter"
    ```


---

### Task 7: ReceivedMessageView + RootView host

A decrypted inbound message needs the same one-tap, app-wide presentation that an inbound cipher already gets. This task adds `ReceivedMessageView` (mirroring `ImportConfirmView`'s shape: sender + decrypted plaintext in a `RunePanel`, with **Close** and **Reply** buttons), hosts it from `RootView` via a second `.sheet(item:)` bound to `MessageCoordinator.shared.pending` (gated behind splash/lock exactly like the import host), wires `MessageCoordinator` into the environment in `RuneScribApp`, and routes **Reply** through a new `Notification.Name` so `ContentView` switches to the message's cipher and focuses compose.

This is scene-level SwiftUI exercised by the user — **build-verified + manual, no unit test** (per prior phases). Tasks 1–6 (the `MessageCoordinator` logic, `MessageSharePayload`, `LinkRouter`, `Cipher.delivered`, etc.) are unit-tested elsewhere; this task assumes `MessageCoordinator` and its `PendingMessage` type already exist and compile.

**Files:**
- Create: `RuneScrib/Views/ReceivedMessageView.swift`
- Modify: `RuneScrib/App/RuneScribApp.swift` — env wiring in `rootContent` (~lines 53–64) and the `Notification.Name` extension (~lines 71–74)
- Modify: `RuneScrib/Views/RootView.swift` — `@EnvironmentObject` (~line 12) and the sheet host block (~lines 55–68)
- Modify: `RuneScrib/Views/ContentView.swift` — `.onReceive` handlers (~lines 116–121)

#### Steps

- [ ] **1. Add the `replyToMessageRequested` notification name.** In `RuneScrib/App/RuneScribApp.swift`, extend the existing `Notification.Name` block (it already holds `openLibraryRequested` / `openSettingsRequested`). The reply carries the target cipher's `UUID` in the notification's `object`, so `ContentView` can switch the active cipher without holding a reference to the view.

```swift
extension Notification.Name {
    static let openLibraryRequested  = Notification.Name("com.runescribe.openLibraryRequested")
    static let openSettingsRequested = Notification.Name("com.runescribe.openSettingsRequested")
    static let replyToMessageRequested = Notification.Name("com.runescribe.replyToMessageRequested")
}
```

- [ ] **2. Wire `MessageCoordinator` into the environment and route inbound URLs through `LinkRouter`.** Still in `RuneScribApp.swift`, in `rootContent` add the `MessageCoordinator.shared` environment object alongside the existing four, and switch the two URL-intake hooks from `ImportCoordinator.shared.ingest(...)` to `LinkRouter.route(...)` (from Task 6) so message links and cipher links are dispatched correctly. Replace lines ~54–64:

```swift
            RootView()
                .environmentObject(KeyManager.shared)
                .environmentObject(AppLock.shared)
                .environmentObject(ImportCoordinator.shared)
                .environmentObject(ContactManager.shared)
                .environmentObject(MessageCoordinator.shared)
                // A tapped runescribe:// link (Messages, Mail, Camera-app QR, etc.)
                // lands here on both platforms, even from a cold launch. LinkRouter
                // sends cipher links to ImportCoordinator and message links to
                // MessageCoordinator.
                .onOpenURL { LinkRouter.route($0) }
                // A tapped https Universal Link arrives as a web-browsing NSUserActivity.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { LinkRouter.route(url) }
                }
```

- [ ] **3. Create `ReceivedMessageView`.** Mirror `ImportConfirmView`'s structure exactly: `RuneHeader` with a runic wordmark + close button, a `ScrollView` containing a `RunePanel` (sender line + decrypted plaintext), and a bottom `HStack` of a secondary **Close** and a primary **Reply**. Presentation-agnostic — it dismisses itself and reports **Reply** via the `onReply` closure, so `RootView` owns the side effect. Write `RuneScrib/Views/ReceivedMessageView.swift`:

```swift
// RuneScrib/Views/ReceivedMessageView.swift

import SwiftUI

/// One-tap view of a decrypted inbound message arriving over the wire (deep link,
/// Universal Link, or clipboard). Shows who sent it and the plaintext, and lets the
/// user jump straight to composing a reply with the same cipher.
///
/// Presentation-agnostic: it dismisses itself and reports a reply request via
/// `onReply`, so it can be hosted app-wide (RootView) without coupling to a
/// particular presenter — the same contract `ImportConfirmView` uses.
struct ReceivedMessageView: View {

    @Environment(\.dismiss) private var dismiss

    let pending: MessageCoordinator.PendingMessage
    var onReply: ((MessageCoordinator.PendingMessage) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᛗᛖᛋᛋᚨᚷᛖ",
                subtitle: "Message",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
                    RuneEyebrow(title: "From", systemImage: "person.crop.circle.fill")
                    Text(pending.senderName)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    RunePanel(title: "Decoded Message", systemImage: "envelope.open.fill") {
                        Text(pending.plaintext)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("Decoded with the “\(pending.cipher.label)” cipher.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.runeSilver.opacity(0.8))
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())

                Button {
                    onReply?(pending)
                    dismiss()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())
            }
            .padding(RuneMetrics.pad)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
    }
}
```

- [ ] **4. Host the message sheet in `RootView`.** Add the `MessageCoordinator` environment object next to the existing `coordinator` declaration (~line 12):

```swift
    @EnvironmentObject private var coordinator: ImportCoordinator
    @EnvironmentObject private var messageCoordinator: MessageCoordinator
```

Then add a second `.sheet(item:)` immediately after the existing `ImportConfirmView` host (after the closing `}` of the block ending ~line 68, before the `.alert(...)`). It uses the **same** splash/lock gating so a tapped message link waits until the app is visible and unlocked, and **Reply** posts `.replyToMessageRequested` carrying the cipher id:

```swift
        // Inbound decrypted message. Same splash/lock gating as the import host: a
        // tapped message link waits and presents the moment the splash ends and the
        // app unlocks.
        .sheet(item: Binding(
            get: { (showSplash || appLock.isLocked) ? nil : messageCoordinator.pending },
            set: { if $0 == nil && !appLock.isLocked && !showSplash { messageCoordinator.pending = nil } }
        )) { pending in
            ReceivedMessageView(pending: pending) { message in
                // Reply: hand ContentView the cipher to compose with. It switches the
                // active cipher and drops to the editor.
                NotificationCenter.default.post(name: .replyToMessageRequested, object: message.cipher.id)
            }
        }
```

- [ ] **5. Handle the reply request in `ContentView`.** Add an `.onReceive` for `.replyToMessageRequested` next to the two existing handlers (~lines 116–121). It reads the cipher `UUID` from the notification's `object`, makes that cipher active (`keyManager.setActive(id:)`), switches to encode mode, and drops to the editor so the user can type their reply. (`returnToEditing()` and `setActive(id:)` already exist.)

```swift
        .onReceive(NotificationCenter.default.publisher(for: .openLibraryRequested)) { _ in
            showLibrary = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .replyToMessageRequested)) { note in
            guard let cipherID = note.object as? UUID else { return }
            keyManager.setActive(id: cipherID)
            mode = .encode
            if !isEditing { returnToEditing() }
        }
```

- [ ] **6. Regenerate the project** (a new `.swift` file was added; sources are globbed):

```bash
cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate
```

Expected: `Created project at .../RuneScrib.xcodeproj` (the committed `.pbxproj` now references `ReceivedMessageView.swift`).

- [ ] **7. Build-verify both platforms.** No unit test — `ReceivedMessageView` and the `RootView`/`ContentView` wiring are scene-level SwiftUI.

```bash
cd /Volumes/NVME/GitHub/rune-scrib && xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. Then the iOS build check:

```bash
cd /Volumes/NVME/GitHub/rune-scrib && xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-iOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **8. Manual verification checklist** (run the app; perform with at least one cipher imported and one inbound message link — e.g. paste a `https://ravenforgesoftware.com/rune-scribe/m?...` URL produced by Task 5/6 onto the clipboard, then foreground the app, or tap the link from Messages):
  - [ ] Tapping/opening a valid message link presents the `ReceivedMessageView` sheet (navy background, "MESSAGE" header) showing the correct sender name and the decrypted plaintext in the "Decoded Message" panel.
  - [ ] The "Decoded with the … cipher" footnote names the cipher that authenticated.
  - [ ] If the app is locked or the splash is still playing, the sheet does **not** appear; it presents the moment the app unlocks / the splash ends (same gating as cipher import). Confirm by locking with a PIN, opening a link, then unlocking.
  - [ ] **Close** dismisses the sheet and clears `messageCoordinator.pending` (re-opening the same link presents it again; a second tap of the identical URL without dismissing does not stack a duplicate, per the coordinator's `lastHandledURL` dedup).
  - [ ] **Reply** dismisses the sheet, switches the active-cipher bar in `ContentView` to the message's cipher, sets the mode picker to **Encode**, and lands on the editable text box (not a stale result), ready for the user to type a reply.
  - [ ] If the reply cipher is linked to a contact, the "To: …" recipient line appears under the active-cipher bar.
  - [ ] An import-cipher link still routes to `ImportConfirmView` (not the message sheet) — `LinkRouter` classification is correct.
  - [ ] On macOS, no `MessageUI`/iOS-only symbols are referenced (build above already proves this; spot-check that `ReceivedMessageView` compiles without `#if os(...)` guards since it is platform-neutral).

- [ ] **9. Commit** (no AI attribution; conventional-commit style):

```bash
cd /Volumes/NVME/GitHub/rune-scrib && git add RuneScrib/Views/ReceivedMessageView.swift RuneScrib/Views/RootView.swift RuneScrib/Views/ContentView.swift RuneScrib/App/RuneScribApp.swift RuneScrib.xcodeproj/project.pbxproj && git commit -m "feat: present decrypted inbound messages with a reply path

Add ReceivedMessageView (sender + decrypted plaintext, Close/Reply),
host it app-wide from RootView behind the same splash/lock gate as the
cipher-import sheet, wire MessageCoordinator into the environment, and
route inbound URLs through LinkRouter. Reply switches ContentView to the
message's cipher via a .replyToMessageRequested notification and focuses
compose."
```

---

### Task 8: MessageSend builder + Send UI (Share both platforms, iMessage iOS)

Wires the composed runes into a sendable link and native send affordances. `MessageSend` is the pure builder (unit-tested): it turns a rune string + cipher into a `MessageSharePayload`, deciding whether to embed the cipher key. `MessageComposeView` is the iOS `MFMessageComposeViewController` wrapper. `ContentView`'s `.result` button row gains a cross-platform `ShareLink` (sharing the `MessageSharePayload.url`) and an iOS-only "Send via iMessage" button that prefills the body with the runes + link and, on success, calls `keyManager.markDelivered(cipherID:)`. A light "Key included" vs "Uses your shared key" indicator tells the sender what is being transmitted.

Depends on (from earlier Phase 4 tasks, must already exist on `feature/messages`): `MessageSharePayload` (Models/MessageSharePayload.swift), `Cipher.delivered`, `CipherLibrary.markingDelivered`, `KeyManager.markDelivered(cipherID:)`, `CipherSharePayload` (already shipped). `MessageComposeView` is created here.

**Files:**
- Create: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/MessageSend.swift`
- Create: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Views/Components/MessageComposeView.swift`
- Create: `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageSendTests.swift`
- Modify: `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Views/ContentView.swift`
  - new `@State` flags near the other `@State` vars (~lines 30–40)
  - `.result` button row HStack (~lines 210–228) — append Share + iMessage buttons + key indicator
  - new helpers in the `// MARK: - Actions` section (~after line 345, before the closing `}`)
  - `.sheet` flag for the iOS compose controller (~near the existing `.sheet(isPresented:)` block, ~lines 99–103)

---

1. - [ ] **Write failing test — `shouldIncludeKey` truth table.** Create `/Volumes/NVME/GitHub/rune-scrib/RuneScribTests/MessageSendTests.swift`:
   ```swift
   import XCTest
   @testable import RuneScrib

   final class MessageSendTests: XCTestCase {

       // includeKey iff the cipher is contact-linked AND not yet delivered.
       func testShouldIncludeKeyTruthTable() throws {
           let contactID = UUID()

           var linkedUndelivered = Cipher.generated(label: "A")
           linkedUndelivered.contactID = contactID
           XCTAssertTrue(MessageSend.shouldIncludeKey(linkedUndelivered))

           var linkedDelivered = Cipher.generated(label: "B")
           linkedDelivered.contactID = contactID
           linkedDelivered.delivered = true
           XCTAssertFalse(MessageSend.shouldIncludeKey(linkedDelivered))

           let unlinked = Cipher.generated(label: "C")  // contactID nil, delivered false
           XCTAssertFalse(MessageSend.shouldIncludeKey(unlinked))
       }
   }
   ```

2. - [ ] **Run (expect fail).** `MessageSend` does not exist yet — compile error.
   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate && xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/MessageSendTests test 2>&1 | tail -20
   ```
   Expected: build/compile failure — `cannot find 'MessageSend' in scope` (** TEST FAILED **).

3. - [ ] **Minimal impl — `MessageSend`.** Create `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Services/MessageSend.swift`:
   ```swift
   import Foundation

   /// Pure builder that turns a composed rune string + its cipher into a sendable
   /// `MessageSharePayload`, deciding whether to ride along the cipher key.
   enum MessageSend {

       /// Embed the key only when the cipher belongs to a known contact and we have
       /// not yet successfully handed it to them (first delivery bootstraps the key).
       static func shouldIncludeKey(_ cipher: Cipher) -> Bool {
           cipher.contactID != nil && !cipher.delivered
       }

       /// Re-derives the raw envelope from the decorated runes (round-trips the codec),
       /// then wraps it — with the cipher key when `includeKey` — into a share payload.
       static func payload(runes: String,
                           senderName: String,
                           cipher: Cipher,
                           includeKey: Bool) throws -> MessageSharePayload {
           let envelope = try RuneCodec().decode(runes, with: cipher)
           let embeddedCipher = includeKey ? CipherSharePayload(cipher: cipher) : nil
           return MessageSharePayload(senderName: senderName,
                                      envelope: envelope,
                                      embeddedCipher: embeddedCipher)
       }
   }
   ```

4. - [ ] **Run (expect pass).**
   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate && xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/MessageSendTests test 2>&1 | tail -20
   ```
   Expected: ** TEST SUCCEEDED **.

5. - [ ] **Write failing test — `payload` round-trips the plaintext and gates the embedded cipher.** Append to `MessageSendTests.swift` (after the `final class { … }` body, as an extension):
   ```swift
   extension MessageSendTests {

       // The envelope inside the payload must decrypt back to the original plaintext
       // under the same cipher (MessageSend.payload is exactly the inverse of compose).
       func testPayloadEnvelopeRoundTripsPlaintext() throws {
           let cipher = Cipher.generated(label: "RT")
           let plaintext = "meet at the standing stones ᛥ"
           let runes = try MessageService().compose(plaintext, with: cipher)

           let payload = try MessageSend.payload(runes: runes,
                                                 senderName: "Freya",
                                                 cipher: cipher,
                                                 includeKey: false)

           let (decoded, used) = try MessageService().read(envelope: payload.envelope,
                                                           tryingCiphers: [cipher])
           XCTAssertEqual(decoded, plaintext)
           XCTAssertEqual(used.id, cipher.id)
       }

       // embeddedCipher present iff includeKey, and it carries this cipher's key material.
       func testPayloadEmbedsCipherOnlyWhenIncludeKey() throws {
           let cipher = Cipher.generated(label: "Embed")
           let runes = try MessageService().compose("hi", with: cipher)

           let without = try MessageSend.payload(runes: runes, senderName: "S",
                                                 cipher: cipher, includeKey: false)
           XCTAssertNil(without.embeddedCipher)

           let with = try MessageSend.payload(runes: runes, senderName: "S",
                                              cipher: cipher, includeKey: true)
           XCTAssertNotNil(with.embeddedCipher)
           XCTAssertEqual(with.embeddedCipher?.keyMaterial, cipher.keyMaterial)
           XCTAssertEqual(with.embeddedCipher?.publicID, cipher.publicID)
       }
   }
   ```

6. - [ ] **Run (expect pass).** No new production code is needed — these tests pin behavior `MessageSend.payload` already provides (relies on `MessageService.read(envelope:tryingCiphers:)` from an earlier Phase 4 task).
   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' -only-testing:RuneScribTests/MessageSendTests test 2>&1 | tail -20
   ```
   Expected: ** TEST SUCCEEDED **. (If `with.embeddedCipher` fails because `CipherSharePayload(cipher:)` ever changes the stored key, that is a real regression — investigate before proceeding.)

7. - [ ] **Commit the builder + tests.**
   ```bash
   cd /Volumes/NVME/GitHub/rune-scrib && git add RuneScrib/Services/MessageSend.swift RuneScribTests/MessageSendTests.swift RuneScrib.xcodeproj/project.pbxproj && git commit -m "feat: add MessageSend builder for outbound message payloads"
   ```

8. - [ ] **Build-verified UI — `MessageComposeView` (iOS MFMessageComposeViewController wrapper).** Create `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Views/Components/MessageComposeView.swift`. Whole file is `#if os(iOS)` so it is excluded from the macOS test target:
   ```swift
   #if os(iOS)
   import SwiftUI
   import MessageUI

   /// Thin SwiftUI bridge to the system Messages compose sheet. Presents a prefilled
   /// draft (runes + import link); the user taps Send in Apple's own UI.
   struct MessageComposeView: UIViewControllerRepresentable {
       var body: String
       var recipients: [String]?
       var onFinish: (() -> Void)?

       /// Whether this device can send texts at all (no SIM / Simulator → false).
       static var canSend: Bool { MFMessageComposeViewController.canSendText() }

       func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

       func makeUIViewController(context: Context) -> MFMessageComposeViewController {
           let vc = MFMessageComposeViewController()
           vc.messageComposeDelegate = context.coordinator
           vc.body = body
           if let recipients { vc.recipients = recipients }
           return vc
       }

       func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

       final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
           let onFinish: (() -> Void)?
           init(onFinish: (() -> Void)?) { self.onFinish = onFinish }

           func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                             didFinishWith result: MessageComposeResult) {
               // Only treat an actual send as delivery; cancelled/failed leave state alone.
               let sent = (result == .sent)
               controller.dismiss(animated: true) { if sent { self.onFinish?() } }
           }
       }
   }
   #endif
   ```

9. - [ ] **Modify `ContentView` — state flags + key indicator.** In `/Volumes/NVME/GitHub/rune-scrib/RuneScrib/Views/ContentView.swift`, add `@State` flags next to the existing ones (after `@State private var decodeError: String?` ~line 40):
   ```swift
   @State private var showMessageCompose = false
   ```
   Then add a computed helper alongside the other private computed vars (e.g. just below `private var actionDisabled: …`, ~line 47):
   ```swift
   /// The cipher used to produce the current result snapshot (encode only).
   private var resultCipher: Cipher? {
       transformDirection == .encode ? keyManager.activeCipher : nil
   }

   /// Builds the share payload for the current runes; nil when not on an encode result.
   private func messageShareURL() -> URL? {
       guard transformDirection == .encode, let cipher = resultCipher else { return nil }
       let include = MessageSend.shouldIncludeKey(cipher)
       guard let payload = try? MessageSend.payload(runes: targetSnapshot,
                                                    senderName: cipher.label,
                                                    cipher: cipher,
                                                    includeKey: include),
             let url = try? payload.url(name: cipher.label) else { return nil }
       return url
   }
   ```

10. - [ ] **Modify `ContentView` — `.result` button row gains Share + iMessage + indicator.** Replace the `.result` case body (~lines 210–228) so the existing Edit/Copy `HStack(spacing: 14)` is wrapped in a `VStack` that adds the new affordances. New `.result` case:
    ```swift
        case .result:
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    Button {
                        returnToEditing()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())

                    Button {
                        confirmCopy()
                    } label: {
                        Label(copyConfirmed ? "Copied!" : (transformDirection == .encode ? "Copy Runes" : "Copy Text"),
                              systemImage: copyConfirmed ? "checkmark.circle.fill" : "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneScribButtonStyle())
                }

                if transformDirection == .encode, let url = messageShareURL() {
                    HStack(spacing: 14) {
                        ShareLink(item: url,
                                  subject: Text("Rune Scribe message"),
                                  message: Text("A message in runes — open in Rune Scribe to read.")) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneSecondaryButtonStyle())

                        #if os(iOS)
                        if MessageComposeView.canSend {
                            Button {
                                showMessageCompose = true
                            } label: {
                                Label("Send via iMessage", systemImage: "message.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(RuneScribButtonStyle())
                        }
                        #endif
                    }

                    keyIndicator(for: resultCipher)
                }
            }
    ```
    Because the `.result` case is now taller than 46pt, relax the fixed height on `actionArea` so the extra row is not clipped: change `.frame(height: 46)` (~line 96) to `.frame(minHeight: 46)`.

11. - [ ] **Modify `ContentView` — key indicator + iMessage sheet + send handler.** Add to the `// MARK: - Actions` section (after `confirmCopy()`, ~line 345, before the final closing `}` of the struct):
    ```swift
    /// A light line telling the sender whether this message carries the cipher key.
    @ViewBuilder
    private func keyIndicator(for cipher: Cipher?) -> some View {
        if let cipher {
            let included = MessageSend.shouldIncludeKey(cipher)
            HStack(spacing: 6) {
                Image(systemName: included ? "key.fill" : "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(included ? .runeGold : .runeBlue)
                Text(included ? "Key included" : "Uses your shared key")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.runeSilver)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    #if os(iOS)
    /// Body for the system Messages sheet: the runes, a blank line, then the link.
    private func messageBody() -> String {
        guard let url = messageShareURL() else { return targetSnapshot }
        return "\(targetSnapshot)\n\n\(url.absoluteString)"
    }

    /// Phone numbers + emails of the active cipher's linked contact, if any.
    private func messageRecipients() -> [String]? {
        guard let contact = contactManager.contact(id: resultCipher?.contactID) else { return nil }
        let all = contact.phones + contact.emails
        return all.isEmpty ? nil : all
    }

    /// Called when Apple's compose sheet reports an actual send: mark the key delivered.
    private func handleMessageSent() {
        if let cipher = resultCipher { keyManager.markDelivered(cipherID: cipher.id) }
    }
    #endif
    ```
    Then attach the compose sheet next to the existing `.sheet(isPresented: $showSettings)` (~line 102):
    ```swift
        #if os(iOS)
        .sheet(isPresented: $showMessageCompose) {
            MessageComposeView(body: messageBody(),
                               recipients: messageRecipients(),
                               onFinish: handleMessageSent)
        }
        #endif
    ```

12. - [ ] **Regenerate the project (new files added).**
    ```bash
    cd /Volumes/NVME/GitHub/rune-scrib && xcodegen generate
    ```

13. - [ ] **Build both platforms.** macOS (no MessageUI; Share-only path):
    ```bash
    cd /Volumes/NVME/GitHub/rune-scrib && xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' build 2>&1 | tail -20
    ```
    iOS (compiles the `#if os(iOS)` MessageUI path):
    ```bash
    cd /Volumes/NVME/GitHub/rune-scrib && xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-iOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
    ```
    Expected: ** BUILD SUCCEEDED ** on both.

14. - [ ] **Manual verification checklist** (run iOS sim + macOS app):
    - Encode a message with an **unlinked** cipher → result row shows a **Share** button and the indicator reads **"Uses your shared key"** (lock icon); Share sheet's link opens to `https://ravenforgesoftware.com/rune-scribe/m?...` with no `n=` cipher payload bloat.
    - Encode with a **contact-linked, not-yet-delivered** cipher → indicator reads **"Key included"** (key icon); on iOS the **Send via iMessage** button appears.
    - iOS: tap **Send via iMessage** → Apple's compose sheet opens prefilled with the runes, a blank line, then the link; recipient field is pre-populated from the linked contact's phone/email.
    - iOS: actually **send** the draft → after dismiss, re-encode the same cipher → indicator now reads **"Uses your shared key"** (delivery flipped `cipher.delivered`); **cancel** instead of send → indicator stays **"Key included"** (no spurious delivery).
    - macOS: only the **Share** button shows (no iMessage button); Share works via the system share sheet.
    - Decode-mode result row is unchanged (no Share/iMessage/indicator on a `.decode` result).

15. - [ ] **Commit the Send UI.**
    ```bash
    cd /Volumes/NVME/GitHub/rune-scrib && git add RuneScrib/Views/Components/MessageComposeView.swift RuneScrib/Views/ContentView.swift RuneScrib.xcodeproj/project.pbxproj && git commit -m "feat: add Share + iMessage send affordances with key-delivery indicator"
    ```

---

### Task 9: associated-domains entitlement (app side of Universal Links)

The website-side Universal Links handshake (the AASA file) is wired up so iOS/macOS hand `https://ravenforgesoftware.com/rune-scribe/m` and `/import` URLs to the app instead of opening Safari. The app half of that handshake is the `com.apple.developer.associated-domains` entitlement, which must be present in **both** target entitlement plists, wired through `project.yml`, and carried into the signed app. This is config + build-verification only — there is no unit test (entitlements are inert plist data the OS reads at install time). It only takes real effect once the website AASA (Task 10) is published at `https://ravenforgesoftware.com/.well-known/apple-app-site-association` **and** the app is signed with the matching team (`9AQ2C2838M`) and a provisioning profile that grants the Associated Domains capability.

**Files:**
- Modify: `Config/RuneScrib-iOS.entitlements` — `<dict>` body (lines 4–13); ensure `com.apple.developer.associated-domains` array is the first key, alongside the existing `keychain-access-groups`.
- Modify: `Config/RuneScrib-macOS.entitlements` — `<dict>` body (lines 4–15); ensure `com.apple.developer.associated-domains` array is present alongside the existing `com.apple.security.app-sandbox` / `personal-information.addressbook` / `files.user-selected.read-write` keys.
- Verify-only (no edit expected): `project.yml` — macOS target `CODE_SIGN_ENTITLEMENTS: Config/RuneScrib-macOS.entitlements` (line ~60) and iOS target `CODE_SIGN_ENTITLEMENTS: Config/RuneScrib-iOS.entitlements` (line ~107).

Steps:

1. - [ ] **Confirm project.yml already points each target at its entitlements file.** This wiring is a prerequisite — without it `xcodebuild` never reads the plist. Inspect, do not edit unless a line is missing:
   ```bash
   grep -n "CODE_SIGN_ENTITLEMENTS" project.yml
   ```
   Expected output (two lines, one per target):
   ```
   60:        CODE_SIGN_ENTITLEMENTS: Config/RuneScrib-macOS.entitlements
   107:        CODE_SIGN_ENTITLEMENTS: Config/RuneScrib-iOS.entitlements
   ```
   If either line is absent, add it under the matching target's `settings.base:` block (sibling of `CODE_SIGN_STYLE`/`CODE_SIGN_IDENTITY`), preserving exact YAML indentation, then continue.

2. - [ ] **Ensure the iOS entitlement plist declares the associated domain.** The full intended file (`Config/RuneScrib-iOS.entitlements`) — the `associated-domains` array sits alongside the pre-existing `keychain-access-groups`:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
   	<key>com.apple.developer.associated-domains</key>
   	<array>
   		<string>applinks:ravenforgesoftware.com</string>
   	</array>
   	<key>keychain-access-groups</key>
   	<array>
   		<string>$(AppIdentifierPrefix)com.runescribe.app</string>
   	</array>
   </dict>
   </plist>
   ```
   The `applinks:` prefix (not `webcredentials:`) is what routes Universal Links; the host has no scheme/path. Leave `keychain-access-groups` untouched (it backs the iOS keychain entitlement from a prior phase).

3. - [ ] **Ensure the macOS entitlement plist declares the same domain.** The full intended file (`Config/RuneScrib-macOS.entitlements`) — `associated-domains` joins the existing sandbox / address-book / file-access keys:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
   	<key>com.apple.developer.associated-domains</key>
   	<array>
   		<string>applinks:ravenforgesoftware.com</string>
   	</array>
   	<key>com.apple.security.app-sandbox</key>
   	<true/>
   	<key>com.apple.security.personal-information.addressbook</key>
   	<true/>
   	<key>com.apple.security.files.user-selected.read-write</key>
   	<true/>
   </dict>
   </plist>
   ```
   Use the identical `applinks:ravenforgesoftware.com` value as iOS so a single AASA covers both platforms. Do not drop the sandbox keys — removing `com.apple.security.app-sandbox` would break the existing macOS build's entitlements contract.

4. - [ ] **Validate both plists are well-formed.** A malformed entitlements plist fails the build late and cryptically; catch it up front with `plutil`:
   ```bash
   plutil -lint Config/RuneScrib-iOS.entitlements Config/RuneScrib-macOS.entitlements
   ```
   Expected (both files):
   ```
   Config/RuneScrib-iOS.entitlements: OK
   Config/RuneScrib-macOS.entitlements: OK
   ```
   Then confirm the key actually parsed into each plist's object graph:
   ```bash
   plutil -extract com.apple.developer.associated-domains xml1 -o - Config/RuneScrib-iOS.entitlements
   plutil -extract com.apple.developer.associated-domains xml1 -o - Config/RuneScrib-macOS.entitlements
   ```
   Each must print an `<array>` containing `<string>applinks:ravenforgesoftware.com</string>` (exit code 0). A non-zero exit means the key is missing — return to step 2/3.

5. - [ ] **Regenerate the Xcode project.** No new source files were added, but `project.yml`/entitlement references must be reflected in the committed `.pbxproj` (sources are globbed; entitlement paths are baked into build settings):
   ```bash
   xcodegen generate
   ```
   Expected tail: `Created project at .../RuneScrib.xcodeproj`. Sanity-check the entitlement path landed in build settings for both targets:
   ```bash
   grep -c "CODE_SIGN_ENTITLEMENTS = Config/RuneScrib-\(iOS\|macOS\).entitlements" RuneScrib.xcodeproj/project.pbxproj
   ```
   Expect a count of `2` (one per target; Debug+Release may double it — any count `>= 2` is acceptable, `0` is a failure).

6. - [ ] **Build-verify the macOS target carries the entitlement.** Build, then read the entitlements back out of the produced binary with `codesign`:
   ```bash
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' build 2>&1 | tail -5
   ```
   Expect `** BUILD SUCCEEDED **`. Locate the built app and dump its embedded entitlements:
   ```bash
   APP=$(xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -showBuildSettings 2>/dev/null \
     | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')
   codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p -
   ```
   The printed dictionary must include:
   ```
   "com.apple.developer.associated-domains" => [
     0 => "applinks:ravenforgesoftware.com"
   ]
   ```
   alongside the sandbox keys. If the app is built with the ad-hoc identity (`-`) the OS will not *enforce* the capability until properly provisioned (see the team/AASA note above), but the entitlement string must still be embedded — that embedding is what this step verifies.

7. - [ ] **Build-verify the iOS target compiles with the entitlement.** A device/simulator build will not exercise the App Group/provisioning side, but it confirms the entitlement plist doesn't break the iOS build graph:
   ```bash
   xcodebuild -project RuneScrib.xcodeproj -scheme RuneScrib-iOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
   ```
   Expect `** BUILD SUCCEEDED **`. (A simulator/unsigned build embeds the entitlements without requiring the Associated Domains capability on the profile; full enforcement arrives only on a real device signed with team `9AQ2C2838M`.)

8. - [ ] **Manual verification checklist** (confirm before committing):
   - `plutil -lint` reports `OK` for both `Config/RuneScrib-iOS.entitlements` and `Config/RuneScrib-macOS.entitlements`.
   - `plutil -extract com.apple.developer.associated-domains …` prints the `applinks:ravenforgesoftware.com` array for **both** files.
   - `project.yml` sets `CODE_SIGN_ENTITLEMENTS` to the matching plist for **both** the `RuneScrib-iOS` and `RuneScrib-macOS` targets.
   - `xcodebuild … -scheme RuneScrib-macOS … build` → `** BUILD SUCCEEDED **`, and `codesign -d --entitlements` on the product shows the `associated-domains` array.
   - `xcodebuild … -scheme RuneScrib-iOS … build` → `** BUILD SUCCEEDED **`.
   - Pre-existing entitlements (iOS `keychain-access-groups`; macOS `app-sandbox`, `personal-information.addressbook`, `files.user-selected.read-write`) are all still present — nothing was removed.
   - **Out-of-band reminder (not a code change here):** routing only works end-to-end once Task 10 publishes the AASA at `https://ravenforgesoftware.com/.well-known/apple-app-site-association` (served as `application/json`, listing appID `9AQ2C2838M.com.runescribe.app` with paths `/rune-scribe/m*` and `/rune-scribe/import*`) and the app is installed signed with a provisioning profile granting Associated Domains.

9. - [ ] **Commit.** Stage the config (and the regenerated project file, since its checksum changes on every `xcodegen generate`):
   ```bash
   git add Config/RuneScrib-iOS.entitlements Config/RuneScrib-macOS.entitlements project.yml RuneScrib.xcodeproj/project.pbxproj
   git commit -m "feat: add associated-domains entitlement for ravenforgesoftware.com universal links"
   ```
   (No AI attribution — the CI guard rejects `Co-Authored-By`/tool-name footers. Author is preconfigured.)

---

### Task 10: Website: apple-app-site-association + /rune-scribe/ no-app fallback (cross-repo, site bridge)

**Cross-repo / website-only task.** No changes land in `/Volumes/NVME/GitHub/rune-scrib`. All work is done against **ravenforgesoftware.com** via the **site bridge** WordPress REST plugin (see memory `ravenforge-site-bridge`). The app-side entitlement (`com.apple.developer.associated-domains = ["applinks:ravenforgesoftware.com"]` in both `Config/*.entitlements`) is already shipped by the entitlements task — this task makes the **server** half of the Universal Link contract work and gives no-app visitors a sane landing.

> **Prereq — bridge auth.** This task needs a live `X-Site-Bridge-Key` token (provided per-session by the user; not persisted). All `curl` calls below assume it is exported once:
> ```bash
> export RF_BRIDGE_KEY='<token-from-user>'
> export RF_BASE='https://ravenforgesoftware.com/wp-json/site-bridge/v1'
> ```
>
> **Why a WP handler, not a static file.** Verified 2026-06-26: the site's docroot does NOT serve arbitrary static files — `GET /robots.txt` returns `content-type: text/html` (WordPress intercepts it), and `GET /.well-known/apple-app-site-association` 404s through WP. The bridge `files` root is `wp-content` (NOT the docroot), so a file dropped via the bridge would not be reachable at `/.well-known/...` anyway. The robust, bridge-only fix is a `template_redirect` handler in the theme that emits the JSON with `Content-Type: application/json`. This mirrors the favicon fix pattern (a `functions.php` edit applied via `POST /files/write`).

**Files (all on ravenforgesoftware.com, via bridge — no local repo files):**
- Modify (via `POST /files/write`, full overwrite): `themes/ravenforge/functions.php` — append an AASA `template_redirect` handler (and matching `init` rewrite rule). Anchor: end of file, after the existing `get_site_icon_url` favicon filter added in the 2026-06-20 favicon fix.
- Verify-only (no edit expected): `/rune-scribe/` page (WP page id 93, default template, `wp:html` content) — confirm no-app fallback content + company link; confirm it renders no query-param/per-message payload. Edit via `PUT /pages/93` ONLY if the company link is found missing.
- Snapshot (local, before risky edit): `/Volumes/NVME/SiteBridge/.rf-snapshots/aasa-<timestamp>/` — capture `functions.php` source, the rendered `/rune-scribe/` HTML, and the page 93 record.

> Note: this is config/content infra on a live WordPress site, not Swift logic — there is no XCTest. "Tests" here are `curl` assertions against the live endpoints (the web analog of build-verified UI). Each step shows the exact command and the expected response, then a commit-equivalent (the bridge `POST /flush/cache` + a `git`-free record). Because the work is on a remote host there is no `git commit`; the completion record is the snapshot dir + a memory upsert.

Steps:

- [ ] **1. Snapshot before editing (required by the bridge convention).** Capture the three artifacts so the `functions.php` overwrite is reversible.
  ```bash
  TS=$(date +%Y%m%dT%H%M%S)
  SNAP="/Volumes/NVME/SiteBridge/.rf-snapshots/aasa-$TS"
  mkdir -p "$SNAP"
  # theme functions.php (bridge files root is wp-content; path is relative to it)
  curl -s -X POST "$RF_BASE/files/read" \
    -H "X-Site-Bridge-Key: $RF_BRIDGE_KEY" -H 'Content-Type: application/json' \
    -d '{"path":"themes/ravenforge/functions.php"}' \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("content",""))' > "$SNAP/functions.php"
  # rendered rune-scribe page + page record
  curl -s "https://ravenforgesoftware.com/rune-scribe/" > "$SNAP/rune-scribe.html"
  curl -s "$RF_BASE/pages/93" -H "X-Site-Bridge-Key: $RF_BRIDGE_KEY" > "$SNAP/page-93.json"
  ls -la "$SNAP"
  ```
  Expected: three non-empty files in `$SNAP` (`functions.php` > 0 bytes, `rune-scribe.html` containing `<title>Rune Scribe`, `page-93.json` valid JSON). **Stop and re-check auth** if `functions.php` is empty (bad/expired bridge key).

- [ ] **2. Failing "test": prove the AASA is absent and wrong-typed.** This is the red state.
  ```bash
  curl -sI "https://ravenforgesoftware.com/.well-known/apple-app-site-association"
  ```
  Expected (RED): `HTTP/2 404` and `content-type: text/html; charset=UTF-8`. (Confirmed 2026-06-26.) The Universal Link cannot work in this state — Apple's CDN fetches this exact path and requires `200` + `application/json` with no redirect.

- [ ] **3. Minimal impl: add the AASA handler to `functions.php`.** Read the current file (from the snapshot in step 1 — `$SNAP/functions.php`), then re-write it with the handler appended at the very end (before any closing `?>` if present; the file is pure PHP and conventionally has no closing tag). The handler is self-contained: it hooks `init` to register a rewrite-free early intercept on `template_redirect` and matches the request path directly off `$_SERVER['REQUEST_URI']`, so it does NOT depend on WP rewrite rules being flushed (which the bridge cannot trigger). Append exactly:
  ```php

  /**
   * Serve the Apple App Site Association file for Rune Scribe Universal Links.
   * ravenscribe Phase 4: maps applinks:ravenforgesoftware.com to the app.
   * Must return 200 + application/json with NO redirect at the exact path
   * /.well-known/apple-app-site-association (no file extension).
   */
  add_action( 'template_redirect', 'ravenforge_apple_app_site_association', 0 );
  function ravenforge_apple_app_site_association() {
      $path = parse_url( $_SERVER['REQUEST_URI'] ?? '', PHP_URL_PATH );
      if ( $path !== '/.well-known/apple-app-site-association' ) {
          return;
      }
      $aasa = array(
          'applinks' => array(
              'details' => array(
                  array(
                      'appIDs'     => array( '9AQ2C2838M.com.runescribe.app' ),
                      'components' => array(
                          array( '/' => '/rune-scribe/import*' ),
                          array( '/' => '/rune-scribe/m*' ),
                      ),
                  ),
              ),
          ),
      );
      // Apple fetches this directly; serve clean JSON, no caching surprises.
      if ( ! headers_sent() ) {
          status_header( 200 );
          nocache_headers();
          header( 'Content-Type: application/json' );
      }
      echo wp_json_encode( $aasa );
      exit;
  }
  ```
  Build the new file body locally and push it (full overwrite — `POST /files/write` is `file_put_contents`, text-only, no sanitization, `.php` allowed):
  ```bash
  # Append the handler to the snapshot copy, then write the whole file back.
  NEW="$SNAP/functions.php.new"
  cp "$SNAP/functions.php" "$NEW"
  cat >> "$NEW" <<'PHP'

/**
 * Serve the Apple App Site Association file for Rune Scribe Universal Links.
 * ravenscribe Phase 4: maps applinks:ravenforgesoftware.com to the app.
 * Must return 200 + application/json with NO redirect at the exact path
 * /.well-known/apple-app-site-association (no file extension).
 */
add_action( 'template_redirect', 'ravenforge_apple_app_site_association', 0 );
function ravenforge_apple_app_site_association() {
    $path = parse_url( $_SERVER['REQUEST_URI'] ?? '', PHP_URL_PATH );
    if ( $path !== '/.well-known/apple-app-site-association' ) {
        return;
    }
    $aasa = array(
        'applinks' => array(
            'details' => array(
                array(
                    'appIDs'     => array( '9AQ2C2838M.com.runescribe.app' ),
                    'components' => array(
                        array( '/' => '/rune-scribe/import*' ),
                        array( '/' => '/rune-scribe/m*' ),
                    ),
                ),
            ),
        ),
    );
    if ( ! headers_sent() ) {
        status_header( 200 );
        nocache_headers();
        header( 'Content-Type: application/json' );
    }
    echo wp_json_encode( $aasa );
    exit;
}
PHP
  # Write back via the bridge (content is sent as a JSON string field).
  python3 - "$NEW" <<'PY'
  import json,sys
  body=open(sys.argv[1]).read()
  print(json.dumps({"path":"themes/ravenforge/functions.php","content":body}))
  PY
  ```
  Then POST that JSON:
  ```bash
  python3 - "$NEW" <<'PY' | curl -s -X POST "$RF_BASE/files/write" \
        -H "X-Site-Bridge-Key: $RF_BRIDGE_KEY" -H 'Content-Type: application/json' -d @-
  import json,sys
  body=open(sys.argv[1]).read()
  sys.stdout.write(json.dumps({"path":"themes/ravenforge/functions.php","content":body}))
  PY
  echo   # expect a JSON success payload from the bridge files/write endpoint
  ```
  Then flush WP cache:
  ```bash
  curl -s -X POST "$RF_BASE/flush/cache" -H "X-Site-Bridge-Key: $RF_BRIDGE_KEY"; echo
  ```

- [ ] **4. Green "test": AASA returns 200 + application/json, valid body, no redirect.**
  ```bash
  echo "--- headers ---"
  curl -sI "https://ravenforgesoftware.com/.well-known/apple-app-site-association"
  echo "--- body (must be valid JSON, exact appID + components) ---"
  curl -s "https://ravenforgesoftware.com/.well-known/apple-app-site-association" | python3 -m json.tool
  echo "--- no-redirect check (Apple does NOT follow 301/302 for AASA) ---"
  curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
    "https://ravenforgesoftware.com/.well-known/apple-app-site-association"
  ```
  Expected (GREEN):
  - Headers: `HTTP/2 200` and `content-type: application/json` (NOT `text/html`).
  - Body pretty-prints as:
    ```json
    {
        "applinks": {
            "details": [
                {
                    "appIDs": ["9AQ2C2838M.com.runescribe.app"],
                    "components": [
                        {"/": "/rune-scribe/import*"},
                        {"/": "/rune-scribe/m*"}
                    ]
                }
            ]
        }
    }
    ```
  - No-redirect line prints `200` with an empty redirect_url. If it shows `301`/`302`, the `template_redirect`-priority-0 hook is being beaten by a canonical-redirect plugin — move the hook earlier (`add_action('init', ...)` echoing + `exit` before WP's canonical pass) and re-test.

- [ ] **5. Verify the `/rune-scribe/` no-app fallback (no per-message payload, clear company link).** A visitor who tapped a `…/rune-scribe/import*` or `…/rune-scribe/m*` link WITHOUT the app installed is handled by iOS as a normal web visit to that path. There is no App Store page yet, so the fallback must show product info + a clear link to the company. The `/rune-scribe/` page (id 93) already renders product info and CTAs to `/products/` and `/contact/`; this step asserts that and that it never echoes a payload.
  ```bash
  PAGE=$(curl -s "https://ravenforgesoftware.com/rune-scribe/")
  echo "--- product info present ---"
  echo "$PAGE" | grep -oiE "<title>[^<]*</title>" ; echo "$PAGE" | grep -c "rf-section"
  echo "--- clear company / contact link present ---"
  echo "$PAGE" | grep -oE 'href="/(products|contact)/"' | sort -u
  echo "--- payload-leak guard: page must NOT reflect import/message query params ---"
  curl -s "https://ravenforgesoftware.com/rune-scribe/m?v=1&p=AAAA&n=Mallory" \
    | grep -iE "AAAA|Mallory|\\?p=|v=1&p=" && echo "LEAK FOUND" || echo "no payload reflected (good)"
  ```
  Expected:
  - `<title>Rune Scribe …</title>` present and several `rf-section` blocks (product info renders). (Confirmed 2026-06-26: id 93 renders hero + What-it-is/Features/How-it-works/Sharing/Security/CTA sections.)
  - At least `href="/products/"` and/or `href="/contact/"` printed (the clear company link). If NEITHER prints, the page is missing the company link → do a surgical `PUT /pages/93` adding a fallback line to the CTA section, e.g. insert into the existing CTA block:
    ```html
    <p class="rf-mt-sm">Tapped a Rune Scribe link but don't have the app yet?
    <a href="/products/">See Rune Scribe on Raven Forge Software</a>
    or <a href="/contact/">get in touch</a>.</p>
    ```
    (Edit surgically per the bridge convention: fetch `GET /pages/93`, assert the CTA anchor substring matches exactly once, replace, `PUT /pages/93` with only `content`, then `POST /flush/cache`.)
  - Payload-leak guard prints `no payload reflected (good)`. The page is a static `wp:html` body that never reads `$_GET`, so this should pass with no change; the test exists to lock that invariant (do NOT add any query-param rendering to this page).

- [ ] **6. Commit-equivalent: flush cache, archive the diff, record the decision.** There is no `git` on the remote host; the "commit" is the cache flush plus a local record and a memory note. (No AI attribution anywhere — same rule as the app repo.)
  ```bash
  curl -s -X POST "$RF_BASE/flush/cache" -H "X-Site-Bridge-Key: $RF_BRIDGE_KEY"; echo
  # archive the pushed file alongside the snapshot for an auditable before/after
  cp "$SNAP/functions.php"     "$SNAP/functions.php.before"
  cp "$SNAP/functions.php.new" "$SNAP/functions.php.after"
  diff -u "$SNAP/functions.php.before" "$SNAP/functions.php.after" | tee "$SNAP/functions.diff"
  ```
  Then persist a durable note (memory MCP) so a future session knows the AASA lives in the theme, not a static file:
  - `memory_store { project: "/Volumes/NVME/GitHub/rune-scrib", key: "phase4/aasa-on-ravenforge", type: "reference", tags: "universal-links aasa ravenforge bridge", content: "Rune Scribe AASA is served by a template_redirect priority-0 handler ravenforge_apple_app_site_association() in themes/ravenforge/functions.php (NOT a static /.well-known file — docroot doesn't serve static files; bridge files root is wp-content). Returns 200 + application/json for /.well-known/apple-app-site-association with appIDs:[9AQ2C2838M.com.runescribe.app], components /rune-scribe/import* and /rune-scribe/m*. /rune-scribe/ page (id 93) is the no-app fallback (product info + /products/ + /contact/ links; never reflects query params). Snapshot+diff in /Volumes/NVME/SiteBridge/.rf-snapshots/aasa-<ts>/." }`

- [ ] **7. Flag the deferred Apple-side requirements (out of scope for this website task).** The AASA being correct is necessary but NOT sufficient for Universal Links to actually open the app. Record explicitly in the plan (and tell the user) that final end-to-end behavior additionally requires, OUTSIDE this task:
  - A **real signed build** installed on-device (the `associated-domains` entitlement only takes effect in a properly provisioned build with Team `9AQ2C2838M` / bundle `com.runescribe.app` — already wired in `Config/*.entitlements`, Task earlier). Simulator/dev-unsigned builds do not exercise Apple's AASA fetch.
  - **Apple's AASA CDN cache.** On first install iOS fetches the AASA via Apple's CDN, which caches it; changes can take time to propagate, and during development the device must either reinstall or use a build with `applinks:…?mode=developer` associated-domain to bypass the cache. There is nothing to do on the website for this — note it so a failed first-tap test on-device is not misdiagnosed as a server bug.
  - **When the App Store page exists**, revisit `/rune-scribe/` (id 93) to add a real Download/App Store button to the CTA + the product card on `page-products.php` (per memory `ravenforge-site-bridge`: "a Download button can be dropped into the page CTA + the card once the App Store link exists"). Out of scope now (no live App Store URL).


---

## Risks / notes

- **Build host:** the macOS test host can be slow or hang when run headless/sandboxed (known from prior phases). If `xcodebuild ... test` hangs at host launch, run the suite from a non-sandboxed host; the entitlement is source-inert for cipher/message logic tests.
- **`xcodegen generate` after new files:** the target globs `sources: - path: RuneScrib`, and the `.pbxproj` is committed — every task that **creates** a file must run `xcodegen generate` before building, and commit the regenerated `RuneScrib.xcodeproj/project.pbxproj` alongside the new file.
- **Universal Links** only fully resolve with a real **signed** build + the **live AASA** (Task 10) + Apple's CDN cache warm. Until then the `runescribe://` custom-scheme path still opens the app, so Tasks 6/9/10 are independently committable; the end-to-end tap-to-open is validated manually on device after all three land.
- **`MFMessageComposeViewController` is iOS-only** and cannot send from the simulator — build-verified on simulator, send-verified on device. Guard everything in `#if os(iOS)`.
- **Security posture (per spec decision):** the embedded key in a first message makes that first exchange only as private as the transport channel; the out-of-band QR/file path remains for fully-private key delivery. The UI shows a "key included" vs "uses your shared key" indicator.
- **No AI attribution** in any commit/branch/file (CI `ai-attribution-guard`); merging to `main` triggers `version-bump`.
