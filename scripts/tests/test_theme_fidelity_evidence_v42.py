#!/usr/bin/env python3
"""Focused tests for Theme-fidelity v4.2 evidence assembly."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from theme_fidelity_evidence_v42 import (  # noqa: E402
    CaptureEvidence,
    Context,
    EvidenceError,
    StagingWriter,
    build_gate_records,
    build_responsive_aggregate,
    generated_logical_names,
    load_gate_catalog,
    sha256_file,
    validate_qualification_results,
    write_capture_indexes,
    write_platform_records,
)
from documentation_source_manifest import validate_current_manifest  # noqa: E402


GATE_CATALOG = (
    ROOT
    / "docs/verification/theme-fidelity-v4/authority/v4.2/04-VERIFICATION-PATCH"
    / "Gate-Catalog-v4.2.json"
)
COMPARISON_AUTHORITY = (
    ROOT
    / "docs/verification/theme-fidelity-v4/authority/v4.2/02-COMPARISON-AUTHORITY"
    / "Comparison-Authority-v1.2.json"
)
SOURCE_SHA = "a" * 40


class ThemeFidelityEvidenceV42Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.gates = load_gate_catalog(GATE_CATALOG)
        self.generated = generated_logical_names()

    def external_requirements(self) -> dict[str, set[str]]:
        requirements: dict[str, set[str]] = {}
        for gate in self.gates:
            for logical_name in gate["requiredEvidence"]:
                if logical_name in self.generated:
                    continue
                requirements.setdefault(logical_name, set()).add(gate["id"])
        return requirements

    def write_qualification(
        self,
        root: Path,
        *,
        omit: str | None = None,
        failed: str | None = None,
        corrupt_hash: str | None = None,
    ) -> Path:
        executions = []
        for ordinal, (logical_name, gate_ids) in enumerate(
            sorted(self.external_requirements().items())
        ):
            if logical_name == omit:
                continue
            kind = "log" if logical_name.endswith(".log") else "json"
            artifact = root / f"artifact-{ordinal}{'.log' if kind == 'log' else '.json'}"
            if kind == "log":
                artifact.write_text("qualification command completed\n", encoding="utf-8")
            else:
                artifact.write_text(
                    json.dumps({"schemaVersion": "1.0", "result": "PASS", "failures": []})
                    + "\n",
                    encoding="utf-8",
                )
            digest = sha256_file(artifact)
            if logical_name == corrupt_hash:
                digest = "0" * 64
            executions.append(
                {
                    "id": f"run-{ordinal}",
                    "gateIDs": sorted(gate_ids),
                    "command": ["fixture", logical_name],
                    "startTimestamp": "2026-08-25T12:00:00Z",
                    "endTimestamp": "2026-08-25T12:00:01Z",
                    "destination": "fixture-host",
                    "toolchain": {"fixture": "1"},
                    "exitCode": 1 if logical_name == failed else 0,
                    "result": "FAIL" if logical_name == failed else "PASS",
                    "failures": ["fixture failure"] if logical_name == failed else [],
                    "artifacts": [
                        {
                            "logicalName": logical_name,
                            "path": str(artifact),
                            "sha256": digest,
                            "kind": kind,
                        }
                    ],
                }
            )
        path = root / "qualification-results.json"
        path.write_text(
            json.dumps(
                {
                    "schemaVersion": "1.0",
                    "sourceSHA": SOURCE_SHA,
                    "executions": executions,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        return path

    def platform_capture_fixture(self, output_root: Path) -> CaptureEvidence:
        authority = json.loads(COMPARISON_AUTHORITY.read_text(encoding="utf-8"))
        entries = [
            {"entryID": entry["id"], "destination": entry["destination"]}
            for entry in authority["entries"]
        ]
        commands = []
        for role in (
            "iphone",
            "iphone-xcui",
            "ipad",
            "ipad-xcui",
            "macos",
            "macos-xcui",
        ):
            log = output_root / "logs" / f"{role}.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(f"{role} passed\n", encoding="utf-8")
            commands.append(
                {
                    "command": ["fixture", role],
                    "startTimestamp": "2026-08-25T12:00:00Z",
                    "endTimestamp": "2026-08-25T12:00:01Z",
                    "exitCode": 0,
                    "result": "PASS",
                    "failures": [],
                    "log": str(log),
                    "logSHA256": sha256_file(log),
                }
            )
        marker = output_root / "fixture.json"
        return CaptureEvidence(
            run_path=marker,
            run={"commands": commands},
            index_path=marker,
            index={"entries": entries},
            source_before_path=marker,
            source_after_path=marker,
            source_manifest={},
            records_by_entry={},
        )

    def focal_capture_fixture(
        self, output_root: Path
    ) -> tuple[
        CaptureEvidence,
        dict[str, list[dict[str, object]]],
        dict[str, dict[str, object]],
    ]:
        authority = json.loads(COMPARISON_AUTHORITY.read_text(encoding="utf-8"))
        artifact = output_root / "artifact.bin"
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_bytes(b"fixture")
        entries: list[dict[str, object]] = []
        grouped: dict[str, list[dict[str, object]]] = {
            theme: [] for theme in ("Norse", "Moonleaf", "Sunspire", "Wildwood", "Gloamthorn")
        }
        semantics: dict[str, dict[str, object]] = {}
        for authority_entry in authority["entries"]:
            mappings = []
            for authority_mapping in authority_entry["referenceMappings"]:
                disposition = authority_mapping["scoreDisposition"]
                mapping = {
                    "mappingID": authority_mapping["mappingID"],
                    "scoreDisposition": disposition,
                    "report": str(artifact),
                }
                if disposition != "negative-invariant":
                    mapping["candidate"] = str(artifact)
                    mapping["candidateID"] = "fixture-candidate"
                if disposition == "image-metric":
                    mapping["heatmap"] = str(artifact)
                mappings.append(mapping)
                semantics[authority_mapping["mappingID"]] = {
                    "scoreDisposition": disposition
                }
            entry = {
                "entryID": authority_entry["id"],
                "theme": authority_entry["theme"],
                "surface": authority_entry["surface"],
                "destination": authority_entry["destination"],
                "capture": {"path": str(artifact)},
                "mappingResults": mappings,
            }
            entries.append(entry)
            grouped[authority_entry["theme"]].append(entry)
        marker = output_root / "fixture.json"
        capture = CaptureEvidence(
            run_path=marker,
            run={},
            index_path=marker,
            index={"entries": entries},
            source_before_path=marker,
            source_after_path=marker,
            source_manifest={},
            records_by_entry={},
        )
        return capture, grouped, semantics

    def platform_context(self, output_root: Path) -> Context:
        return Context(
            root=ROOT,
            output_root=output_root,
            source_sha=SOURCE_SHA,
            authority_sha="c" * 64,
            asset_manifest_sha="d" * 64,
            command=["fixture"],
            start_timestamp="2026-08-25T12:00:00Z",
            end_timestamp="2026-08-25T12:00:01Z",
            toolchain={"fixture": "1"},
        )

    def test_qualification_results_bind_all_non_visual_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = self.write_qualification(root)
            document, artifacts, executions = validate_qualification_results(
                path,
                root,
                SOURCE_SHA,
                self.gates,
                self.generated,
            )
            self.assertEqual(document["sourceSHA"], SOURCE_SHA)
            self.assertEqual(set(artifacts), set(self.external_requirements()))
            self.assertEqual(len(executions), len(self.external_requirements()))

    def test_missing_required_artifact_fails_closed(self) -> None:
        missing = sorted(self.external_requirements())[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = self.write_qualification(root, omit=missing)
            with self.assertRaisesRegex(EvidenceError, "lack required evidence"):
                validate_qualification_results(
                    path, root, SOURCE_SHA, self.gates, self.generated
                )

    def test_failed_execution_is_not_accepted_from_artifact_presence(self) -> None:
        failed = sorted(self.external_requirements())[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = self.write_qualification(root, failed=failed)
            with self.assertRaisesRegex(EvidenceError, "exit code is invalid"):
                validate_qualification_results(
                    path, root, SOURCE_SHA, self.gates, self.generated
                )

    def test_artifact_hash_mismatch_fails_closed(self) -> None:
        corrupt = sorted(self.external_requirements())[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = self.write_qualification(root, corrupt_hash=corrupt)
            with self.assertRaisesRegex(EvidenceError, "SHA-256 does not match"):
                validate_qualification_results(
                    path, root, SOURCE_SHA, self.gates, self.generated
                )

    def test_gate_summary_has_exact_catalog_order_and_all_40_results(self) -> None:
        bindings = {}
        for gate in self.gates:
            for logical_name in gate["requiredEvidence"]:
                bindings[logical_name] = {
                    "logicalName": logical_name,
                    "path": f"fixture/{logical_name.rstrip('/')}",
                    "sha256": "b" * 64,
                    "kind": "fixture",
                    "sourceSHA": SOURCE_SHA,
                    "result": "PASS",
                }
        records = build_gate_records(self.gates, bindings, {})
        self.assertEqual(len(records), 40)
        self.assertEqual(
            [record["id"] for record in records],
            [gate["id"] for gate in self.gates],
        )
        self.assertTrue(all(record["result"] == "PASS" for record in records))

    def test_platform_records_use_authority_destination_counts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output_root = root / "output"
            capture = self.platform_capture_fixture(output_root)
            writer = StagingWriter(self.platform_context(output_root), root / "stage")

            write_platform_records(writer, writer.context, capture)

            expected = {
                "iphone": (100, {"iphone-portrait": 100}),
                "ipad": (100, {"ipad-portrait": 100}),
                "macos": (
                    200,
                    {"macos-resized": 100, "macos-standard": 100},
                ),
            }
            for platform, (entry_count, destination_counts) in expected.items():
                record = json.loads(
                    (root / "stage/test-runs" / f"{platform}.json").read_text(
                        encoding="utf-8"
                    )
                )
                self.assertEqual(record["entryCount"], entry_count)
                self.assertEqual(record["destinationEntryCounts"], destination_counts)

    def test_platform_records_reject_incomplete_destination_counts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output_root = root / "output"
            capture = self.platform_capture_fixture(output_root)
            capture.index["entries"] = capture.index["entries"][1:]
            writer = StagingWriter(self.platform_context(output_root), root / "stage")

            with self.assertRaisesRegex(
                EvidenceError, "capture destination counts differ from comparison authority"
            ):
                write_platform_records(writer, writer.context, capture)

    def test_theme_focal_records_use_authority_image_metric_counts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output_root = root / "output"
            capture, grouped, semantics = self.focal_capture_fixture(output_root)
            writer = StagingWriter(self.platform_context(output_root), root / "stage")

            write_capture_indexes(writer, writer.context, capture, grouped, semantics)

            expected = {
                "gloamthorn": 54,
                "moonleaf": 74,
                "norse": 148,
                "sunspire": 62,
                "wildwood": 62,
            }
            for theme, image_count in expected.items():
                comparison = json.loads(
                    (root / "stage/comparisons" / f"{theme}-focal-comparison.json").read_text(
                        encoding="utf-8"
                    )
                )
                heatmaps = json.loads(
                    (root / "stage/heatmaps" / theme / "index.json").read_text(
                        encoding="utf-8"
                    )
                )
                self.assertEqual(comparison["imageMetricCount"], image_count)
                self.assertEqual(heatmaps["heatmapCount"], image_count)

    def test_theme_focal_records_reject_wrong_distribution_with_global_counts_intact(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output_root = root / "output"
            capture, grouped, semantics = self.focal_capture_fixture(output_root)
            by_theme = {
                theme: [entry for entry in capture.index["entries"] if entry["theme"] == theme]
                for theme in ("Gloamthorn", "Moonleaf")
            }
            swap: tuple[dict[str, object], dict[str, object]] | None = None
            for gloamthorn in by_theme["Gloamthorn"]:
                gloamthorn_count = sum(
                    mapping["scoreDisposition"] == "image-metric"
                    for mapping in gloamthorn["mappingResults"]
                )
                for moonleaf in by_theme["Moonleaf"]:
                    moonleaf_count = sum(
                        mapping["scoreDisposition"] == "image-metric"
                        for mapping in moonleaf["mappingResults"]
                    )
                    if gloamthorn_count != moonleaf_count:
                        swap = gloamthorn, moonleaf
                        break
                if swap is not None:
                    break
            self.assertIsNotNone(swap)
            gloamthorn, moonleaf = swap  # type: ignore[misc]
            gloamthorn["theme"], moonleaf["theme"] = moonleaf["theme"], gloamthorn["theme"]
            regrouped = {
                theme: [entry for entry in capture.index["entries"] if entry["theme"] == theme]
                for theme in ("Norse", "Moonleaf", "Sunspire", "Wildwood", "Gloamthorn")
            }
            writer = StagingWriter(self.platform_context(output_root), root / "stage")

            with self.assertRaisesRegex(
                EvidenceError, "focal evidence lacks exact passing coverage"
            ):
                write_capture_indexes(writer, writer.context, capture, regrouped, semantics)

    def test_responsive_aggregate_rechecks_every_assertion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_root = Path(directory)
            layout = output_root / "final/authority-v1.2/responsive-layout/layout.json"
            layout.parent.mkdir(parents=True)
            layout.write_text(
                json.dumps(
                    {
                        "result": "PASS",
                        "failures": [],
                        "assertions": [
                            {"assertionID": "assert.element.visible", "result": "PASS"}
                        ],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            digest = sha256_file(layout)
            entries = [
                {
                    "entryID": f"entry-{index:03d}",
                    "theme": "Norse",
                    "surface": "workspace-empty",
                    "destination": "iphone-portrait",
                    "responsiveLayout": {"path": str(layout), "sha256": digest},
                }
                for index in range(400)
            ]
            capture = CaptureEvidence(
                run_path=layout,
                run={},
                index_path=layout,
                index={"entries": entries},
                source_before_path=layout,
                source_after_path=layout,
                source_manifest={},
                records_by_entry={},
            )
            context = Context(
                root=output_root,
                output_root=output_root,
                source_sha=SOURCE_SHA,
                authority_sha="c" * 64,
                asset_manifest_sha="d" * 64,
                command=["fixture"],
                start_timestamp="2026-08-25T12:00:00Z",
                end_timestamp="2026-08-25T12:00:01Z",
                toolchain={"fixture": "1"},
            )
            aggregate = build_responsive_aggregate(context, capture)
            self.assertEqual(aggregate["entryCount"], 400)
            self.assertEqual(aggregate["assertionCount"], 400)
            self.assertEqual(aggregate["result"], "PASS")

            layout.write_text(
                json.dumps(
                    {
                        "result": "PASS",
                        "failures": [],
                        "assertions": [
                            {"assertionID": "assert.element.visible", "result": "FAIL"}
                        ],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(EvidenceError, "failed assertion"):
                build_responsive_aggregate(context, capture)

    def test_documentation_checker_accepts_explicit_current_manifest(self) -> None:
        root = Path("/tmp/repository-fixture")
        exclusion = root / "docs/verification/theme-fidelity-v4/final"
        document = {
            "schemaVersion": "1.0",
            "sourceSHA": SOURCE_SHA,
            "fileCount": 1,
            "aggregateSHA256": "b" * 64,
            "gitStatusSHA256": "c" * 64,
            "isClean": True,
            "files": [{"path": "source", "sha256": "d" * 64}],
        }
        errors = validate_current_manifest(
            document,
            root=root,
            exclusions=[exclusion],
            head=SOURCE_SHA,
            recompute=lambda _root, _exclusions: document,
        )
        self.assertEqual(errors, [])
        dirty = dict(document, isClean=False)
        errors = validate_current_manifest(
            dirty,
            root=root,
            exclusions=[exclusion],
            head=SOURCE_SHA,
            recompute=lambda _root, _exclusions: dirty,
        )
        self.assertIn(
            "current source manifest does not report a clean source-only tree",
            errors,
        )


if __name__ == "__main__":
    unittest.main()
