#!/usr/bin/env python3
"""Validate Elven font registration in isolated macOS and iOS test processes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterable


EXPECTED_FONT_COUNT = 4
EXPECTED_PACKAGE_VERSION = "3.1.0"
PROBE_MARKER = "FONT_REGISTRATION_RESULT="
SCHEMA_VERSION = 1

MACOS_COMMAND = (
    "xcodebuild -project ElvenFontRegistrationProbe.xcodeproj "
    "-scheme FontRegistrationMacProbe -destination 'platform=macOS' "
    "-derivedDataPath <ephemeral-derived-data> "
    "-resultBundlePath <ephemeral-result-bundle> test"
)
IOS_COMMAND = (
    "xcodebuild -project ElvenFontRegistrationProbe.xcodeproj "
    "-scheme FontRegistrationIOSProbe -destination "
    "'platform=iOS Simulator,id=SELECTED_SIMULATOR' "
    "-derivedDataPath <ephemeral-derived-data> "
    "-resultBundlePath <ephemeral-result-bundle> test"
)


class ValidationFailure(Exception):
    """A stable, user-actionable validation failure."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Register the four fonts declared by an Elven v3.1 package through "
            "CoreText on macOS and an iOS Simulator. The probe project exists "
            "only in a temporary directory and does not integrate with Rune Scribe."
        )
    )
    parser.add_argument(
        "--package-root",
        required=True,
        type=Path,
        help="Root of Rune-Scribe-Elven-Series-Corrected-Production-Package-v3.1.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help=(
            "Evidence JSON path. Defaults to "
            "<package-root>/Validation/font-registration.json."
        ),
    )
    parser.add_argument(
        "--generated-at-utc",
        required=True,
        help="Caller-supplied UTC evidence timestamp in YYYY-MM-DDTHH:MM:SSZ form.",
    )
    parser.add_argument(
        "--simulator-id",
        help=(
            "Specific booted iOS Simulator UDID. Without this option, a booted "
            "iOS Simulator is required and selected deterministically."
        ),
    )
    parser.add_argument(
        "--timeout-seconds",
        type=positive_integer,
        default=900,
        help="Per-command timeout in seconds (default: 900).",
    )
    return parser.parse_args(argv)


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def validate_generated_at_utc(value: str) -> None:
    match = re.fullmatch(
        r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z", value
    )
    if match is None:
        raise ValidationFailure(
            "INVALID_GENERATED_AT_UTC",
            "--generated-at-utc must use canonical YYYY-MM-DDTHH:MM:SSZ form.",
        )

    year, month, day, hour, minute, second = map(int, match.groups())
    try:
        import datetime

        datetime.datetime(year, month, day, hour, minute, second)
    except ValueError as error:
        raise ValidationFailure(
            "INVALID_GENERATED_AT_UTC",
            "--generated-at-utc is not a valid UTC calendar value.",
        ) from error


def blank_platform(
    platform: str,
    runtime_version: str | None,
    device: str | None,
    command: str,
) -> dict[str, Any]:
    return {
        "platform": platform,
        "runtimeVersion": runtime_version,
        "device": device,
        "status": "NOT_RUN",
        "command": command,
        "fonts": [],
    }


def initial_result(generated_at_utc: str) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "packageVersion": EXPECTED_PACKAGE_VERSION,
        "generatedAtUTC": generated_at_utc,
        "status": "FAIL",
        "expectedFontCount": EXPECTED_FONT_COUNT,
        "platforms": [
            blank_platform("macOS", None, None, MACOS_COMMAND),
            blank_platform("iOS Simulator", None, None, IOS_COMMAND),
        ],
        "errors": [],
    }


def add_error(result: dict[str, Any], code: str, message: str) -> None:
    error = {"code": code, "message": message}
    if error not in result["errors"]:
        result["errors"].append(error)


def find_asset_manifest(package_root: Path) -> Path:
    candidates = sorted(
        path
        for path in package_root.glob(
            "Rune-Scribe-Elven-Series-Asset-Manifest-*.json"
        )
        if path.is_file() and not path.is_symlink()
    )
    if not candidates:
        raise ValidationFailure(
            "ASSET_MANIFEST_MISSING",
            "The package root has no Elven Series asset manifest.",
        )
    if len(candidates) != 1:
        raise ValidationFailure(
            "ASSET_MANIFEST_AMBIGUOUS",
            "The package root must contain exactly one Elven Series asset manifest.",
        )
    return candidates[0]


def load_json_object(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle, object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValidationFailure(
            "ASSET_MANIFEST_INVALID",
            "The Elven Series asset manifest is not readable canonical JSON.",
        ) from error
    if not isinstance(value, dict):
        raise ValidationFailure(
            "ASSET_MANIFEST_INVALID",
            "The Elven Series asset manifest root must be an object.",
        )
    return value


def reject_duplicate_keys(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise json.JSONDecodeError(f"duplicate key: {key}", key, 0)
        result[key] = value
    return result


def require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValidationFailure(
            "FONT_DECLARATION_INVALID", f"Every font requires a non-empty {field}."
        )
    return value


def normalized_package_path(value: Any) -> str:
    raw = require_string(value, "filename")
    if "\\" in raw:
        raise ValidationFailure(
            "FONT_PATH_INVALID", "Font filenames must use normalized POSIX separators."
        )
    path = PurePosixPath(raw)
    if path.is_absolute() or not path.parts or any(
        part in {"", ".", ".."} for part in path.parts
    ):
        raise ValidationFailure(
            "FONT_PATH_INVALID", "Font filenames must be normalized package-relative paths."
        )
    normalized = path.as_posix()
    if normalized != raw or path.suffix.lower() != ".ttf":
        raise ValidationFailure(
            "FONT_PATH_INVALID", "Declared font paths must be normalized .ttf paths."
        )
    return normalized


def reject_symlink_components(
    root: Path,
    relative_path: PurePosixPath,
    *,
    code: str,
    message: str,
) -> None:
    if not relative_path.parts or any(
        part in {"", ".", ".."} for part in relative_path.parts
    ):
        raise ValidationFailure(code, message)
    current = root
    for part in relative_path.parts:
        current = current / part
        if current.is_symlink():
            raise ValidationFailure(code, message)


def extract_fonts(package_root: Path, manifest: dict[str, Any]) -> list[dict[str, Any]]:
    if manifest.get("packageVersion") != EXPECTED_PACKAGE_VERSION:
        raise ValidationFailure(
            "PACKAGE_VERSION_MISMATCH",
            f"The asset manifest packageVersion must be {EXPECTED_PACKAGE_VERSION}.",
        )

    codices = manifest.get("codices")
    if not isinstance(codices, list):
        raise ValidationFailure(
            "FONT_DECLARATION_INVALID", "The asset manifest codices field must be an array."
        )

    fonts: list[dict[str, Any]] = []
    for codex in codices:
        if not isinstance(codex, dict) or not isinstance(codex.get("script"), dict):
            raise ValidationFailure(
                "FONT_DECLARATION_INVALID", "Every Codex must declare one Script object."
            )
        script = codex["script"]
        require_string(script.get("resourceID"), "resourceID")
        expected_name = require_string(
            script.get("postScriptName"), "postScriptName"
        )
        script_id = require_string(script.get("scriptID"), "scriptID")

        dimensions = script.get("sourceViewBoxOrDimensions")
        if not isinstance(dimensions, dict) or dimensions.get("glyphCount") != 32:
            raise ValidationFailure(
                "FONT_DECLARATION_INVALID",
                "Every declared Script must have canonical glyphCount 32.",
            )

        variants = script.get("outputVariants")
        if not isinstance(variants, list):
            raise ValidationFailure(
                "FONT_DECLARATION_INVALID",
                "Every declared Script must have an outputVariants array.",
            )
        font_variants = [
            variant
            for variant in variants
            if isinstance(variant, dict) and variant.get("outputRole") == "script.font"
        ]
        if len(font_variants) != 1:
            raise ValidationFailure(
                "FONT_DECLARATION_INVALID",
                "Every declared Script must have exactly one script.font output.",
            )
        variant = font_variants[0]
        resource_id = require_string(variant.get("resourceID"), "resourceID")
        if variant.get("mediaType") != "font/ttf":
            raise ValidationFailure(
                "FONT_DECLARATION_INVALID",
                "Every script.font output must declare mediaType font/ttf.",
            )

        filename = normalized_package_path(variant.get("filename"))
        declared_sha256 = require_string(variant.get("sha256"), "sha256")
        if re.fullmatch(r"[0-9a-f]{64}", declared_sha256) is None:
            raise ValidationFailure(
                "FONT_DECLARATION_INVALID",
                "Every script.font output must declare a lowercase SHA-256 value.",
            )
        declared_length = variant.get("byteLength")
        if not isinstance(declared_length, int) or isinstance(declared_length, bool) or declared_length <= 0:
            raise ValidationFailure(
                "FONT_DECLARATION_INVALID",
                "Every script.font output must declare a positive byteLength.",
            )

        font_path = package_root.joinpath(*PurePosixPath(filename).parts)
        reject_symlink_components(
            package_root,
            PurePosixPath(filename),
            code="FONT_PATH_INVALID",
            message=f"Required font uses a symbolic-link path component: {filename}.",
        )
        if font_path.is_symlink() or not font_path.is_file():
            raise ValidationFailure(
                "FONT_FILE_MISSING", f"Required font is missing: {filename}."
            )
        try:
            resolved_font = font_path.resolve(strict=True)
            resolved_font.relative_to(package_root)
        except (OSError, ValueError) as error:
            raise ValidationFailure(
                "FONT_PATH_INVALID", f"Required font escapes the package root: {filename}."
            ) from error

        data = font_path.read_bytes()
        actual_sha256 = hashlib.sha256(data).hexdigest()
        if len(data) != declared_length:
            raise ValidationFailure(
                "FONT_BYTE_LENGTH_MISMATCH",
                f"Declared byteLength does not match required font: {filename}.",
            )
        if actual_sha256 != declared_sha256:
            raise ValidationFailure(
                "FONT_SHA256_MISMATCH",
                f"Declared SHA-256 does not match required font: {filename}.",
            )

        fonts.append(
            {
                "scriptID": script_id,
                "resourceID": resource_id,
                "filename": filename,
                "sha256": actual_sha256,
                "expectedPostScriptName": expected_name,
                "sourcePath": font_path,
            }
        )

    if len(fonts) != EXPECTED_FONT_COUNT:
        raise ValidationFailure(
            "FONT_DECLARATION_COUNT",
            f"The asset manifest must declare exactly {EXPECTED_FONT_COUNT} Script fonts.",
        )

    for field in ("scriptID", "resourceID", "filename", "expectedPostScriptName"):
        values = [font[field] for font in fonts]
        if len(values) != len(set(values)):
            raise ValidationFailure(
                "FONT_DECLARATION_DUPLICATE",
                f"Declared Script fonts must have unique {field} values.",
            )

    return sorted(fonts, key=lambda font: font["resourceID"])


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise ValidationFailure("TOOL_MISSING", f"Required tool is unavailable: {name}.")
    return path


def run_command(
    arguments: list[str],
    *,
    cwd: Path | None = None,
    timeout_seconds: int,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            arguments,
            cwd=cwd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout_seconds,
            env=os.environ.copy(),
        )
    except subprocess.TimeoutExpired as error:
        raise ValidationFailure(
            "COMMAND_TIMEOUT", "A font-registration build or test command timed out."
        ) from error
    except OSError as error:
        raise ValidationFailure(
            "COMMAND_EXECUTION_FAILED",
            "A font-registration build or test command could not be executed.",
        ) from error


def macos_runtime_version(sw_vers: str, timeout_seconds: int) -> str:
    completed = run_command(
        [sw_vers, "-productVersion"], timeout_seconds=timeout_seconds
    )
    version = completed.stdout.strip()
    if completed.returncode != 0 or re.fullmatch(r"\d+(?:\.\d+){1,2}", version) is None:
        raise ValidationFailure(
            "MACOS_RUNTIME_UNAVAILABLE", "The macOS runtime version could not be read."
        )
    return version


def ios_runtime_version(identifier: str) -> str:
    prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
    if not identifier.startswith(prefix):
        raise ValidationFailure(
            "IOS_SIMULATOR_INVALID", "The selected simulator does not use an iOS runtime."
        )
    suffix = identifier.removeprefix(prefix)
    if re.fullmatch(r"\d+(?:-\d+){1,2}", suffix) is None:
        raise ValidationFailure(
            "IOS_SIMULATOR_INVALID", "The selected iOS runtime identifier is invalid."
        )
    return suffix.replace("-", ".")


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def select_simulator(
    xcrun: str, simulator_id: str | None, timeout_seconds: int
) -> dict[str, str]:
    completed = run_command(
        [xcrun, "simctl", "list", "devices", "--json"],
        timeout_seconds=timeout_seconds,
    )
    if completed.returncode != 0:
        raise ValidationFailure(
            "IOS_SIMULATOR_DISCOVERY_FAILED",
            "Available iOS Simulators could not be enumerated.",
        )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise ValidationFailure(
            "IOS_SIMULATOR_DISCOVERY_FAILED",
            "Simulator discovery returned invalid JSON.",
        ) from error

    devices = payload.get("devices") if isinstance(payload, dict) else None
    if not isinstance(devices, dict):
        raise ValidationFailure(
            "IOS_SIMULATOR_DISCOVERY_FAILED",
            "Simulator discovery did not return a devices object.",
        )

    candidates: list[dict[str, str]] = []
    for runtime_identifier, runtime_devices in devices.items():
        if not isinstance(runtime_identifier, str) or "SimRuntime.iOS-" not in runtime_identifier:
            continue
        if not isinstance(runtime_devices, list):
            continue
        runtime_version = ios_runtime_version(runtime_identifier)
        for device in runtime_devices:
            if not isinstance(device, dict) or device.get("isAvailable") is not True:
                continue
            udid = device.get("udid")
            name = device.get("name")
            state = device.get("state")
            if not all(isinstance(value, str) and value for value in (udid, name, state)):
                continue
            candidates.append(
                {
                    "udid": udid,
                    "name": name,
                    "state": state,
                    "runtimeVersion": runtime_version,
                }
            )

    if simulator_id is not None:
        matches = [device for device in candidates if device["udid"] == simulator_id]
        if len(matches) != 1:
            raise ValidationFailure(
                "IOS_SIMULATOR_INVALID",
                "--simulator-id must identify one available iOS Simulator.",
            )
        if matches[0]["state"] != "Booted":
            raise ValidationFailure(
                "IOS_SIMULATOR_NOT_BOOTED",
                "--simulator-id must identify an already booted iOS Simulator.",
            )
        return matches[0]

    booted = [device for device in candidates if device["state"] == "Booted"]
    if not booted:
        raise ValidationFailure(
            "IOS_SIMULATOR_NOT_BOOTED",
            "A booted iOS Simulator is required when --simulator-id is omitted.",
        )
    booted.sort(
        key=lambda device: (
            version_key(device["runtimeVersion"]),
            device["name"],
            device["udid"],
        ),
        reverse=True,
    )
    return booted[0]


def prepare_probe_workspace(
    workspace: Path, templates: Path, fonts: list[dict[str, Any]]
) -> None:
    shutil.copytree(templates / "Shared", workspace / "Shared")
    shutil.copytree(templates / "Host", workspace / "Host")
    shutil.copyfile(templates / "project.yml", workspace / "project.yml")
    fixtures = workspace / "Fixtures"
    fixtures.mkdir()

    probe_fonts: list[dict[str, str]] = []
    for index, font in enumerate(fonts):
        bundle_filename = f"font-{index:02d}.ttf"
        shutil.copyfile(font["sourcePath"], fixtures / bundle_filename)
        probe_fonts.append(
            {
                "resourceID": font["resourceID"],
                "filename": font["filename"],
                "bundleFilename": bundle_filename,
                "sha256": font["sha256"],
                "expectedPostScriptName": font["expectedPostScriptName"],
            }
        )

    fixture = {
        "schemaVersion": SCHEMA_VERSION,
        "expectedFontCount": EXPECTED_FONT_COUNT,
        "fonts": probe_fonts,
    }
    (fixtures / "probe-input.json").write_text(
        json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )


def probe_payloads_from_text(output: str) -> list[dict[str, Any]]:
    payloads: list[dict[str, Any]] = []
    for line in output.splitlines():
        marker_index = line.find(PROBE_MARKER)
        if marker_index < 0:
            continue
        raw = line[marker_index + len(PROBE_MARKER) :].strip()
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            payloads.append(value)
    return payloads


def unique_probe_payload(payloads: list[dict[str, Any]]) -> dict[str, Any] | None:
    unique: dict[str, dict[str, Any]] = {}
    for payload in payloads:
        key = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        unique[key] = payload
    if len(unique) != 1:
        return None
    return next(iter(unique.values()))


def parse_probe_output(output: str) -> dict[str, Any] | None:
    return unique_probe_payload(probe_payloads_from_text(output))


def nested_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from nested_strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from nested_strings(item)


def parse_result_bundle(
    xcrun: str,
    result_bundle: Path,
    timeout_seconds: int,
) -> dict[str, Any] | None:
    if not result_bundle.is_dir():
        return None
    completed = run_command(
        [
            xcrun,
            "xcresulttool",
            "get",
            "log",
            "--path",
            str(result_bundle),
            "--type",
            "action",
            "--compact",
        ],
        timeout_seconds=timeout_seconds,
    )
    if completed.returncode != 0:
        return None
    try:
        log = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None

    payloads: list[dict[str, Any]] = []
    for value in nested_strings(log):
        payloads.extend(probe_payloads_from_text(value))
    return unique_probe_payload(payloads)


def validated_probe_fonts(
    payload: dict[str, Any], expected_fonts: list[dict[str, Any]]
) -> list[dict[str, Any]] | None:
    raw_fonts = payload.get("fonts")
    if not isinstance(raw_fonts, list) or len(raw_fonts) != EXPECTED_FONT_COUNT:
        return None

    expected_by_id = {font["resourceID"]: font for font in expected_fonts}
    observed: dict[str, dict[str, Any]] = {}
    for raw_font in raw_fonts:
        if not isinstance(raw_font, dict):
            return None
        resource_id = raw_font.get("resourceID")
        if not isinstance(resource_id, str) or resource_id in observed:
            return None
        expected = expected_by_id.get(resource_id)
        if expected is None:
            return None
        if any(
            raw_font.get(field) != expected[field]
            for field in (
                "filename",
                "sha256",
                "expectedPostScriptName",
            )
        ):
            return None
        resolved_name = raw_font.get("resolvedPostScriptName")
        registered = raw_font.get("registered")
        status = raw_font.get("status")
        error_code = raw_font.get("errorCode")
        if resolved_name is not None and not isinstance(resolved_name, str):
            return None
        if not isinstance(registered, bool) or status not in {"PASS", "FAIL"}:
            return None
        if error_code is not None and not isinstance(error_code, str):
            return None
        observed[resource_id] = {
            "resourceID": resource_id,
            "filename": expected["filename"],
            "sha256": expected["sha256"],
            "expectedPostScriptName": expected["expectedPostScriptName"],
            "resolvedPostScriptName": resolved_name,
            "registered": registered,
            "status": status,
            "errorCode": error_code,
        }

    return [observed[resource_id] for resource_id in sorted(observed)]


def run_platform_probe(
    *,
    xcodebuild: str,
    xcrun: str,
    workspace: Path,
    scheme: str,
    destination: str,
    expected_fonts: list[dict[str, Any]],
    platform_result: dict[str, Any],
    timeout_seconds: int,
) -> None:
    derived_data = workspace / f"DerivedData-{scheme}"
    result_bundle = workspace / f"Results-{scheme}.xcresult"
    completed = run_command(
        [
            xcodebuild,
            "-project",
            str(workspace / "ElvenFontRegistrationProbe.xcodeproj"),
            "-scheme",
            scheme,
            "-destination",
            destination,
            "-derivedDataPath",
            str(derived_data),
            "-resultBundlePath",
            str(result_bundle),
            "test",
        ],
        cwd=workspace,
        timeout_seconds=timeout_seconds,
    )
    payload = parse_probe_output(completed.stdout)
    if payload is None:
        payload = parse_result_bundle(xcrun, result_bundle, timeout_seconds)
    if payload is None:
        platform_result["status"] = "FAIL"
        platform_result["fonts"] = []
        raise ValidationFailure(
            "PROBE_RESULT_MISSING",
            f"{platform_result['platform']} did not emit one valid probe result.",
        )

    fonts = validated_probe_fonts(payload, expected_fonts)
    if fonts is None:
        platform_result["status"] = "FAIL"
        platform_result["fonts"] = []
        raise ValidationFailure(
            "PROBE_RESULT_INVALID",
            f"{platform_result['platform']} emitted invalid font evidence.",
        )

    platform_result["fonts"] = fonts
    all_fonts_pass = all(
        font["status"] == "PASS"
        and font["registered"] is True
        and font["resolvedPostScriptName"] == font["expectedPostScriptName"]
        and font["errorCode"] is None
        for font in fonts
    )
    payload_pass = payload.get("status") == "PASS"
    if completed.returncode == 0 and payload_pass and all_fonts_pass:
        platform_result["status"] = "PASS"
        return

    platform_result["status"] = "FAIL"
    raise ValidationFailure(
        "CORETEXT_REGISTRATION_FAILED",
        f"{platform_result['platform']} CoreText registration evidence did not pass.",
    )


def write_result(
    path: Path,
    result: dict[str, Any],
    protected_root: Path | None = None,
) -> None:
    protected_relative: PurePosixPath | None = None
    if protected_root is not None:
        try:
            protected_relative = PurePosixPath(path.absolute().relative_to(protected_root).as_posix())
        except ValueError as error:
            raise ValidationFailure(
                "OUTPUT_PATH_INVALID",
                "Protected evidence output must remain inside the package root.",
            ) from error
        reject_symlink_components(
            protected_root,
            protected_relative,
            code="OUTPUT_PATH_INVALID",
            message="The package evidence output path must not use symbolic-link components.",
        )
    if path.exists() and path.is_symlink():
        raise ValidationFailure(
            "OUTPUT_PATH_INVALID", "The evidence output path must not be a symbolic link."
        )
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        if protected_root is not None and protected_relative is not None:
            reject_symlink_components(
                protected_root,
                protected_relative,
                code="OUTPUT_PATH_INVALID",
                message="The package evidence output path must not use symbolic-link components.",
            )
        payload = json.dumps(result, sort_keys=True, indent=2) + "\n"
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    except OSError as error:
        raise ValidationFailure(
            "OUTPUT_WRITE_FAILED", "The font-registration evidence JSON could not be written."
        ) from error


def emit_result(result: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(result, sort_keys=True, indent=2) + "\n")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    result = initial_result(args.generated_at_utc)
    package_root = args.package_root.expanduser()
    requested_package_root = package_root.absolute()
    if args.output is not None:
        output: Path | None = args.output.expanduser()
    elif package_root.is_dir() and not package_root.is_symlink():
        output = package_root / "Validation" / "font-registration.json"
    else:
        output = None

    try:
        validate_generated_at_utc(args.generated_at_utc)
        if package_root.is_symlink() or not package_root.is_dir():
            raise ValidationFailure(
                "PACKAGE_ROOT_INVALID", "--package-root must be an existing package directory."
            )
        package_root = package_root.resolve(strict=True)
        if args.output is None:
            output = package_root / "Validation" / "font-registration.json"

        manifest_path = find_asset_manifest(package_root)
        manifest = load_json_object(manifest_path)
        fonts = extract_fonts(package_root, manifest)

        xcodegen = require_tool("xcodegen")
        xcodebuild = require_tool("xcodebuild")
        xcrun = require_tool("xcrun")
        sw_vers = require_tool("sw_vers")

        mac_runtime = macos_runtime_version(sw_vers, args.timeout_seconds)
        result["platforms"][0]["runtimeVersion"] = mac_runtime

        simulator = select_simulator(xcrun, args.simulator_id, args.timeout_seconds)
        result["platforms"][1]["runtimeVersion"] = simulator["runtimeVersion"]
        result["platforms"][1]["device"] = simulator["name"]

        templates = Path(__file__).resolve().parent / "font-registration"
        with tempfile.TemporaryDirectory(prefix="elven-font-registration-") as raw_workspace:
            workspace = Path(raw_workspace)
            prepare_probe_workspace(workspace, templates, fonts)
            generated = run_command(
                [xcodegen, "generate", "--spec", "project.yml"],
                cwd=workspace,
                timeout_seconds=args.timeout_seconds,
            )
            if generated.returncode != 0 or not (
                workspace / "ElvenFontRegistrationProbe.xcodeproj"
            ).is_dir():
                raise ValidationFailure(
                    "XCODEGEN_FAILED", "The ephemeral font-registration project was not generated."
                )

            for index, probe in enumerate(
                (
                    {
                        "scheme": "FontRegistrationMacProbe",
                        "destination": "platform=macOS",
                    },
                    {
                        "scheme": "FontRegistrationIOSProbe",
                        "destination": f"platform=iOS Simulator,id={simulator['udid']}",
                    },
                )
            ):
                try:
                    run_platform_probe(
                        xcodebuild=xcodebuild,
                        xcrun=xcrun,
                        workspace=workspace,
                        scheme=probe["scheme"],
                        destination=probe["destination"],
                        expected_fonts=fonts,
                        platform_result=result["platforms"][index],
                        timeout_seconds=args.timeout_seconds,
                    )
                except ValidationFailure as error:
                    add_error(result, error.code, error.message)

        if all(platform["status"] == "PASS" for platform in result["platforms"]):
            result["status"] = "PASS"
            result["errors"] = []
        else:
            result["status"] = "FAIL"

    except ValidationFailure as error:
        add_error(result, error.code, error.message)
    except (OSError, TypeError, ValueError) as error:
        add_error(
            result,
            "UNEXPECTED_VALIDATION_FAILURE",
            "The font-registration harness encountered an unexpected local failure.",
        )

    if output is not None:
        try:
            protected_root: Path | None = None
            output_absolute = output.absolute()
            for candidate_root in (requested_package_root, package_root):
                try:
                    relative_output = output_absolute.relative_to(candidate_root)
                except ValueError:
                    continue
                output = package_root.joinpath(*relative_output.parts)
                protected_root = package_root
                break
            write_result(
                output,
                result,
                protected_root=protected_root,
            )
        except ValidationFailure as error:
            add_error(result, error.code, error.message)
            result["status"] = "FAIL"

    emit_result(result)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
