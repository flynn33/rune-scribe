# Rune Scribe UI/Xcode remediation qualification

**Candidate:** version 1.0.41 build 41

**Status:** `READY_FOR_APP_STORE_UPLOAD` — signed export handoff; not uploaded or shipped

**Source commit C:** `735b0e70f0dda5d22fe5e57ce48d7998ba308629`

**Input digest D:** `f2a028d520420996a3037099542eecea445afdc422782377aff29a6b0b5b049a`

**Store qualification source S:** `119fca69b90ac75774468a104abfc00d0186966d`

This is the source-bound qualification entry point for the September 2026 UI and
Xcode remediation. The candidate uses one responsive production layout on macOS,
iPhone and iPad; a single themed result surface; truthful full-payload paging;
reflowable received plaintext; and an App Lock boundary that removes protected
content and actions while preserving the user's draft for restoration after unlock.

The checked-in `RuneScrib.xcodeproj` exposes the `RuneScrib-macOS` and
`RuneScrib-iOS` application schemes. It was qualified with Xcode 26.6 (17F113),
Swift 6.3.3, macOS 15.0 as the minimum Mac target, and iOS 17.0 as the minimum iOS
target. Simulator runs used iPhone 17 Pro
`C22CF07C-A445-4A19-A1B8-63FA719EA815` and iPad (A16)
`10877E30-CCED-43A6-9E39-9AEE1D740DDD`.

## What was verified

- The Python regression suite passed 255 of 255 tests.
- The isolated Swift package run passed 1,105 XCTest tests and 137 Swift Testing
  tests: 1,242 total, with zero failures and zero skips.
- Current architecture, documentation, roadmap, source/reference, theme authority,
  provenance and attribution guards passed. Negative mutation suites passed 25
  Norse, 18 remediation and 28 shipping mutations.
- The clean committed release-product qualification passed all 101 inspections.
  It built fresh macOS arm64 and iOS Simulator arm64/x86_64 Release products and
  inspected versions, architectures, embedded resources, privacy manifests,
  entitlements, linkage, and the absence of test/reference payloads.
- Fresh iOS and macOS archives exported successfully for App Store Connect. The iOS
  `.ipa` and macOS `.pkg` use Apple distribution signing, matching Store provisioning
  profiles, production CloudKit entitlements, Game Center, version 1.0.41 build 41, and
  `get-task-allow=false`. The Mac app is sandboxed, uses Hardened Runtime, is universal
  arm64/x86_64, and its installer package signature verifies.
- An unsigned iPhoneOS device-SDK Release compile passed with the shipping
  entitlements preserved.
- The macOS hosted blocking suite passed 26 tests. A native run of the real app
  exercised encoding a 300-character message, page 1 of 4 to page 2 of 4,
  persistence while resizing, all five Settings Codices, version 1.0.41 (41),
  keyboard navigation, and return to the same page.
- The iPhone fresh-install normal route passed its full primary-flow UI test in
  589.680 seconds. It covered onboarding, creation, paging, lock privacy and draft
  restoration, sharing, three inbound cipher imports, and accessibility. The
  configured-entitlements follow-up passed five applicable tests and skipped one
  iPad-only case.
- The formerly affected unsigned/unentitled iPhone isolation lane passed six applicable
  tests with one intentional iPad-only skip and no failures. Each test now receives a
  distinct persistent root without losing relaunch continuity inside that test.
- The iPad hosted tests passed 29 of 29. Three applicable normal-route UI tests
  passed and one phone-only case skipped. After making the rotation assertion wait for
  settled window geometry, the complete fresh-install primary flow passed in 565.772
  seconds with zero failures and zero skips. Standalone inbound persistence also passed.
- Dedicated theme matrices passed on iPhone and iPad, each capturing 211 attachments
  across all five Codices. The macOS fidelity matrix passed its canonical theme
  capture (422 attachments). Sanitized representative images and their approved
  reference mapping are in `visual-reference-index.json`.

## Diagnostic boundaries

An earlier aggregate iPhone command deliberately stripped the shipping entitlements to
exercise the isolated application route. Six UI tests that did not set the isolation
marker reached the real CloudKit adapter and terminated in `CKContainer` initialization;
two additional aggregate assertions also failed. That command is retained as a
superseded test-configuration failure, not represented as a product pass. The central
isolated-app launcher now gives every UI test a unique persistent root, while preserving
state across relaunches inside that test, and the affected unsigned tests pass without
CloudKit or Keychain access. The configured-entitlements follow-up remains independently
green.

The full macOS parity aggregate retained three diagnostic-only failures: host
automation could not establish focus for offscreen keyboard targets, a 900-point
large-text snapshot did not contain every scroll-reachable action at once, and a
Share Builder smoke expected a preview before navigating away from its initial
controls route. Equivalent source-bound checks exercised keyboard navigation,
resizing, scrolling/action reachability, and Share Builder rendering. Tests and
thresholds were not weakened.

The stricter Forsetti P11 scanner remains report-only under the controlling policy.
It reported the known FG-006 legacy authority mapping and was not represented as a
compliance pass or used to revive superseded acceptance machinery.

## Artwork and data safety

Approved artwork was not replaced or edited. Production resource/reference guards,
the five-Codex matrices, and manual inspection confirmed the intended assets and
legible presentation. All UI evidence uses synthetic text, fixture ciphers, and fake
contacts. No user data, credentials, or distribution secrets are included.

## Shipment boundary

Distribution signing, provisioning-profile resolution, archive, export, and local
package inspection were performed without uploading. App Store Connect validation,
upload, submission, release tagging, rollout, and shipment were not performed and remain
with the owner.

Raw commands, logs, result bundles, extracted attachments and candidate manifests are
preserved under `/Users/jimdaley/Projects/RuneScribe/ui-xcode-run.CwlJbz`. The compact
machine-readable record is `EvidenceIndex.json`. Signed archive/export evidence is
preserved under
`/Users/jimdaley/Projects/RuneScribe/AppStoreQualification-1.0.41-20260913`.
The repaired iPhone isolation and iPad primary-flow results are under
`/Users/jimdaley/Projects/RuneScribe/UIIsolationQualification-1.0.41-20260913`.
