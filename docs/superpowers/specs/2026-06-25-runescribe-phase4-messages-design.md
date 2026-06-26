# Rune Scribe — Phase 4: Apple Messages Send & Key Auto-Exchange

**Status:** Reviewed — owner decisions captured 2026-06-26; ready to plan
**Date:** 2026-06-25
**Phase:** 4 of 4 (Phases 1 — encryption — 2 — font package + Universal Links — 3 — Contacts — are merged / PR'd.)

## Programme context

1. Real encryption + new cipher model — merged.
2. Font in the cipher package + https Universal-Link sharing — merged.
3. Contacts + per-contact ciphers — PR #19.
4. **This phase:** send a message over **Apple Messages** with a prominent, discoverable
   action; auto-exchange the cipher key on the first message to a contact; a recipient with
   the app taps to decode, a recipient without it is routed to the product page. Plus a
   **native Apple Share** action, and the updated **splash video** folded in.

**Nothing about the encryption or the rune encoding changes.** Phase 1 already does
plaintext → AES-GCM seal (`MessageCryptor`, pre-shared cipher key) → 1-byte `MessageEnvelope`
→ `RuneCodec.encode` (reversible base-32 over the rune glyphs). The runes carry **no security**
of their own — they are a reversible, cosmetic rendering of the encrypted envelope; the
security is the pre-shared symmetric cipher key. This phase is **transmission + key delivery +
receive-side auto-import**, wiring the existing pieces into Messages.

## Confirmed decisions (2026-06-26)

Reconciled with the owner's requirements:

1. **Per-contact key — on import.** Importing a contact (Import All, the picker, or Add)
   auto-assigns it a freshly-generated cipher (key-delivered marker unset), labelled with the
   contact's name and linked via `contactID`. Contacts that are **not** imported, and the plain
   non-contact compose flow, stay **manual** (create/select a cipher as today).
2. **Rune fidelity — tap-to-open restores it.** The bubble shows runes in the recipient's
   system font; full Noto Sans Runic fidelity returns when they open the app (Phase 2 font
   package). No image-rendering path is added.
3. **Universal Links + website — in scope (app + site)** this phase (see *Universal Links +
   website*).
4. **Key delivery — embed-on-first-message default.** Convenient auto-exchange; out-of-band
   QR/file sharing remains the fully-private alternative. The app surfaces, lightly, whether a
   message carried the key ("key included" vs "uses your shared key").
5. **Silent one-tap iMessage — not possible.** No public API sends iMessage without user
   confirmation; the send action opens a pre-filled `MFMessageComposeViewController` (iOS) the
   user taps Send on (reaffirmed under Non-goals).

## What gets sent (the core model)

A sent Rune Scribe message is an iMessage containing **two things**:

1. **The runes, as plain text** — the existing `MessageService.compose(plaintext, cipher)`
   output. This is what a human sees in the bubble. Without the cipher key it is meaningless,
   so it leaks nothing.
2. **The real encrypted message, embedded in a deep link** (an https Universal Link on
   `ravenforgesoftware.com/rune-scribe/…`) — carrying the `MessageEnvelope` (AES-GCM sealed
   box) and, on the **first message to a contact / first message after a manual rotation**, the
   **cipher key** itself. For a long message that would overflow a URL, the payload is carried
   instead as a **hidden file attachment** (the existing file-form pattern).

**Recipient with the app:** sees the runes; tapping the link opens the app, which imports the
embedded key (if present), decrypts the envelope, displays the message, and associates the
cipher with a contact. **Recipient without the app:** the same link routes (via the existing
AASA + product page) to the website's "get the app" Rune Scribe page.

This reuses the rail built in Phase 2 — `CipherSharePayload.url(name:)` / `init(url:)`,
`ImportCoordinator.ingest(url:)`, `RuneScribApp`'s `.onOpenURL` + `.onContinueUserActivity`,
`AppDelegate.application(_:open:)`, and the `applinks:ravenforgesoftware.com` entitlement — and
extends it to carry a **message** in addition to a **cipher**.

## Key lifecycle (no crypto change; tracks delivery)

- A cipher = one pre-shared AES-256 key (Phase 1), linked to at most one contact (Phase 3).
- **Per-contact key on import** (new): importing a contact (Import All, picker, or Add)
  auto-generates a cipher for it — marker unset, labelled with the contact name, linked via
  `contactID`. Import All makes one cipher per imported contact. The non-imported / plain-compose
  path stays **manual** (create or select a cipher as today).
- **First message to a contact** (the cipher's "key delivered" marker is unset) embeds the key
  in the link and sets the marker. Every message after that carries **just the message**, using
  the same key.
- **Rotation is manual** = create a new cipher for that contact (the existing *New Cipher* flow;
  Phase 2 rule — there is no automatic rotation). A new cipher's marker is unset, so its **next
  message re-embeds the new key**, which the other side **auto-imports** on tap.
- **Bidirectional:** the same applies whichever side composes. Receiving a message whose
  embedded key is newer than the stored one for that contact updates the stored cipher.

## Receive-side behaviour (tap the link)

1. **Has the app** → the Universal Link opens it. Intake:
   - If the payload embeds a cipher, import it (reuse the Phase 1/2 cipher import; if a cipher
     with the same `publicID` already exists it is updated, not duplicated).
   - Decrypt the `MessageEnvelope` with the embedded/just-imported cipher, or by trying stored
     ciphers (`MessageService.read` semantics — the AEAD tag authenticates exactly one).
   - Show the decrypted plaintext in a **received-message sheet** (who it's from + the text),
     analogous to today's import-confirm sheet.
   - **Auto-associate** the cipher with a contact (see Decisions).
2. **No app** → routes to the website Rune Scribe product page ("get the app" + App Store
   link). This is the existing AASA/site behaviour; no web work in this repo.

## Components (new / changed)

- **`MessageSharePayload`** (Model, new) — the wire format for a message: `MessageEnvelope`
  bytes + an optional embedded `CipherSharePayload` (key, for first-send/rotation) + the
  sender's display name. Mirrors `CipherSharePayload`: a compact binary form with version +
  checksum, a base64url **Universal-Link URL** under a distinct path (e.g.
  `/rune-scribe/m`), and a **file form** (compact payload + any overflow) for long messages.
  Generate + parse + round-trip, reusing the base64url / checksum helpers' style.
- **Message intake** — extend `ImportCoordinator` (or add a sibling `MessageCoordinator`) to
  recognise the message path, decode → import-embedded-cipher → decrypt → publish a decoded
  message for display. Wire into the existing `.onOpenURL` / `.onContinueUserActivity` /
  macOS `application(_:open:)` routing (which dispatches cipher-link vs message-link by path).
- **`ReceivedMessageView`** (View, new) — the sheet showing a decrypted incoming message
  (sender + plaintext), with a "Reply" affordance that seeds the compose screen.
- **Send UI** — the compose-result area of `ContentView` gains:
  - **"Send via iMessage"** (iOS) — `MFMessageComposeViewController` (`MessageUI`), prefilled
    with the runes (body) + the message link (or a hidden file attachment for long messages).
  - **A native Apple Share icon** — `ShareLink` / `UIActivityViewController` sharing the same
    runes + link, so sending works through Apple's standard share sheet (Messages, Mail,
    AirDrop, …). This is the **only** send path on macOS.
- **`MessageDeliveryTracker`** (or a field on the cipher/contact) — records, per cipher,
  whether its key has been delivered to its contact, so the first send embeds the key.
- **Info.plist / capability** — iOS `MessageUI` needs no usage string; confirm no new
  entitlement. The message path is covered by the existing associated-domains AASA.
- **Splash** — cherry-pick the `chore/splash-video-v2` asset swap (`raven-forge-spp-splash.mp4`,
  960×960, ~10s) onto this branch; same resource name, no code change.

## UI

- **Compose result** (after encoding): the existing *Edit* / *Copy* buttons gain **Send via
  iMessage** (iOS) and a **Share** icon (both platforms) so sending is the obvious primary
  action — directly addressing "sending isn't discoverable."
- **Received-message sheet:** opens when a message link is tapped — shows the sender (contact
  name when known) and the decrypted text; offers Reply.
- **Cipher library / compose** continue to show the linked contact ("To: …", Phase 3).

## Universal Links + website (in scope this phase)

Tap-to-open and the no-app fallback need link infrastructure that does not yet exist (no
`associated-domains` entitlement, no AASA file):

- **App:** add `associated-domains` = `applinks:ravenforgesoftware.com` to both the iOS and
  macOS targets via `project.yml` (alongside the existing `Config/RuneScrib-*.entitlements`).
- **Site:** publish `https://ravenforgesoftware.com/.well-known/apple-app-site-association` —
  JSON, no file extension, served as `application/json` — declaring appID
  `9AQ2C2838M.com.runescribe.app` with `applinks` paths covering the cipher link
  (`/rune-scribe/import`) and the message link (`/rune-scribe/m`). Edited via the Claude Bridge.
- **No-app fallback:** the `/rune-scribe/` page already exists; make it cleanly handle a visitor
  who tapped a link without the app — show the Rune Scribe product info and a link to the
  **company page** (the App Store page does not exist yet). No per-message payload is rendered on
  the web (it is meaningless without the app's key).
- Cross-repo: the app changes live in this repo; the AASA file + page live on the website.

## Non-goals (out of scope)

- **Silent / one-tap-without-confirmation iMessage send, and background message monitoring** —
  impossible via public APIs: no programmatic iMessage send, no read access to the Messages
  database. Sending is user-initiated — the app opens a pre-filled `MFMessageComposeViewController`
  (iOS) the user taps Send on; macOS uses the native Share sheet.
- **A macOS Messages compose sheet** — `MFMessageComposeViewController` is iOS-only; macOS uses
  the native Share sheet.
- **Changing the encryption or the rune encoding** — Phases 1–2 stand unchanged.
- **(Now in scope this phase)** the AASA file + `/rune-scribe/` no-app fallback — see
  *Universal Links + website* above.

## Testing

- `MessageSharePayload` round-trips: link form and file form; with and without an embedded
  cipher; version + checksum reject corruption.
- Intake: a message link → decode → (import embedded cipher) → decrypt → correct plaintext;
  a message that needs a stored cipher decrypts via try-all; a wrong/absent cipher fails
  cleanly with a readable error.
- Key-delivery marker: first send embeds the key + sets the marker; subsequent sends omit it;
  a new (rotated) cipher re-embeds on its next send.
- Receive-side auto-association by sender name (match existing contact, else create).
- Round-trip: compose → "send" payload → intake reconstructs the same plaintext under the
  embedded key.
- (The `MFMessageComposeViewController` flow, the share sheet, and the tap-to-open routing are
  build-verified + manual, not unit-tested — consistent with prior phases.)

## Risks / decisions

- **Receiver-side auto-association mechanism** (please confirm): the message payload carries the
  **sender's display name only** (never a phone/email — that would leak contact info). On
  import, if the receiver has a contact whose name matches → associate the cipher with it; else
  create a contact with that name and associate. Fully automatic and privacy-safe. *(Alternative
  considered: prompt "who is this from?" — rejected as not automatic.)*
- **"Only runes in the bubble" vs the visible link:** a hidden **file** attachment keeps the
  bubble purely runes but cannot route a non-app recipient anywhere; the **deep link** is what
  enables the non-app "get the app" routing but is visible alongside the runes (it can render as
  a compact rich preview if the site serves Open Graph metadata — an external, site-side nicety
  like AASA). **Decision:** the deep link is the **primary** mechanism (short messages, non-app
  routing); the file form is the **fallback for long messages** (app-to-app). The plan may register
  a `.runescribe` document type so a tapped file opens the app.
- **URL length:** realistic message ciphertext is small and fits a Universal Link comfortably;
  the file fallback covers the rare long message.
- **Dedup of double delivery:** `ImportCoordinator` already dedupes the same URL arriving via
  both `.onOpenURL` and `application(_:open:)`; the message path inherits this.
- **`MessageUI` import is iOS-only** — guard with `#if os(iOS)`; macOS build excludes it.
