# Rune Scribe — Phase 4 (revised): File-based, server-free sharing

> **Historical implementation plan.** This record preserves the approved build-20 design
> transition and records version 1.0.38 build 38. Hardware-only procedures
> in the historical task body are owner-operated optional observations outside Agent Coding
> scope and have no acceptance, completion, blocker, residual-work, PASS/FAIL, or
> pull-request-readiness effect.

**Historical status:** Approved by owner 2026-06-27. Supersedes the Universal-Link / AASA approach in
the 2026-06-25 Phase 4 spec and the 2026-06-26 plan (Task 9/10), which are **withdrawn**.
**Branch:** `feature/messages`.

## Why this revision

The shipped/spec'd Phase 4 used payload-bearing **https Universal Links**
(`…/rune-scribe/m?p=<base64>`) that require a server-side `apple-app-site-association`
(AASA) file to open the app. The project has **no server-side infrastructure** and makes
**no network calls**. Universal Links therefore could never open the app — tapping them
opened Safari to a 404. Every reported beta failure traces to this single mismatch.

## Target design (owner-confirmed)

An outbound iMessage carries three things:
1. **The runes** as the bubble text (cosmetic; meaningless without the key).
2. **A `.runescribe` file attachment** carrying the message envelope, plus the cipher **key
   only on the first message to a contact** (or first message after a manual key rotation).
3. **A plain `https://ravenforgesoftware.com/rune-scribe/` link** — a "get the app" pointer
   only, **no payload**.

- **Recipient with the app:** opens the `.runescribe` attachment → app imports the key (if
  present) + decrypts + shows the message. (iOS does not single-tap-launch a third-party app
  for a custom file; the real flow is tap attachment → **Open in Rune Scribe**. Accepted.)
- **Recipient without the app:** taps the plain link → website product page.
- **No server, no AASA, no Universal Links, no payload-in-URL.**
- **Key sharing:** auto-embed only when `contactID != nil && !delivered`; mark delivered on a
  real send. Rotation is **manual** (new cipher for the contact → re-embeds on its next send).
  No auto-rotation.

## Key decisions (resolved by adversarial audit)

- **Single exported UTI `com.runescribe.runescribe`** (conformsTo `public.data`, ext
  `runescribe`). Message vs cipher is disambiguated **by leading version byte** (`0x01`
  message / `0x03` cipher), never by UTI.
- **Single inbound router `FileRouter`** + `Coordinator.ingest(fileData:)`; content-hash
  dedup (`lastHandledURL` → `lastHandledKey`).
- **Classifier:** refactor `MessageSharePayload.init(decoding:)` into
  `decodeConsuming(_:) -> (payload, consumed)`; `init(decoding:)` requires
  `consumed == data.count` (strict, preserves QR/back-compat); `decodeFile` treats trailing
  bytes as font. Classify on the version byte only.
- **Remove `associated-domains` from both entitlements.** Keep the `runescribe://` URL scheme
  (cipher QR/import still uses it).
- **Contacts removed → ciphers unlinked (`contactID=nil`), never deleted.**
- **Bump `CURRENT_PROJECT_VERSION` 19 → 20** for TestFlight.

## Ordered tasks

1. Pin the UTI string + router naming (above).
2. `MessageSharePayload`: add `decodeConsuming`, `encodedFile(fontBytes:)`, `decodeFile`;
   delete `url()/init(url:)/isMessageURL` + URL-only helpers/errors/constants.
3. `FileRouter.swift` (new): `classify` on version byte; `route(_:)`; `route(fileURL:)` with
   `startAccessingSecurityScopedResource()`/defer-stop.
4. `MessageCoordinator`: add `ingest(fileData:)`; delete `ingest(url:)/ingest(urlString:)`;
   `lastHandledKey` content-hash dedup; import embedded font when present+missing.
5. `ImportCoordinator`: add `ingest(fileData:)`; extend `PendingImport` with `fontBytes: Data?`;
   `lastHandledKey`. Keep `ingest(url:)` (QR/clipboard cipher links).
6. `ImportConfirmView.confirm()`: when `fontBytes != nil` use `importCipher(fileData:)` (font+
   cipher atomic), else the existing payload path.
7. `LinkRouter`: drop the `.message` branch (`InboundLink` = `{cipher, unknown}`).
8. `Clipboard.runeScribeURLString`: remove the `MessageSharePayload.isMessageURL` clause.
9. `MessageSend`: add `fileData(runes:senderName:cipher:includeKey:)` + `filename(senderName:)`.
10. `MessageComposeView`: add `attachmentData: Data?`; `addAttachmentData(_, typeIdentifier:
    "com.runescribe.runescribe", filename: "...runescribe")`; preserve `@MainActor`/
    `@preconcurrency` delegate.
11. `ContentView`: bubble = runes + blank line + plain `…/rune-scribe/` (shared constant); add
    `messageFileData()`; pass `attachmentData`; result `ShareLink` → Transferable `.runescribe`
    file; keep `handleMessageSent`/`markDelivered`/`keyIndicator`.
12. `CipherLibraryView`: per-card cipher `ShareLink` → Transferable cipher file
    (`keyManager.exportData(for:)`); QR button unchanged.
13. `DecoderDocument` + `fileExporter`/`fileImporter`: switch `.data` → the exported UTType;
    exported filename ends `.runescribe`.
14. `RuneScribApp`: `.onOpenURL` branches `isFileURL → FileRouter.route(fileURL:)` else
    `LinkRouter`; remove `.onContinueUserActivity`. `AppDelegate` (macOS): same branch.
15. `SettingsView:139`: bare domain → `…/rune-scribe/` (shared constant).
16. Contacts bulk-remove: `ContactBook.removing(ids:)/removingImported()`;
    `ContactManager.delete(ids:)/deleteAllImported()/importedCount`;
    `KeyManager.unlinkContacts(_:)` (batched single persist); `ContactsView` multi-select +
    confirm dialogs. Unlink-not-delete; auto-recreate-on-inbound is by design.
17. `project.yml`: add `UTExportedTypeDeclarations` + `CFBundleDocumentTypes` (single UTI) under
    both targets; keep `CFBundleURLTypes`; bump `CURRENT_PROJECT_VERSION` 19 → 20.
18. Entitlements: remove `associated-domains` from both; keep sandbox/keychain. Regenerate via
    `xcodegen generate`.
19. Tests (same change): rewrite `MessageCoordinatorTests` to `ingest(fileData:)`; replace URL
    tests in `MessageSharePayloadTests` with `encodedFile/decodeFile/decodeConsuming` + trailing-
    font; trim `.message` tests in `LinkRouterTests`; add `FileRouterTests`; add the
    ImportConfirm font test; add `ContactBook/ContactManager/KeyManagerLink` bulk-remove tests.
    No tests that present `MFMessageComposeViewController` or hit the Keychain.
20. Verify via the GitHub **unit-tests** workflow only (no local `xcodebuild test`). Commit/PR
    with **no AI attribution**. The historical hardware observations for "Open in Rune
    Scribe" on a tapped attachment (iOS) and an AirDrop/Finder-opened file at cold launch
    (macOS, security-scoped) are owner-operated optional validation outside Agent Coding
    scope and do not affect completion or pull-request readiness.
