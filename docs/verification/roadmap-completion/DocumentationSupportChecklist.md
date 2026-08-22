# Documentation and Support Completion Checklist

**Application:** Rune Scribe 1.0.38 (build 38)
**Program state:** Code and source complete for the supported host/Simulator scope; owner test required; not shipped.

This checklist is the BAS-010 publication boundary. A checked item means the named
source describes the same implementation and no-ship state; it does not mean a
physical-device, live-service, distribution, or store gate has passed.

- [x] `README.md` describes the current module graph, four production Elven providers,
  local-first optional CloudKit sync, optional Game Center reporting, themed sharing,
  compatibility behavior, and supported import paths.
- [x] `CHANGELOG.md` records the source-complete roadmap scope without changing version
  1.0.38 or build 38 and without claiming shipment.
- [x] `docs/architecture/RoadmapAlignment.md` and its linked decisions describe Runtime
  mediation, package compatibility, imported fonts, presentation state, share terminal
  evidence, progression authority, private cloud merge, and report-only Game Center.
- [x] `docs/architecture/ModuleGraph.md`, `docs/architecture/ForsettiCompliance.md`, and
  `docs/architecture/MigrationDecisions.md` remain aligned support sources for the
  repository Wiki and architecture documentation.
- [x] `docs/PRIVACY.md` distinguishes synchronized progression metadata from device-only
  cipher keys, plaintext, contacts, message data, and local Vault state.
- [x] `docs/SUPPORT.md` covers offline/local behavior, optional-service states, import and
  sharing troubleshooting, account changes, fallback presentation, and support contact.
- [x] `docs/APP_STORE_SUBMISSION.md` contains aligned customer-facing and review copy while
  leaving live App Store Connect configuration, signing, upload, and submission pending.
- [x] `docs/platform-notes.md` documents macOS, iPhone, and iPad behavior and the exact
  hardware/live-service boundary.
- [x] `docs/architecture/decisions/ADR-RS-005-forward-compatibility.md` and
  `ADR-RS-012-cipher-invitation-presentation.md` document legacy readers, the typed
  writer, update-required outcomes, and Norse fallback.
- [x] The final compatibility matrix identifies the frozen source-level legacy reader
  model separately from current macOS, iPhone Simulator, and iPad Simulator execution.
- [x] Troubleshooting copy never recommends deleting local Vault data for CloudKit or
  Game Center account, denial, offline, corruption, or retry states.
- [x] The owner handoff requires physical-device, live iCloud/Game Center, provisioning,
  signing, store, archive/export, rollout, and shipment approval outside this program.

The final handoff must retain both stop statements:

**NOT SHIPPED — OWNER TEST REQUIRED**

**Do not ship until the owner approves the test results.**
