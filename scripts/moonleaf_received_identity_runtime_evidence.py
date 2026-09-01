#!/usr/bin/env python3
"""Validate and record source-bound Moonleaf received-identity runtime proof."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import struct
import tempfile
from typing import Any, Mapping, Sequence


EVIDENCE_ROOT = Path("docs/verification/theme-fidelity-v4-3")
EXTRACTION_PATH = EVIDENCE_ROOT / (
    "source-masters/moonleaf/Moonleaf-Received-Identity-Extraction-v4.3.json"
)
PROOF_PATH = EVIDENCE_ROOT / (
    "runtime-reviews/moonleaf/"
    "Moonleaf-Received-Identity-Target-Device-Runtime-v4.3.json"
)
CATALOG_PATH = EVIDENCE_ROOT / (
    "authority/03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-v1.3.json"
)
MANIFEST_PATH = Path(
    "Packages/RuneScribeArchitecture/Sources/"
    "RuneScribeThemeMoonleafModule/Resources/Production/"
    "Resource-Integrity-Manifest-v1.0.json"
)
THEME_ID = "theme.moonleaf.production"
CODEX_ID = "codex.moonleaf"
DESTINATION = "iphone-portrait"
SCHEME = "RuneScrib-iOS-Parity"
ONLY_TESTING = (
    "-only-testing:RuneScribIOSTests/ThemeFidelityMatrixTests/"
    "testExportCanonicalProductionRenders"
)
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
RAW_SIDECAR_KEYS = {
    "schemaVersion", "candidateID", "wrapperID", "sourceSHA", "seedIDs",
    "recipe", "renderMode", "width", "height", "resourceIDs",
    "visualPlanRevision", "runtimeState", "byteCount", "sha256",
    "deterministicSHA256", "outputPath",
}
RUNTIME_STATE_KEYS = {
    "candidateID", "codexID", "themeID", "recipe", "primarySurface",
    "seedIDs", "seedSurfaces", "visualPlanRevision",
}
COMMAND_KEYS = {
    "schemaVersion", "evidenceType", "commandID", "category", "sourceSHA",
    "sourceState", "cwd", "argv", "command", "destination",
    "startTimestamp", "endTimestamp", "exitCode", "expectedExitCode", "log",
    "outputs", "result", "failures", "acceptanceEvidence",
}
SOURCE_STATE_KEYS = {
    "requestedSourceSHA", "headSHA", "headMatchesSource",
    "worktreeChangeCount", "worktreeChangesOutsideEvidenceRoot",
    "worktreeCleanOutsideEvidenceRoot", "acceptanceEligible",
}
PROOF_KEYS = {
    "schemaVersion", "evidenceType", "result", "sourceSHA", "themeID",
    "codexID", "destination", "authority", "requiredResourceIDs", "states",
    "resources", "checks", "failures",
}

STATE_SPECS = (
    {
        "name": "primary",
        "candidateID": "canonical.moonleaf.moonleaf-received-cipher-final-a.23b96619f9",
        "primarySurface": "received-cipher",
        "resourceIDs": {
            "resource.received.moonleaf.primary.sender-avatar",
            "resource.received.moonleaf.primary.medallion",
        },
    },
    {
        "name": "share-card",
        "candidateID": "canonical.moonleaf.moonleaf-received-cipher-final-b.79446a4e03",
        "primarySurface": "share-builder",
        "resourceIDs": {
            "resource.received.moonleaf.share.sender-avatar",
            "resource.received.moonleaf.share.codex-badge",
            "resource.received.moonleaf.share.medallion",
        },
    },
)
REQUIRED_RESOURCE_IDS = frozenset().union(
    *(spec["resourceIDs"] for spec in STATE_SPECS)
)


class RuntimeEvidenceError(ValueError):
    """Raised when runtime evidence cannot support the received-identity claim."""


class DuplicateJSONKeyError(ValueError):
    pass


def _reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKeyError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise RuntimeEvidenceError(f"{label} is missing or linked: {path}")
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError(f"non-finite JSON number: {value}")
            ),
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise RuntimeEvidenceError(f"{label} is invalid: {path}: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeEvidenceError(f"{label} must be a JSON object: {path}")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _exact_keys(value: Mapping[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise RuntimeEvidenceError(
            f"{label} keys differ; missing={sorted(expected - set(value))}, "
            f"extra={sorted(set(value) - expected)}"
        )


def _repo_file(root: Path, value: str | Path, label: str) -> Path:
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    if candidate.is_symlink():
        raise RuntimeEvidenceError(f"{label} may not be a symbolic link: {candidate}")
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise RuntimeEvidenceError(f"{label} escapes the repository: {candidate}") from error
    if not resolved.is_file():
        raise RuntimeEvidenceError(f"{label} is missing: {resolved}")
    return resolved


def _binding(root: Path, path: Path) -> dict[str, Any]:
    return {
        "path": path.relative_to(root).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def _validate_binding(
    root: Path,
    value: Any,
    expected_path: Path,
    label: str,
    *,
    location: bool = False,
) -> None:
    expected_keys = {"path", "bytes", "sha256"}
    if location:
        expected_keys.add("location")
    if not isinstance(value, dict):
        raise RuntimeEvidenceError(f"{label} binding is absent")
    _exact_keys(value, expected_keys, f"{label} binding")
    if location and value.get("location") != "repository":
        raise RuntimeEvidenceError(f"{label} must be repository-located")
    expected = _binding(root, expected_path)
    if any(value.get(key) != expected[key] for key in expected):
        raise RuntimeEvidenceError(f"{label} binding differs")


def _png_dimensions(path: Path) -> list[int]:
    header = path.read_bytes()[:24]
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise RuntimeEvidenceError(f"canonical output is not PNG: {path}")
    return list(struct.unpack(">II", header[16:24]))


def _catalog_candidates(catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    candidates = catalog.get("candidates")
    if not isinstance(candidates, list):
        raise RuntimeEvidenceError("canonical catalog candidates are absent")
    result = {
        item.get("id"): item for item in candidates
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    expected = {spec["candidateID"] for spec in STATE_SPECS}
    if not expected.issubset(result):
        raise RuntimeEvidenceError("Moonleaf received canonical candidates are absent")
    return result


def _option_value(argv: list[str], option: str, label: str) -> str:
    positions = [index for index, value in enumerate(argv) if value == option]
    if len(positions) != 1 or positions[0] + 1 >= len(argv):
        raise RuntimeEvidenceError(f"{label} command must contain one {option}")
    return argv[positions[0] + 1]


def _setting(argv: list[str], name: str, label: str) -> str:
    prefix = name + "="
    values = [value[len(prefix):] for value in argv if value.startswith(prefix)]
    if len(values) != 1 or not values[0]:
        raise RuntimeEvidenceError(f"{label} command must contain one {name} setting")
    return values[0]


def _validate_command(
    root: Path,
    path: Path,
    source_sha: str,
    spec: Mapping[str, Any],
    output_path: Path,
    sidecar_path: Path,
) -> dict[str, Any]:
    label = str(spec["name"])
    record = load_json(path, f"{label} command record")
    _exact_keys(record, COMMAND_KEYS, f"{label} command record")
    if (
        record.get("schemaVersion") != "1.3"
        or record.get("evidenceType") != "command-execution"
        or record.get("category") != "runtime-evidence"
        or record.get("sourceSHA") != source_sha
        or record.get("destination") != DESTINATION
        or record.get("exitCode") != 0
        or record.get("expectedExitCode") != 0
        or record.get("result") != "PASS"
        or record.get("failures") != []
        or record.get("acceptanceEvidence") is not True
    ):
        raise RuntimeEvidenceError(f"{label} command is not passing acceptance evidence")
    state = record.get("sourceState")
    if not isinstance(state, dict):
        raise RuntimeEvidenceError(f"{label} command source state is absent")
    _exact_keys(state, SOURCE_STATE_KEYS, f"{label} command source state")
    if (
        state.get("requestedSourceSHA") != source_sha
        or state.get("headSHA") != source_sha
        or state.get("headMatchesSource") is not True
        or state.get("worktreeChangesOutsideEvidenceRoot") != []
        or state.get("worktreeCleanOutsideEvidenceRoot") is not True
        or state.get("acceptanceEligible") is not True
    ):
        raise RuntimeEvidenceError(f"{label} command is not source-bound")
    argv = record.get("argv")
    if not isinstance(argv, list) or any(not isinstance(value, str) for value in argv):
        raise RuntimeEvidenceError(f"{label} command argv is invalid")
    if argv[:2] != ["xcodebuild", "test"] or record.get("command") != shlex.join(argv):
        raise RuntimeEvidenceError(f"{label} command invocation differs")
    if "-disableAutomaticPackageResolution" not in argv or ONLY_TESTING not in argv:
        raise RuntimeEvidenceError(f"{label} command lacks the qualification selector")
    if _option_value(argv, "-project", label) != "RuneScrib.xcodeproj":
        raise RuntimeEvidenceError(f"{label} command project differs")
    if _option_value(argv, "-scheme", label) != SCHEME:
        raise RuntimeEvidenceError(f"{label} command scheme differs")
    if _option_value(argv, "-configuration", label) != "Release":
        raise RuntimeEvidenceError(f"{label} command configuration differs")
    if _option_value(argv, "-parallel-testing-enabled", label) != "NO":
        raise RuntimeEvidenceError(f"{label} command must be sequential")
    destination = _option_value(argv, "-destination", label)
    if not destination.startswith("platform=iOS Simulator,id="):
        raise RuntimeEvidenceError(f"{label} command destination is not a bound iOS Simulator")
    if _setting(argv, "ENABLE_TESTABILITY", label) != "YES":
        raise RuntimeEvidenceError(f"{label} command testability setting differs")
    if _setting(argv, "RUNESCRIBE_THEME_FIDELITY_SOURCE_SHA", label) != source_sha:
        raise RuntimeEvidenceError(f"{label} command source setting differs")
    if _setting(argv, "RUNESCRIBE_THEME_FIDELITY_CANONICAL_CANDIDATE", label) != spec["candidateID"]:
        raise RuntimeEvidenceError(f"{label} command candidate setting differs")
    canonical_root = Path(_setting(argv, "RUNESCRIBE_THEME_FIDELITY_CANONICAL_ROOT", label))
    if canonical_root.resolve() != root:
        raise RuntimeEvidenceError(f"{label} command canonical root differs")
    if record.get("cwd") not in {".", ""}:
        raise RuntimeEvidenceError(f"{label} command cwd must be the repository root")
    log = record.get("log")
    if not isinstance(log, dict) or not isinstance(log.get("path"), str):
        raise RuntimeEvidenceError(f"{label} command log binding is absent")
    log_path = _repo_file(root, EVIDENCE_ROOT / log["path"], f"{label} command log")
    _exact_keys(log, {"path", "bytes", "sha256"}, f"{label} command log binding")
    expected_log = {
        "path": log_path.relative_to(root / EVIDENCE_ROOT).as_posix(),
        "bytes": log_path.stat().st_size,
        "sha256": sha256_file(log_path),
    }
    if log != expected_log:
        raise RuntimeEvidenceError(f"{label} command log binding differs")
    outputs = record.get("outputs")
    if not isinstance(outputs, list) or len(outputs) != 2:
        raise RuntimeEvidenceError(f"{label} command must bind exactly its PNG and sidecar")
    by_path = {
        value.get("path"): value for value in outputs if isinstance(value, dict)
    }
    for target, kind in ((output_path, "output"), (sidecar_path, "sidecar")):
        relative = target.relative_to(root).as_posix()
        _validate_binding(root, by_path.get(relative), target, f"{label} {kind}", location=True)
    return record


def _validate_sidecar(
    root: Path,
    source_sha: str,
    spec: Mapping[str, Any],
    candidate: Mapping[str, Any],
) -> tuple[Path, Path, dict[str, Any], set[str]]:
    output_path = _repo_file(root, candidate.get("outputPath", ""), f"{spec['name']} output")
    sidecar_path = _repo_file(
        root, output_path.with_suffix(".sidecar.json"), f"{spec['name']} sidecar"
    )
    sidecar = load_json(sidecar_path, f"{spec['name']} sidecar")
    _exact_keys(sidecar, RAW_SIDECAR_KEYS, f"{spec['name']} sidecar")
    dimensions = candidate.get("requiredOutputDimensions")
    resources = sidecar.get("resourceIDs")
    if (
        sidecar.get("schemaVersion") != "1.0"
        or sidecar.get("candidateID") != spec["candidateID"]
        or sidecar.get("wrapperID") != candidate.get("requiredCanonicalWrapperID")
        or sidecar.get("sourceSHA") != source_sha
        or sidecar.get("seedIDs") != candidate.get("seedIDs")
        or sidecar.get("recipe") != candidate.get("recipeClass")
        or sidecar.get("renderMode") != candidate.get("renderMode")
        or [sidecar.get("width"), sidecar.get("height")] != dimensions
        or sidecar.get("outputPath") != candidate.get("outputPath")
        or not isinstance(resources, list)
        or resources != sorted(set(resources))
    ):
        raise RuntimeEvidenceError(f"{spec['name']} canonical sidecar authority binding differs")
    digest = sha256_file(output_path)
    if (
        sidecar.get("sha256") != digest
        or sidecar.get("deterministicSHA256") != digest
        or sidecar.get("byteCount") != output_path.stat().st_size
        or _png_dimensions(output_path) != dimensions
    ):
        raise RuntimeEvidenceError(f"{spec['name']} canonical output binding differs")
    revision = sidecar.get("visualPlanRevision")
    if isinstance(revision, bool) or not isinstance(revision, int) or revision <= 0:
        raise RuntimeEvidenceError(f"{spec['name']} visual-plan revision is invalid")
    try:
        runtime_state = json.loads(sidecar.get("runtimeState", ""), object_pairs_hook=_reject_duplicate_keys)
    except (json.JSONDecodeError, TypeError, ValueError) as error:
        raise RuntimeEvidenceError(f"{spec['name']} runtime state is invalid") from error
    if not isinstance(runtime_state, dict):
        raise RuntimeEvidenceError(f"{spec['name']} runtime state must be an object")
    _exact_keys(runtime_state, RUNTIME_STATE_KEYS, f"{spec['name']} runtime state")
    if (
        runtime_state.get("candidateID") != spec["candidateID"]
        or runtime_state.get("themeID") != THEME_ID
        or runtime_state.get("codexID") != CODEX_ID
        or runtime_state.get("recipe") != candidate.get("recipeClass")
        or runtime_state.get("primarySurface") != spec["primarySurface"]
        or runtime_state.get("seedIDs") != candidate.get("seedIDs")
        or runtime_state.get("visualPlanRevision") != str(revision)
    ):
        raise RuntimeEvidenceError(f"{spec['name']} runtime state authority binding differs")
    observed = set(resources)
    received = observed.intersection(REQUIRED_RESOURCE_IDS)
    if received != spec["resourceIDs"]:
        raise RuntimeEvidenceError(f"{spec['name']} received identity resource partition differs")
    return output_path, sidecar_path, sidecar, received


def build_proof(
    repo_root: Path,
    source_sha: str,
    primary_command_record: Path,
    share_command_record: Path,
) -> dict[str, Any]:
    root = repo_root.resolve()
    if HEX40.fullmatch(source_sha) is None:
        raise RuntimeEvidenceError("source SHA must be 40 lowercase hexadecimal characters")
    extraction_path = _repo_file(root, EXTRACTION_PATH, "received identity extraction")
    extraction = load_json(extraction_path, "received identity extraction")
    if extraction.get("qualityReview", {}).get("targetDeviceRuntime") != "PENDING_PROVIDER_BINDING":
        raise RuntimeEvidenceError("received identity targetDeviceRuntime must remain deterministic PENDING_PROVIDER_BINDING")
    extraction_outputs = extraction.get("outputs")
    if not isinstance(extraction_outputs, list):
        raise RuntimeEvidenceError("received identity extraction outputs are absent")
    extraction_by_id = {
        value.get("resourceID"): value for value in extraction_outputs if isinstance(value, dict)
    }
    if set(extraction_by_id) != REQUIRED_RESOURCE_IDS:
        raise RuntimeEvidenceError("received identity extraction resource coverage differs")
    catalog_path = _repo_file(root, CATALOG_PATH, "canonical catalog")
    catalog = load_json(catalog_path, "canonical catalog")
    candidates = _catalog_candidates(catalog)
    manifest_path = _repo_file(root, MANIFEST_PATH, "Moonleaf integrity manifest")
    manifest = load_json(manifest_path, "Moonleaf integrity manifest")
    manifest_files = manifest.get("files")
    if not isinstance(manifest_files, list):
        raise RuntimeEvidenceError("Moonleaf integrity manifest files are absent")
    manifest_by_id = {
        value.get("resourceID"): value for value in manifest_files if isinstance(value, dict)
    }
    if not REQUIRED_RESOURCE_IDS.issubset(manifest_by_id):
        raise RuntimeEvidenceError("Moonleaf integrity manifest received coverage differs")

    states: list[dict[str, Any]] = []
    resources: list[dict[str, Any]] = []
    command_paths = (primary_command_record, share_command_record)
    for spec, command_value in zip(STATE_SPECS, command_paths):
        candidate = candidates[str(spec["candidateID"])]
        if candidate.get("destinationsUsingResult") != [DESTINATION]:
            raise RuntimeEvidenceError(f"{spec['name']} candidate destination differs")
        output_path, sidecar_path, sidecar, received = _validate_sidecar(
            root, source_sha, spec, candidate
        )
        command_path = _repo_file(root, command_value, f"{spec['name']} command record")
        _validate_command(
            root, command_path, source_sha, spec, output_path, sidecar_path
        )
        states.append({
            "name": spec["name"],
            "candidateID": spec["candidateID"],
            "wrapperID": candidate.get("requiredCanonicalWrapperID"),
            "recipe": candidate.get("recipeClass"),
            "seedIDs": candidate.get("seedIDs"),
            "commandRecord": _binding(root, command_path),
            "output": _binding(root, output_path),
            "sidecar": _binding(root, sidecar_path),
            "observedResourceIDs": sidecar["resourceIDs"],
            "observedReceivedIdentityResourceIDs": sorted(received),
            "visualPlanRevision": sidecar["visualPlanRevision"],
            "runtimeState": json.loads(sidecar["runtimeState"]),
        })
        for resource_id in sorted(spec["resourceIDs"]):
            extracted = extraction_by_id[resource_id]
            manifest_record = manifest_by_id[resource_id]
            output = extracted.get("output", {})
            shipping_path = _repo_file(root, output.get("path", ""), resource_id)
            expected_manifest_path = shipping_path.relative_to(
                manifest_path.parent.parent
            ).as_posix()
            if (
                output.get("sha256") != sha256_file(shipping_path)
                or output.get("bytes") != shipping_path.stat().st_size
                or output.get("dimensions") != _png_dimensions(shipping_path)
                or manifest_record.get("path") != expected_manifest_path
                or manifest_record.get("sha256") != output.get("sha256")
                or manifest_record.get("bytes") != output.get("bytes")
            ):
                raise RuntimeEvidenceError(f"shipping resource binding differs: {resource_id}")
            resources.append({
                "resourceID": resource_id,
                "state": spec["name"],
                "path": output["path"],
                "bytes": output["bytes"],
                "sha256": output["sha256"],
                "dimensions": output["dimensions"],
                "candidateID": spec["candidateID"],
            })

    if set().union(*(set(state["observedReceivedIdentityResourceIDs"]) for state in states)) != REQUIRED_RESOURCE_IDS:
        raise RuntimeEvidenceError("received identity runtime proof does not cover all five resources")
    return {
        "schemaVersion": "1.0",
        "evidenceType": "moonleaf-received-identity-target-device-runtime",
        "result": "PASS",
        "sourceSHA": source_sha,
        "themeID": THEME_ID,
        "codexID": CODEX_ID,
        "destination": DESTINATION,
        "authority": {
            "canonicalCatalog": _binding(root, catalog_path),
            "integrityManifest": _binding(root, manifest_path),
            "extraction": _binding(root, extraction_path),
        },
        "requiredResourceIDs": sorted(REQUIRED_RESOURCE_IDS),
        "states": states,
        "resources": sorted(resources, key=lambda value: value["resourceID"]),
        "checks": {
            "sourceBoundCommands": True,
            "deterministicCanonicalOutputs": True,
            "exactStateResourcePartitions": True,
            "shippingIntegrityBindings": True,
        },
        "failures": [],
    }


def validate_proof(repo_root: Path, proof: dict[str, Any], source_sha: str | None = None) -> None:
    root = repo_root.resolve()
    _exact_keys(proof, PROOF_KEYS, "runtime proof")
    proof_source = proof.get("sourceSHA")
    if not isinstance(proof_source, str) or HEX40.fullmatch(proof_source) is None:
        raise RuntimeEvidenceError("runtime proof source SHA is invalid")
    if source_sha is not None and proof_source != source_sha:
        raise RuntimeEvidenceError("runtime proof source SHA differs")
    states = proof.get("states")
    if not isinstance(states, list) or len(states) != 2:
        raise RuntimeEvidenceError("runtime proof state coverage differs")
    command_paths: list[Path] = []
    for state, spec in zip(states, STATE_SPECS):
        if not isinstance(state, dict) or state.get("name") != spec["name"]:
            raise RuntimeEvidenceError("runtime proof state order differs")
        binding = state.get("commandRecord")
        if not isinstance(binding, dict) or not isinstance(binding.get("path"), str):
            raise RuntimeEvidenceError("runtime proof command binding is absent")
        path = _repo_file(root, binding["path"], f"{spec['name']} command record")
        _validate_binding(root, binding, path, f"{spec['name']} command record")
        command_paths.append(path)
    rebuilt = build_proof(root, proof_source, command_paths[0], command_paths[1])
    if proof != rebuilt:
        raise RuntimeEvidenceError("runtime proof content differs from its bound evidence")


def validate_runtime_state(
    repo_root: Path,
    extraction: dict[str, Any],
    *,
    require_proof: bool = False,
    source_sha: str | None = None,
) -> bool:
    status = extraction.get("qualityReview", {}).get("targetDeviceRuntime")
    if status != "PENDING_PROVIDER_BINDING":
        raise RuntimeEvidenceError(
            "targetDeviceRuntime must remain PENDING_PROVIDER_BINDING; only the companion proof may qualify it"
        )
    proof_path = repo_root.resolve() / PROOF_PATH
    if not proof_path.exists():
        if require_proof:
            raise RuntimeEvidenceError("Moonleaf target-device runtime companion proof is absent")
        return False
    proof = load_json(proof_path, "Moonleaf target-device runtime proof")
    validate_proof(repo_root, proof, source_sha)
    return True


def qualification_document(repo_root: Path, extraction: dict[str, Any]) -> dict[str, Any]:
    qualified = dict(extraction)
    review = dict(extraction.get("qualityReview", {}))
    if validate_runtime_state(repo_root, extraction):
        review["targetDeviceRuntime"] = "PASS"
    qualified["qualityReview"] = review
    return qualified


def _write_no_overwrite(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            existing = load_json(path, "existing Moonleaf target-device runtime proof")
            if existing != document:
                raise RuntimeEvidenceError("runtime proof already exists and differs") from error
    finally:
        temporary.unlink(missing_ok=True)


def promote(
    repo_root: Path,
    source_sha: str,
    primary_command_record: Path,
    share_command_record: Path,
) -> dict[str, Any]:
    root = repo_root.resolve()
    proof = build_proof(
        root, source_sha, primary_command_record, share_command_record
    )
    target = root / PROOF_PATH
    _write_no_overwrite(target, proof)
    validate_proof(root, load_json(target, "runtime proof"), source_sha)
    return proof


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    promote = subparsers.add_parser("promote")
    promote.add_argument("--repo-root", type=Path, required=True)
    promote.add_argument("--source-sha", required=True)
    promote.add_argument("--primary-command-record", type=Path, required=True)
    promote.add_argument("--share-command-record", type=Path, required=True)
    check = subparsers.add_parser("check")
    check.add_argument("--repo-root", type=Path, required=True)
    check.add_argument("--source-sha")
    args = parser.parse_args()
    root = args.repo_root.resolve()
    if args.command == "promote":
        promote(
            root,
            args.source_sha,
            args.primary_command_record,
            args.share_command_record,
        )
        target = root / PROOF_PATH
        print(json.dumps({"path": str(target), "result": "PASS"}, sort_keys=True))
    else:
        extraction = load_json(root / EXTRACTION_PATH, "received identity extraction")
        validate_runtime_state(root, extraction, require_proof=True, source_sha=args.source_sha)
        print(json.dumps({"path": str(root / PROOF_PATH), "result": "PASS"}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
