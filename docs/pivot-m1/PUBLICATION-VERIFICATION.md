# M1 documentation publication verification

Date: 2026-10-21. **Application version 1.0.47 / build 47.** M1 inspected source d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54.

This later checkpoint records documentation publication and native build verification authorized after M1. Historical permission/unexecuted-check statements in the original reports describe the completed discovery run. No pivot application implementation is included.

## Fresh native builds

Xcode **27.0 (27A266a)** built both application schemes in fresh external DerivedData directories with signing disabled. [BuildResults.json](BuildResults.json) preserves the command shape, exact build-input hashes, log hashes, result counts and product metadata.

| Scheme | Configuration | Architectures | Errors | Warnings | Analyzer warnings |
|---|---|---|---:|---:|---:|
| RuneScrib-iOS | Debug | arm64 | 0 | 0 | 0 |
| RuneScrib-iOS | Release | arm64 | 0 | 0 | 0 |
| RuneScrib-macOS | Debug | x86_64, arm64 | 0 | 0 | 0 |
| RuneScrib-macOS | Release | x86_64, arm64 | 0 | 0 | 0 |

All four commands exited successfully and result bundles report succeeded. Raw logs contain zero warning/error diagnostic lines. Both iOS runs built the Messages extension. Every app/extension Info.plist reports 1.0.47/build 47. No M1 report files were found in the app products.

Exact commands, raw logs, result summaries, DerivedData and xcresult bundles remain in the external publication evidence directory. Unsigned builds do not establish runtime message delivery, purchase/restore or production migration.

## Documentation and project checks

- Documentation alignment passed with version 1.0.47/build 47 and historical release dates/qualification limits preserved.
- All 17 architecture guardrails passed; project and iOS/macOS Info plists passed plutil validation.
- 124 immutable source links and 37 portable local links resolved in the discovery publication copies; all JSON parsed and all ten original/published report hash pairs matched.
- Content retains 156 items, all 84 historical catalog IDs and 319 resource entries (315 physical plus four embedded localizations).
- Source/wiki attribution scans and diff whitespace checks passed. Private conversation identifiers, absolute user paths and raw local authority retrieval are excluded from portable snapshots.
- The generated Xcode project adds 15 documentation file references and one group; only the existing docs group gains a child. Existing targets, build settings, package/framework references and source/resource/copy phases are unchanged. The generator input adds only top-level fileGroups: docs/pivot-m1.
- Swift sources, Package.swift, entitlements and configuration files have no content changes. Unrelated generated iOS-scheme formatting was omitted.

Original external M1 reports remain preserved. No authoritative Project Record was replaced, adopted method pin selected or reviewed realization-contract acceptance invented.

## Scope and publication boundary

No app runtime tests, launch, StoreKit purchase/restore, customer-data access, Store change, archive/export, distribution signing, upload or release occurred. Earlier runtime-test/recipient gaps remain as documented. Current progression and Game Center behavior remains in the application.

Source/wiki Git publication is separate from implementation/distribution. Current repository rules require a pull request; the owner explicitly permits an administrator bypass for this publication. Any bypass actually reported by GitHub is retained in the external publication receipt. Repository protections are not disabled or edited. Commits use the configured Jim Daley identity without added attribution credit.

See the [M1 report index](README.md) for the approved future commercial outcome and unresolved migration/authority inputs.
