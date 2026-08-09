# ADR-RS-005: Old-App Forward Compatibility

**Status:** Accepted: legacy-only outbound until product review
**Date:** 2026-08-09

## Decision

Current production sharing continues to emit only the established cipher v3 and
message v1 transports. A typed-container reader, builder, and fixtures may be developed
behind tests, but no shipping route emits `RSCRPKG\n` content until product review
selects and approves a transition policy.

The current policy is therefore **legacy-only outbound compatibility**:

- New builds continue reading all supported legacy content.
- Old builds continue receiving the exact formats they already understand.
- No Codex metadata is appended to legacy message trailing bytes; legacy readers treat
  those bytes as font data.
- No visible Codex feature depends on vNext outbound content while this policy applies.

Product review must later choose compatibility mode, dual-item sharing, a
minimum-version transition, or an explicitly accepted vNext-only rollout. Enabling
vNext outbound requires an old/new compatibility matrix, rollback behavior, update
copy, and physical-device evidence for supported destinations.
