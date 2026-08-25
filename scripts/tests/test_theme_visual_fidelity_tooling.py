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
