# ADR-RS-013: Production Theme Resource Budgets

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted; supersedes the aggregate image and module limits in ADR-RS-010
**Date:** 2026-08-28

## Context

ADR-RS-010 froze conservative scaffold limits before production Theme art was
available. The accepted production resources for Norse, Moonleaf, Sunspire,
Wildwood, and Gloamthorn preserve full-resolution backgrounds, accessibility
variants, Relics, Seals, and panel chrome. Their encoded static-image catalogs
exceed the scaffold's 32 MiB aggregate limit, and some complete Theme resource
inventories exceed its 64 MiB module limit.

The production resources remain content-addressed, local, immutable, and bounded.
No individual resource exceeds the existing 8 MiB limit or 4096 by 4096 pixel
limit. Runtime image adoption is lazy, and the decoded cache remains purgeable and
bounded at 64 MiB.

## Decision

The production Theme resource limits are:

| Resource | Limit |
|---|---:|
| Encoded descriptor | 256 KiB |
| One static image | 8 MiB and 4096 x 4096 pixels |
| Static image catalog | 96 MiB |
| One font | 8 MiB |
| Font catalog | 16 MiB |
| Animation catalog | 16 MiB |
| One sound | 2 MiB |
| Sound catalog | 8 MiB |
| Complete Theme Module resources | 112 MiB |
| Decoded resource cache | 64 MiB |

All other ADR-RS-010 controls remain in force. Every required resource retains an
exact byte count, SHA-256 digest, media type, semantic role, and requirement class.
Unknown, missing, malformed, over-budget, or integrity-mismatched resources fail
closed to Base without changing navigation, ownership, or unlock truth.

## Impact

- **Compatibility:** Existing descriptors and resource handles are unchanged. An
  older build may reject a newer aggregate and use Base; no wire format changes.
- **Migration:** No persisted state, ownership, or progression migration is needed.
- **Security and privacy:** Per-resource, dimension, digest, media-type, and decoded
  cache limits remain unchanged. The larger encoded aggregate admits only bundled,
  declared resources and does not permit remote content or executable payloads.
- **Distribution:** Application bundles may be larger. Shipping checks enforce exact
  cross-platform inventories, hashes, sizes, and the new aggregate ceilings.
- **Rollback:** Reverting the production resources permits restoration of the
  scaffold aggregate limits without data migration. Runtime Base fallback remains
  available throughout.
