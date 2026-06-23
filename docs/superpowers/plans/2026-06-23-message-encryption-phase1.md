# Message Encryption (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Rune Scribe's rune-substitution cipher with real CryptoKit AES-GCM message encryption (one symmetric key per cipher), keeping runes as a decorative layer and keeping every current workflow (create/select/share via QR+deep-link+file, import, app-lock) working.

**Architecture:** A cipher becomes a 256-bit symmetric key + an 8-byte public id + a 32-entry decorative rune permutation. Compose = `AES-GCM seal → version-framed envelope → base32 over a 32-rune alphabet (per-cipher permuted)`. Read = try each stored cipher (`decode runes → unwrap → AES-GCM open`); the AEAD tag authenticates exactly one. Sharing carries a compact binary payload (key + public id + mapping + checksum) over the existing `runescribe://import` URL / QR / file paths.

**Tech Stack:** Swift 6, SwiftUI, CryptoKit (`AES.GCM`, `SymmetricKey`, `SHA256`), XCTest, XcodeGen. Module name `RuneScrib`.

**Design spec:** `docs/superpowers/specs/2026-06-23-runescribe-encryption-phase1-design.md`.

---

## Conventions

- **Module / test import:** `@testable import RuneScrib`. Tests are XCTest (`final class … : XCTestCase`) in `RuneScribTests/`.
- **Run one test** (validated working — forces matching ad-hoc signing so the test bundle loads):
  ```bash
  cd /Volumes/NVME/GitHub/rune-scrib
  xcodebuild test -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
    -only-testing:RuneScribTests/<ClassName>/<testName> \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGNING_REQUIRED=NO 2>&1 \
    | grep -E "Test Case|Executed|TEST (SUCCEEDED|FAILED)|error:" | tail -15
  ```
  Drop `-only-testing:` to run the whole suite. The `linkd.autoShortcut` log lines are harmless headless noise.
- **New source files** under `RuneScrib/` are picked up automatically by XcodeGen (targets glob `path: RuneScrib`), so no `project.yml` edit is needed when adding/removing files. New test files under `RuneScribTests/` are likewise auto-included.
- **No AI attribution** in commits (repo convention): no `Co-Authored-By`, no tool names.
- Commit after each task’s tests pass.

## File structure (locked decomposition)

Create:
- `RuneScrib/Models/Cipher.swift` — the new symmetric cipher value type.
- `RuneScrib/Models/MessageEnvelope.swift` — versioned `[version][sealed]` framing.
- `RuneScrib/Models/CipherSharePayload.swift` — compact share/import payload + URL/file forms.
- `RuneScrib/Services/MessageCryptor.swift` — AES-GCM seal/open.
- `RuneScrib/Services/RuneCodec.swift` — Data ↔ rune-string (base32 over decorative alphabet).
- `RuneScrib/Services/MessageService.swift` — compose / read orchestration (try-all on read).
- Tests: `CipherTests.swift`, `MessageCryptorTests.swift`, `MessageEnvelopeTests.swift`, `RuneCodecTests.swift`, `MessageServiceTests.swift`, `CipherSharePayloadTests.swift` in `RuneScribTests/`.

Modify:
- `RuneScrib/Models/RuneCharacterSet.swift` — add the 32-rune `decorativeAlphabet`.
- `RuneScrib/Models/CipherLibrary.swift` — retype `NamedCipher` → `Cipher`; drop `fromLegacy`.
- `RuneScrib/Services/KeyManager.swift` — own a `Cipher` library; new create/import/share; drop legacy migration.
- `RuneScrib/Services/ImportCoordinator.swift` — carry a parsed `CipherSharePayload`.
- `RuneScrib/Services/Clipboard.swift` — use the scheme constant from `CipherSharePayload`.
- `RuneScrib/Views/ContentView.swift` (compose/read), `CipherLibraryView.swift` (share/export/import), `ImportConfirmView.swift` (confirm import).

Delete (Task 11): `Services/CipherEngine.swift`, `Models/RuneKey.swift`, `Models/RuneKeyExport.swift`, `Models/RuneCipherLink.swift`, `Models/NamedCipher.swift`, `Models/ImportedDecoder.swift`, and obsolete tests `RuneCipherLinkTests.swift`, `DecoderImportTests.swift`, `FriendDecodeRoundTripTests.swift` (+ substitution cases in `CipherLibraryTests.swift`/`RuneScribTests.swift`).

---

### Task 1: Decorative rune alphabet

**Files:** Modify `RuneScrib/Models/RuneCharacterSet.swift` · Test `RuneScribTests/RuneCodecTests.swift` (created here, extended in Task 4).

- [ ] **Step 1: Write the failing test**

```swift
// RuneScribTests/RuneCodecTests.swift
import XCTest
@testable import RuneScrib

final class RuneCodecTests: XCTestCase {
    func testDecorativeAlphabetIs32UniqueRunesWithBroadCoverage() {
        let a = RuneCharacterSet.decorativeAlphabet
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(Set(a).count, 32, "alphabet runes must be unique")
        // Core Elder Futhark range U+16A0...U+16BF — broadly rendered by system fonts.
        for ch in a {
            let v = ch.unicodeScalars.first!.value
            XCTAssertTrue((0x16A0...0x16BF).contains(v), "rune \(ch) outside the broadly-supported range")
        }
    }
}
```

- [ ] **Step 2: Run it — expect FAIL** (`decorativeAlphabet` undefined).

Run the single-test command with `-only-testing:RuneScribTests/RuneCodecTests/testDecorativeAlphabetIs32UniqueRunesWithBroadCoverage`. Expected: compile error / FAIL.

- [ ] **Step 3: Add the alphabet**

```swift
// Append inside `enum RuneCharacterSet { … }` in RuneCharacterSet.swift:

    /// The 32-rune alphabet used by the DECORATIVE base-32 message encoding (not the
    /// cipher). Drawn from U+16A0…U+16BF — core Elder Futhark, broadly covered by
    /// system fonts so messages render consistently even outside Rune Scribe.
    static let decorativeAlphabet: [Character] = (0x16A0...0x16BF).map {
        Character(Unicode.Scalar($0)!)
    }
```

- [ ] **Step 4: Run it — expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add RuneScrib/Models/RuneCharacterSet.swift RuneScribTests/RuneCodecTests.swift
git commit -m "feat: add 32-rune decorative alphabet for message encoding"
```

---

### Task 2: `Cipher` model

**Files:** Create `RuneScrib/Models/Cipher.swift` · Test `RuneScribTests/CipherTests.swift`.

- [ ] **Step 1: Write the failing test**

```swift
// RuneScribTests/CipherTests.swift
import XCTest
import CryptoKit
@testable import RuneScrib

final class CipherTests: XCTestCase {
    func testGeneratedCipherHasValidShape() {
        let c = Cipher.generated(label: "Alice")
        XCTAssertEqual(c.label, "Alice")
        XCTAssertEqual(c.origin, .generated)
        XCTAssertEqual(c.keyMaterial.count, 32)        // AES-256
        XCTAssertEqual(c.publicID.count, 8)
        XCTAssertEqual(c.decorativeMapping.count, 32)
        XCTAssertEqual(Set(c.decorativeMapping), Set(0..<32), "mapping must be a permutation of 0..<32")
    }

    func testTwoGeneratedCiphersDiffer() {
        XCTAssertNotEqual(Cipher.generated(label: "A").keyMaterial,
                          Cipher.generated(label: "B").keyMaterial)
    }

    func testCodableRoundTrip() throws {
        let c = Cipher.generated(label: "Bob")
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Cipher.self, from: data)
        XCTAssertEqual(c, back)
    }

    func testSymmetricKeyMatchesKeyMaterial() {
        let c = Cipher.generated(label: "K")
        let raw = c.symmetricKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(raw, c.keyMaterial)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`Cipher` undefined).

- [ ] **Step 3: Implement**

```swift
// RuneScrib/Models/Cipher.swift
import Foundation
import CryptoKit

/// A Rune Scribe cipher: real symmetric encryption key material plus the
/// decorative rune presentation. Replaces the old permutation-based `RuneKey`/`NamedCipher`.
struct Cipher: Codable, Equatable, Identifiable {

    enum Origin: String, Codable { case generated, imported }

    /// Current on-disk schema version for a cipher.
    static let currentVersion = 1

    let id: UUID
    var label: String
    let origin: Origin
    let createdAt: Date
    let formatVersion: Int

    /// Non-secret 8-byte identity, used only in the share payload (dedup / updated-cipher
    /// recognition). Never placed in messages. Never derived from the key.
    let publicID: Data

    /// The secret AES-256 key (32 bytes). Only ever serialized into the Keychain-encrypted
    /// library and a user-initiated share payload. Never logged.
    let keyMaterial: Data

    /// Permutation of 0..<32: `decorativeMapping[value]` is the index into
    /// `RuneCharacterSet.decorativeAlphabet` that represents that 5-bit value.
    let decorativeMapping: [Int]

    var symmetricKey: SymmetricKey { SymmetricKey(data: keyMaterial) }

    var shortPublicID: String { publicID.map { String(format: "%02x", $0) }.joined().prefix(8).description }

    init(id: UUID = UUID(), label: String, origin: Origin, createdAt: Date = Date(),
         formatVersion: Int = Cipher.currentVersion, publicID: Data, keyMaterial: Data,
         decorativeMapping: [Int]) {
        self.id = id
        self.label = label
        self.origin = origin
        self.createdAt = createdAt
        self.formatVersion = formatVersion
        self.publicID = publicID
        self.keyMaterial = keyMaterial
        self.decorativeMapping = decorativeMapping
    }

    /// A brand-new locally-generated cipher with a random key, id, and decorative mapping.
    static func generated(label: String) -> Cipher {
        var rng = SystemRandomNumberGenerator()   // CSPRNG on Apple platforms
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let publicID = Data((0..<8).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        let mapping = Array(0..<32).shuffled(using: &rng)
        return Cipher(label: label, origin: .generated, publicID: publicID,
                      keyMaterial: key, decorativeMapping: mapping)
    }
}
```

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `git add … && git commit -m "feat: add Cipher (symmetric key + decorative mapping) model"`

---

### Task 3: `MessageCryptor` (AES-GCM seal/open)

**Files:** Create `RuneScrib/Services/MessageCryptor.swift` · Test `RuneScribTests/MessageCryptorTests.swift`.

- [ ] **Step 1: Write the failing test**

```swift
// RuneScribTests/MessageCryptorTests.swift
import XCTest
@testable import RuneScrib

final class MessageCryptorTests: XCTestCase {
    private let cryptor = MessageCryptor()

    func testRoundTrip() throws {
        let c = Cipher.generated(label: "x")
        let sealed = try cryptor.seal("Hello, runes! 🜨\nLine2", with: c)
        XCTAssertEqual(try cryptor.open(sealed, with: c), "Hello, runes! 🜨\nLine2")
    }

    func testWrongCipherFails() throws {
        let sealed = try cryptor.seal("secret", with: Cipher.generated(label: "a"))
        XCTAssertThrowsError(try cryptor.open(sealed, with: Cipher.generated(label: "b")))
    }

    func testTamperFails() throws {
        let c = Cipher.generated(label: "x")
        var sealed = try cryptor.seal("secret", with: c)
        sealed[sealed.count - 1] ^= 0x01           // flip a tag bit
        XCTAssertThrowsError(try cryptor.open(sealed, with: c))
    }

    func testTwoSealsDifferentCiphertext() throws {
        let c = Cipher.generated(label: "x")
        XCTAssertNotEqual(try cryptor.seal("same", with: c), try cryptor.seal("same", with: c),
                          "fresh nonce each time")
    }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

```swift
// RuneScrib/Services/MessageCryptor.swift
import Foundation
import CryptoKit

enum MessageCryptorError: Error, LocalizedError {
    case sealFailed
    case notUTF8
    var errorDescription: String? {
        switch self {
        case .sealFailed: return "Couldn't encrypt the message."
        case .notUTF8:    return "The decrypted message wasn't valid text."
        }
    }
}

/// Stateless authenticated encryption over a `Cipher`'s symmetric key (AES-GCM).
/// A wrong key or any tampering makes `open` throw — it never returns bogus plaintext.
struct MessageCryptor {
    /// Returns `AES.GCM.SealedBox.combined` (12-byte nonce ‖ ciphertext ‖ 16-byte tag).
    func seal(_ plaintext: String, with cipher: Cipher) throws -> Data {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: cipher.symmetricKey)
        guard let combined = box.combined else { throw MessageCryptorError.sealFailed }
        return combined
    }

    func open(_ sealed: Data, with cipher: Cipher) throws -> String {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plaintext = try AES.GCM.open(box, using: cipher.symmetricKey)
        guard let text = String(data: plaintext, encoding: .utf8) else { throw MessageCryptorError.notUTF8 }
        return text
    }
}
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `… -m "feat: add MessageCryptor (AES-GCM seal/open)"`

---

### Task 4: `RuneCodec` (Data ↔ rune string)

**Files:** Create `RuneScrib/Services/RuneCodec.swift` · extend `RuneScribTests/RuneCodecTests.swift`.

- [ ] **Step 1: Add the failing tests**

```swift
// Append to RuneCodecTests.swift
extension RuneCodecTests {
    func testRoundTripArbitraryBytes() throws {
        let codec = RuneCodec()
        let c = Cipher.generated(label: "x")
        for len in [0, 1, 2, 3, 4, 5, 7, 16, 33, 128] {
            let data = Data((0..<len).map { _ in UInt8.random(in: .min ... .max) })
            let runes = codec.encode(data, with: c)
            XCTAssertEqual(try codec.decode(runes, with: c), data, "len=\(len)")
        }
    }

    func testOutputUsesOnlyAlphabetRunes() {
        let codec = RuneCodec()
        let c = Cipher.generated(label: "x")
        let runes = codec.encode(Data([0xDE, 0xAD, 0xBE, 0xEF]), with: c)
        let allowed = Set(RuneCharacterSet.decorativeAlphabet)
        XCTAssertTrue(runes.allSatisfy { allowed.contains($0) })
    }

    func testDecodeRejectsForeignCharacter() {
        let codec = RuneCodec()
        let c = Cipher.generated(label: "x")
        XCTAssertThrowsError(try codec.decode("A", with: c))   // 'A' is not a decorative rune
    }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

```swift
// RuneScrib/Services/RuneCodec.swift
import Foundation

enum RuneCodecError: Error { case foreignCharacter, invalidLength }

/// Reversible DECORATIVE encoding of bytes to a rune string and back, using a cipher's
/// `decorativeMapping`. This is base-32 (5 bits/rune, RFC 4648 bit order, no padding)
/// over `RuneCharacterSet.decorativeAlphabet`, with the per-cipher permutation applied.
/// It carries NO security — the security is the AES-GCM layer beneath it.
struct RuneCodec {

    func encode(_ data: Data, with cipher: Cipher) -> String {
        let alphabet = RuneCharacterSet.decorativeAlphabet
        var out = String()
        for value in fiveBitGroups(of: data) {
            out.append(alphabet[cipher.decorativeMapping[value]])
        }
        return out
    }

    func decode(_ runes: String, with cipher: Cipher) throws -> Data {
        // alphabetIndex(of rune) -> 5-bit value, inverting the cipher's permutation.
        var indexOfRune: [Character: Int] = [:]
        for (i, ch) in RuneCharacterSet.decorativeAlphabet.enumerated() { indexOfRune[ch] = i }
        var valueForAlphabetIndex = [Int](repeating: 0, count: 32)
        for (value, alphaIndex) in cipher.decorativeMapping.enumerated() { valueForAlphabetIndex[alphaIndex] = value }

        var groups: [Int] = []
        for ch in runes {
            guard let alphaIndex = indexOfRune[ch] else { throw RuneCodecError.foreignCharacter }
            groups.append(valueForAlphabetIndex[alphaIndex])
        }
        return try bytes(fromFiveBitGroups: groups)
    }

    // MARK: base-32 bit packing (RFC 4648 order, no padding)

    private func fiveBitGroups(of data: Data) -> [Int] {
        var out: [Int] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(Int((buffer >> UInt32(bits)) & 0x1F))
            }
        }
        if bits > 0 { out.append(Int((buffer << UInt32(5 - bits)) & 0x1F)) }   // pad low bits with 0
        return out
    }

    private func bytes(fromFiveBitGroups groups: [Int]) throws -> Data {
        var out = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for g in groups {
            buffer = (buffer << 5) | UInt32(g & 0x1F)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        // Leftover (<8) bits are encoder zero-padding; non-zero means corruption.
        if bits > 0, (buffer & ((1 << UInt32(bits)) - 1)) != 0 { throw RuneCodecError.invalidLength }
        return out
    }
}
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `… -m "feat: add RuneCodec (decorative base-32 over runes)"`

---

### Task 5: `MessageEnvelope` (versioned framing)

**Files:** Create `RuneScrib/Models/MessageEnvelope.swift` · Test `RuneScribTests/MessageEnvelopeTests.swift`.

- [ ] **Step 1: Failing test**

```swift
// RuneScribTests/MessageEnvelopeTests.swift
import XCTest
@testable import RuneScrib

final class MessageEnvelopeTests: XCTestCase {
    func testWrapUnwrapRoundTrip() throws {
        let sealed = Data([1, 2, 3, 4])
        let env = MessageEnvelope.wrap(sealed)
        XCTAssertEqual(env.first, MessageEnvelope.version)
        XCTAssertEqual(try MessageEnvelope.unwrap(env), sealed)
    }
    func testUnwrapRejectsEmpty() {
        XCTAssertThrowsError(try MessageEnvelope.unwrap(Data()))
    }
    func testUnwrapRejectsWrongVersion() {
        XCTAssertThrowsError(try MessageEnvelope.unwrap(Data([99, 1, 2])))
    }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

```swift
// RuneScrib/Models/MessageEnvelope.swift
import Foundation

enum MessageEnvelopeError: Error { case empty, unsupportedVersion(UInt8) }

/// The on-the-wire message framing: a 1-byte version followed by the AES-GCM sealed box.
/// No cipher identifier is included — the receiver tries its stored ciphers (the AEAD
/// tag authenticates the right one).
enum MessageEnvelope {
    static let version: UInt8 = 1

    static func wrap(_ sealed: Data) -> Data {
        var out = Data([version])
        out.append(sealed)
        return out
    }

    static func unwrap(_ data: Data) throws -> Data {
        guard let v = data.first else { throw MessageEnvelopeError.empty }
        guard v == version else { throw MessageEnvelopeError.unsupportedVersion(v) }
        return data.subdata(in: data.index(after: data.startIndex)..<data.endIndex)
    }
}
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `… -m "feat: add MessageEnvelope versioned framing"`

---

### Task 6: `MessageService` (compose / read with try-all)

**Files:** Create `RuneScrib/Services/MessageService.swift` · Test `RuneScribTests/MessageServiceTests.swift`.

- [ ] **Step 1: Failing test**

```swift
// RuneScribTests/MessageServiceTests.swift
import XCTest
@testable import RuneScrib

final class MessageServiceTests: XCTestCase {
    private let svc = MessageService()

    func testComposeProducesRunesThatReadBack() throws {
        let c = Cipher.generated(label: "x")
        let runes = try svc.compose("meet at dawn", with: c)
        XCTAssertTrue(runes.allSatisfy { Set(RuneCharacterSet.decorativeAlphabet).contains($0) })
        let result = try svc.read(runes, tryingCiphers: [c])
        XCTAssertEqual(result.plaintext, "meet at dawn")
        XCTAssertEqual(result.cipher, c)
    }

    func testReadPicksCorrectCipherAmongMany() throws {
        let target = Cipher.generated(label: "target")
        let others = (0..<5).map { Cipher.generated(label: "other\($0)") }
        let runes = try svc.compose("hidden", with: target)
        let result = try svc.read(runes, tryingCiphers: others + [target])
        XCTAssertEqual(result.plaintext, "hidden")
        XCTAssertEqual(result.cipher, target)
    }

    func testReadFailsWhenNoCipherMatches() throws {
        let runes = try svc.compose("nope", with: Cipher.generated(label: "a"))
        XCTAssertThrowsError(try svc.read(runes, tryingCiphers: [Cipher.generated(label: "b")]))
    }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

```swift
// RuneScrib/Services/MessageService.swift
import Foundation

enum MessageError: Error, LocalizedError {
    case noMatchingCipher
    var errorDescription: String? {
        switch self {
        case .noMatchingCipher:
            return "No matching cipher. Import the sender's cipher, then try again."
        }
    }
}

/// Orchestrates compose (encrypt → frame → decorate) and read (try each cipher:
/// un-decorate → unframe → decrypt). Stateless; depends only on the leaf services.
struct MessageService {
    private let cryptor = MessageCryptor()
    private let codec = RuneCodec()

    /// Plaintext + cipher → decorative rune string.
    func compose(_ plaintext: String, with cipher: Cipher) throws -> String {
        let sealed = try cryptor.seal(plaintext, with: cipher)
        let envelope = MessageEnvelope.wrap(sealed)
        return codec.encode(envelope, with: cipher)
    }

    /// Rune string → (plaintext, cipher) by trying each candidate. Exactly one cipher's
    /// key authenticates the message; everything else fails to open.
    func read(_ runes: String, tryingCiphers ciphers: [Cipher]) throws -> (plaintext: String, cipher: Cipher) {
        for cipher in ciphers {
            guard let bytes = try? codec.decode(runes, with: cipher),
                  let sealed = try? MessageEnvelope.unwrap(bytes),
                  let text = try? cryptor.open(sealed, with: cipher)
            else { continue }
            return (text, cipher)
        }
        throw MessageError.noMatchingCipher
    }
}
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `… -m "feat: add MessageService compose/read with try-all decryption"`

---

### Task 7: `CipherSharePayload` (compact share/import)

**Files:** Create `RuneScrib/Models/CipherSharePayload.swift` · Test `RuneScribTests/CipherSharePayloadTests.swift`.

Replaces `RuneCipherLink`. Compact binary layout: `version(1) ‖ publicID(8) ‖ keyMaterial(32) ‖ decorativeMapping(32 bytes, each 0–31) ‖ checksum(4 = first 4 bytes of SHA-256 over the preceding bytes)` = 77 bytes. URL: `runescribe://import?v=2&p=<base64url(77 bytes)>&n=<name>`.

- [ ] **Step 1: Failing test**

```swift
// RuneScribTests/CipherSharePayloadTests.swift
import XCTest
@testable import RuneScrib

final class CipherSharePayloadTests: XCTestCase {
    func testBinaryRoundTripRebuildsAWorkingCipher() throws {
        let original = Cipher.generated(label: "Alice")
        let payload = CipherSharePayload(cipher: original)
        let rebuilt = try CipherSharePayload(decoding: payload.encoded()).cipher(label: "Imported")

        XCTAssertEqual(rebuilt.keyMaterial, original.keyMaterial)
        XCTAssertEqual(rebuilt.publicID, original.publicID)
        XCTAssertEqual(rebuilt.decorativeMapping, original.decorativeMapping)
        XCTAssertEqual(rebuilt.origin, .imported)

        // End-to-end: compose with the original, read with the rebuilt cipher.
        let runes = try MessageService().compose("ping", with: original)
        XCTAssertEqual(try MessageService().read(runes, tryingCiphers: [rebuilt]).plaintext, "ping")
    }

    func testURLRoundTrip() throws {
        let c = Cipher.generated(label: "Bob")
        let url = try CipherSharePayload(cipher: c).url(name: "Bob's cipher")
        let parsed = try CipherSharePayload(url: url)
        XCTAssertEqual(parsed.payload.keyMaterial, c.keyMaterial)
        XCTAssertEqual(parsed.name, "Bob's cipher")
    }

    func testCorruptionRejectedByChecksum() throws {
        var bytes = CipherSharePayload(cipher: .generated(label: "x")).encoded()
        bytes[10] ^= 0x01
        XCTAssertThrowsError(try CipherSharePayload(decoding: bytes))
    }

    func testWrongVersionRejected() {
        var bytes = CipherSharePayload(cipher: .generated(label: "x")).encoded()
        bytes[0] = 9
        XCTAssertThrowsError(try CipherSharePayload(decoding: bytes))
    }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

```swift
// RuneScrib/Models/CipherSharePayload.swift
import Foundation
import CryptoKit

enum CipherShareError: Error, LocalizedError {
    case wrongSize, unsupportedVersion(UInt8), badChecksum, notAMapping
    case invalidURL, badBase64, missingPayload
    var errorDescription: String? {
        switch self {
        case .wrongSize, .badBase64, .notAMapping: return "The cipher's data is corrupted."
        case .badChecksum:                          return "The cipher's data failed its integrity check."
        case .unsupportedVersion:                   return "This cipher uses a newer format. Update Rune Scribe."
        case .invalidURL:                           return "This isn't a Rune Scribe cipher link."
        case .missingPayload:                       return "The cipher link is missing its data."
        }
    }
}

/// The compact, validated wire format for sharing a cipher (QR / deep-link / file).
/// Replaces `RuneCipherLink`. Carries the real key + public id + decorative mapping;
/// the rune FONT is added to this package in Phase 2.
struct CipherSharePayload: Equatable {
    static let version: UInt8 = 2
    static let scheme = "runescribe"
    static let host = "import"
    static let byteCount = 1 + 8 + 32 + 32 + 4   // 77

    let publicID: Data        // 8
    let keyMaterial: Data     // 32
    let decorativeMapping: [Int]  // 32, permutation of 0..<32

    init(publicID: Data, keyMaterial: Data, decorativeMapping: [Int]) {
        self.publicID = publicID
        self.keyMaterial = keyMaterial
        self.decorativeMapping = decorativeMapping
    }

    init(cipher: Cipher) {
        self.init(publicID: cipher.publicID, keyMaterial: cipher.keyMaterial,
                  decorativeMapping: cipher.decorativeMapping)
    }

    /// Reconstructs an importable `Cipher` (fresh id, `.imported`).
    func cipher(label: String) -> Cipher {
        Cipher(label: label, origin: .imported, publicID: publicID,
               keyMaterial: keyMaterial, decorativeMapping: decorativeMapping)
    }

    // MARK: binary

    func encoded() -> Data {
        var body = Data([Self.version])
        body.append(publicID)
        body.append(keyMaterial)
        body.append(Data(decorativeMapping.map { UInt8($0) }))
        body.append(Self.checksum(of: body))
        return body
    }

    init(decoding data: Data) throws {
        guard data.count == Self.byteCount else { throw CipherShareError.wrongSize }
        let body = data.prefix(Self.byteCount - 4)
        let given = data.suffix(4)
        guard Self.checksum(of: body) == Data(given) else { throw CipherShareError.badChecksum }
        var i = data.startIndex
        guard data[i] == Self.version else { throw CipherShareError.unsupportedVersion(data[i]) }
        i = data.index(i, offsetBy: 1)
        let pid  = data.subdata(in: i ..< data.index(i, offsetBy: 8));  i = data.index(i, offsetBy: 8)
        let key  = data.subdata(in: i ..< data.index(i, offsetBy: 32)); i = data.index(i, offsetBy: 32)
        let map  = data.subdata(in: i ..< data.index(i, offsetBy: 32)).map { Int($0) }
        guard Set(map) == Set(0..<32) else { throw CipherShareError.notAMapping }
        self.init(publicID: pid, keyMaterial: key, decorativeMapping: map)
    }

    private static func checksum(of data: Data) -> Data {
        Data(SHA256.hash(data: data).prefix(4))
    }

    // MARK: URL

    func url(name: String?) throws -> URL {
        var comps = URLComponents()
        comps.scheme = Self.scheme
        comps.host = Self.host
        var items = [URLQueryItem(name: "v", value: String(Self.version)),
                     URLQueryItem(name: "p", value: Self.base64url(encoded()))]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            items.append(URLQueryItem(name: "n", value: name))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw CipherShareError.invalidURL }
        return url
    }

    /// Parse `runescribe://import?...`; tolerate the `runescribe:import?...` path form.
    init(url: URL) throws {
        guard url.scheme?.lowercased() == Self.scheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CipherShareError.invalidURL }
        let marker = (comps.host ?? comps.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard marker == Self.host else { throw CipherShareError.invalidURL }
        let items = comps.queryItems ?? []
        guard let p = items.first(where: { $0.name == "p" })?.value, !p.isEmpty else { throw CipherShareError.missingPayload }
        let payload = try CipherSharePayload(decoding: Self.bytesFromBase64url(p))
        self.init(publicID: payload.publicID, keyMaterial: payload.keyMaterial, decorativeMapping: payload.decorativeMapping)
        self.parsedName = items.first(where: { $0.name == "n" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The display name parsed from a URL (nil for binary/file decode). Settable only in init(url:).
    private(set) var parsedName: String?

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func bytesFromBase64url(_ s: String) throws -> Data {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b.count % 4; if rem > 0 { b += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b) else { throw CipherShareError.badBase64 }
        return data
    }
}
```

> **Note:** the test references `parsed.payload` and `parsed.name`. Adjust the test to the actual surface: `parsed` is the `CipherSharePayload`; its parsed name is `parsed.parsedName`, and its key is `parsed.keyMaterial`. Update the `testURLRoundTrip` assertions to `parsed.keyMaterial` and `parsed.parsedName` accordingly before running.

- [ ] **Step 4: Run — expect PASS** (after the test-surface fixup in the note).
- [ ] **Step 5: Commit** `… -m "feat: add CipherSharePayload (compact key+mapping share format)"`

---

### Task 8: Retype `CipherLibrary` + `KeyManager` to `Cipher`

**Files:** Modify `RuneScrib/Models/CipherLibrary.swift`, `RuneScrib/Services/KeyManager.swift` · Test `RuneScribTests/CipherLibraryTests.swift` (replace substitution-based cases).

- [ ] **Step 1: Update `CipherLibrary.swift`** — replace every `NamedCipher` with `Cipher`; delete `fromLegacy(key:decoder:)` entirely; in `removingCipher` use `Cipher.generated(...)`. The pure-mutation helpers (`adding`, `removingCipher`, `renamingCipher`, `settingActive`, `activeCipher`) keep the same signatures, just retyped.

- [ ] **Step 2: Update `KeyManager.swift`:**
  - Type the library/`ciphers`/`activeCipher` to `Cipher`.
  - `addCipher(label:)` → `Cipher.generated(label:)` (already, retyped).
  - Replace both `importCipher(...)` overloads with one:
    ```swift
    @discardableResult
    func importCipher(_ payload: CipherSharePayload, label: String?) throws -> Cipher {
        let cipher = payload.cipher(label: cleanLabel(label ?? "", fallback: "Imported Cipher"))
        let aesKey = try loadOrCreateSymmetricKey()
        library = library.adding(cipher)
        try persist(using: aesKey)
        lastError = nil
        return cipher
    }
    ```
  - `libraryContainsKeyId(_:)` → `libraryContains(publicID:)` comparing `Data`.
  - `exportData(for:)` → returns `CipherSharePayload(cipher: cipher).encoded()`; `exportFilename(for:)` unchanged behaviour (use `cipher.label`/`createdAt`), but extension becomes `.runescribe` at the call site.
  - Add `func shareURL(for id: UUID, name: String?) throws -> URL { CipherSharePayload(cipher: <cipher>).url(name: name) }`.
  - **Delete** `migrateLegacy(using:)` and the legacy branch in `load()`. New `load()`: load library if present; else seed one `Cipher.generated(label: "My Cipher")`. Remove the `deleteEncryptedMapping()/deleteImportedDecoder()` calls.
  - The AES-GCM `encrypt/decrypt`, `loadOrCreateSymmetricKey`, label helpers stay unchanged.

- [ ] **Step 3: Rewrite `CipherLibraryTests.swift`** to the new model. Example cases (replace the `makeKey()`/permutation cases):
  ```swift
  func testGeneratedCipherIsValid() {
      let c = Cipher.generated(label: "Test")
      XCTAssertEqual(c.label, "Test"); XCTAssertEqual(c.origin, .generated)
      XCTAssertEqual(c.keyMaterial.count, 32)
  }
  func testAddingMakesActive() {
      let a = Cipher.generated(label: "A"), b = Cipher.generated(label: "B")
      let lib = CipherLibrary(ciphers: [a], activeID: a.id).adding(b)
      XCTAssertEqual(lib.activeCipher?.id, b.id); XCTAssertEqual(lib.ciphers.count, 2)
  }
  func testRemovingLastRegenerates() {
      let a = Cipher.generated(label: "A")
      let lib = CipherLibrary(ciphers: [a], activeID: a.id).removingCipher(id: a.id)
      XCTAssertEqual(lib.ciphers.count, 1); XCTAssertNotEqual(lib.ciphers[0].id, a.id)
  }
  func testShareImportRoundTripThroughKeyManagerPayload() throws {
      let original = Cipher.generated(label: "Friend")
      let rebuilt = try CipherSharePayload(decoding: CipherSharePayload(cipher: original).encoded()).cipher(label: "In")
      let runes = try MessageService().compose("yo", with: original)
      XCTAssertEqual(try MessageService().read(runes, tryingCiphers: [rebuilt]).plaintext, "yo")
  }
  ```

- [ ] **Step 4: Run** `-only-testing:RuneScribTests/CipherLibraryTests` — expect PASS. (KeyManager is `@MainActor`; it builds against the new model — full verification is the build in Task 11.)
- [ ] **Step 5: Commit** `… -m "refactor: retype cipher library + KeyManager to the Cipher model"`

---

### Task 9: Rewire import intake (`ImportCoordinator`, `Clipboard`, `ImportConfirmView`)

**Files:** Modify `RuneScrib/Services/ImportCoordinator.swift`, `RuneScrib/Services/Clipboard.swift`, `RuneScrib/Views/ImportConfirmView.swift`.

- [ ] **Step 1:** In `ImportCoordinator.swift`, change `PendingImport` to carry the payload:
  ```swift
  struct PendingImport: Identifiable, Equatable {
      let id = UUID()
      let payload: CipherSharePayload
      let suggestedName: String
  }
  ```
  In `ingest(url:)`, replace `RuneCipherLink.decodeURL(url)` with:
  ```swift
  let payload = try CipherSharePayload(url: url)
  pending = PendingImport(payload: payload, suggestedName: payload.parsedName ?? "Imported Cipher")
  ```
  In `ingest(urlString:)`, replace `RuneCipherLink.scheme` with `CipherSharePayload.scheme`.

- [ ] **Step 2:** In `Clipboard.swift:50`, replace `RuneCipherLink.scheme` with `CipherSharePayload.scheme`.

- [ ] **Step 3:** In `ImportConfirmView.swift:87`, replace
  `try keyManager.importCipher(fromPermutation: pending.perm, label: label)` with
  `try keyManager.importCipher(pending.payload, label: label)`.

- [ ] **Step 4:** Build the macOS target to confirm it compiles (no isolated unit test for the coordinator UI):
  ```bash
  xcodebuild build -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -5
  ```
  Expected: `** BUILD SUCCEEDED **` once Tasks 10–11 are also done; at this point expect remaining errors only from views still referencing old types (fixed in Task 10).
- [ ] **Step 5: Commit** `… -m "refactor: import intake carries CipherSharePayload"`

---

### Task 10: Rewire compose/read + share UI (`ContentView`, `CipherLibraryView`)

**Files:** Modify `RuneScrib/Views/ContentView.swift`, `RuneScrib/Views/CipherLibraryView.swift`.

- [ ] **Step 1: `ContentView.swift` compose/read** — replace the `transform()` body (around lines 269–278) that builds `CipherEngine(key: cipher.key)` and calls `engine.encode/decode`:
  ```swift
  // Compose (encrypt) uses the active cipher; Read (decrypt) tries all stored ciphers.
  private func transform() {
      guard boxPhase == .editing else { return }
      let service = MessageService()
      do {
          if isEncoding {                       // compose
              guard let cipher = keyManager.activeCipher else { return }
              target = try service.compose(source, with: cipher)
          } else {                              // read
              target = try service.read(source, tryingCiphers: keyManager.ciphers).plaintext
          }
      } catch {
          target = ""   // surface via the view's existing error/empty handling
      }
  }
  ```
  Adapt names (`isEncoding`, `boxPhase`, `source`, `target`) to the actual ones in the file; the key change is **encode→`compose(_:with:)`** and **decode→`read(_:tryingCiphers:)`**. Read no longer needs an active cipher.

- [ ] **Step 2: `CipherLibraryView.swift` share + export:**
  - Lines 93 & 218: replace `RuneCipherLink.encodeURL(for: cipher.key, name: cipher.label)` with `try? keyManager.shareURL(for: cipher.id, name: cipher.label)`.
  - Line 338: `exportDocument = DecoderDocument(data: try keyManager.exportData(for: cipher.id))` stays, but `exportData` now returns the compact payload bytes.
  - Line 339 + the `.fileExporter` filename: use extension `runescribe` instead of the decoder/JSON extension. In `DecoderDocument` (`Views/Components/DecoderDocument.swift`), set `readableContentTypes`/`writeContentTypes` to `[.data]` and the exported filename suffix to `.runescribe`.
  - Line 369 (`importCipher(data:label:)`) and 399 (`RuneCipherLink.decodeURL`): replace with:
    ```swift
    let payload = try CipherSharePayload(decoding: data)            // file import
    let cipher = try keyManager.importCipher(payload, label: importLabel)
    // …and for a pasted/scanned URL string:
    let payload = try CipherSharePayload(url: url)
    ```

- [ ] **Step 3: Build macOS** with the command in Task 9 Step 4. Expected after this step: `** BUILD SUCCEEDED **` (old type files still exist; removed in Task 11).
- [ ] **Step 4:** No new unit test (UI); covered by build + Task 11 full suite.
- [ ] **Step 5: Commit** `… -m "refactor: compose/read + share UI use real encryption"`

---

### Task 11: Delete obsolete code, fix tests, full verify

**Files:** Delete the obsolete sources/tests; run the whole suite + both-platform build.

- [ ] **Step 1: Remove obsolete sources**
  ```bash
  cd /Volumes/NVME/GitHub/rune-scrib
  git rm RuneScrib/Services/CipherEngine.swift \
         RuneScrib/Models/RuneKey.swift RuneScrib/Models/RuneKeyExport.swift \
         RuneScrib/Models/RuneCipherLink.swift RuneScrib/Models/NamedCipher.swift \
         RuneScrib/Models/ImportedDecoder.swift
  ```

- [ ] **Step 2: Remove obsolete tests** (they test the substitution mechanism / permutation link):
  ```bash
  git rm RuneScribTests/RuneCipherLinkTests.swift \
         RuneScribTests/DecoderImportTests.swift \
         RuneScribTests/FriendDecodeRoundTripTests.swift
  ```
  Then open `RuneScribTests/RuneScribTests.swift` and delete any case that constructs `RuneKey`/`CipherEngine`/`RuneKeyExport` or asserts substitution behaviour (keep app-lock / unrelated cases).

- [ ] **Step 3: Remove now-unused Keychain legacy API** in `KeychainService.swift` (optional but clean): the `cipherMapping` / `importedDecoder` accounts and their `store/retrieve/delete` methods are no longer referenced. Delete those six methods and the two `private let …Account` constants. Leave `symmetricKey`, `cipherLibrary`, `appPin`, `pinThrottle` intact.

- [ ] **Step 4: Full test suite**
  ```bash
  xcodebuild test -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGNING_REQUIRED=NO 2>&1 \
    | grep -E "Test Suite 'All tests'|Executed|TEST (SUCCEEDED|FAILED)|error:" | tail -15
  ```
  Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 5: iOS build** (compile-only; no simulator run needed):
  ```bash
  xcodebuild build -project RuneScrib.xcodeproj -scheme RuneScrib-iOS \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
  ```
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit** `… -m "chore: remove obsolete substitution cipher + migration code"`

---

## Self-review (completed by the planner)

- **Spec coverage:** real AES-GCM encryption (Tasks 3,6) · runes decorative (Tasks 1,4) · no in-message identifier / try-all (Task 6) · cipher = symmetric key (Task 2) · sharing keeps working with compact payload over QR/deep-link/file (Tasks 7,9,10) · at-rest + app-lock unchanged (untouched in `KeyManager`/`AppLock`) · obsolete beta code removed (Task 11) · OO/modular leaf services (Tasks 2–7). Font transport, decorative rotation, contacts, Messages = explicitly later phases.
- **Type consistency:** `Cipher` fields (`keyMaterial`, `publicID`, `decorativeMapping`, `symmetricKey`) used identically across Tasks 2–10; `MessageService.compose(_:with:)` / `read(_:tryingCiphers:)`, `CipherSharePayload(cipher:)/.encoded()/(decoding:)/.url(name:)/(url:)`, `KeyManager.importCipher(_:label:)/shareURL(for:name:)/exportData(for:)` are referenced consistently.
- **Known fixups flagged inline:** Task 7 test references `parsed.payload/.name` — corrected to `parsed.keyMaterial/.parsedName` in the note. Task 10 view edits adapt local variable names to the actual `ContentView` symbols.
- **Verification:** every core unit has a failing-first test; the test run command is validated working on this machine; final task runs the full suite + both-platform build.
