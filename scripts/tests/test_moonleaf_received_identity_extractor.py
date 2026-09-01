#!/usr/bin/env python3
"""Focused tests for the Moonleaf received identity extractor."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from PIL import Image, ImageChops


REPO_ROOT = Path(__file__).resolve().parents[2]
AUTHORITY_PACKAGE_NAME = (
    "Rune-Scribe-Theme-Fidelity-v4.3-Canonical-Authority-and-Remediation"
)


def resolve_authority_root() -> Path:
    configured = os.environ.get("RUNESCRIBE_V43_AUTHORITY_PACKAGE")
    candidates = (
        Path(configured) if configured else None,
        Path.home() / "Projects/RuneScribe" / AUTHORITY_PACKAGE_NAME,
        Path.home() / "Projects" / AUTHORITY_PACKAGE_NAME,
    )
    for candidate in candidates:
        if candidate is not None and candidate.is_dir():
            return candidate
    raise RuntimeError(
        "v4.3 authority package not found; set RUNESCRIBE_V43_AUTHORITY_PACKAGE"
    )


AUTHORITY_ROOT = resolve_authority_root()
EXTRACTOR_PATH = REPO_ROOT / "scripts/extract-moonleaf-received-identity-v43.py"


def load_extractor():
    specification = importlib.util.spec_from_file_location(
        "moonleaf_received_identity_extractor",
        EXTRACTOR_PATH,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {EXTRACTOR_PATH}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


EXTRACTOR = load_extractor()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digests(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): sha256_file(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


class MoonleafReceivedIdentityExtractorTests(unittest.TestCase):
    def test_only_owner_received_sources_are_authoring_inputs(self) -> None:
        expected = {
            "received-primary": (
                "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/"
                "approved-source-full-029-941x1672.png"
            ),
            "received-share": (
                "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/"
                "approved-source-full-009-941x1672.png"
            ),
        }
        self.assertEqual(
            {key: value.relative_path for key, value in EXTRACTOR.SOURCE_SPECS.items()},
            expected,
        )
        for source in EXTRACTOR.SOURCE_SPECS.values():
            self.assertTrue(source.relative_path.startswith(
                "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/approved-source-full-"
            ))
            self.assertEqual(sha256_file(AUTHORITY_ROOT / source.relative_path), source.sha256)
            self.assertEqual(sha256_file(AUTHORITY_ROOT / source.duplicate_relative_path), source.sha256)

    def test_received_source_aliases_match_controlling_goldens_by_pixel(self) -> None:
        sources = EXTRACTOR.validate_sources(AUTHORITY_ROOT)
        self.assertEqual(set(sources), {"received-primary", "received-share"})
        for label, source in sources.items():
            specification = EXTRACTOR.SOURCE_SPECS[label]
            golden = Image.open(AUTHORITY_ROOT / specification.golden_relative_path).convert("RGB")
            duplicate = Image.open(AUTHORITY_ROOT / specification.duplicate_relative_path).convert("RGB")
            self.assertEqual(source.size, (941, 1672))
            self.assertEqual(source.tobytes(), golden.tobytes())
            self.assertEqual(source.tobytes(), duplicate.tobytes())

    def test_bounds_and_resource_identities_are_explicit(self) -> None:
        expected = {
            "primary-sender-avatar": (
                (56, 228, 163, 335),
                "resource.received.moonleaf.primary.sender-avatar",
            ),
            "share-sender-avatar": (
                (60, 224, 159, 323),
                "resource.received.moonleaf.share.sender-avatar",
            ),
            "share-codex-badge": (
                (657, 247, 700, 290),
                "resource.received.moonleaf.share.codex-badge",
            ),
            "primary-medallion": (
                (688, 880, 881, 1073),
                "resource.received.moonleaf.primary.medallion",
            ),
            "share-medallion": (
                (625, 865, 766, 1006),
                "resource.received.moonleaf.share.medallion",
            ),
        }
        self.assertEqual(
            {spec.key: (spec.bounds, spec.resource_id) for spec in EXTRACTOR.ASSET_SPECS},
            expected,
        )
        for spec in EXTRACTOR.ASSET_SPECS:
            left, top, right, bottom = spec.bounds
            self.assertEqual(right - left, bottom - top)
            self.assertGreaterEqual(left, 0)
            self.assertGreaterEqual(top, 0)
            self.assertLessEqual(right, 941)
            self.assertLessEqual(bottom, 1672)

    def test_ellipse_mask_is_symmetric_and_has_real_alpha(self) -> None:
        for size in ((43, 43), (99, 99), (107, 107), (141, 141), (193, 193)):
            alpha = EXTRACTOR.ellipse_alpha(size)
            self.assertEqual(alpha.getextrema(), (0, 255))
            self.assertEqual(alpha.tobytes(), alpha.transpose(Image.Transpose.FLIP_LEFT_RIGHT).tobytes())
            self.assertEqual(alpha.tobytes(), alpha.transpose(Image.Transpose.FLIP_TOP_BOTTOM).tobytes())
            histogram = alpha.histogram()
            self.assertGreater(histogram[0], 0)
            self.assertGreater(histogram[255], 0)
            self.assertGreater(sum(histogram[1:255]), 0)

    def test_extraction_is_lossless_and_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as first_directory, tempfile.TemporaryDirectory() as second_directory:
            first_root = Path(first_directory)
            second_root = Path(second_directory)
            first_production = first_root / "production"
            first_evidence = first_root / "evidence"
            second_production = second_root / "production"
            second_evidence = second_root / "evidence"
            first = EXTRACTOR.build_assets(
                AUTHORITY_ROOT,
                first_production,
                first_evidence,
                EXTRACTOR_PATH,
            )
            second = EXTRACTOR.build_assets(
                AUTHORITY_ROOT,
                second_production,
                second_evidence,
                EXTRACTOR_PATH,
            )
            self.assertEqual(first, second)
            self.assertEqual(tree_digests(first_root), tree_digests(second_root))
            self.assertEqual(
                first["qualityReview"]["targetDeviceRuntime"],
                "PENDING_PROVIDER_BINDING",
            )
            self.assertNotIn("targetDeviceRuntimeEvidence", first)

            sources = EXTRACTOR.validate_sources(AUTHORITY_ROOT)
            for spec in EXTRACTOR.ASSET_SPECS:
                source_region = sources[spec.source_label].crop(spec.bounds).convert("RGB")
                evidence = Image.open(first_evidence / spec.source_region_filename).convert("RGB")
                output = Image.open(first_production / spec.output_filename).convert("RGBA")
                self.assertEqual(evidence.tobytes(), source_region.tobytes())
                self.assertEqual(output.convert("RGB").tobytes(), source_region.tobytes())
                self.assertEqual(output.size, source_region.size)
                self.assertEqual(output.getchannel("A").getextrema(), (0, 255))
                round_trip = Image.alpha_composite(source_region.convert("RGBA"), output).convert("RGB")
                self.assertEqual(ImageChops.difference(round_trip, source_region).getbbox(), None)

    def test_provenance_records_bounds_digests_recipe_and_nonreuse(self) -> None:
        provenance_path = (
            REPO_ROOT
            / EXTRACTOR.EVIDENCE_RELATIVE_ROOT
            / EXTRACTOR.PROVENANCE_FILENAME
        )
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        self.assertEqual(provenance["pipeline"], EXTRACTOR.PIPELINE)
        self.assertEqual(provenance["pipelineSHA256"], sha256_file(EXTRACTOR_PATH))
        self.assertEqual(provenance["recipe"]["resampling"], "none")
        self.assertEqual(provenance["recipe"]["colorTransformation"], "none")
        self.assertEqual(len(provenance["outputs"]), 5)
        self.assertEqual(provenance["qualityReview"]["oneHundredPercent"], "PASS")
        self.assertEqual(provenance["qualityReview"]["twoHundredPercent"], "PASS")
        self.assertEqual(
            provenance["qualityReview"]["targetDeviceRuntime"],
            "PENDING_PROVIDER_BINDING",
        )
        self.assertFalse(provenance["reuseAssessment"]["pixelIdenticalAfterUniformScale"])
        self.assertLess(provenance["reuseAssessment"]["exactRGBPixelAgreementFraction"], 1.0)
        for record in provenance["outputs"]:
            self.assertEqual(record["comparisonBackToSource"]["maximumChannelDifference"], 0)
            self.assertEqual(record["comparisonBackToSource"]["sourceRGBPlaneMaximumDifference"], 0)
            self.assertEqual(len(record["boundsLTRBExclusive"]), 4)
            self.assertEqual(len(record["output"]["sha256"]), 64)
            self.assertEqual(len(record["sourceRegionEvidence"]["sha256"]), 64)

    def test_checked_in_assets_and_provenance_verify(self) -> None:
        summary = EXTRACTOR.check_assets(
            AUTHORITY_ROOT,
            REPO_ROOT / EXTRACTOR.PRODUCTION_RELATIVE_ROOT,
            REPO_ROOT / EXTRACTOR.EVIDENCE_RELATIVE_ROOT,
            EXTRACTOR_PATH,
        )
        self.assertEqual(summary["status"], "PASS")
        self.assertEqual(summary["assetCount"], 5)
        self.assertEqual(summary["sourceCount"], 2)


if __name__ == "__main__":
    unittest.main()
