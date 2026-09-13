# Rune Scribe UI/Xcode remediation qualification

**Candidate:** version 1.0.41 build 41

**Status:** `READY_FOR_OWNER_SHIPMENT` — source/UI/build handoff only; not shipped

**Source commit C:** `735b0e70f0dda5d22fe5e57ce48d7998ba308629`

**Input digest D:** `f2a028d520420996a3037099542eecea445afdc422782377aff29a6b0b5b049a`

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
- The iPad hosted tests passed 29 of 29. Three applicable normal-route UI tests
  passed and one phone-only case skipped. The full flow completed every product
  assertion; its final immediate rotate-back frame read observed the still-landscape
  window (820 by 1180 instead of 1180 by 820), a Simulator timing diagnostic rather
  than a product failure. Standalone inbound persistence passed afterward.
- Dedicated theme matrices passed on iPhone and iPad, each capturing 211 attachments
  across all five Codices. The macOS fidelity matrix passed its canonical theme
  capture (422 attachments). Sanitized representative images and their approved
  reference mapping are in `visual-reference-index.json`.

## Diagnostic boundaries

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

Distribution signing, provisioning, archive, export, notarization, App Store upload,
rollout, and shipment were not performed. Those actions remain with the owner.

Raw commands, logs, result bundles, extracted attachments and candidate manifests are
preserved under `/Users/jimdaley/Projects/RuneScribe/ui-xcode-run.CwlJbz`. The compact
machine-readable record is `EvidenceIndex.json`.
