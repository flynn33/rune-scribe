# ADR-RS-008: Progression Persistence

**Status:** Accepted; implementation deferred to Wave 3
**Date:** 2026-08-09

## Decision

Progression is a local-first service-module responsibility behind a neutral repository
contract. The first implementation uses a versioned Core Data store backed by SQLite;
tests use an in-memory repository. Private CloudKit mirroring is introduced only in
Wave 5A, after the local event, deduplication, transaction, migration, and quarantine
contracts are stable.

The local schema contains versioned event/deduplication records, per-device statistic
shards, distinct-token sets, Achievement progress/completion, ownership grants,
Encounters, selected Codex/Title preferences, pending Game Center reports, catalog
version, and future reset generation. Stable event, operation, grant, and content IDs
are uniqueness keys. One transaction records an eligible event, updates derived
statistics, completes any matching Achievement or milestone, and grants its Codex,
Artifact, or Title reward.

The future private-cloud mapping mirrors those logical record classes rather than the
local SQLite layout. Merge is set union for completions, grants, ownership, and tokens;
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
store until validation succeeds. Reset remains unavailable until a synchronized
reset-generation or tombstone design is accepted.

Core Data is preferred to a custom SQLite or JSON implementation because it provides
typed migrations, transactions, an in-memory test store, Apple data-protection support,
and the supported private CloudKit mirroring path while leaving merge policy explicit.
Direct CloudKit-only storage would weaken offline-first testing and a custom database
would duplicate migration and cloud-mirroring machinery.

## Consequences

- Local progression remains authoritative and fully functional without iCloud or Game
  Center.
- Replayed events are harmless and interrupted transactions cannot split completion
  from its grant.
- Cloud configuration cannot be used to bypass Wave 3 persistence tests.
