# Controlling Decision — Norse Base Vault State

## Decision

The Norse Codex is the permanent Base Theme. It is always installed, always owned, always unlocked, selectable on every valid installation, and the universal fallback. A locked Norse state is not applicable to production.

## Required implementation

- The production Vault must never render Norse as locked.
- A missing Norse ownership record must be repaired as Base ownership during validated startup or migration; it must not produce a locked card.
- A failed required Norse provider produces the existing emergency Base appearance and a truthful warning, not a locked Norse card.
- Optional Codices continue to exercise the generic locked renderer.
- A descriptor-level Norse locked silhouette may remain only when the shared contract requires a complete state resource set. It is inert in production and may be used by a nonshipping conformance fixture.

## Verification

The four Norse `vault-locked` comparison entries remain in the 400-entry authority so the matrix is complete, but their applicability is `prohibited-production-state`. They pass only when:

1. no reachable production element exposes a locked Norse state;
2. Norse ownership and selection eligibility are true;
3. the Base fallback remains available;
4. optional-theme locked-state tests still pass.

The label `LOCKED STATE (NOT APPLICABLE)` in the approved Norse board is explanatory authority, not a requirement to display that card to users.
