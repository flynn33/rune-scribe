# Rune Scribe 1.0.40 Qualification Summary

**Build:** 40

**Status:** Repository-qualified release candidate — not shipped

**Authority:** Operator-approved product-release scope and repository-controlled release gates

This record tracks the product-focused release bar for version 1.0.40 build 40. The
superseded v4.3 instruction package remains noncontrolling verification history. Physical
hardware observation is not required; supported Simulator, hosted, and deterministic
coverage is the qualification boundary without reopening the noncontrolling package
audit.

The machine-readable [qualification evidence](QualificationEvidence.json) binds the
current results to candidate revision `d1754b250429c17d885401388cb17ec32f1bde59`, records
the test and product-inspection log hashes, and keeps retained UI evidence, report-only
architecture findings, and external publication work explicitly separated.

## Verified facts

- `project.yml`, the generated Xcode project, and Debug and Release build settings for
  the iOS app, macOS app, and macOS parity host resolve to marketing version `1.0.40`
  and build `40`. Their Info.plists inherit those values.
- Core, Progression, and UI compiled descriptors and module manifests are version
  `1.0.40`. Theme-provider and Theme Coordinator manifests retain their independent
  contract version `1.0.0`.
- The final source passes **1,238/1,238 Swift tests**: **1,101 XCTest cases** and
  **137 Swift Testing cases**. It also passes **255/255 Python tests**.
- The executable shipping architecture guard passes all **17/17 ratchets**. The stricter
  Forsetti P11 scanner remains report-only and is not represented as a compliance pass;
  its architecture backlog is outside the product-release gate unless it exposes a
  concrete product, security, data-loss, or shipping-guard failure.
- Norse validation passes **60 semantic rules** and **25/25 negative mutations**.
  Legacy remediation passes **18/18 mutations**, and evidence hardening passes
  **27/27 tests**.
- All **315** production theme outputs are present and integrity-pinned: 70 Norse,
  65 Moonleaf, 60 Sunspire, 60 Wildwood, and 60 Gloamthorn resources. The audit found
  no missing declarations, stale pins, duplicate identifiers or basenames, or
  cross-theme byte collisions.
- The shared privacy manifest is valid, belongs to both shipping products, disables
  tracking, declares no collected data, and declares only the reviewed file-timestamp
  reasons. Shipping-product mutation coverage rejects **28/28** promised privacy and
  product-integrity mutations.
- Focused regressions pass for Norse unlock-audio resolution and the four optional
  Codex frame thumbnails.
- The message result and Share Builder recompute first-key delivery disclosure from the
  current cipher relationship, including link and unlink changes made after encoding.
  The received-message dismissal action is labeled Done and explicitly describes that it
  clears the pending message; focused regressions cover both corrections.
- Keychain writes use update-first upserts in the Data Protection Keychain with
  `whenUnlockedThisDeviceOnly`. On macOS, legacy migration reads the current classic
  default keychain without deleting its source, verifies replacement bytes and
  accessibility, and preserves imported or restored keychain entries. Explicit deletion
  verifies a protected blocker before removing the current value, preventing remigration.
- The iOS Release build passes. The arm64-only unsigned macOS Release build passes.
- Local ad-hoc built-product content, resource, privacy, signature, Hardened Runtime, and
  entitlement inspection passes **101/101 checks**. The reusable
  [`qualify-release-products.sh`](../../../scripts/qualify-release-products.sh) command
  reproduces both Release builds and the inspection without launching Simulator.
- Retained prior evidence records the headless iPhone 17 Pro UI run on iOS 26.5 with **7
  tests passed**, **1 iPad-only test skipped**, and **0 tests failed**.
- Retained prior evidence records the headless iPad Pro 13-inch (M5) UI run on iOS 26.5
  with **5 tests passed**, **3 phone-specific tests skipped by design**, and **0 tests
  failed**. Neither retained run is represented as current-candidate source-bound evidence.
- Retained prior post-remediation keyboard evidence records clean iPhone and iPad
  Simulator results: the
  focus-aware Done control is present and hittable, dismisses the keyboard, preserves
  the iPad workspace viewport, and produces no invalid-frame-dimension entries in the
  application log.
- Named regression, architecture, source, mutation, privacy, asset, and built-product
  checks report no known release-blocking defects. The report-only Forsetti P11 result is
  retained separately rather than mislabeled as a passing sweep.

## Repository qualification

All repository-controlled release gates pass.

## External distribution work

The 101 local product checks use ad-hoc signatures and explicitly do not assess a
distribution identity or provisioning profile. Distribution signing, archive, export,
notarization, App Store upload, and rollout remain external publication actions rather
than source-qualification gates.

## Publication boundary

No archive has been exported, notarized, uploaded, released, or rolled out by this
qualification work. Repository qualification establishes a release candidate; it does
not establish shipment.
