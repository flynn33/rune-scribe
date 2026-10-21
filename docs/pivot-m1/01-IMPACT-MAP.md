> Historical M1 discovery snapshot, captured 2026-10-21 against source d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54. Permissions and unexecuted-check statements below describe that completed run. The subsequent owner instruction authorizes documentation publication, Xcode documentation references and unsigned build verification only. Application implementation, Store changes and release remain outside this publication. See [publication scope and portability](README.md).

# RS-PIVOT-M1 source-linked impact map

**Inspection target:** clean local `main`, `d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54`; all rows below are bound to this same commit. This is source inspection and a proposed disposition map, not an implemented design or application test result. See [environment and authority](00-ENVIRONMENT-AND-AUTHORITY.md), [content inventory](02-CONTENT-INVENTORY.json), [migration proposal](03-MIGRATION-AND-RETIREMENT-PROPOSAL.md), and [contracts/verification](04-CONTRACTS-AND-VERIFICATION-PLAN.md).

The owner approval is preserved: free Norse and retained tools; one one-time $1.99 purchase unlocks the complete first Elven Series including all four separate modules and every existing included item; original paid owners receive that series; active achievements and Game Center retire; data and free incoming reading/decoding remain. All replacements below require reviewed design and a separately authorized implementation milestone.

## Responsibility and consumer evidence

Each row records producers, consumers, state owner, native membership, hazard, proposed acceptance and remaining uncertainty. Machine-readable copies with the baseline on every row are in [impact-responsibilities.json](impact-responsibilities.json). Source links point to the immutable inspected commit; the line ranges are the inspected ranges, not execution evidence.

### R01 — preserve host; replace ownership composition; retire progression/GC adapters only after replacement

- [AppDelegate.swift — applicationDidFinishLaunching / didFinishLaunchingWithOptions / applicationDidBecomeActive, 14-24,57-77](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/RuneScrib/AppHost/AppDelegate.swift#L14)
- [RuneScribeRuntimeComposition.swift — init / start / receive(lifecycle:) / configure, 36-84,93-163,181-226](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/RuneScrib/AppHost/RuneScribeRuntimeComposition.swift#L36)

**Chain:** native launch, scene/foreground callbacks → runtime.start; external-services wake; Messages inbox drainer; five theme provider registration.

**State / membership:** host activationState/generation; no paid ownership provenance; RuneScrib-macOS and RuneScrib-iOS share AppHost; no provider merger.

**Hazard:** Qualification earned-unlock injection at 123-136 and simulator route 115-120 are synthetic, not proof of paid ownership; removing lifecycle callbacks can break inbound delivery.

**Proposed acceptance:** Future cold/resume/stop tests with real normal composition; qualification flags absent; optional external services absent.

**Uncertainty:** Store ownership adapter and authoritative transition evidence do not exist in this composition.

### R02 — preserve runtime lifecycle; replace retired subsystem activation hooks

- [Runtime.swift — start / stop, 585-790](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift#L585)

**Chain:** host start/stop → dispatcher, I/O, settings, state, availability, ingress, contribution/resources; outbox and handoff lifecycle.

**State / membership:** runtime status/generation and active module order; RuntimeCore -> both apps.

**Hazard:** Stop must quiesce ingress and cancel tasks before resources/state revoke; deleting all outbox hooks loses retained share completion recovery.

**Proposed acceptance:** Future interrupted-start, foreground and shutdown tests; no retired task after restart.

**Uncertainty:** A commercial ownership lifecycle is proposed, not implemented.

### R03 — replace producer; preserve validated DTO boundaries until deliberate contract amendment

- [ProgressionSnapshotBuilder.swift — entitlements, 269-283](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/ProgressionSnapshotBuilder.swift#L269)
- [ProgressionContracts.swift — ProgressionEntitlementSnapshotDTO, 1607-1644](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/ProgressionContracts.swift#L1607)
- [Runtime.swift — startEntitlementObservation, 988-1004](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift#L988)

**Chain:** Progression projection entitlement records .included/.earned → runtime reconciliation -> availability snapshot -> Theme Coordinator; UI.

**State / membership:** Progression repository; DTO revision, capture time and disjoint ID sets; ProgressionModule + Contracts + RuntimeCore in both apps.

**Hazard:** Neither included nor earned classification proves original paid download or new purchase. Old progression grants cannot become paid receipts.

**Proposed acceptance:** Future legacy-no-progress and complete-series fixture tests; separate provenance for independent sources.

**Uncertainty:** Reviewed replacement ownership/restore/revocation contract missing.

### R04 — replace earning-union semantics for commercial rights; preserve free Norse invariant

- [Runtime.swift — reconcileEntitlements / initialEntitlementSnapshot, 857-901,1007-1017](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift#L857)

**Chain:** Progression entitlement stream / qualification injection → availability publishing and eligible optional activation.

**State / membership:** runtime entitlementSnapshot + lastObservedEntitlementSnapshot; RuntimeCore both apps.

**Hazard:** reconcileEntitlements unions all prior included/earned IDs and ignores lower revisions; this cannot remove one purchase source on revocation. Equal revision differing truth throws conflict.

**Proposed acceptance:** Future duplicate/stale/conflicting revision, independent legacy+purchase refund, transient outage fixtures.

**Uncertainty:** Final account/revocation policy remains reviewed design work; no refund policy selected.

### R05 — replace affected entitlement vocabulary and eligibility; preserve runtime authority

- [Runtime.swift — isEligible / isThemePreviewPublisher / reconcileEligibleOptionalModules, 923-986](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift#L923)
- [MoonleafThemeModule.swift — moduleID / unlockID, 6-18](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/MoonleafThemeModule.swift#L6)

**Chain:** manifest requirement + theme discovery descriptor + eligibility service → module activation -> contribution/resource publication -> selection and previews.

**State / membership:** runtime module state; individual stable provider identities; four separate Elven package targets and Norse target.

**Hazard:** purchase/composite currently return false; earned providers may activate solely as preview publishers while still locked for selection. One bundle is not a module merger.

**Proposed acceptance:** Future one series right activates all four providers; free recipient resolution with locked creator access; no direct UI entitlement bypass.

**Uncertainty:** Exact series product ID intentionally unspecified.

### R06 — replace ownership input only; preserve validation and selection protocol

- [ThemeCoordinatorService.swift — selectCodex / reconcilePass, 155-231,444-625](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/ThemeCoordinatorService.swift#L155)

**Chain:** availability.entitlementSnapshot.allUnlockIDs, contribution registry, resource snapshot, settings → provider records -> settings selectedCodex -> effective theme snapshot.

**State / membership:** Theme Coordinator cache + runtime settings revision; ThemeCoordinatorModule both apps.

**Hazard:** Owned, compatible, live, matching provider and resources are separate facts. A missing resource must not erase rights. Selection revalidates before and after settings write.

**Proposed acceptance:** Future resource-failure, duplicate-ID, stale reconcile, post-write revocation and fallback checks.

**Uncertainty:** No runtime execution performed; exact replacement DTO design unreviewed.

### R07 — replace per-item gates; preserve compatibility filters

- [RuneScribeUISession+ThemeArtifacts.swift — themeRelicItems / themeSealItems / themeFrameItems / ownedThemeArtifactIDs, 73-154,227-275](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession%2BThemeArtifacts.swift#L73)

**Chain:** effective descriptor + ProgressionSnapshot.ownership → artifact pickers -> runtime settings -> Core share choices.

**State / membership:** UI derived ownership and selected IDs; sole UIModule; provider resources remain in four distinct modules.

**Hazard:** Owning a Codex alone does not unlock mastery artifacts: non-included items still read Progression ownership. Frames also filter static share/compatible relics; do not remove compatibility checks to unlock them.

**Proposed acceptance:** Future every-inventory-item ownership matrix including mastery/shared items with no achievements; incompatible combinations rejected.

**Uncertainty:** Reserved/inactive catalog items and shared rewards classified in 02, not silently excluded.

### R08 — preserve selected IDs/settings; replace earned-lock presentation

- [RuneScribeUISession+ThemeArtifacts.swift — selectThemeArtifact / clearOptionalThemeArtifact, 157-225](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession%2BThemeArtifacts.swift#L157)
- [RuntimeSettingsGateway.swift — namespace / set / setAtomically, 207-213,260-394](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeSettingsGateway.swift#L207)
- [RuntimeSettingsContracts.swift — RuneScribeRuntimeSettings appearance keys, 186-205](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/RuntimeSettingsContracts.swift#L186)

**Chain:** artifact picker commands → runtime revision-checked persisted preferences; consumers rendering/creating shares.

**State / membership:** com.runescribe.runtime.settings / settings.values / schema1; selected-codex/relic/seal/frame/effects; RuntimeCore Contracts UIModule both apps.

**Hazard:** Do not purge whole settings namespace with retired feedback preferences; keep stable maps and safe fallback without overwriting preference on temporary provider failure.

**Proposed acceptance:** Future upgrade preserves valid selection; missing provider falls back and recovers preference; stale write rejected.

**Uncertainty:** Final treatment of actually revoked creator preference awaits ownership contract.

### R09 — preserve purpose-separated incoming access and resource integrity

- [ThemeCoordinatorService.swift — providerDescriptor / resolveResource / supportsReceivedPresentationResolution / canResolve, 233-348,574-596,1152-1199](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/ThemeCoordinatorService.swift#L233)

**Chain:** validated received SharePresentationSelection or creator selection purpose → received presentation resolver vs active/share rendering consumers.

**State / membership:** provider live contribution/resource validation key; no recipient ownership grant; ThemeCoordinatorModule + provider modules both apps.

**Hazard:** Received purpose allows available/locked provider only when current registered contribution and resources validate; share rendering requires owned available provider. UI may intentionally render safe fallback when locked; plaintext reading must remain free.

**Proposed acceptance:** Future unowned recipient AEAD decode + safe fallback, exact selected resource allowlist and no creator grant.

**Uncertainty:** Rendered unowned appearance is not guaranteed by this static read; preserve the free reading requirement independently.

### R10 — preserve optional failure isolation and emergency base behavior

- [Runtime.swift — start activation error handling, 650-667](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift#L650)
- [ThemeCoordinatorService.swift — reconcilePass / resolveResource, 291-342,494-625](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/ThemeCoordinatorService.swift#L291)

**Chain:** invalid optional module/contribution/resource → base Norse/effective fallback and sole UI remain available.

**State / membership:** runtime lifecycle and coordinator diagnostic state; all providers + RuntimeCore.

**Hazard:** Removing earning machinery does not justify fail-open resource/identity checks; base required resource failure has separate emergency presentation.

**Proposed acceptance:** Future optional provider throws, missing font/resource and stable collision fixtures.

**Uncertainty:** No app behavior claimed tested in M1.

### R11 — preserve compatibility; retire active progression migration only after Core decoupling

- [RuntimeExistingUserMigrationHandoff.swift — namespace / lifecycle / deliver, 84-159,444-497](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeExistingUserMigrationHandoff.swift#L84)
- [ProgressionServiceActor.swift — bootstrap / applyExistingUserMigration, 66-139,165-265](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/ProgressionServiceActor.swift#L66)

**Chain:** Core existing cipher snapshot → durable runtime migration delivery -> Progression generation staging -> entitlement/reveal publish.

**State / membership:** com.runescribe.runtime.existing-user-migration-handoff; progression.existing-user-migration; schema-v1 / schema-v2-manifest; schema1; Core RuntimeCore ProgressionModule both apps.

**Hazard:** Existing-user means cipher-library activity migration, not verified original paid-app ownership. Pending snapshot, pages, deferred errors and terminal receipts can outlive current process.

**Proposed acceptance:** Future empty/large/corrupt library, repeated migration, before/after commit and interrupted pages with no fabricated achievement history.

**Uncertainty:** Which compatibility readers ship through rollback window must be reviewed.

### R12 — retain inert/read compatibility; retire active evaluators/reveal writes

- [ProgressionRepository.swift — ProgressionRepositoryIDs / commit / promoteStagedGeneration / promoteExistingUserMigration, 5-120,371,885-990,1320-1428,1694-1800](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/ProgressionRepository.swift#L5)
- [ProgressionDomainRecords.swift — ProgressionMetadataRecord, 21-107](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/ProgressionDomainRecords.swift#L21)

**Chain:** Core facts / commands / migration snapshots → generation metadata, shards, events, grants, ownership, reveal queue, recovery diagnostics.

**State / membership:** module com.runescribe.module.progression; metadata/projection/distinct/reveal-queue/seeds/quarantine plus generation event, event-order, semantic, recovery-event, reveal-ack and command collections; schema1; ProgressionModule Resources/module-manifest.json both apps.

**Hazard:** Promotion verifies staged shards, seed digest and metadata generation/revision before atomic metadata switch. Do not delete markers or infer a half-stage is complete. Retiring achievement evaluation does not require erasing its storage.

**Proposed acceptance:** Future compatibility decode and inertness, staged upgrade interruption and ambiguous commit recovery; no automatic old evaluator on replay.

**Uncertainty:** Whole 7454-line repository was not read end to end; cited storage/commit/promotion slices support bounded proposal, final deletion audit still required.

### R13 — preserve/replace share completion journal and replay

- [RuntimeProgressionOutbox.swift — namespace / runtimeDidStart / outstandingShareCompletionArtifactIDs / deactivateRuntime, 179-204,229-289](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeProgressionOutbox.swift#L179)
- [RuntimeProgressionOutbox.swift — replayShareCompletions / deliverShareCompletion, 806-890](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeProgressionOutbox.swift#L806)

**Chain:** normalized terminal native share callback → Core completeShareArtifact replay and exact terminal receipt.

**State / membership:** com.runescribe.runtime.progression-outbox / share-completion-journal schema1; maximum 64 completions; RuntimeCore used by both apps.

**Hazard:** The same file owns non-achievement crash-window closure. Deleting it strands successful delivery before Core key-delivery update.

**Proposed acceptance:** Retain future equivalent of testShareCompletionJournalSurvivesRelaunchBeforeCoreReceipt and before/after commit reservation tests.

**Uncertainty:** Final relocation/name not selected; preserve behavior first.

### R14 — preserve/replace operation context authentication

- [RuntimeProgressionOutbox.swift — context authority namespace / activateRuntime / deactivateRuntime, 179-204,229-252,276-289](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeProgressionOutbox.swift#L179)

**Chain:** runtime dispatcher operation ID/correlation/generation → Core evidence/terminal callbacks and replay verification.

**State / membership:** com.runescribe.runtime.operation-context-authority / operation-context-authority / authority-key-v1 / schema1; RuntimeCore both apps.

**Hazard:** Authority key persistence/recovery is independent of earning. An unavailable store gets ephemeral authority; no accepted durable context should be replaced merely for reservation cleanup.

**Proposed acceptance:** Future forged context rejected; persisted context replay remains valid after relaunch; generation-scoped context expires.

**Uncertainty:** Need reviewed replacement context contract before removal of old entrypoints.

### R15 — retire active earning event outbox after retained journal/context consumers replaced; retain legacy records inert

- [RuntimeProgressionOutbox.swift — submitBatch / acknowledgeBatch / replayReady / deliver, 578-805,892-1014](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeProgressionOutbox.swift#L578)

**Chain:** Core committed sanitized fact batches → Progression apply endpoint + runtime receipt ack; external sync through Progression.

**State / membership:** progression.outbox + progression.outbox-receipts schema1; RuntimeCore and Progression contracts both apps.

**Hazard:** Removing only Progression subscriber leaves deferred retry queues. Removing the whole outbox loses R13/R14. Stale queued facts must never produce renewed rewards after pivot.

**Proposed acceptance:** Future no earning scheduler after launch/foreground/connectivity/retry; old durable events stay inert; share journal independently drains.

**Uncertainty:** Legacy retention duration/deletion authority not approved.

### R16 — retire active achievement sync/report projection; preserve bounded schemas for compatibility if required

- [RuntimeProgressionExternalSync.swift — RuntimeProgressionExternalProjection, 136-210](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeProgressionExternalSync.swift#L136)
- [CloudProgressionSchema.swift — CloudProgressionReplica, 354-383](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionSyncDomain/CloudProgressionSchema.swift#L354)

**Chain:** Progression local authoritative projection → Cloud merge and Game Center candidates.

**State / membership:** replica schema1 includes counters, completions, grants, ownedContentIDs, unlockIDs, encounters, selectedCodex/Title and pending GC reports; ProgressionSyncDomain + CloudSyncModule + RuntimeCore.

**Hazard:** Cloud grants/unlocks are old progression facts, not Apple verified purchase evidence. Never import them as new commercial rights or revive them as locks.

**Proposed acceptance:** Future stale replica replay cannot change commercial right, schedule achievement evaluator or authenticate/report GC.

**Uncertainty:** Only named schema/projection fields inspected, no live Cloud data read.

### R17 — unresolved retained consumer: preserve/replace selected-Codex sync before broad Cloud removal

- [RuntimeCloudGameCenterCoordinator.swift — selectedCodexProjection / adoptSelectedCodexAfterProgressionApply / startSettingsObservation, 1757-1801,1872-2009](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCloudGameCenterCoordinator.swift#L1757)

**Chain:** setting.appearance.selected-codex changes; remote replica.selectedCodex → Cloud upload; runtime settings adoption -> Theme Coordinator preference.

**State / membership:** runtime.settings selectedCodex; coordinator durable progressionCodexSelection tracker; RuntimeCore -> both apps; CloudKit platform adapter.

**Hazard:** This is an independent appearance preference consumer within the progression sync machinery. Current remote adoption checks old codexGates.unlockedAt and falls back to Norse; that gate must not overwrite valid new-series choices.

**Proposed acceptance:** Future selection-only sync under new ownership; stale old selection cannot relock; account mismatch preserves local preference.

**Uncertainty:** Review how to retain this free behavior; no silent retirement of appearance sync authorized by achievement removal.

### R18 — retain inert legacy title selection; retire achievement title UI/evaluation subject to complete content reconciliation

- [RuntimeCloudGameCenterCoordinator.swift — selectedTitleProjection / adoptSelectedTitleAfterProgressionApply, 1803-1871](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCloudGameCenterCoordinator.swift#L1803)
- [RuneScribeUISession+Progression.swift — selectProgressionTitle, 413-426](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession%2BProgression.swift#L413)

**Chain:** Progression selected title / replica.selectedTitle → title selection tracker and vault/title UI.

**State / membership:** Progression TitleSelectionRecord, not a RuntimeSettings key; ProgressionModule UIModule RuntimeCore.

**Hazard:** Do not confuse selectedTitle with selectedCodex or drop stable content merely for old reward origin. Shared title content accounted in 02.

**Proposed acceptance:** Future no title achievement requirements; inert old records decode; complete-content proposal covers shared title items.

**Uncertainty:** Exact retained presentation of old titles is design review work, not a new achievement feature.

### R19 — retire progression cloud work; preserve independent selection consumer per R17; no live record deletion

- [RuntimeCloudGameCenterCoordinator.swift — namespace / processCloudIfPossible / rebindCloudAccount / wake / deactivateRuntime, 417-424,567-615,976-1156](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCloudGameCenterCoordinator.swift#L417)
- [AppleCloudKitProgressionTransport.swift — record constants / fetchPrivateProgression, 7-12,65-124](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/Cloud/AppleCloudKitProgressionTransport.swift#L7)

**Chain:** local progression or selectedCodex change; foreground/retry/poll → Cloud transport fetch/merge -> pending local apply -> ack -> upload.

**State / membership:** com.runescribe.runtime.cloud-game-center / external-services.state / orchestration schema1; Cloud container iCloud.com.runescribe.app record RuneScribeProgressionReplica private-progression-v1 payload; Platform CloudKit + RuntimeCore CloudSyncModule both apps.

**Hazard:** Old cloud pending work, account bindings, retry timers/polls can revive on restart. Whole Cloud capability cannot be removed while R17 retained path remains unresolved.

**Proposed acceptance:** Future stale remote account/retry/merge tests; local secrets never enter payload; no old earning jobs.

**Uncertainty:** No actual Cloud account, record contents or publisher configuration inspected.

### R20 — retire active Game Center auth/report/outbox scheduling; retain durable state inert

- [RuntimeCloudGameCenterCoordinator.swift — activateRuntime / submit participation / processGameCenterIfPossible / wake, 520-565,643-706,999-1055,1287-1398](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCloudGameCenterCoordinator.swift#L520)
- [AppleGameCenterReportingAdapter.swift — authenticationState / requestAuthentication / report / run, 14-59,116-187](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/GameCenter/AppleGameCenterReportingAdapter.swift#L14)
- [GameCenterReportingPolicy.swift — GameCenterAuthorityPolicy, 12-17](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeGameCenterModule/GameCenterReportingPolicy.swift#L12)

**Chain:** saved opt-in + local candidates; user Settings intent; lifecycle/retry → GameKit authenticateHandler, GKAchievement.report; one-way local progress mirror.

**State / membership:** coordinator durable gameCenterOptedIn, account binding and GameCenterReportOutbox; GameCenterModule + Platform/GameCenter; both apps.

**Hazard:** A saved opt-in schedules automatic auth on new launch; hiding button alone leaves it running. Opt-out preserves queue for later replay, so retiring by opt-out alone is insufficient. GC has no authority to grant/revoke rights.

**Proposed acceptance:** Future adapter spy sees zero auth/report/session requests through cold/resume/retry/relaunch with legacy opt-in/pending queue.

**Uncertainty:** Live Apple GC records/capabilities cleanup needs separate publisher authorization.

### R21 — retire journey/achievements/statistics/reveals and their navigation; preserve useful theme browsing

- [SettingsView.swift — progressAndFeedbackPanel / cloudAndGameCenterPanel, 632-800](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/SettingsView.swift#L632)
- [VaultProgressView.swift — section switch, 475-496](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VaultProgressView.swift#L475)
- [RootView.swift — activeReveal overlay, 195-199](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RootView.swift#L195)
- [RuneScribeUISession.swift — submitGameCenterParticipation / rebindCloudAccount, 349-383](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession.swift#L349)

**Chain:** progression/status snapshots and settings navigation → VaultProgressView Journey/Achievements/Statistics/Vault/Archive; unlock overlay and GC actions.

**State / membership:** sole UI observable state and tasks; RuneScribeUIModule both apps.

**Hazard:** Vault mixes collectible appearance content with retired progress, so deleting all vault content can lose paid assets. Preserve free tools/app lock panel immediately following external panel.

**Proposed acceptance:** Future no achievement counters/prompts/screens/GC controls; owned content browsing remains; inaccessible Progression does not gate tools.

**Uncertainty:** Final non-progression content selection layout not selected in M1.

### R22 — retire active achievement reveal feedback; preserve any content resource independently included by inventory

- [RuneScribeUISession+Progression.swift — optional observation / feedback / reveal commands, 352-455,520-594](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession%2BProgression.swift#L352)
- [RuntimeSettingsContracts.swift — unlock feedback keys, 177-185](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/RuntimeSettingsContracts.swift#L177)
- [RuneScribeRuntimeComposition.swift — configure feedback adapter, 225](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/RuneScrib/AppHost/RuneScribeRuntimeComposition.swift#L225)

**Chain:** Progression reveal queue + feedback preferences → mark-presented/ack commands; animation/audio/haptics adapter.

**State / membership:** setting.unlock-feedback.sound-enabled / haptics-enabled / animation-enabled; inert settings rows; UIModule + Platform Feedback resource bundle.

**Hazard:** Do not delete reusable included effects/animation art because formerly used during rewards. No active earning prompt may survive by leaving observer/task alone.

**Proposed acceptance:** Future no reveal queue observation/presentation; every inventoried included visual preserved; accessibility/effects preferences still honored where useful.

**Uncertainty:** Root/content inventory determine complete resource usage; no broad resource deletion approved.

### R23 — preserve generic storage/security; no namespace-wide purge

- [AppleSQLiteModuleStateStore.swift — store constants / production initializer / prepareNamespace, 1-135](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/Storage/AppleSQLiteModuleStateStore.swift#L1)
- [RuntimeSettingsGateway.swift — namespace / lifecycle / set, 207-302](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeSettingsGateway.swift#L207)

**Chain:** all runtime module state owners → namespaced bytes, transactions, settings and share journals.

**State / membership:** Application Support/RuneScribe/RuntimeModuleState/module-state.sqlite and -wal/-shm; protected 0600/iOS protection; generic schemas; Platform storage used by both apps.

**Hazard:** Database is shared by retained settings/share context/journals and retired records. Deleting database to retire achievements damages retained state.

**Proposed acceptance:** Future synthetic DB upgrade integrity; unrelated namespace digests unchanged; interruption tests.

**Uncertainty:** No actual customer database or secrets accessed.

### R24 — preserve four providers and Core/UI/extension linkage; retire only reviewed obsolete products/resources later

- [Package.swift — products / target dependencies / resources, 6-165](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Package.swift#L6)
- [project.yml — macOS/iOS/extension target dependencies, 35-74,148-189,268-300](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/project.yml#L35)
- [project.pbxproj — PBXBuildFile/framework product references, 27-115,258-296,708-813,1990-2017](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/RuneScrib.xcodeproj/project.pbxproj#L27)

**Chain:** SwiftPM targets + XcodeGen native manifest → native Frameworks phases; module resource bundles; Messages extension embedding.

**State / membership:** stable target/product names; no dependency additions; both native apps link all providers/Progression/Cloud/GC; extension links MessagesShared + Messages.framework.

**Hazard:** Removing GC source import alone leaves package product/native refs. RuntimeCore itself depends on GC/Cloud/SyncDomain; changing app dependencies alone cannot retire compiled code.

**Proposed acceptance:** Future exact package/native dependency diff, no external Forsetti, no GC framework/API references; all provider resource membership preserved; native build only when authorized.

**Uncertainty:** No package resolution, generator, compiler or product scripts executed.

### R25 — retire Game Center entitlement only in later authorized implementation; Cloud decision separate; preserve app group/links/keychain

- [project.yml — app/extension entitlements, 105-115,239-254,287-300](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/project.yml#L105)
- [RuneScrib-macOS.entitlements — plist, 1-24](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Config/RuneScrib-macOS.entitlements#L1)
- [RuneScrib-iOS.entitlements — plist, 1-30](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Config/RuneScrib-iOS.entitlements#L1)
- [RuneScribeMessagesExtension.entitlements — plist, 1-10](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Config/RuneScribeMessagesExtension.entitlements#L1)

**Chain:** native target CODE_SIGN_ENTITLEMENTS → app capabilities; Messages App Group handoff; secure storage.

**State / membership:** GC=true both apps; iCloud container/service/ubiquity; iOS associated domains/app group/keychain; macOS, iOS and iOS Messages extension distinct capability scopes.

**Hazard:** Do not remove app group/keychain/associated domains while removing GC; CloudKit removal awaits selectedCodex consumer review. Source entitlement presence is not portal or signing evidence.

**Proposed acceptance:** Future source/project/capability parity and no-GC runtime verification; independently verify signed candidate if later authorized.

**Uncertainty:** Live provisioning, store and signing capability states uninspected.

### R26 — propose focused policy/docs amendment; retain runtime architecture and permanent external dependency ban

- [FORSETTI_CONTROLLING_POLICY.md — Theme Module rule / dependency prohibition, 140-165](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/docs/architecture/FORSETTI_CONTROLLING_POLICY.md#L140)
- [README.md — Codex/progression descriptions and cloud authority, 58-71,402-431](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/README.md#L58)

**Chain:** owner APPROVAL-PIVOT-001 supersedes earned-only acquisition → future contract/test/copy revisions.

**State / membership:** documentation contracts, not live ownership evidence; no runtime/module merger; app-owned framework only.

**Hazard:** Current policy requires completed Progression gate; README promises local-first usability and bounded optional sync. Amend eligibility to approved ownership, preserve lifecycle/resource checks and local data safety.

**Proposed acceptance:** Future reviewed policy diff plus relevant test amendments; no broad architecture changes.

**Uncertainty:** M1 does not amend or approve product contracts.


### R27 — preserve/replace Core delivery semantics before earning retirement

- [RuneScribeCoreApplicationService.swift — completeShareArtifact, 1081-1142,1204-1349](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Application/RuneScribeCoreApplicationService.swift#L1081)
- [CoreProgressionCoordinator.swift — drain / acknowledgeRetainedReceipts, 223-306](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreProgressionCoordinator.swift#L223)

**Chain:** native required-attachment acceptance + runtime terminal journal → Core registry durable intent -> terminal repository commit -> key delivery/relationship mutation -> receipt/cleanup.

**State / membership:** encrypted Core library progression ledger; durable ShareArtifactRegistry terminal state; CoreModule+RuntimeCore+UIModule both apps.

**Hazard:** Core currently checks progression evidence readiness before completing delivery. The commit simultaneously records first delivery/bidirectional facts and key-delivery transition. Retire counters without losing completion evidence, required attachment acceptance, exactly-once terminal handling or contact relationship behavior.

**Proposed acceptance:** Future equivalent of terminal-intent crash/relaunch tests with no Progression module; key-free messages never consume key-delivery rights; cancelled/unaccepted attachment never records delivery.

**Uncertainty:** Exact replacement schema/migration requires review; detailed Core namespaces and constraints in 03.

### R28 — retain current library decoding; propose separately versioned compatible migration if needed

- [CipherLibrary.swift — validatedProgressionLedger / validateStoredShape, 183-210](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Domain/CipherLibrary.swift#L183)
- [CoreProgressionCoordinator.swift — migrateEvidenceIfNeeded, 148-178](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreProgressionCoordinator.swift#L148)

**Chain:** stored v1/v2 cipher library and encrypted evidence → Core startup/repository validation, cipher selection and sharing.

**State / membership:** CipherLibrary v2 requires progressionLedger; Core coordinator migrates evidence; CoreModule both apps.

**Hazard:** Removing the ledger field without a compatible version change invalidates current stored libraries. Existing activity seeds do not prove paid-app purchase.

**Proposed acceptance:** Future decode historical v1/v2/absent/corrupt/empty/large fixtures; data/key digests preserved; no fabricated achievement completion.

**Uncertainty:** No customer data inspected; new storage shape not approved.

### R29 — preserve input validation/AEAD/free plaintext reading and safe fallback; retire only optional encounter earning

- [RuneScribeCoreApplicationService.swift — ingestFileData package admission before AEAD, 2429-2501](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Application/RuneScribeCoreApplicationService.swift#L2429)
- [FileRouter.swift — decode / decodePackage, 67-146](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Import/FileRouter.swift#L67)
- [MessageImportUseCase.swift — ingest / receivedMessage, 15-83,296-338](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Messages/MessageImportUseCase.swift#L15)
- [SharePresentationLifecycle.swift — SharePresentationResolver.resolve, 4-39](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Messages/SharePresentationLifecycle.swift#L4)
- [ReceivedPresentationAvailabilityBinding.swift — resolve / providerAvailability, 21-71](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ReceivedPresentationAvailabilityBinding.swift#L21)

**Chain:** admitted legacy/package data -> exact wire decoder -> candidate cipher → authenticated plaintext -> ReceivedMessageDTO -> UI compatibility resolver and requested/Norse presentation.

**State / membership:** Core library and transient incoming metadata; no recipient series grant; Core+Contracts+UIModule both apps; iOS Messages ingress separately retained.

**Hazard:** MessageImportUseCase.ingest authenticates before changing cipher/contact/relationship data. The outer CoreApplicationService.ingestFileData path may first persist optional package-admission facts and encounter metadata before AEAD (2429-2501); that metadata write is not authenticated plaintext or sender-identity proof. Core returns decoded plaintext independently of series ownership; optional earning must not become admission/paywall. Locked/unavailable appearance can render Norse fallback while message remains readable.

**Proposed acceptance:** Future unowned recipient with valid/invalid ciphertext, unknown/locked/missing provider, static preview, legacy links/package and cipher confirmation; tampering must not mutate cipher, key, contact relationship or message content; optional pre-decode admission metadata is assessed separately.

**Uncertainty:** Not a claim that every sender appearance renders for an unowned recipient; no native path executed.

### R30 — replace share creator item ownership feed; preserve authorization and composition validation

- [OutboundSharePresentationBuilder.swift — requestedSelectionValidated, 291-309](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/OutboundSharePresentationBuilder.swift#L291)
- [ShareBuilderModel.swift — ShareBuilderDraft.selection / resolveDefaults, 151-174,370-394](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ShareBuilderModel.swift#L151)

**Chain:** provider isOwned/state + ownedThemeArtifactIDs + selected relic/seal/frame → ShareBuilderPolicy selection -> static renderer metadata/resource resolution -> Core artifact.

**State / membership:** UI draft/settings plus progression-derived owned artifact IDs; sole UIModule and provider resources both apps.

**Hazard:** Share creation has a separate item ownership check from Codex selection. Replacing only provider ownership leaves mastery visuals unavailable. Keep static-share, compatibility, exact selection equality, integrity and resource allowlists.

**Proposed acceptance:** Future new or legacy whole-series owner can create with every compatible inventoried item, without mastery; recipient access still cannot grant creation.

**Uncertainty:** 02 explicitly distinguishes five deferred shared visual catalog entries from shipped provider items; no new artwork promise.


### R31 — preserve Messages handoff lifecycle and App Group

- [MessagesViewController.swift — continueToRuneScribe / openContainingApp / recordOpenResult, 103-164](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/RuneScribeMessagesExtension/MessagesViewController.swift#L103)
- [AppDelegate.swift — startup / foreground / drainMessagesInbox, 59-109](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/RuneScrib/AppHost/AppDelegate.swift#L59)
- [MessagesImportInboxDrainer.swift — drain / acknowledgeDirectDelivery / recordTerminalState, 17-69](https://github.com/flynn33/rune-scribe/blob/d33fa227b3bad4cdd49c0f6f10e97a8f060b4f54/RuneScrib/AppHost/MessagesImportInboxDrainer.swift#L17)

**Chain:** validated incoming Messages invitation and user confirmation → App Group durable confirmation/open result -> containing app ingress -> presented/completed/declined terminal status.

**State / membership:** group.com.runescribe.app inbox; per-handoff state and process dedupe; iOS Messages extension + iOS AppHost + MessagesShared; not a GC capability.

**Hazard:** Deleting App Group or foreground drain with Game Center cleanup strands invitations. Open accepted is not import complete; presented and completed/declined remain distinct. No purchase prerequisite belongs in this route.

**Proposed acceptance:** Future valid/invalid invitation, open rejection, foreground retry, duplicate handoff and terminal confirmation fixtures without owned series.

**Uncertainty:** No Messages app or native simulation launched; exact live invitation behavior remains unverified

## End-to-end responsibility chains

1. **Launch/resume to content:** native `AppDelegate`/scene lifecycle → composition registration and normal runtime start (R01) → runtime infrastructure and availability (R02) → Progression entitlements (R03) → monotonic runtime reconciliation (R04) → provider preview/activation eligibility (R05) → coordinator compatibility/lifecycle/resource validation and Codex selection (R06) → separate artifact ownership gates (R07/R30) → revision-checked settings (R08). Replace the ownership producer and both levels of gating; preserve runtime authorization and provider integrity. A series purchase is not sufficient if any mastery gate still reads the old projection.
2. **Creation/share to external reporting:** validated UI draft/resource render (R30) → Core share artifact creation → native completion with required attachment evidence → runtime durable terminal journal (R13) → Core terminal commit/key delivery/relationship semantics (R27) → encrypted pending fact batch and authenticated runtime context (R14/R28) → runtime earning outbox (R15) → Progression projection → Cloud/Game Center projection (R16) → persisted orchestration/retry (R19/R20). Preserve completion and relationship semantics first, then stop earning and reporting; old state remains inert.
3. **Receive/import to free reading:** host inbound route and Messages inbox → legacy/container validation → optional durable package-admission facts/encounter metadata → Core AEAD → decoded plaintext and authenticated relationship/content changes → received DTO → purpose-specific coordinator/resource resolution and UI requested/Norse fallback (R09/R29). Purchase ownership restricts creator selection; no reading paywall is introduced. Input and resource validation still apply.
4. **Existing install to migration/recovery:** encrypted cipher library v1/v2 → validated current ledger or compatible upgrade (R28) → runtime durable snapshot/page handoff (R11) → Progression stage, seed digest/shard validation and atomic generation promotion (R12) → published state/entitlement snapshot (R03). The existing migration is activity migration. The future paid-owner migration must use independent verified evidence and cannot use old achievements, selected themes or install flags as payment proof.
5. **Settings/account to shutdown/relaunch:** selected-Codex preference and title/participation state (R08/R17/R18/R21) → coordinator durable queue (R19/R20) → foreground/connectivity/retry polling → account-scoped session and pending local merge/ack → runtime stop revokes epochs/cancels timers/observers (R02) → startup reloads durable state and can reschedule (R20). A UI deletion or saved opt-out alone cannot establish retirement. No old opt-in/outbox may resurrect Game Center. Retained appearance sync needs a reviewed replacement before broad Cloud removal.

The Core artifact creation, Messages wire and source-defined persistence details are expanded in [03-MIGRATION-AND-RETIREMENT-PROPOSAL.md](03-MIGRATION-AND-RETIREMENT-PROPOSAL.md). The source snippets for these rows were read directly, with additional independent Core/sharing inspection feeding that report.

## Content and resource boundary

[02-CONTENT-INVENTORY.json](02-CONTENT-INVENTORY.json) and [content-review-notes.md](content-review-notes.md) are the exhaustive enumeration. Preserve all shipped provider content, all stable identifiers, all 14 Norse compatibility aliases, and the nine shipped textual titles. Five shared visual catalog entries have no shipped descriptor/resource implementation and are explicitly deferred/gaps; they are not lost between Codices or silently promised as new art. Previously mastery-gated shipped items remain included in the approved series/free Norse scope. Unlock animation/effect assets must be classified independently from retired achievement scheduling; removing a scheduler is not permission to delete included visual resources. All four Elven modules remain separate.

The only RuntimeSettings key observed in the Cloud coordinator is `setting.appearance.selected-codex`; `selectedTitle` is a separate Progression projection field. Relic/seal/frame/effects settings have local persistence consumers but no observed export in this coordinator. This is a source-defined scope statement, not a claim about live Cloud contents.

## Tests and focused history inspected

No application test or product script was executed. These are test-source observations and proposed future preservation/amendment targets:

- `RuntimeThemeFoundationIntegrationTests.swift:8-115`: earned provider activation/resource publication and optional failure isolation. Preserve lifecycle/client revocation and fault isolation; replace earning-only fixtures with reviewed ownership fixtures.
- `ThemeCoordinatorConformanceTests.swift:83-118,699-815`: locked provider baseline; received purpose cannot revive a non-running entitlement-gated provider; received resources allow only declared selected composition/identity references. Preserve these resource/lifecycle boundaries while changing acquisition rules. The synthetic entitlement-gated provider is not evidence that all actual preview publishers fail while locked.
- `RuntimeProgressionOutboxTests.swift:146-207`: terminal journal replays after relaunch without a Progression module; this is retained Core behavior. Other located test names identify before/after commit reservations, forged context rejection and stale generation tests; their full bodies were not all newly read.
- `RuntimeCloudGameCenterCoordinatorTests.swift:1142-1225`: a selected-Codex-only settings change queues and uploads a replica even without a new progression event. This supports the independent retained-consumer classification in R17.
- `ProgressionExistingUserMigrationTests.swift:35-105,842-889`: existing activity migration awards based on cipher counts, and fault-matrix fixtures locate promotion boundaries. Preserve data/idempotency/interruption properties; active reward assertions need deliberate replacement under the approved retirement scope. No fictitious completed achievements are needed to grant legacy paid inclusion.

Read-only `git log -6 --format='%h %ad %s' --date=short -- <runtime/coordinator/outbox paths>` located the relevant history; per-file log showed Runtime.swift last changed at `9e3d51c2c703d8d37f7243d6b17d713e8e8a4dd9`, outbox at merge `80caf9a542bde5ac5e623d3b5d31b0d2b39400e2`. No historical ancestor was checked out. `git show --no-ext-diff --no-textconv` was read for:

- `bd28940cdbdeb404c7e8b50a73eb8bc9d3df4d8d`, ThemeCoordinatorService: frame thumbnails were deliberately added to catalog previews. Keep preview and share-rendering allowlists distinct.
- `79a0059a21949cac5961c92b8d6095f2478bb08d`, CoreApplicationService: Messages required attachment semantics distinguish key-free rendered artwork from separate cipher/key delivery. Preserve that distinction through retirement.

History review was focused on touched responsibility chains, not a full repository archaeology or proof of production behavior. Every future deletion needs a final consumer check at the then-current source baseline; M1 makes none.

## Remaining uncertainty and next dependency

Commercial scope is settled. Missing authoritative method/record identity, reviewed realization contracts, native purchase identifier/live app relationship/history and final refund/account transition rules are readiness evidence gaps, not invented approvals. The migration report proposes independent right sources and interruption-safe ordering. Source access was sufficient for this impact map; no hidden runtime execution, contract conformance pass or release acceptance is claimed. Readiness and proposed host/macOS/iPhone/iPad Simulator checks are in report 04. All source and native project work remains unauthorized until a later owner instruction.
