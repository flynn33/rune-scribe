# ADR-RS-007: Themed Follow-Up Transport

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted for package routes; iOS Messages transport superseded by ADR-RS-015
**Date:** 2026-08-09

## Original decision

The iOS Messages attachment requirement below is superseded by
[ADR-RS-015](ADR-RS-015-encoded-messages-artwork-and-runes.md). Package construction and
non-Messages file routes retain this decision. Regular message packages contain no
cipher key; cipher delivery is a separate explicit invitation operation.

Every themed or customized message share carries a versioned message package, even
after the cipher key has already been delivered. A first-delivery package may include
the key under existing security rules. An established-relationship package carries the
encrypted envelope and presentation metadata but does not resend the key.

Manual **Copy Runes** remains a compatibility action. It is not the authoritative
transport for a customized Artifact and does not promise Script portability.

ADR-RS-005 now authorizes this path. The UI freezes one runtime-persisted presentation
selection for each operation; Core validates that bounded record and constructs the
typed package. Terminal delivery evidence remains authoritative for progression, and
the explicit no-presentation command path retains the legacy writer for rollback.
