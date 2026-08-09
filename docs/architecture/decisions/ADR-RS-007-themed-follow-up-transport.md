# ADR-RS-007: Themed Follow-Up Transport

**Status:** Accepted; implementation deferred to Wave 4
**Date:** 2026-08-09

## Decision

Every themed or customized message share carries a versioned message package, even
after the cipher key has already been delivered. A first-delivery package may include
the key under existing security rules. An established-relationship package carries the
encrypted envelope and presentation metadata but does not resend the key.

Manual **Copy Runes** remains a compatibility action. It is not the authoritative
transport for a customized Artifact and does not promise Script portability.

This decision does not change current outbound behavior while ADR-RS-005 remains
legacy-only. It becomes active only with the reviewed Wave 4 rollout.
