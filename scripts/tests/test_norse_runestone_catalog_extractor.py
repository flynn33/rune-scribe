#!/usr/bin/env python3
"""Focused tests for the deterministic Runestone catalog extraction."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

from PIL import Image


REPO_ROOT = Path(__file__).resolve().parents[2]
EXTRACTOR_PATH = REPO_ROOT / "scripts/extract-norse-runestone-catalog-source.py"
SPEC = importlib.util.spec_from_file_location("norse_runestone_catalog_extractor", EXTRACTOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"unable to load {EXTRACTOR_PATH}")
EXTRACTOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = EXTRACTOR
SPEC.loader.exec_module(EXTRACTOR)


class NorseRunestoneCatalogExtractorTests(unittest.TestCase):
    def test_stored_extraction_is_byte_repeatable_and_fully_bound(self) -> None:
        self.assertIn("theme-fidelity-v4", EXTRACTOR.LANDSCAPE_SOURCE_RELATIVE.parts)
        self.assertIn("theme-fidelity-v4-3", EXTRACTOR.OUTPUT_RELATIVE.parts)
        self.assertIn("theme-fidelity-v4-3", EXTRACTOR.RECORD_RELATIVE.parts)
        first_output, first_record = EXTRACTOR.build(REPO_ROOT)
        second_output, second_record = EXTRACTOR.build(REPO_ROOT)
        self.assertEqual(first_output, second_output)
        self.assertEqual(first_record, second_record)
        self.assertEqual(
            first_output,
            (REPO_ROOT / EXTRACTOR.OUTPUT_RELATIVE).read_bytes(),
        )
        self.assertEqual(
            first_record,
            (REPO_ROOT / EXTRACTOR.RECORD_RELATIVE).read_bytes(),
        )

        record = json.loads(first_record)
        self.assertEqual(record["sourceAuthority"]["sha256"], EXTRACTOR.OWNER_SOURCE_SHA256)
        self.assertEqual(
            record["sourceAuthority"]["extractionBounds"],
            {"x": 655, "y": 104, "width": 142, "height": 185},
        )
        self.assertFalse(record["storedOwnerRegion"]["containsCompleteUIScreen"])
        self.assertEqual(
            record["transformation"]["runtimeGlyphPolicy"],
            "No glyph pixels are baked into this master; production Script rendering supplies glyphs.",
        )
        self.assertFalse(record["transformation"]["cropping"])
        self.assertTrue(record["transformation"]["aspectFit"])

    def test_authoring_source_is_portrait_rgba_with_true_transparency(self) -> None:
        with Image.open(REPO_ROOT / EXTRACTOR.OUTPUT_RELATIVE) as image:
            self.assertEqual(image.format, "PNG")
            self.assertEqual(image.mode, "RGBA")
            self.assertEqual(image.size, EXTRACTOR.AUTHORING_SIZE)
            alpha = image.getchannel("A")
            self.assertEqual(alpha.getextrema(), (0, 255))
            bounds = alpha.getbbox()
            self.assertIsNotNone(bounds)
            self.assertLess(bounds[2] - bounds[0], bounds[3] - bounds[1])
            self.assertGreater(bounds[0], 0)
            self.assertGreater(bounds[1], 0)
            self.assertLess(bounds[2], image.width)
            self.assertLess(bounds[3], image.height)

    def test_owner_source_import_rejects_wrong_bytes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runestone-owner-source-") as temporary:
            source = Path(temporary) / "wrong.png"
            Image.new("RGB", EXTRACTOR.OWNER_SOURCE_SIZE, (7, 21, 34)).save(source)
            with self.assertRaisesRegex(ValueError, "digest differs"):
                EXTRACTOR.import_owner_region(source)

    def test_field_replacement_encloses_the_declared_glyph_region(self) -> None:
        mask = Image.new("1", EXTRACTOR.OWNER_REGION_SIZE, 0)
        from PIL import ImageDraw

        ImageDraw.Draw(mask).polygon(EXTRACTOR.FIELD_POLYGON, fill=1)
        left, top, right, bottom = EXTRACTOR.GLYPH_BEARING_BOUNDS
        self.assertTrue(
            all(mask.getpixel((x, y)) for y in range(top, bottom) for x in range(left, right))
        )


if __name__ == "__main__":
    unittest.main()
