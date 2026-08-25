#!/usr/bin/env python3
"""Focused tests for the deterministic Norse production-asset builder."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

from PIL import Image


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILDER_PATH = REPO_ROOT / "scripts/build-norse-production-assets.py"
SPEC = importlib.util.spec_from_file_location("norse_production_asset_builder", BUILDER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"unable to load {BUILDER_PATH}")
BUILDER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILDER
SPEC.loader.exec_module(BUILDER)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class NorseProductionAssetBuilderTests(unittest.TestCase):
    def test_output_plan_is_exact_and_recipe_complete(self) -> None:
        plan = BUILDER.planned_outputs()
        paths = [item["path"] for item in plan]
        self.assertEqual(len(plan), 60)
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(
            {item["recipeID"] for item in plan},
            set(BUILDER.RECIPE_DEFINITIONS),
        )

        relics = [item for item in plan if item["resourceID"].startswith("relic.norse.")]
        self.assertEqual(len(relics), 12)
        for slug, _, master_size in BUILDER.RELICS:
            variants = {
                item["variant"]: tuple(item["size"])
                for item in relics
                if item["resourceID"] == f"relic.norse.{slug}"
            }
            self.assertEqual(
                variants,
                {
                    "standard": master_size,
                    "thumbnail-512": (512, 512),
                    "static-share-fallback": (1600, 1200),
                    "high-contrast": master_size,
                },
            )

        seals = [item for item in plan if item["resourceID"].startswith("seal.norse.")]
        self.assertEqual(len(seals), 24)
        for slug in BUILDER.SEALS:
            resource_id = f"seal.norse.{slug}"
            seal_outputs = [item for item in seals if item["resourceID"] == resource_id]
            self.assertEqual(len(seal_outputs), 4)
            self.assertEqual(
                {item["variant"] for item in seal_outputs},
                {"standard-raster-intermediate", "standard", "monochrome", "thumbnail-512"},
            )
            self.assertIn(
                f"Seals/{resource_id}.vector-master.pdf",
                {item["path"] for item in seal_outputs},
            )
            self.assertTrue(
                all(
                    tuple(item["size"])
                    == ((512, 512) if item["variant"] == "thumbnail-512" else (1024, 1024))
                    for item in seal_outputs
                )
            )

        frame = [item for item in plan if item["resourceID"] == "frame.norse.carved-knotwork"]
        crest = [item for item in plan if item["resourceID"] == "crest.norse.raven-mastery"]
        self.assertEqual(len(frame), 3)
        self.assertEqual(len(crest), 4)
        self.assertGreaterEqual(
            max(next(item for item in frame if item.get("format") == "pdf")["size"]),
            2048,
        )
        self.assertEqual(
            tuple(next(item for item in crest if item.get("format") == "pdf")["size"]),
            (2048, 2048),
        )

        backgrounds = [
            item for item in plan if item["resourceID"] == "background.norse.cold-sea-hall"
        ]
        self.assertEqual(
            {item["variant"] for item in backgrounds},
            {"standard", "reduce-motion", "high-contrast", "macos-wide-crop"},
        )
        self.assertTrue(all(max(item["size"]) >= 2732 for item in backgrounds))

        cards = [item for item in plan if item["kind"] == "codex-card"]
        self.assertEqual({item["variant"] for item in cards}, set(BUILDER.CARD_STATES))
        self.assertTrue(all(tuple(item["size"]) == (1600, 900) for item in cards))

        panels = [item for item in plan if item["kind"] == "panel-ornament"]
        self.assertEqual(
            {item["path"] for item in panels},
            {
                "PanelOrnaments/panel.norse.card-border.png",
                "PanelOrnaments/panel.norse.corner-ornament.png",
                "PanelOrnaments/panel.norse.divider.png",
                "PanelOrnaments/panel.norse.primary-button.png",
                "PanelOrnaments/panel.norse.tab-selector.png",
            },
        )
        scripts = [item for item in plan if item["kind"] == "script-specimen"]
        self.assertEqual(len(scripts), 3)
        self.assertTrue(all(tuple(item["size"]) == (1600, 600) for item in scripts))

        for item in plan:
            self.assertFalse(Path(item["path"]).is_absolute())
            self.assertNotIn("..", Path(item["path"]).parts)
            if item["targetPath"] is None:
                self.assertEqual(item["promotionStatus"], "derivation-only")
            else:
                target = BUILDER.TARGET_ROOT_RELATIVE / item["targetPath"]
                self.assertTrue(str(target).startswith(str(BUILDER.TARGET_ROOT_RELATIVE)))

    def test_supplied_source_inventory_is_valid(self) -> None:
        source_root = REPO_ROOT / BUILDER.SOURCE_ROOT_RELATIVE
        BUILDER.validate_sources(source_root)
        self.assertEqual(len(BUILDER.required_sources()), 25)

    def test_missing_sources_fail_before_rendering(self) -> None:
        with tempfile.TemporaryDirectory(prefix="norse-builder-missing-") as temporary:
            with self.assertRaisesRegex(ValueError, "missing regular source"):
                BUILDER.validate_sources(Path(temporary))

    def test_magenta_matte_has_clean_transparency_and_despill(self) -> None:
        source = Image.new("RGB", (9, 9), (250, 3, 251))
        for y in range(2, 7):
            for x in range(2, 7):
                source.putpixel((x, y), (190, 45, 185))
        for y in range(3, 6):
            for x in range(3, 6):
                source.putpixel((x, y), (40, 35, 30))

        first = BUILDER.chroma_key_magenta(source)
        second = BUILDER.chroma_key_magenta(source)
        self.assertEqual(first.mode, "RGBA")
        self.assertEqual(first.tobytes(), second.tobytes())
        self.assertEqual(first.getpixel((0, 0)), (0, 0, 0, 0))
        self.assertEqual(first.getpixel((4, 4)), (40, 35, 30, 255))

        red, green, blue, alpha = first.getpixel((4, 2))
        self.assertGreater(alpha, 0)
        self.assertLess(alpha, 255)
        self.assertLessEqual(min(red, blue) - green, 0)
        self.assertEqual(first.getchannel("A").getextrema(), (0, 255))

    def test_alpha_padding_preserves_every_source_pixel_without_cropping(self) -> None:
        source = Image.new("RGBA", (5, 3), (0, 0, 0, 0))
        for y in range(source.height):
            for x in range(source.width):
                source.putpixel((x, y), (x * 31, y * 53, x + y, 255))
        padded = BUILDER.pad_rgba_without_cropping(source, (8, 8))
        self.assertEqual(padded.size, (8, 8))
        self.assertEqual(padded.crop((1, 2, 6, 5)).tobytes(), source.tobytes())
        self.assertEqual(padded.getpixel((0, 0)), (0, 0, 0, 0))
        with self.assertRaisesRegex(ValueError, "exceeds no-crop canvas"):
            BUILDER.pad_rgba_without_cropping(source, (4, 4))

    def test_mjolnir_reconstruction_leaves_transparency_on_every_edge(self) -> None:
        source_path = (
            REPO_ROOT
            / BUILDER.SOURCE_ROOT_RELATIVE
            / "seals/seal.norse.mjolnir.png"
        )
        with Image.open(source_path) as source:
            source_rgba = source.convert("RGBA")
        source_box = source_rgba.getchannel("A").getbbox()
        self.assertEqual(source_box[2:], source_rgba.size)
        padded = BUILDER.pad_rgba_with_minimum_margin(source_rgba, (1024, 1024), 24)
        box = padded.getchannel("A").getbbox()
        self.assertIsNotNone(box)
        self.assertGreater(box[0], 0)
        self.assertGreater(box[1], 0)
        self.assertLess(box[2], padded.width)
        self.assertLess(box[3], padded.height)

    def test_high_contrast_relic_transform_preserves_alpha(self) -> None:
        source = Image.new("RGBA", (5, 5), (60, 50, 40, 255))
        source.putpixel((0, 0), (0, 0, 0, 0))
        source.putpixel((1, 1), (120, 90, 50, 128))
        transformed = BUILDER.high_contrast_rgba(source)
        self.assertEqual(transformed.getchannel("A").tobytes(), source.getchannel("A").tobytes())
        self.assertNotEqual(transformed.getpixel((2, 2))[:3], source.getpixel((2, 2))[:3])
        self.assertEqual(transformed.getpixel((0, 0)), (0, 0, 0, 0))

    def test_codex_card_states_are_exact_and_visually_distinct(self) -> None:
        source = Image.new("RGB", (160, 90))
        for y in range(source.height):
            for x in range(source.width):
                source.putpixel((x, y), (20 + x, 30 + y, 40 + (x + y) // 2))
        variants = {
            state: BUILDER.codex_card_variant(source, state) for state in BUILDER.CARD_STATES
        }
        self.assertTrue(all(image.size == (1600, 900) for image in variants.values()))
        self.assertTrue(all(image.mode == "RGB" for image in variants.values()))
        self.assertEqual(len({image.tobytes() for image in variants.values()}), len(variants))

    def test_script_specimen_uses_exact_mapping_and_repository_font(self) -> None:
        tokens, font_path = BUILDER.load_script_contract(REPO_ROOT)
        self.assertEqual(tokens, [chr(0x16A0 + value) for value in range(32)])
        self.assertEqual(font_path, REPO_ROOT / BUILDER.FONT_RELATIVE)
        variants = {
            name: BUILDER.script_specimen(REPO_ROOT, name)
            for name in ("standard", "high-contrast", "static-fallback")
        }
        self.assertTrue(all(image.size == (1600, 600) for image in variants.values()))
        self.assertEqual(len({image.tobytes() for image in variants.values()}), 3)

    def test_script_contract_rejects_a_glyph_mapping_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="norse-builder-script-") as temporary:
            temporary_root = Path(temporary)
            font_target = temporary_root / BUILDER.FONT_RELATIVE
            mapping_target = temporary_root / BUILDER.SCRIPT_MAPPING_RELATIVE
            font_target.parent.mkdir(parents=True)
            mapping_target.parent.mkdir(parents=True)
            shutil.copyfile(REPO_ROOT / BUILDER.FONT_RELATIVE, font_target)
            mapping = json.loads(
                (REPO_ROOT / BUILDER.SCRIPT_MAPPING_RELATIVE).read_text(encoding="utf-8")
            )
            mapping["glyphs"][0]["textToken"] = "ᚡ"
            mapping_target.write_text(
                json.dumps(mapping, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "differs from the exact contract"):
                BUILDER.load_script_contract(temporary_root)

    def test_lossless_pdf_wrapper_is_repeatable_and_uses_an_alpha_soft_mask(self) -> None:
        image = Image.new("RGBA", (13, 9), (20, 40, 60, 255))
        image.putpixel((0, 0), (0, 0, 0, 0))
        image.putpixel((1, 1), (80, 70, 60, 128))
        first = BUILDER.lossless_pdf_bytes(image)
        second = BUILDER.lossless_pdf_bytes(image)
        self.assertEqual(first, second)
        self.assertTrue(first.startswith(b"%PDF-1.4"))
        self.assertIn(b"/FlateDecode", first)
        self.assertIn(b"/SMask", first)
        self.assertNotIn(b"/DCTDecode", first)
        self.assertTrue(first.endswith(b"%%EOF\n"))

    def test_png_serialization_is_byte_repeatable_and_strips_metadata(self) -> None:
        source = Image.new("RGBA", (17, 11), (23, 41, 67, 191))
        source.info["comment"] = "authoring note"
        with tempfile.TemporaryDirectory(prefix="norse-builder-png-") as temporary:
            first = Path(temporary) / "first.png"
            second = Path(temporary) / "second.png"
            BUILDER.save_png(source, first)
            BUILDER.save_png(source, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with Image.open(first) as reopened:
                self.assertEqual(reopened.info, {})
                self.assertEqual(reopened.mode, "RGBA")
                self.assertEqual(reopened.size, source.size)

    def test_provenance_records_hash_dimensions_alpha_recipe_and_target(self) -> None:
        with tempfile.TemporaryDirectory(prefix="norse-builder-record-") as temporary:
            root = Path(temporary)
            source_root = root / "sources"
            output_root = root / "outputs"
            source_root.mkdir()
            output_root.mkdir()
            source = source_root / "sample.png"
            output = output_root / "candidate.png"
            Image.new("RGBA", (7, 5), (10, 20, 30, 0)).save(source)
            BUILDER.save_png(Image.new("RGBA", (11, 9), (50, 60, 70, 128)), output)
            source_record = BUILDER._source_record(source_root, "sample.png")
            spec = {
                "path": "Relics/candidate.png",
                "targetPath": "Relics/candidate.png",
                "resourceID": "relic.norse.sample",
                "variant": "standard",
                "recipeID": "magenta-matte-standard-v1",
            }
            rendered = Image.new("RGBA", (11, 9), (50, 60, 70, 128))
            record = BUILDER._output_record(output, spec, [source_record], rendered)
            self.assertEqual(record["sourceSHA256"], digest(source))
            self.assertEqual(record["sha256"], digest(output))
            self.assertEqual(record["pixelDimensions"], {"width": 11, "height": 9})
            self.assertTrue(record["alpha"]["present"])
            self.assertEqual(record["recipeID"], "magenta-matte-standard-v1")
            self.assertEqual(
                record["targetPath"],
                str(BUILDER.TARGET_ROOT_RELATIVE / "Relics/candidate.png"),
            )


if __name__ == "__main__":
    unittest.main()
