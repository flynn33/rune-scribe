#!/usr/bin/env python3
"""Tests for v4.3 canonical and responsive evidence materialization."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from PIL import Image


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_ROOT = REPOSITORY_ROOT / "scripts"
if str(SCRIPTS_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_ROOT))

SPEC = importlib.util.spec_from_file_location(
    "theme_fidelity_evidence_v43",
    SCRIPTS_ROOT / "materialize-theme-fidelity-v43-evidence.py",
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load v4.3 evidence materializer")
MATERIALIZER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MATERIALIZER
SPEC.loader.exec_module(MATERIALIZER)

from theme_fidelity_xcui_evidence import (  # noqa: E402
    CONTRACT_PATHS,
    CONTRACT_V43,
    LOCKED_QUERY_PREDICATE,
    UI_TEST_TARGET_KIND,
    UI_TEST_TARGETS_BY_ROLE,
    XCUI_OPERATION,
    XCUI_TEST_IDENTIFIER,
    candidate_attachment_name,
    capture_candidate_ids_for_entry,
    expected_structural_witnesses,
    query_attachment_name,
    sidecar_name,
    xcui_probe_ids_for_entry,
)


SOURCE_SHA = "a" * 40
RECT = {"x": 10.0, "y": 10.0, "width": 40.0, "height": 40.0}
WINDOW = {"x": 0.0, "y": 0.0, "width": 100.0, "height": 100.0}


def write_json(path: Path, document) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CanonicalFixture:
    def __init__(self, test: unittest.TestCase, bundle) -> None:
        self.test = test
        self.bundle = bundle
        self.temporary = tempfile.TemporaryDirectory(prefix="runescribe-v43-canonical-")
        test.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.raw = self.root / "raw"
        self.comparisons = self.root / "comparisons"
        self.raw.mkdir()
        self.comparisons.mkdir()
        seal_root = (
            REPOSITORY_ROOT
            / "Packages/RuneScribeArchitecture/Sources/"
            "RuneScribeNorseThemeModule/Resources/Production/Seals"
        )
        seals_by_hash = {sha256(path): path for path in seal_root.glob("*.png")}
        for candidate in bundle.canonical["candidates"]:
            output = self.raw / candidate["outputPath"]
            output.parent.mkdir(parents=True, exist_ok=True)
            if candidate["renderMode"] == "resolved-resource-export":
                source = seals_by_hash.get(candidate["referenceSHA256"])
                test.assertIsNotNone(source, candidate["id"])
                shutil.copyfile(source, output)
            else:
                Image.new(
                    "RGB",
                    tuple(candidate["requiredOutputDimensions"]),
                    (8, 16, 24),
                ).save(output)
            digest = sha256(output)
            sidecar_path = output.with_suffix(".sidecar.json")
            if candidate["renderMode"] == "resolved-resource-export":
                sidecar = {
                    "schemaVersion": "1.0",
                    "candidateID": candidate["id"],
                    "wrapperID": candidate["requiredCanonicalWrapperID"],
                    "sourceSHA": SOURCE_SHA,
                    "seedID": candidate["seedIDs"][0],
                    "renderMode": candidate["renderMode"],
                    "resourceID": "resource.test.exact",
                    "visualPlanRevisions": [1, 1],
                    "width": candidate["requiredOutputDimensions"][0],
                    "height": candidate["requiredOutputDimensions"][1],
                    "byteCount": output.stat().st_size,
                    "sha256": digest,
                    "determinism": True,
                    "outputPath": candidate["outputPath"],
                }
            else:
                sidecar = {
                    "schemaVersion": "1.0",
                    "candidateID": candidate["id"],
                    "wrapperID": candidate["requiredCanonicalWrapperID"],
                    "sourceSHA": SOURCE_SHA,
                    "seedIDs": candidate["seedIDs"],
                    "recipe": candidate["recipeClass"],
                    "renderMode": candidate["renderMode"],
                    "width": candidate["requiredOutputDimensions"][0],
                    "height": candidate["requiredOutputDimensions"][1],
                    "resourceIDs": ["resource.test.production"],
                    "visualPlanRevision": 1,
                    "runtimeState": "available",
                    "byteCount": output.stat().st_size,
                    "sha256": digest,
                    "deterministicSHA256": digest,
                    "outputPath": candidate["outputPath"],
                }
            write_json(sidecar_path, sidecar)

            report_path = self.comparisons / f"{MATERIALIZER.safe_stem(candidate['id'])}.json"
            base = {
                "schemaVersion": "1.3",
                "candidateID": candidate["id"],
                "referenceSHA256": candidate["referenceSHA256"],
                "candidateSHA256": digest,
                "expectedDimensions": candidate["requiredOutputDimensions"],
                "referenceDimensions": candidate["referenceDimensions"],
                "candidateDimensions": candidate["requiredOutputDimensions"],
                "thresholdProfile": candidate["thresholdProfile"],
                "authoritySHA256": sha256(bundle.authority_path),
                "canonicalCatalogSHA256": sha256(bundle.canonical_path),
                "result": "PASS",
            }
            if candidate["evaluationKind"] == "resource-byte-identity":
                test.assertEqual(digest, candidate["referenceSHA256"])
                report = {
                    **base,
                    "checks": {"byteIdentity": True, "exactDimensions": True},
                    "metrics": {},
                    "failure": None,
                }
            else:
                thresholds = bundle.authority["thresholdProfiles"][candidate["thresholdProfile"]]
                report = {
                    **base,
                    "checks": {
                        "exactDimensions": True,
                        "luminanceSSIM": True,
                        "edgeSSIM": True,
                        "medianDeltaE": True,
                        "p95DeltaE": True,
                        "severeDeltaEPercent": True,
                    },
                    "metrics": {
                        "luminanceSSIM": thresholds["luminanceSSIMMinimum"],
                        "edgeSSIM": thresholds["edgeSSIMMinimum"],
                        "medianDeltaE": thresholds["medianDeltaEMaximum"],
                        "p95DeltaE": thresholds["p95DeltaEMaximum"],
                        "severeDeltaEThreshold": thresholds["severeDeltaEThreshold"],
                        "severeDeltaEPercent": thresholds["severeDeltaEPercentMaximum"],
                    },
                    "thresholds": thresholds,
                }
                for suffix in (".ssim-heatmap.png", ".color-heatmap.png"):
                    Image.new(
                        "L", tuple(candidate["requiredOutputDimensions"]), 0
                    ).save(report_path.with_suffix(suffix))
            write_json(report_path, report)


class ResponsiveFixture:
    def __init__(self, test: unittest.TestCase, bundle) -> None:
        self.test = test
        self.bundle = bundle
        self.temporary = tempfile.TemporaryDirectory(prefix="runescribe-v43-responsive-")
        test.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.captures = self.root / "captures"
        self.captures.mkdir()
        self.template_png = self.root / "template.png"
        Image.new("RGB", (100, 100), (16, 32, 48)).save(self.template_png)
        self.png_digest = sha256(self.template_png)
        self._build_files()
        self.extraction = self._write_extraction()
        self.run_report = self._write_run_report()

    def link_png(self, name: str) -> Path:
        destination = self.captures / name
        if not destination.exists():
            os.link(self.template_png, destination)
        return destination

    @staticmethod
    def role(destination: str) -> str:
        return {
            "iphone-portrait": "iphone-xcui",
            "ipad-portrait": "ipad-xcui",
            "macos-standard": "macos-xcui",
            "macos-resized": "macos-xcui",
        }[destination]

    def passing_observation(self, assertion_id: str):
        specification = self.bundle.authority["structuralAssertionCatalog"][assertion_id]
        operator = specification["operator"]
        if operator in {
            "exists", "visible", "viewport-contained", "state-text-shape-consistency",
            "composition-plan-equality", "required-controls-visible",
        }:
            observed = True
        elif operator in {"horizontal-overflow", "artifact-safe-region-overlap"}:
            observed = False
        elif operator == "minimum-hit-target":
            observed = specification["expectedMinimumPoints"]
        elif operator in {"placeholder-resource-count", "system-symbol-artifact-count"}:
            observed = specification["expected"]
        else:
            observed = [
                f"component.{index}" for index in range(specification["expectedCount"])
            ]
        return {"source": "hosted-test-evidence", "observed": observed, "details": {}}

    def probe_value(self, probe_id: str, entry) -> object:
        if probe_id.startswith("probe.theme.active."):
            return entry["themeID"]
        if probe_id.startswith("probe.motion.mode."):
            return "reduce-motion"
        if probe_id.startswith("probe.motion.active-animation-count."):
            return 0
        if probe_id.startswith("probe.motion.background-resource."):
            return True
        if probe_id.startswith("probe.motion.visual-plan-revision."):
            return 1
        if probe_id.startswith("probe.motion.frame-stability."):
            return 1.0
        if probe_id in {
            "probe.norse.base-owned", "probe.norse.base-selectable",
            "probe.norse.fallback-available", "probe.optional-codex.locked-renderer-covered",
        }:
            return True
        raise AssertionError(probe_id)

    def witness(self, specification, entry, seed):
        identifier = specification["expectedElementIdentifier"]
        value = None
        if identifier == "theme-fidelity.diagnostic.state":
            environment = seed["launchEnvironment"]
            value = json.dumps({
                "schemaVersion": "1.0",
                "themeID": entry["themeID"],
                "codexID": entry["codexID"],
                "surface": entry["surface"],
                "destination": entry["destination"],
                "appearance": environment.get("RUNESCRIBE_QUALIFICATION_APPEARANCE"),
                "messageProfile": environment.get("RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE"),
                "vaultState": environment.get("RUNESCRIBE_QUALIFICATION_VAULT_STATE"),
                "activeThemeID": entry["themeID"],
                "effectiveCodexID": entry["codexID"],
            }, sort_keys=True)
        elif identifier == "theme-fidelity.diagnostic.dynamic-type":
            value = "accessibility5"
        return {
            "witnessID": specification["witnessID"],
            "queryPredicate": specification["queryPredicate"],
            "matchCount": specification["expectedMatchCount"],
            "elementIdentifier": identifier,
            "coordinateOrigin": "top-left",
            "coordinateUnits": "points",
            "elementFrame": RECT if identifier is not None else None,
            "windowFrame": WINDOW,
            "label": "Evidence" if identifier is not None else None,
            "value": value,
            "isEnabled": True if identifier is not None else None,
            "isHittable": True if identifier is not None else None,
        }

    def _write_xcui_sidecar(self, entry, seed) -> None:
        candidate_ids = capture_candidate_ids_for_entry(
            entry,
            self.bundle.probes,
            self.bundle.responsive_candidates,
            CONTRACT_V43,
        )
        probe_ids = xcui_probe_ids_for_entry(entry, self.bundle.probes)
        if not candidate_ids and not probe_ids:
            return
        role = self.role(entry["destination"])
        candidates = []
        for candidate_id in candidate_ids:
            name = candidate_attachment_name(entry, candidate_id)
            path = self.link_png(name)
            candidates.append({
                "candidateID": candidate_id,
                "elementIdentifier": candidate_id,
                "attachmentName": name,
                "declaredOperation": XCUI_OPERATION,
                "actualOperation": XCUI_OPERATION,
                "sha256": sha256(path),
                "byteCount": path.stat().st_size,
                "pixelWidth": 100,
                "pixelHeight": 100,
                "queryPredicate": f"identifier == '{candidate_id}'",
                "matchCount": 1,
                "coordinateOrigin": "top-left",
                "coordinateUnits": "points",
                "elementFrame": RECT,
                "windowFrame": WINDOW,
                "label": "Candidate",
                "value": None,
                "isEnabled": True,
                "isHittable": True,
            })
        probes = []
        for probe_id in probe_ids:
            catalog = self.bundle.probes[probe_id]
            if probe_id == "probe.norse.vault.locked-element-count":
                candidate_id = None
                name = query_attachment_name(entry)
                match_count = 0
                element = None
                predicate = LOCKED_QUERY_PREDICATE
                observed = 0
            else:
                preview_ids = [
                    candidate_id
                    for candidate_id in candidate_ids
                    if candidate_id.startswith("theme.artifact-preview.")
                ]
                self.test.assertEqual(len(preview_ids), 1)
                candidate_id = preview_ids[0]
                name = candidate_attachment_name(entry, candidate_id)
                match_count = 1
                element = RECT
                predicate = f"identifier == '{candidate_id}'"
                observed = True
            path = self.link_png(name)
            probes.append({
                "probeID": probe_id,
                "source": catalog["source"],
                "operator": catalog["operator"],
                "expected": catalog["expected"],
                "observed": observed,
                "queryPredicate": predicate,
                "matchCount": match_count,
                "candidateID": candidate_id,
                "attachmentName": name,
                "attachmentSHA256": sha256(path),
                "pixelWidth": 100,
                "pixelHeight": 100,
                "coordinateOrigin": "top-left",
                "coordinateUnits": "points",
                "elementFrame": element,
                "containerFrame": WINDOW,
            })
        sidecar = {
            "schemaVersion": "1.0",
            "entryID": entry["id"],
            "theme": entry["theme"],
            "surface": entry["surface"],
            "destination": entry["destination"],
            "deterministicSeed": seed,
            "primaryCaptureAttachmentName": (
                f"{entry['theme'].lower()}--{entry['surface']}--{entry['destination']}.png"
            ),
            "captureRecordAttachmentName": (
                f"{entry['theme'].lower()}--{entry['surface']}--{entry['destination']}.capture.json"
            ),
            "sourceTest": {
                "targetName": UI_TEST_TARGETS_BY_ROLE[role],
                "targetKind": UI_TEST_TARGET_KIND,
                "testIdentifier": XCUI_TEST_IDENTIFIER,
                "bundleRole": role,
            },
            "candidateElementCaptures": candidates,
            "structuralWitnesses": [
                self.witness(specification, entry, seed)
                for specification in expected_structural_witnesses(
                    entry, self.bundle.responsive_candidates
                )
            ],
            "xcuiProbeEvidence": probes,
        }
        write_json(self.captures / sidecar_name(entry), sidecar)

    def _build_files(self) -> None:
        for entry in self.bundle.authority["entries"]:
            stem = f"{entry['theme'].lower()}--{entry['surface']}--{entry['destination']}"
            capture = self.link_png(stem + ".png")
            auxiliary_b = None
            if entry["surface"] == "reduce-motion":
                auxiliary_b = self.link_png(stem + "--stability-b.png")
            renderer_outputs = []
            renderer_ids = {
                mapping["candidateRendererOutputID"]
                for mapping in entry["referenceMappings"]
                if "candidateRendererOutputID" in mapping
            }
            if entry["surface"] == "static-share":
                self.test.assertLessEqual(len(renderer_ids), 1)
                renderer = self.link_png(stem + "--renderer-output.png")
                renderer_outputs.append({
                    "outputID": (
                        next(iter(renderer_ids))
                        if renderer_ids
                        else f"renderer.static-share.{entry['codexID']}.test"
                    ),
                    "attachmentName": renderer.name,
                    "usesPrimaryCapture": False,
                    "sha256": sha256(renderer),
                    "byteCount": renderer.stat().st_size,
                    "pixelWidth": 100,
                    "pixelHeight": 100,
                })
            if entry["theme"] == "Norse" and entry["surface"] == "vault-locked":
                self.link_png(stem + "--optional-codex-locked.png")
            hosted_probe_ids = [
                probe_id for probe_id in entry["runtimeProbeIDs"]
                if not self.bundle.probes[probe_id]["source"].startswith("xcui-")
            ]
            record = {
                "schemaVersion": "1.0",
                "stateSeed": "fixed",
                "stateSeedSHA256": "b" * 64,
                "contentSeed": {},
                "stateID": entry["surface"],
                "themeName": entry["theme"],
                "themeID": entry["themeID"],
                "codexID": entry["codexID"],
                "relicID": f"relic.{entry['theme'].lower()}.test",
                "sealID": f"seal.{entry['theme'].lower()}.test",
                "frameID": f"frame.{entry['theme'].lower()}.test",
                "surface": entry["surface"],
                "destination": MATERIALIZER.DESTINATION_DISPLAY_NAMES[entry["destination"]],
                "pointWidth": 100.0,
                "pointHeight": 100.0,
                "scale": 1.0,
                "pixelWidth": 100,
                "pixelHeight": 100,
                "visualPlanRevision": 1,
                "pngSHA256": sha256(capture),
                "byteCount": capture.stat().st_size,
                "renderedResourceIDs": ["resource.test.production"],
                "renderedResourceBindings": [],
                "viewportAssertions": {
                    "requiredElementCount": 1,
                    "requiredElementIDs": ["theme.artifact-preview.test"],
                    "clippedElementIDs": [],
                },
                "elementFrames": {
                    "coordinateOrigin": "top-left",
                    "units": "pixels",
                    "frames": [
                        {"elementID": "theme-fidelity.viewport", **WINDOW},
                        {"elementID": "theme.artifact-preview.test", **RECT},
                    ],
                },
                "runtimeDiagnostics": {
                    "activeThemeID": entry["themeID"],
                    "activeCodexID": entry["codexID"],
                    "effectiveMotionMode": (
                        "reduce-motion" if entry["surface"] == "reduce-motion" else "standard"
                    ),
                    "activeThemeAnimationCount": 0,
                    "effectiveBackgroundResourceID": "resource.background.reduce-motion",
                    "declaredReduceMotionBackgroundResourceID": "resource.background.reduce-motion",
                    "visualPlanRevision": 1,
                    "preview": {
                        "elementID": "theme.artifact-preview.test",
                        "exists": True,
                        "visible": True,
                        "viewportContained": True,
                    },
                    "norseBase": {
                        "owned": True,
                        "selectable": True,
                        "fallbackAvailable": True,
                        "lockedElementCount": 0,
                        "optionalLockedRendererCovered": True,
                    },
                },
                "rendererOutputs": renderer_outputs,
                "runtimeProbeObservations": [
                    {
                        "probeID": probe_id,
                        "source": self.bundle.probes[probe_id]["source"],
                        "observed": self.probe_value(probe_id, entry),
                    }
                    for probe_id in hosted_probe_ids
                ],
                "structuralAssertionObservations": {
                    assertion_id: self.passing_observation(assertion_id)
                    for assertion_id in entry["entryStructuralAssertionIDs"]
                },
            }
            if auxiliary_b is not None:
                record["reduceMotionStability"] = {
                    "captureATimestamp": "2026-08-28T12:00:00Z",
                    "captureBTimestamp": "2026-08-28T12:00:02Z",
                    "separationSeconds": 2.0,
                    "captureASHA256": sha256(capture),
                    "captureBSHA256": sha256(auxiliary_b),
                    "captureBAttachmentName": auxiliary_b.name,
                    "luminanceSSIM": 1.0,
                }
            write_json(self.captures / (stem + ".capture.json"), record)
            self._write_xcui_sidecar(entry, self.bundle.seeds[entry["seedID"]])

    def _write_extraction(self) -> Path:
        attachments = []
        for path in sorted(self.captures.iterdir()):
            item = {
                "name": path.name,
                "sha256": sha256(path),
                "bytes": path.stat().st_size,
            }
            if (
                path.name.endswith(".xcui.json")
                or "--candidate-element--" in path.name
                or path.name.endswith("--xcui-query.png")
            ):
                destination = next(
                    value for value in MATERIALIZER.DESTINATION_DISPLAY_NAMES
                    if f"--{value}" in path.name
                )
                role = self.role(destination)
                item.update({
                    "testIdentifier": XCUI_TEST_IDENTIFIER,
                    "resultBundleRole": role,
                    "sourceTargetName": UI_TEST_TARGETS_BY_ROLE[role],
                    "sourceTargetKind": UI_TEST_TARGET_KIND,
                })
            attachments.append(item)
        expected_names, expected_counts = MATERIALIZER.expected_responsive_inventory(
            self.bundle
        )
        self.test.assertEqual({item["name"] for item in attachments}, expected_names)
        counts = {
            "pngCount": sum(
                path.name.endswith(".png") and "--" in path.stem
                and not any(token in path.name for token in (
                    "--stability-b", "--renderer-output", "--optional-codex-locked",
                    "--candidate-element--", "--xcui-query",
                ))
                for path in self.captures.iterdir()
            ),
            "auxiliaryPNGCount": sum(
                any(token in path.name for token in (
                    "--stability-b", "--renderer-output", "--optional-codex-locked",
                ))
                for path in self.captures.iterdir()
            ),
            "recordCount": sum(path.name.endswith(".capture.json") for path in self.captures.iterdir()),
            "candidatePNGCount": sum("--candidate-element--" in path.name for path in self.captures.iterdir()),
            "xcuiQueryPNGCount": sum(path.name.endswith("--xcui-query.png") for path in self.captures.iterdir()),
            "xcuiSidecarCount": sum(path.name.endswith(".xcui.json") for path in self.captures.iterdir()),
            "attachmentCount": len(attachments),
        }
        self.test.assertEqual(counts, expected_counts)
        def provenance(contract_version: str) -> dict:
            specification = CONTRACT_PATHS[contract_version]
            files = {}
            for key in ("authority", "probes", "seeds", "candidates"):
                relative = specification[key]
                files[key] = {
                    "path": relative.as_posix(),
                    "sha256": sha256(REPOSITORY_ROOT / relative),
                }
            return {
                "contractVersion": contract_version,
                "schemaVersion": specification["schemaVersion"],
                "files": files,
            }

        manifest = REPOSITORY_ROOT / MATERIALIZER.DEFAULT_IMPORT_MANIFEST
        path = self.root / "extraction.json"
        write_json(path, {
            "schemaVersion": "1.3",
            "result": "pass",
            "sourceSHA": SOURCE_SHA,
            "authorityContract": CONTRACT_V43,
            "sourceXCUIContract": CONTRACT_V43,
            "authorityValidation": {
                "schemaVersion": "1.3",
                "authorityVersion": "4.3",
                "result": "PASS",
                "manifestSHA256": sha256(manifest),
                "findings": [],
            },
            "authorityProvenance": provenance(CONTRACT_V43),
            "sourceXCUIAuthorityProvenance": provenance(CONTRACT_V43),
            "captureRoot": str(self.captures.resolve()),
            **counts,
            "attachments": attachments,
        })
        return path

    def _write_run_report(self) -> Path:
        aggregate = hashlib.sha256(b"").hexdigest()
        source_manifest = {
            "schemaVersion": "1.0",
            "sourceSHA": SOURCE_SHA,
            "fileCount": 0,
            "aggregateSHA256": aggregate,
            "gitStatusSHA256": aggregate,
            "isClean": True,
            "files": [],
        }
        before = self.root / "SourceManifest.before.json"
        after = self.root / "SourceManifest.after.json"
        write_json(before, source_manifest)
        write_json(after, source_manifest)
        path = self.root / "run-report.json"
        write_json(path, {
            "schemaVersion": "1.0",
            "phase": "final",
            "sourceSHA": SOURCE_SHA,
            "sourceBinding": {
                "aggregateSHA256": aggregate,
                "gitStatusSHA256": aggregate,
                "beforeManifest": str(before.resolve()),
                "beforeManifestSHA256": sha256(before),
                "afterManifest": str(after.resolve()),
                "afterManifestSHA256": sha256(after),
                "prePostEqual": True,
            },
            "result": "pass",
            "failures": [],
            "commands": [{"exitCode": 0, "result": "pass"}],
            "outputPaths": {
                "captures": str(self.captures.resolve()),
                "extraction": str(self.extraction.resolve()),
                "extractionSHA256": sha256(self.extraction),
            },
        })
        return path


class EvidenceV43Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bundle = MATERIALIZER.AuthorityBundle.load(REPOSITORY_ROOT)

    def test_canonical_materialization_is_complete_deterministic_and_metric_preserving(self) -> None:
        fixture = CanonicalFixture(self, self.bundle)
        first_root = fixture.root / "evidence-a"
        second_root = fixture.root / "evidence-b"
        first, _, first_generated = MATERIALIZER.materialize_canonical(
            self.bundle, fixture.raw, fixture.comparisons, first_root, SOURCE_SHA
        )
        second, _, second_generated = MATERIALIZER.materialize_canonical(
            self.bundle, fixture.raw, fixture.comparisons, second_root, SOURCE_SHA
        )
        self.assertEqual(len(first), 50)
        self.assertEqual(first, second)
        self.assertEqual(
            sorted(MATERIALIZER.rendered_json(document) for document in first_generated.values()),
            sorted(MATERIALIZER.rendered_json(document) for document in second_generated.values()),
        )
        self.assertEqual(len(first_generated), 100)
        self.assertTrue(all(item["result"] == "PASS" for item in first))
        first_visual = next(item for item in first if item["metrics"])
        raw_report = MATERIALIZER.load_json(
            Path(first_visual["reportPath"]), "comparison report"
        )
        self.assertEqual(first_visual["metrics"], raw_report["metrics"])

    def test_canonical_materialization_fails_closed_on_missing_or_failed_report(self) -> None:
        fixture = CanonicalFixture(self, self.bundle)
        report = next(fixture.comparisons.glob("*.json"))
        backup = report.read_bytes()
        report.unlink()
        with self.assertRaises(MATERIALIZER.MaterializationError):
            MATERIALIZER.materialize_canonical(
                self.bundle,
                fixture.raw,
                fixture.comparisons,
                fixture.root / "evidence",
                SOURCE_SHA,
            )
        report.write_bytes(backup)
        sidecar = next(fixture.raw.rglob("*.sidecar.json"))
        sidecar_backup = sidecar.read_bytes()
        sidecar.write_text('{"candidateID":"first","candidateID":"second"}\n')
        with self.assertRaises(MATERIALIZER.MaterializationError):
            MATERIALIZER.materialize_canonical(
                self.bundle,
                fixture.raw,
                fixture.comparisons,
                fixture.root / "evidence",
                SOURCE_SHA,
            )
        sidecar.write_bytes(sidecar_backup)
        report.write_bytes(backup)
        document = MATERIALIZER.load_json(report, "comparison report")
        document["result"] = "FAIL"
        write_json(report, document)
        with self.assertRaises(MATERIALIZER.MaterializationError):
            MATERIALIZER.materialize_canonical(
                self.bundle,
                fixture.raw,
                fixture.comparisons,
                fixture.root / "evidence",
                SOURCE_SHA,
            )

    def test_responsive_materialization_projects_all_required_instances(self) -> None:
        fixture = ResponsiveFixture(self, self.bundle)
        evidence_root = fixture.root / "evidence"
        responsive, probes, contexts, probe_index, generated = (
            MATERIALIZER.materialize_responsive(
                self.bundle,
                fixture.captures,
                fixture.run_report,
                evidence_root,
                SOURCE_SHA,
            )
        )
        canonical_stub = {
            candidate["id"]: {
                "result": "PASS",
                "candidateSHA256": "c" * 64,
                "reportPath": "canonical-report.json",
                "reportSHA256": "d" * 64,
                "checks": {"exactDimensions": True},
                "metrics": {},
            }
            for candidate in self.bundle.canonical["candidates"]
        }
        mappings = MATERIALIZER.materialize_mappings(
            self.bundle, SOURCE_SHA, canonical_stub, contexts, probe_index
        )
        self.assertEqual(len(responsive), 400)
        self.assertEqual(len(probes), 576)
        self.assertEqual(len(generated), 400)
        self.assertEqual(len(mappings), 1104)
        self.assertEqual(
            sum(item["scoreDisposition"] == "structural-assertion" for item in mappings),
            700,
        )
        self.assertTrue(all(item["result"] == "PASS" for item in responsive))
        self.assertTrue(all("observedValue" in item for item in probes))

    def test_responsive_materialization_rejects_missing_source_bound_capture(self) -> None:
        fixture = ResponsiveFixture(self, self.bundle)
        target = fixture.captures / "norse--workspace-empty--iphone-portrait.png"
        target.unlink()
        with self.assertRaises(MATERIALIZER.MaterializationError):
            MATERIALIZER.materialize_responsive(
                self.bundle,
                fixture.captures,
                fixture.run_report,
                fixture.root / "evidence",
                SOURCE_SHA,
            )

    def test_responsive_materialization_rejects_tampered_source_binding(self) -> None:
        fixture = ResponsiveFixture(self, self.bundle)
        before = fixture.root / "SourceManifest.before.json"
        document = MATERIALIZER.load_json(before, "source manifest fixture")
        document["isClean"] = False
        write_json(before, document)
        with self.assertRaises(MATERIALIZER.MaterializationError):
            MATERIALIZER.materialize_responsive(
                self.bundle,
                fixture.captures,
                fixture.run_report,
                fixture.root / "evidence",
                SOURCE_SHA,
            )

    def test_responsive_materialization_rejects_legacy_extraction_schema(self) -> None:
        fixture = ResponsiveFixture(self, self.bundle)
        extraction = MATERIALIZER.load_json(
            fixture.extraction, "responsive extraction fixture"
        )
        extraction["schemaVersion"] = "1.2"
        write_json(fixture.extraction, extraction)
        run_report = MATERIALIZER.load_json(
            fixture.run_report, "responsive run report fixture"
        )
        run_report["outputPaths"]["extractionSHA256"] = sha256(
            fixture.extraction
        )
        write_json(fixture.run_report, run_report)
        with self.assertRaisesRegex(
            MATERIALIZER.MaterializationError,
            "direct source-bound v4.3 capture",
        ):
            MATERIALIZER.materialize_responsive(
                self.bundle,
                fixture.captures,
                fixture.run_report,
                fixture.root / "evidence",
                SOURCE_SHA,
            )

    def test_responsive_materialization_rejects_authority_hash_drift(self) -> None:
        fixture = ResponsiveFixture(self, self.bundle)
        extraction = MATERIALIZER.load_json(
            fixture.extraction, "responsive extraction fixture"
        )
        extraction["authorityProvenance"]["files"]["authority"][
            "sha256"
        ] = "0" * 64
        write_json(fixture.extraction, extraction)
        run_report = MATERIALIZER.load_json(
            fixture.run_report, "responsive run report fixture"
        )
        run_report["outputPaths"]["extractionSHA256"] = sha256(
            fixture.extraction
        )
        write_json(fixture.run_report, run_report)
        with self.assertRaisesRegex(
            MATERIALIZER.MaterializationError, "v4.3 authority provenance differs"
        ):
            MATERIALIZER.materialize_responsive(
                self.bundle,
                fixture.captures,
                fixture.run_report,
                fixture.root / "evidence",
                SOURCE_SHA,
            )

    def test_full_materializer_writes_validator_compatible_aggregates(self) -> None:
        canonical = CanonicalFixture(self, self.bundle)
        responsive = ResponsiveFixture(self, self.bundle)
        evidence = responsive.root / "evidence"
        report = MATERIALIZER.materialize(
            REPOSITORY_ROOT,
            SOURCE_SHA,
            canonical.raw,
            canonical.comparisons,
            responsive.captures,
            responsive.run_report,
            evidence,
        )
        self.assertEqual(report["result"], "PASS")
        self.assertEqual(report["counts"], {
            "canonicalCandidates": 50,
            "responsiveEntries": 400,
            "runtimeProbeInstances": 576,
            "canonicalImageMappings": 400,
            "responsiveStructuralMappings": 700,
            "negativeInvariantMappings": 4,
            "mappingResults": 1104,
        })
        canonical_results = MATERIALIZER.load_json(
            evidence / "canonical-results.json", "canonical aggregate"
        )
        responsive_results = MATERIALIZER.load_json(
            evidence / "responsive-results.json", "responsive aggregate"
        )
        probe_results = MATERIALIZER.load_json(
            evidence / "runtime-probe-results.json", "probe aggregate"
        )
        mapping_results = MATERIALIZER.load_json(
            evidence / "mapping-results.json", "mapping aggregate"
        )
        self.assertEqual(len(canonical_results["results"]), 50)
        self.assertEqual(len(responsive_results["entries"]), 400)
        self.assertEqual(len(probe_results["results"]), 576)
        self.assertEqual(len(mapping_results["results"]), 1104)
        for item in canonical_results["results"]:
            sidecar = evidence / item["sidecarPath"]
            determinism = evidence / item["determinismPath"]
            self.assertEqual(sha256(sidecar), item["sidecarSHA256"])
            self.assertEqual(sha256(determinism), item["determinismSHA256"])
        self.assertFalse(any(
            path.name.endswith(".tmp") for path in evidence.rglob("*")
        ))

        package_name = (
            "Rune-Scribe-Theme-Fidelity-v4.3-Canonical-Authority-and-Remediation"
        )
        configured = os.environ.get("RUNESCRIBE_V43_AUTHORITY_PACKAGE")
        candidates = (
            Path(configured) if configured else None,
            Path.home() / "Projects/RuneScribe" / package_name,
            Path.home() / "Projects" / package_name,
        )
        package_root = next(
            (
                candidate
                for candidate in candidates
                if candidate is not None and candidate.is_dir()
            ),
            Path.home() / "Projects/RuneScribe" / package_name,
        )
        validator = package_root / "05-AUTOMATION/validate_v4_3_evidence.py"
        if validator.is_file():
            gates = MATERIALIZER.load_json(
                package_root / "06-EVIDENCE/Gate-Catalog-v4.3.json",
                "gate catalog",
            )
            write_json(evidence / "gate-results.json", {
                "schemaVersion": "1.3",
                "templateOnly": False,
                "acceptanceEvidence": True,
                "sourceSHA": SOURCE_SHA,
                "results": [
                    {
                        "gateID": gate["id"],
                        "sourceSHA": SOURCE_SHA,
                        "evidencePaths": ["fixture-evidence"],
                        "result": "PASS",
                    }
                    for gate in gates["gates"]
                ],
            })
            support_documents = {
                "SourceManifest.before.json": {"sourceSHA": SOURCE_SHA, "result": "PASS"},
                "SourceManifest.after.json": {"sourceSHA": SOURCE_SHA, "result": "PASS"},
                "SourceBoundary.json": {
                    "applicationSourceSHA": SOURCE_SHA,
                    "evidenceHeadSHA": "b" * 40,
                    "allowedEvidenceRoot": "docs/verification/theme-fidelity-v4-3/",
                    "onlyEvidencePathsAfterApplicationSource": True,
                    "worktreeCleanAtApplicationSource": True,
                    "result": "PASS",
                },
                "Toolchain.json": {"result": "PASS", "tools": {"fixture": "1"}},
                "CommandIndex.json": {"result": "PASS", "commands": []},
                "FailureLedger.json": {
                    "unresolvedBlockingFailureCount": 0,
                    "failures": [],
                },
            }
            for name, document in support_documents.items():
                write_json(evidence / name, document)
            (evidence / "FinalSelfAudit.md").write_text(
                "# Final Self Audit\n\nPASS\n", encoding="utf-8"
            )

            def support(name: str) -> dict[str, str]:
                return {"path": name, "sha256": sha256(evidence / name)}

            write_json(evidence / "final-qualification.json", {
                "schemaVersion": "1.3",
                "templateOnly": False,
                "acceptanceEvidence": True,
                "sourceSHA": SOURCE_SHA,
                "evidenceHeadSHA": "b" * 40,
                "authoritySHA256": sha256(
                    package_root
                    / "03-COMPARISON-AUTHORITY/Comparison-Authority-v1.3.json"
                ),
                "canonicalCatalogSHA256": sha256(
                    package_root
                    / "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-v1.3.json"
                ),
                "gateCatalogSHA256": sha256(
                    package_root / "06-EVIDENCE/Gate-Catalog-v4.3.json"
                ),
                "counts": {
                    "canonicalCandidates": 50,
                    "responsiveEntries": 400,
                    "runtimeProbeInstances": 576,
                    "mappingResults": 1104,
                    "gates": len(gates["gates"]),
                },
                "supportingEvidence": {
                    "sourceManifestBefore": support("SourceManifest.before.json"),
                    "sourceManifestAfter": support("SourceManifest.after.json"),
                    "sourceBoundary": support("SourceBoundary.json"),
                    "toolchain": support("Toolchain.json"),
                    "commandIndex": support("CommandIndex.json"),
                    "failureLedger": support("FailureLedger.json"),
                    "finalSelfAudit": support("FinalSelfAudit.md"),
                },
                "result": "PASS",
            })
            completed = subprocess.run(
                [sys.executable, str(validator), str(evidence)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                completed.returncode,
                0,
                completed.stdout + completed.stderr,
            )


if __name__ == "__main__":
    unittest.main()
