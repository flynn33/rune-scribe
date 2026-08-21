#!/usr/bin/env python3
"""Create a byte-repeatable ZIP archive from a verified production package."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
import platform
import sys
import tempfile
import zipfile
import zlib
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple


EXPECTED_PYTHON = (3, 9, 6)
EXPECTED_ZLIB = "1.2.12"


def reject_duplicate_keys(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_generated_at(value: str) -> dt.datetime:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected an ISO-8601 UTC timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() != dt.timedelta(0):
        raise argparse.ArgumentTypeError("generated-at must be an explicit UTC timestamp")
    parsed = parsed.astimezone(dt.timezone.utc).replace(microsecond=0)
    if parsed.year < 1980 or parsed.year > 2107:
        raise argparse.ArgumentTypeError("generated-at year must fit the ZIP timestamp range 1980 through 2107")
    if parsed.second % 2:
        raise argparse.ArgumentTypeError("generated-at seconds must be even because ZIP timestamps have two-second precision")
    return parsed


def verify_runtime() -> None:
    if sys.version_info[:3] != EXPECTED_PYTHON or zlib.ZLIB_VERSION != EXPECTED_ZLIB or zlib.ZLIB_RUNTIME_VERSION != EXPECTED_ZLIB:
        raise SystemExit(
            "Unsupported deterministic archive runtime: "
            f"Python {platform.python_version()}, zlib compile/runtime {zlib.ZLIB_VERSION}/{zlib.ZLIB_RUNTIME_VERSION}; "
            f"expected Python {'.'.join(map(str, EXPECTED_PYTHON))}, zlib {EXPECTED_ZLIB}"
        )


def verified_package_files(root: Path) -> Tuple[Dict[str, Any], List[Path]]:
    manifest_path = root / "PACKAGE-MANIFEST.json"
    if not manifest_path.is_file():
        raise SystemExit("Package root has no PACKAGE-MANIFEST.json")
    manifest = load_json(manifest_path)
    if manifest.get("rootDirectory") != root.name:
        raise SystemExit("Package manifest rootDirectory does not match the selected package root")
    if manifest.get("packageID") != "runescribe.elven-series.corrected-production-package":
        raise SystemExit("Refusing package with an unexpected package identity")
    declared = manifest.get("files")
    if not isinstance(declared, list):
        raise SystemExit("Package manifest files must be an array")
    declared_paths = [entry.get("path") for entry in declared if isinstance(entry, dict)]
    if len(declared_paths) != len(declared) or declared_paths != sorted(set(declared_paths)):
        raise SystemExit("Package manifest file paths must be complete, unique, and sorted")
    actual = sorted(
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.name != "PACKAGE-MANIFEST.json"
    )
    if declared_paths != actual or manifest.get("fileCountExcludingManifest") != len(actual):
        raise SystemExit("Package manifest coverage differs from the package tree")
    for path in root.rglob("*"):
        if path.is_symlink():
            raise SystemExit(f"Symbolic links are not permitted in deterministic packages: {path}")
    for entry in declared:
        relative = str(entry["path"])
        if relative.startswith("/") or ".." in Path(relative).parts or "\\" in relative:
            raise SystemExit(f"Unsafe package manifest path: {relative}")
        path = root / relative
        if path.stat().st_size != entry.get("bytes") or sha256_file(path) != entry.get("sha256"):
            raise SystemExit(f"Package fact differs from PACKAGE-MANIFEST.json: {relative}")
    files = [manifest_path] + [root / relative for relative in actual]
    return manifest, sorted(files, key=lambda path: path.relative_to(root).as_posix())


def archive_bytes(root: Path, files: Sequence[Path], timestamp: dt.datetime, compression_level: int) -> bytes:
    buffer = io.BytesIO()
    date_time = (timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.minute, timestamp.second)
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=compression_level, strict_timestamps=True) as archive:
        archive.comment = b""
        for path in files:
            relative = path.relative_to(root).as_posix()
            info = zipfile.ZipInfo(f"{root.name}/{relative}", date_time=date_time)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.internal_attr = 0
            info.extra = b""
            info.comment = b""
            archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=compression_level)
    return buffer.getvalue()


def atomic_write(path: Path, payload: bytes, replace: bool) -> None:
    if path.exists() and not replace:
        raise SystemExit(f"Output already exists; pass --replace to atomically replace it: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    try:
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def package_inventory(root: Path, files: Sequence[Path]) -> Dict[str, Dict[str, Any]]:
    return {
        path.relative_to(root).as_posix(): {
            "byteLength": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        for path in files
    }


def inventory_digest(inventory: Dict[str, Dict[str, Any]]) -> str:
    payload = json.dumps(inventory, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return sha256_bytes(payload)


def validate_phase_c_matrix(root: Path, timestamp: dt.datetime, pipeline_path: Path) -> Tuple[int, int, Dict[str, Any]]:
    asset_path = root / "Rune-Scribe-Elven-Series-Asset-Manifest-v1.0.json"
    if not asset_path.is_file():
        raise SystemExit(f"Phase C asset manifest is missing: {asset_path}")
    asset = load_json(asset_path)
    generated_at = timestamp.isoformat().replace("+00:00", "Z")
    if asset.get("packageVersion") != "3.1.0" or asset.get("generatedDate") != generated_at:
        raise SystemExit(f"Phase C asset manifest version/timestamp differs: {asset_path}")
    generation = asset.get("generationPipeline")
    expected_pipeline_hash = sha256_file(pipeline_path)
    if not isinstance(generation, dict) or generation.get("path") != "scripts/build-elven-production-assets.py" or generation.get("sha256") != expected_pipeline_hash:
        raise SystemExit(f"Phase C asset manifest pipeline identity differs: {asset_path}")
    if generation.get("targetWasClean") is not True:
        raise SystemExit(f"Phase C comparison requires a target that was empty or absent at build start: {root}")
    resources = asset.get("resourceCatalog")
    if not isinstance(resources, list):
        raise SystemExit(f"Phase C resourceCatalog is missing: {asset_path}")
    outputs = [
        output
        for resource in resources
        if isinstance(resource, dict) and isinstance(resource.get("outputVariants"), list)
        for output in resource["outputVariants"]
        if isinstance(output, dict)
    ]
    if len(resources) != 56 or len(outputs) != 184:
        raise SystemExit(f"Phase C resource/output counts differ from 56/184: {root}")
    matrix = asset.get("phaseCOutputMatrix")
    matrix_file = load_json(root / "Validation/phase-c-output-matrix.json")
    if not isinstance(matrix, dict) or matrix != matrix_file or matrix.get("resourceCount") != 56 or matrix.get("outputCount") != 184 or matrix.get("resources") != resources:
        raise SystemExit(f"Phase C matrix differs from the resource catalog: {root}")
    regeneration = load_json(root / "Validation/deterministic-regeneration.json")
    if regeneration.get("status") != "PENDING_EXTERNAL_VALIDATION":
        raise SystemExit(f"Preliminary comparison packages must contain the pending deterministic-regeneration placeholder: {root}")
    return len(resources), len(outputs), asset


def validate_archive(archive_path: Path, root: Path, files: Sequence[Path], timestamp: dt.datetime) -> str:
    if not archive_path.is_file() or archive_path.name != f"{root.name}.zip":
        raise SystemExit(f"Deterministic archive path/name is invalid: {archive_path}")
    expected_names = [f"{root.name}/{path.relative_to(root).as_posix()}" for path in files]
    expected_time = (timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.minute, timestamp.second)
    try:
        with zipfile.ZipFile(archive_path, "r") as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            if names != expected_names or len(names) != len(set(names)):
                raise SystemExit(f"Archive member coverage/order differs from its package: {archive_path}")
            if archive.comment:
                raise SystemExit(f"Archive comment must be empty: {archive_path}")
            for info, path in zip(infos, files):
                mode = (info.external_attr >> 16) & 0xFFFF
                if (
                    info.is_dir()
                    or info.date_time != expected_time
                    or info.compress_type != zipfile.ZIP_DEFLATED
                    or info.create_system != 3
                    or mode != 0o100644
                    or info.extra
                    or info.comment
                ):
                    raise SystemExit(f"Archive member metadata is not canonical: {archive_path}:{info.filename}")
                if archive.read(info) != path.read_bytes():
                    raise SystemExit(f"Archive member bytes differ from package: {archive_path}:{info.filename}")
            if archive.testzip() is not None:
                raise SystemExit(f"Archive CRC validation failed: {archive_path}")
    except zipfile.BadZipFile as error:
        raise SystemExit(f"Archive is not a valid ZIP: {archive_path}") from error
    return sha256_file(archive_path)


def compare_packages(args: argparse.Namespace) -> int:
    required = {
        "intended_root": args.intended_root,
        "clean_root": args.clean_root,
        "intended_archive": args.intended_archive,
        "clean_archive": args.clean_archive,
        "repo_root": args.repo_root,
        "evidence_output": args.evidence_output,
    }
    missing = sorted(name.replace("_", "-") for name, value in required.items() if value is None)
    if missing:
        raise SystemExit(f"Comparison mode requires: {', '.join('--' + name for name in missing)}")
    if args.package_root is not None or args.output is not None:
        raise SystemExit("Comparison mode cannot be combined with --package-root or --output")
    selected_paths = (
        args.intended_root,
        args.clean_root,
        args.intended_archive,
        args.clean_archive,
        args.evidence_output,
    )
    if any(path.is_symlink() for path in selected_paths):
        raise SystemExit("Comparison roots, archives, and evidence output must not be symbolic links")
    intended_root = args.intended_root.resolve()
    clean_root = args.clean_root.resolve()
    intended_archive = args.intended_archive.resolve()
    clean_archive = args.clean_archive.resolve()
    repo_root = args.repo_root.resolve()
    evidence_output = args.evidence_output.resolve()
    if intended_root == clean_root or intended_root.name != clean_root.name:
        raise SystemExit("Comparison package roots must be distinct and have the same basename")
    if intended_archive == clean_archive:
        raise SystemExit("Comparison archives must be distinct paths")
    if evidence_output in {intended_archive, clean_archive}:
        raise SystemExit("Regeneration evidence output must be distinct from both compared archives")
    if any(evidence_output == root or root in evidence_output.parents for root in (intended_root, clean_root)):
        raise SystemExit("Regeneration evidence output must be outside both compared packages")
    if any(root == archive or root in archive.parents for root in (intended_root, clean_root) for archive in (intended_archive, clean_archive)):
        raise SystemExit("Compared archives must be outside both package roots")
    pipeline_path = repo_root / "scripts/build-elven-production-assets.py"
    if not pipeline_path.is_file():
        raise SystemExit(f"Build pipeline is missing: {pipeline_path}")

    intended_manifest, intended_files = verified_package_files(intended_root)
    clean_manifest, clean_files = verified_package_files(clean_root)
    if intended_manifest.get("packageVersion") != "3.1.0" or clean_manifest.get("packageVersion") != "3.1.0":
        raise SystemExit("Comparison mode requires two v3.1.0 packages")
    generated_at = args.generated_at.isoformat().replace("+00:00", "Z")
    if intended_manifest.get("generatedDate") != generated_at or clean_manifest.get("generatedDate") != generated_at:
        raise SystemExit("Package manifest timestamps differ from --generated-at")
    intended_resource_count, intended_output_count, _ = validate_phase_c_matrix(intended_root, args.generated_at, pipeline_path)
    clean_resource_count, clean_output_count, _ = validate_phase_c_matrix(clean_root, args.generated_at, pipeline_path)

    intended_inventory = package_inventory(intended_root, intended_files)
    clean_inventory = package_inventory(clean_root, clean_files)
    all_paths = sorted(set(intended_inventory) | set(clean_inventory))
    mismatches = [
        relative for relative in all_paths
        if intended_inventory.get(relative) != clean_inventory.get(relative)
    ]
    source_mismatches = [
        relative for relative in mismatches
        if relative.startswith("Source-Masters/")
    ]
    if mismatches:
        preview = mismatches[:8]
        raise SystemExit(f"Compared package trees differ at {len(mismatches)} paths: {preview}")
    intended_tree_hash = inventory_digest(intended_inventory)
    clean_tree_hash = inventory_digest(clean_inventory)
    if intended_tree_hash != clean_tree_hash:
        raise SystemExit("Compared package inventory hashes differ")
    intended_archive_hash = validate_archive(intended_archive, intended_root, intended_files, args.generated_at)
    clean_archive_hash = validate_archive(clean_archive, clean_root, clean_files, args.generated_at)
    if intended_archive_hash != clean_archive_hash:
        raise SystemExit("Compared deterministic archive hashes differ")

    evidence = {
        "schemaVersion": 1,
        "packageVersion": "3.1.0",
        "generatedAtUTC": generated_at,
        "status": "PASS",
        "command": [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]],
        "pipelinePath": "scripts/build-elven-production-assets.py",
        "pipelineSHA256": sha256_file(pipeline_path),
        "intendedPackageRoot": str(intended_root),
        "cleanPackageRoot": str(clean_root),
        "cleanTarget": True,
        "distinctTarget": True,
        "expectedResourceCount": intended_resource_count,
        "rebuiltResourceCount": clean_resource_count,
        "expectedOutputCount": intended_output_count,
        "rebuiltOutputCount": clean_output_count,
        "hashMismatches": [],
        "sourceHashMismatches": source_mismatches,
        "intendedTreeSHA256": intended_tree_hash,
        "cleanTreeSHA256": clean_tree_hash,
        "intendedArchivePath": str(intended_archive),
        "cleanArchivePath": str(clean_archive),
        "archivesDistinct": True,
        "intendedArchiveSHA256": intended_archive_hash,
        "cleanArchiveSHA256": clean_archive_hash,
    }
    payload = (json.dumps(evidence, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    atomic_write(evidence_output, payload, args.replace)
    print(json.dumps({
        "status": "COMPARED",
        "evidenceOutput": str(evidence_output),
        "resourceCount": intended_resource_count,
        "outputCount": intended_output_count,
        "treeSHA256": intended_tree_hash,
        "archiveSHA256": intended_archive_hash,
    }, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Create deterministic package archives or compare two clean package/archive pairs.")
    parser.add_argument("--package-root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--generated-at", required=True, type=parse_generated_at)
    parser.add_argument("--compression-level", type=int, choices=range(0, 10), default=9)
    parser.add_argument("--intended-root", type=Path)
    parser.add_argument("--clean-root", type=Path)
    parser.add_argument("--intended-archive", type=Path)
    parser.add_argument("--clean-archive", type=Path)
    parser.add_argument("--repo-root", type=Path)
    parser.add_argument("--evidence-output", type=Path)
    parser.add_argument("--replace", action="store_true", help="Atomically replace an existing archive or evidence file at the exact output path")
    args = parser.parse_args()
    verify_runtime()

    comparison_requested = any(
        value is not None
        for value in (args.intended_root, args.clean_root, args.intended_archive, args.clean_archive, args.repo_root, args.evidence_output)
    )
    if comparison_requested:
        return compare_packages(args)
    if args.package_root is None or args.output is None:
        raise SystemExit("Archive mode requires --package-root and --output")

    if args.package_root.is_symlink() or args.output.is_symlink():
        raise SystemExit("Package root and archive output must not be symbolic links")
    root = args.package_root.resolve()
    output = args.output.resolve()
    if not root.is_dir():
        raise SystemExit("Package root must be an existing directory")
    if output.name != f"{root.name}.zip":
        raise SystemExit("Output filename must equal the package root name plus .zip")
    if root == output.parent or root in output.parents:
        raise SystemExit("Archive output must be outside the package root")
    manifest, files = verified_package_files(root)
    generated_at = args.generated_at.isoformat().replace("+00:00", "Z")
    if manifest.get("generatedDate") != generated_at:
        raise SystemExit("Package manifest generatedDate must match --generated-at")
    first = archive_bytes(root, files, args.generated_at, args.compression_level)
    second = archive_bytes(root, files, args.generated_at, args.compression_level)
    if first != second:
        raise SystemExit("Archive encoder did not reproduce identical bytes")
    atomic_write(output, first, args.replace)
    print(json.dumps({
        "status": "ARCHIVED",
        "packageVersion": manifest.get("packageVersion"),
        "rootDirectory": root.name,
        "output": str(output),
        "fileCount": len(files),
        "byteLength": len(first),
        "sha256": sha256_bytes(first),
        "generatedAtUTC": generated_at,
        "toolVersions": {"python": platform.python_version(), "zlib": zlib.ZLIB_RUNTIME_VERSION},
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
