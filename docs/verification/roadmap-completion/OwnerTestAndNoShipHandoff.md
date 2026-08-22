# Owner Test and No-Ship Handoff

## Review state

- Feature branch: `feature/roadmap-completion-post-phase-c`
- Baseline: `131f101069d1a8053f72e60918092e81373e2687`
- Final source commit: `b7c55ff40255f96a6c857b49a14962e9fcd79c37`
- Evidence publication: the review commit containing this handoff
- Marketing version: 1.0.38
- Build number: 38
- Program result: code complete for the supported source-controlled boundary
- Shipment state: not shipped

## Automated and supported-environment evidence

The common-schema records in this directory identify the complete package suite,
architecture/roadmap/documentation guards, deterministic XcodeGen regeneration,
Release builds, hosted macOS tests, iPhone Simulator tests, iPad Simulator tests,
parity/UI suites, resource/hash inspection, shipping-product inspection, malformed-input
mutations, privacy boundaries, security review, and attribution audit. Final hosted and
Simulator qualification passed at the final source revision: macOS hosted 20/20 and
parity 4/4, iPhone hosted 21/21 and parity/accessibility 1/1, and iPad
Release and parity/accessibility 1/1. Shipping-product inspection passed 101 checks with zero
failures.

Primary evidence:

- `FullRegression.json`
- `FinalSelfAudit.md`
- `SecurityPrivacyReview.md`
- `CompatibilityMatrix.json`
- `NegativeMutations.json`
- `GateRun/`

These results do not qualify physical hardware, live service accounts, provisioning,
App Store Connect, distribution signing, archive/export, upload, review, or release.

## Accepted provider/resource totals

| Provider | Outputs | Bytes | Integrity-manifest SHA-256 |
|---|---:|---:|---|
| Moonleaf | 46 | 678,743 | `e7222671993ad13ff4f3c72dd048f31f49295a1412e1f365d9fd904ef0b4c633` |
| Sunspire | 46 | 666,458 | `da391cc35e89ad0606099e50e98bb2e28591420f68ec745efc2878411e9b1edc` |
| Wildwood | 46 | 697,897 | `f41665d69e3034bd8df8cf60954a5e7fa338a144384116fac2a4ca8b71b6c8f8` |
| Gloamthorn | 46 | 609,418 | `1808d845cbcf30ae21ae87cd1ec8e3db549ab493a652de420de7d8868466c6d9` |
| **Total** | **184** | **2,652,516** | Four independently pinned manifests |

Accepted v3.1 package-manifest SHA-256:
`d55f4b7c0f74eaf2b396ceb664f25ba086f50b7033052cd0f0a18d407c8a31da`.

## Expected owner-test product flows

- Create/import ciphers, preserve existing libraries, and verify active-cipher selection.
- Encode/decode with bundled and imported compatible fonts; verify missing, corrupt, and
  incompatible font fallback without any mapping or key change.
- Browse all Codices in the Vault; verify locked, encountered, owned, selected,
  unavailable, corrupt, and revoked presentation states.
- Complete each approved Elven gate journey and verify immediate provider activation
  without restart.
- Customize Share and Quick Share with owned Codex, Relic, Seal, and Frame selections;
  verify locked content cannot be selected as owned.
- Receive legacy cipher v3, legacy message v1, current typed packages, themed packages,
  unknown optional content, and update-required fixtures.
- Verify unknown, locked, unavailable, incompatible, and corrupt presentation falls back
  to Norse while preserving a valid sender-rendered safe preview.
- Verify first delivery includes key material only where allowed; established delivery
  does not resend it; cancel/failure grants nothing.
- Verify an embedded first-delivery cipher remains untrusted until explicit confirmation
  and does not create/rebind contacts or enable Reply early.
- Verify privacy-safe Encounters appear without granting ownership.

## Physical-device checklist

Perform on an owner-controlled iPhone and iPad, plus any Mac hardware the owner chooses:

- [ ] Install a locally signed review build without replacing recoverable production data.
- [ ] Launch, background, foreground, terminate, relaunch, and migrate existing data.
- [ ] Exercise Messages first/established delivery, cancellation, retry, and attachment acceptance.
- [ ] Exercise Share sheet targets, Files import/export, drag/drop where applicable, and clipboard fallback.
- [ ] Scan QR fixtures with the physical camera across distance, crop, lighting, noise, and high-contrast conditions.
- [ ] Import Contacts, deny/revoke Contacts permission, confirm snapshot behavior, and verify no silent rebinding.
- [ ] Enable, unlock, change, disable, fail, throttle, relaunch, and recover App Lock.
- [ ] Test VoiceOver, larger text sizes, Increase Contrast, Differentiate Without Color, Reduce Motion, keyboard, pointer, and no-sound alternatives.
- [ ] Exercise long inscriptions, pagination, static fallback, thumbnails, memory pressure, repeated renderer/cache use, and low-storage/error paths.
- [ ] Verify legacy libraries, ciphers, fonts, contacts, delivery state, selected Codex/defaults, and progression migration.
- [ ] Confirm local encode/decode, unlocks, Vault, and sharing remain usable with iCloud and Game Center disabled or offline.

## iCloud and CloudKit owner checks

Declared private container: `iCloud.com.runescribe.app`.

- [ ] Confirm the App ID, entitlements, container assignment, provisioning profiles, and
  environments are correct in the owner accounts.
- [ ] Test signed-in, signed-out, restricted, unavailable, account-change, offline,
  divergent-device, retry, partial-failure, corrupt-remote, quarantine, and reset-generation flows.
- [ ] Inspect private records and diagnostics to confirm they contain progression-only
  fields and never plaintext, keys, contacts, raw relationship identity, QR content,
  messages, or package bytes.
- [ ] Verify valid local state survives rejected or corrupt remote input.

## Game Center and App Store Connect owner checks

The source-controlled catalog has 15 evergreen achievements totaling 220 points;
leaderboards are disabled.

- [ ] Create/verify the exact achievement records, localized names/descriptions, points,
  and approved images in App Store Connect.
- [ ] Test sandbox authentication, decline, cancellation, parental restriction, offline,
  account change, duplicate callbacks, prior completion, retry/backoff, opt-out, and later opt-in.
- [ ] Confirm local Progression grants immediately and Game Center never grants or revokes ownership.
- [ ] Confirm monotonic percentages and interrupted-report recovery after relaunch/reactivation.

## Distribution actions not performed

This program did not:

- merge to `main`;
- create or push a release tag;
- create a release;
- bump the marketing version or build number;
- use distribution signing credentials;
- archive or export either app;
- notarize;
- upload to TestFlight or either App Store;
- mutate Developer Portal identifiers, capabilities, containers, certificates, or profiles;
- create or update App Store Connect or Game Center records;
- stage a public rollout or announce shipment.

## Rollback criteria

Stop testing and return to the accepted baseline or last owner-approved review build if
any of these occurs:

- existing cipher/library/contact/font/message data becomes unreadable or mutates unexpectedly;
- Theme selection changes cipher identity, key material, or symbol mapping;
- locked/unavailable presentation blocks decryption or bypasses Norse fallback;
- a corrupt optional provider blocks Core, UI, Norse, or another provider;
- first-delivery key material repeats on established delivery or sender identity becomes trusted without confirmation;
- cancelled/failed sharing emits progression or ownership;
- cloud records expose prohibited fields, lose valid local state, or merge nondeterministically;
- Game Center grants/revokes local ownership or regresses local utility;
- App Lock throttling can be bypassed by relaunch/operation switching or cannot recover safely;
- accessibility, memory, performance, migration, provisioning, signing, or store review
  reveals a blocking defect;
- any resource hash, entitlement, catalog identity, version/build, or no-ship boundary differs from this handoff.

Record the exact build, device, OS, account state, reproduction steps, logs, screenshots,
and affected data class. Do not ship a workaround that weakens a gate.

## Final status

```text
CODE COMPLETE
AUTOMATED TESTS PASS
SUPPORTED HOST/SIMULATOR TESTS PASS
OWNER TEST REQUIRED
NOT SHIPPED
```

**NOT SHIPPED — OWNER TEST REQUIRED**

**Do not ship until the owner approves the test results.**
