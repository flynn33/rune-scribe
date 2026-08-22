# ADR-RS-008: Progression Persistence

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted; local-first persistence and private-cloud policy implemented
**Date:** 2026-08-09

## Decision

Progression is a local-first service-module responsibility behind a neutral repository
contract. The first implementation uses the runtime-owned protected SQLite module-state
adapter; tests use an in-memory adapter through the same contract. The Wave 5A
implementation adds a runtime-owned private CloudKit transport, bounded logical cloud
records, deterministic merge policy, offline queue, account-generation isolation, and
quarantine while leaving the local validated store authoritative.

The local schema contains versioned event/deduplication records, per-device statistic
shards, distinct-token sets, Achievement progress/completion, ownership grants,
Encounters, selected Title, reveals, migration evidence, catalog version, diagnostics,
and quarantine/recovery state. Stable event, operation, grant, and content IDs are
uniqueness keys. One transaction records an eligible event, updates derived statistics,
completes any matching Achievement or milestone, and grants its Codex, Artifact, or
Title reward.

The private-cloud mapping mirrors those logical record classes rather than the local
SQLite layout. Merge is set union for completions, grants, ownership, and tokens;
earliest valid date for first completion/grant; earliest and latest dates for
Encounters; maximum per device shard; maximum per Achievement for pending reports; and
logical last-write-wins with availability fallback for selection. Local load results
distinguish absent, loaded, migrated, quarantined, unreadable, and corrupt state. Invalid
local or remote records are quarantined and never silently overwrite valid local state.

The progression store may contain opaque relationship tokens, event and operation IDs,
counters, completion dates, grants, selected-Codex preference, Encounters, diagnostic
categories, and future sync metadata. It must never contain cipher keys, cipher bytes,
plaintext, contact identity, PIN material, or message contents.

Migrations are explicit, version-stepped, idempotent, and preserve the pre-migration
store until validation succeeds. Reset is deliberately unavailable in schema version
1; generation values other than zero are rejected and mutation-tested.

The implemented SQLite adapter is intentionally generic and runtime-owned. It provides
protected local storage, atomic bounded transactions, paged scans, integrity digests,
ambiguous-commit receipts, and physical quarantine without exposing a database handle
or path to Progression. Direct CloudKit-only storage would weaken offline-first testing;
JSON files or a module-owned database would violate the runtime boundary.

## Consequences

- Local progression remains authoritative and fully functional without iCloud or Game
  Center.
- Replayed events are harmless and interrupted transactions cannot split completion
  from its grant.
- Missing, denied, offline, changing, or corrupt cloud state cannot bypass local
  persistence or revoke an earned grant.
- Source entitlements declare the deterministic private container, while account,
  container, and production provisioning remain owner pre-ship work.

## Implementation note

The shipping implementation keeps the physical Core Data/SQLite stack runtime-owned
and exposes only the generic `ModuleStateStore` contract to Progression. Progression
defines and validates its versioned logical records, while the runtime adapter owns
file location, protection, integrity digests, transaction receipts, paging, physical
quarantine, and bounded mutation/byte limits. See
[ProgressionArchitecture.md](../ProgressionArchitecture.md) for the implemented ports,
event flow, migration, reveal protocol, and recovery behavior.
