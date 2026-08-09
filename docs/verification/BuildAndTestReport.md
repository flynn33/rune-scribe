# Rune Scribe Build and Test Report

## Result

**Status:** `CODE COMPLETE — EXTERNAL VALIDATION REMAINS`

All final-current automatable gates for cleanup commit `01e2fcf655a3139a856787fc96f17a58db3f3ad0` passed. The 28 automatable pre-audit matrix rows have current evidence and zero pending implementation evidence; T-026 remains an external physical-device row and unconditional completion remains deferred. The retained evidence was produced against the exact cleanup tree later committed at `01e2fcf`; no source changed between the final lanes and that local commit.

## Toolchain

| Tool | Observed version |
|---|---|
| macOS build environment | Apple Silicon macOS host |
| Xcode | 26.2, build 17C52 |
| Swift | Apple Swift 6.2.3 (`swiftlang-6.2.3.3.21`, Clang 1700.6.3.2) |
| XcodeGen | 2.46.0 |
| iOS Simulator runtime | iOS 26.2 |
| jq | 1.7.1 |
| Git | 2.50.1 |
| ripgrep | 15.1.0 |

The project source of truth is `project.yml`; `RuneScrib.xcodeproj` is the committed generated project. The Swift package uses Swift tools 6.0 and Swift language mode 6.

## Final evidence inventory

| Evidence root | Contents and final result |
|---|---|
| `/tmp/RuneScribe-P8-final-package.yGz7qs` | Architecture 17/17; SwiftPM 283/283; deterministic project; clean diff; empty warning/error census. |
| `/tmp/RuneScribe-P8-cleanup.bxBuUN` | Cleanup regression gates plus source/generated shipping negative fixtures. |
| `/tmp/RuneScribe-P8-guard-audit.4gkAfP` | Independent TestSupport source, package-product, dependency, and regenerated-project negative fixtures. |
| `/tmp/RuneScribe-P8-final-mac.MN3k9e` | macOS hosted 8/8, macOS parity 3/3, native file/link share presentation and dismissal. |
| `/tmp/RuneScribe-P8-final-ios.87OHyd` | Clean generic iOS Simulator build-for-testing, hosted iOS 18/18, iPhone parity 1/1, and iPad AXXXL parity 1/1. Each individual result bundle is green; all temporary Simulators were deleted. |
| `/tmp/RuneScribe-P8-release-final.XsJS4P` | Clean macOS and generic iOS Simulator Release builds; shipping inspection 50/50. |
| `docs/verification/p7-test-matrix.json` | Exact 30-row normative matrix, commands, timestamps, results, and cross-references. |
| `docs/verification/feature-parity-matrix.json` | All 40 parity rows terminal: 33 passed, 7 device-required, 0 failed/open. |
| `docs/verification/ForsettiMigrationReconciliation.json` | 89/89 migration entries terminal and current. |
| `docs/verification/ForsettiTestReconciliation.json` | 157/157 P0 test methods terminal: 78 preserved, 79 equivalent. |

This report does not claim a completion-report JSON.

## Exact final commands and destinations

### Package and architecture

Destination: local arm64 macOS SwiftPM host and repository working tree.

```bash
swift test --package-path Packages/RuneScribeArchitecture
scripts/check-architecture.sh
git diff --check
```

Result: SwiftPM passed 283/283 tests in 1.437 seconds with zero failures or unexpected results. The architecture script passed 17/17 checks; all zero-tolerance metrics were zero, the two local media-notification observations remained within their allowlist, and the host was 290/300 physical lines. `git diff --check` passed. Evidence:

- `/tmp/RuneScribe-P8-final-package.yGz7qs/swift-test.log`
- `/tmp/RuneScribe-P8-final-package.yGz7qs/check-architecture.log`
- `/tmp/RuneScribe-P8-final-package.yGz7qs/git-diff-check.log`
- `/tmp/RuneScribe-P8-final-package.yGz7qs/warning-error-census.log`

### XcodeGen reproducibility

Destination: `RuneScrib.xcodeproj` generated from `project.yml`.

```bash
xcodegen generate
xcodegen generate
scripts/check-architecture.sh
git diff --check
```

Result: after each generation, `project.pbxproj` and all four shared schemes were hashed into `generated-first.sha256` and `generated-second.sha256`; the manifests are identical. `project.pbxproj` SHA-256 is `5fcafb2ffd877311dd1ea973f58526036e7af543e6e6ff45d36b1a80beb56a30`. Shipping apps consume exactly six production products. `RuneScribeTestSupport` is limited to two package test targets and three Xcode test targets and is excluded from app sources and generated PBXSources. Evidence: `/tmp/RuneScribe-P8-final-package.yGz7qs`, `/tmp/RuneScribe-P8-cleanup.bxBuUN`, and `/tmp/RuneScribe-P8-guard-audit.4gkAfP`.

### Full macOS hosted tests

Destination: `platform=macOS,arch=arm64`; manual ad-hoc test host, empty team and entitlements, in-memory security stores.

```bash
xcodebuild test \
  -project RuneScrib.xcodeproj \
  -scheme RuneScrib-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/RuneScribe-P8-final-mac.MN3k9e/main-derived \
  -resultBundlePath /tmp/RuneScribe-P8-final-mac.MN3k9e/RuneScrib-macOS.xcresult \
  -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=
```

Result: exit 0; 8/8 passed, 0 failed, 0 skipped; seven hosted tests plus the standalone architecture guard; 18.347 seconds. Evidence: `/tmp/RuneScribe-P8-final-mac.MN3k9e/RuneScrib-macOS.log`, `/tmp/RuneScribe-P8-final-mac.MN3k9e/RuneScrib-macOS.xcresult`, and `/tmp/RuneScribe-P8-final-mac.MN3k9e/RuneScrib-macOS-test-summary.json`.

### macOS production-view parity and native share

Destination: isolated no-entitlements macOS test host with in-memory services and test-owned temporary artifacts.

```bash
xcodebuild test \
  -project RuneScrib.xcodeproj \
  -scheme RuneScrib-macOS-Parity \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/RuneScribe-P8-final-mac.MN3k9e/parity-derived \
  -resultBundlePath /tmp/RuneScribe-P8-final-mac.MN3k9e/RuneScrib-macOS-Parity.xcresult \
  -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=

scripts/check-macos-native-share.sh \
  /tmp/RuneScribe-P8-final-mac.MN3k9e/parity-derived/Build/Products/Debug/RuneScribMacParityHost.app \
  /tmp/RuneScribe-P8-final-mac.MN3k9e/native-share-report.json
```

Result: 3/3 parity tests passed with zero failures/skips in 16.830 seconds. The normal-app self-test then triggered production file and link share controls once each, observed the native picker, and dismissed it with a same-process local Escape event. Evidence: `RuneScrib-macOS-Parity.xcresult`, `native-share-report.json`, `codesign-verify.log`, and `final-gate-report.json` under `/tmp/RuneScribe-P8-final-mac.MN3k9e`.

### Generic iOS Simulator build

Destination: `generic/platform=iOS Simulator`.

```bash
xcodebuild \
  -project RuneScrib.xcodeproj \
  -scheme RuneScrib-iOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/RuneScribe-P8-final-ios.87OHyd/generic-derived \
  -resultBundlePath /tmp/RuneScribe-P8-final-ios.87OHyd/GenericBuild.xcresult \
  clean build-for-testing \
  CODE_SIGNING_ALLOWED=NO
```

Result: exit 0; clean and `BUILD SUCCEEDED`; the individual result bundle reports succeeded with zero warnings, errors, or analyzer warnings. Evidence: `/tmp/RuneScribe-P8-final-ios.87OHyd/generic-build.log`, `/tmp/RuneScribe-P8-final-ios.87OHyd/GenericBuild.xcresult`, and `/tmp/RuneScribe-P8-final-ios.87OHyd/GenericBuild-request.json`.

### Hosted iOS tests

Destination: fresh isolated iPhone 17 Pro, iOS 26.2 Simulator, recorded ID `906599AD-E2E7-4BB0-AE05-8D7731BE2204` (deleted after the run).

```bash
xcodebuild \
  -project RuneScrib.xcodeproj \
  -scheme RuneScrib-iOS \
  -destination 'platform=iOS Simulator,id=906599AD-E2E7-4BB0-AE05-8D7731BE2204' \
  -derivedDataPath /tmp/RuneScribe-P8-final-ios.87OHyd/hosted-derived \
  -resultBundlePath /tmp/RuneScribe-P8-final-ios.87OHyd/IOSHosted.xcresult \
  test \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=9AQ2C2838M
```

Result: exit 0; 18/18 passed, 0 failed, 0 skipped in 18.553 seconds: 5 AppHostRouting, 1 KeychainMigration, 3 NativeShareOutcome, and 9 PlatformPresentation. Evidence: `/tmp/RuneScribe-P8-final-ios.87OHyd/hosted-test.log`, `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSHosted.xcresult`, and `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSHosted-summary.json`.

The team value was used only to create the simulated Keychain access-group prefix for the isolated app. `KeychainMigrationTests` exercised real `SecItem` only inside that Simulator namespace. It could not access or prompt for the macOS login Keychain.

### iPhone parity

Destination: fresh isolated iPhone 17 Pro, iOS 26.2 Simulator, recorded ID `9E1647B9-7B8D-4EFD-AFD0-C17C9CFA955B` (deleted after the run).

```bash
xcodebuild \
  -project RuneScrib.xcodeproj \
  -scheme RuneScrib-iOS-Parity \
  -destination 'platform=iOS Simulator,id=9E1647B9-7B8D-4EFD-AFD0-C17C9CFA955B' \
  -derivedDataPath /tmp/RuneScribe-P8-final-ios.87OHyd/iphone-parity-derived \
  -resultBundlePath /tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPhone.xcresult \
  test \
  RUNESCRIBE_APP_BUNDLE_IDENTIFIER=com.runescribe.app.p8uitest.iphone \
  CODE_SIGN_ENTITLEMENTS= CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Result: the individual result bundle is green: 1/1 passed, 0 failures/skips in 216.666 seconds. The rail covered fresh launch, six strict accessibility audits, product-only UI, contacts, PIN lifecycle/background relock, share cancellation, cipher lifecycle, rotations, malformed and valid links/files, custom-font success/hash failure, decoded message, and reply. Evidence: `/tmp/RuneScribe-P8-final-ios.87OHyd/iphone-parity.log`, `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPhone.xcresult`, and `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPhone-summary.json`.

### iPad parity at largest accessibility size

Destination: fresh iPad Pro 11-inch (M5), iOS 26.2 Simulator, AXXXL, recorded ID `50A89D30-353C-4D26-87D7-D714C256EEF0` (deleted after the run).

```bash
xcodebuild \
  -project RuneScrib.xcodeproj \
  -scheme RuneScrib-iOS-Parity \
  -destination 'platform=iOS Simulator,id=50A89D30-353C-4D26-87D7-D714C256EEF0' \
  -derivedDataPath /tmp/RuneScribe-P8-final-ios.87OHyd/ipad-parity-derived \
  -resultBundlePath /tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPad.xcresult \
  test \
  RUNESCRIBE_APP_BUNDLE_IDENTIFIER=com.runescribe.app.p8uitest.ipad \
  CODE_SIGN_ENTITLEMENTS= CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Result: the individual result bundle is green: 1/1 passed, 0 failures/skips in 223.516 seconds. The same full flow passed with iPad layout, AXXXL content, native share popover anchoring, and portrait/landscape rotation. Evidence: `/tmp/RuneScribe-P8-final-ios.87OHyd/ipad-parity.log`, `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPad.xcresult`, `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPad-summary.json`, and `/tmp/RuneScribe-P8-final-ios.87OHyd/ipad-content-size.log`.

### Clean macOS Release product

Destination: `generic/platform=macOS`; manual ad-hoc signature; no injected base entitlements.

```bash
xcodebuild \
  -project RuneScrib.xcodeproj \
  -scheme RuneScrib-macOS \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/RuneScribe-P8-release-final.XsJS4P/macos-final/DerivedData \
  -resultBundlePath /tmp/RuneScribe-P8-release-final.XsJS4P/macos-final/RuneScrib-macOS-Release.xcresult \
  -disableAutomaticPackageResolution \
  clean build \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
```

Result: clean/build succeeded in 29.848 seconds; the individual result bundle contains zero structured errors or warnings. The sole raw warning is the expected AppIntents metadata skip.

### Clean generic iOS Simulator Release product

Destination: `generic/platform=iOS Simulator`; manual ad-hoc signature.

```bash
xcodebuild \
  -project RuneScrib.xcodeproj \
  -scheme RuneScrib-iOS \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/RuneScribe-P8-release-final.XsJS4P/ios/DerivedData \
  -resultBundlePath /tmp/RuneScribe-P8-release-final.XsJS4P/ios/RuneScrib-iOS-Release.xcresult \
  -disableAutomaticPackageResolution \
  clean build \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
```

Result: clean/build succeeded in 28.953 seconds; the individual result bundle and raw log contain zero warnings or errors.

### Shipping-product inspection

```bash
scripts/check-shipping-products.sh \
  --macos-app /tmp/RuneScribe-P8-release-final.XsJS4P/macos-final/DerivedData/Build/Products/Release/RuneScrib.app \
  --ios-app /tmp/RuneScribe-P8-release-final.XsJS4P/ios/DerivedData/Build/Products/Release-iphonesimulator/RuneScrib.app
```

Result: 50/50 checks passed. The checker validated exact Info.plists; strict signatures and nested seals; macOS hardened runtime; per-architecture entitlement dictionaries and cross-slice equality; assets, icon, font, video, Metal, and manifests; every bundled Mach-O and canonical load command; exact app executables; absence of Forsetti linkage; all six production products; the exact source/generated dependency graph; and absence of `RuneScribeTestSupport` symbols from both executables. Evidence: `/tmp/RuneScribe-P8-release-final.XsJS4P/shipping-products-50-of-50.log`, `/tmp/RuneScribe-P8-release-final.XsJS4P/qualification-summary.json`, and `/tmp/RuneScribe-P8-release-final.XsJS4P/census`.

## Consolidated result matrix

| Layer | Destination | Result | Final evidence |
|---|---|---|---|
| JSON/normative matrix | Repository | Passed; all schemas/IDs/counts/references coherent | `docs/verification/p7-test-matrix.json` |
| Architecture | Repository | 17/17 | `/tmp/RuneScribe-P8-final-package.yGz7qs/check-architecture.log` |
| Package/runtime/modules/migration | arm64 macOS SwiftPM | 283/283 | `/tmp/RuneScribe-P8-final-package.yGz7qs/swift-test.log` |
| Project generation | Local project | Two identical generations | `/tmp/RuneScribe-P8-final-package.yGz7qs/generated-second.sha256` |
| macOS full hosted | arm64 macOS | 8/8 | `/tmp/RuneScribe-P8-final-mac.MN3k9e/RuneScrib-macOS.xcresult` |
| macOS product parity | arm64 macOS | 3/3 | `/tmp/RuneScribe-P8-final-mac.MN3k9e/RuneScrib-macOS-Parity.xcresult` |
| macOS native share | Same-process normal app | Link/file both passed | `/tmp/RuneScribe-P8-final-mac.MN3k9e/native-share-report.json` |
| Cleanup/negative guards | Repository fixtures | All intended injections rejected | `/tmp/RuneScribe-P8-cleanup.bxBuUN` and `/tmp/RuneScribe-P8-guard-audit.4gkAfP` |
| Generic iOS build | iOS Simulator | Build succeeded | `/tmp/RuneScribe-P8-final-ios.87OHyd/GenericBuild.xcresult` |
| Hosted iOS | iPhone 17 Pro Simulator | 18/18 | `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSHosted.xcresult` |
| iPhone UI parity | iPhone 17 Pro Simulator | 1/1 | `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPhone.xcresult` |
| iPad UI parity | iPad Pro 11-inch (M5), AXXXL | 1/1 | `/tmp/RuneScribe-P8-final-ios.87OHyd/IOSParity-iPad.xcresult` |
| macOS Release | Generic macOS | Clean build succeeded | `/tmp/RuneScribe-P8-release-final.XsJS4P/macos-final/RuneScrib-macOS-Release.xcresult` |
| iOS Simulator Release | Generic Simulator | Clean build succeeded | `/tmp/RuneScribe-P8-release-final.XsJS4P/ios/RuneScrib-iOS-Release.xcresult` |
| Shipping configuration/products | Both Release products | 50/50 | `/tmp/RuneScribe-P8-release-final.XsJS4P/shipping-products-50-of-50.log` |
| Original test reconciliation | Repository | 157/157 terminal | `docs/verification/ForsettiTestReconciliation.json` |
| Migration reconciliation | Repository | 89/89 terminal | `docs/verification/ForsettiMigrationReconciliation.json` |
| Feature parity | All automatable platforms | 33 passed, 7 device-required, 0 failed/open | `docs/verification/feature-parity-matrix.json` |

## Migration, wire, data, and platform coverage

- Existing cipher library, active selection, raw key bytes, PIN/throttle, encrypted contacts, imported fonts, preferences, and first-run behavior passed frozen-fixture and consolidated existing-install tests without destructive rewrite.
- Cipher v3 and message v1 passed exact golden decode/re-encode; malformed, truncated, trailing, oversized, duplicate, and cancellation paths failed safely.
- First-delivery key inclusion and subsequent no-resend behavior passed artifact-byte, acknowledgement, cancellation, failure, and cleanup tests.
- Cold/warm URL/file/activity/lifecycle inputs passed package, macOS-hosted, iOS-hosted, and production UI parity rails.
- macOS RootView, Settings, commands, custom fonts, file/link share controls, and native picker presentation passed without global input or permission prompts.
- iPhone and iPad production flows passed on fresh isolated Simulators, including accessibility, orientation, share presentation, import, PIN, font, message, and reply paths.
- Both clean Release products passed exact entitlements, registrations, resources, manifests, executables, linkage, and dependency-graph inspection.

## Warnings and diagnostics

Structured warnings, errors, analyzer issues, test failures, and unexpected results are zero across the final Xcode result bundles. The package `warning-error-census.log` is empty.

Classified raw-output diagnostics:

- AppIntents metadata extraction skips where the product has no AppIntents dependency.
- Headless `linkd` and CVDisplayLink environment messages in macOS hosted lanes.

The final macOS Release log has one AppIntents metadata-skip warning; the iOS Simulator Release log has zero raw warning lines. None of the classified macOS lines is a compiler, Swift concurrency, analyzer, signing, test, or product failure.

## Failures, retries, and remediation

Only final-current roots above qualify the implementation. Earlier partial or stale rails were retained solely as diagnosis history.

| Area | Root cause found during qualification | Remediation | Final-current proof |
|---|---|---|---|
| iOS native file/link share | Early handoff and `.sheet` embedding did not preserve public system completion/lifecycle semantics. | Added a retained controller presenter, pending/active separation, appeared/dismissing guards, iPad anchor, tracked dismissal, adaptive fallback, and exact-once outcome gate. | IOS-H 18/18; IPH 1/1; IPD 1/1. |
| Lock during message work | In-flight work could restore plaintext or release/complete an artifact after lock. | Generation-bound single-flight cancellation, full sensitive-state clearing, artifact identity, and one terminal completion. | PKG 283/283; IPH/IPD relock flow. |
| Required Messages attachment | Rejected required attachment could fail open to a usable composer. | Explicit attachment setup policy; inert controller plus one failure on required rejection. | IOS-H PlatformPresentation 9/9. |
| Shipping entitlements | Earlier product check did not prove exact dictionaries on every slice. | Per-slice extraction, no-extra-key allowlists, cross-slice equality, and source binding. | Cleanup/guard negative fixtures rejected; REL 50/50. |
| Shipping linkage/TestSupport | Earlier product check did not enumerate every Mach-O, structurally bind the graph, or prove test-support exclusion. | All-Mach-O enumeration, per-arch load-command checks, canonical paths, exact executable/product/phase/config/source graph, and symbol-exclusion checks. | Source, PBXSources, package-product, dependency, Mach-O, and configuration fixtures rejected; REL 50/50. |

Earlier diagnostic iPhone parity attempts exposed the share-presentation lifecycle defects and are not acceptance evidence. The successor iPhone, iPad, and hosted result bundles under `/tmp/RuneScribe-P8-final-ios.87OHyd` compile the cleanup source, are individually green, and are the only current share qualification evidence.

The hardened guards ran disposable negative fixtures under `/tmp/RuneScribe-P8-cleanup.bxBuUN` and `/tmp/RuneScribe-P8-guard-audit.4gkAfP`. Extra or direct TestSupport shipping sources, generated PBXSources membership, package products, dependencies, entitlements, divergent slices, unexpected code, non-canonical install names, and broadened source configuration were rejected before the clean 50/50 pass.

## Unattended execution and signing boundary

- macOS tests used in-memory or test-owned stores and manual ad-hoc signatures.
- The sole real `SecItem` migration ran in a fresh isolated iOS Simulator namespace.
- Generic build verification used `CODE_SIGNING_ALLOWED=NO`; signed test and Release lanes used `CODE_SIGN_IDENTITY=-` noninteractively.
- No distribution signing identity was queried or assessed.
- No macOS login Keychain, password prompt, Contacts or clipboard approval, Accessibility/Automation permission, System Events, VoiceOver control, AXUIElement, CGEvent, screen capture, or global synthetic event was used.
- All temporary Simulators created for final parity/hosted evidence were erased and deleted.

## Remaining external validation

T-026 remains `device-validation-required`. Signed physical hardware must still validate real Contacts/camera permissions, QR optical scanning, Files/Messages/AirDrop ingress, Messages attachment delivery, external share destination receipt, and physical device lock/background lifecycle. Distribution identity/provisioning, signed archive installation, and release-device launch also remain external.

Because these gates are not passed, this report does not claim all 30 blocking self-audit assertions or a schema-valid completion-report JSON. The exact external steps and expected results are in `docs/verification/FeatureParityReport.md`.

## Final conclusion

The final-current package, project-generation, macOS, iOS hosted, iPhone, iPad, Release, migration, test-reconciliation, and shipping evidence is green with zero actionable warning or open code defect. The appropriate result is `CODE COMPLETE — EXTERNAL VALIDATION REMAINS`, not unconditional pass or release approval.
