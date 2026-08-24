# Rune Scribe Codex Roadmap Remediation Amendment v1.1

**Document version:** 1.1  
**Amends:** `Rune-Scribe-Codex-Current-App-Delta-and-Implementation-Roadmap-v1.0.md`  
**Original roadmap date:** August 7, 2026  
**Amendment date:** August 23, 2026  
**Decision status:** Controlling remediation amendment  
**Product:** Rune Scribe for macOS and iOS  
**Public shipment authorized:** No  
**Owner-testable release candidate authorized:** Yes

## 1. Purpose

This amendment resolves the implementation-authority and verification ambiguities identified by the August 23, 2026 roadmap audit. It does not replace or rewrite the original v1.0 roadmap. The original remains immutable historical authority; this document records the accepted variances and defines the mandatory remediation needed to reach a complete, simulator-qualified release candidate.

## 2. Authority order during remediation

When implementation sources conflict, use this order:

1. Active user instructions.
2. This remediation package and its machine-readable gates.
3. `docs/architecture/FORSETTI_CONTROLLING_POLICY.md` in the repository.
4. The locked Rune Scribe Codex System Specification v1.0, except where later Forsetti ownership clarification changes operational ownership without changing product behavior.
5. The original Current-App Delta and Implementation Roadmap v1.0 as amended here.
6. The August 23, 2026 roadmap implementation audit and finding records.
7. Existing implementation details that do not conflict with the above.

## 3. Accepted architecture variance

### 3.1 FOR-001 through FOR-011

The original roadmap expected public extensions to an external Forsetti framework release. The project later adopted a permanent app-owned Forsetti operating environment and explicitly prohibited external Forsetti dependencies.

For this remediation:

- FOR-001 through FOR-011 are not called “completed as written.”
- They are classified `VARIANCE_ACCEPTED_APP_OWNED_EQUIVALENT`.
- Their replacement requirements are the controlling repository Forsetti policy, architecture guard, runtime mediation tests, negative mutation tests, and permanent dependency prohibition.
- No external package, submodule, binary, source copy, or remote Forsetti dependency may be added.
- Existing app-owned runtime behavior must remain intact while remediation work is performed.

This variance closes governance ambiguity without reopening the architecture.

## 4. Verification variance: no physical hardware

The following original work packages or exit criteria referenced physical-device activity:

- BAS-006;
- SHR-001;
- SHR-015 when interpreted as device-only visual qualification;
- physical-device portions of Wave 4, Wave 5, Wave 6, and the global test matrix.

They are replaced for Agent Coding qualification by:

- macOS hosted tests;
- iPhone Simulator tests;
- iPad Simulator tests;
- runtime presentation-session test doubles;
- deterministic Share, Messages, camera, Contacts, CloudKit, and Game Center adapters;
- simulator screenshots and accessibility audits;
- release-product inspection;
- owner-test package generation.

No physical hardware test is mandatory, and no task may stop for lack of hardware.

## 5. External-account variance

Live CloudKit, live Game Center, App Store Connect, provisioning, distribution signing, notarization, TestFlight, review, rollout, and public release are outside the autonomous source-remediation boundary.

The replacement gate requires:

- complete source adapters;
- deterministic local and simulator qualification;
- entitlement and configuration inspection;
- injected success, cancellation, restriction, retry, corruption, offline, and account-change tests;
- unsigned or ad-hoc Release products where distribution credentials are unavailable;
- clear nonshipment status.

The source candidate may be complete without live accounts. It may not be called publicly shipped.

## 6. Release-candidate definition

For this program, “shippable state that the owner can test” means:

- all product behavior required by the locked specification is implemented for the supported source and simulator boundary;
- all open audit findings are closed by source, tests, or this formal variance;
- macOS and iOS Release products build;
- required macOS, iPhone Simulator, and iPad Simulator tests pass;
- no known source defect remains open;
- data and payload compatibility are preserved;
- the final source is bound to a deterministic source manifest;
- an owner-test package is produced;
- no public distribution action is performed.

The formal terminal state is `RELEASE_CANDIDATE_READY`.

## 7. Mandatory remediation work packages

### REM-001 — Establish a clean, self-verifying baseline

- Preserve original work.
- Record source hash, version/build, tools, schemes, and installed Simulator runtimes.
- Generate a deterministic source manifest before changes.
- Copy this amendment into `docs/product-roadmap/` without modifying the original v1.0 files.
- Update the roadmap alignment ledger to understand `VARIANCE_ACCEPTED_APP_OWNED_EQUIVALENT`, `SIMULATOR_REPLACEMENT`, and `NON_GATING_EXTERNAL`.

### REM-002 — Prove and retain the Norse visual remediation

- Ensure Codex cards, Relic/Seal/Frame artwork, settled workspace Artifact rendering, Settings, Vault, and Artifact browsers use validated runtime image references.
- Ensure all five current providers use the same provider-neutral scaffold.
- Supersede the earlier completion evidence that represented the visually incomplete source.
- Regenerate evidence against the final source manifest.

### REM-003 — Implement the user-facing Share Builder

- Add a provider-neutral Share Builder for encrypted messages and cipher invitations.
- Preserve one-action Quick Share.
- Support Codex, Relic, optional Seal, optional Frame, and effects preference when supported.
- Render a live bounded preview.
- Display a fixed, non-themeable security summary.
- Support reset to validated defaults and optional save-as-default.
- Launch the runtime-owned share presentation from the builder.

### REM-004 — Correct Cipher Library share hierarchy

- Make the typed themed `.runescribe` cipher invitation the primary Share representation.
- Preserve Export, QR, and compact link as clearly labeled compatibility/fallback actions.
- Use the same selection, preview, completion, and cancellation rails as message sharing.

### REM-005 — Surface required Base Theme failures

- Keep emergency Norse fallback for reading and decoding.
- Preserve structured details for required-resource failures.
- Publish the failure through runtime diagnostics.
- Show a nonblocking root/workspace warning, not only a Settings note.
- Make shipping-product qualification fail when the built required Base provider cannot fully load and validate.

### REM-006 — Complete Appearance defaults

- Add per-Codex default Relic.
- Add per-Codex default Seal or None.
- Add per-Codex default Frame or None.
- Add effects preference `Full`, `Reduced`, and `Off`.
- Use the same runtime-owned Settings values for workspace selection, Quick Share, Share Builder initialization, and Settings.
- Respect system Reduce Motion as an upper bound.

### REM-007 — Finalize release-candidate Norse provenance

- Treat the current audited `Resources/Production` bytes as the remediation release-candidate baseline.
- Do not redesign or replace the artwork.
- Remove obsolete placeholder/candidate naming from active production tooling and manifests.
- Regenerate hashes, byte counts, dimensions, paths, rights references, accessibility references, and source provenance from the exact final bytes.
- Mark the record `release-candidate`, not publicly approved shipment.

### REM-008 — Make evidence verifiable without Git

- Add deterministic `SOURCE-MANIFEST.json` generation.
- Bind every remediation evidence record to the source manifest SHA-256.
- Make completion and documentation checks operate from the source manifest when `.git` is absent.
- Refresh the roadmap alignment ledger after all remediation changes.

### REM-009 — Compose the Theme background at the root shell

- Mount the runtime-selected, provider-neutral application background in the root application `ZStack`.
- Use explicit safe-area and clipping behavior.
- Convert the header background use to a header-specific scrim/decoration instead of relying on overdraw.
- Verify all primary screens share the root background contract.

### REM-010 — Correct documentation and portable contract hygiene

- Correct stale runes-only follow-up comments and documentation.
- Add the required `CoreFoundation` import or replace the Core Foundation Boolean check with a portable typed decoding approach.
- Preserve strict input validation.
- Update support, privacy, architecture, roadmap, and release-candidate documentation to match actual behavior.

### REM-011 — Release-candidate qualification

- Run complete package, architecture, roadmap, documentation, mutation, compatibility, security, privacy, accessibility, macOS, iPhone Simulator, iPad Simulator, and shipping-product gates.
- Produce deterministic screenshots for Share Builder, Cipher Library themed share, Base failure banner, Appearance defaults, Norse workspace, and fallback states.
- Build macOS and iOS Simulator Release products.
- Produce the owner-test package.
- Increment version/build once at final integration.

## 8. Mandatory product behavior retained from v1.0

This amendment does not change the following locked requirements:

- Rune Scribe remains a communication utility first.
- One cipher can be presented through multiple Codices.
- Cryptographic state and presentation state remain separate.
- Exactly one user-facing UI Module exists.
- Runtime modules do not communicate directly.
- Theme Modules are non-UI providers.
- Progression remains the ownership authority.
- Game Center never grants or revokes ownership.
- Incoming valid content is readable regardless of Theme ownership.
- `.runescribe` remains the canonical secure transport.
- Quick Share remains available.
- Customize Share is optional but fully implemented.
- Ownership and Encounter remain distinct.
- Existing payloads and data remain readable.
- No trading, random paid drops, or authoritative scarcity is added.

## 9. Explicitly nonrequired work

The remediation must not add:

- new production Codices or Artifacts;
- a Quick Look extension;
- an iMessage extension;
- live referral attribution;
- a backend or Forge Ledger;
- public telemetry;
- StoreKit products;
- physical-device gates;
- live-service gates;
- public shipment actions.

## 10. Amendment completion

The amendment is satisfied when every mandatory remediation work package and every required machine-readable gate passes against one final source manifest and the owner-test package exists.
