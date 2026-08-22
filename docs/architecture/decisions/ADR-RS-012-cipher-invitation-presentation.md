# ADR-RS-012: Cipher-Invitation Presentation

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted interim; owner-operated hardware observation optional
**Date:** 2026-08-09

## Decision

Keep the current cipher link, file, and QR invitation paths until separately authorized
implementation work selects a reliable public transport. Candidate image, URL, file,
Quick Look, multi-item, MessageUI, and generic-share routes must be validated through
supported simulators, hosted tests, deterministic test doubles, platform builds,
static inspection, negative route mutations, and reproducible artifact checks.

No permanent choice is made yet between image-led sharing, file-led sharing, dual-item
composition, a Quick Look thumbnail extension, or a dedicated iMessage extension.
Owner-operated hardware-only observations may supplement the automated record, but are
optional outside Agent Coding scope. They do not affect acceptance, completion,
blocker status, residual work, PASS/FAIL, or pull-request readiness.

## Exit evidence

Record supported-environment destination results, cancellation and completion
callbacks, attachment state transitions, lifecycle behavior, fallbacks, visible
warnings, error paths, accessibility assertions, and deterministic artifacts. The
successor decision must preserve offline QR/social/print fallback, first-delivery key
warnings, bounded resources, and the compatibility policy in ADR-RS-005.
