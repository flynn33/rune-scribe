# Forsetti Architecture Supersession Index

The [controlling Forsetti policy](FORSETTI_CONTROLLING_POLICY.md) is the sole current authority for runtime mediation, module boundaries, operational I/O, persistent Settings, Theme ownership, and dependency policy.

## Current guidance

| Document | Treatment |
|---|---|
| `README.md` | Current product overview; its architecture summary must match the controlling policy. |
| `docs/architecture/RoadmapAlignment.md` | Current human-readable roadmap and Agent Coding gate summary; it must match the machine-readable ledger. |
| `docs/architecture/decisions/ADR-RS-001-module-packaging-and-target-graph.md` | Superseded and replaced by the permanent app-owned dependency policy. |
| `docs/verification/roadmap-alignment.json` | Current machine-readable roadmap; the former external-release gate is superseded. |
| `docs/product-roadmap/Rune-Scribe-Codex-System-Spec-v1.0.md` | Hash-locked historical input (`7c4c460815064fca87a6769766fb875f267eb692795bbab2635eec5d55d8f88d`); authority is limited to nonconflicting product requirements and compatibility anchors. Every framework-ownership or dependency directive is superseded. |
| `docs/product-roadmap/Rune-Scribe-Codex-Current-App-Delta-and-Implementation-Roadmap-v1.0.md` | Hash-locked historical input with a current publication-boundary banner (`1c6e3cf79e6cd60d105c848a5fab65418daac799ae94db0d0c61504fc2c5679a`); authority is limited to nonconflicting product sequencing and compatibility evidence. Every external-framework prerequisite, upstream work package, hardware gate, and dependency directive is superseded. |

The historical planning bodies remain preserved. The current-app delta roadmap adds
only its explicit publication-boundary banner; the recorded hashes pin both complete
files. No statement inside either historical body constitutes current permission for an
external dependency, hardware gate, or override of the controlling policy. Any further
content change invalidates this exception and requires a fresh conflict audit.

## Historical architecture and compliance evidence

The following documents retain measured source inventories, compatibility anchors,
build results, test counts, and historical parity observations. They do not define
current architectural compliance, acceptance, completion, blocker status, residual
work, PASS/FAIL, or pull-request readiness:

- `docs/architecture/ForsettiCompliance.md`;
- `docs/architecture/ContractsAndCapabilities.md`;
- `docs/architecture/ModuleGraph.md`;
- `docs/architecture/MigrationDecisions.md`;
- `docs/verification/ForsettiComplianceReport.md`;
- `docs/verification/ForsettiMigrationBaseline.md`;
- `docs/verification/ForsettiMigrationReconciliation.json`;
- `docs/verification/ForsettiTestReconciliation.json`;
- `docs/verification/BuildAndTestReport.md`;
- `docs/verification/FeatureParityReport.md`;
- `docs/verification/ProgressionImplementationReport.md`;
- `docs/verification/feature-parity-matrix.json`;
- `docs/verification/p7-test-matrix.json`.

Where these records describe lookup-time authorization as runtime mediation, allow a UI or host to retain provider-owned services, allow modules to retain raw platform adapters, place operational I/O or durable Settings in UI code, require restart-only eligibility, or describe the app-owned runtime as temporary, those conclusions are superseded. A recorded test result remains historical evidence unless a later run disproves it.

## Retained product decisions

ADR-RS-002 through ADR-RS-012 remain effective only where they do not conflict with the
controlling policy. Compatibility identifiers, wire formats, resource budgets,
persistence decisions, and privacy limits remain in force. Hardware-only observations
are owner-operated optional validation outside Agent Coding scope and have no gating
effect.

## No paper compliance

A document status or table cell cannot close a finding. Current source, runtime
behavior, executable guards, positive tests, negative mutations, supported platform
builds, static inspection, and final artifact membership determine Agent Coding
compliance.
