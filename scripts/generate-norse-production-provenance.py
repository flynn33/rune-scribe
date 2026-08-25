#!/usr/bin/env python3
"""Generate deterministic provenance for the exact Norse v2 resource catalog."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
from typing import Any


MODULE_ID = "com.runescribe.module.theme.norse"
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
    / "Production/Metadata/Norse-Resource-Integrity-Manifest-v2.0.json"
)
PROVENANCE_RELATIVE = (
    RESOURCE_ROOT_RELATIVE
    / "Production/Metadata/Norse-Production-Asset-Provenance-v2.0.json"
)
DESCRIPTOR_RELATIVE = MODULE_RELATIVE / "NorseBaseThemeDescriptor.swift"
DERIVATION_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/generated/norse/Metadata/"
    "Norse-Production-Asset-Derivation-v4.0.json"
)
SOURCE_MASTERS_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/source-masters/norse"
)
GENERATOR_RELATIVE = Path("scripts/generate-norse-production-provenance.py")
BASE_OWNERSHIP_RELATIVE = Path("EULA.md")
FONT_LICENSE_RELATIVE = Path("RuneScrib/Resources/Fonts/OFL.txt")

BASE_RIGHTS_ID = "rights.norse.base"
FONT_RIGHTS_ID = "rights.norse.font.noto"
BASE_RIGHTS_REFERENCE = "EULA.md#4-ownership-and-intellectual-property"
FONT_RIGHTS_REFERENCE = "RuneScrib/Resources/Fonts/OFL.txt"
CATALOG_PATTERN = re.compile(
    r'^\s*"([^"]+)": resource\("([^"]+)", "([^"]+)"\),\s*$',
    re.MULTILINE,
)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def parse_catalog(root: Path) -> dict[str, tuple[str, str]]:
    source = (root / CATALOG_RELATIVE).read_text(encoding="utf-8")
    values = {
        handle: (name, extension)
        for handle, name, extension in CATALOG_PATTERN.findall(source)
    }
    if len(values) != 70:
        raise ValueError(
            f"Norse v2 catalog must declare exactly 70 handles, got {len(values)}"
        )
    return values


def normalized_resource_path(resource_root: Path, value: str) -> Path:
    relative = PurePosixPath(value)
    if relative.is_absolute() or ".." in relative.parts or relative.as_posix() != value:
        raise ValueError(f"resource path is not normalized: {value}")
    path = resource_root / Path(*relative.parts)
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"resource is not a regular file: {value}")
    return path


def validate_integrity_resource(
    resource_root: Path,
    resource: dict[str, Any],
) -> Path:
    required = {
        "resourceHandle",
        "path",
        "semanticRole",
        "mediaType",
        "byteLength",
        "sha256",
        "requiredForActiveContent",
        "activeInCurrentCatalog",
    }
    if not required.issubset(resource):
        raise ValueError("integrity resource fields are incomplete")
    path = normalized_resource_path(resource_root, str(resource["path"]))
    if path.stat().st_size != resource["byteLength"]:
        raise ValueError(f"resource byte count differs: {resource['resourceHandle']}")
    if sha256_file(path) != resource["sha256"]:
        raise ValueError(f"resource digest differs: {resource['resourceHandle']}")
    if resource["activeInCurrentCatalog"] is not True:
        raise ValueError(f"resource is not active: {resource['resourceHandle']}")
    return path


def accessibility_key(resource_id: str) -> str:
    if resource_id.startswith("resource.relic.norse."):
        slug = resource_id.split(".")[3]
        return f"relic.norse.{slug}.accessibility-label"
    if resource_id.startswith("resource.seal.norse."):
        slug = resource_id.split(".")[3]
        return f"seal.norse.{slug}.accessibility-label"
    if resource_id.startswith("resource.frame.norse."):
        return "frame.norse.carved-knotwork.accessibility-label"
    if resource_id.startswith("resource.crest.norse."):
        return "crest.norse.raven-mastery.accessibility-label"
    if resource_id.startswith("resource.background.norse."):
        return "background.norse.cold-sea-hall.accessibility-label"
    if resource_id.startswith("resource.codex-card.norse."):
        return "vault.norse.accessibility-label"
    if resource_id.startswith(("resource.script.norse.", "resource.font.norse.")):
        return "script.base-runes.accessibility-label"
    return "codex.norse.accessibility-label"


def fallback_map() -> dict[str, list[str]]:
    values: dict[str, list[str]] = {}
    for slug in ("runestone-tablet", "dragonwood-plaque", "stormforged-stele"):
        primary = f"resource.relic.norse.{slug}.master"
        values[primary] = [
            f"resource.relic.norse.{slug}.thumbnail",
            f"resource.relic.norse.{slug}.high-contrast",
            f"resource.relic.norse.{slug}.static-share-fallback",
        ]
    for slug in ("valknut", "ravenshield", "mjolnir", "wolkin", "yggdrasil", "berserk"):
        values[f"resource.seal.norse.{slug}.vector-master"] = [
            f"resource.seal.norse.{slug}.monochrome-fallback",
            f"resource.seal.norse.{slug}.thumbnail",
        ]
    values["resource.frame.norse.carved-knotwork.vector-master"] = [
        "resource.frame.norse.carved-knotwork.static-fallback"
    ]
    values["resource.crest.norse.raven-mastery.vector-master"] = [
        "resource.crest.norse.raven-mastery.static-fallback",
        "resource.crest.norse.raven-mastery.thumbnail",
    ]
    values["resource.background.norse.cold-sea-hall.standard"] = [
        "resource.background.norse.cold-sea-hall.reduce-motion",
        "resource.background.norse.cold-sea-hall.high-contrast",
        "resource.background.norse.cold-sea-hall.macos-wide-crop",
    ]
    values["resource.codex-card.norse.owned"] = [
        "resource.codex-card.norse.locked",
        "resource.codex-card.norse.encountered",
        "resource.codex-card.norse.selected",
        "resource.codex-card.norse.unavailable",
    ]
    values["resource.script.norse.specimen.standard"] = [
        "resource.script.norse.specimen.high-contrast",
        "resource.script.norse.specimen.static-fallback",
    ]
    return values


def source_classification(media_type: str, resource_id: str) -> str:
    if resource_id == "resource.font.norse.noto-sans-runic":
        return "bundled-font"
    if media_type in {"image/png", "application/pdf"}:
        return "generated-derivative"
    if media_type == "application/json":
        return "metadata"
    return "original-project-resource"


def generator_inputs(root: Path) -> list[dict[str, str]]:
    values = [
        CATALOG_RELATIVE,
        DESCRIPTOR_RELATIVE,
        INTEGRITY_RELATIVE,
        DERIVATION_RELATIVE,
        BASE_OWNERSHIP_RELATIVE,
        FONT_LICENSE_RELATIVE,
    ]
    source_root = root / SOURCE_MASTERS_RELATIVE
    values.extend(
        path.relative_to(root)
        for path in sorted(source_root.rglob("*"))
        if path.is_file() and not path.is_symlink()
    )
    return [
        {"path": value.as_posix(), "sha256": sha256_file(root / value)}
        for value in values
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
    catalog = parse_catalog(root)
    integrity = read_json(root / INTEGRITY_RELATIVE)
    integrity_resources = integrity.get("resources")
    if integrity.get("schemaVersion") != "2.0" or not isinstance(
        integrity_resources, list
    ):
        raise ValueError("Norse v2 integrity manifest is invalid")
    by_id = {
        str(item.get("resourceHandle")): item
        for item in integrity_resources
        if isinstance(item, dict)
    }
    if len(integrity_resources) != 70 or len(by_id) != 70:
        raise ValueError("Norse v2 integrity manifest must contain 70 unique resources")
    if set(by_id) != set(catalog):
        raise ValueError("Norse v2 catalog and integrity identities differ")

    resource_root = root / RESOURCE_ROOT_RELATIVE
    fallbacks = fallback_map()
    fallback_for: dict[str, list[str]] = {}
    for primary, values in fallbacks.items():
        for value in values:
            fallback_for.setdefault(value, []).append(primary)

    derivation_sha = sha256_file(root / DERIVATION_RELATIVE)
    resources: list[dict[str, Any]] = []
    for resource_id in sorted(by_id):
        integrity_resource = by_id[resource_id]
        path = validate_integrity_resource(resource_root, integrity_resource)
        media_type = str(integrity_resource["mediaType"])
        classification = source_classification(media_type, resource_id)
        rights_id = (
            FONT_RIGHTS_ID
            if resource_id == "resource.font.norse.noto-sans-runic"
            else BASE_RIGHTS_ID
        )
        resources.append(
            {
                "accessibilityDescriptionKey": accessibility_key(resource_id),
                "activeInCurrentCatalog": True,
                "byteCount": path.stat().st_size,
                "derivationRecordSHA256": (
                    derivation_sha if classification == "generated-derivative" else None
                ),
                "fallbackForResourceIDs": sorted(fallback_for.get(resource_id, [])),
                "fallbackResourceIDs": sorted(fallbacks.get(resource_id, [])),
                "licenseOrOwnershipStatementReference": (
                    FONT_RIGHTS_REFERENCE
                    if rights_id == FONT_RIGHTS_ID
                    else BASE_RIGHTS_REFERENCE
                ),
                "mediaType": media_type,
                "normalizedProductionPath": str(integrity_resource["path"]),
                "pixelDimensions": integrity_resource.get("dimensions"),
                "qualificationStatus": "local-qualification-candidate",
                "requiredForActiveContent": bool(
                    integrity_resource["requiredForActiveContent"]
                ),
                "resourceID": resource_id,
                "rightsProvenanceID": rights_id,
                "semanticRole": str(integrity_resource["semanticRole"]),
                "sha256": str(integrity_resource["sha256"]),
                "sourceClassification": classification,
            }
        )

    inputs = generator_inputs(root)
    input_digest = hashlib.sha256()
    for value in inputs:
        input_digest.update(
            f"{value['path']}\0{value['sha256']}\n".encode("utf-8")
        )
    return {
        "aggregateSHA256": aggregate_sha256(resources),
        "authority": {
            "package": "Rune-Scribe-Theme-Fidelity-Remediation-v4.0",
            "publicDistributionAuthorized": False,
            "scope": "Norse v2 local implementation and qualification only",
        },
        "generator": {
            "inputAggregateSHA256": input_digest.hexdigest(),
            "inputs": inputs,
            "path": GENERATOR_RELATIVE.as_posix(),
            "sha256": sha256_file(root / GENERATOR_RELATIVE),
        },
        "moduleID": MODULE_ID,
        "recordID": "production-asset-provenance.norse.v2",
        "resourceCount": len(resources),
        "resources": resources,
        "rightsSources": [
            {
                "id": BASE_RIGHTS_ID,
                "statementReference": BASE_RIGHTS_REFERENCE,
            },
            {
                "id": FONT_RIGHTS_ID,
                "statementReference": FONT_RIGHTS_REFERENCE,
            },
        ],
        "schemaVersion": "2.0",
    }


def encoded_document(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args(sys.argv[1:] if argv is None else argv)
    root = arguments.root.resolve()
    output = (arguments.output or (root / PROVENANCE_RELATIVE)).resolve()
    try:
        generated = encoded_document(build_document(root))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"FAIL: unable to generate Norse v2 provenance: {error}", file=sys.stderr)
        return 1
    if arguments.check:
        try:
            existing = output.read_bytes()
        except OSError as error:
            print(f"FAIL: unable to read {output}: {error}", file=sys.stderr)
            return 1
        if existing != generated:
            print(f"FAIL: Norse v2 provenance differs: {output}", file=sys.stderr)
            return 1
        print(f"PASS: deterministic Norse v2 provenance ({sha256_bytes(generated)})")
        return 0
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(generated)
    print(f"WROTE: {output}")
    print(f"SHA256: {sha256_bytes(generated)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
