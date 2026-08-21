#!/usr/bin/env python3
"""Create deterministic SHA-256 inventories for package trees and archives."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import zipfile
from pathlib import Path
from typing import Any


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory_tree(root: Path) -> dict[str, Any]:
    files = []
    for path in sorted((item for item in root.rglob("*") if item.is_file())):
        relative_path = path.relative_to(root).as_posix()
        files.append(
            {
                "path": relative_path,
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    return {
        "root": str(root),
        "fileCount": len(files),
        "byteTotal": sum(item["bytes"] for item in files),
        "files": files,
    }


def archive_inventory(path: Path, require_deterministic: bool) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    members: list[dict[str, Any]] = []
    roots: set[str] = set()
    names: list[str] = []
    try:
        with zipfile.ZipFile(path) as archive:
            duplicate_names: set[str] = set()
            seen: set[str] = set()
            for entry in archive.infolist():
                name = entry.filename
                names.append(name)
                if name in seen:
                    duplicate_names.add(name)
                seen.add(name)
                normalized_name = name[:-1] if entry.is_dir() and name.endswith("/") else name
                parts = Path(normalized_name).parts
                if (
                    not normalized_name
                    or name.startswith("/")
                    or "\\" in name
                    or any(part in ("", ".", "..") for part in parts)
                    or normalized_name != Path(normalized_name).as_posix()
                ):
                    errors.append(f"unsafe archive member: {name!r}")
                if parts:
                    roots.add(parts[0])
                unix_mode = (entry.external_attr >> 16) & 0o170000
                if unix_mode == 0o120000:
                    errors.append(f"archive symlink is prohibited: {name}")
                member = {
                    "path": name,
                    "bytes": entry.file_size,
                    "compressedBytes": entry.compress_size,
                    "crc32": f"{entry.CRC:08x}",
                    "directory": entry.is_dir(),
                }
                if not entry.is_dir():
                    with archive.open(entry) as handle:
                        digest = hashlib.sha256()
                        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                            digest.update(chunk)
                    member["sha256"] = digest.hexdigest()
                members.append(member)
            for name in sorted(duplicate_names):
                errors.append(f"duplicate archive member: {name}")
            corrupt = archive.testzip()
            if corrupt is not None:
                errors.append(f"archive CRC failure: {corrupt}")
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        errors.append(f"archive parse failure: {error}")
    if len(roots) != 1:
        errors.append(f"archive must have one extraction root, found {sorted(roots)}")
    if require_deterministic and names != sorted(names):
        errors.append("archive members are not sorted")
    return (
        {
            "path": str(path),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
            "memberCount": len(members),
            "extractionRoots": sorted(roots),
            "members": members,
        },
        errors,
    )


def parse_named_path(value: str) -> tuple[str, Path]:
    name, separator, raw_path = value.partition("=")
    if not separator or not name or not raw_path:
        raise argparse.ArgumentTypeError("expected NAME=PATH")
    return name, Path(raw_path).expanduser().resolve()


def parse_named_pair(value: str) -> tuple[str, str]:
    left, separator, right = value.partition("=")
    if not separator or not left or not right:
        raise argparse.ArgumentTypeError("expected LEFT_NAME=RIGHT_NAME")
    return left, right


def parse_generated_at(value: str) -> str:
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        raise argparse.ArgumentTypeError("expected UTC timestamp YYYY-MM-DDTHH:MM:SSZ")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", action="append", default=[], type=parse_named_path)
    parser.add_argument("--archive", action="append", default=[], type=parse_named_path)
    parser.add_argument(
        "--require-deterministic-archive",
        action="store_true",
        help="Also require lexicographically sorted archive members.",
    )
    parser.add_argument(
        "--expect-identical",
        action="append",
        default=[],
        type=parse_named_pair,
        metavar="LEFT_NAME=RIGHT_NAME",
        help="Fail unless two named root inventories contain identical relative paths and bytes.",
    )
    parser.add_argument(
        "--expect-identical-archive",
        action="append",
        default=[],
        type=parse_named_pair,
        metavar="LEFT_NAME=RIGHT_NAME",
        help="Fail unless two named archives have identical bytes.",
    )
    parser.add_argument(
        "--expect-archive-matches-root",
        action="append",
        default=[],
        type=parse_named_pair,
        metavar="ARCHIVE_NAME=ROOT_NAME",
        help="Fail unless an archive extracts to the same relative files and bytes as a named root.",
    )
    parser.add_argument(
        "--generated-at-utc",
        type=parse_generated_at,
        help="Explicit timestamp for reproducible evidence; defaults to the current UTC time.",
    )
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    errors: list[str] = []
    trees: dict[str, Any] = {}
    archives: dict[str, Any] = {}
    comparisons: dict[str, Any] = {}

    if not args.root and not args.archive:
        errors.append("at least one --root or --archive input is required")

    all_names = [name for name, _ in args.root] + [name for name, _ in args.archive]
    duplicate_input_names = sorted(name for name in set(all_names) if all_names.count(name) > 1)
    errors.extend(f"duplicate input name: {name}" for name in duplicate_input_names)

    output = args.output.expanduser().resolve()

    for name, root in args.root:
        if not root.is_dir():
            errors.append(f"missing directory: {name}={root}")
            continue
        if output == root or root in output.parents:
            errors.append(f"output must be outside inventoried root: {name}={root}")
            continue
        symlinks = sorted(item.relative_to(root).as_posix() for item in root.rglob("*") if item.is_symlink())
        errors.extend(f"package symlink is prohibited: {name}:{item}" for item in symlinks)
        trees[name] = inventory_tree(root)

    for name, archive in args.archive:
        if not archive.is_file():
            errors.append(f"missing archive: {name}={archive}")
            continue
        archives[name], archive_errors = archive_inventory(archive, args.require_deterministic_archive)
        errors.extend(f"{name}: {error}" for error in archive_errors)

    for left_name, right_name in args.expect_identical:
        key = f"{left_name}={right_name}"
        if left_name not in trees or right_name not in trees:
            errors.append(f"comparison references missing root inventory: {key}")
            comparisons[key] = {"status": "FAIL", "differences": ["missing inventory"]}
            continue
        left_files = trees[left_name]["files"]
        right_files = trees[right_name]["files"]
        differences: list[str] = []
        left_by_path = {item["path"]: item for item in left_files}
        right_by_path = {item["path"]: item for item in right_files}
        for relative in sorted(set(left_by_path) | set(right_by_path)):
            left = left_by_path.get(relative)
            right = right_by_path.get(relative)
            if left is None:
                differences.append(f"only in {right_name}: {relative}")
            elif right is None:
                differences.append(f"only in {left_name}: {relative}")
            elif (left["bytes"], left["sha256"]) != (right["bytes"], right["sha256"]):
                differences.append(f"content differs: {relative}")
        comparisons[key] = {
            "status": "PASS" if not differences else "FAIL",
            "fileCount": len(left_files) if not differences else None,
            "differences": differences,
        }
        if differences:
            errors.append(f"root inventories differ: {key}")

    for left_name, right_name in args.expect_identical_archive:
        key = f"archive:{left_name}={right_name}"
        if left_name not in archives or right_name not in archives:
            errors.append(f"comparison references missing archive inventory: {key}")
            comparisons[key] = {"status": "FAIL", "differences": ["missing inventory"]}
            continue
        left = archives[left_name]
        right = archives[right_name]
        identical = (left["bytes"], left["sha256"]) == (right["bytes"], right["sha256"])
        comparisons[key] = {
            "status": "PASS" if identical else "FAIL",
            "bytes": left["bytes"] if identical else None,
            "sha256": left["sha256"] if identical else None,
            "differences": [] if identical else ["archive bytes differ"],
        }
        if not identical:
            errors.append(f"archive inventories differ: {key}")

    for archive_name, root_name in args.expect_archive_matches_root:
        key = f"archive-root:{archive_name}={root_name}"
        if archive_name not in archives or root_name not in trees:
            errors.append(f"comparison references missing archive or root inventory: {key}")
            comparisons[key] = {"status": "FAIL", "differences": ["missing inventory"]}
            continue
        extraction_roots = archives[archive_name]["extractionRoots"]
        differences: list[str] = []
        if len(extraction_roots) != 1:
            differences.append("archive extraction root is not unique")
            archive_files: dict[str, Any] = {}
        else:
            prefix = extraction_roots[0] + "/"
            archive_files = {
                item["path"][len(prefix):]: item
                for item in archives[archive_name]["members"]
                if not item["directory"] and item["path"].startswith(prefix)
            }
        root_files = {item["path"]: item for item in trees[root_name]["files"]}
        for relative in sorted(set(archive_files) | set(root_files)):
            archive_item = archive_files.get(relative)
            root_item = root_files.get(relative)
            if archive_item is None:
                differences.append(f"only in {root_name}: {relative}")
            elif root_item is None:
                differences.append(f"only in {archive_name}: {relative}")
            elif (archive_item["bytes"], archive_item.get("sha256")) != (
                root_item["bytes"],
                root_item["sha256"],
            ):
                differences.append(f"content differs: {relative}")
        comparisons[key] = {
            "status": "PASS" if not differences else "FAIL",
            "fileCount": len(root_files) if not differences else None,
            "differences": differences,
        }
        if differences:
            errors.append(f"archive does not match root inventory: {key}")

    report = {
        "schemaVersion": 1,
        "generatedAtUTC": args.generated_at_utc or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "trees": trees,
        "archives": archives,
        "comparisons": comparisons,
        "errors": errors,
        "status": "PASS" if not errors else "FAIL",
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "errors": errors}, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
