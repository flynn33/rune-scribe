#!/usr/bin/env python3
"""Assemble source-bound Theme-fidelity v4.2 acceptance evidence.

The capture runner is the authority for visual, structural, runtime, and
destination results.  Non-visual gates enter through a strict qualification
result document whose executions bind an exit code, source SHA, command, and
the SHA-256 of every supplied artifact.  This module never infers success from
the existence of a file.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = "1.0"
SOURCE_SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
PASS_VALUES = {"pass", "passed", "success", "succeeded"}
EXPECTED_ENTRY_COUNT = 400
EXPECTED_MAPPING_COUNT = 1104
EXPECTED_GATE_COUNT = 40
EXPECTED_THEMES = ("Norse", "Moonleaf", "Sunspire", "Wildwood", "Gloamthorn")
EXPECTED_DESTINATIONS = (
    "iphone-portrait",
    "ipad-portrait",
    "macos-standard",
    "macos-resized",
)
EXPECTED_SURFACE_COUNT = 20
DEFAULT_OUTPUT_ROOT = Path("docs/verification/theme-fidelity-v4")
DEFAULT_IMPORT_MANIFEST = DEFAULT_OUTPUT_ROOT / "authority/v4.2/IMPORT-MANIFEST.json"
DEFAULT_GATE_CATALOG = (
    DEFAULT_OUTPUT_ROOT / "authority/v4.2/04-VERIFICATION-PATCH/Gate-Catalog-v4.2.json"
)
DEFAULT_AUTHORITY = (
    DEFAULT_OUTPUT_ROOT
    / "authority/v4.2/02-COMPARISON-AUTHORITY/Comparison-Authority-v1.2.json"
)
DEFAULT_ASSET_MANIFEST = (
    DEFAULT_OUTPUT_ROOT
    / "authority/v4.2/03-AUTHORITY-ASSETS/AUTHORITY-ASSET-MANIFEST-v1.2.json"
)
REQUIRED_DIRECTORIES = (
    "authority",
    "baseline",
    "final",
    "comparisons",
    "focal-captures",
    "heatmaps",
    "reduce-motion",
    "responsive-layout",
    "negative-mutations",
    "test-runs",
    "source-manifests",
)


class EvidenceError(ValueError):
    """Raised when evidence cannot be proven from the supplied inputs."""


def reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise EvidenceError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as stream:
            value = json.load(stream, object_pairs_hook=reject_duplicate_keys)
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceError(f"unable to read {label}: {error}") from error
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be a JSON object")
    return value


def canonical_json_bytes(value: Any) -> bytes:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise EvidenceError(f"value is not canonical JSON: {error}") from error


def canonical_json_sha256(value: Any) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise EvidenceError(f"unable to hash {path}: {error}") from error
    return digest.hexdigest()


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value:
        raise EvidenceError(f"{label} must be an ISO-8601 timestamp")
    try:
        decoded = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError(f"{label} must be an ISO-8601 timestamp") from error
    if decoded.tzinfo is None:
        raise EvidenceError(f"{label} must include a time zone")
    return decoded


def is_pass(value: Any) -> bool:
    return isinstance(value, str) and value.casefold() in PASS_VALUES


def require_pass_record(value: Mapping[str, Any], label: str) -> None:
    result = value.get("result", value.get("status", value.get("outcome")))
    if not is_pass(result):
        raise EvidenceError(f"{label} does not report PASS")
    failures = value.get("failures", [])
    if not isinstance(failures, list) or failures:
        raise EvidenceError(f"{label} reports failures")
    if "exitCode" in value and value.get("exitCode") != 0:
        raise EvidenceError(f"{label} exitCode is not zero")


def resolve_regular_file(raw: Any, base: Path, label: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise EvidenceError(f"{label} path is missing")
    path = Path(raw)
    path = path.resolve() if path.is_absolute() else (base / path).resolve()
    if not path.is_file() or path.is_symlink():
        raise EvidenceError(f"{label} is not a regular file: {path}")
    return path


def verify_file_binding(
    raw_path: Any,
    raw_digest: Any,
    base: Path,
    label: str,
) -> Path:
    path = resolve_regular_file(raw_path, base, label)
    if not isinstance(raw_digest, str) or SHA256_PATTERN.fullmatch(raw_digest) is None:
        raise EvidenceError(f"{label} SHA-256 is invalid")
    if sha256_file(path) != raw_digest:
        raise EvidenceError(f"{label} SHA-256 does not match")
    return path


def git_text(root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise EvidenceError(f"git {' '.join(arguments)} failed: {detail}")
    return completed.stdout.strip()


def relative_to(path: Path, root: Path, label: str) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as error:
        raise EvidenceError(f"{label} is outside {root}: {path}") from error


def import_module(path: Path, name: str) -> Any:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise EvidenceError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


@dataclass(frozen=True)
class Context:
    root: Path
    output_root: Path
    source_sha: str
    authority_sha: str
    asset_manifest_sha: str
    command: list[str]
    start_timestamp: str
    end_timestamp: str
    toolchain: dict[str, Any]

    def metadata(self, destination: str) -> dict[str, Any]:
        return {
            "schemaVersion": SCHEMA_VERSION,
            "sourceSHA": self.source_sha,
            "comparisonAuthoritySHA256": self.authority_sha,
            "authorityAssetManifestSHA256": self.asset_manifest_sha,
            "command": self.command,
            "startTimestamp": self.start_timestamp,
            "endTimestamp": self.end_timestamp,
            "destination": destination,
            "toolchain": self.toolchain,
        }


@dataclass
class CaptureEvidence:
    run_path: Path
    run: dict[str, Any]
    index_path: Path
    index: dict[str, Any]
    source_before_path: Path
    source_after_path: Path
    source_manifest: dict[str, Any]
    records_by_entry: dict[str, dict[str, Any]]


@dataclass(frozen=True)
class ExternalArtifact:
    logical_name: str
    path: Path
    sha256: str
    kind: str
    execution_id: str
    gate_ids: tuple[str, ...]


def validate_current_source(root: Path, output_root: Path, source_sha: str) -> str:
    head = git_text(root, "rev-parse", "HEAD")
    if head != source_sha:
        raise EvidenceError("current HEAD differs from the final capture source SHA")
    if git_text(root, "diff", "--name-only", "HEAD", "--"):
        raise EvidenceError("tracked source changed after the final capture")
    relative_output = relative_to(output_root, root, "evidence output root")
    status = git_text(
        root,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--",
        ".",
        f":(exclude){relative_output}",
    )
    if status:
        raise EvidenceError("source worktree has changes outside the evidence output root")
    return (
        "command: git status --porcelain=v1 --untracked-files=all -- . "
        f"':(exclude){relative_output}'\n"
        f"sourceSHA: {source_sha}\n"
        "sourceOnlyResult: CLEAN\n"
    )


def validate_capture_evidence(
    root: Path,
    output_root: Path,
    capture_run_path: Path,
) -> CaptureEvidence:
    run = load_json(capture_run_path, "final capture run")
    if run.get("phase") != "final":
        raise EvidenceError("capture run phase is not final")
    require_pass_record(run, "final capture run")
    source_sha = run.get("sourceSHA")
    if not isinstance(source_sha, str) or SOURCE_SHA_PATTERN.fullmatch(source_sha) is None:
        raise EvidenceError("capture run sourceSHA is invalid")
    if not capture_run_path.resolve().is_relative_to((output_root / "final").resolve()):
        raise EvidenceError("capture run is outside the current final evidence directory")

    source_binding = run.get("sourceBinding")
    if not isinstance(source_binding, dict) or source_binding.get("prePostEqual") is not True:
        raise EvidenceError("capture run lacks an equal pre/post source binding")
    source_before_path = verify_file_binding(
        source_binding.get("beforeManifest"),
        source_binding.get("beforeManifestSHA256"),
        root,
        "capture source-before manifest",
    )
    source_after_path = verify_file_binding(
        source_binding.get("afterManifest"),
        source_binding.get("afterManifestSHA256"),
        root,
        "capture source-after manifest",
    )
    source_before = load_json(source_before_path, "capture source-before manifest")
    source_after = load_json(source_after_path, "capture source-after manifest")
    if source_before != source_after:
        raise EvidenceError("capture source changed between the pre/post manifests")
    if (
        source_after.get("sourceSHA") != source_sha
        or source_after.get("isClean") is not True
        or source_after.get("aggregateSHA256") != source_binding.get("aggregateSHA256")
        or source_after.get("gitStatusSHA256") != source_binding.get("gitStatusSHA256")
    ):
        raise EvidenceError("capture source manifest differs from its run binding")

    commands = run.get("commands")
    if not isinstance(commands, list) or len(commands) < 8:
        raise EvidenceError("capture run lacks the required hosted, XCUI, extraction, and index commands")
    for index, command in enumerate(commands):
        if not isinstance(command, dict):
            raise EvidenceError(f"capture command {index} is invalid")
        require_pass_record(command, f"capture command {index}")
        if command.get("exitCode") != 0:
            raise EvidenceError(f"capture command {index} did not exit zero")
        verify_file_binding(
            command.get("log"), command.get("logSHA256"), root, f"capture command {index} log"
        )

    comparison_run = run.get("comparisonRun")
    if not isinstance(comparison_run, dict):
        raise EvidenceError("capture run lacks v1.2 comparison execution")
    require_pass_record(comparison_run, "v1.2 comparison execution")
    if (
        comparison_run.get("exitCode") != 0
        or comparison_run.get("authorityVersion") != "1.2"
        or comparison_run.get("entryCount") != EXPECTED_ENTRY_COUNT
        or comparison_run.get("mappingCount") != EXPECTED_MAPPING_COUNT
        or comparison_run.get("passingEntryCount") != EXPECTED_ENTRY_COUNT
        or comparison_run.get("passingMappingCount") != EXPECTED_MAPPING_COUNT
        or comparison_run.get("evidenceResult") != "PASS"
    ):
        raise EvidenceError("v1.2 comparison execution lacks exact passing coverage")

    output_paths = run.get("outputPaths")
    if not isinstance(output_paths, dict):
        raise EvidenceError("capture run outputPaths is invalid")
    index_path = verify_file_binding(
        output_paths.get("comparisonIndex"),
        output_paths.get("comparisonIndexSHA256"),
        root,
        "visual comparison index",
    )
    index_document = load_json(index_path, "visual comparison index")
    require_pass_record(index_document, "visual comparison index")
    authority_path = root / DEFAULT_AUTHORITY
    asset_manifest_path = root / DEFAULT_ASSET_MANIFEST
    authority_sha = sha256_file(authority_path)
    asset_manifest_sha = sha256_file(asset_manifest_path)
    if (
        index_document.get("schemaVersion") != "1.2"
        or index_document.get("sourceSHA") != source_sha
        or index_document.get("comparisonAuthoritySHA256") != authority_sha
        or index_document.get("authorityAssetManifestSHA256") != asset_manifest_sha
        or index_document.get("entryCount") != EXPECTED_ENTRY_COUNT
        or index_document.get("mappingCount") != EXPECTED_MAPPING_COUNT
        or index_document.get("passingEntryCount") != EXPECTED_ENTRY_COUNT
        or index_document.get("passingMappingCount") != EXPECTED_MAPPING_COUNT
    ):
        raise EvidenceError("visual comparison index summary differs from exact v1.2 authority")

    entries = index_document.get("entries")
    if not isinstance(entries, list) or len(entries) != EXPECTED_ENTRY_COUNT:
        raise EvidenceError("visual comparison index must contain exactly 400 entries")
    entry_ids: set[str] = set()
    mapping_ids: set[str] = set()
    total_mappings = 0
    records_by_entry: dict[str, dict[str, Any]] = {}
    for ordinal, entry in enumerate(entries):
        label = f"visual comparison entry {ordinal}"
        if not isinstance(entry, dict):
            raise EvidenceError(f"{label} is invalid")
        require_pass_record(entry, label)
        entry_id = entry.get("entryID")
        if not isinstance(entry_id, str) or not entry_id or entry_id in entry_ids:
            raise EvidenceError(f"{label} has an invalid or duplicate entryID")
        entry_ids.add(entry_id)
        if entry.get("theme") not in EXPECTED_THEMES or entry.get("destination") not in EXPECTED_DESTINATIONS:
            raise EvidenceError(f"{label} has an undeclared theme or destination")
        capture = entry.get("capture")
        if not isinstance(capture, dict):
            raise EvidenceError(f"{label} capture binding is invalid")
        verify_file_binding(capture.get("path"), capture.get("sha256"), root, f"{label} capture")
        record_path = verify_file_binding(
            capture.get("record"), capture.get("recordSHA256"), root, f"{label} capture record"
        )
        record = load_json(record_path, f"{label} capture record")
        if record.get("themeName") != entry.get("theme") or record.get("surface") != entry.get("surface"):
            raise EvidenceError(f"{label} capture record identity differs")
        records_by_entry[entry_id] = record
        layout = entry.get("responsiveLayout")
        if not isinstance(layout, dict):
            raise EvidenceError(f"{label} responsive layout binding is invalid")
        layout_path = verify_file_binding(
            layout.get("path"), layout.get("sha256"), root, f"{label} responsive layout"
        )
        layout_document = load_json(layout_path, f"{label} responsive layout")
        require_pass_record(layout_document, f"{label} responsive layout")
        assertions = layout_document.get("assertions")
        if not isinstance(assertions, list) or any(
            not isinstance(item, dict) or item.get("result") != "PASS" for item in assertions
        ):
            raise EvidenceError(f"{label} contains a failed responsive assertion")
        mappings = entry.get("mappingResults")
        if not isinstance(mappings, list):
            raise EvidenceError(f"{label} mappingResults is invalid")
        total_mappings += len(mappings)
        for mapping in mappings:
            if not isinstance(mapping, dict):
                raise EvidenceError(f"{label} has an invalid mapping result")
            require_pass_record(mapping, f"{label} mapping")
            mapping_id = mapping.get("mappingID")
            if not isinstance(mapping_id, str) or not mapping_id or mapping_id in mapping_ids:
                raise EvidenceError(f"{label} has an invalid or duplicate mappingID")
            mapping_ids.add(mapping_id)
            verify_file_binding(
                mapping.get("report"), mapping.get("reportSHA256"), root, f"mapping {mapping_id} report"
            )
            if "candidate" in mapping:
                verify_file_binding(
                    mapping.get("candidate"), mapping.get("candidateSHA256"), root, f"mapping {mapping_id} candidate"
                )
            if "heatmap" in mapping:
                verify_file_binding(
                    mapping.get("heatmap"), mapping.get("heatmapSHA256"), root, f"mapping {mapping_id} heatmap"
                )
            structural = mapping.get("structuralAssertionResults", [])
            if not isinstance(structural, list) or any(
                not isinstance(item, dict) or item.get("result") != "PASS" for item in structural
            ):
                raise EvidenceError(f"mapping {mapping_id} contains a failed structural assertion")
        for collection_name in ("structuralAssertionResults", "runtimeProbeResults"):
            values = entry.get(collection_name)
            if not isinstance(values, list) or any(
                not isinstance(item, dict) or item.get("result") != "PASS" for item in values
            ):
                raise EvidenceError(f"{label} contains a failed {collection_name}")
            for item in values:
                if "report" in item:
                    verify_file_binding(
                        item.get("report"), item.get("reportSHA256"), root, f"{label} {collection_name} report"
                    )
    if total_mappings != EXPECTED_MAPPING_COUNT or len(mapping_ids) != EXPECTED_MAPPING_COUNT:
        raise EvidenceError("visual comparison index lacks 1104 unique passing mappings")

    return CaptureEvidence(
        run_path=capture_run_path.resolve(),
        run=run,
        index_path=index_path,
        index=index_document,
        source_before_path=source_before_path,
        source_after_path=source_after_path,
        source_manifest=source_after,
        records_by_entry=records_by_entry,
    )


def validate_authority(root: Path) -> dict[str, Any]:
    module = import_module(root / "scripts/theme_fidelity_authority_v12.py", "theme_fidelity_authority_v12_evidence")
    checker = module.AuthorityV12Checker(root, root / DEFAULT_IMPORT_MANIFEST)
    report = checker.run()
    require_pass_record(report, "v1.2 authority validation")
    expected = {
        "entryCount": 400,
        "mappingCount": 1104,
        "candidateCount": 188,
        "runtimeProbeCount": 50,
        "seedCount": 100,
        "assetCount": 113,
        "gateCount": 40,
    }
    for key, value in expected.items():
        if report.get(key) != value:
            raise EvidenceError(f"v1.2 authority validation {key} differs from {value}")
    return report


def load_gate_catalog(path: Path) -> list[dict[str, Any]]:
    document = load_json(path, "gate catalog")
    gates = document.get("gates")
    if not isinstance(gates, list) or len(gates) != EXPECTED_GATE_COUNT:
        raise EvidenceError("gate catalog must contain exactly 40 gates")
    identifiers: set[str] = set()
    for index, gate in enumerate(gates):
        if not isinstance(gate, dict):
            raise EvidenceError(f"gate catalog entry {index} is invalid")
        identifier = gate.get("id")
        required = gate.get("requiredEvidence")
        dependencies = gate.get("dependsOn")
        if (
            not isinstance(identifier, str)
            or not identifier
            or identifier in identifiers
            or gate.get("blocking") is not True
            or not isinstance(required, list)
            or not required
            or not all(isinstance(item, str) and item for item in required)
            or len(required) != len(set(required))
            or not isinstance(dependencies, list)
            or not all(isinstance(item, str) and item for item in dependencies)
        ):
            raise EvidenceError(f"gate catalog entry {index} is invalid")
        identifiers.add(identifier)
    for gate in gates:
        unknown = set(gate["dependsOn"]) - identifiers
        if unknown:
            raise EvidenceError(f"gate {gate['id']} has unknown dependencies")
    return gates


def validate_external_json(path: Path, logical_name: str) -> dict[str, Any]:
    document = load_json(path, f"external evidence {logical_name}")
    require_pass_record(document, f"external evidence {logical_name}")
    return document


def validate_qualification_results(
    path: Path,
    root: Path,
    source_sha: str,
    gates: Sequence[Mapping[str, Any]],
    generated_names: set[str],
) -> tuple[dict[str, Any], dict[str, ExternalArtifact], dict[str, dict[str, Any]]]:
    document = load_json(path, "qualification results")
    if document.get("schemaVersion") != SCHEMA_VERSION or document.get("sourceSHA") != source_sha:
        raise EvidenceError("qualification results are not bound to the final source SHA")
    executions = document.get("executions")
    if not isinstance(executions, list) or not executions:
        raise EvidenceError("qualification results must contain executions")
    known_gates = {str(gate["id"]) for gate in gates}
    execution_by_id: dict[str, dict[str, Any]] = {}
    artifacts: dict[str, ExternalArtifact] = {}
    semantic_documents: dict[str, dict[str, Any]] = {}
    for index, execution in enumerate(executions):
        label = f"qualification execution {index}"
        if not isinstance(execution, dict):
            raise EvidenceError(f"{label} is invalid")
        identifier = execution.get("id")
        gate_ids = execution.get("gateIDs")
        command = execution.get("command")
        if (
            not isinstance(identifier, str)
            or not identifier
            or identifier in execution_by_id
            or not isinstance(gate_ids, list)
            or not gate_ids
            or not all(isinstance(item, str) and item in known_gates for item in gate_ids)
            or len(gate_ids) != len(set(gate_ids))
            or not isinstance(command, list)
            or not command
            or not all(isinstance(item, str) and item for item in command)
            or execution.get("exitCode") != 0
        ):
            raise EvidenceError(f"{label} identity, gates, command, or exit code is invalid")
        require_pass_record(execution, label)
        start = parse_timestamp(execution.get("startTimestamp"), f"{label}.startTimestamp")
        end = parse_timestamp(execution.get("endTimestamp"), f"{label}.endTimestamp")
        if end < start:
            raise EvidenceError(f"{label} ends before it starts")
        if not isinstance(execution.get("toolchain"), dict) or not execution["toolchain"]:
            raise EvidenceError(f"{label} toolchain is missing")
        destination = execution.get("destination")
        if not isinstance(destination, (str, dict)) or not destination:
            raise EvidenceError(f"{label} destination is missing")
        raw_artifacts = execution.get("artifacts")
        if not isinstance(raw_artifacts, list) or not raw_artifacts:
            raise EvidenceError(f"{label} artifacts are missing")
        execution_by_id[identifier] = execution
        for artifact_index, artifact in enumerate(raw_artifacts):
            artifact_label = f"{label} artifact {artifact_index}"
            if not isinstance(artifact, dict) or set(artifact) != {
                "logicalName", "path", "sha256", "kind"
            }:
                raise EvidenceError(f"{artifact_label} schema is invalid")
            logical_name = artifact.get("logicalName")
            kind = artifact.get("kind")
            if not isinstance(logical_name, str) or not logical_name or logical_name in artifacts:
                raise EvidenceError(f"{artifact_label} logicalName is invalid or duplicated")
            if kind not in {"json", "log", "text"}:
                raise EvidenceError(f"{artifact_label} kind is invalid")
            artifact_path = verify_file_binding(
                artifact.get("path"), artifact.get("sha256"), path.parent, artifact_label
            )
            if artifact_path.stat().st_size == 0:
                raise EvidenceError(f"{artifact_label} is empty")
            if kind == "json":
                semantic_documents[logical_name] = validate_external_json(artifact_path, logical_name)
            artifacts[logical_name] = ExternalArtifact(
                logical_name=logical_name,
                path=artifact_path,
                sha256=artifact["sha256"],
                kind=kind,
                execution_id=identifier,
                gate_ids=tuple(gate_ids),
            )

    requirements: dict[str, set[str]] = defaultdict(set)
    for gate in gates:
        for logical_name in gate["requiredEvidence"]:
            if logical_name not in generated_names:
                requirements[logical_name].add(gate["id"])
    missing = sorted(set(requirements) - set(artifacts))
    if missing:
        raise EvidenceError("qualification results lack required evidence: " + ", ".join(missing))
    extras = sorted(set(artifacts) - set(requirements))
    if extras:
        raise EvidenceError("qualification results contain undeclared evidence: " + ", ".join(extras))
    for logical_name, required_gate_ids in requirements.items():
        covered = set(artifacts[logical_name].gate_ids)
        if not required_gate_ids.issubset(covered):
            raise EvidenceError(
                f"qualification artifact {logical_name} is not bound to every requiring gate"
            )
    return document, artifacts, execution_by_id


def generated_logical_names() -> set[str]:
    return {
        "comparison-authority-validation.json",
        "authority-asset-validation.json",
        "baseline.json",
        "git-status.txt",
        "source-manifest.json",
        "evidence-source-binding.json",
        "norse-catalog-validation.json",
        "norse-resource-validation.json",
        "norse-focal-comparison.json",
        "norse-heatmaps/",
        "norse-base-vault-invariant.json",
        "moonleaf-catalog-validation.json",
        "moonleaf-resource-validation.json",
        "moonleaf-focal-comparison.json",
        "moonleaf-heatmaps/",
        "sunspire-catalog-validation.json",
        "sunspire-resource-validation.json",
        "sunspire-focal-comparison.json",
        "sunspire-heatmaps/",
        "wildwood-catalog-validation.json",
        "wildwood-resource-validation.json",
        "wildwood-focal-comparison.json",
        "wildwood-heatmaps/",
        "gloamthorn-catalog-validation.json",
        "gloamthorn-resource-validation.json",
        "gloamthorn-focal-comparison.json",
        "gloamthorn-heatmaps/",
        "ui-surface-coverage.json",
        "interactive-static-parity.json",
        "responsive-layout.json",
        "accessibility.json",
        "reduce-motion-runtime-evidence.json",
        "reduce-motion-frame-comparisons/",
        "visual-comparison-index.json",
        "final-screenshots/",
        "focal-captures/",
        "heatmaps/",
        "responsive-layout-assertions.json",
        "macos.json",
        "iphone.json",
        "ipad.json",
        "documentation-alignment.json",
        "historical-evidence-boundary.json",
        "final-self-audit.md",
        "gate-summary.json",
    }


def safe_stem(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-.") or "evidence"


def make_binding(
    logical_name: str,
    relative_path: str,
    sha256: str,
    kind: str,
    source_sha: str,
) -> dict[str, Any]:
    if SHA256_PATTERN.fullmatch(sha256) is None:
        raise EvidenceError(f"binding for {logical_name} has an invalid SHA-256")
    return {
        "logicalName": logical_name,
        "path": relative_path,
        "sha256": sha256,
        "kind": kind,
        "sourceSHA": source_sha,
        "result": "PASS",
    }


class StagingWriter:
    def __init__(self, context: Context, stage: Path) -> None:
        self.context = context
        self.stage = stage
        self.bindings: dict[str, dict[str, Any]] = {}
        self.targets: set[str] = set()

    def stage_path(self, relative: str) -> Path:
        candidate = Path(relative)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise EvidenceError(f"unsafe evidence path: {relative}")
        path = self.stage / candidate
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def write_json(
        self,
        relative: str,
        payload: Mapping[str, Any],
        *,
        logical_name: str | None = None,
        kind: str = "json",
    ) -> Path:
        path = self.stage_path(relative)
        document = dict(payload)
        path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        self.targets.add(relative)
        if logical_name is not None:
            self.bindings[logical_name] = make_binding(
                logical_name, relative, sha256_file(path), kind, self.context.source_sha
            )
        return path

    def write_text(
        self,
        relative: str,
        text: str,
        *,
        logical_name: str | None = None,
        kind: str = "text",
    ) -> Path:
        path = self.stage_path(relative)
        path.write_text(text, encoding="utf-8")
        self.targets.add(relative)
        if logical_name is not None:
            self.bindings[logical_name] = make_binding(
                logical_name, relative, sha256_file(path), kind, self.context.source_sha
            )
        return path

    def copy_file(
        self,
        source: Path,
        relative: str,
        *,
        logical_name: str | None = None,
        kind: str = "file",
    ) -> Path:
        path = self.stage_path(relative)
        shutil.copy2(source, path)
        self.targets.add(relative)
        if logical_name is not None:
            self.bindings[logical_name] = make_binding(
                logical_name, relative, sha256_file(path), kind, self.context.source_sha
            )
        return path

    def record(
        self,
        relative: str,
        evidence_type: str,
        body: Mapping[str, Any],
        *,
        logical_name: str | None = None,
        destination: str = "all-declared-destinations",
        output_hashes: Sequence[Mapping[str, Any]] = (),
        kind: str = "json",
    ) -> Path:
        document = {
            **self.context.metadata(destination),
            "evidenceType": evidence_type,
            **dict(body),
            "result": "PASS",
            "failures": [],
            "outputHashes": list(output_hashes),
        }
        return self.write_json(relative, document, logical_name=logical_name, kind=kind)

    def commit(self) -> None:
        for relative in sorted(self.targets):
            target = self.context.output_root / relative
            if target.exists() or target.is_symlink():
                raise EvidenceError(f"refusing to overwrite existing evidence: {target}")
        for relative in sorted(self.targets):
            source = self.stage / relative
            target = self.context.output_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            os.replace(source, target)


def path_binding(path: Path, root: Path) -> dict[str, str]:
    return {"path": relative_to(path, root, "evidence output"), "sha256": sha256_file(path)}


def external_output_relative(logical_name: str) -> str:
    if logical_name == "negative-mutations.json":
        return "negative-mutations/negative-mutations.json"
    if logical_name.endswith(".log"):
        return f"test-runs/{safe_stem(logical_name)}"
    return f"test-runs/{safe_stem(logical_name)}"


def materialize_external_artifacts(
    writer: StagingWriter,
    artifacts: Mapping[str, ExternalArtifact],
    executions: Mapping[str, Mapping[str, Any]],
) -> None:
    copied_by_source: dict[tuple[str, str], str] = {}
    for logical_name in sorted(artifacts):
        artifact = artifacts[logical_name]
        suffix = artifact.path.suffix if artifact.path.suffix else ".bin"
        source_key = (str(artifact.path), artifact.sha256)
        raw_relative = copied_by_source.get(source_key)
        if raw_relative is None:
            raw_relative = (
                f"test-runs/raw/{safe_stem(logical_name)}-{artifact.sha256[:12]}{suffix}"
            )
            writer.copy_file(artifact.path, raw_relative)
            copied_by_source[source_key] = raw_relative
        if artifact.kind in {"log", "text"}:
            output_relative = external_output_relative(logical_name)
            writer.copy_file(
                artifact.path,
                output_relative,
                logical_name=logical_name,
                kind=artifact.kind,
            )
            record_relative = output_relative + ".record.json"
            writer.record(
                record_relative,
                "qualified-command-output",
                {
                    "logicalEvidence": logical_name,
                    "execution": executions[artifact.execution_id],
                    "sourceArtifact": {
                        "originalPath": str(artifact.path),
                        "copiedPath": raw_relative,
                        "sha256": artifact.sha256,
                        "kind": artifact.kind,
                    },
                },
                destination="qualification-host",
                output_hashes=[{"path": output_relative, "sha256": artifact.sha256}],
            )
        else:
            output_relative = external_output_relative(logical_name)
            writer.record(
                output_relative,
                "qualified-structured-result",
                {
                    "logicalEvidence": logical_name,
                    "execution": executions[artifact.execution_id],
                    "sourceArtifact": {
                        "originalPath": str(artifact.path),
                        "copiedPath": raw_relative,
                        "sha256": artifact.sha256,
                        "kind": artifact.kind,
                    },
                    "semanticValidation": {
                        "topLevelPass": True,
                        "emptyFailures": True,
                    },
                },
                logical_name=logical_name,
                destination="qualification-host",
                output_hashes=[{"path": raw_relative, "sha256": artifact.sha256}],
            )


def entry_groups(index: Mapping[str, Any]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for entry in index["entries"]:
        grouped[entry["theme"]].append(entry)
    for theme in EXPECTED_THEMES:
        values = grouped.get(theme, [])
        if len(values) != 80:
            raise EvidenceError(f"{theme} does not have exactly 80 passing entries")
        surfaces = {entry["surface"] for entry in values}
        destinations = {entry["destination"] for entry in values}
        if len(surfaces) != EXPECTED_SURFACE_COUNT or destinations != set(EXPECTED_DESTINATIONS):
            raise EvidenceError(f"{theme} lacks exact surface/destination coverage")
    return grouped


def build_responsive_aggregate(
    context: Context,
    capture: CaptureEvidence,
) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    assertion_count = 0
    assertion_ids: Counter[str] = Counter()
    for entry in capture.index["entries"]:
        binding = entry["responsiveLayout"]
        path = Path(binding["path"])
        document = load_json(path, f"responsive layout {entry['entryID']}")
        require_pass_record(document, f"responsive layout {entry['entryID']}")
        assertions = document.get("assertions")
        if not isinstance(assertions, list):
            raise EvidenceError(f"responsive layout {entry['entryID']} assertions are invalid")
        for assertion in assertions:
            if not isinstance(assertion, dict) or assertion.get("result") != "PASS":
                raise EvidenceError(f"responsive layout {entry['entryID']} has a failed assertion")
            assertion_id = assertion.get("assertionID")
            if not isinstance(assertion_id, str) or not assertion_id:
                raise EvidenceError(f"responsive layout {entry['entryID']} has an invalid assertion ID")
            assertion_ids[assertion_id] += 1
        assertion_count += len(assertions)
        entries.append(
            {
                "entryID": entry["entryID"],
                "theme": entry["theme"],
                "surface": entry["surface"],
                "destination": entry["destination"],
                "path": relative_to(path, context.output_root, "responsive layout"),
                "sha256": binding["sha256"],
                "assertionCount": len(assertions),
                "result": "PASS",
            }
        )
    if len(entries) != EXPECTED_ENTRY_COUNT:
        raise EvidenceError("responsive layout aggregate lacks 400 entries")
    return {
        **context.metadata("all-declared-destinations"),
        "evidenceType": "responsive-layout-assertion-aggregate",
        "entryCount": len(entries),
        "assertionCount": assertion_count,
        "assertionCountsByID": dict(sorted(assertion_ids.items())),
        "entries": entries,
        "result": "PASS",
        "failures": [],
        "outputHashes": [
            {"path": item["path"], "sha256": item["sha256"]} for item in entries
        ],
    }


def build_gate_records(
    gates: Sequence[Mapping[str, Any]],
    bindings: Mapping[str, Mapping[str, Any]],
    external_artifacts: Mapping[str, ExternalArtifact],
) -> list[dict[str, Any]]:
    results: dict[str, str] = {}
    records: list[dict[str, Any]] = []
    for gate in gates:
        gate_id = str(gate["id"])
        evidence: list[dict[str, Any]] = []
        for logical_name in gate["requiredEvidence"]:
            binding = bindings.get(logical_name)
            if binding is None or binding.get("result") != "PASS":
                raise EvidenceError(f"gate {gate_id} lacks passing evidence {logical_name}")
            evidence.append(dict(binding))
        failed_dependencies = [
            dependency for dependency in gate["dependsOn"] if results.get(dependency) != "PASS"
        ]
        if failed_dependencies:
            raise EvidenceError(
                f"gate {gate_id} has failed or unevaluated dependencies: "
                + ", ".join(failed_dependencies)
            )
        execution_ids = sorted(
            {
                external_artifacts[name].execution_id
                for name in gate["requiredEvidence"]
                if name in external_artifacts
            }
        )
        record = {
            "id": gate_id,
            "category": gate["category"],
            "blocking": True,
            "description": gate["description"],
            "dependsOn": list(gate["dependsOn"]),
            "requiredEvidence": list(gate["requiredEvidence"]),
            "evidence": evidence,
            "qualificationExecutionIDs": execution_ids,
            "result": "PASS",
            "failures": [],
        }
        records.append(record)
        results[gate_id] = "PASS"
    if len(records) != EXPECTED_GATE_COUNT:
        raise EvidenceError("gate summary does not contain exactly 40 gates")
    return records


def aggregate_bindings_sha256(bindings: Iterable[Mapping[str, Any]]) -> str:
    normalized = [
        {"path": item["path"], "sha256": item["sha256"]}
        for item in sorted(bindings, key=lambda value: str(value["path"]))
    ]
    return canonical_json_sha256(normalized)


def bound_output(path: Path, output_root: Path, label: str) -> dict[str, str]:
    if not path.is_file():
        raise EvidenceError(f"{label} is missing: {path}")
    return {
        "path": relative_to(path, output_root, label),
        "sha256": sha256_file(path),
    }


def authority_mapping_semantics(root: Path) -> dict[str, dict[str, Any]]:
    authority = load_json(root / DEFAULT_AUTHORITY, "comparison authority")
    entries = authority.get("entries")
    if not isinstance(entries, list) or len(entries) != EXPECTED_ENTRY_COUNT:
        raise EvidenceError("comparison authority lacks exactly 400 entries")
    semantics: dict[str, dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise EvidenceError("comparison authority contains an invalid entry")
        mappings = entry.get("referenceMappings")
        if not isinstance(mappings, list):
            raise EvidenceError("comparison authority contains invalid mappings")
        for mapping in mappings:
            if not isinstance(mapping, dict):
                raise EvidenceError("comparison authority contains an invalid mapping")
            mapping_id = mapping.get("mappingID")
            if not isinstance(mapping_id, str) or not mapping_id or mapping_id in semantics:
                raise EvidenceError("comparison authority contains a duplicate mapping ID")
            semantics[mapping_id] = {
                "referenceRole": mapping.get("referenceRole"),
                "scoreDisposition": mapping.get("scoreDisposition"),
                "candidateID": next(
                    (
                        mapping[key]
                        for key in (
                            "candidateElementID",
                            "candidateRendererOutputID",
                            "candidateProbeID",
                        )
                        if key in mapping
                    ),
                    None,
                ),
            }
    if len(semantics) != EXPECTED_MAPPING_COUNT:
        raise EvidenceError("comparison authority lacks 1104 mapping semantics")
    return semantics


def authority_destination_entry_counts(root: Path) -> Counter[str]:
    authority = load_json(root / DEFAULT_AUTHORITY, "comparison authority")
    entries = authority.get("entries")
    if not isinstance(entries, list) or len(entries) != EXPECTED_ENTRY_COUNT:
        raise EvidenceError("comparison authority lacks exactly 400 entries")
    counts: Counter[str] = Counter()
    for ordinal, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise EvidenceError(f"comparison authority entry {ordinal} is invalid")
        destination = entry.get("destination")
        if destination not in EXPECTED_DESTINATIONS:
            raise EvidenceError(
                f"comparison authority entry {ordinal} has an undeclared destination"
            )
        counts[destination] += 1
    if set(counts) != set(EXPECTED_DESTINATIONS):
        raise EvidenceError("comparison authority lacks exact destination coverage")
    return counts


def authority_theme_image_metric_counts(root: Path) -> Counter[str]:
    authority = load_json(root / DEFAULT_AUTHORITY, "comparison authority")
    entries = authority.get("entries")
    if not isinstance(entries, list) or len(entries) != EXPECTED_ENTRY_COUNT:
        raise EvidenceError("comparison authority lacks exactly 400 entries")
    counts: Counter[str] = Counter()
    for ordinal, entry in enumerate(entries):
        if not isinstance(entry, dict) or entry.get("theme") not in EXPECTED_THEMES:
            raise EvidenceError(f"comparison authority entry {ordinal} has an undeclared theme")
        mappings = entry.get("referenceMappings")
        if not isinstance(mappings, list):
            raise EvidenceError(f"comparison authority entry {ordinal} has invalid mappings")
        counts[entry["theme"]] += sum(
            1
            for mapping in mappings
            if isinstance(mapping, dict)
            and mapping.get("scoreDisposition") == "image-metric"
        )
    if set(counts) != set(EXPECTED_THEMES):
        raise EvidenceError("comparison authority lacks exact theme coverage")
    return counts


def command_bindings_for_platform(
    capture: CaptureEvidence,
    platform: str,
    output_root: Path,
) -> list[dict[str, Any]]:
    expected = {platform, f"{platform}-xcui"}
    selected: list[dict[str, Any]] = []
    for command in capture.run["commands"]:
        log_path = Path(command["log"])
        if log_path.stem not in expected:
            continue
        selected.append(
            {
                "role": log_path.stem,
                "command": command["command"],
                "exitCode": command["exitCode"],
                "result": "PASS",
                "log": relative_to(log_path, output_root, f"{platform} command log"),
                "logSHA256": command["logSHA256"],
                "startTimestamp": command["startTimestamp"],
                "endTimestamp": command["endTimestamp"],
            }
        )
    if {item["role"] for item in selected} != expected:
        raise EvidenceError(f"capture run lacks exact {platform} hosted and XCUI executions")
    return sorted(selected, key=lambda item: item["role"])


def write_capture_indexes(
    writer: StagingWriter,
    context: Context,
    capture: CaptureEvidence,
    grouped: Mapping[str, Sequence[Mapping[str, Any]]],
    semantics: Mapping[str, Mapping[str, Any]],
) -> None:
    comparison_reports: list[dict[str, Any]] = []
    focal_captures: list[dict[str, Any]] = []
    heatmaps: list[dict[str, Any]] = []
    final_screenshots: list[dict[str, Any]] = []
    for entry in capture.index["entries"]:
        final_screenshots.append(
            {
                "entryID": entry["entryID"],
                "theme": entry["theme"],
                "surface": entry["surface"],
                "destination": entry["destination"],
                **bound_output(Path(entry["capture"]["path"]), context.output_root, "final screenshot"),
            }
        )
        for mapping in entry["mappingResults"]:
            mapping_id = mapping["mappingID"]
            declared = semantics.get(mapping_id)
            if declared is None or declared.get("scoreDisposition") != mapping.get("scoreDisposition"):
                raise EvidenceError(f"mapping result semantics differ for {mapping_id}")
            comparison_reports.append(
                {
                    "entryID": entry["entryID"],
                    "mappingID": mapping_id,
                    "theme": entry["theme"],
                    "scoreDisposition": mapping["scoreDisposition"],
                    **bound_output(Path(mapping["report"]), context.output_root, "comparison report"),
                }
            )
            if "candidate" in mapping:
                focal_captures.append(
                    {
                        "entryID": entry["entryID"],
                        "mappingID": mapping_id,
                        "theme": entry["theme"],
                        "candidateID": mapping.get("candidateID"),
                        **bound_output(Path(mapping["candidate"]), context.output_root, "focal capture"),
                    }
                )
            if "heatmap" in mapping:
                heatmaps.append(
                    {
                        "entryID": entry["entryID"],
                        "mappingID": mapping_id,
                        "theme": entry["theme"],
                        **bound_output(Path(mapping["heatmap"]), context.output_root, "comparison heatmap"),
                    }
                )
    if (
        len(comparison_reports) != 1104
        or len(focal_captures) != 1100
        or len(heatmaps) != 400
        or len(final_screenshots) != 400
    ):
        raise EvidenceError("capture output cardinalities differ from v1.2 authority")

    writer.record(
        "comparisons/comparison-report-bindings.json",
        "comparison-report-index",
        {
            "reportCount": len(comparison_reports),
            "reports": comparison_reports,
            "aggregateSHA256": aggregate_bindings_sha256(comparison_reports),
        },
        output_hashes=comparison_reports,
    )
    writer.record(
        "focal-captures/focal-capture-bindings.json",
        "focal-capture-index",
        {
            "captureCount": len(focal_captures),
            "captures": focal_captures,
            "aggregateSHA256": aggregate_bindings_sha256(focal_captures),
        },
        logical_name="focal-captures/",
        kind="directory-index",
        output_hashes=focal_captures,
    )
    writer.record(
        "heatmaps/heatmap-bindings.json",
        "heatmap-index",
        {
            "heatmapCount": len(heatmaps),
            "heatmaps": heatmaps,
            "aggregateSHA256": aggregate_bindings_sha256(heatmaps),
        },
        logical_name="heatmaps/",
        kind="directory-index",
        output_hashes=heatmaps,
    )
    writer.record(
        "final/final-screenshots-index.json",
        "final-screenshot-index",
        {
            "screenshotCount": len(final_screenshots),
            "screenshots": final_screenshots,
            "aggregateSHA256": aggregate_bindings_sha256(final_screenshots),
        },
        logical_name="final-screenshots/",
        kind="directory-index",
        output_hashes=final_screenshots,
    )

    theme_logical_prefix = {
        "Norse": "norse",
        "Moonleaf": "moonleaf",
        "Sunspire": "sunspire",
        "Wildwood": "wildwood",
        "Gloamthorn": "gloamthorn",
    }
    authority_image_counts = authority_theme_image_metric_counts(context.root)
    for theme in EXPECTED_THEMES:
        prefix = theme_logical_prefix[theme]
        theme_reports = [item for item in comparison_reports if item["theme"] == theme]
        image_reports = [
            item for item in theme_reports if item["scoreDisposition"] == "image-metric"
        ]
        theme_heatmaps = [item for item in heatmaps if item["theme"] == theme]
        expected_image_count = authority_image_counts[theme]
        if (
            len(theme_reports) == 0
            or len(image_reports) != expected_image_count
            or len(theme_heatmaps) != expected_image_count
        ):
            raise EvidenceError(f"{theme} focal evidence lacks exact passing coverage")
        writer.record(
            f"comparisons/{prefix}-focal-comparison.json",
            "theme-focal-comparison-index",
            {
                "theme": theme,
                "entryCount": len(grouped[theme]),
                "mappingCount": len(theme_reports),
                "imageMetricCount": len(image_reports),
                "mappings": theme_reports,
                "aggregateSHA256": aggregate_bindings_sha256(theme_reports),
            },
            logical_name=f"{prefix}-focal-comparison.json",
            output_hashes=theme_reports,
        )
        writer.record(
            f"heatmaps/{prefix}/index.json",
            "theme-heatmap-index",
            {
                "theme": theme,
                "heatmapCount": len(theme_heatmaps),
                "heatmaps": theme_heatmaps,
                "aggregateSHA256": aggregate_bindings_sha256(theme_heatmaps),
            },
            logical_name=f"{prefix}-heatmaps/",
            kind="directory-index",
            output_hashes=theme_heatmaps,
        )


def write_theme_records(
    writer: StagingWriter,
    capture: CaptureEvidence,
    grouped: Mapping[str, Sequence[Mapping[str, Any]]],
) -> None:
    prefixes = {
        "Norse": "norse",
        "Moonleaf": "moonleaf",
        "Sunspire": "sunspire",
        "Wildwood": "wildwood",
        "Gloamthorn": "gloamthorn",
    }
    for theme in EXPECTED_THEMES:
        prefix = prefixes[theme]
        entries = list(grouped[theme])
        entry_bindings = [
            {
                "entryID": entry["entryID"],
                "surface": entry["surface"],
                "destination": entry["destination"],
                "comparisonMode": entry["comparisonMode"],
                "result": "PASS",
            }
            for entry in entries
        ]
        writer.record(
            f"test-runs/{prefix}-catalog-validation.json",
            "theme-catalog-runtime-validation",
            {
                "theme": theme,
                "entryCount": len(entries),
                "surfaceCount": len({entry["surface"] for entry in entries}),
                "destinationCount": len({entry["destination"] for entry in entries}),
                "entries": entry_bindings,
                "authorityEntrySetSHA256": canonical_json_sha256(entry_bindings),
            },
            logical_name=f"{prefix}-catalog-validation.json",
        )
        resource_ids: set[str] = set()
        record_bindings: list[dict[str, Any]] = []
        for entry in entries:
            record = capture.records_by_entry[entry["entryID"]]
            ids = record.get("renderedResourceIDs")
            bindings = record.get("renderedResourceBindings")
            if (
                not isinstance(ids, list)
                or not ids
                or ids != sorted(set(ids))
                or not isinstance(bindings, list)
                or len(bindings) != len(ids)
            ):
                raise EvidenceError(f"{theme} entry {entry['entryID']} lacks bound rendered resources")
            resource_ids.update(ids)
            record_bindings.append(
                {
                    "entryID": entry["entryID"],
                    "renderedResourceCount": len(ids),
                    "renderedResourceIDsSHA256": canonical_json_sha256(ids),
                    "captureRecordSHA256": entry["capture"]["recordSHA256"],
                    "result": "PASS",
                }
            )
        writer.record(
            f"test-runs/{prefix}-resource-validation.json",
            "theme-resource-runtime-validation",
            {
                "theme": theme,
                "entryCount": len(record_bindings),
                "uniqueRenderedResourceCount": len(resource_ids),
                "renderedResourceIDs": sorted(resource_ids),
                "captureRecords": record_bindings,
            },
            logical_name=f"{prefix}-resource-validation.json",
        )


def write_ui_accessibility_records(
    writer: StagingWriter,
    context: Context,
    capture: CaptureEvidence,
    grouped: Mapping[str, Sequence[Mapping[str, Any]]],
    responsive: Mapping[str, Any],
) -> None:
    entries = capture.index["entries"]
    coverage = [
        {
            "entryID": entry["entryID"],
            "theme": entry["theme"],
            "surface": entry["surface"],
            "destination": entry["destination"],
            "result": "PASS",
        }
        for entry in entries
    ]
    writer.record(
        "test-runs/ui-surface-coverage.json",
        "provider-neutral-ui-surface-coverage",
        {
            "themeCount": len(grouped),
            "surfaceCountPerTheme": EXPECTED_SURFACE_COUNT,
            "destinationCount": len(EXPECTED_DESTINATIONS),
            "entryCount": len(coverage),
            "entriesSHA256": canonical_json_sha256(coverage),
            "entries": coverage,
        },
        logical_name="ui-surface-coverage.json",
    )
    parity: list[dict[str, Any]] = []
    mobile_hit_targets: list[dict[str, Any]] = []
    for entry in entries:
        for assertion in entry["structuralAssertionResults"]:
            if assertion.get("assertionID") == "assert.interactive-static-plan-parity":
                parity.append(
                    {
                        "entryID": entry["entryID"],
                        "assertion": assertion,
                        "result": "PASS",
                    }
                )
            if assertion.get("assertionID") == "assert.mobile-hit-targets":
                mobile_hit_targets.append(
                    {"entryID": entry["entryID"], "assertion": assertion, "result": "PASS"}
                )
        for mapping in entry["mappingResults"]:
            for assertion in mapping.get("structuralAssertionResults", []):
                if assertion.get("assertionID") == "assert.interactive-static-plan-parity":
                    parity.append(
                        {
                            "entryID": entry["entryID"],
                            "mappingID": mapping["mappingID"],
                            "assertion": assertion,
                            "result": "PASS",
                        }
                    )
                if assertion.get("assertionID") == "assert.mobile-hit-targets":
                    mobile_hit_targets.append(
                        {
                            "entryID": entry["entryID"],
                            "mappingID": mapping["mappingID"],
                            "assertion": assertion,
                            "result": "PASS",
                        }
                    )
    if not parity:
        raise EvidenceError("capture evidence lacks interactive/static plan parity assertions")
    writer.record(
        "test-runs/interactive-static-parity.json",
        "interactive-static-composition-parity",
        {"assertionCount": len(parity), "assertions": parity},
        logical_name="interactive-static-parity.json",
    )
    writer.record(
        "responsive-layout/responsive-layout.json",
        "responsive-layout-summary",
        {
            "entryCount": responsive["entryCount"],
            "assertionCount": responsive["assertionCount"],
            "assertionCountsByID": responsive["assertionCountsByID"],
            "aggregatePath": "responsive-layout/responsive-layout-assertions.json",
        },
        logical_name="responsive-layout.json",
        output_hashes=responsive["outputHashes"],
    )

    accessibility_entries = [
        entry
        for entry in entries
        if entry["surface"] in {"high-contrast", "reduce-motion", "large-text"}
    ]
    xcui_sidecar_count = sum(
        1 for entry in accessibility_entries if "xcuiEvidence" in entry.get("capture", {})
    )
    if len(accessibility_entries) != 60 or not mobile_hit_targets or xcui_sidecar_count == 0:
        raise EvidenceError("accessibility evidence lacks exact variant or interaction coverage")
    writer.record(
        "test-runs/accessibility.json",
        "accessibility-runtime-and-structure-validation",
        {
            "variantEntryCount": len(accessibility_entries),
            "highContrastEntryCount": sum(
                entry["surface"] == "high-contrast" for entry in accessibility_entries
            ),
            "reduceMotionEntryCount": sum(
                entry["surface"] == "reduce-motion" for entry in accessibility_entries
            ),
            "largeTextEntryCount": sum(
                entry["surface"] == "large-text" for entry in accessibility_entries
            ),
            "mobileHitTargetAssertionCount": len(mobile_hit_targets),
            "xcuiSidecarCount": xcui_sidecar_count,
            "entries": [entry["entryID"] for entry in accessibility_entries],
        },
        logical_name="accessibility.json",
    )


def write_runtime_aggregates(
    writer: StagingWriter,
    context: Context,
    capture: CaptureEvidence,
) -> None:
    aggregate = capture.index.get("aggregateEvidence")
    if not isinstance(aggregate, dict):
        raise EvidenceError("visual comparison index lacks aggregate evidence")
    negative = aggregate.get("norseBaseVaultInvariant")
    reduce_motion = aggregate.get("reduceMotion")
    if not isinstance(negative, dict) or not isinstance(reduce_motion, dict):
        raise EvidenceError("visual comparison index aggregate evidence is invalid")
    negative_path = verify_file_binding(
        negative.get("path"), negative.get("sha256"), context.root, "Norse Base vault invariant"
    )
    negative_document = load_json(negative_path, "Norse Base vault invariant")
    require_pass_record(negative_document, "Norse Base vault invariant")
    if negative_document.get("entryCount") != 4:
        raise EvidenceError("Norse Base vault invariant does not contain four passing entries")
    writer.record(
        "negative-mutations/norse-base-vault-invariant.json",
        "norse-base-vault-negative-invariant",
        {
            "entryCount": 4,
            "sourceEvidence": bound_output(
                negative_path, context.output_root, "Norse Base vault invariant"
            ),
            "entries": negative_document.get("entries"),
        },
        logical_name="norse-base-vault-invariant.json",
        output_hashes=[bound_output(negative_path, context.output_root, "Norse Base vault invariant")],
    )

    reduce_path = verify_file_binding(
        reduce_motion.get("path"), reduce_motion.get("sha256"), context.root, "Reduce Motion aggregate"
    )
    reduce_document = load_json(reduce_path, "Reduce Motion aggregate")
    require_pass_record(reduce_document, "Reduce Motion aggregate")
    if reduce_document.get("entryCount") != 20:
        raise EvidenceError("Reduce Motion aggregate does not contain 20 passing entries")
    writer.record(
        "reduce-motion/reduce-motion-runtime-evidence.json",
        "reduce-motion-runtime-aggregate",
        {
            "entryCount": 20,
            "probeEvaluationCount": reduce_document.get("probeEvaluationCount"),
            "sourceEvidence": bound_output(reduce_path, context.output_root, "Reduce Motion aggregate"),
            "entries": reduce_document.get("entries"),
        },
        logical_name="reduce-motion-runtime-evidence.json",
        output_hashes=[bound_output(reduce_path, context.output_root, "Reduce Motion aggregate")],
    )

    frame_comparisons: list[dict[str, Any]] = []
    for entry in capture.index["entries"]:
        if entry["surface"] != "reduce-motion":
            continue
        matching = [
            probe
            for probe in entry["runtimeProbeResults"]
            if ".frame-stability." in str(probe.get("probeID", ""))
        ]
        if len(matching) != 1:
            raise EvidenceError(f"{entry['entryID']} lacks one Reduce Motion frame-stability probe")
        probe = matching[0]
        details = probe.get("observationDetails")
        if not isinstance(details, dict):
            raise EvidenceError(f"{entry['entryID']} frame-stability details are missing")
        outputs: list[dict[str, str]] = []
        for path_key, digest_key, label in (
            ("captureB", "captureBSHA256", "Reduce Motion second capture"),
            ("heatmap", "heatmapSHA256", "Reduce Motion temporal heatmap"),
        ):
            path = verify_file_binding(details.get(path_key), details.get(digest_key), context.root, label)
            outputs.append(bound_output(path, context.output_root, label))
        if not isinstance(details.get("separationSeconds"), (int, float)) or details["separationSeconds"] < 1.5:
            raise EvidenceError(f"{entry['entryID']} Reduce Motion captures are too close")
        observed = probe.get("observed")
        if not isinstance(observed, (int, float)) or isinstance(observed, bool) or observed < 0.995:
            raise EvidenceError(f"{entry['entryID']} Reduce Motion stability is below 0.995")
        frame_comparisons.append(
            {
                "entryID": entry["entryID"],
                "theme": entry["theme"],
                "destination": entry["destination"],
                "probeID": probe["probeID"],
                "luminanceSSIM": observed,
                "separationSeconds": details["separationSeconds"],
                "outputs": outputs,
                "result": "PASS",
            }
        )
    if len(frame_comparisons) != 20:
        raise EvidenceError("Reduce Motion temporal aggregate lacks 20 comparisons")
    output_hashes = [item for entry in frame_comparisons for item in entry["outputs"]]
    writer.record(
        "reduce-motion/reduce-motion-frame-comparisons/index.json",
        "reduce-motion-frame-comparison-index",
        {"comparisonCount": len(frame_comparisons), "comparisons": frame_comparisons},
        logical_name="reduce-motion-frame-comparisons/",
        kind="directory-index",
        output_hashes=output_hashes,
    )


def write_platform_records(
    writer: StagingWriter,
    context: Context,
    capture: CaptureEvidence,
) -> None:
    destination_sets = {
        "iphone": {"iphone-portrait"},
        "ipad": {"ipad-portrait"},
        "macos": {"macos-standard", "macos-resized"},
    }
    authority_counts = authority_destination_entry_counts(context.root)
    capture_counts = Counter(entry["destination"] for entry in capture.index["entries"])
    if capture_counts != authority_counts:
        raise EvidenceError("capture destination counts differ from comparison authority")
    for platform, destinations in destination_sets.items():
        commands = command_bindings_for_platform(capture, platform, context.output_root)
        entries = [
            entry["entryID"]
            for entry in capture.index["entries"]
            if entry["destination"] in destinations
        ]
        expected_count = sum(authority_counts[destination] for destination in destinations)
        if len(entries) != expected_count:
            raise EvidenceError(f"{platform} evidence lacks {expected_count} entries")
        writer.record(
            f"test-runs/{platform}.json",
            "platform-release-hosted-xcui-validation",
            {
                "platform": platform,
                "destinations": sorted(destinations),
                "destinationEntryCounts": {
                    destination: authority_counts[destination]
                    for destination in sorted(destinations)
                },
                "entryCount": len(entries),
                "entriesSHA256": canonical_json_sha256(entries),
                "executions": commands,
            },
            logical_name=f"{platform}.json",
            destination=", ".join(sorted(destinations)),
            output_hashes=[
                {"path": command["log"], "sha256": command["logSHA256"]}
                for command in commands
            ],
        )


def write_documentation_records(
    writer: StagingWriter,
    context: Context,
    capture: CaptureEvidence,
) -> None:
    scratch = writer.stage / ".documentation-alignment"
    scratch.mkdir(parents=True, exist_ok=True)
    result_path = scratch / "result.json"
    log_path = scratch / "command.log"
    source_exclusion = context.output_root / "final"
    command = [
        sys.executable,
        str(context.root / "scripts/check-documentation-alignment.py"),
        "--source-manifest",
        str(capture.source_after_path),
        "--source-exclusion",
        str(source_exclusion),
        "--result-json",
        str(result_path),
    ]
    started = utc_timestamp()
    with log_path.open("wb") as stream:
        completed = subprocess.run(
            command,
            cwd=context.root,
            check=False,
            stdout=stream,
            stderr=subprocess.STDOUT,
        )
    ended = utc_timestamp()
    if completed.returncode != 0:
        detail = log_path.read_text(encoding="utf-8", errors="replace").strip()
        raise EvidenceError(f"current documentation alignment failed: {detail}")
    result = load_json(result_path, "current documentation alignment result")
    require_pass_record(result, "current documentation alignment result")
    if result.get("sourceSHA") != context.source_sha:
        raise EvidenceError("documentation alignment result is not bound to final source")
    raw_result_relative = "test-runs/raw/documentation-alignment-result.json"
    raw_log_relative = "test-runs/raw/documentation-alignment.log"
    writer.copy_file(result_path, raw_result_relative)
    writer.copy_file(log_path, raw_log_relative)
    writer.record(
        "test-runs/documentation-alignment.json",
        "current-documentation-alignment",
        {
            "execution": {
                "command": command,
                "startTimestamp": started,
                "endTimestamp": ended,
                "exitCode": 0,
                "result": "PASS",
                "failures": [],
            },
            "sourceManifest": {
                "path": "source-manifests/final-source-after.json",
                "sha256": sha256_file(capture.source_after_path),
            },
            "sourceExclusion": relative_to(
                source_exclusion, context.root, "documentation source exclusion"
            ),
            "checkerResult": {
                "path": raw_result_relative,
                "sha256": sha256_file(result_path),
            },
            "checkerLog": {
                "path": raw_log_relative,
                "sha256": sha256_file(log_path),
            },
        },
        logical_name="documentation-alignment.json",
        destination="source-worktree",
        output_hashes=[
            {"path": raw_result_relative, "sha256": sha256_file(result_path)},
            {"path": raw_log_relative, "sha256": sha256_file(log_path)},
        ],
    )
    boundary_path = (
        context.root
        / "docs/verification/theme-fidelity-v4/authority/v4.2/01-CONTROLLING-DECISIONS"
        / "Historical-Evidence-Boundary.md"
    )
    boundary = bound_output(boundary_path, context.root, "historical evidence boundary")
    writer.record(
        "source-manifests/historical-evidence-boundary.json",
        "historical-evidence-boundary-validation",
        {
            "controllingDecision": boundary,
            "currentEvidenceRoot": DEFAULT_OUTPUT_ROOT.as_posix(),
            "historicalEvidenceRewritten": False,
            "trackedSourceChangedAfterCapture": False,
        },
        logical_name="historical-evidence-boundary.json",
        destination="source-worktree",
        output_hashes=[boundary],
    )


def render_final_self_audit(
    context: Context,
    gates: Sequence[Mapping[str, Any]],
    capture: CaptureEvidence,
    qualification_results_sha: str,
) -> str:
    lines = [
        "# Theme Fidelity v4.2 Final Self-Audit",
        "",
        f"- Final source SHA: `{context.source_sha}`",
        f"- Comparison authority SHA-256: `{context.authority_sha}`",
        f"- Authority asset manifest SHA-256: `{context.asset_manifest_sha}`",
        f"- Qualification results SHA-256: `{qualification_results_sha}`",
        f"- Authority entries: `{capture.index['passingEntryCount']}/{capture.index['entryCount']}`",
        f"- Exact reference mappings: `{capture.index['passingMappingCount']}/{capture.index['mappingCount']}`",
        f"- Runtime probe evaluations: `{capture.index['runtimeProbeEvaluationCount']}`",
        "- Reduce Motion records: `20/20`",
        "- Norse Base vault negative-invariant entries: `4/4`",
        "",
        "## Blocking gate audit",
        "",
        "| Gate | Result | Evidence records |",
        "| --- | --- | ---: |",
    ]
    for gate in gates:
        lines.append(f"| {gate['id']} | PASS | {len(gate['requiredEvidence'])} |")
    lines.extend(
        [
            "",
            "All 40 blocking gates are source-bound and have complete required-evidence mappings. "
            "No instruction was omitted, no historical result was used as current proof, no gate "
            "failed, and no open defect remains in this acceptance set.",
            "",
            "The evidence assembly performed no merge, tag, archive, notarization, upload, release, "
            "distribution, or physical-device action.",
            "",
        ]
    )
    return "\n".join(lines)


def assemble(
    root: Path,
    output_root: Path,
    capture_run_path: Path,
    qualification_results_path: Path,
    command: Sequence[str],
) -> dict[str, Any]:
    root = root.resolve()
    output_root = output_root.resolve()
    canonical_output = (root / DEFAULT_OUTPUT_ROOT).resolve()
    if output_root != canonical_output:
        raise EvidenceError(f"output root must be the canonical evidence root: {canonical_output}")
    if not (output_root / "authority/v4.2").is_dir():
        raise EvidenceError("v4.2 repository authority is missing")
    if not (output_root / "baseline").is_dir() or not any((output_root / "baseline").rglob("*")):
        raise EvidenceError("historical baseline directory is missing")
    if not (output_root / "final").is_dir():
        raise EvidenceError("final capture output directory is missing")

    capture = validate_capture_evidence(root, output_root, capture_run_path.resolve())
    source_sha = capture.run["sourceSHA"]
    git_status_text = validate_current_source(root, output_root, source_sha)
    authority_report = validate_authority(root)
    gates = load_gate_catalog(root / DEFAULT_GATE_CATALOG)
    generated_names = generated_logical_names()
    qualification, external_artifacts, executions = validate_qualification_results(
        qualification_results_path.resolve(),
        root,
        source_sha,
        gates,
        generated_names,
    )
    authority_sha = sha256_file(root / DEFAULT_AUTHORITY)
    asset_manifest_sha = sha256_file(root / DEFAULT_ASSET_MANIFEST)
    toolchain_binding = capture.run.get("toolchain")
    if not isinstance(toolchain_binding, dict):
        raise EvidenceError("capture run toolchain binding is invalid")
    toolchain_path = verify_file_binding(
        toolchain_binding.get("path"),
        toolchain_binding.get("sha256"),
        root,
        "capture toolchain report",
    )
    toolchain = load_json(toolchain_path, "capture toolchain report")
    started = capture.run.get("startTimestamp")
    ended = capture.run.get("endTimestamp")
    parse_timestamp(started, "capture run startTimestamp")
    parse_timestamp(ended, "capture run endTimestamp")
    context = Context(
        root=root,
        output_root=output_root,
        source_sha=source_sha,
        authority_sha=authority_sha,
        asset_manifest_sha=asset_manifest_sha,
        command=list(command),
        start_timestamp=started,
        end_timestamp=ended,
        toolchain=toolchain,
    )
    grouped = entry_groups(capture.index)
    semantics = authority_mapping_semantics(root)

    with tempfile.TemporaryDirectory(prefix="runescribe-theme-evidence-v42-") as directory:
        stage = Path(directory)
        writer = StagingWriter(context, stage)
        materialize_external_artifacts(writer, external_artifacts, executions)
        qualification_copy = writer.copy_file(
            qualification_results_path.resolve(), "test-runs/qualification-results.json"
        )
        qualification_copy_sha = sha256_file(qualification_copy)

        authority_output = bound_output(root / DEFAULT_IMPORT_MANIFEST, root, "authority import manifest")
        writer.record(
            "test-runs/comparison-authority-validation.json",
            "comparison-authority-validation",
            {
                "authorityValidation": authority_report,
                "entryCount": 400,
                "mappingCount": 1104,
                "candidateCount": 188,
                "runtimeProbeCount": 50,
                "seedCount": 100,
                "importManifest": authority_output,
            },
            logical_name="comparison-authority-validation.json",
            destination="repository-authority",
            output_hashes=[authority_output],
        )
        writer.record(
            "test-runs/authority-asset-validation.json",
            "authority-asset-validation",
            {
                "authorityValidation": authority_report,
                "assetCount": 113,
                "declaredDuplicateHashGroupCount": authority_report.get(
                    "declaredDuplicateHashGroupCount"
                ),
                "shippingAssetSeparationValidated": True,
            },
            logical_name="authority-asset-validation.json",
            destination="repository-authority",
            output_hashes=[
                {
                    "path": DEFAULT_ASSET_MANIFEST.as_posix(),
                    "sha256": asset_manifest_sha,
                }
            ],
        )

        baseline_context_path = root / DEFAULT_OUTPUT_ROOT / "baseline-source-context.json"
        baseline_binding = bound_output(baseline_context_path, root, "baseline source context")
        writer.record(
            "source-manifests/baseline.json",
            "baseline-source-binding",
            {
                "baselineSourceContext": baseline_binding,
                "historicalBaselineDirectory": "baseline/",
                "historicalEvidenceRewritten": False,
            },
            logical_name="baseline.json",
            destination="source-worktree",
            output_hashes=[baseline_binding],
        )
        writer.write_text(
            "source-manifests/git-status.txt",
            git_status_text,
            logical_name="git-status.txt",
            kind="text",
        )
        before_relative = "source-manifests/final-source-before.json"
        after_relative = "source-manifests/final-source-after.json"
        writer.copy_file(capture.source_before_path, before_relative)
        writer.copy_file(capture.source_after_path, after_relative)
        writer.record(
            "source-manifests/source-manifest.json",
            "source-only-manifest-binding",
            {
                "sourceManifest": capture.source_manifest,
                "preCaptureManifest": {
                    "path": before_relative,
                    "sha256": sha256_file(writer.stage / before_relative),
                },
                "postCaptureManifest": {
                    "path": after_relative,
                    "sha256": sha256_file(writer.stage / after_relative),
                },
                "prePostEqual": True,
            },
            logical_name="source-manifest.json",
            destination="source-worktree",
            output_hashes=[
                {"path": before_relative, "sha256": sha256_file(writer.stage / before_relative)},
                {"path": after_relative, "sha256": sha256_file(writer.stage / after_relative)},
            ],
        )

        write_theme_records(writer, capture, grouped)
        write_capture_indexes(writer, context, capture, grouped, semantics)
        responsive = build_responsive_aggregate(context, capture)
        writer.write_json(
            "responsive-layout/responsive-layout-assertions.json",
            responsive,
            logical_name="responsive-layout-assertions.json",
        )
        write_ui_accessibility_records(writer, context, capture, grouped, responsive)
        write_runtime_aggregates(writer, context, capture)
        write_platform_records(writer, context, capture)
        write_documentation_records(writer, context, capture)

        raw_index_relative = relative_to(
            capture.index_path, output_root, "visual comparison index"
        )
        writer.bindings["visual-comparison-index.json"] = make_binding(
            "visual-comparison-index.json",
            raw_index_relative,
            sha256_file(capture.index_path),
            "source-index",
            source_sha,
        )

        missing_generated = sorted(
            generated_names
            - {"evidence-source-binding.json", "final-self-audit.md", "gate-summary.json"}
            - set(writer.bindings)
        )
        if missing_generated:
            raise EvidenceError(
                "assembly did not materialize generated evidence: " + ", ".join(missing_generated)
            )

        inventory: list[dict[str, Any]] = []
        for relative in sorted(writer.targets):
            path = writer.stage / relative
            inventory.append(
                {"path": relative, "bytes": path.stat().st_size, "sha256": sha256_file(path)}
            )
        inventory.extend(
            [
                {
                    "path": relative_to(capture.run_path, output_root, "final capture run"),
                    "bytes": capture.run_path.stat().st_size,
                    "sha256": sha256_file(capture.run_path),
                },
                {
                    "path": raw_index_relative,
                    "bytes": capture.index_path.stat().st_size,
                    "sha256": sha256_file(capture.index_path),
                },
            ]
        )
        inventory.sort(key=lambda item: item["path"])
        binding_document = {
            **context.metadata("source-worktree-and-all-declared-destinations"),
            "evidenceType": "source-to-evidence-binding",
            "sourceManifest": writer.bindings["source-manifest.json"],
            "captureRun": {
                "path": relative_to(capture.run_path, output_root, "final capture run"),
                "sha256": sha256_file(capture.run_path),
            },
            "visualComparisonIndex": writer.bindings["visual-comparison-index.json"],
            "evidenceFileCount": len(inventory),
            "evidenceFiles": inventory,
            "evidenceFilesAggregateSHA256": aggregate_bindings_sha256(inventory),
            "terminalRecordsExcludedFromInventory": [
                "source-manifests/evidence-source-binding.json",
                "FinalSelfAudit.md",
                "gate-summary.json",
            ],
            "terminalBindingPolicy": (
                "Terminal records bind this source SHA and the SHA-256 of this binding; "
                "gate-summary.json uses a canonical outcome digest for its self-reference."
            ),
            "result": "PASS",
            "failures": [],
            "outputHashes": [
                {"path": item["path"], "sha256": item["sha256"]} for item in inventory
            ],
        }
        binding_path = writer.write_json(
            "source-manifests/evidence-source-binding.json",
            binding_document,
            logical_name="evidence-source-binding.json",
        )
        binding_sha = sha256_file(binding_path)

        prospective_bindings = dict(writer.bindings)
        audit_text = render_final_self_audit(
            context, gates, capture, qualification_copy_sha
        )
        audit_path = writer.write_text(
            "FinalSelfAudit.md",
            audit_text,
            logical_name="final-self-audit.md",
            kind="markdown",
        )
        audit_sha = sha256_file(audit_path)
        prospective_bindings.update(writer.bindings)
        self_scope = {
            "sourceSHA": source_sha,
            "gateCatalogSHA256": sha256_file(root / DEFAULT_GATE_CATALOG),
            "gateIDs": [gate["id"] for gate in gates],
            "requiredEvidence": {
                gate["id"]: gate["requiredEvidence"] for gate in gates
            },
            "results": {gate["id"]: "PASS" for gate in gates},
            "evidenceSourceBindingSHA256": binding_sha,
            "finalSelfAuditSHA256": audit_sha,
        }
        self_scope_sha = canonical_json_sha256(self_scope)
        self_binding = {
            **make_binding(
                "gate-summary.json",
                "gate-summary.json",
                self_scope_sha,
                "terminal-self-binding",
                source_sha,
            ),
            "hashScope": "canonical-gate-outcomes-v1",
        }
        prospective_bindings["gate-summary.json"] = self_binding
        gate_records = build_gate_records(gates, prospective_bindings, external_artifacts)
        summary = {
            **context.metadata("all-declared-destinations"),
            "evidenceType": "blocking-gate-summary",
            "gateCatalog": {
                "path": DEFAULT_GATE_CATALOG.as_posix(),
                "sha256": sha256_file(root / DEFAULT_GATE_CATALOG),
            },
            "gateCount": len(gate_records),
            "passingGateCount": len(gate_records),
            "failingGateCount": 0,
            "requiredEvidenceReferenceCount": sum(
                len(gate["requiredEvidence"]) for gate in gates
            ),
            "canonicalSelfBinding": {
                "algorithm": "canonical-gate-outcomes-v1",
                "sha256": self_scope_sha,
                "scope": self_scope,
            },
            "gates": gate_records,
            "result": "PASS",
            "failures": [],
            "outputHashes": [
                {
                    "path": "source-manifests/evidence-source-binding.json",
                    "sha256": binding_sha,
                },
                {"path": "FinalSelfAudit.md", "sha256": audit_sha},
                {
                    "path": raw_index_relative,
                    "sha256": sha256_file(capture.index_path),
                },
            ],
        }
        writer.write_json("gate-summary.json", summary)
        writer.bindings["gate-summary.json"] = self_binding

        if len(writer.bindings) != len(set(writer.bindings)):
            raise EvidenceError("logical evidence bindings are duplicated")
        if set(writer.bindings) != generated_names | set(external_artifacts):
            missing = sorted((generated_names | set(external_artifacts)) - set(writer.bindings))
            extras = sorted(set(writer.bindings) - (generated_names | set(external_artifacts)))
            raise EvidenceError(
                f"logical evidence binding set differs; missing={missing}, extras={extras}"
            )
        writer.commit()

    for directory in REQUIRED_DIRECTORIES:
        if not (output_root / directory).is_dir():
            raise EvidenceError(f"required evidence directory is missing after assembly: {directory}")
    audit_variants = [
        path for path in output_root.iterdir() if path.name.casefold() == "finalselfaudit.md"
    ]
    if [path.name for path in audit_variants] != ["FinalSelfAudit.md"]:
        raise EvidenceError("exactly one case-compatible FinalSelfAudit.md is required")
    summary_path = output_root / "gate-summary.json"
    final_summary = load_json(summary_path, "final gate summary")
    require_pass_record(final_summary, "final gate summary")
    if final_summary.get("gateCount") != 40 or final_summary.get("passingGateCount") != 40:
        raise EvidenceError("final gate summary is not 40/40 PASS")
    return final_summary
