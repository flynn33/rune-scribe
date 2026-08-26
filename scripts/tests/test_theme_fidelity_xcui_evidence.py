#!/usr/bin/env python3
"""Mutation tests for independently captured Theme-fidelity XCUI evidence."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import theme_fidelity_execution_v12 as execution  # noqa: E402
import theme_fidelity_xcui_evidence as xcui  # noqa: E402


def load_script(name: str, relative: str):
    path = ROOT / relative
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


extractor = load_script(
    "theme_fidelity_capture_extractor_xcui_tests",
    "scripts/extract-theme-fidelity-captures.py",
)
indexer = load_script(
    "theme_fidelity_capture_indexer_xcui_tests",
    "scripts/index-theme-fidelity-captures.py",
)
capture_runner = load_script(
    "theme_fidelity_capture_runner_xcui_tests",
    "scripts/capture-theme-fidelity-matrix.py",
)


class ThemeFidelityXCUIEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.authority, cls.probes = xcui.load_repository_authority(ROOT)
        cls.seeds = xcui.load_repository_seeds(ROOT)
        cls.candidates = xcui.load_repository_candidates(ROOT)
        cls.entries = xcui.index_entries(cls.authority)

    def entry(self, identifier: str) -> dict:
        return copy.deepcopy(self.entries[identifier])

    @staticmethod
    def source_test(entry: dict) -> dict[str, str]:
        role = xcui.bundle_role_for_destination(entry["destination"])
        return {
            "targetName": xcui.UI_TEST_TARGETS_BY_ROLE[role],
            "targetKind": xcui.UI_TEST_TARGET_KIND,
            "testIdentifier": xcui.XCUI_TEST_IDENTIFIER,
            "bundleRole": role,
        }

    @staticmethod
    def write_png(path: Path, size: tuple[int, int] = (23, 19)) -> None:
        Image.new("RGBA", size, (27, 81, 143, 255)).save(path)

    def write_sidecar(
        self,
        root: Path,
        entry: dict,
        include_probes: bool = True,
    ) -> tuple[Path, dict, dict[str, dict]]:
        candidates: list[dict] = []
        attachment_records: dict[str, dict] = {}
        source_test = self.source_test(entry)
        for candidate_id in xcui.candidate_ids_for_entry(entry):
            name = xcui.candidate_attachment_name(entry, candidate_id)
            path = root / name
            self.write_png(path)
            candidates.append(
                {
                    "candidateID": candidate_id,
                    "elementIdentifier": candidate_id,
                    "attachmentName": name,
                    "declaredOperation": xcui.XCUI_OPERATION,
                    "actualOperation": xcui.XCUI_OPERATION,
                    "sha256": xcui.sha256_file(path),
                    "byteCount": path.stat().st_size,
                    "pixelWidth": 23,
                    "pixelHeight": 19,
                    "queryPredicate": xcui.exact_identifier_predicate(candidate_id),
                    "matchCount": 1,
                    "coordinateOrigin": "top-left",
                    "coordinateUnits": "points",
                    "elementFrame": {
                        "x": 20.0,
                        "y": 40.0,
                        "width": 200.0,
                        "height": 240.0,
                    },
                    "windowFrame": {
                        "x": 0.0,
                        "y": 0.0,
                        "width": 390.0,
                        "height": 844.0,
                    },
                    "label": candidate_id,
                    "value": None,
                    "isEnabled": True,
                    "isHittable": True,
                }
            )
            attachment_records[name] = self.attachment_record(
                source_test, path
            )

        probe_evidence: list[dict] = []
        if include_probes:
            for probe_id in xcui.xcui_probe_ids_for_entry(entry, self.probes):
                catalog = self.probes[probe_id]
                if probe_id == "probe.norse.vault.locked-element-count":
                    candidate_id = None
                    attachment_name = xcui.query_attachment_name(entry)
                    attachment_path = root / attachment_name
                    self.write_png(attachment_path, (390, 844))
                    query_predicate = xcui.LOCKED_QUERY_PREDICATE
                    match_count = 0
                    observed = 0
                    element_frame = None
                else:
                    candidate_id = xcui.expected_preview_candidate(entry)
                    attachment_name = xcui.candidate_attachment_name(
                        entry, candidate_id
                    )
                    attachment_path = root / attachment_name
                    query_predicate = f"identifier == '{candidate_id}'"
                    match_count = 1
                    observed = True
                    element_frame = {
                        "x": 20.0,
                        "y": 40.0,
                        "width": 200.0,
                        "height": 240.0,
                    }
                width, height = xcui.image_dimensions(
                    attachment_path, "test attachment"
                )
                attachment_records[attachment_name] = self.attachment_record(
                    source_test, attachment_path
                )
                probe_evidence.append(
                    {
                        "probeID": probe_id,
                        "source": catalog["source"],
                        "operator": catalog["operator"],
                        "expected": catalog["expected"],
                        "observed": observed,
                        "queryPredicate": query_predicate,
                        "matchCount": match_count,
                        "candidateID": candidate_id,
                        "attachmentName": attachment_name,
                        "attachmentSHA256": xcui.sha256_file(attachment_path),
                        "pixelWidth": width,
                        "pixelHeight": height,
                        "coordinateOrigin": "top-left",
                        "coordinateUnits": "points",
                        "elementFrame": element_frame,
                        "containerFrame": {
                            "x": 0.0,
                            "y": 0.0,
                            "width": 390.0,
                            "height": 844.0,
                        },
                    }
                )

        structural_witnesses: list[dict] = []
        for specification in xcui.expected_structural_witnesses(
            entry, self.candidates
        ):
            match_count = specification["expectedMatchCount"]
            identifier = specification["expectedElementIdentifier"]
            value = None
            if identifier == xcui.DIAGNOSTIC_STATE:
                environment = self.seeds[entry["seedID"]]["launchEnvironment"]
                value = json.dumps({
                    "schemaVersion": "1.0",
                    "themeID": entry["themeID"],
                    "codexID": entry["codexID"],
                    "surface": entry["surface"],
                    "destination": entry["destination"],
                    "appearance": environment[
                        "RUNESCRIBE_QUALIFICATION_APPEARANCE"
                    ],
                    "messageProfile": environment[
                        "RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE"
                    ],
                    "vaultState": environment.get(
                        "RUNESCRIBE_QUALIFICATION_VAULT_STATE"
                    ),
                    "activeThemeID": entry["themeID"],
                    "effectiveCodexID": entry["codexID"],
                }, sort_keys=True)
            elif identifier == xcui.DIAGNOSTIC_DYNAMIC_TYPE:
                value = "accessibility5"
            structural_witnesses.append(
                {
                    "witnessID": specification["witnessID"],
                    "queryPredicate": specification["queryPredicate"],
                    "matchCount": match_count,
                    "elementIdentifier": identifier,
                    "coordinateOrigin": "top-left",
                    "coordinateUnits": "points",
                    "elementFrame": None if match_count == 0 else {
                        "x": 20.0,
                        "y": 40.0,
                        "width": 200.0,
                        "height": 240.0,
                    },
                    "windowFrame": {
                        "x": 0.0,
                        "y": 0.0,
                        "width": 390.0,
                        "height": 844.0,
                    },
                    "label": None if match_count == 0 else str(identifier),
                    "value": value,
                    "isEnabled": None if match_count == 0 else True,
                    "isHittable": None if match_count == 0 else True,
                }
            )

        document = {
            "schemaVersion": xcui.SCHEMA_VERSION,
            "entryID": entry["id"],
            "theme": entry["theme"],
            "surface": entry["surface"],
            "destination": entry["destination"],
            "deterministicSeed": copy.deepcopy(self.seeds[entry["seedID"]]),
            "primaryCaptureAttachmentName": xcui.primary_capture_name(entry),
            "captureRecordAttachmentName": xcui.capture_record_name(entry),
            "sourceTest": source_test,
            "candidateElementCaptures": candidates,
            "structuralWitnesses": structural_witnesses,
            "xcuiProbeEvidence": probe_evidence,
        }
        sidecar_path = root / xcui.sidecar_name(entry)
        sidecar_path.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        attachment_records[sidecar_path.name] = self.attachment_record(
            source_test, sidecar_path
        )
        return sidecar_path, document, attachment_records

    @staticmethod
    def attachment_record(source_test: dict[str, str], path: Path) -> dict:
        return {
            "testIdentifier": source_test["testIdentifier"],
            "resultBundleRole": source_test["bundleRole"],
            "sourceTargetName": source_test["targetName"],
            "sourceTargetKind": source_test["targetKind"],
            "sha256": xcui.sha256_file(path),
            "bytes": path.stat().st_size,
        }

    @staticmethod
    def rewrite(path: Path, document: dict) -> None:
        path.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def executor(self, capture_root: Path, output_root: Path) -> execution.AuthorityExecutor:
        return execution.AuthorityExecutor(
            ROOT,
            capture_root,
            output_root,
            "a" * 40,
            ["theme-fidelity-test"],
            {"test": True},
        )

    def test_authority_inventory_is_exact_per_bundle_and_globally(self) -> None:
        inventory = xcui.expected_inventory(self.authority, self.probes)
        self.assertEqual(
            (len(inventory.sidecars), len(inventory.candidate_pngs), len(inventory.query_pngs)),
            (380, 672, 4),
        )
        expected = {
            "iphone-xcui": (95, 168, 1, 264),
            "ipad-xcui": (95, 168, 1, 264),
            "macos-xcui": (190, 336, 2, 528),
        }
        for role, counts in expected.items():
            with self.subTest(role=role):
                selected = xcui.expected_inventory_for_role(
                    self.authority, self.probes, role
                )
                self.assertEqual(
                    (
                        len(selected.sidecars),
                        len(selected.candidate_pngs),
                        len(selected.query_pngs),
                        len(selected.attachments),
                    ),
                    counts,
                )

    def test_candidate_sidecar_rejects_operation_hash_dimension_and_hosted_source_mutations(self) -> None:
        entry = self.entry("Norse|inscription-preview|iphone-portrait")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sidecar_path, document, records = self.write_sidecar(root, entry)
            validated = xcui.validate_sidecar(
                sidecar_path, entry, self.probes, self.seeds, self.candidates, root, records
            )
            self.assertEqual(len(validated.candidate_captures), 1)

            mutations = {
                "declared operation": lambda value: value["candidateElementCaptures"][0].update(
                    {"declaredOperation": "hosted-frame-crop"}
                ),
                "actual operation": lambda value: value["candidateElementCaptures"][0].update(
                    {"actualOperation": "hosted-frame-crop"}
                ),
                "hash": lambda value: value["candidateElementCaptures"][0].update(
                    {"sha256": "0" * 64}
                ),
                "dimension": lambda value: value["candidateElementCaptures"][0].update(
                    {"pixelWidth": 24}
                ),
                "hosted source": lambda value: value["sourceTest"].update(
                    {
                        "targetName": "RuneScribIOSTests",
                        "targetKind": "com.apple.product-type.bundle.unit-test",
                        "testIdentifier": xcui.HOSTED_TEST_IDENTIFIER,
                    }
                ),
            }
            for label, mutation in mutations.items():
                with self.subTest(mutation=label):
                    changed = copy.deepcopy(document)
                    mutation(changed)
                    self.rewrite(sidecar_path, changed)
                    with self.assertRaises(xcui.XCUIEvidenceError):
                        xcui.validate_sidecar(
                            sidecar_path, entry, self.probes, self.seeds,
                            self.candidates, root, records
                        )
            self.rewrite(sidecar_path, document)
            changed_records = copy.deepcopy(records)
            candidate_name = document["candidateElementCaptures"][0]["attachmentName"]
            changed_records[candidate_name]["sourceTargetKind"] = (
                "com.apple.product-type.bundle.unit-test"
            )
            with self.assertRaisesRegex(
                xcui.XCUIEvidenceError, "sourceTargetKind binding failed"
            ):
                xcui.validate_sidecar(
                    sidecar_path, entry, self.probes, self.seeds,
                    self.candidates, root, changed_records
                )

    def test_candidate_sidecar_rejects_mutated_raw_query_evidence(self) -> None:
        entry = self.entry("Norse|inscription-preview|iphone-portrait")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sidecar_path, document, _ = self.write_sidecar(root, entry)

            mutations = {
                "query predicate": lambda item: item.update(
                    {"queryPredicate": "identifier CONTAINS 'preview'"}
                ),
                "match count": lambda item: item.update({"matchCount": 0}),
                "element identifier": lambda item: item.update(
                    {"elementIdentifier": "theme.unrelated"}
                ),
                "coordinate origin": lambda item: item.update(
                    {"coordinateOrigin": "bottom-left"}
                ),
                "coordinate units": lambda item: item.update(
                    {"coordinateUnits": "pixels"}
                ),
                "element frame": lambda item: item.update({"elementFrame": None}),
                "window frame": lambda item: item.update({"windowFrame": None}),
                "label": lambda item: item.update({"label": 7}),
                "value": lambda item: item.update({"value": {"not": "text"}}),
                "enabled": lambda item: item.update({"isEnabled": "true"}),
                "hittable": lambda item: item.update({"isHittable": None}),
            }
            for label, mutation in mutations.items():
                with self.subTest(mutation=label):
                    changed = copy.deepcopy(document)
                    mutation(changed["candidateElementCaptures"][0])
                    self.rewrite(sidecar_path, changed)
                    with self.assertRaises(xcui.XCUIEvidenceError):
                        xcui.validate_sidecar(
                            sidecar_path,
                            entry,
                            self.probes,
                            self.seeds,
                            self.candidates,
                            root,
                        )

    def test_sidecar_rejects_missing_extra_duplicate_and_mutated_structural_witnesses(self) -> None:
        entry = self.entry("Norse|inscription-preview|iphone-portrait")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sidecar_path, document, _ = self.write_sidecar(root, entry)
            self.assertGreaterEqual(len(document["structuralWitnesses"]), 3)

            structural_set_mutations = {
                "missing": lambda witnesses: witnesses.pop(),
                "extra": lambda witnesses: witnesses.append(
                    {
                        **copy.deepcopy(witnesses[-1]),
                        "witnessID": "query:unexpected",
                        "queryPredicate": "identifier BEGINSWITH 'unexpected.'",
                    }
                ),
                "duplicate": lambda witnesses: witnesses.__setitem__(
                    1, copy.deepcopy(witnesses[0])
                ),
            }
            for label, mutation in structural_set_mutations.items():
                with self.subTest(witness_set_mutation=label):
                    changed = copy.deepcopy(document)
                    mutation(changed["structuralWitnesses"])
                    self.rewrite(sidecar_path, changed)
                    with self.assertRaises(xcui.XCUIEvidenceError):
                        xcui.validate_sidecar(
                            sidecar_path,
                            entry,
                            self.probes,
                            self.seeds,
                            self.candidates,
                            root,
                        )

            exact_witness_mutations = {
                "query predicate": lambda item: item.update(
                    {"queryPredicate": "identifier == 'theme.unrelated'"}
                ),
                "match count": lambda item: item.update({"matchCount": 2}),
                "element identifier": lambda item: item.update(
                    {"elementIdentifier": "theme.unrelated"}
                ),
                "coordinate origin": lambda item: item.update(
                    {"coordinateOrigin": "bottom-left"}
                ),
                "coordinate units": lambda item: item.update(
                    {"coordinateUnits": "pixels"}
                ),
                "element frame": lambda item: item.update({"elementFrame": None}),
                "window frame": lambda item: item.update({"windowFrame": None}),
                "label": lambda item: item.update({"label": False}),
                "value": lambda item: item.update({"value": ["not", "text"]}),
                "enabled": lambda item: item.update({"isEnabled": 1}),
                "hittable": lambda item: item.update({"isHittable": "yes"}),
            }
            for label, mutation in exact_witness_mutations.items():
                with self.subTest(witness_mutation=label):
                    changed = copy.deepcopy(document)
                    mutation(changed["structuralWitnesses"][0])
                    self.rewrite(sidecar_path, changed)
                    with self.assertRaises(xcui.XCUIEvidenceError):
                        xcui.validate_sidecar(
                            sidecar_path,
                            entry,
                            self.probes,
                            self.seeds,
                            self.candidates,
                            root,
                        )

            changed = copy.deepcopy(document)
            zero_result = next(
                witness
                for witness in changed["structuralWitnesses"]
                if witness["matchCount"] == 0
            )
            zero_result["label"] = "fabricated fallback"
            self.rewrite(sidecar_path, changed)
            with self.assertRaisesRegex(
                xcui.XCUIEvidenceError, "aggregate query contains element values"
            ):
                xcui.validate_sidecar(
                    sidecar_path,
                    entry,
                    self.probes,
                    self.seeds,
                    self.candidates,
                    root,
                )

    def test_sidecar_rejects_mutated_nonzero_picker_aggregate_count(self) -> None:
        entry = self.entry("Norse|relic-picker|iphone-portrait")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sidecar_path, document, _ = self.write_sidecar(root, entry)
            aggregate = next(
                witness
                for witness in document["structuralWitnesses"]
                if witness["witnessID"] == "query:relic-picker-set"
            )
            self.assertEqual(aggregate["matchCount"], 3)

            aggregate["matchCount"] = 4
            self.rewrite(sidecar_path, document)
            with self.assertRaisesRegex(
                xcui.XCUIEvidenceError, "exact query count differs"
            ):
                xcui.validate_sidecar(
                    sidecar_path,
                    entry,
                    self.probes,
                    self.seeds,
                    self.candidates,
                    root,
                )

    def test_sidecar_rejects_seed_id_and_launch_tuple_drift(self) -> None:
        entry = self.entry("Norse|inscription-preview|iphone-portrait")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sidecar_path, document, _ = self.write_sidecar(root, entry)
            validated = xcui.validate_sidecar(
                sidecar_path, entry, self.probes, self.seeds, self.candidates, root
            )
            self.assertEqual(
                validated.deterministic_seed,
                self.seeds[entry["seedID"]],
            )

            mutations = {
                "seed ID": lambda value: value["deterministicSeed"].update(
                    {"id": "seed.norse.compose-short"}
                ),
                "launch tuple": lambda value: value["deterministicSeed"][
                    "launchEnvironment"
                ].update({"RUNESCRIBE_QUALIFICATION_SURFACE": "compose-short"}),
            }
            for label, mutation in mutations.items():
                with self.subTest(mutation=label):
                    changed = copy.deepcopy(document)
                    mutation(changed)
                    self.rewrite(sidecar_path, changed)
                    with self.assertRaisesRegex(
                        xcui.XCUIEvidenceError,
                        "deterministic seed binding failed",
                    ):
                        xcui.validate_sidecar(
                            sidecar_path,
                            entry,
                            self.probes,
                            self.seeds,
                            self.candidates,
                            root,
                        )

    def test_sidecar_rejects_mutated_settled_readiness_tuple(self) -> None:
        entry = self.entry("Norse|inscription-preview|iphone-portrait")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sidecar_path, document, _ = self.write_sidecar(root, entry)
            readiness = next(
                witness
                for witness in document["structuralWitnesses"]
                if witness["witnessID"]
                == f"element:{xcui.DIAGNOSTIC_STATE}"
            )
            baseline = json.loads(readiness["value"])
            mutations = {
                "themeID": "theme.gloamthorn.production",
                "codexID": "codex.gloamthorn",
                "surface": "compose-short",
                "destination": "ipad-portrait",
                "appearance": "high-contrast",
                "messageProfile": "long-six-lines",
                "vaultState": "owned",
                "activeThemeID": "theme.gloamthorn.production",
                "effectiveCodexID": "codex.gloamthorn",
            }
            for key, value in mutations.items():
                with self.subTest(readiness_field=key):
                    changed = copy.deepcopy(document)
                    changed_readiness = next(
                        witness
                        for witness in changed["structuralWitnesses"]
                        if witness["witnessID"]
                        == f"element:{xcui.DIAGNOSTIC_STATE}"
                    )
                    mutated = copy.deepcopy(baseline)
                    mutated[key] = value
                    changed_readiness["value"] = json.dumps(
                        mutated, sort_keys=True
                    )
                    self.rewrite(sidecar_path, changed)
                    with self.assertRaisesRegex(
                        xcui.XCUIEvidenceError,
                        f"readiness {key} binding failed",
                    ):
                        xcui.validate_sidecar(
                            sidecar_path,
                            entry,
                            self.probes,
                            self.seeds,
                            self.candidates,
                            root,
                        )

    def test_large_text_sidecar_requires_live_accessibility5_witness(self) -> None:
        entry = self.entry("Gloamthorn|large-text|iphone-portrait")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sidecar_path, document, _ = self.write_sidecar(root, entry)

            validated = xcui.validate_sidecar(
                sidecar_path,
                entry,
                self.probes,
                self.seeds,
                self.candidates,
                root,
            )
            witness_id = f"element:{xcui.DIAGNOSTIC_DYNAMIC_TYPE}"
            self.assertEqual(
                validated.structural_witnesses[witness_id]["value"],
                "accessibility5",
            )

            changed = copy.deepcopy(document)
            dynamic_type = next(
                witness
                for witness in changed["structuralWitnesses"]
                if witness["witnessID"] == witness_id
            )
            dynamic_type["value"] = "accessibility2"
            self.rewrite(sidecar_path, changed)
            with self.assertRaisesRegex(
                xcui.XCUIEvidenceError,
                "large-text dynamic-type witness is not accessibility5",
            ):
                xcui.validate_sidecar(
                    sidecar_path,
                    entry,
                    self.probes,
                    self.seeds,
                    self.candidates,
                    root,
                )

    def test_candidate_source_uses_attachment_and_detects_post_validation_mutation(self) -> None:
        entry = self.entry("Norse|inscription-preview|iphone-portrait")
        mapping = next(
            item
            for item in entry["referenceMappings"]
            if item.get("candidateElementID")
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            capture_root = root / "captures"
            capture_root.mkdir()
            sidecar_path, _, _ = self.write_sidecar(capture_root, entry)
            validated = xcui.validate_sidecar(
                sidecar_path, entry, self.probes, self.seeds,
                self.candidates, capture_root
            )
            hosted_path = capture_root / xcui.primary_capture_name(entry)
            Image.new("RGBA", (100, 100), (200, 20, 20, 255)).save(hosted_path)
            executor = self.executor(capture_root, root / "output")
            with mock.patch.object(
                execution,
                "integral_crop",
                side_effect=AssertionError("hosted crop must not execute"),
            ):
                source = executor.candidate_source(
                    mapping,
                    hosted_path,
                    Image.open(hosted_path).convert("RGBA"),
                    {},
                    {mapping["candidateElementID"]: {"x": 1, "y": 1, "width": 5, "height": 5}},
                    validated,
                )
            self.assertEqual(source.source_kind, xcui.XCUI_OPERATION)
            self.assertEqual(source.image.size, (23, 19))
            self.assertNotIn("pixelCrop", source.provenance)
            self.assertNotIn("capture", source.provenance)
            self.assertEqual(
                source.provenance["sourceTest"]["targetKind"],
                xcui.UI_TEST_TARGET_KIND,
            )

            attachment = capture_root / validated.candidate_captures[
                mapping["candidateElementID"]
            ]["attachmentName"]
            Image.new("RGBA", (23, 19), (0, 0, 0, 255)).save(attachment)
            with self.assertRaisesRegex(execution.ExecutionError, "hash changed"):
                executor.candidate_source(
                    mapping,
                    hosted_path,
                    Image.open(hosted_path).convert("RGBA"),
                    {},
                    {},
                    validated,
                )

    def test_xcui_probe_requires_sidecar_and_ignores_hosted_pseudo_observation(self) -> None:
        entry = self.entry("Norse|reduce-motion|iphone-portrait")
        probe_id = "probe.motion.preview-contained.theme.norse.base"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            capture_root = root / "captures"
            capture_root.mkdir()
            sidecar_path, _, _ = self.write_sidecar(capture_root, entry)
            validated = xcui.validate_sidecar(
                sidecar_path, entry, self.probes, self.seeds,
                self.candidates, capture_root
            )
            hosted_path = capture_root / xcui.primary_capture_name(entry)
            Image.new("RGBA", (100, 100), (10, 20, 30, 255)).save(hosted_path)
            executor = self.executor(capture_root, root / "output")
            hosted_record = {
                "runtimeProbeObservations": [
                    {
                        "probeID": probe_id,
                        "source": "xcui-geometry-assertion",
                        "observed": True,
                        "details": {"hosted": True},
                    }
                ],
                "runtimeDiagnostics": {
                    "preview": {
                        "elementID": xcui.expected_preview_candidate(entry),
                        "exists": True,
                        "visible": True,
                        "viewportContained": True,
                    }
                },
            }
            pseudo_only = executor.evaluate_probe(
                probe_id,
                hosted_record,
                {},
                hosted_path,
                Image.open(hosted_path).convert("RGBA"),
                entry["destination"],
                None,
            )
            self.assertEqual(pseudo_only["result"], "FAIL")
            self.assertIn("independent XCUI", pseudo_only["failures"][0])

            bound = executor.evaluate_probe(
                probe_id,
                hosted_record,
                {},
                hosted_path,
                Image.open(hosted_path).convert("RGBA"),
                entry["destination"],
                validated,
            )
            self.assertEqual(bound["result"], "PASS")
            self.assertEqual(
                bound["observationDetails"]["sourceTest"]["targetKind"],
                xcui.UI_TEST_TARGET_KIND,
            )
            self.assertNotIn("hosted", bound["observationDetails"])

    def test_locked_query_is_bound_to_dedicated_screenshot_and_zero_count(self) -> None:
        entry = self.entry("Norse|vault-locked|iphone-portrait")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sidecar_path, document, _ = self.write_sidecar(root, entry)
            validated = xcui.validate_sidecar(
                sidecar_path, entry, self.probes, self.seeds, self.candidates, root
            )
            evidence = validated.probe_evidence[
                "probe.norse.vault.locked-element-count"
            ]
            self.assertEqual(evidence["matchCount"], 0)
            self.assertEqual(
                evidence["attachmentName"], xcui.query_attachment_name(entry)
            )
            self.assertEqual(evidence["queryPredicate"], xcui.LOCKED_QUERY_PREDICATE)

            mutated = copy.deepcopy(document)
            mutated["xcuiProbeEvidence"][0]["matchCount"] = 1
            mutated["xcuiProbeEvidence"][0]["observed"] = 1
            self.rewrite(sidecar_path, mutated)
            with self.assertRaisesRegex(
                xcui.XCUIEvidenceError, "must be zero"
            ):
                xcui.validate_sidecar(
                    sidecar_path, entry, self.probes, self.seeds,
                    self.candidates, root
                )

    def test_extractor_indexer_and_runner_use_the_exact_xcui_contract(self) -> None:
        entry = self.entry("Norse|inscription-preview|iphone-portrait")
        candidate_name = xcui.candidate_attachment_name(
            entry, xcui.candidate_ids_for_entry(entry)[0]
        )
        sidecar = xcui.sidecar_name(entry)
        query = xcui.query_attachment_name(
            self.entry("Norse|vault-locked|iphone-portrait")
        )
        for name in (candidate_name, sidecar, query):
            with self.subTest(name=name):
                self.assertEqual(extractor.canonical_attachment_name(name), name)
                self.assertEqual(
                    indexer.capture_destination_slug(name), "iphone-portrait"
                )
        decorated = sidecar.removesuffix(".json") + (
            "_0_570E0EB5-19B7-4236-8332-85D14C912D5B.json"
        )
        self.assertEqual(extractor.canonical_attachment_name(decorated), sidecar)
        decorated_candidate = candidate_name.removesuffix(".png") + (
            "_0_570E0EB5-19B7-4236-8332-85D14C912D5B.png"
        )
        self.assertEqual(
            extractor.canonical_attachment_name(decorated_candidate),
            candidate_name,
        )

        jobs = capture_runner.hosted_capture_jobs(
            "final", "iphone", "ipad", Path("/tmp/derived"), Path("/tmp/results")
        ) + capture_runner.xcui_capture_jobs(
            "final", "iphone", "ipad", Path("/tmp/derived"), Path("/tmp/results")
        )
        self.assertEqual(len(jobs), 6)
        for label, command in jobs:
            with self.subTest(job=label):
                self.assertEqual(command[command.index("-configuration") + 1], "Release")
                if label.endswith("-xcui"):
                    self.assertNotIn("ENABLE_TESTABILITY=YES", command)
                else:
                    self.assertEqual(command.count("ENABLE_TESTABILITY=YES"), 1)
        schemes = {
            label: command[command.index("-scheme") + 1]
            for label, command in jobs
            if label.endswith("-xcui")
        }
        self.assertEqual(
            schemes,
            {
                "iphone-xcui": "RuneScrib-Theme-Fidelity-iOS-XCUI",
                "ipad-xcui": "RuneScrib-Theme-Fidelity-iOS-XCUI",
                "macos-xcui": "RuneScrib-Theme-Fidelity-macOS-XCUI",
            },
        )
        for label, command in jobs:
            if label.endswith("-xcui"):
                only_testing = next(
                    argument for argument in command if argument.startswith("-only-testing:")
                )
                self.assertIn(
                    "/ThemeFidelityAuthorityUITests/testCaptureThemeFidelityAuthority",
                    only_testing,
                )


if __name__ == "__main__":
    unittest.main()
