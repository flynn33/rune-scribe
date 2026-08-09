# ADR-RS-002: Cipher Material Versus Script Presentation

**Status:** Accepted
**Date:** 2026-08-09

## Decision

Preserve the cipher's existing 32-entry permutation and key bytes exactly. In the
versioned Core model its role is a **symbol permutation**: it maps each encrypted
base-32 value to one of 32 presentation slots. A `ScriptDescriptor` supplies the
ordered 32 visible symbols or resource handles for those slots.

The Base Rune Script must reproduce current encoded strings byte-for-byte and
glyph-for-glyph. Selecting another Codex or Script must not mutate the key, public ID,
symbol permutation, contact relationship, or legacy payload bytes.

Selected Codex, Script, Relic, Seal, Frame, and Effect are presentation or per-share
state. They are never cryptographic cipher material.

## Consequences

- Existing keys and decoder behavior migrate idempotently.
- Multiple Scripts can present one cipher without key rotation.
- Script descriptors must contain exactly 32 unique, deterministic symbol slots.
- Legacy APIs may temporarily adapt `decorativeMapping`, but new contracts and code use
  `symbolPermutation` terminology.
