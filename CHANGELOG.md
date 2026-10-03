# Changelog

All notable changes to Rune Scribe are recorded here. Entries are maintained with
release work and reviewed against the project version before merge. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

<!-- NEW ENTRIES BELOW -->
## [Unreleased]

## [1.0.45] - 2026-10-03

- Remove an unused share-completion result variable that caused a Swift compiler
  warning in `ContentView`. The completion call and error handling remain unchanged.
- Advance the local source candidate to version 1.0.45 build 45. An unsigned macOS
  build from the Downloads project passed without the reported warning. This source
  candidate is not shipped.

## [1.0.44] - 2026-10-03

- Remove the visible cipher-invitation fallback text from the iOS Messages composer.
  The artwork retains its validated invitation URL in `MSMessage.url`; the composer
  body is empty. Captions remain.
- Keep cipher material out of regular message packages, including messages to newly
  linked contacts. Runes remain the regular message body; cipher sharing remains an
  explicit Cipher Manager action.
- Fit rendered rune lines to the tablet's font and inscription area so longer
  messages paginate before text reaches the border.
- Local focused tests and an unsigned iOS build verify the source repair. The simulator
  cannot initialize a Messages composer; no device transcript or shipment is claimed.

## [1.0.43] - 2026-09-25

- Add an iOS Messages extension route for cipher invitations. The composed
  `MSMessage` uses the themed cipher artwork as its template image, carries the
  validated HTTPS invitation in `MSMessage.url`. In 1.0.43, the composer also repeated
  the URL as visible fallback text; 1.0.44 removes that body text.
- Keep the extension as a handoff surface only. **Continue to Rune Scribe** attempts
  to open the exact validated invitation URL; the containing app remains the only
  import-confirmation and cipher-mutation authority. A key-free App Group envelope
  provides recovery if the open handoff does not complete.
- Add a durable containing-app fingerprint guard so repeated taps, confirmations,
  cold starts, warm starts, URL delivery, and App Group recovery cannot commit the
  same imported cipher more than once.
- Add the `RuneScribeMessagesExtension` target (`com.runescribe.app.messages`) and
  shared App Group (`group.com.runescribe.app`) configuration. Automatic-signing
  builds compile and sign locally.
- Physical-device Messages transcript behavior, artwork-tap handoff, deleted-app
  product/App Store fallback, and green-bubble/SMS behavior were not run. This
  historical source was not device-qualified or shipped.

## [1.0.42] - 2026-09-19

- Add the Rune Scribe Universal Link, website association package, and recipient
  App Store fallback for shared cipher invitations.
- Add the built-in tutorial, seal guidance, simplified Scribe/Decode workspaces, and
  stable splash/lock presentation behavior.
- Isolate every normal-route UI test's persistent state while preserving state across
  relaunches within the test, preventing unsigned aggregate runs from sharing CloudKit,
  Keychain, or inbound-file fixtures.
- Add a reproducible App Store archive qualification command and export options. The
  earlier 1.0.41 archives passed Apple distribution, Store profile, entitlement,
  Hardened Runtime, and version checks, but predate the subsequently merged visual and
  sharing/tutorial changes. Fresh archives are required for the current 1.0.42 build 42
  source before upload. Upload, submission, release, and rollout remain owner-operated.

## [1.0.41] - 2026-09-13

- Make the normal compose and result workspace responsive at compact iPhone, iPad,
  and resizable Mac widths, with one scroll policy and protected theme-chrome insets.
- Replace the duplicate result-screen message shell with the canonical themed Artifact
  preview, preserving full rune payloads and truthful multi-page navigation.
- Keep received plaintext complete, selectable, and reflowable, and remove misleading
  truncation metadata and inactive disclosure affordances.
- Enforce App Lock as a real interaction and accessibility boundary so protected editor
  and Settings content cannot remain reachable behind the lock surface.
- Add normal-route iPhone, iPad, and macOS application coverage for long messages,
  paging, rotation/resizing, control dimensions, fresh-install lock behavior, and the
  five existing Codices without adding product features or replacing approved artwork.
- Advance the repository candidate to version 1.0.41 build 41. This source/UI checkpoint
  preceded the later signed Store archive qualification recorded under Unreleased.

## [1.0.40] - 2026-08-31

- Replace the contradictory v4.2 visual-comparison bindings with separate v4.3
  responsive, canonical visual, and runtime lanes covering 400 application states,
  50 canonical production renders, 576 runtime probes, and 1,104 mappings.
- Expand the five Codices with provider-neutral production composition, protected panel
  chrome, shared artifact rendering, responsive layouts, accessibility treatments, and
  source-bound qualification tooling.
- Add the App Store privacy manifest to both products with the required file-timestamp
  declarations for app-container and user-selected files, plus built-product mutation
  coverage that rejects missing or altered declarations.
- Replace destructive Keychain delete-then-add writes with update-first upserts so a
  failed cipher-library, App Lock, or throttle update preserves the prior protected
  value. Legacy macOS migration treats the current classic default keychain as a
  read-only source, verifies the Data Protection Keychain copy, and never deletes a
  file-based item. Explicit deletion writes a protected blocker before removing the
  current value, preventing retained legacy or backup data from being remigrated.
- Correct the Norse unlock-audio semantic role contract so all four integrity-pinned
  sound cues resolve through the runtime instead of silently falling back.
- Wire each optional Codex's dedicated frame thumbnail into the descriptor and UI
  presentation contract instead of substituting its full-size static frame.
- Replace the SwiftUI keyboard-toolbar dismissal control with a focus-aware safe-area
  control that remains tappable on iPhone and iPad and avoids the framework's invalid
  frame-dimension runtime fault.
- Keep the first-delivery key disclosure synchronized when the encoded cipher is linked
  or unlinked, and rename the received-message dismissal action from Save to Done so its
  label and accessibility hint match its behavior.
- Qualify the final source with 1,238/1,238 Swift tests, 255/255 Python tests, 60 Norse
  semantic rules, 25/25 Norse mutations, 18/18 legacy mutations, 28/28 shipping negative
  mutations, and 27/27 evidence-hardening tests.
- Pass the iOS Release build, the arm64-only unsigned macOS Release build, and 101/101
  local ad-hoc built-product content, resource, privacy, signing, Hardened Runtime, and
  entitlement checks. Distribution identity and provisioning remain unassessed external
  publication work.
- Add a path-independent, noninteractive Release-product qualification command that
  preserves build logs and qualified local app bundles without launching Simulator.
- Retain the prior iPhone 17 Pro headless UI result on iOS 26.5 with 7 passed, 1
  iPad-only skipped, and 0 failed, and the prior iPad Pro 13-inch (M5) result on iOS
  26.5 with 5 passed, 3 phone-specific skipped by design, and 0 failed. Current-candidate
  qualification does not relabel those retained runs as source-bound evidence.
- Retain the superseded v4.3 package audit as noncontrolling verification history;
  manual-evidence and package self-binding mechanics do not define product release
  readiness.
- Record passing named regression, architecture, source, asset, mutation, privacy, and
  built-product checks and establish version 1.0.40 build 40 as a repository-qualified
  release candidate. The stricter P11 Forsetti scanner remains report-only rather than a
  claimed pass. Distribution signing, archive, export, notarization, upload, and shipment
  remain external and have not occurred.

## [1.0.39] - 2026-08-23

- Complete the authorized source remediation while preserving the repository's strict
  no-ship boundary.
- Add a complete Share Builder flow with themed static previews, optional frozen
  geometry, explicit first-delivery key handling, and cancellable runtime resource reads.
- Correct Cipher Library sharing, unsupported-theme fallback, share lifecycle handling,
  minimum control hit regions, and deterministic 4:3 Appearance defaults previews.
- Replace Norse placeholder generation with provenance-locked production resources and
  byte-count, digest, availability, accessibility, and visual-integrity qualification.
- Expand the Swift package regression to 1,088 tests: 959 XCTest cases and 129 Swift
  Testing cases, plus hosted macOS/iOS and iPhone/iPad parity coverage.
- Add fail-closed release-product inspection, mutation-tested evidence generation,
  source-manifest verification, and deterministic owner-test candidate packaging.

## [1.0.38] - 2026-08-22

- Complete the source-controlled roadmap program while retaining version 1.0.38 build
  38 and a strict no-ship boundary.
- Add the Moonleaf, Sunspire, Wildwood, and Gloamthorn production Theme providers from
  the accepted v3.1 corpus: 56 logical resources and 184 hash-pinned shipping outputs.
- Add runtime-persisted Codex/Relic/Seal/Frame defaults, deterministic 4:3 Artifact
  rendering, themed vNext cipher/message files, legacy readers and fallbacks, safe
  receiving, Encounter facts, and provenance state.
- Add local-first private progression synchronization policy and runtime-owned
  CloudKit transport, plus optional Game Center mapping/reporting with the frozen
  15-achievement, 220-point catalog. Neither service can grant local ownership or
  carry message/key material.
- Harden typed-package allocation ordering, malformed-input coverage, imported-font
  rendering, explicit key-delivery transitions, destination compatibility, privacy,
  accessibility, resource budgets, placeholder checks, and architecture guards.
- Complete and validate the corrected Elven Series v3.1 production package with 56
  logical resources, 184 shipping outputs, complete provenance, and deterministic
  regeneration. Recovery is PASS / CLOSED, the corrected v3.1 package is ACCEPTED,
  and all nine recovery findings continue to pass simultaneously. The
  outcome is PHASE C: PASS / MERGED TO MAIN via PR #45 at merge commit
  `e9e0e0c8814aaa107d7480e070f14a6fe9b09975`.
  The roadmap-completion branch begins after that accepted Phase C history; it does not
  rewrite or replace the Phase C evidence.
- Align the version 1.0.38 build 38 README roadmap, architecture decisions, historical
  verification boundary, 124-task machine-readable status, App Store/support sources,
  and fail-closed documentation guards. Physical-device, live-service, signing,
  archive/export, notarization, upload, rollout, and shipment remain owner work.

## [1.0.37] - 2026-08-14

- Add durable, privacy-safe Achievements, Codex progression, rewards, and
  existing-user migration behind the runtime boundary.
- Add the Vault/Progress experience, accessible queued unlock reveals, and
  optional sound, haptic, and animation controls.
- Add live earned-entitlement activation for future optional Theme providers
  while preserving encode, decode, import, and share when Progression is
  unavailable.

## [1.0.36] - 2026-08-11

- Move platform I/O and system presentation behind runtime (#37) by @flynn33

## [1.0.35] - 2026-08-09

- Align Rune Scribe architecture with the product roadmap (#36) by @flynn33

## [1.0.34] - 2026-08-09

- Complete Rune Scribe modular architecture migration (#35) by @flynn33

## [1.0.33] - 2026-07-31

- Play the cold-launch intro at most once every 30 days.
- Share ciphers from the Cipher Library as `runescribe://import` deep links so recipients can tap to open the app and import (file export remains available separately).

## [1.0.32] - 2026-07-08

- docs: clarify macOS cipher import support (#31) by @flynn33

## [1.0.31] - 2026-07-07

- fix(ios): reliably import .runescribe files opened from Messages (#30) by @flynn33

## [1.0.29] - 2026-06-29

- docs(readme): describe file-based offline sharing; test count 111 -> 126 (#29) by @flynn33

## [1.0.28] - 2026-06-29

- fix(messaging): scope cipher file and product link to first message only (#28) by @flynn33

## [1.0.27] - 2026-06-28

- Offline cipher/message sharing: tap-to-import, iMessage button, macOS share, QR-only (#27) by @flynn33

## [1.0.26] - 2026-06-28

- Fix Share-to-Messages, add macOS/iOS Messages send, copy carries cipher key, add Clear (#26) by @flynn33

## [1.0.25] - 2026-06-28

- Selective contacts import; fix Share, first-message key, and remove-contacts (#25) by @flynn33

## [1.0.24] - 2026-06-28

- Fix Info.plist version and match build number to version (#24) by @flynn33

## [1.0.23] - 2026-06-27

- feat: file-based, server-free cipher and message sharing (#23) by @flynn33

## [1.0.21] - 2026-06-26

- Messages: inbound/outbound flow, Swift 6 fixes, updated splash (#22) by @flynn33

## [1.0.20] - 2026-06-26

- Phase 4: Apple Messages send + cipher key auto-exchange (#21) by @flynn33

## [1.0.19] - 2026-06-25

- Replace the cold-launch splash video with v2 (#20) by @flynn33

## [1.0.18] - 2026-06-24

- Phase 3: Contacts & per-contact ciphers (#19) by @flynn33

## [1.0.17] - 2026-06-24

- Phase 2: font travels with the cipher + https Universal-Link sharing (#18) by @flynn33

## [1.0.16] - 2026-06-23

- Phase 1: real message encryption (replace substitution cipher) (#17) by @flynn33

## [1.0.15] - 2026-06-21

- Refresh the README for v1.0.14 — cipher sharing & cold-launch splash (#16) by @flynn33

## [1.0.14] - 2026-06-21

- Video splash screen on cold launch (#15) by @flynn33

## [1.0.13] - 2026-06-20

- Share ciphers via iMessage, QR code, and deep-link auto-import (#14) by @flynn33

## [1.0.12] - 2026-06-20

- Rebrand to "Rune Scribe" and refresh the README + docs (#12) by @flynn33

## [1.0.11] - 2026-06-20

- Add cross-person decoder round-trip tests (#11) by @flynn33

## [1.0.10] - 2026-06-20

- Lock the text frame height during the transformation (#10) by @flynn33

## [1.0.9] - 2026-06-20

- Keep runes norse and the text frame fixed; remove info chips (#9) by @flynn33

## [1.0.8] - 2026-06-20

- Make rune transformation fast and sharp; remove the glow (#8) by @flynn33

## [1.0.7] - 2026-06-20

- Animate text-to-rune conversion in place (rune-by-rune inscription) (#7) by @flynn33

## [1.0.6] - 2026-06-20

- PIN app lock, multi-cipher library, settings, and rune glow (#6) by @flynn33

## [1.0.5] - 2026-06-19

- Enable App Sandbox for the macOS app (Mac App Store) (#5) by @flynn33

## [1.0.4] - 2026-06-19

- Rebrand identifiers to com.runescribe (#4) by @flynn33

## [1.0.3] - 2026-06-19

- Fix Xcode warnings: iPad orientations and MTKView main-actor isolation (#3) by @flynn33

## [1.0.2] - 2026-06-19

- Add app icon and developer-team signing for iOS (#2) by @flynn33

## [1.0.1] - 2026-06-19

- Single-file decoder export, plus decoder import and a Decode tab (#1) by @flynn33


## [1.0.0] - 2026-06-19

- Initial release: universal macOS + iOS runic substitution cipher.
