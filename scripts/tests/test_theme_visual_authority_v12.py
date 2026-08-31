#!/usr/bin/env python3
"""Focused tests for the active Theme-fidelity v1.2 authority validator."""

from __future__ import annotations

import csv
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_ROOT = REPOSITORY_ROOT / "scripts"
if str(SCRIPTS_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_ROOT))

from theme_fidelity_authority_v12 import (  # noqa: E402
    AuthorityV12Checker,
    DEFAULT_IMPORT_MANIFEST,
    payload_aggregate_sha256,
    sha256_file,
)
from theme_fidelity_authority_v13 import (  # noqa: E402
    DEFAULT_IMPORT_MANIFEST as ACTIVE_V13_IMPORT_MANIFEST,
)


CHECKER = SCRIPTS_ROOT / "check-theme-visual-authority.py"
SOURCE_AUTHORITY_ROOT = REPOSITORY_ROOT / DEFAULT_IMPORT_MANIFEST.parent


def detached_write(path: Path, value: str) -> None:
    """Replace a fixture hard link without changing its source inode."""
    path.unlink()
    path.write_text(value, encoding="utf-8")


class AuthorityFixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.authority_root = self.root / DEFAULT_IMPORT_MANIFEST.parent
        self.authority_root.parent.mkdir(parents=True, exist_ok=True)

        def link_or_copy(source: str, destination: str) -> str:
            try:
                os.link(source, destination)
                return destination
            except OSError:
                return shutil.copy2(source, destination)

        shutil.copytree(
            SOURCE_AUTHORITY_ROOT,
            self.authority_root,
            copy_function=link_or_copy,
        )
        legacy_source = (
            REPOSITORY_ROOT
            / "docs/verification/theme-fidelity-v4/authority/asset-manifest.json"
        )
        legacy_destination = (
            self.root
            / "docs/verification/theme-fidelity-v4/authority/asset-manifest.json"
        )
        shutil.copy2(legacy_source, legacy_destination)
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        policy = manifest["repositoryPolicy"]
        for raw in policy["shippingRoots"] + policy["rejectedRoots"]:
            (self.root / raw).mkdir(parents=True, exist_ok=True)

    @property
    def manifest_path(self) -> Path:
        return self.root / DEFAULT_IMPORT_MANIFEST

    def close(self) -> None:
        self.temporary.cleanup()

    def imported_path(self, relative: str) -> Path:
        return self.authority_root / relative

    def mutate_json(self, relative: str, mutation) -> None:
        path = self.imported_path(relative)
        document = json.loads(path.read_text(encoding="utf-8"))
        mutation(document)
        detached_write(path, json.dumps(document, indent=2, ensure_ascii=False) + "\n")
        self.refresh_inventory(relative)

    def refresh_inventory(self, relative: str) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        imported = self.imported_path(relative)
        record = next(item for item in manifest["files"] if item["path"] == relative)
        record["byteCount"] = imported.stat().st_size
        record["sha256"] = sha256_file(imported)
        manifest["payloadAggregateSHA256"] = payload_aggregate_sha256(manifest["files"])
        detached_write(
            self.manifest_path,
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        )

    def run(self):
        return AuthorityV12Checker(self.root, self.manifest_path).run()


class ActiveAuthorityTests(unittest.TestCase):
    def test_repository_bundle_passes_all_declared_counts(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)
        result = fixture.run()

        self.assertEqual(result["result"], "PASS", result["findings"])
        self.assertEqual(result["authorityStatus"], "active-acceptance-authority")
        self.assertEqual(result["entryCount"], 400)
        self.assertEqual(result["themeSurfaceAuthorityCount"], 100)
        self.assertEqual(result["mappingCount"], 1104)
        self.assertEqual(result["candidateCount"], 188)
        self.assertEqual(result["runtimeProbeCount"], 50)
        self.assertEqual(result["seedCount"], 100)
        self.assertEqual(result["assetCount"], 113)
        self.assertEqual(result["declaredDuplicateHashGroupCount"], 6)
        self.assertEqual(result["gateCount"], 40)

    def test_default_checker_selects_active_authority(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(CHECKER), "--root", str(REPOSITORY_ROOT)],
            check=False,
            capture_output=True,
            text=True,
        )
        result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(result["result"], "PASS", result["findings"])
        self.assertEqual(result["schemaVersion"], "1.3")
        self.assertEqual(result["authorityVersion"], "4.3")
        self.assertEqual(
            result["manifest"],
            ACTIVE_V13_IMPORT_MANIFEST.as_posix(),
        )

    def test_active_checker_preserves_historical_authority_directory(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)
        output = (
            fixture.root
            / "docs/verification/theme-fidelity-v4/authority/historical-result.json"
        )
        completed = subprocess.run(
            [
                sys.executable,
                str(CHECKER),
                "--root",
                str(fixture.root),
                "--output",
                str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        result = json.loads(completed.stdout)

        self.assertEqual(completed.returncode, 1)
        self.assertEqual(result["result"], "FAIL")
        self.assertIn(
            "immutable-output-path",
            {finding["code"] for finding in result["findings"]},
        )
        self.assertFalse(output.exists())

    def test_manual_crop_drift_fails_after_valid_inventory_refresh(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)
        relative = "02-COMPARISON-AUTHORITY/Comparison-Authority-v1.2.json"

        def mutate(document) -> None:
            document["entries"][0]["referenceMappings"][0]["sourceCrop"][
                "manualCoordinatesAllowed"
            ] = True

        fixture.mutate_json(relative, mutate)
        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("manual-source-crop-drift", codes)
        self.assertNotIn("import-hash-drift", codes)

    def test_candidate_catalog_kind_drift_fails_cross_validation(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)
        relative = "02-COMPARISON-AUTHORITY/Candidate-Capture-Catalog-v1.2.json"

        def mutate(document) -> None:
            candidate = next(
                item
                for item in document["candidates"]
                if item["id"] == "workspace.primary-surface"
            )
            candidate["kind"] = "renderer-output"
            candidate["captureOperation"] = "deterministic-png-export"

        fixture.mutate_json(relative, mutate)
        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("candidate-kind-count-drift", codes)
        self.assertIn("unknown-mapping-candidate", codes)
        self.assertNotIn("import-hash-drift", codes)

    def test_mapping_without_exact_candidate_source_fails(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)
        relative = "02-COMPARISON-AUTHORITY/Comparison-Authority-v1.2.json"

        def mutate(document) -> None:
            del document["entries"][0]["referenceMappings"][0][
                "candidateElementID"
            ]

        fixture.mutate_json(relative, mutate)
        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("mapping-candidate-source-drift", codes)
        self.assertIn("mapping-count-mismatch", codes)
        self.assertNotIn("import-hash-drift", codes)

    def test_mapping_index_drift_fails_exact_projection(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)
        relative = (
            "02-COMPARISON-AUTHORITY/Reference-Candidate-Mapping-Index-v1.2.csv"
        )
        path = fixture.imported_path(relative)
        with path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            fields = reader.fieldnames
            rows = list(reader)
        rows[0]["candidateID"] = "workspace.unapproved-neighbor"
        output = io.StringIO(newline="")
        writer = csv.DictWriter(output, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
        detached_write(path, output.getvalue())
        fixture.refresh_inventory(relative)

        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("mapping-index-projection-drift", codes)
        self.assertNotIn("import-hash-drift", codes)

    def test_uninventoried_controlling_file_fails_import_boundary(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)
        extra = (
            fixture.authority_root
            / "01-CONTROLLING-DECISIONS/uninventoried-note.md"
        )
        extra.write_text("Uninventoried content.\n", encoding="utf-8")

        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("import-inventory-drift", codes)


if __name__ == "__main__":
    unittest.main()
