# Rune Scribe Support

**Current product source:** version 1.0.42 (build 42)
**Publication boundary:** Current source requires fresh Store qualification; not shipped

Earlier source-bound results and screenshots are indexed in the
[UI/Xcode remediation qualification](verification/ui-xcode-remediation/QualificationSummary.md).
The version 1.0.40 counts below are retained historical context and are not evidence for
the new candidate.

Final-source qualification passes the Swift and Python suites, the executable 17-ratchet
architecture guard, roadmap/documentation guards, exact-resource validators, and
negative mutation suites. The iOS
Release build and arm64-only unsigned macOS Release build pass. Built-product content,
resource, privacy, local-signature, Hardened Runtime, and entitlement inspection passes
101/101 checks on local products. The earlier iOS and macOS archives exported
successfully for App Store Connect with matching distribution identities, Store
profiles, versions, production entitlements, and package signatures, but they predate
later merged changes and do not qualify the current source. Retained prior iPhone 17 Pro headless UI evidence records
7 tests with 1 iPad-only skip and 0 failures. The iPad Pro 13-inch (M5) headless UI run
on iOS 26.5 records 5 passed, 3 phone-specific skipped by design, and 0 failed. Those
runs are not represented as current-candidate source-bound evidence. The
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
- Long themed output is presented in the canonical Artifact preview with truthful
  `Page n of m` navigation. Use Previous and Next to review every page; rotating an
  iPhone/iPad or resizing the Mac window preserves the selected page.
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

Received plaintext remains complete, selectable, and reflows within the available
width. Rune Scribe does not label a message with a false line count or hide the rest
behind an inactive disclosure control.

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
repository-qualified release candidate with no known release-blocking defects. Retained
prior headless UI results remain regression context rather than current-candidate
source-bound evidence. Fresh current-source archive and export qualification is required
before owner upload; App Store Connect validation, upload, submission, release, and
rollout remain external publication work.

For help, use the contact channel published at
[Raven Forge Software](https://ravenforgesoftware.com/). Include the app version, build,
platform version, and whether the issue occurs with iCloud or Game Center disabled.
