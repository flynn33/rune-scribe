# Rune Scribe Feature Parity Report

> **Historical qualification snapshot.** Hardware-only classifications in the body
> are owner-operated optional observations outside Agent Coding scope under the current
> policy. They do not affect acceptance, completion, blocker status, residual work,
> PASS/FAIL, or pull-request readiness. Current status is governed by the
> [Forsetti supersession index](../architecture/ForsettiSupersessionIndex.md).

## Result

**Status:** `CODE COMPLETE — EXTERNAL VALIDATION REMAINS`

| Classification | Count |
|---|---:|
| Passed automated | 12 |
| Passed automated and manual | 21 |
| Passed total | 33 |
| Device validation required | 7 |
| In progress | 0 |
| Failed/open | 0 |
| Total | 40 |

The behavior baseline is the P0 snapshot at `a3d5a868e24f2d71a24b6d2a8e87a7c299782ec2`, including the newer local product delta over the audited `793f275b86ef16aa3d2606318cccd9714b7af95e` release baseline. The final cleanup HEAD is `01e2fcf655a3139a856787fc96f17a58db3f3ad0`. Every parity row is terminal. The seven device-required rows have complete unit, integration, hosted, Simulator, or local presentation evidence for their automatable portions; only the specifically listed physical behavior remains unproven.

The machine-readable source of truth is `docs/verification/feature-parity-matrix.json`. Source and test movement are reconciled in `docs/verification/ForsettiMigrationReconciliation.json` and `docs/verification/ForsettiTestReconciliation.json`.

## Evidence key

| Key | Final-current evidence |
|---|---|
| PKG | `/tmp/RuneScribe-P8-final-package.yGz7qs` — 283/283 SwiftPM tests, 17/17 architecture checks, and deterministic XcodeGen output |
| GUARD | `/tmp/RuneScribe-P8-cleanup.bxBuUN` and `/tmp/RuneScribe-P8-guard-audit.4gkAfP` — migration-shim cleanup and negative shipping/TestSupport guard evidence |
| MAC | `/tmp/RuneScribe-P8-final-mac.MN3k9e` — macOS 8/8, parity 3/3, file/link native share presentation |
| IOS-H | `/tmp/RuneScribe-P8-final-ios.87OHyd` — generic build and hosted iOS 18/18 |
| IPH | `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPhone.xcresult` — iPhone full parity 1/1 |
| IPD | `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPad.xcresult` — iPad AXXXL full parity 1/1 |
| REL | `/tmp/RuneScribe-P8-release-final.XsJS4P` — two clean Release products and 50/50 shipping checks |

## Complete 40-item matrix

| ID | Platform | Feature | Final status | Compact evidence |
|---|---|---|---|---|
| FP-001 | Both | Cold launch and first-run setup | Passed automated + manual | PKG first-run persistence/runtime-root tests; MAC product window; IPH fresh launch reached `My Cipher` with product-only controls. |
| FP-002 | Both | Existing-user launch | Passed automated + manual | PKG consolidated legacy-install test; IOS-H real Simulator `SecItem` migration; stored PIN-root and macOS state inspection. |
| FP-003 | Both | Cipher create/rename/delete/select | Passed automated + manual | PKG lifecycle/fallback tests; IPH created, renamed, selected, linked, unlinked, and deleted a second cipher. |
| FP-004 | Both | AES-GCM encryption/decryption | Passed automated | PKG round trip, wrong-cipher, and tamper rejection tests. |
| FP-005 | Both | Rune codec/reveal | Passed automated + manual | PKG 32-symbol, arbitrary-byte, and foreign-character tests; inspected production rune rendering. |
| FP-006 | Both | Cipher library persistence | Passed automated | PKG frozen library/no-rewrite and stable-account tests; IOS-H isolated Apple Keychain migration. |
| FP-007 | Both | Contact encrypted persistence | Passed automated | PKG frozen version-1 AES-GCM `contacts.enc`, association, cache invalidation, and no-startup-write tests. |
| FP-008 | Both | Manual contacts and cipher linking | Passed automated + manual | PKG identity/link/unlink/delete tests; IPH manual contact CRUD and cipher association flow. |
| FP-009 | Both | System contact import | Device validation required | PKG minimal-value mapping, authorization publication, and 11/11 contact replacements; real permission/picker steps remain. |
| FP-010 | Both | Cipher URL export/import | Passed automated | PKG golden custom/legacy link tests; MAC input rail and IOS-H AppHostRouting 5/5. |
| FP-011 | Both | Cipher `.runescribe` v3 | Passed automated + manual | PKG exact golden decode/re-encode; IPH production host opened and imported a registered v3 file. |
| FP-012 | Both | Message `.runescribe` v1 | Passed automated + manual | PKG exact golden decode/re-encode; IPH opened v1, displayed sender/plaintext, and entered Reply. |
| FP-013 | Both | First-delivery key inclusion | Passed automated | PKG first-delivery artifact bytes, acknowledgement, completion, and cleanup tests. |
| FP-014 | Both | Subsequent delivery | Passed automated | PKG follow-up no-resend and delivery-state tests. |
| FP-015 | Both | Inbound file routing | Device validation required | PKG strict complete-file decoder; IOS-H host routing; IPH distinct cipher-confirmation and received-message flows; external Files/Messages/AirDrop ingress remains. |
| FP-016 | Both | Inbound deep-link routing | Passed automated + manual | PKG FIFO/dedupe tests; IOS-H cold/warm host routing; IPH custom, malformed, and legacy URL flows. |
| FP-017 | Both | Import confirmation/duplicate/errors | Passed automated + manual | PKG cancel/dedupe/FIFO/error tests; IPH confirmation, cancellation, visible failure, and successful commit. |
| FP-018 | Both | Received-message and reply | Passed automated + manual | PKG embedded/stored cipher association and dedupe; IPH sender, decoded message, and Reply transition. |
| FP-019 | Both | Clipboard import | Passed automated + manual | PKG async-only adapter and activation-gating tests; IOS-H clipboard round trip without paste prompt; inspected confirmation state. |
| FP-020 | Both | QR generation | Device validation required | PKG exact link/QR data and lifetime tests; inspected generated QR; separate physical-reader decode remains. |
| FP-021 | iOS | QR scanning | Device validation required | IOS-H permission-state mapping and scan/cancel routing tests; physical camera authorization/optical scan remains. |
| FP-022 | iOS | iMessage composer | Device validation required | PKG attachment policy; IOS-H PlatformPresentation 9/9 for setup/outcomes/exact-once completion; real Messages delivery remains. |
| FP-023 | Both | System Share sheet | Device validation required | PKG artifact lifetime; IOS-H NativeShareOutcome 3/3; IPH/IPD activity presentation/cancel; MAC file/link native picker presentation; destination receipt remains. |
| FP-024 | Both | Custom font import | Passed automated | PKG digest/path/round-trip/registration tests; IPH/IPD valid import and visible hash-mismatch failure with retained retry state. |
| FP-025 | Both | Bundled runic font | Passed automated + manual | PKG fixed identity/hash/registration; REL font presence/validity on both products; inspected rune rendering. |
| FP-026 | Both | Metal background | Passed automated + manual | MAC real Metal library/symbol test; REL `default.metallib` presence; production iOS header visually inspected. |
| FP-027 | Both | Splash video | Passed automated + manual | PKG resource/schedule/skip/completion tests; MAC resource test; IPH/IPD launch and skip-intro flow. |
| FP-028 | Both | App PIN operations | Passed automated + manual | PKG PBKDF2 and service-state tests; IPH set `1234`, unlocked, changed to `5678`, then disabled PIN. |
| FP-029 | Both | PIN throttling/lockout | Passed automated | PKG frozen legacy PIN/throttle restore and exact cooldown tests. |
| FP-030 | Both | Background/resume lock | Device validation required | PKG resign/background ordering and plaintext cleanup; IOS-H lifecycle routing; IPH Simulator background relock; physical device lock remains. |
| FP-031 | Both | Settings/license | Passed automated + manual | PKG representative render/command tests; IPH Settings, PIN/contact/license controls, LICENSE, and return. |
| FP-032 | macOS | Commands/window behavior | Passed automated + manual | PKG typed command catalog/FIFO tests; MAC 3/3 production RootView/Settings/commands and visible product-window smoke. |
| FP-033 | iOS | Orientations/device families | Passed automated + manual | REL plist/device-family checks; IPH and IPD portrait/landscape flows; IPD at accessibility-extra-extra-extra-large. |
| FP-034 | Both | Sandbox/entitlements | Passed automated | REL exact per-architecture entitlement dictionaries, signatures, nested seals, and macOS hardened runtime, 50/50. |
| FP-035 | Both | URL scheme/UTI/document registration | Passed automated | PKG stable identifier tests; REL exact `runescribe`, `com.runescribe.runescribe`, and document registration. |
| FP-036 | Both | Privacy/no-network behavior | Passed automated | PKG static architecture/privacy scan; REL canonical system-only linkage and exact capability graph. |
| FP-037 | Both | Production UI invisibility | Passed automated + manual | PKG exactly-one-root tests; IPH/IPD/MAC expose product-only UI; REL contains no framework binary or test-only debug dylib. |
| FP-038 | Both | Accessibility/keyboard | Passed automated | IPH six strict accessibility audits; IPD AXXXL and rotation; PKG macOS command descriptors and UI labels. |
| FP-039 | Both | Resource identity | Passed automated + manual | PKG root-bundle identity tests; REL assets/icon/font/video/Metal/manifests on both products; launch/content inspection. |
| FP-040 | Both | No data/wire migration required | Passed automated + manual | PKG consolidated existing-install/no-rewrite plus golden wire fixtures; IOS-H real isolated Keychain read; product state smoke. |

## Automated command and evidence summary

The final automatable rails were:

- `swift test --package-path Packages/RuneScribeArchitecture` — 283/283 passed.
- `scripts/check-architecture.sh` — 17/17 passed.
- XcodeGen 2.46.0 twice — byte-identical `project.pbxproj` and four shared schemes; PBX SHA-256 `5fcafb2ffd877311dd1ea973f58526036e7af543e6e6ff45d36b1a80beb56a30`.
- Cleanup/guard negatives — direct TestSupport shipping source, generated PBXSources, package-product, and dependency injections all rejected.
- `RuneScrib-macOS` hosted XCTest — 8/8 passed.
- `RuneScrib-macOS-Parity` — 3/3 passed.
- Same-process macOS native share self-test — file and link pickers each presented exactly once and dismissed.
- Generic iOS Simulator build-for-testing — succeeded.
- Hosted iOS tests — 18/18 passed: 5 AppHostRouting, 1 KeychainMigration, 3 NativeShareOutcome, and 9 PlatformPresentation.
- iPhone 17 Pro, iOS 26.2 Simulator parity — 1/1 passed in 216.666 seconds.
- iPad Pro 11-inch (M5), iOS 26.2 Simulator at AXXXL — 1/1 passed in 223.516 seconds.
- Clean macOS and generic iOS Simulator Release builds plus product inspection — 50/50 passed.

Exact commands, destinations, logs, result bundles, warnings, and remediation history are in `docs/verification/BuildAndTestReport.md`.

## Persisted-data migration evidence

| Store | Compatibility asserted | Evidence |
|---|---|---|
| Cipher library | Service `com.runescribe.keystore`; accounts `symmetricKey` and `cipherLibrary`; encrypted bytes and active selection unchanged; no startup rewrite or duplicate default cipher. | `CipherPersistenceApplicationTests`, consolidated existing-install test, IOS-H `KeychainMigrationTests`. |
| PIN and throttle | Accounts `appPin` and `pinThrottle`; PBKDF2 bytes, failure count, retry date, and cold locked state unchanged. | `AppLockServiceTests` golden/legacy fixtures and IPH PIN flow. |
| Contacts | Directory `RuneScribContacts`, file `contacts.enc`, version-1 AES-GCM schema and associations unchanged. | `ContactRepositoryTests` frozen fixture, ambiguous-write recovery, and association tests. |
| Imported fonts | Directory `RuneScribFonts`; digest filenames, hashes, mapping, registration, and fallback unchanged. | `FontCatalogTests`, IPH/IPD valid and invalid import flows. |
| Preferences/first run | Existing preferences load together; startup does not reset data or create a second default cipher. | `P4BApplicationServiceTests.testExistingInstallLoadsTogetherWithoutResetDuplicateOrStartupRewrite`. |

All fixtures are synthetic or frozen test data. The macOS rail uses an in-memory secure-store boundary. Real Apple Keychain calls occur only inside a fresh, isolated, ad-hoc-signed Simulator namespace and cannot access the macOS login Keychain.

## Wire-format evidence

| Format/rail | Compatibility result |
|---|---|
| Cipher payload v3 | Exact golden bytes decode and re-encode unchanged; custom and legacy links parse; registered v3 file routes to confirmation/import. |
| Message payload v1 | Exact golden bytes decode and re-encode unchanged; truncated/trailing input fails safely; registered v1 file routes to received-message/reply. |
| First delivery | Required cipher material is present in the first-delivery artifact and is consumed only after acknowledged terminal handoff. |
| Subsequent delivery | No key resend; cancellation/failure does not consume delivery. |
| URL/file identity | `runescribe://`, `com.runescribe.runescribe`, and `.runescribe` remain exact. |
| Failure/duplicate handling | Malformed, truncated, oversized, duplicate, and cancelled imports fail or remain pending without destructive state change. |
| Future metadata | No Codices/themes or future transport metadata was added. |

## Platform smoke and visual evidence

### macOS

The final hosted rail passed 8/8, the production-view parity host passed 3/3, and the strict ad-hoc normal-app self-test presented and dismissed both production file and link native share pickers. A product smoke recorded one visible, full-opacity Rune Scribe window. The lane used no Accessibility, Automation, global event injection, Contacts, clipboard, or login-Keychain approval surface.

### iOS and iPadOS

The final iPhone rail exercised first launch, product-only UI, six accessibility audits, Settings/license, contact and cipher CRUD, PIN create/change/remove and background relock, native share cancellation, rotation, custom-font success/failure, cold/warm URL handling, registered cipher/message files, decoded message, and reply. The iPad rail repeated the full flow at accessibility-extra-extra-extra-large and both orientations. Hosted tests separately proved app-host routing, isolated Apple Keychain migration, native-share outcome mapping, QR permission mapping, and MessageUI setup/completion policies.

### Retained UI evidence

The final iPhone and iPad UI observations are retained in their individual green result bundles under `/tmp/RuneScribe-P8-final-ios.87OHyd`. macOS production-view and native-picker observations are retained in `/tmp/RuneScribe-P8-final-mac.MN3k9e`. No sensitive screenshot or real contact/message data is tracked in the repository. All temporary Simulators used by the final iOS matrix were deleted after their individual result bundles were captured.

## Exact external/device validation

### FP-009 — System contact import

1. On a signed physical iPhone/iPad, start with Contacts permission undetermined.
2. Open contact import, grant and then deny permission in separate runs, select a synthetic contact, and complete import.
3. Inspect the resulting Rune Scribe contact and verify only mapped name/phone/email values are retained.
4. On a signed macOS product, repeat grant, deny, picker selection, and cancellation against a synthetic Contacts account without using real contact data.

Expected: authorization state and picker outcomes match the current product on iOS and macOS; selected values import once and no `CNContact` object or unnecessary source data persists.

### FP-015 — Inbound file routing

1. Send synthetic v3 cipher and v1 message files to a signed device through Files and Messages/AirDrop.
2. Open each file while the app is cold and warm.

Expected: the registered document type opens Rune Scribe; cipher files show import confirmation, message files show received-message state, and no sender file is modified.

### FP-020 — QR generation

1. Display a synthetic generated QR code on one device or screen.
2. Scan it with a separate physical camera or known QR reader.

Expected: the QR decodes to the exact generated `runescribe` URL and imports through the normal confirmation path.

### FP-021 — QR scanning

1. On a signed physical iOS device, open Scan QR, respond to camera permission, scan a valid synthetic Rune Scribe QR, cancel a second scan, and exercise the fallback path.
2. Repeat once with camera permission denied.

Expected: permission, scan, cancel, denied, and fallback states match current behavior; a valid scan routes exactly once.

### FP-022 — iMessage composer

1. On a signed physical iOS device configured for Messages, compose a first-delivery message with its required attachment and a follow-up without required key delivery.
2. Complete separate cancel, failure, and sent runs.

Expected: the required attachment is present and accepted before delivery is recorded; cancel/failure do not consume delivery; follow-up behavior remains unchanged.

### FP-023 — System Share sheet

1. On a signed physical iOS device, share synthetic link and file artifacts to at least one real system destination or AirDrop.
2. Complete a separate cancel run and verify the destination receives only the explicitly completed share.

Expected: destinations receive the exact link/file, completion/cancel semantics are reported once, and scoped artifacts are released.

### FP-030 — Background/resume lock

1. On a signed physical iOS device with PIN enabled, background and foreground the app and lock/unlock the device during pending and idle states.

Expected: resign alone does not prematurely lock; background/device lock protects content; resume presents the expected unlock state without losing queued input.

## Regressions and defects repaired

| Behavior | Previous risk | Repair | Regression evidence |
|---|---|---|---|
| Lock plaintext cleanup | An in-flight transform could restore sensitive state after lock/unlock. | Generation-bound single-flight work is cancelled and every plaintext snapshot/presentation state is cleared on lock. | Package lock-cleanup/generation tests; IPH/IPD relock flow. |
| Share artifact lifetime | Lock or duplicate callbacks could release or complete the wrong artifact more than once. | Identity-bound completion gate retains ownership through exactly one terminal outcome. | Package completion-gate and artifact-cleanup tests. |
| iOS file share completion | Tapping the control could be treated as delivery before the system outcome. | Retained `UIActivityViewController` maps public completed/error/cancel outcomes once. | IOS-H NativeShareOutcome 3/3; IPH/IPD native presentation/cancel. |
| iOS private-link completion | Opaque link data had the same early-handoff risk. | Link and file use the same retained presenter and terminal contract. | Hosted outcome tests and both parity devices. |
| iOS presenter lifecycle | Presentation, dismissal, and view reappearance could race or duplicate. | Separate pending/active state, appeared/dismissing guards, tracked dismissal, and adaptive-presentation fallback. | Final presenter source compiled in PKG, IOS-H, IPH, and IPD; all final rails green. |
| Required Messages attachment | A rejected first-delivery attachment could leave a sendable composer. | Required rejection returns an inert controller and exactly one failure. | IOS-H PlatformPresentation 9/9. |
| Shipping entitlements/linkage | Partial checks could accept an extra entitlement, divergent slice, unexpected Mach-O, broadened graph, or test-support product in a shipping binary. | Exact per-slice dictionaries, cross-slice equality, all-Mach-O linkage, structural graph allowlists, and TestSupport exclusion. | GUARD negative fixtures rejected; REL 50/50. |

These are correctness, security, and data-lifetime repairs, not a product redesign. Existing encode/decode, first-key delivery, private-link, Messages, export, import, and lifecycle contracts remain intact.

## Known limitations and conclusion

- Simulator and same-process local share evidence does not prove a real destination received content.
- Simulator Contacts/camera behavior does not replace physical permission and device interaction.
- Ad-hoc products do not qualify distribution identity, provisioning, installation, or signed-device behavior.
- The seven device-required rows are release gates and are not counted as passed.

All automatable and non-device feature-parity work is complete at `01e2fcf655a3139a856787fc96f17a58db3f3ad0`: 33 passed, 7 device validation required, 0 failed/open, and all 40 rows terminal. Rune Scribe is code-complete for the Forsetti architecture conversion, but the overall result remains `CODE COMPLETE — EXTERNAL VALIDATION REMAINS` until the exact physical-device checks above succeed.
