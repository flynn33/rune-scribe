from __future__ import annotations

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    path = ROOT / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


indexer = load_script("index-theme-fidelity-captures.py")
extractor = load_script("extract-theme-fidelity-captures.py")
capture_runner = load_script("capture-theme-fidelity-matrix.py")
destination_policy = load_script("theme_fidelity_destination_policy.py")
ALLOWED_RESOURCE_IDS_BY_THEME_CODEX = indexer.load_theme_resource_manifests(ROOT)


def validate_capture_record(record: dict, expected: dict, png: Path):
    return indexer.validate_record(
        record,
        expected,
        png,
        ALLOWED_RESOURCE_IDS_BY_THEME_CODEX,
    )


def write_minimal_theme_resource_manifests(root: Path) -> None:
    for theme_name, specification in indexer.THEME_RESOURCE_MANIFESTS.items():
        document = dict(specification["identity"])
        document[specification["collectionKey"]] = [
            {
                specification["resourceIDKey"]: (
                    f"resource.{theme_name.lower()}.fixture"
                )
            }
        ]
        path = root / specification["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document), encoding="utf-8")


def simulator_selection(role: str, udid: str) -> dict:
    identifier = {
        "iphone": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        "ipad": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
    }[role]
    policy = destination_policy.policy_for_device_type(identifier, role)
    return destination_policy.build_selection(
        role,
        {"udid": udid, "name": f"{role} fixture", "deviceTypeIdentifier": identifier},
        {
            "identifier": identifier,
            "name": policy["expectedModelName"],
            "pixelDimensions": policy["expectedPixelDimensions"],
            "scale": policy["expectedScale"],
        },
    )


def bind_content_seed(record: dict) -> None:
    content_seed = {
        "fixtureID": record["stateSeed"],
        "fixtureVersion": 1,
        "surface": record["surface"],
        "plaintext": None,
        "glyphTokens": [],
        "sender": {"name": None},
        "cipher": {"id": None, "name": None},
        "timestamp": "2023-11-14T22:13:20Z",
        "selectedResources": {
            "codexID": record["codexID"],
            "relicID": record["relicID"],
            "sealID": record["sealID"],
            "frameID": record["frameID"],
        },
        "progression": {
            "ownershipState": None,
            "achievementID": None,
            "completedRuleCount": None,
            "requiredRuleCount": None,
        },
        "locale": "en_US_POSIX",
        "calendar": "gregorian",
        "timeZone": "GMT",
        "accessibility": {
            "increasedContrast": False,
            "reduceMotion": False,
            "dynamicTypeSize": "large",
        },
    }
    record["contentSeed"] = content_seed
    record["stateSeedSHA256"] = indexer.canonical_json_sha256(content_seed)


class ThemeFidelityCaptureHarnessTests(unittest.TestCase):
    def test_comparator_argv_contains_one_script_and_canonical_manifest_is_fixed(self) -> None:
        candidate = Path("/tmp/capture.png")
        capture_record = Path("/tmp/capture.capture.json")
        output = Path("/tmp/comparison")
        command = capture_runner.comparison_command(
            ROOT, "comparison-id", candidate, capture_record, output
        )
        comparator = str(ROOT / "scripts/compare-theme-captures.py")
        self.assertEqual(command[:2], [capture_runner.sys.executable, comparator])
        self.assertEqual(command.count(comparator), 1)
        self.assertEqual(
            command[command.index("--capture-record") + 1], str(capture_record)
        )
        self.assertEqual(
            capture_runner.resolve_authority_manifest(
                ROOT, capture_runner.DEFAULT_AUTHORITY_MANIFEST
            ),
            (ROOT / capture_runner.DEFAULT_AUTHORITY_MANIFEST).resolve(),
        )
        with self.assertRaisesRegex(capture_runner.CaptureError, "canonical"):
            capture_runner.resolve_authority_manifest(ROOT, Path("alternate.json"))
        self.assertEqual(
            capture_runner.comparison_region_policy(
                {"policy": "responsive-regions-v1", "mask": None}
            ),
            "responsive-regions-v1",
        )
        self.assertEqual(
            capture_runner.comparison_region_policy({"mask": None}), "full-frame"
        )
        with self.assertRaisesRegex(capture_runner.CaptureError, "unsupported"):
            capture_runner.comparison_region_policy({"policy": "unknown"})
        with mock.patch.object(capture_runner.sys, "stderr", io.StringIO()):
            with self.assertRaises(SystemExit):
                capture_runner.parse_arguments(
                    [
                        "--phase",
                        "final",
                        "--output-root",
                        "/tmp/evidence",
                        "--comparison-index",
                        "/tmp/prebuilt.json",
                    ]
                )

    def test_generated_comparison_run_binds_all_400_invocations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            captures = root / "captures"
            evidence = root / "evidence"
            captures.mkdir()
            evidence.mkdir()
            matrix = root / "matrix.json"
            matrix.write_text("{}", encoding="utf-8")
            entries = [
                {"png": f"capture-{ordinal:03d}.png"}
                for ordinal in range(400)
            ]
            plans = []
            for ordinal, entry in enumerate(entries):
                capture = captures / entry["png"]
                capture.write_bytes(f"capture-{ordinal}".encode("utf-8"))
                capture.with_suffix(".capture.json").write_text(
                    json.dumps({"ordinal": ordinal}), encoding="utf-8"
                )
                plans.append(
                    {
                        "id": f"comparison-{ordinal:03d}",
                        "capture": entry["png"],
                        "reference": "goldens/reference.png",
                        "mask": None,
                        "focalRegion": [0, 0, 8, 8],
                    }
                )
            authority_manifest = root / "asset-manifest.json"
            authority_manifest.write_text(
                json.dumps({"comparisons": plans}), encoding="utf-8"
            )

            class FakeIndexer:
                @staticmethod
                def load_matrix(path: Path) -> dict:
                    return {}

                @staticmethod
                def expected_entries(document: dict) -> list[dict]:
                    return entries

            def fake_comparator(command: list[str], **kwargs):
                output_stem = Path(command[command.index("--output") + 1])
                Path(str(output_stem) + ".json").write_text(
                    json.dumps({"result": "PASS"}), encoding="utf-8"
                )
                Image.new("RGB", (8, 8), (0, 0, 0)).save(
                    Path(str(output_stem) + ".heatmap.png")
                )
                return mock.Mock(returncode=0)

            output = evidence / "comparison-index.json"
            log = evidence / "comparisons.log"
            with mock.patch.object(
                capture_runner.subprocess, "run", side_effect=fake_comparator
            ):
                result = capture_runner.generate_comparison_index(
                    root,
                    matrix,
                    captures,
                    authority_manifest,
                    output,
                    log,
                    FakeIndexer,
                )

            self.assertEqual(result["invocationCount"], 400)
            self.assertEqual(len(result["invocations"]), 400)
            self.assertEqual(
                result["invocationsSHA256"],
                capture_runner.canonical_json_sha256(result["invocations"]),
            )
            self.assertTrue(
                all(
                    "--capture-record" in invocation["command"]
                    and invocation["result"] == "pass"
                    and invocation["exitCode"] == 0
                    for invocation in result["invocations"]
                )
            )
            generated = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(len(generated["mappings"]), 400)
            self.assertEqual(
                {item["capture"] for item in result["invocations"]},
                {item["capture"] for item in generated["mappings"]},
            )

    def test_hosted_capture_argv_does_not_disable_signing(self) -> None:
        jobs = capture_runner.hosted_capture_jobs(
            "baseline",
            "iphone-id",
            "ipad-id",
            Path("/tmp/derived"),
            Path("/tmp/results"),
        )
        self.assertEqual([label for label, _ in jobs], ["iphone", "ipad", "macos"])
        for _, command in jobs:
            self.assertNotIn("CODE_SIGNING_ALLOWED=NO", command)
            self.assertEqual(command[:2], ["xcodebuild", "test"])
            self.assertIn("RUNESCRIBE_THEME_FIDELITY_PHASE=baseline", command)
        with self.assertRaisesRegex(capture_runner.CaptureError, "phase"):
            capture_runner.hosted_capture_jobs(
                "unknown",
                "iphone-id",
                "ipad-id",
                Path("/tmp/derived"),
                Path("/tmp/results"),
            )

    def test_simulator_selection_prefers_target_class_and_records_substitution(self) -> None:
        exact_id = "exact-phone"
        substitute_id = "substitute-phone"
        exact_identifier = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
        substitute_identifier = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
        devices = [
            {
                "udid": substitute_id,
                "name": "Substitute",
                "deviceTypeIdentifier": substitute_identifier,
            },
            {
                "udid": exact_id,
                "name": "Target",
                "deviceTypeIdentifier": exact_identifier,
            },
        ]

        def catalog_entry(identifier: str) -> dict:
            policy = destination_policy.policy_for_device_type(identifier, "iphone")
            return {
                "identifier": identifier,
                "name": policy["expectedModelName"],
                "pixelDimensions": policy["expectedPixelDimensions"],
                "scale": policy["expectedScale"],
            }

        catalog = {
            identifier: catalog_entry(identifier)
            for identifier in (exact_identifier, substitute_identifier)
        }
        with mock.patch.object(
            capture_runner, "booted_simulators", return_value=devices
        ), mock.patch.object(
            capture_runner, "simulator_device_types", return_value=catalog
        ):
            selected = capture_runner.choose_simulator(ROOT, None, "iphone")
            self.assertEqual(selected["udid"], exact_id)
            self.assertEqual(selected["expectedModelName"], "iPhone 17 Pro")
            self.assertFalse(selected["substitution"]["used"])
            with self.assertRaisesRegex(capture_runner.CaptureError, "lesser substitute"):
                capture_runner.choose_simulator(ROOT, substitute_id, "iphone")

        with mock.patch.object(
            capture_runner, "booted_simulators", return_value=devices[:1]
        ), mock.patch.object(
            capture_runner, "simulator_device_types", return_value=catalog
        ):
            selected = capture_runner.choose_simulator(ROOT, None, "iphone")
            self.assertEqual(selected["expectedModelName"], "iPhone 16 Pro")
            self.assertTrue(selected["substitution"]["used"])
            self.assertEqual(
                selected["substitution"]["reason"], "target-model-class-not-booted"
            )

    def test_destination_policy_rejects_arbitrary_family_and_dimension_drift(self) -> None:
        iphone = simulator_selection("iphone", "iphone-id")
        ipad = simulator_selection("ipad", "ipad-id")
        arbitrary = json.loads(json.dumps(iphone))
        arbitrary["deviceTypeIdentifier"] = (
            "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation"
        )
        with self.assertRaisesRegex(destination_policy.DestinationPolicyError, "not an approved"):
            destination_policy.validate_selection(arbitrary, "iphone")

        by_role = {
            "iphone": {"destinationSelection": iphone},
            "ipad": {"destinationSelection": ipad},
        }
        captures = [
            {
                "destination": "iPhone portrait",
                "pixelWidth": 1206,
                "pixelHeight": 2622,
                "scale": 3,
            },
            {
                "destination": "iPad portrait",
                "pixelWidth": 2064,
                "pixelHeight": 2752,
                "scale": 2,
            },
        ]
        indexer.validate_destination_selection_dimensions(by_role, captures)
        captures[0]["pixelWidth"] = 1179
        with self.assertRaisesRegex(indexer.IndexError, "exact selected model"):
            indexer.validate_destination_selection_dimensions(by_role, captures)

    def test_controlling_matrix_expands_to_exact_required_set(self) -> None:
        matrix_path = (
            ROOT
            / "docs/verification/theme-fidelity-v4/Golden-Screenshot-Matrix.json"
        )
        matrix = indexer.load_matrix(matrix_path)
        entries = indexer.expected_entries(matrix)

        self.assertEqual(len(entries), 400)
        self.assertEqual(len({entry["png"] for entry in entries}), 400)
        self.assertEqual(len({entry["record"] for entry in entries}), 400)
        self.assertEqual(
            {entry["destination"] for entry in entries},
            set(indexer.DESTINATION_SLUGS),
        )
        self.assertEqual(
            {entry["themeName"] for entry in entries},
            set(indexer.EXPECTED_THEMES),
        )

    def test_matrix_hash_is_byte_locked(self) -> None:
        matrix_path = (
            ROOT
            / "docs/verification/theme-fidelity-v4/Golden-Screenshot-Matrix.json"
        )
        self.assertEqual(indexer.sha256_file(matrix_path), indexer.MATRIX_SHA256)

    def test_production_integrity_manifests_map_all_five_theme_codex_pairs(self) -> None:
        resource_ids = indexer.load_theme_resource_manifests(ROOT)
        self.assertEqual(
            set(resource_ids),
            {
                (theme_name, codex_id)
                for theme_name, (_, codex_id) in indexer.EXPECTED_THEMES.items()
            },
        )
        self.assertIn(
            "resource.relic.norse.runestone.weathered.art",
            resource_ids[("Norse", "codex.norse")],
        )
        self.assertIn(
            "resource.background.moonleaf.moonlit-canopy.output.background-static-base",
            resource_ids[("Moonleaf", "codex.moonleaf")],
        )
        self.assertNotIn(
            "resource.relic.norse.runestone.weathered.art",
            resource_ids[("Moonleaf", "codex.moonleaf")],
        )

    def test_production_integrity_manifest_schema_and_resource_ids_are_strict(self) -> None:
        mutations = (
            (
                "schema",
                lambda document, specification: document.__setitem__(
                    "schemaVersion", "2.0"
                ),
                "schema is invalid",
            ),
            (
                "empty",
                lambda document, specification: document[
                    specification["collectionKey"]
                ][0].__setitem__(specification["resourceIDKey"], " "),
                "invalid resourceID",
            ),
            (
                "duplicate",
                lambda document, specification: document[
                    specification["collectionKey"]
                ].append(dict(document[specification["collectionKey"]][0])),
                "repeats resource IDs",
            ),
        )
        for label, mutate, error_pattern in mutations:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                write_minimal_theme_resource_manifests(root)
                specification = indexer.THEME_RESOURCE_MANIFESTS["Moonleaf"]
                path = root / specification["path"]
                document = json.loads(path.read_text(encoding="utf-8"))
                mutate(document, specification)
                path.write_text(json.dumps(document), encoding="utf-8")
                with self.assertRaisesRegex(indexer.IndexError, error_pattern):
                    indexer.load_theme_resource_manifests(root)

    def test_content_seed_shape_digest_and_top_level_bindings_are_exact(self) -> None:
        record = {
            "stateSeed": "fixture-01",
            "surface": "compose-short",
            "codexID": "codex.norse",
            "relicID": "relic.norse.runestone-tablet",
            "sealID": None,
            "frameID": None,
        }
        bind_content_seed(record)
        record["contentSeed"]["glyphTokens"] = ["ᚠ", "/"]
        record["stateSeedSHA256"] = indexer.canonical_json_sha256(
            record["contentSeed"]
        )
        expected = {
            "record": "norse--compose-short--iphone-portrait.capture.json",
            "surface": "compose-short",
        }
        self.assertEqual(
            indexer.validate_content_seed(record, expected),
            record["stateSeedSHA256"],
        )

        mutated = json.loads(json.dumps(record))
        mutated["contentSeed"]["unexpected"] = None
        with self.assertRaisesRegex(indexer.IndexError, "contentSeed keys"):
            indexer.validate_content_seed(mutated, expected)

        mutated = json.loads(json.dumps(record))
        mutated["contentSeed"]["plaintext"] = "changed"
        with self.assertRaisesRegex(indexer.IndexError, "canonical contentSeed"):
            indexer.validate_content_seed(mutated, expected)

        mutated = json.loads(json.dumps(record))
        mutated["sealID"] = "seal.norse.valknut"
        with self.assertRaisesRegex(indexer.IndexError, "sealID differs"):
            indexer.validate_content_seed(mutated, expected)

    def test_capture_record_rejects_identity_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            png = Path(temporary) / "capture.png"
            png.write_bytes(b"not-decoded-in-this-test")
            digest = hashlib.sha256(png.read_bytes()).hexdigest()
            expected = {
                "themeName": "Moonleaf",
                "surface": "workspace-empty",
                "destination": "iPhone portrait",
                "record": "moonleaf--workspace-empty--iphone-portrait.capture.json",
                "png": "moonleaf--workspace-empty--iphone-portrait.png",
            }
            record = {
                "schemaVersion": "1.0",
                "stateSeed": "theme-fidelity-v4-seed-01",
                "stateID": "workspace-empty",
                "themeName": "Moonleaf",
                "themeID": "theme.moonleaf.production",
                "codexID": "codex.moonleaf",
                "relicID": "relic.moonleaf.tablet",
                "sealID": "seal.moonleaf.crescentleaf",
                "frameID": None,
                "surface": "workspace-empty",
                "destination": "iPhone portrait",
                "pointWidth": 390.0,
                "pointHeight": 844.0,
                "scale": 1.0,
                "pixelWidth": 390,
                "pixelHeight": 844,
                "visualPlanRevision": 1,
                "pngSHA256": digest,
                "byteCount": png.stat().st_size,
            }
            bind_content_seed(record)
            findings = validate_capture_record(record, expected, png)
            self.assertEqual(
                {finding["code"] for finding in findings},
                {
                    "element-frames-unverified",
                    "rendered-resources-unverified",
                    "layout-clipping-unverified",
                },
            )
            record["renderedResourceIDs"] = [
                "resource.background.moonleaf.moonlit-canopy.output.background-static-base"
            ]
            record["viewportAssertions"] = {
                "requiredElementCount": 1,
                "requiredElementIDs": ["theme-fidelity.viewport"],
                "clippedElementIDs": [],
            }
            record["elementFrames"] = {
                "coordinateOrigin": "top-left",
                "units": "pixels",
                "scale": 1.0,
                "frames": [
                    {
                        "elementID": "theme-fidelity.viewport",
                        "x": 0.0,
                        "y": 0.0,
                        "width": 390.0,
                        "height": 844.0,
                    }
                ],
            }
            self.assertEqual(validate_capture_record(record, expected, png), [])
            record["renderedResourceIDs"] = [
                "resource.relic.norse.runestone.weathered.art"
            ]
            with self.assertRaisesRegex(
                indexer.IndexError, "absent from the active theme"
            ):
                validate_capture_record(record, expected, png)
            record["renderedResourceIDs"] = [
                "resource.background.moonleaf.moonlit-canopy.output.background-static-base"
            ]
            record["viewportAssertions"]["requiredElementCount"] = 2
            with self.assertRaisesRegex(indexer.IndexError, "does not match"):
                validate_capture_record(record, expected, png)
            record["viewportAssertions"]["requiredElementCount"] = 1
            record["viewportAssertions"]["requiredElementIDs"] = [
                "theme-fidelity.viewport",
                "artifact.preview",
            ]
            record["viewportAssertions"]["requiredElementCount"] = 2
            with self.assertRaisesRegex(indexer.IndexError, "sorted unique"):
                validate_capture_record(record, expected, png)
            record["viewportAssertions"]["requiredElementIDs"] = [
                "artifact.preview",
                "theme-fidelity.viewport",
            ]
            record["viewportAssertions"]["clippedElementIDs"] = [
                "theme-fidelity.viewport",
                "artifact.preview",
            ]
            with self.assertRaisesRegex(indexer.IndexError, "clippedElementIDs is invalid"):
                validate_capture_record(record, expected, png)
            record["viewportAssertions"]["clippedElementIDs"] = []
            with self.assertRaisesRegex(indexer.IndexError, "lack attested frames"):
                validate_capture_record(record, expected, png)
            record["viewportAssertions"]["requiredElementCount"] = 1
            record["viewportAssertions"]["requiredElementIDs"] = [
                "theme-fidelity.viewport"
            ]
            record["viewportAssertions"]["clippedElementIDs"] = ["artifact.preview"]
            with self.assertRaisesRegex(indexer.IndexError, "subset"):
                validate_capture_record(record, expected, png)
            record["viewportAssertions"]["clippedElementIDs"] = []
            record["elementFrames"]["frames"][0]["width"] = 0
            with self.assertRaisesRegex(indexer.IndexError, "elementFrames width"):
                validate_capture_record(record, expected, png)
            record["elementFrames"]["frames"][0]["width"] = 390.0
            record["elementFrames"]["frames"][0]["x"] = 2.0
            with self.assertRaisesRegex(indexer.IndexError, "viewport differs"):
                validate_capture_record(record, expected, png)
            record["elementFrames"]["frames"][0]["x"] = 0.0
            record["themeID"] = "theme.wrong"
            with self.assertRaisesRegex(indexer.IndexError, "themeID"):
                validate_capture_record(record, expected, png)

    def test_image_quality_diagnoses_blank_and_accepts_detailed_capture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            blank = root / "blank.png"
            Image.new("RGB", (128, 160), (22, 28, 36)).save(blank)
            record = {"pixelWidth": 128, "pixelHeight": 160}
            blank_metrics = indexer.analyze_image(blank, record)
            self.assertIn(
                "blank-luminance",
                {finding["code"] for finding in blank_metrics["diagnostics"]},
            )

            detailed = root / "detailed.png"
            x = np.arange(128, dtype=np.uint8)[None, :]
            y = np.arange(160, dtype=np.uint8)[:, None]
            red = np.broadcast_to((x * 3) % 255, (160, 128))
            green = np.broadcast_to((y * 5) % 255, (160, 128))
            blue = ((red.astype(np.uint16) + green.astype(np.uint16)) % 255).astype(
                np.uint8
            )
            Image.fromarray(np.dstack([red, green, blue])).save(detailed)
            metrics = indexer.analyze_image(detailed, record)
            self.assertGreaterEqual(metrics["uniqueSampleColors"], 48)
            self.assertGreater(metrics["edgeFraction"], 0.01)
            self.assertEqual(metrics["diagnostics"], [])

    def test_received_safe_preview_evidence_is_phase_diagnostic_and_frame_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            png = Path(temporary) / "received.png"
            png.write_bytes(b"received-capture")
            digest = hashlib.sha256(png.read_bytes()).hexdigest()
            expected = {
                "themeName": "Norse",
                "surface": "received-cipher",
                "destination": "iPhone portrait",
                "record": "norse--received-cipher--iphone-portrait.capture.json",
                "png": "norse--received-cipher--iphone-portrait.png",
            }
            record = {
                "schemaVersion": "1.0",
                "stateSeed": "theme-fidelity-v4-seed-01",
                "stateID": "received-cipher",
                "themeName": "Norse",
                "themeID": "theme.norse.base",
                "codexID": "codex.norse",
                "relicID": "relic.norse.runestone-tablet",
                "sealID": "seal.norse.valknut",
                "frameID": None,
                "surface": "received-cipher",
                "destination": "iPhone portrait",
                "pointWidth": 390.0,
                "pointHeight": 844.0,
                "scale": 1.0,
                "pixelWidth": 390,
                "pixelHeight": 844,
                "visualPlanRevision": 1,
                "pngSHA256": digest,
                "byteCount": png.stat().st_size,
                "renderedResourceIDs": [
                    "resource.background.norse.forge.static",
                    "resource.relic.norse.runestone.weathered.art",
                ],
                "viewportAssertions": {
                    "requiredElementCount": 2,
                    "requiredElementIDs": [
                        "received.safe-preview",
                        "theme-fidelity.viewport",
                    ],
                    "clippedElementIDs": [],
                },
                "elementFrames": {
                    "coordinateOrigin": "top-left",
                    "units": "pixels",
                    "scale": 1.0,
                    "frames": [
                        {
                            "elementID": "received.safe-preview",
                            "x": 20.0,
                            "y": 200.0,
                            "width": 350.0,
                            "height": 262.5,
                        },
                        {
                            "elementID": "theme-fidelity.viewport",
                            "x": 0.0,
                            "y": 0.0,
                            "width": 390.0,
                            "height": 844.0,
                        },
                    ],
                },
                "safePreviewEvidence": {
                    "status": "valid",
                    "byteCount": 100,
                    "sha256": "a" * 64,
                    "resourceIDs": [
                        "resource.relic.norse.runestone.weathered.art"
                    ],
                    "decodedPreviewElementID": "received.safe-preview",
                    "failureCode": None,
                },
            }
            bind_content_seed(record)
            self.assertEqual(validate_capture_record(record, expected, png), [])

            record["safePreviewEvidence"]["resourceIDs"] = [
                "resource.font.norse.noto-sans-runic"
            ]
            with self.assertRaisesRegex(indexer.IndexError, "subset of renderedResourceIDs"):
                validate_capture_record(record, expected, png)
            record["safePreviewEvidence"]["resourceIDs"] = [
                "resource.background.moonleaf.moonlit-canopy.output.background-static-base"
            ]
            with self.assertRaisesRegex(
                indexer.IndexError, "absent from the active theme"
            ):
                validate_capture_record(record, expected, png)
            record["safePreviewEvidence"]["resourceIDs"] = [
                "resource.relic.norse.runestone.weathered.art"
            ]

            record["elementFrames"]["frames"] = record["elementFrames"]["frames"][1:]
            record["viewportAssertions"] = {
                "requiredElementCount": 1,
                "requiredElementIDs": ["theme-fidelity.viewport"],
                "clippedElementIDs": [],
            }
            findings = validate_capture_record(record, expected, png)
            self.assertIn(
                "received-preview-not-rendered",
                {finding["code"] for finding in findings},
            )

            record["safePreviewEvidence"] = {
                "status": "generation-failed",
                "byteCount": None,
                "sha256": None,
                "resourceIDs": [],
                "decodedPreviewElementID": None,
                "failureCode": "preview-generation-failed",
            }
            findings = validate_capture_record(record, expected, png)
            self.assertIn(
                "received-preview-generation-failed",
                {finding["code"] for finding in findings},
            )

    def test_baseline_diagnostics_are_nonblocking_and_final_blocks(self) -> None:
        findings = [indexer.diagnostic("blank-luminance", "capture.png", "blank")]
        indexer.enforce_final_diagnostics("baseline", findings, "capture")
        with self.assertRaisesRegex(indexer.IndexError, "final capture diagnostic"):
            indexer.enforce_final_diagnostics("final", findings, "capture")

    def test_material_state_duplicate_is_rejected(self) -> None:
        captures = []
        normalized = {}
        for theme in indexer.EXPECTED_THEMES:
            for destination in indexer.DESTINATION_SLUGS:
                for group in indexer.MATERIAL_GROUPS:
                    for surface in group:
                        name = f"{theme}-{destination}-{surface}.png"
                        captures.append(
                            {
                                "themeName": theme,
                                "destination": destination,
                                "surface": surface,
                                "png": name,
                            }
                        )
                        normalized[name] = np.zeros((32, 32), dtype=np.float32)
        with self.assertRaisesRegex(indexer.IndexError, "perceptually duplicated"):
            indexer.validate_material_uniqueness(captures, normalized)

        findings = indexer.material_uniqueness_findings(captures, normalized)
        self.assertGreater(len(findings), 0)
        self.assertIn("perceptually duplicated", findings[0])

    def test_extractor_accepts_only_canonical_attachment_names(self) -> None:
        self.assertIsNotNone(
            extractor.CAPTURE_NAME.fullmatch(
                "gloamthorn--vault-selected--macos-resized.png"
            )
        )
        self.assertIsNotNone(
            extractor.CAPTURE_NAME.fullmatch(
                "norse--compose-long--iphone-portrait.capture.json"
            )
        )
        self.assertIsNone(
            extractor.CAPTURE_NAME.fullmatch(
                "../norse--compose-long--iphone-portrait.png"
            )
        )

    def test_extractor_recovers_xcresult_decorated_names_without_ambiguity(self) -> None:
        suffix = "_0_570E0EB5-19B7-4236-8332-85D14C912D5B"
        self.assertEqual(
            extractor.canonical_attachment_name(
                f"norse--large-text--macos-resized{suffix}.png"
            ),
            "norse--large-text--macos-resized.png",
        )
        self.assertEqual(
            extractor.canonical_attachment_name(
                f"moonleaf--vault-owned--ipad-portrait.capture{suffix}.json"
            ),
            "moonleaf--vault-owned--ipad-portrait.capture.json",
        )
        self.assertIsNone(
            extractor.canonical_attachment_name(
                f"norse--large-text--macos-resized{suffix}{suffix}.png"
            )
        )
        self.assertIsNone(
            extractor.canonical_attachment_name(
                "norse--large-text--macos-resized_0_not-a-uuid.png"
            )
        )

    def test_attachment_content_type_is_validated_and_recorded_as_uti(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            png = root / "capture.png"
            png.write_bytes(b"\x89PNG\r\n\x1a\nrest")
            record = root / "capture.capture.json"
            record.write_text("{}", encoding="utf-8")
            self.assertEqual(
                extractor.validate_attachment_content(png, "norse--mastery--iphone-portrait.png"),
                "public.png",
            )
            self.assertEqual(
                extractor.validate_attachment_content(
                    record, "norse--mastery--iphone-portrait.capture.json"
                ),
                "public.json",
            )
            png.write_bytes(b"not-png")
            with self.assertRaisesRegex(extractor.ExtractionError, "public.png"):
                extractor.validate_attachment_content(
                    png, "norse--mastery--iphone-portrait.png"
                )

    def test_xcresult_summary_requires_exact_passed_single_test(self) -> None:
        binding = extractor.BundleBinding(
            "iphone",
            Path("result.xcresult"),
            "device-id",
            "iPhone 17 Pro",
            simulator_selection("iphone", "device-id"),
        )
        summary = {
            "result": "Passed",
            "totalTestCount": 1,
            "passedTests": 1,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "environmentDescription": "RuneScrib-iOS",
            "startTime": 1.0,
            "finishTime": 2.0,
            "devicesAndConfigurations": [
                {
                    "passedTests": 1,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "device": {
                        "deviceId": "device-id",
                        "deviceName": "iPhone Test",
                        "modelName": "iPhone 17 Pro",
                        "osVersion": "1.0",
                        "osBuildNumber": "1A1",
                        "platform": "iOS Simulator",
                        "architecture": "arm64",
                    },
                    "testPlanConfiguration": {
                        "configurationName": "Test Scheme Action"
                    },
                }
            ],
        }
        provenance = extractor.validate_summary(binding, summary)
        self.assertEqual(provenance["device"]["deviceId"], "device-id")
        wrong_model = json.loads(json.dumps(summary))
        wrong_model["devicesAndConfigurations"][0]["device"]["modelName"] = "iPhone 16 Pro"
        with self.assertRaisesRegex(extractor.ExtractionError, "exact selected model"):
            extractor.validate_summary(binding, wrong_model)
        summary["result"] = "Failed"
        with self.assertRaisesRegex(extractor.ExtractionError, "result"):
            extractor.validate_summary(binding, summary)

        mac_summary = json.loads(json.dumps(summary))
        mac_summary["result"] = "Passed"
        mac_device = mac_summary["devicesAndConfigurations"][0]["device"]
        mac_device.update(
            {
                "deviceId": "mac-id",
                "deviceName": "Mac Test",
                "modelName": "Mac Test",
                "platform": "macOS",
                "architecture": "x86_64",
            }
        )
        with self.assertRaisesRegex(extractor.ExtractionError, "architecture"):
            extractor.validate_summary(
                extractor.BundleBinding("macos", Path("mac.xcresult")), mac_summary
            )

    def test_toolchain_report_rejects_non_arm64_host(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "tool"
            executable.write_bytes(b"tool")
            executable_record = {
                "path": str(executable),
                "sha256": indexer.sha256_file(executable),
            }
            document = {
                "schemaVersion": "1.0",
                "xcodebuildVersion": "Xcode 1",
                "swiftVersion": "Swift 1",
                "macOS": {"productVersion": "1", "buildVersion": "1A1"},
                "architecture": "arm64",
                "pythonVersion": "3",
                "executables": {
                    key: dict(executable_record)
                    for key in ("python", "swiftc", "xcodebuild", "xcresulttool", "xcrun")
                },
            }
            path = root / "toolchain.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            indexer.validate_toolchain_report(path)
            document["architecture"] = "x86_64"
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(indexer.IndexError, "arm64"):
                indexer.validate_toolchain_report(path)

    def test_extractor_rejects_decorated_names_that_collapse_to_duplicate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bindings = [
                extractor.BundleBinding(
                    "iphone",
                    root / "iphone.xcresult",
                    "iphone-id",
                    "iPhone 17 Pro",
                    simulator_selection("iphone", "iphone-id"),
                ),
                extractor.BundleBinding(
                    "ipad",
                    root / "ipad.xcresult",
                    "ipad-id",
                    "iPad Pro 13-inch (M5)",
                    simulator_selection("ipad", "ipad-id"),
                ),
                extractor.BundleBinding("macos", root / "macos.xcresult"),
            ]
            for binding in bindings:
                binding.path.mkdir()
            output = root / "captures"

            def fake_summary(bundle: Path):
                role = bundle.stem
                device_id = {"iphone": "iphone-id", "ipad": "ipad-id", "macos": "mac-id"}[role]
                model = {
                    "iphone": "iPhone 17 Pro",
                    "ipad": "iPad Pro 13-inch (M5)",
                    "macos": "Mac Test",
                }[role]
                platform_name = "macOS" if role == "macos" else "iOS Simulator"
                return {
                    "result": "Passed",
                    "totalTestCount": 1,
                    "passedTests": 1,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "environmentDescription": "test environment",
                    "startTime": 1.0,
                    "finishTime": 2.0,
                    "devicesAndConfigurations": [
                        {
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
                                "platform": platform_name,
                                "architecture": "arm64",
                            },
                            "testPlanConfiguration": {
                                "configurationName": "Test Scheme Action"
                            },
                        }
                    ],
                }

            def fake_export(bundle: Path, exported: Path):
                exported.mkdir(parents=True)
                role = bundle.stem
                if role == "iphone":
                    attachment_names = ["capture-1.png", "capture-2.png"]
                    canonical = "norse--workspace-empty--iphone-portrait"
                else:
                    attachment_names = []
                    canonical = "unused"
                attachments = []
                for ordinal, exported_name in enumerate(attachment_names):
                    (exported / exported_name).write_bytes(b"\x89PNG\r\n\x1a\n")
                    attachments.append(
                        {
                            "suggestedHumanReadableName": (
                                f"{canonical}_{ordinal}_"
                                "570E0EB5-19B7-4236-8332-85D14C912D5B.png"
                            ),
                            "exportedFileName": exported_name,
                            "configurationName": "Test Scheme Action",
                            "deviceName": {
                                "iphone": "iPhone 17 Pro",
                                "ipad": "iPad Pro 13-inch (M5)",
                                "macos": "Mac Test",
                            }[role],
                            "deviceId": f"{role}-id",
                            "isAssociatedWithFailure": False,
                            "timestamp": 1.0,
                        }
                    )
                manifest = [
                    {
                        "testIdentifier": extractor.EXPECTED_TEST_IDENTIFIER,
                        "testIdentifierURL": "test://theme-fidelity",
                        "attachments": attachments,
                    }
                ]
                (exported / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
                return manifest

            with mock.patch.object(extractor, "xcresult_summary", side_effect=fake_summary), mock.patch.object(
                extractor, "export_attachments", side_effect=fake_export
            ):
                with self.assertRaisesRegex(
                    extractor.ExtractionError, "duplicate canonical attachment name"
                ):
                    extractor.extract(bindings, output)

    def test_source_manifests_must_be_exactly_equal(self) -> None:
        manifest = {
            "schemaVersion": "1.0",
            "sourceSHA": "a" * 40,
            "fileCount": 1,
            "aggregateSHA256": "b" * 64,
            "gitStatusSHA256": "c" * 64,
            "isClean": True,
            "files": [
                {
                    "path": "file.swift",
                    "bytes": 1,
                    "sha256": "d" * 64,
                    "executable": False,
                }
            ],
        }
        indexer.validate_source_manifest_pair(manifest, json.loads(json.dumps(manifest)))
        changed = json.loads(json.dumps(manifest))
        changed["files"][0]["sha256"] = "e" * 64
        with self.assertRaisesRegex(indexer.IndexError, "source changed"):
            indexer.validate_source_manifest_pair(manifest, changed)

        dirty = json.loads(json.dumps(manifest))
        dirty["isClean"] = False
        with self.assertRaisesRegex(indexer.IndexError, "dirty source tree"):
            indexer.validate_source_manifest_pair(dirty, dirty)

    def test_command_provenance_preserves_argument_boundaries(self) -> None:
        command = ["xcodebuild", "test", "-destination", "platform=macOS,arch=arm64"]
        self.assertEqual(indexer.validate_commands([json.dumps(command)]), [command])
        with self.assertRaisesRegex(indexer.IndexError, "JSON argument array"):
            indexer.validate_commands(["xcodebuild test"])

    def test_runtime_warning_diagnostics_are_bound_to_hashed_logs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "iphone.log"
            log.write_text(
                "Unbalanced calls to begin/end appearance transitions for <UIViewController>\n"
                "duplicate_visual_classes=19\n",
                encoding="utf-8",
            )
            findings, records = indexer.runtime_diagnostics([log])
            self.assertEqual(
                {finding["code"] for finding in findings},
                {"unbalanced-appearance-transition", "duplicate-visual-class"},
            )
            self.assertEqual(records[0]["sha256"], indexer.sha256_file(log))

    def test_final_comparison_gate_requires_400_digest_bound_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            capture_root = root / "captures"
            evidence_root = root / "evidence"
            reports_root = evidence_root / "reports"
            authority_root = root / "authority"
            (authority_root / "goldens").mkdir(parents=True)
            capture_root.mkdir()
            reports_root.mkdir(parents=True)
            reference = authority_root / "goldens/reference.png"
            Image.new("RGB", (8, 8), (40, 80, 120)).save(reference)
            reference_digest = indexer.sha256_file(reference)

            matrix = indexer.load_matrix(
                ROOT / "docs/verification/theme-fidelity-v4/Golden-Screenshot-Matrix.json"
            )
            entries = indexer.expected_entries(matrix)

            def synthetic_record(entry: dict) -> dict:
                record = {
                    "stateSeed": "theme-fidelity-v4-seed-01",
                    "surface": entry["surface"],
                    "codexID": indexer.EXPECTED_THEMES[entry["themeName"]][1],
                    "relicID": "relic.fixture",
                    "sealID": None,
                    "frameID": None,
                }
                bind_content_seed(record)
                return record

            plans = [
                {
                    "id": f"comparison-{ordinal:03d}",
                    "capture": entry["png"],
                    "reference": "goldens/reference.png",
                    "mask": None,
                    "focalRegion": [0, 0, 8, 8],
                }
                for ordinal, entry in enumerate(entries)
            ]
            plans[1].pop("mask")
            responsive_crop = [0, 0, 8, 8]
            responsive_seed_digest = synthetic_record(entries[0])["stateSeedSHA256"]
            plans[0] = {
                "id": "comparison-000",
                "capture": entries[0]["png"],
                "policy": "responsive-regions-v1",
                "stateSeedSHA256": responsive_seed_digest,
                "regions": [
                    {
                        "id": "artifact",
                        "reference": "goldens/reference.png",
                        "sourceCrop": responsive_crop,
                        "sourceCropSHA256": indexer.source_crop_sha256(
                            reference, responsive_crop
                        ),
                        "candidateElementID": "artifact",
                        "mask": None,
                        "thresholds": dict(indexer.COMPARISON_THRESHOLDS),
                    }
                ],
                "layoutAssertions": {
                    "requiredElementIDs": ["artifact"],
                    "withinViewportElementIDs": ["artifact"],
                    "requireNoClippedElements": True,
                },
            }
            authority = {
                "schemaVersion": "1.0",
                "authorityRoot": "authority",
                "assets": [
                    {
                        "path": "goldens/reference.png",
                        "sha256": reference_digest,
                        "dimensions": [8, 8],
                    }
                ],
                "comparisons": plans,
            }
            authority_manifest = authority_root / "asset-manifest.json"
            authority_manifest.write_text(json.dumps(authority), encoding="utf-8")
            authority_digest = indexer.sha256_file(authority_manifest)

            captures = []
            mappings = []
            passing_metrics = {
                "luminanceSSIM": 1.0,
                "edgeSSIM": 1.0,
                "focalSSIM": 1.0,
                "medianDeltaE": 0.0,
                "p95DeltaE": 0.0,
                "fractionDeltaEAbove20": 0.0,
            }
            passing_checks = {
                key: True for key in indexer.COMPARISON_CHECK_KEYS
            }
            for ordinal, entry in enumerate(entries):
                candidate = capture_root / entry["png"]
                candidate.write_bytes(reference.read_bytes())
                candidate_digest = indexer.sha256_file(candidate)
                capture_record = capture_root / entry["record"]
                record_document = synthetic_record(entry)
                record_document.update(
                    {
                        "schemaVersion": "1.0",
                        "pngSHA256": candidate_digest,
                        "pixelWidth": 8,
                        "pixelHeight": 8,
                        "scale": 1.0,
                    }
                )
                if ordinal == 0:
                    record_document["elementFrames"] = {
                        "coordinateOrigin": "top-left",
                        "units": "pixels",
                        "scale": 1.0,
                        "frames": [
                            {
                                "elementID": "artifact",
                                "x": 0.0,
                                "y": 0.0,
                                "width": 8.0,
                                "height": 8.0,
                            },
                            {
                                "elementID": "theme-fidelity.viewport",
                                "x": 0.0,
                                "y": 0.0,
                                "width": 8.0,
                                "height": 8.0,
                            },
                        ],
                    }
                    record_document["viewportAssertions"] = {
                        "requiredElementCount": 2,
                        "requiredElementIDs": ["artifact", "theme-fidelity.viewport"],
                        "clippedElementIDs": [],
                    }
                state_seed_digest = record_document["stateSeedSHA256"]
                capture_record.write_text(
                    json.dumps(record_document),
                    encoding="utf-8",
                )
                heatmap = reports_root / f"{ordinal:03d}.heatmap.png"
                Image.new("RGB", (8, 8), (0, 0, 0)).save(heatmap)
                report_path = reports_root / f"{ordinal:03d}.json"
                common_report = {
                    "schemaVersion": "1.0",
                    "result": "PASS",
                    "comparisonID": plans[ordinal]["id"],
                    "manifest": authority_manifest.relative_to(root).as_posix(),
                    "manifestSHA256": authority_digest,
                    "candidate": candidate.relative_to(root).as_posix(),
                    "candidateSHA256": candidate_digest,
                    "candidateDimensions": [8, 8],
                    "captureRecord": capture_record.relative_to(root).as_posix(),
                    "captureRecordSHA256": indexer.sha256_file(capture_record),
                    "stateSeedSHA256": state_seed_digest,
                    "heatmap": heatmap.relative_to(root).as_posix(),
                    "metrics": dict(passing_metrics),
                    "thresholds": dict(indexer.COMPARISON_THRESHOLDS),
                    "checks": dict(passing_checks),
                }
                capture = {
                    **record_document,
                    "png": entry["png"],
                    "record": entry["record"],
                    "pngSHA256": candidate_digest,
                    "pixelWidth": 8,
                    "pixelHeight": 8,
                    "comparisonResult": "not-evaluated",
                }
                if ordinal == 0:
                    viewport_ids = ["artifact", "theme-fidelity.viewport"]
                    capture["elementFrames"] = {
                        "coordinateOrigin": "top-left",
                        "units": "pixels",
                        "scale": 1.0,
                        "frames": [
                            {
                                "elementID": "artifact",
                                "x": 0.0,
                                "y": 0.0,
                                "width": 8.0,
                                "height": 8.0,
                            },
                            {
                                "elementID": "theme-fidelity.viewport",
                                "x": 0.0,
                                "y": 0.0,
                                "width": 8.0,
                                "height": 8.0,
                            },
                        ],
                    }
                    capture["viewportAssertions"] = {
                        "requiredElementCount": 2,
                        "requiredElementIDs": viewport_ids,
                        "clippedElementIDs": [],
                    }
                    layout_checks = {
                        "requiredElementsPresent": True,
                        "requiredElementCountAttested": True,
                        "noClippedElements": True,
                        "elementsWithinViewport": True,
                    }
                    report = {
                        **common_report,
                        "comparisonPolicy": "responsive-regions-v1",
                        "elementFrameAttestation": {
                            "coordinateOrigin": "top-left",
                            "units": "pixels",
                            "scale": 1.0,
                            "pixelRoundingPolicy": "outward-to-integral-bounds",
                        },
                        "layoutAssertions": {
                            "requiredElementIDs": ["artifact"],
                            "missingElementIDs": [],
                            "withinViewportElementIDs": ["artifact"],
                            "outsideViewportElementIDs": [],
                            "requireNoClippedElements": True,
                            "attestedRequiredElementCount": 2,
                            "attestedRequiredElementIDs": viewport_ids,
                            "attestedClippedElementIDs": [],
                            "checks": layout_checks,
                        },
                        "regionCount": 1,
                        "passingRegionCount": 1,
                        "regions": [
                            {
                                "id": "artifact",
                                "result": "PASS",
                                "reference": reference.relative_to(root).as_posix(),
                                "referenceSHA256": reference_digest,
                                "referenceDimensions": [8, 8],
                                "sourceCrop": responsive_crop,
                                "sourceCropSHA256": plans[0]["regions"][0][
                                    "sourceCropSHA256"
                                ],
                                "sourceDimensions": [8, 8],
                                "candidateElementID": "artifact",
                                "candidateElementFrame": {
                                    "x": 0.0,
                                    "y": 0.0,
                                    "width": 8.0,
                                    "height": 8.0,
                                },
                                "candidatePixelCrop": [0, 0, 8, 8],
                                "candidateRegionDimensions": [8, 8],
                                "candidateNormalizedToSource": False,
                                "aspectRatioPreserved": True,
                                "approvedMask": None,
                                "approvedMaskSHA256": None,
                                "scoredPixelFraction": 1.0,
                                "focalRegion": [0, 0, 8, 8],
                                "metrics": dict(passing_metrics),
                                "thresholds": dict(indexer.COMPARISON_THRESHOLDS),
                                "checks": dict(passing_checks),
                                "heatmapAtlasFrame": [0, 0, 8, 8],
                            }
                        ],
                        "aggregateChecks": {
                            "allRegionsPass": True,
                            "layoutAssertionsPass": True,
                        },
                        "heatmapAtlas": [
                            {"regionID": "artifact", "frame": [0, 0, 8, 8]}
                        ],
                    }
                    region_policy = "responsive-regions-v1"
                else:
                    report = {
                        **common_report,
                        "reference": reference.relative_to(root).as_posix(),
                        "referenceSHA256": reference_digest,
                        "referenceDimensions": [8, 8],
                        "candidateNormalizedToReference": False,
                        "approvedMask": None,
                        "scoredPixelFraction": 1.0,
                        "focalRegion": [0, 0, 8, 8],
                    }
                    region_policy = "full-frame"
                report_path.write_text(json.dumps(report), encoding="utf-8")
                mappings.append(
                    {
                        "capture": entry["png"],
                        "candidateSHA256": candidate_digest,
                        "comparisonID": plans[ordinal]["id"],
                        "regionPolicy": region_policy,
                        "result": "PASS",
                        "report": report_path.relative_to(evidence_root).as_posix(),
                        "reportSHA256": indexer.sha256_file(report_path),
                        "heatmap": heatmap.relative_to(evidence_root).as_posix(),
                        "heatmapSHA256": indexer.sha256_file(heatmap),
                    }
                )
                captures.append(capture)
            comparison_index = evidence_root / "comparison-index.json"
            comparison_document = {
                "schemaVersion": "1.0",
                "phase": "final",
                "mappings": mappings,
            }
            comparison_index.write_text(json.dumps(comparison_document), encoding="utf-8")
            result = indexer.validate_final_comparisons(
                root,
                capture_root,
                captures,
                comparison_index,
                authority_manifest,
            )
            self.assertEqual(result["mappingCount"], 400)
            self.assertTrue(all(capture["comparisonResult"] == "pass" for capture in captures))

            responsive_report_path = reports_root / "000.json"
            original_responsive_report = json.loads(
                responsive_report_path.read_text(encoding="utf-8")
            )
            original_heatmap = (reports_root / "000.heatmap.png").read_bytes()
            responsive_candidate = capture_root / entries[0]["png"]
            responsive_record = capture_root / entries[0]["record"]
            original_candidate_bytes = responsive_candidate.read_bytes()
            original_record_bytes = responsive_record.read_bytes()
            Image.new("RGB", (8, 8), (0, 0, 0)).save(responsive_candidate)
            mutated_candidate_digest = indexer.sha256_file(responsive_candidate)
            mutated_record = json.loads(original_record_bytes)
            mutated_record["pngSHA256"] = mutated_candidate_digest
            responsive_record.write_text(json.dumps(mutated_record), encoding="utf-8")
            hand_authored_pass = json.loads(json.dumps(original_responsive_report))
            hand_authored_pass["candidateSHA256"] = mutated_candidate_digest
            hand_authored_pass["captureRecordSHA256"] = indexer.sha256_file(
                responsive_record
            )
            responsive_report_path.write_text(
                json.dumps(hand_authored_pass), encoding="utf-8"
            )
            captures[0]["pngSHA256"] = mutated_candidate_digest
            comparison_document["mappings"][0][
                "candidateSHA256"
            ] = mutated_candidate_digest
            comparison_document["mappings"][0]["reportSHA256"] = indexer.sha256_file(
                responsive_report_path
            )
            comparison_index.write_text(json.dumps(comparison_document), encoding="utf-8")
            with self.assertRaisesRegex(indexer.IndexError, "recomputed output"):
                indexer.validate_final_comparisons(
                    root,
                    capture_root,
                    captures,
                    comparison_index,
                    authority_manifest,
                )

            responsive_candidate.write_bytes(original_candidate_bytes)
            responsive_record.write_bytes(original_record_bytes)
            responsive_report_path.write_text(
                json.dumps(original_responsive_report), encoding="utf-8"
            )
            captures[0]["pngSHA256"] = indexer.sha256_file(responsive_candidate)
            comparison_document["mappings"][0]["candidateSHA256"] = captures[0][
                "pngSHA256"
            ]
            comparison_document["mappings"][0]["reportSHA256"] = indexer.sha256_file(
                responsive_report_path
            )
            comparison_index.write_text(json.dumps(comparison_document), encoding="utf-8")

            mutated = json.loads(json.dumps(original_responsive_report))
            mutated["regions"][0]["sourceCropSHA256"] = "0" * 64
            responsive_report_path.write_text(json.dumps(mutated), encoding="utf-8")
            comparison_document["mappings"][0]["reportSHA256"] = indexer.sha256_file(
                responsive_report_path
            )
            comparison_index.write_text(json.dumps(comparison_document), encoding="utf-8")
            with self.assertRaisesRegex(indexer.IndexError, "source-crop provenance"):
                indexer.validate_final_comparisons(
                    root,
                    capture_root,
                    captures,
                    comparison_index,
                    authority_manifest,
                )

            responsive_report_path.write_text(
                json.dumps(original_responsive_report), encoding="utf-8"
            )
            heatmap_path = reports_root / "000.heatmap.png"
            Image.new("RGB", (7, 8), (0, 0, 0)).save(heatmap_path)
            comparison_document["mappings"][0]["reportSHA256"] = indexer.sha256_file(
                responsive_report_path
            )
            comparison_document["mappings"][0]["heatmapSHA256"] = indexer.sha256_file(
                heatmap_path
            )
            comparison_index.write_text(json.dumps(comparison_document), encoding="utf-8")
            with self.assertRaisesRegex(indexer.IndexError, "atlas dimensions"):
                indexer.validate_final_comparisons(
                    root,
                    capture_root,
                    captures,
                    comparison_index,
                    authority_manifest,
                )

            heatmap_path.write_bytes(original_heatmap)
            comparison_document["mappings"][0]["heatmapSHA256"] = indexer.sha256_file(
                heatmap_path
            )
            comparison_document["mappings"][0]["reportSHA256"] = indexer.sha256_file(
                responsive_report_path
            )

            comparison_document["mappings"][0]["result"] = "pending"
            comparison_index.write_text(json.dumps(comparison_document), encoding="utf-8")
            with self.assertRaisesRegex(indexer.IndexError, "pending or failed"):
                indexer.validate_final_comparisons(
                    root,
                    capture_root,
                    captures,
                    comparison_index,
                    authority_manifest,
                )

    def test_shared_swift_harness_declares_every_exact_surface_and_provider(self) -> None:
        source = (ROOT / "ThemeFidelityTests/ThemeFidelityMatrixTests.swift").read_text(
            encoding="utf-8"
        )
        matrix = json.loads(
            (
                ROOT
                / "docs/verification/theme-fidelity-v4/Golden-Screenshot-Matrix.json"
            ).read_text(encoding="utf-8")
        )
        for surface in matrix["themes"]["Norse"]["requiredSurfaces"]:
            self.assertIn(f'"{surface}"', source)
        for bootstrap in (
            "RuneScribeNorseThemeModuleBootstrap",
            "RuneScribeThemeMoonleafModuleBootstrap",
            "RuneScribeThemeSunspireModuleBootstrap",
            "RuneScribeThemeWildwoodModuleBootstrap",
            "RuneScribeThemeGloamthornModuleBootstrap",
        ):
            self.assertIn(f"{bootstrap}.register(with: runtime)", source)


if __name__ == "__main__":
    unittest.main()
