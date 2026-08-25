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

Comparison policy is manifest-pinned. A `comparisons` entry supplies a stable `id`, a declared `reference`, an optional declared binary `mask`, and an in-bounds `focalRegion`. Masks and references are digest-checked before scoring. The command accepts no mask or threshold override:

```sh
python3 scripts/compare-theme-captures.py \
  --comparison-id <id> \
  --candidate <capture.png> \
  --output <evidence/path-stem>
```

The fixed gates are luminance SSIM `>= 0.92`, edge SSIM `>= 0.94`, focal SSIM `>= 0.95`, median DeltaE `<= 4`, p95 DeltaE `<= 12`, and fraction of scored pixels with DeltaE above 20 `<= 0.02`. The comparator writes `<path-stem>.json` and `<path-stem>.heatmap.png`, exits `0` for pass, `1` for a metric failure, and `2` for invalid inputs or policy. Neither tool writes inside `authorityRoot`.

Python requires Pillow, NumPy, and scikit-image. Approved captures, masks, and comparison records are added through reviewed manifest changes; the tools provide no golden-update mode.
