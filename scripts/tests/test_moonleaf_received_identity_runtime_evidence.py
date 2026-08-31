#!/usr/bin/env python3
"""Focused fail-closed tests for Moonleaf received-identity runtime promotion."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shlex
import tempfile
import unittest

from PIL import Image

from scripts import moonleaf_received_identity_runtime_evidence as EVIDENCE


SOURCE_SHA = "a" * 40


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def binding(root: Path, path: Path, *, location: bool = False) -> dict[str, object]:
    value: dict[str, object] = {
        "path": path.relative_to(root).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }
    if location:
        value["location"] = "repository"
    return value


class RuntimeEvidenceFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.extraction_path = root / EVIDENCE.EXTRACTION_PATH
        self.catalog_path = root / EVIDENCE.CATALOG_PATH
        self.manifest_path = root / EVIDENCE.MANIFEST_PATH
        self.command_paths: list[Path] = []
        self.sidecar_paths: list[Path] = []
        self._create()

    def _png(self, path: Path, size: tuple[int, int], color: tuple[int, int, int, int]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        Image.new("RGBA", size, color).save(path, format="PNG")

    def _create(self) -> None:
        extraction_outputs: list[dict[str, object]] = []
        manifest_files: list[dict[str, object]] = []
        resource_sizes = ((17, 17), (19, 19), (21, 21), (23, 23), (25, 25))
        for index, resource_id in enumerate(sorted(EVIDENCE.REQUIRED_RESOURCE_IDS)):
            filename = resource_id.rsplit(".", 1)[-1] + f"-{index}.png"
            path = self.root / (
                "Packages/RuneScribeArchitecture/Sources/"
                "RuneScribeThemeMoonleafModule/Resources/Production/received/"
                + filename
            )
            self._png(path, resource_sizes[index], (20 + index, 40, 60, 255))
            relative = path.relative_to(self.root).as_posix()
            extraction_outputs.append({
                "resourceID": resource_id,
                "output": {
                    "path": relative,
                    "sha256": sha256(path),
                    "bytes": path.stat().st_size,
                    "dimensions": list(resource_sizes[index]),
                },
            })
            manifest_files.append({
                "path": path.relative_to(self.manifest_path.parent.parent).as_posix(),
                "resourceID": resource_id,
                "role": "received.fixture",
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            })
        write_json(self.extraction_path, {
            "schemaVersion": "1.0",
            "qualityReview": {"targetDeviceRuntime": "PENDING_PROVIDER_BINDING"},
            "outputs": extraction_outputs,
        })
        write_json(self.manifest_path, {
            "schemaVersion": "1.0",
            "codexID": EVIDENCE.CODEX_ID,
            "files": manifest_files,
        })

        candidates: list[dict[str, object]] = []
        for index, spec in enumerate(EVIDENCE.STATE_SPECS):
            output = self.root / EVIDENCE.EVIDENCE_ROOT / "canonical/moonleaf" / f"state-{index}.png"
            self._png(output, (941, 1672), (10 + index, 20, 30, 255))
            sidecar = output.with_suffix(".sidecar.json")
            candidate_id = str(spec["candidateID"])
            recipe = f"fixture-recipe-{index}"
            seeds = [f"fixture-seed-{index}"]
            wrapper = candidate_id + ".wrapper"
            runtime_state = json.dumps({
                "candidateID": candidate_id,
                "codexID": EVIDENCE.CODEX_ID,
                "themeID": EVIDENCE.THEME_ID,
                "recipe": recipe,
                "primarySurface": spec["primarySurface"],
                "seedIDs": seeds,
                "seedSurfaces": [spec["primarySurface"]],
                "visualPlanRevision": str(index + 1),
            }, separators=(",", ":"), sort_keys=True)
            write_json(sidecar, {
                "schemaVersion": "1.0",
                "candidateID": candidate_id,
                "wrapperID": wrapper,
                "sourceSHA": SOURCE_SHA,
                "seedIDs": seeds,
                "recipe": recipe,
                "renderMode": "full-production-screen",
                "width": 941,
                "height": 1672,
                "resourceIDs": sorted(spec["resourceIDs"]),
                "visualPlanRevision": index + 1,
                "runtimeState": runtime_state,
                "byteCount": output.stat().st_size,
                "sha256": sha256(output),
                "deterministicSHA256": sha256(output),
                "outputPath": output.relative_to(self.root).as_posix(),
            })
            self.sidecar_paths.append(sidecar)
            candidates.append({
                "id": candidate_id,
                "destinationsUsingResult": [EVIDENCE.DESTINATION],
                "outputPath": output.relative_to(self.root).as_posix(),
                "requiredOutputDimensions": [941, 1672],
                "requiredCanonicalWrapperID": wrapper,
                "seedIDs": seeds,
                "recipeClass": recipe,
                "renderMode": "full-production-screen",
            })
        write_json(self.catalog_path, {"schemaVersion": "1.3", "candidates": candidates})

        for index, (spec, sidecar) in enumerate(zip(EVIDENCE.STATE_SPECS, self.sidecar_paths)):
            output = sidecar.with_suffix("").with_suffix(".png")
            log = self.root / EVIDENCE.EVIDENCE_ROOT / "commands/logs" / f"state-{index}.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text("Test Suite 'All tests' passed\n", encoding="utf-8")
            record_path = self.root / EVIDENCE.EVIDENCE_ROOT / "commands/records" / f"state-{index}.json"
            argv = [
                "xcodebuild", "test", "-disableAutomaticPackageResolution",
                "-project", "RuneScrib.xcodeproj", "-scheme", EVIDENCE.SCHEME,
                "-configuration", "Release", "-destination",
                f"platform=iOS Simulator,id=fixture-device-{index}",
                "-parallel-testing-enabled", "NO", EVIDENCE.ONLY_TESTING,
                "ENABLE_TESTABILITY=YES",
                f"RUNESCRIBE_THEME_FIDELITY_SOURCE_SHA={SOURCE_SHA}",
                f"RUNESCRIBE_THEME_FIDELITY_CANONICAL_ROOT={self.root}",
                f"RUNESCRIBE_THEME_FIDELITY_CANONICAL_CANDIDATE={spec['candidateID']}",
            ]
            write_json(record_path, {
                "schemaVersion": "1.3",
                "evidenceType": "command-execution",
                "commandID": f"moonleaf-received-state-{index}",
                "category": "runtime-evidence",
                "sourceSHA": SOURCE_SHA,
                "sourceState": {
                    "requestedSourceSHA": SOURCE_SHA,
                    "headSHA": SOURCE_SHA,
                    "headMatchesSource": True,
                    "worktreeChangeCount": 3,
                    "worktreeChangesOutsideEvidenceRoot": [],
                    "worktreeCleanOutsideEvidenceRoot": True,
                    "acceptanceEligible": True,
                },
                "cwd": ".",
                "argv": argv,
                "command": shlex.join(argv),
                "destination": EVIDENCE.DESTINATION,
                "startTimestamp": "2026-08-31T12:00:00Z",
                "endTimestamp": "2026-08-31T12:01:00Z",
                "exitCode": 0,
                "expectedExitCode": 0,
                "log": {
                    "path": log.relative_to(self.root / EVIDENCE.EVIDENCE_ROOT).as_posix(),
                    "bytes": log.stat().st_size,
                    "sha256": sha256(log),
                },
                "outputs": sorted(
                    [binding(self.root, output, location=True), binding(self.root, sidecar, location=True)],
                    key=lambda value: str(value["path"]),
                ),
                "result": "PASS",
                "failures": [],
                "acceptanceEvidence": True,
            })
            self.command_paths.append(record_path)

    def extraction(self) -> dict[str, object]:
        return json.loads(self.extraction_path.read_text(encoding="utf-8"))

    def promote(self) -> dict[str, object]:
        return EVIDENCE.promote(
            self.root, SOURCE_SHA, self.command_paths[0], self.command_paths[1]
        )


class MoonleafReceivedIdentityRuntimeEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.fixture = RuntimeEvidenceFixture(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_promotion_is_atomic_idempotent_and_keeps_deterministic_pending(self) -> None:
        before = self.fixture.extraction()
        proof = self.fixture.promote()
        self.assertEqual(self.fixture.promote(), proof)
        self.assertEqual(self.fixture.extraction(), before)
        self.assertEqual(
            before["qualityReview"]["targetDeviceRuntime"],
            "PENDING_PROVIDER_BINDING",
        )
        self.assertTrue(EVIDENCE.validate_runtime_state(self.root, before, require_proof=True))
        qualified = EVIDENCE.qualification_document(self.root, before)
        self.assertEqual(qualified["qualityReview"]["targetDeviceRuntime"], "PASS")
        self.assertEqual(before["qualityReview"]["targetDeviceRuntime"], "PENDING_PROVIDER_BINDING")

    def test_missing_or_cross_state_identity_is_rejected(self) -> None:
        sidecar = json.loads(self.fixture.sidecar_paths[0].read_text(encoding="utf-8"))
        sidecar["resourceIDs"].append("resource.received.moonleaf.share.codex-badge")
        sidecar["resourceIDs"].sort()
        write_json(self.fixture.sidecar_paths[0], sidecar)
        with self.assertRaisesRegex(EVIDENCE.RuntimeEvidenceError, "partition differs"):
            self.fixture.promote()

    def test_non_source_bound_command_is_rejected(self) -> None:
        record = json.loads(self.fixture.command_paths[0].read_text(encoding="utf-8"))
        record["sourceState"]["acceptanceEligible"] = False
        write_json(self.fixture.command_paths[0], record)
        with self.assertRaisesRegex(EVIDENCE.RuntimeEvidenceError, "not source-bound"):
            self.fixture.promote()

    def test_hand_edited_pass_without_companion_is_rejected(self) -> None:
        extraction = self.fixture.extraction()
        extraction["qualityReview"]["targetDeviceRuntime"] = "PASS"
        with self.assertRaisesRegex(EVIDENCE.RuntimeEvidenceError, "must remain"):
            EVIDENCE.validate_runtime_state(self.root, extraction)

    def test_proof_or_shipping_drift_is_rejected(self) -> None:
        self.fixture.promote()
        proof_path = self.root / EVIDENCE.PROOF_PATH
        proof = json.loads(proof_path.read_text(encoding="utf-8"))
        proof["resources"][0]["sha256"] = "0" * 64
        write_json(proof_path, proof)
        with self.assertRaisesRegex(EVIDENCE.RuntimeEvidenceError, "content differs"):
            EVIDENCE.validate_runtime_state(
                self.root, self.fixture.extraction(), require_proof=True
            )


if __name__ == "__main__":
    unittest.main()
