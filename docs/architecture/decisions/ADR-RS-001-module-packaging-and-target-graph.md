# ADR-RS-001: Module Packaging and Target Graph

**Controlling policy:** [Rune Scribe Controlling Forsetti Policy](../FORSETTI_CONTROLLING_POLICY.md)

**Status:** Superseded by the controlling Forsetti policy
**Date:** 2026-08-09

## Decision

The historical decision retained the macOS and iOS XcodeGen application targets as
thin composition roots and retained app-owned implementation targets in the local Swift
package. Those target-graph and Test Support decisions remain useful. Its planned
external-framework integration does not.

The host may import factories and platform-adapter products solely to compose the
runtime. `RuneScribeTestSupport` remains test-only and must never be linked into a
shipping application or shipping package target.

The controlling replacement makes `RuneScribeRuntimeCore` the permanent app-owned
control plane. No runtime implementation target may import another runtime module
implementation, and no external Forsetti dependency is permitted.

## Supersession

The external-release gate and conditional dependency allowance are removed. Required
entitlement, reconciliation, contribution, resource, settings, I/O, and service
capabilities must be implemented and tested in the app-owned runtime.

## Consequences

- The current behavior-preserving Core/UI split remains usable and testable.
- Historical test and compatibility evidence remains evidence, not current compliance.
- Direct runtime-module imports, external packages, copied framework source, binaries,
  fetch scripts, submodules, and developer-machine checkout assumptions are prohibited.
- The architecture guard must enforce that prohibition permanently.
