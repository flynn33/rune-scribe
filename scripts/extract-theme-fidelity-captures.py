#!/usr/bin/env python3
"""Extract named Theme fidelity attachments from XCTest result bundles."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, NamedTuple

try:
    from scripts.theme_fidelity_destination_policy import (
        DestinationPolicyError,
        validate_selection,
    )
except ModuleNotFoundError:
    from theme_fidelity_destination_policy import (  # type: ignore[no-redef]
        DestinationPolicyError,
        validate_selection,
    )


SCHEMA_VERSION = "1.0"
CAPTURE_NAME = re.compile(
    r"^(norse|moonleaf|sunspire|wildwood|gloamthorn)--"
    r"([a-z0-9-]+)--"
    r"(iphone-portrait|ipad-portrait|macos-standard|macos-resized)"
    r"(?:\.png|\.capture\.json)$"
)
XCRESULT_NAME_SUFFIX = re.compile(
    r"^(?P<base>.+)_(?P<ordinal>[0-9]+)_"
    r"(?P<uuid>[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})"
    r"(?P<extension>\.png|\.json)$"
)
EXPECTED_TEST_IDENTIFIER = "ThemeFidelityMatrixTests/testCaptureThemeFidelityMatrix()"
BUNDLE_EXPECTATIONS = {
    "iphone": {
        "destinations": {"iphone-portrait"},
        "platform": "iOS Simulator",
        "attachmentCount": 200,
    },
    "ipad": {
        "destinations": {"ipad-portrait"},
        "platform": "iOS Simulator",
        "attachmentCount": 200,
    },
    "macos": {
        "destinations": {"macos-standard", "macos-resized"},
        "platform": "macOS",
        "modelPrefix": "Mac",
        "attachmentCount": 400,
    },
}


class BundleBinding(NamedTuple):
    role: str
    path: Path
    expected_device_id: str | None = None
    expected_model_name: str | None = None
    destination_selection: dict[str, Any] | None = None


class ExtractionError(ValueError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def result_bundle_digest(path: Path) -> str:
    digest = hashlib.sha256()
    for candidate in sorted(item for item in path.rglob("*") if item.is_file()):
        relative = candidate.relative_to(path).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256_file(candidate)))
    return digest.hexdigest()


def export_attachments(result_bundle: Path, output: Path) -> list[dict[str, Any]]:
    completed = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "export",
            "attachments",
            "--path",
            str(result_bundle),
            "--output-path",
            str(output),
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise ExtractionError(f"attachment export failed for {result_bundle}: {detail}")
    manifest_path = output / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ExtractionError(f"invalid attachment manifest for {result_bundle}: {error}") from error
    if not isinstance(manifest, list):
        raise ExtractionError(f"attachment manifest is not an array: {result_bundle}")
    return manifest


def xcresult_summary(result_bundle: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(result_bundle),
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise ExtractionError(f"result summary failed for {result_bundle}: {detail}")
    try:
        document = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise ExtractionError(f"invalid result summary for {result_bundle}: {error}") from error
    if not isinstance(document, dict):
        raise ExtractionError(f"result summary is not an object: {result_bundle}")
    return document


def canonical_json_sha256(document: Any) -> str:
    encoded = json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def write_json(path: Path, document: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def validate_summary(binding: BundleBinding, summary: dict[str, Any]) -> dict[str, Any]:
    expectation = BUNDLE_EXPECTATIONS[binding.role]
    exact_counts = {
        "result": "Passed",
        "totalTestCount": 1,
        "passedTests": 1,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
    }
    for key, expected in exact_counts.items():
        if summary.get(key) != expected:
            raise ExtractionError(
                f"{binding.role} result summary {key} is {summary.get(key)!r}, expected {expected!r}"
            )
    devices = summary.get("devicesAndConfigurations")
    if not isinstance(devices, list) or len(devices) != 1 or not isinstance(devices[0], dict):
        raise ExtractionError(f"{binding.role} result must contain exactly one device/configuration")
    device_record = devices[0]
    for key in ("passedTests", "failedTests", "skippedTests", "expectedFailures"):
        if device_record.get(key) != exact_counts[key]:
            raise ExtractionError(
                f"{binding.role} device result {key} is {device_record.get(key)!r}, "
                f"expected {exact_counts[key]!r}"
            )
    device = device_record.get("device")
    configuration = device_record.get("testPlanConfiguration")
    if not isinstance(device, dict) or not isinstance(configuration, dict):
        raise ExtractionError(f"{binding.role} result lacks device/configuration provenance")
    for key in ("deviceId", "deviceName", "modelName", "osVersion", "osBuildNumber", "platform", "architecture"):
        if not isinstance(device.get(key), str) or not device[key]:
            raise ExtractionError(f"{binding.role} result device.{key} is missing")
    if device["platform"] != expectation["platform"]:
        raise ExtractionError(
            f"{binding.role} result platform is {device['platform']!r}, expected {expectation['platform']!r}"
        )
    if binding.role in {"iphone", "ipad"}:
        if device["modelName"] != binding.expected_model_name:
            raise ExtractionError(
                f"{binding.role} result model {device['modelName']!r} does not match exact "
                f"selected model {binding.expected_model_name!r}"
            )
    elif not device["modelName"].startswith(expectation["modelPrefix"]):
        raise ExtractionError(f"macos result model is not a Mac destination")
    if binding.role == "macos" and device["architecture"] != "arm64":
        raise ExtractionError(
            f"macos result architecture is {device['architecture']!r}, expected 'arm64'"
        )
    if binding.expected_device_id is not None and device["deviceId"] != binding.expected_device_id:
        raise ExtractionError(
            f"{binding.role} result device ID {device['deviceId']!r} does not match "
            f"requested destination {binding.expected_device_id!r}"
        )
    configuration_name = configuration.get("configurationName")
    if not isinstance(configuration_name, str) or not configuration_name:
        raise ExtractionError(f"{binding.role} result configurationName is missing")
    environment = summary.get("environmentDescription")
    if not isinstance(environment, str) or not environment:
        raise ExtractionError(f"{binding.role} result environmentDescription is missing")
    start_time = summary.get("startTime")
    finish_time = summary.get("finishTime")
    if not (
        isinstance(start_time, (int, float))
        and not isinstance(start_time, bool)
        and math.isfinite(start_time)
        and isinstance(finish_time, (int, float))
        and not isinstance(finish_time, bool)
        and math.isfinite(finish_time)
        and finish_time >= start_time
    ):
        raise ExtractionError(f"{binding.role} result timestamps are invalid")
    return {
        "device": device,
        "configurationName": configuration_name,
        "environmentDescription": environment,
        "startTime": start_time,
        "finishTime": finish_time,
    }


def flatten_attachments(manifest: list[dict[str, Any]]) -> list[dict[str, Any]]:
    flattened: list[dict[str, Any]] = []
    for test in manifest:
        if not isinstance(test, dict) or not isinstance(test.get("attachments"), list):
            raise ExtractionError("attachment manifest contains an invalid test record")
        test_identifier = test.get("testIdentifier")
        test_identifier_url = test.get("testIdentifierURL")
        for attachment in test["attachments"]:
            if not isinstance(attachment, dict):
                raise ExtractionError("attachment manifest contains an invalid attachment")
            flattened.append(
                {
                    **attachment,
                    "testIdentifier": test_identifier,
                    "testIdentifierURL": test_identifier_url,
                }
            )
    return flattened


def canonical_attachment_name(suggested: str) -> str | None:
    """Recover the exact XCTest attachment name from xcresult export decoration."""
    if CAPTURE_NAME.fullmatch(suggested):
        return suggested
    decorated = XCRESULT_NAME_SUFFIX.fullmatch(suggested)
    if decorated is None:
        return None
    candidate = decorated.group("base") + decorated.group("extension")
    if CAPTURE_NAME.fullmatch(candidate):
        return candidate
    return None


def destination_slug(name: str) -> str:
    match = CAPTURE_NAME.fullmatch(name)
    if match is None:
        raise ExtractionError(f"attachment name is not canonical: {name}")
    return match.group(3)


def validate_attachment_content(path: Path, canonical_name: str) -> str:
    if canonical_name.endswith(".png"):
        try:
            signature = path.read_bytes()[:8]
        except OSError as error:
            raise ExtractionError(f"unable to read attachment {path}: {error}") from error
        if signature != b"\x89PNG\r\n\x1a\n":
            raise ExtractionError(f"attachment content is not public.png: {canonical_name}")
        return "public.png"
    try:
        decoded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ExtractionError(f"attachment content is not public.json: {canonical_name}") from error
    if not isinstance(decoded, dict):
        raise ExtractionError(f"capture record attachment is not a JSON object: {canonical_name}")
    return "public.json"


def validate_bindings(bindings: list[BundleBinding]) -> None:
    roles = [binding.role for binding in bindings]
    if len(roles) != len(BUNDLE_EXPECTATIONS) or set(roles) != set(BUNDLE_EXPECTATIONS):
        raise ExtractionError(
            "result bundle roles must be exactly once each: iphone, ipad, macos"
        )
    if len({binding.path.resolve() for binding in bindings}) != len(bindings):
        raise ExtractionError("result bundle paths must be distinct")
    for binding in bindings:
        if binding.role in {"iphone", "ipad"}:
            if not binding.expected_device_id:
                raise ExtractionError(f"{binding.role} result bundle requires an expected device ID")
            if not binding.expected_model_name:
                raise ExtractionError(
                    f"{binding.role} result bundle requires an exact expected model name"
                )
            try:
                validate_selection(
                    binding.destination_selection,
                    binding.role,
                    binding.expected_device_id,
                    binding.expected_model_name,
                )
            except DestinationPolicyError as error:
                raise ExtractionError(str(error)) from error


def extract(
    bindings: list[BundleBinding],
    output: Path,
    simulator_selection_source: dict[str, Any] | None = None,
) -> dict[str, Any]:
    validate_bindings(bindings)
    output.mkdir(parents=True, exist_ok=True)
    existing = [path.name for path in output.iterdir() if CAPTURE_NAME.fullmatch(path.name)]
    if existing:
        raise ExtractionError(
            "capture output already contains matrix attachments: " + ", ".join(sorted(existing)[:8])
        )

    copied: dict[str, dict[str, Any]] = {}
    bundles: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="theme-fidelity-attachments-") as temporary:
        temporary_root = Path(temporary)
        for index, binding in enumerate(bindings):
            result_bundle = binding.path.resolve()
            if not result_bundle.is_dir():
                raise ExtractionError(f"result bundle is missing: {result_bundle}")
            summary = xcresult_summary(result_bundle)
            provenance = validate_summary(binding, summary)
            exported = temporary_root / f"bundle-{index}"
            manifest = export_attachments(result_bundle, exported)
            if len(manifest) != 1 or manifest[0].get("testIdentifier") != EXPECTED_TEST_IDENTIFIER:
                identifiers = [record.get("testIdentifier") for record in manifest]
                raise ExtractionError(
                    f"{binding.role} attachment test identifiers are {identifiers!r}, "
                    f"expected exactly {EXPECTED_TEST_IDENTIFIER!r}"
                )
            manifest_path = exported / "manifest.json"
            if not manifest_path.is_file():
                raise ExtractionError(f"attachment export omitted manifest.json: {result_bundle}")
            selected_count = 0
            for attachment in flatten_attachments(manifest):
                suggested = attachment.get("suggestedHumanReadableName")
                exported_name = attachment.get("exportedFileName")
                if not isinstance(suggested, str):
                    raise ExtractionError(f"{binding.role} attachment lacks a suggested name")
                canonical_name = canonical_attachment_name(suggested)
                if canonical_name is None:
                    raise ExtractionError(
                        f"{binding.role} result bundle contains a non-matrix attachment: {suggested}"
                    )
                if attachment.get("testIdentifier") != EXPECTED_TEST_IDENTIFIER:
                    raise ExtractionError(
                        f"attachment belongs to unexpected test: {attachment.get('testIdentifier')!r}"
                    )
                if destination_slug(canonical_name) not in BUNDLE_EXPECTATIONS[binding.role]["destinations"]:
                    raise ExtractionError(
                        f"{binding.role} result bundle contains a capture for another destination: "
                        f"{canonical_name}"
                    )
                if not isinstance(exported_name, str) or Path(exported_name).name != exported_name:
                    raise ExtractionError(f"unsafe exported attachment name: {exported_name!r}")
                source = exported / exported_name
                if not source.is_file():
                    raise ExtractionError(f"exported attachment is missing: {source}")
                expected_configuration = provenance["configurationName"]
                expected_device = provenance["device"]
                exact_attachment = {
                    "configurationName": expected_configuration,
                    "deviceName": expected_device["deviceName"],
                    "deviceId": expected_device["deviceId"],
                    "isAssociatedWithFailure": False,
                }
                for key, expected_value in exact_attachment.items():
                    if attachment.get(key) != expected_value:
                        raise ExtractionError(
                            f"{canonical_name} {key} is {attachment.get(key)!r}, "
                            f"expected {expected_value!r}"
                        )
                attachment_timestamp = attachment.get("timestamp")
                if not (
                    isinstance(attachment_timestamp, (int, float))
                    and not isinstance(attachment_timestamp, bool)
                    and math.isfinite(attachment_timestamp)
                ):
                    raise ExtractionError(f"{canonical_name} attachment timestamp is missing")
                attachment_uti = validate_attachment_content(source, canonical_name)
                destination = output / canonical_name
                digest = sha256_file(source)
                if canonical_name in copied:
                    raise ExtractionError(
                        "duplicate canonical attachment name across result bundles: "
                        f"{canonical_name}"
                    )
                shutil.copyfile(source, destination)
                copied[canonical_name] = {
                    "name": canonical_name,
                    "exportedSuggestedName": suggested,
                    "sha256": digest,
                    "bytes": source.stat().st_size,
                    "testIdentifier": attachment.get("testIdentifier"),
                    "testIdentifierURL": attachment.get("testIdentifierURL"),
                    "configurationName": attachment.get("configurationName"),
                    "deviceName": attachment.get("deviceName"),
                    "deviceID": attachment.get("deviceId"),
                    "attachmentTimestamp": attachment_timestamp,
                    "attachmentUTI": attachment_uti,
                    "attachmentUTISource": "validated-content",
                    "resultBundleRole": binding.role,
                    "resultBundle": str(result_bundle),
                }
                selected_count += 1
            expected_count = BUNDLE_EXPECTATIONS[binding.role]["attachmentCount"]
            if selected_count != expected_count:
                raise ExtractionError(
                    f"{binding.role} result bundle produced {selected_count} matrix attachments, "
                    f"expected {expected_count}"
                )
            bundles.append(
                {
                    "role": binding.role,
                    "path": str(result_bundle),
                    "sha256": result_bundle_digest(result_bundle),
                    "selectedAttachmentCount": selected_count,
                    "expectedTestIdentifier": EXPECTED_TEST_IDENTIFIER,
                    "outcome": "Passed",
                    "summarySHA256": canonical_json_sha256(summary),
                    "attachmentManifestSHA256": canonical_json_sha256(manifest),
                    "resultSummary": summary,
                    "attachmentManifest": manifest,
                    "destinationSelection": binding.destination_selection,
                    **provenance,
                }
            )

    png_count = sum(name.endswith(".png") for name in copied)
    record_count = sum(name.endswith(".capture.json") for name in copied)
    if png_count != 400 or record_count != 400:
        raise ExtractionError(
            f"expected 400 PNG and 400 capture records, found {png_count} PNG and {record_count} records"
        )
    tool = subprocess.run(
        ["xcrun", "--find", "xcresulttool"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if tool.returncode != 0 or not tool.stdout.strip():
        detail = tool.stderr.strip() or tool.stdout.strip()
        raise ExtractionError(f"unable to resolve xcresulttool provenance: {detail}")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "result": "pass",
        "captureRoot": str(output.resolve()),
        "pngCount": png_count,
        "recordCount": record_count,
        "expectedTestIdentifier": EXPECTED_TEST_IDENTIFIER,
        "xcresulttool": tool.stdout.strip(),
        "simulatorSelectionSource": simulator_selection_source,
        "resultBundles": bundles,
        "attachments": [copied[name] for name in sorted(copied)],
    }


def parse_binding(
    raw: str,
    expected_devices: dict[str, str],
    expected_models: dict[str, str],
    selections: dict[str, dict[str, Any]],
) -> BundleBinding:
    role, separator, path = raw.partition("=")
    if not separator or role not in BUNDLE_EXPECTATIONS or not path:
        raise ExtractionError("--result-bundle must use ROLE=PATH for iphone, ipad, or macos")
    return BundleBinding(
        role,
        Path(path),
        expected_devices.get(role),
        expected_models.get(role),
        selections.get(role),
    )


def parse_role_values(raw_values: list[str], option: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw in raw_values:
        role, separator, value = raw.partition("=")
        if not separator or role not in {"iphone", "ipad"} or not value or role in parsed:
            raise ExtractionError(
                f"{option} must use iphone=VALUE and ipad=VALUE exactly once each"
            )
        parsed[role] = value
    if set(parsed) != {"iphone", "ipad"}:
        raise ExtractionError(f"{option} requires both iphone and ipad values")
    return parsed


def load_simulator_selections(
    path: Path,
    expected_devices: dict[str, str],
    expected_models: dict[str, str],
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    resolved = path.resolve()
    try:
        document = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ExtractionError(f"invalid Simulator selection evidence: {error}") from error
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "destinations"}:
        raise ExtractionError("Simulator selection evidence schema is invalid")
    destinations = document.get("destinations")
    if document.get("schemaVersion") != "1.0" or not isinstance(destinations, dict):
        raise ExtractionError("Simulator selection evidence schema is invalid")
    if set(destinations) != {"iphone", "ipad"}:
        raise ExtractionError("Simulator selection evidence destinations are incomplete")
    selections: dict[str, dict[str, Any]] = {}
    for role in ("iphone", "ipad"):
        try:
            selections[role] = validate_selection(
                destinations[role], role, expected_devices[role], expected_models[role]
            )
        except DestinationPolicyError as error:
            raise ExtractionError(str(error)) from error
    return selections, {
        "path": str(resolved),
        "sha256": sha256_file(resolved),
        "documentSHA256": canonical_json_sha256(document),
        "document": document,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-bundle", action="append", required=True)
    parser.add_argument(
        "--expected-device",
        action="append",
        default=[],
        help="Expected hosted destination as ROLE=DEVICE_ID (required for iphone and ipad).",
    )
    parser.add_argument(
        "--expected-model",
        action="append",
        default=[],
        help="Exact selected result model as ROLE=MODEL_NAME (required for iphone and ipad).",
    )
    parser.add_argument("--simulator-selections", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args()
    report_path = arguments.report or arguments.output / "extraction.json"
    try:
        expected_devices = parse_role_values(arguments.expected_device, "--expected-device")
        expected_models = parse_role_values(arguments.expected_model, "--expected-model")
        selections, selection_source = load_simulator_selections(
            arguments.simulator_selections, expected_devices, expected_models
        )
        bindings = [
            parse_binding(raw, expected_devices, expected_models, selections)
            for raw in arguments.result_bundle
        ]
        report = extract(bindings, arguments.output, selection_source)
        write_json(report_path, report)
    except ExtractionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: extracted {report['pngCount']} PNG captures and {report['recordCount']} records")
    print(f"REPORT: {report_path.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
