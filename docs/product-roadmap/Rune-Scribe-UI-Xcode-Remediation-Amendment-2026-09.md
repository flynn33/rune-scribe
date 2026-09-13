# UI and Xcode remediation amendment — September 2026

## Scope

This amendment maps the bounded version 1.0.41 build 41 UI/Xcode repair onto the
existing Codex roadmap. It does not replace the locked v1.0 system specification or
roadmap, authorize new product features, change cryptographic or storage policy, or
alter the permanent app-owned architecture boundary.

## Roadmap mapping

| Package work | Existing roadmap area | Current disposition |
| --- | --- | --- |
| W01 baseline and reconciliation | BAS verification and release hygiene | Current local/remote state and pre-existing in-scope edits preserved before repair. |
| W02 responsive workspace | THM responsive composition | One geometry-driven, scrollable production workspace replaces qualification-only width branches. |
| W03 canonical result surface | THM Artifact rendering | Result routes use the canonical themed Artifact preview rather than a duplicate nested message shell. |
| W04 payload and paging truth | DOM message integrity and THM presentation | Full payload remains available; page models are bounds-safe and labels report actual page state. |
| W05 accessibility, lock, and motion | BAS accessibility and DOM security | Platform control floors are explicit and App Lock removes protected content from interaction and accessibility. |
| W06 import/share integration | SHR sharing and receiving | Existing typed package, fallback, preview, and import rails are preserved; no new transport was added. |
| W07 Xcode qualification | BAS/REL build and test rails | The actual macOS and iOS app targets and normal application routes receive focused coverage. |
| W08 documentation and wiki | BAS documentation and release status | Active sources and the live wiki point to the current source-bound qualification record. |
| W09 integration and synchronization | REL repository handoff | Source and evidence follow the normal protected-branch workflow; shipment remains owner-operated. |

## Acceptance boundary

The current decision and exact evidence are maintained in
[`../verification/ui-xcode-remediation/QualificationSummary.md`](../verification/ui-xcode-remediation/QualificationSummary.md).
Earlier qualification, parity, and Theme Fidelity records remain historical evidence
for the source they measured. They are not relabeled as current-source results.

Fresh distribution-signed iOS and macOS archives and App Store exports were qualified
after the source repair. App Store Connect validation, upload, submission, rollout, and
shipment remain outside this amendment and were not performed.
