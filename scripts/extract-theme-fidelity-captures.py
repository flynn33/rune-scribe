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
    from scripts.theme_fidelity_authority_v13 import (
        AuthorityV13Checker,
        DEFAULT_IMPORT_MANIFEST,
    )
    from scripts.theme_fidelity_destination_policy import (
        DestinationPolicyError,
        validate_selection,
    )
    from scripts.theme_fidelity_xcui_evidence import (
        CANDIDATE_ATTACHMENT_NAME,
        CONTRACT_PATHS,
        CONTRACT_V42,
        CONTRACT_V43,
        UI_TEST_TARGET_KIND,
        UI_TEST_TARGETS_BY_ROLE,
        XCUI_QUERY_ATTACHMENT_NAME,
        XCUI_SIDECAR_NAME,
        XCUI_TEST_IDENTIFIER,
        XCUIEvidenceError,
        expected_inventory,
        expected_inventory_for_role,
        index_entries,
        load_repository_authority,
        load_repository_candidates,
        load_repository_seeds,
        validate_sidecar,
    )
except ModuleNotFoundError:
    from theme_fidelity_authority_v13 import (  # type: ignore[no-redef]
        AuthorityV13Checker,
        DEFAULT_IMPORT_MANIFEST,
    )
    from theme_fidelity_destination_policy import (  # type: ignore[no-redef]
        DestinationPolicyError,
        validate_selection,
    )
    from theme_fidelity_xcui_evidence import (  # type: ignore[no-redef]
        CANDIDATE_ATTACHMENT_NAME,
        CONTRACT_PATHS,
        CONTRACT_V42,
        CONTRACT_V43,
        UI_TEST_TARGET_KIND,
        UI_TEST_TARGETS_BY_ROLE,
        XCUI_QUERY_ATTACHMENT_NAME,
        XCUI_SIDECAR_NAME,
        XCUI_TEST_IDENTIFIER,
        XCUIEvidenceError,
        expected_inventory,
        expected_inventory_for_role,
        index_entries,
        load_repository_authority,
        load_repository_candidates,
        load_repository_seeds,
        validate_sidecar,
    )


SCHEMA_VERSION = "1.2"
V43_SCHEMA_VERSION = "1.3"
SOURCE_SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
THEMES = ("norse", "moonleaf", "sunspire", "wildwood", "gloamthorn")
SURFACES = (
    "workspace-empty", "compose-short", "compose-long", "inscription-preview",
    "received-cipher", "share-builder", "static-share", "settings-codex-card",
    "settings-defaults-preview", "vault-locked", "vault-progress",
    "vault-encountered", "vault-owned", "vault-selected", "relic-picker",
    "seal-picker", "mastery", "high-contrast", "reduce-motion", "large-text",
)
CAPTURE_NAME = re.compile(
    r"^(norse|moonleaf|sunspire|wildwood|gloamthorn)--"
    r"([a-z0-9-]+)--"
    r"(iphone-portrait|ipad-portrait|macos-standard|macos-resized)"
    r"(?:\.png|\.capture\.json)$"
)
AUXILIARY_NAME = re.compile(
    r"^(norse|moonleaf|sunspire|wildwood|gloamthorn)--"
    r"([a-z0-9-]+)--"
    r"(iphone-portrait|ipad-portrait|macos-standard|macos-resized)--"
    r"(stability-b|renderer-output|optional-codex-locked)\.png$"
)
XCRESULT_NAME_SUFFIX = re.compile(
    r"^(?P<base>.+)_(?P<ordinal>[0-9]+)_"
    r"(?P<uuid>[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})"
    r"(?P<extension>\.png|\.json)$"
)
EXPECTED_TEST_IDENTIFIER = "ThemeFidelityMatrixTests/testCaptureThemeFidelityMatrix()"
XCODE_TEST_URL_AUTHORITY = "com.apple.xcode"
XCODE_TEST_URL_PROJECT = "RuneScrib"
BUNDLE_EXPECTATIONS = {
    "iphone": {
        "destinations": {"iphone-portrait"},
        "platform": "iOS Simulator",
        "attachmentCount": 211,
        "testIdentifier": EXPECTED_TEST_IDENTIFIER,
    },
    "ipad": {
        "destinations": {"ipad-portrait"},
        "platform": "iOS Simulator",
        "attachmentCount": 211,
        "testIdentifier": EXPECTED_TEST_IDENTIFIER,
    },
    "macos": {
        "destinations": {"macos-standard", "macos-resized"},
        "platform": "macOS",
        "modelPrefix": "Mac",
        "attachmentCount": 422,
        "testIdentifier": EXPECTED_TEST_IDENTIFIER,
    },
    "iphone-xcui": {
        "destinations": {"iphone-portrait"},
        "platform": "iOS Simulator",
        "attachmentCount": 264,
        "testIdentifier": XCUI_TEST_IDENTIFIER,
        "targetName": UI_TEST_TARGETS_BY_ROLE["iphone-xcui"],
        "targetKind": UI_TEST_TARGET_KIND,
    },
    "ipad-xcui": {
        "destinations": {"ipad-portrait"},
        "platform": "iOS Simulator",
        "attachmentCount": 264,
        "testIdentifier": XCUI_TEST_IDENTIFIER,
        "targetName": UI_TEST_TARGETS_BY_ROLE["ipad-xcui"],
        "targetKind": UI_TEST_TARGET_KIND,
    },
    "macos-xcui": {
        "destinations": {"macos-standard", "macos-resized"},
        "platform": "macOS",
        "modelPrefix": "Mac",
        "attachmentCount": 528,
        "testIdentifier": XCUI_TEST_IDENTIFIER,
        "targetName": UI_TEST_TARGETS_BY_ROLE["macos-xcui"],
        "targetKind": UI_TEST_TARGET_KIND,
    },
}
HOSTED_ROLES = frozenset({"iphone", "ipad", "macos"})
XCUI_ROLES = frozenset({"iphone-xcui", "ipad-xcui", "macos-xcui"})


class BundleBinding(NamedTuple):
    role: str
    path: Path
    expected_device_id: str | None = None
    expected_model_name: str | None = None
    destination_selection: dict[str, Any] | None = None


class ExtractionError(ValueError):
    pass


def hosted_role(role: str) -> str:
    return role.removesuffix("-xcui")


def is_xcui_role(role: str) -> bool:
    return role in XCUI_ROLES


def expected_xcui_test_identifier_url(role: str) -> str:
    if role not in XCUI_ROLES:
        raise ExtractionError(f"result bundle role is not XCUI: {role}")
    target_name = BUNDLE_EXPECTATIONS[role]["targetName"]
    test_case, test_method = XCUI_TEST_IDENTIFIER.removesuffix("()").split("/", 1)
    return (
        f"test://{XCODE_TEST_URL_AUTHORITY}/{XCODE_TEST_URL_PROJECT}/"
        f"{target_name}/{test_case}/{test_method}"
    )


def validate_xcui_test_identity(role: str, record: dict[str, Any]) -> dict[str, str]:
    expected_identifier = BUNDLE_EXPECTATIONS[role]["testIdentifier"]
    expected_url = expected_xcui_test_identifier_url(role)
    if record.get("testIdentifier") != expected_identifier:
        raise ExtractionError(
            f"{role} attachment test identifier is {record.get('testIdentifier')!r}, "
            f"expected {expected_identifier!r}"
        )
    if record.get("testIdentifierURL") != expected_url:
        raise ExtractionError(
            f"{role} attachment test identifier URL is "
            f"{record.get('testIdentifierURL')!r}, expected {expected_url!r}"
        )
    path_components = expected_url.removeprefix(
        f"test://{XCODE_TEST_URL_AUTHORITY}/"
    ).split("/")
    return {
        "projectName": path_components[0],
        "targetName": path_components[1],
        "targetKind": BUNDLE_EXPECTATIONS[role]["targetKind"],
    }


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
    base_role = hosted_role(binding.role)
    if base_role in {"iphone", "ipad"}:
        if device["modelName"] != binding.expected_model_name:
            raise ExtractionError(
                f"{binding.role} result model {device['modelName']!r} does not match exact "
                f"selected model {binding.expected_model_name!r}"
            )
    elif not device["modelName"].startswith(expectation["modelPrefix"]):
        raise ExtractionError(f"macos result model is not a Mac destination")
    if base_role == "macos" and device["architecture"] != "arm64":
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
    patterns = (
        CAPTURE_NAME,
        AUXILIARY_NAME,
        CANDIDATE_ATTACHMENT_NAME,
        XCUI_SIDECAR_NAME,
        XCUI_QUERY_ATTACHMENT_NAME,
    )
    decorated = XCRESULT_NAME_SUFFIX.fullmatch(suggested)
    if decorated is not None:
        candidate = decorated.group("base") + decorated.group("extension")
        if XCRESULT_NAME_SUFFIX.fullmatch(candidate) is not None:
            return None
        return candidate if any(pattern.fullmatch(candidate) for pattern in patterns) else None
    return suggested if any(pattern.fullmatch(suggested) for pattern in patterns) else None


def destination_slug(name: str) -> str:
    match = (
        CAPTURE_NAME.fullmatch(name)
        or AUXILIARY_NAME.fullmatch(name)
        or CANDIDATE_ATTACHMENT_NAME.fullmatch(name)
        or XCUI_SIDECAR_NAME.fullmatch(name)
        or XCUI_QUERY_ATTACHMENT_NAME.fullmatch(name)
    )
    if match is None:
        raise ExtractionError(f"attachment name is not canonical: {name}")
    return match.group(3)


def expected_attachment_names(
    role: str,
    authority_contract: str = CONTRACT_V42,
) -> set[str]:
    if role in XCUI_ROLES:
        if authority_contract not in {CONTRACT_V42, CONTRACT_V43}:
            raise ExtractionError(
                f"unsupported authority contract: {authority_contract!r}"
            )
        repository_root = Path(__file__).resolve().parents[1]
        authority, probes = load_repository_authority(
            repository_root,
            authority_contract,
        )
        candidates = load_repository_candidates(
            repository_root,
            authority_contract,
        )
        return set(
            expected_inventory_for_role(
                authority,
                probes,
                role,
                candidates=candidates,
                contract_version=authority_contract,
            ).attachments
        )
    destinations = BUNDLE_EXPECTATIONS[role]["destinations"]
    expected: set[str] = set()
    for destination in destinations:
        for theme in THEMES:
            for surface in SURFACES:
                stem = f"{theme}--{surface}--{destination}"
                expected.add(f"{stem}.png")
                expected.add(f"{stem}.capture.json")
            expected.add(f"{theme}--reduce-motion--{destination}--stability-b.png")
            expected.add(f"{theme}--static-share--{destination}--renderer-output.png")
        expected.add(f"norse--vault-locked--{destination}--optional-codex-locked.png")
    return expected


def authority_provenance(
    repository_root: Path,
    authority_contract: str,
) -> dict[str, Any]:
    specification = CONTRACT_PATHS.get(authority_contract)
    if specification is None:
        raise ExtractionError(f"unsupported authority contract: {authority_contract!r}")
    files: dict[str, dict[str, str]] = {}
    for key in ("authority", "probes", "seeds", "candidates"):
        relative = specification[key]
        if not isinstance(relative, Path):
            raise ExtractionError(f"authority contract path is invalid: {key}")
        path = (repository_root / relative).resolve()
        if not path.is_file() or path.is_symlink():
            raise ExtractionError(f"authority contract file is missing or linked: {path}")
        files[key] = {
            "path": relative.as_posix(),
            "sha256": sha256_file(path),
        }
    return {
        "contractVersion": authority_contract,
        "schemaVersion": specification["schemaVersion"],
        "files": files,
    }


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


def validate_bindings(bindings: list[BundleBinding], require_xcui: bool = False) -> None:
    roles = [binding.role for binding in bindings]
    expected_roles = HOSTED_ROLES | XCUI_ROLES if require_xcui else HOSTED_ROLES
    if len(roles) != len(expected_roles) or set(roles) != expected_roles:
        raise ExtractionError(
            "result bundle roles must be exactly once each: "
            + ", ".join(sorted(expected_roles))
        )
    if len({binding.path.resolve() for binding in bindings}) != len(bindings):
        raise ExtractionError("result bundle paths must be distinct")
    for binding in bindings:
        base_role = hosted_role(binding.role)
        if base_role in {"iphone", "ipad"}:
            if not binding.expected_device_id:
                raise ExtractionError(f"{binding.role} result bundle requires an expected device ID")
            if not binding.expected_model_name:
                raise ExtractionError(
                    f"{binding.role} result bundle requires an exact expected model name"
                )
            try:
                validate_selection(
                    binding.destination_selection,
                    base_role,
                    binding.expected_device_id,
                    binding.expected_model_name,
                )
            except DestinationPolicyError as error:
                raise ExtractionError(str(error)) from error


def extract(
    bindings: list[BundleBinding],
    output: Path,
    simulator_selection_source: dict[str, Any] | None = None,
    require_xcui: bool | None = None,
    authority_contract: str = CONTRACT_V42,
    source_sha: str | None = None,
) -> dict[str, Any]:
    if authority_contract not in {CONTRACT_V42, CONTRACT_V43}:
        raise ExtractionError(f"unsupported authority contract: {authority_contract!r}")
    if authority_contract == CONTRACT_V43:
        if source_sha is None or SOURCE_SHA_PATTERN.fullmatch(source_sha) is None:
            raise ExtractionError(
                "v4.3 extraction requires --source-sha as exactly 40 lowercase hex characters"
            )
        if require_xcui is False:
            raise ExtractionError("v4.3 extraction requires all three XCUI result bundles")
        require_xcui = True
    elif source_sha is not None:
        raise ExtractionError("--source-sha is only valid with --authority-contract v4.3")
    if require_xcui is None:
        require_xcui = any(is_xcui_role(binding.role) for binding in bindings)
    validate_bindings(bindings, require_xcui=require_xcui)
    repository_root = Path(__file__).resolve().parents[1]
    authority: dict[str, Any] | None = None
    probes: dict[str, dict[str, Any]] | None = None
    seeds: dict[str, dict[str, Any]] | None = None
    candidates: dict[str, dict[str, Any]] | None = None
    authority_entries: dict[str, dict[str, Any]] = {}
    inventory = None
    source_authority: dict[str, Any] | None = None
    source_probes: dict[str, dict[str, Any]] | None = None
    source_seeds: dict[str, dict[str, Any]] | None = None
    source_candidates: dict[str, dict[str, Any]] | None = None
    source_authority_entries: dict[str, dict[str, Any]] = {}
    authority_validation: dict[str, Any] | None = None
    target_authority_provenance: dict[str, Any] | None = None
    source_authority_provenance: dict[str, Any] | None = None
    if require_xcui:
        try:
            if authority_contract == CONTRACT_V43:
                authority_validation = AuthorityV13Checker(
                    repository_root,
                    repository_root / DEFAULT_IMPORT_MANIFEST,
                ).run()
                if authority_validation.get("result") != "PASS":
                    raise ExtractionError(
                        "v4.3 authority import is invalid: "
                        + json.dumps(
                            authority_validation.get("findings", [])[:5],
                            sort_keys=True,
                        )
                    )
                target_authority_provenance = authority_provenance(
                    repository_root, CONTRACT_V43
                )
                source_authority_provenance = authority_provenance(
                    repository_root, CONTRACT_V43
                )
            authority, probes = load_repository_authority(
                repository_root, authority_contract
            )
            seeds = load_repository_seeds(repository_root, authority_contract)
            candidates = load_repository_candidates(
                repository_root, authority_contract
            )
            authority_entries = index_entries(authority)
            inventory = expected_inventory(
                authority,
                probes,
                candidates=candidates,
                contract_version=authority_contract,
            )
            source_authority, source_probes = load_repository_authority(
                repository_root, authority_contract
            )
            source_seeds = load_repository_seeds(repository_root, authority_contract)
            source_candidates = load_repository_candidates(
                repository_root, authority_contract
            )
            source_authority_entries = index_entries(source_authority)
        except XCUIEvidenceError as error:
            raise ExtractionError(str(error)) from error
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise ExtractionError(f"authority contract could not be read: {error}") from error
    output.mkdir(parents=True, exist_ok=True)
    existing = [
        path.name for path in output.iterdir()
        if any(
            pattern.fullmatch(path.name)
            for pattern in (
                CAPTURE_NAME,
                AUXILIARY_NAME,
                CANDIDATE_ATTACHMENT_NAME,
                XCUI_SIDECAR_NAME,
                XCUI_QUERY_ATTACHMENT_NAME,
            )
        )
    ]
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
            expected_test_identifier = BUNDLE_EXPECTATIONS[binding.role]["testIdentifier"]
            if len(manifest) != 1 or manifest[0].get("testIdentifier") != expected_test_identifier:
                identifiers = [record.get("testIdentifier") for record in manifest]
                raise ExtractionError(
                    f"{binding.role} attachment test identifiers are {identifiers!r}, "
                    f"expected exactly {expected_test_identifier!r}"
                )
            source_test_identity: dict[str, str] | None = None
            if is_xcui_role(binding.role):
                source_test_identity = validate_xcui_test_identity(
                    binding.role,
                    manifest[0],
                )
            manifest_path = exported / "manifest.json"
            if not manifest_path.is_file():
                raise ExtractionError(f"attachment export omitted manifest.json: {result_bundle}")
            if is_xcui_role(binding.role):
                assert (
                    authority is not None
                    and probes is not None
                    and candidates is not None
                    and source_authority is not None
                    and source_probes is not None
                    and source_seeds is not None
                    and source_candidates is not None
                )
                target_inventory = expected_inventory_for_role(
                    authority,
                    probes,
                    binding.role,
                    candidates=candidates,
                    contract_version=authority_contract,
                )
                source_inventory = expected_inventory_for_role(
                    source_authority,
                    source_probes,
                    binding.role,
                    candidates=source_candidates,
                    contract_version=authority_contract,
                )
                target_names = set(target_inventory.attachments)
                expected_source_names = set(source_inventory.attachments)
            else:
                target_inventory = None
                source_inventory = None
                target_names = expected_attachment_names(binding.role)
                expected_source_names = target_names

            role_sources: dict[str, tuple[Path, dict[str, Any]]] = {}
            raw_attachment_records: dict[str, dict[str, Any]] = {}
            raw_capture_root = temporary_root / f"raw-{index}"
            if is_xcui_role(binding.role):
                raw_capture_root.mkdir()
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
                if attachment.get("testIdentifier") != expected_test_identifier:
                    raise ExtractionError(
                        f"attachment belongs to unexpected test: {attachment.get('testIdentifier')!r}"
                    )
                if is_xcui_role(binding.role):
                    attachment_identity = validate_xcui_test_identity(
                        binding.role,
                        attachment,
                    )
                    if attachment_identity != source_test_identity:
                        raise ExtractionError(
                            f"{binding.role} attachment source test identity changed"
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
                digest = sha256_file(source)
                if canonical_name in role_sources:
                    raise ExtractionError(
                        "duplicate canonical attachment name in result bundle: "
                        f"{canonical_name}"
                    )
                metadata = {
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
                if is_xcui_role(binding.role):
                    assert source_test_identity is not None
                    metadata.update(
                        {
                            "sourceTargetName": source_test_identity["targetName"],
                            "sourceTargetKind": source_test_identity["targetKind"],
                            "sourceProjectName": source_test_identity["projectName"],
                        }
                    )
                    shutil.copyfile(source, raw_capture_root / canonical_name)
                    raw_attachment_records[canonical_name] = dict(metadata)
                role_sources[canonical_name] = (source, metadata)

            expected_source_count = len(expected_source_names)
            if len(role_sources) != expected_source_count:
                raise ExtractionError(
                    f"{binding.role} result bundle produced {len(role_sources)} matrix attachments, "
                    f"expected {expected_source_count}"
                )
            source_names = set(role_sources)
            if source_names != expected_source_names:
                missing = sorted(expected_source_names - source_names)
                extra = sorted(source_names - expected_source_names)
                raise ExtractionError(
                    f"{binding.role} source attachment set differs; "
                    f"missing={missing[:8]}, extra={extra[:8]}"
                )

            validated_source_sidecars: dict[str, dict[str, Any]] = {}
            if is_xcui_role(binding.role):
                assert source_inventory is not None
                entries_by_sidecar = {
                    (
                        f"{entry['theme'].lower()}--{entry['surface']}--"
                        f"{entry['destination']}.xcui.json"
                    ): entry
                    for entry in source_authority_entries.values()
                }
                for name in sorted(source_inventory.sidecars):
                    entry = entries_by_sidecar.get(name)
                    if entry is None:
                        raise ExtractionError(
                            "source XCUI sidecar is not bound to "
                            f"{authority_contract} authority: {name}"
                        )
                    try:
                        validated = validate_sidecar(
                            raw_capture_root / name,
                            entry,
                            source_probes,
                            source_seeds,
                            source_candidates,
                            raw_capture_root,
                            raw_attachment_records,
                            contract_version=authority_contract,
                        )
                    except XCUIEvidenceError as error:
                        raise ExtractionError(str(error)) from error
                    validated_source_sidecars[name] = validated.document

            if not target_names.issubset(source_names):
                missing = sorted(target_names - source_names)
                raise ExtractionError(
                    f"{binding.role} source cannot satisfy {authority_contract}; "
                    f"missing={missing[:8]}"
                )
            for canonical_name in sorted(target_names):
                source, source_metadata = role_sources[canonical_name]
                if canonical_name in copied:
                    raise ExtractionError(
                        "duplicate canonical attachment name across result bundles: "
                        f"{canonical_name}"
                    )
                destination = output / canonical_name
                metadata = dict(source_metadata)
                shutil.copyfile(source, destination)
                validate_attachment_content(destination, canonical_name)
                if authority_contract == CONTRACT_V43 and is_xcui_role(binding.role):
                    metadata.update(
                        {
                            "sourceAttachmentSHA256": source_metadata["sha256"],
                            "sourceAttachmentBytes": source_metadata["bytes"],
                            "sourceAuthorityContract": CONTRACT_V43,
                            "evidenceAuthorityContract": CONTRACT_V43,
                            "extractionOperation": "direct-copy",
                        }
                    )
                metadata["sha256"] = sha256_file(destination)
                metadata["bytes"] = destination.stat().st_size
                copied[canonical_name] = metadata

            selected_count = len(target_names)
            bundles.append(
                {
                    "role": binding.role,
                    "path": str(result_bundle),
                    "sha256": result_bundle_digest(result_bundle),
                    "selectedAttachmentCount": selected_count,
                    "expectedTestIdentifier": expected_test_identifier,
                    "expectedTestIdentifierURL": (
                        expected_xcui_test_identifier_url(binding.role)
                        if is_xcui_role(binding.role) else None
                    ),
                    "outcome": "Passed",
                    "summarySHA256": canonical_json_sha256(summary),
                    "attachmentManifestSHA256": canonical_json_sha256(manifest),
                    "resultSummary": summary,
                    "attachmentManifest": manifest,
                    "destinationSelection": binding.destination_selection,
                    **provenance,
                }
            )
            if authority_contract == CONTRACT_V43:
                bundles[-1]["sourceAttachmentCount"] = len(source_names)
                if is_xcui_role(binding.role):
                    bundles[-1].update(
                        {
                            "sourceAuthorityContract": CONTRACT_V43,
                            "evidenceAuthorityContract": CONTRACT_V43,
                            "extractionOperation": "direct-copy",
                            "validatedSourceXCUISidecarCount": len(
                                validated_source_sidecars
                            ),
                        }
                    )

    validated_sidecars: list[dict[str, Any]] = []
    if require_xcui:
        assert (
            authority is not None
            and probes is not None
            and seeds is not None
            and candidates is not None
            and inventory is not None
        )
        actual_xcui = {
            name
            for name in copied
            if CANDIDATE_ATTACHMENT_NAME.fullmatch(name)
            or XCUI_SIDECAR_NAME.fullmatch(name)
            or XCUI_QUERY_ATTACHMENT_NAME.fullmatch(name)
        }
        if actual_xcui != set(inventory.attachments):
            missing = sorted(set(inventory.attachments) - actual_xcui)
            extra = sorted(actual_xcui - set(inventory.attachments))
            raise ExtractionError(
                "XCUI attachment set differs; "
                f"missing={missing[:8]}, extra={extra[:8]}"
            )
        entries_by_sidecar = {
            f"{entry['theme'].lower()}--{entry['surface']}--{entry['destination']}.xcui.json": entry
            for entry in authority_entries.values()
        }
        for name in sorted(inventory.sidecars):
            entry = entries_by_sidecar.get(name)
            if entry is None:
                raise ExtractionError(f"XCUI sidecar is not bound to an authority entry: {name}")
            try:
                validated = validate_sidecar(
                    output / name,
                    entry,
                    probes,
                    seeds,
                    candidates,
                    output,
                    copied,
                    contract_version=authority_contract,
                )
            except XCUIEvidenceError as error:
                raise ExtractionError(str(error)) from error
            validated_sidecars.append(
                {
                    "name": name,
                    "sha256": validated.sha256,
                    "entryID": entry["id"],
                    "sourceTest": validated.source_test,
                    "deterministicSeed": validated.deterministic_seed,
                    "candidateElementCaptureCount": len(validated.candidate_captures),
                    "structuralWitnessCount": len(validated.structural_witnesses),
                    "xcuiProbeEvidenceCount": len(validated.probe_evidence),
                }
            )

    png_count = sum(CAPTURE_NAME.fullmatch(name) is not None and name.endswith(".png") for name in copied)
    auxiliary_png_count = sum(AUXILIARY_NAME.fullmatch(name) is not None for name in copied)
    record_count = sum(name.endswith(".capture.json") for name in copied)
    candidate_png_count = sum(
        CANDIDATE_ATTACHMENT_NAME.fullmatch(name) is not None for name in copied
    )
    xcui_query_png_count = sum(
        XCUI_QUERY_ATTACHMENT_NAME.fullmatch(name) is not None for name in copied
    )
    xcui_sidecar_count = sum(
        XCUI_SIDECAR_NAME.fullmatch(name) is not None for name in copied
    )
    if png_count != 400 or auxiliary_png_count != 44 or record_count != 400:
        raise ExtractionError(
            "expected 400 primary PNG, 44 auxiliary PNG, and 400 capture records; "
            f"found {png_count}, {auxiliary_png_count}, and {record_count}"
        )
    if require_xcui:
        assert inventory is not None
        expected_xcui_counts = (
            len(inventory.candidate_pngs),
            len(inventory.query_pngs),
            len(inventory.sidecars),
            844 + len(inventory.attachments),
        )
        actual_xcui_counts = (
            candidate_png_count,
            xcui_query_png_count,
            xcui_sidecar_count,
            len(copied),
        )
        if actual_xcui_counts != expected_xcui_counts:
            raise ExtractionError(
                f"expected {expected_xcui_counts[0]} candidate PNG, "
                f"{expected_xcui_counts[1]} XCUI query PNG, and "
                f"{expected_xcui_counts[2]} XCUI sidecars in "
                f"{expected_xcui_counts[3]} attachments; found "
                f"{actual_xcui_counts[0]}, {actual_xcui_counts[1]}, "
                f"{actual_xcui_counts[2]}, and {actual_xcui_counts[3]}"
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
    report = {
        "schemaVersion": SCHEMA_VERSION if require_xcui else "1.1",
        "result": "pass",
        "captureRoot": str(output.resolve()),
        "pngCount": png_count,
        "auxiliaryPNGCount": auxiliary_png_count,
        "recordCount": record_count,
        "candidatePNGCount": candidate_png_count,
        "xcuiQueryPNGCount": xcui_query_png_count,
        "xcuiSidecarCount": xcui_sidecar_count,
        "attachmentCount": len(copied),
        "expectedTestIdentifier": EXPECTED_TEST_IDENTIFIER,
        "expectedXCUITestIdentifier": XCUI_TEST_IDENTIFIER if require_xcui else None,
        "xcresulttool": tool.stdout.strip(),
        "simulatorSelectionSource": simulator_selection_source,
        "resultBundles": bundles,
        "xcuiSidecars": validated_sidecars,
        "attachments": [copied[name] for name in sorted(copied)],
    }
    if authority_contract == CONTRACT_V43:
        assert (
            source_sha is not None
            and authority_validation is not None
            and target_authority_provenance is not None
            and source_authority_provenance is not None
        )
        report.update(
            {
                "schemaVersion": V43_SCHEMA_VERSION,
                "sourceSHA": source_sha,
                "authorityContract": CONTRACT_V43,
                "sourceXCUIContract": CONTRACT_V43,
                "authorityValidation": authority_validation,
                "authorityProvenance": target_authority_provenance,
                "sourceXCUIAuthorityProvenance": source_authority_provenance,
            }
        )
    return report


def parse_binding(
    raw: str,
    expected_devices: dict[str, str],
    expected_models: dict[str, str],
    selections: dict[str, dict[str, Any]],
) -> BundleBinding:
    role, separator, path = raw.partition("=")
    if not separator or role not in BUNDLE_EXPECTATIONS or not path:
        raise ExtractionError(
            "--result-bundle must use ROLE=PATH for hosted or matching -xcui roles"
        )
    base_role = hosted_role(role)
    return BundleBinding(
        role,
        Path(path),
        expected_devices.get(base_role),
        expected_models.get(base_role),
        selections.get(base_role),
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
    parser.add_argument(
        "--authority-contract",
        choices=(CONTRACT_V42, CONTRACT_V43),
        default=CONTRACT_V42,
        help="Evidence authority used for direct attachment extraction.",
    )
    parser.add_argument(
        "--source-sha",
        help="Exact tested application source SHA; required for v4.3 extraction.",
    )
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
        report = extract(
            bindings,
            arguments.output,
            selection_source,
            authority_contract=arguments.authority_contract,
            source_sha=arguments.source_sha,
        )
        write_json(report_path, report)
    except ExtractionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: extracted "
        f"{report['pngCount']} primary PNG captures, "
        f"{report['auxiliaryPNGCount']} auxiliary PNG captures, "
        f"{report['recordCount']} records, "
        f"{report['candidatePNGCount']} candidate element PNGs, "
        f"{report['xcuiQueryPNGCount']} XCUI query PNGs, and "
        f"{report['xcuiSidecarCount']} XCUI sidecars"
    )
    print(f"REPORT: {report_path.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
