#!/usr/bin/env python3
"""Focused tests for the v4.3 Theme background asset builders."""

from __future__ import annotations

import hashlib
import importlib.util
import inspect
import json
from pathlib import Path
import sys
import tempfile
import unittest

from PIL import Image


REPO_ROOT = Path(__file__).resolve().parents[2]
MOONLEAF_BUILDER_PATH = REPO_ROOT / "scripts/build-moonleaf-v43-assets.py"
THEME_BUILDER_PATH = REPO_ROOT / "scripts/build-sunspire-wildwood-gloamthorn-v43-assets.py"
BACKGROUND_RENDERER_PATH = REPO_ROOT / "scripts/theme_v43_background_master.py"


def load_builder(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


MOONLEAF = load_builder("moonleaf_v43_asset_builder", MOONLEAF_BUILDER_PATH)
THEMES = load_builder("elven_v43_asset_builder", THEME_BUILDER_PATH)
BACKGROUNDS = load_builder("theme_v43_background_master", BACKGROUND_RENDERER_PATH)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class V43BackgroundAssetBuilderTests(unittest.TestCase):
    def qualification_fixture(
        self,
        builder,
        root: Path,
        *,
        theme: str = "example",
        seal: str = "detailed-seal",
    ) -> tuple[dict, list[dict], str]:
        relative_path = f"Production/seal/{theme}-{seal}-color-master.png"
        output = root / relative_path
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(b"production color master")
        record = {"path": relative_path, "role": "seal.color-master"}
        provenance = {
            "blockers": [],
            "outputs": [record],
            "targetScaleReview": {
                "implementationReview": "PASS",
                "ownerReview": "PENDING",
            },
        }
        return provenance, [record], relative_path

    def test_generators_use_only_owner_archive_aliases(self) -> None:
        forbidden = ("00-CONTROLLING-GOLDENS", "02-REFERENCE-SLICES")
        for path in (MOONLEAF_BUILDER_PATH, THEME_BUILDER_PATH):
            source = path.read_text(encoding="utf-8")
            for marker in forbidden:
                self.assertNotIn(marker, source)

        prefix = "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/approved-source-full-"
        moonleaf_inputs = [item[0] for item in MOONLEAF.OWNER_ARCHIVE_INPUTS.values()]
        theme_inputs = [item.relative_path for theme in THEMES.THEMES for item in theme.inputs]
        self.assertTrue(moonleaf_inputs)
        self.assertTrue(theme_inputs)
        self.assertTrue(all(path.startswith(prefix) for path in moonleaf_inputs + theme_inputs))

    def test_aspect_fill_geometry_uses_one_uniform_source_scale(self) -> None:
        portrait = BACKGROUNDS.aspect_fill_crop_box((1672, 941), (2048, 2732))
        portrait_width = portrait[2] - portrait[0]
        portrait_height = portrait[3] - portrait[1]
        self.assertAlmostEqual(portrait_width / portrait_height, 2048 / 2732)
        self.assertAlmostEqual(2048 / portrait_width, 2732 / portrait_height)
        self.assertAlmostEqual((portrait[0] + portrait[2]) / 2, 1672 / 2)

        wide = BACKGROUNDS.aspect_fill_crop_box((1672, 941), (3200, 1800))
        wide_width = wide[2] - wide[0]
        wide_height = wide[3] - wide[1]
        self.assertAlmostEqual(wide_width / wide_height, 3200 / 1800)
        self.assertAlmostEqual(3200 / wide_width, 1800 / wide_height)
        self.assertAlmostEqual((wide[1] + wide[3]) / 2, 941 / 2)

        probe = Image.linear_gradient("L").resize((1672, 941)).convert("RGB")
        portrait_layout = BACKGROUNDS.output_layout_record(probe, (2048, 2732), (0.5, 0.5))
        wide_layout = BACKGROUNDS.output_layout_record(probe, (3200, 1800), (0.5, 0.5))
        self.assertEqual(portrait_layout["resampling"], "bicubic")
        self.assertEqual(wide_layout["resampling"], "bilinear")

    def test_background_functions_do_not_fit_or_blur_completed_images(self) -> None:
        for function in (
            MOONLEAF.moonleaf_environment,
            THEMES.source_background,
            BACKGROUNDS.render_background_variant,
        ):
            source = inspect.getsource(function)
            self.assertNotIn("ImageOps.fit", source)
            self.assertNotIn("GaussianBlur", source)
            self.assertNotIn("alpha_composite", source)
        renderer_source = inspect.getsource(BACKGROUNDS.render_background_variant)
        self.assertIn("Image.Transform.EXTENT", renderer_source)
        self.assertNotIn("paste(", renderer_source)

    def test_continuous_source_master_pins_are_explicit(self) -> None:
        specifications = {
            "moonleaf": MOONLEAF.BACKGROUND_SOURCE_MASTER,
            **THEMES.BACKGROUND_SOURCE_MASTERS,
        }
        self.assertEqual(set(specifications), {"moonleaf", "sunspire", "wildwood", "gloamthorn"})
        for theme, specification in specifications.items():
            self.assertEqual(specification.focal_point, (0.5, 0.5))
            self.assertEqual(len(specification.sha256), 64)
            self.assertEqual(
                specification.relative_path,
                (
                    "docs/verification/theme-fidelity-v4-3/source-masters/"
                    f"{theme}/{theme}-environment-production-master-v4.3.png"
                ),
            )
            source = REPO_ROOT / specification.relative_path
            self.assertEqual(sha256_file(source), specification.sha256)
            with Image.open(source) as image:
                self.assertEqual(image.size, (1672, 941))

    def test_small_probe_render_is_repeatable(self) -> None:
        master = Image.linear_gradient("L").resize((1672, 941), Image.Resampling.BILINEAR).convert("RGB")
        first = MOONLEAF.moonleaf_environment(master, (470, 836), mode="standard")
        second = MOONLEAF.moonleaf_environment(master, (470, 836), mode="standard")
        self.assertEqual(first.size, (470, 836))
        self.assertEqual(first.tobytes(), second.tobytes())

        sunspire = next(theme for theme in THEMES.THEMES if theme.slug == "sunspire")
        first = THEMES.source_background(sunspire, master, (470, 836), "standard")
        second = THEMES.source_background(sunspire, master, (470, 836), "standard")
        self.assertEqual(first.size, (470, 836))
        self.assertEqual(first.tobytes(), second.tobytes())

        reduce_motion = THEMES.source_background(sunspire, master, (470, 836), "reduce-motion")
        high_contrast = THEMES.source_background(sunspire, master, (470, 836), "high-contrast")
        self.assertNotEqual(first.tobytes(), reduce_motion.tobytes())
        self.assertNotEqual(first.tobytes(), high_contrast.tobytes())

    def test_generated_recipe_manifest_and_pin_records_agree(self) -> None:
        module_names = {
            "Moonleaf": "RuneScribeThemeMoonleafModule",
            "Sunspire": "RuneScribeThemeSunspireModule",
            "Wildwood": "RuneScribeThemeWildwoodModule",
            "Gloamthorn": "RuneScribeThemeGloamthornModule",
        }
        for title, module_name in module_names.items():
            slug = title.lower()
            provenance_path = REPO_ROOT / f"docs/verification/theme-fidelity-v4-3/inventory/{title}-Production-Asset-Provenance-v4.3.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            recipe_reference = provenance["backgroundRecipe"]
            recipe_path = REPO_ROOT / recipe_reference["path"]
            recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
            self.assertEqual(sha256_file(recipe_path), recipe_reference["sha256"])
            self.assertEqual(recipe["ownerReview"], "PENDING")
            self.assertEqual(len(recipe["outputs"]), 4)
            source_master = recipe["productionSourceMaster"]
            self.assertEqual(
                source_master["path"],
                (
                    "docs/verification/theme-fidelity-v4-3/source-masters/"
                    f"{slug}/{slug}-environment-production-master-v4.3.png"
                ),
            )
            self.assertEqual(source_master["sha256"], sha256_file(REPO_ROOT / source_master["path"]))
            self.assertEqual(source_master["dimensions"], [1672, 941])
            self.assertFalse(source_master["runtimeBundled"])
            self.assertNotIn("sourceRegions", recipe)
            self.assertEqual(provenance["backgroundSourceMaster"], source_master)
            self.assertEqual(recipe["renderer"], "scripts/theme_v43_background_master.py")
            self.assertEqual(recipe["rendererSHA256"], sha256_file(BACKGROUND_RENDERER_PATH))
            self.assertEqual(
                provenance["backgroundRenderer"],
                {
                    "path": "scripts/theme_v43_background_master.py",
                    "sha256": sha256_file(BACKGROUND_RENDERER_PATH),
                },
            )

            resources = REPO_ROOT / "Packages/RuneScribeArchitecture/Sources" / module_name / "Resources"
            integrity_path = resources / "Production/Resource-Integrity-Manifest-v1.0.json"
            integrity = json.loads(integrity_path.read_text(encoding="utf-8"))
            backgrounds = [record for record in integrity["files"] if record["role"].startswith("background.")]
            self.assertEqual(len(backgrounds), 4)
            pins = (resources.parent / f"{title}V43ResourcePins.swift").read_text(encoding="utf-8")
            for record in backgrounds:
                output = resources / record["path"]
                self.assertEqual(output.stat().st_size, record["bytes"])
                self.assertEqual(sha256_file(output), record["sha256"])
                self.assertIn(record["sha256"], pins)
                with Image.open(output) as image:
                    expected_size = (3200, 1800) if record["role"] == "background.macos-wide-crop" else (2048, 2732)
                    self.assertEqual(image.size, expected_size)

            module_manifest = json.loads((resources / "module-manifest.json").read_text(encoding="utf-8"))
            required_names = {
                item["name"]
                for item in module_manifest["runtimeRequirements"]["requiredResources"]
            }
            self.assertTrue({f"{slug}-background-static", f"{slug}-background-macos-wide"}.issubset(required_names))

    def test_builders_record_each_missing_required_color_master_as_a_blocker(self) -> None:
        moonleaf_available = {"crescentleaf", "woodland-stag"}
        moonleaf = MOONLEAF.color_master_blockers(
            "moonleaf",
            MOONLEAF.MOONLEAF_SEALS,
            moonleaf_available,
        )
        self.assertEqual(
            {item["asset"] for item in moonleaf},
            {
                "seal.moonleaf.echo-firefly",
                "seal.moonleaf.moonwell",
                "seal.moonleaf.night-owl",
                "seal.moonleaf.starflower",
            },
        )

        for theme in THEMES.THEMES:
            available = tuple(source.slug for source in theme.authority_seals)
            blockers = THEMES.color_master_blockers(theme.slug, theme.seals, available)
            self.assertEqual(len(blockers), len(theme.seals) - len(available))
            self.assertTrue(all(item["status"] == "BLOCKED" for item in blockers))

    def test_owner_review_pending_is_independent_from_production_pass(self) -> None:
        for builder in (MOONLEAF, THEMES):
            with self.subTest(builder=builder.__name__), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                provenance, records, _ = self.qualification_fixture(builder, root)
                failures = builder.production_qualification_failures(
                    provenance,
                    resources=root,
                    manifest_records=records,
                    theme="example",
                    required_seals=("detailed-seal",),
                )
                self.assertEqual(failures, [])
                provenance["targetScaleReview"]["ownerReview"] = "PASS"
                failures = builder.production_qualification_failures(
                    provenance,
                    resources=root,
                    manifest_records=records,
                    theme="example",
                    required_seals=("detailed-seal",),
                )
                self.assertIn(
                    "provenance.targetScaleReview.ownerReview must remain PENDING",
                    failures,
                )

    def test_recorded_production_blocker_prevents_pass(self) -> None:
        for builder in (MOONLEAF, THEMES):
            with self.subTest(builder=builder.__name__), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                provenance, records, _ = self.qualification_fixture(builder, root)
                provenance["blockers"] = [{"asset": "frame.example", "status": "BLOCKED"}]
                failures = builder.production_qualification_failures(
                    provenance,
                    resources=root,
                    manifest_records=records,
                    theme="example",
                    required_seals=("detailed-seal",),
                )
                self.assertIn("provenance records 1 production blocker(s)", failures)

    def test_missing_required_color_master_prevents_pass(self) -> None:
        for builder in (MOONLEAF, THEMES):
            with self.subTest(builder=builder.__name__), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                provenance, records, relative_path = self.qualification_fixture(builder, root)
                provenance["outputs"] = []
                records.clear()
                (root / relative_path).unlink()
                failures = builder.production_qualification_failures(
                    provenance,
                    resources=root,
                    manifest_records=records,
                    theme="example",
                    required_seals=("detailed-seal",),
                )
                self.assertEqual(len([item for item in failures if relative_path in item]), 3)

    def test_declared_quality_failure_prevents_pass(self) -> None:
        for builder in (MOONLEAF, THEMES):
            with self.subTest(builder=builder.__name__), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                provenance, records, _ = self.qualification_fixture(builder, root)
                provenance["qualityReview"] = {
                    "oneHundredPercent": "PASS",
                    "twoHundredPercent": "FAIL",
                }
                supporting = {
                    "blockers": [{"asset": "background.example", "status": "BLOCKED"}],
                    "qualityReview": {
                        "transparentEdgeReview": "BLOCKED",
                        "targetDeviceRuntime": "PENDING_PROVIDER_BINDING",
                    }
                }
                failures = builder.production_qualification_failures(
                    provenance,
                    resources=root,
                    manifest_records=records,
                    theme="example",
                    required_seals=("detailed-seal",),
                    supporting_documents=(("supporting", supporting),),
                )
                self.assertIn("provenance.qualityReview.twoHundredPercent declares 'FAIL'", failures)
                self.assertIn("supporting records 1 production blocker(s)", failures)
                self.assertIn("supporting.qualityReview.transparentEdgeReview declares 'BLOCKED'", failures)
                self.assertIn(
                    "supporting.qualityReview.targetDeviceRuntime declares 'PENDING_PROVIDER_BINDING'",
                    failures,
                )


if __name__ == "__main__":
    unittest.main()
