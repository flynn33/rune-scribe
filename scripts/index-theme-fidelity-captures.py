#!/usr/bin/env python3
"""Validate and index the complete Theme fidelity capture matrix."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterable

try:
    from scripts.theme_fidelity_destination_policy import (
        DestinationPolicyError,
        validate_selection,
    )
except ModuleNotFoundError:
    from theme_fidelity_destination_policy import (  # type: ignore[no-redef]
        DestinationPolicyError,
        validate_selection,
    )

try:
    import numpy as np
    from PIL import Image, ImageFilter, ImageStat, UnidentifiedImageError
except ImportError as import_error:  # pragma: no cover - incomplete host only.
    np = None
    Image = None
    ImageFilter = None
    ImageStat = None
    UnidentifiedImageError = OSError
    DEPENDENCY_ERROR = import_error
else:
    DEPENDENCY_ERROR = None


SCHEMA_VERSION = "1.0"
MATRIX_SHA256 = "bf49d24a1ac9ef881c25504a17ceeea4befe9d685fe46fd469f99b43f4ae833c"
DEFAULT_AUTHORITY_MANIFEST = Path(
    "docs/verification/theme-fidelity-v4/authority/asset-manifest.json"
)
EXPECTED_TEST_IDENTIFIER = "ThemeFidelityMatrixTests/testCaptureThemeFidelityMatrix()"
VIEWPORT_ELEMENT_ID = "theme-fidelity.viewport"
EXPECTED_THEMES = {
    "Norse": ("theme.norse.base", "codex.norse"),
    "Moonleaf": ("theme.moonleaf.production", "codex.moonleaf"),
    "Sunspire": ("theme.sunspire.production", "codex.sunspire"),
    "Wildwood": ("theme.wildwood.production", "codex.wildwood"),
    "Gloamthorn": ("theme.gloamthorn.production", "codex.gloamthorn"),
}
THEME_RESOURCE_MANIFESTS = {
    "Norse": {
        "path": Path(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
            "Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v2.0.json"
        ),
        "collectionKey": "resources",
        "resourceIDKey": "resourceHandle",
        "identity": {
            "schemaVersion": "2.0",
            "manifestID": "norse-resource-integrity.v2",
            "moduleID": "com.runescribe.module.theme.norse",
        },
    },
    "Moonleaf": {
        "path": Path(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/"
            "Resources/Production/Resource-Integrity-Manifest-v1.0.json"
        ),
        "collectionKey": "files",
        "resourceIDKey": "resourceID",
        "identity": {
            "schemaVersion": "1.0",
            "codexID": "codex.moonleaf",
            "moduleID": "com.runescribe.module.theme.moonleaf",
        },
    },
    "Sunspire": {
        "path": Path(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeSunspireModule/"
            "Resources/Production/Resource-Integrity-Manifest-v1.0.json"
        ),
        "collectionKey": "files",
        "resourceIDKey": "resourceID",
        "identity": {
            "schemaVersion": "1.0",
            "codexID": "codex.sunspire",
            "moduleID": "com.runescribe.module.theme.sunspire",
        },
    },
    "Wildwood": {
        "path": Path(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeWildwoodModule/"
            "Resources/Production/Resource-Integrity-Manifest-v1.0.json"
        ),
        "collectionKey": "files",
        "resourceIDKey": "resourceID",
        "identity": {
            "schemaVersion": "1.0",
            "codexID": "codex.wildwood",
            "moduleID": "com.runescribe.module.theme.wildwood",
        },
    },
    "Gloamthorn": {
        "path": Path(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeGloamthornModule/"
            "Resources/Production/Resource-Integrity-Manifest-v1.0.json"
        ),
        "collectionKey": "files",
        "resourceIDKey": "resourceID",
        "identity": {
            "schemaVersion": "1.0",
            "codexID": "codex.gloamthorn",
            "moduleID": "com.runescribe.module.theme.gloamthorn",
        },
    },
}
DESTINATION_SLUGS = {
    "iPhone portrait": "iphone-portrait",
    "iPad portrait": "ipad-portrait",
    "macOS standard": "macos-standard",
    "macOS resized": "macos-resized",
}
MATERIAL_GROUPS = (
    ("workspace-empty", "compose-short", "compose-long", "inscription-preview"),
    ("received-cipher", "share-builder", "static-share"),
    ("settings-codex-card", "settings-defaults-preview"),
    ("vault-locked", "vault-progress", "vault-encountered", "vault-owned", "vault-selected"),
    ("relic-picker", "seal-picker", "mastery"),
    ("high-contrast", "reduce-motion", "large-text"),
)
REQUIRED_RECORD_KEYS = {
    "schemaVersion",
    "stateSeed",
    "stateSeedSHA256",
    "contentSeed",
    "stateID",
    "themeName",
    "themeID",
    "codexID",
    "relicID",
    "sealID",
    "frameID",
    "surface",
    "destination",
    "pointWidth",
    "pointHeight",
    "scale",
    "pixelWidth",
    "pixelHeight",
    "visualPlanRevision",
    "pngSHA256",
    "byteCount",
}
EVIDENCE_RECORD_KEYS = {
    "elementFrames",
    "renderedResourceBindings",
    "renderedResourceIDs",
    "safePreviewEvidence",
    "viewportAssertions",
}
BUNDLE_DESTINATIONS = {
    "iphone": {"iphone-portrait"},
    "ipad": {"ipad-portrait"},
    "macos": {"macos-standard", "macos-resized"},
}
EXPECTED_BUNDLE_ATTACHMENT_COUNTS = {"iphone": 200, "ipad": 200, "macos": 400}
FINAL_COMPARISON_KEYS = {
    "capture",
    "candidateSHA256",
    "comparisonID",
    "regionPolicy",
    "result",
    "report",
    "reportSHA256",
    "heatmap",
    "heatmapSHA256",
}
COMPARISON_THRESHOLDS = {
    "luminanceSSIM": 0.92,
    "edgeSSIM": 0.94,
    "focalSSIM": 0.95,
    "medianDeltaE": 4.0,
    "p95DeltaE": 12.0,
    "maxFractionDeltaEAbove20": 0.02,
}
COMPARISON_CHECK_KEYS = {
    "luminanceSSIM",
    "edgeSSIM",
    "focalSSIM",
    "medianDeltaE",
    "p95DeltaE",
    "fractionDeltaEAbove20",
}
RESPONSIVE_POLICY = "responsive-regions-v1"
PLATFORM_MASK_ROLE = "platform-controlled-mask"
CONTENT_SEED_KEYS = {
    "fixtureID",
    "fixtureVersion",
    "surface",
    "plaintext",
    "glyphTokens",
    "sender",
    "cipher",
    "timestamp",
    "selectedResources",
    "progression",
    "locale",
    "calendar",
    "timeZone",
    "accessibility",
}
CONTENT_SEED_NESTED_KEYS = {
    "sender": {"name"},
    "cipher": {"id", "name"},
    "selectedResources": {"codexID", "relicID", "sealID", "frameID"},
    "progression": {
        "ownershipState",
        "achievementID",
        "completedRuleCount",
        "requiredRuleCount",
    },
    "accessibility": {"increasedContrast", "reduceMotion", "dynamicTypeSize"},
}
CONTENT_SEED_TIMESTAMP = "2023-11-14T22:13:20Z"
LEGACY_PLAN_KEYS = {"id", "capture", "reference", "mask", "focalRegion"}
LEGACY_PLAN_REQUIRED_KEYS = {"id", "capture", "reference", "focalRegion"}
RESPONSIVE_PLAN_KEYS = {
    "id",
    "capture",
    "policy",
    "stateSeedSHA256",
    "regions",
    "layoutAssertions",
}
RESPONSIVE_REGION_KEYS = {
    "id",
    "reference",
    "sourceCrop",
    "sourceCropSHA256",
    "candidateElementID",
    "mask",
    "thresholds",
}
RESPONSIVE_LAYOUT_KEYS = {
    "requiredElementIDs",
    "withinViewportElementIDs",
    "requireNoClippedElements",
}
RESPONSIVE_REPORT_KEYS = {
    "schemaVersion",
    "comparisonPolicy",
    "result",
    "comparisonID",
    "manifest",
    "manifestSHA256",
    "candidate",
    "candidateSHA256",
    "candidateDimensions",
    "captureRecord",
    "captureRecordSHA256",
    "stateSeedSHA256",
    "elementFrameAttestation",
    "layoutAssertions",
    "regionCount",
    "passingRegionCount",
    "regions",
    "metrics",
    "thresholds",
    "checks",
    "aggregateChecks",
    "heatmap",
    "heatmapAtlas",
}
RESPONSIVE_REPORT_REGION_KEYS = {
    "id",
    "result",
    "reference",
    "referenceSHA256",
    "referenceDimensions",
    "sourceCrop",
    "sourceCropSHA256",
    "sourceDimensions",
    "candidateElementID",
    "candidateElementFrame",
    "candidatePixelCrop",
    "candidateRegionDimensions",
    "candidateNormalizedToSource",
    "aspectRatioPreserved",
    "approvedMask",
    "approvedMaskSHA256",
    "scoredPixelFraction",
    "focalRegion",
    "metrics",
    "thresholds",
    "checks",
    "heatmapAtlasFrame",
}
LEGACY_REPORT_KEYS = {
    "schemaVersion",
    "result",
    "comparisonID",
    "manifest",
    "manifestSHA256",
    "reference",
    "referenceSHA256",
    "candidate",
    "candidateSHA256",
    "referenceDimensions",
    "candidateDimensions",
    "candidateNormalizedToReference",
    "approvedMask",
    "scoredPixelFraction",
    "focalRegion",
    "metrics",
    "thresholds",
    "checks",
    "heatmap",
    "captureRecord",
    "captureRecordSHA256",
    "stateSeedSHA256",
}


class IndexError(ValueError):
    pass


_COMPARATOR_MODULE: Any = None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_sha256(document: Any) -> str:
    try:
        encoded = json.dumps(
            document,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise IndexError("document is not canonical JSON data") from error
    return hashlib.sha256(encoded).hexdigest()


def write_json(path: Path, document: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise IndexError(f"unable to read JSON {path}: {error}") from error


def load_theme_resource_manifests(
    root: Path,
) -> dict[tuple[str, str], frozenset[str]]:
    """Load the fixed production integrity manifests and index their resource IDs."""
    root = root.resolve()
    if set(THEME_RESOURCE_MANIFESTS) != set(EXPECTED_THEMES):
        raise IndexError("theme production integrity manifest map is incomplete")
    allowed_by_theme_codex: dict[tuple[str, str], frozenset[str]] = {}
    for theme_name, specification in THEME_RESOURCE_MANIFESTS.items():
        manifest_path = (root / specification["path"]).resolve()
        if not is_within(manifest_path, root):
            raise IndexError(
                f"{theme_name} production integrity manifest must be inside the repository root"
            )
        document = load_json(manifest_path)
        expected_identity = specification["identity"]
        if not isinstance(document, dict) or any(
            document.get(key) != value for key, value in expected_identity.items()
        ):
            raise IndexError(
                f"{theme_name} production integrity manifest schema is invalid"
            )
        collection_key = specification["collectionKey"]
        resource_id_key = specification["resourceIDKey"]
        entries = document.get(collection_key)
        if not isinstance(entries, list) or not entries:
            raise IndexError(
                f"{theme_name} production integrity manifest {collection_key} are invalid"
            )
        resource_ids: list[str] = []
        for ordinal, entry in enumerate(entries):
            if not isinstance(entry, dict):
                raise IndexError(
                    f"{theme_name} production integrity manifest entry {ordinal} is invalid"
                )
            resource_id = entry.get(resource_id_key)
            if (
                not isinstance(resource_id, str)
                or not resource_id
                or resource_id != resource_id.strip()
            ):
                raise IndexError(
                    f"{theme_name} production integrity manifest entry {ordinal} "
                    f"has an invalid {resource_id_key}"
                )
            resource_ids.append(resource_id)
        duplicates = sorted(
            resource_id
            for resource_id in set(resource_ids)
            if resource_ids.count(resource_id) > 1
        )
        if duplicates:
            raise IndexError(
                f"{theme_name} production integrity manifest repeats resource IDs: "
                + ", ".join(duplicates)
            )
        _, codex_id = EXPECTED_THEMES[theme_name]
        key = (theme_name, codex_id)
        if key in allowed_by_theme_codex:
            raise IndexError(f"duplicate theme/codex resource manifest mapping: {key}")
        allowed_by_theme_codex[key] = frozenset(resource_ids)
    return allowed_by_theme_codex


def load_comparator() -> Any:
    global _COMPARATOR_MODULE
    if _COMPARATOR_MODULE is not None:
        return _COMPARATOR_MODULE
    path = Path(__file__).resolve().parent / "compare-theme-captures.py"
    spec = importlib.util.spec_from_file_location("theme_fidelity_comparator", path)
    if spec is None or spec.loader is None:
        raise IndexError(f"unable to load comparison implementation: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    _COMPARATOR_MODULE = module
    return module


def load_matrix(path: Path) -> dict[str, Any]:
    if sha256_file(path) != MATRIX_SHA256:
        raise IndexError("Golden Screenshot Matrix bytes differ from the controlling matrix")
    document = load_json(path)
    if not isinstance(document, dict) or document.get("schemaVersion") != "1.0":
        raise IndexError("Golden Screenshot Matrix schema is invalid")
    if document.get("destinations") != list(DESTINATION_SLUGS):
        raise IndexError("Golden Screenshot Matrix destinations differ from the required order")
    themes = document.get("themes")
    if not isinstance(themes, dict) or list(themes) != list(EXPECTED_THEMES):
        raise IndexError("Golden Screenshot Matrix themes differ from the required order")
    surface_lists = []
    for theme_name, definition in themes.items():
        if not isinstance(definition, dict) or set(definition) != {"requiredSurfaces"}:
            raise IndexError(f"matrix definition is invalid for {theme_name}")
        surfaces = definition["requiredSurfaces"]
        if (
            not isinstance(surfaces, list)
            or len(surfaces) != 20
            or len(set(surfaces)) != 20
            or not all(isinstance(surface, str) for surface in surfaces)
        ):
            raise IndexError(f"matrix surface list is invalid for {theme_name}")
        surface_lists.append(surfaces)
    if any(surfaces != surface_lists[0] for surfaces in surface_lists[1:]):
        raise IndexError("matrix surface order differs across themes")
    return document


def expected_entries(matrix: dict[str, Any]) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    for theme_name, definition in matrix["themes"].items():
        theme_slug = theme_name.lower()
        for surface in definition["requiredSurfaces"]:
            for destination in matrix["destinations"]:
                destination_slug = DESTINATION_SLUGS[destination]
                stem = f"{theme_slug}--{surface}--{destination_slug}"
                entries.append(
                    {
                        "themeName": theme_name,
                        "themeSlug": theme_slug,
                        "surface": surface,
                        "destination": destination,
                        "destinationSlug": destination_slug,
                        "stem": stem,
                        "png": f"{stem}.png",
                        "record": f"{stem}.capture.json",
                    }
                )
    if len(entries) != 400:
        raise IndexError(f"matrix expands to {len(entries)} captures instead of 400")
    return entries


def diagnostic(code: str, capture: str, detail: str) -> dict[str, str]:
    return {"code": code, "capture": capture, "detail": detail}


def enforce_final_diagnostics(
    phase: str, findings: list[dict[str, str]], category: str
) -> None:
    if phase == "final" and findings:
        first = findings[0]
        raise IndexError(
            f"final {category} diagnostic {first['code']} for {first['capture']}: "
            f"{first['detail']}"
        )


def nullable_string(value: Any) -> bool:
    return value is None or (isinstance(value, str) and bool(value))


def validate_content_seed(
    record: dict[str, Any], expected: dict[str, str]
) -> str:
    label = expected["record"]
    content_seed = record.get("contentSeed")
    if not isinstance(content_seed, dict) or set(content_seed) != CONTENT_SEED_KEYS:
        raise IndexError(f"{label} contentSeed keys are invalid")
    for key, required_keys in CONTENT_SEED_NESTED_KEYS.items():
        nested = content_seed.get(key)
        if not isinstance(nested, dict) or set(nested) != required_keys:
            raise IndexError(f"{label} contentSeed.{key} keys are invalid")

    fixture_version = content_seed.get("fixtureVersion")
    if (
        isinstance(fixture_version, bool)
        or not isinstance(fixture_version, int)
        or fixture_version != 1
    ):
        raise IndexError(f"{label} contentSeed.fixtureVersion must be 1")
    for key in ("fixtureID", "surface"):
        if not isinstance(content_seed.get(key), str) or not content_seed[key]:
            raise IndexError(f"{label} contentSeed.{key} must be a non-empty string")
    plaintext = content_seed.get("plaintext")
    if plaintext is not None and not isinstance(plaintext, str):
        raise IndexError(f"{label} contentSeed.plaintext must be string or null")
    glyph_tokens = content_seed.get("glyphTokens")
    if not (
        isinstance(glyph_tokens, list)
        and all(isinstance(value, str) and value for value in glyph_tokens)
    ):
        raise IndexError(f"{label} contentSeed.glyphTokens is invalid")

    sender = content_seed["sender"]
    if not nullable_string(sender.get("name")):
        raise IndexError(f"{label} contentSeed.sender.name is invalid")
    cipher = content_seed["cipher"]
    if not nullable_string(cipher.get("id")) or not nullable_string(cipher.get("name")):
        raise IndexError(f"{label} contentSeed.cipher values are invalid")
    if (cipher.get("id") is None) != (cipher.get("name") is None):
        raise IndexError(f"{label} contentSeed.cipher identity is incomplete")

    selected = content_seed["selectedResources"]
    for key in ("codexID", "relicID"):
        if not isinstance(selected.get(key), str) or not selected[key]:
            raise IndexError(f"{label} contentSeed.selectedResources.{key} is invalid")
    for key in ("sealID", "frameID"):
        if not nullable_string(selected.get(key)):
            raise IndexError(f"{label} contentSeed.selectedResources.{key} is invalid")

    progression = content_seed["progression"]
    for key in ("ownershipState", "achievementID"):
        if not nullable_string(progression.get(key)):
            raise IndexError(f"{label} contentSeed.progression.{key} is invalid")
    completed = progression.get("completedRuleCount")
    required = progression.get("requiredRuleCount")
    for key, value in (
        ("completedRuleCount", completed),
        ("requiredRuleCount", required),
    ):
        if value is not None and (
            isinstance(value, bool) or not isinstance(value, int) or value < 0
        ):
            raise IndexError(f"{label} contentSeed.progression.{key} is invalid")
    if (completed is None) != (required is None):
        raise IndexError(f"{label} contentSeed progression counts are incomplete")
    if completed is not None and completed > required:
        raise IndexError(f"{label} contentSeed progression counts are inconsistent")

    accessibility = content_seed["accessibility"]
    if not isinstance(accessibility.get("increasedContrast"), bool) or not isinstance(
        accessibility.get("reduceMotion"), bool
    ):
        raise IndexError(f"{label} contentSeed accessibility flags are invalid")
    if not isinstance(accessibility.get("dynamicTypeSize"), str) or not accessibility[
        "dynamicTypeSize"
    ]:
        raise IndexError(f"{label} contentSeed.dynamicTypeSize is invalid")

    fixed = {
        "timestamp": CONTENT_SEED_TIMESTAMP,
        "locale": "en_US_POSIX",
        "calendar": "gregorian",
        "timeZone": "GMT",
    }
    for key, expected_value in fixed.items():
        if content_seed.get(key) != expected_value:
            raise IndexError(f"{label} contentSeed.{key} differs from fixed fixture")

    selected_bindings = {
        "codexID": selected["codexID"],
        "relicID": selected["relicID"],
        "sealID": selected["sealID"],
        "frameID": selected["frameID"],
    }
    top_level_bindings = {
        "stateSeed": content_seed["fixtureID"],
        "surface": content_seed["surface"],
        **selected_bindings,
    }
    for key, expected_value in top_level_bindings.items():
        if record.get(key) != expected_value:
            raise IndexError(f"{label} {key} differs from contentSeed")
    if content_seed["surface"] != expected["surface"]:
        raise IndexError(f"{label} contentSeed.surface differs from matrix")

    declared_digest = record.get("stateSeedSHA256")
    if not valid_sha256(declared_digest):
        raise IndexError(f"{label} stateSeedSHA256 is invalid")
    actual_digest = canonical_json_sha256(content_seed)
    if declared_digest != actual_digest:
        raise IndexError(f"{label} stateSeedSHA256 differs from canonical contentSeed")
    return actual_digest


def validate_record(
    record: Any,
    expected: dict[str, str],
    png: Path,
    allowed_resource_ids_by_theme_codex: dict[
        tuple[str, str], frozenset[str]
    ],
) -> list[dict[str, str]]:
    if not isinstance(record, dict):
        raise IndexError(f"capture record keys are invalid: {expected['record']}")
    keys = set(record)
    if not REQUIRED_RECORD_KEYS.issubset(keys) or not keys.issubset(
        REQUIRED_RECORD_KEYS | EVIDENCE_RECORD_KEYS
    ):
        missing = sorted(REQUIRED_RECORD_KEYS - keys)
        extra = sorted(keys - REQUIRED_RECORD_KEYS - EVIDENCE_RECORD_KEYS)
        raise IndexError(
            f"capture record keys are invalid: {expected['record']}; "
            f"missing={missing}, extra={extra}"
        )
    if record["schemaVersion"] != "1.0":
        raise IndexError(f"capture record schema is invalid: {expected['record']}")
    expected_theme_id, expected_codex_id = EXPECTED_THEMES[expected["themeName"]]
    exact = {
        "themeName": expected["themeName"],
        "themeID": expected_theme_id,
        "codexID": expected_codex_id,
        "surface": expected["surface"],
        "stateID": expected["surface"],
        "destination": expected["destination"],
    }
    for key, value in exact.items():
        if record.get(key) != value:
            raise IndexError(
                f"{expected['record']} {key} is {record.get(key)!r}, expected {value!r}"
            )
    manifest_key = (record["themeName"], record["codexID"])
    allowed_resource_ids = allowed_resource_ids_by_theme_codex.get(manifest_key)
    if allowed_resource_ids is None:
        raise IndexError(
            f"{expected['record']} has no active theme production integrity manifest"
        )
    validate_content_seed(record, expected)
    for key in ("stateSeed", "relicID"):
        if not isinstance(record.get(key), str) or not record[key]:
            raise IndexError(f"{expected['record']} {key} must be a non-empty string")
    for key in ("sealID", "frameID"):
        if record.get(key) is not None and (
            not isinstance(record[key], str) or not record[key]
        ):
            raise IndexError(f"{expected['record']} {key} must be null or a non-empty string")
    for key in ("pixelWidth", "pixelHeight", "visualPlanRevision", "byteCount"):
        value = record.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise IndexError(f"{expected['record']} {key} must be a positive integer")
    for key in ("pointWidth", "pointHeight", "scale"):
        value = record.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            raise IndexError(f"{expected['record']} {key} must be positive and finite")
    if record["pixelWidth"] != round(record["pointWidth"] * record["scale"]):
        raise IndexError(f"{expected['record']} pixelWidth does not match points and scale")
    if record["pixelHeight"] != round(record["pointHeight"] * record["scale"]):
        raise IndexError(f"{expected['record']} pixelHeight does not match points and scale")
    digest = record.get("pngSHA256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise IndexError(f"{expected['record']} pngSHA256 is invalid")
    if sha256_file(png) != digest:
        raise IndexError(f"{expected['record']} does not match {expected['png']}")
    if record["byteCount"] != png.stat().st_size:
        raise IndexError(f"{expected['record']} byteCount does not match {expected['png']}")
    findings: list[dict[str, str]] = []
    rendered_resources = record.get("renderedResourceIDs")
    rendered_resource_set: set[str] = set()
    active_rendered_resource_set: set[str] = set()
    if rendered_resources is None:
        findings.append(
            diagnostic(
                "rendered-resources-unverified",
                expected["png"],
                "capture record does not attest which active-plan resources were rendered",
            )
        )
    elif not (
        isinstance(rendered_resources, list)
        and rendered_resources
        and all(isinstance(value, str) and value for value in rendered_resources)
        and len(rendered_resources) == len(set(rendered_resources))
        and rendered_resources == sorted(rendered_resources)
    ):
        raise IndexError(
            f"{expected['record']} renderedResourceIDs must be sorted unique non-empty strings"
        )
    else:
        rendered_resource_set = set(rendered_resources)
    rendered_resource_bindings = record.get("renderedResourceBindings")
    if rendered_resources is not None and rendered_resource_bindings is None:
        findings.append(
            diagnostic(
                "rendered-resource-bindings-unverified",
                expected["png"],
                "capture record does not bind rendered resources to owning Codices and revision",
            )
        )
    elif rendered_resource_bindings is not None:
        if not isinstance(rendered_resource_bindings, list) or not rendered_resource_bindings:
            raise IndexError(
                f"{expected['record']} renderedResourceBindings must be a non-empty array"
            )
        allowed_by_codex_id: dict[str, frozenset[str]] = {}
        for (_, owning_codex_id), resource_ids in allowed_resource_ids_by_theme_codex.items():
            prior = allowed_by_codex_id.setdefault(owning_codex_id, resource_ids)
            if prior != resource_ids:
                raise IndexError(
                    f"production integrity manifest ownership is ambiguous for {owning_codex_id}"
                )
        declared_owner_codex_ids_by_resource: dict[str, set[str]] = {}
        for owning_codex_id, resource_ids in allowed_by_codex_id.items():
            for resource_id in resource_ids:
                declared_owner_codex_ids_by_resource.setdefault(resource_id, set()).add(
                    owning_codex_id
                )
        normalized_bindings: list[tuple[str, str, int]] = []
        for binding in rendered_resource_bindings:
            if not isinstance(binding, dict) or set(binding) != {
                "codexID",
                "resourceID",
                "visualPlanRevision",
            }:
                raise IndexError(
                    f"{expected['record']} renderedResourceBindings keys are invalid"
                )
            owning_codex_id = binding.get("codexID")
            resource_id = binding.get("resourceID")
            revision = binding.get("visualPlanRevision")
            if (
                not isinstance(owning_codex_id, str)
                or not owning_codex_id
                or not isinstance(resource_id, str)
                or not resource_id
                or isinstance(revision, bool)
                or not isinstance(revision, int)
                or revision <= 0
            ):
                raise IndexError(
                    f"{expected['record']} renderedResourceBindings values are invalid"
                )
            owning_resource_ids = allowed_by_codex_id.get(owning_codex_id)
            if owning_resource_ids is None:
                raise IndexError(
                    f"{expected['record']} rendered resource has unknown owning Codex "
                    f"{owning_codex_id}"
                )
            if resource_id not in owning_resource_ids:
                declared_owners = declared_owner_codex_ids_by_resource.get(resource_id, set())
                if declared_owners:
                    raise IndexError(
                        f"{expected['record']} rendered resource {resource_id} is bound to "
                        f"{owning_codex_id}, but its manifest owner is "
                        + ", ".join(sorted(declared_owners))
                    )
                findings.append(
                    diagnostic(
                        "rendered-resource-missing-from-owning-manifest",
                        expected["png"],
                        f"{resource_id} rendered for {owning_codex_id} but is undeclared",
                    )
                )
            if revision != record["visualPlanRevision"]:
                raise IndexError(
                    f"{expected['record']} rendered resource revision differs from visualPlanRevision"
                )
            normalized_bindings.append((owning_codex_id, resource_id, revision))
            if owning_codex_id == record["codexID"]:
                active_rendered_resource_set.add(resource_id)
        if (
            normalized_bindings != sorted(normalized_bindings)
            or len(normalized_bindings) != len(set(normalized_bindings))
        ):
            raise IndexError(
                f"{expected['record']} renderedResourceBindings must be sorted and unique"
            )
        bound_resource_set = {binding[1] for binding in normalized_bindings}
        if bound_resource_set != rendered_resource_set:
            raise IndexError(
                f"{expected['record']} renderedResourceIDs differ from renderedResourceBindings"
            )
        if not active_rendered_resource_set:
            raise IndexError(
                f"{expected['record']} renderedResourceBindings omit the active Codex"
            )
    attested_frame_ids: set[str] = set()
    required_element_ids: list[str] | None = None
    clipped_element_ids: set[str] = set()
    viewport = record.get("viewportAssertions")
    if viewport is None:
        findings.append(
            diagnostic(
                "layout-clipping-unverified",
                expected["png"],
                "capture record does not include required-element viewport assertions",
            )
        )
    elif not isinstance(viewport, dict) or set(viewport) != {
        "requiredElementCount",
        "requiredElementIDs",
        "clippedElementIDs",
    }:
        raise IndexError(f"{expected['record']} viewportAssertions keys are invalid")
    else:
        required_count = viewport.get("requiredElementCount")
        required_element_ids = viewport.get("requiredElementIDs")
        clipped = viewport.get("clippedElementIDs")
        if (
            isinstance(required_count, bool)
            or not isinstance(required_count, int)
            or required_count <= 0
        ):
            raise IndexError(
                f"{expected['record']} viewportAssertions.requiredElementCount must be positive"
            )
        if not (
            isinstance(required_element_ids, list)
            and required_element_ids
            and all(
                isinstance(value, str) and value for value in required_element_ids
            )
            and required_element_ids == sorted(required_element_ids)
            and len(required_element_ids) == len(set(required_element_ids))
        ):
            raise IndexError(
                f"{expected['record']} viewportAssertions.requiredElementIDs "
                "must be sorted unique non-empty strings"
            )
        if required_count != len(required_element_ids):
            raise IndexError(
                f"{expected['record']} viewportAssertions.requiredElementCount "
                "does not match requiredElementIDs"
            )
        if not (
            isinstance(clipped, list)
            and all(isinstance(value, str) and value for value in clipped)
            and clipped == sorted(clipped)
            and len(clipped) == len(set(clipped))
        ):
            raise IndexError(
                f"{expected['record']} viewportAssertions.clippedElementIDs is invalid"
            )
        if not set(clipped).issubset(set(required_element_ids)):
            raise IndexError(
                f"{expected['record']} viewportAssertions.clippedElementIDs "
                "must be a subset of requiredElementIDs"
            )
        clipped_element_ids = set(clipped)
        if clipped:
            findings.append(
                diagnostic(
                    "layout-clipping",
                    expected["png"],
                    "required elements outside the viewport: " + ", ".join(clipped),
                )
            )
    element_frames = record.get("elementFrames")
    if element_frames is None:
        findings.append(
            diagnostic(
                "element-frames-unverified",
                expected["png"],
                "capture record does not attest exact rendered element frames",
            )
        )
    elif not isinstance(element_frames, dict) or set(element_frames) != {
        "coordinateOrigin",
        "frames",
        "scale",
        "units",
    }:
        raise IndexError(f"{expected['record']} elementFrames keys are invalid")
    else:
        if element_frames.get("coordinateOrigin") != "top-left":
            raise IndexError(
                f"{expected['record']} elementFrames.coordinateOrigin must be top-left"
            )
        if element_frames.get("units") != "pixels":
            raise IndexError(f"{expected['record']} elementFrames.units must be pixels")
        frame_scale = element_frames.get("scale")
        if (
            isinstance(frame_scale, bool)
            or not isinstance(frame_scale, (int, float))
            or not math.isfinite(frame_scale)
            or frame_scale <= 0
            or frame_scale != record["scale"]
        ):
            raise IndexError(
                f"{expected['record']} elementFrames.scale must equal capture scale"
            )
        frames = element_frames.get("frames")
        if not isinstance(frames, list) or not frames:
            raise IndexError(f"{expected['record']} elementFrames.frames must be non-empty")
        frame_ids: list[str] = []
        for frame in frames:
            if not isinstance(frame, dict) or set(frame) != {
                "elementID",
                "height",
                "width",
                "x",
                "y",
            }:
                raise IndexError(
                    f"{expected['record']} elementFrames contains an invalid frame"
                )
            element_id = frame.get("elementID")
            if not isinstance(element_id, str) or not element_id:
                raise IndexError(
                    f"{expected['record']} elementFrames elementID must be non-empty"
                )
            frame_ids.append(element_id)
            for coordinate in ("x", "y", "width", "height"):
                value = frame.get(coordinate)
                if (
                    isinstance(value, bool)
                    or not isinstance(value, (int, float))
                    or not math.isfinite(value)
                    or (coordinate in {"width", "height"} and value <= 0)
                ):
                    raise IndexError(
                        f"{expected['record']} elementFrames {coordinate} is invalid"
                    )
        if frame_ids != sorted(frame_ids) or len(frame_ids) != len(set(frame_ids)):
            raise IndexError(
                f"{expected['record']} elementFrames must be sorted by unique elementID"
            )
        attested_frame_ids = set(frame_ids)
        viewport_frames = [
            frame for frame in frames if frame["elementID"] == VIEWPORT_ELEMENT_ID
        ]
        if len(viewport_frames) != 1:
            raise IndexError(
                f"{expected['record']} elementFrames must include the exact viewport frame"
            )
        viewport_frame = viewport_frames[0]
        expected_viewport = {
            "x": 0.0,
            "y": 0.0,
            "width": float(record["pixelWidth"]),
            "height": float(record["pixelHeight"]),
        }
        if any(
            not math.isclose(
                float(viewport_frame[key]), value, rel_tol=0.0, abs_tol=0.5
            )
            for key, value in expected_viewport.items()
        ):
            raise IndexError(
                f"{expected['record']} elementFrames viewport differs from capture bounds"
            )
    if required_element_ids is not None:
        missing_required_frames = sorted(
            set(required_element_ids) - attested_frame_ids
        )
        unexplained_missing_frames = sorted(
            set(missing_required_frames) - clipped_element_ids
        )
        if unexplained_missing_frames:
            raise IndexError(
                f"{expected['record']} required viewport elements lack attested frames: "
                + ", ".join(unexplained_missing_frames)
            )
        if missing_required_frames:
            findings.append(
                diagnostic(
                    "required-element-frames-unattested",
                    expected["png"],
                    "clipped required elements have no rendered frame: "
                    + ", ".join(missing_required_frames),
                )
            )
    safe_preview = record.get("safePreviewEvidence")
    if expected["surface"] != "received-cipher":
        if safe_preview is not None:
            raise IndexError(
                f"{expected['record']} safePreviewEvidence is only valid for received-cipher"
            )
    elif safe_preview is None:
        findings.append(
            diagnostic(
                "received-preview-unverified",
                expected["png"],
                "received capture does not attest the production safe-preview result",
            )
        )
    elif not isinstance(safe_preview, dict) or set(safe_preview) != {
        "byteCount",
        "decodedPreviewElementID",
        "failureCode",
        "resourceIDs",
        "sha256",
        "status",
    }:
        raise IndexError(f"{expected['record']} safePreviewEvidence keys are invalid")
    else:
        status = safe_preview.get("status")
        if status not in {"valid", "generation-failed", "unavailable"}:
            raise IndexError(f"{expected['record']} safePreviewEvidence status is invalid")
        resource_ids = safe_preview.get("resourceIDs")
        if not (
            isinstance(resource_ids, list)
            and all(isinstance(value, str) and value for value in resource_ids)
            and resource_ids == sorted(resource_ids)
            and len(resource_ids) == len(set(resource_ids))
        ):
            raise IndexError(
                f"{expected['record']} safePreviewEvidence resourceIDs are invalid"
            )
        undeclared_preview = sorted(set(resource_ids) - allowed_resource_ids)
        if undeclared_preview:
            globally_declared = {
                resource_id
                for resource_ids in allowed_resource_ids_by_theme_codex.values()
                for resource_id in resource_ids
            }
            cross_theme_preview = sorted(set(undeclared_preview) & globally_declared)
            if cross_theme_preview:
                raise IndexError(
                    f"{expected['record']} safePreviewEvidence.resourceIDs belong to "
                    "another Codex manifest: " + ", ".join(cross_theme_preview)
                )
            findings.append(
                diagnostic(
                    "safe-preview-resource-missing-from-active-manifest",
                    expected["png"],
                    "safe preview rendered active-Codex resources missing from its "
                    "integrity manifest: " + ", ".join(undeclared_preview),
                )
            )
        if status == "valid":
            byte_count = safe_preview.get("byteCount")
            preview_digest = safe_preview.get("sha256")
            preview_element_id = safe_preview.get("decodedPreviewElementID")
            if (
                isinstance(byte_count, bool)
                or not isinstance(byte_count, int)
                or byte_count <= 0
                or not isinstance(preview_digest, str)
                or not re.fullmatch(r"[0-9a-f]{64}", preview_digest)
                or not resource_ids
                or preview_element_id != "received.safe-preview"
                or safe_preview.get("failureCode") is not None
            ):
                raise IndexError(
                    f"{expected['record']} valid safePreviewEvidence is incomplete"
                )
            preview_rendered_resource_set = (
                active_rendered_resource_set
                if rendered_resource_bindings is not None
                else rendered_resource_set
            )
            if not set(resource_ids).issubset(preview_rendered_resource_set):
                raise IndexError(
                    f"{expected['record']} valid safePreviewEvidence.resourceIDs must be "
                    "a subset of the active-Codex rendered resources"
                )
            if preview_element_id not in attested_frame_ids:
                findings.append(
                    diagnostic(
                        "received-preview-not-rendered",
                        expected["png"],
                        "valid safe preview was not present in the rendered element frames",
                    )
                )
        else:
            failure_code = safe_preview.get("failureCode")
            if (
                safe_preview.get("byteCount") is not None
                or safe_preview.get("sha256") is not None
                or safe_preview.get("decodedPreviewElementID") is not None
                or resource_ids
                or not isinstance(failure_code, str)
                or not failure_code
            ):
                raise IndexError(
                    f"{expected['record']} failed safePreviewEvidence is inconsistent"
                )
            findings.append(
                diagnostic(
                    "received-preview-" + status,
                    expected["png"],
                    "production safe preview status: " + failure_code,
                )
            )
    return findings


def analyze_image(path: Path, record: dict[str, Any]) -> dict[str, Any]:
    if DEPENDENCY_ERROR is not None:
        raise IndexError(f"image dependencies unavailable: {DEPENDENCY_ERROR}")
    try:
        with Image.open(path) as source:
            source.load()
            if source.format != "PNG":
                raise IndexError(f"capture is not PNG: {path.name}")
            if source.width != record["pixelWidth"] or source.height != record["pixelHeight"]:
                raise IndexError(f"capture dimensions differ from its record: {path.name}")
            rgb = source.convert("RGB")
            sample = rgb.resize((64, 64), Image.Resampling.LANCZOS)
            gray = sample.convert("L")
            luminance = np.asarray(gray, dtype=np.float32)
            unique_colors = len(set(sample.getdata()))
            standard_deviation = float(luminance.std())
            entropy = float(gray.entropy())
            edges = np.asarray(gray.filter(ImageFilter.FIND_EDGES), dtype=np.float32)
            edge_fraction = float(np.count_nonzero(edges > 18) / edges.size)
            normalized = np.asarray(
                rgb.resize((32, 32), Image.Resampling.LANCZOS).convert("L"),
                dtype=np.float32,
            )
    except (OSError, UnidentifiedImageError) as error:
        raise IndexError(f"unable to decode {path.name}: {error}") from error
    findings: list[dict[str, str]] = []
    if unique_colors < 48:
        findings.append(
            diagnostic(
                "insufficient-color-detail",
                path.name,
                f"64x64 sample contains only {unique_colors} unique colors",
            )
        )
    if standard_deviation < 4.0:
        findings.append(
            diagnostic(
                "blank-luminance",
                path.name,
                f"luminance standard deviation is {standard_deviation:.3f}",
            )
        )
    if entropy < 3.0:
        findings.append(
            diagnostic(
                "low-entropy",
                path.name,
                f"luminance entropy is {entropy:.3f}",
            )
        )
    if edge_fraction < 0.01:
        findings.append(
            diagnostic(
                "insufficient-structural-detail",
                path.name,
                f"edge fraction is {edge_fraction:.4f}",
            )
        )
    return {
        "width": record["pixelWidth"],
        "height": record["pixelHeight"],
        "uniqueSampleColors": unique_colors,
        "luminanceStandardDeviation": round(standard_deviation, 6),
        "entropy": round(entropy, 6),
        "edgeFraction": round(edge_fraction, 6),
        "normalized": normalized,
        "diagnostics": findings,
    }


def validate_dimensions(records: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    dimensions: dict[str, set[tuple[int, int]]] = {}
    for record in records:
        dimensions.setdefault(record["destination"], set()).add(
            (record["pixelWidth"], record["pixelHeight"])
        )
    if set(dimensions) != set(DESTINATION_SLUGS):
        raise IndexError("capture destinations are incomplete")
    for destination, values in dimensions.items():
        if len(values) != 1:
            raise IndexError(f"capture dimensions vary within {destination}: {sorted(values)}")
    expected_mac = {
        "macOS standard": (720, 900),
        "macOS resized": (980, 720),
    }
    for destination, expected in expected_mac.items():
        if next(iter(dimensions[destination])) != expected:
            raise IndexError(
                f"{destination} dimensions differ: {next(iter(dimensions[destination]))}, expected {expected}"
            )
    iphone = next(iter(dimensions["iPhone portrait"]))
    ipad = next(iter(dimensions["iPad portrait"]))
    if iphone[0] >= iphone[1] or ipad[0] >= ipad[1]:
        raise IndexError("iPhone and iPad captures must be portrait")
    if min(iphone) < 320 or min(ipad) < 700 or iphone == ipad:
        raise IndexError("iPhone/iPad destination dimensions are not distinct hosted viewports")
    return {
        destination: {"width": next(iter(values))[0], "height": next(iter(values))[1]}
        for destination, values in dimensions.items()
    }


def material_uniqueness_findings(
    captures: list[dict[str, Any]], normalized: dict[str, Any]
) -> list[str]:
    findings: list[str] = []
    by_key = {
        (capture["themeName"], capture["destination"], capture["surface"]): capture
        for capture in captures
    }
    for theme_name in EXPECTED_THEMES:
        for destination in DESTINATION_SLUGS:
            for surfaces in MATERIAL_GROUPS:
                values = [by_key[(theme_name, destination, surface)] for surface in surfaces]
                for index, left in enumerate(values):
                    for right in values[index + 1 :]:
                        left_pixels = normalized[left["png"]]
                        right_pixels = normalized[right["png"]]
                        rms = float(np.sqrt(np.mean(np.square(left_pixels - right_pixels))))
                        if rms < 1.0:
                            findings.append(
                                "materially different states are perceptually duplicated: "
                                f"{left['png']} and {right['png']} (RMS {rms:.4f})"
                            )
    return findings


def validate_material_uniqueness(
    captures: list[dict[str, Any]], normalized: dict[str, Any]
) -> None:
    findings = material_uniqueness_findings(captures, normalized)
    if findings:
        raise IndexError(findings[0])


def git_output(root: Path, *arguments: str) -> bytes:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        raise IndexError(completed.stderr.decode("utf-8", "replace").strip())
    return completed.stdout


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
    except ValueError:
        return False
    return True


def source_manifest(
    root: Path,
    excluded_paths: Iterable[Path],
) -> dict[str, Any]:
    excluded = [path.resolve() for path in excluded_paths]
    raw_paths = git_output(
        root,
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        "-z",
    )
    records: list[dict[str, Any]] = []
    for raw in raw_paths.split(b"\0"):
        if not raw:
            continue
        relative = raw.decode("utf-8")
        path = (root / relative).resolve()
        if any(path == excluded_path or is_within(path, excluded_path) for excluded_path in excluded):
            continue
        if not path.is_file():
            continue
        records.append(
            {
                "path": relative,
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
                "executable": bool(path.stat().st_mode & 0o111),
            }
        )
    records.sort(key=lambda record: record["path"])
    aggregate = hashlib.sha256()
    for record in records:
        aggregate.update(
            (
                f"{record['path']}\0{record['bytes']}\0{record['sha256']}\0"
                f"{1 if record['executable'] else 0}\n"
            ).encode("utf-8")
        )
    head = git_output(root, "rev-parse", "HEAD").decode("ascii").strip()
    status_arguments = ["status", "--porcelain=v1", "--untracked-files=all", "-z", "--", "."]
    for excluded_path in excluded:
        try:
            relative_exclusion = excluded_path.relative_to(root).as_posix()
        except ValueError:
            continue
        status_arguments.append(f":(exclude){relative_exclusion}")
    status = git_output(root, *status_arguments)
    return {
        "schemaVersion": "1.0",
        "sourceSHA": head,
        "fileCount": len(records),
        "aggregateSHA256": aggregate.hexdigest(),
        "gitStatusSHA256": hashlib.sha256(status).hexdigest(),
        "isClean": not status,
        "files": records,
    }


def validate_source_manifest_pair(
    before: dict[str, Any], after: dict[str, Any]
) -> None:
    required = {
        "schemaVersion",
        "sourceSHA",
        "fileCount",
        "aggregateSHA256",
        "gitStatusSHA256",
        "isClean",
        "files",
    }
    for label, document in (("before", before), ("after", after)):
        if not isinstance(document, dict) or set(document) != required:
            raise IndexError(f"{label} source manifest schema is invalid")
        if document.get("schemaVersion") != "1.0":
            raise IndexError(f"{label} source manifest schemaVersion is invalid")
        if not isinstance(document.get("files"), list):
            raise IndexError(f"{label} source manifest files are invalid")
        if document.get("isClean") is not True:
            raise IndexError(f"{label} source manifest reports a dirty source tree")
    if before != after:
        changed = []
        before_files = {
            record.get("path"): record.get("sha256")
            for record in before["files"]
            if isinstance(record, dict)
        }
        after_files = {
            record.get("path"): record.get("sha256")
            for record in after["files"]
            if isinstance(record, dict)
        }
        for path in sorted(set(before_files) | set(after_files)):
            if before_files.get(path) != after_files.get(path):
                changed.append(path)
        detail = ", ".join(changed[:8]) or "repository identity/status changed"
        raise IndexError(f"source changed between pre-build and post-build manifests: {detail}")


def validate_captures(
    root: Path,
    matrix_path: Path,
    capture_root: Path,
    phase: str,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, int]], list[dict[str, str]]]:
    matrix = load_matrix(matrix_path)
    expected = expected_entries(matrix)
    expected_pngs = {entry["png"] for entry in expected}
    actual_pngs = {path.name for path in capture_root.glob("*.png") if path.is_file()}
    if actual_pngs != expected_pngs:
        missing = sorted(expected_pngs - actual_pngs)
        extra = sorted(actual_pngs - expected_pngs)
        raise IndexError(f"PNG set differs; missing={missing[:8]}, extra={extra[:8]}")
    expected_records = {entry["record"] for entry in expected}
    actual_records = {
        path.name for path in capture_root.glob("*.capture.json") if path.is_file()
    }
    if actual_records != expected_records:
        missing = sorted(expected_records - actual_records)
        extra = sorted(actual_records - expected_records)
        raise IndexError(f"capture record set differs; missing={missing[:8]}, extra={extra[:8]}")

    captures: list[dict[str, Any]] = []
    normalized: dict[str, Any] = {}
    png_digests: dict[str, str] = {}
    state_seeds: set[str] = set()
    findings: list[dict[str, str]] = []
    allowed_resource_ids = load_theme_resource_manifests(root)
    for entry in expected:
        png = capture_root / entry["png"]
        record = load_json(capture_root / entry["record"])
        findings.extend(validate_record(record, entry, png, allowed_resource_ids))
        metrics = analyze_image(png, record)
        findings.extend(metrics.pop("diagnostics"))
        digest = record["pngSHA256"]
        if digest in png_digests:
            findings.append(
                diagnostic(
                    "duplicate-capture-bytes",
                    entry["png"],
                    f"PNG bytes duplicate {png_digests[digest]}",
                )
            )
        else:
            png_digests[digest] = entry["png"]
        state_seeds.add(record["stateSeed"])
        normalized[entry["png"]] = metrics.pop("normalized")
        captures.append(
            {
                **record,
                "png": entry["png"],
                "record": entry["record"],
                "comparisonResult": "not-evaluated",
                "quality": metrics,
            }
        )
    if len(state_seeds) != 1:
        raise IndexError(f"capture state seeds differ: {sorted(state_seeds)}")
    for detail in material_uniqueness_findings(captures, normalized):
        findings.append(diagnostic("material-state-similarity", "matrix", detail))
    enforce_final_diagnostics(phase, findings, "capture")
    return captures, validate_dimensions(captures), findings


def result_bundle_digest(path: Path) -> str:
    digest = hashlib.sha256()
    for candidate in sorted(item for item in path.rglob("*") if item.is_file()):
        relative = candidate.relative_to(path).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256_file(candidate)))
    return digest.hexdigest()


def capture_destination_slug(name: str) -> str:
    for destination_slug in DESTINATION_SLUGS.values():
        if name.endswith(f"--{destination_slug}.png") or name.endswith(
            f"--{destination_slug}.capture.json"
        ):
            return destination_slug
    raise IndexError(f"capture attachment has no known destination: {name}")


def validate_destination_selection_dimensions(
    by_role: dict[str, dict[str, Any]], captures: list[dict[str, Any]]
) -> None:
    destination_names = {"iphone": "iPhone portrait", "ipad": "iPad portrait"}
    for role, destination_name in destination_names.items():
        selection = by_role[role]["destinationSelection"]
        expected_dimensions = selection["expectedPixelDimensions"]
        expected_pair = (expected_dimensions["width"], expected_dimensions["height"])
        actual_pairs = {
            (capture.get("pixelWidth"), capture.get("pixelHeight"))
            for capture in captures
            if capture.get("destination") == destination_name
        }
        actual_scales = {
            capture.get("scale")
            for capture in captures
            if capture.get("destination") == destination_name
        }
        if actual_pairs != {expected_pair} or actual_scales != {selection["expectedScale"]}:
            raise IndexError(
                f"{destination_name} dimensions/scale do not match exact selected model "
                f"{selection['expectedModelName']!r}"
            )


def validate_extraction_report(
    report_path: Path,
    capture_root: Path,
    captures: list[dict[str, Any]],
) -> dict[str, Any]:
    report = load_json(report_path)
    if not isinstance(report, dict) or report.get("schemaVersion") != SCHEMA_VERSION:
        raise IndexError("extraction report schema is invalid")
    exact = {
        "result": "pass",
        "pngCount": 400,
        "recordCount": 400,
        "expectedTestIdentifier": EXPECTED_TEST_IDENTIFIER,
    }
    for key, expected in exact.items():
        if report.get(key) != expected:
            raise IndexError(
                f"extraction report {key} is {report.get(key)!r}, expected {expected!r}"
            )
    capture_root_field = report.get("captureRoot")
    if not isinstance(capture_root_field, str) or Path(capture_root_field).resolve() != capture_root:
        raise IndexError("extraction report captureRoot does not bind the indexed capture root")
    if not isinstance(report.get("xcresulttool"), str) or not report["xcresulttool"]:
        raise IndexError("extraction report lacks xcresulttool provenance")

    selection_source = report.get("simulatorSelectionSource")
    if not isinstance(selection_source, dict) or set(selection_source) != {
        "path",
        "sha256",
        "documentSHA256",
        "document",
    }:
        raise IndexError("extraction report lacks exact Simulator selection source provenance")
    selection_path_value = selection_source.get("path")
    selection_document = selection_source.get("document")
    if not isinstance(selection_path_value, str):
        raise IndexError("Simulator selection source path is invalid")
    selection_path = Path(selection_path_value).resolve()
    if (
        not selection_path.is_file()
        or selection_source.get("sha256") != sha256_file(selection_path)
        or not isinstance(selection_document, dict)
        or selection_source.get("documentSHA256") != canonical_json_sha256(selection_document)
        or load_json(selection_path) != selection_document
        or set(selection_document) != {"schemaVersion", "destinations"}
        or selection_document.get("schemaVersion") != "1.0"
        or not isinstance(selection_document.get("destinations"), dict)
        or set(selection_document["destinations"]) != {"iphone", "ipad"}
    ):
        raise IndexError("Simulator selection source no longer matches its bound evidence")

    bundles = report.get("resultBundles")
    if not isinstance(bundles, list) or len(bundles) != 3:
        raise IndexError("extraction report must contain exactly three result bundles")
    by_role: dict[str, dict[str, Any]] = {}
    for bundle in bundles:
        if not isinstance(bundle, dict) or bundle.get("role") not in BUNDLE_DESTINATIONS:
            raise IndexError("extraction report contains an invalid result-bundle role")
        role = bundle["role"]
        if role in by_role:
            raise IndexError(f"extraction report repeats result-bundle role {role}")
        if bundle.get("selectedAttachmentCount") != EXPECTED_BUNDLE_ATTACHMENT_COUNTS[role]:
            raise IndexError(f"{role} result bundle attachment count is invalid")
        if bundle.get("expectedTestIdentifier") != EXPECTED_TEST_IDENTIFIER:
            raise IndexError(f"{role} result bundle test identifier is invalid")
        if bundle.get("outcome") != "Passed":
            raise IndexError(f"{role} result bundle outcome is not Passed")
        path_value = bundle.get("path")
        digest = bundle.get("sha256")
        if not isinstance(path_value, str) or not isinstance(digest, str):
            raise IndexError(f"{role} result bundle path/hash is invalid")
        path = Path(path_value).resolve()
        if not path.is_dir() or result_bundle_digest(path) != digest:
            raise IndexError(f"{role} result bundle no longer matches its SHA-256")
        device = bundle.get("device")
        if not isinstance(device, dict):
            raise IndexError(f"{role} result bundle lacks device provenance")
        for key in (
            "deviceId",
            "deviceName",
            "modelName",
            "osVersion",
            "osBuildNumber",
            "platform",
            "architecture",
        ):
            if not isinstance(device.get(key), str) or not device[key]:
                raise IndexError(f"{role} result bundle device.{key} is invalid")
        expected_platform = "macOS" if role == "macos" else "iOS Simulator"
        if device["platform"] != expected_platform:
            raise IndexError(f"{role} result bundle is bound to the wrong destination")
        destination_selection = bundle.get("destinationSelection")
        if role in {"iphone", "ipad"}:
            try:
                validated_selection = validate_selection(
                    destination_selection, role, device["deviceId"], device["modelName"]
                )
            except DestinationPolicyError as error:
                raise IndexError(str(error)) from error
            if selection_document["destinations"][role] != validated_selection:
                raise IndexError(f"{role} result bundle selection differs from source evidence")
        elif destination_selection is not None or not device["modelName"].startswith("Mac"):
            raise IndexError("macos result bundle is bound to the wrong destination")
        if role == "macos" and device["architecture"] != "arm64":
            raise IndexError("macos result bundle architecture must be arm64")
        for key in (
            "configurationName",
            "environmentDescription",
            "summarySHA256",
            "attachmentManifestSHA256",
        ):
            if not isinstance(bundle.get(key), str) or not bundle[key]:
                raise IndexError(f"{role} result bundle {key} is invalid")
        summary = bundle.get("resultSummary")
        attachment_manifest = bundle.get("attachmentManifest")
        if (
            not isinstance(summary, dict)
            or canonical_json_sha256(summary) != bundle["summarySHA256"]
            or summary.get("result") != "Passed"
            or summary.get("totalTestCount") != 1
            or summary.get("passedTests") != 1
            or summary.get("failedTests") != 0
            or summary.get("skippedTests") != 0
            or summary.get("expectedFailures") != 0
        ):
            raise IndexError(f"{role} embedded result summary is invalid")
        if (
            not isinstance(attachment_manifest, list)
            or len(attachment_manifest) != 1
            or attachment_manifest[0].get("testIdentifier") != EXPECTED_TEST_IDENTIFIER
            or not isinstance(attachment_manifest[0].get("attachments"), list)
            or len(attachment_manifest[0]["attachments"])
            != EXPECTED_BUNDLE_ATTACHMENT_COUNTS[role]
            or canonical_json_sha256(attachment_manifest)
            != bundle["attachmentManifestSHA256"]
        ):
            raise IndexError(f"{role} embedded attachment manifest is invalid")
        by_role[role] = bundle
    if set(by_role) != set(BUNDLE_DESTINATIONS):
        raise IndexError("extraction report result-bundle roles are incomplete")

    validate_destination_selection_dimensions(by_role, captures)

    expected_names = {
        capture[key]
        for capture in captures
        for key in ("png", "record")
    }
    attachments = report.get("attachments")
    if not isinstance(attachments, list) or len(attachments) != 800:
        raise IndexError("extraction report must contain exactly 800 attachment records")
    names: set[str] = set()
    for attachment in attachments:
        if not isinstance(attachment, dict) or not isinstance(attachment.get("name"), str):
            raise IndexError("extraction report contains an invalid attachment record")
        name = attachment["name"]
        if name in names:
            raise IndexError(f"extraction report repeats attachment {name}")
        names.add(name)
        if name not in expected_names:
            raise IndexError(f"extraction report contains an unexpected attachment {name}")
        role = attachment.get("resultBundleRole")
        if role not in by_role:
            raise IndexError(f"{name} has an invalid result-bundle role")
        if capture_destination_slug(name) not in BUNDLE_DESTINATIONS[role]:
            raise IndexError(f"{name} is bound to the wrong result bundle")
        expected_uti = "public.png" if name.endswith(".png") else "public.json"
        exact_attachment = {
            "testIdentifier": EXPECTED_TEST_IDENTIFIER,
            "attachmentUTI": expected_uti,
            "attachmentUTISource": "validated-content",
            "configurationName": by_role[role]["configurationName"],
            "deviceName": by_role[role]["device"]["deviceName"],
            "deviceID": by_role[role]["device"]["deviceId"],
            "resultBundle": by_role[role]["path"],
        }
        for key, expected in exact_attachment.items():
            if attachment.get(key) != expected:
                raise IndexError(f"{name} {key} does not match result-bundle provenance")
        file_path = capture_root / name
        if (
            not file_path.is_file()
            or attachment.get("sha256") != sha256_file(file_path)
            or attachment.get("bytes") != file_path.stat().st_size
        ):
            raise IndexError(f"{name} no longer matches its extracted attachment record")
    if names != expected_names:
        raise IndexError("extraction report attachment set is incomplete")
    return {
        "path": str(report_path.resolve()),
        "sha256": sha256_file(report_path),
        "expectedTestIdentifier": EXPECTED_TEST_IDENTIFIER,
        "attachmentCount": len(attachments),
        "xcresulttool": report["xcresulttool"],
        "resultBundles": bundles,
    }


def validate_toolchain_report(path: Path) -> dict[str, Any]:
    document = load_json(path)
    required = {
        "schemaVersion",
        "xcodebuildVersion",
        "swiftVersion",
        "macOS",
        "architecture",
        "pythonVersion",
        "executables",
    }
    if not isinstance(document, dict) or set(document) != required:
        raise IndexError("toolchain report schema is invalid")
    if document.get("schemaVersion") != SCHEMA_VERSION:
        raise IndexError("toolchain report schemaVersion is invalid")
    for key in ("xcodebuildVersion", "swiftVersion", "architecture", "pythonVersion"):
        if not isinstance(document.get(key), str) or not document[key]:
            raise IndexError(f"toolchain report {key} is invalid")
    if document["architecture"] != "arm64":
        raise IndexError("toolchain report architecture must be arm64")
    macos = document.get("macOS")
    if not isinstance(macos, dict) or set(macos) != {"productVersion", "buildVersion"}:
        raise IndexError("toolchain report macOS provenance is invalid")
    executables = document.get("executables")
    if not isinstance(executables, dict) or set(executables) != {
        "python",
        "swiftc",
        "xcodebuild",
        "xcresulttool",
        "xcrun",
    }:
        raise IndexError("toolchain report executable set is invalid")
    for label, record in executables.items():
        if not isinstance(record, dict) or set(record) != {"path", "sha256"}:
            raise IndexError(f"toolchain executable {label} provenance is invalid")
        executable = Path(record["path"]).resolve() if isinstance(record.get("path"), str) else None
        if executable is None or not executable.is_file() or sha256_file(executable) != record.get("sha256"):
            raise IndexError(f"toolchain executable {label} no longer matches its SHA-256")
    return {
        "path": str(path.resolve()),
        "sha256": sha256_file(path),
        "details": document,
    }


def runtime_diagnostics(log_paths: list[Path]) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    findings: list[dict[str, str]] = []
    records: list[dict[str, str]] = []
    patterns = (
        (
            "unbalanced-appearance-transition",
            re.compile(r"unbalanced calls to begin/end appearance transitions", re.IGNORECASE),
        ),
        (
            "duplicate-visual-class",
            re.compile(r"duplicate(?:[_ -](?:visual|capture))?[_ -]class", re.IGNORECASE),
        ),
    )
    for path in log_paths:
        resolved = path.resolve()
        if not resolved.is_file():
            raise IndexError(f"command log is missing: {resolved}")
        records.append({"path": str(resolved), "sha256": sha256_file(resolved)})
        try:
            lines = resolved.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError as error:
            raise IndexError(f"unable to read command log {resolved}: {error}") from error
        for line_number, line in enumerate(lines, 1):
            for code, pattern in patterns:
                if pattern.search(line):
                    findings.append(
                        diagnostic(
                            code,
                            resolved.name,
                            f"line {line_number}: {line.strip()[:500]}",
                        )
                    )
    return findings, records


def valid_sha256(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def validate_commands(values: list[str]) -> list[list[str]]:
    commands: list[list[str]] = []
    for value in values:
        try:
            command = json.loads(value)
        except json.JSONDecodeError as error:
            raise IndexError(f"command provenance is not a JSON argument array: {error}") from error
        if not (
            isinstance(command, list)
            and command
            and all(isinstance(argument, str) and argument for argument in command)
        ):
            raise IndexError("command provenance must contain non-empty string arguments")
        commands.append(command)
    return commands


def validate_timestamps(start: str, end: str) -> None:
    try:
        start_value = datetime.fromisoformat(start.replace("Z", "+00:00"))
        end_value = datetime.fromisoformat(end.replace("Z", "+00:00"))
    except (AttributeError, ValueError) as error:
        raise IndexError("capture timestamps must be ISO-8601 values") from error
    if start_value.tzinfo is None or end_value.tzinfo is None or end_value < start_value:
        raise IndexError("capture timestamps must be timezone-aware and ordered")


def resolve_mapping_path(base: Path, raw: Any, label: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise IndexError(f"{label} must be a non-empty relative path")
    relative = Path(raw)
    if relative.is_absolute():
        raise IndexError(f"{label} must be relative to the comparison index")
    resolved = (base / relative).resolve()
    if not is_within(resolved, base):
        raise IndexError(f"{label} escapes the comparison evidence root")
    return resolved


def resolve_report_path(root: Path, raw: Any, label: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise IndexError(f"comparison report {label} is invalid")
    path = Path(raw)
    return path.resolve() if path.is_absolute() else (root / path).resolve()


def expected_comparison_checks(metrics: dict[str, Any]) -> dict[str, bool]:
    return {
        "luminanceSSIM": metrics["luminanceSSIM"]
        >= COMPARISON_THRESHOLDS["luminanceSSIM"],
        "edgeSSIM": metrics["edgeSSIM"] >= COMPARISON_THRESHOLDS["edgeSSIM"],
        "focalSSIM": metrics["focalSSIM"] >= COMPARISON_THRESHOLDS["focalSSIM"],
        "medianDeltaE": metrics["medianDeltaE"]
        <= COMPARISON_THRESHOLDS["medianDeltaE"],
        "p95DeltaE": metrics["p95DeltaE"] <= COMPARISON_THRESHOLDS["p95DeltaE"],
        "fractionDeltaEAbove20": metrics["fractionDeltaEAbove20"]
        <= COMPARISON_THRESHOLDS["maxFractionDeltaEAbove20"],
    }


def validate_comparison_metrics(document: Any, label: str) -> dict[str, float]:
    if not isinstance(document, dict):
        raise IndexError(f"{label} is not an object")
    metrics = document.get("metrics")
    checks = document.get("checks")
    if (
        not isinstance(metrics, dict)
        or set(metrics) != COMPARISON_CHECK_KEYS
        or not all(
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(value)
            for value in metrics.values()
        )
    ):
        raise IndexError(f"{label} metrics are invalid")
    if document.get("thresholds") != COMPARISON_THRESHOLDS:
        raise IndexError(f"{label} thresholds differ")
    expected = expected_comparison_checks(metrics)
    if checks != expected or not all(expected.values()):
        raise IndexError(f"{label} checks are not all passing")
    return metrics


def source_crop_sha256(path: Path, crop: list[int]) -> str:
    x, y, width, height = crop
    try:
        with Image.open(path) as image:
            image.load()
            pixels = image.convert("RGB").crop(
                (x, y, x + width, y + height)
            ).tobytes()
    except (OSError, UnidentifiedImageError) as error:
        raise IndexError(f"responsive reference cannot be decoded: {path}") from error
    digest = hashlib.sha256()
    digest.update(b"responsive-regions-v1\0rgb\0")
    digest.update(sha256_file(path).encode("ascii"))
    digest.update(b"\0")
    for value in crop:
        digest.update(value.to_bytes(8, byteorder="big", signed=False))
    digest.update(pixels)
    return digest.hexdigest()


def valid_crop(value: Any, dimensions: list[int]) -> bool:
    if not (
        isinstance(value, list)
        and len(value) == 4
        and all(isinstance(item, int) and not isinstance(item, bool) for item in value)
        and isinstance(dimensions, list)
        and len(dimensions) == 2
    ):
        return False
    x, y, width, height = value
    return (
        x >= 0
        and y >= 0
        and width >= 7
        and height >= 7
        and x + width <= dimensions[0]
        and y + height <= dimensions[1]
    )


def outward_pixel_crop(frame: dict[str, Any]) -> list[int]:
    values = [frame.get(key) for key in ("x", "y", "width", "height")]
    if not all(
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        for value in values
    ):
        raise IndexError("responsive candidate element frame is invalid")
    x, y, width, height = values
    if width <= 0 or height <= 0:
        raise IndexError("responsive candidate element frame is empty")
    left = math.floor(x)
    top = math.floor(y)
    right = math.ceil(x + width)
    bottom = math.ceil(y + height)
    return [left, top, right - left, bottom - top]


def validate_capture_record_report_binding(
    root: Path,
    capture_root: Path,
    capture: dict[str, Any],
    report: dict[str, Any],
    capture_name: str,
) -> Path:
    record_name = capture.get("record")
    if not isinstance(record_name, str) or not record_name:
        record_name = capture_name.removesuffix(".png") + ".capture.json"
    record_path = (capture_root / record_name).resolve()
    if not record_path.is_file():
        raise IndexError(f"capture record is missing for {capture_name}")
    if (
        resolve_report_path(root, report.get("captureRecord"), "captureRecord")
        != record_path
        or report.get("captureRecordSHA256") != sha256_file(record_path)
    ):
        raise IndexError(f"comparison capture-record provenance differs for {capture_name}")
    record_document = load_json(record_path)
    if not isinstance(record_document, dict):
        raise IndexError(f"capture record is invalid for {capture_name}")
    expected_surface = capture.get("surface")
    if not isinstance(expected_surface, str) or not expected_surface:
        expected_surface = record_document.get("surface")
    if not isinstance(expected_surface, str) or not expected_surface:
        raise IndexError(f"capture surface is invalid for {capture_name}")
    record_seed_digest = validate_content_seed(
        record_document,
        {"record": record_name, "surface": expected_surface},
    )
    if (
        report.get("stateSeedSHA256") != record_seed_digest
        or capture.get("stateSeedSHA256", record_seed_digest) != record_seed_digest
    ):
        raise IndexError(f"comparison state-seed provenance differs for {capture_name}")
    return record_path


def validate_recomputed_comparison(
    root: Path,
    authority_manifest_path: Path,
    plan: dict[str, Any],
    candidate_path: Path,
    capture_record_path: Path,
    report: dict[str, Any],
    heatmap_path: Path,
    capture_name: str,
) -> None:
    comparator = load_comparator()
    try:
        with tempfile.TemporaryDirectory(prefix="theme-fidelity-recheck-") as temporary:
            output_stem = Path(temporary) / "comparison"
            recomputed = comparator.compare(
                root,
                authority_manifest_path,
                plan["id"],
                candidate_path,
                output_stem,
                capture_record_path,
            )
            recomputed_heatmap = Path(str(output_stem) + ".heatmap.png")
            supplied_payload = {key: value for key, value in report.items() if key != "heatmap"}
            recomputed_payload = {
                key: value for key, value in recomputed.items() if key != "heatmap"
            }
            if supplied_payload != recomputed_payload:
                raise IndexError(
                    f"comparison report differs from recomputed output for {capture_name}"
                )
            try:
                with Image.open(heatmap_path) as supplied_image, Image.open(
                    recomputed_heatmap
                ) as recomputed_image:
                    supplied_image.load()
                    recomputed_image.load()
                    supplied_pixels = np.asarray(supplied_image.convert("RGB"), dtype=np.uint8)
                    recomputed_pixels = np.asarray(
                        recomputed_image.convert("RGB"), dtype=np.uint8
                    )
            except (OSError, UnidentifiedImageError) as error:
                raise IndexError(
                    f"comparison heatmap cannot be recomputed for {capture_name}"
                ) from error
            if not np.array_equal(supplied_pixels, recomputed_pixels):
                raise IndexError(
                    f"comparison heatmap differs from recomputed output for {capture_name}"
                )
    except IndexError:
        raise
    except (comparator.ComparisonError, OSError, ValueError) as error:
        raise IndexError(
            f"comparison cannot be independently recomputed for {capture_name}: {error}"
        ) from error


def validate_responsive_report(
    root: Path,
    capture: dict[str, Any],
    capture_name: str,
    report: dict[str, Any],
    plan: dict[str, Any],
    asset_records: dict[str, dict[str, Any]],
    authority_root: Path,
    heatmap_path: Path,
) -> list[str]:
    if set(report) != RESPONSIVE_REPORT_KEYS:
        raise IndexError(f"responsive comparison report keys differ for {capture_name}")
    if report.get("comparisonPolicy") != RESPONSIVE_POLICY:
        raise IndexError(f"responsive comparison policy differs for {capture_name}")
    if report.get("stateSeedSHA256") != plan.get("stateSeedSHA256"):
        raise IndexError(f"responsive comparison seed differs for {capture_name}")

    frame_attestation = report.get("elementFrameAttestation")
    capture_frames = capture.get("elementFrames")
    if not isinstance(capture_frames, dict) or frame_attestation != {
        "coordinateOrigin": "top-left",
        "units": "pixels",
        "scale": capture_frames.get("scale"),
        "pixelRoundingPolicy": "outward-to-integral-bounds",
    }:
        raise IndexError(f"responsive frame attestation differs for {capture_name}")
    frame_records = capture_frames.get("frames")
    if not isinstance(frame_records, list):
        raise IndexError(f"responsive capture frames are invalid for {capture_name}")
    frames = {
        frame.get("elementID"): frame
        for frame in frame_records
        if isinstance(frame, dict) and isinstance(frame.get("elementID"), str)
    }

    layout_plan = plan.get("layoutAssertions")
    layout_report = report.get("layoutAssertions")
    viewport = capture.get("viewportAssertions")
    if (
        not isinstance(layout_plan, dict)
        or set(layout_plan) != RESPONSIVE_LAYOUT_KEYS
        or not isinstance(layout_report, dict)
        or not isinstance(viewport, dict)
    ):
        raise IndexError(f"responsive layout evidence is invalid for {capture_name}")
    expected_layout_checks = {
        "requiredElementsPresent": set(layout_plan["requiredElementIDs"]).issubset(frames),
        "requiredElementCountAttested": set(layout_plan["requiredElementIDs"]).issubset(
            set(viewport.get("requiredElementIDs", []))
        ),
        "noClippedElements": not viewport.get("clippedElementIDs"),
        "elementsWithinViewport": True,
    }
    outside: list[str] = []
    for identifier in layout_plan["withinViewportElementIDs"]:
        frame = frames.get(identifier)
        if not isinstance(frame, dict):
            outside.append(identifier)
            continue
        x, y, width, height = (frame.get(key) for key in ("x", "y", "width", "height"))
        if not (
            all(
                isinstance(value, (int, float))
                and not isinstance(value, bool)
                and math.isfinite(value)
                for value in (x, y, width, height)
            )
            and x >= 0
            and y >= 0
            and x + width <= capture["pixelWidth"]
            and y + height <= capture["pixelHeight"]
        ):
            outside.append(identifier)
    expected_layout_checks["elementsWithinViewport"] = not outside
    expected_layout = {
        "requiredElementIDs": layout_plan["requiredElementIDs"],
        "missingElementIDs": sorted(set(layout_plan["requiredElementIDs"]) - set(frames)),
        "withinViewportElementIDs": layout_plan["withinViewportElementIDs"],
        "outsideViewportElementIDs": sorted(outside),
        "requireNoClippedElements": True,
        "attestedRequiredElementCount": viewport.get("requiredElementCount"),
        "attestedRequiredElementIDs": viewport.get("requiredElementIDs"),
        "attestedClippedElementIDs": viewport.get("clippedElementIDs"),
        "checks": expected_layout_checks,
    }
    if layout_report != expected_layout or not all(expected_layout_checks.values()):
        raise IndexError(f"responsive layout assertions fail for {capture_name}")

    plan_regions = plan.get("regions")
    report_regions = report.get("regions")
    if not (
        isinstance(plan_regions, list)
        and plan_regions
        and isinstance(report_regions, list)
        and len(report_regions) == len(plan_regions)
    ):
        raise IndexError(f"responsive region inventory differs for {capture_name}")
    atlas_y = 0
    atlas_width = 0
    expected_atlas: list[dict[str, Any]] = []
    region_metrics: list[dict[str, float]] = []
    reference_digests: list[str] = []
    for plan_region, region_report in zip(plan_regions, report_regions):
        if (
            not isinstance(plan_region, dict)
            or set(plan_region) != RESPONSIVE_REGION_KEYS
            or not isinstance(region_report, dict)
            or set(region_report) != RESPONSIVE_REPORT_REGION_KEYS
        ):
            raise IndexError(f"responsive region schema differs for {capture_name}")
        region_id = plan_region.get("id")
        if region_report.get("id") != region_id or region_report.get("result") != "PASS":
            raise IndexError(f"responsive region identity/result differs for {capture_name}")
        if plan_region.get("thresholds") != COMPARISON_THRESHOLDS:
            raise IndexError(f"responsive region threshold plan differs for {capture_name}")
        region_metrics.append(
            validate_comparison_metrics(
                region_report, f"responsive region {region_id} for {capture_name}"
            )
        )

        reference_key = plan_region.get("reference")
        reference_record = asset_records.get(reference_key)
        if (
            not isinstance(reference_key, str)
            or Path(reference_key).parts[:1] != ("goldens",)
            or not isinstance(reference_record, dict)
        ):
            raise IndexError(f"responsive reference is undeclared for {capture_name}")
        reference_path = (authority_root / reference_key).resolve()
        if (
            not is_within(reference_path, authority_root)
            or not reference_path.is_file()
            or sha256_file(reference_path) != reference_record.get("sha256")
            or region_report.get("referenceSHA256") != reference_record.get("sha256")
            or resolve_report_path(root, region_report.get("reference"), "reference")
            != reference_path
            or region_report.get("referenceDimensions")
            != reference_record.get("dimensions")
        ):
            raise IndexError(f"responsive reference provenance differs for {capture_name}")
        reference_digests.append(reference_record["sha256"])
        crop = plan_region.get("sourceCrop")
        if not valid_crop(crop, reference_record["dimensions"]):
            raise IndexError(f"responsive source crop is invalid for {capture_name}")
        crop_digest = source_crop_sha256(reference_path, crop)
        if (
            plan_region.get("sourceCropSHA256") != crop_digest
            or region_report.get("sourceCrop") != crop
            or region_report.get("sourceCropSHA256") != crop_digest
            or region_report.get("sourceDimensions") != crop[2:4]
        ):
            raise IndexError(f"responsive source-crop provenance differs for {capture_name}")

        candidate_id = plan_region.get("candidateElementID")
        frame = frames.get(candidate_id)
        if not isinstance(frame, dict):
            raise IndexError(f"responsive candidate frame is absent for {capture_name}")
        expected_frame = {key: frame[key] for key in ("x", "y", "width", "height")}
        pixel_crop = outward_pixel_crop(frame)
        if (
            pixel_crop[0] < 0
            or pixel_crop[1] < 0
            or pixel_crop[0] + pixel_crop[2] > capture["pixelWidth"]
            or pixel_crop[1] + pixel_crop[3] > capture["pixelHeight"]
            or crop[2] * pixel_crop[3] != crop[3] * pixel_crop[2]
        ):
            raise IndexError(f"responsive candidate aspect/bounds differ for {capture_name}")
        if (
            region_report.get("candidateElementID") != candidate_id
            or region_report.get("candidateElementFrame") != expected_frame
            or region_report.get("candidatePixelCrop") != pixel_crop
            or region_report.get("candidateRegionDimensions") != pixel_crop[2:4]
            or region_report.get("candidateNormalizedToSource")
            != (pixel_crop[2:4] != crop[2:4])
            or region_report.get("aspectRatioPreserved") is not True
            or region_report.get("focalRegion") != [0, 0, crop[2], crop[3]]
        ):
            raise IndexError(f"responsive candidate-region provenance differs for {capture_name}")

        mask_key = plan_region.get("mask")
        scored_fraction = 1.0
        if mask_key is None:
            if (
                region_report.get("approvedMask") is not None
                or region_report.get("approvedMaskSHA256") is not None
            ):
                raise IndexError(f"responsive report unexpectedly masks {capture_name}")
        else:
            mask_record = asset_records.get(mask_key)
            mask_path = (authority_root / str(mask_key)).resolve()
            if (
                not isinstance(mask_record, dict)
                or str(mask_record.get("role", "")).lower() != PLATFORM_MASK_ROLE
                or mask_record.get("dimensions") != crop[2:4]
                or not is_within(mask_path, authority_root)
                or not mask_path.is_file()
                or sha256_file(mask_path) != mask_record.get("sha256")
                or resolve_report_path(root, region_report.get("approvedMask"), "approvedMask")
                != mask_path
                or region_report.get("approvedMaskSHA256") != mask_record.get("sha256")
            ):
                raise IndexError(f"responsive mask provenance differs for {capture_name}")
            try:
                with Image.open(mask_path) as mask_image:
                    mask_image.load()
                    mask_values = np.asarray(mask_image.convert("L"), dtype=np.uint8)
            except (OSError, UnidentifiedImageError) as error:
                raise IndexError(f"responsive mask cannot be decoded for {capture_name}") from error
            values = set(int(value) for value in np.unique(mask_values))
            if not values.issubset({0, 255}) or 255 not in values:
                raise IndexError(f"responsive mask pixels are invalid for {capture_name}")
            scored_fraction = float(np.mean(mask_values == 255))
        scored_report = region_report.get("scoredPixelFraction")
        if not (
            isinstance(scored_report, (int, float))
            and not isinstance(scored_report, bool)
            and math.isclose(float(scored_report), scored_fraction, rel_tol=0.0, abs_tol=1e-12)
        ):
            raise IndexError(f"responsive scored-pixel fraction differs for {capture_name}")

        atlas_frame = [0, atlas_y, crop[2], crop[3]]
        expected_atlas.append({"regionID": region_id, "frame": atlas_frame})
        if region_report.get("heatmapAtlasFrame") != atlas_frame:
            raise IndexError(f"responsive heatmap placement differs for {capture_name}")
        atlas_y += crop[3]
        atlas_width = max(atlas_width, crop[2])

    aggregate_metrics = {
        "luminanceSSIM": min(item["luminanceSSIM"] for item in region_metrics),
        "edgeSSIM": min(item["edgeSSIM"] for item in region_metrics),
        "focalSSIM": min(item["focalSSIM"] for item in region_metrics),
        "medianDeltaE": max(item["medianDeltaE"] for item in region_metrics),
        "p95DeltaE": max(item["p95DeltaE"] for item in region_metrics),
        "fractionDeltaEAbove20": max(
            item["fractionDeltaEAbove20"] for item in region_metrics
        ),
    }
    if report.get("metrics") != aggregate_metrics:
        raise IndexError(f"responsive aggregate metrics differ for {capture_name}")
    validate_comparison_metrics(report, f"responsive aggregate for {capture_name}")
    if report.get("aggregateChecks") != {
        "allRegionsPass": True,
        "layoutAssertionsPass": True,
    }:
        raise IndexError(f"responsive aggregate checks differ for {capture_name}")
    if (
        report.get("regionCount") != len(plan_regions)
        or report.get("passingRegionCount") != len(plan_regions)
        or report.get("heatmapAtlas") != expected_atlas
    ):
        raise IndexError(f"responsive aggregate inventory differs for {capture_name}")
    try:
        with Image.open(heatmap_path) as heatmap_image:
            heatmap_image.load()
            if heatmap_image.format != "PNG" or list(heatmap_image.size) != [
                atlas_width,
                atlas_y,
            ]:
                raise IndexError(f"responsive heatmap atlas dimensions differ for {capture_name}")
    except (OSError, UnidentifiedImageError) as error:
        raise IndexError(f"responsive heatmap atlas cannot be decoded for {capture_name}") from error
    return reference_digests


def validate_legacy_report(
    root: Path,
    capture_name: str,
    report: dict[str, Any],
    plan: dict[str, Any],
    asset_records: dict[str, dict[str, Any]],
    authority_root: Path,
    heatmap_path: Path,
) -> str:
    if set(report) != LEGACY_REPORT_KEYS:
        raise IndexError(f"legacy comparison report keys differ for {capture_name}")
    reference_key = plan.get("reference")
    reference_record = asset_records.get(reference_key)
    if not isinstance(reference_record, dict):
        raise IndexError(f"comparison reference is undeclared for {capture_name}")
    reference_path = (authority_root / str(reference_key)).resolve()
    if (
        not is_within(reference_path, authority_root)
        or not reference_path.is_file()
        or report.get("referenceSHA256") != reference_record.get("sha256")
        or sha256_file(reference_path) != reference_record.get("sha256")
        or resolve_report_path(root, report.get("reference"), "reference") != reference_path
    ):
        raise IndexError(f"comparison reference provenance differs for {capture_name}")
    if report.get("referenceDimensions") != reference_record.get("dimensions"):
        raise IndexError(f"comparison reference dimensions differ for {capture_name}")
    candidate_dimensions = report.get("candidateDimensions")
    reference_dimensions = reference_record["dimensions"]
    if (
        candidate_dimensions[0] * reference_dimensions[1]
        != candidate_dimensions[1] * reference_dimensions[0]
        or report.get("candidateNormalizedToReference")
        is not (candidate_dimensions != reference_dimensions)
    ):
        raise IndexError(f"comparison candidate normalization differs for {capture_name}")
    if not valid_crop(plan.get("focalRegion"), reference_dimensions) or report.get(
        "focalRegion"
    ) != plan.get("focalRegion"):
        raise IndexError(f"comparison focal region differs for {capture_name}")
    mask_key = plan.get("mask")
    scored_fraction = 1.0
    if mask_key is None:
        if report.get("approvedMask") is not None:
            raise IndexError(f"comparison report unexpectedly uses a mask for {capture_name}")
    else:
        mask_record = asset_records.get(mask_key)
        mask_path = (authority_root / str(mask_key)).resolve()
        if (
            not isinstance(mask_record, dict)
            or mask_record.get("dimensions") != reference_dimensions
            or not is_within(mask_path, authority_root)
            or not mask_path.is_file()
            or sha256_file(mask_path) != mask_record.get("sha256")
            or resolve_report_path(root, report.get("approvedMask"), "approvedMask")
            != mask_path
        ):
            raise IndexError(f"comparison mask provenance differs for {capture_name}")
        try:
            with Image.open(mask_path) as mask_image:
                mask_image.load()
                mask_values = np.asarray(mask_image.convert("L"), dtype=np.uint8)
        except (OSError, UnidentifiedImageError) as error:
            raise IndexError(f"comparison mask cannot be decoded for {capture_name}") from error
        values = set(int(value) for value in np.unique(mask_values))
        if not values.issubset({0, 255}) or 255 not in values:
            raise IndexError(f"comparison mask pixels are invalid for {capture_name}")
        scored_fraction = float(np.mean(mask_values == 255))
    scored_report = report.get("scoredPixelFraction")
    if not (
        isinstance(scored_report, (int, float))
        and not isinstance(scored_report, bool)
        and math.isclose(float(scored_report), scored_fraction, rel_tol=0.0, abs_tol=1e-12)
    ):
        raise IndexError(f"comparison scored-pixel fraction differs for {capture_name}")
    try:
        with Image.open(heatmap_path) as heatmap_image:
            heatmap_image.load()
            if (
                heatmap_image.format != "PNG"
                or list(heatmap_image.size) != report.get("referenceDimensions")
            ):
                raise IndexError(f"comparison heatmap dimensions differ for {capture_name}")
    except (OSError, UnidentifiedImageError) as error:
        raise IndexError(f"comparison heatmap cannot be decoded for {capture_name}") from error
    return reference_record["sha256"]


def validate_final_comparisons(
    root: Path,
    capture_root: Path,
    captures: list[dict[str, Any]],
    comparison_index_path: Path,
    authority_manifest_path: Path,
) -> dict[str, Any]:
    if not is_within(authority_manifest_path.resolve(), root):
        raise IndexError("authority manifest must be inside the repository root")
    document = load_json(comparison_index_path)
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "phase", "mappings"}:
        raise IndexError("comparison index schema is invalid")
    if document.get("schemaVersion") != SCHEMA_VERSION or document.get("phase") != "final":
        raise IndexError("comparison index must be schemaVersion 1.0 and phase final")
    mappings = document.get("mappings")
    if not isinstance(mappings, list) or len(mappings) != 400:
        raise IndexError("final comparison index must contain exactly 400 mappings")

    authority = load_json(authority_manifest_path)
    if not isinstance(authority, dict) or authority.get("schemaVersion") != SCHEMA_VERSION:
        raise IndexError("authority manifest schema is invalid")
    comparison_plans = authority.get("comparisons")
    assets = authority.get("assets")
    authority_root_value = authority.get("authorityRoot")
    if not isinstance(comparison_plans, list) or not isinstance(assets, list):
        raise IndexError("authority manifest comparison/asset arrays are invalid")
    if (
        not isinstance(authority_root_value, str)
        or not authority_root_value
        or Path(authority_root_value).is_absolute()
    ):
        raise IndexError("authority manifest authorityRoot is invalid")
    authority_root = (root / authority_root_value).resolve()
    if not is_within(authority_root, root):
        raise IndexError("authorityRoot escapes the repository root")
    if (
        is_within(capture_root, authority_root)
        or is_within(comparison_index_path, authority_root)
    ):
        raise IndexError("capture/comparison evidence must not be stored in authorityRoot")
    plans: dict[str, dict[str, Any]] = {}
    planned_captures: set[str] = set()
    for plan in comparison_plans:
        if not isinstance(plan, dict):
            raise IndexError("authority manifest contains an invalid comparison plan")
        if plan.get("policy") == RESPONSIVE_POLICY:
            if set(plan) != RESPONSIVE_PLAN_KEYS or not valid_sha256(
                plan.get("stateSeedSHA256")
            ):
                raise IndexError("authority manifest contains an invalid responsive plan")
            regions = plan.get("regions")
            layout = plan.get("layoutAssertions")
            if not isinstance(regions, list) or not regions:
                raise IndexError("responsive plan regions are invalid")
            if not isinstance(layout, dict) or set(layout) != RESPONSIVE_LAYOUT_KEYS:
                raise IndexError("responsive plan layout assertions are invalid")
            region_ids: list[str] = []
            candidate_ids: set[str] = set()
            for region in regions:
                if not isinstance(region, dict) or set(region) != RESPONSIVE_REGION_KEYS:
                    raise IndexError("responsive plan region schema is invalid")
                if region.get("thresholds") != COMPARISON_THRESHOLDS:
                    raise IndexError("responsive plan thresholds differ")
                region_id = region.get("id")
                candidate_id = region.get("candidateElementID")
                if not isinstance(region_id, str) or not region_id:
                    raise IndexError("responsive plan region id is invalid")
                if not isinstance(candidate_id, str) or not candidate_id:
                    raise IndexError("responsive plan candidate element id is invalid")
                region_ids.append(region_id)
                candidate_ids.add(candidate_id)
            if region_ids != sorted(region_ids) or len(region_ids) != len(set(region_ids)):
                raise IndexError("responsive plan regions must be sorted and unique")
            required_ids = layout.get("requiredElementIDs")
            within_ids = layout.get("withinViewportElementIDs")
            for label, values in (
                ("requiredElementIDs", required_ids),
                ("withinViewportElementIDs", within_ids),
            ):
                if not (
                    isinstance(values, list)
                    and values
                    and all(isinstance(value, str) and value for value in values)
                    and values == sorted(values)
                    and len(values) == len(set(values))
                ):
                    raise IndexError(f"responsive plan {label} is invalid")
            if (
                layout.get("requireNoClippedElements") is not True
                or not set(within_ids).issubset(set(required_ids))
                or not candidate_ids.issubset(set(within_ids))
            ):
                raise IndexError("responsive plan layout assertion relationships are invalid")
        elif not LEGACY_PLAN_REQUIRED_KEYS.issubset(plan) or not set(plan).issubset(
            LEGACY_PLAN_KEYS
        ):
            raise IndexError("authority manifest contains an invalid legacy comparison plan")
        if not (
            isinstance(plan.get("id"), str)
            and plan["id"]
            and isinstance(plan.get("capture"), str)
            and plan["capture"]
            and Path(plan["capture"]).name == plan["capture"]
            and plan["capture"].endswith(".png")
        ):
            raise IndexError("authority manifest comparison identity is invalid")
        if plan["id"] in plans:
            raise IndexError(f"authority manifest repeats comparison id {plan['id']}")
        if plan["capture"] in planned_captures:
            raise IndexError(f"authority manifest repeats capture {plan['capture']}")
        plans[plan["id"]] = plan
        planned_captures.add(plan["capture"])
    asset_records: dict[str, dict[str, Any]] = {}
    for asset in assets:
        if not (
            isinstance(asset, dict)
            and isinstance(asset.get("path"), str)
            and asset["path"]
            and valid_sha256(asset.get("sha256"))
            and isinstance(asset.get("dimensions"), list)
            and len(asset["dimensions"]) == 2
            and all(
                isinstance(value, int) and not isinstance(value, bool) and value > 0
                for value in asset["dimensions"]
            )
        ):
            raise IndexError("authority manifest contains an invalid asset record")
        if asset["path"] in asset_records:
            raise IndexError(f"authority manifest repeats asset path {asset['path']}")
        asset_records[asset["path"]] = asset
    authority_digest = sha256_file(authority_manifest_path)
    by_capture = {capture["png"]: capture for capture in captures}
    if len(plans) != 400 or planned_captures != set(by_capture):
        raise IndexError("authority manifest must map the exact 400 capture set")
    seen: set[str] = set()
    seen_reports: set[Path] = set()
    seen_heatmaps: set[Path] = set()
    mapping_root = comparison_index_path.resolve().parent
    indexed_mappings: list[dict[str, Any]] = []
    for mapping in mappings:
        if not isinstance(mapping, dict) or set(mapping) != FINAL_COMPARISON_KEYS:
            raise IndexError("comparison mapping keys are invalid")
        capture_name = mapping.get("capture")
        if capture_name not in by_capture or capture_name in seen:
            raise IndexError(f"comparison mapping capture is unexpected or repeated: {capture_name!r}")
        seen.add(capture_name)
        capture = by_capture[capture_name]
        candidate_digest = capture["pngSHA256"]
        if mapping.get("candidateSHA256") != candidate_digest:
            raise IndexError(f"comparison mapping candidate digest differs for {capture_name}")
        if mapping.get("result") != "PASS":
            raise IndexError(f"comparison mapping is pending or failed for {capture_name}")
        comparison_id = mapping.get("comparisonID")
        if comparison_id not in plans:
            raise IndexError(f"comparison mapping uses undeclared comparisonID for {capture_name}")
        plan = plans[comparison_id]
        if plan.get("capture") != capture_name:
            raise IndexError(f"authority comparison plan is mapped to another capture: {capture_name}")
        expected_policy = (
            RESPONSIVE_POLICY
            if plan.get("policy") == RESPONSIVE_POLICY
            else ("approved-mask" if plan.get("mask") is not None else "full-frame")
        )
        if mapping.get("regionPolicy") != expected_policy:
            raise IndexError(f"comparison mapping regionPolicy differs for {capture_name}")
        report_path = resolve_mapping_path(mapping_root, mapping.get("report"), "mapping.report")
        heatmap_path = resolve_mapping_path(mapping_root, mapping.get("heatmap"), "mapping.heatmap")
        if report_path in seen_reports or heatmap_path in seen_heatmaps:
            raise IndexError(f"comparison report/heatmap is reused for {capture_name}")
        seen_reports.add(report_path)
        seen_heatmaps.add(heatmap_path)
        if is_within(report_path, authority_root) or is_within(heatmap_path, authority_root):
            raise IndexError(f"comparison output is stored in authorityRoot for {capture_name}")
        if not report_path.is_file() or not valid_sha256(mapping.get("reportSHA256")):
            raise IndexError(f"comparison report is missing or unbound for {capture_name}")
        if sha256_file(report_path) != mapping["reportSHA256"]:
            raise IndexError(f"comparison report digest differs for {capture_name}")
        if not heatmap_path.is_file() or not valid_sha256(mapping.get("heatmapSHA256")):
            raise IndexError(f"comparison heatmap is missing or unbound for {capture_name}")
        if sha256_file(heatmap_path) != mapping["heatmapSHA256"]:
            raise IndexError(f"comparison heatmap digest differs for {capture_name}")
        if heatmap_path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise IndexError(f"comparison heatmap is not PNG for {capture_name}")
        report = load_json(report_path)
        required_report = {
            "schemaVersion": SCHEMA_VERSION,
            "result": "PASS",
            "comparisonID": comparison_id,
            "manifestSHA256": authority_digest,
            "candidateSHA256": candidate_digest,
        }
        for key, expected in required_report.items():
            if not isinstance(report, dict) or report.get(key) != expected:
                raise IndexError(f"comparison report {key} differs for {capture_name}")
        if resolve_report_path(root, report.get("manifest"), "manifest") != authority_manifest_path.resolve():
            raise IndexError(f"comparison report manifest path differs for {capture_name}")
        capture_record_path = validate_capture_record_report_binding(
            root, capture_root, capture, report, capture_name
        )
        validate_comparison_metrics(report, f"comparison report for {capture_name}")
        report_candidate = resolve_report_path(root, report.get("candidate"), "candidate")
        if report_candidate != (capture_root / capture_name).resolve():
            raise IndexError(f"comparison report candidate path differs for {capture_name}")
        report_heatmap = resolve_report_path(root, report.get("heatmap"), "heatmap")
        if report_heatmap != heatmap_path:
            raise IndexError(f"comparison report heatmap path differs for {capture_name}")
        candidate_dimensions = report.get("candidateDimensions")
        if not (
            isinstance(candidate_dimensions, list)
            and len(candidate_dimensions) == 2
            and all(
                isinstance(value, int) and not isinstance(value, bool) and value > 0
                for value in candidate_dimensions
            )
        ):
            raise IndexError(f"comparison candidate dimensions are invalid for {capture_name}")
        if "pixelWidth" in capture and candidate_dimensions != [
            capture["pixelWidth"],
            capture["pixelHeight"],
        ]:
            raise IndexError(f"comparison candidate dimensions differ for {capture_name}")
        if expected_policy == RESPONSIVE_POLICY:
            reference_digests = validate_responsive_report(
                root,
                capture,
                capture_name,
                report,
                plan,
                asset_records,
                authority_root,
                heatmap_path,
            )
        else:
            reference_digests = [
                validate_legacy_report(
                    root,
                    capture_name,
                    report,
                    plan,
                    asset_records,
                    authority_root,
                    heatmap_path,
                )
            ]
        validate_recomputed_comparison(
            root,
            authority_manifest_path,
            plan,
            report_candidate,
            capture_record_path,
            report,
            heatmap_path,
            capture_name,
        )
        capture["comparisonResult"] = "pass"
        capture["comparison"] = {
            "comparisonID": comparison_id,
            "regionPolicy": expected_policy,
            "report": str(report_path),
            "reportSHA256": mapping["reportSHA256"],
            "heatmap": str(heatmap_path),
            "heatmapSHA256": mapping["heatmapSHA256"],
            "referenceSHA256": reference_digests[0]
            if len(reference_digests) == 1
            else None,
            "referenceSHA256s": reference_digests,
        }
        indexed_mappings.append(
            {
                "capture": capture_name,
                "candidateSHA256": candidate_digest,
                **capture["comparison"],
            }
        )
    if seen != set(by_capture):
        raise IndexError("final comparison index does not map the exact 400 capture set")
    if any(capture["comparisonResult"] != "pass" for capture in captures):
        raise IndexError("final comparison results contain a non-pass state")
    return {
        "path": str(comparison_index_path.resolve()),
        "sha256": sha256_file(comparison_index_path),
        "authorityManifest": str(authority_manifest_path.resolve()),
        "authorityManifestSHA256": authority_digest,
        "mappingCount": len(indexed_mappings),
        "mappings": indexed_mappings,
    }


def build_evidence(arguments: argparse.Namespace) -> dict[str, Any]:
    capture_root = arguments.captures.resolve()
    matrix_path = arguments.matrix.resolve()
    root = arguments.root.resolve()
    canonical_authority_manifest = (root / DEFAULT_AUTHORITY_MANIFEST).resolve()
    if arguments.authority_manifest.resolve() != canonical_authority_manifest:
        raise IndexError(
            "authority manifest must be the canonical repository manifest used by the comparator"
        )
    commands = validate_commands(arguments.command)
    validate_timestamps(arguments.started_at, arguments.ended_at)
    source_before_path = arguments.source_manifest_before.resolve()
    source_after_path = arguments.source_manifest_after.resolve()
    source_before = load_json(source_before_path)
    source_after = load_json(source_after_path)
    validate_source_manifest_pair(source_before, source_after)
    source_exclusion = (
        arguments.source_exclusion.resolve()
        if arguments.source_exclusion is not None
        else capture_root.parent.resolve()
    )
    current_source = source_manifest(root, [source_exclusion])
    validate_source_manifest_pair(source_after, current_source)

    captures, dimensions, capture_findings = validate_captures(
        root,
        matrix_path,
        capture_root,
        arguments.phase,
    )
    extraction = validate_extraction_report(
        arguments.extraction_report.resolve(), capture_root, captures
    )
    toolchain = validate_toolchain_report(arguments.toolchain_report.resolve())
    if Path(extraction["xcresulttool"]).resolve() != Path(
        toolchain["details"]["executables"]["xcresulttool"]["path"]
    ).resolve():
        raise IndexError("extraction xcresulttool differs from the hashed toolchain")
    if len(arguments.command_log) != 3:
        raise IndexError("exactly three hosted capture command logs are required")
    runtime_findings, command_logs = runtime_diagnostics(arguments.command_log)
    all_findings = capture_findings + runtime_findings
    enforce_final_diagnostics(arguments.phase, runtime_findings, "runtime")

    if arguments.phase == "final":
        if arguments.comparison_index is None:
            raise IndexError("final phase requires a 400-entry comparison index")
        comparison = validate_final_comparisons(
            root,
            capture_root,
            captures,
            arguments.comparison_index.resolve(),
            arguments.authority_manifest.resolve(),
        )
    else:
        comparison = {
            "required": False,
            "result": "not-evaluated",
            "mappingCount": 0,
            "mappings": [],
        }

    final_source = source_manifest(root, [source_exclusion])
    validate_source_manifest_pair(source_after, final_source)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "phase": arguments.phase,
        "sourceSHA": source_after["sourceSHA"],
        "sourceBinding": {
            "aggregateSHA256": source_after["aggregateSHA256"],
            "gitStatusSHA256": source_after["gitStatusSHA256"],
            "isClean": source_after["isClean"],
            "beforeManifestPath": str(source_before_path),
            "beforeManifestSHA256": sha256_file(source_before_path),
            "afterManifestPath": str(source_after_path),
            "afterManifestSHA256": sha256_file(source_after_path),
            "prePostEqual": True,
        },
        "matrix": {
            "path": str(matrix_path),
            "sha256": MATRIX_SHA256,
            "themeCount": 5,
            "surfaceCountPerTheme": 20,
            "destinationCount": 4,
            "captureCount": 400,
        },
        "commands": commands,
        "startTimestamp": arguments.started_at,
        "endTimestamp": arguments.ended_at,
        "toolchain": toolchain,
        "destinations": dimensions,
        "result": "pass",
        "failures": [],
        "diagnostics": {
            "blocking": arguments.phase == "final",
            "count": len(all_findings),
            "findings": all_findings,
        },
        "comparisonEvidence": comparison,
        "outputPaths": {
            "captureRoot": str(capture_root),
            "sourceManifestBefore": str(source_before_path),
            "sourceManifestAfter": str(source_after_path),
            "extraction": extraction,
            "commandLogs": command_logs,
        },
        "captures": captures,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--matrix",
        type=Path,
        default=Path("docs/verification/theme-fidelity-v4/Golden-Screenshot-Matrix.json"),
    )
    parser.add_argument("--captures", required=True, type=Path)
    parser.add_argument("--phase", required=True, choices=("baseline", "final"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-manifest-before", required=True, type=Path)
    parser.add_argument("--source-manifest-after", required=True, type=Path)
    parser.add_argument("--source-exclusion", type=Path)
    parser.add_argument("--extraction-report", required=True, type=Path)
    parser.add_argument("--toolchain-report", required=True, type=Path)
    parser.add_argument("--command-log", action="append", required=True, type=Path)
    parser.add_argument("--comparison-index", type=Path)
    parser.add_argument(
        "--authority-manifest",
        type=Path,
        default=DEFAULT_AUTHORITY_MANIFEST,
    )
    parser.add_argument("--command", action="append", required=True)
    parser.add_argument("--started-at", required=True)
    parser.add_argument("--ended-at", required=True)
    arguments = parser.parse_args()
    if not arguments.authority_manifest.is_absolute():
        arguments.authority_manifest = arguments.root / arguments.authority_manifest
    try:
        evidence = build_evidence(arguments)
        write_json(arguments.output, evidence)
    except IndexError as error:
        failure = {
            "schemaVersion": SCHEMA_VERSION,
            "phase": arguments.phase,
            "result": "fail",
            "failures": [str(error)],
            "command": arguments.command,
            "startTimestamp": arguments.started_at,
            "endTimestamp": arguments.ended_at,
            "toolchainReport": str(arguments.toolchain_report.resolve()),
        }
        write_json(arguments.output, failure)
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: indexed {len(evidence['captures'])} captures")
    print(f"SOURCE: {evidence['sourceBinding']['aggregateSHA256']}")
    print(f"OUTPUT: {arguments.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
