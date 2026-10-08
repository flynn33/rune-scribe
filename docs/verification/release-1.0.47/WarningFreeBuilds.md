# Rune Scribe 1.0.47 (47) Xcode build follow-up

Date: 2026-10-08. Xcode 27.0 (27A266a). Parent source commit:
`3699782606ec100566fe46ee814b0a545737cb9b`.

All four fresh unsigned application builds succeeded with **zero errors and zero
warnings**, in both the Xcode result bundles and raw build logs.
[Build results](WarningFreeBuildResults.json) retain commands, diagnostic counts,
log hashes, product versions, and binary architectures.
[Source hashes](WarningFreeSourceFiles.json) identify the build settings and
unchanged message-payload/test sources checked in this follow-up.

| Scheme | Configuration | Built architectures | Errors | Warnings |
| --- | --- | --- | --- | --- |
| RuneScrib-iOS | Debug | arm64 | 0 | 0 |
| RuneScrib-iOS | Release | arm64 | 0 | 0 |
| RuneScrib-macOS | Debug | arm64, x86_64 | 0 | 0 |
| RuneScrib-macOS | Release | arm64, x86_64 | 0 | 0 |

Both iOS configurations also built the embedded Messages extension. Every built
app and extension Info.plist reports version **1.0.47**, build **47**. Analyzer
warning counts are also zero. Raw logs were scanned case-insensitively for
`warning:` and `error:` diagnostics.

## Build setting and scope

The previous Release logs recorded an App Intents metadata-processor warning:
`Metadata extraction skipped, no AppIntents.framework dependency found`.
A scan of all 370 tracked Swift files outside reference-resource sources found no
AppIntents imports or AppIntent, AppShortcutsProvider, AppEntity, or AppShortcut
declarations, and no intent-definition/AppShortcuts resources were found.

The shared Debug/Release settings now set `LM_SKIP_METADATA_EXTRACTION = YES` in
`project.yml` and the regenerated `RuneScrib.xcodeproj/project.pbxproj`.
[Swift Build's App Intents task producer](https://github.com/swiftlang/swift-build/blob/080a73325cbc9063df3985d20d06181d9d4c5ab7/Sources/SWBApplePlatform/AppIntentsMetadataTaskProducer.swift#L50-L57)
returns no extraction task when this setting is enabled. The installed Xcode
build-system binary also contains this setting. Compiler warning diagnostics
remain enabled; no compiler-warning suppression, framework dependency, package
dependency, signing setting, application behavior, or version was changed.

The Xcode project references the local RuneScribeArchitecture package containing
the published Messages payload changes. A package import/dependency audit found
no missing direct production dependency. The only build-input changes since the
parent commit are the two shared build-setting entries and their source YAML.

## Reproduction and retained evidence

Each build used a new, separate DerivedData directory and result bundle with this
command shape; exact arguments for every run are retained in the build-results
JSON:

```sh
xcodebuild build -project RuneScrib.xcodeproj \
  -scheme RuneScrib-iOS -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/rune-scribe-xcode-warning-free-20261008/ios-debug-derived \
  -resultBundlePath /private/tmp/rune-scribe-xcode-warning-free-20261008/ios-debug.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=
```

The other runs substitute Release and/or `RuneScrib-macOS` with
`generic/platform=macOS`. `xcresulttool get build-results` reports `succeeded`,
`errorCount: 0`, `warningCount: 0`, and `analyzerWarningCount: 0` for each run.
Built products were inspected using Python plistlib and `lipo -archs`.

The documentation alignment, roadmap alignment/completion, architecture guardrails,
and both repositories' `git diff --check` checks passed after the documentation
updates. Documentation alignment reports version 1.0.47 build 47.

Raw logs, per-run result summaries, the source scan, and copies of both evidence
JSON files are retained at:
`/Users/jimdaley/Documents/Rune-Scribe-1.0.47-warning-free-verification`.
DerivedData and complete result bundles are retained at:
`/private/tmp/rune-scribe-xcode-warning-free-20261008`.

## Verification limits

These are application build checks. The earlier 12 iOS and 5 focused macOS test
results, broader baseline failures, and original source hashes remain unchanged
in the [message-payload qualification report](QualificationSummary.md). Those
tests were not rerun for this build-setting-only follow-up. No full aggregate
test pass, actual Messages delivery/recipient appearance, physical-device
screenshot, Store archive/export, signing, upload, or shipment is claimed.
Version 1.0.47 (47) remains the source candidate for the owner's device testing.
