#!/usr/bin/env python3
"""Inventory and structurally validate all shipping Theme production resources."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import mimetypes
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

from PIL import Image, UnidentifiedImageError


SCHEMA_VERSION = "1.0"
IMAGE_EXTENSIONS = {".heic", ".heif", ".jpeg", ".jpg", ".png", ".tif", ".tiff"}
PLACEHOLDER_PATTERN = re.compile(
    r"(?:^|[._-])(dummy|placeholder|sample|temp|temporary|todo)(?:[._-]|$)",
    re.IGNORECASE,
)
THEMES = (
    {
        "theme": "Norse",
        "module": "RuneScribeNorseThemeModule",
        "production": "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production",
        "manifest": "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v1.0.json",
        "records": "resources",
        "id": "resourceHandle",
        "bytes": "byteLength",
        "role": "semanticRole",
    },
    {
        "theme": "Moonleaf",
        "module": "RuneScribeThemeMoonleafModule",
        "production": "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/Resources/Production",
        "manifest": "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/Resources/Production/Resource-Integrity-Manifest-v1.0.json",
        "records": "files",
        "id": "resourceID",
        "bytes": "bytes",
        "role": "role",
    },
    {
        "theme": "Sunspire",
        "module": "RuneScribeThemeSunspireModule",
        "production": "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeSunspireModule/Resources/Production",
        "manifest": "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeSunspireModule/Resources/Production/Resource-Integrity-Manifest-v1.0.json",
        "records": "files",
        "id": "resourceID",
        "bytes": "bytes",
        "role": "role",
    },
    {
        "theme": "Wildwood",
        "module": "RuneScribeThemeWildwoodModule",
        "production": "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeWildwoodModule/Resources/Production",
        "manifest": "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeWildwoodModule/Resources/Production/Resource-Integrity-Manifest-v1.0.json",
        "records": "files",
        "id": "resourceID",
        "bytes": "bytes",
        "role": "role",
    },
    {
        "theme": "Gloamthorn",
        "module": "RuneScribeThemeGloamthornModule",
        "production": "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeGloamthornModule/Resources/Production",
        "manifest": "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeGloamthornModule/Resources/Production/Resource-Integrity-Manifest-v1.0.json",
        "records": "files",
        "id": "resourceID",
        "bytes": "bytes",
        "role": "role",
    },
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_output(command: Sequence[str], cwd: Path) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
    )
    return completed.stdout.strip() if completed.returncode == 0 else completed.stderr.strip()


def git_output(root: Path, *arguments: str) -> str:
    return command_output(("git", *arguments), root)


def media_type(path: Path) -> str:
    overrides = {
        ".heic": "image/heic",
        ".heif": "image/heif",
        ".json": "application/json",
        ".pdf": "application/pdf",
        ".ttf": "font/ttf",
        ".wav": "audio/wav",
    }
    return overrides.get(path.suffix.lower()) or mimetypes.guess_type(path.name)[0] or "application/octet-stream"


def parse_sips(path: Path) -> Dict[str, Any]:
    completed = subprocess.run(
        ("sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", "-g", "format", str(path)),
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
    )
    if completed.returncode != 0:
        return {"inspectionError": completed.stderr.strip() or "sips could not inspect resource"}
    values: Dict[str, str] = {}
    for line in completed.stdout.splitlines():
        if ":" not in line:
            continue
        key, value = line.strip().split(":", 1)
        values[key.strip()] = value.strip()
    width = int(values["pixelWidth"]) if values.get("pixelWidth", "").isdigit() else None
    height = int(values["pixelHeight"]) if values.get("pixelHeight", "").isdigit() else None
    alpha_value = values.get("hasAlpha", "").lower()
    has_alpha = True if alpha_value == "yes" else False if alpha_value == "no" else None
    return {
        "dimensions": [width, height] if width and height else None,
        "hasAlpha": has_alpha,
        "colorMode": values.get("format"),
    }


def inspect_image(path: Path) -> Dict[str, Any]:
    try:
        with Image.open(path) as image:
            image.load()
            width, height = image.size
            rgba = image.convert("RGBA")
            alpha_extrema = list(rgba.getchannel("A").getextrema())
            sample = rgba.resize((min(width, 64), min(height, 64)), Image.Resampling.BILINEAR)
            unique_sample_colors = len(set(sample.getdata()))
            rgb_extrema = rgba.convert("RGB").getextrema()
            return {
                "dimensions": [width, height],
                "hasAlpha": "A" in image.getbands(),
                "alphaExtrema": alpha_extrema,
                "colorMode": image.mode,
                "uniqueSampleColorCount": unique_sample_colors,
                "isFullyTransparent": alpha_extrema[1] == 0,
                "isSingleColor": all(low == high for low, high in rgb_extrema),
            }
    except (OSError, UnidentifiedImageError):
        return parse_sips(path)


def relative_resource_path(raw: Any) -> Optional[str]:
    if not isinstance(raw, str) or not raw:
        return None
    return raw


def source_corpus(root: Path, module: str) -> str:
    paths = [
        root / "Packages/RuneScribeArchitecture/Sources" / module,
        root / "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts",
        root / "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule",
    ]
    values: List[str] = []
    for path in paths:
        if not path.is_dir():
            continue
        for source in sorted(path.rglob("*.swift")):
            try:
                values.append(source.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError):
                continue
    return "\n".join(values)


def load_manifest(path: Path, records_key: str) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    decoded = json.loads(path.read_text(encoding="utf-8"))
    records = decoded.get(records_key)
    if not isinstance(decoded, dict) or not isinstance(records, list):
        raise ValueError("integrity manifest has an invalid record collection")
    return decoded, [record for record in records if isinstance(record, dict)]


def finding(code: str, path: str, message: str) -> Dict[str, str]:
    return {"code": code, "path": path, "message": message}


def inventory_theme(root: Path, definition: Dict[str, str]) -> Tuple[Dict[str, Any], List[Dict[str, str]]]:
    production = root / definition["production"]
    resource_root = production.parent
    manifest_path = root / definition["manifest"]
    findings: List[Dict[str, str]] = []
    manifest, records = load_manifest(manifest_path, definition["records"])
    declared: Dict[Path, Dict[str, Any]] = {}
    for record in records:
        relative = relative_resource_path(record.get("path"))
        if relative is None:
            findings.append(finding("invalid-manifest-path", definition["manifest"], "resource path is missing"))
            continue
        declared_path = (resource_root / relative).resolve()
        try:
            declared_path.relative_to(resource_root.resolve())
        except ValueError:
            findings.append(finding("invalid-manifest-path", relative, "resource path escapes the module Resources root"))
            continue
        if declared_path in declared:
            findings.append(finding("duplicate-manifest-path", relative, "resource path is declared more than once"))
            continue
        declared[declared_path] = record

    corpus = source_corpus(root, definition["module"])
    rows: List[Dict[str, Any]] = []
    actual_paths = {
        path.resolve()
        for path in production.rglob("*")
        if path.is_file()
    }
    actual_paths.update(path for path in declared if path.is_file())
    manifest_resolved = manifest_path.resolve()

    for path in sorted(actual_paths):
        relative = path.relative_to(resource_root.resolve()).as_posix()
        record = declared.get(path)
        is_control_manifest = path == manifest_resolved
        digest = sha256_file(path)
        byte_count = path.stat().st_size
        resource_id = record.get(definition["id"]) if record else None
        row: Dict[str, Any] = {
            "path": path.relative_to(root).as_posix(),
            "relativeProductionPath": relative,
            "theme": definition["theme"],
            "module": definition["module"],
            "mediaType": record.get("mediaType") if record and record.get("mediaType") else media_type(path),
            "byteLength": byte_count,
            "sha256": digest,
            "resourceID": resource_id,
            "role": record.get(definition["role"]) if record else "integrity-manifest" if is_control_manifest else None,
            "declared": record is not None,
            "controlManifest": is_control_manifest,
            "consumedBySource": isinstance(resource_id, str) and resource_id in corpus,
            "manifestByteLengthMatches": record.get(definition["bytes"]) == byte_count if record else None,
            "manifestSHA256Matches": record.get("sha256") == digest if record else None,
        }
        if path.suffix.lower() in IMAGE_EXTENSIONS or path.suffix.lower() == ".pdf":
            row.update(inspect_image(path))
        rows.append(row)

        display = row["path"]
        if record is None and not is_control_manifest:
            findings.append(finding("undeclared-production-resource", display, "file is absent from the integrity manifest"))
        if record is not None and record.get(definition["bytes"]) != byte_count:
            findings.append(finding("stale-byte-length", display, "integrity manifest byte length differs"))
        if record is not None and record.get("sha256") != digest:
            findings.append(finding("stale-sha256", display, "integrity manifest SHA-256 differs"))
        if isinstance(resource_id, str) and resource_id not in corpus:
            findings.append(finding("unconsumed-resource-id", display, "resource ID is not present in the module, contracts, or shared UI sources"))
        if PLACEHOLDER_PATTERN.search(path.stem):
            findings.append(finding("placeholder-name", display, "shipping filename indicates placeholder content"))
        if row.get("inspectionError"):
            findings.append(finding("unreadable-visual-resource", display, str(row["inspectionError"])))
        if row.get("isFullyTransparent"):
            findings.append(finding("fully-transparent-resource", display, "shipping visual is fully transparent"))
        if row.get("isSingleColor"):
            findings.append(finding("single-color-resource", display, "shipping visual is a single solid color"))

    for path in sorted(set(declared) - set(actual_paths)):
        findings.append(finding(
            "missing-production-resource",
            path.relative_to(resource_root.resolve()).as_posix(),
            "integrity-manifest resource is missing",
        ))

    return {
        "theme": definition["theme"],
        "module": definition["module"],
        "productionRoot": definition["production"],
        "integrityManifest": definition["manifest"],
        "integrityManifestSHA256": sha256_file(manifest_path),
        "integrityManifestSchemaVersion": manifest.get("schemaVersion"),
        "fileCount": len(rows),
        "declaredResourceCount": len(declared),
        "files": rows,
    }, findings


def atomic_write(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a source-bound Theme production-resource inventory.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--phase", choices=("baseline", "final"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_arguments(argv)
    root = args.root.resolve()
    output = args.output if args.output.is_absolute() else root / args.output
    started = utc_now()
    themes: List[Dict[str, Any]] = []
    findings: List[Dict[str, str]] = []
    try:
        for definition in THEMES:
            result, theme_findings = inventory_theme(root, definition)
            themes.append(result)
            findings.extend(theme_findings)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        findings.append(finding("inventory-error", str(output), str(error)))

    status = git_output(root, "status", "--porcelain=v1")
    payload: Dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "phase": args.phase,
        "result": "PASS" if not findings else "FAIL",
        "sourceSHA": git_output(root, "rev-parse", "HEAD"),
        "originMainSHA": git_output(root, "rev-parse", "origin/main"),
        "worktreeDirty": bool(status),
        "worktreeStatus": status.splitlines(),
        "command": "python3 scripts/inventory-theme-resources.py --phase {} --output {}".format(
            args.phase, output.relative_to(root).as_posix() if output.is_relative_to(root) else str(output)
        ),
        "startedAt": started,
        "endedAt": utc_now(),
        "host": platform.platform(),
        "python": sys.version.split()[0],
        "xcode": command_output(("xcodebuild", "-version"), root).splitlines(),
        "themeCount": len(themes),
        "fileCount": sum(theme["fileCount"] for theme in themes),
        "declaredResourceCount": sum(theme["declaredResourceCount"] for theme in themes),
        "structuralFindings": sorted(findings, key=lambda item: (item["code"], item["path"], item["message"])),
        "visualFidelityAssessment": "BASELINE_DEFECT_CONFIRMED" if args.phase == "baseline" else "REQUIRES_VISUAL_MATRIX_CORRELATION",
        "themes": themes,
    }
    atomic_write(output, payload)
    sys.stdout.write(json.dumps({
        "result": payload["result"],
        "phase": args.phase,
        "themeCount": payload["themeCount"],
        "fileCount": payload["fileCount"],
        "declaredResourceCount": payload["declaredResourceCount"],
        "findingCount": len(payload["structuralFindings"]),
        "output": str(output),
    }, indent=2, sort_keys=True) + "\n")
    return 0 if payload["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
