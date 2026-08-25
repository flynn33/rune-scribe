#!/usr/bin/env python3
"""Validate Norse v2 provenance against current catalog, integrity, and bytes."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path, PurePosixPath
import sys
from types import ModuleType
from typing import Any


GENERATOR_RELATIVE = Path("scripts/generate-norse-production-provenance.py")
OBSOLETE_CURRENT_IDENTITIES = (
    "relic.norse.runestone.weathered",
    "relic.norse.raven-medallion",
    "relic.norse.ironbound-shield",
    "relic.norse.sealed-parchment",
    "relic.norse.runestone.blackstone",
    "relic.norse.runestone.frozen",
    "seal.norse.knotwork",
    "seal.norse.forge-flame",
    "seal.norse.raven",
    "seal.norse.longship",
    "seal.norse.forge-hammer",
    "seal.norse.echo-rune",
    "crest.norse.forge-master",
    "background.norse.forge-v1",
)


def load_generator(root: Path) -> ModuleType:
    path = root / GENERATOR_RELATIVE
    spec = importlib.util.spec_from_file_location("norse_v2_provenance_generator", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_document(
    root: Path,
    document: dict[str, Any],
    generator: ModuleType | None = None,
) -> list[str]:
    root = root.resolve()
    generator = generator or load_generator(root)
    errors: list[str] = []
    try:
        expected = generator.build_document(root)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        return [f"cannot derive expected provenance: {error}"]
    if document != expected:
        errors.append("provenance differs from deterministic current-byte derivation")

    if document.get("schemaVersion") != "2.0":
        errors.append("provenance schema version differs")
    if document.get("recordID") != "production-asset-provenance.norse.v2":
        errors.append("provenance record identity differs")
    if document.get("resourceCount") != 70:
        errors.append("provenance resource count must be 70")
    authority = document.get("authority")
    if not isinstance(authority, dict) or authority.get(
        "publicDistributionAuthorized"
    ) is not False:
        errors.append("provenance must explicitly deny public distribution")

    resources = document.get("resources")
    if not isinstance(resources, list) or len(resources) != 70:
        errors.append("provenance resources must contain 70 records")
        return errors
    by_id: dict[str, dict[str, Any]] = {}
    for index, resource in enumerate(resources):
        if not isinstance(resource, dict):
            errors.append(f"resource {index} must be an object")
            continue
        resource_id = resource.get("resourceID")
        if not isinstance(resource_id, str) or not resource_id:
            errors.append(f"resource {index} has no identity")
            continue
        if resource_id in by_id:
            errors.append(f"duplicate resource identity: {resource_id}")
        by_id[resource_id] = resource
    if len(by_id) != 70:
        errors.append("provenance resource identities are not unique")

    for resource_id, resource in by_id.items():
        path_value = resource.get("normalizedProductionPath")
        if not isinstance(path_value, str):
            errors.append(f"{resource_id}: resource path is missing")
        else:
            normalized = PurePosixPath(path_value)
            if (
                normalized.is_absolute()
                or ".." in normalized.parts
                or normalized.as_posix() != path_value
            ):
                errors.append(f"{resource_id}: resource path is not normalized")
        if resource.get("activeInCurrentCatalog") is not True:
            errors.append(f"{resource_id}: resource is not current")
        if resource.get("qualificationStatus") != "local-qualification-candidate":
            errors.append(f"{resource_id}: qualification status differs")
        if not isinstance(resource.get("accessibilityDescriptionKey"), str) or not resource[
            "accessibilityDescriptionKey"
        ]:
            errors.append(f"{resource_id}: accessibility key is missing")
        if not isinstance(resource.get("sha256"), str) or len(resource["sha256"]) != 64:
            errors.append(f"{resource_id}: digest is invalid")
        for relationship in ("fallbackResourceIDs", "fallbackForResourceIDs"):
            values = resource.get(relationship)
            if not isinstance(values, list) or not all(
                isinstance(value, str) and value in by_id for value in values
            ):
                errors.append(f"{resource_id}: {relationship} is invalid")

    serialized = json.dumps(document, sort_keys=True)
    for obsolete in OBSOLETE_CURRENT_IDENTITIES:
        position = serialized.find(obsolete)
        while position >= 0:
            end = position + len(obsolete)
            if end == len(serialized) or serialized[end] in '."/':
                break
            position = serialized.find(obsolete, position + 1)
        if position >= 0:
            errors.append(f"obsolete current Norse identity remains: {obsolete}")

    try:
        integrity = generator.read_json(root / generator.INTEGRITY_RELATIVE)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        errors.append(f"cannot read v2 integrity manifest: {error}")
        return errors
    integrity_resources = integrity.get("resources")
    if not isinstance(integrity_resources, list) or len(integrity_resources) != 70:
        errors.append("v2 integrity manifest must contain 70 resources")
    else:
        integrity_by_id = {
            item.get("resourceHandle"): item
            for item in integrity_resources
            if isinstance(item, dict)
        }
        if set(integrity_by_id) != set(by_id):
            errors.append("provenance and integrity identities differ")
        for resource_id in set(integrity_by_id) & set(by_id):
            integrity_resource = integrity_by_id[resource_id]
            provenance_resource = by_id[resource_id]
            pairs = {
                "path": "normalizedProductionPath",
                "semanticRole": "semanticRole",
                "mediaType": "mediaType",
                "byteLength": "byteCount",
                "sha256": "sha256",
                "requiredForActiveContent": "requiredForActiveContent",
                "activeInCurrentCatalog": "activeInCurrentCatalog",
                "dimensions": "pixelDimensions",
            }
            for integrity_key, provenance_key in pairs.items():
                if integrity_resource.get(integrity_key) != provenance_resource.get(
                    provenance_key
                ):
                    errors.append(
                        f"{resource_id}: {integrity_key} differs from provenance"
                    )
    return sorted(set(errors))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--document", type=Path)
    arguments = parser.parse_args(sys.argv[1:] if argv is None else argv)
    root = arguments.root.resolve()
    generator = load_generator(root)
    document_path = (
        arguments.document or (root / generator.PROVENANCE_RELATIVE)
    ).resolve()
    try:
        document = json.loads(document_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"FAIL: unable to read Norse v2 provenance: {error}", file=sys.stderr)
        return 1
    if not isinstance(document, dict):
        print("FAIL: Norse v2 provenance root must be an object", file=sys.stderr)
        return 1
    errors = validate_document(root, document, generator)
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        f"PASS: 70 exact Norse v2 resources "
        f"({generator.sha256_bytes(generator.encoded_document(document))})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
