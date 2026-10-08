# Rune Scribe 1.0.47 (47) message-payload qualification

Date: 2026-10-08. Xcode 27.0 (27A266a). Baseline: `79a0059`.
[Test counts](TestResults.json) retain the current and baseline results.
[Source hashes](SourceFiles.json) identify the tested production adapters, module
versions, project settings, and test sources. Version 1.0.47 is not shipped.

## Change and observed cause

The reported recipient screenshot contains an unwanted `message.runescribe` document
card after the artwork and rune text. Its sending build, platform, and action remain
unknown. Source inspection identified two remaining file-sharing surfaces:

- iOS registered a package activity source alongside the artwork/text sources and
  relied on returning nil for the Messages activity. The package still supplied a
  file placeholder and link metadata. That metadata causing the screenshot is
  **not established**; [Apple documents per-activity nil omission as supported](https://developer.apple.com/documentation/uikit/uiactivityitemsource/activityviewcontroller(_:itemforactivitytype:)).
- macOS ignored the launcher's supplied artwork/text and always proposed the package
  URL to its native sharing picker, including Messages.

The iOS package sheet now excludes native Messages and offers an app-owned Messages
activity. Its separate MessageUI composer takes only validated PNG data and the exact
rune body. The direct iOS composer uses that same configuration. The macOS Messages
picker service forwards exactly an image followed by the rune string to the real
Messages service. It forwards no package URL. Invalid artwork cannot fall back to a
message package. Mail, AirDrop, explicit files, cipher invitations, encrypted message
construction, and wire formats retain their existing routes/contracts.

Composer results are preserved through UIKit dismissal and a once-only gate. AppKit
reports its actual system-completion result; user cancellation maps to cancelled.
The Mac parity host and old Share Builder test calls were updated for APIs already
changed before this patch (required invitation preview and key-free message purpose).
No test assertion was removed to obtain a passing run.

## Xcode verification

- iPhone Simulator, iOS 26.5: all **12 NativeShareOutcomeTests passed**, 0 skipped,
  0 failed. Tests exercise the production composer configuration, custom activity
  and file-sheet construction, native Messages exclusion, invalid artwork, stored
  outcome priority, duplicate completion, and unchanged cipher-invitation items.
- macOS: the four new payload/cancellation tests and the existing production share
  control/transfer cleanup test passed in the broader six-test run. The focused rerun
  passed **5/5**, 0 skipped, 0 failed (`mac-focused` result/log). Final-source reruns
  again passed 12/12 iOS and 5/5 macOS (`ios-verified`, `mac-verified`); both unsigned
  Release builds also passed again (`*-release-verified`).
- Unsigned Release builds of `RuneScrib-iOS` (generic iOS device, including Messages
  extension) and `RuneScrib-macOS` (arm64) **succeeded**. Built app and extension
  Info.plists read `1.0.47` / `47` with their expected identifiers.
- Release commands set `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=`. Simulator/host tests used ad hoc signing
  (`CODE_SIGN_IDENTITY=-`), with no developer certificate or distribution signing.
  Project signing settings were not changed.
- Architecture guardrails passed. Documentation and roadmap checks passed
  after this report's creation; their earlier only failures were missing report links.

The Xcode commands use `RuneScrib.xcodeproj`, schemes `RuneScrib-iOS-Parity`,
`RuneScrib-macOS-Parity`, `RuneScrib-iOS`, and `RuneScrib-macOS`. Test selectors and
complete command lines are retained at the start of their logs. Derived data/results:
`/private/tmp/runescribe-message-payload-20261008`. Durable raw logs:
`/Users/jimdaley/Documents/Rune-Scribe-1.0.47-verification`.

## Failed broader checks and limits

The broader macOS run recorded **5 tests passed, 1 test failed** (two failures inside
`testShareBuilderPurposesUseFixedSecurityContractsAndRuntimeFourByThreePreviews`).
A detached `79a0059` checkout, with only the same API-compatible test/host repairs,
reproduced both failures without changing baseline production code:

- Repeated preview PNG digests differ. Both decode to 1200×900; the inspected images
  differ at 1,229 pixels by at most one RGB channel value. The underlying raster
  variance remains unknown; the exact digest assertion remains in the test.
- The test fetches an HTTPS cipher invitation as though it were a package and feeds
  the response to FileRouter, producing `unsupportedVersion(60)`. Production prepares
  invitation links; its supported decoder is `LinkRouter.decodeCipher`. This stale
  file-only test assumption remains recorded rather than hidden by a passing subset.

The Norse visual checker reports the same four historical evidence findings on
current and baseline sources: semantic coverage in Baseline.json, ResourceCoverage.json,
ActiveVisualPlanValidation.json, and the NegativeMutations.json count. Those historical
artifacts were not altered or relabeled as current evidence.

The first iOS compile attempts exposed missing actor bridging in the new UIActivity;
these were repaired before the passing run. Early Mac attempts found the obsolete
host/test API calls described above. Raw failed logs are retained.

No actual Messages composer/send, recipient transcript, physical-device screenshot,
full package aggregate, complete parity suite, Store archive/export, upload, or release
was exercised or claimed. Native ordering and recipient display still require the
owner's test of build 47. A simulated transcript is not evidence of delivery.
