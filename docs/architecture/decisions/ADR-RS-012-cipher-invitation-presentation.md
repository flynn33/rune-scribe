# ADR-RS-012: Cipher-Invitation Presentation

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted for file/QR compatibility; Messages conclusion superseded by ADR-RS-014
**Date:** 2026-08-09

## Decision

Use the typed `.runescribe` file as the authoritative themed cipher-invitation Artifact.
It contains the validated Core invitation plus bounded presentation metadata and a
static 4:3 safe preview. Compact offline link and QR invitation paths remain available
as legacy-compatible fallbacks and continue through the same validated intake rail.

Before rendering a requested installed provider, the receiver resolves the selected
Script, Relic, Seal, and optional Frame against that provider's installed inventory and
verifies every referenced resource's role, media type, byte length, dimensions, and
SHA-256 digest. Unknown selections are incompatible and resource drift is corrupt; both
use the Norse fallback. Presentation rejection never blocks admission or decryption of
an otherwise valid Core payload.

The earlier decision not to require a dedicated Messages extension is superseded by
[ADR-RS-014](ADR-RS-014-interactive-messages-cipher-invitations.md). Typed files and QR
remain separate compatibility paths; they are not silent substitutes for the
interactive `MSMessage` cipher-invitation route.

## Evidence boundary

The completion evidence records supported-environment destination results, cancellation and completion
callbacks, attachment state transitions, lifecycle behavior, fallbacks, visible
warnings, error paths, accessibility assertions, and deterministic artifacts. The
implementation preserves offline QR/social/print fallback, first-delivery key warnings,
bounded resources, and the compatibility policy in ADR-RS-005. Physical public-share
destinations remain in the owner checklist.
