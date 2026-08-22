# Rune Scribe Support

**Current product source:** version 1.0.38 (build 38)
**Publication boundary:** owner test required; not shipped

## Import and sharing

- A `.runescribe` file may contain a cipher invitation or an encrypted message. Open it
  from Files/Finder or use Rune Scribe's Import action.
- On iOS, a Messages attachment can open directly in Rune Scribe. macOS does not claim
  automatic Messages import; use the file, Import, or a `runescribe://` link.
- A first-delivery message can show a decrypted preview, but its embedded cipher and
  claimed sender remain unverified until you confirm the cipher. Rune Scribe does not
  create or rebind a contact from the sender label in the attachment.
- A valid encrypted message remains readable with the Base Norse appearance when the
  sender's Codex is locked, unavailable, incompatible, corrupt, or not installed.
- Requested themed presentation is used only after the installed provider confirms the
  selected artifacts and each referenced resource's type, dimensions, length, and
  digest. A mismatch falls back to Base Norse without rejecting the valid message.
- A cipher invitation carries key material. Treat a cipher file, QR image, or invitation
  link as sensitive and do not post it publicly.

## iCloud and Game Center status

Rune Scribe's local Vault works without either Apple service.

- **Waiting for iCloud or network:** local changes remain queued and retry later.
- **iCloud account changed:** local progress is protected and sync pauses. Use the
  Settings rebind action only after confirming the intended Apple account.
- **Protected local progress:** invalid remote data was ignored; local progress remains
  available.
- **Game Center not connected:** reporting is optional. Connecting is always a user
  action, and stopping mirroring does not remove local achievements. When opt-in was
  previously saved, a later launch may make one authentication attempt and then drain
  queued reports. Cancellation or denial does not repeatedly prompt; queued reports
  remain durable until a permitted later attempt succeeds or mirroring is disabled.

Live iCloud-container provisioning and Game Center record configuration are release
owner tasks. A missing or unavailable service must not block encryption, decryption,
imports, sharing, appearance fallback, or local progression.

## App Lock and recovery

App Lock uses a four-digit PIN. Rune Scribe cannot reveal a forgotten PIN. Follow the
in-app reset flow only after understanding its local-data effect. Repeated incorrect
attempts trigger an escalating delay that persists across relaunches.

If a themed preview cannot be rendered, Rune Scribe preserves the underlying secure
share and clearly reports that the standard legacy appearance was used. If an import
fails, retain the original file and record the platform, app version, and exact visible
error; do not send cipher keys or decrypted text in a support request.

## Compatibility and accessibility

The supported deployment targets are iOS 17 or later and macOS 15 or later. Surrounding
UI supports Dynamic Type, VoiceOver labels, keyboard and pointer focus, High Contrast,
Reduce Motion, monochrome presentation, and non-audio unlock feedback. Hardware-only
and live-service qualification remains part of the release owner's pre-ship checklist.

For help, use the contact channel published at
[Raven Forge Software](https://ravenforgesoftware.com/). Include the app version, build,
platform version, and whether the issue occurs with iCloud or Game Center disabled.
