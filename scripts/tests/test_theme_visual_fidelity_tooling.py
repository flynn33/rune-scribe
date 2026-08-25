#!/usr/bin/env python3
"""Focused tests for the deterministic Theme visual-fidelity tools."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from PIL import Image, ImageOps


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY_ROOT / "scripts/check-theme-visual-authority.py"
COMPARATOR = REPOSITORY_ROOT / "scripts/compare-theme-captures.py"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def gradient(path: Path, offset: int = 0, dimensions=(64, 64)) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    width, height = dimensions
    image = Image.new("RGB", dimensions)
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            pixels[x, y] = (
                (x * 3 + y + offset) % 256,
                (x + y * 5 + offset * 2) % 256,
                (x * 2 + y * 3 + offset * 4) % 256,
            )
    image.save(path)


def binary_mask(path: Path, dimensions=(64, 64)) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image = Image.new("L", dimensions, 255)
    for y in range(8):
        for x in range(dimensions[0]):
            image.putpixel((x, y), 0)
    image.save(path)


def canonical_crop_digest(path: Path, crop) -> str:
    x, y, width, height = crop
    with Image.open(path) as image:
        pixels = image.convert("RGB").crop((x, y, x + width, y + height)).tobytes()
    value = hashlib.sha256()
    value.update(b"responsive-regions-v1\0rgb\0")
    value.update(digest(path).encode("ascii"))
    value.update(b"\0")
    for item in (x, y, width, height):
        value.update(item.to_bytes(8, byteorder="big", signed=False))
    value.update(pixels)
    return value.hexdigest()


def canonical_json_digest(value) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


class ToolFixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.authority = (
            self.root / "docs/verification/theme-fidelity-v4/authority"
        )
        self.reference = self.authority / "goldens/reference.png"
        self.mask = self.authority / "masks/status.mask.png"
        self.shipping = self.root / "shipping"
        self.rejected = self.root / "rejected"
        self.manifest = self.authority / "asset-manifest.json"
        self.shipping.mkdir(parents=True)
        self.rejected.mkdir(parents=True)
        gradient(self.reference)
        binary_mask(self.mask)
        gradient(self.rejected / "flat-baseline.png", offset=41)
        self.payload = {
            "schemaVersion": "1.0",
            "assetCount": 2,
            "authorityRoot": "docs/verification/theme-fidelity-v4/authority",
            "shippingRoots": ["shipping"],
            "rejectedRoots": ["rejected"],
            "rejectedAssetSHA256": [],
            "assets": [
                self.asset_record(
                    self.reference,
                    theme="Norse",
                    role="complete-theme-board",
                    tier="controlling",
                ),
                self.asset_record(
                    self.mask,
                    theme="All",
                    role="comparison-mask",
                    tier="authoritative",
                ),
            ],
            "comparisons": [
                {
                    "id": "norse.workspace",
                    "reference": "goldens/reference.png",
                    "mask": "masks/status.mask.png",
                    "focalRegion": [8, 8, 40, 40],
                }
            ],
        }
        self.write_manifest()

    def cleanup(self) -> None:
        self.temporary.cleanup()

    def asset_record(self, path: Path, theme: str, role: str, tier: str) -> dict:
        with Image.open(path) as image:
            dimensions = list(image.size)
        return {
            "path": path.relative_to(self.authority).as_posix(),
            "sha256": digest(path),
            "dimensions": dimensions,
            "theme": theme,
            "role": role,
            "tier": tier,
        }

    def write_manifest(self) -> None:
        self.manifest.parent.mkdir(parents=True, exist_ok=True)
        self.manifest.write_text(
            json.dumps(self.payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def run_checker(self) -> tuple:
        return run_json(
            [
                sys.executable,
                str(CHECKER),
                "--root",
                str(self.root),
            ],
            self.root,
        )

    def run_comparator(self, candidate: Path, output: Path, extra=None) -> tuple:
        command = [
            sys.executable,
            str(COMPARATOR),
            "--root",
            str(self.root),
            "--comparison-id",
            "norse.workspace",
            "--candidate",
            str(candidate),
            "--output",
            str(output),
        ]
        if extra:
            command.extend(extra)
        return run_json(command, self.root)


class ResponsiveToolFixture(ToolFixture):
    seed = "responsive-fixture-seed"

    def __init__(self) -> None:
        super().__init__()
        binary_mask(self.mask, dimensions=(32, 32))
        self.candidate = self.root / "captures/responsive.png"
        self.candidate.parent.mkdir(parents=True)
        with Image.open(self.reference) as source:
            source = source.convert("RGB")
            candidate = Image.new("RGB", (64, 32))
            candidate.paste(source.crop((0, 0, 32, 32)), (0, 0))
            candidate.paste(source.crop((32, 32, 64, 64)), (32, 0))
            candidate.save(self.candidate)
        self.capture_record = self.root / "captures/responsive.capture.json"
        content_seed = {
            "fixtureID": self.seed,
            "fixtureVersion": 1,
            "surface": "workspace-empty",
            "plaintext": None,
            "glyphTokens": ["ᚠ", "/"],
            "sender": {"name": None},
            "cipher": {"id": None, "name": None},
            "timestamp": "2023-11-14T22:13:20Z",
            "selectedResources": {
                "codexID": "codex.norse",
                "relicID": "relic.norse.runestone-tablet",
                "sealID": None,
                "frameID": None,
            },
            "progression": {
                "ownershipState": None,
                "achievementID": None,
                "completedRuleCount": None,
                "requiredRuleCount": None,
            },
            "locale": "en_US_POSIX",
            "calendar": "gregorian",
            "timeZone": "GMT",
            "accessibility": {
                "increasedContrast": False,
                "reduceMotion": False,
                "dynamicTypeSize": "large",
            },
        }
        self.record = {
            "schemaVersion": "1.0",
            "stateSeed": self.seed,
            "stateSeedSHA256": canonical_json_digest(content_seed),
            "contentSeed": content_seed,
            "surface": "workspace-empty",
            "codexID": "codex.norse",
            "relicID": "relic.norse.runestone-tablet",
            "sealID": None,
            "frameID": None,
            "scale": 2.0,
            "pixelWidth": 64,
            "pixelHeight": 32,
            "pngSHA256": digest(self.candidate),
            "viewportAssertions": {
                "requiredElementCount": 3,
                "requiredElementIDs": [
                    "artifact.a",
                    "artifact.b",
                    "theme-fidelity.viewport",
                ],
                "clippedElementIDs": [],
            },
            "elementFrames": {
                "coordinateOrigin": "top-left",
                "units": "pixels",
                "scale": 2.0,
                "frames": [
                    {
                        "elementID": "artifact.a",
                        "x": 0.0,
                        "y": 0.0,
                        "width": 32.0,
                        "height": 32.0,
                    },
                    {
                        "elementID": "artifact.b",
                        "x": 32.0,
                        "y": 0.0,
                        "width": 32.0,
                        "height": 32.0,
                    },
                    {
                        "elementID": "theme-fidelity.viewport",
                        "x": 0.0,
                        "y": 0.0,
                        "width": 64.0,
                        "height": 32.0,
                    },
                ],
            },
        }
        self.payload["assets"] = [
            self.asset_record(
                self.reference,
                theme="Norse",
                role="complete-theme-board",
                tier="controlling",
            ),
            self.asset_record(
                self.mask,
                theme="All",
                role="platform-controlled-mask",
                tier="authoritative",
            ),
        ]
        self.payload["comparisons"] = [
            {
                "id": "norse.workspace",
                "capture": "responsive.png",
                "policy": "responsive-regions-v1",
                "stateSeedSHA256": self.record["stateSeedSHA256"],
                "regions": [
                    self.region(
                        "a-primary",
                        "artifact.a",
                        [0, 0, 32, 32],
                        "masks/status.mask.png",
                    ),
                    self.region(
                        "b-secondary",
                        "artifact.b",
                        [32, 32, 32, 32],
                        None,
                    ),
                ],
                "layoutAssertions": {
                    "requiredElementIDs": ["artifact.a", "artifact.b"],
                    "withinViewportElementIDs": ["artifact.a", "artifact.b"],
                    "requireNoClippedElements": True,
                },
            }
        ]
        self.write_record()
        self.write_manifest()

    def region(self, identifier: str, candidate_id: str, crop, mask) -> dict:
        return {
            "id": identifier,
            "reference": "goldens/reference.png",
            "sourceCrop": crop,
            "sourceCropSHA256": canonical_crop_digest(self.reference, crop),
            "candidateElementID": candidate_id,
            "mask": mask,
            "thresholds": {
                "luminanceSSIM": 0.92,
                "edgeSSIM": 0.94,
                "focalSSIM": 0.95,
                "medianDeltaE": 4.0,
                "p95DeltaE": 12.0,
                "maxFractionDeltaEAbove20": 0.02,
            },
        }

    def write_record(self) -> None:
        self.capture_record.write_text(
            json.dumps(self.record, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def run_responsive_comparator(self, output: Path, extra=None) -> tuple:
        command = [
            sys.executable,
            str(COMPARATOR),
            "--root",
            str(self.root),
            "--comparison-id",
            "norse.workspace",
            "--candidate",
            str(self.candidate),
            "--capture-record",
            str(self.capture_record),
            "--output",
            str(output),
        ]
        if extra:
            command.extend(extra)
        return run_json(command, self.root)


def run_json(command, cwd: Path) -> tuple:
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        timeout=30,
    )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        payload = None
    return completed, payload


class AuthorityCheckerTests(unittest.TestCase):
    def assert_finding(self, payload: dict, code: str) -> None:
        self.assertIsNotNone(payload)
        self.assertEqual(payload["result"], "FAIL")
        self.assertIn(code, {finding["code"] for finding in payload["findings"]})

    def test_complete_immutable_inventory_passes(self) -> None:
        fixture = ToolFixture()
        try:
            completed, payload = fixture.run_checker()
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(payload["result"], "PASS")
            self.assertEqual(payload["declaredAssetCount"], 2)
            self.assertEqual(payload["comparisonCount"], 1)
            self.assertEqual(payload["findings"], [])
        finally:
            fixture.cleanup()

    def test_checker_cannot_write_results_inside_authority_root(self) -> None:
        fixture = ToolFixture()
        try:
            output = fixture.authority / "checker-result.json"
            completed, payload = run_json(
                [
                    sys.executable,
                    str(CHECKER),
                    "--root",
                    str(fixture.root),
                    "--output",
                    str(output),
                ],
                fixture.root,
            )
            self.assertEqual(completed.returncode, 1)
            self.assert_finding(payload, "immutable-output-path")
            self.assertFalse(output.exists())
        finally:
            fixture.cleanup()

    def test_missing_stale_and_undeclared_assets_are_rejected(self) -> None:
        def stale_dimensions(fixture: ToolFixture) -> None:
            fixture.payload["assets"][0]["dimensions"] = [63, 64]
            fixture.write_manifest()

        mutations = (
            (
                "missing-asset",
                lambda fixture: fixture.reference.unlink(),
            ),
            (
                "stale-sha256",
                lambda fixture: gradient(fixture.reference, offset=73),
            ),
            ("stale-dimensions", stale_dimensions),
            (
                "undeclared-authority-asset",
                lambda fixture: gradient(fixture.authority / "goldens/extra.png", offset=19),
            ),
        )
        for code, mutate in mutations:
            with self.subTest(code=code):
                fixture = ToolFixture()
                try:
                    mutate(fixture)
                    completed, payload = fixture.run_checker()
                    self.assertEqual(completed.returncode, 1)
                    self.assert_finding(payload, code)
                finally:
                    fixture.cleanup()

    def test_rejected_placeholder_and_reference_shipping_are_rejected(self) -> None:
        def ship_rejected(fixture: ToolFixture) -> None:
            shutil.copy2(
                fixture.rejected / "flat-baseline.png",
                fixture.shipping / "bad.png",
            )

        def ship_reference(fixture: ToolFixture) -> None:
            shutil.copy2(fixture.reference, fixture.shipping / "art.png")

        def ship_placeholder(fixture: ToolFixture) -> None:
            Image.new("RGBA", (32, 32), (0, 0, 0, 0)).save(
                fixture.shipping / "placeholder.png"
            )

        mutations = (
            ("rejected-asset-shipped", ship_rejected),
            ("reference-asset-shipped", ship_reference),
            ("placeholder-asset", ship_placeholder),
        )
        for code, mutate in mutations:
            with self.subTest(code=code):
                fixture = ToolFixture()
                try:
                    mutate(fixture)
                    completed, payload = fixture.run_checker()
                    self.assertEqual(completed.returncode, 1)
                    self.assert_finding(payload, code)
                finally:
                    fixture.cleanup()


class CaptureComparatorTests(unittest.TestCase):
    def test_identical_capture_passes_and_inputs_remain_immutable(self) -> None:
        fixture = ToolFixture()
        try:
            candidate = fixture.root / "captures/candidate.png"
            candidate.parent.mkdir(parents=True)
            shutil.copy2(fixture.reference, candidate)
            output = fixture.root / "evidence/norse-workspace"
            before = {
                path: path.read_bytes()
                for path in (fixture.manifest, fixture.reference, fixture.mask)
            }

            completed, payload = fixture.run_comparator(candidate, output)

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(payload["result"], "PASS")
            self.assertEqual(
                payload["thresholds"],
                {
                    "edgeSSIM": 0.94,
                    "focalSSIM": 0.95,
                    "luminanceSSIM": 0.92,
                    "maxFractionDeltaEAbove20": 0.02,
                    "medianDeltaE": 4.0,
                    "p95DeltaE": 12.0,
                },
            )
            self.assertAlmostEqual(payload["metrics"]["luminanceSSIM"], 1.0)
            self.assertAlmostEqual(payload["metrics"]["edgeSSIM"], 1.0)
            self.assertAlmostEqual(payload["metrics"]["focalSSIM"], 1.0)
            self.assertAlmostEqual(payload["metrics"]["medianDeltaE"], 0.0)
            self.assertTrue(Path(str(output) + ".json").is_file())
            heatmap = Path(str(output) + ".heatmap.png")
            self.assertTrue(heatmap.is_file())
            with Image.open(heatmap) as image:
                self.assertEqual(image.size, (64, 64))
            for path, contents in before.items():
                self.assertEqual(path.read_bytes(), contents)
        finally:
            fixture.cleanup()


class ResponsiveRegionComparatorTests(unittest.TestCase):
    def assert_checker_finding(self, fixture: ResponsiveToolFixture, code: str) -> None:
        completed, payload = fixture.run_checker()
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertEqual(payload["result"], "FAIL")
        self.assertIn(code, {item["code"] for item in payload["findings"]})

    def assert_comparison_error(
        self, fixture: ResponsiveToolFixture, expected: str, name: str
    ) -> None:
        completed, payload = fixture.run_responsive_comparator(
            fixture.root / "evidence" / name
        )
        self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
        self.assertEqual(payload["result"], "ERROR")
        self.assertIn(expected, payload["error"])

    def test_multi_region_comparison_passes_with_aggregate_atlas(self) -> None:
        fixture = ResponsiveToolFixture()
        try:
            completed, checker = fixture.run_checker()
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(checker["result"], "PASS")

            output = fixture.root / "evidence/responsive"
            completed, payload = fixture.run_responsive_comparator(output)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(payload["result"], "PASS")
            self.assertEqual(payload["comparisonPolicy"], "responsive-regions-v1")
            self.assertEqual(payload["regionCount"], 2)
            self.assertEqual(payload["passingRegionCount"], 2)
            self.assertTrue(all(payload["layoutAssertions"]["checks"].values()))
            self.assertTrue(all(payload["aggregateChecks"].values()))
            self.assertEqual(
                payload["elementFrameAttestation"],
                {
                    "coordinateOrigin": "top-left",
                    "units": "pixels",
                    "scale": 2.0,
                    "pixelRoundingPolicy": "outward-to-integral-bounds",
                },
            )
            self.assertTrue(
                all(item["aspectRatioPreserved"] for item in payload["regions"])
            )
            self.assertEqual(
                [item["regionID"] for item in payload["heatmapAtlas"]],
                ["a-primary", "b-secondary"],
            )
            self.assertEqual(payload["heatmapAtlas"][0]["frame"], [0, 0, 32, 32])
            self.assertEqual(payload["heatmapAtlas"][1]["frame"], [0, 32, 32, 32])
            with Image.open(Path(str(output) + ".heatmap.png")) as atlas:
                self.assertEqual(atlas.size, (32, 64))
            report = Path(str(output) + ".json")
            self.assertTrue(report.is_file())
            self.assertEqual(payload["captureRecordSHA256"], digest(fixture.capture_record))
            self.assertEqual(
                payload["stateSeedSHA256"],
                fixture.record["stateSeedSHA256"],
            )
        finally:
            fixture.cleanup()

    def test_responsive_comparison_requires_explicit_capture_record(self) -> None:
        fixture = ResponsiveToolFixture()
        try:
            completed, payload = fixture.run_comparator(
                fixture.candidate,
                fixture.root / "evidence/missing-record",
            )
            self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
            self.assertEqual(payload["result"], "ERROR")
            self.assertIn("explicit --capture-record", payload["error"])
        finally:
            fixture.cleanup()

    def test_crop_coordinate_and_crop_digest_mutations_are_rejected(self) -> None:
        for mutation, code in (
            ("coordinate", "stale-responsive-crop-digest"),
            ("digest", "stale-responsive-crop-digest"),
        ):
            with self.subTest(mutation=mutation):
                fixture = ResponsiveToolFixture()
                try:
                    region = fixture.payload["comparisons"][0]["regions"][0]
                    if mutation == "coordinate":
                        region["sourceCrop"] = [1, 0, 32, 32]
                    else:
                        region["sourceCropSHA256"] = "0" * 64
                    fixture.write_manifest()
                    self.assert_checker_finding(fixture, code)
                    self.assert_comparison_error(
                        fixture, "source crop digest no longer matches", f"crop-{mutation}"
                    )
                finally:
                    fixture.cleanup()

    def test_state_seed_digest_mutation_is_rejected(self) -> None:
        fixture = ResponsiveToolFixture()
        try:
            fixture.payload["comparisons"][0]["stateSeedSHA256"] = hashlib.sha256(
                b"different-seed"
            ).hexdigest()
            fixture.write_manifest()
            self.assert_comparison_error(
                fixture,
                "stateSeedSHA256 differs from the comparison plan",
                "seed-mutation",
            )
        finally:
            fixture.cleanup()

    def test_content_seed_shape_and_canonical_digest_mutations_are_rejected(self) -> None:
        mutations = (
            (
                "extra-key",
                lambda fixture: fixture.record["contentSeed"].__setitem__(
                    "unexpected", None
                ),
                "contentSeed keys are invalid",
            ),
            (
                "canonical-digest",
                lambda fixture: fixture.record["contentSeed"].__setitem__(
                    "plaintext", "changed"
                ),
                "differs from canonical contentSeed",
            ),
            (
                "fixture-binding",
                lambda fixture: fixture.record.__setitem__(
                    "stateSeed", "different-fixture"
                ),
                "stateSeed differs from contentSeed",
            ),
            (
                "fixture-version-type",
                lambda fixture: fixture.record["contentSeed"].__setitem__(
                    "fixtureVersion", True
                ),
                "fixtureVersion must be 1",
            ),
        )
        for name, mutate, expected in mutations:
            with self.subTest(name=name):
                fixture = ResponsiveToolFixture()
                try:
                    mutate(fixture)
                    fixture.write_record()
                    self.assert_comparison_error(fixture, expected, name)
                finally:
                    fixture.cleanup()

    def test_golden_and_candidate_hash_mutations_are_rejected(self) -> None:
        fixture = ResponsiveToolFixture()
        try:
            fixture.payload["assets"][0]["sha256"] = "0" * 64
            fixture.write_manifest()
            self.assert_checker_finding(fixture, "stale-sha256")
            self.assert_comparison_error(
                fixture,
                "reference SHA-256",
                "golden-hash",
            )
        finally:
            fixture.cleanup()

        fixture = ResponsiveToolFixture()
        try:
            fixture.record["pngSHA256"] = "0" * 64
            fixture.write_record()
            self.assert_comparison_error(
                fixture,
                "pngSHA256 does not match",
                "candidate-hash",
            )
        finally:
            fixture.cleanup()

    def test_attested_frame_origin_bounds_and_aspect_mutations_are_rejected(self) -> None:
        mutations = (
            (
                "origin",
                lambda fixture: fixture.record["elementFrames"].__setitem__(
                    "coordinateOrigin", "bottom-left"
                ),
                "top-left coordinates",
            ),
            (
                "frame",
                lambda fixture: fixture.record["elementFrames"]["frames"][0].__setitem__(
                    "x", -1.0
                ),
                "outside the candidate capture",
            ),
        )
        for name, mutate, expected in mutations:
            with self.subTest(name=name):
                fixture = ResponsiveToolFixture()
                try:
                    mutate(fixture)
                    fixture.write_record()
                    self.assert_comparison_error(fixture, expected, name)
                finally:
                    fixture.cleanup()

        fixture = ResponsiveToolFixture()
        try:
            region = fixture.payload["comparisons"][0]["regions"][1]
            region["sourceCrop"] = [32, 32, 31, 32]
            region["sourceCropSHA256"] = canonical_crop_digest(
                fixture.reference, region["sourceCrop"]
            )
            fixture.write_manifest()
            self.assert_comparison_error(
                fixture,
                "aspect ratio differs",
                "aspect",
            )
        finally:
            fixture.cleanup()

    def test_threshold_mutation_is_rejected_without_override(self) -> None:
        fixture = ResponsiveToolFixture()
        try:
            fixture.payload["comparisons"][0]["regions"][0]["thresholds"][
                "luminanceSSIM"
            ] = 0.91
            fixture.write_manifest()
            self.assert_checker_finding(fixture, "responsive-threshold-mutation")
            self.assert_comparison_error(
                fixture,
                "thresholds differ from fixed policy",
                "threshold",
            )
        finally:
            fixture.cleanup()

    def test_mask_role_and_digest_mutations_are_rejected(self) -> None:
        fixture = ResponsiveToolFixture()
        try:
            fixture.payload["assets"][1]["role"] = "theme-art-mask"
            fixture.write_manifest()
            self.assert_checker_finding(fixture, "responsive-mask-not-platform-only")
            self.assert_comparison_error(
                fixture,
                "not platform-controlled",
                "mask-role",
            )
        finally:
            fixture.cleanup()

        fixture = ResponsiveToolFixture()
        try:
            with Image.open(fixture.mask) as source:
                changed = source.convert("L")
            changed.putpixel((9, 9), 0)
            changed.save(fixture.mask)
            self.assert_checker_finding(fixture, "stale-sha256")
            self.assert_comparison_error(
                fixture,
                "mask SHA-256",
                "mask-digest",
            )
        finally:
            fixture.cleanup()

        fixture = ResponsiveToolFixture()
        try:
            with Image.open(fixture.mask) as source:
                changed = source.convert("L")
            changed.putpixel((9, 9), 127)
            changed.save(fixture.mask)
            fixture.payload["assets"][1] = fixture.asset_record(
                fixture.mask,
                theme="All",
                role="platform-controlled-mask",
                tier="authoritative",
            )
            fixture.write_manifest()
            self.assert_checker_finding(fixture, "invalid-responsive-mask")
            self.assert_comparison_error(
                fixture,
                "only black and white",
                "mask-pixels",
            )
        finally:
            fixture.cleanup()

    def test_layout_assertion_failure_is_a_blocking_fail(self) -> None:
        fixture = ResponsiveToolFixture()
        try:
            fixture.record["viewportAssertions"]["clippedElementIDs"] = ["artifact.a"]
            fixture.write_record()
            output = fixture.root / "evidence/layout-fail"
            completed, payload = fixture.run_responsive_comparator(output)
            self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
            self.assertEqual(payload["result"], "FAIL")
            self.assertFalse(
                payload["layoutAssertions"]["checks"]["noClippedElements"]
            )
            self.assertTrue(Path(str(output) + ".json").is_file())
            self.assertTrue(Path(str(output) + ".heatmap.png").is_file())
        finally:
            fixture.cleanup()


class CaptureComparatorLegacyRegressionTests(unittest.TestCase):
    def test_degraded_capture_fails_fixed_metrics(self) -> None:
        fixture = ToolFixture()
        try:
            candidate = fixture.root / "captures/degraded.png"
            candidate.parent.mkdir(parents=True)
            with Image.open(fixture.reference) as reference:
                ImageOps.invert(reference.convert("RGB")).save(candidate)
            output = fixture.root / "evidence/degraded"

            completed, payload = fixture.run_comparator(candidate, output)

            self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
            self.assertEqual(payload["result"], "FAIL")
            self.assertFalse(all(payload["checks"].values()))
            self.assertTrue(Path(str(output) + ".json").is_file())
            self.assertTrue(Path(str(output) + ".heatmap.png").is_file())
        finally:
            fixture.cleanup()

    def test_cli_cannot_override_thresholds_or_masks(self) -> None:
        fixture = ToolFixture()
        try:
            candidate = fixture.root / "captures/candidate.png"
            candidate.parent.mkdir(parents=True)
            shutil.copy2(fixture.reference, candidate)
            output = fixture.root / "evidence/forbidden-override"
            for extra in (
                ["--ssim", "0.1"],
                ["--mask", str(fixture.mask)],
                ["--manifest", str(fixture.manifest)],
            ):
                with self.subTest(extra=extra):
                    completed, payload = fixture.run_comparator(candidate, output, extra)
                    self.assertEqual(completed.returncode, 2)
                    self.assertIsNone(payload)
                    self.assertIn("unrecognized arguments", completed.stderr)
        finally:
            fixture.cleanup()

    def test_stale_mask_and_authority_output_are_rejected(self) -> None:
        fixture = ToolFixture()
        try:
            candidate = fixture.root / "captures/candidate.png"
            candidate.parent.mkdir(parents=True)
            shutil.copy2(fixture.reference, candidate)
            binary_mask(fixture.mask, dimensions=(64, 64))
            with Image.open(fixture.mask) as mask:
                changed = mask.convert("L")
            changed.putpixel((9, 9), 0)
            changed.save(fixture.mask)
            output = fixture.root / "evidence/stale-mask"

            completed, payload = fixture.run_comparator(candidate, output)
            self.assertEqual(completed.returncode, 2)
            self.assertEqual(payload["result"], "ERROR")
            self.assertIn("mask SHA-256", payload["error"])
            self.assertFalse(Path(str(output) + ".json").exists())

            fixture.payload["assets"][1] = fixture.asset_record(
                fixture.mask,
                theme="All",
                role="comparison-mask",
                tier="authoritative",
            )
            fixture.write_manifest()
            protected_output = fixture.authority / "results/forbidden"
            completed, payload = fixture.run_comparator(candidate, protected_output)
            self.assertEqual(completed.returncode, 2)
            self.assertEqual(payload["result"], "ERROR")
            self.assertIn("must not be written inside authorityRoot", payload["error"])
        finally:
            fixture.cleanup()


if __name__ == "__main__":
    unittest.main()
