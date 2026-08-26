# Theme Fidelity v4 Verification

The files under `authority/` are immutable comparison inputs. They are not production resources and must never be updated to match a failing capture.

## Authority manifest

`authority/asset-manifest.json` is the source of truth. Both commands use this fixed repository path; there is no alternate-manifest option. Each `assets` entry requires:

- `path`, relative to `authorityRoot`;
- lowercase SHA-256 and exact `[width, height]` dimensions;
- owning `theme`, semantic `role`, and authority `tier`.

The checker scans every image under `authorityRoot`, all declared `shippingRoots`, and any available `rejectedRoots`. It fails for missing or undeclared authority images, stale hashes or dimensions, placeholder images, rejected assets in shipping resources, and byte-identical authority images in shipping resources.

```sh
python3 scripts/check-theme-visual-authority.py
python3 -m unittest scripts.tests.test_theme_visual_fidelity_tooling -v
```

## Capture comparison

Comparison policy is manifest-pinned. A legacy full-frame `comparisons` entry supplies a stable `id`, the exact canonical matrix `capture` filename, a declared `reference`, an optional declared binary `mask`, and an in-bounds `focalRegion`. A `responsive-regions-v1` entry instead pins one or more immutable golden `sourceCrop` rectangles and crop digests, fixed thresholds per region, the candidate `elementFrames` IDs, the exact `stateSeedSHA256`, and layout assertions. Responsive masks are allowed only for platform-controlled pixels and must use a digest-pinned `platform-controlled-mask` asset. The command accepts no mask or threshold override:

```sh
python3 scripts/compare-theme-captures.py \
  --comparison-id <id> \
  --candidate <capture.png> \
  --capture-record <capture.capture.json> \
  --output <evidence/path-stem>
```

The fixed gates are luminance SSIM `>= 0.92`, edge SSIM `>= 0.94`, focal SSIM `>= 0.95`, median DeltaE `<= 4`, p95 DeltaE `<= 12`, and fraction of scored pixels with DeltaE above 20 `<= 0.02`. Responsive candidate rectangles come only from top-left-origin pixel frames in the explicit capture record, must preserve each source crop's aspect ratio, and produce one aggregate report plus a vertically packed heatmap atlas. The comparator writes `<path-stem>.json` and `<path-stem>.heatmap.png`, exits `0` for pass, `1` for a metric failure, and `2` for invalid inputs or policy. Neither tool writes inside `authorityRoot`.

Python requires Pillow, NumPy, and scikit-image. Approved captures, masks, and comparison records are added through reviewed manifest changes; the tools provide no golden-update mode.

## Capture matrix

`baseline-source-context.json` records the pre-remediation source reconciliation. The package and fetched repository resolve to the same pinned commit, `91344d384b1060fd9b7d1a8839af7029fe889ec8`; the package's declared `1.0.38 (38)` metadata is stale relative to that commit's `1.0.39 (39)`, so the repository version and build are preserved.

`Golden-Screenshot-Matrix.json` is a byte-for-byte repository copy of the controlling matrix. The capture orchestrator verifies its SHA-256 before running and requires the exact five themes, 20 named surfaces, and four destinations. The shared hosted test registers every theme provider, seeds deterministic owned entitlement state, resolves provider resources through the runtime, and renders the actual shared visual components. It captures the active iPhone and iPad Simulator dimensions and renders both fixed macOS destinations.

The controlling Simulator classes are iPhone 17 Pro portrait (`1206x2622`, scale `3`) and iPad Pro 13-inch portrait (`2064x2752`, scale `2`). The orchestrator selects a booted target-class Simulator ahead of every substitute. An explicitly requested lesser device is rejected whenever a preferred target-class device is booted. If the target class is not booted, the only accepted deterministic substitutes are the fixed prior iPhone Pro and iPad Pro 12.9-inch classes in `theme_fidelity_destination_policy.py`; the selected exact model name, model class, substitution reason/rank, device-type identifier, dimensions, scale, and UDID are written to `simulator-destinations.json`. Arbitrary iPhone and iPad family members are not accepted. The command never boots a destination and the output directory must be absent or empty:

```sh
python3 scripts/capture-theme-fidelity-matrix.py \
  --phase baseline \
  --output-root <absolute-empty-output-directory> \
  --iphone-id <booted-iphone-identifier> \
  --ipad-id <booted-ipad-identifier>
```

Every capture record must identify the actual active visual-plan revision and rendered resources through `visualPlanRevision`, a sorted, non-empty, unique `renderedResourceIDs` array, and exact `renderedResourceBindings` entries containing each resource's owning Codex and revision. The indexer loads the five fixed production integrity manifests from the source tree (`resources[].resourceHandle` for Norse and `files[].resourceID` for Moonleaf, Sunspire, Wildwood, and Gloamthorn), rejects cross-Codex ownership or revision drift, and records a baseline diagnostic when a runtime-descriptor resource is missing from its owning integrity manifest. Final indexing blocks that diagnostic. This permits truthful shared surfaces such as the share builder to render cards from more than one Codex without weakening ownership validation; every capture must still render at least one resource from its active Codex. A valid received-cipher safe preview must use only active-Codex IDs and be a subset of the active-Codex rendered bindings. This is a membership and truthful-rendering check; a screenshot is not required to attest every resource declared by its theme descriptor or integrity manifest. Each record also carries the complete deterministic `contentSeed` and a lowercase `stateSeedSHA256` computed from its UTF-8 JSON with sorted keys and compact separators; the indexer and comparator independently recompute that digest, and `stateSeed` remains the fixture ID. `viewportAssertions.requiredElementIDs` is the exact sorted, unique route requirement list used to calculate clipping; `requiredElementCount` must equal its length and the sorted, unique `clippedElementIDs` array must be a subset of it. A required ID without a frame is accepted during baseline only when it is explicitly listed as clipped, producing a diagnostic that final indexing blocks. `elementFrames` binds the post-layout production probes to sorted, unique element IDs in top-left-origin screenshot pixels at the declared capture scale; responsive comparisons consume these attested rectangles rather than guessed crops.

Baseline is structural evidence. Decoding, record/digest binding, dimensions, matrix cardinality, exact XCTest identity and outcome, result-bundle destination binding, attachment content UTIs, device identity, toolchain identity, and pre-build/post-build source equality are mandatory. Extraction requires both the exact selected Simulator UDID and exact `modelName`; a family-name prefix is insufficient. The indexer independently binds the extraction bundle to the hashed selection document and verifies that every iPhone/iPad capture dimension and scale matches the selected approved model policy. Blank/detail, byte-duplicate, layout-clipping, rendered-resource, material-similarity, duplicate-visual-class, and unbalanced-appearance-transition findings are recorded as nonblocking diagnostics.

Use `--phase final` for Phase 10. Final blocks every baseline diagnostic and activates the imported v4.2 executable authority: exactly 400 entries and 1,104 one-to-one reference mappings must pass. The orchestrator runs all six Release result bundles—hosted and XCUI bundles for iPhone, iPad, and macOS—and then executes every declared image metric, structural assertion, runtime probe, and negative invariant. It does not accept a prebuilt comparison index. Each result is bound to the exact candidate source, capture record, authority mapping, passing report digest, and any required candidate capture or heatmap digest. The v1.2 executor independently recomputes the declared results and writes a 400-entry, 1,104-mapping visual-comparison index. A successful run produces 400 canonical full-screen PNGs and records, the exact focal candidate captures and heatmaps required by the mappings, six hashed result bundles, an extraction report, hashed toolchain provenance, equal pre-build and post-build source manifests, a capture index, and a source-bound run report. It does not update authority images or comparison policy.

After the remaining source-bound gates have produced their current logs and structured results, assemble the minimum v4.2 evidence contract and its true 40-gate summary:

```sh
python3 scripts/assemble-theme-fidelity-v42-evidence.py \
  --capture-run docs/verification/theme-fidelity-v4/final/evidence/final-capture-run.json \
  --qualification-results <absolute-current-qualification-results.json>
```

The qualification document must bind each non-visual artifact to the final source SHA, a successful command execution, and the artifact's exact SHA-256. Missing, failed, stale, or hash-invalid evidence stops assembly; file presence alone is never treated as PASS.

Its schema is intentionally small. Each logical artifact name comes directly from `Gate-Catalog-v4.2.json`; `gateIDs` must include every gate that consumes that artifact. JSON artifacts must also report top-level PASS with no failures.

```json
{
  "schemaVersion": "1.0",
  "sourceSHA": "<40-character-final-source-SHA>",
  "executions": [
    {
      "id": "architecture-and-mediation",
      "gateIDs": ["ARC-001"],
      "command": ["./scripts/check-architecture.sh"],
      "startTimestamp": "<ISO-8601>",
      "endTimestamp": "<ISO-8601>",
      "destination": "local-macOS-host",
      "toolchain": {"xcode": "<version>"},
      "exitCode": 0,
      "result": "PASS",
      "failures": [],
      "artifacts": [
        {
          "logicalName": "architecture.log",
          "path": "<absolute-current-log-path>",
          "sha256": "<64-character-SHA-256>",
          "kind": "log"
        }
      ]
    }
  ]
}
```

Focused tooling checks:

```sh
python3 -m unittest scripts.tests.test_theme_fidelity_capture_harness -v
python3 -m py_compile \
  scripts/theme_fidelity_destination_policy.py \
  scripts/capture-theme-fidelity-matrix.py \
  scripts/extract-theme-fidelity-captures.py \
  scripts/index-theme-fidelity-captures.py
```
