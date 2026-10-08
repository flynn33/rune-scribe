# ADR-RS-015: Ordinary Messages Artwork and Rune Transport

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted; source implemented, current qualification and sent-recipient verification recorded separately
**Date:** 2026-10-04; corrected 2026-10-08 for candidate 1.0.47 (47)
**Supersedes:** The ordinary Messages package requirement in ADR-RS-007 on iOS and macOS

## Decision

Ordinary Messages routes supply rendered PNG artwork and encrypted rune text without
passing a `.runescribe` message package to Messages. This applies to direct iOS
MessageUI composition, Quick Share, and encrypted-message Customize Share on both
platforms. The actual recipient transcript remains unverified.

The direct iOS composer requires valid PNG artwork and an active scoped transfer.
`RuneScribeMessageComposerConfiguration` attaches only `Rune-Scribe.png` and places
runes in the composer body. Attachment acceptance records the actual PNG result.
Core message artifacts remain key-free and require no key delivery.

For iOS Quick Share and Customize Share, the activity controller contains only package
items for file destinations and excludes Apple's native `.message` activity.
`RuneScribeMessageArtworkActivity` captures the validated PNG and rune body separately;
it does not consume the sheet's package items. It presents its own
`MFMessageComposeViewController` and records that composer's terminal result and
attachment acceptance. Missing or invalid artwork prevents this Messages activity.

For macOS, `.messageFile` retains the package URL for the ordinary share picker.
Only the authoritative `.composeMessage` service is replaced by a custom picker service.
Its handler forwards exactly a validated `NSImage` and rune `NSString` to the real
Messages service. Invalid or missing artwork removes that Messages entry. The wrapper
cannot finish the transfer: only the real native service's callbacks report
`completedBySystem`, `cancelled`, or `failed`, never MessageUI's `sentConfirmed`. The existing
once-only completion gate and scoped transfer lifetime remain in use.

## Compatibility and impact

Package construction, wire formats, supported file import, Mail/AirDrop package routes,
and explicit cipher export remain unchanged. The recipient imports the cipher through
a separate invitation, then pastes the complete Messages rune text into Rune Scribe to
decode. That rune-text intake carries the encrypted envelope rather than package
presentation metadata or provenance. File routes retain supported package intake.
No sender label creates a contact or rebinds a relationship.

The interactive cipher invitation in ADR-RS-014 remains separate and unchanged. This
decision introduces no new dependency, persistence migration, or key transport.
Native completion callbacks retain ADR-RS-006 semantics.

## Evidence boundary

The October 8 screenshot again shows an unwanted document card, but it does not
establish the sending platform or exact runtime path. Source inspection found that
the previous macOS launcher still passed only the package URL. The previous iOS route
relied on activity-item omission; the corrective implementation removes that dependency
by excluding the native file-based Messages activity and composing separately. Neither
finding identifies the screenshot's exact mechanism.

Current native payload and routing checks belong in the
[1.0.47 qualification summary](../../verification/release-1.0.47/QualificationSummary.md).
The [1.0.46 qualification summary](../../verification/release-1.0.46/QualificationSummary.md)
retains earlier focused results and Simulator limitations without relabeling them.
No actual sent-recipient transcript, physical-device handoff, or shipment is claimed.
