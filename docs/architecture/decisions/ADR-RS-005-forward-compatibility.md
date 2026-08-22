# ADR-RS-005: Old-App Forward Compatibility

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted: vNext themed outbound with legacy compatibility
**Date:** 2026-08-09
**Transition authorized:** 2026-08-22

## Decision

The normal customized file path emits the bounded typed container beginning with
`RSCRPKG\n`. Cipher invitations and encrypted messages carry an authoritative Core
payload plus optional, nonsecret presentation metadata, a validated 4:3 safe preview,
and provenance state. Established-message packages do not resend the key.

Compatibility remains explicit and reversible:

- New builds continue reading exact legacy cipher v3 and message v1 content.
- Link and QR invitation paths retain their compact legacy representation.
- Callers that omit an outbound presentation request deliberately receive the legacy
  writer, providing a source-controlled rollback switch.
- Optional or malformed presentation never changes Core payload admission or message
  decryption; known future required sections produce an update-required result.
- Presentation bytes are never appended to a legacy payload where an older reader
  could mistake them for font data.

The destination matrix covers legacy and vNext readers, unknown optional and required
sections, future payload versions, and unavailable presentation providers. Physical
destination observation remains an owner pre-ship activity and does not alter the
source-complete transition decision.
