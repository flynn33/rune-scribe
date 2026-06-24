# Cipher Package: Fonts & Universal-Link Sharing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the rune font part of a cipher and carry it inside the shared package (font *reference* in the QR/link, font *bytes* in the file form), and make shared links `https://` Universal Links that open Rune Scribe + decode if installed, else land on the rune-scribe webpage.

**Architecture:** A `Cipher` gains a `FontRef` (id+version+sha256) defaulting to the bundled font (Codable default → Phase-1 ciphers load unchanged). `CipherSharePayload` bumps to v3 (adds the font ref, fixed-size binary); its **file form** appends the raw font bytes; its **url form** is the https link. A new `FontStore` validates/registers/resolves fonts. **No rotation** — runes stay purely decorative.

**Tech Stack:** Swift 6, SwiftUI, CryptoKit (`SHA256`), CoreText (`CTFontManager`, `CGFont`), XCTest, XcodeGen. Module `RuneScrib`. Spec: `docs/superpowers/specs/2026-06-23-runescribe-phase2-cipher-package-design.md`.

---

## Conventions (same as Phase 1)

- Work from `/Volumes/NVME/GitHub/rune-scrib`, branch `feature/cipher-package-fonts`. Tests: XCTest, `@testable import RuneScrib`, in `RuneScribTests/`.
- **After creating any new file, run `xcodegen generate`** (repo root) so it enters the build graph; commit the regenerated `RuneScrib.xcodeproj/project.pbxproj` with your files. (`xcodegen generate` also rewrites the xcschemes — never stage `*.xcscheme`.)
- **Implementers compile-check with `build-for-testing`** (NOT `xcodebuild test`):
  ```bash
  cd /Volumes/NVME/GitHub/rune-scrib
  xcodebuild build-for-testing -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -6
  ```
  Expect `** TEST BUILD SUCCEEDED **`. The **controller** runs the actual test assertions:
  ```bash
  xcodebuild test -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
    -only-testing:RuneScribTests/<Class> \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGNING_REQUIRED=NO 2>&1 | grep -E "Test Case|Executed|TEST (SUCCEEDED|FAILED)" | tail
  ```
- **NO AI attribution** in commit messages (no `Co-Authored-By`, tool names, 🤖).
- The app already skips its UI + Keychain under XCTest (`RuneScribApp.rootContent`), so tests run headless without a Keychain prompt.

## File structure

Create: `RuneScrib/Models/FontRef.swift`, `RuneScrib/Services/FontStore.swift`. Tests: `FontRefTests.swift`, `FontStoreTests.swift`, extend `CipherSharePayloadTests.swift`, `CipherTests.swift`.
Modify: `RuneScrib/Models/Cipher.swift` (+`fontRef`), `RuneScrib/Models/CipherSharePayload.swift` (v3 + file form + https url), `RuneScrib/Services/KeyManager.swift` (export file form / share https / import file-or-compact), `RuneScrib/Services/ImportCoordinator.swift` + `RuneScrib/Services/Clipboard.swift` (recognise https), `RuneScrib/Views/Components/RuneTheme.swift` (cipher-aware font) + the rune-render call sites, `RuneScrib/App/RuneScribApp.swift` + `AppDelegate.swift` (universal-link userActivity), `Config/RuneScrib-iOS.entitlements` + `RuneScrib-macOS.entitlements`.
Remove: `RuneScrib/Services/FontRegistration.swift` (folded into `FontStore`).

---

### Task 1: `FontRef` model

**Files:** Create `RuneScrib/Models/FontRef.swift` · Test `RuneScribTests/FontRefTests.swift`.

- [ ] **Step 1: Failing test**

```swift
// RuneScribTests/FontRefTests.swift
import XCTest
import CryptoKit
@testable import RuneScrib

final class FontRefTests: XCTestCase {
    func testBundledRefShape() {
        let r = FontRef.bundled
        XCTAssertEqual(r.id, "noto-sans-runic")
        XCTAssertEqual(r.version, 1)
        XCTAssertEqual(r.sha256.count, 32)
    }

    func testBundledRefHashMatchesTheBundledFontFile() throws {
        // The bundled ref's hash is computed from NotoSansRunic-Regular.ttf in the app bundle.
        let url = try XCTUnwrap(Bundle(for: FontRefTests.self).url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
            ?? Bundle.main.url(forResource: "NotoSansRunic-Regular", withExtension: "ttf"))
        let expected = Data(SHA256.hash(data: try Data(contentsOf: url)))
        XCTAssertEqual(FontRef.bundled.sha256, expected)
    }

    func testCodableRoundTrip() throws {
        let r = FontRef.bundled
        XCTAssertEqual(try JSONDecoder().decode(FontRef.self, from: JSONEncoder().encode(r)), r)
    }
}
```

- [ ] **Step 2: `xcodegen generate`, then `build-for-testing`** — expect build FAIL (`FontRef` undefined).

- [ ] **Step 3: Implement**

```swift
// RuneScrib/Models/FontRef.swift
import Foundation
import CryptoKit

/// A non-secret reference to the rune font a cipher uses: a stable id, a version, and the
/// SHA-256 of the font file. Carried in the compact share payload; the actual font bytes
/// travel only in the file form of the package.
struct FontRef: Codable, Equatable {
    let id: String
    let version: Int
    let sha256: Data

    /// The single bundled font, hashed from the app bundle at first use (identical on every
    /// install, so sender and receiver agree).
    static let bundled: FontRef = {
        let data = bundledFontData()
        return FontRef(id: "noto-sans-runic", version: 1, sha256: Data(SHA256.hash(data: data)))
    }()

    /// Raw bytes of the bundled font (empty Data if somehow missing — the hash then simply
    /// won't match a real font, which surfaces as a validation failure rather than a crash).
    static func bundledFontData() -> Data {
        guard let url = Bundle.main.url(forResource: "NotoSansRunic-Regular", withExtension: "ttf"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }
}
```

- [ ] **Step 4: `build-for-testing`** → `** TEST BUILD SUCCEEDED **`. (Controller runs `FontRefTests`.)
- [ ] **Step 5: Commit** `git add RuneScrib/Models/FontRef.swift RuneScribTests/FontRefTests.swift RuneScrib.xcodeproj/project.pbxproj && git commit -m "feat: add FontRef (id+version+sha256) with bundled-font constant"`

---

### Task 2: `FontStore` (validate / register / resolve), absorbing `FontRegistration`

**Files:** Create `RuneScrib/Services/FontStore.swift` · Test `RuneScribTests/FontStoreTests.swift` · later remove `RuneScrib/Services/FontRegistration.swift` (Task 9).

- [ ] **Step 1: Failing test**

```swift
// RuneScribTests/FontStoreTests.swift
import XCTest
@testable import RuneScrib

final class FontStoreTests: XCTestCase {
    func testResolveBundledRefReturnsRegisteredName() {
        let store = FontStore.shared
        store.registerBundledAndImportedFonts()
        XCTAssertEqual(store.resolve(.bundled), "Noto Sans Runic")
    }

    func testImportBundledBytesValidates() throws {
        let store = FontStore.shared
        // Importing the bundled font's own bytes against its own ref must validate.
        XCTAssertNoThrow(try store.importFont(FontRef.bundledFontData(), expecting: .bundled))
    }

    func testImportRejectsCorruptBytes() {
        let store = FontStore.shared
        XCTAssertThrowsError(try store.importFont(Data([0, 1, 2, 3]), expecting: .bundled))
    }

    func testImportRejectsHashMismatch() {
        let store = FontStore.shared
        let wrongRef = FontRef(id: "noto-sans-runic", version: 1, sha256: Data(repeating: 0xAB, count: 32))
        XCTAssertThrowsError(try store.importFont(FontRef.bundledFontData(), expecting: wrongRef))
    }
}
```

- [ ] **Step 2: `xcodegen generate`, `build-for-testing`** — expect FAIL.

- [ ] **Step 3: Implement**

```swift
// RuneScrib/Services/FontStore.swift
import Foundation
import CryptoKit
import CoreText

enum FontStoreError: Error, LocalizedError {
    case unreadableFont
    case hashMismatch
    case cannotRegister
    var errorDescription: String? {
        switch self {
        case .unreadableFont: return "The font data is not a valid font."
        case .hashMismatch:   return "The font doesn't match the cipher's font reference."
        case .cannotRegister: return "The font could not be installed."
        }
    }
}

/// Owns the rune fonts available for rendering: registers the bundled font and any previously
/// imported fonts, validates and stores fonts that arrive inside a shared cipher, and resolves
/// a `FontRef` to a registered font name. Device-only; never downloads.
final class FontStore {
    static let shared = FontStore()
    private init() {}

    /// Display/PostScript name a `FontRef` resolves to, or nil if that font isn't present.
    func resolve(_ ref: FontRef) -> String? {
        if ref == .bundled { return "Noto Sans Runic" }
        let url = importedFontURL(ref)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              Data(SHA256.hash(data: data)) == ref.sha256 else { return nil }
        return Self.postScriptName(of: data)
    }

    /// Validates font bytes against `ref`, stores them in app-support, and registers them.
    /// Throws (changing nothing) on invalid font or hash mismatch.
    func importFont(_ bytes: Data, expecting ref: FontRef) throws {
        guard Data(SHA256.hash(data: bytes)) == ref.sha256 else { throw FontStoreError.hashMismatch }
        guard Self.postScriptName(of: bytes) != nil else { throw FontStoreError.unreadableFont }
        if ref == .bundled { return }   // already bundled; nothing to store
        let url = importedFontURL(ref)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        register(url)
    }

    /// Registers the bundled font and every previously-imported font. Call once at launch.
    func registerBundledAndImportedFonts() {
        if let url = Bundle.main.url(forResource: "NotoSansRunic-Regular", withExtension: "ttf") {
            register(url)
        }
        let dir = importedFontsDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "ttf" { register(url) }
    }

    // MARK: helpers

    private func register(_ url: URL) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) // idempotent; ignores already-registered
    }

    private func importedFontsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RuneScribFonts", isDirectory: true)
    }

    private func importedFontURL(_ ref: FontRef) -> URL {
        importedFontsDirectory().appendingPathComponent("\(ref.id)-v\(ref.version).ttf")
    }

    static func postScriptName(of data: Data) -> String? {
        guard let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else { return nil }
        return (cgFont.postScriptName as String?)
    }
}
```

> Note: `resolve(.bundled)` returns the family name `"Noto Sans Runic"` (the name `RuneTheme.runic` already uses with `.custom`). `postScriptName` is used only as a validity probe for imported fonts; if a future imported font's `.custom` lookup needs the PostScript name vs. family name, adjust `resolve` for the imported branch then.

- [ ] **Step 4: `build-for-testing`** → SUCCEEDED. (Controller runs `FontStoreTests`.)
- [ ] **Step 5: Commit** `… -m "feat: add FontStore (validate/register/resolve rune fonts)"`

---

### Task 3: `Cipher` gains `fontRef` (Codable default = bundled)

**Files:** Modify `RuneScrib/Models/Cipher.swift` · extend `RuneScribTests/CipherTests.swift`.

- [ ] **Step 1: Failing test** — append to `CipherTests.swift`:

```swift
extension CipherTests {
    func testGeneratedCipherUsesBundledFont() {
        XCTAssertEqual(Cipher.generated(label: "x").fontRef, .bundled)
    }
    func testDecodingALegacyCipherWithoutFontRefDefaultsToBundled() throws {
        // Simulate a Phase-1 stored cipher: encode a JSON object with no fontRef key.
        let json = """
        {"id":"\(UUID().uuidString)","label":"old","origin":"generated","createdAt":0,
         "formatVersion":1,"publicID":"AAAAAAAAAAA=","keyMaterial":"\(Data(repeating:1,count:32).base64EncodedString())",
         "decorativeMapping":[\((0..<32).map(String.init).joined(separator: ","))]}
        """
        let c = try JSONDecoder().decode(Cipher.self, from: Data(json.utf8))
        XCTAssertEqual(c.fontRef, .bundled)
    }
}
```

- [ ] **Step 2: `build-for-testing`** — expect FAIL (no `fontRef`). (No new file → no xcodegen.)

- [ ] **Step 3: Implement** — in `RuneScrib/Models/Cipher.swift`:
  - Add the stored property: `let fontRef: FontRef`.
  - Add `fontRef: FontRef = .bundled` to the memberwise `init(...)` (default).
  - In `generated(label:)`, the call already uses the memberwise init, so it picks up `.bundled`.
  - Add a **custom decoder** so legacy ciphers (no `fontRef`) default to bundled. Add to `Cipher`:
    ```swift
    private enum CodingKeys: String, CodingKey {
        case id, label, origin, createdAt, formatVersion, publicID, keyMaterial, decorativeMapping, fontRef
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        origin = try c.decode(Origin.self, forKey: .origin)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        publicID = try c.decode(Data.self, forKey: .publicID)
        keyMaterial = try c.decode(Data.self, forKey: .keyMaterial)
        decorativeMapping = try c.decode([Int].self, forKey: .decorativeMapping)
        fontRef = try c.decodeIfPresent(FontRef.self, forKey: .fontRef) ?? .bundled
    }
    ```
  (Synthesised `encode` is fine — it writes `fontRef`. Adding `CodingKeys` + `init(from:)` keeps `Codable`/`Equatable` working.)

- [ ] **Step 4: `build-for-testing`** → SUCCEEDED. (Controller runs `CipherTests` — note the legacy-decode test uses `createdAt:0`; ensure the decoder's date strategy matches how the library is stored. `KeyManager` uses `.iso8601`; this isolated test uses default — keep the test self-consistent by encoding/decoding with the same `JSONDecoder()` defaults, i.e. numeric `createdAt`. If the date strategy bites, change the test to build the JSON via `JSONEncoder` on a struct missing only fontRef.)
- [ ] **Step 5: Commit** `… -m "feat: Cipher carries a FontRef (defaults to bundled for legacy ciphers)"`

---

### Task 4: `CipherSharePayload` v3 — font ref in the compact form

**Files:** Modify `RuneScrib/Models/CipherSharePayload.swift` · extend `RuneScribTests/CipherSharePayloadTests.swift`.

New fixed binary layout (v3): `version(1) | publicID(8) | keyMaterial(32) | decorativeMapping(32) | fontId(16, utf8 zero-padded) | fontVersion(4, big-endian) | fontSha256(32) | checksum(4)` = **129 bytes**.

- [ ] **Step 1: Failing test** — append to `CipherSharePayloadTests.swift`:

```swift
extension CipherSharePayloadTests {
    func testV3CompactRoundTripIncludesFontRef() throws {
        let c = Cipher.generated(label: "Alice")
        let back = try CipherSharePayload(decoding: CipherSharePayload(cipher: c).encoded())
        XCTAssertEqual(back.keyMaterial, c.keyMaterial)
        XCTAssertEqual(back.fontRef, c.fontRef)
        XCTAssertEqual(back.cipher(label: "in").fontRef, .bundled)
    }
    func testV3ByteCount() {
        XCTAssertEqual(CipherSharePayload(cipher: .generated(label: "x")).encoded().count, 129)
        XCTAssertEqual(CipherSharePayload.byteCount, 129)
    }
}
```

- [ ] **Step 2: `build-for-testing`** — expect FAIL (no fontRef on payload / byteCount==77).

- [ ] **Step 3: Implement** — in `CipherSharePayload.swift`:
  - `static let version: UInt8 = 3`; `static let byteCount = 1 + 8 + 32 + 32 + 16 + 4 + 32 + 4  // 129`.
  - Add stored `let fontRef: FontRef`. Update both `init`s and `init(cipher:)` to carry it; `cipher(label:)` passes `fontRef:` into the `Cipher` init.
  - In `encoded()`, after `decorativeMapping`, append the font ref: a 16-byte id field, the 4-byte big-endian version, the 32-byte sha256 — then checksum over everything preceding:
    ```swift
    func encoded() -> Data {
        var body = Data([Self.version])
        body.append(publicID); body.append(keyMaterial)
        body.append(Data(decorativeMapping.map { UInt8($0) }))
        body.append(Self.fixedID(fontRef.id))                       // 16 bytes
        var v = UInt32(fontRef.version).bigEndian
        body.append(Data(bytes: &v, count: 4))                      // 4 bytes
        body.append(fontRef.sha256)                                 // 32 bytes
        body.append(Self.checksum(of: body))                        // 4 bytes
        return body
    }
    private static func fixedID(_ id: String) -> Data {
        var d = Data(id.utf8).prefix(16)
        d.append(Data(repeating: 0, count: 16 - d.count))
        return Data(d)
    }
    private static func parseID(_ d: Data) -> String {
        String(decoding: Data(d.prefix { $0 != 0 }), as: UTF8.self)
    }
    ```
  - In `init(decoding:)`, after `decorativeMapping`, read `fontId(16)`, `fontVersion(4 BE)`, `fontSha256(32)` and build the `FontRef`; keep the existing checksum + version + permutation guards (the checksum now covers the font fields too). Use the slice-safe `data.subdata(in:)` / index advancing already in the file.

- [ ] **Step 4: `build-for-testing`** → SUCCEEDED. (Controller runs `CipherSharePayloadTests`; the Phase-1 corruption/wrong-version tests still pass — they flip bytes that break the checksum, which still gates first.)
- [ ] **Step 5: Commit** `… -m "feat: CipherSharePayload v3 carries the font reference"`

---

### Task 5: File form (payload + font bytes) and the https URL

**Files:** Modify `RuneScrib/Models/CipherSharePayload.swift` · extend `RuneScribTests/CipherSharePayloadTests.swift`.

- [ ] **Step 1: Failing test** — append:

```swift
extension CipherSharePayloadTests {
    func testFileFormRoundTripsPayloadAndFontBytes() throws {
        let c = Cipher.generated(label: "Bob")
        let font = FontRef.bundledFontData()
        let file = CipherSharePayload(cipher: c).encodedFile(fontBytes: font)
        let (payload, bytes) = try CipherSharePayload.decodeFile(file)
        XCTAssertEqual(payload.keyMaterial, c.keyMaterial)
        XCTAssertEqual(bytes, font)
    }
    func testFileFormWithoutFontIsCompactOnly() throws {
        let c = Cipher.generated(label: "C")
        let (payload, bytes) = try CipherSharePayload.decodeFile(CipherSharePayload(cipher: c).encoded())
        XCTAssertEqual(payload.publicID, c.publicID)
        XCTAssertNil(bytes)
    }
    func testHTTPSURLRoundTrip() throws {
        let c = Cipher.generated(label: "Dee")
        let url = try CipherSharePayload(cipher: c).url(name: "Dee")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "ravenforgesoftware.com")
        let parsed = try CipherSharePayload(url: url)
        XCTAssertEqual(parsed.keyMaterial, c.keyMaterial)
        XCTAssertEqual(parsed.parsedName, "Dee")
    }
    func testLegacyCustomSchemeStillParses() throws {
        let c = Cipher.generated(label: "E")
        let legacy = URL(string: "runescribe://import?v=3&p=" + CipherSharePayload(cipher: c).encoded()
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))!
        XCTAssertEqual(try CipherSharePayload(url: legacy).keyMaterial, c.keyMaterial)
    }
}
```

- [ ] **Step 2: `build-for-testing`** — expect FAIL.

- [ ] **Step 3: Implement** — in `CipherSharePayload.swift`:
  - File form:
    ```swift
    static let webHost = "ravenforgesoftware.com"
    static let webPath = "/rune-scribe/import"

    /// Self-contained file form: the 129-byte compact payload followed by the raw font bytes.
    func encodedFile(fontBytes: Data) -> Data { encoded() + fontBytes }

    /// Splits a file form into (payload, fontBytes?). A file exactly `byteCount` long has no font.
    static func decodeFile(_ data: Data) throws -> (CipherSharePayload, Data?) {
        guard data.count >= byteCount else { throw CipherShareError.wrongSize }
        let payload = try CipherSharePayload(decoding: data.prefix(byteCount))
        let rest = data.count == byteCount ? nil : Data(data.suffix(from: data.index(data.startIndex, offsetBy: byteCount)))
        return (payload, rest)
    }
    ```
  - URL: change `url(name:)` to build the https form, and `init(url:)` to accept the https host/path **and** the legacy `runescribe://import` scheme:
    ```swift
    func url(name: String?) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = Self.webHost; comps.path = Self.webPath
        var items = [URLQueryItem(name: "v", value: String(Self.version)),
                     URLQueryItem(name: "p", value: Self.base64url(encoded()))]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            items.append(URLQueryItem(name: "n", value: name))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw CipherShareError.invalidURL }
        return url
    }

    init(url: URL) throws {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CipherShareError.invalidURL }
        let isHTTPS = (url.scheme?.lowercased() == "https") && (comps.host?.lowercased() == Self.webHost)
            && comps.path.lowercased().hasPrefix("/rune-scribe/import")
        let isScheme = url.scheme?.lowercased() == "runescribe"
            && ((comps.host ?? comps.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "import")
        guard isHTTPS || isScheme else { throw CipherShareError.invalidURL }
        let items = comps.queryItems ?? []
        guard let p = items.first(where: { $0.name == "p" })?.value, !p.isEmpty else { throw CipherShareError.missingPayload }
        let decoded = try CipherSharePayload(decoding: Self.bytesFromBase64url(p))
        self.init(publicID: decoded.publicID, keyMaterial: decoded.keyMaterial,
                  decorativeMapping: decoded.decorativeMapping, fontRef: decoded.fontRef)
        self.parsedName = items.first(where: { $0.name == "n" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    ```
  - **Add a static URL matcher** for clipboard/coordinator: `static func isShareURL(_ s: String) -> Bool` returning true for an https `…ravenforgesoftware.com/rune-scribe/import…` or a `runescribe:` string. Used in Task 6.

- [ ] **Step 4: `build-for-testing`** → SUCCEEDED. (Controller runs `CipherSharePayloadTests`.)
- [ ] **Step 5: Commit** `… -m "feat: CipherSharePayload file form (font bytes) + https universal-link URL"`

---

### Task 6: Recognise the https URL on intake (`ImportCoordinator`, `Clipboard`)

**Files:** Modify `RuneScrib/Services/Clipboard.swift`, `RuneScrib/Services/ImportCoordinator.swift`.

- [ ] **Step 1:** In `Clipboard.runeScribeURLString()`, replace the scheme-prefix check with `CipherSharePayload.isShareURL(trimmed) ? trimmed : nil`.
- [ ] **Step 2:** In `ImportCoordinator.ingest(urlString:)`, replace the `hasPrefix("\(CipherSharePayload.scheme):")` guard with `guard CipherSharePayload.isShareURL(trimmed), let url = URL(string: trimmed) else { return }`. (`ingest(url:)` already funnels through `CipherSharePayload(url:)`, which now accepts both forms — no other change.)
- [ ] **Step 3:** `build-for-testing` → SUCCEEDED. (No isolated unit test; covered by the payload tests + Task 10 build.)
- [ ] **Step 4: Commit** `… -m "refactor: recognise https cipher links on clipboard/deep-link intake"`

---

### Task 7: `KeyManager` — export file form, share https, import file-or-compact

**Files:** Modify `RuneScrib/Services/KeyManager.swift` · extend `RuneScribTests/CipherLibraryTests.swift`.

- [ ] **Step 1: Failing test** — append to `CipherLibraryTests.swift`:

```swift
extension CipherLibraryTests {
    func testImportFromFileFormValidatesFontAndRebuildsCipher() throws {
        let original = Cipher.generated(label: "Friend")
        let file = CipherSharePayload(cipher: original).encodedFile(fontBytes: FontRef.bundledFontData())
        let (payload, fontBytes) = try CipherSharePayload.decodeFile(file)
        if let fontBytes { try FontStore.shared.importFont(fontBytes, expecting: payload.fontRef) } // bundled → no-op
        let rebuilt = payload.cipher(label: "Imported")
        XCTAssertEqual(rebuilt.fontRef, original.fontRef)
        let runes = try MessageService().compose("hi", with: original)
        XCTAssertEqual(try MessageService().read(runes, tryingCiphers: [rebuilt]).plaintext, "hi")
    }
}
```

- [ ] **Step 2: `build-for-testing`** — expect PASS already for this test if the APIs exist; the real change is wiring KeyManager's export/share/import to the new forms. Make these `KeyManager` edits:
  - `exportData(for:)` → returns the **file form** with font bytes:
    ```swift
    func exportData(for id: UUID) throws -> Data {
        guard let cipher = library.ciphers.first(where: { $0.id == id }) else { throw KeyManagerError.noKeyAvailable }
        let fontBytes = cipher.fontRef == .bundled ? FontRef.bundledFontData()
            : (FontStore.shared.resolve(cipher.fontRef) != nil ? FontRef.bundledFontData() : Data())
        return CipherSharePayload(cipher: cipher).encodedFile(fontBytes: fontBytes)
    }
    ```
    (For Phase 2 there is only the bundled font, so the bytes are always the bundled font.)
  - Replace `importCipher(_ payload:label:)` callers' needs with a data-first import that handles file-or-compact + font validation:
    ```swift
    @discardableResult
    func importCipher(fileData data: Data, label: String?) throws -> Cipher {
        let (payload, fontBytes) = try CipherSharePayload.decodeFile(data)
        if let fontBytes { try FontStore.shared.importFont(fontBytes, expecting: payload.fontRef) }
        else if FontStore.shared.resolve(payload.fontRef) == nil {
            throw FontStoreError.unreadableFont   // font referenced but neither present nor supplied
        }
        return try importCipher(payload, label: label)
    }
    ```
    Keep the existing `importCipher(_ payload: CipherSharePayload, label:)` (used by URL/QR intake, where the font is by reference and resolved locally).
  - `shareURL(for:name:)` already returns `CipherSharePayload(cipher:).url(name:)`, which now emits the https form — no change needed beyond confirming it compiles.

- [ ] **Step 3:** `build-for-testing` → SUCCEEDED. (Controller runs `CipherLibraryTests`.)
- [ ] **Step 4: Commit** `… -m "feat: KeyManager exports the self-contained file form and validates fonts on file import"`

---

### Task 8: Cipher-aware rune font rendering

**Files:** Modify `RuneScrib/Views/Components/RuneTheme.swift` and the rune-render call sites; register fonts via `FontStore` at launch.

- [ ] **Step 1:** In `RuneTheme.swift`, add a cipher-aware variant alongside the existing one:
  ```swift
  static func runic(_ size: CGFloat, fontName: String? = nil) -> Font { .custom(fontName ?? "Noto Sans Runic", size: size) }
  ```
  Add a tiny resolver `RuneFont`:
  ```swift
  enum RuneFont { static func name(for cipher: Cipher?) -> String { cipher.flatMap { FontStore.shared.resolve($0.fontRef) } ?? "Noto Sans Runic" } }
  ```
- [ ] **Step 2:** At the rune output sites that have a cipher in hand, pass the cipher's font name. Minimum: in `ContentView`, when showing the encoded/decoded result, resolve `RuneFont.name(for: keyManager.activeCipher)` and pass it to the rune text style. (With one font this is `"Noto Sans Runic"` — the change is plumbing; keep edits to where the cipher is readily available, don't thread it through every component.)
- [ ] **Step 3:** Make launch registration use `FontStore`: in `AppDelegate` (both platforms) replace `FontRegistration.registerBundledFonts()` with `FontStore.shared.registerBundledAndImportedFonts()`.
- [ ] **Step 4:** `build-for-testing` → SUCCEEDED.
- [ ] **Step 5: Commit** `… -m "feat: render runes with the cipher's font; register imported fonts at launch"`

---

### Task 9: Remove `FontRegistration`; entitlements + universal-link handling

**Files:** Remove `RuneScrib/Services/FontRegistration.swift`; modify `Config/RuneScrib-iOS.entitlements`, `Config/RuneScrib-macOS.entitlements`, `RuneScrib/App/RuneScribApp.swift`, `RuneScrib/App/AppDelegate.swift`.

- [ ] **Step 1:** `git rm RuneScrib/Services/FontRegistration.swift` (no longer referenced after Task 8).
- [ ] **Step 2:** Add to **both** entitlements files (inside the top-level `<dict>`):
  ```xml
  <key>com.apple.developer.associated-domains</key>
  <array><string>applinks:ravenforgesoftware.com</string></array>
  ```
- [ ] **Step 3:** Handle the inbound universal link. In `RuneScribApp.rootContent`'s non-test branch, add to the `RootView()` chain:
  ```swift
  .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL { ImportCoordinator.shared.ingest(url: url) }
  }
  ```
  (Custom-scheme links keep arriving via the existing `.onOpenURL`. macOS also routes web activities through `application(_:continue:)` if needed — add the AppKit `func application(_:continue:restorationHandler:)` to `AppDelegate` mirroring `application(_:open:)` if macOS testing shows the SwiftUI modifier isn't enough.)
- [ ] **Step 4: VERIFY THE AD-HOC BUILD STILL WORKS** (the associated-domains entitlement is the one real risk):
  ```bash
  xcodegen generate
  xcodebuild build-for-testing -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -8
  ```
  Expect `** TEST BUILD SUCCEEDED **`. **If it fails on the entitlement** (provisioning/profile), the fallback is to add `CODE_SIGN_ENTITLEMENTS=""` or a stripped test-only entitlements file for the ad-hoc test build, or set `com.apple.developer.associated-domains` only via a Release config — record which fallback was used. (Unit tests don't exercise universal links, so the entitlement only needs to not break the build.)
- [ ] **Step 5: Commit** `… -m "feat: associated-domains entitlement + universal-link intake; fold FontRegistration into FontStore"`

---

### Task 10: Full verification

- [ ] **Step 1:** Full macOS suite:
  ```bash
  xcodebuild test -project RuneScrib.xcodeproj -scheme RuneScrib-macOS -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGNING_REQUIRED=NO 2>&1 \
    | grep -E "Test Suite 'All tests'|Executed [0-9]+ tests, with|\*\* TEST (SUCCEEDED|FAILED)" | tail -4
  ```
  Expect `** TEST SUCCEEDED **`, 0 failures.
- [ ] **Step 2:** iOS build:
  ```bash
  xcodebuild build -project RuneScrib.xcodeproj -scheme RuneScrib-iOS -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tail -4
  ```
  Expect `** BUILD SUCCEEDED **`. (If the entitlement blocks the iOS build, apply the Task 9 fallback.)
- [ ] **Step 3:** Grep for any leftover reference to removed `FontRegistration`; confirm none.
- [ ] **Step 4: Commit** any final fixups.

---

## Self-review (planner)

- **Spec coverage:** FontRef (T1) · FontStore validate/register/resolve (T2) · Cipher fontRef + legacy default (T3) · compact v3 with ref (T4) · file form font bytes + https URL + legacy scheme (T5) · https intake (T6) · export/share/import wiring + font validation (T7) · cipher-aware rendering + launch registration (T8) · entitlements + universal-link handling + FontRegistration removal (T9) · full verify (T10). Non-goals (rotation, contacts, Messages, custom-font UI, website AASA) correctly excluded.
- **Type consistency:** `FontRef(.bundled/.id/.version/.sha256/.bundledFontData())`, `FontStore.shared.resolve/importFont/registerBundledAndImportedFonts`, `CipherSharePayload(.fontRef, byteCount=129, encoded/encodedFile/decodeFile/url/init(url:)/isShareURL)`, `Cipher.fontRef`, `KeyManager.exportData/importCipher(fileData:)/importCipher(_:label:)/shareURL` used consistently.
- **Known fixups flagged inline:** the Task 3 legacy-decode test's date strategy; the macOS `application(_:continue:)` fallback; the entitlement/ad-hoc-build fallback in Task 9.
- **Verification:** every new unit has a failing-first test; controller runs assertions with the validated headless command; T10 runs the full suite + both-platform build.
