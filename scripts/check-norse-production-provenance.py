#!/usr/bin/env python3
"""Validate Norse release-candidate provenance against exact source bytes."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path, PurePosixPath
import sys
from types import ModuleType
from typing import Any


GENERATOR_RELATIVE = Path("scripts/generate-norse-production-provenance.py")


def load_generator(root: Path) -> ModuleType:
    path = root / GENERATOR_RELATIVE
    spec = importlib.util.spec_from_file_location("norse_provenance_generator", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def active_production_term_errors(root: Path, generator: ModuleType) -> list[str]:
    resource_root = root / generator.RESOURCE_ROOT_RELATIVE
    targets = [
        root / generator.INTEGRITY_RELATIVE,
        root / generator.PROVENANCE_RELATIVE,
    ]
    source_root = resource_root / "Source"
    if source_root.is_dir():
        targets.extend(path for path in source_root.rglob("*") if path.is_file())

    prohibited = [
        "place" + "holder",
        "shipping " + "candidate",
        "Shipping" + "Candidates",
        "unlock-sound-" + "candidate",
        "final conversion " + "still remains",
    ]
    errors: list[str] = []
    for path in sorted(set(targets)):
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            errors.append(f"cannot inspect active production source {path}: {error}")
            continue
        lowered = content.lower()
        for term in prohibited:
            if term.lower() in lowered:
                errors.append(
                    f"active production source contains obsolete terminology: "
                    f"{path.relative_to(root).as_posix()}"
                )
                break
    return errors


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
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        return [f"cannot derive expected provenance: {error}"]

    if set(document) != set(expected):
        errors.append("provenance root keys differ")
    for key in set(expected) - {"resources"}:
        if document.get(key) != expected[key]:
            errors.append(f"provenance {key} differs")

    resources = document.get("resources")
    if not isinstance(resources, list):
        errors.append("provenance resources must be an array")
        return errors + active_production_term_errors(root, generator)
    if len(resources) != 55:
        errors.append(f"provenance must contain exactly 55 resources, got {len(resources)}")

    actual_by_id: dict[str, dict[str, Any]] = {}
    for index, resource in enumerate(resources):
        if not isinstance(resource, dict):
            errors.append(f"provenance resource {index} must be an object")
            continue
        resource_id = resource.get("resourceID")
        if not isinstance(resource_id, str) or not resource_id:
            errors.append(f"provenance resource {index} has no resourceID")
            continue
        if resource_id in actual_by_id:
            errors.append(f"provenance resourceID is duplicated: {resource_id}")
            continue
        actual_by_id[resource_id] = resource

    expected_by_id = {item["resourceID"]: item for item in expected["resources"]}
    if set(actual_by_id) != set(expected_by_id):
        missing = sorted(set(expected_by_id) - set(actual_by_id))
        extra = sorted(set(actual_by_id) - set(expected_by_id))
        if missing:
            errors.append("provenance resource IDs missing: " + ", ".join(missing))
        if extra:
            errors.append("provenance resource IDs unexpected: " + ", ".join(extra))

    allowed_classifications = {
        "bundled-font",
        "commissioned-or-original-project-art",
        "generated-derivative",
        "metadata",
    }
    for resource_id in sorted(set(actual_by_id) & set(expected_by_id)):
        actual = actual_by_id[resource_id]
        expected_resource = expected_by_id[resource_id]
        if set(actual) != set(expected_resource):
            errors.append(f"{resource_id}: provenance fields differ")
        for field, expected_value in expected_resource.items():
            if actual.get(field) != expected_value:
                errors.append(f"{resource_id}: {field} differs")

        path_value = actual.get("normalizedProductionPath")
        if isinstance(path_value, str):
            normalized = PurePosixPath(path_value)
            if normalized.is_absolute() or ".." in normalized.parts or normalized.as_posix() != path_value:
                errors.append(f"{resource_id}: production path is not normalized")
            if resource_id == "resource.font.norse.noto-sans-runic":
                if path_value != "NotoSansRunic-Regular.ttf":
                    errors.append(f"{resource_id}: bundled font path differs")
            elif not path_value.startswith("Production/"):
                errors.append(f"{resource_id}: resource is outside Production")
        else:
            errors.append(f"{resource_id}: production path must be a string")

        if actual.get("releaseStatus") != "release-candidate":
            errors.append(f"{resource_id}: release status differs")
        if actual.get("sourceClassification") not in allowed_classifications:
            errors.append(f"{resource_id}: source classification is invalid")
        if not isinstance(actual.get("accessibilityDescriptionKey"), str) or not actual[
            "accessibilityDescriptionKey"
        ]:
            errors.append(f"{resource_id}: accessibility description key is missing")
        for relation_key in ("fallbackResourceIDs", "fallbackForResourceIDs"):
            relations = actual.get(relation_key)
            if not isinstance(relations, list) or not all(
                isinstance(value, str) and value in expected_by_id for value in relations
            ):
                errors.append(f"{resource_id}: {relation_key} is invalid")

    integrity_path = root / generator.INTEGRITY_RELATIVE
    integrity: dict[str, Any] = {}
    try:
        loaded_integrity = json.loads(integrity_path.read_text(encoding="utf-8"))
        if not isinstance(loaded_integrity, dict):
            raise TypeError("integrity root must be an object")
        integrity = loaded_integrity
        integrity_resources = integrity["resources"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        errors.append(f"cannot validate Norse integrity manifest: {error}")
        integrity_resources = []
    if integrity.get("generationScope") != (
        "Exact release-candidate Production resources, regenerated from the checked-in "
        "paths and bytes. Public distribution is not authorized."
    ):
        errors.append("Norse integrity manifest release-candidate scope differs")
    if not isinstance(integrity_resources, list) or len(integrity_resources) != 47:
        errors.append("Norse integrity manifest must contain exactly 47 resources")
    else:
        for item in integrity_resources:
            if not isinstance(item, dict) or not isinstance(item.get("resourceHandle"), str):
                errors.append("Norse integrity manifest contains an invalid resource")
                continue
            resource_id = item["resourceHandle"]
            provenance = expected_by_id.get(resource_id)
            if provenance is None:
                errors.append(f"Norse integrity manifest has unknown handle: {resource_id}")
                continue
            comparisons = {
                "path": "normalizedProductionPath",
                "semanticRole": "semanticRole",
                "mediaType": "mediaType",
                "byteLength": "byteCount",
                "sha256": "sha256",
                "requiredForActiveContent": "requiredForActiveContent",
                "activeInV1": "activeInV1",
                "dimensions": "pixelDimensions",
            }
            for integrity_key, provenance_key in comparisons.items():
                if item.get(integrity_key) != provenance.get(provenance_key):
                    errors.append(
                        f"{resource_id}: integrity {integrity_key} differs from provenance"
                    )

    descriptor = (root / generator.DESCRIPTOR_RELATIVE).read_text(encoding="utf-8")
    for rights_id in (generator.BASE_RIGHTS_ID, generator.FONT_RIGHTS_ID):
        if rights_id not in descriptor:
            errors.append(f"descriptor does not declare rights source {rights_id}")

    errors.extend(active_production_term_errors(root, generator))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--document", type=Path)
    args = parser.parse_args()

    root = args.root.resolve()
    generator = load_generator(root)
    document_path = (args.document or (root / generator.PROVENANCE_RELATIVE)).resolve()
    try:
        document = json.loads(document_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"FAIL: unable to read Norse production provenance: {error}", file=sys.stderr)
        return 1
    if not isinstance(document, dict):
        print("FAIL: Norse production provenance root must be an object", file=sys.stderr)
        return 1

    errors = validate_document(root, document, generator)
    if errors:
        for error in sorted(set(errors)):
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    encoded = generator.encoded_document(document)
    print(
        f"PASS: 55 exact Norse release-candidate resources "
        f"({generator.sha256_bytes(encoded)})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
