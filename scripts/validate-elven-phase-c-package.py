#!/usr/bin/env python3
"""Fail-closed semantic validation for an Elven Phase C production package."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import mimetypes
import os
import re
import subprocess
import sys
import unicodedata
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

from PIL import Image
from fontTools.pens.recordingPen import RecordingPen
from fontTools.ttLib import TTFont


SCOPES = (
    "output-matrix",
    "relics",
    "seals",
    "fonts",
    "share-accessibility-fallbacks",
    "provenance-recipes",
    "budgets-integrity",
    "publication",
)

ASSET_MANIFEST = "Rune-Scribe-Elven-Series-Asset-Manifest-v1.0.json"
PACKAGE_MANIFEST = "PACKAGE-MANIFEST.json"
EXPECTED_CODEX_IDS = {
    "codex.moonleaf",
    "codex.sunspire",
    "codex.wildwood",
    "codex.gloamthorn",
}
CLASS_COUNTS_PER_CODEX = {
    "script": 1,
    "background": 1,
    "vault": 1,
    "relic": 3,
    "seal": 6,
    "frame": 1,
    "crest": 1,
}
ROLE_SETS = {
    "script": {"script.font", "script.static-fallback", "script.specimen-preview"},
    "background": {
        "background.static-base",
        "background.reduce-motion",
        "background.high-contrast",
    },
    "vault": {"vault.card", "vault.locked-silhouette", "vault.encountered", "vault.selected"},
    "relic": {
        "relic.master",
        "relic.thumbnail",
        "relic.static-share-fallback",
        "relic.high-contrast",
    },
    "seal": {"seal.vector-master", "seal.monochrome-fallback", "seal.thumbnail"},
    "frame": {"frame.vector-master", "frame.static-fallback", "frame.thumbnail"},
    "crest": {"crest.vector-master", "crest.static-fallback", "crest.thumbnail"},
}
ROLE_MEDIA = {
    "script.font": {"font/ttf", "font/otf"},
    "script.static-fallback": {"image/png", "application/pdf"},
    "script.specimen-preview": {"image/png", "image/heif"},
    "background.static-base": {"image/png", "image/heif"},
    "background.reduce-motion": {"image/png", "image/heif"},
    "background.high-contrast": {"image/png", "image/heif"},
    "vault.card": {"image/png", "image/heif"},
    "vault.locked-silhouette": {"image/png", "image/heif"},
    "vault.encountered": {"image/png", "image/heif"},
    "vault.selected": {"image/png", "image/heif"},
    "relic.master": {"image/png"},
    "relic.thumbnail": {"image/heif"},
    "relic.static-share-fallback": {"image/heif"},
    "relic.high-contrast": {"image/png"},
    "seal.vector-master": {"application/pdf"},
    "seal.monochrome-fallback": {"application/pdf"},
    "seal.thumbnail": {"image/png"},
    "frame.vector-master": {"application/pdf"},
    "frame.static-fallback": {"image/png", "application/pdf"},
    "frame.thumbnail": {"image/png", "image/heif"},
    "crest.vector-master": {"application/pdf"},
    "crest.static-fallback": {"image/png", "application/pdf"},
    "crest.thumbnail": {"image/png", "image/heif"},
}
MATRIX_RESOURCE_FIELDS = {
    "resourceID",
    "artifactID",
    "ownerCodexID",
    "assetClass",
    "sourceClass",
    "semanticRole",
    "requiredOrOptional",
    "sourceMasterPath",
    "sourceMediaType",
    "sourceViewBoxOrDimensions",
    "outputVariants",
    "fallbackResourceID",
    "fallbackBehavior",
    "accessibility",
    "budgetClass",
    "provenanceID",
}
MATRIX_OUTPUT_FIELDS = {
    "resourceID",
    "artifactID",
    "outputRole",
    "filename",
    "mediaType",
    "dimensionsOrViewBox",
    "colorSpace",
    "alphaPolicy",
    "byteLimit",
    "maximumBytes",
    "requiredOrOptional",
    "status",
    "byteLength",
    "sha256",
    "fallbackResourceID",
    "fallbackBehavior",
    "accessibility",
    "exportRecipeID",
    "provenanceID",
    "createdAtUTC",
}
PROVENANCE_FIELDS = {
    "provenanceID",
    "assetIDOrResourceID",
    "creatorOrCommissioningEntity",
    "actualAuthoringToolAndVersion",
    "creationDateUTC",
    "rightsHolder",
    "rightsBasisOrLicense",
    "originalOrDerivedStatus",
    "derivationDescription",
    "sourceReference",
    "sourceReferenceSHA256",
    "sourceMasterPath",
    "sourceMasterSHA256",
    "thirdPartyInputs",
    "exportRecipeID",
    "exportSettings",
    "outputFiles",
    "approvalStatus",
    "approvedBy",
    "approvalDateUTC",
    "revisionHistory",
}
FONT_EVIDENCE_KINDS = {
    "small",
    "normal",
    "large",
    "long-inscription",
    "minimum-size",
    "high-contrast",
}
ALLOWED_MEDIA = {
    "application/json",
    "image/png",
    "image/heif",
    "application/pdf",
    "font/ttf",
    "font/otf",
    "video/mp4",
    "video/quicktime",
    "audio/mp4",
    "audio/x-caf",
    "audio/wav",
}
SHIPPING_SUFFIXES = {".json", ".png", ".heif", ".heic", ".pdf", ".ttf", ".otf", ".mp4", ".mov", ".m4a", ".caf", ".wav"}
TEXT_SUFFIXES = {".json", ".md", ".txt", ".svg", ".xml", ".yaml", ".yml", ".swift", ".plist", ".csv"}
HASH_PATTERN = re.compile(r"[0-9a-f]{64}")
UTC_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")


class DuplicateKeyError(ValueError):
    """Raised when a JSON object repeats a key."""


def reject_duplicate_keys(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json_strict(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)


def sha256_file(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def tag_name(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1].lower()


def is_nonempty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def valid_utc_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or not UTC_PATTERN.fullmatch(value):
        return False
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None and parsed.utcoffset() == dt.timedelta(0)


def as_list(value: Any) -> List[Any]:
    return value if isinstance(value, list) else []


def normalized_relative_path(value: Any) -> Optional[str]:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        return None
    if value != unicodedata.normalize("NFC", value):
        return None
    pure = PurePosixPath(value)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        return None
    if pure.as_posix() != value or any(ord(character) < 32 for character in value):
        return None
    return value


def actual_media_type(path: Path) -> str:
    suffix = path.suffix.lower()
    explicit = {
        ".png": "image/png",
        ".heif": "image/heif",
        ".heic": "image/heif",
        ".pdf": "application/pdf",
        ".ttf": "font/ttf",
        ".otf": "font/otf",
        ".json": "application/json",
    }
    return explicit.get(suffix, mimetypes.guess_type(path.name)[0] or "application/octet-stream")


def dimensions_from_declaration(value: Any) -> Optional[Tuple[int, int]]:
    if isinstance(value, list) and len(value) == 2 and all(isinstance(item, (int, float)) for item in value):
        width, height = value
    elif isinstance(value, dict):
        width, height = value.get("width"), value.get("height")
        if not isinstance(width, (int, float)) or not isinstance(height, (int, float)):
            return None
    else:
        return None
    if width <= 0 or height <= 0:
        return None
    return round(width), round(height)


def image_dimensions(path: Path) -> Optional[Tuple[int, int]]:
    try:
        with Image.open(path) as image:
            return image.size
    except Exception:
        if path.suffix.lower() not in {".heif", ".heic"}:
            return None
    try:
        result = subprocess.run(
            ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
        width = re.search(r"pixelWidth:\s*(\d+)", result.stdout)
        height = re.search(r"pixelHeight:\s*(\d+)", result.stdout)
        if result.returncode == 0 and width and height:
            return int(width.group(1)), int(height.group(1))
    except Exception:
        return None
    return None


def svg_viewbox(path: Path) -> Optional[Tuple[float, float, float, float]]:
    try:
        root = ET.fromstring(path.read_text(encoding="utf-8"))
        values = [float(item) for item in re.split(r"[ ,]+", root.attrib.get("viewBox", "").strip()) if item]
        if len(values) == 4 and all(math.isfinite(item) for item in values) and values[2] > 0 and values[3] > 0:
            return values[0], values[1], values[2], values[3]
    except Exception:
        return None
    return None


def normalized_region(value: Any) -> Optional[Tuple[float, float, float, float]]:
    if isinstance(value, list) and len(value) == 4:
        raw = value
    elif isinstance(value, dict) and {"x", "y", "width", "height"} <= set(value):
        raw = [value["x"], value["y"], value["width"], value["height"]]
    elif isinstance(value, dict) and isinstance(value.get("origin"), dict) and isinstance(value.get("size"), dict):
        raw = [
            value["origin"].get("x"),
            value["origin"].get("y"),
            value["size"].get("width"),
            value["size"].get("height"),
        ]
    else:
        return None
    if not all(isinstance(item, (int, float)) and math.isfinite(item) for item in raw):
        return None
    x, y, width, height = (float(item) for item in raw)
    if x < 0 or y < 0 or width <= 0 or height <= 0 or x + width > 1.000001 or y + height > 1.000001:
        return None
    return x, y, width, height


def normalized_point(value: Any) -> Optional[Tuple[float, float]]:
    if isinstance(value, list) and len(value) == 2:
        raw = value
    elif isinstance(value, dict):
        raw = [value.get("x"), value.get("y")]
    else:
        return None
    if not all(isinstance(item, (int, float)) and math.isfinite(item) for item in raw):
        return None
    point = float(raw[0]), float(raw[1])
    return point if 0 <= point[0] <= 1 and 0 <= point[1] <= 1 else None


def contains_region(outer: Tuple[float, float, float, float], inner: Tuple[float, float, float, float]) -> bool:
    return (
        inner[0] >= outer[0]
        and inner[1] >= outer[1]
        and inner[0] + inner[2] <= outer[0] + outer[2] + 0.000001
        and inner[1] + inner[3] <= outer[1] + outer[3] + 0.000001
    )


def contains_point(region: Tuple[float, float, float, float], point: Tuple[float, float]) -> bool:
    return region[0] <= point[0] <= region[0] + region[2] and region[1] <= point[1] <= region[1] + region[3]


def overlap(first: Tuple[float, float, float, float], second: Tuple[float, float, float, float]) -> bool:
    return not (
        first[0] + first[2] <= second[0]
        or second[0] + second[2] <= first[0]
        or first[1] + first[3] <= second[1]
        or second[1] + second[3] <= first[1]
    )


def iter_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from iter_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from iter_strings(item)


@dataclass(frozen=True)
class Issue:
    scope: str
    code: str
    path: str
    message: str
    resource_id: Optional[str] = None

    def json(self) -> Dict[str, Any]:
        result: Dict[str, Any] = {
            "scope": self.scope,
            "code": self.code,
            "path": self.path,
            "message": self.message,
        }
        if self.resource_id:
            result["resourceID"] = self.resource_id
        return result


class Validator:
    def __init__(self, root: Path, repo: Path, selected: Sequence[str]) -> None:
        self.root = root
        self.repo = repo
        self.selected = list(selected)
        self.issues: List[Issue] = []
        self.evidence: Dict[str, List[str]] = defaultdict(list)
        self.json_cache: Dict[str, Any] = {}
        self.bad_json: Set[str] = set()
        self.manifest: Dict[str, Any] = {}
        self.package_manifest: Dict[str, Any] = {}
        self.codices: List[Dict[str, Any]] = []
        self.resources: List[Dict[str, Any]] = []
        self.outputs: List[Tuple[Dict[str, Any], Dict[str, Any]]] = []
        self.resources_by_id: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
        self.outputs_by_id: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
        self.outputs_by_path: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
        self.provenance_records: List[Dict[str, Any]] = []

    def add(self, scope: str, code: str, path: str, message: str, resource_id: Optional[str] = None) -> None:
        issue = Issue(scope, code, path, message, resource_id)
        if issue not in self.issues:
            self.issues.append(issue)

    def record(self, scope: str, message: str) -> None:
        if message not in self.evidence[scope]:
            self.evidence[scope].append(message)

    def read_json(self, relative: str, scope: str, required: bool = True) -> Any:
        if relative in self.json_cache:
            return self.json_cache[relative]
        if normalized_relative_path(relative) is None:
            self.add(scope, "PHC-PATH-001", relative, "JSON path is not a normalized safe package-relative path")
            return None
        path = self.root / relative
        if not path.is_file():
            if required:
                self.add(scope, "PHC-INPUT-002", relative, "required JSON input is missing")
            return None
        try:
            value = load_json_strict(path)
        except DuplicateKeyError as error:
            self.bad_json.add(relative)
            self.add(scope, "PHC-JSON-002", relative, str(error))
            return None
        except Exception as error:
            self.bad_json.add(relative)
            self.add(scope, "PHC-JSON-001", relative, f"JSON parse failed: {type(error).__name__}: {error}")
            return None
        self.json_cache[relative] = value
        return value

    def setup(self) -> None:
        if not self.root.is_dir():
            self.add("output-matrix", "PHC-INPUT-001", str(self.root), "package root is not a directory")
            return
        if not self.repo.is_dir():
            self.add("output-matrix", "PHC-INPUT-003", str(self.repo), "repository root is not a directory")
        self.scan_paths_and_json()
        manifest = self.read_json(ASSET_MANIFEST, "output-matrix")
        package_manifest = self.read_json(PACKAGE_MANIFEST, "budgets-integrity")
        self.manifest = manifest if isinstance(manifest, dict) else {}
        self.package_manifest = package_manifest if isinstance(package_manifest, dict) else {}
        self.codices = [item for item in as_list(self.manifest.get("codices")) if isinstance(item, dict)]
        self.resources = [item for item in as_list(self.manifest.get("resourceCatalog")) if isinstance(item, dict)]
        for resource in self.resources:
            resource_id = resource.get("resourceID")
            if isinstance(resource_id, str):
                self.resources_by_id[resource_id].append(resource)
            for output in as_list(resource.get("outputVariants")):
                if not isinstance(output, dict):
                    continue
                self.outputs.append((resource, output))
                output_id = output.get("resourceID")
                if isinstance(output_id, str):
                    self.outputs_by_id[output_id].append(output)
                filename = output.get("filename")
                if isinstance(filename, str):
                    self.outputs_by_path[filename].append(output)
        ledger_path = self.manifest.get("provenanceLedgerPath")
        if isinstance(ledger_path, str):
            ledger = self.read_json(ledger_path, "provenance-recipes")
            if isinstance(ledger, dict):
                self.provenance_records = [item for item in as_list(ledger.get("records")) if isinstance(item, dict)]

    def scan_paths_and_json(self) -> None:
        try:
            entries = sorted(self.root.rglob("*"), key=lambda item: item.relative_to(self.root).as_posix())
        except Exception as error:
            self.add("budgets-integrity", "PHC-INPUT-004", str(self.root), f"package traversal failed: {error}")
            return
        casefolded: Dict[str, str] = {}
        for path in entries:
            try:
                relative = path.relative_to(self.root).as_posix()
                if path.is_symlink():
                    self.add("budgets-integrity", "PHC-PATH-002", relative, "symbolic links are forbidden in the package")
                    continue
                if normalized_relative_path(relative) is None:
                    self.add("budgets-integrity", "PHC-PATH-001", relative, "filesystem path is not normalized and safe")
                folded = unicodedata.normalize("NFC", relative).casefold()
                if folded in casefolded and casefolded[folded] != relative:
                    self.add("budgets-integrity", "PHC-PATH-003", relative, f"case-insensitive path collision with {casefolded[folded]}")
                else:
                    casefolded[folded] = relative
                if path.is_file() and path.suffix.lower() == ".json":
                    self.read_json(relative, "budgets-integrity", required=False)
            except OSError as error:
                self.add("budgets-integrity", "PHC-PATH-004", str(path), f"filesystem metadata could not be read: {error}")

    def run(self) -> None:
        self.setup()
        methods: Dict[str, Callable[[], None]] = {
            "output-matrix": self.validate_output_matrix,
            "relics": self.validate_relics,
            "seals": self.validate_seals,
            "fonts": self.validate_fonts,
            "share-accessibility-fallbacks": self.validate_share_accessibility_fallbacks,
            "provenance-recipes": self.validate_provenance_recipes,
            "budgets-integrity": self.validate_budgets_integrity,
            "publication": self.validate_publication,
        }
        for scope in self.selected:
            try:
                methods[scope]()
            except Exception as error:
                self.add(scope, "PHC-INTERNAL-001", "", f"scope failed safely: {type(error).__name__}: {error}")

    def phase_matrix_records(self) -> Tuple[List[Dict[str, Any]], str]:
        scope = "output-matrix"
        candidate: Any = self.manifest.get("phaseCOutputMatrix")
        relative = "Validation/phase-c-output-matrix.json"
        if isinstance(candidate, str):
            relative = candidate
            candidate = self.read_json(relative, scope)
        elif isinstance(candidate, dict):
            linked = candidate.get("path") or candidate.get("filename") or candidate.get("matrixPath")
            if isinstance(linked, str):
                relative = linked
                linked_value = self.read_json(relative, scope)
                if linked_value is not None:
                    candidate = linked_value
        if candidate is None:
            candidate = self.read_json(relative, scope, required=False)
        if isinstance(candidate, list):
            records = candidate
        elif isinstance(candidate, dict):
            records = next(
                (
                    candidate[key]
                    for key in ("resources", "records", "logicalResources", "resourceCatalog")
                    if isinstance(candidate.get(key), list)
                ),
                [],
            )
            for count_key in ("resourceCount", "logicalResourceCount"):
                if count_key in candidate and candidate.get(count_key) != 56:
                    self.add(scope, "PHC-MATRIX-002", relative, f"{count_key} must equal 56")
            for count_key in ("outputCount", "shippingOutputCount", "materializedOutputCount"):
                if count_key in candidate and candidate.get(count_key) != 184:
                    self.add(scope, "PHC-MATRIX-003", relative, f"{count_key} must equal 184")
        else:
            records = []
        return [item for item in records if isinstance(item, dict)], relative

    def expected_artifacts(self) -> Tuple[Set[str], Set[str]]:
        relic_ids: Set[str] = set()
        seal_ids: Set[str] = set()
        for codex in self.codices:
            relic_ids.update(
                item.get("assetID") for item in as_list(codex.get("relics"))
                if isinstance(item, dict) and isinstance(item.get("assetID"), str)
            )
            seal_ids.update(
                item.get("assetID") for item in as_list(codex.get("seals"))
                if isinstance(item, dict) and isinstance(item.get("assetID"), str)
            )
        return relic_ids, seal_ids

    def validate_output_matrix(self) -> None:
        scope = "output-matrix"
        if not self.manifest:
            return
        codex_ids = [item.get("codexID") for item in self.codices]
        if len(codex_ids) != 4 or set(codex_ids) != EXPECTED_CODEX_IDS or len(set(codex_ids)) != 4:
            self.add(scope, "PHC-MATRIX-001", ASSET_MANIFEST, "Codex set must contain the four canonical IDs exactly once")
        if len(self.resources) != 56:
            self.add(scope, "PHC-MATRIX-002", ASSET_MANIFEST, f"resourceCatalog must contain exactly 56 records; found {len(self.resources)}")
        if len(self.outputs) != 184:
            self.add(scope, "PHC-MATRIX-003", ASSET_MANIFEST, f"resourceCatalog must contain exactly 184 output variants; found {len(self.outputs)}")

        matrix_records, matrix_path = self.phase_matrix_records()
        if not matrix_records:
            self.add(scope, "PHC-MATRIX-004", matrix_path, "machine-readable Phase C matrix with logical resource records is missing")
        else:
            if len(matrix_records) != 56:
                self.add(scope, "PHC-MATRIX-002", matrix_path, f"Phase C matrix must contain exactly 56 records; found {len(matrix_records)}")
            matrix_outputs = sum(len(as_list(item.get("outputVariants"))) for item in matrix_records)
            if matrix_outputs != 184:
                self.add(scope, "PHC-MATRIX-003", matrix_path, f"Phase C matrix must contain exactly 184 output variants; found {matrix_outputs}")
            manifest_ids = [item.get("resourceID") for item in self.resources]
            matrix_ids = [item.get("resourceID") for item in matrix_records]
            if matrix_ids != manifest_ids:
                self.add(scope, "PHC-MATRIX-005", matrix_path, "Phase C matrix record order and IDs differ from resourceCatalog")
            matrix_by_id = {item.get("resourceID"): item for item in matrix_records if isinstance(item.get("resourceID"), str)}
            for resource in self.resources:
                resource_id = resource.get("resourceID")
                peer = matrix_by_id.get(resource_id)
                if peer is not None and peer != resource:
                    self.add(scope, "PHC-MATRIX-006", matrix_path, "Phase C matrix record differs from resourceCatalog", str(resource_id))

        for resource_id, records in sorted(self.resources_by_id.items()):
            if len(records) != 1:
                self.add(scope, "PHC-MATRIX-007", ASSET_MANIFEST, f"logical resource ID resolves {len(records)} times", resource_id)
        unnamed = [item for item in self.resources if not is_nonempty(item.get("resourceID"))]
        if unnamed:
            self.add(scope, "PHC-MATRIX-008", ASSET_MANIFEST, f"{len(unnamed)} logical resources lack a stable resourceID")

        per_codex: Dict[str, Counter[str]] = defaultdict(Counter)
        per_codex_outputs: Counter[str] = Counter()
        relic_ids, seal_ids = self.expected_artifacts()
        seen_artifacts: Dict[Tuple[str, str], str] = {}
        for resource in self.resources:
            resource_id = str(resource.get("resourceID", ""))
            owner = str(resource.get("ownerCodexID", ""))
            asset_class = str(resource.get("assetClass", ""))
            missing = MATRIX_RESOURCE_FIELDS - set(resource)
            if missing:
                self.add(scope, "PHC-MATRIX-009", ASSET_MANIFEST, f"logical resource is missing fields: {sorted(missing)}", resource_id or None)
            if owner not in EXPECTED_CODEX_IDS:
                self.add(scope, "PHC-MATRIX-010", ASSET_MANIFEST, f"ownerCodexID is invalid: {owner}", resource_id or None)
            if asset_class not in CLASS_COUNTS_PER_CODEX:
                self.add(scope, "PHC-MATRIX-011", ASSET_MANIFEST, f"assetClass is not active: {asset_class}", resource_id or None)
                continue
            per_codex[owner][asset_class] += 1
            artifact_id = resource.get("artifactID")
            if not is_nonempty(artifact_id):
                self.add(scope, "PHC-MATRIX-012", ASSET_MANIFEST, "artifactID must be explicit", resource_id or None)
            else:
                artifact_key = (asset_class, str(artifact_id))
                if artifact_key in seen_artifacts:
                    self.add(scope, "PHC-MATRIX-013", ASSET_MANIFEST, f"artifactID duplicates {seen_artifacts[artifact_key]}", resource_id or None)
                seen_artifacts[artifact_key] = resource_id
            if asset_class in {"relic", "seal"}:
                expected_ids = relic_ids if asset_class == "relic" else seal_ids
                if artifact_id not in expected_ids:
                    self.add(scope, "PHC-MATRIX-014", ASSET_MANIFEST, "artifactID is not declared by its Codex", resource_id or None)
                if resource_id != f"resource.{artifact_id}":
                    self.add(scope, "PHC-MATRIX-015", ASSET_MANIFEST, f"resourceID must be the stable resource.{artifact_id} identity", resource_id or None)
            if resource.get("requiredOrOptional") != "required":
                self.add(scope, "PHC-MATRIX-016", ASSET_MANIFEST, "Phase C logical resource must be required", resource_id or None)
            source = resource.get("sourceMasterPath")
            if normalized_relative_path(source) is None:
                self.add(scope, "PHC-PATH-001", str(source), "sourceMasterPath is unsafe or not normalized", resource_id or None)
            elif not (self.root / source).is_file():
                self.add(scope, "PHC-MATRIX-017", source, "declared source master is missing", resource_id or None)
            if not is_nonempty(resource.get("semanticRole")) or not is_nonempty(resource.get("sourceClass")):
                self.add(scope, "PHC-MATRIX-018", ASSET_MANIFEST, "source class and semantic role must be explicit", resource_id or None)
            if not is_nonempty(resource.get("fallbackBehavior")) or not is_nonempty(resource.get("fallbackResourceID")):
                self.add(scope, "PHC-MATRIX-019", ASSET_MANIFEST, "logical fallback ID and behavior must be explicit", resource_id or None)
            if not is_nonempty(resource.get("provenanceID")):
                self.add(scope, "PHC-MATRIX-020", ASSET_MANIFEST, "logical provenanceID must be explicit", resource_id or None)

            variants = [item for item in as_list(resource.get("outputVariants")) if isinstance(item, dict)]
            roles = [item.get("outputRole") for item in variants]
            expected_roles = ROLE_SETS[asset_class]
            if set(roles) != expected_roles or len(roles) != len(expected_roles):
                self.add(scope, "PHC-MATRIX-021", ASSET_MANIFEST, f"declared roles must equal {sorted(expected_roles)}; found {roles}", resource_id or None)
            per_codex_outputs[owner] += len(variants)
            for output in variants:
                self.validate_matrix_output(scope, resource, output)

        for codex_id in sorted(EXPECTED_CODEX_IDS):
            if per_codex[codex_id] != Counter(CLASS_COUNTS_PER_CODEX):
                self.add(scope, "PHC-MATRIX-022", ASSET_MANIFEST, f"{codex_id} class matrix differs: {dict(per_codex[codex_id])}")
            if per_codex_outputs[codex_id] != 46:
                self.add(scope, "PHC-MATRIX-023", ASSET_MANIFEST, f"{codex_id} must declare 46 outputs; found {per_codex_outputs[codex_id]}")
        for output_id, records in sorted(self.outputs_by_id.items()):
            if len(records) != 1:
                self.add(scope, "PHC-MATRIX-024", ASSET_MANIFEST, f"output resourceID resolves {len(records)} times", output_id)
        if any(not is_nonempty(output.get("resourceID")) for _, output in self.outputs):
            self.add(scope, "PHC-MATRIX-025", ASSET_MANIFEST, "every output variant must have a stable resourceID")
        for filename, records in sorted(self.outputs_by_path.items()):
            if len(records) != 1:
                self.add(scope, "PHC-MATRIX-026", filename, f"output path is declared {len(records)} times")
        self.record(scope, f"Observed {len(self.resources)} logical resources and {len(self.outputs)} explicit outputs")

    def validate_matrix_output(self, scope: str, resource: Dict[str, Any], output: Dict[str, Any]) -> None:
        parent_id = str(resource.get("resourceID", ""))
        output_id = str(output.get("resourceID", ""))
        role = str(output.get("outputRole", ""))
        filename = output.get("filename")
        missing = MATRIX_OUTPUT_FIELDS - set(output)
        if missing:
            self.add(scope, "PHC-MATRIX-027", str(filename or ASSET_MANIFEST), f"output is missing fields: {sorted(missing)}", output_id or parent_id or None)
        expected_id = f"{parent_id}.output.{role.replace('.', '-')}"
        if output_id != expected_id:
            self.add(scope, "PHC-MATRIX-028", str(filename or ASSET_MANIFEST), f"stable output resourceID must be {expected_id}", output_id or parent_id or None)
        if output.get("artifactID") != resource.get("artifactID"):
            self.add(scope, "PHC-MATRIX-029", str(filename or ASSET_MANIFEST), "output artifactID differs from its logical resource", output_id or None)
        if role not in ROLE_SETS.get(str(resource.get("assetClass")), set()):
            self.add(scope, "PHC-MATRIX-030", str(filename or ASSET_MANIFEST), "output role is undeclared or inferred", output_id or None)
        media = output.get("mediaType")
        if media not in ROLE_MEDIA.get(role, set()):
            self.add(scope, "PHC-MATRIX-031", str(filename or ASSET_MANIFEST), f"mediaType {media!r} is not valid for {role}", output_id or None)
        if output.get("requiredOrOptional") != "required" or output.get("status") != "materialized":
            self.add(scope, "PHC-MATRIX-032", str(filename or ASSET_MANIFEST), "output must be required and materialized", output_id or None)
        if normalized_relative_path(filename) is None or not str(filename).startswith("Shipping/"):
            self.add(scope, "PHC-PATH-001", str(filename), "output filename must be a normalized Shipping path", output_id or None)
        for key in ("byteLimit", "maximumBytes", "byteLength"):
            if not isinstance(output.get(key), int) or output.get(key, 0) <= 0:
                self.add(scope, "PHC-MATRIX-033", str(filename or ASSET_MANIFEST), f"{key} must be a positive integer", output_id or None)
        if isinstance(output.get("byteLimit"), int) and output.get("maximumBytes") != output.get("byteLimit"):
            self.add(scope, "PHC-MATRIX-034", str(filename or ASSET_MANIFEST), "byteLimit and maximumBytes must agree", output_id or None)
        if not HASH_PATTERN.fullmatch(str(output.get("sha256", ""))):
            self.add(scope, "PHC-MATRIX-035", str(filename or ASSET_MANIFEST), "sha256 is not a lowercase digest", output_id or None)
        if not UTC_PATTERN.fullmatch(str(output.get("createdAtUTC", ""))):
            self.add(scope, "PHC-MATRIX-036", str(filename or ASSET_MANIFEST), "createdAtUTC is not an explicit UTC timestamp", output_id or None)
        for key in ("colorSpace", "alphaPolicy", "fallbackResourceID", "fallbackBehavior", "exportRecipeID", "provenanceID"):
            if not is_nonempty(output.get(key)):
                self.add(scope, "PHC-MATRIX-037", str(filename or ASSET_MANIFEST), f"{key} must be explicit", output_id or None)
        if output.get("provenanceID") != resource.get("provenanceID"):
            self.add(scope, "PHC-MATRIX-038", str(filename or ASSET_MANIFEST), "output provenanceID differs from logical resource", output_id or None)

    def descriptor_maps(self) -> Tuple[Dict[str, Tuple[str, Dict[str, Any]]], Dict[str, Tuple[str, Dict[str, Any]]]]:
        relics: Dict[str, Tuple[str, Dict[str, Any]]] = {}
        seals: Dict[str, Tuple[str, Dict[str, Any]]] = {}
        for codex in self.codices:
            codex_id = str(codex.get("codexID", ""))
            for item in as_list(codex.get("relics")):
                if isinstance(item, dict) and is_nonempty(item.get("assetID")):
                    relics[str(item["assetID"])] = (codex_id, item)
            for item in as_list(codex.get("seals")):
                if isinstance(item, dict) and is_nonempty(item.get("assetID")):
                    seals[str(item["assetID"])] = (codex_id, item)
        return relics, seals

    def resource_for_artifact(self, asset_class: str, artifact_id: str) -> Optional[Dict[str, Any]]:
        matches = [
            item for item in self.resources
            if item.get("assetClass") == asset_class and item.get("artifactID") == artifact_id
        ]
        return matches[0] if len(matches) == 1 else None

    def outputs_for_roles(self, resource: Optional[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
        if not resource:
            return {}
        return {
            str(item.get("outputRole")): item
            for item in as_list(resource.get("outputVariants"))
            if isinstance(item, dict) and is_nonempty(item.get("outputRole"))
        }

    def validate_relics(self) -> None:
        scope = "relics"
        relics, _ = self.descriptor_maps()
        if len(relics) != 12:
            self.add(scope, "PHC-REL-001", ASSET_MANIFEST, f"exactly 12 stable Relic descriptors are required; found {len(relics)}")
        relic_resources = [item for item in self.resources if item.get("assetClass") == "relic"]
        if len(relic_resources) != 12:
            self.add(scope, "PHC-REL-002", ASSET_MANIFEST, f"exactly 12 logical Relic resources are required; found {len(relic_resources)}")
        relic_outputs = [output for resource, output in self.outputs if resource.get("assetClass") == "relic"]
        if len(relic_outputs) != 48:
            self.add(scope, "PHC-REL-003", ASSET_MANIFEST, f"exactly 48 Relic outputs are required; found {len(relic_outputs)}")

        profiles = {
            item.get("layoutProfileID") or item.get("id"): item
            for item in as_list(self.manifest.get("layoutProfiles"))
            if isinstance(item, dict) and is_nonempty(item.get("layoutProfileID") or item.get("id"))
        }
        fixture_data = self.read_json("Validation/layout-fixtures.json", scope)
        fixtures = {
            item.get("artifactID"): item
            for item in as_list(fixture_data.get("records") if isinstance(fixture_data, dict) else None)
            if isinstance(item, dict) and is_nonempty(item.get("artifactID"))
        }
        geometry_data = self.read_json("Validation/geometry/anchor-safety.json", scope)
        geometry_records = as_list(geometry_data.get("records") if isinstance(geometry_data, dict) else None)
        geometry_by_artifact = {
            item.get("artifactID"): item
            for item in geometry_records
            if isinstance(item, dict) and is_nonempty(item.get("artifactID"))
        }
        geometry_by_source = {
            item.get("sourceMaster"): item
            for item in geometry_records
            if isinstance(item, dict) and is_nonempty(item.get("sourceMaster"))
        }
        if len(geometry_records) != 12:
            self.add(scope, "PHC-REL-004", "Validation/geometry/anchor-safety.json", f"anchor/protected-region evidence must cover all 12 Relics; found {len(geometry_records)}")

        for artifact_id, (codex_id, relic) in sorted(relics.items()):
            resource = self.resource_for_artifact("relic", artifact_id)
            if resource is None:
                self.add(scope, "PHC-REL-005", ASSET_MANIFEST, "Relic logical resource does not resolve exactly once", artifact_id)
                continue
            if resource.get("ownerCodexID") != codex_id:
                self.add(scope, "PHC-REL-006", ASSET_MANIFEST, "Relic owner differs from its Codex", artifact_id)
            roles = self.outputs_for_roles(resource)
            if set(roles) != ROLE_SETS["relic"]:
                self.add(scope, "PHC-REL-007", ASSET_MANIFEST, f"Relic role coverage differs: {sorted(roles)}", artifact_id)
            requirements = {
                item.get("role"): item
                for item in as_list(relic.get("requiredResources"))
                if isinstance(item, dict) and is_nonempty(item.get("role"))
            }
            if set(requirements) != ROLE_SETS["relic"]:
                self.add(scope, "PHC-REL-008", ASSET_MANIFEST, "Relic requiredResources does not declare all four active roles", artifact_id)
            for role, expected in requirements.items():
                output = roles.get(str(role))
                if output is None:
                    continue
                expected_media = {"png": "image/png", "heif": "image/heif", "pdf": "application/pdf"}.get(expected.get("format"))
                if output.get("mediaType") != expected_media:
                    self.add(scope, "PHC-REL-009", str(output.get("filename", ASSET_MANIFEST)), f"{role} media differs from descriptor format {expected.get('format')}", str(output.get("resourceID") or artifact_id))
                if output.get("maximumBytes") != expected.get("maxBytes") or output.get("byteLimit") != expected.get("maxBytes"):
                    self.add(scope, "PHC-REL-010", str(output.get("filename", ASSET_MANIFEST)), f"{role} budget differs from descriptor", str(output.get("resourceID") or artifact_id))
                transparent = expected.get("transparent")
                if transparent is True and output.get("alphaPolicy") not in {"straight", "premultiplied"}:
                    self.add(scope, "PHC-REL-011", str(output.get("filename", ASSET_MANIFEST)), f"{role} must preserve transparency", str(output.get("resourceID") or artifact_id))
                if transparent is False and output.get("alphaPolicy") != "opaque":
                    self.add(scope, "PHC-REL-011", str(output.get("filename", ASSET_MANIFEST)), f"{role} must be opaque", str(output.get("resourceID") or artifact_id))

            source = relic.get("geometrySourceMaster")
            if normalized_relative_path(source) is None or not (self.root / str(source)).is_file():
                self.add(scope, "PHC-REL-012", str(source), "Relic geometry source is missing or unsafe", artifact_id)
            else:
                viewbox = svg_viewbox(self.root / str(source))
                declared = dimensions_from_declaration(relic.get("sourceMasterDimensions"))
                if viewbox is None:
                    self.add(scope, "PHC-REL-013", str(source), "Relic geometry SVG lacks a valid positive viewBox", artifact_id)
                elif declared != (round(viewbox[2]), round(viewbox[3])):
                    self.add(scope, "PHC-REL-014", str(source), "Relic descriptor dimensions differ from geometry viewBox", artifact_id)
                if "plaque" in artifact_id and declared != (1600, 1200):
                    self.add(scope, "PHC-REL-015", str(source), "plaque authority must remain 1600 x 1200", artifact_id)
            glyph_region = normalized_region(relic.get("glyphSafeRegion"))
            if glyph_region is None:
                self.add(scope, "PHC-REL-016", ASSET_MANIFEST, "glyphSafeRegion must be a valid normalized region", artifact_id)
            if not is_nonempty(relic.get("accessibilityDescription")):
                self.add(scope, "PHC-REL-017", ASSET_MANIFEST, "Relic accessibility description is missing", artifact_id)

            profile_id = relic.get("layoutProfileID")
            profile = profiles.get(profile_id)
            if not isinstance(profile, dict) or profile.get("artifactID") != artifact_id:
                self.add(scope, "PHC-REL-018", ASSET_MANIFEST, "Relic layoutProfileID does not resolve to its artifact", artifact_id)
            else:
                self.validate_layout_profile(scope, artifact_id, profile, glyph_region)
            fixture = fixtures.get(artifact_id)
            if not isinstance(fixture, dict):
                self.add(scope, "PHC-REL-019", "Validation/layout-fixtures.json", "Relic layout fixture record is missing", artifact_id)
            else:
                kinds = {item.get("kind") for item in as_list(fixture.get("fixtures")) if isinstance(item, dict)}
                expected_kinds = {"one-line", "normal-content", "exact-maximum", "one-beyond-maximum", "minimum-scale"}
                if kinds != expected_kinds:
                    self.add(scope, "PHC-REL-020", "Validation/layout-fixtures.json", f"layout fixture coverage differs: {sorted(str(item) for item in kinds)}", artifact_id)
                required_evidence = {
                    "minimumScaleFixtureDoesNotTouchSeal",
                    "maximumLineFixtureDoesNotTouchSeal",
                    "thumbnailLegible",
                    "shareCompositionLegible",
                    "highContrastPass",
                }
                for key in required_evidence:
                    if fixture.get(key) is not True:
                        self.add(scope, "PHC-REL-021", "Validation/layout-fixtures.json", f"{key} must be PASS/true", artifact_id)
                visual = fixture.get("visualFixture")
                if normalized_relative_path(visual) is None or not (self.root / str(visual)).is_file():
                    self.add(scope, "PHC-REL-022", str(visual), "layout visual evidence is missing", artifact_id)

            geometry_record = geometry_by_artifact.get(artifact_id) or geometry_by_source.get(source)
            if not isinstance(geometry_record, dict):
                self.add(scope, "PHC-REL-023", "Validation/geometry/anchor-safety.json", "Relic anchor-safety record is missing", artifact_id)
            else:
                anchors = [item for item in as_list(geometry_record.get("anchors")) if isinstance(item, dict)]
                expected_categories = set(str(item) for item in as_list(relic.get("sealAnchors")))
                actual_categories = {item.get("category") for item in anchors}
                if actual_categories != expected_categories:
                    self.add(scope, "PHC-REL-024", "Validation/geometry/anchor-safety.json", f"anchor categories differ: {sorted(str(item) for item in actual_categories)}", artifact_id)
                for anchor in anchors:
                    if not (
                        anchor.get("insideRelicBounds") is True
                        and anchor.get("intersectsExpandedSafeRegion") is False
                        and isinstance(anchor.get("clearanceFromGlyphSafeRegion"), (int, float))
                        and anchor.get("clearanceFromGlyphSafeRegion", 0) >= 24
                    ):
                        self.add(scope, "PHC-REL-025", "Validation/geometry/anchor-safety.json", "Seal anchor violates protected-region clearance", artifact_id)

            crop_records = [item for item in as_list(relic.get("squareDerivatives")) if isinstance(item, dict)]
            if not crop_records:
                self.add(scope, "PHC-REL-026", ASSET_MANIFEST, "explicit square crop recipe is missing", artifact_id)
            else:
                source_dimensions = dimensions_from_declaration(relic.get("sourceMasterDimensions"))
                for crop in crop_records:
                    rectangle = crop.get("cropRectangle")
                    dimensions = dimensions_from_declaration(crop.get("dimensions"))
                    if not (
                        isinstance(rectangle, list)
                        and len(rectangle) == 4
                        and all(isinstance(item, (int, float)) for item in rectangle)
                        and rectangle[2] == rectangle[3]
                        and dimensions is not None
                        and dimensions[0] == dimensions[1]
                    ):
                        self.add(scope, "PHC-REL-027", ASSET_MANIFEST, "square derivative must declare a square crop and square output", artifact_id)
                    elif source_dimensions and (
                        rectangle[0] < 0
                        or rectangle[1] < 0
                        or rectangle[0] + rectangle[2] > source_dimensions[0]
                        or rectangle[1] + rectangle[3] > source_dimensions[1]
                    ):
                        self.add(scope, "PHC-REL-028", ASSET_MANIFEST, "square crop rectangle exceeds master geometry", artifact_id)
                    if crop.get("resizePolicy") not in {"aspect-fill-crop", "crop-then-scale", "no-stretch"} or crop.get("allowStretch") is not False:
                        self.add(scope, "PHC-REL-029", ASSET_MANIFEST, "square derivative must explicitly forbid stretching", artifact_id)
            output = roles.get("relic.thumbnail")
            declared_size = dimensions_from_declaration(output.get("dimensionsOrViewBox")) if output else None
            if declared_size is None or declared_size[0] != declared_size[1]:
                self.add(scope, "PHC-REL-030", str(output.get("filename") if output else ASSET_MANIFEST), "relic.thumbnail must be square and crop-derived", artifact_id)
            share = roles.get("relic.static-share-fallback")
            share_size = dimensions_from_declaration(share.get("dimensionsOrViewBox")) if share else None
            share_policy = relic.get("shareCompositionPolicy") or resource.get("shareCompositionPolicy")
            if share_size is None or share_policy not in {"aspect-fit-no-stretch", "crop-safe-aspect-fit", "no-stretch"}:
                self.add(scope, "PHC-REL-045", str(share.get("filename") if share else ASSET_MANIFEST), "static share must declare dimensions and a no-stretch/aspect-fit composition policy", artifact_id)
            master = roles.get("relic.master")
            contrast = roles.get("relic.high-contrast")
            if master and contrast and master.get("sha256") == contrast.get("sha256"):
                self.add(scope, "PHC-REL-031", str(contrast.get("filename", ASSET_MANIFEST)), "High Contrast derivative must not be byte-identical to the master", artifact_id)
        self.record(scope, f"Observed {len(relics)} Relic descriptors and {len(relic_outputs)} Relic outputs")

    def validate_layout_profile(
        self,
        scope: str,
        artifact_id: str,
        profile: Dict[str, Any],
        descriptor_glyph: Optional[Tuple[float, float, float, float]],
    ) -> None:
        required = {
            "aspectRatio",
            "relicBounds",
            "contentSafeRegion",
            "glyphSafeRegion",
            "sealAnchors",
            "maximumGlyphLines",
            "minimumGlyphScale",
            "overflowBehavior",
            "attributionRegion",
            "provenanceRegion",
            "serialNumberRegion",
            "qrSafeRegion",
            "qrPolicy",
            "thumbnailCrop",
        }
        missing = required - set(profile)
        if missing:
            self.add(scope, "PHC-REL-032", ASSET_MANIFEST, f"layout profile lacks contract/reserved declarations: {sorted(missing)}", artifact_id)
        relic_bounds = normalized_region(profile.get("relicBounds"))
        content = normalized_region(profile.get("contentSafeRegion"))
        glyph = normalized_region(profile.get("glyphSafeRegion"))
        thumbnail = normalized_region(profile.get("thumbnailCrop"))
        if None in {relic_bounds, content, glyph, thumbnail}:
            self.add(scope, "PHC-REL-033", ASSET_MANIFEST, "layout regions must be valid normalized rectangles", artifact_id)
            return
        assert relic_bounds is not None and content is not None and glyph is not None and thumbnail is not None
        if not contains_region(relic_bounds, content) or not contains_region(content, glyph):
            self.add(scope, "PHC-REL-034", ASSET_MANIFEST, "relic/content/glyph regions are not nested", artifact_id)
        if descriptor_glyph and any(abs(first - second) > 0.000001 for first, second in zip(glyph, descriptor_glyph)):
            self.add(scope, "PHC-REL-035", ASSET_MANIFEST, "layout glyphSafeRegion differs from Relic descriptor", artifact_id)
        if not contains_region(relic_bounds, thumbnail):
            self.add(scope, "PHC-REL-036", ASSET_MANIFEST, "thumbnail crop exceeds Relic bounds", artifact_id)
        maximum = profile.get("maximumGlyphLines")
        minimum = profile.get("minimumGlyphScale")
        if not isinstance(maximum, int) or not 1 <= maximum <= 32 or not isinstance(minimum, (int, float)) or not 0 < minimum <= 1:
            self.add(scope, "PHC-REL-037", ASSET_MANIFEST, "glyph line/scale bounds are invalid", artifact_id)
        if profile.get("overflowBehavior") not in {"standardAlternate", "alternate-standard-presentation"}:
            self.add(scope, "PHC-REL-038", ASSET_MANIFEST, "overflowBehavior is not the active standard alternate behavior", artifact_id)
        anchor_categories: List[str] = []
        for anchor in as_list(profile.get("sealAnchors")):
            if not isinstance(anchor, dict):
                self.add(scope, "PHC-REL-039", ASSET_MANIFEST, "Seal anchor must declare category and point", artifact_id)
                continue
            category = anchor.get("category")
            point = normalized_point(anchor.get("point"))
            anchor_categories.append(str(category))
            if category not in {"lowerLeft", "lowerRight", "bottomCenter", "topCenter"} or point is None:
                self.add(scope, "PHC-REL-039", ASSET_MANIFEST, "Seal anchor category or point is invalid", artifact_id)
            elif not contains_point(relic_bounds, point) or contains_point(glyph, point):
                self.add(scope, "PHC-REL-040", ASSET_MANIFEST, "Seal anchor lies outside Relic bounds or inside glyph region", artifact_id)
        if len(anchor_categories) != len(set(anchor_categories)) or not anchor_categories:
            self.add(scope, "PHC-REL-041", ASSET_MANIFEST, "Seal anchor categories must be nonempty and unique", artifact_id)
        reserved: List[Tuple[str, Tuple[float, float, float, float]]] = []
        for key in ("attributionRegion", "provenanceRegion", "serialNumberRegion", "qrSafeRegion"):
            value = profile.get(key)
            if value is None and key != "attributionRegion":
                continue
            region = normalized_region(value)
            if region is None:
                self.add(scope, "PHC-REL-042", ASSET_MANIFEST, f"{key} must be null or a valid normalized region", artifact_id)
            else:
                reserved.append((key, region))
        if profile.get("qrPolicy") not in {"disabled", "none", "no-resource", "disabled-no-resource"}:
            self.add(scope, "PHC-REL-043", ASSET_MANIFEST, "Phase C QR policy must explicitly disable QR output", artifact_id)
        for name, region in reserved:
            if overlap(glyph, region):
                self.add(scope, "PHC-REL-044", ASSET_MANIFEST, f"glyph region overlaps protected {name}", artifact_id)

    def validate_svg_safety(self, scope: str, relative: str, resource_id: str) -> Optional[ET.Element]:
        if normalized_relative_path(relative) is None:
            self.add(scope, "PHC-SEA-011", relative, "SVG source path is unsafe", resource_id)
            return None
        path = self.root / relative
        if not path.is_file():
            self.add(scope, "PHC-SEA-012", relative, "SVG source is missing", resource_id)
            return None
        try:
            text = path.read_text(encoding="utf-8")
        except Exception as error:
            self.add(scope, "PHC-SEA-013", relative, f"SVG source is not UTF-8 text: {error}", resource_id)
            return None
        lowered = text.lower()
        if "<!doctype" in lowered or "<!entity" in lowered:
            self.add(scope, "PHC-SEA-014", relative, "SVG DTD/entity declarations are forbidden", resource_id)
        try:
            root = ET.fromstring(text)
        except Exception as error:
            self.add(scope, "PHC-SEA-015", relative, f"SVG/XML parse failed: {error}", resource_id)
            return None
        ids: List[str] = []
        topology_count = 0
        forbidden_tags = {"script", "foreignobject", "iframe", "object", "embed", "audio", "video"}
        for element in root.iter():
            name = tag_name(element)
            if name in forbidden_tags:
                self.add(scope, "PHC-SEA-016", relative, f"forbidden SVG element: {name}", resource_id)
            if name in {"path", "circle", "ellipse", "rect", "line", "polyline", "polygon"}:
                topology_count += 1
            element_id = element.attrib.get("id")
            if element_id:
                ids.append(element_id)
            for raw_name, value in element.attrib.items():
                attr = raw_name.rsplit("}", 1)[-1].lower()
                if attr.startswith("on"):
                    self.add(scope, "PHC-SEA-017", relative, f"event attribute is forbidden: {attr}", resource_id)
                if attr == "href" and value and not value.startswith("#"):
                    self.add(scope, "PHC-SEA-018", relative, f"external SVG reference is forbidden: {value}", resource_id)
                if attr in {"style", "fill", "stroke", "filter", "clip-path", "mask"} and re.search(r"url\(\s*['\"]?(?!#)", value, re.IGNORECASE):
                    self.add(scope, "PHC-SEA-018", relative, "external CSS/SVG URL is forbidden", resource_id)
        duplicates = sorted(item for item, count in Counter(ids).items() if count > 1)
        if duplicates:
            self.add(scope, "PHC-SEA-019", relative, f"duplicate SVG IDs: {duplicates}", resource_id)
        if topology_count == 0:
            self.add(scope, "PHC-SEA-020", relative, "SVG has no renderable vector topology", resource_id)
        if svg_viewbox(path) is None:
            self.add(scope, "PHC-SEA-021", relative, "SVG lacks a valid positive viewBox", resource_id)
        return root

    def validate_pdf(self, scope: str, output: Dict[str, Any], monochrome: bool = False) -> None:
        relative = output.get("filename")
        resource_id = str(output.get("resourceID", ""))
        if normalized_relative_path(relative) is None or not (self.root / str(relative)).is_file():
            return
        payload = (self.root / str(relative)).read_bytes()
        if not payload.startswith(b"%PDF-") or len(re.findall(rb"/Type\s*/Page\b", payload)) != 1:
            self.add(scope, "PHC-SEA-022", str(relative), "shipping PDF must be a valid single-page vector container", resource_id)
        if b"/Subtype /Image" in payload or b"/Subtype/Image" in payload:
            self.add(scope, "PHC-SEA-023", str(relative), "shipping vector PDF contains a raster image object", resource_id)
        if not re.search(rb"(?:\bm\b|\bl\b|\bc\b|\bre\b).*(?:\bS\b|\bf\b|\bB\b)", payload, re.DOTALL):
            self.add(scope, "PHC-SEA-024", str(relative), "shipping vector PDF lacks drawing topology", resource_id)
        if monochrome:
            color_operator = re.search(
                rb"(?:[-+]?\d*\.?\d+\s+){2,3}(?:rg|RG|k|K)\b|/(?:DeviceRGB|DeviceCMYK)\b",
                payload,
            )
            if color_operator:
                self.add(scope, "PHC-SEA-025", str(relative), "monochrome fallback contains RGB or CMYK color operators", resource_id)
            if not re.search(rb"[-+]?\d*\.?\d+\s+(?:g|G)\b", payload):
                self.add(scope, "PHC-SEA-026", str(relative), "monochrome fallback lacks an explicit grayscale paint operation", resource_id)

    def seal_recognition_records(self) -> Tuple[List[Dict[str, Any]], str]:
        candidates = (
            "Validation/topology/seal-smallest-output-recognition.json",
            "Validation/seals/smallest-output-recognition.json",
            "Validation/seals/seal-recognition.json",
            "Validation/topology/smallest-output-recognition.json",
        )
        for relative in candidates:
            value = self.read_json(relative, "seals", required=False)
            if isinstance(value, dict):
                records = [item for item in as_list(value.get("records")) if isinstance(item, dict)]
                seal_records = [
                    item for item in records
                    if str(item.get("assetID") or item.get("sealID") or "").startswith("seal.")
                    or "/Seals/" in str(item.get("sourceMaster", ""))
                ]
                if seal_records:
                    if value.get("reviewStatus") not in {"PASS", "pass"} and value.get("status") not in {"PASS", "pass"}:
                        self.add("seals", "PHC-SEA-027", relative, "seal smallest-output review status is not PASS")
                    return seal_records, relative
        return [], candidates[0]

    def validate_seals(self) -> None:
        scope = "seals"
        relics, seals = self.descriptor_maps()
        if len(seals) != 24:
            self.add(scope, "PHC-SEA-001", ASSET_MANIFEST, f"exactly 24 stable Seal descriptors are required; found {len(seals)}")
        seal_resources = [item for item in self.resources if item.get("assetClass") == "seal"]
        if len(seal_resources) != 24:
            self.add(scope, "PHC-SEA-002", ASSET_MANIFEST, f"exactly 24 logical Seal resources are required; found {len(seal_resources)}")
        seal_outputs = [output for resource, output in self.outputs if resource.get("assetClass") == "seal"]
        if len(seal_outputs) != 72:
            self.add(scope, "PHC-SEA-003", ASSET_MANIFEST, f"exactly 72 Seal outputs are required; found {len(seal_outputs)}")
        recognition, recognition_path = self.seal_recognition_records()
        recognition_by_asset = {
            (item.get("assetID") or item.get("sealID")): item
            for item in recognition if is_nonempty(item.get("assetID") or item.get("sealID"))
        }
        recognition_by_source = {
            item.get("sourceMaster"): item for item in recognition if is_nonempty(item.get("sourceMaster"))
        }
        if len(recognition) != 24:
            self.add(scope, "PHC-SEA-004", recognition_path, f"smallest-output recognition must cover all 24 Seals; found {len(recognition)}")

        relics_by_codex: Dict[str, Dict[str, Dict[str, Any]]] = defaultdict(dict)
        for artifact_id, (codex_id, descriptor) in relics.items():
            relics_by_codex[codex_id][artifact_id] = descriptor
        for artifact_id, (codex_id, seal) in sorted(seals.items()):
            resource = self.resource_for_artifact("seal", artifact_id)
            if resource is None:
                self.add(scope, "PHC-SEA-005", ASSET_MANIFEST, "Seal logical resource does not resolve exactly once", artifact_id)
                continue
            if resource.get("ownerCodexID") != codex_id:
                self.add(scope, "PHC-SEA-006", ASSET_MANIFEST, "Seal owner differs from its Codex", artifact_id)
            roles = self.outputs_for_roles(resource)
            if set(roles) != ROLE_SETS["seal"]:
                self.add(scope, "PHC-SEA-007", ASSET_MANIFEST, f"Seal role coverage differs: {sorted(roles)}", artifact_id)
            requirements = {
                item.get("role"): item
                for item in as_list(seal.get("requiredResources"))
                if isinstance(item, dict) and is_nonempty(item.get("role"))
            }
            if set(requirements) != ROLE_SETS["seal"]:
                self.add(scope, "PHC-SEA-008", ASSET_MANIFEST, "Seal requiredResources does not declare all three active roles", artifact_id)
            for role, expected in requirements.items():
                output = roles.get(str(role))
                if output is None:
                    continue
                expected_media = {"png": "image/png", "pdf": "application/pdf"}.get(expected.get("format"))
                if output.get("mediaType") != expected_media:
                    self.add(scope, "PHC-SEA-009", str(output.get("filename", ASSET_MANIFEST)), f"{role} media differs from descriptor format", str(output.get("resourceID") or artifact_id))
                if output.get("maximumBytes") != expected.get("maxBytes") or output.get("byteLimit") != expected.get("maxBytes"):
                    self.add(scope, "PHC-SEA-010", str(output.get("filename", ASSET_MANIFEST)), f"{role} budget differs from descriptor", str(output.get("resourceID") or artifact_id))
            for output in roles.values():
                relative = output.get("filename")
                if normalized_relative_path(relative) is None or not (self.root / str(relative)).is_file():
                    self.add(scope, "PHC-SEA-039", str(relative), "Seal output is missing or unsafe", str(output.get("resourceID") or artifact_id))
                else:
                    path = self.root / str(relative)
                    if output.get("sha256") != sha256_file(path) or output.get("byteLength") != path.stat().st_size:
                        self.add(scope, "PHC-SEA-040", str(relative), "Seal output hash/length differs from bytes", str(output.get("resourceID") or artifact_id))

            source = str(seal.get("sourceMaster", ""))
            self.validate_svg_safety(scope, source, artifact_id)
            for role in ("seal.vector-master", "seal.monochrome-fallback"):
                if role in roles:
                    self.validate_pdf(scope, roles[role], monochrome=role == "seal.monochrome-fallback")
            if roles.get("seal.vector-master", {}).get("sha256") == roles.get("seal.monochrome-fallback", {}).get("sha256"):
                self.add(scope, "PHC-SEA-028", str(roles.get("seal.monochrome-fallback", {}).get("filename", ASSET_MANIFEST)), "monochrome fallback must be a distinct transformation", artifact_id)

            allowed = set(str(item) for item in as_list(seal.get("allowedAnchorCategories")))
            declared_categories = set(str(item) for item in as_list(resource.get("compatibleAnchorCategories")))
            if declared_categories != allowed or not allowed:
                self.add(scope, "PHC-SEA-029", ASSET_MANIFEST, f"compatible anchor categories must exactly match descriptor: {sorted(allowed)}", artifact_id)
            expected_relic_ids = {
                relic_id for relic_id, descriptor in relics_by_codex[codex_id].items()
                if allowed.intersection(str(item) for item in as_list(descriptor.get("sealAnchors")))
            }
            compatible_relic_ids = set(str(item) for item in as_list(resource.get("compatibleRelicIDs")))
            if compatible_relic_ids != expected_relic_ids:
                self.add(scope, "PHC-SEA-030", ASSET_MANIFEST, f"compatibleRelicIDs differ from legal anchors: expected {sorted(expected_relic_ids)}", artifact_id)
            if not is_nonempty(seal.get("accessibilityDescription")):
                self.add(scope, "PHC-SEA-031", ASSET_MANIFEST, "Seal accessibility description is missing", artifact_id)

            record = recognition_by_asset.get(artifact_id) or recognition_by_source.get(source)
            if not isinstance(record, dict):
                self.add(scope, "PHC-SEA-032", recognition_path, "Seal recognition record is missing", artifact_id)
            else:
                smallest = record.get("smallestOutput") if isinstance(record.get("smallestOutput"), dict) else {}
                recognized = record.get("recognizableAtMinimumSize") is True or record.get("recognizableAt24pt") is True or record.get("status") == "PASS" or smallest.get("status") == "PASS"
                minimum = record.get("minimumPointSize") or record.get("pointSize") or 24
                if not recognized or not isinstance(minimum, (int, float)) or minimum > 24:
                    self.add(scope, "PHC-SEA-033", recognition_path, "Seal is not proven recognizable at the required smallest output", artifact_id)
                output_path = record.get("smallestRequiredOutput") or record.get("thumbnailPath") or record.get("path") or smallest.get("path")
                if normalized_relative_path(output_path) is None or not (self.root / str(output_path)).is_file():
                    self.add(scope, "PHC-SEA-034", str(output_path), "Seal smallest-output evidence file is missing", artifact_id)
                elif (record.get("sha256") or smallest.get("sha256")) != sha256_file(self.root / str(output_path)):
                    self.add(scope, "PHC-SEA-035", str(output_path), "Seal smallest-output evidence hash differs from bytes", artifact_id)

        crest_sources: Set[str] = set()
        for codex in self.codices:
            crest = codex.get("crest")
            if not isinstance(crest, dict):
                continue
            source = crest.get("sourceMaster")
            if isinstance(source, str):
                crest_sources.add(source)
            if crest.get("assetClass") != "crest" or crest.get("sourceClass") != "crest" or crest.get("semanticRole") != "masteryCrest" or crest.get("placeableOnSealAnchor") is not False:
                self.add(scope, "PHC-SEA-036", ASSET_MANIFEST, "Crest classification or anchor exclusion is invalid", str(crest.get("assetID", "")) or None)
        for resource in self.resources:
            if resource.get("assetClass") == "crest" and resource.get("placeableOnSealAnchor") is not False:
                self.add(scope, "PHC-SEA-037", ASSET_MANIFEST, "Crest logical resource must explicitly forbid Seal-anchor placement", str(resource.get("resourceID", "")) or None)
            if resource.get("assetClass") == "seal" and resource.get("sourceMasterPath") in crest_sources:
                self.add(scope, "PHC-SEA-038", ASSET_MANIFEST, "Crest source is classified or used as a Seal", str(resource.get("resourceID", "")) or None)
        self.record(scope, f"Observed {len(seals)} Seal descriptors and {len(seal_outputs)} Seal outputs")

    def candidate_json(self, scope: str, candidates: Sequence[str]) -> Tuple[Optional[Dict[str, Any]], str]:
        for relative in candidates:
            value = self.read_json(relative, scope, required=False)
            if isinstance(value, dict):
                return value, relative
        return None, candidates[0]

    @staticmethod
    def font_name(font: TTFont, name_id: int) -> Optional[str]:
        table = font.get("name")
        if table is None:
            return None
        candidates = [
            table.getName(name_id, 3, 1, 0x409),
            table.getName(name_id, 3, 10, 0x409),
            table.getName(name_id, 1, 0, 0),
        ]
        for value in candidates:
            if value is not None:
                try:
                    return value.toUnicode()
                except Exception:
                    return str(value)
        values = [item for item in table.names if item.nameID == name_id]
        if values:
            try:
                return values[0].toUnicode()
            except Exception:
                return None
        return None

    @staticmethod
    def glyph_signature(font: TTFont, glyph_name: str) -> str:
        pen = RecordingPen()
        font.getGlyphSet()[glyph_name].draw(pen)
        normalized = repr(pen.value).encode("utf-8")
        return hashlib.sha256(normalized).hexdigest()

    def validate_font_reference(
        self,
        scope: str,
        evidence_path: str,
        reference: Any,
        code: str,
        label: str,
        resource_id: str,
    ) -> None:
        if not isinstance(reference, dict):
            self.add(scope, code, evidence_path, f"{label} reference is missing", resource_id)
            return
        relative = reference.get("path")
        if reference.get("status") != "PASS":
            self.add(scope, code, evidence_path, f"{label} status is not PASS", resource_id)
        if normalized_relative_path(relative) is None or not (self.root / str(relative)).is_file():
            self.add(scope, code, str(relative), f"{label} evidence file is missing", resource_id)
            return
        declared_hash = reference.get("sha256")
        if declared_hash != sha256_file(self.root / str(relative)):
            self.add(scope, code, str(relative), f"{label} evidence hash differs from bytes", resource_id)

    def validate_fonts(self) -> None:
        scope = "fonts"
        script_resources = [item for item in self.resources if item.get("assetClass") == "script"]
        if len(script_resources) != 4:
            self.add(scope, "PHC-FNT-001", ASSET_MANIFEST, f"exactly four Script/font resources are required; found {len(script_resources)}")
        evidence, evidence_path = self.candidate_json(
            scope,
            ("Validation/fonts/font-evidence.json", "Validation/font-evidence.json"),
        )
        if evidence is None:
            self.add(scope, "PHC-FNT-002", evidence_path, "four-font production evidence is missing")
            evidence_records: List[Dict[str, Any]] = []
        else:
            evidence_records = [item for item in as_list(evidence.get("records") or evidence.get("fonts")) if isinstance(item, dict)]
            if len(evidence_records) != 4:
                self.add(scope, "PHC-FNT-003", evidence_path, f"font evidence must contain four records; found {len(evidence_records)}")
        evidence_by_script = {
            item.get("scriptID"): item for item in evidence_records if is_nonempty(item.get("scriptID"))
        }
        evidence_by_resource = {
            item.get("fontResourceID"): item for item in evidence_records if is_nonempty(item.get("fontResourceID"))
        }
        expected_ps_names: Set[str] = set()
        seen_ps_names: Set[str] = set()
        for codex in self.codices:
            codex_id = str(codex.get("codexID", ""))
            script = codex.get("script")
            if not isinstance(script, dict):
                self.add(scope, "PHC-FNT-004", ASSET_MANIFEST, "Codex Script descriptor is missing", codex_id)
                continue
            script_id = str(script.get("scriptID", ""))
            expected_ps = str(script.get("postScriptName", ""))
            expected_ps_names.add(expected_ps)
            glyph_manifest_path = script.get("glyphMasterManifest")
            glyph_manifest = self.read_json(str(glyph_manifest_path), scope) if isinstance(glyph_manifest_path, str) else None
            if not isinstance(glyph_manifest, dict):
                self.add(scope, "PHC-FNT-005", str(glyph_manifest_path), "glyph master manifest is missing or invalid", script_id)
                continue
            glyphs = [item for item in as_list(glyph_manifest.get("glyphs")) if isinstance(item, dict)]
            values = [item.get("canonicalValue") for item in glyphs]
            tokens = [item.get("unicodeToken") for item in glyphs]
            if values != list(range(32)) or len(set(values)) != 32:
                self.add(scope, "PHC-FNT-006", str(glyph_manifest_path), "canonical values must be ordered exactly 0 through 31", script_id)
            if tokens != [f"U+{0x16A0 + value:04X}" for value in range(32)] or len(set(tokens)) != 32:
                self.add(scope, "PHC-FNT-007", str(glyph_manifest_path), "Unicode transport tokens must be U+16A0 through U+16BF exactly once", script_id)
            classifications = Counter(item.get("classification") for item in glyphs)
            if classifications != Counter({"primary": 24, "secondary-variant": 8}):
                self.add(scope, "PHC-FNT-008", str(glyph_manifest_path), f"glyph classes must be 24 primary and 8 secondary; found {dict(classifications)}", script_id)
            glyph_ids = [item.get("glyphID") for item in glyphs]
            if len(glyph_ids) != 32 or len(set(glyph_ids)) != 32 or any(not is_nonempty(item) for item in glyph_ids):
                self.add(scope, "PHC-FNT-009", str(glyph_manifest_path), "32 unique nonempty glyph IDs are required", script_id)
            for glyph in glyphs:
                source = glyph.get("sourceMaster")
                if normalized_relative_path(source) is None or not (self.root / str(source)).is_file():
                    self.add(scope, "PHC-FNT-010", str(source), "glyph source master is missing or unsafe", str(glyph.get("glyphID") or script_id))
                elif svg_viewbox(self.root / str(source)) is None:
                    self.add(scope, "PHC-FNT-011", str(source), "glyph source SVG is invalid", str(glyph.get("glyphID") or script_id))

            resource = next(
                (
                    item for item in script_resources
                    if item.get("scriptID") == script_id or item.get("resourceID") == script.get("resourceID")
                ),
                None,
            )
            if resource is None:
                self.add(scope, "PHC-FNT-012", ASSET_MANIFEST, "Script logical resource does not resolve", script_id)
                continue
            roles = self.outputs_for_roles(resource)
            font_output = roles.get("script.font")
            fallback_output = roles.get("script.static-fallback")
            if font_output is None:
                self.add(scope, "PHC-FNT-013", ASSET_MANIFEST, "Script font output is missing", script_id)
                continue
            if fallback_output is None or font_output.get("fallbackResourceID") != fallback_output.get("resourceID"):
                self.add(scope, "PHC-FNT-014", ASSET_MANIFEST, "font does not resolve to its declared static fallback", script_id)
            font_relative = font_output.get("filename")
            if normalized_relative_path(font_relative) is None or not (self.root / str(font_relative)).is_file():
                self.add(scope, "PHC-FNT-015", str(font_relative), "font file is missing", script_id)
                continue
            try:
                font = TTFont(self.root / str(font_relative), lazy=False)
            except Exception as error:
                self.add(scope, "PHC-FNT-016", str(font_relative), f"font parse failed: {type(error).__name__}: {error}", script_id)
                continue
            try:
                self.validate_font_tables(scope, script_id, str(font_relative), font, glyph_manifest, expected_ps, seen_ps_names)
            finally:
                font.close()

            evidence_record = evidence_by_script.get(script_id) or evidence_by_resource.get(font_output.get("resourceID"))
            if not isinstance(evidence_record, dict):
                self.add(scope, "PHC-FNT-017", evidence_path, "font evidence record is missing", script_id)
                continue
            if evidence_record.get("fontPath") != font_relative or evidence_record.get("fontSHA256") != font_output.get("sha256"):
                self.add(scope, "PHC-FNT-018", evidence_path, "font evidence path/hash differs from manifest", script_id)
            if evidence_record.get("rightsProvenanceID") != resource.get("provenanceID"):
                self.add(scope, "PHC-FNT-019", evidence_path, "font rights provenance differs from logical resource", script_id)
            self.validate_font_reference(scope, evidence_path, evidence_record.get("characterMapReport"), "PHC-FNT-020", "character-map report", script_id)
            self.validate_font_reference(scope, evidence_path, evidence_record.get("metricsReport"), "PHC-FNT-021", "metrics/bounds report", script_id)
            self.validate_font_reference(scope, evidence_path, evidence_record.get("postScriptNameReport"), "PHC-FNT-022", "PostScript-name report", script_id)
            self.validate_font_reference(scope, evidence_path, evidence_record.get("confusabilityReport"), "PHC-FNT-023", "confusability report", script_id)
            self.validate_font_reference(scope, evidence_path, evidence_record.get("fallbackEvidence"), "PHC-FNT-024", "fallback evidence", script_id)
            self.validate_font_reference(scope, evidence_path, evidence_record.get("highContrastEvidence"), "PHC-FNT-025", "High Contrast evidence", script_id)
            confusability = evidence_record.get("confusabilityReport")
            if not isinstance(confusability, dict) or confusability.get("pairCount") != 496:
                self.add(scope, "PHC-FNT-026", evidence_path, "confusability report must cover all 496 glyph pairs", script_id)
            specimen_records = [item for item in as_list(evidence_record.get("specimens")) if isinstance(item, dict)]
            kinds = {item.get("kind") for item in specimen_records}
            if kinds != FONT_EVIDENCE_KINDS or len(specimen_records) != len(FONT_EVIDENCE_KINDS):
                self.add(scope, "PHC-FNT-027", evidence_path, f"specimen kinds must equal {sorted(FONT_EVIDENCE_KINDS)}", script_id)
            for specimen in specimen_records:
                self.validate_font_reference(scope, evidence_path, specimen, "PHC-FNT-028", f"{specimen.get('kind')} specimen", script_id)
                if specimen.get("kind") == "long-inscription" and not as_list(specimen.get("layoutProfileIDs")):
                    self.add(scope, "PHC-FNT-029", evidence_path, "long-inscription specimen must link applicable Relic layout profiles", script_id)
            reduce_motion = evidence_record.get("reduceMotionCompatibility")
            if not isinstance(reduce_motion, dict) or reduce_motion.get("status") != "PASS" or not is_nonempty(reduce_motion.get("reason")):
                self.add(scope, "PHC-FNT-030", evidence_path, "Reduce Motion compatibility must be explicit and PASS", script_id)

        if expected_ps_names != seen_ps_names or len(seen_ps_names) != 4:
            self.add(scope, "PHC-FNT-031", ASSET_MANIFEST, "four expected unique PostScript names were not resolved")
        self.validate_font_registration(script_resources)
        self.record(scope, f"Observed {len(script_resources)} Script/font resources and {len(evidence_records)} evidence records")

    def validate_font_tables(
        self,
        scope: str,
        script_id: str,
        relative: str,
        font: TTFont,
        glyph_manifest: Dict[str, Any],
        expected_ps: str,
        seen_ps_names: Set[str],
    ) -> None:
        expected_codepoints = set(range(0x16A0, 0x16C0))
        cmap = font.getBestCmap() or {}
        if set(cmap) != expected_codepoints:
            self.add(scope, "PHC-FNT-032", relative, f"font cmap must contain only U+16A0 through U+16BF; found {len(cmap)} entries", script_id)
        if len(set(cmap.values())) != 32:
            self.add(scope, "PHC-FNT-033", relative, "font cmap aliases two canonical values to one glyph", script_id)
        unicode_maps = [table.cmap for table in font["cmap"].tables if table.isUnicode()] if "cmap" in font else []
        if not unicode_maps or any(set(table) != expected_codepoints for table in unicode_maps):
            self.add(scope, "PHC-FNT-034", relative, "a Unicode cmap subtable is missing values or contains unintended aliases", script_id)
        ps_name = self.font_name(font, 6)
        family = self.font_name(font, 1)
        style = self.font_name(font, 2)
        version = self.font_name(font, 5)
        if ps_name != expected_ps:
            self.add(scope, "PHC-FNT-035", relative, f"PostScript name {ps_name!r} differs from {expected_ps!r}", script_id)
        elif ps_name in seen_ps_names:
            self.add(scope, "PHC-FNT-036", relative, "PostScript name duplicates another font", script_id)
        else:
            seen_ps_names.add(ps_name)
        expected_family = expected_ps.removesuffix("-Regular")
        if family != expected_family or style != "Regular":
            self.add(scope, "PHC-FNT-037", relative, f"family/style names are incorrect: {family!r}/{style!r}", script_id)
        if not is_nonempty(version) or not str(version).startswith("Version ") or not isinstance(font["head"].fontRevision, (int, float)) or font["head"].fontRevision <= 0:
            self.add(scope, "PHC-FNT-038", relative, "font version metadata is missing or invalid", script_id)
        expected_metrics = {
            "unitsPerEm": glyph_manifest.get("unitsPerEm"),
            "ascent": glyph_manifest.get("ascender"),
            "descent": glyph_manifest.get("descender"),
            "lineGap": glyph_manifest.get("lineGap"),
        }
        actual_metrics = {
            "unitsPerEm": font["head"].unitsPerEm,
            "ascent": font["hhea"].ascent,
            "descent": font["hhea"].descent,
            "lineGap": font["hhea"].lineGap,
        }
        if actual_metrics != expected_metrics:
            self.add(scope, "PHC-FNT-039", relative, f"font global metrics differ: {actual_metrics}", script_id)
        expected_advance = glyph_manifest.get("advanceWidth")
        missing_bounds: List[str] = []
        wrong_advances: List[str] = []
        signatures: Dict[str, str] = {}
        for codepoint in sorted(expected_codepoints):
            glyph_name = cmap.get(codepoint)
            if not glyph_name:
                continue
            advance, _ = font["hmtx"].metrics.get(glyph_name, (None, None))
            if advance != expected_advance:
                wrong_advances.append(glyph_name)
            glyph = font["glyf"][glyph_name] if "glyf" in font else None
            if glyph is None:
                missing_bounds.append(glyph_name)
            else:
                try:
                    glyph.recalcBounds(font["glyf"])
                    bounds = (glyph.xMin, glyph.yMin, glyph.xMax, glyph.yMax)
                    if bounds[2] <= bounds[0] or bounds[3] <= bounds[1]:
                        missing_bounds.append(glyph_name)
                except Exception:
                    missing_bounds.append(glyph_name)
            try:
                signatures[glyph_name] = self.glyph_signature(font, glyph_name)
            except Exception:
                missing_bounds.append(glyph_name)
        if wrong_advances:
            self.add(scope, "PHC-FNT-040", relative, f"glyph advances differ from {expected_advance}: {wrong_advances}", script_id)
        if missing_bounds:
            self.add(scope, "PHC-FNT-041", relative, f"glyph bounds are empty or unreadable: {sorted(set(missing_bounds))}", script_id)
        grouped: Dict[str, List[str]] = defaultdict(list)
        for name, signature in signatures.items():
            grouped[signature].append(name)
        duplicates = [names for names in grouped.values() if len(names) > 1]
        if duplicates:
            self.add(scope, "PHC-FNT-042", relative, f"deterministically duplicate glyph outlines: {duplicates}", script_id)
        prohibited_tables = {"GSUB", "fvar", "gvar", "avar", "HVAR", "VVAR", "MVAR", "COLR", "CPAL", "SVG ", "CBDT", "CBLC", "sbix"}
        present = sorted(prohibited_tables.intersection(font.keys()))
        if present:
            self.add(scope, "PHC-FNT-043", relative, f"font contains prohibited alias/variable/color tables: {present}", script_id)
        required_tables = {"head", "hhea", "maxp", "OS/2", "hmtx", "cmap", "loca", "glyf", "name", "post"}
        missing_tables = sorted(required_tables - set(font.keys()))
        if missing_tables:
            self.add(scope, "PHC-FNT-044", relative, f"font lacks required production tables: {missing_tables}", script_id)

    def validate_font_registration(self, script_resources: Sequence[Dict[str, Any]]) -> None:
        scope = "fonts"
        registration, relative = self.candidate_json(
            scope,
            ("Validation/fonts/font-registration.json", "Validation/font-registration.json"),
        )
        if registration is None:
            self.add(scope, "PHC-FNT-045", relative, "font registration evidence is missing")
            return
        if registration.get("status") != "PASS" or registration.get("expectedFontCount") != 4:
            self.add(scope, "PHC-FNT-046", relative, "font registration aggregate status/count must be PASS/4")
        if registration.get("packageVersion") != self.manifest.get("packageVersion"):
            self.add(scope, "PHC-FNT-052", relative, "registration packageVersion differs from the asset manifest")
        if type(registration.get("schemaVersion")) is not int or registration.get("schemaVersion") != 1 or not valid_utc_timestamp(registration.get("generatedAtUTC")):
            self.add(scope, "PHC-FNT-053", relative, "registration schemaVersion/generatedAtUTC is missing or invalid")
        platforms = [item for item in as_list(registration.get("platforms")) if isinstance(item, dict)]
        by_platform = {item.get("platform"): item for item in platforms}
        if set(by_platform) != {"macOS", "iOS Simulator"} or len(platforms) != 2:
            self.add(scope, "PHC-FNT-047", relative, "registration evidence must contain macOS and iOS Simulator exactly once")
        expected: Dict[str, Tuple[str, str, str]] = {}
        for resource in script_resources:
            font = self.outputs_for_roles(resource).get("script.font")
            if font and is_nonempty(font.get("resourceID")):
                expected[str(font["resourceID"])] = (
                    str(font.get("filename", "")),
                    str(font.get("sha256", "")),
                    str(resource.get("postScriptName", "")),
                )
        for platform_name in ("macOS", "iOS Simulator"):
            platform = by_platform.get(platform_name)
            if not isinstance(platform, dict):
                continue
            device_valid = platform.get("device") is None if platform_name == "macOS" else is_nonempty(platform.get("device"))
            if platform.get("status") != "PASS" or not is_nonempty(platform.get("runtimeVersion")) or not device_valid or not is_nonempty(platform.get("command")):
                self.add(scope, "PHC-FNT-048", relative, f"{platform_name} registration metadata/status is incomplete")
            records = [item for item in as_list(platform.get("fonts")) if isinstance(item, dict)]
            if len(records) != 4 or {item.get("resourceID") for item in records} != set(expected):
                self.add(scope, "PHC-FNT-049", relative, f"{platform_name} must cover the four font resource IDs exactly")
            for item in records:
                resource_id = str(item.get("resourceID", ""))
                facts = expected.get(resource_id)
                if not facts:
                    continue
                filename, digest, ps_name = facts
                if (
                    item.get("filename") != filename
                    or item.get("sha256") != digest
                    or item.get("expectedPostScriptName") != ps_name
                    or item.get("resolvedPostScriptName") != ps_name
                    or item.get("registered") is not True
                    or item.get("status") != "PASS"
                    or item.get("errorCode") is not None
                ):
                    self.add(scope, "PHC-FNT-050", relative, f"{platform_name} registration facts differ from the package", resource_id)
        if registration.get("errors") != []:
            self.add(scope, "PHC-FNT-051", relative, "PASS registration evidence errors must be an explicit empty array")

    def validate_accessibility(self, scope: str, path: str, value: Any, resource_id: str) -> None:
        if not isinstance(value, dict):
            self.add(scope, "PHC-SHR-001", path, "accessibility metadata must be an object", resource_id)
            return
        required = {"label", "hint", "hidesRedundantGlyphs", "noColorOnlyState", "dynamicTypeSafe"}
        missing = required - set(value)
        if missing:
            self.add(scope, "PHC-SHR-002", path, f"accessibility metadata lacks Theme contract fields: {sorted(missing)}", resource_id)
        label = value.get("label")
        if not isinstance(label, dict) or not is_nonempty(label.get("key")) or not is_nonempty(label.get("fallbackValue")):
            self.add(scope, "PHC-SHR-003", path, "accessibility label must have a localization key and fallbackValue", resource_id)
        hint = value.get("hint")
        if hint is not None and (not isinstance(hint, dict) or not is_nonempty(hint.get("key")) or not is_nonempty(hint.get("fallbackValue"))):
            self.add(scope, "PHC-SHR-004", path, "accessibility hint must be null or complete localized text", resource_id)
        if not isinstance(value.get("hidesRedundantGlyphs"), bool):
            self.add(scope, "PHC-SHR-005", path, "hidesRedundantGlyphs must be explicit boolean", resource_id)
        if value.get("noColorOnlyState") is not True:
            self.add(scope, "PHC-SHR-006", path, "noColorOnlyState must be true", resource_id)
        if value.get("dynamicTypeSafe") is not True:
            self.add(scope, "PHC-SHR-007", path, "dynamicTypeSafe must be true", resource_id)

    def validate_share_accessibility_fallbacks(self) -> None:
        scope = "share-accessibility-fallbacks"
        roles = Counter(output.get("outputRole") for _, output in self.outputs)
        expected = {
            "relic.static-share-fallback": 12,
            "relic.high-contrast": 12,
            "background.static-base": 4,
            "background.reduce-motion": 4,
            "background.high-contrast": 4,
            "vault.card": 4,
            "vault.locked-silhouette": 4,
            "vault.encountered": 4,
            "vault.selected": 4,
            "script.static-fallback": 4,
            "seal.monochrome-fallback": 24,
            "frame.static-fallback": 4,
            "crest.static-fallback": 4,
        }
        for role, count in expected.items():
            if roles[role] != count:
                self.add(scope, "PHC-SHR-008", ASSET_MANIFEST, f"{role} count must be {count}; found {roles[role]}")
        invented_motion = sorted(role for role in roles if isinstance(role, str) and ("motion" in role or "animation" in role) and role != "background.reduce-motion")
        if invented_motion:
            self.add(scope, "PHC-SHR-009", ASSET_MANIFEST, f"undeclared motion/animation output roles are forbidden: {invented_motion}")

        terminal_roles = {
            "script.static-fallback",
            "background.reduce-motion",
            "vault.locked-silhouette",
            "relic.static-share-fallback",
            "seal.monochrome-fallback",
            "frame.static-fallback",
            "crest.static-fallback",
        }
        fallback_edges: Dict[str, str] = {}
        for resource in self.resources:
            resource_id = str(resource.get("resourceID", ""))
            self.validate_accessibility(scope, ASSET_MANIFEST, resource.get("accessibility"), resource_id)
            fallback_id = resource.get("fallbackResourceID")
            if not is_nonempty(fallback_id) or len(self.outputs_by_id.get(str(fallback_id), [])) != 1:
                self.add(scope, "PHC-SHR-010", ASSET_MANIFEST, "logical fallbackResourceID must resolve to one output", resource_id)
            if not is_nonempty(resource.get("fallbackBehavior")):
                self.add(scope, "PHC-SHR-011", ASSET_MANIFEST, "logical fallback behavior is missing", resource_id)
            for output in as_list(resource.get("outputVariants")):
                if not isinstance(output, dict):
                    continue
                output_id = str(output.get("resourceID", ""))
                path = str(output.get("filename", ASSET_MANIFEST))
                self.validate_accessibility(scope, path, output.get("accessibility"), output_id)
                fallback = output.get("fallbackResourceID")
                if not is_nonempty(fallback) or len(self.outputs_by_id.get(str(fallback), [])) != 1:
                    self.add(scope, "PHC-SHR-012", path, "output fallbackResourceID must resolve exactly once", output_id)
                else:
                    fallback_edges[output_id] = str(fallback)
                if not is_nonempty(output.get("fallbackBehavior")):
                    self.add(scope, "PHC-SHR-013", path, "output fallback behavior is missing", output_id)
                if output_id == fallback and output.get("outputRole") not in terminal_roles:
                    self.add(scope, "PHC-SHR-014", path, "only an approved terminal static representation may self-resolve", output_id)
        for start in sorted(fallback_edges):
            seen: List[str] = []
            current = start
            while current in fallback_edges:
                target = fallback_edges[current]
                if target == current:
                    break
                if target in seen:
                    self.add(scope, "PHC-SHR-015", ASSET_MANIFEST, f"fallback cycle detected: {' -> '.join(seen + [target])}", start)
                    break
                seen.append(current)
                current = target
                if len(seen) > 184:
                    self.add(scope, "PHC-SHR-015", ASSET_MANIFEST, "fallback chain does not terminate", start)
                    break

        share_data, share_path = self.candidate_json(
            scope,
            ("Validation/share/share-layouts.json", "Validation/share-layouts.json"),
        )
        if share_data is None:
            self.add(scope, "PHC-SHR-016", share_path, "share-layout evidence is missing")
            share_records: List[Dict[str, Any]] = []
        else:
            share_records = [item for item in as_list(share_data.get("records")) if isinstance(item, dict)]
            if share_data.get("status") != "PASS" or len(share_records) != 12 or share_data.get("recordCount", 12) != 12:
                self.add(scope, "PHC-SHR-017", share_path, f"share-layout evidence must be PASS with 12 records; found {len(share_records)}")
        share_by_relic = {
            item.get("relicID"): item for item in share_records if is_nonempty(item.get("relicID"))
        }
        relics, _ = self.descriptor_maps()
        for relic_id in sorted(relics):
            record = share_by_relic.get(relic_id)
            resource = self.resource_for_artifact("relic", relic_id)
            if not isinstance(record, dict) or resource is None:
                self.add(scope, "PHC-SHR-018", share_path, "Relic share declaration does not resolve exactly once", relic_id)
                continue
            share_contract = resource.get("shareContract")
            if not isinstance(share_contract, dict):
                self.add(scope, "PHC-SHR-019", ASSET_MANIFEST, "Relic logical resource lacks shareContract", relic_id)
                continue
            if record.get("status") != "PASS" or record.get("resourceID") != resource.get("resourceID"):
                self.add(scope, "PHC-SHR-020", share_path, "share evidence status/resourceID differs", relic_id)
            for key, value in share_contract.items():
                if record.get(key) != value:
                    self.add(scope, "PHC-SHR-021", share_path, f"share evidence differs from resource shareContract field {key}", relic_id)
            required = {
                "layoutProfileID",
                "sourceAspectRatio",
                "preferredAspectRatio",
                "shareCanvasDimensions",
                "cropPolicy",
                "glyphSafeRegionNormalized",
                "reservedRegionsNormalized",
                "compatibleAnchorCategories",
                "attributionPolicy",
                "provenancePolicy",
                "serialPolicy",
                "qrPolicy",
                "staticShareResourceID",
                "highContrastResourceID",
                "reduceMotion",
                "highContrast",
            }
            missing = required - set(share_contract)
            if missing:
                self.add(scope, "PHC-SHR-022", ASSET_MANIFEST, f"shareContract lacks declarations: {sorted(missing)}", relic_id)
            if "no-stretch" not in str(share_contract.get("cropPolicy", "")):
                self.add(scope, "PHC-SHR-023", ASSET_MANIFEST, "share crop policy must explicitly forbid stretching", relic_id)
            if normalized_region(share_contract.get("glyphSafeRegionNormalized")) is None:
                self.add(scope, "PHC-SHR-024", ASSET_MANIFEST, "share glyph safe region is invalid", relic_id)
            reserved = share_contract.get("reservedRegionsNormalized")
            if not isinstance(reserved, (list, dict)) or not reserved:
                self.add(scope, "PHC-SHR-025", ASSET_MANIFEST, "share protected/reserved region declaration is empty", relic_id)
            if share_contract.get("qrPolicy") not in {"disabled", "none", "no-resource", "disabled-no-resource"}:
                self.add(scope, "PHC-SHR-026", ASSET_MANIFEST, "share QR policy must disable QR output", relic_id)
            reduce_motion = share_contract.get("reduceMotion")
            high_contrast = share_contract.get("highContrast")
            if not isinstance(reduce_motion, dict) or reduce_motion.get("status") != "PASS" or not is_nonempty(reduce_motion.get("reason")):
                self.add(scope, "PHC-SHR-027", ASSET_MANIFEST, "static Reduce Motion declaration is incomplete", relic_id)
            if not isinstance(high_contrast, dict) or high_contrast.get("status") != "PASS" or not isinstance(high_contrast.get("minimumContrastRatio"), (int, float)) or high_contrast.get("minimumContrastRatio", 0) < 7:
                self.add(scope, "PHC-SHR-028", ASSET_MANIFEST, "High Contrast declaration must be PASS at 7:1 or better", relic_id)
            role_outputs = self.outputs_for_roles(resource)
            if share_contract.get("staticShareResourceID") != role_outputs.get("relic.static-share-fallback", {}).get("resourceID") or share_contract.get("highContrastResourceID") != role_outputs.get("relic.high-contrast", {}).get("resourceID"):
                self.add(scope, "PHC-SHR-029", ASSET_MANIFEST, "share/High Contrast resource IDs do not resolve to active roles", relic_id)
        self.record(scope, f"Observed fallback and accessibility declarations on {len(self.outputs)} outputs")

    def validate_provenance_recipes(self) -> None:
        scope = "provenance-recipes"
        ledger_path = self.manifest.get("provenanceLedgerPath")
        if normalized_relative_path(ledger_path) is None:
            self.add(scope, "PHC-PRO-001", str(ledger_path), "provenanceLedgerPath is missing or unsafe")
            return
        if not self.provenance_records:
            self.add(scope, "PHC-PRO-002", str(ledger_path), "provenance ledger has no records")
        declared_count = self.manifest.get("provenanceRecordCount")
        if declared_count != len(self.provenance_records):
            self.add(scope, "PHC-PRO-003", str(ledger_path), f"manifest provenanceRecordCount {declared_count!r} differs from {len(self.provenance_records)}")
        provenance_ids = [item.get("provenanceID") for item in self.provenance_records]
        if any(not is_nonempty(item) for item in provenance_ids) or len(set(provenance_ids)) != len(provenance_ids):
            self.add(scope, "PHC-PRO-004", str(ledger_path), "provenance IDs must be nonempty and unique")

        sources = {
            item.relative_to(self.root).as_posix()
            for directory_name in ("Source-Masters", "Production-Sources")
            for item in (self.root / directory_name).rglob("*")
            if item.is_file() and not item.is_symlink()
        }
        source_declarations = [item.get("sourceMasterPath") for item in self.provenance_records]
        if set(source_declarations) != sources or len(source_declarations) != len(set(source_declarations)):
            missing = sorted(sources - set(source_declarations))
            extra = sorted(set(source_declarations) - sources)
            self.add(scope, "PHC-PRO-005", str(ledger_path), f"source coverage must be exact and unique; missing={missing}, extra={extra}")

        output_provenance: Dict[str, List[Tuple[Dict[str, Any], Dict[str, Any]]]] = defaultdict(list)
        referenced_recipe_ids: Set[str] = set()
        placeholders = {"", "unknown", "tbd", "todo", "pending", "automation", "n/a", "none"}
        for record in self.provenance_records:
            provenance_id = str(record.get("provenanceID", ""))
            missing_fields = PROVENANCE_FIELDS - set(record)
            if missing_fields:
                self.add(scope, "PHC-PRO-006", str(ledger_path), f"provenance record lacks fields: {sorted(missing_fields)}", provenance_id or None)
            for key in (
                "creatorOrCommissioningEntity",
                "actualAuthoringToolAndVersion",
                "creationDateUTC",
                "rightsHolder",
                "rightsBasisOrLicense",
                "approvedBy",
                "approvalDateUTC",
            ):
                value = str(record.get(key, "")).strip()
                if value.casefold() in placeholders:
                    self.add(scope, "PHC-PRO-007", str(ledger_path), f"{key} contains placeholder or empty provenance", provenance_id or None)
            if not UTC_PATTERN.fullmatch(str(record.get("creationDateUTC", ""))):
                self.add(scope, "PHC-PRO-008", str(ledger_path), "creationDateUTC is not an explicit UTC timestamp", provenance_id or None)
            source = record.get("sourceMasterPath")
            if normalized_relative_path(source) is None or not (self.root / str(source)).is_file():
                self.add(scope, "PHC-PRO-009", str(source), "provenance source is missing or unsafe", provenance_id or None)
            else:
                if record.get("sourceMasterSHA256") != sha256_file(self.root / str(source)):
                    self.add(scope, "PHC-PRO-010", str(source), "sourceMasterSHA256 differs from bytes", provenance_id or None)
            reference_hash = str(record.get("sourceReferenceSHA256", ""))
            if not HASH_PATTERN.fullmatch(reference_hash) or set(reference_hash) == {"0"}:
                self.add(scope, "PHC-PRO-011", str(ledger_path), "sourceReferenceSHA256 is invalid or synthetic", provenance_id or None)
            recipe_id = record.get("exportRecipeID")
            if is_nonempty(recipe_id):
                referenced_recipe_ids.add(str(recipe_id))
            else:
                self.add(scope, "PHC-PRO-012", str(ledger_path), "provenance exportRecipeID is missing", provenance_id or None)
            export_settings = record.get("exportSettings")
            if not isinstance(export_settings, dict) or export_settings.get("deterministic") is not True or not is_nonempty(export_settings.get("pipeline")) or not HASH_PATTERN.fullmatch(str(export_settings.get("pipelineSHA256", ""))):
                self.add(scope, "PHC-PRO-013", str(ledger_path), "deterministic exportSettings/pipeline hash is incomplete", provenance_id or None)
            for output in as_list(record.get("outputFiles")):
                if not isinstance(output, dict):
                    self.add(scope, "PHC-PRO-014", str(ledger_path), "provenance output entry is not an object", provenance_id or None)
                    continue
                filename = output.get("filename")
                if isinstance(filename, str):
                    output_provenance[filename].append((record, output))
                if is_nonempty(output.get("exportRecipeID")):
                    referenced_recipe_ids.add(str(output.get("exportRecipeID")))
                required = {
                    "resourceID",
                    "artifactID",
                    "filename",
                    "outputRole",
                    "mediaType",
                    "dimensionsOrViewBox",
                    "colorSpace",
                    "alphaPolicy",
                    "compressionSettings",
                    "byteLength",
                    "sha256",
                    "exportRecipeID",
                    "createdAtUTC",
                }
                if not required <= set(output):
                    self.add(scope, "PHC-PRO-015", str(filename or ledger_path), f"provenance output lacks fields: {sorted(required - set(output))}", str(output.get("resourceID") or provenance_id))

        manifest_output_paths = set(self.outputs_by_path)
        if set(output_provenance) != manifest_output_paths or any(len(items) != 1 for items in output_provenance.values()):
            missing = sorted(manifest_output_paths - set(output_provenance))
            extra = sorted(set(output_provenance) - manifest_output_paths)
            duplicates = sorted(path for path, items in output_provenance.items() if len(items) != 1)
            self.add(scope, "PHC-PRO-016", str(ledger_path), f"output provenance must cover all 184 outputs exactly once; missing={missing}, extra={extra}, duplicates={duplicates}")
        compare_keys = {
            "resourceID",
            "artifactID",
            "filename",
            "outputRole",
            "mediaType",
            "dimensionsOrViewBox",
            "colorSpace",
            "alphaPolicy",
            "byteLength",
            "sha256",
            "exportRecipeID",
            "createdAtUTC",
        }
        resource_provenance_ids = {str(item.get("resourceID")): item.get("provenanceID") for item in self.resources}
        for resource, declared in self.outputs:
            filename = str(declared.get("filename", ""))
            records = output_provenance.get(filename, [])
            if len(records) != 1:
                continue
            record, generated = records[0]
            differences = sorted(key for key in compare_keys if generated.get(key) != declared.get(key))
            if differences:
                self.add(scope, "PHC-PRO-017", filename, f"provenance output differs from matrix fields: {differences}", str(declared.get("resourceID", "")) or None)
            if record.get("provenanceID") != resource.get("provenanceID") or resource_provenance_ids.get(str(resource.get("resourceID"))) != record.get("provenanceID"):
                self.add(scope, "PHC-PRO-018", filename, "output provenance record differs from logical provenanceID", str(declared.get("resourceID", "")) or None)
            path = self.root / filename
            if path.is_file() and (generated.get("sha256") != sha256_file(path) or generated.get("byteLength") != path.stat().st_size):
                self.add(scope, "PHC-PRO-019", filename, "provenance output hash/length differs from bytes", str(declared.get("resourceID", "")) or None)

        recipe_catalog, recipe_path = self.candidate_json(
            scope,
            ("Validation/recipes/recipe-catalog.json", "Validation/export-recipes.json", "Production-Sources/export-recipes.json"),
        )
        if recipe_catalog is None:
            self.add(scope, "PHC-REC-001", recipe_path, "export recipe catalog is missing")
            recipe_records: List[Dict[str, Any]] = []
        else:
            recipe_records = [item for item in as_list(recipe_catalog.get("records") or recipe_catalog.get("recipes")) if isinstance(item, dict)]
            if recipe_catalog.get("recordCount", len(recipe_records)) != len(recipe_records):
                self.add(scope, "PHC-REC-002", recipe_path, "recipe catalog recordCount differs from records")
        recipe_ids = [item.get("recipeID") for item in recipe_records]
        if any(not is_nonempty(item) for item in recipe_ids) or len(set(recipe_ids)) != len(recipe_ids):
            self.add(scope, "PHC-REC-003", recipe_path, "recipe IDs must be nonempty and unique")
        if set(recipe_ids) != referenced_recipe_ids:
            self.add(scope, "PHC-REC-004", recipe_path, f"recipe catalog must exactly resolve referenced recipes; missing={sorted(referenced_recipe_ids - set(recipe_ids))}, unused={sorted(set(recipe_ids) - referenced_recipe_ids)}")
        for recipe in recipe_records:
            recipe_id = str(recipe.get("recipeID", ""))
            source = recipe.get("sourcePath")
            if normalized_relative_path(source) is None or not (self.root / str(source)).is_file():
                self.add(scope, "PHC-REC-005", str(source), "recipe source is missing or unsafe", recipe_id or None)
                continue
            if recipe.get("sha256") != sha256_file(self.root / str(source)) or recipe.get("status") != "PASS":
                self.add(scope, "PHC-REC-006", str(source), "recipe catalog hash/status differs from recipe source", recipe_id or None)
            source_value = self.read_json(str(source), scope)
            if not isinstance(source_value, dict) or source_value.get("recipeID") != recipe_id or source_value.get("deterministic") is not True:
                self.add(scope, "PHC-REC-007", str(source), "recipe source lacks matching ID or deterministic=true", recipe_id or None)
            else:
                for key in ("pipeline", "tool", "toolVersions", "settings", "generatedAtUTC"):
                    if key not in source_value or source_value.get(key) in ({}, [], "", None):
                        self.add(scope, "PHC-REC-008", str(source), f"recipe source lacks explicit {key}", recipe_id or None)

        regeneration, regeneration_path = self.candidate_json(
            scope,
            ("Validation/deterministic-regeneration.json", "Validation/regeneration/deterministic-regeneration.json"),
        )
        if regeneration is None:
            self.add(scope, "PHC-DET-001", regeneration_path, "independent clean-target regeneration evidence is missing")
        else:
            required = {
                "schemaVersion",
                "packageVersion",
                "status",
                "command",
                "pipelinePath",
                "pipelineSHA256",
                "cleanTarget",
                "distinctTarget",
                "expectedOutputCount",
                "rebuiltOutputCount",
                "hashMismatches",
                "sourceHashMismatches",
            }
            if not required <= set(regeneration):
                self.add(scope, "PHC-DET-002", regeneration_path, f"regeneration evidence lacks fields: {sorted(required - set(regeneration))}")
            if (
                regeneration.get("packageVersion") != self.manifest.get("packageVersion")
                or regeneration.get("status") != "PASS"
                or regeneration.get("cleanTarget") is not True
                or regeneration.get("distinctTarget") is not True
                or regeneration.get("expectedOutputCount") != 184
                or regeneration.get("rebuiltOutputCount") != 184
                or as_list(regeneration.get("hashMismatches"))
                or as_list(regeneration.get("sourceHashMismatches"))
            ):
                self.add(scope, "PHC-DET-003", regeneration_path, "regeneration evidence does not prove an identical 184-output clean rebuild")
            pipeline = self.repo / "scripts/build-elven-production-assets.py"
            if not pipeline.is_file() or regeneration.get("pipelinePath") != "scripts/build-elven-production-assets.py" or regeneration.get("pipelineSHA256") != sha256_file(pipeline):
                self.add(scope, "PHC-DET-004", regeneration_path, "regeneration pipeline path/hash differs from current repository")
            if not isinstance(regeneration.get("command"), list) or not all(is_nonempty(item) for item in regeneration.get("command", [])):
                self.add(scope, "PHC-DET-005", regeneration_path, "regeneration command must be an explicit argv array")
        self.record(scope, f"Observed {len(self.provenance_records)} provenance records, {len(output_provenance)} output links, and {len(recipe_records)} recipes")

    def validate_file_magic(self, scope: str, relative: str, media: str, resource_id: str) -> None:
        path = self.root / relative
        try:
            header = path.read_bytes()[:64]
        except Exception as error:
            self.add(scope, "PHC-INT-012", relative, f"output bytes cannot be read: {error}", resource_id)
            return
        valid = True
        if media == "image/png":
            valid = header.startswith(b"\x89PNG\r\n\x1a\n")
        elif media == "application/pdf":
            valid = header.startswith(b"%PDF-")
        elif media == "font/ttf":
            valid = header.startswith((b"\x00\x01\x00\x00", b"true"))
        elif media == "font/otf":
            valid = header.startswith(b"OTTO")
        elif media == "image/heif":
            valid = len(header) >= 12 and header[4:8] == b"ftyp" and any(brand in header[8:] for brand in (b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"))
        elif media == "application/json":
            try:
                load_json_strict(path)
            except Exception:
                valid = False
        if not valid:
            self.add(scope, "PHC-INT-013", relative, f"file signature does not match declared mediaType {media}", resource_id)

    def validate_budgets_integrity(self) -> None:
        scope = "budgets-integrity"
        limits = self.manifest.get("sharedRequirements", {}).get("resourceLimits", {}) if isinstance(self.manifest.get("sharedRequirements"), dict) else {}
        required_limits = {
            "encodedDescriptorBytes": 262144,
            "oneStaticImageBytes": 8388608,
            "oneStaticImagePixels": [4096, 4096],
            "staticImageCatalogBytes": 33554432,
            "oneFontBytes": 8388608,
            "fontCatalogBytes": 16777216,
            "animationCatalogBytes": 16777216,
            "soundCatalogBytes": 8388608,
            "completeThemeModuleBytes": 67108864,
            "decodedResourceCacheBytes": 67108864,
        }
        for key, expected in required_limits.items():
            if limits.get(key) != expected:
                self.add(scope, "PHC-BUD-001", ASSET_MANIFEST, f"active resource limit {key} must remain {expected!r}")

        shipping_actual = {
            item.relative_to(self.root).as_posix()
            for item in (self.root / "Shipping").rglob("*")
            if item.is_file() and not item.is_symlink()
        } if (self.root / "Shipping").is_dir() else set()
        if shipping_actual != set(self.outputs_by_path):
            self.add(scope, "PHC-INT-001", "Shipping", f"Shipping tree and declared output paths differ; undeclared={sorted(shipping_actual - set(self.outputs_by_path))}, missing={sorted(set(self.outputs_by_path) - shipping_actual)}")
        module_bytes: Counter[str] = Counter()
        static_bytes: Counter[str] = Counter()
        font_bytes: Counter[str] = Counter()
        animation_bytes: Counter[str] = Counter()
        sound_bytes: Counter[str] = Counter()
        budget_classes = {
            "script": "font",
            "background": "static-image",
            "vault": "static-image",
            "relic": "static-image",
            "seal": "vector-and-static",
            "frame": "static-image",
            "crest": "static-image",
        }
        for resource, output in self.outputs:
            output_id = str(output.get("resourceID", ""))
            relative = output.get("filename")
            owner = str(resource.get("ownerCodexID", ""))
            asset_class = str(resource.get("assetClass", ""))
            media = str(output.get("mediaType", ""))
            if resource.get("budgetClass") != budget_classes.get(asset_class):
                self.add(scope, "PHC-BUD-002", ASSET_MANIFEST, f"budgetClass differs for {asset_class}", str(resource.get("resourceID", "")) or None)
            if normalized_relative_path(relative) is None:
                self.add(scope, "PHC-PATH-001", str(relative), "output path is unsafe or not normalized", output_id or None)
                continue
            path = self.root / str(relative)
            if not path.is_file() or path.is_symlink():
                self.add(scope, "PHC-INT-002", str(relative), "declared output is missing or a symbolic link", output_id or None)
                continue
            actual_size = path.stat().st_size
            actual_hash = sha256_file(path)
            if output.get("byteLength") != actual_size:
                self.add(scope, "PHC-INT-003", str(relative), f"byteLength {output.get('byteLength')!r} differs from {actual_size}", output_id or None)
            if output.get("sha256") != actual_hash:
                self.add(scope, "PHC-INT-004", str(relative), "declared SHA-256 differs from bytes", output_id or None)
            limit = output.get("maximumBytes")
            if not isinstance(limit, int) or actual_size > limit:
                self.add(scope, "PHC-BUD-003", str(relative), f"output uses {actual_size} bytes against limit {limit!r}", output_id or None)
            if media not in ALLOWED_MEDIA or actual_media_type(path) != media:
                self.add(scope, "PHC-INT-005", str(relative), f"declared mediaType {media!r} differs from path/media contract", output_id or None)
            if path.suffix.lower() not in SHIPPING_SUFFIXES:
                self.add(scope, "PHC-INT-006", str(relative), "shipping format is not active/accepted", output_id or None)
            self.validate_file_magic(scope, str(relative), media, output_id)
            declared_dimensions = dimensions_from_declaration(output.get("dimensionsOrViewBox"))
            if media in {"image/png", "image/heif"}:
                actual_dimensions = image_dimensions(path)
                if actual_dimensions is None:
                    self.add(scope, "PHC-INT-007", str(relative), "raster dimensions cannot be read", output_id or None)
                elif declared_dimensions != actual_dimensions:
                    self.add(scope, "PHC-INT-008", str(relative), f"declared dimensions {declared_dimensions} differ from {actual_dimensions}", output_id or None)
                if actual_dimensions and (actual_dimensions[0] > 4096 or actual_dimensions[1] > 4096):
                    self.add(scope, "PHC-BUD-004", str(relative), "raster exceeds 4096 x 4096 resource limit", output_id or None)
                if media == "image/png":
                    try:
                        with Image.open(path) as image:
                            has_alpha = "A" in image.getbands()
                            alpha_extrema = image.getchannel("A").getextrema() if has_alpha else (255, 255)
                        if output.get("alphaPolicy") in {"straight", "premultiplied"} and not has_alpha:
                            self.add(scope, "PHC-INT-009", str(relative), "transparent alpha policy is declared but PNG has no alpha channel", output_id or None)
                        if output.get("alphaPolicy") == "opaque" and alpha_extrema != (255, 255):
                            self.add(scope, "PHC-INT-010", str(relative), "opaque alpha policy differs from PNG alpha bytes", output_id or None)
                    except Exception:
                        pass
            elif media == "application/pdf":
                payload = path.read_bytes()
                media_box = re.search(rb"/MediaBox\s*\[\s*[-+]?\d*\.?\d+\s+[-+]?\d*\.?\d+\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s*\]", payload)
                if media_box and declared_dimensions != (round(float(media_box.group(1))), round(float(media_box.group(2)))):
                    self.add(scope, "PHC-INT-011", str(relative), "PDF MediaBox differs from declared dimensions", output_id or None)
            module_bytes[owner] += actual_size
            if media.startswith("image/") or media == "application/pdf":
                static_bytes[owner] += actual_size
            elif media.startswith("font/"):
                font_bytes[owner] += actual_size
            elif media.startswith("video/"):
                animation_bytes[owner] += actual_size
            elif media.startswith("audio/"):
                sound_bytes[owner] += actual_size

        for codex_id in sorted(EXPECTED_CODEX_IDS):
            checks = (
                (module_bytes[codex_id], required_limits["completeThemeModuleBytes"], "complete module"),
                (static_bytes[codex_id], required_limits["staticImageCatalogBytes"], "static image catalog"),
                (font_bytes[codex_id], required_limits["fontCatalogBytes"], "font catalog"),
                (animation_bytes[codex_id], required_limits["animationCatalogBytes"], "animation catalog"),
                (sound_bytes[codex_id], required_limits["soundCatalogBytes"], "sound catalog"),
            )
            for actual, maximum, label in checks:
                if actual > maximum:
                    self.add(scope, "PHC-BUD-005", "Shipping", f"{codex_id} {label} uses {actual} bytes against {maximum}")

        declared = [item for item in as_list(self.package_manifest.get("files")) if isinstance(item, dict)]
        declared_paths = [item.get("path") for item in declared]
        actual_paths = sorted(
            item.relative_to(self.root).as_posix()
            for item in self.root.rglob("*")
            if item.is_file() and not item.is_symlink() and item.name != PACKAGE_MANIFEST
        ) if self.root.is_dir() else []
        if declared_paths != sorted(set(declared_paths)):
            self.add(scope, "PHC-INT-014", PACKAGE_MANIFEST, "package manifest paths must be sorted and unique")
        if declared_paths != actual_paths:
            self.add(scope, "PHC-INT-015", PACKAGE_MANIFEST, "package manifest coverage differs from the package tree")
        if self.package_manifest.get("fileCountExcludingManifest") != len(declared):
            self.add(scope, "PHC-INT-016", PACKAGE_MANIFEST, "fileCountExcludingManifest differs from manifest entries")
        if self.package_manifest.get("packageVersion") != self.manifest.get("packageVersion"):
            self.add(scope, "PHC-INT-017", PACKAGE_MANIFEST, "package and asset manifest versions differ")
        if self.package_manifest.get("rootDirectory") != self.root.name:
            self.add(scope, "PHC-INT-018", PACKAGE_MANIFEST, "rootDirectory differs from package directory name")
        for entry in declared:
            relative = entry.get("path")
            if normalized_relative_path(relative) is None:
                self.add(scope, "PHC-PATH-001", str(relative), "package manifest path is unsafe or not normalized")
                continue
            path = self.root / str(relative)
            if not path.is_file() or path.is_symlink():
                self.add(scope, "PHC-INT-019", str(relative), "package manifest entry is missing or a symbolic link")
            elif entry.get("bytes") != path.stat().st_size or entry.get("sha256") != sha256_file(path):
                self.add(scope, "PHC-INT-020", str(relative), "package manifest hash/length differs from bytes")
            if not is_nonempty(entry.get("role")):
                self.add(scope, "PHC-INT-021", str(relative), "package manifest entry role is missing")

        self.validate_archive(scope)
        self.record(scope, f"Observed {len(shipping_actual)} shipping files and {len(declared)} package-manifest entries")

    def validate_archive(self, scope: str) -> None:
        archive = Path(str(self.root) + ".zip")
        if not archive.is_file():
            self.add(scope, "PHC-ZIP-001", str(archive), "sibling Phase C archive is missing")
            return
        try:
            with zipfile.ZipFile(archive) as bundle:
                corrupt = bundle.testzip()
                if corrupt:
                    self.add(scope, "PHC-ZIP-002", str(archive), f"ZIP integrity failed at {corrupt}")
                files: Dict[str, zipfile.ZipInfo] = {}
                for info in bundle.infolist():
                    if info.is_dir():
                        continue
                    relative = info.filename
                    pure = PurePosixPath(relative)
                    if pure.is_absolute() or ".." in pure.parts or "\\" in relative or relative != unicodedata.normalize("NFC", relative):
                        self.add(scope, "PHC-ZIP-003", relative, "ZIP member path is unsafe or not normalized")
                        continue
                    if not pure.parts or pure.parts[0] != self.root.name or len(pure.parts) < 2:
                        self.add(scope, "PHC-ZIP-004", relative, "ZIP must contain exactly one expected extraction root")
                        continue
                    mode = (info.external_attr >> 16) & 0o170000
                    if mode == 0o120000:
                        self.add(scope, "PHC-ZIP-005", relative, "ZIP symbolic-link members are forbidden")
                    package_relative = PurePosixPath(*pure.parts[1:]).as_posix()
                    if package_relative in files:
                        self.add(scope, "PHC-ZIP-006", relative, "ZIP contains a duplicate member path")
                    files[package_relative] = info
                actual_files = {
                    item.relative_to(self.root).as_posix(): item
                    for item in self.root.rglob("*")
                    if item.is_file() and not item.is_symlink()
                }
                if set(files) != set(actual_files):
                    self.add(scope, "PHC-ZIP-007", str(archive), "ZIP member coverage differs from package tree")
                for relative, info in files.items():
                    path = actual_files.get(relative)
                    if path is None:
                        continue
                    with bundle.open(info) as handle:
                        value = hashlib.sha256()
                        length = 0
                        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                            value.update(chunk)
                            length += len(chunk)
                    if length != path.stat().st_size or value.hexdigest() != sha256_file(path):
                        self.add(scope, "PHC-ZIP-008", info.filename, "ZIP member differs from package bytes")
        except (OSError, zipfile.BadZipFile, RuntimeError) as error:
            self.add(scope, "PHC-ZIP-009", str(archive), f"ZIP cannot be validated: {type(error).__name__}: {error}")

    def validate_publication(self) -> None:
        scope = "publication"
        terms = [
            "Chat" + "GPT",
            "Open" + "AI",
            "Anth" + "ropic",
            "Clau" + "de",
            "Gem" + "ini",
            "generated by " + "AI",
            "created by " + "AI",
            "language " + "model",
            "assigned to " + "Codex",
            "Codex " + "writes",
        ]
        placeholders = re.compile(r"\b(?:TODO|TBD|FIXME|LOREM IPSUM|PLACEHOLDER)\b", re.IGNORECASE)
        remote = re.compile(r"(?:https?:)?//[^\s\"'<>]+", re.IGNORECASE)
        publication_files = [item for item in self.root.rglob("*") if item.is_file() and not item.is_symlink()]
        owned_repo_files = [
            self.repo / "scripts/build-elven-production-assets.py",
            self.repo / "scripts/inventory-elven-package.py",
            self.repo / "scripts/validate-elven-production-package.py",
            self.repo / "scripts/validate-elven-phase-c-package.py",
            self.repo / "scripts/test-elven-phase-c-validator.py",
            self.repo / "scripts/validate-elven-font-registration.py",
        ]
        for path in publication_files + [item for item in owned_repo_files if item.is_file()]:
            try:
                relative = path.relative_to(self.root).as_posix()
                in_package = True
            except ValueError:
                relative = path.relative_to(self.repo).as_posix()
                in_package = False
            for term in terms:
                if term.casefold() in relative.casefold():
                    self.add(scope, "PHC-PUB-001", relative, "prohibited attribution appears in a filename")
            if path.suffix.lower() in TEXT_SUFFIXES:
                text = path.read_text(encoding="utf-8", errors="replace")
                for term in terms:
                    if term.casefold() in text.casefold():
                        self.add(scope, "PHC-PUB-002", relative, "prohibited attribution appears in publication text")
                generated_publication = relative.startswith(("Shipping/", "Validation/", "Provenance/")) or relative in {ASSET_MANIFEST, PACKAGE_MANIFEST}
                if in_package and generated_publication and placeholders.search(text):
                    self.add(scope, "PHC-PUB-003", relative, "publication text contains a placeholder marker")
                if in_package and relative.startswith("Shipping/") and remote.search(text):
                    self.add(scope, "PHC-PUB-004", relative, "shipping resource contains a remote reference")
            if in_package and relative.startswith("Shipping/"):
                if path.suffix.lower() in {".svg", ".xml", ".html", ".htm", ".js", ".sh", ".py", ".zip", ".tar", ".gz"}:
                    self.add(scope, "PHC-PUB-005", relative, "prohibited shipping source/archive/executable format is present")
                try:
                    header = path.read_bytes()[:8]
                except OSError:
                    header = b""
                if header.startswith((b"#!", b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf")):
                    self.add(scope, "PHC-PUB-006", relative, "shipping resource contains executable code")
        rights = self.manifest.get("rights")
        if not isinstance(rights, dict) or rights.get("owner") != "Raven Forge Software" or not as_list(rights.get("prohibitions")):
            self.add(scope, "PHC-PUB-007", ASSET_MANIFEST, "rights ownership and original-design prohibitions are incomplete")
        source_policy = self.manifest.get("sourceMasters")
        if not isinstance(source_policy, dict) or source_policy.get("shippingResources") is not False:
            self.add(scope, "PHC-PUB-008", ASSET_MANIFEST, "source-master non-shipping policy is missing")
        prohibited_formats = set(str(item) for item in as_list(self.manifest.get("sharedRequirements", {}).get("prohibitedFormats")))
        expected_prohibited = {"archive", "executable-code", "shader-source", "html", "remote-reference", "undeclared-file"}
        if prohibited_formats != expected_prohibited:
            self.add(scope, "PHC-PUB-009", ASSET_MANIFEST, "active prohibitedFormats declaration differs from the Theme specification")
        self.record(scope, f"Scanned {len(publication_files)} package files and {len([item for item in owned_repo_files if item.is_file()])} repository publication files")

    def report(self, requested: Sequence[str]) -> Dict[str, Any]:
        ordered_issues = sorted(
            self.issues,
            key=lambda item: (item.scope, item.code, item.path, item.resource_id or "", item.message),
        )
        active_issues = [item for item in ordered_issues if item.scope in self.selected]
        scope_records: List[Dict[str, Any]] = []
        for scope in self.selected:
            scoped = [item for item in active_issues if item.scope == scope]
            scope_records.append({
                "scope": scope,
                "status": "PASS" if not scoped else "FAIL",
                "issueCount": len(scoped),
                "issueCodes": sorted({item.code for item in scoped}),
                "evidence": sorted(self.evidence.get(scope, [])),
            })
        status = "PASS" if not active_issues else "FAIL"
        result: Dict[str, Any] = {
            "schemaVersion": "1.0",
            "validator": "elven-phase-c-package",
            "packageRoot": str(self.root),
            "repositoryRoot": str(self.repo),
            "packageVersion": self.manifest.get("packageVersion"),
            "requestedScopes": list(requested),
            "effectiveScopes": list(self.selected),
            "status": status,
            "scopes": scope_records,
            "issues": [item.json() for item in active_issues],
            "summary": {
                "status": status,
                "scopeCount": len(scope_records),
                "passedScopeCount": sum(item["status"] == "PASS" for item in scope_records),
                "failedScopes": [item["scope"] for item in scope_records if item["status"] == "FAIL"],
                "issueCount": len(active_issues),
                "issueCodes": sorted({item.code for item in active_issues}),
                "logicalResourceCount": len(self.resources),
                "shippingOutputCount": len(self.outputs),
                "provenanceRecordCount": len(self.provenance_records),
            },
        }
        if requested == ["aggregate"]:
            result["aggregate"] = {
                "status": status,
                "requiredScopeCount": len(SCOPES),
                "passedScopeCount": result["summary"]["passedScopeCount"],
            }
        return result


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate one Elven Phase C package without modifying it.",
    )
    parser.add_argument("--package-root", type=Path, help="completed Phase C package directory")
    parser.add_argument("--repo-root", type=Path, help="Rune Scribe repository worktree")
    parser.add_argument("--output", type=Path, help="structured JSON report path")
    parser.add_argument(
        "--scope",
        action="append",
        choices=SCOPES + ("aggregate",),
        help="repeatable validation scope; defaults to aggregate",
    )
    parser.add_argument("--list-scopes", action="store_true", help="print available scopes and exit")
    arguments = parser.parse_args(argv)
    if arguments.list_scopes:
        print("\n".join(SCOPES + ("aggregate",)))
        raise SystemExit(0)
    missing = [name for name in ("package_root", "repo_root", "output") if getattr(arguments, name) is None]
    if missing:
        parser.error("required arguments missing: " + ", ".join("--" + item.replace("_", "-") for item in missing))
    return arguments


def write_report(path: Path, report: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = parse_arguments(argv)
    requested = arguments.scope or ["aggregate"]
    if "aggregate" in requested:
        if len(requested) != 1:
            requested = ["aggregate"]
        selected = list(SCOPES)
    else:
        selected = list(dict.fromkeys(requested))
    root = arguments.package_root.resolve()
    repo = arguments.repo_root.resolve()
    try:
        validator = Validator(root, repo, selected)
        validator.run()
        report = validator.report(requested)
    except Exception as error:
        report = {
            "schemaVersion": "1.0",
            "validator": "elven-phase-c-package",
            "packageRoot": str(root),
            "repositoryRoot": str(repo),
            "requestedScopes": list(requested),
            "effectiveScopes": selected,
            "status": "FAIL",
            "scopes": [],
            "issues": [{
                "scope": "aggregate" if requested == ["aggregate"] else selected[0],
                "code": "PHC-INTERNAL-002",
                "path": "",
                "message": f"validator failed safely: {type(error).__name__}: {error}",
            }],
            "summary": {
                "status": "FAIL",
                "scopeCount": len(selected),
                "passedScopeCount": 0,
                "failedScopes": selected,
                "issueCount": 1,
                "issueCodes": ["PHC-INTERNAL-002"],
                "logicalResourceCount": 0,
                "shippingOutputCount": 0,
                "provenanceRecordCount": 0,
            },
        }
    try:
        write_report(arguments.output.resolve(), report)
    except Exception as error:
        emergency = dict(report)
        emergency["reportWriteError"] = f"{type(error).__name__}: {error}"
        print(json.dumps(emergency, indent=2, ensure_ascii=False))
        return 1
    print(json.dumps(report["summary"], indent=2, ensure_ascii=False))
    return 0 if report.get("status") == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
