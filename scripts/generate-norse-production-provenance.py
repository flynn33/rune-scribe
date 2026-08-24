#!/usr/bin/env python3
"""Generate deterministic provenance for the exact Norse production resources."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
from typing import Any


CATALOG_RELATIVE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
    "NorseApplicationResourceCatalog.swift"
)
MODULE_RELATIVE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule"
)
RESOURCE_ROOT_RELATIVE = MODULE_RELATIVE / "Resources"
INTEGRITY_RELATIVE = (
    RESOURCE_ROOT_RELATIVE
    / "Production/Metadata/Norse-Resource-Integrity-Manifest-v1.0.json"
)
PROVENANCE_RELATIVE = (
    RESOURCE_ROOT_RELATIVE
    / "Production/Metadata/Norse-Production-Asset-Provenance-v1.0.json"
)
DESCRIPTOR_RELATIVE = MODULE_RELATIVE / "NorseBaseThemeDescriptor.swift"
GENERATOR_RELATIVE = Path("scripts/generate-norse-production-provenance.py")
BASELINE_APPROVAL_RELATIVE = Path(
    "docs/product-roadmap/Rune-Scribe-Codex-Roadmap-Remediation-Amendment-v1.1.md"
)
BASE_OWNERSHIP_RELATIVE = Path("EULA.md")
FONT_LICENSE_RELATIVE = Path("RuneScrib/Resources/Fonts/OFL.txt")

BASE_RIGHTS_ID = "rights.norse.base"
FONT_RIGHTS_ID = "rights.norse.font.noto"
BASE_RIGHTS_DECLARATION_REFERENCE = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "NorseBaseThemeDescriptor.swift#rights.norse.base"
)
FONT_RIGHTS_DECLARATION_REFERENCE = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "NorseBaseThemeDescriptor.swift#rights.norse.font.noto"
)
BASE_RIGHTS_REFERENCE = "EULA.md#4-ownership-and-intellectual-property"
FONT_RIGHTS_REFERENCE = "RuneScrib/Resources/Fonts/OFL.txt"
BASELINE_APPROVAL_REFERENCE = (
    "docs/product-roadmap/"
    "Rune-Scribe-Codex-Roadmap-Remediation-Amendment-v1.1.md"
    "#rem-007-finalize-release-candidate-norse-provenance"
)

CONSTANT_PATTERN = re.compile(
    r'public static let (\w+) = resource\("([^"]+)", "([^"]+)"\)'
)
HANDLE_PATTERN = re.compile(r'^\s*"([^"]+)":\s*(\w+),\s*$', re.MULTILINE)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def media_type(file_extension: str) -> str:
    values = {
        "json": "application/json",
        "pdf": "application/pdf",
        "png": "image/png",
        "ttf": "font/ttf",
        "wav": "audio/wav",
    }
    try:
        return values[file_extension.lower()]
    except KeyError as error:
        raise ValueError(f"unsupported Norse shipping extension: {file_extension}") from error


def png_dimensions(path: Path) -> dict[str, int] | None:
    if path.suffix.lower() != ".png":
        return None
    header = path.read_bytes()[:24]
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"invalid PNG header: {path}")
    width, height = struct.unpack(">II", header[16:24])
    return {"height": height, "width": width}


def parse_catalog(root: Path) -> dict[str, tuple[str, str]]:
    source = (root / CATALOG_RELATIVE).read_text(encoding="utf-8")
    constants = {
        name: (resource_name, extension)
        for name, resource_name, extension in CONSTANT_PATTERN.findall(source)
    }
    handles: dict[str, tuple[str, str]] = {}
    for resource_id, constant_name in HANDLE_PATTERN.findall(source):
        if constant_name not in constants:
            raise ValueError(
                f"Norse catalog handle {resource_id} uses unknown constant {constant_name}"
            )
        handles[resource_id] = constants[constant_name]
    if len(handles) != 55:
        raise ValueError(f"Norse catalog must declare exactly 55 resource handles, got {len(handles)}")
    return handles


def production_files_by_name(root: Path) -> dict[str, Path]:
    resource_root = root / RESOURCE_ROOT_RELATIVE
    paths = [
        path
        for path in resource_root.rglob("*")
        if path.is_file()
        and not path.is_symlink()
        and "Source" not in path.relative_to(resource_root).parts
        and path not in {root / INTEGRITY_RELATIVE, root / PROVENANCE_RELATIVE}
    ]
    by_name: dict[str, Path] = {}
    collisions: set[str] = set()
    for path in paths:
        if path.name in by_name:
            collisions.add(path.name)
        else:
            by_name[path.name] = path
    if collisions:
        raise ValueError(
            "Norse shipping resources have colliding basenames: "
            + ", ".join(sorted(collisions))
        )
    return by_name


def semantic_role(resource_id: str, integrity_by_id: dict[str, dict[str, Any]]) -> str:
    if resource_id in integrity_by_id:
        return str(integrity_by_id[resource_id]["semanticRole"])
    if resource_id.startswith("resource.seal.norse.") and resource_id.endswith(".thumbnail"):
        return "seal.thumbnail"
    if resource_id == "resource.frame.norse.carved-knotwork.static-fallback":
        return "frame.static-fallback"
    if resource_id == "resource.crest.norse.forge-master.static-fallback":
        return "crest.static-fallback"
    raise ValueError(f"missing semantic role for {resource_id}")


def source_classification(resource_id: str, extension: str) -> str:
    if resource_id == "resource.font.norse.noto-sans-runic":
        return "bundled-font"
    if extension == "json":
        return "metadata"
    return "commissioned-or-original-project-art"


def accessibility_key(resource_id: str) -> str:
    if resource_id.startswith("resource.relic.norse."):
        value = resource_id.removeprefix("resource.")
        value = value.removesuffix(".art").removesuffix(".geometry")
        return f"{value}.accessibility-label"
    if resource_id.startswith("resource.share-fallback.norse."):
        value = resource_id.removeprefix("resource.share-fallback.")
        return f"relic.{value}.accessibility-label"
    if resource_id.startswith("resource.seal.norse."):
        value = resource_id.removeprefix("resource.")
        value = value.removesuffix(".vector").removesuffix(".thumbnail")
        return f"{value}.accessibility-label"
    if resource_id.startswith("resource.frame.norse."):
        value = resource_id.removeprefix("resource.")
        value = value.removesuffix(".vector").removesuffix(".static-fallback")
        return f"{value}.accessibility-label"
    if resource_id.startswith("resource.crest.norse."):
        value = resource_id.removeprefix("resource.")
        value = value.removesuffix(".vector").removesuffix(".static-fallback")
        return f"{value}.accessibility-label"
    if resource_id.startswith("resource.background.norse."):
        return "background.norse.accessibility-label"
    if resource_id.startswith("resource.script.norse.") or resource_id.startswith(
        "resource.font.norse."
    ):
        return "script.base-runes.accessibility-label"
    if resource_id.startswith("resource.codex-"):
        return "vault.norse.accessibility-label"
    return "codex.norse.accessibility-label"


def fallback_relationships(resource_id: str) -> tuple[list[str], list[str]]:
    has_fallbacks: dict[str, list[str]] = {
        "resource.background.norse.forge.static": [
            "resource.background.norse.high-contrast"
        ],
        "resource.crest.norse.forge-master.vector": [
            "resource.crest.norse.forge-master.static-fallback"
        ],
        "resource.frame.norse.carved-knotwork.vector": [
            "resource.frame.norse.carved-knotwork.static-fallback"
        ],
    }
    for name in (
        "ironbound-shield",
        "raven-medallion",
        "runestone.blackstone",
        "runestone.frozen",
        "runestone.weathered",
        "sealed-parchment",
    ):
        has_fallbacks[f"resource.relic.norse.{name}.art"] = [
            f"resource.share-fallback.norse.{name}"
        ]
    for name in (
        "echo-rune",
        "forge-flame",
        "forge-hammer",
        "knotwork",
        "longship",
        "raven",
    ):
        has_fallbacks[f"resource.seal.norse.{name}.vector"] = [
            f"resource.seal.norse.{name}.thumbnail"
        ]
    fallback_for: dict[str, list[str]] = {}
    for primary, fallbacks in has_fallbacks.items():
        for fallback in fallbacks:
            fallback_for.setdefault(fallback, []).append(primary)
    return sorted(has_fallbacks.get(resource_id, [])), sorted(fallback_for.get(resource_id, []))


def generator_inputs(root: Path) -> list[dict[str, str]]:
    inputs = [
        CATALOG_RELATIVE,
        DESCRIPTOR_RELATIVE,
        INTEGRITY_RELATIVE,
        BASELINE_APPROVAL_RELATIVE,
        BASE_OWNERSHIP_RELATIVE,
        FONT_LICENSE_RELATIVE,
    ]
    return [
        {"path": path.as_posix(), "sha256": sha256_file(root / path)}
        for path in inputs
    ]


def aggregate_sha256(resources: list[dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for resource in resources:
        digest.update(
            (
                f"{resource['resourceID']}\0{resource['normalizedProductionPath']}\0"
                f"{resource['byteCount']}\0{resource['sha256']}\n"
            ).encode("utf-8")
        )
    return digest.hexdigest()


def build_document(root: Path) -> dict[str, Any]:
    root = root.resolve()
    handles = parse_catalog(root)
    integrity = json.loads((root / INTEGRITY_RELATIVE).read_text(encoding="utf-8"))
    integrity_resources = integrity.get("resources")
    if not isinstance(integrity_resources, list) or len(integrity_resources) != 47:
        raise ValueError("Norse integrity manifest must contain exactly 47 resources")
    integrity_by_id = {
        str(item["resourceHandle"]): item for item in integrity_resources
    }
    if len(integrity_by_id) != 47:
        raise ValueError("Norse integrity manifest contains duplicate resource handles")

    files_by_name = production_files_by_name(root)
    resource_root = root / RESOURCE_ROOT_RELATIVE
    resources: list[dict[str, Any]] = []
    for resource_id in sorted(handles):
        resource_name, extension = handles[resource_id]
        basename = f"{resource_name}.{extension}"
        try:
            path = files_by_name[basename]
        except KeyError as error:
            raise ValueError(f"missing Norse shipping resource: {basename}") from error
        relative = path.relative_to(resource_root).as_posix()
        has_fallbacks, fallback_for = fallback_relationships(resource_id)
        rights_id = FONT_RIGHTS_ID if resource_id == "resource.font.norse.noto-sans-runic" else BASE_RIGHTS_ID
        resources.append(
            {
                "accessibilityDescriptionKey": accessibility_key(resource_id),
                "activeInV1": bool(
                    integrity_by_id.get(resource_id, {}).get("activeInV1", True)
                ),
                "byteCount": path.stat().st_size,
                "fallbackForResourceIDs": fallback_for,
                "fallbackResourceIDs": has_fallbacks,
                "generatorToolInputSHA256": None,
                "licenseOrOwnershipStatementReference": (
                    FONT_RIGHTS_REFERENCE if rights_id == FONT_RIGHTS_ID else BASE_RIGHTS_REFERENCE
                ),
                "mediaType": media_type(extension),
                "normalizedProductionPath": relative,
                "pixelDimensions": png_dimensions(path),
                "releaseStatus": "release-candidate",
                "requiredForActiveContent": bool(
                    integrity_by_id.get(resource_id, {}).get("requiredForActiveContent", True)
                ),
                "resourceID": resource_id,
                "rightsProvenanceID": rights_id,
                "semanticRole": semantic_role(resource_id, integrity_by_id),
                "sha256": sha256_file(path),
                "sourceClassification": source_classification(resource_id, extension),
            }
        )

    inputs = generator_inputs(root)
    input_digest = hashlib.sha256()
    for item in inputs:
        input_digest.update(f"{item['path']}\0{item['sha256']}\n".encode("utf-8"))
    return {
        "aggregateSHA256": aggregate_sha256(resources),
        "releaseCandidateBaselineApproval": {
            "authority": "Raven Forge remediation amendment",
            "publicDistributionAuthorized": False,
            "reference": BASELINE_APPROVAL_REFERENCE,
            "scope": "Exact current audited Resources/Production bytes",
            "status": "approved-as-release-candidate-baseline",
        },
        "generator": {
            "inputAggregateSHA256": input_digest.hexdigest(),
            "inputs": inputs,
            "path": GENERATOR_RELATIVE.as_posix(),
            "sha256": sha256_file(root / GENERATOR_RELATIVE),
        },
        "moduleID": "com.runescribe.module.theme.norse",
        "recordID": "production-asset-provenance.norse.v1",
        "releaseStatus": "release-candidate",
        "resourceCount": len(resources),
        "resources": resources,
        "rightsSources": [
            {
                "declarationReference": BASE_RIGHTS_DECLARATION_REFERENCE,
                "id": BASE_RIGHTS_ID,
                "statementReference": BASE_RIGHTS_REFERENCE,
            },
            {
                "declarationReference": FONT_RIGHTS_DECLARATION_REFERENCE,
                "id": FONT_RIGHTS_ID,
                "statementReference": FONT_RIGHTS_REFERENCE,
            },
        ],
        "schemaVersion": "1.0",
    }


def encoded_document(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    root = args.root.resolve()
    output = (args.output or (root / PROVENANCE_RELATIVE)).resolve()
    try:
        generated = encoded_document(build_document(root))
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"FAIL: unable to generate Norse production provenance: {error}", file=sys.stderr)
        return 1

    if args.check:
        try:
            existing = output.read_bytes()
        except OSError as error:
            print(f"FAIL: unable to read {output}: {error}", file=sys.stderr)
            return 1
        if existing != generated:
            print(f"FAIL: Norse production provenance differs: {output}", file=sys.stderr)
            return 1
        print(f"PASS: Norse production provenance is deterministic ({sha256_bytes(generated)})")
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(generated)
    print(f"WROTE: {output}")
    print(f"SHA256: {sha256_bytes(generated)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
