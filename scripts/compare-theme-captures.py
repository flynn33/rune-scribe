#!/usr/bin/env python3
"""Compare a deterministic Theme capture with a manifest-pinned authority image."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple

try:
    import numpy as np
    from PIL import Image, UnidentifiedImageError
    from skimage.color import deltaE_ciede2000, rgb2gray, rgb2lab
    from skimage.filters import sobel
    from skimage.metrics import structural_similarity
except ImportError as import_error:  # pragma: no cover - exercised only on an incomplete host.
    np = None
    Image = None
    UnidentifiedImageError = OSError
    deltaE_ciede2000 = None
    rgb2gray = None
    rgb2lab = None
    sobel = None
    structural_similarity = None
    DEPENDENCY_ERROR = import_error
else:
    DEPENDENCY_ERROR = None


SCHEMA_VERSION = "1.0"
RESPONSIVE_POLICY = "responsive-regions-v1"
PLATFORM_MASK_ROLE = "platform-controlled-mask"
VIEWPORT_ELEMENT_ID = "theme-fidelity.viewport"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
DEFAULT_MANIFEST = Path(
    "docs/verification/theme-fidelity-v4/authority/asset-manifest.json"
)
THRESHOLDS = {
    "luminanceSSIM": 0.92,
    "edgeSSIM": 0.94,
    "focalSSIM": 0.95,
    "medianDeltaE": 4.0,
    "p95DeltaE": 12.0,
    "maxFractionDeltaEAbove20": 0.02,
}
RESPONSIVE_COMPARISON_KEYS = {
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
LAYOUT_ASSERTION_KEYS = {
    "requiredElementIDs",
    "withinViewportElementIDs",
    "requireNoClippedElements",
}
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


class ComparisonError(ValueError):
    pass


class DuplicateJSONKeyError(ValueError):
    pass


def reject_duplicate_keys(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateJSONKeyError("duplicate JSON key: {}".format(key))
        value[key] = item
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
    except ValueError:
        return False
    return True


def resolve_repo_path(root: Path, raw: Any, label: str) -> Path:
    if not isinstance(raw, str) or not raw.strip():
        raise ComparisonError("{} must be a non-empty repository-relative path".format(label))
    relative = Path(raw)
    if relative.is_absolute():
        raise ComparisonError("{} must be repository-relative".format(label))
    resolved = (root / relative).resolve()
    if not is_within(resolved, root):
        raise ComparisonError("{} escapes the repository root".format(label))
    return resolved


def resolve_authority_path(authority_root: Path, raw: Any, label: str) -> Path:
    if not isinstance(raw, str) or not raw.strip():
        raise ComparisonError("{} must be a non-empty authorityRoot-relative path".format(label))
    relative = Path(raw)
    if relative.is_absolute():
        raise ComparisonError("{} must be authorityRoot-relative".format(label))
    resolved = (authority_root / relative).resolve()
    if not is_within(resolved, authority_root):
        raise ComparisonError("{} escapes authorityRoot".format(label))
    return resolved


def load_manifest(path: Path) -> Dict[str, Any]:
    if not path.is_file():
        raise ComparisonError("authority manifest is missing: {}".format(path))
    try:
        decoded = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
        raise ComparisonError("authority manifest is invalid: {}".format(error)) from error
    if not isinstance(decoded, dict) or decoded.get("schemaVersion") != SCHEMA_VERSION:
        raise ComparisonError("authority manifest schemaVersion must be {}".format(SCHEMA_VERSION))
    return decoded


def load_json_object(path: Path, label: str) -> Dict[str, Any]:
    if not path.is_file():
        raise ComparisonError("{} is missing: {}".format(label, path))
    try:
        decoded = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
        raise ComparisonError("{} is invalid: {}".format(label, error)) from error
    if not isinstance(decoded, dict):
        raise ComparisonError("{} must be a JSON object".format(label))
    return decoded


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
        raise ComparisonError("contentSeed is not canonical JSON data") from error
    return hashlib.sha256(encoded).hexdigest()


def is_nullable_string(value: Any) -> bool:
    return value is None or (isinstance(value, str) and bool(value))


def validate_content_seed(record: Dict[str, Any]) -> str:
    content_seed = record.get("contentSeed")
    if not isinstance(content_seed, dict) or set(content_seed) != CONTENT_SEED_KEYS:
        raise ComparisonError("capture record contentSeed keys are invalid")
    for key, expected_keys in CONTENT_SEED_NESTED_KEYS.items():
        value = content_seed.get(key)
        if not isinstance(value, dict) or set(value) != expected_keys:
            raise ComparisonError(
                "capture record contentSeed.{} keys are invalid".format(key)
            )

    fixture_version = content_seed.get("fixtureVersion")
    if (
        isinstance(fixture_version, bool)
        or not isinstance(fixture_version, int)
        or fixture_version != 1
    ):
        raise ComparisonError("capture record contentSeed.fixtureVersion must be 1")
    for key in ("fixtureID", "surface"):
        if not isinstance(content_seed.get(key), str) or not content_seed[key]:
            raise ComparisonError(
                "capture record contentSeed.{} must be a non-empty string".format(key)
            )
    if content_seed.get("plaintext") is not None and not isinstance(
        content_seed.get("plaintext"), str
    ):
        raise ComparisonError("capture record contentSeed.plaintext must be string or null")
    glyph_tokens = content_seed.get("glyphTokens")
    if not (
        isinstance(glyph_tokens, list)
        and all(isinstance(value, str) and value for value in glyph_tokens)
    ):
        raise ComparisonError(
            "capture record contentSeed.glyphTokens must be an ordered string array"
        )

    sender = content_seed["sender"]
    if not is_nullable_string(sender.get("name")):
        raise ComparisonError("capture record contentSeed.sender.name is invalid")
    cipher = content_seed["cipher"]
    if not is_nullable_string(cipher.get("id")) or not is_nullable_string(
        cipher.get("name")
    ):
        raise ComparisonError("capture record contentSeed.cipher values are invalid")
    if (cipher.get("id") is None) != (cipher.get("name") is None):
        raise ComparisonError("capture record contentSeed.cipher identity is incomplete")

    selected = content_seed["selectedResources"]
    for key in ("codexID", "relicID"):
        if not isinstance(selected.get(key), str) or not selected[key]:
            raise ComparisonError(
                "capture record contentSeed.selectedResources.{} is invalid".format(key)
            )
    for key in ("sealID", "frameID"):
        if not is_nullable_string(selected.get(key)):
            raise ComparisonError(
                "capture record contentSeed.selectedResources.{} is invalid".format(key)
            )

    progression = content_seed["progression"]
    for key in ("ownershipState", "achievementID"):
        if not is_nullable_string(progression.get(key)):
            raise ComparisonError(
                "capture record contentSeed.progression.{} is invalid".format(key)
            )
    completed = progression.get("completedRuleCount")
    required = progression.get("requiredRuleCount")
    for key, value in (
        ("completedRuleCount", completed),
        ("requiredRuleCount", required),
    ):
        if value is not None and (
            isinstance(value, bool) or not isinstance(value, int) or value < 0
        ):
            raise ComparisonError(
                "capture record contentSeed.progression.{} is invalid".format(key)
            )
    if (completed is None) != (required is None):
        raise ComparisonError("capture record contentSeed progression counts are incomplete")
    if completed is not None and completed > required:
        raise ComparisonError("capture record contentSeed progression counts are inconsistent")

    accessibility = content_seed["accessibility"]
    if not isinstance(accessibility.get("increasedContrast"), bool) or not isinstance(
        accessibility.get("reduceMotion"), bool
    ):
        raise ComparisonError("capture record contentSeed accessibility flags are invalid")
    if not isinstance(accessibility.get("dynamicTypeSize"), str) or not accessibility[
        "dynamicTypeSize"
    ]:
        raise ComparisonError(
            "capture record contentSeed.accessibility.dynamicTypeSize is invalid"
        )

    fixed_values = {
        "timestamp": CONTENT_SEED_TIMESTAMP,
        "locale": "en_US_POSIX",
        "calendar": "gregorian",
        "timeZone": "GMT",
    }
    for key, expected in fixed_values.items():
        if content_seed.get(key) != expected:
            raise ComparisonError(
                "capture record contentSeed.{} differs from the fixed fixture".format(key)
            )

    top_level_bindings = {
        "stateSeed": content_seed["fixtureID"],
        "surface": content_seed["surface"],
        "codexID": selected["codexID"],
        "relicID": selected["relicID"],
        "sealID": selected["sealID"],
        "frameID": selected["frameID"],
    }
    for key, expected in top_level_bindings.items():
        if record.get(key) != expected:
            raise ComparisonError(
                "capture record {} differs from contentSeed".format(key)
            )

    declared_digest = record.get("stateSeedSHA256")
    if not isinstance(declared_digest, str) or SHA256_PATTERN.fullmatch(
        declared_digest
    ) is None:
        raise ComparisonError("capture record stateSeedSHA256 is invalid")
    actual_digest = canonical_json_sha256(content_seed)
    if declared_digest != actual_digest:
        raise ComparisonError(
            "capture record stateSeedSHA256 differs from canonical contentSeed"
        )
    return actual_digest


def source_crop_sha256(
    pixels: Any, reference_sha256: str, region: Sequence[int]
) -> str:
    digest = hashlib.sha256()
    digest.update(b"responsive-regions-v1\0rgb\0")
    digest.update(reference_sha256.encode("ascii"))
    digest.update(b"\0")
    for value in region:
        digest.update(value.to_bytes(8, byteorder="big", signed=False))
    digest.update(np.ascontiguousarray(pixels, dtype=np.uint8).tobytes())
    return digest.hexdigest()


def validate_dimensions(value: Any, label: str) -> Tuple[int, int]:
    if not (
        isinstance(value, list)
        and len(value) == 2
        and all(isinstance(item, int) and not isinstance(item, bool) and item > 0 for item in value)
    ):
        raise ComparisonError("{} must contain two positive integers".format(label))
    return value[0], value[1]


def validate_region(value: Any, dimensions: Tuple[int, int]) -> Tuple[int, int, int, int]:
    if not (
        isinstance(value, list)
        and len(value) == 4
        and all(isinstance(item, int) and not isinstance(item, bool) for item in value)
    ):
        raise ComparisonError("focalRegion must be x,y,width,height integers")
    x, y, width, height = value
    image_width, image_height = dimensions
    if (
        x < 0
        or y < 0
        or width < 7
        or height < 7
        or x + width > image_width
        or y + height > image_height
    ):
        raise ComparisonError("focalRegion is outside the authority image or is smaller than 7x7")
    return x, y, width, height


def load_rgb(path: Path) -> Tuple[Any, Tuple[int, int]]:
    if Image is None:
        raise ComparisonError("image dependencies are unavailable")
    if not path.is_file():
        raise ComparisonError("image is missing: {}".format(path))
    try:
        with Image.open(path) as image:
            image.load()
            rgb = image.convert("RGB")
            return np.asarray(rgb, dtype=np.uint8), rgb.size
    except (OSError, UnidentifiedImageError) as error:
        raise ComparisonError("image cannot be decoded: {}".format(path)) from error


def asset_index(manifest: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    assets = manifest.get("assets")
    if not isinstance(assets, list) or not assets:
        raise ComparisonError("authority manifest assets must be a non-empty array")
    indexed: Dict[str, Dict[str, Any]] = {}
    for record in assets:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise ComparisonError("authority manifest contains an invalid asset record")
        path = record["path"]
        if path in indexed:
            raise ComparisonError("authority manifest contains a duplicate asset path")
        indexed[path] = record
    return indexed


def selected_comparison(manifest: Dict[str, Any], identifier: str) -> Dict[str, Any]:
    comparisons = manifest.get("comparisons")
    if not isinstance(comparisons, list):
        raise ComparisonError("authority manifest comparisons must be an array")
    matches = [
        record
        for record in comparisons
        if isinstance(record, dict) and record.get("id") == identifier
    ]
    if len(matches) != 1:
        raise ComparisonError("comparison id must resolve exactly once: {}".format(identifier))
    return matches[0]


def validate_pinned_asset(
    root: Path,
    authority_root: Path,
    record: Dict[str, Any],
    label: str,
) -> Tuple[Path, Any, Tuple[int, int]]:
    path = resolve_authority_path(authority_root, record.get("path"), "{}.path".format(label))
    expected_hash = record.get("sha256")
    if not isinstance(expected_hash, str) or len(expected_hash) != 64:
        raise ComparisonError("{}.sha256 is invalid".format(label))
    expected_dimensions = validate_dimensions(
        record.get("dimensions"), "{}.dimensions".format(label)
    )
    actual_hash = sha256_file(path)
    if actual_hash != expected_hash:
        raise ComparisonError("{} SHA-256 no longer matches the manifest".format(label))
    pixels, actual_dimensions = load_rgb(path)
    if actual_dimensions != expected_dimensions:
        raise ComparisonError("{} dimensions no longer match the manifest".format(label))
    return path, pixels, actual_dimensions


def load_mask(
    root: Path,
    authority_root: Path,
    record: Dict[str, Any],
    dimensions: Tuple[int, int],
    platform_only: bool = False,
) -> Tuple[Path, Any]:
    role = record.get("role")
    if platform_only and str(role).lower() != PLATFORM_MASK_ROLE:
        raise ComparisonError("responsive comparison mask is not platform-controlled")
    if not platform_only and (not isinstance(role, str) or "mask" not in role.lower()):
        raise ComparisonError("comparison mask must have a mask role")
    path = resolve_authority_path(authority_root, record.get("path"), "mask.path")
    expected_hash = record.get("sha256")
    if not isinstance(expected_hash, str) or sha256_file(path) != expected_hash:
        raise ComparisonError("comparison mask SHA-256 no longer matches the manifest")
    expected_dimensions = validate_dimensions(record.get("dimensions"), "mask.dimensions")
    if expected_dimensions != dimensions:
        raise ComparisonError("comparison mask dimensions do not match the reference")
    try:
        with Image.open(path) as image:
            image.load()
            if image.size != dimensions:
                raise ComparisonError("comparison mask dimensions no longer match the manifest")
            raw = np.asarray(image.convert("L"), dtype=np.uint8)
    except (OSError, UnidentifiedImageError) as error:
        raise ComparisonError("comparison mask cannot be decoded") from error
    values = set(int(item) for item in np.unique(raw))
    if not values.issubset({0, 255}):
        raise ComparisonError("comparison mask must contain only black and white pixels")
    scored = raw == 255
    if not bool(np.any(scored)):
        raise ComparisonError("comparison mask excludes every pixel")
    return path, scored


def masked_ssim(reference: Any, candidate: Any, mask: Any) -> Tuple[float, Any]:
    scored_candidate = candidate.copy()
    scored_candidate[~mask] = reference[~mask]
    _, score_map = structural_similarity(
        reference,
        scored_candidate,
        data_range=1.0,
        full=True,
    )
    return float(np.mean(score_map[mask])), score_map


def normalize_candidate(candidate: Any, dimensions: Tuple[int, int]) -> Tuple[Any, bool]:
    target_width, target_height = dimensions
    source_height, source_width = candidate.shape[:2]
    if source_width * target_height != source_height * target_width:
        raise ComparisonError("candidate aspect ratio differs from the authority image")
    if (source_width, source_height) == dimensions:
        return candidate, False
    resized = Image.fromarray(candidate).resize(dimensions, Image.Resampling.LANCZOS)
    return np.asarray(resized, dtype=np.uint8), True


def comparison_metrics(
    reference: Any,
    candidate: Any,
    mask: Any,
    focal_region: Tuple[int, int, int, int],
) -> Tuple[Dict[str, float], Any, Any]:
    reference_rgb = reference.astype(np.float32) / 255.0
    candidate_rgb = candidate.astype(np.float32) / 255.0
    reference_luminance = rgb2gray(reference_rgb)
    candidate_luminance = rgb2gray(candidate_rgb)

    luminance_ssim, luminance_map = masked_ssim(
        reference_luminance,
        candidate_luminance,
        mask,
    )
    edge_ssim, _ = masked_ssim(
        sobel(reference_luminance),
        sobel(candidate_luminance),
        mask,
    )

    x, y, width, height = focal_region
    focal_mask = mask[y : y + height, x : x + width]
    if not bool(np.any(focal_mask)):
        raise ComparisonError("approved mask excludes every focal-region pixel")
    focal_ssim, _ = masked_ssim(
        reference_luminance[y : y + height, x : x + width],
        candidate_luminance[y : y + height, x : x + width],
        focal_mask,
    )

    delta_e = deltaE_ciede2000(rgb2lab(reference_rgb), rgb2lab(candidate_rgb))
    scored_delta = delta_e[mask]
    metrics = {
        "luminanceSSIM": luminance_ssim,
        "edgeSSIM": edge_ssim,
        "focalSSIM": focal_ssim,
        "medianDeltaE": float(np.median(scored_delta)),
        "p95DeltaE": float(np.percentile(scored_delta, 95)),
        "fractionDeltaEAbove20": float(np.mean(scored_delta > 20.0)),
    }
    return metrics, luminance_map, delta_e


def metric_checks(
    metrics: Dict[str, float], thresholds: Dict[str, float] = THRESHOLDS
) -> Dict[str, bool]:
    return {
        "luminanceSSIM": metrics["luminanceSSIM"] >= thresholds["luminanceSSIM"],
        "edgeSSIM": metrics["edgeSSIM"] >= thresholds["edgeSSIM"],
        "focalSSIM": metrics["focalSSIM"] >= thresholds["focalSSIM"],
        "medianDeltaE": metrics["medianDeltaE"] <= thresholds["medianDeltaE"],
        "p95DeltaE": metrics["p95DeltaE"] <= thresholds["p95DeltaE"],
        "fractionDeltaEAbove20": metrics["fractionDeltaEAbove20"]
        <= thresholds["maxFractionDeltaEAbove20"],
    }


def heatmap_pixels(luminance_map: Any, delta_e: Any, mask: Any) -> Any:
    structural = np.clip((1.0 - luminance_map) / 2.0, 0.0, 1.0)
    perceptual = np.clip(delta_e / 20.0, 0.0, 1.0)
    level = np.maximum(structural, perceptual)
    level[~mask] = 0.0
    red = np.rint(level * 255.0).astype(np.uint8)
    green = np.rint(level * (1.0 - level) * 2.0 * 255.0).astype(np.uint8)
    blue = np.zeros_like(red)
    return np.stack((red, green, blue), axis=-1)


def heatmap_atlas(heatmaps: Sequence[Tuple[str, Any]]) -> Tuple[Any, List[Dict[str, Any]]]:
    if not heatmaps:
        raise ComparisonError("responsive comparison produced no heatmaps")
    atlas_width = max(item.shape[1] for _, item in heatmaps)
    atlas_height = sum(item.shape[0] for _, item in heatmaps)
    atlas = np.zeros((atlas_height, atlas_width, 3), dtype=np.uint8)
    placements: List[Dict[str, Any]] = []
    y = 0
    for identifier, pixels in heatmaps:
        height, width = pixels.shape[:2]
        atlas[y : y + height, 0:width] = pixels
        placements.append(
            {
                "regionID": identifier,
                "frame": [0, y, width, height],
            }
        )
        y += height
    return atlas, placements


def display_path(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return str(path.resolve())


def atomic_write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def atomic_write_png(path: Path, pixels: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    Image.fromarray(pixels).save(temporary, format="PNG")
    temporary.replace(path)


def validate_identifier_list(value: Any, label: str) -> List[str]:
    if not (
        isinstance(value, list)
        and value
        and all(
            isinstance(item, str) and IDENTIFIER_PATTERN.fullmatch(item) is not None
            for item in value
        )
        and value == sorted(value)
        and len(value) == len(set(value))
    ):
        raise ComparisonError(
            "{} must be a sorted unique non-empty stable-identifier array".format(label)
        )
    return value


def validate_responsive_plan(plan: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    if set(plan) != RESPONSIVE_COMPARISON_KEYS:
        raise ComparisonError("responsive comparison fields are invalid")
    seed_digest = plan.get("stateSeedSHA256")
    if not isinstance(seed_digest, str) or SHA256_PATTERN.fullmatch(seed_digest) is None:
        raise ComparisonError("responsive stateSeedSHA256 is invalid")
    capture = plan.get("capture")
    if not (
        isinstance(capture, str)
        and capture
        and Path(capture).name == capture
        and capture.endswith(".png")
    ):
        raise ComparisonError("responsive comparison capture is invalid")
    regions = plan.get("regions")
    if not isinstance(regions, list) or not regions:
        raise ComparisonError("responsive comparison regions must be a non-empty array")
    region_ids: List[str] = []
    candidate_ids: set[str] = set()
    for region in regions:
        if not isinstance(region, dict) or set(region) != RESPONSIVE_REGION_KEYS:
            raise ComparisonError("responsive region fields are invalid")
        identifier = region.get("id")
        candidate_id = region.get("candidateElementID")
        if not isinstance(identifier, str) or IDENTIFIER_PATTERN.fullmatch(identifier) is None:
            raise ComparisonError("responsive region id is invalid")
        if not isinstance(candidate_id, str) or IDENTIFIER_PATTERN.fullmatch(candidate_id) is None:
            raise ComparisonError("responsive candidateElementID is invalid")
        if region.get("thresholds") != THRESHOLDS:
            raise ComparisonError("responsive region thresholds differ from fixed policy")
        region_ids.append(identifier)
        candidate_ids.add(candidate_id)
    if region_ids != sorted(region_ids) or len(region_ids) != len(set(region_ids)):
        raise ComparisonError("responsive regions must be sorted by unique id")

    layout = plan.get("layoutAssertions")
    if not isinstance(layout, dict) or set(layout) != LAYOUT_ASSERTION_KEYS:
        raise ComparisonError("responsive layoutAssertions fields are invalid")
    required_ids = validate_identifier_list(
        layout.get("requiredElementIDs"), "layoutAssertions.requiredElementIDs"
    )
    within_ids = validate_identifier_list(
        layout.get("withinViewportElementIDs"),
        "layoutAssertions.withinViewportElementIDs",
    )
    if layout.get("requireNoClippedElements") is not True:
        raise ComparisonError("responsive requireNoClippedElements must be true")
    if not set(within_ids).issubset(set(required_ids)):
        raise ComparisonError("withinViewportElementIDs are not all required")
    if not candidate_ids.issubset(set(within_ids)):
        raise ComparisonError("every responsive candidate element must be within the viewport")
    return regions, layout


def valid_number(value: Any) -> bool:
    return (
        not isinstance(value, bool)
        and isinstance(value, (int, float))
        and math.isfinite(value)
    )


def frame_inside(frame: Dict[str, Any], dimensions: Tuple[int, int]) -> bool:
    width, height = dimensions
    return (
        frame["x"] >= 0
        and frame["y"] >= 0
        and frame["x"] + frame["width"] <= width
        and frame["y"] + frame["height"] <= height
    )


def frame_pixel_crop(
    frame: Dict[str, Any], dimensions: Tuple[int, int], label: str
) -> Tuple[int, int, int, int]:
    if not frame_inside(frame, dimensions):
        raise ComparisonError("{} frame is outside the candidate capture".format(label))
    left = math.floor(frame["x"])
    top = math.floor(frame["y"])
    right = math.ceil(frame["x"] + frame["width"])
    bottom = math.ceil(frame["y"] + frame["height"])
    if right - left < 7 or bottom - top < 7:
        raise ComparisonError("{} frame is smaller than 7x7 pixels".format(label))
    return left, top, right - left, bottom - top


def load_bound_capture_record(
    path: Path,
    candidate_path: Path,
    candidate_dimensions: Tuple[int, int],
) -> Dict[str, Any]:
    record = load_json_object(path, "capture record")
    if record.get("schemaVersion") != SCHEMA_VERSION:
        raise ComparisonError("capture record schemaVersion must be {}".format(SCHEMA_VERSION))
    if record.get("pngSHA256") != sha256_file(candidate_path):
        raise ComparisonError("capture record pngSHA256 does not match the candidate")
    if (
        record.get("pixelWidth") != candidate_dimensions[0]
        or record.get("pixelHeight") != candidate_dimensions[1]
    ):
        raise ComparisonError("capture record pixel dimensions do not match the candidate")
    validate_content_seed(record)
    return record


def validate_capture_record(
    path: Path,
    candidate_path: Path,
    candidate_dimensions: Tuple[int, int],
    plan: Dict[str, Any],
) -> Tuple[Dict[str, Dict[str, Any]], Dict[str, Any], Dict[str, Any]]:
    record = load_bound_capture_record(path, candidate_path, candidate_dimensions)
    if record.get("stateSeedSHA256") != plan.get("stateSeedSHA256"):
        raise ComparisonError(
            "capture record stateSeedSHA256 differs from the comparison plan"
        )

    scale = record.get("scale")
    if not valid_number(scale) or scale <= 0:
        raise ComparisonError("capture record scale is invalid")
    element_frames = record.get("elementFrames")
    if not isinstance(element_frames, dict) or set(element_frames) != {
        "coordinateOrigin",
        "frames",
        "scale",
        "units",
    }:
        raise ComparisonError("capture record elementFrames fields are invalid")
    if element_frames.get("coordinateOrigin") != "top-left":
        raise ComparisonError("capture record elementFrames must use top-left coordinates")
    if element_frames.get("units") != "pixels":
        raise ComparisonError("capture record elementFrames must use pixel units")
    if element_frames.get("scale") != scale:
        raise ComparisonError("capture record elementFrames scale differs")
    raw_frames = element_frames.get("frames")
    if not isinstance(raw_frames, list) or not raw_frames:
        raise ComparisonError("capture record elementFrames.frames must be non-empty")
    frames: Dict[str, Dict[str, Any]] = {}
    ordered_ids: List[str] = []
    for frame in raw_frames:
        if not isinstance(frame, dict) or set(frame) != {
            "elementID",
            "height",
            "width",
            "x",
            "y",
        }:
            raise ComparisonError("capture record contains an invalid element frame")
        identifier = frame.get("elementID")
        if not isinstance(identifier, str) or IDENTIFIER_PATTERN.fullmatch(identifier) is None:
            raise ComparisonError("capture record contains an invalid elementID")
        for coordinate in ("x", "y", "width", "height"):
            if not valid_number(frame.get(coordinate)):
                raise ComparisonError("capture record element frame coordinate is invalid")
        if frame["width"] <= 0 or frame["height"] <= 0:
            raise ComparisonError("capture record element frame dimensions must be positive")
        ordered_ids.append(identifier)
        frames[identifier] = frame
    if ordered_ids != sorted(ordered_ids) or len(ordered_ids) != len(frames):
        raise ComparisonError("capture record element frames must be sorted and unique")
    viewport = frames.get(VIEWPORT_ELEMENT_ID)
    if viewport is None:
        raise ComparisonError("capture record omits the attested viewport frame")
    expected_viewport = {
        "x": 0.0,
        "y": 0.0,
        "width": float(candidate_dimensions[0]),
        "height": float(candidate_dimensions[1]),
    }
    if any(
        not math.isclose(float(viewport[key]), value, rel_tol=0.0, abs_tol=0.5)
        for key, value in expected_viewport.items()
    ):
        raise ComparisonError("capture record viewport frame differs from candidate bounds")

    viewport_assertions = record.get("viewportAssertions")
    if not isinstance(viewport_assertions, dict) or set(viewport_assertions) != {
        "requiredElementCount",
        "requiredElementIDs",
        "clippedElementIDs",
    }:
        raise ComparisonError("capture record viewportAssertions fields are invalid")
    required_count = viewport_assertions.get("requiredElementCount")
    attested_required_ids = validate_identifier_list(
        viewport_assertions.get("requiredElementIDs"),
        "capture record requiredElementIDs",
    )
    clipped = viewport_assertions.get("clippedElementIDs")
    if (
        isinstance(required_count, bool)
        or not isinstance(required_count, int)
        or required_count <= 0
    ):
        raise ComparisonError("capture record requiredElementCount is invalid")
    if required_count != len(attested_required_ids):
        raise ComparisonError(
            "capture record requiredElementCount differs from requiredElementIDs"
        )
    if not (
        isinstance(clipped, list)
        and all(
            isinstance(item, str) and IDENTIFIER_PATTERN.fullmatch(item) is not None
            for item in clipped
        )
        and clipped == sorted(clipped)
        and len(clipped) == len(set(clipped))
    ):
        raise ComparisonError("capture record clippedElementIDs is invalid")
    if not set(clipped).issubset(set(attested_required_ids)):
        raise ComparisonError(
            "capture record clippedElementIDs are not all required elements"
        )
    unattested_required_ids = sorted(set(attested_required_ids) - set(frames))
    if unattested_required_ids:
        raise ComparisonError(
            "capture record required elements lack attested frames: "
            + ", ".join(unattested_required_ids)
        )

    layout = plan["layoutAssertions"]
    required_ids = layout["requiredElementIDs"]
    within_ids = layout["withinViewportElementIDs"]
    missing = sorted(set(required_ids) - set(frames))
    outside = sorted(
        identifier
        for identifier in within_ids
        if identifier in frames and not frame_inside(frames[identifier], candidate_dimensions)
    )
    layout_checks = {
        "requiredElementsPresent": not missing,
        "requiredElementCountAttested": set(required_ids).issubset(
            set(attested_required_ids)
        ),
        "noClippedElements": not clipped,
        "elementsWithinViewport": not outside,
    }
    layout_evidence = {
        "requiredElementIDs": required_ids,
        "missingElementIDs": missing,
        "withinViewportElementIDs": within_ids,
        "outsideViewportElementIDs": outside,
        "requireNoClippedElements": True,
        "attestedRequiredElementCount": required_count,
        "attestedRequiredElementIDs": attested_required_ids,
        "attestedClippedElementIDs": clipped,
        "checks": layout_checks,
    }
    return frames, layout_evidence, record


def compare_responsive(
    root: Path,
    manifest_path: Path,
    manifest: Dict[str, Any],
    authority_root: Path,
    assets: Dict[str, Dict[str, Any]],
    plan: Dict[str, Any],
    candidate_path: Path,
    output_stem: Path,
    capture_record_path: Optional[Path],
) -> Dict[str, Any]:
    regions, _ = validate_responsive_plan(plan)
    if capture_record_path is None:
        raise ComparisonError(
            "responsive comparison requires an explicit --capture-record path"
        )
    capture_record_path = capture_record_path.resolve()
    if is_within(capture_record_path, authority_root):
        raise ComparisonError("capture record must not be stored inside authorityRoot")
    if not candidate_path.is_file():
        raise ComparisonError("candidate image is missing")
    if candidate_path.name != plan["capture"]:
        raise ComparisonError("responsive comparison candidate differs from mapped capture")
    if is_within(candidate_path, authority_root):
        raise ComparisonError("candidate must not be stored inside immutable authorityRoot")
    candidate, candidate_dimensions = load_rgb(candidate_path)
    frames, layout_evidence, capture_record = validate_capture_record(
        capture_record_path,
        candidate_path,
        candidate_dimensions,
        plan,
    )

    output_json = Path(str(output_stem) + ".json")
    output_heatmap = Path(str(output_stem) + ".heatmap.png")
    for output in (output_json, output_heatmap):
        if is_within(output, authority_root):
            raise ComparisonError("comparison output must not be written inside authorityRoot")

    input_paths = {manifest_path, candidate_path, capture_record_path}
    rendered_regions: List[Dict[str, Any]] = []
    heatmaps: List[Tuple[str, Any]] = []
    for region in regions:
        identifier = region["id"]
        reference_key = region["reference"]
        if reference_key not in assets:
            raise ComparisonError(
                "responsive region {} reference is not declared in assets".format(identifier)
            )
        if Path(reference_key).parts[:1] != ("goldens",):
            raise ComparisonError(
                "responsive region {} reference is not a hash-pinned golden".format(identifier)
            )
        reference_path, reference, reference_dimensions = validate_pinned_asset(
            root,
            authority_root,
            assets[reference_key],
            "responsive region {} reference".format(identifier),
        )
        input_paths.add(reference_path)
        source_crop = validate_region(region["sourceCrop"], reference_dimensions)
        source_x, source_y, source_width, source_height = source_crop
        source = reference[
            source_y : source_y + source_height,
            source_x : source_x + source_width,
        ]
        expected_crop_digest = region.get("sourceCropSHA256")
        if (
            not isinstance(expected_crop_digest, str)
            or SHA256_PATTERN.fullmatch(expected_crop_digest) is None
        ):
            raise ComparisonError(
                "responsive region {} sourceCropSHA256 is invalid".format(identifier)
            )
        actual_crop_digest = source_crop_sha256(
            source, sha256_file(reference_path), source_crop
        )
        if actual_crop_digest != expected_crop_digest:
            raise ComparisonError(
                "responsive region {} source crop digest no longer matches".format(identifier)
            )

        mask_path: Optional[Path] = None
        mask_key = region.get("mask")
        if mask_key is None:
            mask = np.ones((source_height, source_width), dtype=bool)
        else:
            if mask_key not in assets:
                raise ComparisonError(
                    "responsive region {} mask is not declared in assets".format(identifier)
                )
            mask_path, mask = load_mask(
                root,
                authority_root,
                assets[mask_key],
                (source_width, source_height),
                platform_only=True,
            )
            input_paths.add(mask_path)

        candidate_element_id = region["candidateElementID"]
        frame = frames.get(candidate_element_id)
        if frame is None:
            raise ComparisonError(
                "responsive region {} candidate element is absent from attested elementFrames".format(
                    identifier
                )
            )
        candidate_crop = frame_pixel_crop(
            frame,
            candidate_dimensions,
            "responsive region {} candidate".format(identifier),
        )
        candidate_x, candidate_y, candidate_width, candidate_height = candidate_crop
        if source_width * candidate_height != source_height * candidate_width:
            raise ComparisonError(
                "responsive region {} candidate frame aspect ratio differs from sourceCrop".format(
                    identifier
                )
            )
        candidate_region = candidate[
            candidate_y : candidate_y + candidate_height,
            candidate_x : candidate_x + candidate_width,
        ]
        candidate_region, resized = normalize_candidate(
            candidate_region, (source_width, source_height)
        )
        focal_region = (0, 0, source_width, source_height)
        metrics, luminance_map, delta_e = comparison_metrics(
            source,
            candidate_region,
            mask,
            focal_region,
        )
        thresholds = dict(region["thresholds"])
        checks = metric_checks(metrics, thresholds)
        heatmap = heatmap_pixels(luminance_map, delta_e, mask)
        heatmaps.append((identifier, heatmap))
        rendered_regions.append(
            {
                "id": identifier,
                "result": "PASS" if all(checks.values()) else "FAIL",
                "reference": display_path(reference_path, root),
                "referenceSHA256": sha256_file(reference_path),
                "referenceDimensions": list(reference_dimensions),
                "sourceCrop": list(source_crop),
                "sourceCropSHA256": actual_crop_digest,
                "sourceDimensions": [source_width, source_height],
                "candidateElementID": candidate_element_id,
                "candidateElementFrame": {
                    key: frame[key] for key in ("x", "y", "width", "height")
                },
                "candidatePixelCrop": list(candidate_crop),
                "candidateRegionDimensions": [candidate_width, candidate_height],
                "candidateNormalizedToSource": resized,
                "aspectRatioPreserved": True,
                "approvedMask": (
                    display_path(mask_path, root) if mask_path is not None else None
                ),
                "approvedMaskSHA256": (
                    sha256_file(mask_path) if mask_path is not None else None
                ),
                "scoredPixelFraction": float(np.mean(mask)),
                "focalRegion": list(focal_region),
                "metrics": metrics,
                "thresholds": thresholds,
                "checks": checks,
            }
        )

    for output in (output_json, output_heatmap):
        if output in input_paths:
            raise ComparisonError("comparison output collides with an input")

    atlas, placements = heatmap_atlas(heatmaps)
    placement_index = {item["regionID"]: item["frame"] for item in placements}
    for region in rendered_regions:
        region["heatmapAtlasFrame"] = placement_index[region["id"]]
    aggregate_metrics = {
        "luminanceSSIM": min(
            item["metrics"]["luminanceSSIM"] for item in rendered_regions
        ),
        "edgeSSIM": min(item["metrics"]["edgeSSIM"] for item in rendered_regions),
        "focalSSIM": min(item["metrics"]["focalSSIM"] for item in rendered_regions),
        "medianDeltaE": max(
            item["metrics"]["medianDeltaE"] for item in rendered_regions
        ),
        "p95DeltaE": max(item["metrics"]["p95DeltaE"] for item in rendered_regions),
        "fractionDeltaEAbove20": max(
            item["metrics"]["fractionDeltaEAbove20"] for item in rendered_regions
        ),
    }
    aggregate_checks = metric_checks(aggregate_metrics)
    layout_passed = all(layout_evidence["checks"].values())
    metrics_passed = all(aggregate_checks.values())
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "comparisonPolicy": RESPONSIVE_POLICY,
        "result": "PASS" if layout_passed and metrics_passed else "FAIL",
        "comparisonID": plan["id"],
        "manifest": display_path(manifest_path, root),
        "manifestSHA256": sha256_file(manifest_path),
        "candidate": display_path(candidate_path, root),
        "candidateSHA256": sha256_file(candidate_path),
        "candidateDimensions": list(candidate_dimensions),
        "captureRecord": display_path(capture_record_path, root),
        "captureRecordSHA256": sha256_file(capture_record_path),
        "stateSeedSHA256": capture_record["stateSeedSHA256"],
        "elementFrameAttestation": {
            "coordinateOrigin": "top-left",
            "units": "pixels",
            "scale": capture_record["elementFrames"]["scale"],
            "pixelRoundingPolicy": "outward-to-integral-bounds",
        },
        "layoutAssertions": layout_evidence,
        "regionCount": len(rendered_regions),
        "passingRegionCount": sum(
            1 for item in rendered_regions if item["result"] == "PASS"
        ),
        "regions": rendered_regions,
        "metrics": aggregate_metrics,
        "thresholds": dict(THRESHOLDS),
        "checks": aggregate_checks,
        "aggregateChecks": {
            "allRegionsPass": metrics_passed,
            "layoutAssertionsPass": layout_passed,
        },
        "heatmap": display_path(output_heatmap, root),
        "heatmapAtlas": placements,
    }
    atomic_write_text(output_json, json.dumps(result, indent=2, sort_keys=True) + "\n")
    atomic_write_png(output_heatmap, atlas)
    return result


def compare(
    root: Path,
    manifest_path: Path,
    comparison_id: str,
    candidate_path: Path,
    output_stem: Path,
    capture_record_path: Optional[Path] = None,
) -> Dict[str, Any]:
    if DEPENDENCY_ERROR is not None:
        raise ComparisonError(
            "required image comparison dependency is unavailable: {}".format(DEPENDENCY_ERROR)
        )
    root = root.resolve()
    manifest_path = manifest_path.resolve()
    candidate_path = candidate_path.resolve()
    output_stem = output_stem.resolve()
    if not is_within(manifest_path, root):
        raise ComparisonError("authority manifest must be inside the repository root")

    manifest = load_manifest(manifest_path)
    authority_root = resolve_repo_path(root, manifest.get("authorityRoot"), "authorityRoot")
    if not authority_root.is_dir():
        raise ComparisonError("authorityRoot is missing")
    assets = asset_index(manifest)
    plan = selected_comparison(manifest, comparison_id)
    if plan.get("policy") == RESPONSIVE_POLICY:
        return compare_responsive(
            root,
            manifest_path,
            manifest,
            authority_root,
            assets,
            plan,
            candidate_path,
            output_stem,
            capture_record_path,
        )
    if "policy" in plan:
        raise ComparisonError("comparison policy is unsupported")
    if plan.get("capture") is not None and plan.get("capture") != candidate_path.name:
        raise ComparisonError("comparison candidate differs from mapped capture")
    reference_key = plan.get("reference")
    if reference_key not in assets:
        raise ComparisonError("comparison reference is not declared in assets")
    reference_path, reference, dimensions = validate_pinned_asset(
        root,
        authority_root,
        assets[reference_key],
        "reference",
    )
    focal_region = validate_region(plan.get("focalRegion"), dimensions)

    mask_path: Optional[Path] = None
    if plan.get("mask") is None:
        mask = np.ones((dimensions[1], dimensions[0]), dtype=bool)
    else:
        mask_key = plan.get("mask")
        if mask_key not in assets:
            raise ComparisonError("comparison mask is not declared in assets")
        mask_path, mask = load_mask(root, authority_root, assets[mask_key], dimensions)

    if not candidate_path.is_file():
        raise ComparisonError("candidate image is missing")
    if is_within(candidate_path, authority_root):
        raise ComparisonError("candidate must not be stored inside immutable authorityRoot")
    candidate, candidate_dimensions = load_rgb(candidate_path)
    capture_record: Optional[Dict[str, Any]] = None
    if capture_record_path is not None:
        capture_record_path = capture_record_path.resolve()
        if is_within(capture_record_path, authority_root):
            raise ComparisonError("capture record must not be stored inside authorityRoot")
        capture_record = load_bound_capture_record(
            capture_record_path, candidate_path, candidate_dimensions
        )
    candidate, resized = normalize_candidate(candidate, dimensions)

    output_json = Path(str(output_stem) + ".json")
    output_heatmap = Path(str(output_stem) + ".heatmap.png")
    inputs = {manifest_path, reference_path, candidate_path}
    if capture_record_path is not None:
        inputs.add(capture_record_path)
    if mask_path is not None:
        inputs.add(mask_path)
    for output in (output_json, output_heatmap):
        if is_within(output, authority_root):
            raise ComparisonError("comparison output must not be written inside authorityRoot")
        if output in inputs:
            raise ComparisonError("comparison output collides with an input")

    metrics, luminance_map, delta_e = comparison_metrics(
        reference,
        candidate,
        mask,
        focal_region,
    )
    checks = metric_checks(metrics)
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "result": "PASS" if all(checks.values()) else "FAIL",
        "comparisonID": comparison_id,
        "manifest": display_path(manifest_path, root),
        "manifestSHA256": sha256_file(manifest_path),
        "reference": display_path(reference_path, root),
        "referenceSHA256": sha256_file(reference_path),
        "candidate": display_path(candidate_path, root),
        "candidateSHA256": sha256_file(candidate_path),
        "referenceDimensions": list(dimensions),
        "candidateDimensions": list(candidate_dimensions),
        "candidateNormalizedToReference": resized,
        "approvedMask": display_path(mask_path, root) if mask_path is not None else None,
        "scoredPixelFraction": float(np.mean(mask)),
        "focalRegion": list(focal_region),
        "metrics": metrics,
        "thresholds": dict(THRESHOLDS),
        "checks": checks,
        "heatmap": display_path(output_heatmap, root),
    }
    if capture_record_path is not None and capture_record is not None:
        result.update(
            {
                "captureRecord": display_path(capture_record_path, root),
                "captureRecordSHA256": sha256_file(capture_record_path),
                "stateSeedSHA256": capture_record["stateSeedSHA256"],
            }
        )
    atomic_write_text(output_json, json.dumps(result, indent=2, sort_keys=True) + "\n")
    atomic_write_png(output_heatmap, heatmap_pixels(luminance_map, delta_e, mask))
    return result


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare one capture using manifest-pinned authority, focal region, and mask."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root. Defaults to the parent of scripts/.",
    )
    parser.add_argument("--comparison-id", required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument(
        "--capture-record",
        type=Path,
        help="Explicit candidate-bound record; required by responsive-regions-v1.",
    )
    parser.add_argument("--output", type=Path, required=True, help="Output path stem.")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_arguments(argv)
    root = args.root.resolve()
    manifest = root / DEFAULT_MANIFEST
    candidate = args.candidate if args.candidate.is_absolute() else root / args.candidate
    capture_record = args.capture_record
    if capture_record is not None and not capture_record.is_absolute():
        capture_record = root / capture_record
    output = args.output if args.output.is_absolute() else root / args.output
    try:
        result = compare(
            root,
            manifest,
            args.comparison_id,
            candidate,
            output,
            capture_record,
        )
    except (ComparisonError, OSError) as error:
        rendered = {
            "schemaVersion": SCHEMA_VERSION,
            "result": "ERROR",
            "error": str(error),
        }
        sys.stdout.write(json.dumps(rendered, indent=2, sort_keys=True) + "\n")
        return 2
    sys.stdout.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
