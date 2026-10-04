# ADR-RS-015: Ordinary iOS Messages Artwork and Rune Transport

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted; focused source/payload evidence, sent-recipient qualification pending
**Date:** 2026-10-04
**Supersedes:** The ordinary iOS Messages attachment requirement in ADR-RS-007

## Decision

Ordinary iOS Messages sends present the rendered PNG artwork and the encrypted rune
text without a trailing `.runescribe` message file. This applies to direct MessageUI
composition, Messages chosen from Quick Share, and encrypted-message Customize Share.

The direct composer requires valid PNG artwork and an active scoped transfer, attaches
only that artwork, and places the runes in its body. Attachment acceptance records the
actual PNG result. Core message artifacts remain key-free and require no key delivery.
The transfer retains the existing operation, completion, and cleanup lifetime.

The iOS activity adapter supplies image and text only to the Messages destination and
returns no package item there. Other destinations retain the original package item.
When artwork is missing or invalid, Messages is excluded rather than receiving a file
as fallback. Native completion callbacks retain ADR-RS-006 semantics.

## Compatibility and impact

Package construction, wire formats, supported file import, Mail/AirDrop package routes,
and explicit cipher export remain unchanged. The recipient imports the cipher through
a separate invitation, then pastes the Messages rune text into Rune Scribe to decode.
That rune-text intake carries the encrypted envelope rather than package presentation
metadata or provenance. Supported package intake remains available for file routes.
No sender label creates a contact or rebinds a relationship.

The interactive cipher invitation in ADR-RS-014 remains separate and unchanged. This
decision does not introduce a service, dependency, persistence migration, or key
transport. Rollback can restore the package attachment at the presentation adapter
without changing stored ciphers or the package format.

## Evidence boundary

`NativeShareOutcomeTests` verifies the concrete destination-specific artwork, rune text,
package omission, preserved non-Messages package, and invalid-artwork behavior.
The direct composer source attaches PNG data and no package URL. The simulator's
Messages destination was unavailable, so no native composer or sent-recipient
transcript screenshot is claimed. See the
[1.0.46 qualification summary](../../verification/release-1.0.46/QualificationSummary.md).
