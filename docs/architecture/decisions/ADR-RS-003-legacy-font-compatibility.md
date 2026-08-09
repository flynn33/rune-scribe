# ADR-RS-003: Legacy Custom-Font Compatibility

**Status:** Accepted
**Date:** 2026-08-09

## Decision

Preserve each existing `FontRef` as legacy presentation-compatibility metadata in the
versioned Cipher Record. Imported fonts remain Core-managed, content-addressed,
SHA-256-validated data. They are not Theme Modules and cannot define screens,
capabilities, ownership, or unlock rules.

The ordinary default after migration is the Base Codex and Base Rune Script. A legacy
font override remains available wherever historical or imported content needs it.
Official Codex fonts are module-owned resources resolved through the future opaque
Forsetti resource service; consumers never guess another module's bundle path.

## Consequences

- Legacy cipher v3 and message v1 readers retain current font behavior.
- Font validation and path-safety rules cannot be weakened during Script extraction.
- No executable behavior or arbitrary UI can enter through a font package.
