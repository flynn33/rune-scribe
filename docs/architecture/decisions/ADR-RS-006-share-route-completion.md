# ADR-RS-006: Share-Route Completion Semantics

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Accepted
**Date:** 2026-08-09

## Decision

Every share operation has a stable operation ID and correlation ID. Presentation is
not completion. A route reports `presented` when system UI appears, followed by at most
one terminal result:

| Result | Meaning | May consume first delivery or progression? |
|---|---|---:|
| `cancelled` | The user or system cancelled | No |
| `completedBySystem` | A public operating-system callback reported completion | Eligible under route policy |
| `sentConfirmed` | MessageUI returned `.sent` | Yes, only if any required attachment was accepted |
| `failed` | Presentation or handoff failed | No |
| `completionUnavailable` | The route exposes no reliable terminal callback | No |

`presented` is nonterminal and never awards progress. Opening a Share sheet, exporting a
file, copying text, or observing a tap does not prove delivery. A generic completion
does not claim recipient identity, app installation, purchase, reading, or successful
decryption.

Key-delivery state and progression share evidence are separate domain facts. A linked
first delivery advances only after an eligible terminal result. Duplicate callbacks
for one operation are ignored. Artifact cleanup follows its lifetime policy regardless
of whether the outcome is progression-eligible.

## Consequences

- Existing iOS native-share and MessageUI adapters are a foundation but their contract
  must be migrated to this complete vocabulary before progression events ship.
- Cancelled, failed, unavailable, and duplicate outcomes never grant progress.
- Tests cover every route/result combination and required-attachment state.
