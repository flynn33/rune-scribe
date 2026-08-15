# Theme Scaffold and Norse Base Implementation Report

**Recorded:** 2026-08-15

**Repository baseline:** `e8c76537082829ef1e2292eb8fa21ca78740aaa2`

**Phase A result:** PASS — generic Theme scaffold implemented

**Phase B result:** PASS — required Norse Base provider extracted and verified

**Overall Elven Series package result:** **FAIL / BLOCKED**

## Executive decision

The two non-creative prerequisites authorized by the active Elven Series design
package are implemented:

- Phase A closes the generic Theme scaffold and records THM-001 through THM-012 as
  satisfied.
- Phase B extracts the existing Norse presentation into the required
  `RuneScribeNorseThemeModule` without changing the canonical Base Script, bundled
  Noto Sans Runic bytes, cryptography, payload readers, or outbound format policy.

The package as a whole does **not** pass. Phase C and every Elven-dependent phase are
blocked by unresolved findings DEV-ELVEN-003 through DEV-ELVEN-009 in
[`ElvenSeriesBlockingDeviationReport.md`](ElvenSeriesBlockingDeviationReport.md).
An official corrective-resolution package was then received and logged in
[`ElvenSeriesBlockingResolutionLedger.md`](ElvenSeriesBlockingResolutionLedger.md).
Those findings cover conflicting Progression identifiers and authorities, geometry
and anchor conflicts, missing line-limit authority, prose/source topology conflicts,
incorrect Crest metadata, incomplete resource declarations, and absent mandatory
provenance facts. A zero-unresolved-finding statement cannot be issued.

No production Elven asset, font, descriptor, provider target, Progression binding,
share resource, or receive-path behavior was created or changed. Existing repository
references to future Theme content predate this implementation and remain frozen.

## Controlling scope

This report covers only the smallest coherent work allowed while the blocking
findings remain open:

1. versioned, provider-neutral Theme and Coordinator contracts;
2. runtime-owned contribution, opaque-resource, selection, availability, and
   diagnostics foundations;
3. common-UI interpretation of semantic Theme state and resources;
4. one required Norse Base provider preserving the existing Base behavior;
5. conformance providers and tests that use synthetic non-production resources;
6. host, build graph, architecture guard, roadmap, and shipping-product updates
   needed to compose those prerequisites.

The following work is expressly outside the completed scope:

- Phase C Elven Series resource production;
- Phase D Moonleaf, Sunspire, Wildwood, and Gloamthorn provider targets;
- Phase E Elven Progression bindings;
- Phase F themed share/receive integration;
- Phase G full Elven release evidence.

## Input and preflight evidence

The active package was inspected before implementation. Its byte-level intake result
is recorded separately with the semantic deviations. The integrity facts are:

| Evidence | Result |
|---|---:|
| Files present | 197 |
| Manifest-declared files | 196 |
| Declared hash and byte-length matches | 196 of 196 |
| Package manifest SHA-256 | `46a9ca790e5d1f98232cf3532c9a0f996132e036ebc05d32db82c6509af24dd9` |
| Asset manifest SHA-256 | `752bcf17e2607bbdd7b5006e4fe0c999c4f58943cd3168046ff20e2cf5482b8f` |

Byte integrity does not resolve DEV-ELVEN-001 through DEV-ELVEN-009 and therefore does
not authorize production Elven work.

## Phase A — generic Theme scaffold

### Contracts and invariants

`RuneScribeContracts` now defines versioned, value-semantic contracts for:

- Theme, Codex, Script, glyph, Artifact, palette, accessibility, layout, rights, and
  resource descriptors;
- exact 32-value canonical Script ordering and the unchanged Base transport tokens;
- bounded `FontRef` identity and registration metadata;
- normalized layout regions, Seal anchors, maximum glyph lines, overflow behavior,
  and share aspect ratios;
- SHA-256, byte length, pixel dimensions, media type, semantic role, and required or
  optional status for every opaque resource;
- provider installation, ownership, availability, entitlement, selection, fallback,
  diagnostics, and Coordinator snapshot data.

Descriptors reject duplicate or invalid identifiers, incompatible schema versions,
unbound resources, invalid geometry, invalid hashes, missing rights references, and
provider-supplied UI behavior.

### Runtime ownership and isolation

The app-owned runtime remains the privileged mediator. The resulting ownership path
is:

```text
Theme provider
  -> publishes one validated descriptor and owner-scoped opaque bytes
App-owned runtime
  -> validates identity, generation lease, hash, media, dimensions, and budgets
Theme Coordinator
  -> composes installed / owned / selectable / selected / fallback state
Common UI
  -> resolves semantic state and opaque handles through runtime endpoints
```

Provider modules do not import the UI, inject views, communicate with peers, read
messages or Contacts, evaluate Progression gates, access platform I/O directly, or
resolve another module's bundle. Owner and generation leases remove contributions and
resources when a provider stops or becomes invalid.

The generic keyed contribution registry enforces type identity, unique keys,
owner-scoped publication, generation cleanup, canonical validation, snapshots, and
change streams. The opaque-resource registry enforces namespace ownership, declared
payload completeness, undeclared-resource rejection, media validation, byte and hash
agreement, image dimensions, per-resource limits, catalog limits, module limits,
owner-generation cleanup, and opaque-handle resolution.

### Coordinator, selection, and fallback

`RuneScribeThemeCoordinatorModule` is a required app-owned service. It:

- discovers provider contributions without importing a provider implementation;
- requires the Norse Base role before activation;
- reconciles contribution, resource, availability, entitlement, and Setting changes;
- persists the preferred Codex only through the runtime-owned Setting;
- rejects locked or unavailable selections;
- retains preference while selecting Norse as the effective fallback;
- serializes reconciliation so stale work cannot overwrite a newer state;
- exposes only bounded state, selection, resource-resolution, and diagnostics
  endpoints;
- denies support diagnostics in production.

The Coordinator manifest currently publishes:

- `theme.state`
- `theme.state.current`
- `theme.codex.select`
- `theme.resource.resolve`
- `theme.diagnostics.summary`

### Common UI adoption

The sole UI Module imports contracts and runtime clients, not a Theme provider. The
common scaffold interprets semantic palette tokens, Script font or provider-resolved
PDF vectors, background variants and renderer parameters, Vault state, accessibility
labels, High Contrast, and Reduce Motion. Appearance Settings uses product language
and Coordinator-owned selection state; it does not introduce provider-specific
navigation or screens.

Resource adoption is transactional: the UI resolves and validates the complete
effective Theme presentation before committing a new snapshot. A failed or incomplete
optional provider leaves the previous effective presentation intact and records a
bounded error. Initial root presentation waits for the Base Theme resources and font
to be ready, avoiding a partially themed first frame.

Encoded and decoded resource caches are bounded, purgeable, and keyed by verified
content identity. Provider vector resources are rendered as data, never executed as
code. The current decoded cache ceiling is 64 MiB.

### Shared conformance evidence

The conformance harness exercises the required Base provider plus two deliberately
different synthetic providers:

- a font-dependent provider; and
- a vector-rendered Script provider.

The providers share the same contracts, Coordinator, resource resolver, semantic UI,
selection behavior, accessibility variants, and failure/fallback tests. No production
Elven art is used to close a scaffold gate.

The roadmap evidence records THM-001 through THM-012 as `satisfied` in both
`docs/architecture/RoadmapAlignment.md` and
`docs/verification/roadmap-alignment.json`.

## Phase B — Norse Base extraction

### Provider identity and ownership

| Property | Frozen value |
|---|---|
| Module | `com.runescribe.module.theme.norse` |
| Role | `runescribe.theme.norse` |
| Policy class | `policy.theme-provider` |
| Criticality | required |
| Theme | `theme.norse.base` |
| Codex | `codex.norse` |
| Entitlement | `unlock.codex.norse` with `always` requirement |
| Script | `script.base-runes` |
| Fallback | Norse Base itself |
| Platforms | iOS 17+ and macOS 15+ |

The host registers Norse before the Theme Coordinator and UI. The Coordinator requires
the Norse role. The provider is always owned, non-removable through product settings,
and the universal fallback for a missing, locked, unavailable, incompatible, or failed
optional provider.

### Frozen Script and font

The Script catalog contains exactly 32 unique entries in canonical values 0 through
31, exact glyph IDs `glyph.base-runes.00` through `glyph.base-runes.31`, and the
unchanged ordered Unicode tokens U+16A0 through U+16BF. The font reference is
`noto-sans-runic`, version 1, PostScript name `NotoSansRunic-Regular`.

The extracted font is a byte-for-byte copy of the existing application font:

| File | Bytes | SHA-256 |
|---|---:|---|
| `RuneScrib/Resources/Fonts/NotoSansRunic-Regular.ttf` | 55,800 | `615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b` |
| `RuneScribeNorseThemeModule/Resources/NotoSansRunic-Regular.ttf` | 55,800 | `615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b` |
| `RuneScrib/Resources/Fonts/OFL.txt` | 4,381 | `b0fbcb9eaf0f5f415358bfefa5999ee75e18cde4a275b78285b2140a9e381865` |

The Script mapping catalog is 3,012 bytes with SHA-256
`b4c6b17c75a29faeed7c51f9c34d975b4c8b10c0522f7c3212b8471e53fd2cac`.

### Logical resource inventory

The Norse descriptor declares 42 resources and every one is required. Runtime budgets
count each declared semantic resource ID, including distinct roles that intentionally
resolve to the same immutable payload.

| Runtime category | Resources | Published bytes | Limit |
|---|---:|---:|---:|
| Descriptor JSON | 3 | 10,196 | 256 KiB per resource |
| Static/vector images | 38 | 957,575 | 8 MiB each; 32 MiB catalog |
| Font | 1 | 55,800 | 8 MiB each; 16 MiB catalog |
| Animation | 0 | 0 | 16 MiB catalog |
| Sound | 0 | 0 | 2 MiB each; 8 MiB catalog |
| **Complete published module** | **42** | **1,023,571** | **64 MiB** |

All raster dimensions are at most 1024 by 1024, below the 4096 by 4096 limit. The
largest declared resource is 176,255 bytes. The published set includes:

- one font, one canonical mapping, and one Script static fallback;
- three background variants plus renderer parameters;
- four Vault-state resources;
- three Relics with primary, thumbnail, static share fallback, and High Contrast
  roles;
- six Seals with PDF vector, monochrome fallback, and thumbnail roles;
- one English localization catalog.

Norse frames and crests remain empty because the extraction preserves existing Base
presentation rather than inventing new content.

### Bundled resource inventory and hashes

The module ships six owner-scoped bundle files totaling 1,088,132 bytes. Source tooling
is excluded from the processed bundle.

| Bundled file | Bytes | SHA-256 |
|---|---:|---|
| `NorseBaseLocalizations-en-US-v1.0.json` | 3,799 | `5151ffb31d7d3622b067422e959d2054ff095ef35f92ca25b1bf4bfcb1de2949` |
| `NorseBasePlaceholderAssets-v1.0.json` | 1,019,985 | `3a488cfbec99d79f8e776e52e57504c049312d865ba85a336068a2641e8b07d2` |
| `NorseBaseScriptFallback-v1.0.json` | 3,012 | `b4c6b17c75a29faeed7c51f9c34d975b4c8b10c0522f7c3212b8471e53fd2cac` |
| `NorseBaseVisualResources-v1.0.json` | 3,385 | `ede2823478bf8afa7838fe3b6e6965d9e76e6eefd2b745e45431abc68aa0fc38` |
| `NotoSansRunic-Regular.ttf` | 55,800 | `615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b` |
| `module-manifest.json` | 2,151 | `f0d3588fef8a4accc6f1769e07367ee6f4da99473eff4c77f75ffc0f4e0716fe` |

The deterministically reproducible Norse conformance-resource source is retained at
`Resources/Source/make_norse_base_placeholders.swift`; it is 14,927 bytes with
SHA-256 `f4991f9ee481e2c7cad501d8cef49c043596803d3ea6974751299abbfaef24a6` and
is verified absent from the shipping resource bundle.

Related manifest hashes at this report revision are:

| Manifest | Bytes | SHA-256 |
|---|---:|---|
| Theme Coordinator | 1,215 | `aaa6a0e08f4b7ae9c1fa39a26990dbd7909824aaf6efae08492ab8f86f48507c` |
| UI Module | 2,931 | `59625d0f310749082865de1ab05637add6b566ae95c5ca57e124e6f0347d4f3a` |

### Compatibility boundaries preserved

The implementation does not alter:

- AES-GCM, key exchange, Cipher identity, or canonical 5-bit values;
- `script.base-runes` ordering or existing encode/decode results;
- legacy message, Cipher, or package readers;
- current legacy-only outbound behavior;
- navigation ownership or the one-UI-module rule;
- Progression evaluation authority;
- the permanent Norse fallback.

Theme resources affect presentation only. The common renderer receives verified bytes
and semantic contracts; providers never receive plaintext, message, Cipher, Contact,
network, or raw platform-adapter access.

## Verification ledger

The final regression pass below includes the initial-Theme readiness barrier,
startup-query lifecycle rule, persistent font-registration fix, responsive header,
and Dynamic Type-safe Appearance row.

| Gate | Current evidence | Status |
|---|---|---|
| Complete Swift package suite | 725 XCTest cases plus 89 Swift Testing tests, 814 total | PASS, zero failures |
| Integrated architecture subset | Included in the final 814-test complete-suite run; earlier focused run: 127 tests | PASS |
| Opaque-resource cache subset | Included in the final complete-suite run; focused run: 17 tests | PASS |
| Theme Coordinator subset | Included in the final complete-suite run; focused run: 6 tests | PASS |
| Norse Base module subset | Included in the final complete-suite run; focused run: 9 tests | PASS |
| Contribution and opaque registries | Included in the final complete-suite run; focused run: 24 tests | PASS |
| Runtime startup-query semantics | Focused run: 3 of 3 tests | PASS after startup delta |
| Initial Theme readiness barrier | Focused run: 1 of 1 test | PASS after startup delta |
| Platform font-registration adapter | Focused run: 2 of 2 tests | PASS after persistent-cache delta |
| UI Module target build | Focused Swift build | PASS after startup delta |
| Architecture guard | `check-architecture.sh`; all ratchets within bounds, including host physical lines 300 of 300 | PASS |
| Roadmap alignment guard | `check-roadmap-alignment.sh`; 92 tasks and 12 decisions | PASS |
| macOS Release build | Signed Release product at `/tmp/runescribe-theme-final-signed-macos-20260815/Build/Products/Release/RuneScrib.app` | PASS |
| iOS Simulator Release build | Signed Release product at `/tmp/runescribe-theme-final-signed-ios-20260815/Build/Products/Release-iphonesimulator/RuneScrib.app` | PASS |
| Shipping-product inspection | Fresh signed products: 74 of 74 checks | PASS; T-028 passed |
| iPhone exact-parity UI test | iPhone 17 Pro, iOS 26.2 Simulator: 1 of 1 | PASS; `/tmp/runescribe-theme-parity-status-copy-iphone.xcresult` |
| iPad exact-parity UI test | iPad Pro 13-inch (M5), iOS 26.2 Simulator: 1 of 1 | PASS; `/tmp/runescribe-theme-parity-status-copy-ipad.xcresult` |
| Prohibited-attribution phrase audit | Report, changed content, changed paths, branch, and contextual attribution scan | PASS |
| Whitespace/error-marker check | Tracked, cached, and untracked-file checks | PASS |

The green Phase A/B regression ledger is not permission to begin Phase C. Phase C
remains blocked independently by DEV-ELVEN-001 through DEV-ELVEN-009.

## Visual and device evidence

- Package reference images were inspected as non-shipping design inputs. They were not
  cropped, traced, transformed, or imported into application resources.
- No formal Elven before/after screenshot set exists because no Elven production UI or
  asset was implemented.
- Fresh iPhone 17 Pro and iPad Pro 13-inch (M5) Simulator parity runs each passed the
  complete primary-product flow and accessibility audit, one test of one.
- No physical-device session was performed for this implementation. Font registration,
  share/import presentation, memory pressure, and device-only accessibility behavior
  therefore remain pending physical-device evidence.
- Physical-device evidence is not the sole remaining package boundary. Nine design
  deviations and all Phase C through Phase G production work remain outstanding.

## Changed-file inventory

The Phase A/B implementation is contained in these repository scopes:

- package graph: `Packages/RuneScribeArchitecture/Package.swift`;
- contracts: `RuneScribeContracts/ThemeContracts.swift`,
  `ThemeCoordinatorContracts.swift`, `Identifiers.swift`,
  `RuntimePolicyVocabulary.swift`, and `RuntimeSettingsContracts.swift`;
- runtime foundation: `RuneScribeRuntimeCore/RuntimeContributionRegistry.swift`,
  `RuntimeOpaqueResourceRegistry.swift`, `RuntimeThemeContribution.swift`,
  `RuntimeThemeEndpoints.swift`, plus manifest, policy, service, availability,
  settings, dispatcher, and lifecycle integration files;
- required Base provider: the complete
  `Sources/RuneScribeNorseThemeModule` target and its owner-scoped resources;
- app-owned Coordinator: the complete
  `Sources/RuneScribeThemeCoordinatorModule` target and manifest;
- common UI: `RuneScribeUIModule/UIModule.swift`, its manifest, session/models,
  semantic presentation, Appearance Settings, and affected common views;
- common presentation runtime: `RuntimeApplicationResourcePresentation.swift` and
  `RuntimeThemeVectorText.swift`;
- host and build composition: `RuneScribeRuntimeComposition.swift`, `project.yml`,
  `RuneScrib.xcodeproj/project.pbxproj`, and the parameterized background shader;
- verification: Theme contract, registry, integration, Norse, Coordinator, semantic
  UI, session, cache, parity UI, and manifest-validation tests under
  `Packages/RuneScribeArchitecture/Tests` and `RuneScribIOSUITests`;
- guards and roadmap evidence: `scripts/check-architecture.sh`,
  `scripts/architecture-ratchet.json`, `scripts/check-shipping-products.sh`,
  `docs/architecture/RoadmapAlignment.md`, and
  `docs/verification/roadmap-alignment.json`;
- deviation and implementation evidence: this report and
  `docs/verification/ElvenSeriesBlockingDeviationReport.md`.

No file from the Elven source-master or concept-reference trees is present in a
shipping target.

## Final criterion audit

| Criterion | Result | Evidence or disposition |
|---|---|---|
| Generic Theme scaffold | PASS | THM-001 through THM-012 satisfied; runtime-owned contracts, registries, Coordinator, common UI, and conformance suite implemented |
| Norse Base prerequisite | PASS | Required provider, exact Script mapping, exact font bytes, 42 verified resources, permanent fallback |
| Four Elven providers | BLOCKED | Phase D cannot begin before Phase C and DEV-ELVEN-003 through DEV-ELVEN-009 disposition |
| Stable Elven IDs | PASS | DEV-ELVEN-001 and DEV-ELVEN-002 resolved in the remediation ledger |
| Elven production resources and budgets | BLOCKED | DEV-ELVEN-003 through DEV-ELVEN-009 |
| Elven fonts and source fidelity | BLOCKED | Production source work is not authorized |
| Elven Progression gates | PASS | Identifier mappings and Future Theme Binding authority are recorded |
| Themed share/receive integration | BLOCKED | No Phase F change; outbound policy remains frozen |
| Automated final regression evidence | PASS | 814 package tests, both Release builds, both parity runs, both static guards, and 74 shipping checks passed |
| Physical-device evidence | PENDING | No physical-device run; not the sole remaining boundary |
| Zero unresolved findings | FAIL | DEV-ELVEN-003 through DEV-ELVEN-009 remain open |
| Overall package delivery | **FAIL / BLOCKED** | Phase A/B pass does not satisfy Phase C through Phase G or resolve the deviation report |

## Required next authority

Production Elven work can resume only after an authoritative, traceable disposition
for every remaining finding DEV-ELVEN-003 through DEV-ELVEN-009. DEV-ELVEN-001 and
DEV-ELVEN-002 already have recorded mappings and binding authority. Remaining
dispositions must correct or explicitly amend the controlling inputs; they cannot be
represented by a silent topology change, asset normalization, or test exception.
After that disposition, implementation must restart at Phase C and repeat all earlier
Phase A/B gates before advancing.
