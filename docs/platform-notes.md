# Platform Notes

Rune Scribe shares the same encrypted payload formats across macOS and iOS, but the
operating systems expose different intake paths.

## Cipher Import on macOS

Automatic cipher import from Messages is not supported on Mac. A `.runescribe`
cipher file received in Messages does not silently add itself to the cipher library;
every new cipher requires confirmation before persistence.

On macOS, import a cipher by one of these supported paths:

- Open **Cipher Library > Import** and choose the `.runescribe` file.
- Open a saved `.runescribe` file with Rune Scribe.
- Paste a `runescribe://` import link into Rune Scribe.

The imported cipher is still validated on-device before it is saved. Exact legacy
payloads must have the expected version, byte length, rune permutation, and checksum.
Typed packages additionally require canonical sections, supported required versions,
bounded resources, and matching hashes before their Core payload is admitted.

## iOS Intake

iOS supports opening a Messages attachment directly in Rune Scribe. A regular message
package contains the encrypted message without an embedded cipher. The recipient
imports a separately shared cipher from Cipher Manager before decoding; messages use
the confirmed local cipher identity rather than trusting the wire sender label.

Cipher invitations also have a dedicated Messages extension route. The sender composes
an `MSMessage` with the themed 4:3 artwork in `MSMessageTemplateLayout.image` and the
exact validated HTTPS invitation in `MSMessage.url`. The invitation composer body is
empty; the artwork caption and subcaption remain. No PNG or `.runescribe` attachment is
added on this route. The extension's
only action is **Continue to Rune Scribe**; it asks the system to open that URL, while a
key-free App Group envelope provides recovery. The containing app remains the only
import-confirmation and mutation authority.

The physical-device matrix for installed-app cold start, installed-app already running,
deleted-app fallback, tappable artwork and invitation URL, and green-bubble/SMS behavior has
not been run. The source, simulator, and signing results do not prove transcript or tap
behavior, and the feature remains device-unqualified.

## Themed presentation fallback

Both platforms validate the encrypted Core payload independently from optional
presentation. A locked, unknown, unavailable, incompatible, corrupt, or uninstalled
Codex falls back to the Norse interactive presentation. A valid sender-rendered 4:3
preview remains visible. Invalid preview or provenance state is labeled and ignored;
it cannot block authenticated message decryption or grant content.

Normal compose and result routes use the same responsive, scrollable workspace policy.
Multi-page themed output uses the canonical Artifact preview and preserves its current
page across iPhone/iPad rotation and Mac window resizing. Rune lines are measured and
paginated within the tablet inscription rect. iOS paging controls keep a
44-point minimum interaction region; Mac controls keep a 28-point minimum. App Lock
hides and disables the underlying editor and Settings content from both interaction and
the accessibility tree until the PIN is accepted.

Compact `runescribe://` links and cipher QR codes remain the legacy-compatible offline
invitation rail. Themed cipher files use the typed package rail.

## Optional Apple services

Private iCloud progression sync and Game Center reporting are optional on both
platforms. They are not required on first run and do not carry cipher keys, contacts,
plaintext, full messages, QR content, or package bytes. Source entitlements are present,
and repository-controlled deterministic equivalents cover unavailable, account-change,
retry, corruption, and reporting behavior. Live container, account, record, and sandbox
configuration is a separate external-service action when credentials are available; it
does not determine product shippability.

Manual hardware observations are superseded for the previously covered behavior by
repository-controlled macOS hosted, iPhone Simulator, iPad Simulator, and deterministic
evidence. The new Messages extension device matrix above is an explicit exception.
Version 1.0.44 build 44 is the current source candidate and is not shipped. The linked
[qualification report](verification/ui-xcode-remediation/QualificationSummary.md)
records the earlier 1.0.41 source; fresh current-source qualification is required.
Version 1.0.40 retained evidence records the iPhone
17 Pro headless UI run on iOS 26.5 with 7 passed, 1 iPad-only skipped, and 0 failed and
the iPad Pro 13-inch (M5) run with 5 passed, 3 phone-specific skipped by design, and 0
failed; those runs are not current-candidate source-bound evidence. Local ad-hoc
built-product content, resource, privacy, signature, Hardened
Runtime, and entitlement inspection passed 101/101 checks for the earlier qualified
source. Its iOS and macOS App Store exports passed distribution signature, Store profile,
production-entitlement, architecture, privacy-manifest, and package inspection, but
they predate later merged changes and must not be reused for the current source. Fresh
qualification, upload, and submission remain owner-operated publication work. The separate v4.3 package audit is incomplete
but noncontrolling.

The same privacy rule applies on both platforms: a `.runescribe` file or import link
carries the actual cipher key. Share it only through a private channel.
