# Rune Scribe — Phase 2: Font in the Cipher Package & Universal-Link Sharing

**Status:** Draft for review
**Date:** 2026-06-23
**Phase:** 2 of 4 (Phase 1 — real encryption — is merged.)

## Programme context

1. Real encryption + new cipher model — **done/merged**.
2. **This phase:** the rune **font** travels inside the shared cipher package, and a shared
   link **opens Rune Scribe (and decodes) if installed, else routes to the rune-scribe
   webpage**.
3. Contacts + per-contact ciphers.
4. Apple Messages (auto-share the cipher on the first message to a contact).

**There is no decorative-mapping rotation.** The runes are purely decorative — they only
need to look good and be Norse runes. Each cipher already gets a distinct random decorative
mapping at creation (Phase 1); that is the entire requirement, and nothing rotates.

## Key/cipher lifecycle (clarification — no new feature)

A cipher bundles **encryption key + rune font + decorative mapping**, all fixed at creation.
A key is shared on the first message to a contact (auto in Phase 4, or manually via the
existing share now) and **stays valid forever** unless the user (or the recipient) makes a
**new** key for that contact. "Making a new key" = creating a new cipher (the existing *New
Cipher* flow). Phase 2 adds **no** rotate/expire feature; per-contact keys and
auto-share-on-first-message are Phases 3–4.

## Goals

- The rune font is part of the cipher and **travels in the shared package**, so a received
  cipher renders identically without assuming the recipient already has the font.
- A shared link is an **https Universal Link** to `ravenforgesoftware.com/rune-scribe/import`:
  recipient **with** the app → app opens and decodes; **without** → the existing webpage.
- All Phase 1 behaviour (encryption, create/select/share/import, app-lock) is preserved.

## Non-goals (later or out of scope)

- Decorative-mapping rotation (dropped).
- Per-contact association (Phase 3); auto-share on first message / Messages (Phase 4).
- A custom-font **picker UI** — the plumbing supports per-cipher fonts, but there is only
  the one bundled font and no import-your-own-font UI this phase.
- The website's `apple-app-site-association` file and the landing page — they exist / are
  outside this repo (see Dependency note).

## A. Font reference & package format

- **`FontRef { id: String, version: Int, sha256: Data }`.** The bundled font is
  `id: "noto-sans-runic", version: 1, sha256: 615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b`
  (SHA-256 of `NotoSansRunic-Regular.ttf`).
- **`Cipher` gains `fontRef: FontRef`.** It decodes with a **default** equal to the bundled
  `FontRef`, so Phase-1-stored ciphers load unchanged (no migration). New ciphers reference
  the bundled font.
- **Compact form (QR / https link)** carries the cipher + the font **reference** only:
  `version, publicID(8), keyMaterial(32), decorativeMapping(32), fontRef(id+version+sha256),
  checksum(4)`. ~110 bytes — fits a QR and a URL.
- **File form (`.runescribe`)** is self-contained: the compact payload **plus the font file
  bytes** appended. This is what gets exported to a file and bundled/attached on the first
  message (Phase 4). The ~55 KB font is fine in a file/attachment (and is excluded from the
  QR/link, which carries only the reference).
- `CipherSharePayload.version` bumps **2 → 3** (font reference added). Beta — no back-compat
  for the v2 (Phase 1) format.

## B. Font store, validation, rendering

- **`FontStore` (service):**
  - `resolve(_ ref: FontRef) -> String?` — the registered font name for a ref if present
    locally (bundled or previously imported), else `nil`.
  - `importFont(_ bytes: Data, expecting ref: FontRef) throws` — validates: CoreText can build
    a `CGFont`/`CTFont` from the bytes; the computed SHA-256 equals `ref.sha256`. On success,
    saves the bytes to app-support (`Fonts/<id>-v<version>.ttf`), registers via
    `CTFontManager`, and records `(id, version) → PostScript name`. On parse failure or hash
    mismatch it **throws and changes nothing** (existing ciphers untouched).
  - At launch: register the bundled font (as `FontRegistration` does today) plus any
    previously-imported fonts in app-support.
- **Importing a cipher:**
  - **File form** (has font bytes): import the font (validate + store + register) first; if the
    font is invalid, **reject the whole import** (the cipher is not added) with a clear error.
    Then add the cipher.
  - **Compact form** (QR / link, no bytes): if `resolve(fontRef)` finds the font (always true
    for the bundled font) → import normally. If not found (a future custom font that hasn't
    arrived) → import the cipher but mark it **font-pending** (renders with a system fallback
    and shows a "font not yet received" state); it is not "fully imported" per the original
    scope. Rare while there is one bundled font.
- **Rendering:** a `RuneFont.name(for: cipher)` helper resolves `cipher.fontRef` via
  `FontStore` to a font name; views use `.custom(name, size)` (today's hardcoded
  `RuneTheme.runic` becomes cipher-aware). A missing custom font falls back to a system font
  so runes still display.

## C. https / Universal-Link sharing

- **Generated link form:**
  `https://ravenforgesoftware.com/rune-scribe/import?v=3&p=<base64url payload>&n=<name>`.
  This replaces `runescribe://import` as the form the app emits for ShareLink, QR, and
  deep-link export.
- **App supports Universal Links:**
  - Add `com.apple.developer.associated-domains = ["applinks:ravenforgesoftware.com"]` to
    `Config/RuneScrib-iOS.entitlements` and `Config/RuneScrib-macOS.entitlements`.
  - Handle the inbound universal link: iOS/macOS deliver it as an
    `NSUserActivity` (`NSUserActivityTypeBrowsingWeb`) → `.onContinueUserActivity(...)` /
    `application(_:continue:restorationHandler:)` reading `userActivity.webpageURL`, routed
    into `ImportCoordinator.ingest(url:)`. (Custom-scheme links keep arriving via `.onOpenURL`
    / `application(_:open:)`.)
- **`CipherSharePayload(url:)`** parses the https host/path form
  (`ravenforgesoftware.com` + path `/rune-scribe/import`) **and** keeps parsing the legacy
  `runescribe://import` scheme (back-compat for Phase-1 links/QRs).
  `ImportCoordinator.ingest(urlString:)` and `Clipboard.runeScribeURLString()` recognise the
  https URL (host/path) in addition to the scheme.
- **Behaviour:** recipient **with** Rune Scribe taps the link → app opens, imports the cipher
  / decodes. Recipient **without** → the existing rune-scribe webpage (app info + App Store).
- **Dependency (note — outside this repo):** for the https link to open the app *directly*,
  the site must serve `apple-app-site-association` at
  `https://ravenforgesoftware.com/.well-known/apple-app-site-association` listing the app's
  App ID. The webpage already exists. Until the AASA is live, app users import via QR / paste
  (the app parses the https URL); non-app users get the webpage regardless.

## Components (new / changed)

- **`FontRef`** (Model) — id, version, sha256; the bundled-font constant.
- **`FontStore`** (Service) — import/validate/register/resolve; launch registration.
- **`CipherSharePayload`** (extended) — fontRef in the compact form, font bytes in the file
  form, https URL generate + parse, v3, legacy-scheme parse retained.
- **`Cipher`** (+`fontRef` with bundled default).
- **`RuneFont`** / `RuneTheme` — cipher-aware rune font resolution.
- **`ImportCoordinator`** / **`Clipboard`** — recognise the https URL.
- **`RuneScribApp`** / **`AppDelegate`** — handle the universal-link `NSUserActivity`.
- **Entitlements** — associated-domains for both platforms.
- **`FontRegistration`** → folded into `FontStore` (register bundled + imported at launch).
- **Views** — import-confirm reflects the font / "complete" state; export writes the file form;
  `CipherLibraryView` share emits the https link.

## Testing

- `FontRef` for the bundled font has the expected stable SHA-256; bundled font resolves.
- Compact payload **v3** round-trips with `fontRef`; the file form round-trips payload **+**
  font bytes.
- `FontStore.importFont` accepts the real bundled font, **rejects** corrupt bytes and a
  hash-mismatched ref, and leaves existing state unchanged on rejection.
- https URL generate → parse round-trips (with name); the legacy `runescribe://import` scheme
  still parses.
- `Cipher` Codable default gives a Phase-1-encoded cipher (no `fontRef`) the bundled font ref.
- Share → import via the **file form** reconstructs a working cipher whose messages decode.

## Risks / decisions

- **AASA is a website dependency** for direct app-open; flagged, not built here.
- **associated-domains entitlement + ad-hoc test signing:** the headless test build signs
  ad-hoc (`CODE_SIGN_IDENTITY="-"`); the entitlement may need to be tolerated/stripped for that
  build (as Phase 1 handled signing). Unit tests don't exercise universal links, so this is a
  build-config concern to resolve during implementation.
- **Universal Links arrive as `NSUserActivity`, not `onOpenURL`** — handled via
  `onContinueUserActivity`; the custom scheme path is unchanged.
- **Font size** (~55 KB) inflates the file-form package (fine for a file/attachment; excluded
  from the QR/link).
