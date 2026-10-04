# ADR-RS-014: Interactive Messages Cipher Invitations

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted; source implemented, physical-device qualification pending
**Date:** 2026-09-25
**Supersedes:** The cipher-invitation Messages conclusion in ADR-RS-012

## Decision

On iOS, Cipher Library **Share** and the cipher-invitation route in Share Builder compose
an `MSMessage`. `MSMessageTemplateLayout.image` receives the existing themed render
letterboxed into a 300 × 225-point 4:3 canvas with the agreed safe inset and no
instructional text in the bitmap. The exact validated HTTPS invitation is assigned to
`MSMessage.url`; the composer body is empty. This route attaches neither a PNG
nor a `.runescribe` file.

The embedded `RuneScribeMessagesExtension` (`com.runescribe.app.messages`) is a handoff
surface only. Its single action is **Continue to Rune Scribe**. After validating the
selected message URL, it records a key-free recovery envelope in
`group.com.runescribe.app` and calls `extensionContext.open` with that exact URL. The
containing app remains the only import-confirmation UI and mutation authority. Its new
durable post-import fingerprint guard makes repeated URL delivery, App Group recovery,
and repeated confirmation idempotent.

The extension links only the extension-safe Messages Shared package target and required
Apple frameworks. `APPLICATION_EXTENSION_API_ONLY = YES` is mandatory. Keychain,
CloudKit, Share Builder UI, the full UI Module, cipher persistence, and import mutation
are forbidden in the extension.

## Compatibility and fallback

The invitation is carried by `MSMessage.url` and the tappable artwork. Messages
transport and recipient behavior, including SMS/green-bubble fallback, require
physical-device qualification. Explicit Export and QR remain separate user actions.

## Evidence boundary

Source tests, simulator builds, automatic-signing builds, provisioning profiles, and
signed-product entitlements do not establish recipient transcript behavior. Before the
feature is accepted, two physical iPhones must cover:

1. recipient with Rune Scribe installed, app cold;
2. recipient with Rune Scribe installed, app already running;
3. recipient with Rune Scribe deleted;
4. tappable artwork and invitation URL; and
5. green-bubble/SMS behavior.

Each row must record what appeared in the transcript, what the first artwork tap did,
and whether the containing-app import confirmation ran exactly once. These rows have not
been run. Artwork-tap import, deleted-app product/App Store fallback, and SMS fallback
therefore remain unproven for the current 1.0.46 source candidate. The ordinary-message
transport change in [ADR-RS-015](ADR-RS-015-encoded-messages-artwork-and-runes.md) does not
alter this separate cipher-invitation route or establish shipment.
