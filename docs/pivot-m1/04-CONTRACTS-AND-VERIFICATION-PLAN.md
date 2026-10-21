> Historical M1 discovery snapshot, captured 2026-10-21 against source d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54. Permissions and unexecuted-check statements below describe that completed run. The subsequent owner instruction authorizes documentation publication, Xcode documentation references and unsigned build verification only. Application implementation, Store changes and release remain outside this publication. See [publication scope and portability](README.md).

# RS-PIVOT-M1 — contract readiness and verification plan

Source target: clean main, d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54. All tests and native qualification below are proposed for a later authorized implementation. None ran in M1.

## Actual contract and authority inventory

SHA-256 values for the named local authority/API/config inputs are in [contract-source-identities.json](contract-source-identities.json), normalized from the original absolute source bindings. Remaining tracked manifests, capability plists and generated-project identities are in [source-baseline-start.json](README.md#evidence-and-portability). No source review status is inferred from a filename or hash.

| Authority / contract | Identity and actual provenance | Readiness / required treatment |
|---|---|---|
| APPROVAL-PIVOT-001 | Owner approval in package record §5.1 and retrieved chat turn [private approval-conversation identifier omitted] | Approved product outcome and bounded retirement; implementation/publication remain absent |
| Prepared Project Record | planning draft 0.4; SHA-256 49c823e7ab12593f05614dfc2ddd5104c0483c7bcf87029e348d57fc91e66dff | Prepared local package copy; authoritative route/revision not established; return proposed delta only |
| M1 TASK-CONTRACT.json revision 1.0 | official_system_realization_contract=false | Governs this read-only task; no source realization review/acceptance |
| Historic adopted playbook binding | No actual product-specific pin located by bounded workspace/repository/Page/chat retrieval | Unresolved; preserve an existing pin if recovered, never silently upgrade |
| Inspected Raven Forge Development | 0.7.4 at d3d40076e1bc21201e23628058b3907dc4443e51 | Reference only; intake receipt provides inherited 19-document coverage |
| System Realization Execution Block | Same immutable method commit; blob dd92b4fb6db534d28de8217cc67b32748a68e26f; fetched/read in M1 | Future issuance/preflight/delivery obligations, not executed now |
| Development Diagnostics policy | Same immutable method commit; blob c10bacff2384f7ab9803d2672904e3e555e1bf6e; fetched/read in M1 | Deliberate adoption in existing products remains subject to actual binding; M1 package independently requests diagnostic planning |
| Reviewed pivot System Realization Contract set | Not located in searched sources; no reviewer/acceptance receipt, linked set ID, selected profile IDs/hashes or immutable upstream authority roles supplied | Missing. No declaration of accepted design or implementation readiness |
| Repository controlling policy | docs/architecture/FORSETTI_CONTROLLING_POLICY.md; SHA-256 2e7c3729d51724929838269d29c71bb2dd92caa4976167cb4275f9ece6d55db6 | Current source authority, overridden where owner explicitly changed product scope; Theme test completed-Progression-gate clause needs focused amendment |
| Source API contracts | ProgressionContracts.swift, ThemeCoordinatorContracts.swift, ExistingUserMigrationContracts.swift, ShareCompletionContracts.swift | Real typed interfaces, not reviewed System Realization Contracts; preserve compatibility/security/lifecycle while replacing earned-only licensing |
| Future-theme-binding JSON | contractID runescribe.progression.future-theme-binding; version 2 although filename v1.0; status label approved | Existing source catalog binding; no independent pivot review receipt found. Gate-rule entries stale under approved pivot; preserve five module IDs, entitlement IDs, optional isolation and free-reading rule |
| ADR-RS-008 | Status text Accepted; local-first persistence/private-cloud implemented; SHA-256 ffdac018d373a117512c4a95bbb40e0cd90685cc34b477853b8a8bc1b8e73025 | Existing decision with source-specific boundaries, not current pivot acceptance. Preserve integrity, replay/quarantine and privacy; amend retired active progression/merge scope |
| ADR-RS-011 | Status text Accepted; source catalog/shared-platform strategy frozen; SHA-256 b58a3e932212f226856ca59fef5d072c2dbc7f99a033d980f3fd04afa8e56f6e | Superseded target behavior by owner removal. Actual Apple record relationships remain unverified |
| Native dependency/resource contracts | Package.swift; project.yml; generated project.pbxproj; manifests; Config entitlement plists; architecture-ratchet.json | Both hosts explicitly link progression/cloud/Game Center and all five providers. Amend source/generator/generated graph and guards together only in authorized implementation |
| Customer-facing contracts | README, PRIVACY, SUPPORT, APP_STORE_SUBMISSION, EULA | Privacy §§optional Apple services/retention and support GC/sync copy need synchronized later amendment. Read EULA historical purchase wording before narrowing rights; no live policy/store edits now |

The policy states no historical instruction package currently controls product acceptance; retained package records are verification history. Accordingly no historic package or an “approved” JSON label was promoted to current review authority.

No APS, Aeostara, Windows, upstream Forsetti runtime or new governance runtime/profile is selected. All external Forsetti package/binary/source/submodule/fetch/local-path acquisitions remain prohibited. A general method catalog is not a dependency permission.

## Amendments to prepare for review

1. Replace Progression-earned-only content authority with a runtime-mediated, provenance-aware free/legacy/series ownership contract; bind every item from 02, including old mastery items. Preserve distinct provider module identities, runtime lifecycle/resource checks and purpose-specific inbound access.
2. Specify original-paid-app qualification from actual distribution evidence; single product identity, original transaction fields, offline/reinstall recovery, independent rights/revocation and account-switch treatment. No chosen cutoff/product ID/family or platform sharing promise is supplied by M1.
3. Separate retained cipher-library/share-terminal/relationship compatibility from retired earning, reveal/statistics, Game Center and progression-sync work. Define dormant queue barriers and old-cloud replay behavior. Retain/review selected-Codex preference synchronization separately.
4. Revise policy Theme clause, manifests/capabilities, UI/pickers/settings, source catalogs/ADRs, exact module lists in guards, generator/generated project, native target/resource references and public copy. Removal must tighten remaining guard guarantees rather than deleting their tests.
5. Bind diagnostics, export and release composition to reviewed scope. Record new compatibility/migration schema, rollback/read-back evidence and fault fixtures before an implementation package is issued.

All five are proposed amendments, not accepted contracts or product edits.

## Current diagnostic facility: observed source

Source paths below share Packages/RuneScribeArchitecture/Sources/ at the bound commit.

| Interface / capture / consumer | Observed behavior | Gap or retained obligation |
|---|---|---|
| RuneScribeContracts/ProgressionContracts.swift:1888–1940, ProgressionDiagnosticsSummaryDTO | Codable typed bounded health/catalog/schema/count/hash/error summary; max categories 32, hashes16, errors32 | Snapshot contract, not a purchase/migration event collector |
| RuneScribeProgressionModule/ProgressionServiceActor.swift:1131–1143 → ProgressionSnapshotBuilder.swift:285–362 | Reads repository health/quarantine diagnostics, groups logical counts and catalog hashes; pendingOutboxCount is explicitly zero in builder | Do not represent this literal as measured runtime/GC outbox emptiness |
| RuneScribeRuntimeCore/RuntimeProgressionEndpoints.swift:157–164 | progression.diagnostics.summary query protected by progressionStateRead capability | Preserve useful health semantics if active Progression endpoint retires |
| RuneScribeContracts/ThemeCoordinatorContracts.swift:454–541; ThemeCoordinatorService.swift:679–723 | Bounded provider acceptance/resource/fallback diagnostics and latest reconciled snapshot | Preserve distinctions between ownership, provider failure, required base failure and safe fallback |
| RuneScribeRuntimeCore/RuntimeThemeEndpoints.swift:137–168; RuntimeEnvironment.swift:16–81 | Theme query closure captures permitsThemeDiagnostics; false by default and in .live; endpoint throws disabled when false | A Boolean access gate is not a demonstrated development/release collector replacement |
| RuneScribeRuntimeCore/ManifestDecoder.swift:320–324 | Rejects diagnosticsVisibleInProduction=true | Existing resource/security rule; do not bypass it to add invasive production capture |
| RuneScribePlatform/Storage/AppleSQLiteModuleStateStore.swift:707–735,952–1053 | Schema metadata/records carry diagnostic codes, load health and quarantine state | Protected module-state diagnostics, not a standalone durable incident log/export |
| RuneScrib/AppHost/RuneScribeRuntimeComposition.swift:33–35,77–90 | Exposes runtime ingress snapshot/failure and maps input failure to bounded notice | Preserve actionable ingress failures without logging user data |

Searches of production Sources and RuneScrib Swift files for Logger/OSLog/logevent and diagnostic-export entry points found no general collector or paired product JSON/Markdown exporter. No dedicated development/release collector selection, public diagnostic-export schema/action, quota/rotation/overflow implementation or release replacement was located in those searched paths. This is bounded source evidence; M1 did not run or inspect app data to claim runtime absence. These external M1 JSON/Markdown reports are not product diagnostic exports.

Existing tests read: ProgressionContractSafetyTests.testDiagnosticsAreBoundedTypedAndContainNoRawTokenFields (637–732) exercises typed bounds, roundtrip, unknown raw-event rejection and forbidden field names; ThemeCoordinatorConformanceTests.testDiagnosticsEndpointIsDeniedInProductionAndEnabledByDebugGate (964–989) checks endpoint gating. They are source evidence only, unexecuted in M1.

## Proposed diagnostic foundation and verification

For a later authorized slice, reuse the runtime's typed operation/lifecycle boundaries and neutral Contracts surface. Propose one narrow product-owned diagnostic interface and substitutable development/release implementations selected at composition/build time. It must not introduce another UI module, peer implementation calls, external backend or new dependency by implication.

Development capture should cover ownership evidence state and reason (without original transaction/account values), purchase/restore outcome classes, independent provenance changes, cache age classification, migration version/stage/commit/read-back/retry, provider reconciliation, safe fallback and retirement work scheduling. Use synthetic fixture references, bounded counts, typed errors, UTC and monotonic sequence, operation/correlation IDs, build/source/profile/export schema and explicit dropped/unavailable coverage. Never persist raw receipts/JWS, keys, PINs, cipher/package/message contents, full deep links, account/contact identifiers or private paths. Redact before storage and recheck exports.

Review a bounded protected local store, overflow/retention policy and user-invoked offline export of one consistent snapshot to paired JSON/Markdown. Commit/export failure must report incomplete output, not success. Lightweight release diagnostics must preserve actionable faults/export while development collectors/resources are excluded from the actual release artifact; a runtime level toggle is insufficient.

| Proposed named check | Required counterexample / result | Route / evidence |
|---|---|---|
| DiagnosticControlledMigrationFailure | Synthetic interrupted migration reconstructs expected vs actual stage and recovery; same bundle/events in JSON and Markdown | New focused contract/runtime tests; retained pair and schema |
| DiagnosticSecretCanaries | Nested synthetic receipt/key/PIN/contact/URL canaries absent before durable storage and after both exports | New fake store/export tests, bytes inspected |
| DiagnosticConcurrentExportAndOverflow | Snapshot stable during concurrent capture; quotas/drop/truncation explicit | New deterministic collector tests |
| DiagnosticHalfExportAndDiskFailure | One failed format/part yields incomplete status, preserves original product failure, bounded fallback | Injected store/encoder/export failures |
| DiagnosticReleaseReplacement | Release selects minimal implementation; invasive collector/resources absent and cannot be re-enabled; business/authorization unchanged | Later source/config AND actual release artifact/runtime inspection |
| DiagnosticOwnershipTransitions | Pending/unverified/legacy/series/refund/account/retry reasons distinguish unknown from non-owner without secret identifiers | New synthetic ownership fixtures and native StoreKit scenarios |

These are planning names, not existing tests or selected implementation names.

## Host and simulator feasibility

Measured host is macOS27.0.1 arm64/Xcode27.0; SDK27.0. iOS26.5 and27.0 iPhone/iPad simulator destinations are available and shut down. Use only a fresh synthetic test container/fixture during later authorization; never reuse actual customer stores or enable live Game Center/CloudKit to prove their removal.

| Proposed layer | Real entry point inspected | Coverage / acceptance and limits |
|---|---|---|
| Static contracts/architecture | scripts/check-architecture.sh; architecture-ratchet.json; Package.swift; source manifests/config | Update exact required product/module/import/capability lists deliberately. Preserve one UI, default-deny, resource membership and external-Forsetti exclusion. M1 did not invoke the guard |
| Deterministic package regression | swift test --package-path Packages/RuneScribeArchitecture | Existing typed/in-memory suites plus focused new ownership, migration and retired-task fakes. No current pass claimed |
| Native macOS | RuneScrib-macOS scheme: RuneScribTests, RuneScribArchitectureTests, RuneScribMacAppUITests; macOS parity scheme | Host metadata supports planning. Verify fresh free/upgrade/restore/selection/share/Core flows on synthetic data; no run in M1 |
| Native iPhone | RuneScrib-iOS / RuneScrib-iOS-Parity, available iPhone destinations | iOS26.5 and27.0 ordinary and fault/size/accessibility/share workflows; local StoreKit fixture when separately authorized |
| Native iPad | Same iOS schemes, available iPad destinations | Split/window/layout and same complete ownership matrix. Do not infer iPad from iPhone results |
| Minimum supported OS | Package/project say iOS17/macOS15 | Corresponding minimum OS execution environment not established. Later obtain an allowed destination or report that coverage explicitly deferred; do not install/change tools in M1 |
| StoreKit local testing | No production StoreKit implementation/config located by scoped source review; installed SDK supports candidate APIs | Future StoreKit fixtures simulate purchase outcomes, never Apple-signed production ownership or live storefront history |
| Release guard/resources | controlling policy; scripts/qualify-release-products.sh source; shipping guards | Script builds and ad-hoc signs; do not run under M1 or a future no-signing assignment. Artifact/privacy/architectures/resources diagnostics replacement require later explicit authority |
| Report-only scan | scripts/check-forsetti-compliance.sh source | Banner says REPORT ONLY — NOT A COMPLIANCE PASS. Never count it as release/architecture acceptance |

Normal native checks may require separate test-signing permissions. Tool presence does not establish signing/keychain/store access. No additional physical device is an agent prerequisite; owner-only hardware/distribution acceptance remains a separate phase.

## Proposed acceptance matrix

| Case group / future planning names | Existing anchors to retain or amend | Required evidence |
|---|---|---|
| FreshFreeNorseAllTools; LegacyOwnerNoEarnedItems; SeriesAllCatalogContent | ThemeCoordinatorConformanceTests; provider tests; content inventory 02 | Every actual included visual/script available for authorized creation, all retained tools free; all four provider identities remain distinct; no fake achievement completions |
| LegacyRestoreReinstall; EstablishedOfflineRestart; StoreUnavailableUnverified; PendingCancelledDuplicatePurchase | New ownership tests with deterministic store fakes, then local StoreKit/native hosts | Explicit state/outcome assertions; uncertain prior owner not directed to repurchase; no double delivery |
| IndependentLegacyAndRefundedPurchase; AccountChangeDuringRestore; StaleEntitlementGeneration | New provenance/state-generation tests | Refund invalidates only affected source; independent legacy rights/data survive; account policy reviewed first |
| InterruptedBeforeCommit; AmbiguousCommitReadback; RepeatMigration; EmptyLargeCorruptLibrary | CoreApplicationProgressionIntegrationTests.testConfirmedImportAfterWriteErrorUsesReadbackWithImportEvidence (2425–2473), existing migration/storage suites | Versioned fixtures, old bytes preserved, durable commit/read-back/idempotence, no ownership minted from install/achievement flags |
| ShareTerminalWithoutEarning; RelaunchTerminalExactlyOnce | testTerminalCannotCleanupOrTransitionBeforeDurableIntent (718–788); testRelaunchReplaysDurableTerminalAfterCoreCommitFailureExactlyOnce (876–951) in CoreApplicationProgressionIntegrationTests | Retained delivery/cleanup succeeds while no earning event/outbox evaluation occurs |
| NonOwnerIncomingThemedDecode; OptionalProviderFailure; LongMessageShare | Same Core suite testThemedInboundKeepsPlaintextWhenEncounterRecordingIsUnavailable (1755–1807), testOptionalInboundTokenAndContextFailuresPreserveAuthenticatedUtility (1866–1921); WireCompatibilityTests:9–83; SharePresentationSectionTests:195–279 | Decode/admission/preview compatibility survives unavailable ownership, token/encounter and provider paths; receiving grants no creation right |
| NoAchievementEvaluator; NoGameCenterAfterRelaunchForegroundRetry; OldCloudCannotRestoreLocks | Runtime cloud/Game Center scheduling, settings/outbox tests and new negative spies | Zero retired authentications/reports/retries/evaluation after launch/resume/account/connectivity/shutdown; stale state inert; selectedCodex sync treatment separately specified |
| ProviderMissingResourceKeepsRights; NorseAliasCompatibility | ThemeCoordinatorConformanceTests, RequiredThemeResourceFailureContractTests, NorseArtifactCompatibilityContractTests | Distinct valid rights vs unavailable resource; safe fallback and old stable identifiers preserved |
| DirtyCheckoutPreservation; Diagnostic cases above | External snapshot policy; existing safety tests + new synthetic fixtures | No unrelated file reset/overwrite; paired redaction/export and real release exclusion proof |

Existing test names and ranges are read-only anchors, not a promise they already cover the new contract. Old progression assertions need deliberate replacement, preserving data/security counterexamples; no tests are weakened merely to make retirement green.

## Later issuance, preflight and delivery obligations

Reconcile the actual authoritative record and adopted pin first. Then prepare a linked contract set with immutable authority/profile identities, precedence, exact dependency allowlists, prohibited acquisitions, concrete product-owned paths/interfaces, migration/data-retention policy and actual independent review/owner acceptance evidence. Resolve the source/store facts and technical choices in 03. Do not fill placeholders with this M1 task contract.

At the actually applicable reviewed method revision: validate each realization contract before package issuance; return the project-specific Builder acknowledgment; run preflight on the actual preserved checkout before dependent edits; after implementation run delivery plus affected native, behavioral, architecture/resource/dependency and diagnostic checks. Preserve exact reports, profiles and source binding. Those validators were not run in M1. A structural validator pass would not replace source-understanding/instruction review or owner authorization.

No accepted implementation candidate, signing/archive/upload, portal mutation, device acceptance, review approval or shipment is established by this report.
