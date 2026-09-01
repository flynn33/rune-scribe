#!/usr/bin/env python3
"""Adversarial regression tests for terminal remediation evidence."""

from __future__ import annotations

import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile
import zlib


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def resolve_package_root() -> Path:
    package_name = "Rune-Scribe-Codex-Remediation-Package-v1.0"
    raven_forge_root = Path.home() / "Documents/RavenForge"
    candidates = (
        raven_forge_root / "Projects/RuneScribe" / package_name,
        raven_forge_root / "RuneScribe" / package_name,
    )
    return next((path for path in candidates if path.is_dir()), candidates[0])


PACKAGE_ROOT = resolve_package_root()


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, REPOSITORY_ROOT / "scripts" / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


generator = load_script("remediation_evidence_generator", "generate-remediation-evidence.py")
checker = load_script("remediation_completion_checker", "check-remediation-completion.py")
capture = load_script(
    "remediation_domain_capture", "capture-remediation-domain-results.py"
)
mutation_harness = load_script(
    "remediation_mutation_harness", "test-remediation-mutations.py"
)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")


def write_minimal_png(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    def chunk(chunk_type: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data)) + chunk_type + data
            + struct.pack(">I", zlib.crc32(chunk_type + data) & 0xFFFFFFFF)
        )
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00\x00"))
        + chunk(b"IEND", b"")
    )


class EvidenceHardeningTests(unittest.TestCase):
    def test_human_claims_map_to_exact_typed_artifacts(self) -> None:
        claims = {
            "workspace/settings/vault screenshots": (
                "docs/verification/remediation-v1/Screenshots/iphone-workspace-moonleaf.png",
                "docs/verification/remediation-v1/Screenshots/iphone-settings-moonleaf.png",
                "docs/verification/remediation-v1/Screenshots/iphone-vault-moonleaf.png",
            ),
            "cloud/game center test logs": (
                generator.claim_evidence_path("cloud/game center test logs"),
            ),
            "performance/resource report": (
                generator.claim_evidence_path("performance/resource report"),
            ),
            "shipping product log": (
                "docs/verification/remediation-v1/GateRun/shipping-products.log",
            ),
            "negative mutation results": (
                "docs/verification/remediation-v1/NegativeMutations.json",
            ),
            "built Info.plists": (
                generator.BUILT_PRODUCT_INSPECTION_RESULTS,
            ),
            "macOS screenshots": generator.PLATFORM_SCREENSHOT_CLAIM_PATHS[
                "macOS screenshots"
            ],
            "iPhone screenshots": generator.PLATFORM_SCREENSHOT_CLAIM_PATHS[
                "iPhone screenshots"
            ],
            "all remediation JSON evidence": (
                generator.EVIDENCE_INDEX,
            ),
        }
        for claim, expected in claims.items():
            with self.subTest(claim=claim):
                self.assertEqual(generator.required_claim_paths(claim), expected)
                self.assertEqual(checker.required_claim_paths(claim), expected)
                self.assertNotEqual(expected, ("logs/unrelated.log",))

    def test_concrete_slash_claim_remains_exact(self) -> None:
        claim = "Screenshots/iphone-norse-workspace.png"
        exact = (
            "docs/verification/remediation-v1/"
            "Screenshots/iphone-norse-workspace.png"
        )
        alias = (
            "docs/verification/remediation-v1/"
            "Screenshots/iphone-norse-workspace-alias.png"
        )
        self.assertEqual(generator.required_claim_paths(claim), (exact,))
        self.assertEqual(checker.required_claim_paths(claim), (exact,))
        self.assertNotEqual(generator.required_claim_paths(claim), (alias,))
        self.assertNotEqual(checker.required_claim_paths(claim), (alias,))

    def test_moonleaf_share_builder_screenshot_is_a_written_contract(self) -> None:
        path = (
            "docs/verification/remediation-v1/Screenshots/"
            "macos-share-builder-moonleaf.png"
        )
        description = (
            "Moonleaf selected in the macOS Share Builder, demonstrating the "
            "optional provider's themed builder surface."
        )
        self.assertIn(
            path,
            generator.required_claim_paths("macOS screenshots"),
        )
        self.assertIn(
            path,
            checker.required_claim_paths("macOS screenshots"),
        )
        self.assertEqual(
            generator.WRITTEN_SCREENSHOT_CONTRACTS[path],
            ("macOS", description),
        )
        self.assertEqual(
            checker.WRITTEN_SCREENSHOT_CONTRACTS[path],
            ("macOS", description),
        )

        (
            _, finding_gates, finding_controls, _, test_rows, _, matrix_screenshots,
        ) = generator.load_controls(PACKAGE_ROOT, REPOSITORY_ROOT)
        template = generator.generated_output_template(
            test_rows,
            finding_gates,
            finding_controls,
            matrix_screenshots,
            set(),
        )
        screenshots = {
            item["path"]: item
            for item in template["screenshots"]
        }
        self.assertEqual(
            screenshots[path],
            {
                "path": path,
                "platform": "macOS",
                "description": description,
            },
        )

    def test_info_plist_only_app_zip_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "InfoOnly.app.zip"
            plist = plistlib.dumps({
                "CFBundleShortVersionString": "1.0.40",
                "CFBundleVersion": "40",
                "CFBundleIdentifier": "com.runescribe.app",
                "CFBundlePackageType": "APPL",
                "CFBundleExecutable": "RuneScrib",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
            })
            info = zipfile.ZipInfo("RuneScrib.app/Info.plist")
            info.create_system = 3
            info.external_attr = (0o100644 & 0xFFFF) << 16
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr(info, plist)
            with self.assertRaisesRegex(generator.EvidenceError, "omits declared executable"):
                generator.validate_app_zip(
                    archive_path, "iOS", "com.runescribe.app"
                )
            checker_errors = checker.validate_app_zip(
                archive_path.read_bytes(), "iOS", "synthetic Info-only app"
            )
            self.assertTrue(any("declared executable is missing" in item for item in checker_errors))

    def test_test_index_rejects_mutated_locked_field(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            matrix_target = root / checker.EXPECTED_TEST_MATRIX
            matrix_target.parent.mkdir(parents=True, exist_ok=True)
            matrix_target.write_bytes(
                (PACKAGE_ROOT / "controls/TEST-MATRIX-v1.0.csv").read_bytes()
            )
            with matrix_target.open(newline="", encoding="utf-8") as stream:
                rows = list(csv.DictReader(stream))
            log = "docs/verification/remediation-v1/GateRun/all.log"
            log_path = root / log
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text("PASS\n", encoding="utf-8")
            log_hash = checker.sha256_file(log_path)
            tests: list[dict[str, object]] = []
            for row in rows:
                named = checker.canonical_test_evidence(row["requiredEvidence"])
                evidence = [log]
                if named is not None:
                    evidence.append(named)
                    named_path = root / named
                    if named.endswith(".png"):
                        write_minimal_png(named_path)
                    elif not named_path.exists():
                        named_path.parent.mkdir(parents=True, exist_ok=True)
                        named_path.write_text("{}\n", encoding="utf-8")
                evidence = sorted(set(evidence))
                evidence_hashes = {
                    item: checker.sha256_file(root / item) for item in evidence
                }
                attachment = (
                    "docs/verification/remediation-v1/Attachments/"
                    f"{row['testID']}.md"
                )
                attachment_path = root / attachment
                attachment_path.parent.mkdir(parents=True, exist_ok=True)
                fragments = [
                    *row.values(), "PASS", "suite", "command", log, log_hash,
                    *evidence, *evidence_hashes.values(),
                ]
                attachment_path.write_text("\n".join(fragments), encoding="utf-8")
                execution = {
                    **row,
                    "gateIDs": row["gateIDs"].split(";"),
                    "result": "PASS",
                    "suiteName": "suite",
                    "command": "command",
                    "log": log,
                    "logSHA256": log_hash,
                    "evidence": evidence,
                    "evidenceSHA256": evidence_hashes,
                    "attachments": [attachment],
                    "attachmentSHA256": {
                        attachment: checker.sha256_file(attachment_path)
                    },
                }
                tests.append(execution)
            tests[0]["scenario"] = "mutated scenario"
            index = {
                "schemaVersion": "1.0",
                "sourceManifestSHA256": "a" * 64,
                "sourceRevision": None,
                "testMatrixSHA256": checker.EXPECTED_TEST_MATRIX_SHA256,
                "requiredTestCount": 87,
                "passedTestCount": 87,
                "failedTestCount": 0,
                "tests": tests,
            }
            write_json(root / checker.EXPECTED_TEST_EXECUTION_INDEX, index)
            errors, _, _, _ = checker.validate_test_execution_index(
                root, "a" * 64, False
            )
            self.assertTrue(any(".scenario differs from locked row" in item for item in errors))

    def test_ipad_record_rejects_unbound_source_hash(self) -> None:
        udid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        document = {
            "schemaVersion": "1.0",
            "status": "PASS",
            "sourceManifestSHA256": "b" * 64,
            "sourceRevision": None,
            "version": "1.0.40",
            "build": "40",
            "simulator": {"name": "iPad Pro", "udid": udid, "runtime": "iOS 26.0"},
            "iOSProduct": {
                "path": "artifacts/remediation-v1/RuneScrib-iPhoneSimulator-Release.app.zip",
                "sha256": "c" * 64,
                "bundleIdentifier": "com.runescribe.app",
            },
            "suites": [],
            "screenshots": [],
        }
        locked_rows = {
            "T-023": {"platform": "iPad Simulator", "requiredEvidence": "ipad-share-builder.png"},
            "T-114": {"platform": "iPad Simulator", "requiredEvidence": "ipad logs"},
        }
        executions = {
            test_id: {"command": f"xcodebuild -destination id={udid}", "result": "PASS", "suiteName": "ipad"}
            for test_id in locked_rows
        }
        with tempfile.TemporaryDirectory() as temporary:
            errors = checker.validate_ipad_qualification_document(
                document,
                repository_root=Path(temporary),
                source_hash="a" * 64,
                source_revision=None,
                locked_rows=locked_rows,
                executions=executions,
                ios_product_digest="c" * 64,
            )
        self.assertIn("iPad qualification: sourceManifestSHA256 differs", errors)

    def test_finding_closure_rejects_same_token_unrelated_source_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            matrix_path = root / checker.EXPECTED_FINDING_MATRIX
            matrix_path.parent.mkdir(parents=True, exist_ok=True)
            matrix_path.write_bytes(
                (PACKAGE_ROOT / "controls/FINDING-CLOSURE-MATRIX-v1.0.json").read_bytes()
            )
            _, controls = checker.load_locked_finding_controls(root)
            with (PACKAGE_ROOT / "controls/TEST-MATRIX-v1.0.csv").open(
                newline="", encoding="utf-8"
            ) as stream:
                locked_rows = {row["testID"]: row for row in csv.DictReader(stream)}
            arbitrary = "Sources/ThemeCoordinatorContractsShadow.swift"
            arbitrary_path = root / arbitrary
            arbitrary_path.parent.mkdir(parents=True, exist_ok=True)
            arbitrary_path.write_text("struct Arbitrary {}\n", encoding="utf-8")
            executions = {test_id: {"result": "PASS"} for test_id in locked_rows}
            findings = []
            for finding_id in sorted(checker.EXPECTED_FINDING_IDS):
                gates = set(controls[finding_id]["gates"])
                relevant = sorted(
                    test_id for test_id, row in locked_rows.items()
                    if gates & set(row["gateIDs"].split(";"))
                )
                findings.append({
                    "id": finding_id,
                    "originalStatus": checker.EXPECTED_FINDING_STATUSES[finding_id],
                    "changedFiles": [arbitrary],
                    "removedFiles": [],
                    "removalBindings": {},
                    "implementationBindings": {
                        expectation: [arbitrary]
                        for expectation in controls[finding_id]["implementation"]
                    },
                    "sourceAreaBindings": {
                        expectation: [arbitrary]
                        for expectation in controls[finding_id]["sourceAreas"]
                    },
                    "testBindings": {
                        expectation: relevant
                        for expectation in controls[finding_id]["tests"]
                    },
                    "tests": [
                        f"{test_id}: {locked_rows[test_id]['scenario']}"
                        for test_id in relevant
                    ],
                    "evidence": ["evidence.json"],
                    "finalStatus": "CLOSED",
                    "gateIDs": sorted(gates),
                })
            closure_path = root / "DefectClosure.json"
            write_json(closure_path, {
                "schemaVersion": "1.0",
                "sourceManifestSHA256": "a" * 64,
                "sourceRevision": None,
                "version": "1.0.40",
                "build": "40",
                "findings": findings,
            })
            errors = checker.validate_defect_closure(
                closure_path, root, "a" * 64, checker.EXPECTED_GATE_IDS, False,
                {"evidence.json": checker.EXPECTED_GATE_IDS},
                {"evidence.json": {"evidence.json"}}, {arbitrary},
                {arbitrary}, set(), set(), set(),
                locked_rows, executions,
            )
            self.assertTrue(any(
                "differs from its exact source-manifest path tuple" in item
                for item in errors
            ))

            findings[0]["changedFiles"] = [{}]
            write_json(closure_path, {
                "schemaVersion": "1.0",
                "sourceManifestSHA256": "a" * 64,
                "sourceRevision": None,
                "version": "1.0.40",
                "build": "40",
                "findings": findings,
            })
            malformed_errors = checker.validate_defect_closure(
                closure_path, root, "a" * 64, checker.EXPECTED_GATE_IDS, False,
                {"evidence.json": checker.EXPECTED_GATE_IDS},
                {"evidence.json": {"evidence.json"}}, {arbitrary},
                {arbitrary}, set(), set(), set(),
                locked_rows, executions,
            )
            self.assertTrue(any(
                "findings[0] changedFiles are invalid or missing" in item
                for item in malformed_errors
            ))

    def test_publication_false_requires_remote_inspection_record_and_log(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = "docs/verification/remediation-v1/GateRun/publication.log"
            log_path = root / log
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text("PUBLICATION_AUDIT_PASS\n", encoding="utf-8")
            record = {
                "schemaVersion": "1.0", "status": "PASS",
                "sourceManifestSHA256": "a" * 64, "sourceRevision": None,
                "version": "1.0.40", "build": "40",
                "command": "inspect publication state", "log": log,
                "checkedAt": "2026-08-23T00:00:00Z", "branch": None,
                "defaultBranch": "main", "remoteInspectionPerformed": False,
                "headTags": [], "sourceMergedToDefault": False,
                "releasePublished": False, "uploadPerformed": False,
                "notarizationPerformed": False, "testFlightPerformed": False,
                "appStorePerformed": False, "rolloutPerformed": False,
                "logSHA256": hashlib.sha256(log_path.read_bytes()).hexdigest(),
            }
            write_json(root / checker.EXPECTED_PUBLICATION_AUDIT, record)
            executions = {"T-121": {
                "command": "inspect publication state",
                "evidence": [checker.EXPECTED_PUBLICATION_AUDIT, log],
            }}
            errors = checker.validate_publication_audit_record(
                root, "a" * 64, None, executions
            )
            self.assertIn(
                f"{checker.EXPECTED_PUBLICATION_AUDIT}: remoteInspectionPerformed differs",
                errors,
            )

        # The same record must remain valid after the terminal checker copies
        # the repository without Git metadata.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = "docs/verification/remediation-v1/GateRun/publication.log"
            log_path = root / log
            log_path.parent.mkdir(parents=True, exist_ok=True)
            branch = "fix/rune-scribe-remediation-v1"
            revision = "b" * 40
            markers = (
                "PUBLICATION_AUDIT_PASS",
                "REMOTE_INSPECTION_PERFORMED=true",
                "HEAD_TAGS=NONE",
                "SOURCE_MERGED_TO_DEFAULT=false",
                "RELEASE_PUBLISHED=false",
                "UPLOAD_PERFORMED=false",
                "NOTARIZATION_PERFORMED=false",
                "TESTFLIGHT_PERFORMED=false",
                "APPSTORE_PERFORMED=false",
                "ROLLOUT_PERFORMED=false",
                branch,
                "main",
                revision,
            )
            log_path.write_text("\n".join(markers) + "\n", encoding="utf-8")
            command = "inspect publication state"
            record = {
                "schemaVersion": "1.0", "status": "PASS",
                "sourceManifestSHA256": "a" * 64,
                "sourceRevision": revision,
                "version": "1.0.40", "build": "40",
                "command": command, "log": log,
                "checkedAt": "2026-08-23T00:00:00Z", "branch": branch,
                "defaultBranch": "main", "remoteInspectionPerformed": True,
                "headTags": [], "sourceMergedToDefault": False,
                "releasePublished": False, "uploadPerformed": False,
                "notarizationPerformed": False, "testFlightPerformed": False,
                "appStorePerformed": False, "rolloutPerformed": False,
                "logSHA256": hashlib.sha256(log_path.read_bytes()).hexdigest(),
            }
            write_json(root / checker.EXPECTED_PUBLICATION_AUDIT, record)
            executions = {"T-121": {
                "command": command,
                "evidence": [checker.EXPECTED_PUBLICATION_AUDIT, log],
            }}
            with mock.patch.object(checker, "NO_GIT_CHILD_MODE", True):
                self.assertEqual(
                    checker.validate_publication_audit_record(
                        root, "a" * 64, revision, executions
                    ),
                    [],
                )

    def test_flat_owner_archive_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            owner = root / "owner.zip"
            with zipfile.ZipFile(owner, "w") as archive:
                archive.writestr("RuneScrib-macOS-Release.app.zip", b"not an app")
            errors = checker.validate_owner_package(
                owner, root, "a" * 64, None, None, {}, {}
            )
            self.assertTrue(any("outer envelope members differ" in item for item in errors))

    def test_generator_checker_exact_path_policies_match(self) -> None:
        self.assertEqual(generator.SOURCE_AREA_PATHS, checker.SOURCE_AREA_PATHS)
        self.assertEqual(generator.IMPLEMENTATION_PATHS, checker.IMPLEMENTATION_PATHS)
        progression_catalog_path = (
            "Packages/RuneScribeArchitecture/Sources/"
            "RuneScribeProgressionModule/ProgressionCatalogResources.swift"
        )
        self.assertIn(
            progression_catalog_path,
            generator.SOURCE_AREA_PATHS["RSA-009"][0],
        )
        self.assertTrue(
            any(
                progression_catalog_path in expectation_paths
                for expectation_paths in generator.IMPLEMENTATION_PATHS["RSA-009"]
            )
        )
        self.assertEqual(
            generator.REMOVED_IMPLEMENTATION_PATHS,
            checker.REMOVED_IMPLEMENTATION_PATHS,
        )
        self.assertEqual(generator.TEST_EXPECTATION_IDS, checker.TEST_EXPECTATION_IDS)
        self.assertEqual(
            generator.WORKSPACE_SCREENSHOT_CLAIM_PATHS,
            checker.WORKSPACE_SCREENSHOT_CLAIM_PATHS,
        )
        self.assertEqual(
            generator.PLATFORM_SCREENSHOT_CLAIM_PATHS,
            checker.PLATFORM_SCREENSHOT_CLAIM_PATHS,
        )
        self.assertEqual(
            generator.PLATFORM_SCREENSHOT_CLAIM_PLATFORMS,
            checker.PLATFORM_SCREENSHOT_CLAIM_PLATFORMS,
        )
        self.assertEqual(
            generator.WRITTEN_SCREENSHOT_CONTRACTS,
            checker.WRITTEN_SCREENSHOT_CONTRACTS,
        )
        self.assertEqual(capture.CLOUD_TEST_SOURCES, checker.DOMAIN_CLOUD_TEST_SOURCES)
        self.assertEqual(
            capture.PERFORMANCE_TEST_SOURCES,
            checker.DOMAIN_PERFORMANCE_TEST_SOURCES,
        )
        self.assertEqual(capture.CLOUD_CASE_TESTS, checker.DOMAIN_CLOUD_CASE_TESTS)
        self.assertEqual(
            capture.PERFORMANCE_CASE_TESTS,
            checker.DOMAIN_PERFORMANCE_CASE_TESTS,
        )
        self.assertEqual(capture.THEME_SPECS, checker.DOMAIN_THEME_SPECS)
        self.assertEqual(capture.CLOUD_MARKERS, checker.CLOUD_GAME_CENTER_MARKERS)
        self.assertEqual(
            capture.PERFORMANCE_MARKERS,
            checker.PERFORMANCE_RESOURCE_MARKERS,
        )
        self.assertEqual(capture.PREVIEW_TEST, checker.DOMAIN_PREVIEW_TEST)
        self.assertEqual(
            capture.ICLOUD_ENTITLEMENT_KEYS,
            checker.ICLOUD_ENTITLEMENT_KEYS,
        )
        self.assertEqual(
            capture.MACOS_REQUIRED_TRUE_ENTITLEMENTS,
            checker.MACOS_REQUIRED_TRUE_ENTITLEMENTS,
        )
        self.assertEqual(
            capture.MACOS_OPTIONAL_SIGNING_ENTITLEMENTS,
            checker.MACOS_OPTIONAL_SIGNING_ENTITLEMENTS,
        )
        self.assertEqual(
            capture.IOS_ALLOWED_ENTITLEMENTS,
            checker.IOS_ALLOWED_ENTITLEMENTS,
        )
        self.assertEqual(
            generator.EXPECTED_DOMAIN_PRODUCER_SHA256,
            checker.EXPECTED_DOMAIN_PRODUCER_SHA256,
        )
        self.assertEqual(
            generator.EXPECTED_DOMAIN_PRODUCER_SHA256,
            hashlib.sha256(
                (REPOSITORY_ROOT / generator.DOMAIN_RESULT_PRODUCER).read_bytes()
            ).hexdigest(),
        )
        self.assertEqual(
            capture.EXPECTED_SHIPPING_CHECKER_SHA256,
            generator.EXPECTED_SHIPPING_CHECKER_SHA256,
        )
        self.assertEqual(
            capture.EXPECTED_SHIPPING_CHECKER_SHA256,
            checker.EXPECTED_SHIPPING_CHECKER_SHA256,
        )
        self.assertEqual(
            capture.EXPECTED_SHIPPING_CHECKER_SHA256,
            hashlib.sha256(
                (REPOSITORY_ROOT / capture.SHIPPING_CHECKER_PATH).read_bytes()
            ).hexdigest(),
        )
        capture_path = capture.PRODUCER_PATH
        self.assertIn(capture_path, generator.SOURCE_AREA_PATHS["RSA-008"][3])
        self.assertTrue(any(
            capture_path in paths
            for paths in generator.IMPLEMENTATION_PATHS["RSA-008"]
        ))
        self.assertEqual(
            [
                index for index, paths in enumerate(
                    generator.IMPLEMENTATION_PATHS["RSA-009"]
                )
                if capture_path in paths
            ],
            [1],
        )
        self.assertEqual(
            generator.required_claim_paths(generator.EVIDENCE_INDEX_CLAIM),
            checker.required_claim_paths(checker.EVIDENCE_INDEX_CLAIM),
        )

    def test_domain_filters_preserve_exact_framework_identity(self) -> None:
        scratch = Path("/tmp/domain-scratch")
        swift_testing = next(iter(capture.CLOUD_TEST_SOURCES))
        xctest = next(
            identifier for identifier in capture.PERFORMANCE_TEST_SOURCES
            if "/" in identifier
        )
        self.assertEqual(capture.test_command(swift_testing, scratch)[-1], swift_testing)
        self.assertEqual(
            capture.test_command(xctest, scratch)[-1],
            "^" + __import__("re").escape(xctest) + "$",
        )
        for identifier, source_relative in (
            (swift_testing, capture.CLOUD_TEST_SOURCES[swift_testing]),
            (xctest, capture.PERFORMANCE_TEST_SOURCES[xctest]),
        ):
            errors, expected = checker.expected_domain_execution(
                REPOSITORY_ROOT,
                identifier,
                source_relative,
            )
            self.assertEqual(errors, [])
            self.assertEqual(
                expected["command"],
                capture.display_command(
                    capture.test_command(identifier, scratch),
                    scratch,
                ),
            )

    def test_swift_testing_zero_match_output_is_rejected(self) -> None:
        identifier = next(iter(capture.CLOUD_TEST_SOURCES))
        with self.assertRaisesRegex(capture.CaptureError, "did not PASS exact identity"):
            capture.verify_pass_output(
                identifier,
                "Swift Testing",
                "Test run with 0 tests passed after 0.001 seconds.\n",
            )

    def test_generator_rejects_unbound_shipping_change_and_deletion(self) -> None:
        locked_removed = {
            path
            for bindings in generator.REMOVED_IMPLEMENTATION_PATHS.values()
            for paths in bindings.values()
            for path in paths
        }
        with self.assertRaisesRegex(
            generator.EvidenceError,
            "omits baseline-changed shipping source/config/project paths",
        ):
            generator.validate_global_shipping_path_coverage(
                {"Packages/RuneScribeArchitecture/Sources/UnboundShipping.swift"},
                locked_removed,
            )
        with self.assertRaisesRegex(
            generator.EvidenceError,
            "omits deleted shipping paths",
        ):
            generator.validate_global_shipping_path_coverage(
                set(),
                locked_removed
                | {"Packages/RuneScribeArchitecture/Sources/RemovedButUnmapped.swift"},
            )

    def test_immutable_baseline_anchors_reject_forged_records(self) -> None:
        self.assertEqual(generator.EXPECTED_BASELINE_REVISION, checker.EXPECTED_BASELINE_REVISION)
        self.assertEqual(
            generator.EXPECTED_BASELINE_MANIFEST_AGGREGATE,
            checker.EXPECTED_BASELINE_AGGREGATE_SHA256,
        )
        self.assertEqual(
            generator.EXPECTED_BASELINE_FILE_COUNT,
            checker.EXPECTED_BASELINE_FILE_COUNT,
        )
        self.assertEqual(
            generator.EXPECTED_BASELINE_ARCHIVE_SHA256,
            checker.EXPECTED_BASELINE_PACKAGE_SHA256,
        )
        before_source = REPOSITORY_ROOT / checker.SOURCE_MANIFEST_BEFORE
        baseline_source = REPOSITORY_ROOT / checker.BASELINE_RECORD
        final_manifest = json.loads(before_source.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before_target = root / checker.SOURCE_MANIFEST_BEFORE
            before_target.parent.mkdir(parents=True, exist_ok=True)
            forged_before = dict(final_manifest)
            forged_before["aggregateSHA256"] = "0" * 64
            write_json(before_target, forged_before)
            errors, *_ = checker.baseline_changed_manifest_paths(
                root, final_manifest, has_git=False, source_revision=None
            )
            self.assertTrue(any("immutable task baseline" in item for item in errors))

            write_json(before_target, final_manifest)
            forged_baseline = json.loads(baseline_source.read_text(encoding="utf-8"))
            forged_baseline["sourceBaseline"]["packageArchiveSHA256"] = "0" * 64
            write_json(root / checker.BASELINE_RECORD, forged_baseline)
            errors, *_ = checker.baseline_changed_manifest_paths(
                root, final_manifest, has_git=True, source_revision="a" * 40
            )
            self.assertTrue(any("source baseline differs" in item for item in errors))

    def test_rc005_deferred_evidence_index_authority_is_narrow(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = "docs/verification/remediation-v1/GateRun/artifact.txt"
            log = "docs/verification/remediation-v1/GateRun/result.log"
            index = checker.EVIDENCE_INDEX_PATH
            for relative, value in (
                (artifact, "artifact\n"), (log, "PASS\n"), (index, "{}\n")
            ):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(value, encoding="utf-8")
            record = {
                "schemaVersion": "1.0",
                "recordID": "full-regression",
                "gateIDs": ["RC-005"],
                "sourceManifestSHA256": "a" * 64,
                "version": "1.0.40",
                "build": "40",
                "result": "PASS",
                "commands": ["python3 scripts/check-remediation-completion.py"],
                "environment": {
                    "operatingSystem": "macOS",
                    "architecture": "arm64",
                    "xcode": "Xcode",
                    "swift": "Swift",
                },
                "startedAt": "2026-08-23T00:00:00Z",
                "endedAt": "2026-08-23T00:00:01Z",
                "failures": [],
                "artifacts": [artifact],
                "logs": [log],
                "evidenceClaims": [checker.EVIDENCE_INDEX_CLAIM],
                "evidenceBindings": {
                    checker.EVIDENCE_INDEX_CLAIM: [index],
                },
                "artifactSHA256": {
                    artifact: checker.sha256_file(root / artifact),
                    log: checker.sha256_file(root / log),
                },
            }
            gate_requirements = {
                "RC-005": {checker.EVIDENCE_INDEX_CLAIM},
            }
            full_path = root / "docs/verification/remediation-v1/FullRegression.json"
            errors, *_ = checker.validate_evidence_record(
                full_path, record, root, "a" * 64, {"RC-005"},
                gate_requirements, False, True,
            )
            self.assertFalse(any("evidence binding" in item for item in errors), errors)

            disconnected, *_ = checker.validate_evidence_record(
                full_path, record, root, "a" * 64, {"RC-005"},
                gate_requirements, False, False,
            )
            self.assertTrue(any("evidence binding" in item for item in disconnected))

            unauthorized_path = root / "docs/verification/remediation-v1/Other.json"
            unauthorized, *_ = checker.validate_evidence_record(
                unauthorized_path, record, root, "a" * 64, {"RC-005"},
                gate_requirements, False, True,
            )
            self.assertTrue(any("evidence binding" in item for item in unauthorized))

    def test_no_git_child_guard_and_exact_output_binding(self) -> None:
        guarded = subprocess.run(
            [
                sys.executable,
                str(REPOSITORY_ROOT / "scripts/check-remediation-completion.py"),
                "--no-git-child", "--binding-only",
                "--expected-source-hash", "a" * 64,
            ],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(guarded.returncode, 0)
        guarded_output = guarded.stdout + guarded.stderr
        self.assertIn("--no-git-child is forbidden in a normal Git worktree", guarded_output)
        self.assertIn("--no-git-child may not suppress terminal validation", guarded_output)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repository"
            script = root / "scripts/check-remediation-completion.py"
            script.parent.mkdir(parents=True, exist_ok=True)
            script.write_text(
                "import sys\n"
                "sys.stdout.write(" + repr(checker.NO_GIT_CHILD_OUTPUT) + ")\n",
                encoding="utf-8",
            )
            result_path = root / checker.NO_GIT_QUALIFICATION_RESULT
            write_json(result_path, {
                "expectedOutput": checker.NO_GIT_CHILD_OUTPUT,
                "expectedOutputSHA256": hashlib.sha256(
                    checker.NO_GIT_CHILD_OUTPUT.encode("utf-8")
                ).hexdigest(),
            })
            self.assertEqual(
                checker.run_copied_tree_no_git_check(root, "a" * 64), []
            )
            document = json.loads(result_path.read_text(encoding="utf-8"))
            document["expectedOutputSHA256"] = "0" * 64
            write_json(result_path, document)
            self.assertIn(
                "copied-tree no-Git checker output hash differs from its bound result",
                checker.run_copied_tree_no_git_check(root, "a" * 64),
            )

    def test_domain_capture_rejects_forged_marker_metric_prefix(self) -> None:
        forged = "\n".join((
            "semanticMarker=queue result=PASS testIDs=T-096,T-097",
            "metric.previewBytesMax=0",
            "domainCaptureResult=PASS",
        ))
        with self.assertRaisesRegex(capture.CaptureError, "reserved domain evidence"):
            capture.validate_suite_prefix(forged)

    def test_body_only_domain_producer_mutation_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            producer = root / generator.DOMAIN_RESULT_PRODUCER
            producer.parent.mkdir(parents=True, exist_ok=True)
            producer.write_bytes(
                (REPOSITORY_ROOT / generator.DOMAIN_RESULT_PRODUCER).read_bytes()
                + b"\n# body-only mutation\n"
            )
            with self.assertRaisesRegex(
                generator.EvidenceError,
                "source differs from the locked executable",
            ):
                generator.load_domain_producer(root)
            raw = root / "raw.log"
            raw.write_text("not a test log\n", encoding="utf-8")
            errors = checker.validate_domain_capture_replay(
                root,
                root / "SOURCE-MANIFEST.json",
                None,
                {"rawLog": "raw.log"},
            )
            self.assertEqual(
                errors,
                ["domain capture replay producer differs from the locked executable"],
            )

    def test_shipping_checker_body_lock_and_exact_success_output(self) -> None:
        pass_lines = [f"PASS: locked shipping check {index}" for index in range(1, 102)]
        body = (
            pass_lines[:9]
            + [
                "INFO: macOS product uses a non-ad-hoc signature.",
                pass_lines[9],
                "INFO: iOS product uses an ad hoc local signature; "
                "distribution identity is not assessed.",
            ]
            + pass_lines[10:]
        )
        output = (
            "\n".join(body)
            + "\nShipping-product inspection: 101 checks, 0 failures.\n"
            + "T-028 shipping-product/configuration inspection passed.\n"
        ).encode("utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shipping_checker = root / capture.SHIPPING_CHECKER_PATH
            shipping_checker.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(
                REPOSITORY_ROOT / capture.SHIPPING_CHECKER_PATH,
                shipping_checker,
            )
            minimal_zip = mutation_harness.deterministic_zip({
                "RuneScrib.app/placeholder": b"regular file\n",
            })
            macos_zip = root / "macOS.zip"
            ios_zip = root / "iOS.zip"
            macos_zip.write_bytes(minimal_zip)
            ios_zip.write_bytes(minimal_zip)
            completed = subprocess.CompletedProcess(
                args=[], returncode=0, stdout=output, stderr=b""
            )
            with mock.patch.object(capture.subprocess, "run", return_value=completed):
                summary, observed = capture.run_shipping_product_validation(
                    root=root,
                    macos_zip=macos_zip,
                    ios_zip=ios_zip,
                    output_relative=capture.SHIPPING_VALIDATION_LOG,
                )
            self.assertEqual(observed, output)
            self.assertEqual(summary["checkCount"], 101)
            self.assertEqual(summary["signatureKinds"], {
                "macOS": "non-ad-hoc", "iOS": "ad-hoc",
            })

            log_path = root / checker.DOMAIN_SHIPPING_VALIDATION_LOG
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_bytes(output)
            errors, checker_summary = checker.validate_shipping_validation_log(root)
            self.assertEqual(errors, [])
            self.assertEqual(checker_summary, summary)

            moved = list(body)
            moved[9], moved[10] = moved[10], moved[9]
            forged_output = (
                "\n".join(moved)
                + "\nShipping-product inspection: 101 checks, 0 failures.\n"
                + "T-028 shipping-product/configuration inspection passed.\n"
            ).encode("utf-8")
            forged_completed = subprocess.CompletedProcess(
                args=[], returncode=0, stdout=forged_output, stderr=b""
            )
            with mock.patch.object(
                capture.subprocess, "run", return_value=forged_completed
            ):
                with self.assertRaisesRegex(
                    capture.CaptureError, "output semantics differ"
                ):
                    capture.run_shipping_product_validation(
                        root=root,
                        macos_zip=macos_zip,
                        ios_zip=ios_zip,
                        output_relative=capture.SHIPPING_VALIDATION_LOG,
                    )
            log_path.write_bytes(forged_output)
            forged_errors, _ = checker.validate_shipping_validation_log(root)
            self.assertIn(
                "shipping-product validation log semantics differ", forged_errors
            )

            shipping_checker.write_bytes(shipping_checker.read_bytes() + b"\n# mutation\n")
            with self.assertRaisesRegex(
                capture.CaptureError, "differs from the locked executable"
            ):
                capture.run_shipping_product_validation(
                    root=root,
                    macos_zip=macos_zip,
                    ios_zip=ios_zip,
                    output_relative=capture.SHIPPING_VALIDATION_LOG,
                )

            producer = root / checker.DOMAIN_RESULT_PRODUCER
            producer.write_bytes(
                (REPOSITORY_ROOT / checker.DOMAIN_RESULT_PRODUCER).read_bytes()
            )
            raw = root / "raw.log"
            raw.write_text("not a test log\n", encoding="utf-8")
            self.assertEqual(
                checker.validate_domain_capture_replay(
                    root, root / "SOURCE-MANIFEST.json", None, {"rawLog": "raw.log"}
                ),
                [
                    "domain capture replay shipping-product checker differs from "
                    "the locked executable"
                ],
            )

    def test_safe_shipping_extractor_rejects_aliases_and_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            alias_zip = root / "alias.zip"
            with zipfile.ZipFile(alias_zip, "w") as archive:
                archive.writestr("RuneScrib.app/file", b"first")
                archive.writestr("RuneScrib.app//file", b"alias")
            with self.assertRaisesRegex(capture.CaptureError, "unsafe ZIP member"):
                capture.safe_extract_app_zip(alias_zip, root / "alias", "alias ZIP")

            case_alias_zip = root / "case-alias.zip"
            with zipfile.ZipFile(case_alias_zip, "w") as archive:
                archive.writestr("RuneScrib.app/Resources/first", b"first")
                archive.writestr("RuneScrib.app/resources/second", b"second")
            with self.assertRaisesRegex(
                capture.CaptureError, "colliding destination aliases"
            ):
                capture.safe_extract_app_zip(
                    case_alias_zip, root / "case-alias", "case-alias ZIP"
                )

            symlink_zip = root / "symlink.zip"
            link = zipfile.ZipInfo("RuneScrib.app/link")
            link.create_system = 3
            link.external_attr = (0o120777 & 0xFFFF) << 16
            with zipfile.ZipFile(symlink_zip, "w") as archive:
                archive.writestr(link, "../outside")
            with self.assertRaisesRegex(capture.CaptureError, "archive symlink"):
                capture.safe_extract_app_zip(
                    symlink_zip, root / "symlink", "symlink ZIP"
                )

    def test_exact_shipping_entitlement_policy_rejects_debug_extra_and_identity_forgery(
        self,
    ) -> None:
        macos = {
            "com.apple.developer.game-center": True,
            "com.apple.developer.icloud-container-identifiers": [
                "iCloud.com.runescribe.app"
            ],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.ubiquity-kvstore-identifier": (
                "$(TeamIdentifierPrefix)com.runescribe.app"
            ),
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.user-selected.read-write": True,
            "com.apple.security.personal-information.addressbook": True,
        }
        ios = {
            "application-identifier": "ABCDEFGHIJ.com.runescribe.app",
            "com.apple.developer.team-identifier": "ABCDEFGHIJ",
            "com.apple.developer.game-center": True,
            "com.apple.developer.icloud-container-identifiers": [
                "iCloud.com.runescribe.app"
            ],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.ubiquity-kvstore-identifier": (
                "ABCDEFGHIJ.com.runescribe.app"
            ),
            "keychain-access-groups": ["ABCDEFGHIJ.com.runescribe.app"],
        }
        for platform, document in (("macOS", macos), ("iOS", ios)):
            self.assertEqual(
                capture.entitlement_policy_errors(
                    document, platform=platform, architecture="arm64"
                ),
                [],
            )
            self.assertEqual(
                checker.entitlement_policy_errors(
                    document, platform=platform, architecture="arm64"
                ),
                [],
            )

        mutations = (
            ("macOS", macos, "com.example.unexpected", True, "unexpected entitlements"),
            (
                "macOS", macos, "com.apple.security.get-task-allow", True,
                "Release product enables get-task-allow",
            ),
            (
                "macOS", macos,
                "com.apple.developer.ubiquity-kvstore-identifier",
                "WRONG.identifier", "ubiquity key-value store identifier differs",
            ),
            ("iOS", ios, "com.example.unexpected", True, "unexpected entitlements"),
            (
                "iOS", ios, "get-task-allow", True,
                "Release product enables get-task-allow",
            ),
            (
                "iOS", ios, "com.apple.developer.ubiquity-kvstore-identifier",
                "ZZZZZZZZZZ.com.runescribe.app",
                "ubiquity key-value store prefix differs from the signing team",
            ),
            (
                "iOS", ios, "keychain-access-groups",
                ["ZZZZZZZZZZ.com.runescribe.app"],
                "keychain access group does not preserve com.runescribe.app",
            ),
        )
        for platform, base, key, value, marker in mutations:
            with self.subTest(platform=platform, key=key):
                forged = json.loads(json.dumps(base))
                forged[key] = value
                capture_errors = capture.entitlement_policy_errors(
                    forged, platform=platform, architecture="arm64"
                )
                checker_errors = checker.entitlement_policy_errors(
                    forged, platform=platform, architecture="arm64"
                )
                self.assertEqual(capture_errors, checker_errors)
                self.assertTrue(any(marker in item for item in capture_errors), capture_errors)

    def test_forged_entitlement_sidecar_cannot_replace_macho_entitlements(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "forged-sidecar.zip"
            plist = plistlib.dumps({
                "CFBundleExecutable": "RuneScrib",
                "CFBundleIdentifier": "com.runescribe.app",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0.40",
                "CFBundleVersion": "40",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
            })
            sidecar = plistlib.dumps({
                "com.apple.developer.game-center": True,
                "com.apple.developer.icloud-container-identifiers": [
                    "iCloud.com.runescribe.app"
                ],
                "com.apple.developer.icloud-services": ["CloudKit"],
            })
            archive_path.write_bytes(mutation_harness.deterministic_zip(
                {
                    "RuneScrib.app/Info.plist": plist,
                    "RuneScrib.app/RuneScrib": b"\xcf\xfa\xed\xfe" + b"\0" * 28,
                    "RuneScrib.app/forged.entitlements": sidecar,
                },
                executable_names={"RuneScrib.app/RuneScrib"},
            ))
            with self.assertRaises(capture.CaptureError):
                capture.inspect_app_zip(
                    archive_path, "artifacts/forged-sidecar.zip", "iOS",
                    REPOSITORY_ROOT,
                )

    def test_complete_theme_inventory_rejects_unlisted_bundle_member(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "extra-theme-member.zip"
            original = mutation_harness.app_zip("iOS")
            with zipfile.ZipFile(__import__("io").BytesIO(original)) as archive:
                entries = {
                    info.filename: archive.read(info)
                    for info in archive.infolist() if not info.is_dir()
                }
            entries[
                "RuneScrib.app/"
                "RuneScribeArchitecture_RuneScribeNorseThemeModule.bundle/"
                "undeclared-payload.bin"
            ] = b"x" * 1024
            archive_path.write_bytes(mutation_harness.deterministic_zip(
                entries, executable_names={"RuneScrib.app/RuneScrib"}
            ))
            with self.assertRaisesRegex(capture.CaptureError, "inventory differs"):
                capture.inspect_app_zip(
                    archive_path, "artifacts/extra-theme-member.zip", "iOS",
                    REPOSITORY_ROOT,
                )

    def test_macos_nested_theme_bundle_layout_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "macos-nested-theme-bundles.zip"
            archive_path.write_bytes(mutation_harness.app_zip("macOS"))

            product, budgets = capture.inspect_app_zip(
                archive_path,
                "artifacts/macos-nested-theme-bundles.zip",
                "macOS",
                REPOSITORY_ROOT,
            )

            self.assertEqual(product["platform"], "macOS")
            self.assertEqual(len(budgets), len(capture.THEME_SPECS))
            self.assertTrue(all(item["result"] == "PASS" for item in budgets))
            self.assertTrue(all(
                "/Contents/Resources/" in item["manifestPath"]
                for item in budgets
            ))

    def test_ios_extended_resource_bundle_signature_layout_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "ios-extended-bundle-signatures.zip"
            archive_path.write_bytes(mutation_harness.app_zip("iOS"))

            product, budgets = capture.inspect_app_zip(
                archive_path,
                "artifacts/ios-extended-bundle-signatures.zip",
                "iOS",
                REPOSITORY_ROOT,
            )

            self.assertEqual(product["platform"], "iOS")
            self.assertEqual(len(budgets), len(capture.THEME_SPECS))
            self.assertTrue(all(item["result"] == "PASS" for item in budgets))

    def test_checker_accepts_domain_producer_theme_bundle_layouts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for _theme, _bundle, source_relative, *_rest in capture.THEME_SPECS:
                source_root = (
                    REPOSITORY_ROOT
                    / source_relative.split("/Resources/", 1)[0]
                    / "Resources"
                )
                destination = (
                    root
                    / source_relative.split("/Resources/", 1)[0]
                    / "Resources"
                )
                shutil.copytree(source_root, destination)
            for platform, relative in checker.DOMAIN_APP_PRODUCTS:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(mutation_harness.app_zip(platform))

            errors, budgets = checker.derive_domain_theme_budgets(root)

            self.assertEqual(errors, [])
            self.assertEqual(
                len(budgets),
                len(checker.DOMAIN_APP_PRODUCTS) * len(capture.THEME_SPECS),
            )
            self.assertTrue(all(item["result"] == "PASS" for item in budgets))

    def test_recursive_theme_inventory_rejects_nested_unlisted_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = mutation_harness.app_zip("iOS")
            with zipfile.ZipFile(__import__("io").BytesIO(original)) as archive:
                entries = {
                    info.filename: archive.read(info)
                    for info in archive.infolist() if not info.is_dir()
                }
            entries[
                "RuneScrib.app/"
                "RuneScribeArchitecture_RuneScribeThemeMoonleafModule.bundle/"
                "Nested/undeclared-payload.bin"
            ] = b"x" * (70 * 1024 * 1024)
            nested_zip = root / "nested-theme-member.zip"
            with zipfile.ZipFile(
                nested_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
            ) as archive:
                for name in sorted(entries):
                    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                    info.create_system = 3
                    mode = 0o100755 if name == "RuneScrib.app/RuneScrib" else 0o100644
                    info.external_attr = mode << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, entries[name])
            with self.assertRaisesRegex(capture.CaptureError, "inventory differs"):
                capture.inspect_app_zip(
                    nested_zip, "artifacts/nested-theme-member.zip", "iOS",
                    REPOSITORY_ROOT,
                )

            for _theme, _bundle, source_relative, *_rest in capture.THEME_SPECS:
                source_root = (
                    REPOSITORY_ROOT
                    / source_relative.split("/Resources/", 1)[0]
                    / "Resources"
                )
                destination = (
                    root
                    / source_relative.split("/Resources/", 1)[0]
                    / "Resources"
                )
                shutil.copytree(source_root, destination)
            app_archives = {
                "macOS": mutation_harness.app_zip("macOS"),
                "iOS": nested_zip.read_bytes(),
            }
            for platform, relative in checker.DOMAIN_APP_PRODUCTS:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(app_archives[platform])
            errors, _budgets = checker.derive_domain_theme_budgets(root)
            self.assertTrue(any(
                "Moonleaf complete bundle inventory differs" in error
                and "Nested/undeclared-payload.bin" in error
                for error in errors
            ), errors)


if __name__ == "__main__":
    unittest.main()
