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

iOS supports opening a Messages attachment directly in Rune Scribe. When a first
message includes an embedded key, the app may show a decrypted preview but labels the
sender claim as unverified and keeps the key transient. The recipient must confirm the
cipher before it is saved or used for Reply. Later themed messages do not resend the
key; they use the confirmed local cipher identity rather than trusting the wire label.

## Themed presentation fallback

Both platforms validate the encrypted Core payload independently from optional
presentation. A locked, unknown, unavailable, incompatible, corrupt, or uninstalled
Codex falls back to the Norse interactive presentation. A valid sender-rendered 4:3
preview remains visible. Invalid preview or provenance state is labeled and ignored;
it cannot block authenticated message decryption or grant content.

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

Manual hardware observations are superseded by repository-controlled macOS hosted,
iPhone Simulator, iPad Simulator, and deterministic evidence. Version 1.0.40 build 40 is
a repository-qualified release candidate and is not shipped. The iOS Release build and
arm64-only unsigned macOS Release build pass, as does the iPhone 17 Pro headless UI run
on iOS 26.5 with 7 passed, 1 iPad-only skipped, and 0 failed. The iPad Pro 13-inch (M5)
headless UI run on iOS 26.5 passes with 5 passed, 3 phone-specific skipped by design, and
0 failed. Local ad-hoc built-product content, resource, privacy, signature, Hardened
Runtime, and entitlement inspection passes 101/101 checks. Distribution identity and
provisioning remain unassessed external publication work. The separate v4.3 package audit is incomplete
but noncontrolling.

The same privacy rule applies on both platforms: a `.runescribe` file or import link
carries the actual cipher key. Share it only through a private channel.
