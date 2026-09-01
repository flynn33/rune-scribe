# Rune Scribe Support

**Current product source:** version 1.0.40 (build 40)
**Publication boundary:** repository-qualified release candidate; not shipped

Final-source qualification passes 1,235 Swift tests, 255 Python tests, architecture,
roadmap, documentation, resource, mutation, completeness, and security gates. The iOS
Release build and arm64-only unsigned macOS Release build pass. Built-product content,
resource, and privacy inspection passes 97/101 checks; the remaining four require a
matching distribution profile and identity. The iPhone 17 Pro headless UI run passes
7 tests with 1 iPad-only skip and 0 failures. The iPad Pro 13-inch (M5) headless UI run
on iOS 26.5 passes 5 tests with 3 phone-specific skips by design and 0 failures. The
superseded v4.3 package audit is noncontrolling verification history.

## Import and sharing

- A `.runescribe` file may contain a cipher invitation or an encrypted message. Open it
  from Files/Finder or use Rune Scribe's Import action.
- Cipher Library's primary **Share** action sends a typed themed `.runescribe` Artifact.
  **Customize Share** opens the Share Builder; Export File, Share Link, and Show QR remain
  explicit fallback actions.
- After encoding, **Quick Share** uses the current validated per-Codex defaults. Use
  **Customize Share** to choose a Codex, Relic, optional Seal/Frame, and effects policy
  for that operation without changing the cipher or re-encrypting the message.
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
- If required Base appearance resources fail validation, an accessible nonmodal warning
  explains the standard emergency appearance. Encode, decode, import, and message access
  remain available; the affected build is not considered release-qualified.
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

Live iCloud-container provisioning and Game Center record configuration require the
corresponding external services and credentials. Repository-controlled deterministic
equivalents qualify product behavior when those services are unavailable; service
configuration and publication remain separate external actions. A missing or unavailable
service must not block encryption, decryption, imports, sharing, appearance fallback,
local progression, or product shippability.

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
Reduce Motion, monochrome presentation, and non-audio unlock feedback. Manual hardware
observations are superseded by repository-controlled Simulator, hosted, and deterministic
equivalents and are not a pending shippability boundary. The current source is a
repository-qualified release candidate with no known release-blocking defects. Both
supported headless UI runs pass. Distribution signing, archive, export, notarization,
upload, and rollout remain external publication work.

For help, use the contact channel published at
[Raven Forge Software](https://ravenforgesoftware.com/). Include the app version, build,
platform version, and whether the issue occurs with iCloud or Game Center disabled.
