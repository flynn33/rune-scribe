#!/usr/bin/env python3
"""Focused tests for executable Theme fidelity authority v1.2."""

from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np
from PIL import Image


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "scripts"))

import theme_fidelity_execution_v12 as execution  # noqa: E402
from theme_fidelity_execution_v12 import (  # noqa: E402
    ExecutionError,
    alpha_trim,
    aspect_fit_pad,
    comparison_metrics,
    destination_system_chrome_mask,
    derive_bounds_assertion,
    evaluate_structural_assertion,
    evaluate_operator,
    frame_index,
    integral_crop,
    load_json,
    metric_checks,
    normalize_pair,
    parse_iso_timestamp,
    recomputed_probe_observed,
    validate_direct_screen_mask_contract,
)


class ThemeFidelityExecutionV12Tests(unittest.TestCase):
    def test_duplicate_json_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"value": 1, "value": 2}\n', encoding="utf-8")
            with self.assertRaisesRegex(ExecutionError, "duplicate JSON key"):
                load_json(path)

    def test_alpha_trim_removes_only_transparent_outer_pixels(self) -> None:
        image = Image.new("RGBA", (9, 8), (0, 0, 0, 0))
        for y in range(2, 7):
            for x in range(1, 8):
                image.putpixel((x, y), (40, 80, 120, 255 if (x + y) % 2 else 1))
        trimmed, crop = alpha_trim(image)
        self.assertEqual(crop, [1, 2, 7, 5])
        self.assertEqual(trimmed.size, (7, 5))

    def test_alpha_trim_rejects_fully_transparent_input(self) -> None:
        with self.assertRaisesRegex(ExecutionError, "fully transparent"):
            alpha_trim(Image.new("RGBA", (8, 8), (0, 0, 0, 0)))

    def test_aspect_fit_preserves_complete_image(self) -> None:
        source = Image.new("RGBA", (20, 10), (255, 0, 0, 255))
        normalized = aspect_fit_pad(source, (100, 100))
        self.assertEqual(normalized.size, (100, 100))
        alpha = np.asarray(normalized.getchannel("A"))
        populated = np.argwhere(alpha > 0)
        self.assertEqual(tuple(populated.min(axis=0)), (25, 0))
        self.assertEqual(tuple(populated.max(axis=0)), (74, 99))

    def test_focal_normalization_never_crops_opaque_pixels(self) -> None:
        reference = Image.new("RGBA", (40, 20), (200, 100, 50, 255))
        candidate = Image.new("RGBA", (20, 40), (200, 100, 50, 255))
        ref, cand, details, metric_mask = normalize_pair(
            reference, candidate, "focal-complete-image-aspect-fit-v1"
        )
        self.assertEqual(ref.shape, (512, 512, 3))
        self.assertEqual(cand.shape, (512, 512, 3))
        self.assertFalse(details["opaquePixelsCropped"])
        self.assertIsNone(metric_mask)

    def test_direct_normalization_uses_common_minimum_dimensions_and_mask(self) -> None:
        reference = Image.new("RGBA", (80, 60), (20, 40, 60, 255))
        candidate = Image.new("RGBA", (90, 50), (20, 40, 60, 255))
        with self.assertRaisesRegex(ExecutionError, "not portrait"):
            normalize_pair(
                reference,
                candidate,
                "direct-screen-system-chrome-v1",
                destination="iphone-portrait",
            )

        portrait_reference = Image.new("RGBA", (80, 120), (20, 40, 60, 255))
        portrait_candidate = Image.new("RGBA", (50, 90), (20, 40, 60, 255))
        ref, cand, details, metric_mask = normalize_pair(
            portrait_reference,
            portrait_candidate,
            "direct-screen-system-chrome-v1",
            destination="iphone-portrait",
        )
        self.assertEqual(ref.shape, (90, 50, 3))
        self.assertEqual(cand.shape, (90, 50, 3))
        self.assertEqual(details["normalizedDimensions"], [50, 90])
        self.assertIsNotNone(metric_mask)
        self.assertEqual(metric_mask.shape, (90, 50))
        provenance = details["platformChromeMask"]
        self.assertEqual(provenance["destination"], "iphone-portrait")
        self.assertEqual(
            [region["kind"] for region in provenance["regions"]],
            ["status-bar", "home-indicator"],
        )
        self.assertFalse(provenance["customMaskFileUsed"])
        self.assertFalse(provenance["manualCoordinatesUsed"])

    def test_direct_normalization_masks_only_destination_chrome_differences(self) -> None:
        width, height = (100, 200)
        reference = Image.new("RGBA", (width, height), (40, 80, 120, 255))
        candidate = reference.copy()
        inclusion, provenance = destination_system_chrome_mask(
            "iphone-portrait", (width, height)
        )
        excluded = np.logical_not(inclusion)
        candidate_pixels = np.asarray(candidate).copy()
        candidate_pixels[excluded] = np.array([255, 0, 255, 255], dtype=np.uint8)
        candidate = Image.fromarray(candidate_pixels)
        ref, cand, details, metric_mask = normalize_pair(
            reference,
            candidate,
            "direct-screen-system-chrome-v1",
            destination="iphone-portrait",
        )
        metrics, _, _ = comparison_metrics(ref, cand, metric_mask)
        self.assertAlmostEqual(metrics["luminanceSSIM"], 1.0)
        self.assertAlmostEqual(metrics["edgeSSIM"], 1.0)
        self.assertAlmostEqual(metrics["medianDeltaE"], 0.0)
        self.assertEqual(
            details["platformChromeMask"]["maskSHA256"],
            provenance["maskSHA256"],
        )

        application_pixels = np.asarray(candidate).copy()
        application_pixels[80:120, 20:80] = np.array(
            [255, 255, 255, 255], dtype=np.uint8
        )
        mutated = Image.fromarray(application_pixels)
        ref, cand, _, metric_mask = normalize_pair(
            reference,
            mutated,
            "direct-screen-system-chrome-v1",
            destination="iphone-portrait",
        )
        mutated_metrics, _, _ = comparison_metrics(ref, cand, metric_mask)
        self.assertLess(mutated_metrics["luminanceSSIM"], 0.92)

    def test_direct_screen_mask_fails_closed_on_destination_and_profile_mutations(self) -> None:
        reference = Image.new("RGBA", (100, 200), (0, 0, 0, 255))
        with self.assertRaisesRegex(ExecutionError, "requires a destination"):
            normalize_pair(reference, reference, "direct-screen-system-chrome-v1")
        with self.assertRaisesRegex(ExecutionError, "no platform-chrome profile"):
            normalize_pair(
                reference,
                reference,
                "direct-screen-system-chrome-v1",
                destination="macos-standard",
            )

        oversized = {
            "profileID": "ios-iphone-portrait-platform-chrome-v1",
            "platform": "iOS Simulator",
            "regions": (
                {"kind": "status-bar", "normalizedRect": (0.0, 0.0, 1.0, 0.2)},
                {
                    "kind": "home-indicator",
                    "normalizedRect": (0.31, 0.981, 0.38, 0.012),
                },
            ),
        }
        with mock.patch.dict(
            execution.DESTINATION_SYSTEM_CHROME_PROFILES,
            {"iphone-portrait": oversized},
        ):
            with self.assertRaisesRegex(ExecutionError, "maximum authorized fraction"):
                destination_system_chrome_mask("iphone-portrait", (100, 200))

    def test_direct_screen_authority_mask_mutations_are_rejected(self) -> None:
        authority_path = (
            REPOSITORY_ROOT
            / execution.AUTHORITY_RELATIVE
        )
        authority = json.loads(authority_path.read_text(encoding="utf-8"))
        validate_direct_screen_mask_contract(authority)

        custom_mask = copy.deepcopy(authority)
        custom_mask["customMaskFilesAuthorized"] = True
        with self.assertRaisesRegex(ExecutionError, "prohibit custom mask files"):
            validate_direct_screen_mask_contract(custom_mask)

        operator_mask = copy.deepcopy(authority)
        direct_mapping = next(
            mapping
            for entry in operator_mask["entries"]
            for mapping in entry["referenceMappings"]
            if mapping.get("normalizationPolicy")
            == "direct-screen-system-chrome-v1"
        )
        direct_mapping["maskFile"] = "operator-mask.png"
        with self.assertRaisesRegex(ExecutionError, "operator mask field"):
            validate_direct_screen_mask_contract(operator_mask)

    def test_identical_images_pass_declared_metrics(self) -> None:
        pixels = np.zeros((64, 64, 3), dtype=np.float32)
        for y in range(64):
            for x in range(64):
                pixels[y, x] = (x / 63.0, y / 63.0, (x + y) / 126.0)
        metrics, _, _ = comparison_metrics(pixels, pixels.copy())
        checks = metric_checks(
            metrics,
            {
                "focalSSIMMinimum": 0.95,
                "edgeSSIMMinimum": 0.94,
                "medianDeltaEMaximum": 4,
                "p95DeltaEMaximum": 12,
                "severeDeltaEPercentMaximum": 2,
            },
        )
        self.assertTrue(all(checks.values()))

    def test_different_images_fail_declared_metrics(self) -> None:
        reference = np.zeros((64, 64, 3), dtype=np.float32)
        candidate = np.ones((64, 64, 3), dtype=np.float32)
        metrics, _, _ = comparison_metrics(reference, candidate)
        checks = metric_checks(
            metrics,
            {
                "focalSSIMMinimum": 0.95,
                "edgeSSIMMinimum": 0.94,
                "medianDeltaEMaximum": 4,
                "p95DeltaEMaximum": 12,
                "severeDeltaEPercentMaximum": 2,
            },
        )
        self.assertFalse(all(checks.values()))

    def test_integral_crop_rounds_outward_without_clipping(self) -> None:
        self.assertEqual(
            integral_crop(
                {"x": 1.25, "y": 2.75, "width": 10.5, "height": 20.1},
                (50, 50),
            ),
            (1, 2, 12, 23),
        )
        with self.assertRaisesRegex(ExecutionError, "beyond"):
            integral_crop(
                {"x": -0.1, "y": 2.0, "width": 10.0, "height": 10.0},
                (50, 50),
            )

    def test_frame_index_rejects_duplicate_elements(self) -> None:
        record = {
            "elementFrames": {
                "coordinateOrigin": "top-left",
                "units": "pixels",
                "scale": 2,
                "frames": [
                    {"elementID": "view", "x": 0, "y": 0, "width": 20, "height": 20},
                    {"elementID": "view", "x": 1, "y": 1, "width": 20, "height": 20},
                ],
            }
        }
        with self.assertRaisesRegex(ExecutionError, "unique"):
            frame_index(record)

    def test_bounds_assertions_are_recomputed_from_frames(self) -> None:
        frames = {
            "theme-fidelity.viewport": {"x": 0, "y": 0, "width": 100, "height": 200},
            "candidate": {"x": 10, "y": 10, "width": 80, "height": 180},
        }
        record = {"pixelWidth": 100, "pixelHeight": 200, "scale": 1}
        result = derive_bounds_assertion(
            "assert.element.viewport-contained", ["candidate"], frames, record
        )
        self.assertIsNotNone(result)
        self.assertTrue(result[0])
        overflowing = dict(frames)
        overflowing["candidate"] = {"x": 10, "y": 10, "width": 95, "height": 180}
        result = derive_bounds_assertion(
            "assert.no-horizontal-overflow", ["candidate"], overflowing, record
        )
        self.assertIsNotNone(result)
        self.assertFalse(result[0])

    def test_runtime_probe_operators_are_strict(self) -> None:
        self.assertTrue(evaluate_operator("equals", "reduce-motion", "reduce-motion"))
        self.assertFalse(evaluate_operator("equals", True, 1))
        self.assertTrue(evaluate_operator("less-than-or-equal", 0, 0))
        self.assertFalse(evaluate_operator("less-than-or-equal", True, 0))
        self.assertTrue(evaluate_operator("greater-than", 2, 0))
        self.assertTrue(
            evaluate_operator("equals-declared-reduce-motion-resource", True, True)
        )
        with self.assertRaisesRegex(ExecutionError, "unsupported"):
            evaluate_operator("contains", "value", "value")

    def test_runtime_probe_values_are_recomputed_from_diagnostics(self) -> None:
        record = {
            "scale": 2,
            "pixelWidth": 100,
            "pixelHeight": 200,
            "runtimeDiagnostics": {
                "activeThemeID": "theme.norse.base",
                "effectiveMotionMode": "reduce-motion",
                "activeThemeAnimationCount": 0,
                "effectiveBackgroundResourceID": "resource.background.norse.reduce-motion",
                "declaredReduceMotionBackgroundResourceID": "resource.background.norse.reduce-motion",
                "visualPlanRevision": 42,
                "preview": {
                    "elementID": "theme.artifact-preview.relic.norse.runestone-tablet",
                    "exists": True,
                    "visible": True,
                    "viewportContained": True,
                },
                "norseBase": {
                    "owned": True,
                    "selectable": True,
                    "fallbackAvailable": True,
                    "lockedElementCount": 0,
                    "optionalLockedRendererCovered": True,
                },
            },
        }
        frames = {
            "theme-fidelity.viewport": {"x": 0, "y": 0, "width": 100, "height": 200},
            "theme.artifact-preview.relic.norse.runestone-tablet": {
                "x": 10, "y": 20, "width": 80, "height": 150
            },
        }
        self.assertEqual(
            recomputed_probe_observed(
                "probe.theme.active.theme.norse.base", record, frames
            ),
            "theme.norse.base",
        )
        self.assertTrue(
            recomputed_probe_observed(
                "probe.motion.background-resource.theme.norse.base", record, frames
            )
        )
        self.assertTrue(
            recomputed_probe_observed(
                "probe.motion.preview-contained.theme.norse.base", record, frames
            )
        )
        self.assertEqual(
            recomputed_probe_observed(
                "probe.norse.vault.locked-element-count", record, frames
            ),
            0,
        )

    def test_structural_assertions_use_declared_operator_semantics(self) -> None:
        catalog = {
            "truth": {"operator": "state-text-shape-consistency", "expected": True},
            "no-overflow": {"operator": "horizontal-overflow", "expected": False},
            "hit-target": {"operator": "minimum-hit-target", "expectedMinimumPoints": 44},
            "placeholder-count": {"operator": "placeholder-resource-count", "expected": 0},
            "relics": {"operator": "relic-id-set-exact", "expectedCount": 3},
        }
        observations = {
            "truth": {"source": "runtime", "observed": True},
            "no-overflow": {"source": "runtime", "observed": False},
            "hit-target": {"source": "runtime", "observed": 44.0},
            "placeholder-count": {"source": "runtime", "observed": 0},
            "relics": {"source": "runtime", "observed": ["a", "b", "c"]},
        }
        record = {"structuralAssertionObservations": observations}
        for assertion_id in catalog:
            with self.subTest(assertion_id=assertion_id):
                result = evaluate_structural_assertion(
                    assertion_id, [], {}, record, catalog
                )
                self.assertEqual(result["result"], "PASS")

        failing_values = {
            "truth": False,
            "no-overflow": True,
            "hit-target": 43.9,
            "placeholder-count": 1,
            "relics": ["b", "a", "c"],
        }
        for assertion_id, observed in failing_values.items():
            with self.subTest(failing_assertion_id=assertion_id):
                failing_record = {
                    "structuralAssertionObservations": {
                        assertion_id: {"source": "runtime", "observed": observed}
                    }
                }
                result = evaluate_structural_assertion(
                    assertion_id, [], {}, failing_record, catalog
                )
                self.assertEqual(result["result"], "FAIL")

    def test_live_structural_assertions_ignore_hosted_frames_and_observations(self) -> None:
        candidate_id = "theme.artifact-preview.relic.norse.runestone-tablet"
        live_item = {
            "matchCount": 1,
            "elementFrame": {
                "x": 20.0,
                "y": 40.0,
                "width": 200.0,
                "height": 240.0,
            },
            "windowFrame": {
                "x": 0.0,
                "y": 0.0,
                "width": 390.0,
                "height": 844.0,
            },
        }
        sidecar = execution.ValidatedSidecar(
            path=Path("live-evidence.json"),
            sha256="a" * 64,
            document={},
            source_test={},
            deterministic_seed={},
            candidate_captures={candidate_id: live_item},
            structural_witnesses={},
            probe_evidence={},
        )
        catalog = {
            "assert.element.viewport-contained": {
                "operator": "viewport-containment",
                "expected": True,
            }
        }
        hosted_frames = {
            "theme-fidelity.viewport": {
                "x": 0,
                "y": 0,
                "width": 100,
                "height": 100,
            },
            candidate_id: {
                "x": 200,
                "y": 200,
                "width": 50,
                "height": 50,
            },
        }
        hosted_record = {
            "pixelWidth": 100,
            "pixelHeight": 100,
            "scale": 1,
            "structuralAssertionObservations": {
                "assert.element.viewport-contained": {
                    "source": "runtime",
                    "observed": False,
                }
            },
        }

        live_result = evaluate_structural_assertion(
            "assert.element.viewport-contained",
            [candidate_id],
            hosted_frames,
            hosted_record,
            catalog,
            sidecar=sidecar,
            entry={"surface": "inscription-preview"},
            candidate_catalog={candidate_id: {}},
        )
        self.assertEqual(live_result["source"], "xcui-sidecar-raw-query")
        self.assertEqual(live_result["result"], "PASS")

        live_item["elementFrame"] = {
            "x": 400.0,
            "y": 40.0,
            "width": 200.0,
            "height": 240.0,
        }
        hosted_frames[candidate_id] = {
            "x": 10,
            "y": 10,
            "width": 50,
            "height": 50,
        }
        hosted_record["structuralAssertionObservations"][
            "assert.element.viewport-contained"
        ]["observed"] = True
        mutated_live_result = evaluate_structural_assertion(
            "assert.element.viewport-contained",
            [candidate_id],
            hosted_frames,
            hosted_record,
            catalog,
            sidecar=sidecar,
            entry={"surface": "inscription-preview"},
            candidate_catalog={candidate_id: {}},
        )
        self.assertEqual(mutated_live_result["result"], "FAIL")
        self.assertEqual(
            mutated_live_result["details"]["containedElementIDs"], []
        )

    def test_live_mobile_hit_targets_require_every_control_enabled_and_hittable(self) -> None:
        control_ids = execution.MOBILE_HIT_TARGET_IDS["workspace-empty"]

        def witness(identifier: str) -> dict:
            return {
                "witnessID": f"element:{identifier}",
                "queryPredicate": f"identifier == '{identifier}'",
                "matchCount": 1,
                "elementIdentifier": identifier,
                "coordinateOrigin": "top-left",
                "coordinateUnits": "points",
                "elementFrame": {
                    "x": 20.0,
                    "y": 40.0,
                    "width": 44.0,
                    "height": 44.0,
                },
                "windowFrame": {
                    "x": 0.0,
                    "y": 0.0,
                    "width": 390.0,
                    "height": 844.0,
                },
                "label": identifier,
                "value": None,
                "isEnabled": True,
                "isHittable": True,
            }

        structural_witnesses = {
            f"element:{identifier}": witness(identifier)
            for identifier in control_ids
        }
        sidecar = execution.ValidatedSidecar(
            path=Path("live-hit-target-evidence.json"),
            sha256="b" * 64,
            document={},
            source_test={},
            deterministic_seed={},
            candidate_captures={},
            structural_witnesses=structural_witnesses,
            probe_evidence={},
        )
        catalog = {
            "assert.mobile-hit-targets": {
                "operator": "minimum-hit-target",
                "expectedMinimumPoints": 44,
            }
        }

        passing = evaluate_structural_assertion(
            "assert.mobile-hit-targets",
            [],
            {},
            {},
            catalog,
            sidecar=sidecar,
            entry={"surface": "workspace-empty"},
            candidate_catalog={},
        )
        self.assertEqual(passing["result"], "PASS")
        self.assertEqual(
            passing["details"]["enabledAndHittableControlIDs"], control_ids
        )

        for identifier in control_ids:
            for field in ("isEnabled", "isHittable"):
                with self.subTest(control=identifier, boolean=field):
                    structural_witnesses[f"element:{identifier}"][field] = False
                    failing = evaluate_structural_assertion(
                        "assert.mobile-hit-targets",
                        [],
                        {},
                        {},
                        catalog,
                        sidecar=sidecar,
                        entry={"surface": "workspace-empty"},
                        candidate_catalog={},
                    )
                    self.assertEqual(failing["result"], "FAIL")
                    structural_witnesses[f"element:{identifier}"][field] = True

    def test_clean_source_check_excludes_the_complete_generated_evidence_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            phase_root = root / "docs/verification/theme-fidelity-v4/final"
            output_root = phase_root / "authority-v1.2"
            with mock.patch.object(execution, "git_output", return_value="") as git:
                execution.require_clean_source(
                    root,
                    output_root,
                    [phase_root, output_root],
                )
            git.assert_called_once_with(
                root,
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--",
                ".",
                ":(exclude)docs/verification/theme-fidelity-v4/final/authority-v1.2",
                ":(exclude)docs/verification/theme-fidelity-v4/final",
            )

    def test_iso_timestamp_requires_timezone(self) -> None:
        self.assertEqual(
            parse_iso_timestamp("2026-08-25T18:00:00Z", "timestamp").utcoffset().total_seconds(),
            0,
        )
        with self.assertRaisesRegex(ExecutionError, "timezone"):
            parse_iso_timestamp("2026-08-25T18:00:00", "timestamp")


if __name__ == "__main__":
    unittest.main()
