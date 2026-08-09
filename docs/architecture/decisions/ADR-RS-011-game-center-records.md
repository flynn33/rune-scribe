# ADR-RS-011: Game Center App Store Record Strategy

**Status:** Blocked on App Store configuration review
**Date:** 2026-08-09

## Decision

Do not freeze achievement identifiers, descriptions, points, hidden flags, images,
localizations, target entitlements, or App Store Connect records until product review
confirms whether the macOS and iOS binaries share one App Store record and Game Center
grouping strategy.

Rune Scribe Progression remains authoritative. Game Center is an optional, monotonic
mirror of the approved evergreen catalog: declining authentication changes no local
capability; reports cannot grant or revoke ownership; failed reports remain in an
idempotent outbox; and later opt-in reports the maximum locally earned progress.

## Exit evidence

The decision can be completed only with recorded App Store Connect configuration,
identifier ownership, platform grouping, sandbox behavior on both targets, localization
review, and confirmation that the locked 15-Achievement catalog maps to 220 points.
