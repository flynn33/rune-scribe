# ADR-RS-004: Typed `.runescribe` Container

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted; version 1 wire layout frozen
**Date:** 2026-08-09

## Decision

Add a bounded binary container whose payload kind and payload version are independent.
All multi-byte integers are unsigned big-endian. Version 1 uses this 32-byte fixed
header:

| Offset | Size | Field | Version 1 rule |
|---:|---:|---|---|
| 0 | 8 | Magic | ASCII `RSCRPKG\n` |
| 8 | 2 | Container version | `1` |
| 10 | 2 | Header length | `32 + directoryLength` |
| 12 | 4 | Total length | Entire container including checksum trailer |
| 16 | 2 | Payload kind | Independent registered kind |
| 18 | 2 | Payload version | Core payload schema version |
| 20 | 2 | Section count | `1...16` |
| 22 | 2 | Container flags | `0` in version 1 |
| 24 | 4 | Directory length | `sectionCount * 16` |
| 28 | 4 | Reserved | `0` |

The header is followed by `sectionCount` 16-byte directory records:

| Size | Field | Version 1 rule |
|---:|---|---|
| 2 | Section type | Unique within the container |
| 2 | Section version | Independent section schema version |
| 2 | Section flags | Bit 0 means required; all other bits are zero |
| 2 | Reserved | Zero |
| 4 | Absolute offset | Offset from the first magic byte |
| 4 | Length | Exact section byte count |

Directory records are sorted by ascending section type. Sections are unique,
contiguous, non-overlapping, and stored in directory order immediately after the
directory. The last 32 bytes are the full SHA-256 digest of every preceding byte,
including header, directory, and section bytes.

Initial section types are:

| Type | Meaning | Limit |
|---:|---|---:|
| `0x0001` | Core payload; required exactly once | 1 MiB |
| `0x0002` | Presentation metadata | 64 KiB |
| `0x0003` | Safe static preview | 4 MiB |
| `0x0004` | Bounded resource table/data | 12 MiB |
| `0x0005` | Provenance | 64 KiB |

The complete container is limited to 16 MiB and 16 sections. Bounds, integer
overflow, header/directory consistency, canonical offsets, uniqueness, and total length
are validated before section allocation. Header flags, directory flags, and reserved
fields with unsupported nonzero bits fail closed.

Initial payload-kind assignments are `0x0001` for cipher material and `0x0002` for an
encrypted message. Their payload versions remain independent; a container may wrap the
current cipher v3 or message v1 Core bytes while new schemas evolve separately.

An unknown optional section is skipped by consumers but retained as opaque bytes in a
decoded container so a decode/re-encode does not discard it. An unknown required
section is rejected. An unsupported container version or required payload version is
rejected with a typed update-required result.

If the eight-byte magic is absent, intake falls back to the permanent legacy classifier:
leading byte `3` routes to cipher v3 and leading byte `1` routes to message v1. Theme
code, plaintext, contact identity, and Game Center identity are forbidden from all
container presentation sections.

## Consequences

- Presentation metadata is never appended to legacy trailing font bytes.
- Legacy readers remain permanent and are covered by exact golden fixtures.
- Parser, builder, malformed-input, unknown-section, checksum, canonical-order, and
  bounded-allocation tests are required before outbound use.
