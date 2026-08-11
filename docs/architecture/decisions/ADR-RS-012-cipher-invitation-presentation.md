# ADR-RS-012: Cipher-Invitation Presentation

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Blocked on physical-device spike
**Date:** 2026-08-09

## Decision

Keep the current cipher link, file, and QR invitation paths until a physical-device
share-composition spike determines the reliable public transport. The spike must test
image plus custom URL, image plus HTTPS URL, file/Quick Look behavior, multiple share
items, iOS MessageUI attachment acceptance, and generic Share destinations on a real
iPhone and Mac.

No permanent choice is made yet between image-led sharing, file-led sharing, dual-item
composition, a Quick Look thumbnail extension, or a dedicated iMessage extension.
Simulator or unit evidence may prepare the spike but cannot replace it.

## Exit evidence

Record the exact OS/device matrix, destination results, cancellation and completion
callbacks, attachment behavior, visible warnings, screenshots or video, failure modes,
and accessibility observations. The successor decision must preserve offline QR/social/
print fallback, first-delivery key warnings, bounded resources, and the compatibility
policy in ADR-RS-005.
