#!/usr/bin/env python3
"""Focused tests for the Theme-fidelity v1.3 authority validator."""

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

from theme_fidelity_authority_v13 import (  # noqa: E402
    AuthorityV13Checker,
    DEFAULT_IMPORT_MANIFEST,
)


CHECKER = SCRIPTS_ROOT / "theme_fidelity_authority_v13.py"
SOURCE_AUTHORITY_ROOT = REPOSITORY_ROOT / DEFAULT_IMPORT_MANIFEST.parent


def detached_write(path: Path, value: str) -> None:
    """Replace a fixture hard link without changing the source inode."""
    path.unlink()
    path.write_text(value, encoding="utf-8")


class AuthorityFixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="runescribe-v13-authority-")
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

    def run(self):
        return AuthorityV13Checker(self.root, self.manifest_path).run()


class ActiveAuthorityV13Tests(unittest.TestCase):
    def test_repository_bundle_passes_exact_cardinalities(self) -> None:
        result = AuthorityV13Checker(
            REPOSITORY_ROOT,
            REPOSITORY_ROOT / DEFAULT_IMPORT_MANIFEST,
        ).run()

        self.assertEqual(result["result"], "PASS", result["findings"])
        self.assertEqual(result["responsiveEntryCount"], 400)
        self.assertEqual(result["mappingCount"], 1104)
        self.assertEqual(result["canonicalCandidateCount"], 50)
        self.assertEqual(result["responsiveCandidateCount"], 188)
        self.assertEqual(result["runtimeProbeCount"], 50)
        self.assertEqual(result["runtimeProbeInstanceCount"], 576)
        self.assertEqual(result["seedCount"], 100)
        self.assertEqual(result["gateCount"], 40)

    def test_cli_reports_evidence_relative_paths(self) -> None:
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
        self.assertEqual(result["manifest"], DEFAULT_IMPORT_MANIFEST.as_posix())
        self.assertFalse(any(finding["path"].startswith("/") for finding in result["findings"]))

    def test_seed_marker_drift_fails_even_when_only_one_seed_changes(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)

        fixture.mutate_json(
            "03-COMPARISON-AUTHORITY/Deterministic-Seed-Catalog-v1.3.json",
            lambda document: document["seeds"][0]["launchEnvironment"].__setitem__(
                "RUNESCRIBE_QUALIFICATION", "theme-fidelity-v4.3"
            ),
        )
        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("seed-marker-drift", codes)
        self.assertIn("imported-file-hash-drift", codes)

    def test_candidate_output_cannot_enter_reference_authority_boundary(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)

        def mutate(document) -> None:
            candidate = document["candidates"][0]
            candidate["outputPath"] = (
                "docs/verification/theme-fidelity-v4-3/authority/"
                + candidate["referenceAsset"]
            )

        fixture.mutate_json(
            "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-v1.3.json",
            mutate,
        )
        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("candidate-reference-separation", codes)

    def test_responsive_matrix_must_remain_exact_projection(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)

        fixture.mutate_json(
            "03-COMPARISON-AUTHORITY/Responsive-Surface-Matrix-v1.3.json",
            lambda document: document["entries"][0].__setitem__(
                "candidateOutputDirectory",
                "docs/verification/theme-fidelity-v4-3/comparisons/drift",
            ),
        )
        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("responsive-matrix-projection-drift", codes)

    def test_mapping_index_must_remain_exact_ordered_projection(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)
        path = fixture.imported_path(
            "03-COMPARISON-AUTHORITY/Reference-Candidate-Mapping-Index-v1.3.csv"
        )
        with path.open("r", encoding="utf-8", newline="") as stream:
            reader = csv.DictReader(stream)
            fields = reader.fieldnames
            rows = list(reader)
        rows[0]["candidateID"] = "canonical.invalid"
        output = io.StringIO(newline="")
        writer = csv.DictWriter(output, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
        detached_write(path, output.getvalue())

        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("mapping-index-projection-drift", codes)

    def test_all_gates_remain_blocking_and_ordered(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)

        fixture.mutate_json(
            "06-EVIDENCE/Gate-Catalog-v4.3.json",
            lambda document: document["gates"][0].__setitem__("blocking", False),
        )
        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("nonblocking-gate-drift", codes)

    def test_import_rejects_reference_image_bytes(self) -> None:
        fixture = AuthorityFixture()
        self.addCleanup(fixture.close)
        catalog = json.loads(
            fixture.imported_path(
                "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-v1.3.json"
            ).read_text(encoding="utf-8")
        )
        reference = fixture.imported_path(catalog["candidates"][0]["referenceAsset"])
        reference.parent.mkdir(parents=True, exist_ok=True)
        reference.write_bytes(b"reference bytes are excluded")

        result = fixture.run()
        codes = {finding["code"] for finding in result["findings"]}

        self.assertEqual(result["result"], "FAIL")
        self.assertIn("candidate-reference-separation", codes)
        self.assertIn("import-inventory-drift", codes)


if __name__ == "__main__":
    unittest.main()
