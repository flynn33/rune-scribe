# Rune Scribe Migration Decisions

> **Historical decision record:** Migration facts and compatibility anchors remain evidence,
> but conflicting architecture conclusions are superseded by the
> [controlling Forsetti policy](FORSETTI_CONTROLLING_POLICY.md). The current application is
> version 1.0.38 build 38. Hardware-only classifications in this historical record are
> owner-operated optional observations outside Agent Coding scope and have no acceptance,
> completion, blocker, residual-work, PASS/FAIL, or pull-request-readiness effect. In
> particular, provider-object retention, raw platform-adapter retention, lookup-time
> authorization, and any external dependency direction are not current guidance.

## Record scope

These decisions describe the migration from the pre-architecture Rune Scribe application to committed cleanup snapshot `01e2fcf655a3139a856787fc96f17a58db3f3ad0`. P7 implementation commit `49a8cee0077939de100d6da7405c980d7a31163f` is retained here only as the historical phase boundary that preceded the committed cleanup. The decisions supplement the source-level ledgers:

- [`ForsettiMigrationBaseline.md`](../verification/ForsettiMigrationBaseline.md)
- [`ForsettiMigrationReconciliation.json`](../verification/ForsettiMigrationReconciliation.json)
- [`ForsettiTestReconciliation.json`](../verification/ForsettiTestReconciliation.json)
- [`feature-parity-matrix.json`](../verification/feature-parity-matrix.json)
- [`p7-test-matrix.json`](../verification/p7-test-matrix.json)

These decisions preserve the historical P8 current-shipping-state evidence. The
hash-locked Codex documents and the records in [`decisions`](decisions/README.md) govern
only nonconflicting product requirements, compatibility anchors, and sequencing
evidence. The controlling policy and current roadmap ledger govern architecture and
dependency direction without changing what the P8 evidence proved at its recorded
snapshot.

## ADR-001: Reconcile the live repository before moving ownership

**Context.** The implementation package was prepared from source commit `793f275b86ef16aa3d2606318cccd9714b7af95e`, while the local preflight HEAD was `2d3d371e51d95ff4c8d9b6dd9e55465176f986d6`. Forcing the working repository back to the package snapshot would have discarded newer behavior and tests.

**Decision.** Treat the local repository as implementation source of truth and use the package inventory only as the comparison baseline. P0 recorded:

- no removed or renamed application, test, configuration, or resource path relative to the package baseline;
- 9 changed application files and 303 additional application lines;
- 22 local test files and 148 source-defined tests versus 21 files and 126 tests in the package baseline;
- unchanged resource bytes;
- the newer local version `1.0.33` (`33`) retained instead of the package snapshot's `1.0.29` (`29`), with bundle identity, deployment targets, Swift mode, and transport identifiers otherwise preserved.

The newer behaviors retained as migration contracts were unified cold/warm inbound routing, visible typed failures for unreadable or unrecognized files, first-delivery Messages attachment acceptance and cleanup, tappable cipher-link sharing distinct from explicit file export, and the 30-day splash schedule.

**Consequences.** P0 added frozen compatibility fixtures and corrected generated-project test membership before migration. The final reconciliation contains 63 package entries plus 26 P0 local-delta entries, all terminal. The original-test ledger contains 157 methods: 78 remain in their owning target and 79 map to tested equivalents, with none pending.

**Evidence.** [`ForsettiMigrationBaseline.md`](../verification/ForsettiMigrationBaseline.md), `P7-MIGRATION-RECONCILIATION-FINAL`, and `P7-TEST-RECONCILIATION-FINAL` in [`p7-test-matrix.json`](../verification/p7-test-matrix.json).

## ADR-002: Use one app-owned local package with six shipping products

**Context.** Physical targets were needed to make forbidden implementation edges compile-time failures. A local Swift package was viable on the supported macOS 15/iOS 17 and Swift 6 toolchain.

**Decision.** Adopt the preferred local-package layout at [`Packages/RuneScribeArchitecture`](../../Packages/RuneScribeArchitecture) with six one-target shipping library products:

```text
RuneScribeContracts
RuneScribeRuntimeCore
RuneScribeUIRuntime
RuneScribePlatform
RuneScribeCoreModule
RuneScribeUIModule
```

The committed package also declares `RuneScribeTestSupport` as a seventh, explicitly test-only product. It contains reusable deterministic implementations of neutral contracts and depends only on Contracts.

`project.yml` is authoritative and both shipping app targets link exactly the six shipping products. Only package and hosted test targets consume Test Support, and built-product guards require its absence from application linkage and binaries. The generated Xcode project remains committed. The architecture package declares no remote or local third-party dependency.

**Consequences.** Imports enforce the Pattern B graph. Core, UI, and Platform cannot import each other. The hosts may see all six shipping products solely to compose factories, adapters, runtime, and the neutral root shell. Test doubles no longer enlarge the shipping Platform API. Package tests align with the target that owns each behavior.

**Evidence.** [`Package.swift`](../../Packages/RuneScribeArchitecture/Package.swift), [`project.yml`](../../project.yml), [`ModuleGraph.md`](ModuleGraph.md), `T-011`/`T-024` in the phase ledger, the 17-of-17 architecture result under `/tmp/RuneScribe-P8-final-package.yGz7qs`, and the 50-of-50 shipping result under `/tmp/RuneScribe-P8-release-final.XsJS4P`.

## ADR-003: Superseded transitional-runtime direction

**Context.** At the P8 snapshot, this record treated the app-owned runtime as temporary.

**Superseded decision.** The former external-release direction is not current guidance.
The replacement keeps the runtime app-owned permanently and prohibits external
Forsetti packages, binaries, source copies, submodules, fetch scripts, and local
checkout paths. Required capabilities are implemented within Rune Scribe.

**Consequences.** The recorded shipping build remains app-owned and Apple-only. That
fact and its test evidence remain historical evidence; the conditional dependency path
is removed.

**Evidence.** [`check-architecture.sh`](../../scripts/check-architecture.sh), [`architecture-ratchet.json`](../../scripts/architecture-ratchet.json), and `T-010` in the P7 ledger.

## ADR-004: Isolate mutable services inside runtime scope

**Context.** The pre-migration application used observable global managers and direct environment access. Those patterns made ownership implicit and could cross module boundaries.

**Decision.** The host owns one composition object and concrete Platform adapters. `RuneScribeRuntime` owns the service registry and creates one leased `ModuleContext` per activated module. Core resolves only neutral adapter protocols, constructs an actor-backed `RuneScribeCoreApplicationService`, and publishes that facade plus the inbound-input service. UI resolves the facade into one `@MainActor` `RuneScribeUISession`.

Service access is default deny: descriptor declaration, known capability, role allowance, policy mapping, lifecycle state, registration presence, and runtime type must all agree. Module stop revokes its context and removes its services.

**Consequences.** No app-owned `.shared` declaration or legacy manager singleton reference remains in production. UI never receives a key-bearing cipher or repository. Platform adapters have no product orchestration. Tests substitute adapters from [`RuneScribeTestSupport`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeTestSupport) without mutating global application state or exporting those adapters from Platform.

**Evidence.** [`RuneScribeRuntimeComposition.swift`](../../RuneScrib/AppHost/RuneScribeRuntimeComposition.swift), [`Services.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Services.swift), [`RuneScribeCoreApplicationService.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Application/RuneScribeCoreApplicationService.swift), and `T-007`/`T-012`.

## ADR-005: Buffer host input through one bounded, ordered rail

**Context.** AppKit, UIKit, SwiftUI scenes, user activities, document opens, lifecycle callbacks, and menu commands can arrive before Core activation or while activation and shutdown race. Dropping or reordering cold-start input would break compatibility and app-lock behavior.

**Decision.** Convert every host callback to `RuneScribeInboundInput` immediately and synchronously submit it to one `@MainActor` `SerialInboundInputForwarder`. The forwarder retains FIFO order before service attachment, permits one destination, bounds metadata, caps its queue at 512, reserves control/security capacity, and reports rejection/failure. After runtime start, the host resolves only `RuneScribeInboundInputService`, attaches it, and flushes.

Core applies a second bounded queue, input-ID and content/path deduplication, presentation-aware data pausing, and a dedicated control lane so background locking is not delayed by data imports.

**Consequences.** Cold and warm file/URL paths share one Core validation route. Detach waits for an in-flight receive and releases the old service handle; queued later input is retained for a subsequent activation. There is no legacy singleton router or dual delivery path.

**Evidence.** [`SerialInboundInputForwarder.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/SerialInboundInputForwarder.swift), [`AppDelegate.swift`](../../RuneScrib/AppHost/AppDelegate.swift), [`RuneScribApp.swift`](../../RuneScrib/AppHost/RuneScribApp.swift), `T-006`, `T-014`, and `T-023`.

## ADR-006: Keep shipping resources in application targets

**Context.** Asset catalogs, an approximately 8 MB splash video, the runic font/license, and Metal compilation already depended on application-bundle membership. Moving them into a package risked changing lookup, app size, launch, or platform behavior.

**Decision.** Keep the asset catalog, bundled font/license, splash video, and Metal shader under [`RuneScrib`](../../RuneScrib) and include them in both app targets through `project.yml`. Register `BundleApplicationResourceLocator(bundle: .main)` at composition. Core and UI ask for stable `ApplicationResource` handles. Keep each module manifest as a processed resource of its owning package target.

**Consequences.** Package code does not assume `Bundle.main`; the host explicitly identifies the shipping resource owner. Core validates/registers the font through contracts, UI resolves splash and Metal URLs, and built-product checks can verify exact membership on both platforms.

**Evidence.** [`BundleApplicationResourceLocator.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/Resources/BundleApplicationResourceLocator.swift), [`PlatformContracts.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/PlatformContracts.swift), `T-019`, and the current 50-of-50 Release inspection at `/tmp/RuneScribe-P8-release-final.XsJS4P/shipping-products-50-of-50.log`.

## ADR-007: Preserve data and wire compatibility as fixed anchors

**Context.** Architectural ownership could change without invalidating existing ciphers, contacts, imported fonts, PINs, links, files, or messages. Regenerating formats or identifiers would silently strand user data.

**Decision.** Freeze and test the following anchors:

| Area | Preserved anchor |
|---|---|
| App identity | bundle `com.runescribe.app`; version `1.0.33` build `33`; macOS 15/iOS 17 |
| Keychain | service `com.runescribe.keystore`; accounts `symmetricKey`, `cipherLibrary`, `appPin`, `pinThrottle`; `whenUnlockedThisDeviceOnly`; delete-then-add writes |
| Cipher storage | schema 1, ISO-8601 JSON, AES-GCM combined representation, active selection, unchanged existing-install loading |
| Contacts | `RuneScribContacts/contacts.enc`; version-1 deferred-date JSON encrypted with the existing symmetric key; atomic protected writes |
| Fonts | `RuneScribFonts/<sha256>.ttf`; bundled ID `noto-sans-runic`, version 1, digest `615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b` |
| PIN | exactly four ASCII digits; record version 1; 16-byte salt; PBKDF2-HMAC-SHA256, 120,000 iterations, 32-byte result; persisted throttle from attempt 5 with 15/30/60/120/300-second delays |
| Cipher wire | compact version 3, fixed 129-byte golden fixture, exact re-encode |
| Message wire | version 1, fixed 151-byte golden fixture, exact re-encode |
| Routing | `runescribe://import`; legacy `https://[www.]ravenforgesoftware.com/rune-scribe/import`; UTI `com.runescribe.runescribe`; `.runescribe` extension |
| Splash | preference `rf.splash.lastShownAt`; 30-day replay interval |

Core owns format parsing, encryption, state, and migration decisions; Platform owns only secure storage and file mechanics. Corruption, truncation, trailing bytes, invalid routes, hash mismatches, and unreadable input fail closed with safe typed outcomes.

**Consequences.** Existing stores load without opportunistic rewrite. Deliberate new mutations use the same identifiers and formats. Compatibility changes require a separate explicit decision and replacement fixtures.

**Evidence.** [`ForsettiMigrationBaseline.md`](../verification/ForsettiMigrationBaseline.md), [`WireCompatibilityTests.swift`](../../Packages/RuneScribeArchitecture/Tests/RuneScribeCoreModuleTests/Domain/WireCompatibilityTests.swift), [`CipherPersistenceApplicationTests.swift`](../../Packages/RuneScribeArchitecture/Tests/RuneScribeCoreModuleTests/Domain/CipherPersistenceApplicationTests.swift), [`ContactRepositoryTests.swift`](../../Packages/RuneScribeArchitecture/Tests/RuneScribeCoreModuleTests/Contacts/ContactRepositoryTests.swift), and `T-015` through `T-019`.

## ADR-008: Close singleton and notification coordination

**Context.** `KeyManager`, `ContactManager`, `ImportCoordinator`, `MessageCoordinator`, `KeychainService`, `ContactStore`, `FontStore`, and app-lock paths previously mixed global observation, persistence, and orchestration. App-specific `NotificationCenter` channels could bypass typed boundaries.

**Decision.** Split those responsibilities into:

- Core actors/services for cipher, contact, font, import, message, share-lifetime, and lock policy;
- Platform adapters for Keychain, files, Contacts, fonts, resources, clipboard, time, and UUIDs;
- one UI-owned observable session for navigation and presentation;
- runtime services and typed streams for cross-boundary coordination.

Delete application-specific notification names and post/publisher flows. Retain only the local `AVPlayerItem.didPlayToEndTimeNotification` observer inside runtime application-resource presentation, paired with removal in the same type.

**Consequences.** The architecture ratchet requires zero app-owned singleton declarations, zero named legacy singleton references, zero feature notification calls, zero application-specific notification names, and zero unexpected `NotificationCenter` uses. Its only notification allowance is the two local media observer calls.

**Evidence.** [`architecture-ratchet.json`](../../scripts/architecture-ratchet.json), [`check-architecture.sh`](../../scripts/check-architecture.sh), [`RuntimeApplicationResourcePresentation.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeApplicationResourcePresentation.swift), `T-012`, and `T-013`.

## ADR-009: Remove migration bridges before architecture closure

**Context.** Temporary adapters were acceptable only while keeping intermediate migration commits buildable. Leaving an old and new route active would create split ownership, duplicate writes, and inconsistent lifecycle behavior.

**Decision.** Remove the monolithic application source path, observable-manager environment bridges, legacy inbound router access, host-to-concrete-Core access, application-session adapters, and dual routing before P7. Shipping app targets now compile only `RuneScrib/AppHost`, resources, and the Metal shader. The ratchet requires:

- `monolithicAppTargets = 0`;
- `temporaryApplicationSessionAdapters = 0`;
- `hostLegacyBoundaryReferences = 0`;
- `hostRuntimeBypassReferences = 0`.

No dual-write persistence path remains. Compatibility is achieved by preserving identifiers and byte formats in the new owning repositories, not by writing old and new stores in parallel.

**Consequences.** The only observable application session is UI-owned, the only production application facade is Core-owned and runtime-published, and the host never constructs or retains the concrete Core service. All 89 migration entries have a terminal ownership/disposition.

The committed cleanup removed `RuneScribePlatformBoundary`; the unused `EntitlementProviding`, `AllowAllEntitlements`, and `ManifestEligibilityProvider` layer; `SemanticVersionRange`; the public `AppleKeychainStore` methods `dataSynchronously`, `setSynchronously`, and `deleteSynchronously`; and the duplicate UI surfaces `RuneScribeUIContributingModule`, `makeRootView()`, and `rootContribution()`. `AppleKeychainStore` now exposes only its async `SecureValueStore` surface. `ModuleEligibilityProviding` is the sole eligibility seam. The UI factory creates a fresh module lazily, and `start(context:)` is the sole production path that creates and presents its root contribution. Deterministic adapters moved out of Platform into the test-only support product.

**Evidence.** [`ForsettiMigrationReconciliation.json`](../verification/ForsettiMigrationReconciliation.json), [`Package.swift`](../../Packages/RuneScribeArchitecture/Package.swift), [`project.yml`](../../project.yml), `T-011`, `T-012`, and `T-014`.

## ADR-010: Use opaque, completion-bound share artifacts

**Context.** Cipher sharing can carry key-bearing content. Exposing link contents or retaining temporary files beyond presentation would enlarge the UI contract and leave sensitive artifacts alive after lock, cancellation, or shutdown.

**Decision.** Core constructs payloads and owns lifetime policy through `ShareArtifactRegistry`. Platform owns safe temporary paths and an opaque link lease. Contracts expose only an artifact ID, scoped file URL or opaque reference, display metadata, lifetime, and completion outcome. UI presentation reports one terminal outcome; Core decides release, delivery recording, or retry retention. Stop revokes all leases before new preparation is allowed on restart.

**Consequences.** Key-bearing link URLs do not enter snapshots, events, logs, or Codable DTO fields. App lock cancels and cleans UI presentation state without bypassing Core completion. Required Messages attachments fail closed and first delivery is recorded only after the required attachment was accepted and the message was sent.

**Evidence.** [`ShareArtifactRegistry.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Messages/ShareArtifactRegistry.swift), [`RuntimeSharePresentation.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeSharePresentation.swift), [`RuntimeMessageComposeView.swift`](../../Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeMessageComposeView.swift), `T-027`, and the native-share records in the P7 ledger.

## Resulting migration closure

At committed cleanup snapshot `01e2fcf655a3139a856787fc96f17a58db3f3ad0`:

- 89 of 89 source/configuration/resource migration entries are terminal;
- 157 of 157 P0 original/local-delta test methods are preserved or mapped to a passing equivalent;
- 33 feature-parity items pass automated or automated-plus-manual local evidence;
- 7 feature-parity items remain explicitly assigned to physical-device validation;
- no migration entry, replacement test, or non-device parity item is pending;
- at that snapshot, no external Forsetti dependency, direct implementation edge, app-owned boundary singleton, cross-module notification channel, or temporary application-session bridge remained;
- the package suite passes 283 of 283 tests and the architecture ratchet passes 17 of 17 checks under `/tmp/RuneScribe-P8-final-package.yGz7qs`;
- two generated-project passes produce committed `RuneScrib.xcodeproj/project.pbxproj` SHA-256 `5fcafb2ffd877311dd1ea973f58526036e7af543e6e6ff45d36b1a80beb56a30`;
- the current Release inspection passes 50 of 50 checks under `/tmp/RuneScribe-P8-release-final.XsJS4P`;
- cleanup and negative-mutation evidence under `/tmp/RuneScribe-P8-cleanup.bxBuUN` and `/tmp/RuneScribe-P8-guard-audit.4gkAfP` confirms that shipping-source, generated-project, and Test Support dependency drift is rejected.

The architecture and its extension constraints are summarized in [`ForsettiCompliance.md`](ForsettiCompliance.md), [`ModuleGraph.md`](ModuleGraph.md), and [`ContractsAndCapabilities.md`](ContractsAndCapabilities.md).
