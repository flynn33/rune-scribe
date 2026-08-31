#!/usr/bin/env python3
"""Materialize v4.3 acceptance indexes from source-bound raw render evidence."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any, Mapping, Sequence

from PIL import Image, UnidentifiedImageError

try:
    from theme_fidelity_authority_v13 import AuthorityV13Checker, DEFAULT_IMPORT_MANIFEST
    from theme_fidelity_execution_v12 import (
        _MISSING,
        comparison_metrics,
        evaluate_operator,
        evaluate_structural_assertion,
        frame_index,
        integral_crop,
        load_rgba,
        normalize_pair,
        parse_iso_timestamp,
        recomputed_probe_observed,
    )
    from theme_fidelity_xcui_evidence import (
        CONTRACT_PATHS,
        CONTRACT_V43,
        UI_TEST_TARGET_KIND,
        XCUI_TEST_IDENTIFIER,
        capture_candidate_ids_for_entry,
        resolve_attachment,
        sidecar_name,
        validate_sidecar,
        xcui_probe_ids_for_entry,
    )
except ModuleNotFoundError:  # pragma: no cover - module execution from repository root.
    from scripts.theme_fidelity_authority_v13 import (  # type: ignore[no-redef]
        AuthorityV13Checker,
        DEFAULT_IMPORT_MANIFEST,
    )
    from scripts.theme_fidelity_execution_v12 import (  # type: ignore[no-redef]
        _MISSING,
        comparison_metrics,
        evaluate_operator,
        evaluate_structural_assertion,
        frame_index,
        integral_crop,
        load_rgba,
        normalize_pair,
        parse_iso_timestamp,
        recomputed_probe_observed,
    )
    from scripts.theme_fidelity_xcui_evidence import (  # type: ignore[no-redef]
        CONTRACT_PATHS,
        CONTRACT_V43,
        UI_TEST_TARGET_KIND,
        XCUI_TEST_IDENTIFIER,
        capture_candidate_ids_for_entry,
        resolve_attachment,
        sidecar_name,
        validate_sidecar,
        xcui_probe_ids_for_entry,
    )


SCHEMA_VERSION = "1.3"
EXPECTED_COUNTS = {
    "canonicalCandidates": 50,
    "responsiveEntries": 400,
    "runtimeProbeInstances": 576,
    "canonicalImageMappings": 400,
    "responsiveStructuralMappings": 700,
    "negativeInvariantMappings": 4,
    "mappingResults": 1104,
}
SHA40 = re.compile(r"[0-9a-f]{40}\Z")
SHA64 = re.compile(r"[0-9a-f]{64}\Z")
DESTINATION_DISPLAY_NAMES = {
    "iphone-portrait": "iPhone portrait",
    "ipad-portrait": "iPad portrait",
    "macos-standard": "macOS standard",
    "macos-resized": "macOS resized",
}
RAW_CANONICAL_KEYS = {
    "schemaVersion", "candidateID", "wrapperID", "sourceSHA", "seedIDs",
    "recipe", "renderMode", "width", "height", "resourceIDs",
    "visualPlanRevision", "runtimeState", "byteCount", "sha256",
    "deterministicSHA256", "outputPath",
}
RAW_RESOURCE_KEYS = {
    "schemaVersion", "candidateID", "wrapperID", "sourceSHA", "seedID",
    "renderMode", "resourceID", "visualPlanRevisions", "width", "height",
    "byteCount", "sha256", "determinism", "outputPath",
}
MATERIALIZED_TOP_LEVEL = (
    "canonical-results.json",
    "responsive-results.json",
    "runtime-probe-results.json",
    "mapping-results.json",
)


class MaterializationError(ValueError):
    """Raised when raw evidence cannot support an acceptance record."""


class DuplicateJSONKeyError(ValueError):
    pass


def reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for key, value in pairs:
        if key in output:
            raise DuplicateJSONKeyError(f"duplicate JSON key: {key}")
        output[key] = value
    return output


def reject_nonfinite(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def load_json(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise MaterializationError(f"{label} is missing or linked: {path}")
    try:
        decoded = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonfinite,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise MaterializationError(f"{label} is invalid: {path}: {error}") from error
    if not isinstance(decoded, dict):
        raise MaterializationError(f"{label} must be a JSON object: {path}")
    return decoded


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_sha256(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def rendered_json(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n"


def rendered_json_sha256(value: Any) -> str:
    return hashlib.sha256(rendered_json(value).encode("utf-8")).hexdigest()


def require_sha(value: Any, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise MaterializationError(f"{label} is not a lowercase hexadecimal digest")
    return value


def require_exact_keys(value: Mapping[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise MaterializationError(f"{label} keys differ; missing={missing}, extra={extra}")


def image_dimensions(path: Path, label: str) -> tuple[int, int]:
    try:
        with Image.open(path) as image:
            image.load()
            if image.format != "PNG":
                raise MaterializationError(f"{label} is not PNG: {path}")
            return image.size
    except (OSError, UnidentifiedImageError) as error:
        raise MaterializationError(f"{label} is not decodable: {path}: {error}") from error


def safe_file(root: Path, name: Any, label: str) -> Path:
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise MaterializationError(f"{label} filename is unsafe")
    path = (root / name).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as error:
        raise MaterializationError(f"{label} escapes its root") from error
    if not path.is_file() or path.is_symlink():
        raise MaterializationError(f"{label} file is missing or linked: {path}")
    return path


def displayed_path(path: Path, evidence_root: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(evidence_root.resolve()).as_posix()
    except ValueError:
        return str(resolved)


def safe_stem(identifier: str) -> str:
    rendered = re.sub(r"[^A-Za-z0-9._-]+", "_", identifier).strip("._")
    if not rendered:
        raise MaterializationError(f"identifier cannot form a safe filename: {identifier!r}")
    return rendered


def write_json(path: Path, document: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(rendered_json(document))
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise MaterializationError(
                f"materialization target appeared during write; refusing to overwrite: {path}"
            ) from error
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


@dataclass(frozen=True)
class AuthorityBundle:
    repository_root: Path
    authority_root: Path
    authority_path: Path
    canonical_path: Path
    seed_path: Path
    probe_path: Path
    responsive_candidate_path: Path
    authority: dict[str, Any]
    canonical: dict[str, Any]
    seeds: dict[str, dict[str, Any]]
    probes: dict[str, dict[str, Any]]
    responsive_candidates: dict[str, dict[str, Any]]

    @classmethod
    def load(cls, repository_root: Path) -> "AuthorityBundle":
        manifest = (repository_root / DEFAULT_IMPORT_MANIFEST).resolve()
        validation = AuthorityV13Checker(repository_root, manifest).run()
        if validation.get("result") != "PASS":
            raise MaterializationError(
                "v4.3 authority import is invalid: "
                + json.dumps(validation.get("findings", [])[:5], sort_keys=True)
            )
        authority_root = manifest.parent
        comparison = authority_root / "03-COMPARISON-AUTHORITY"
        authority_path = comparison / "Comparison-Authority-v1.3.json"
        canonical_path = comparison / "Canonical-Render-Catalog-v1.3.json"
        seed_path = comparison / "Deterministic-Seed-Catalog-v1.3.json"
        probe_path = comparison / "Runtime-Probe-Catalog-v1.3.json"
        responsive_candidate_path = comparison / "Responsive-Candidate-Catalog-v1.3.json"
        authority = load_json(authority_path, "comparison authority")
        canonical = load_json(canonical_path, "canonical catalog")
        seed_document = load_json(seed_path, "seed catalog")
        probe_document = load_json(probe_path, "probe catalog")
        candidate_document = load_json(responsive_candidate_path, "responsive candidate catalog")

        def index(document: Mapping[str, Any], key: str, identifier: str) -> dict[str, dict[str, Any]]:
            values = document.get(key)
            if not isinstance(values, list):
                raise MaterializationError(f"authority {key} is not an array")
            output: dict[str, dict[str, Any]] = {}
            for item in values:
                if not isinstance(item, dict):
                    raise MaterializationError(f"authority {key} contains a non-object")
                item_id = item.get(identifier)
                if not isinstance(item_id, str) or not item_id or item_id in output:
                    raise MaterializationError(f"authority {key} IDs are invalid")
                output[item_id] = item
            return output

        seeds = index(seed_document, "seeds", "id")
        probes = index(probe_document, "probes", "id")
        responsive_candidates = index(candidate_document, "candidates", "id")
        entries = authority.get("entries")
        canonical_candidates = canonical.get("candidates")
        if not isinstance(entries, list) or len(entries) != EXPECTED_COUNTS["responsiveEntries"]:
            raise MaterializationError("authority does not contain exactly 400 responsive entries")
        if not isinstance(canonical_candidates, list) or len(canonical_candidates) != EXPECTED_COUNTS["canonicalCandidates"]:
            raise MaterializationError("authority does not contain exactly 50 canonical candidates")
        return cls(
            repository_root=repository_root.resolve(),
            authority_root=authority_root,
            authority_path=authority_path,
            canonical_path=canonical_path,
            seed_path=seed_path,
            probe_path=probe_path,
            responsive_candidate_path=responsive_candidate_path,
            authority=authority,
            canonical=canonical,
            seeds=seeds,
            probes=probes,
            responsive_candidates=responsive_candidates,
        )


@dataclass(frozen=True)
class ExtractionBinding:
    run_report_path: Path
    run_report_sha256: str
    extraction_path: Path
    extraction_sha256: str
    attachments: dict[str, dict[str, Any]]


def bound_file(raw: Any, base: Path, label: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise MaterializationError(f"{label} path is missing")
    declared = Path(raw)
    path = declared.resolve() if declared.is_absolute() else (base / declared).resolve()
    if not path.is_file() or path.is_symlink():
        raise MaterializationError(f"{label} is missing or linked: {path}")
    return path


def validate_source_manifest(document: Mapping[str, Any], source_sha: str, label: str) -> None:
    required = {
        "schemaVersion", "sourceSHA", "fileCount", "aggregateSHA256",
        "gitStatusSHA256", "isClean", "files",
    }
    require_exact_keys(document, required, label)
    if document.get("schemaVersion") != "1.0" or document.get("sourceSHA") != source_sha:
        raise MaterializationError(f"{label} identity differs")
    if document.get("isClean") is not True:
        raise MaterializationError(f"{label} does not attest a clean source tree")
    require_sha(document.get("aggregateSHA256"), SHA64, f"{label} aggregate SHA-256")
    require_sha(document.get("gitStatusSHA256"), SHA64, f"{label} status SHA-256")
    files = document.get("files")
    file_count = document.get("fileCount")
    if (
        not isinstance(files, list)
        or isinstance(file_count, bool)
        or not isinstance(file_count, int)
        or file_count != len(files)
    ):
        raise MaterializationError(f"{label} file inventory is malformed")
    aggregate = hashlib.sha256()
    prior_path = ""
    for index, record in enumerate(files):
        if not isinstance(record, dict):
            raise MaterializationError(f"{label} file {index} is not an object")
        require_exact_keys(record, {"path", "bytes", "sha256", "executable"}, f"{label} file {index}")
        relative = record.get("path")
        byte_count = record.get("bytes")
        executable = record.get("executable")
        if (
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or relative <= prior_path
            or isinstance(byte_count, bool)
            or not isinstance(byte_count, int)
            or byte_count < 0
            or not isinstance(executable, bool)
        ):
            raise MaterializationError(f"{label} file {index} metadata is malformed")
        digest = require_sha(record.get("sha256"), SHA64, f"{label} file {index} SHA-256")
        aggregate.update(
            f"{relative}\0{byte_count}\0{digest}\0{1 if executable else 0}\n".encode("utf-8")
        )
        prior_path = relative
    if aggregate.hexdigest() != document.get("aggregateSHA256"):
        raise MaterializationError(f"{label} aggregate SHA-256 differs")


def validate_source_binding(
    binding: Mapping[str, Any],
    report_path: Path,
    source_sha: str,
) -> None:
    if binding.get("prePostEqual") is not True:
        raise MaterializationError("responsive run report lacks an equal pre/post source binding")
    aggregate = require_sha(
        binding.get("aggregateSHA256"), SHA64, "responsive source aggregate SHA-256"
    )
    status = require_sha(
        binding.get("gitStatusSHA256"), SHA64, "responsive source status SHA-256"
    )
    manifests: list[dict[str, Any]] = []
    for phase in ("before", "after"):
        path = bound_file(
            binding.get(f"{phase}Manifest"),
            report_path.parent,
            f"responsive source manifest {phase}",
        )
        declared_digest = require_sha(
            binding.get(f"{phase}ManifestSHA256"),
            SHA64,
            f"responsive source manifest {phase} SHA-256",
        )
        if sha256_file(path) != declared_digest:
            raise MaterializationError(f"responsive source manifest {phase} digest differs")
        manifest = load_json(path, f"responsive source manifest {phase}")
        validate_source_manifest(manifest, source_sha, f"responsive source manifest {phase}")
        if manifest.get("aggregateSHA256") != aggregate or manifest.get("gitStatusSHA256") != status:
            raise MaterializationError(f"responsive source manifest {phase} binding differs")
        manifests.append(manifest)
    if manifests[0] != manifests[1]:
        raise MaterializationError("responsive source manifests differ before and after capture")


def expected_authority_provenance(
    repository_root: Path,
    contract_version: str,
) -> dict[str, Any]:
    specification = CONTRACT_PATHS.get(contract_version)
    if specification is None:
        raise MaterializationError(
            f"responsive extraction authority contract is unsupported: {contract_version!r}"
        )
    files: dict[str, dict[str, str]] = {}
    for key in ("authority", "probes", "seeds", "candidates"):
        relative = specification.get(key)
        if not isinstance(relative, Path):
            raise MaterializationError(
                f"responsive extraction authority path is invalid: {contract_version} {key}"
            )
        path = (repository_root / relative).resolve()
        if not path.is_file() or path.is_symlink():
            raise MaterializationError(
                f"responsive extraction authority file is missing or linked: {path}"
            )
        files[key] = {"path": relative.as_posix(), "sha256": sha256_file(path)}
    return {
        "contractVersion": contract_version,
        "schemaVersion": specification["schemaVersion"],
        "files": files,
    }


def validate_v43_extraction_identity(
    extraction: Mapping[str, Any],
    source_sha: str,
    bundle: AuthorityBundle,
) -> None:
    if (
        extraction.get("schemaVersion") != "1.3"
        or extraction.get("result") not in {"pass", "PASS"}
        or extraction.get("sourceSHA") != source_sha
        or extraction.get("authorityContract") != CONTRACT_V43
        or extraction.get("sourceXCUIContract") != CONTRACT_V43
    ):
        raise MaterializationError(
            "responsive extraction report is not a direct source-bound v4.3 capture"
        )
    manifest = bundle.repository_root / DEFAULT_IMPORT_MANIFEST
    validation = extraction.get("authorityValidation")
    if (
        not isinstance(validation, dict)
        or validation.get("schemaVersion") != "1.3"
        or validation.get("authorityVersion") != "4.3"
        or validation.get("result") != "PASS"
        or validation.get("manifestSHA256") != sha256_file(manifest)
        or validation.get("findings") != []
    ):
        raise MaterializationError(
            "responsive extraction lacks passing v4.3 authority validation"
        )
    expected_target = expected_authority_provenance(
        bundle.repository_root, CONTRACT_V43
    )
    if extraction.get("authorityProvenance") != expected_target:
        raise MaterializationError(
            "responsive extraction v4.3 authority provenance differs"
        )
    expected_source = expected_authority_provenance(
        bundle.repository_root, CONTRACT_V43
    )
    if extraction.get("sourceXCUIAuthorityProvenance") != expected_source:
        raise MaterializationError(
            "responsive extraction v4.3 source authority provenance differs"
        )


def validate_extraction_binding(
    run_report_path: Path,
    capture_root: Path,
    source_sha: str,
    expected_attachment_names: set[str],
    expected_counts: Mapping[str, int],
    bundle: AuthorityBundle,
) -> ExtractionBinding:
    run_report_path = run_report_path.resolve()
    report = load_json(run_report_path, "responsive run report")
    if (
        report.get("schemaVersion") != "1.0"
        or report.get("result") not in {"pass", "PASS"}
        or report.get("phase") != "final"
        or report.get("failures") != []
    ):
        raise MaterializationError("responsive run report is not a passing final run")
    if report.get("sourceSHA") != source_sha:
        raise MaterializationError("responsive run report source SHA differs")
    binding = report.get("sourceBinding")
    if not isinstance(binding, dict):
        raise MaterializationError("responsive run report has no source binding")
    validate_source_binding(binding, run_report_path, source_sha)
    commands = report.get("commands")
    if not isinstance(commands, list) or not commands:
        raise MaterializationError("responsive run report has no command results")
    for index, command in enumerate(commands):
        if (
            not isinstance(command, dict)
            or command.get("exitCode") != 0
            or command.get("result") not in {"pass", "PASS"}
        ):
            raise MaterializationError(f"responsive run command {index} did not pass")
    output_paths = report.get("outputPaths")
    if not isinstance(output_paths, dict):
        raise MaterializationError("responsive run report has no output paths")
    captures_value = output_paths.get("captures")
    if not isinstance(captures_value, str) or not captures_value:
        raise MaterializationError("responsive run report capture root is missing")
    captures_declared = Path(captures_value)
    captures_declared = (
        captures_declared.resolve()
        if captures_declared.is_absolute()
        else (run_report_path.parent / captures_declared).resolve()
    )
    if captures_declared != capture_root.resolve():
        raise MaterializationError("responsive run report capture root differs")
    extraction_value = output_paths.get("extraction")
    if not isinstance(extraction_value, str) or not extraction_value:
        raise MaterializationError("responsive run report has no extraction report path")
    extraction_declared = Path(extraction_value)
    extraction_path = (
        extraction_declared.resolve()
        if extraction_declared.is_absolute()
        else (run_report_path.parent / extraction_declared).resolve()
    )
    extraction_digest = require_sha(
        output_paths.get("extractionSHA256"), SHA64, "responsive extraction SHA-256"
    )
    if sha256_file(extraction_path) != extraction_digest:
        raise MaterializationError("responsive extraction report digest differs")
    extraction = load_json(extraction_path, "responsive extraction report")
    validate_v43_extraction_identity(extraction, source_sha, bundle)
    extraction_capture_value = extraction.get("captureRoot")
    if not isinstance(extraction_capture_value, str) or not extraction_capture_value:
        raise MaterializationError("responsive extraction capture root is missing")
    extraction_capture = Path(extraction_capture_value)
    extraction_capture = (
        extraction_capture.resolve()
        if extraction_capture.is_absolute()
        else (extraction_path.parent / extraction_capture).resolve()
    )
    if extraction_capture != capture_root.resolve():
        raise MaterializationError("responsive extraction capture root differs")
    for key, expected in expected_counts.items():
        if extraction.get(key) != expected:
            raise MaterializationError(
                f"responsive extraction {key} is {extraction.get(key)!r}, expected {expected}"
            )
    raw_attachments = extraction.get("attachments")
    if (
        not isinstance(raw_attachments, list)
        or len(raw_attachments) != expected_counts["attachmentCount"]
    ):
        raise MaterializationError("responsive extraction attachment inventory is incomplete")
    attachments: dict[str, dict[str, Any]] = {}
    for item in raw_attachments:
        if not isinstance(item, dict):
            raise MaterializationError("responsive extraction contains a non-object attachment")
        name = item.get("name")
        if not isinstance(name, str) or not name or Path(name).name != name or name in attachments:
            raise MaterializationError("responsive extraction attachment names are invalid")
        path = safe_file(capture_root, name, f"responsive attachment {name}")
        expected_hash = require_sha(item.get("sha256"), SHA64, f"responsive attachment {name}")
        expected_bytes = item.get("bytes")
        if sha256_file(path) != expected_hash:
            raise MaterializationError(f"responsive attachment digest differs: {name}")
        if (
            isinstance(expected_bytes, bool)
            or not isinstance(expected_bytes, int)
            or expected_bytes <= 0
            or path.stat().st_size != expected_bytes
        ):
            raise MaterializationError(f"responsive attachment byte count differs: {name}")
        attachments[name] = item
    if set(attachments) != expected_attachment_names:
        missing = expected_attachment_names - set(attachments)
        extra = set(attachments) - expected_attachment_names
        raise MaterializationError(
            f"responsive extraction attachment set differs; missing={len(missing)}, "
            f"extra={len(extra)}"
        )
    return ExtractionBinding(
        run_report_path=run_report_path.resolve(),
        run_report_sha256=sha256_file(run_report_path.resolve()),
        extraction_path=extraction_path,
        extraction_sha256=extraction_digest,
        attachments=attachments,
    )


def expected_responsive_inventory(
    bundle: AuthorityBundle,
) -> tuple[set[str], dict[str, int]]:
    names: set[str] = set()
    primary_count = 0
    record_count = 0
    auxiliary_count = 0
    candidate_count = 0
    query_count = 0
    sidecar_count = 0
    for entry in bundle.authority["entries"]:
        stem = f"{str(entry['theme']).lower()}--{entry['surface']}--{entry['destination']}"
        names.add(stem + ".png")
        names.add(stem + ".capture.json")
        primary_count += 1
        record_count += 1
        if entry["surface"] == "reduce-motion":
            names.add(stem + "--stability-b.png")
            auxiliary_count += 1
        if entry["surface"] == "static-share":
            names.add(stem + "--renderer-output.png")
            auxiliary_count += 1
        if entry["theme"] == "Norse" and entry["surface"] == "vault-locked":
            names.add(stem + "--optional-codex-locked.png")
            auxiliary_count += 1
        candidates = capture_candidate_ids_for_entry(
            entry,
            bundle.probes,
            bundle.responsive_candidates,
            CONTRACT_V43,
        )
        probes = xcui_probe_ids_for_entry(entry, bundle.probes)
        if candidates or probes:
            names.add(sidecar_name(entry))
            sidecar_count += 1
        for candidate_id in candidates:
            names.add(
                f"{stem}--candidate-element--{candidate_id}.png"
            )
            candidate_count += 1
        if "probe.norse.vault.locked-element-count" in probes:
            names.add(stem + "--xcui-query.png")
            query_count += 1
    counts = {
        "pngCount": primary_count,
        "auxiliaryPNGCount": auxiliary_count,
        "recordCount": record_count,
        "candidatePNGCount": candidate_count,
        "xcuiQueryPNGCount": query_count,
        "xcuiSidecarCount": sidecar_count,
        "attachmentCount": len(names),
    }
    expected = {
        "pngCount": 400,
        "auxiliaryPNGCount": 44,
        "recordCount": 400,
        "candidatePNGCount": 341,
        "xcuiQueryPNGCount": 4,
        "xcuiSidecarCount": 325,
        "attachmentCount": 1514,
    }
    if counts != expected:
        raise MaterializationError(f"v4.3 responsive attachment inventory drifted: {counts}")
    return names, counts


def index_json_documents(
    root: Path,
    predicate,
    label: str,
) -> dict[str, tuple[Path, dict[str, Any]]]:
    if not root.is_dir() or root.is_symlink():
        raise MaterializationError(f"{label} root is missing or linked: {root}")
    output: dict[str, tuple[Path, dict[str, Any]]] = {}
    for path in sorted(root.rglob("*.json")):
        document = load_json(path, label)
        if not predicate(document):
            continue
        candidate_id = document.get("candidateID")
        if not isinstance(candidate_id, str) or not candidate_id or candidate_id in output:
            raise MaterializationError(f"{label} candidate IDs are invalid or duplicated")
        output[candidate_id] = (path.resolve(), document)
    return output


def resolve_canonical_output(
    raw_root: Path,
    sidecar_path: Path,
    sidecar: Mapping[str, Any],
    catalog_record: Mapping[str, Any],
) -> Path:
    declared = sidecar.get("outputPath")
    if not isinstance(declared, str) or not declared or Path(declared).is_absolute():
        raise MaterializationError(
            f"canonical sidecar output path is invalid: {catalog_record.get('id')}"
        )
    catalog_path = str(catalog_record.get("outputPath", ""))
    catalog_suffix = catalog_path.removeprefix(
        "docs/verification/theme-fidelity-v4-3/canonical/"
    )
    if declared not in {catalog_path, catalog_suffix}:
        raise MaterializationError(
            f"canonical sidecar output path differs: {catalog_record.get('id')}"
        )
    sibling_name = sidecar_path.name.removesuffix(".sidecar.json") + ".png"
    candidates = [
        sidecar_path.with_name(sibling_name),
        raw_root / declared,
        raw_root / catalog_path,
        raw_root / catalog_suffix,
    ]
    matches: list[Path] = []
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved.is_file() and not resolved.is_symlink() and resolved not in matches:
            matches.append(resolved)
    if not matches:
        raise MaterializationError(
            f"canonical output is missing: {catalog_record.get('id')}"
        )
    digests = {sha256_file(path) for path in matches}
    if len(digests) != 1:
        raise MaterializationError(
            f"canonical output locations disagree: {catalog_record.get('id')}"
        )
    return matches[0]


def validate_comparison_report(
    path: Path,
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    candidate_path: Path,
    bundle: AuthorityBundle,
) -> dict[str, Any]:
    candidate_id = str(candidate["id"])
    if report.get("schemaVersion") != SCHEMA_VERSION:
        raise MaterializationError(f"comparison report version differs: {candidate_id}")
    exact = {
        "candidateID": candidate_id,
        "candidateSHA256": sha256_file(candidate_path),
        "referenceSHA256": candidate.get("referenceSHA256"),
        "expectedDimensions": candidate.get("requiredOutputDimensions"),
        "referenceDimensions": candidate.get("referenceDimensions"),
        "candidateDimensions": candidate.get("requiredOutputDimensions"),
        "thresholdProfile": candidate.get("thresholdProfile"),
        "authoritySHA256": sha256_file(bundle.authority_path),
        "canonicalCatalogSHA256": sha256_file(bundle.canonical_path),
        "result": "PASS",
    }
    for key, expected in exact.items():
        if report.get(key) != expected:
            raise MaterializationError(
                f"comparison report {key} differs for {candidate_id}"
            )
    checks = report.get("checks")
    metrics = report.get("metrics")
    if not isinstance(checks, dict) or not checks or any(value is not True for value in checks.values()):
        raise MaterializationError(f"comparison checks did not all pass: {candidate_id}")
    if not isinstance(metrics, dict):
        raise MaterializationError(f"comparison metrics are malformed: {candidate_id}")
    evaluation_kind = candidate.get("evaluationKind")
    evidence: dict[str, Any] = {
        "reportPath": str(path.resolve()),
        "reportSHA256": sha256_file(path),
        "checks": dict(checks),
        "metrics": dict(metrics),
    }
    if evaluation_kind == "resource-byte-identity":
        if checks != {"byteIdentity": True, "exactDimensions": True} or metrics:
            raise MaterializationError(
                f"resource comparison report is not exact byte identity: {candidate_id}"
            )
        if report.get("candidateSHA256") != candidate.get("referenceSHA256"):
            raise MaterializationError(
                f"resource candidate bytes differ from authority: {candidate_id}"
            )
        if report.get("failure") is not None:
            raise MaterializationError(f"passing resource report declares failure: {candidate_id}")
        return evidence

    expected_check_names = {
        "exactDimensions", "luminanceSSIM", "edgeSSIM", "medianDeltaE",
        "p95DeltaE", "severeDeltaEPercent",
    }
    expected_metric_names = {
        "luminanceSSIM", "edgeSSIM", "medianDeltaE", "p95DeltaE",
        "severeDeltaEThreshold", "severeDeltaEPercent",
    }
    if set(checks) != expected_check_names or set(metrics) != expected_metric_names:
        raise MaterializationError(f"comparison metric fields differ: {candidate_id}")
    for name, value in metrics.items():
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise MaterializationError(f"comparison metric {name} is invalid: {candidate_id}")
    thresholds = bundle.authority.get("thresholdProfiles", {}).get(
        candidate.get("thresholdProfile")
    )
    if not isinstance(thresholds, dict) or report.get("thresholds") != thresholds:
        raise MaterializationError(f"comparison thresholds differ: {candidate_id}")
    heatmaps: dict[str, dict[str, Any]] = {}
    for kind, suffix in (
        ("ssim", ".ssim-heatmap.png"),
        ("color", ".color-heatmap.png"),
    ):
        heatmap = path.with_suffix(suffix)
        if not heatmap.is_file() or heatmap.is_symlink():
            raise MaterializationError(f"comparison {kind} heatmap is missing: {candidate_id}")
        if image_dimensions(heatmap, f"comparison {kind} heatmap") != tuple(
            candidate["requiredOutputDimensions"]
        ):
            raise MaterializationError(f"comparison {kind} heatmap dimensions differ: {candidate_id}")
        heatmaps[kind] = {"path": str(heatmap.resolve()), "sha256": sha256_file(heatmap)}
    evidence["heatmaps"] = heatmaps
    return evidence


def validate_raw_canonical_sidecar(
    sidecar: Mapping[str, Any],
    candidate: Mapping[str, Any],
    output: Path,
    source_sha: str,
) -> tuple[str, list[str], list[str], int, str]:
    candidate_id = str(candidate["id"])
    if sidecar.get("schemaVersion") != "1.0":
        raise MaterializationError(f"canonical raw sidecar version differs: {candidate_id}")
    if sidecar.get("candidateID") != candidate_id:
        raise MaterializationError(f"canonical raw sidecar ID differs: {candidate_id}")
    if sidecar.get("wrapperID") != candidate.get("requiredCanonicalWrapperID"):
        raise MaterializationError(f"canonical wrapper differs: {candidate_id}")
    if sidecar.get("sourceSHA") != source_sha:
        raise MaterializationError(f"canonical raw sidecar source SHA differs: {candidate_id}")
    if sidecar.get("renderMode") != candidate.get("renderMode"):
        raise MaterializationError(f"canonical render mode differs: {candidate_id}")
    dimensions = candidate.get("requiredOutputDimensions")
    if [sidecar.get("width"), sidecar.get("height")] != dimensions:
        raise MaterializationError(f"canonical raw sidecar dimensions differ: {candidate_id}")
    digest = sha256_file(output)
    if sidecar.get("sha256") != digest:
        raise MaterializationError(f"canonical raw sidecar output digest differs: {candidate_id}")
    if sidecar.get("byteCount") != output.stat().st_size:
        raise MaterializationError(f"canonical raw sidecar byte count differs: {candidate_id}")
    if list(image_dimensions(output, "canonical output")) != dimensions:
        raise MaterializationError(f"canonical output dimensions differ: {candidate_id}")
    expected_seeds = candidate.get("seedIDs")
    if not isinstance(expected_seeds, list) or not expected_seeds:
        raise MaterializationError(f"canonical authority seeds are invalid: {candidate_id}")
    if candidate.get("renderMode") == "resolved-resource-export":
        require_exact_keys(sidecar, RAW_RESOURCE_KEYS, f"canonical resource sidecar {candidate_id}")
        if sidecar.get("seedID") not in expected_seeds:
            raise MaterializationError(f"canonical resource seed differs: {candidate_id}")
        revisions = sidecar.get("visualPlanRevisions")
        if (
            sidecar.get("determinism") is not True
            or not isinstance(revisions, list)
            or len(revisions) != 2
            or any(isinstance(value, bool) or not isinstance(value, int) or value <= 0 for value in revisions)
        ):
            raise MaterializationError(f"canonical resource determinism is invalid: {candidate_id}")
        resource_id = sidecar.get("resourceID")
        if not isinstance(resource_id, str) or not resource_id:
            raise MaterializationError(f"canonical resource ID is missing: {candidate_id}")
        return str(sidecar["seedID"]), [resource_id], [digest, digest], revisions[0], "available"

    require_exact_keys(sidecar, RAW_CANONICAL_KEYS, f"canonical render sidecar {candidate_id}")
    if sidecar.get("recipe") != candidate.get("recipeClass"):
        raise MaterializationError(f"canonical recipe differs: {candidate_id}")
    seeds = sidecar.get("seedIDs")
    if seeds != expected_seeds:
        raise MaterializationError(f"canonical seed set differs: {candidate_id}")
    deterministic = sidecar.get("deterministicSHA256")
    if deterministic != digest:
        raise MaterializationError(f"canonical second render digest differs: {candidate_id}")
    resources = sidecar.get("resourceIDs")
    if (
        not isinstance(resources, list)
        or not resources
        or resources != sorted(set(resources))
        or any(not isinstance(value, str) or not value for value in resources)
    ):
        raise MaterializationError(f"canonical runtime resource IDs are invalid: {candidate_id}")
    revision = sidecar.get("visualPlanRevision")
    state = sidecar.get("runtimeState")
    if isinstance(revision, bool) or not isinstance(revision, int) or revision <= 0:
        raise MaterializationError(f"canonical visual-plan revision is invalid: {candidate_id}")
    if not isinstance(state, str) or not state:
        raise MaterializationError(f"canonical runtime state is invalid: {candidate_id}")
    return str(seeds[0]), list(resources), [digest, deterministic], revision, state


def materialize_canonical(
    bundle: AuthorityBundle,
    raw_root: Path,
    comparison_root: Path,
    evidence_root: Path,
    source_sha: str,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]], dict[Path, dict[str, Any]]]:
    raw_sidecars = index_json_documents(
        raw_root.resolve(),
        lambda item: "wrapperID" in item and "renderMode" in item and "candidateID" in item,
        "canonical raw sidecar",
    )
    reports = index_json_documents(
        comparison_root.resolve(),
        lambda item: "authoritySHA256" in item and "candidateID" in item,
        "canonical comparison report",
    )
    candidates = bundle.canonical["candidates"]
    expected_ids = [candidate["id"] for candidate in candidates]
    if set(raw_sidecars) != set(expected_ids):
        raise MaterializationError(
            f"canonical raw sidecar set differs; missing={len(set(expected_ids) - set(raw_sidecars))}, "
            f"extra={len(set(raw_sidecars) - set(expected_ids))}"
        )
    if set(reports) != set(expected_ids):
        raise MaterializationError(
            f"canonical comparison report set differs; missing={len(set(expected_ids) - set(reports))}, "
            f"extra={len(set(reports) - set(expected_ids))}"
        )

    results: list[dict[str, Any]] = []
    by_id: dict[str, dict[str, Any]] = {}
    generated: dict[Path, dict[str, Any]] = {}
    for candidate in candidates:
        candidate_id = candidate["id"]
        raw_sidecar_path, raw_sidecar = raw_sidecars[candidate_id]
        output = resolve_canonical_output(raw_root, raw_sidecar_path, raw_sidecar, candidate)
        seed_id, resources, render_hashes, revision, runtime_state = (
            validate_raw_canonical_sidecar(raw_sidecar, candidate, output, source_sha)
        )
        report_path, report = reports[candidate_id]
        comparison = validate_comparison_report(
            report_path, report, candidate, output, bundle
        )
        normalized_sidecar_path = (
            evidence_root / "canonical/materialized-sidecars"
            / f"{safe_stem(candidate_id)}.sidecar.json"
        )
        normalized_sidecar = {
            "schemaVersion": SCHEMA_VERSION,
            "candidateID": candidate_id,
            "sourceSHA": source_sha,
            "outputSHA256": render_hashes[0],
            "outputDimensions": candidate["requiredOutputDimensions"],
            "seedID": seed_id,
            "seedIDs": candidate["seedIDs"],
            "wrapperID": candidate["requiredCanonicalWrapperID"],
            "renderMode": candidate["renderMode"],
            "recipeClass": candidate["recipeClass"],
            "resourceIDs": resources,
            "visualPlanRevision": revision,
            "runtimeState": runtime_state,
            "usedProductionTypes": True,
            "usedRuntimeResolvedResources": True,
            "referenceAssetReadAtRenderTime": False,
            "contractDerivation": {
                "producer": "ThemeCanonicalOutputRecorder",
                "rawSidecarPath": displayed_path(raw_sidecar_path, evidence_root),
                "rawSidecarSHA256": sha256_file(raw_sidecar_path),
                "basis": [
                    "authority-wrapper-binding",
                    "strict-production-render-sidecar",
                    "runtime-resource-observation",
                    "render-sidecar-schema-excludes-reference-inputs",
                ],
            },
        }
        determinism_path = (
            evidence_root / "canonical/determinism"
            / f"{safe_stem(candidate_id)}.determinism.json"
        )
        determinism = {
            "schemaVersion": SCHEMA_VERSION,
            "candidateID": candidate_id,
            "sourceSHA": source_sha,
            "outputASHA256": render_hashes[0],
            "outputBSHA256": render_hashes[1],
            "rawSidecarPath": displayed_path(raw_sidecar_path, evidence_root),
            "rawSidecarSHA256": sha256_file(raw_sidecar_path),
            "method": "two-independent-production-renders",
            "result": "PASS",
        }
        generated[normalized_sidecar_path] = normalized_sidecar
        generated[determinism_path] = determinism
        result = {
            "candidateID": candidate_id,
            "sourceSHA": source_sha,
            "candidatePath": displayed_path(output, evidence_root),
            "candidateSHA256": render_hashes[0],
            "reportPath": displayed_path(report_path, evidence_root),
            "reportSHA256": comparison["reportSHA256"],
            "sidecarPath": displayed_path(normalized_sidecar_path, evidence_root),
            "sidecarSHA256": rendered_json_sha256(normalized_sidecar),
            "determinismPath": displayed_path(determinism_path, evidence_root),
            "determinismSHA256": rendered_json_sha256(determinism),
            "checks": comparison["checks"],
            "metrics": comparison["metrics"],
            "result": "PASS",
        }
        if "heatmaps" in comparison:
            result["heatmaps"] = {
                name: {
                    "path": displayed_path(Path(record["path"]), evidence_root),
                    "sha256": record["sha256"],
                }
                for name, record in comparison["heatmaps"].items()
            }
        results.append(result)
        by_id[candidate_id] = result
    if len(results) != EXPECTED_COUNTS["canonicalCandidates"]:
        raise MaterializationError("canonical result cardinality differs")
    return results, by_id, generated


def require_extracted_attachment(
    extraction: ExtractionBinding,
    capture_root: Path,
    name: str,
    label: str,
) -> tuple[Path, dict[str, Any]]:
    metadata = extraction.attachments.get(name)
    if metadata is None:
        raise MaterializationError(f"{label} is absent from the extraction inventory: {name}")
    path = safe_file(capture_root, name, label)
    if metadata.get("sha256") != sha256_file(path) or metadata.get("bytes") != path.stat().st_size:
        raise MaterializationError(f"{label} extraction binding differs: {name}")
    return path, metadata


def validate_capture_record(
    entry: Mapping[str, Any],
    capture_root: Path,
    extraction: ExtractionBinding,
) -> tuple[Path, Path, dict[str, Any], dict[str, dict[str, float]]]:
    stem = f"{str(entry['theme']).lower()}--{entry['surface']}--{entry['destination']}"
    capture_name = stem + ".png"
    record_name = stem + ".capture.json"
    capture, _ = require_extracted_attachment(
        extraction, capture_root, capture_name, f"responsive capture {entry['id']}"
    )
    record_path, _ = require_extracted_attachment(
        extraction, capture_root, record_name, f"responsive capture record {entry['id']}"
    )
    record = load_json(record_path, f"responsive capture record {entry['id']}")
    expected_identity = {
        "schemaVersion": "1.0",
        "themeName": entry["theme"],
        "themeID": entry["themeID"],
        "codexID": entry["codexID"],
        "surface": entry["surface"],
        "destination": DESTINATION_DISPLAY_NAMES[entry["destination"]],
    }
    for key, expected in expected_identity.items():
        if record.get(key) != expected:
            raise MaterializationError(f"responsive capture {key} differs: {entry['id']}")
    digest = sha256_file(capture)
    if record.get("pngSHA256") != digest or record.get("byteCount") != capture.stat().st_size:
        raise MaterializationError(f"responsive capture hash or byte count differs: {entry['id']}")
    dimensions = image_dimensions(capture, f"responsive capture {entry['id']}")
    if [record.get("pixelWidth"), record.get("pixelHeight")] != list(dimensions):
        raise MaterializationError(f"responsive capture dimensions differ: {entry['id']}")
    revision = record.get("visualPlanRevision")
    if isinstance(revision, bool) or not isinstance(revision, int) or revision <= 0:
        raise MaterializationError(f"responsive visual-plan revision is invalid: {entry['id']}")
    diagnostics = record.get("runtimeDiagnostics")
    if (
        not isinstance(diagnostics, dict)
        or diagnostics.get("activeThemeID") != entry["themeID"]
        or diagnostics.get("activeCodexID") != entry["codexID"]
        or diagnostics.get("visualPlanRevision") != revision
    ):
        raise MaterializationError(f"responsive runtime diagnostics differ: {entry['id']}")
    frames = frame_index(record)
    return capture, record_path, record, frames


def validate_renderer_outputs(
    entry: Mapping[str, Any],
    record: Mapping[str, Any],
    capture_root: Path,
    extraction: ExtractionBinding,
) -> dict[str, dict[str, Any]]:
    raw = record.get("rendererOutputs")
    if not isinstance(raw, list):
        raise MaterializationError(f"responsive rendererOutputs is not an array: {entry['id']}")
    output: dict[str, dict[str, Any]] = {}
    for item in raw:
        if not isinstance(item, dict):
            raise MaterializationError(f"responsive renderer output is malformed: {entry['id']}")
        output_id = item.get("outputID")
        if not isinstance(output_id, str) or not output_id or output_id in output:
            raise MaterializationError(f"responsive renderer output IDs are invalid: {entry['id']}")
        name = item.get("attachmentName")
        if not isinstance(name, str):
            raise MaterializationError(f"responsive renderer attachment is invalid: {entry['id']}")
        path, _ = require_extracted_attachment(
            extraction, capture_root, name, f"responsive renderer output {output_id}"
        )
        if item.get("sha256") != sha256_file(path) or item.get("byteCount") != path.stat().st_size:
            raise MaterializationError(f"responsive renderer output binding differs: {output_id}")
        if [item.get("pixelWidth"), item.get("pixelHeight")] != list(
            image_dimensions(path, f"responsive renderer output {output_id}")
        ):
            raise MaterializationError(f"responsive renderer output dimensions differ: {output_id}")
        output[output_id] = {
            "path": str(path.resolve()),
            "sha256": item["sha256"],
            "pixelWidth": item["pixelWidth"],
            "pixelHeight": item["pixelHeight"],
            "usesPrimaryCapture": item.get("usesPrimaryCapture"),
        }
    return output


def observation_index(
    record: Mapping[str, Any],
    key: str,
    identifier_key: str,
    label: str,
) -> dict[str, dict[str, Any]]:
    values = record.get(key)
    if not isinstance(values, list):
        raise MaterializationError(f"{label} is not an array")
    output: dict[str, dict[str, Any]] = {}
    for item in values:
        if not isinstance(item, dict):
            raise MaterializationError(f"{label} contains a non-object")
        identifier = item.get(identifier_key)
        if not isinstance(identifier, str) or not identifier or identifier in output:
            raise MaterializationError(f"{label} IDs are invalid or duplicated")
        output[identifier] = item
    return output


def recompute_frame_stability(
    entry: Mapping[str, Any],
    record: Mapping[str, Any],
    frames: Mapping[str, Mapping[str, float]],
    capture: Path,
    capture_root: Path,
    extraction: ExtractionBinding,
    authority: Mapping[str, Any],
) -> tuple[float, dict[str, Any]]:
    stability = record.get("reduceMotionStability")
    if not isinstance(stability, dict):
        raise MaterializationError(f"Reduce Motion stability is missing: {entry['id']}")
    name = stability.get("captureBAttachmentName")
    if not isinstance(name, str):
        raise MaterializationError(f"Reduce Motion capture B name is invalid: {entry['id']}")
    capture_b, _ = require_extracted_attachment(
        extraction, capture_root, name, f"Reduce Motion capture B {entry['id']}"
    )
    if stability.get("captureASHA256") != sha256_file(capture):
        raise MaterializationError(f"Reduce Motion capture A digest differs: {entry['id']}")
    if stability.get("captureBSHA256") != sha256_file(capture_b):
        raise MaterializationError(f"Reduce Motion capture B digest differs: {entry['id']}")
    timestamp_a = parse_iso_timestamp(
        stability.get("captureATimestamp"), "Reduce Motion capture A timestamp"
    )
    timestamp_b = parse_iso_timestamp(
        stability.get("captureBTimestamp"), "Reduce Motion capture B timestamp"
    )
    separation = (timestamp_b - timestamp_a).total_seconds()
    declared_separation = stability.get("separationSeconds")
    profile = authority.get("thresholdProfiles", {}).get("runtime-reduce-motion-v1")
    if (
        isinstance(declared_separation, bool)
        or not isinstance(declared_separation, (int, float))
        or not math.isclose(separation, float(declared_separation), abs_tol=0.01, rel_tol=0.0)
        or not isinstance(profile, dict)
        or separation < float(profile.get("minimumCaptureSeparationSeconds", math.inf))
    ):
        raise MaterializationError(f"Reduce Motion capture separation differs: {entry['id']}")
    first = load_rgba(capture, "Reduce Motion capture A")
    second = load_rgba(capture_b, "Reduce Motion capture B")
    if first.size != second.size:
        raise MaterializationError(f"Reduce Motion capture dimensions differ: {entry['id']}")
    preview = record.get("runtimeDiagnostics", {}).get("preview", {})
    element_id = preview.get("elementID") if isinstance(preview, dict) else None
    frame = frames.get(element_id) if isinstance(element_id, str) else None
    if frame is None:
        raise MaterializationError(f"Reduce Motion preview frame is missing: {entry['id']}")
    box = integral_crop(frame, first.size)
    first_pixels, second_pixels, normalization, metric_mask = normalize_pair(
        first.crop(box),
        second.crop(box),
        "focal-complete-image-aspect-fit-v1",
    )
    metrics, _, _ = comparison_metrics(first_pixels, second_pixels, metric_mask)
    observed = metrics["luminanceSSIM"]
    declared = stability.get("luminanceSSIM")
    if (
        isinstance(declared, bool)
        or not isinstance(declared, (int, float))
        or not math.isclose(observed, float(declared), abs_tol=1e-6, rel_tol=0.0)
    ):
        raise MaterializationError(f"Reduce Motion SSIM differs on recomputation: {entry['id']}")
    return observed, {
        "captureAPath": str(capture.resolve()),
        "captureASHA256": sha256_file(capture),
        "captureBPath": str(capture_b.resolve()),
        "captureBSHA256": sha256_file(capture_b),
        "separationSeconds": separation,
        "elementID": element_id,
        "pixelCrop": [box[0], box[1], box[2] - box[0], box[3] - box[1]],
        "normalization": normalization,
    }


def evaluate_entry_probes(
    entry: Mapping[str, Any],
    record: Mapping[str, Any],
    frames: Mapping[str, Mapping[str, float]],
    capture: Path,
    capture_root: Path,
    extraction: ExtractionBinding,
    bundle: AuthorityBundle,
    source_sha: str,
    xcui_sidecar,
    evidence_root: Path,
) -> list[dict[str, Any]]:
    expected_ids = list(entry.get("runtimeProbeIDs", []))
    if any(probe_id not in bundle.probes for probe_id in expected_ids):
        raise MaterializationError(f"entry uses an unknown runtime probe: {entry['id']}")
    hosted_expected = [
        probe_id for probe_id in expected_ids
        if not str(bundle.probes[probe_id].get("source", "")).startswith("xcui-")
    ]
    observations = observation_index(
        record,
        "runtimeProbeObservations",
        "probeID",
        f"runtime probe observations {entry['id']}",
    )
    if set(observations) != set(hosted_expected):
        raise MaterializationError(
            f"hosted runtime probe observation set differs: {entry['id']}"
        )
    results: list[dict[str, Any]] = []
    for probe_id in expected_ids:
        catalog = bundle.probes[probe_id]
        source = catalog.get("source")
        details: dict[str, Any]
        if isinstance(source, str) and source.startswith("xcui-"):
            if xcui_sidecar is None:
                raise MaterializationError(f"XCUI probe sidecar is missing: {entry['id']}")
            evidence = xcui_sidecar.probe_evidence.get(probe_id)
            if evidence is None:
                raise MaterializationError(f"XCUI probe evidence is missing: {entry['id']} {probe_id}")
            observed = evidence.get("observed")
            attachment = resolve_attachment(
                capture_root, evidence.get("attachmentName"), f"XCUI probe {probe_id}"
            )
            details = {
                "rawSidecarPath": displayed_path(xcui_sidecar.path, evidence_root),
                "rawSidecarSHA256": xcui_sidecar.sha256,
                "attachmentPath": displayed_path(attachment, evidence_root),
                "attachmentSHA256": evidence.get("attachmentSHA256"),
                "queryPredicate": evidence.get("queryPredicate"),
                "matchCount": evidence.get("matchCount"),
                "elementFrame": evidence.get("elementFrame"),
                "containerFrame": evidence.get("containerFrame"),
            }
        else:
            raw = observations[probe_id]
            if raw.get("source") != source:
                raise MaterializationError(f"runtime probe source differs: {entry['id']} {probe_id}")
            if probe_id.startswith("probe.motion.frame-stability."):
                observed, details = recompute_frame_stability(
                    entry, record, frames, capture, capture_root, extraction, bundle.authority
                )
            else:
                observed = recomputed_probe_observed(probe_id, record, frames)
                if observed is _MISSING:
                    raise MaterializationError(
                        f"runtime probe cannot be recomputed: {entry['id']} {probe_id}"
                    )
                details = {"rawObservation": raw.get("observed")}
            if type(raw.get("observed")) is not type(observed) or raw.get("observed") != observed:
                raise MaterializationError(
                    f"runtime probe differs from recomputed value: {entry['id']} {probe_id}"
                )
        if not evaluate_operator(str(catalog.get("operator")), observed, catalog.get("expected")):
            raise MaterializationError(f"runtime probe did not pass: {entry['id']} {probe_id}")
        results.append({
            "entryID": entry["id"],
            "probeID": probe_id,
            "sourceSHA": source_sha,
            "source": source,
            "operator": catalog.get("operator"),
            "expectedValue": catalog.get("expected"),
            "observedValue": observed,
            "observationDetails": details,
            "result": "PASS",
        })
    return results


def materialize_responsive(
    bundle: AuthorityBundle,
    capture_root: Path,
    run_report_path: Path,
    evidence_root: Path,
    source_sha: str,
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    dict[str, dict[str, Any]],
    dict[tuple[str, str], dict[str, Any]],
    dict[Path, dict[str, Any]],
]:
    expected_names, expected_counts = expected_responsive_inventory(bundle)
    extraction = validate_extraction_binding(
        run_report_path,
        capture_root,
        source_sha,
        expected_names,
        expected_counts,
        bundle,
    )
    entries = bundle.authority["entries"]
    responsive_results: list[dict[str, Any]] = []
    probe_results: list[dict[str, Any]] = []
    entry_contexts: dict[str, dict[str, Any]] = {}
    probe_index: dict[tuple[str, str], dict[str, Any]] = {}
    generated: dict[Path, dict[str, Any]] = {}
    validated_xcui_names: set[str] = set()

    for entry in entries:
        entry_id = entry["id"]
        seed_id = entry.get("seedID")
        seed = bundle.seeds.get(seed_id) if isinstance(seed_id, str) else None
        if seed is None:
            raise MaterializationError(f"responsive entry seed is undeclared: {entry_id}")
        environment = seed.get("launchEnvironment")
        if (
            not isinstance(environment, dict)
            or environment.get("RUNESCRIBE_QUALIFICATION_THEME_ID") != entry["themeID"]
            or environment.get("RUNESCRIBE_QUALIFICATION_CODEX_ID") != entry["codexID"]
            or environment.get("RUNESCRIBE_QUALIFICATION_SURFACE") != entry["surface"]
        ):
            raise MaterializationError(f"responsive seed identity differs: {entry_id}")

        capture, record_path, record, frames = validate_capture_record(
            entry, capture_root, extraction
        )
        renderer_outputs = validate_renderer_outputs(
            entry, record, capture_root, extraction
        )
        expected_candidate_ids = capture_candidate_ids_for_entry(
            entry,
            bundle.probes,
            bundle.responsive_candidates,
            CONTRACT_V43,
        )
        expected_xcui_probes = xcui_probe_ids_for_entry(entry, bundle.probes)
        xcui_sidecar = None
        if expected_candidate_ids or expected_xcui_probes:
            name = sidecar_name(entry)
            sidecar_path, _ = require_extracted_attachment(
                extraction, capture_root, name, f"responsive XCUI sidecar {entry_id}"
            )
            try:
                xcui_sidecar = validate_sidecar(
                    sidecar_path,
                    entry,
                    bundle.probes,
                    bundle.seeds,
                    bundle.responsive_candidates,
                    capture_root,
                    extraction.attachments,
                    contract_version=CONTRACT_V43,
                )
            except ValueError as error:
                raise MaterializationError(
                    f"responsive XCUI sidecar is invalid: {entry_id}: {error}"
                ) from error
            validated_xcui_names.add(name)

        observations = record.get("structuralAssertionObservations")
        expected_assertions = list(entry.get("entryStructuralAssertionIDs", []))
        if not isinstance(observations, dict) or set(observations) != set(expected_assertions):
            raise MaterializationError(
                f"responsive structural observation set differs: {entry_id}"
            )
        structural_results: list[dict[str, Any]] = []
        structural_by_id: dict[str, dict[str, Any]] = {}
        for assertion_id in expected_assertions:
            result = evaluate_structural_assertion(
                assertion_id,
                [],
                frames,
                record,
                bundle.authority["structuralAssertionCatalog"],
            )
            if result.get("result") != "PASS":
                raise MaterializationError(
                    f"responsive structural assertion did not pass: {entry_id} {assertion_id}"
                )
            normalized = {
                "id": assertion_id,
                "source": result.get("source"),
                "operator": result.get("operator"),
                "expected": result.get("expected"),
                "observedValue": result.get("observed"),
                "details": result.get("details"),
                "result": "PASS",
            }
            structural_results.append(normalized)
            structural_by_id[assertion_id] = normalized

        entry_probes = evaluate_entry_probes(
            entry,
            record,
            frames,
            capture,
            capture_root,
            extraction,
            bundle,
            source_sha,
            xcui_sidecar,
            evidence_root,
        )
        for probe in entry_probes:
            key = (entry_id, probe["probeID"])
            if key in probe_index:
                raise MaterializationError(f"duplicate runtime probe instance: {key}")
            probe_index[key] = probe
            probe_results.append(probe)

        mapping_candidate_evidence: dict[str, dict[str, Any]] = {}
        if xcui_sidecar is not None:
            for candidate_id, evidence in xcui_sidecar.candidate_captures.items():
                attachment = resolve_attachment(
                    capture_root,
                    evidence.get("attachmentName"),
                    f"responsive candidate {candidate_id}",
                )
                mapping_candidate_evidence[candidate_id] = {
                    "kind": "xcui-element-screenshot",
                    "path": displayed_path(attachment, evidence_root),
                    "sha256": evidence.get("sha256"),
                    "elementFrame": evidence.get("elementFrame"),
                    "windowFrame": evidence.get("windowFrame"),
                    "rawSidecarPath": displayed_path(xcui_sidecar.path, evidence_root),
                    "rawSidecarSHA256": xcui_sidecar.sha256,
                }
        for output_id, evidence in renderer_outputs.items():
            mapping_candidate_evidence[output_id] = {
                "kind": "deterministic-png-export",
                "path": displayed_path(Path(evidence["path"]), evidence_root),
                "sha256": evidence["sha256"],
                "pixelWidth": evidence["pixelWidth"],
                "pixelHeight": evidence["pixelHeight"],
            }

        for mapping in entry.get("referenceMappings", []):
            if mapping.get("scoreDisposition") != "structural-assertion":
                continue
            candidate_id = mapping.get("candidateElementID") or mapping.get(
                "candidateRendererOutputID"
            )
            if not isinstance(candidate_id, str) or candidate_id not in mapping_candidate_evidence:
                raise MaterializationError(
                    f"responsive mapping has no exact candidate evidence: {mapping.get('mappingID')}"
                )

        resources = record.get("renderedResourceIDs")
        if (
            not isinstance(resources, list)
            or not resources
            or resources != sorted(set(resources))
            or any(not isinstance(value, str) or not value for value in resources)
        ):
            raise MaterializationError(f"responsive resource IDs are invalid: {entry_id}")
        viewport = frames.get("theme-fidelity.viewport") or {
            "x": 0.0,
            "y": 0.0,
            "width": float(record["pixelWidth"]),
            "height": float(record["pixelHeight"]),
        }
        normalized_sidecar_path = (
            evidence_root / "responsive/entry-sidecars"
            / f"{safe_stem(entry_id)}.responsive.json"
        )
        normalized_sidecar = {
            "schemaVersion": SCHEMA_VERSION,
            "entryID": entry_id,
            "sourceSHA": source_sha,
            "seedID": seed_id,
            "seedDigest": canonical_json_sha256(seed),
            "theme": entry["theme"],
            "themeID": entry["themeID"],
            "codexID": entry["codexID"],
            "surface": entry["surface"],
            "destination": entry["destination"],
            "effectiveModes": {
                "appearance": environment.get("RUNESCRIBE_QUALIFICATION_APPEARANCE"),
                "messageProfile": environment.get("RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE"),
                "motionMode": record["runtimeDiagnostics"].get("effectiveMotionMode"),
            },
            "selection": {
                "relicID": record.get("relicID"),
                "sealID": record.get("sealID"),
                "frameID": record.get("frameID"),
            },
            "capture": {
                "path": displayed_path(capture, evidence_root),
                "sha256": sha256_file(capture),
                "pixelWidth": record["pixelWidth"],
                "pixelHeight": record["pixelHeight"],
            },
            "viewportBounds": viewport,
            "elementBounds": record.get("elementFrames"),
            "visualPlanRevision": record["visualPlanRevision"],
            "resourceIDs": resources,
            "resourceBindings": record.get("renderedResourceBindings"),
            "structuralAssertions": structural_results,
            "runtimeProbeIDs": [probe["probeID"] for probe in entry_probes],
            "candidateEvidence": mapping_candidate_evidence,
            "rawCaptureRecordPath": displayed_path(record_path, evidence_root),
            "rawCaptureRecordSHA256": sha256_file(record_path),
            "runReportPath": displayed_path(extraction.run_report_path, evidence_root),
            "runReportSHA256": extraction.run_report_sha256,
            "extractionReportPath": displayed_path(extraction.extraction_path, evidence_root),
            "extractionReportSHA256": extraction.extraction_sha256,
            "result": "PASS",
        }
        generated[normalized_sidecar_path] = normalized_sidecar
        responsive_result = {
            "entryID": entry_id,
            "sourceSHA": source_sha,
            "seedID": seed_id,
            "seedDigest": canonical_json_sha256(seed),
            "destination": entry["destination"],
            "capturePath": displayed_path(capture, evidence_root),
            "captureSHA256": sha256_file(capture),
            "captureDimensions": [record["pixelWidth"], record["pixelHeight"]],
            "sidecarPath": displayed_path(normalized_sidecar_path, evidence_root),
            "sidecarSHA256": rendered_json_sha256(normalized_sidecar),
            "structuralAssertions": structural_results,
            "runtimeProbeIDs": [probe["probeID"] for probe in entry_probes],
            "result": "PASS",
        }
        responsive_results.append(responsive_result)
        entry_contexts[entry_id] = {
            "entry": entry,
            "responsive": responsive_result,
            "structural": structural_by_id,
            "candidates": mapping_candidate_evidence,
        }

    actual_xcui = {
        name for name in extraction.attachments if name.endswith(".xcui.json")
    }
    if (
        validated_xcui_names != actual_xcui
        or len(actual_xcui) != expected_counts["xcuiSidecarCount"]
    ):
        raise MaterializationError(
            "responsive XCUI sidecar set differs from the v4.3 authority-required sidecars"
        )
    if len(responsive_results) != EXPECTED_COUNTS["responsiveEntries"]:
        raise MaterializationError("responsive result cardinality differs")
    if len(probe_results) != EXPECTED_COUNTS["runtimeProbeInstances"]:
        raise MaterializationError("runtime probe instance cardinality differs")
    return responsive_results, probe_results, entry_contexts, probe_index, generated


def materialize_mappings(
    bundle: AuthorityBundle,
    source_sha: str,
    canonical_by_id: Mapping[str, Mapping[str, Any]],
    entry_contexts: Mapping[str, Mapping[str, Any]],
    probe_index: Mapping[tuple[str, str], Mapping[str, Any]],
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    counts: dict[str, int] = {
        "image-metric": 0,
        "structural-assertion": 0,
        "negative-invariant": 0,
    }
    seen: set[str] = set()
    for entry in bundle.authority["entries"]:
        entry_id = entry["id"]
        context = entry_contexts.get(entry_id)
        if context is None:
            raise MaterializationError(f"mapping entry context is missing: {entry_id}")
        for mapping in entry.get("referenceMappings", []):
            mapping_id = mapping.get("mappingID")
            disposition = mapping.get("scoreDisposition")
            lane = mapping.get("evaluationLane")
            if (
                not isinstance(mapping_id, str)
                or not mapping_id
                or mapping_id in seen
                or disposition not in counts
            ):
                raise MaterializationError("mapping identity or disposition is invalid")
            seen.add(mapping_id)
            counts[disposition] += 1
            result: dict[str, Any] = {
                "mappingID": mapping_id,
                "sourceSHA": source_sha,
                "lane": lane,
                "scoreDisposition": disposition,
                "referenceSHA256": mapping.get("referenceSHA256"),
                "result": "PASS",
            }
            if disposition == "image-metric":
                candidate_id = mapping.get("candidateCanonicalOutputID")
                canonical = canonical_by_id.get(candidate_id) if isinstance(candidate_id, str) else None
                if canonical is None or canonical.get("result") != "PASS":
                    raise MaterializationError(f"image mapping candidate did not pass: {mapping_id}")
                result.update({
                    "candidateID": candidate_id,
                    "candidateSHA256": canonical["candidateSHA256"],
                    "comparisonReportPath": canonical["reportPath"],
                    "comparisonReportSHA256": canonical["reportSHA256"],
                    "checks": canonical["checks"],
                    "metrics": canonical["metrics"],
                })
            elif disposition == "structural-assertion":
                assertion_ids = mapping.get("structuralAssertionIDs")
                if not isinstance(assertion_ids, list) or not assertion_ids:
                    raise MaterializationError(f"structural mapping assertions are missing: {mapping_id}")
                assertions = context["structural"]
                assertion_results = []
                for assertion_id in assertion_ids:
                    assertion = assertions.get(assertion_id)
                    if assertion is None or assertion.get("result") != "PASS":
                        raise MaterializationError(
                            f"structural mapping assertion did not pass: {mapping_id} {assertion_id}"
                        )
                    assertion_results.append(assertion)
                candidate_id = mapping.get("candidateElementID") or mapping.get(
                    "candidateRendererOutputID"
                )
                candidate_evidence = context["candidates"].get(candidate_id)
                if not isinstance(candidate_id, str) or candidate_evidence is None:
                    raise MaterializationError(f"structural mapping candidate is missing: {mapping_id}")
                result.update({
                    "entryID": entry_id,
                    "candidateID": candidate_id,
                    "candidateEvidence": candidate_evidence,
                    "structuralAssertions": assertion_results,
                })
            else:
                probe_id = mapping.get("candidateProbeID")
                probe = probe_index.get((entry_id, probe_id)) if isinstance(probe_id, str) else None
                if probe is None or probe.get("result") != "PASS":
                    raise MaterializationError(f"negative mapping probe did not pass: {mapping_id}")
                result.update({
                    "entryID": entry_id,
                    "probeID": probe_id,
                    "observedValue": probe["observedValue"],
                })
            results.append(result)
    expected = {
        "image-metric": EXPECTED_COUNTS["canonicalImageMappings"],
        "structural-assertion": EXPECTED_COUNTS["responsiveStructuralMappings"],
        "negative-invariant": EXPECTED_COUNTS["negativeInvariantMappings"],
    }
    if counts != expected or len(results) != EXPECTED_COUNTS["mappingResults"]:
        raise MaterializationError(f"mapping cardinalities differ: {counts}")
    return results


def acceptance_aggregate(key: str, values: list[dict[str, Any]], source_sha: str) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "templateOnly": False,
        "acceptanceEvidence": True,
        "sourceSHA": source_sha,
        key: values,
    }


def materialize(
    repository_root: Path,
    source_sha: str,
    canonical_root: Path,
    comparison_root: Path,
    responsive_root: Path,
    responsive_run_report: Path,
    evidence_root: Path,
    check_only: bool = False,
) -> dict[str, Any]:
    require_sha(source_sha, SHA40, "application source SHA")
    repository_root = repository_root.resolve()
    evidence_root = evidence_root.resolve()
    bundle = AuthorityBundle.load(repository_root)
    canonical, canonical_by_id, canonical_generated = materialize_canonical(
        bundle,
        canonical_root.resolve(),
        comparison_root.resolve(),
        evidence_root,
        source_sha,
    )
    responsive, probes, entry_contexts, probe_index, responsive_generated = (
        materialize_responsive(
            bundle,
            responsive_root.resolve(),
            responsive_run_report.resolve(),
            evidence_root,
            source_sha,
        )
    )
    mappings = materialize_mappings(
        bundle, source_sha, canonical_by_id, entry_contexts, probe_index
    )
    documents: dict[Path, dict[str, Any]] = {
        **canonical_generated,
        **responsive_generated,
        evidence_root / "canonical-results.json": acceptance_aggregate(
            "results", canonical, source_sha
        ),
        evidence_root / "responsive-results.json": acceptance_aggregate(
            "entries", responsive, source_sha
        ),
        evidence_root / "runtime-probe-results.json": acceptance_aggregate(
            "results", probes, source_sha
        ),
        evidence_root / "mapping-results.json": acceptance_aggregate(
            "results", mappings, source_sha
        ),
    }
    collisions = sorted(str(path) for path in documents if path.exists())
    if collisions:
        raise MaterializationError(
            "materialization targets already exist; refusing to overwrite: "
            + ", ".join(collisions[:8])
        )
    if not check_only:
        created: list[Path] = []
        try:
            for path in sorted(documents):
                write_json(path, documents[path])
                created.append(path)
                if sha256_file(path) != rendered_json_sha256(documents[path]):
                    raise MaterializationError(f"materialized JSON digest differs: {path}")
        except Exception:
            for path in reversed(created):
                try:
                    path.unlink()
                except OSError:
                    pass
            raise
    return {
        "schemaVersion": SCHEMA_VERSION,
        "sourceSHA": source_sha,
        "checkOnly": check_only,
        "result": "PASS",
        "counts": {
            "canonicalCandidates": len(canonical),
            "responsiveEntries": len(responsive),
            "runtimeProbeInstances": len(probes),
            "canonicalImageMappings": sum(
                item["scoreDisposition"] == "image-metric" for item in mappings
            ),
            "responsiveStructuralMappings": sum(
                item["scoreDisposition"] == "structural-assertion" for item in mappings
            ),
            "negativeInvariantMappings": sum(
                item["scoreDisposition"] == "negative-invariant" for item in mappings
            ),
            "mappingResults": len(mappings),
        },
        "outputs": [
            str((evidence_root / name).resolve()) for name in MATERIALIZED_TOP_LEVEL
        ],
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--canonical-root", required=True, type=Path)
    parser.add_argument("--comparison-root", required=True, type=Path)
    parser.add_argument("--responsive-root", required=True, type=Path)
    parser.add_argument("--responsive-run-report", required=True, type=Path)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--check-only", action="store_true")
    arguments = parser.parse_args(argv)
    try:
        report = materialize(
            arguments.root,
            arguments.source_sha,
            arguments.canonical_root,
            arguments.comparison_root,
            arguments.responsive_root,
            arguments.responsive_run_report,
            arguments.evidence_root,
            arguments.check_only,
        )
    except (MaterializationError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
