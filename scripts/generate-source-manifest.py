#!/usr/bin/env python3
"""Generate or verify a deterministic, location-independent source manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import unicodedata
from typing import Any, Iterable


SCHEMA_VERSION = "1.1"
AGGREGATE_FORMAT = (
    "UTF-8 records sorted by normalized path: "
    "path\\0kind\\0bytes\\0sha256\\0executable-as-0-or-1\\n"
)
DEFAULT_EXCLUDES = (
    ".git",
    ".build",
    "DerivedData",
    "artifacts/remediation-v1",
    "docs/verification/remediation-v1",
    ".DS_Store",
)


class ManifestError(ValueError):
    """Raised when a manifest or source tree cannot be represented safely."""


def normalized_path(path: Path) -> str:
    return unicodedata.normalize("NFC", path.as_posix())


def normalize_excludes(excludes: Iterable[str]) -> list[str]:
    normalized: set[str] = set()
    for raw in excludes:
        if not isinstance(raw, str):
            raise ManifestError("exclude paths must be strings")
        value = normalized_path(Path(raw.strip().strip("/")))
        if not value or value == ".":
            continue
        candidate = Path(value)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise ManifestError(f"unsafe exclude path: {raw}")
        normalized.add(value)
    return sorted(normalized)


def is_excluded(relative: str, excludes: Iterable[str]) -> bool:
    parts = relative.split("/")
    for entry in excludes:
        if relative == entry or relative.startswith(entry + "/"):
            return True
        if "/" not in entry and entry in parts:
            return True
    return False


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    byte_count = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            byte_count += len(chunk)
            digest.update(chunk)
    return byte_count, digest.hexdigest()


def record_for(path: Path, relative: str) -> dict[str, object]:
    if "\0" in relative or "\n" in relative:
        raise ManifestError(f"path cannot be represented canonically: {relative!r}")
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode):
        target = os.readlink(path).encode("utf-8")
        return {
            "path": relative,
            "kind": "symlink",
            "bytes": len(target),
            "sha256": sha256_bytes(target),
            "executable": False,
        }
    if not stat.S_ISREG(metadata.st_mode):
        raise ManifestError(f"unsupported filesystem entry: {relative}")
    byte_count, digest = file_digest(path)
    return {
        "path": relative,
        "kind": "file",
        "bytes": byte_count,
        "sha256": digest,
        "executable": bool(metadata.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)),
    }


def collect(root: Path, excludes: list[str]) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    seen_paths: set[str] = set()
    candidates = sorted(
        root.rglob("*"),
        key=lambda item: normalized_path(item.relative_to(root)),
    )
    for path in candidates:
        relative = normalized_path(path.relative_to(root))
        if is_excluded(relative, excludes):
            continue
        if path.is_dir() and not path.is_symlink():
            continue
        if relative in seen_paths:
            raise ManifestError(f"normalized path collision: {relative}")
        seen_paths.add(relative)
        records.append(record_for(path, relative))
    return records


def aggregate_digest(records: list[dict[str, object]]) -> str:
    digest = hashlib.sha256()
    for record in records:
        line = (
            f"{record['path']}\0{record['kind']}\0{record['bytes']}\0"
            f"{record['sha256']}\0{1 if record['executable'] else 0}\n"
        )
        digest.update(line.encode("utf-8"))
    return digest.hexdigest()


def build_manifest(root: Path, excludes: list[str]) -> dict[str, object]:
    records = collect(root, excludes)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "aggregateFormat": AGGREGATE_FORMAT,
        "fileCount": len(records),
        "aggregateSHA256": aggregate_digest(records),
        "excludes": excludes,
        "files": records,
    }


def canonical_excludes(root: Path, manifest_path: Path) -> list[str]:
    excludes = list(DEFAULT_EXCLUDES)
    try:
        excludes.append(normalized_path(manifest_path.resolve().relative_to(root.resolve())))
    except ValueError:
        pass
    return normalize_excludes(excludes)


def validate_manifest_document(document: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, dict):
        return ["manifest root must be an object"]
    expected_keys = {
        "schemaVersion",
        "aggregateFormat",
        "fileCount",
        "aggregateSHA256",
        "excludes",
        "files",
    }
    if set(document) != expected_keys:
        errors.append("manifest keys differ from the canonical schema")
    if document.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"schemaVersion must be {SCHEMA_VERSION}")
    if document.get("aggregateFormat") != AGGREGATE_FORMAT:
        errors.append("aggregateFormat differs from the canonical algorithm")
    try:
        excludes = normalize_excludes(document.get("excludes", []))
    except (ManifestError, TypeError):
        excludes = []
        errors.append("excludes must contain safe repository-relative strings")
    if document.get("excludes") != excludes:
        errors.append("excludes must be normalized, unique, and sorted")

    files = document.get("files")
    if not isinstance(files, list):
        errors.append("files must be an array")
        return errors
    expected_record_keys = {"path", "kind", "bytes", "sha256", "executable"}
    paths: list[str] = []
    for index, record in enumerate(files):
        label = f"files[{index}]"
        if not isinstance(record, dict) or set(record) != expected_record_keys:
            errors.append(f"{label} keys differ from the canonical schema")
            continue
        path = record.get("path")
        if (
            not isinstance(path, str)
            or not path
            or Path(path).is_absolute()
            or ".." in Path(path).parts
            or "\0" in path
            or "\n" in path
            or normalized_path(Path(path)) != path
        ):
            errors.append(f"{label}.path is not a normalized relative path")
        else:
            paths.append(path)
        if record.get("kind") not in {"file", "symlink"}:
            errors.append(f"{label}.kind is invalid")
        byte_count = record.get("bytes")
        if isinstance(byte_count, bool) or not isinstance(byte_count, int) or byte_count < 0:
            errors.append(f"{label}.bytes is invalid")
        digest = record.get("sha256")
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            errors.append(f"{label}.sha256 is invalid")
        if not isinstance(record.get("executable"), bool):
            errors.append(f"{label}.executable must be Boolean")
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        errors.append("file records must have unique paths in sorted order")
    if document.get("fileCount") != len(files):
        errors.append("fileCount differs from files length")
    if not errors and document.get("aggregateSHA256") != aggregate_digest(files):
        errors.append("aggregateSHA256 differs from the canonical file-record digest")
    return errors


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exception:
        raise ManifestError(f"unable to read manifest: {exception}") from exception
    errors = validate_manifest_document(document)
    if errors:
        raise ManifestError("; ".join(errors))
    return document


def verify_manifest(root: Path, manifest_path: Path) -> tuple[bool, list[str], dict[str, Any]]:
    expected = load_manifest(manifest_path)
    required_excludes = canonical_excludes(root, manifest_path)
    if expected["excludes"] != required_excludes:
        raise ManifestError(
            "excludes differ from the locked source-manifest policy: "
            + ", ".join(expected["excludes"])
        )
    actual = build_manifest(root, required_excludes)
    if expected == actual:
        return True, [], actual
    expected_by_path = {record["path"]: record for record in expected["files"]}
    actual_by_path = {record["path"]: record for record in actual["files"]}
    changed = sorted(
        path
        for path in set(expected_by_path) | set(actual_by_path)
        if expected_by_path.get(path) != actual_by_path.get(path)
    )
    if not changed:
        changed.append("manifest metadata")
    return False, changed, actual


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    root = args.root.resolve()
    output = args.output.resolve()
    if not root.is_dir():
        parser.error(f"root is not a directory: {root}")

    try:
        if args.verify:
            valid, changed, manifest = verify_manifest(root, output)
            if not valid:
                print("FAIL: source manifest differs", file=sys.stderr)
                for relative in changed[:100]:
                    print(f"  {relative}", file=sys.stderr)
                if len(changed) > 100:
                    print(f"  ... {len(changed) - 100} more", file=sys.stderr)
                return 1
            print(f"PASS: {manifest['fileCount']} files, {manifest['aggregateSHA256']}")
            return 0

        if args.exclude:
            raise ManifestError(
                "custom excludes are prohibited by the locked source-manifest policy"
            )
        normalized_excludes = canonical_excludes(root, output)
        manifest = build_manifest(root, normalized_excludes)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except ManifestError as exception:
        print(f"ERROR: {exception}", file=sys.stderr)
        return 2

    print(f"WROTE: {output}")
    print(f"FILES: {manifest['fileCount']}")
    print(f"SHA256: {manifest['aggregateSHA256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
