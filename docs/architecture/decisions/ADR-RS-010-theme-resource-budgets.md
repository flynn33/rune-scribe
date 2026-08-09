# ADR-RS-010: Theme Resource Delivery and Budgets

**Status:** Accepted; initial limits frozen for scaffold work
**Date:** 2026-08-09

## Decision

Theme Modules contribute a versioned descriptor and content-addressed resources through
the official opaque Forsetti resource API. Consumers resolve stable resource handles;
they never guess bundle paths, import a Theme Module, accept a remote URL, or execute
module-supplied script.

The initial conformance budget is:

| Resource | Limit |
|---|---:|
| Encoded descriptor | 256 KiB |
| One static image | 8 MiB and 4096 x 4096 pixels |
| Static image catalog | 32 MiB |
| One font | 8 MiB |
| Font catalog | 16 MiB |
| Animation catalog | 16 MiB |
| One sound | 2 MiB |
| Sound catalog | 8 MiB |
| Complete Theme Module resources | 64 MiB |
| Decoded resource cache | 64 MiB |

Every required resource carries a SHA-256 digest, declared media type, byte length, and
semantic role. Accepted scaffold formats are JSON, PNG, HEIF, PDF, TTF/OTF, MP4/MOV,
and M4A/CAF/WAV. Archives, executable code, shader source, HTML, remote references, and
undeclared files are rejected. The cache is purgeable under memory pressure and a
missing, malformed, over-budget, or hash-mismatched resource falls back to Base.

## Consequences

- Theme conformance is measurable before production art exists.
- Resource failure cannot change navigation, ownership, or unlock state.
- A budget or format change requires a successor decision and unchanged Base-fallback
  coverage.
