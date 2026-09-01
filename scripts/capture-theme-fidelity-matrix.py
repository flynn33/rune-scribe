#!/usr/bin/env python3
"""Run sequential Theme-fidelity captures and produce source-bound evidence."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
from typing import Any

try:
    from scripts.theme_fidelity_destination_policy import (
        DESTINATION_TARGETS,
        DestinationPolicyError,
        build_selection,
        policy_for_device_type,
    )
except ModuleNotFoundError:
    from theme_fidelity_destination_policy import (  # type: ignore[no-redef]
        DESTINATION_TARGETS,
        DestinationPolicyError,
        build_selection,
        policy_for_device_type,
    )


MATRIX_SHA256 = "bf49d24a1ac9ef881c25504a17ceeea4befe9d685fe46fd469f99b43f4ae833c"
DEFAULT_MATRIX = Path(
    "docs/verification/theme-fidelity-v4/Golden-Screenshot-Matrix.json"
)
DEFAULT_AUTHORITY_MANIFEST = Path(
    "docs/verification/theme-fidelity-v4/authority/asset-manifest.json"
)
V12_IMPORT_MANIFEST = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/IMPORT-MANIFEST.json"
)
V43_IMPORT_MANIFEST = Path(
    "docs/verification/theme-fidelity-v4-3/authority/IMPORT-MANIFEST-v4.3.json"
)
V43_RESPONSIVE_MATRIX = Path(
    "docs/verification/theme-fidelity-v4-3/authority/"
    "03-COMPARISON-AUTHORITY/Responsive-Surface-Matrix-v1.3.json"
)
AUTHORITY_CONTRACT_LEGACY = "legacy"
AUTHORITY_CONTRACT_V43 = "v4.3"
SOURCE_SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
V43_CAPTURE_JOB_ORDER = (
    "iphone",
    "ipad",
    "macos",
    "iphone-xcui",
    "ipad-xcui",
    "macos-xcui",
)
V43_EXTRACTION_COUNTS = {
    "pngCount": 400,
    "auxiliaryPNGCount": 44,
    "recordCount": 400,
    "candidatePNGCount": 341,
    "xcuiQueryPNGCount": 4,
    "xcuiSidecarCount": 325,
    "attachmentCount": 1514,
}
V43_XCUI_RESOURCE_RELATIVES = (
    "docs/verification/theme-fidelity-v4-3/authority/03-COMPARISON-AUTHORITY/"
    "Comparison-Authority-v1.3.json",
    "docs/verification/theme-fidelity-v4-3/authority/03-COMPARISON-AUTHORITY/"
    "Responsive-Candidate-Catalog-v1.3.json",
    "docs/verification/theme-fidelity-v4-3/authority/03-COMPARISON-AUTHORITY/"
    "Deterministic-Seed-Catalog-v1.3.json",
    "docs/verification/theme-fidelity-v4-3/authority/03-COMPARISON-AUTHORITY/"
    "Runtime-Probe-Catalog-v1.3.json",
)
V43_XCUI_RESOURCE_NAMES = tuple(Path(path).name for path in V43_XCUI_RESOURCE_RELATIVES)
V43_XCUI_TARGETS = ("RuneScribIOSUITests", "RuneScribMacParityUITests")


class CaptureError(ValueError):
    pass


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, document: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def canonical_json_sha256(document: Any) -> str:
    encoded = json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def load_indexer(root: Path) -> Any:
    path = root / "scripts/index-theme-fidelity-captures.py"
    spec = importlib.util.spec_from_file_location("theme_fidelity_capture_indexer", path)
    if spec is None or spec.loader is None:
        raise CaptureError(f"unable to load source-binding implementation: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_output(arguments: list[str], cwd: Path) -> str:
    completed = subprocess.run(
        arguments,
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise CaptureError(f"command failed: {' '.join(arguments)}\n{detail}")
    return completed.stdout.strip()


def executable_record(path: Path) -> dict[str, str]:
    resolved = path.resolve()
    if not resolved.is_file():
        raise CaptureError(f"toolchain executable is missing: {resolved}")
    return {"path": str(resolved), "sha256": sha256_file(resolved)}


def resolve_contract_source_sha(
    authority_contract: str,
    source_sha: str | None,
    phase: str,
) -> str | None:
    if authority_contract == AUTHORITY_CONTRACT_V43:
        if phase != "final":
            raise CaptureError("v4.3 responsive qualification requires --phase final")
        if source_sha is None or SOURCE_SHA_PATTERN.fullmatch(source_sha) is None:
            raise CaptureError(
                "v4.3 responsive qualification requires --source-sha as exactly "
                "40 lowercase hex characters"
            )
        return source_sha
    if authority_contract != AUTHORITY_CONTRACT_LEGACY:
        raise CaptureError(f"unsupported authority contract: {authority_contract!r}")
    if source_sha is not None:
        raise CaptureError("--source-sha is only valid with --authority-contract v4.3")
    return None


def resolve_matrix(
    root: Path,
    requested: Path | None,
    authority_contract: str,
) -> Path:
    default = (
        V43_RESPONSIVE_MATRIX
        if authority_contract == AUTHORITY_CONTRACT_V43
        else DEFAULT_MATRIX
    )
    selected = requested or default
    resolved = (root / selected).resolve() if not selected.is_absolute() else selected.resolve()
    if authority_contract == AUTHORITY_CONTRACT_V43:
        canonical = (root / V43_RESPONSIVE_MATRIX).resolve()
        if resolved != canonical:
            raise CaptureError(
                "v4.3 responsive matrix must be the canonical imported repository authority"
            )
        if not resolved.is_file() or resolved.is_symlink():
            raise CaptureError(f"v4.3 responsive matrix is missing or linked: {resolved}")
        return resolved
    if not resolved.is_file() or sha256_file(resolved) != MATRIX_SHA256:
        raise CaptureError("repository Golden Screenshot Matrix differs from the controlling matrix")
    return resolved


def resolve_authority_manifest(
    root: Path,
    requested: Path | None,
    authority_contract: str = AUTHORITY_CONTRACT_LEGACY,
) -> Path:
    default = (
        V43_IMPORT_MANIFEST
        if authority_contract == AUTHORITY_CONTRACT_V43
        else DEFAULT_AUTHORITY_MANIFEST
    )
    selected = requested or default
    resolved = (root / selected).resolve() if not selected.is_absolute() else selected.resolve()
    canonical = (root / default).resolve()
    if resolved != canonical:
        raise CaptureError(
            "authority manifest must be the canonical repository manifest for the contract"
        )
    if not resolved.is_file() or (
        authority_contract == AUTHORITY_CONTRACT_V43 and resolved.is_symlink()
    ):
        raise CaptureError(f"authority manifest is missing: {resolved}")
    return resolved


def validate_frozen_source_manifest(
    manifest: dict[str, Any],
    source_sha: str,
) -> None:
    if manifest.get("sourceSHA") != source_sha:
        raise CaptureError(
            "requested source SHA differs from the checked-out frozen source: "
            f"requested={source_sha} actual={manifest.get('sourceSHA')!r}"
        )


def v43_authority_validation_command(
    root: Path,
    manifest: Path,
    output: Path,
) -> list[str]:
    return [
        sys.executable,
        str(root / "scripts/theme_fidelity_authority_v13.py"),
        "--root",
        str(root),
        "--manifest",
        str(manifest),
        "--output",
        str(output),
    ]


def validate_v43_authority_report(report: Path, manifest: Path) -> dict[str, Any]:
    try:
        document = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CaptureError(f"v4.3 authority validation report is invalid: {error}") from error
    if (
        not isinstance(document, dict)
        or document.get("schemaVersion") != "1.3"
        or document.get("authorityVersion") != "4.3"
        or document.get("result") != "PASS"
        or document.get("findings") != []
        or document.get("manifestSHA256") != sha256_file(manifest)
    ):
        raise CaptureError("v4.3 imported authority validation did not pass exactly")
    return document


def validate_v43_extraction_report(
    report: Path,
    source_sha: str,
    authority_manifest: Path,
) -> dict[str, Any]:
    try:
        document = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CaptureError(f"v4.3 extraction report is invalid: {error}") from error
    if not isinstance(document, dict):
        raise CaptureError("v4.3 extraction report is not a JSON object")
    validation = document.get("authorityValidation")
    result_bundles = document.get("resultBundles")
    roles = (
        tuple(item.get("role") for item in result_bundles)
        if isinstance(result_bundles, list)
        and all(isinstance(item, dict) for item in result_bundles)
        else ()
    )
    if (
        document.get("schemaVersion") != "1.3"
        or document.get("result") not in {"pass", "PASS"}
        or document.get("sourceSHA") != source_sha
        or document.get("authorityContract") != AUTHORITY_CONTRACT_V43
        or document.get("sourceXCUIContract") != AUTHORITY_CONTRACT_V43
        or roles != V43_CAPTURE_JOB_ORDER
        or any(document.get(key) != value for key, value in V43_EXTRACTION_COUNTS.items())
        or not isinstance(validation, dict)
        or validation.get("result") != "PASS"
        or validation.get("findings") != []
        or validation.get("manifestSHA256") != sha256_file(authority_manifest)
    ):
        raise CaptureError("v4.3 extraction report does not bind the exact authority run")
    return document


def _project_target_block(project_source: str, target_name: str) -> list[str]:
    lines = project_source.splitlines()
    header = f"  {target_name}:"
    try:
        start = lines.index(header) + 1
    except ValueError as error:
        raise CaptureError(f"project.yml target is missing: {target_name}") from error
    end = len(lines)
    for index in range(start, len(lines)):
        line = lines[index]
        if line.startswith("  ") and not line.startswith("    ") and line.endswith(":"):
            end = index
            break
    return lines[start:end]


def _declared_resource_paths(project_source: str, target_name: str) -> set[str]:
    block = _project_target_block(project_source, target_name)
    resources: set[str] = set()
    for index, line in enumerate(block):
        prefix = "      - path: "
        if not line.startswith(prefix):
            continue
        path = line.removeprefix(prefix)
        next_line = block[index + 1].strip() if index + 1 < len(block) else ""
        if next_line == "buildPhase: resources":
            resources.add(path)
    return resources


def _generated_target_resources(project_path: Path, target_name: str) -> set[str]:
    converted = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(project_path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if converted.returncode != 0:
        detail = converted.stderr.strip() or converted.stdout.strip()
        raise CaptureError(f"generated Xcode project is unreadable: {detail}")
    try:
        document = json.loads(converted.stdout)
        objects = document["objects"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise CaptureError(f"generated Xcode project structure is invalid: {error}") from error
    targets = [
        item
        for item in objects.values()
        if isinstance(item, dict)
        and item.get("isa") == "PBXNativeTarget"
        and item.get("name") == target_name
    ]
    if len(targets) != 1:
        raise CaptureError(f"generated Xcode target is not unique: {target_name}")
    phases = [
        objects.get(identifier)
        for identifier in targets[0].get("buildPhases", [])
        if isinstance(objects.get(identifier), dict)
        and objects[identifier].get("isa") == "PBXResourcesBuildPhase"
    ]
    if len(phases) != 1:
        raise CaptureError(f"generated Xcode resource phase is not unique: {target_name}")
    names: set[str] = set()
    for build_identifier in phases[0].get("files", []):
        build_file = objects.get(build_identifier)
        file_reference = (
            objects.get(build_file.get("fileRef"))
            if isinstance(build_file, dict)
            else None
        )
        path = file_reference.get("path") if isinstance(file_reference, dict) else None
        if not isinstance(path, str) or not path:
            raise CaptureError(f"generated Xcode resource reference is invalid: {target_name}")
        names.add(Path(path).name)
    return names


def validate_v43_xcui_source_binding(root: Path) -> None:
    swift_path = root / "ThemeFidelityXCUITests/ThemeFidelityAuthorityUITests.swift"
    project_source_path = root / "project.yml"
    generated_project_path = root / "RuneScrib.xcodeproj/project.pbxproj"
    for label, path in (
        ("XCUI authority source", swift_path),
        ("XcodeGen project source", project_source_path),
        ("generated Xcode project", generated_project_path),
    ):
        if not path.is_file() or path.is_symlink():
            raise CaptureError(f"{label} is missing or linked: {path}")

    swift_source = swift_path.read_text(encoding="utf-8")
    loaded = re.findall(
        r"try\s+decodeResource\(\s*named:\s*\"([^\"]+)\"",
        swift_source,
        flags=re.MULTILINE,
    )
    expected_stems = {Path(name).stem for name in V43_XCUI_RESOURCE_NAMES}
    if len(loaded) != 4 or set(loaded) != expected_stems:
        raise CaptureError("XCUI source does not load the exact four v1.3 catalogs")
    required_snippets = (
        "captureCandidateIDs(",
        'hasPrefix("probe.motion.preview-")',
        "CaptureInventory(sidecars: 70, candidates: 74, queries: 1)",
        "CaptureInventory(sidecars: 85, candidates: 89, queries: 1)",
        "CaptureInventory(sidecars: 325, candidates: 341, queries: 4)",
    )
    if any(snippet not in swift_source for snippet in required_snippets):
        raise CaptureError("XCUI source lacks the direct v4.3 capture contract")
    if re.search(r"(?:Authority|Catalog)-v1\.2", swift_source):
        raise CaptureError("XCUI source still references a v1.2 authority resource")

    project_source = project_source_path.read_text(encoding="utf-8")
    expected_paths = set(V43_XCUI_RESOURCE_RELATIVES)
    expected_names = set(V43_XCUI_RESOURCE_NAMES)
    for target_name in V43_XCUI_TARGETS:
        declared = _declared_resource_paths(project_source, target_name)
        if declared != expected_paths:
            raise CaptureError(
                f"project.yml {target_name} resources differ from direct v4.3 authority"
            )
        generated = _generated_target_resources(generated_project_path, target_name)
        if generated != expected_names:
            raise CaptureError(
                f"generated {target_name} resources differ from direct v4.3 authority"
            )


def toolchain_document(root: Path) -> dict[str, Any]:
    xcodebuild = Path(run_output(["xcrun", "--find", "xcodebuild"], root))
    swiftc = Path(run_output(["xcrun", "--find", "swiftc"], root))
    xcresulttool = Path(run_output(["xcrun", "--find", "xcresulttool"], root))
    xcrun = Path("/usr/bin/xcrun")
    python_executable = Path(sys.executable)
    return {
        "schemaVersion": "1.0",
        "xcodebuildVersion": run_output([str(xcodebuild), "-version"], root).replace("\n", "; "),
        "swiftVersion": run_output([str(swiftc), "--version"], root).replace("\n", "; "),
        "macOS": {
            "productVersion": run_output(["sw_vers", "-productVersion"], root),
            "buildVersion": run_output(["sw_vers", "-buildVersion"], root),
        },
        "architecture": platform.machine(),
        "pythonVersion": platform.python_version(),
        "executables": {
            "python": executable_record(python_executable),
            "swiftc": executable_record(swiftc),
            "xcodebuild": executable_record(xcodebuild),
            "xcresulttool": executable_record(xcresulttool),
            "xcrun": executable_record(xcrun),
        },
    }


def booted_simulators(root: Path) -> list[dict[str, Any]]:
    document = json.loads(run_output(["xcrun", "simctl", "list", "devices", "available", "-j"], root))
    result: list[dict[str, Any]] = []
    for devices in document.get("devices", {}).values():
        for device in devices:
            if isinstance(device, dict) and device.get("state") == "Booted":
                result.append(device)
    return result


def simulator_device_types(root: Path) -> dict[str, dict[str, Any]]:
    document = json.loads(run_output(["xcrun", "simctl", "list", "devicetypes", "-j"], root))
    result: dict[str, dict[str, Any]] = {}
    for device_type in document.get("devicetypes", []):
        if not isinstance(device_type, dict):
            continue
        identifier = device_type.get("identifier")
        bundle_path = device_type.get("bundlePath")
        if not isinstance(identifier, str) or not isinstance(bundle_path, str):
            continue
        profile = Path(bundle_path) / "Contents/Resources/profile.plist"
        try:
            with profile.open("rb") as stream:
                profile_document = plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException):
            continue
        width = profile_document.get("mainScreenWidth")
        height = profile_document.get("mainScreenHeight")
        scale = profile_document.get("mainScreenScale")
        if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in (width, height, scale)):
            continue
        result[identifier] = {
            **device_type,
            "pixelDimensions": {"width": int(width), "height": int(height)},
            "scale": int(scale),
            "profile": str(profile.resolve()),
            "profileSHA256": sha256_file(profile),
        }
    return result


def choose_simulator(
    root: Path,
    requested_id: str | None,
    role: str,
) -> dict[str, Any]:
    if role not in DESTINATION_TARGETS:
        raise CaptureError(f"unknown Simulator destination role: {role}")
    devices = booted_simulators(root)
    catalog = simulator_device_types(root)
    eligible: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for device in devices:
        identifier = str(device.get("deviceTypeIdentifier", ""))
        try:
            policy = policy_for_device_type(identifier, role)
        except DestinationPolicyError:
            continue
        eligible.append((device, policy))
    target = DESTINATION_TARGETS[role]
    if not eligible:
        raise CaptureError(
            f"no booted approved {target['targetModelName']} Simulator or deterministic substitute"
        )
    if requested_id:
        matches = [candidate for candidate in eligible if candidate[0].get("udid") == requested_id]
        if len(matches) != 1:
            raise CaptureError(
                f"requested {target['targetModelName']} Simulator is not booted or approved: "
                f"{requested_id}"
            )
        selected, selected_policy = matches[0]
        selected_rank = selected_policy["substitution"]["preferenceRank"]
        best_rank = min(candidate[1]["substitution"]["preferenceRank"] for candidate in eligible)
        if selected_policy["substitution"]["used"] and selected_rank > best_rank:
            better = sorted(
                candidate[1]["expectedModelName"]
                for candidate in eligible
                if candidate[1]["substitution"]["preferenceRank"] == best_rank
            )
            raise CaptureError(
                f"requested {selected_policy['expectedModelName']} is a lesser substitute while "
                f"a preferred approved destination is booted: {better}"
            )
    else:
        selected, selected_policy = min(
            eligible,
            key=lambda candidate: (
                candidate[1]["substitution"]["preferenceRank"],
                candidate[1]["expectedModelName"],
                str(candidate[0].get("udid", "")),
            ),
        )
    identifier = str(selected.get("deviceTypeIdentifier", ""))
    device_type = catalog.get(identifier)
    if device_type is None:
        raise CaptureError(f"Simulator device profile is unavailable: {identifier}")
    try:
        return build_selection(role, selected, device_type)
    except DestinationPolicyError as error:
        raise CaptureError(str(error)) from error


def ensure_empty_output(path: Path) -> None:
    if path.exists() and any(path.iterdir()):
        raise CaptureError(f"output directory must be absent or empty: {path}")
    path.mkdir(parents=True, exist_ok=True)


def run_command(command: list[str], root: Path, log: Path) -> dict[str, Any]:
    started = timestamp()
    with log.open("wb") as stream:
        completed = subprocess.run(
            command,
            cwd=root,
            check=False,
            stdout=stream,
            stderr=subprocess.STDOUT,
        )
    ended = timestamp()
    result = {
        "command": command,
        "startTimestamp": started,
        "endTimestamp": ended,
        "exitCode": completed.returncode,
        "result": "pass" if completed.returncode == 0 else "fail",
        "log": str(log.resolve()),
        "logSHA256": sha256_file(log),
    }
    return result


def comparison_command(
    root: Path,
    comparison_id: str,
    candidate: Path,
    capture_record: Path,
    output_stem: Path,
) -> list[str]:
    return [
        sys.executable,
        str(root / "scripts/compare-theme-captures.py"),
        "--root",
        str(root),
        "--comparison-id",
        comparison_id,
        "--candidate",
        str(candidate),
        "--capture-record",
        str(capture_record),
        "--output",
        str(output_stem),
    ]


def comparison_region_policy(plan: dict[str, Any]) -> str:
    policy = plan.get("policy")
    if policy == "responsive-regions-v1":
        return policy
    if policy is not None:
        raise CaptureError(f"unsupported authority comparison policy: {policy!r}")
    return "approved-mask" if plan.get("mask") is not None else "full-frame"


def hosted_capture_jobs(
    phase: str,
    iphone_id: str,
    ipad_id: str,
    derived: Path,
    results: Path,
    source_sha: str | None = None,
) -> list[tuple[str, list[str]]]:
    if phase not in {"baseline", "final"}:
        raise CaptureError(f"invalid hosted capture phase: {phase}")
    common = [
        "xcodebuild",
        "test",
        "-project",
        "RuneScrib.xcodeproj",
        "-configuration",
        "Release",
        "-parallel-testing-enabled",
        "NO",
        f"RUNESCRIBE_THEME_FIDELITY_PHASE={phase}",
        "ENABLE_TESTABILITY=YES",
    ]
    if source_sha is not None:
        if SOURCE_SHA_PATTERN.fullmatch(source_sha) is None:
            raise CaptureError("hosted capture source SHA is invalid")
        common.insert(2, "-disableAutomaticPackageResolution")
        common.append(f"RUNESCRIBE_THEME_FIDELITY_SOURCE_SHA={source_sha}")
    return [
        (
            "iphone",
            common
            + [
                "-scheme",
                "RuneScrib-iOS",
                "-destination",
                f"platform=iOS Simulator,id={iphone_id}",
                "-derivedDataPath",
                str(derived / "iphone"),
                "-resultBundlePath",
                str(results / "iphone.xcresult"),
                "-only-testing:RuneScribIOSTests/ThemeFidelityMatrixTests/testCaptureThemeFidelityMatrix",
            ],
        ),
        (
            "ipad",
            common
            + [
                "-scheme",
                "RuneScrib-iOS",
                "-destination",
                f"platform=iOS Simulator,id={ipad_id}",
                "-derivedDataPath",
                str(derived / "ipad"),
                "-resultBundlePath",
                str(results / "ipad.xcresult"),
                "-only-testing:RuneScribIOSTests/ThemeFidelityMatrixTests/testCaptureThemeFidelityMatrix",
            ],
        ),
        (
            "macos",
            common
            + [
                "-scheme",
                "RuneScrib-macOS-Parity",
                "-destination",
                "platform=macOS",
                "-derivedDataPath",
                str(derived / "macos"),
                "-resultBundlePath",
                str(results / "macos.xcresult"),
                "-only-testing:RuneScribMacParityTests/ThemeFidelityMatrixTests/testCaptureThemeFidelityMatrix",
            ],
        ),
    ]


def xcui_capture_jobs(
    phase: str,
    iphone_id: str,
    ipad_id: str,
    derived: Path,
    results: Path,
    source_sha: str | None = None,
) -> list[tuple[str, list[str]]]:
    if phase not in {"baseline", "final"}:
        raise CaptureError(f"invalid XCUI capture phase: {phase}")
    common = [
        "xcodebuild",
        "test",
        "-project",
        "RuneScrib.xcodeproj",
        "-configuration",
        "Release",
        "-parallel-testing-enabled",
        "NO",
        f"RUNESCRIBE_THEME_FIDELITY_PHASE={phase}",
    ]
    if source_sha is not None:
        if SOURCE_SHA_PATTERN.fullmatch(source_sha) is None:
            raise CaptureError("XCUI capture source SHA is invalid")
        common.insert(2, "-disableAutomaticPackageResolution")
        common.append(f"RUNESCRIBE_THEME_FIDELITY_SOURCE_SHA={source_sha}")
    return [
        (
            "iphone-xcui",
            common
            + [
                "-scheme",
                "RuneScrib-Theme-Fidelity-iOS-XCUI",
                "-destination",
                f"platform=iOS Simulator,id={iphone_id}",
                "-derivedDataPath",
                str(derived / "iphone-xcui"),
                "-resultBundlePath",
                str(results / "iphone-xcui.xcresult"),
                "-only-testing:RuneScribIOSUITests/ThemeFidelityAuthorityUITests/testCaptureThemeFidelityAuthority",
            ],
        ),
        (
            "ipad-xcui",
            common
            + [
                "-scheme",
                "RuneScrib-Theme-Fidelity-iOS-XCUI",
                "-destination",
                f"platform=iOS Simulator,id={ipad_id}",
                "-derivedDataPath",
                str(derived / "ipad-xcui"),
                "-resultBundlePath",
                str(results / "ipad-xcui.xcresult"),
                "-only-testing:RuneScribIOSUITests/ThemeFidelityAuthorityUITests/testCaptureThemeFidelityAuthority",
            ],
        ),
        (
            "macos-xcui",
            common
            + [
                "-scheme",
                "RuneScrib-Theme-Fidelity-macOS-XCUI",
                "-destination",
                "platform=macOS",
                "-derivedDataPath",
                str(derived / "macos-xcui"),
                "-resultBundlePath",
                str(results / "macos-xcui.xcresult"),
                "-only-testing:RuneScribMacParityUITests/ThemeFidelityAuthorityUITests/testCaptureThemeFidelityAuthority",
            ],
        ),
    ]


def capture_jobs_for_contract(
    root: Path,
    authority_contract: str,
    phase: str,
    iphone_id: str,
    ipad_id: str,
    derived: Path,
    results: Path,
    source_sha: str | None,
) -> list[tuple[str, list[str]]]:
    source_sha = resolve_contract_source_sha(authority_contract, source_sha, phase)
    jobs = hosted_capture_jobs(
        phase,
        iphone_id,
        ipad_id,
        derived,
        results,
        source_sha=source_sha,
    )
    if authority_contract == AUTHORITY_CONTRACT_V43:
        validate_v43_xcui_source_binding(root)
        jobs.extend(
            xcui_capture_jobs(
                phase,
                iphone_id,
                ipad_id,
                derived,
                results,
                source_sha=source_sha,
            )
        )
        if tuple(label for label, _ in jobs) != V43_CAPTURE_JOB_ORDER:
            raise CaptureError("v4.3 capture job order differs from the six-job contract")
        return jobs
    if authority_contract != AUTHORITY_CONTRACT_LEGACY:
        raise CaptureError(f"unsupported authority contract: {authority_contract!r}")
    if (root / V12_IMPORT_MANIFEST).is_file():
        jobs.extend(
            xcui_capture_jobs(
                phase,
                iphone_id,
                ipad_id,
                derived,
                results,
            )
        )
    return jobs


def extraction_command(
    root: Path,
    result_bundles: dict[str, Path],
    iphone: dict[str, Any],
    ipad: dict[str, Any],
    simulator_selections: Path,
    captures: Path,
    report: Path,
    authority_contract: str,
    source_sha: str | None,
) -> list[str]:
    if authority_contract not in {
        AUTHORITY_CONTRACT_LEGACY,
        AUTHORITY_CONTRACT_V43,
    }:
        raise CaptureError(f"unsupported authority contract: {authority_contract!r}")
    required_roles = (
        V43_CAPTURE_JOB_ORDER
        if authority_contract == AUTHORITY_CONTRACT_V43
        else ("iphone", "ipad", "macos")
    )
    missing = [role for role in required_roles if role not in result_bundles]
    if missing:
        raise CaptureError(
            "capture result bundles are incomplete: " + ", ".join(missing)
        )
    command = [
        sys.executable,
        str(root / "scripts/extract-theme-fidelity-captures.py"),
    ]
    for role in required_roles:
        command.extend(["--result-bundle", f"{role}={result_bundles[role]}"])
    if authority_contract == AUTHORITY_CONTRACT_LEGACY:
        for role in ("iphone-xcui", "ipad-xcui", "macos-xcui"):
            if role in result_bundles:
                command.extend(["--result-bundle", f"{role}={result_bundles[role]}"])
    command.extend(
        [
            "--expected-device",
            f"iphone={iphone['udid']}",
            "--expected-device",
            f"ipad={ipad['udid']}",
            "--expected-model",
            f"iphone={iphone['expectedModelName']}",
            "--expected-model",
            f"ipad={ipad['expectedModelName']}",
            "--simulator-selections",
            str(simulator_selections),
        ]
    )
    if authority_contract == AUTHORITY_CONTRACT_V43:
        if source_sha is None or SOURCE_SHA_PATTERN.fullmatch(source_sha) is None:
            raise CaptureError("v4.3 extraction command has no valid source SHA")
        command.extend(
            [
                "--authority-contract",
                AUTHORITY_CONTRACT_V43,
                "--source-sha",
                source_sha,
            ]
        )
    command.extend(["--output", str(captures), "--report", str(report)])
    return command


def generate_comparison_index(
    root: Path,
    matrix: Path,
    captures: Path,
    authority_manifest: Path,
    output: Path,
    log: Path,
    indexer: Any,
) -> dict[str, Any]:
    try:
        authority = json.loads(authority_manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CaptureError(f"invalid authority manifest: {error}") from error
    plans = authority.get("comparisons") if isinstance(authority, dict) else None
    if not isinstance(plans, list):
        raise CaptureError("authority manifest comparisons must be an array")
    expected_names = {
        entry["png"] for entry in indexer.expected_entries(indexer.load_matrix(matrix))
    }
    by_capture: dict[str, dict[str, Any]] = {}
    comparison_ids: set[str] = set()
    for plan in plans:
        if not isinstance(plan, dict):
            raise CaptureError("authority manifest contains an invalid comparison plan")
        capture_name = plan.get("capture")
        comparison_id = plan.get("id")
        if (
            capture_name not in expected_names
            or capture_name in by_capture
            or not isinstance(comparison_id, str)
            or not comparison_id
            or comparison_id in comparison_ids
        ):
            raise CaptureError("authority manifest must map each capture to one unique comparison id")
        by_capture[capture_name] = plan
        comparison_ids.add(comparison_id)
    if set(by_capture) != expected_names or len(by_capture) != 400:
        raise CaptureError("authority manifest must map the exact 400-capture matrix")
    authority_digest = sha256_file(authority_manifest)

    output.parent.mkdir(parents=True, exist_ok=True)
    report_root = output.parent / "comparisons"
    report_root.mkdir(parents=True, exist_ok=True)
    mappings: list[dict[str, Any]] = []
    invocations: list[dict[str, Any]] = []
    started = timestamp()
    with log.open("wb") as stream:
        for capture_name in sorted(expected_names):
            plan = by_capture[capture_name]
            stem = report_root / capture_name.removesuffix(".png")
            capture_record = captures / (
                capture_name.removesuffix(".png") + ".capture.json"
            )
            if not capture_record.is_file():
                raise CaptureError(f"capture record is missing for {capture_name}")
            command = comparison_command(
                root,
                plan["id"],
                captures / capture_name,
                capture_record,
                stem,
            )
            invocation_started = timestamp()
            completed = subprocess.run(
                command,
                cwd=root,
                check=False,
                stdout=stream,
                stderr=subprocess.STDOUT,
            )
            invocation_ended = timestamp()
            if completed.returncode != 0:
                raise CaptureError(
                    f"comparison failed for {capture_name}; see {log}"
                )
            report = Path(str(stem) + ".json")
            heatmap = Path(str(stem) + ".heatmap.png")
            try:
                report_document = json.loads(report.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise CaptureError(f"comparison report is invalid for {capture_name}: {error}") from error
            if report_document.get("result") != "PASS":
                raise CaptureError(f"comparison did not pass for {capture_name}")
            candidate_digest = sha256_file(captures / capture_name)
            capture_record_digest = sha256_file(capture_record)
            report_digest = sha256_file(report)
            heatmap_digest = sha256_file(heatmap)
            region_policy = comparison_region_policy(plan)
            mapping = {
                "capture": capture_name,
                "candidateSHA256": candidate_digest,
                "comparisonID": plan["id"],
                "regionPolicy": region_policy,
                "result": "PASS",
                "report": report.relative_to(output.parent).as_posix(),
                "reportSHA256": report_digest,
                "heatmap": heatmap.relative_to(output.parent).as_posix(),
                "heatmapSHA256": heatmap_digest,
            }
            mappings.append(mapping)
            invocations.append(
                {
                    "capture": capture_name,
                    "comparisonID": plan["id"],
                    "regionPolicy": region_policy,
                    "authorityManifestSHA256": authority_digest,
                    "command": command,
                    "startTimestamp": invocation_started,
                    "endTimestamp": invocation_ended,
                    "exitCode": completed.returncode,
                    "result": "pass",
                    "candidateSHA256": candidate_digest,
                    "captureRecord": str(capture_record.resolve()),
                    "captureRecordSHA256": capture_record_digest,
                    "report": str(report.resolve()),
                    "reportSHA256": report_digest,
                    "heatmap": str(heatmap.resolve()),
                    "heatmapSHA256": heatmap_digest,
                }
            )
    document = {"schemaVersion": "1.0", "phase": "final", "mappings": mappings}
    write_json(output, document)
    return {
        "commandTemplate": [
            sys.executable,
            str(root / "scripts/compare-theme-captures.py"),
            "--root",
            str(root),
            "--comparison-id",
            "<authority comparison id>",
            "--candidate",
            "<capture path>",
            "--capture-record",
            "<capture record path>",
            "--output",
            "<comparison output stem>",
        ],
        "startTimestamp": started,
        "endTimestamp": timestamp(),
        "exitCode": 0,
        "result": "pass",
        "invocationCount": len(mappings),
        "invocations": invocations,
        "invocationsSHA256": canonical_json_sha256(invocations),
        "authorityManifest": str(authority_manifest.resolve()),
        "authorityManifestSHA256": authority_digest,
        "log": str(log.resolve()),
        "logSHA256": sha256_file(log),
        "index": str(output.resolve()),
        "indexSHA256": sha256_file(output),
    }


def generate_v12_comparison_index(
    root: Path,
    captures: Path,
    output_root: Path,
    toolchain_report: Path,
    log: Path,
    source_exclusion: Path,
) -> tuple[Path, dict[str, Any]]:
    command = [
        sys.executable,
        str(root / "scripts/execute-theme-fidelity-authority-v12.py"),
        "--root",
        str(root),
        "--captures",
        str(captures),
        "--output-root",
        str(output_root),
        "--toolchain-report",
        str(toolchain_report),
        "--source-exclusion",
        str(source_exclusion),
    ]
    result = run_command(command, root, log)
    index = output_root / "visual-comparison-index.json"
    if not index.is_file():
        raise CaptureError("v1.2 authority execution did not produce an evidence index")
    try:
        document = json.loads(index.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CaptureError(f"v1.2 authority evidence index is invalid: {error}") from error
    result.update(
        {
            "authorityVersion": "1.2",
            "index": str(index.resolve()),
            "indexSHA256": sha256_file(index),
            "entryCount": document.get("entryCount"),
            "mappingCount": document.get("mappingCount"),
            "passingEntryCount": document.get("passingEntryCount"),
            "passingMappingCount": document.get("passingMappingCount"),
            "evidenceResult": document.get("result"),
        }
    )
    if result["exitCode"] == 0 and document.get("result") == "PASS" and (
        document.get("entryCount") != 400
        or document.get("mappingCount") != 1104
        or document.get("passingEntryCount") != 400
        or document.get("passingMappingCount") != 1104
    ):
        raise CaptureError("v1.2 authority execution lacks exact passing coverage")
    return index, result


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--phase", required=True, choices=("baseline", "final"))
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--iphone-id")
    parser.add_argument("--ipad-id")
    parser.add_argument(
        "--authority-contract",
        choices=(AUTHORITY_CONTRACT_LEGACY, AUTHORITY_CONTRACT_V43),
        default=AUTHORITY_CONTRACT_LEGACY,
        help="Use legacy v4/v4.2 behavior or the source-bound v4.3 qualification lane.",
    )
    parser.add_argument(
        "--source-sha",
        help="Exact frozen source SHA; required by --authority-contract v4.3.",
    )
    parser.add_argument(
        "--matrix",
        type=Path,
        help="Override the legacy matrix; v4.3 requires its canonical imported matrix.",
    )
    parser.add_argument(
        "--authority-manifest",
        type=Path,
        help="Override the legacy manifest; v4.3 requires its canonical import manifest.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)

    root = arguments.root.resolve()
    phase_root = (arguments.output_root / arguments.phase).resolve()
    evidence = phase_root / "evidence"
    report_path = evidence / f"{arguments.phase}-capture-run.json"
    started = timestamp()
    command_results: list[dict[str, Any]] = []
    comparison_run: dict[str, Any] | None = None
    comparison_index: Path | None = None
    capture_index: Path | None = None
    authority_validation_path: Path | None = None
    source_sha: str | None = None
    authority_contract = arguments.authority_contract
    try:
        source_sha = resolve_contract_source_sha(
            authority_contract,
            arguments.source_sha,
            arguments.phase,
        )
        matrix = resolve_matrix(root, arguments.matrix, authority_contract)
        authority_manifest = resolve_authority_manifest(
            root,
            arguments.authority_manifest,
            authority_contract,
        )
        ensure_empty_output(phase_root)
        logs = phase_root / "logs"
        results = phase_root / "results"
        captures = phase_root / "captures"
        derived = phase_root / "DerivedData"
        for directory in (logs, results, captures, evidence, derived):
            directory.mkdir(parents=True, exist_ok=True)

        indexer = load_indexer(root)
        source_before_path = evidence / f"{arguments.phase}-source-before.json"
        source_after_path = evidence / f"{arguments.phase}-source-after.json"
        source_before = indexer.source_manifest(root, [phase_root])
        indexer.validate_source_manifest_pair(source_before, source_before)
        if source_sha is not None:
            validate_frozen_source_manifest(source_before, source_sha)
        write_json(source_before_path, source_before)

        iphone = choose_simulator(root, arguments.iphone_id, "iphone")
        ipad = choose_simulator(root, arguments.ipad_id, "ipad")
        simulator_selections_path = evidence / "simulator-destinations.json"
        write_json(
            simulator_selections_path,
            {
                "schemaVersion": "1.0",
                "destinations": {"iphone": iphone, "ipad": ipad},
            },
        )
        toolchain_path = evidence / "toolchain.json"
        write_json(toolchain_path, toolchain_document(root))
        started = timestamp()

        if authority_contract == AUTHORITY_CONTRACT_V43:
            authority_validation_path = evidence / "authority-validation-v1.3.json"
            authority_command = v43_authority_validation_command(
                root,
                authority_manifest,
                authority_validation_path,
            )
            authority_result = run_command(
                authority_command,
                root,
                logs / "authority-validation-v1.3.log",
            )
            authority_result.update(
                {
                    "authorityContract": AUTHORITY_CONTRACT_V43,
                    "operation": "authority-validation",
                    "sourceSHA": source_sha,
                }
            )
            command_results.append(authority_result)
            if authority_result["exitCode"] != 0:
                raise CaptureError("v4.3 imported authority validation failed")
            validate_v43_authority_report(
                authority_validation_path,
                authority_manifest,
            )

        jobs = capture_jobs_for_contract(
            root,
            authority_contract,
            arguments.phase,
            iphone["udid"],
            ipad["udid"],
            derived,
            results,
            source_sha,
        )
        for ordinal, (label, command) in enumerate(jobs, start=1):
            command_result = run_command(command, root, logs / f"{label}.log")
            if authority_contract == AUTHORITY_CONTRACT_V43:
                command_result.update(
                    {
                        "authorityContract": AUTHORITY_CONTRACT_V43,
                        "captureJobOrdinal": ordinal,
                        "destinationRole": label,
                        "parallelTestingEnabled": False,
                        "sourceSHA": source_sha,
                    }
                )
            command_results.append(command_result)
            if command_result["exitCode"] != 0:
                raise CaptureError(f"capture command failed; see {command_result['log']}")
        build_ended = timestamp()
        result_bundles = {
            label: results / f"{label}.xcresult" for label, _ in jobs
        }

        extraction_report = evidence / "extraction.json"
        extraction_argv = extraction_command(
            root,
            result_bundles,
            iphone,
            ipad,
            simulator_selections_path,
            captures,
            extraction_report,
            authority_contract,
            source_sha,
        )
        extraction_result = run_command(
            extraction_argv,
            root,
            logs / "extraction.log",
        )
        if authority_contract == AUTHORITY_CONTRACT_V43:
            extraction_result.update(
                {
                    "authorityContract": AUTHORITY_CONTRACT_V43,
                    "operation": "six-bundle-direct-v4.3-extraction",
                    "sourceSHA": source_sha,
                }
            )
        command_results.append(extraction_result)
        if extraction_result["exitCode"] != 0:
            raise CaptureError("attachment extraction failed")
        if authority_contract == AUTHORITY_CONTRACT_V43:
            assert source_sha is not None
            validate_v43_extraction_report(
                extraction_report,
                source_sha,
                authority_manifest,
            )

        if (
            authority_contract == AUTHORITY_CONTRACT_LEGACY
            and arguments.phase == "final"
        ):
            if (root / V12_IMPORT_MANIFEST).is_file():
                comparison_index, comparison_run = generate_v12_comparison_index(
                    root,
                    captures,
                    phase_root / "authority-v1.2",
                    toolchain_path,
                    logs / "comparisons-v1.2.log",
                    phase_root,
                )
                command_results.append(comparison_run)
                if (
                    comparison_run.get("exitCode") != 0
                    or comparison_run.get("evidenceResult") != "PASS"
                ):
                    raise CaptureError(
                        "v1.2 authority execution failed; see "
                        f"{comparison_index} and {logs / 'comparisons-v1.2.log'}"
                    )
            else:
                comparison_index = evidence / "final-comparison-index.json"
                comparison_run = generate_comparison_index(
                    root,
                    matrix,
                    captures,
                    authority_manifest,
                    comparison_index,
                    logs / "comparisons.log",
                    indexer,
                )
                if (
                    comparison_run.get("invocationCount") != 400
                    or len(comparison_run.get("invocations", [])) != 400
                    or comparison_run.get("invocationsSHA256")
                    != canonical_json_sha256(comparison_run["invocations"])
                ):
                    raise CaptureError("final comparison run lacks 400 bound invocations")

        source_after = indexer.source_manifest(root, [phase_root])
        indexer.validate_source_manifest_pair(source_before, source_after)
        if source_sha is not None:
            validate_frozen_source_manifest(source_after, source_sha)
        write_json(source_after_path, source_after)

        if authority_contract == AUTHORITY_CONTRACT_LEGACY:
            capture_index = evidence / f"{arguments.phase}-capture-index.json"
            index_command = [
                sys.executable,
                str(root / "scripts/index-theme-fidelity-captures.py"),
                "--root",
                str(root),
                "--matrix",
                str(matrix),
                "--captures",
                str(captures),
                "--phase",
                arguments.phase,
                "--output",
                str(capture_index),
                "--source-manifest-before",
                str(source_before_path),
                "--source-manifest-after",
                str(source_after_path),
                "--source-exclusion",
                str(phase_root),
                "--extraction-report",
                str(extraction_report),
                "--toolchain-report",
                str(toolchain_path),
                "--authority-manifest",
                str(authority_manifest),
                "--started-at",
                started,
                "--ended-at",
                build_ended,
                *sum(
                    (["--command", json.dumps(command)] for _, command in jobs),
                    [],
                ),
                "--command",
                json.dumps(extraction_argv),
                *sum(
                    (
                        ["--command-log", str(logs / f"{label}.log")]
                        for label, _ in jobs
                    ),
                    [],
                ),
            ]
            if comparison_index is not None:
                index_command.extend(["--comparison-index", str(comparison_index)])
            index_result = run_command(index_command, root, logs / "index.log")
            command_results.append(index_result)
            if index_result["exitCode"] != 0:
                raise CaptureError("capture indexing failed")

        ended = timestamp()
        run_report = {
            "schemaVersion": "1.0",
            "phase": arguments.phase,
            "startTimestamp": started,
            "endTimestamp": ended,
            "sourceSHA": source_after["sourceSHA"],
            "sourceBinding": {
                "aggregateSHA256": source_after["aggregateSHA256"],
                "gitStatusSHA256": source_after["gitStatusSHA256"],
                "beforeManifest": str(source_before_path),
                "beforeManifestSHA256": sha256_file(source_before_path),
                "afterManifest": str(source_after_path),
                "afterManifestSHA256": sha256_file(source_after_path),
                "prePostEqual": True,
            },
            "toolchain": {
                "path": str(toolchain_path),
                "sha256": sha256_file(toolchain_path),
            },
            "destinations": {
                "iPhone portrait": iphone,
                "iPad portrait": ipad,
                "macOS standard": "hosted offscreen 720x900",
                "macOS resized": "hosted offscreen 980x720",
            },
            "result": "pass",
            "failures": [],
            "commands": command_results,
            "comparisonRun": comparison_run,
            "outputPaths": {
                "captures": str(captures),
                "extraction": str(extraction_report),
                "extractionSHA256": sha256_file(extraction_report),
                "simulatorDestinations": str(simulator_selections_path),
                "simulatorDestinationsSHA256": sha256_file(simulator_selections_path),
                "index": str(capture_index) if capture_index is not None else None,
                "indexSHA256": (
                    sha256_file(capture_index) if capture_index is not None else None
                ),
                "sourceManifestBefore": str(source_before_path),
                "sourceManifestAfter": str(source_after_path),
                "comparisonIndex": str(comparison_index) if comparison_index is not None else None,
                "comparisonIndexSHA256": (
                    sha256_file(comparison_index) if comparison_index is not None else None
                ),
            },
        }
        if authority_contract == AUTHORITY_CONTRACT_V43:
            assert source_sha is not None and authority_validation_path is not None
            run_report.update(
                {
                    "authorityContract": AUTHORITY_CONTRACT_V43,
                    "authorityBinding": {
                        "importManifest": str(authority_manifest),
                        "importManifestSHA256": sha256_file(authority_manifest),
                        "responsiveMatrix": str(matrix),
                        "responsiveMatrixSHA256": sha256_file(matrix),
                        "validationReport": str(authority_validation_path),
                        "validationReportSHA256": sha256_file(
                            authority_validation_path
                        ),
                    },
                    "captureExecution": {
                        "jobOrder": list(V43_CAPTURE_JOB_ORDER),
                        "sequential": True,
                        "parallelTestingEnabled": False,
                        "sourceSHA": source_sha,
                    },
                }
            )
        write_json(report_path, run_report)
    except (ValueError, json.JSONDecodeError, OSError) as error:
        if evidence.is_dir():
            failure = {
                "schemaVersion": "1.0",
                "phase": arguments.phase,
                "authorityContract": authority_contract,
                "sourceSHA": source_sha,
                "startTimestamp": started,
                "endTimestamp": timestamp(),
                "result": "fail",
                "failures": [str(error)],
                "commands": command_results,
                "comparisonRun": comparison_run,
            }
            write_json(report_path, failure)
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    if authority_contract == AUTHORITY_CONTRACT_V43:
        print("PASS: captured and source-bound the v4.3 responsive authority")
    else:
        print("PASS: captured and indexed the 400-entry matrix")
    print(f"REPORT: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
