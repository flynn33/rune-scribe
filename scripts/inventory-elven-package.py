#!/usr/bin/env python3
"""Create deterministic SHA-256 inventories for package trees and archives."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
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


def parse_named_path(value: str) -> tuple[str, Path]:
    name, separator, raw_path = value.partition("=")
    if not separator or not name or not raw_path:
        raise argparse.ArgumentTypeError("expected NAME=PATH")
    return name, Path(raw_path).expanduser().resolve()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", action="append", default=[], type=parse_named_path)
    parser.add_argument("--archive", action="append", default=[], type=parse_named_path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    errors: list[str] = []
    trees: dict[str, Any] = {}
    archives: dict[str, Any] = {}

    for name, root in args.root:
        if not root.is_dir():
            errors.append(f"missing directory: {name}={root}")
            continue
        trees[name] = inventory_tree(root)

    for name, archive in args.archive:
        if not archive.is_file():
            errors.append(f"missing archive: {name}={archive}")
            continue
        archives[name] = {
            "path": str(archive),
            "bytes": archive.stat().st_size,
            "sha256": sha256_file(archive),
        }

    report = {
        "schemaVersion": 1,
        "generatedAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
        "trees": trees,
        "archives": archives,
        "errors": errors,
        "status": "PASS" if not errors else "FAIL",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "errors": errors}, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
