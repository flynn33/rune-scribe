# ADR-RS-011: Game Center App Store Record Strategy

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted; source catalog and shared-platform strategy frozen
**Date:** 2026-08-09
**Decision completed:** 2026-08-22

## Decision

Use one source-controlled evergreen achievement catalog across the macOS and iOS
variants of `com.runescribe.app`. If the variants use separate App Store records, place
them in one Game Center group rather than duplicating the catalog. The catalog freezes
15 production identifiers, English descriptions, point values totaling 220, hidden
flags, fallback art references, localization keys, and the no-leaderboard decision.
Both targets declare the Game Center capability in source.

Rune Scribe Progression remains authoritative. Game Center is an optional, monotonic
mirror of the approved evergreen catalog: declining authentication changes no local
capability; reports cannot grant or revoke ownership; failed reports remain in an
idempotent outbox; and later opt-in reports the maximum locally earned progress.

The runtime owns opt-in, authentication state, retry scheduling, durable report state,
and status projection. The policy module maps Progression state only and never imports
GameKit. The Platform adapter is invoked exclusively through the runtime boundary.

Persisted opt-in is continuing consent for one restored authentication attempt during
each application activation. A successful restored attempt drains the durable outbox in
the same work pass. Cancellation or denial does not loop. If GameKit cannot present its
authentication interface during cold launch, the runtime permits exactly one retry on a
later application-active event; connectivity and other lifecycle wakes cannot multiply
that attempt. An explicit opt-in submitted while authentication is already in flight is
idempotent and cannot replace the active GameKit handler.

## External configuration boundary

No App Store Connect record is created or changed by repository work. Identifier
ownership, record grouping, localization entry, achievement image upload, and sandbox
checks on both platforms remain explicit owner pre-ship steps. Those external steps do
not change the accepted source catalog or local-first authority boundary.
