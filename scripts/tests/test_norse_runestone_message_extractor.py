#!/usr/bin/env python3
"""Focused tests for the deterministic near-square Runestone extraction."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

from PIL import Image, ImageDraw, ImageOps


REPO_ROOT = Path(__file__).resolve().parents[2]
EXTRACTOR_PATH = REPO_ROOT / "scripts/extract-norse-runestone-message-source.py"
SPEC = importlib.util.spec_from_file_location("norse_runestone_message_extractor", EXTRACTOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"unable to load {EXTRACTOR_PATH}")
EXTRACTOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = EXTRACTOR
SPEC.loader.exec_module(EXTRACTOR)


class NorseRunestoneMessageExtractorTests(unittest.TestCase):
    def test_stored_output_and_record_are_byte_repeatable(self) -> None:
        first_output, first_record = EXTRACTOR.build(REPO_ROOT)
        second_output, second_record = EXTRACTOR.build(REPO_ROOT)
        self.assertEqual(first_output, second_output)
        self.assertEqual(first_record, second_record)
        self.assertEqual(first_output, (REPO_ROOT / EXTRACTOR.OUTPUT_RELATIVE).read_bytes())
        self.assertEqual(first_record, (REPO_ROOT / EXTRACTOR.RECORD_RELATIVE).read_bytes())

    def test_owner_import_rejects_unapproved_bytes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="runestone-message-owner-") as temporary:
            source = Path(temporary) / "wrong.png"
            Image.new("RGB", EXTRACTOR.OWNER_SOURCE_SIZE, (7, 21, 34)).save(source)
            with self.assertRaisesRegex(ValueError, "digest differs"):
                EXTRACTOR.import_owner_region(source)

    def test_output_is_near_square_rgba_with_a_transparent_perimeter(self) -> None:
        with Image.open(REPO_ROOT / EXTRACTOR.OUTPUT_RELATIVE) as image:
            self.assertEqual(image.format, "PNG")
            self.assertEqual(image.mode, "RGBA")
            self.assertEqual(image.size, EXTRACTOR.OUTPUT_SIZE)
            alpha = image.getchannel("A")
            self.assertEqual(alpha.getextrema(), (0, 255))
            bounds = alpha.getbbox()
            self.assertIsNotNone(bounds)
            width = bounds[2] - bounds[0]
            height = bounds[3] - bounds[1]
            self.assertGreaterEqual(width / height, 0.95)
            self.assertLessEqual(width / height, 1.15)
            self.assertGreater(bounds[0], 0)
            self.assertGreater(bounds[1], 0)
            self.assertLess(bounds[2], image.width)
            self.assertLess(bounds[3], image.height)
            self.assertEqual(image.getpixel((0, 0)), (0, 0, 0, 0))
            self.assertTrue(
                all(pixel[:3] == (0, 0, 0) for pixel in image.getdata() if pixel[3] == 0)
            )

    def test_reconstruction_replaces_the_seal_occlusion_with_owner_frame_pixels(self) -> None:
        repair_left = EXTRACTOR.CORNER_DESTINATION[0]
        repair_top = EXTRACTOR.CORNER_DESTINATION[1]
        repair_right = repair_left + (
            EXTRACTOR.CORNER_SOURCE_BOUNDS[2] - EXTRACTOR.CORNER_SOURCE_BOUNDS[0]
        )
        repair_bottom = repair_top + (
            EXTRACTOR.CORNER_SOURCE_BOUNDS[3] - EXTRACTOR.CORNER_SOURCE_BOUNDS[1]
        )
        seal_left, seal_top, seal_right, seal_bottom = EXTRACTOR.SELECTED_SEAL_OCCLUSION_BOUNDS
        self.assertLessEqual(repair_left, seal_left)
        self.assertLessEqual(repair_top, seal_top)
        self.assertGreaterEqual(repair_right, seal_right)
        self.assertGreaterEqual(repair_bottom, seal_bottom)
        self.assertLessEqual(
            repair_left + EXTRACTOR.CORNER_JOIN_FEATHER,
            seal_left,
        )
        self.assertLessEqual(
            repair_top + EXTRACTOR.CORNER_JOIN_FEATHER,
            seal_top,
        )

        with Image.open(REPO_ROOT / EXTRACTOR.OUTPUT_RELATIVE) as image:
            offset_x = (EXTRACTOR.OUTPUT_SIZE[0] - EXTRACTOR.OBJECT_WORKING_SIZE[0]) // 2
            offset_y = (EXTRACTOR.OUTPUT_SIZE[1] - EXTRACTOR.OBJECT_WORKING_SIZE[1]) // 2
            scale = EXTRACTOR.UPSCALE
            left = image.crop(
                (
                    offset_x + 9 * scale,
                    offset_y + 150 * scale,
                    offset_x + 24 * scale,
                    offset_y + 175 * scale,
                )
            )
            right = image.crop(
                (
                    offset_x + 165 * scale,
                    offset_y + 150 * scale,
                    offset_x + 180 * scale,
                    offset_y + 175 * scale,
                )
            )
            self.assertEqual(right.tobytes(), ImageOps.mirror(left).tobytes())

    def test_field_replacement_encloses_every_declared_glyph_pixel(self) -> None:
        mask = Image.new("1", EXTRACTOR.OWNER_REGION_SIZE, 0)
        ImageDraw.Draw(mask).polygon(EXTRACTOR.FIELD_POLYGON, fill=1)
        left, top, right, bottom = EXTRACTOR.GLYPH_BEARING_BOUNDS
        self.assertTrue(
            all(mask.getpixel((x, y)) for y in range(top, bottom) for x in range(left, right))
        )

    def test_record_is_explicit_about_source_limits_and_forbidden_operations(self) -> None:
        record = json.loads((REPO_ROOT / EXTRACTOR.RECORD_RELATIVE).read_text())
        self.assertEqual(record["sourceAuthority"]["sha256"], EXTRACTOR.OWNER_SOURCE_SHA256)
        self.assertEqual(
            record["sourceAuthority"]["extractionBounds"],
            {"x": 356, "y": 462, "width": 189, "height": 189},
        )
        self.assertFalse(record["storedOwnerRegion"]["containsCompleteUIScreen"])
        self.assertFalse(record["authorityLimitation"]["exactCompleteObjectAvailable"])
        self.assertIn("occlude", record["authorityLimitation"]["reason"])
        transformation = record["transformation"]
        self.assertTrue(transformation["sourceRegionCrop"])
        self.assertTrue(transformation["fieldMaterialCenterCrop"])
        self.assertFalse(transformation["outputObjectCropping"])
        self.assertFalse(transformation["cropping"])
        self.assertTrue(transformation["aspectFit"])
        self.assertFalse(transformation["nonUniformScaling"])
        self.assertFalse(transformation["generativeFill"])
        self.assertFalse(transformation["referenceScreenshotEmbedded"])
        self.assertIn("No glyph pixels", transformation["runtimeGlyphPolicy"])
        self.assertIn("No user-selected Seal", transformation["runtimeSealPolicy"])
        self.assertEqual(
            {reference["sha256"] for reference in record["controllingReferences"]},
            {reference["sha256"] for reference in EXTRACTOR.REFERENCE_IDENTITIES},
        )
        self.assertEqual(
            record["corroboratingReference"],
            EXTRACTOR.CORROBORATING_REFERENCE,
        )


if __name__ == "__main__":
    unittest.main()
