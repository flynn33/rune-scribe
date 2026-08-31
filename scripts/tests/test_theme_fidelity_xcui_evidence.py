#!/usr/bin/env python3
"""Mutation tests for independently captured Theme-fidelity XCUI evidence."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import theme_fidelity_execution_v12 as execution  # noqa: E402
import theme_fidelity_destination_policy as destination_policy  # noqa: E402
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
        cls.v43_authority, cls.v43_probes = xcui.load_repository_authority(
            ROOT, xcui.CONTRACT_V43
        )
        cls.v43_seeds = xcui.load_repository_seeds(ROOT, xcui.CONTRACT_V43)
        cls.v43_candidates = xcui.load_repository_candidates(
            ROOT, xcui.CONTRACT_V43
        )
        cls.v43_entries = xcui.index_entries(cls.v43_authority)

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
        contract_version: str = xcui.CONTRACT_V42,
    ) -> tuple[Path, dict, dict[str, dict]]:
        if contract_version == xcui.CONTRACT_V43:
            probes = self.v43_probes
            seeds = self.v43_seeds
            candidate_catalog = self.v43_candidates
            candidate_ids = xcui.capture_candidate_ids_for_entry(
                entry,
                probes,
                candidate_catalog,
                contract_version,
            )
        else:
            probes = self.probes
            seeds = self.seeds
            candidate_catalog = self.candidates
            candidate_ids = xcui.candidate_ids_for_entry(entry)
        candidates: list[dict] = []
        attachment_records: dict[str, dict] = {}
        source_test = self.source_test(entry)
        for candidate_id in candidate_ids:
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
            for probe_id in xcui.xcui_probe_ids_for_entry(entry, probes):
                catalog = probes[probe_id]
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
                    preview_ids = [
                        identifier
                        for identifier in candidate_ids
                        if identifier.startswith("theme.artifact-preview.")
                    ]
                    if len(preview_ids) != 1:
                        raise AssertionError(
                            f"fixture preview candidate differs: {entry['id']}"
                        )
                    candidate_id = preview_ids[0]
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
            entry, candidate_catalog
        ):
            match_count = specification["expectedMatchCount"]
            identifier = specification["expectedElementIdentifier"]
            has_element = identifier is not None
            value = None
            if identifier == xcui.DIAGNOSTIC_STATE:
                environment = seeds[entry["seedID"]]["launchEnvironment"]
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
                    "elementFrame": None if not has_element else {
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
                    "label": None if not has_element else str(identifier),
                    "value": value,
                    "isEnabled": None if not has_element else True,
                    "isHittable": None if not has_element else True,
                }
            )

        document = {
            "schemaVersion": xcui.SCHEMA_VERSION,
            "entryID": entry["id"],
            "theme": entry["theme"],
            "surface": entry["surface"],
            "destination": entry["destination"],
            "deterministicSeed": copy.deepcopy(seeds[entry["seedID"]]),
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

    def test_v43_authority_inventory_is_exact_per_bundle_and_globally(self) -> None:
        inventory = xcui.expected_inventory(
            self.v43_authority,
            self.v43_probes,
            candidates=self.v43_candidates,
            contract_version=xcui.CONTRACT_V43,
        )
        self.assertEqual(
            (
                len(inventory.sidecars),
                len(inventory.candidate_pngs),
                len(inventory.query_pngs),
                len(inventory.attachments),
            ),
            (325, 341, 4, 670),
        )
        expected = {
            "iphone-xcui": (70, 74, 1, 145),
            "ipad-xcui": (85, 89, 1, 175),
            "macos-xcui": (170, 178, 2, 350),
        }
        for role, counts in expected.items():
            with self.subTest(role=role):
                selected = xcui.expected_inventory_for_role(
                    self.v43_authority,
                    self.v43_probes,
                    role,
                    candidates=self.v43_candidates,
                    contract_version=xcui.CONTRACT_V43,
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

    def test_v43_reduce_motion_adds_exactly_one_probe_only_preview_capture(self) -> None:
        expected_preview = {
            "Norse": "theme.artifact-preview.relic.norse.runestone-tablet",
            "Moonleaf": "theme.artifact-preview.relic.moonleaf.tablet",
            "Sunspire": "theme.artifact-preview.relic.sunspire.dawnfire-tablet",
            "Wildwood": "theme.artifact-preview.relic.wildwood.rootsong-tablet",
            "Gloamthorn": "theme.artifact-preview.relic.gloamthorn.nightthorn-tablet",
        }
        entries = [
            entry
            for entry in self.v43_entries.values()
            if entry["surface"] == "reduce-motion"
        ]
        self.assertEqual(len(entries), 20)
        for entry in entries:
            with self.subTest(entry=entry["id"]):
                mapped = set(xcui.candidate_ids_for_entry(entry))
                effective = xcui.capture_candidate_ids_for_entry(
                    entry,
                    self.v43_probes,
                    self.v43_candidates,
                    xcui.CONTRACT_V43,
                )
                added = set(effective) - mapped
                self.assertEqual(added, {expected_preview[entry["theme"]]})
                self.assertEqual(
                    xcui.candidate_attachment_name(entry, next(iter(added))),
                    (
                        f"{entry['theme'].lower()}--reduce-motion--"
                        f"{entry['destination']}--candidate-element--"
                        f"{expected_preview[entry['theme']]}.png"
                    ),
                )

    def test_v43_reduce_motion_rejects_missing_or_ambiguous_preview_candidate(self) -> None:
        entry = copy.deepcopy(
            self.v43_entries["Norse|reduce-motion|iphone-portrait"]
        )
        preview = "theme.artifact-preview.relic.norse.runestone-tablet"
        missing = dict(self.v43_candidates)
        missing.pop(preview)
        with self.assertRaisesRegex(xcui.XCUIEvidenceError, "not unique"):
            xcui.capture_candidate_ids_for_entry(
                entry, self.v43_probes, missing, xcui.CONTRACT_V43
            )

        ambiguous = dict(self.v43_candidates)
        ambiguous["theme.artifact-preview.relic.norse.unapproved"] = {
            "id": "theme.artifact-preview.relic.norse.unapproved"
        }
        with self.assertRaisesRegex(xcui.XCUIEvidenceError, "not unique"):
            xcui.capture_candidate_ids_for_entry(
                entry, self.v43_probes, ambiguous, xcui.CONTRACT_V43
            )

    def test_v43_reduce_motion_sidecar_captures_probe_preview_directly(self) -> None:
        entry = copy.deepcopy(
            self.v43_entries["Norse|reduce-motion|iphone-portrait"]
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sidecar_path, _, records = self.write_sidecar(
                root,
                entry,
                contract_version=xcui.CONTRACT_V43,
            )
            validated = xcui.validate_sidecar(
                sidecar_path,
                entry,
                self.v43_probes,
                self.v43_seeds,
                self.v43_candidates,
                root,
                records,
                contract_version=xcui.CONTRACT_V43,
            )
            expected_ids = xcui.capture_candidate_ids_for_entry(
                entry,
                self.v43_probes,
                self.v43_candidates,
                xcui.CONTRACT_V43,
            )
            self.assertEqual(list(validated.candidate_captures), expected_ids)
            self.assertEqual(
                xcui.candidate_ids_for_entry(entry), ["screen.workspace"]
            )
            preview_probe = validated.probe_evidence[
                "probe.motion.preview-contained.theme.norse.base"
            ]
            self.assertEqual(
                preview_probe["candidateID"],
                "theme.artifact-preview.relic.norse.runestone-tablet",
            )

    def test_v43_extractor_reads_direct_v43_bundles_and_preserves_legacy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_roots: dict[str, Path] = {}
            roles = (
                "iphone",
                "ipad",
                "macos",
                "iphone-xcui",
                "ipad-xcui",
                "macos-xcui",
            )
            for role in roles:
                source_root = root / f"{role}-attachments"
                source_root.mkdir()
                source_roots[role] = source_root
                if role in extractor.XCUI_ROLES:
                    inventory = xcui.expected_inventory_for_role(
                        self.v43_authority,
                        self.v43_probes,
                        role,
                        candidates=self.v43_candidates,
                        contract_version=xcui.CONTRACT_V43,
                    )
                    for entry in self.v43_entries.values():
                        if xcui.sidecar_name(entry) in inventory.sidecars:
                            self.write_sidecar(
                                source_root,
                                copy.deepcopy(entry),
                                contract_version=xcui.CONTRACT_V43,
                            )
                    self.assertEqual(
                        {path.name for path in source_root.iterdir()},
                        set(inventory.attachments),
                    )
                else:
                    for name in extractor.expected_attachment_names(role):
                        path = source_root / name
                        if name.endswith(".png"):
                            self.write_png(path)
                        else:
                            path.write_text("{}\n", encoding="utf-8")

            result_roots = {
                role: root / f"{role}.xcresult" for role in roles
            }
            for path in result_roots.values():
                path.mkdir()

            identifiers = {
                "iphone": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "ipad": (
                    "com.apple.CoreSimulator.SimDeviceType."
                    "iPad-Pro-13-inch-M5-12GB"
                ),
            }
            selections: dict[str, dict] = {}
            models: dict[str, str] = {}
            device_ids = {"iphone": "iphone-id", "ipad": "ipad-id"}
            for role in ("iphone", "ipad"):
                policy = destination_policy.policy_for_device_type(
                    identifiers[role], role
                )
                models[role] = policy["expectedModelName"]
                selections[role] = destination_policy.build_selection(
                    role,
                    {
                        "udid": device_ids[role],
                        "name": f"{role} fixture",
                        "deviceTypeIdentifier": identifiers[role],
                    },
                    {
                        "identifier": identifiers[role],
                        "name": policy["expectedModelName"],
                        "pixelDimensions": policy["expectedPixelDimensions"],
                        "scale": policy["expectedScale"],
                    },
                )

            bindings = [
                extractor.BundleBinding(
                    role,
                    result_roots[role],
                    device_ids.get(role.removesuffix("-xcui")),
                    models.get(role.removesuffix("-xcui")),
                    selections.get(role.removesuffix("-xcui")),
                )
                for role in roles
            ]
            role_by_result = {
                path.resolve(): role for role, path in result_roots.items()
            }

            def fake_summary(bundle: Path) -> dict:
                role = role_by_result[bundle.resolve()]
                base = role.removesuffix("-xcui")
                model = models.get(base, "Mac Test")
                device_id = device_ids.get(base, "mac-id")
                platform = "macOS" if base == "macos" else "iOS Simulator"
                return {
                    "result": "Passed",
                    "totalTestCount": 1,
                    "passedTests": 1,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "environmentDescription": "synthetic CLI extraction",
                    "startTime": 1.0,
                    "finishTime": 2.0,
                    "devicesAndConfigurations": [{
                        "passedTests": 1,
                        "failedTests": 0,
                        "skippedTests": 0,
                        "expectedFailures": 0,
                        "device": {
                            "deviceId": device_id,
                            "deviceName": model,
                            "modelName": model,
                            "osVersion": "1.0",
                            "osBuildNumber": "1A1",
                            "platform": platform,
                            "architecture": "arm64",
                        },
                        "testPlanConfiguration": {
                            "configurationName": "Test Scheme Action"
                        },
                    }],
                }

            def fake_export(bundle: Path, exported: Path) -> list[dict]:
                role = role_by_result[bundle.resolve()]
                base = role.removesuffix("-xcui")
                model = models.get(base, "Mac Test")
                device_id = device_ids.get(base, "mac-id")
                exported.mkdir(parents=True)
                attachments = []
                for path in sorted(source_roots[role].iterdir()):
                    shutil.copyfile(path, exported / path.name)
                    attachments.append({
                        "suggestedHumanReadableName": path.name,
                        "exportedFileName": path.name,
                        "configurationName": "Test Scheme Action",
                        "deviceName": model,
                        "deviceId": device_id,
                        "isAssociatedWithFailure": False,
                        "timestamp": 1.0,
                    })
                test_identifier = (
                    xcui.XCUI_TEST_IDENTIFIER
                    if role in extractor.XCUI_ROLES
                    else extractor.EXPECTED_TEST_IDENTIFIER
                )
                manifest = [{
                    "testIdentifier": test_identifier,
                    "testIdentifierURL": (
                        extractor.expected_xcui_test_identifier_url(role)
                        if role in extractor.XCUI_ROLES
                        else "test://theme-fidelity/hosted"
                    ),
                    "attachments": attachments,
                }]
                (exported / "manifest.json").write_text(
                    json.dumps(manifest), encoding="utf-8"
                )
                return manifest

            output = root / "captures"
            with mock.patch.object(
                extractor, "xcresult_summary", side_effect=fake_summary
            ), mock.patch.object(
                extractor, "export_attachments", side_effect=fake_export
            ), mock.patch.object(
                extractor.subprocess,
                "run",
                return_value=mock.Mock(
                    returncode=0,
                    stdout="/usr/bin/xcresulttool\n",
                    stderr="",
                ),
            ):
                report = extractor.extract(
                    bindings,
                    output,
                    authority_contract=xcui.CONTRACT_V43,
                    source_sha="a" * 40,
                )

                for role in extractor.XCUI_ROLES:
                    source_root = source_roots[role]
                    for path in source_root.iterdir():
                        path.unlink()
                    inventory = xcui.expected_inventory_for_role(
                        self.authority,
                        self.probes,
                        role,
                    )
                    for entry in self.entries.values():
                        if xcui.sidecar_name(entry) in inventory.sidecars:
                            self.write_sidecar(source_root, copy.deepcopy(entry))
                legacy_report = extractor.extract(
                    bindings,
                    root / "legacy-captures",
                )

            self.assertEqual(report["schemaVersion"], "1.3")
            self.assertEqual(report["sourceSHA"], "a" * 40)
            self.assertEqual(report["authorityContract"], xcui.CONTRACT_V43)
            self.assertEqual(report["sourceXCUIContract"], xcui.CONTRACT_V43)
            self.assertEqual(
                (
                    legacy_report["schemaVersion"],
                    legacy_report["candidatePNGCount"],
                    legacy_report["xcuiQueryPNGCount"],
                    legacy_report["xcuiSidecarCount"],
                    legacy_report["attachmentCount"],
                ),
                ("1.2", 672, 4, 380, 1900),
            )
            self.assertNotIn("authorityContract", legacy_report)
            self.assertEqual(
                (
                    report["pngCount"],
                    report["auxiliaryPNGCount"],
                    report["recordCount"],
                    report["candidatePNGCount"],
                    report["xcuiQueryPNGCount"],
                    report["xcuiSidecarCount"],
                    report["attachmentCount"],
                ),
                (400, 44, 400, 341, 4, 325, 1514),
            )
            bundle_counts = {
                item["role"]: (
                    item["sourceAttachmentCount"],
                    item["selectedAttachmentCount"],
                )
                for item in report["resultBundles"]
            }
            self.assertEqual(bundle_counts, {
                "iphone": (211, 211),
                "ipad": (211, 211),
                "macos": (422, 422),
                "iphone-xcui": (145, 145),
                "ipad-xcui": (175, 175),
                "macos-xcui": (350, 350),
            })
            direct_path = (
                output / "norse--reduce-motion--iphone-portrait.xcui.json"
            )
            direct = json.loads(direct_path.read_text(encoding="utf-8"))
            self.assertEqual(
                [item["candidateID"] for item in direct["candidateElementCaptures"]],
                [
                    "screen.workspace",
                    "theme.artifact-preview.relic.norse.runestone-tablet",
                ],
            )
            direct_metadata = next(
                item
                for item in report["attachments"]
                if item["name"] == direct_path.name
            )
            self.assertEqual(direct_metadata["sourceAuthorityContract"], "v4.3")
            self.assertEqual(direct_metadata["evidenceAuthorityContract"], "v4.3")
            self.assertEqual(direct_metadata["extractionOperation"], "direct-copy")
            self.assertFalse(
                (
                    output /
                    "norse--reduce-motion--iphone-portrait--candidate-element--"
                    "theme.background.theme.norse.base.reduce-motion.png"
                ).exists()
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
