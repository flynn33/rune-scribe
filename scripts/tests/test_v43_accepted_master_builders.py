#!/usr/bin/env python3
"""Focused fail-closed tests for accepted v4.3 Relic, Frame, and Crest masters."""

from __future__ import annotations

import hashlib
import importlib.util
import inspect
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

from PIL import Image, ImageDraw


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = REPO_ROOT / "scripts/theme_v43_accepted_masters.py"
MOONLEAF_BUILDER_PATH = REPO_ROOT / "scripts/build-moonleaf-v43-assets.py"
THEME_BUILDER_PATH = REPO_ROOT / "scripts/build-sunspire-wildwood-gloamthorn-v43-assets.py"
SWIFT_GEOMETRY_PATH = (
    REPO_ROOT
    / "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ThemeVisualComponents.swift"
)


def load_module(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


MASTERS = load_module("theme_v43_accepted_masters", HELPER_PATH)
MOONLEAF = load_module("moonleaf_v43_accepted_asset_builder", MOONLEAF_BUILDER_PATH)
THEMES = load_module("elven_v43_accepted_asset_builder", THEME_BUILDER_PATH)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


MODULES = {
    "moonleaf": "RuneScribeThemeMoonleafModule",
    "sunspire": "RuneScribeThemeSunspireModule",
    "wildwood": "RuneScribeThemeWildwoodModule",
    "gloamthorn": "RuneScribeThemeGloamthornModule",
}


class V43AcceptedMasterBuilderTests(unittest.TestCase):
    def test_source_master_paths_records_and_hashes_are_fail_closed(self) -> None:
        mappings = (
            MASTERS.FRAME_SOURCE_MASTERS,
            MASTERS.CREST_SOURCE_MASTERS,
        )
        specifications = [spec for mapping in mappings for spec in mapping.values()]
        specifications.extend(
            spec
            for theme_specs in MASTERS.RELIC_SOURCE_MASTERS.values()
            for spec in theme_specs.values()
        )
        self.assertEqual(len(specifications), 12)
        for spec in specifications:
            with self.subTest(asset=spec.asset_id):
                image, fact = MASTERS.load_source_master(REPO_ROOT, spec)
                self.assertEqual(image.size, spec.pixel_size)
                self.assertEqual(sha256_file(REPO_ROOT / spec.relative_path), spec.sha256)
                self.assertEqual(
                    sha256_file(REPO_ROOT / spec.acceptance_record_path),
                    spec.acceptance_record_sha256,
                )
                self.assertEqual(fact["acceptanceRecord"]["ownerReview"], "PENDING")
                self.assertFalse(fact["runtimeBundled"])

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            spec = MASTERS.FRAME_SOURCE_MASTERS["moonleaf"]
            for relative in (spec.relative_path, spec.acceptance_record_path):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(REPO_ROOT / relative, destination)
            with (root / spec.relative_path).open("ab") as handle:
                handle.write(b"changed")
            with self.assertRaisesRegex(ValueError, "source-master hash differs"):
                MASTERS.load_source_master(root, spec)
            shutil.copy2(REPO_ROOT / spec.relative_path, root / spec.relative_path)
            with (root / spec.acceptance_record_path).open("ab") as handle:
                handle.write(b"changed")
            with self.assertRaisesRegex(ValueError, "record hash differs"):
                MASTERS.load_source_master(root, spec)

    def test_recipe_reference_hash_and_pending_review_are_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            relative = "inventory/accepted-recipe.json"
            path = root / relative
            path.parent.mkdir(parents=True)
            path.write_text('{"ownerReview":"PENDING"}\n', encoding="utf-8")
            reference = {"path": relative, "sha256": sha256_file(path)}
            self.assertEqual(
                MASTERS.load_accepted_recipe(root, relative, reference)["ownerReview"],
                "PENDING",
            )
            path.write_text('{"ownerReview":"PASS"}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "recipe hash differs"):
                MASTERS.load_accepted_recipe(root, relative, reference)
            reference["sha256"] = sha256_file(path)
            with self.assertRaisesRegex(ValueError, "owner review differs"):
                MASTERS.load_accepted_recipe(root, relative, reference)

    def test_uniform_aspect_fit_is_repeatable_and_preserves_geometry(self) -> None:
        source = Image.new("RGBA", (300, 200), (0, 0, 0, 0))
        ImageDraw.Draw(source).rectangle((30, 20, 269, 179), fill=(20, 90, 160, 255))
        first = MASTERS.uniform_aspect_fit(source, (512, 512))
        second = MASTERS.uniform_aspect_fit(source, (512, 512))
        self.assertEqual(first.tobytes(), second.tobytes())
        self.assertEqual(first.size, (512, 512))
        self.assertEqual(first.getchannel("A").getbbox(), second.getchannel("A").getbbox())
        record = MASTERS.aspect_fit_record(source.size, first.size)
        self.assertEqual(record["method"], "uniform-aspect-fit")
        self.assertEqual(record["renderedPixels"], [512, 341])
        self.assertEqual(record["offsetPixels"], [0, 85])

    def test_nine_slice_uses_independent_corners_and_contiguous_overlapped_edges(self) -> None:
        source = Image.new("RGBA", (100, 100), (0, 0, 0, 0))
        draw = ImageDraw.Draw(source)
        corner_colors = ((255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255), (255, 255, 0, 255))
        for box, color in zip(
            ((0, 0, 19, 19), (80, 0, 99, 19), (0, 80, 19, 99), (80, 80, 99, 99)),
            corner_colors,
        ):
            draw.rectangle(box, fill=color)
        for box in ((20, 0, 79, 19), (20, 80, 79, 99), (0, 20, 19, 79), (80, 20, 99, 79)):
            draw.rectangle(box, fill=(255, 255, 255, 255))
        policy = MASTERS.FrameSlicePolicy(
            MASTERS.CapInsets(top=20, left=20, bottom=20, right=20),
            (40, 60),
            (40, 60),
        )
        target_caps = MASTERS.CapInsets(top=30, left=30, bottom=30, right=30)
        first = MASTERS.render_nine_slice_frame(source, (200, 120), target_caps, policy)
        second = MASTERS.render_nine_slice_frame(source, (200, 120), target_caps, policy)
        self.assertEqual(first.tobytes(), second.tobytes())
        self.assertEqual([first.getpixel(point) for point in ((0, 0), (199, 0), (0, 119), (199, 119))], list(corner_colors))
        self.assertEqual(first.getpixel((30, 5))[3], 255)
        self.assertEqual(first.getpixel((5, 30))[3], 255)
        self.assertEqual(first.getpixel((100, 60))[3], 0)

    def test_all_accepted_seal_masters_are_pinned_rgba_and_render_losslessly(self) -> None:
        specifications = [
            spec
            for theme_specs in MASTERS.SEAL_SOURCE_MASTERS.values()
            for spec in theme_specs.values()
        ]
        self.assertEqual(len(specifications), 18)
        for spec in specifications:
            with self.subTest(seal=spec.seal_id):
                source, fact = MASTERS.load_seal_source_master(REPO_ROOT, spec)
                color, monochrome, thumbnail = MASTERS.render_seal_variants(source)
                repeated = MASTERS.render_seal_variants(source)
                self.assertEqual(source.mode, "RGBA")
                self.assertEqual(source.size, spec.pixel_size)
                self.assertEqual(source.getchannel("A").getextrema(), (0, 255))
                self.assertEqual(color.tobytes(), source.tobytes())
                self.assertEqual(monochrome.getchannel("A").tobytes(), source.getchannel("A").tobytes())
                self.assertEqual(thumbnail.size, (512, 512))
                self.assertEqual(
                    tuple(image.tobytes() for image in (color, monochrome, thumbnail)),
                    tuple(image.tobytes() for image in repeated),
                )
                self.assertEqual(fact["targetScaleReview"], "PASS_AT_64_PX")
                self.assertEqual(fact["acceptanceRecord"]["ownerReview"], "PENDING")

    def test_seal_source_and_record_hashes_fail_closed(self) -> None:
        spec = MASTERS.SEAL_SOURCE_MASTERS["gloamthorn"]["thornmoon"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in (spec.relative_path, spec.acceptance_record_path):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(REPO_ROOT / relative, destination)
            with (root / spec.relative_path).open("ab") as handle:
                handle.write(b"changed")
            with self.assertRaisesRegex(ValueError, "source-master hash differs"):
                MASTERS.load_seal_source_master(root, spec)
            shutil.copy2(REPO_ROOT / spec.relative_path, root / spec.relative_path)
            with (root / spec.acceptance_record_path).open("ab") as handle:
                handle.write(b"changed")
            with self.assertRaisesRegex(ValueError, "record hash differs"):
                MASTERS.load_seal_source_master(root, spec)

    def test_panel_cap_insets_match_shared_swift_geometry(self) -> None:
        self.assertEqual(
            {name: caps.as_dict() if caps else None for name, caps in MASTERS.PANEL_CAP_INSETS.items()},
            {
                "card-border": {"top": 150, "left": 170, "bottom": 150, "right": 170},
                "corner-ornament": None,
                "divider": {"top": 48, "left": 360, "bottom": 48, "right": 360},
                "primary-button": {"top": 104, "left": 190, "bottom": 104, "right": 190},
                "tab-selector": {"top": 76, "left": 170, "bottom": 76, "right": 170},
            },
        )
        swift = SWIFT_GEOMETRY_PATH.read_text(encoding="utf-8")
        for marker in (
            "height * 0.15", "width * 0.10625",
            "height * 0.375", "width * 0.225",
            "height * 0.325", "width * 0.1583333333",
            "height * 0.3166666667", "width * 0.17",
        ):
            self.assertIn(marker, swift)

    def test_builders_do_not_reconstruct_accepted_roles(self) -> None:
        relic_source = inspect.getsource(THEMES.render_relic_variants)
        frame_source = inspect.getsource(THEMES.render_accepted_frame_crest_and_panels)
        moonleaf_source = inspect.getsource(MOONLEAF.render_accepted_frame_crest_and_panels)
        vault_sources = inspect.getsource(THEMES.vault_card) + inspect.getsource(MOONLEAF.vault_card)
        for source in (relic_source, frame_source, moonleaf_source):
            self.assertNotIn("GaussianBlur", source)
            self.assertNotIn("ImageOps.fit", source)
            self.assertNotIn("reconstruct", source)
        self.assertNotIn("frame_overlay.resize", vault_sources)
        self.assertNotIn("frame.resize", frame_source + moonleaf_source)

    def test_generated_outputs_recipes_provenance_manifests_and_pins_agree(self) -> None:
        configurations = {theme.slug: theme for theme in THEMES.THEMES}
        for theme, module_name in MODULES.items():
            with self.subTest(theme=theme):
                title = theme.title()
                resources = REPO_ROOT / "Packages/RuneScribeArchitecture/Sources" / module_name / "Resources"
                production = resources / "Production"
                provenance_path = REPO_ROOT / f"docs/verification/theme-fidelity-v4-3/inventory/{title}-Production-Asset-Provenance-v4.3.json"
                provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
                reference = provenance["acceptedSourceMasterRecipe"]
                recipe_path = REPO_ROOT / reference["path"]
                recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
                self.assertEqual(sha256_file(recipe_path), reference["sha256"])
                self.assertEqual(recipe["ownerReview"], "PENDING")
                self.assertEqual(provenance["targetScaleReview"]["ownerReview"], "PENDING")
                self.assertEqual(recipe["panelNineSlicePolicy"], MASTERS.panel_policy_record(theme))
                self.assertEqual(provenance["panelNineSlicePolicy"], MASTERS.panel_policy_record(theme))

                manifest_path = production / "Resource-Integrity-Manifest-v1.0.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                records = {record["path"]: record for record in manifest["files"]}
                pins = (resources.parent / f"{title}V43ResourcePins.swift").read_text(encoding="utf-8")
                for output in recipe["outputs"]:
                    path = resources / output["path"]
                    self.assertEqual(sha256_file(path), output["sha256"])
                    self.assertEqual(records[output["path"]]["sha256"], output["sha256"])
                    self.assertIn(output["sha256"], pins)

                frame_master, _ = MASTERS.load_source_master(REPO_ROOT, MASTERS.FRAME_SOURCE_MASTERS[theme])
                crest_master, _ = MASTERS.load_source_master(REPO_ROOT, MASTERS.CREST_SOURCE_MASTERS[theme])
                frame_slug = "silvervine" if theme == "moonleaf" else configurations[theme].frame_slug
                crest_slug = "moonbloom" if theme == "moonleaf" else configurations[theme].crest_slug
                expected_images = {
                    production / f"frame/{theme}-{frame_slug}-static-fallback.png": MASTERS.uniform_aspect_fit(frame_master, (2048, 1536)),
                    production / f"frame/{theme}-{frame_slug}-thumbnail.png": MASTERS.uniform_aspect_fit(frame_master, (512, 384)),
                    production / f"crest/{theme}-{crest_slug}-static-fallback.png": MASTERS.uniform_aspect_fit(crest_master, (1024, 1024)),
                    production / f"crest/{theme}-{crest_slug}-thumbnail.png": MASTERS.uniform_aspect_fit(crest_master, (512, 512)),
                }
                for name, image in MASTERS.panel_assets(theme, frame_master).items():
                    expected_images[production / f"panel/{theme}-{name}.png"] = image
                for path, expected in expected_images.items():
                    with Image.open(path) as actual:
                        self.assertEqual(actual.convert("RGBA").tobytes(), expected.tobytes())

                seal_records = [
                    record for record in manifest["files"]
                    if record["role"] == "seal.color-master"
                ]
                self.assertEqual(len(seal_records), 6)
                accepted_seal_facts = provenance["sealSourceMasters"]
                self.assertEqual(set(accepted_seal_facts), set(MASTERS.SEAL_SOURCE_MASTERS[theme]))
                for slug, spec in MASTERS.SEAL_SOURCE_MASTERS[theme].items():
                    source, _ = MASTERS.load_seal_source_master(REPO_ROOT, spec)
                    prefix = production / f"seal/{theme}-{slug}"
                    color, monochrome, thumbnail = MASTERS.render_seal_variants(source)
                    for suffix, expected in (
                        ("color-master", color),
                        ("monochrome-fallback", monochrome),
                        ("thumbnail", thumbnail),
                    ):
                        with Image.open(Path(str(prefix) + f"-{suffix}.png")) as actual:
                            self.assertEqual(actual.convert("RGBA").tobytes(), expected.tobytes())

    def test_clean_relic_production_masters_are_exact_aspect_fit_derivations(self) -> None:
        configurations = {theme.slug: theme for theme in THEMES.THEMES}
        for theme, source_specs in MASTERS.RELIC_SOURCE_MASTERS.items():
            for slug, spec in source_specs.items():
                with self.subTest(theme=theme, relic=slug):
                    source, _ = MASTERS.load_source_master(REPO_ROOT, spec)
                    config = configurations[theme]
                    target_size = next(relic.size for relic in config.relics if relic.slug == slug)
                    expected = MASTERS.uniform_aspect_fit(source, target_size)
                    output = (
                        REPO_ROOT
                        / "Packages/RuneScribeArchitecture/Sources"
                        / MODULES[theme]
                        / f"Resources/Production/relic/{theme}-{slug}-master.png"
                    )
                    with Image.open(output) as actual:
                        self.assertEqual(actual.convert("RGBA").tobytes(), expected.tobytes())

    def test_wildwood_checkerboard_remediation_has_real_transparency(self) -> None:
        for slug in ("rootsong-tablet", "mossbound-plaque"):
            spec = MASTERS.RELIC_SOURCE_MASTERS["wildwood"][slug]
            with self.subTest(relic=slug):
                source, _ = MASTERS.load_source_master(REPO_ROOT, spec)
                self.assertEqual(source.mode, "RGBA")
                alpha = source.getchannel("A")
                self.assertEqual(alpha.getextrema(), (0, 255))
                transparent_rgb = {
                    pixel[:3]
                    for pixel in source.getdata()
                    if pixel[3] == 0
                }
                self.assertEqual(transparent_rgb, {(0, 0, 0)})
                light = Image.new("RGBA", source.size, (245, 245, 245, 255))
                dark = Image.new("RGBA", source.size, (12, 18, 24, 255))
                light.alpha_composite(source)
                dark.alpha_composite(source)
                for point in ((0, 0), (source.width - 1, source.height - 1)):
                    self.assertEqual(light.getpixel(point), (245, 245, 245, 255))
                    self.assertEqual(dark.getpixel(point), (12, 18, 24, 255))


if __name__ == "__main__":
    unittest.main()
