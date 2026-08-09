# ADR-RS-001: Module Packaging and Target Graph

**Status:** Accepted; upstream integration blocked
**Date:** 2026-08-09

## Decision

Retain the macOS and iOS XcodeGen application targets as thin composition roots and
retain app-owned implementation targets in the local Swift package. The final Codex
runtime graph will consume official Forsetti public products plus
`RuneScribeContracts`. No runtime implementation target may import another runtime
implementation target.

The host may import factories and platform-adapter products solely to compose the
runtime. `RuneScribeTestSupport` remains test-only and must never be linked into a
shipping application or shipping package target.

`RuneScribeRuntimeCore` and `RuneScribeUIRuntime` are transitional app-owned
infrastructure, not the final upstream integration. The earlier decision in
[`MigrationDecisions.md`](../MigrationDecisions.md) that Forsetti must never be a
dependency is superseded for Codex work.

## Upstream gate

The inspected official Forsetti source is commit `f0199a4`, source version `0.1.5`.
It has no release tag and does not yet expose all required generalized entitlement,
runtime reconciliation, keyed contribution, opaque resource-resolution, and
app-defined service APIs. Rune Scribe will not add an unused package dependency or copy
framework source while that gate is unresolved.

Integration may begin only after an official semantic release exposes those APIs with
tests and migration documentation. At that point the package graph, manifests,
composition root, and architecture guard must be changed together.

## Consequences

- The current behavior-preserving Core/UI split remains usable and testable.
- Current local runtime success is not reported as Wave 0B completion.
- Direct runtime-module imports, copied framework source, private patches, and
  developer-machine checkout assumptions remain prohibited.
- The architecture guard must eventually allow the one pinned official dependency
  while continuing to reject vendored or privately modified framework code.
