# Rune Scribe Codex Architecture Decisions

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

These records implement the decision freeze required by Wave 0A of the locked
[Codex implementation roadmap](../../product-roadmap/Rune-Scribe-Codex-Current-App-Delta-and-Implementation-Roadmap-v1.0.md).
They supplement the completed compatibility-migration decisions in
[`MigrationDecisions.md`](../MigrationDecisions.md). If the two sets conflict, these
roadmap-specific records control Codex work.

[ADR-RS-001](ADR-RS-001-module-packaging-and-target-graph.md) is superseded. The
app-owned runtime is permanent, and the repository must never add an external Forsetti
package, binary, source copy, fetch, submodule, or local checkout.

| Record | Decision | Status |
|---|---|---|
| [ADR-RS-001](ADR-RS-001-module-packaging-and-target-graph.md) | Module packaging and target graph | Superseded by controlling policy |
| [ADR-RS-002](ADR-RS-002-cipher-and-script.md) | Cipher material versus Script presentation | Accepted |
| [ADR-RS-003](ADR-RS-003-legacy-font-compatibility.md) | Legacy custom-font compatibility | Accepted |
| [ADR-RS-004](ADR-RS-004-typed-runescribe-container.md) | Typed `.runescribe` container | Accepted and wire layout frozen |
| [ADR-RS-005](ADR-RS-005-forward-compatibility.md) | Old-app forward compatibility | Accepted: legacy-only outbound |
| [ADR-RS-006](ADR-RS-006-share-route-completion.md) | Share-route completion semantics | Accepted |
| [ADR-RS-007](ADR-RS-007-themed-follow-up-transport.md) | Themed follow-up transport | Accepted; implementation deferred |
| [ADR-RS-008](ADR-RS-008-progression-persistence.md) | Progression persistence technology | Accepted; implemented in 1.0.37 |
| [ADR-RS-009](ADR-RS-009-relationship-token.md) | Relationship-token derivation | Accepted |
| [ADR-RS-010](ADR-RS-010-theme-resource-budgets.md) | Theme resource delivery and budgets | Accepted initial limits |
| [ADR-RS-011](ADR-RS-011-game-center-records.md) | Game Center App Store record strategy | Blocked on App Store configuration review |
| [ADR-RS-012](ADR-RS-012-cipher-invitation-presentation.md) | Cipher-invitation presentation | Blocked on physical-device spike |

Reversing an accepted decision requires a successor record that identifies the
compatibility, migration, security, privacy, distribution, and rollback impact.
