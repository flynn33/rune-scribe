# Rune Scribe 1.0.46 (46) beta-fix qualification

Recorded October 4, 2026. This is a source candidate, not a Store upload or shipment.
The runs below measured the beta-fix source while its version still read 1.0.45 (45),
before the 1.0.46 (46) version/documentation update. No post-bump test run is claimed.

## Changes and focused proof

- Ordinary iOS Messages uses rendered PNG artwork and rune text without the trailing
  `.runescribe` message package. `MessageComposeView` attaches only validated PNG data;
  `RuneScribeIOSMessageActivityItemFactory` omits the package for Messages while
  preserving it for other destinations. Missing, invalid, and JPEG artwork cannot
  enable the Messages route. Separate cipher invitations and exports remain unchanged.
- The first-use Manage Ciphers contacts dialog includes **Skip**. Isolated UI tests
  verify dismissal, cipher creation, and persistence across reopen/relaunch. Production
  first-use UI tests passed on clean iPhone and iPad simulator installations.

## Recorded Xcode results

| Run | Passed | Skipped | Failed | Scope |
|---|---:|---:|---:|---|
| Final iPhone | 31 | 1 | 0 | Selected hosted tests and beta-fix UI tests |
| iPad | 23 | 1 | 0 | Selected hosted tests and beta-fix UI tests |
| Native-share repeat | 10 | 0 | 0 | `NativeShareOutcomeTests` |

The Messages composer UI test was skipped on each simulator because no Messages share
destination was available. Payload assertions passed; they do not prove an actual sent
recipient transcript. The production contacts test requires a clean installation; its
repeat skipped after the first-use prompt had already been consumed.

`AppHostRoutingTests.testCompositionActivatesProgressionBeforeUIWithInMemoryState`
failed on both the repaired source and unchanged baseline `b8193fc`, reporting failed
rather than active Progression state. The final selected runs excluded that known
baseline failure. These results are not an aggregate suite pass or a fix for that test.
The full package suite was not run for this repair.

Simulator runs used `CODE_SIGN_IDENTITY=-` and manual ad-hoc signing. Read-back of the
app and embedded Messages extension reported `Signature=adhoc` and
`TeamIdentifier=not set`; no developer certificate was used.

## Post-bump compile and version evidence

Fresh Xcode 27 Release builds succeeded for `RuneScrib-iOS` at generic iOS Simulator
and `RuneScrib-macOS` at arm64 macOS (`ARCHS=arm64`, `ONLY_ACTIVE_ARCH=YES`). Both
used `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, empty signing identity,
and empty development team. The iOS app, embedded Messages extension, and macOS app
Info.plists read back version 1.0.46, build 46, with the expected bundle identifiers.
The logs contain no Swift compiler warnings or errors. The only reported diagnostic
was skipped App Intents metadata extraction for products without an AppIntents
dependency.

These are unsigned compile/version checks, separate from the earlier focused tests.
Documentation alignment, roadmap alignment (124 tasks and 15 decisions), roadmap
completion, and architecture guardrails also passed after the update.

They do not establish archive/export qualification, developer signing, a Store upload,
or actual sent-recipient Messages behavior. The local-only publication evidence
directory `Rune-Scribe-1.0.46-publication` retains `ios-build.log` and `macos-build.log`.

## Retained local evidence and limits

Logs, result bundles, screenshots, and the screenshot hash manifest remain outside the
repository in the local `Rune-Scribe-beta-fixes` evidence directory. These local-only
artifacts are not published as repository links.

The principal logs are `iphone-final-xcode-tests.log`, `ipad-xcode-tests.log`,
`test-repeatability.log`, and `baseline-activation.log`. The `Screenshots` directory
contains iPhone/iPad production contacts prompts with Skip and the library after Skip,
plus artwork/rune result and share-destination screenshots. `Screenshots/manifest.json`
binds those screenshots to their tests, result bundles, timestamps, and SHA-256 hashes.
It contains no successful native Messages composer screenshot.

Actual sent-recipient Messages output, physical-device invitation handoff, deleted-app
fallback, SMS behavior, full regression, and fresh current-source Store archive/export
qualification remain unverified by this focused work. Earlier qualified archives and
test histories are not relabeled as evidence for 1.0.46.
