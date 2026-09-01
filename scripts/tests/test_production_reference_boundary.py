#!/usr/bin/env python3
"""Synthetic mutation coverage for the production reference-boundary guard."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

from PIL import Image, ImageDraw


REPO_ROOT = Path(__file__).resolve().parents[2]
GUARD_PATH = REPO_ROOT / "scripts/check-production-reference-boundary.py"


def load_guard():
    specification = importlib.util.spec_from_file_location(
        "production_reference_boundary_guard", GUARD_PATH
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {GUARD_PATH}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


GUARD = load_guard()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def patterned_image(size: tuple[int, int], variant: int) -> Image.Image:
    width, height = size
    image = Image.new(
        "RGBA",
        size,
        (24 + variant * 7, 33 + variant * 5, 52 + variant * 3, 255),
    )
    draw = ImageDraw.Draw(image)
    for index in range(18):
        x = (index * 37 + variant * 19) % max(1, width - 48)
        y = (index * 53 + variant * 23) % max(1, height - 48)
        color = (
            (43 + index * 29 + variant * 11) % 256,
            (87 + index * 17 + variant * 13) % 256,
            (131 + index * 31 + variant * 7) % 256,
            255,
        )
        draw.rectangle((x, y, min(width - 1, x + 32), min(height - 1, y + 25)), fill=color)
        draw.ellipse(
            (max(0, x - 9), max(0, y - 7), min(width - 1, x + 40), min(height - 1, y + 41)),
            outline=(245, 225, 177, 255),
            width=3,
        )
    draw.line((7, height - 11, width - 13, 9), fill=(250, 102, 57, 255), width=5)
    draw.line((11, 8, width - 8, height - 17), fill=(72, 231, 191, 255), width=4)
    return image


class Fixture:
    def __init__(self, root: Path) -> None:
        self.package = root / "package"
        self.repository = root / "repository"
        self.package.mkdir(parents=True)
        self.repository.mkdir(parents=True)
        self.protected_relative = "assets/authority/approved-board.png"
        self.candidate_relative = "assets/candidates/seals/approved-emblem.png"
        self.protected_path = self.package / self.protected_relative
        self.candidate_path = self.package / self.candidate_relative
        self.protected_path.parent.mkdir(parents=True)
        self.candidate_path.parent.mkdir(parents=True)
        patterned_image((320, 240), 1).save(self.protected_path, compress_level=9)
        patterned_image((192, 192), 2).save(self.candidate_path, compress_level=9)
        self.manifest = self.package / "asset-index.json"
        self.catalog = self.package / "exact-identities.json"
        self.write_controls()

    def asset_record(self, relative: str, authority: str) -> dict:
        path = self.package / relative
        with Image.open(path) as image:
            dimensions = list(image.size)
        return {
            "path": relative,
            "authority": authority,
            "sha256": sha256_file(path),
            "dimensions": dimensions,
            "byteCount": path.stat().st_size,
        }

    def write_controls(self) -> None:
        assets = [
            self.asset_record(self.protected_relative, "authoritative-full-golden"),
            self.asset_record(self.candidate_relative, "approved-production-candidate"),
        ]
        self.manifest.write_text(
            json.dumps({"schemaVersion": "test", "assetCount": len(assets), "assets": assets}),
            encoding="utf-8",
        )
        candidate = assets[1]
        self.catalog.write_text(
            json.dumps(
                {
                    "schemaVersion": "test",
                    "candidates": [
                        {
                            "evaluationKind": "resource-byte-identity",
                            "thresholdProfile": "exact-resource-v1",
                            "renderMode": "resolved-resource-export",
                            "referenceAsset": candidate["path"],
                            "referenceSHA256": candidate["sha256"],
                            "referenceDimensions": candidate["dimensions"],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    def shipping_path(self, tail: str) -> Path:
        path = (
            self.repository
            / "Packages/Example/Sources/Theme/Resources/Production"
            / tail
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def run(self) -> dict:
        return GUARD.run_guard(
            self.repository,
            self.package,
            self.manifest,
            self.catalog,
        )


class ProductionReferenceBoundaryTests(unittest.TestCase):
    def fixture(self) -> tuple[tempfile.TemporaryDirectory[str], Fixture]:
        temporary = tempfile.TemporaryDirectory()
        return temporary, Fixture(Path(temporary.name))

    def test_independent_shipping_asset_passes(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        patterned_image((286, 214), 7).save(fixture.shipping_path("art/independent.png"))

        report = fixture.run()

        self.assertEqual(report["result"], "PASS")
        self.assertEqual(report["summary"]["findingCount"], 0)

    def test_exact_protected_bytes_fail(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        shutil.copyfile(fixture.protected_path, fixture.shipping_path("art/copied.png"))

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-101"])

    def test_lossless_reencode_of_protected_pixels_fails(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        with Image.open(fixture.protected_path) as image:
            image.save(fixture.shipping_path("art/reencoded.png"), compress_level=0)

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-102"])

    def test_uniform_resize_of_protected_pixels_fails(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        with Image.open(fixture.protected_path) as image:
            image.resize((160, 120), Image.Resampling.LANCZOS).save(
                fixture.shipping_path("art/resized.png")
            )

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-103"])

    def test_lossy_reencode_of_protected_pixels_fails(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        with Image.open(fixture.protected_path) as image:
            image.convert("RGB").save(
                fixture.shipping_path("art/reencoded.jpg"),
                quality=92,
                subsampling=0,
            )

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-103"])

    def test_large_crop_of_protected_pixels_fails(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        with Image.open(fixture.protected_path) as image:
            image.crop((55, 35, 285, 215)).save(fixture.shipping_path("art/crop.png"))

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-104"])

    def test_large_embedded_protected_region_fails(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        canvas = patterned_image((500, 400), 9)
        with Image.open(fixture.protected_path) as source:
            canvas.alpha_composite(source.convert("RGBA"), (90, 80))
        canvas.save(fixture.shipping_path("art/embedded.png"))

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-104"])

    def test_scaled_embedded_protected_region_fails(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        canvas = patterned_image((500, 400), 9)
        with Image.open(fixture.protected_path) as source:
            scaled = source.convert("RGBA").resize((240, 180), Image.Resampling.LANCZOS)
            canvas.alpha_composite(scaled, (120, 105))
        canvas.save(fixture.shipping_path("art/scaled-embedded.png"))

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-104"])

    def test_protected_pixels_wrapped_in_pdf_fail(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        with Image.open(fixture.protected_path) as image:
            image.convert("RGB").save(
                fixture.shipping_path("art/wrapped.pdf"),
                "PDF",
                resolution=72.0,
            )

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertIn(report["findings"][0]["code"], {"PRB-103", "PRB-104"})
        self.assertTrue(report["findings"][0]["shippingPath"].endswith("#page=1"))

    def test_transparent_protected_object_wrapped_in_pdf_fails(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        transparent_relative = "assets/authority/transparent-object.png"
        transparent_path = fixture.package / transparent_relative
        image = Image.new("RGBA", (320, 240), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        for index in range(14):
            x = 18 + (index * 43) % 252
            y = 15 + (index * 31) % 172
            draw.ellipse(
                (x, y, x + 38, y + 42),
                fill=((index * 29) % 255, 90 + index * 7, 210 - index * 5, 255),
                outline=(250, 235, 180, 255),
                width=3,
            )
        draw.line((25, 215, 295, 22), fill=(57, 231, 191, 255), width=7)
        image.save(transparent_path)
        manifest = json.loads(fixture.manifest.read_text(encoding="utf-8"))
        manifest["assets"].append(
            fixture.asset_record(transparent_relative, "authoritative-focal-reference")
        )
        manifest["assetCount"] = len(manifest["assets"])
        fixture.manifest.write_text(json.dumps(manifest), encoding="utf-8")
        white = Image.new("RGB", image.size, "white")
        white.paste(image, mask=image.getchannel("A"))
        white.save(fixture.shipping_path("art/transparent-wrapped.pdf"), "PDF", resolution=72.0)

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-104"])

    def test_declared_candidate_passes_only_at_exact_identity(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        target = fixture.shipping_path("seals/approved-emblem.png")
        shutil.copyfile(fixture.candidate_path, target)

        report = fixture.run()

        self.assertEqual(report["result"], "PASS")
        self.assertEqual(report["summary"]["allowedExactIdentityCount"], 1)
        self.assertEqual(report["allowedExactIdentities"][0]["shippingPath"], target.relative_to(fixture.repository).as_posix())

    def test_reencoded_candidate_fails_exact_identity_policy(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        with Image.open(fixture.candidate_path) as image:
            image.save(fixture.shipping_path("seals/approved-emblem.png"), compress_level=0)

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-105"])

    def test_resized_candidate_fails_exact_identity_policy(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        with Image.open(fixture.candidate_path) as image:
            image.resize((144, 144), Image.Resampling.LANCZOS).save(
                fixture.shipping_path("seals/approved-emblem.png")
            )

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-105"])

    def test_candidate_bytes_in_wrong_resource_role_fail(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        shutil.copyfile(fixture.candidate_path, fixture.shipping_path("background/copied.png"))

        report = fixture.run()

        self.assertEqual(report["result"], "FAIL")
        self.assertEqual([item["code"] for item in report["findings"]], ["PRB-106"])

    def test_malformed_manifest_fails_closed(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        patterned_image((100, 100), 4).save(fixture.shipping_path("art/independent.png"))
        fixture.manifest.write_text("{", encoding="utf-8")

        with self.assertRaises(GUARD.GuardError):
            fixture.run()

    def test_unreadable_shipping_raster_fails_closed(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        fixture.shipping_path("art/corrupt.png").write_bytes(b"not a raster")

        with self.assertRaises(GUARD.GuardError):
            fixture.run()

    def test_missing_dependency_fails_closed(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        patterned_image((100, 100), 4).save(fixture.shipping_path("art/independent.png"))
        previous = GUARD.DEPENDENCY_ERRORS
        GUARD.DEPENDENCY_ERRORS = ["required image dependency unavailable"]
        self.addCleanup(setattr, GUARD, "DEPENDENCY_ERRORS", previous)

        with self.assertRaises(GUARD.GuardError):
            fixture.run()

    def test_report_rendering_is_deterministic(self) -> None:
        temporary, fixture = self.fixture()
        self.addCleanup(temporary.cleanup)
        with Image.open(fixture.protected_path) as image:
            image.crop((55, 35, 285, 215)).save(fixture.shipping_path("art/crop.png"))

        first = GUARD.render_report(fixture.run())
        second = GUARD.render_report(fixture.run())

        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
