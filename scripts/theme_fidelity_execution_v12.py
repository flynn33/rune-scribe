#!/usr/bin/env python3
"""Execute the v1.2 Theme fidelity authority against bound capture evidence.

The executor deliberately recomputes image metrics, structural observations,
and runtime probe results.  A pre-existing PASS label is never acceptance
evidence.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any, Iterable, Mapping, Sequence

import numpy as np
from PIL import Image, UnidentifiedImageError
from skimage.color import deltaE_ciede2000, rgb2gray, rgb2lab
from skimage.filters import sobel
from skimage.metrics import structural_similarity

try:
    from scripts.theme_fidelity_xcui_evidence import (
        XCUI_OPERATION,
        XCUIEvidenceError,
        ValidatedSidecar,
        DIAGNOSTIC_PLAN_INTERACTIVE,
        DIAGNOSTIC_PLAN_STATIC,
        DIAGNOSTIC_RESOURCES,
        DIAGNOSTIC_STATE,
        DIAGNOSTIC_DYNAMIC_TYPE,
        LARGE_TEXT_CONTROL_IDS,
        MASTERY_TITLE_BY_CODEX,
        MOBILE_HIT_TARGET_IDS,
        NORSE_ENCOUNTERED_ARTIFACT_ID,
        candidate_ids_for_entry,
        recompute_probe_observed as recompute_xcui_probe_observed,
        resolve_attachment as resolve_xcui_attachment,
        sidecar_name,
        validate_rect as validate_xcui_rect,
        validate_sidecar,
        xcui_probe_ids_for_entry,
    )
except ModuleNotFoundError:
    from theme_fidelity_xcui_evidence import (  # type: ignore[no-redef]
        XCUI_OPERATION,
        XCUIEvidenceError,
        ValidatedSidecar,
        DIAGNOSTIC_PLAN_INTERACTIVE,
        DIAGNOSTIC_PLAN_STATIC,
        DIAGNOSTIC_RESOURCES,
        DIAGNOSTIC_STATE,
        DIAGNOSTIC_DYNAMIC_TYPE,
        LARGE_TEXT_CONTROL_IDS,
        MASTERY_TITLE_BY_CODEX,
        MOBILE_HIT_TARGET_IDS,
        NORSE_ENCOUNTERED_ARTIFACT_ID,
        candidate_ids_for_entry,
        recompute_probe_observed as recompute_xcui_probe_observed,
        resolve_attachment as resolve_xcui_attachment,
        sidecar_name,
        validate_rect as validate_xcui_rect,
        validate_sidecar,
        xcui_probe_ids_for_entry,
    )


SCHEMA_VERSION = "1.2"
AUTHORITY_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/"
    "02-COMPARISON-AUTHORITY/Comparison-Authority-v1.2.json"
)
ASSET_MANIFEST_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/"
    "03-AUTHORITY-ASSETS/AUTHORITY-ASSET-MANIFEST-v1.2.json"
)
CANDIDATE_CATALOG_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/"
    "02-COMPARISON-AUTHORITY/Candidate-Capture-Catalog-v1.2.json"
)
PROBE_CATALOG_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/"
    "02-COMPARISON-AUTHORITY/Runtime-Probe-Catalog-v1.2.json"
)
SEED_CATALOG_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/"
    "02-COMPARISON-AUTHORITY/Deterministic-Seed-Catalog-v1.2.json"
)
AUTHORITY_ROOT_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2"
)
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
SOURCE_SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
ELEMENT_SOURCE_KEY = "candidateElementID"
RENDERER_SOURCE_KEY = "candidateRendererOutputID"
PROBE_SOURCE_KEY = "candidateProbeID"
SOURCE_KEYS = (ELEMENT_SOURCE_KEY, RENDERER_SOURCE_KEY, PROBE_SOURCE_KEY)
DESTINATION_DISPLAY_NAMES = {
    "iphone-portrait": "iPhone portrait",
    "ipad-portrait": "iPad portrait",
    "macos-standard": "macOS standard",
    "macos-resized": "macOS resized",
}
EXPECTED_ENTRY_COUNT = 400
EXPECTED_MAPPING_COUNT = 1104
NORMALIZED_SIZE = (512, 512)
DIRECT_SCREEN_POLICY = "direct-screen-system-chrome-v1"
DIRECT_SCREEN_THRESHOLD_PROFILE = "direct-screen-v1"
DIRECT_SCREEN_POLICY_MASK_DECLARATION = (
    "platform-owned status bar, home indicator, window titlebar, cursor, and "
    "scrollbar only; never Theme or application content"
)
DIRECT_SCREEN_THRESHOLD_MASK_DECLARATION = (
    "Only platform-owned status/window chrome, transient cursor, and scrollbar pixels."
)
MAXIMUM_SYSTEM_CHROME_MASK_FRACTION = 0.05

# Direct-screen mappings currently exist only for the approved iPhone portrait
# destination.  These normalized regions describe platform-owned chrome, not
# application layout, and are deliberately part of executable source rather
# than an operator-supplied mask file.
DESTINATION_SYSTEM_CHROME_PROFILES: Mapping[str, Mapping[str, Any]] = {
    "iphone-portrait": {
        "profileID": "ios-iphone-portrait-platform-chrome-v1",
        "platform": "iOS Simulator",
        "regions": (
            {
                "kind": "status-bar",
                "normalizedRect": (0.0, 0.0, 1.0, 0.03),
            },
            {
                "kind": "home-indicator",
                "normalizedRect": (0.31, 0.981, 0.38, 0.012),
            },
        ),
    },
}
EXPECTED_SYSTEM_CHROME_KINDS = {
    "iphone-portrait": ("status-bar", "home-indicator"),
}


class ExecutionError(ValueError):
    """Raised when authority or evidence cannot be executed truthfully."""


class DuplicateJSONKeyError(ValueError):
    pass


def reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    decoded: dict[str, Any] = {}
    for key, value in pairs:
        if key in decoded:
            raise DuplicateJSONKeyError(f"duplicate JSON key: {key}")
        decoded[key] = value
    return decoded


def load_json(path: Path, label: str = "JSON document") -> dict[str, Any]:
    try:
        decoded = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
        raise ExecutionError(f"{label} is invalid: {path}: {error}") from error
    if not isinstance(decoded, dict):
        raise ExecutionError(f"{label} must be a JSON object: {path}")
    return decoded


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
        raise ExecutionError(f"document is not canonical JSON data: {error}") from error
    return hashlib.sha256(encoded).hexdigest()


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
    except ValueError:
        return False
    return True


def resolve_within(parent: Path, raw: Any, label: str) -> Path:
    if not isinstance(raw, str) or not raw.strip():
        raise ExecutionError(f"{label} must be a non-empty relative path")
    relative = Path(raw)
    if relative.is_absolute():
        raise ExecutionError(f"{label} must be relative")
    resolved = (parent / relative).resolve()
    if not is_within(resolved, parent):
        raise ExecutionError(f"{label} escapes its declared root")
    return resolved


def atomic_write_json(path: Path, document: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def atomic_write_png(path: Path, image: Image.Image) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    image.save(temporary, format="PNG", optimize=False)
    temporary.replace(path)


def safe_stem(identifier: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "--", identifier).strip(".-")
    if not value:
        raise ExecutionError("identifier cannot be represented as an output filename")
    return value


def load_rgba(path: Path, label: str) -> Image.Image:
    if not path.is_file():
        raise ExecutionError(f"{label} is missing: {path}")
    try:
        with Image.open(path) as source:
            source.load()
            image = source.convert("RGBA")
    except (OSError, UnidentifiedImageError) as error:
        raise ExecutionError(f"{label} cannot be decoded: {path}: {error}") from error
    if image.width < 1 or image.height < 1:
        raise ExecutionError(f"{label} has invalid dimensions: {path}")
    return image


def alpha_trim(image: Image.Image) -> tuple[Image.Image, list[int]]:
    """Remove only completely transparent outer rows and columns."""
    rgba = image.convert("RGBA")
    alpha = np.asarray(rgba.getchannel("A"), dtype=np.uint8)
    nonzero = np.argwhere(alpha != 0)
    if nonzero.size == 0:
        raise ExecutionError("candidate/reference image is fully transparent")
    y0, x0 = nonzero.min(axis=0)
    y1, x1 = nonzero.max(axis=0) + 1
    return rgba.crop((int(x0), int(y0), int(x1), int(y1))), [
        int(x0), int(y0), int(x1 - x0), int(y1 - y0)
    ]


def aspect_fit_pad(image: Image.Image, size: tuple[int, int] = NORMALIZED_SIZE) -> Image.Image:
    if image.width < 1 or image.height < 1:
        raise ExecutionError("cannot normalize an empty image")
    scale = min(size[0] / image.width, size[1] / image.height)
    dimensions = (
        max(1, int(round(image.width * scale))),
        max(1, int(round(image.height * scale))),
    )
    resized = image.resize(dimensions, Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    origin = ((size[0] - dimensions[0]) // 2, (size[1] - dimensions[1]) // 2)
    canvas.alpha_composite(resized, origin)
    return canvas


def composite_rgb(image: Image.Image) -> np.ndarray:
    rgba = np.asarray(image.convert("RGBA"), dtype=np.float32) / 255.0
    alpha = rgba[..., 3:4]
    rgb = rgba[..., :3] * alpha
    return rgb


def destination_system_chrome_mask(
    destination: str,
    dimensions: tuple[int, int],
) -> tuple[np.ndarray, dict[str, Any]]:
    """Derive the only authorized direct-screen mask from the destination."""
    if not isinstance(destination, str) or not destination:
        raise ExecutionError("direct-screen normalization requires a destination")
    profile = DESTINATION_SYSTEM_CHROME_PROFILES.get(destination)
    if not isinstance(profile, Mapping):
        raise ExecutionError(
            f"direct-screen destination has no platform-chrome profile: {destination}"
        )
    if (
        not isinstance(dimensions, tuple)
        or len(dimensions) != 2
        or any(isinstance(value, bool) or not isinstance(value, int) for value in dimensions)
    ):
        raise ExecutionError("platform-chrome mask dimensions must be two integers")
    width, height = dimensions
    if width < 7 or height < 7:
        raise ExecutionError("platform-chrome mask dimensions are smaller than SSIM window")
    if destination.endswith("-portrait") and width >= height:
        raise ExecutionError(
            f"platform-chrome destination is not portrait: {destination} {width}x{height}"
        )
    if set(profile) != {"profileID", "platform", "regions"}:
        raise ExecutionError("platform-chrome profile has unexpected fields")
    profile_id = profile.get("profileID")
    platform = profile.get("platform")
    regions = profile.get("regions")
    if (
        not isinstance(profile_id, str)
        or not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", profile_id)
        or platform != "iOS Simulator"
        or not isinstance(regions, (tuple, list))
    ):
        raise ExecutionError("platform-chrome profile identity is invalid")
    expected_kinds = EXPECTED_SYSTEM_CHROME_KINDS.get(destination)
    if expected_kinds is None or len(regions) != len(expected_kinds):
        raise ExecutionError("platform-chrome profile region count is invalid")

    excluded = np.zeros((height, width), dtype=np.bool_)
    materialized_regions: list[dict[str, Any]] = []
    for ordinal, (region, expected_kind) in enumerate(zip(regions, expected_kinds)):
        if not isinstance(region, Mapping) or set(region) != {"kind", "normalizedRect"}:
            raise ExecutionError("platform-chrome region has unexpected fields")
        kind = region.get("kind")
        raw_rect = region.get("normalizedRect")
        if kind != expected_kind:
            raise ExecutionError(
                f"platform-chrome region kind differs at index {ordinal}: {kind!r}"
            )
        if not isinstance(raw_rect, (tuple, list)) or len(raw_rect) != 4:
            raise ExecutionError(f"platform-chrome {kind} rectangle is invalid")
        values: list[float] = []
        for value in raw_rect:
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(float(value))
            ):
                raise ExecutionError(f"platform-chrome {kind} rectangle is non-numeric")
            values.append(float(value))
        x, y, region_width, region_height = values
        if (
            x < 0.0
            or y < 0.0
            or region_width <= 0.0
            or region_height <= 0.0
            or x + region_width > 1.0
            or y + region_height > 1.0
        ):
            raise ExecutionError(f"platform-chrome {kind} rectangle is out of bounds")
        x0 = int(math.floor(x * width))
        y0 = int(math.floor(y * height))
        x1 = int(math.ceil((x + region_width) * width))
        y1 = int(math.ceil((y + region_height) * height))
        if x0 < 0 or y0 < 0 or x1 > width or y1 > height or x0 >= x1 or y0 >= y1:
            raise ExecutionError(f"platform-chrome {kind} pixel rectangle is invalid")
        if np.any(excluded[y0:y1, x0:x1]):
            raise ExecutionError("platform-chrome regions overlap")
        excluded[y0:y1, x0:x1] = True
        materialized_regions.append(
            {
                "kind": kind,
                "normalizedRect": values,
                "pixelRect": [x0, y0, x1 - x0, y1 - y0],
            }
        )

    excluded_count = int(np.count_nonzero(excluded))
    total_count = int(width * height)
    fraction = excluded_count / total_count
    if excluded_count == 0 or fraction > MAXIMUM_SYSTEM_CHROME_MASK_FRACTION:
        raise ExecutionError(
            "platform-chrome mask is empty or exceeds the maximum authorized fraction"
        )
    included = np.logical_not(excluded)
    if int(np.count_nonzero(included)) < 49:
        raise ExecutionError("platform-chrome mask leaves too few metric pixels")
    mask_sha = hashlib.sha256(
        np.ascontiguousarray(excluded, dtype=np.uint8).tobytes(order="C")
    ).hexdigest()
    profile_document = {
        "profileID": profile_id,
        "platform": platform,
        "regions": [
            {
                "kind": item["kind"],
                "normalizedRect": item["normalizedRect"],
            }
            for item in materialized_regions
        ],
    }
    provenance = {
        "policy": DIRECT_SCREEN_POLICY,
        "derivation": "declared-destination-normalized-regions",
        "destination": destination,
        "profileID": profile_id,
        "profileSHA256": canonical_json_sha256(profile_document),
        "profileSource": "executor-built-in-destination-profile",
        "coordinateOrigin": "top-left",
        "normalizedDimensions": [width, height],
        "regions": materialized_regions,
        "pixelEncoding": "uint8-row-major-1-excluded",
        "maskSHA256": mask_sha,
        "excludedPixelCount": excluded_count,
        "includedPixelCount": total_count - excluded_count,
        "totalPixelCount": total_count,
        "excludedPixelFraction": fraction,
        "customMaskFileUsed": False,
        "manualCoordinatesUsed": False,
    }
    return included, provenance


def normalize_pair(
    reference: Image.Image,
    candidate: Image.Image,
    policy: str,
    *,
    destination: str | None = None,
) -> tuple[np.ndarray, np.ndarray, dict[str, Any], np.ndarray | None]:
    metric_inclusion_mask: np.ndarray | None = None
    if policy == DIRECT_SCREEN_POLICY:
        dimensions = (
            min(reference.width, candidate.width),
            min(reference.height, candidate.height),
        )
        if min(dimensions) < 7:
            raise ExecutionError("direct-screen normalization is smaller than SSIM window")
        normalized_reference = reference.resize(dimensions, Image.Resampling.LANCZOS)
        normalized_candidate = candidate.resize(dimensions, Image.Resampling.LANCZOS)
        metric_inclusion_mask, mask_provenance = destination_system_chrome_mask(
            destination or "", dimensions
        )
        details = {
            "policy": policy,
            "referenceCrop": "full-image",
            "candidateCrop": "exact-declared-screen-element",
            "normalizedDimensions": list(dimensions),
            "opaquePixelsCropped": False,
            "platformChromeMask": mask_provenance,
        }
    elif policy in {
        "focal-complete-image-aspect-fit-v1",
        "renderer-complete-image-aspect-fit-v1",
    }:
        trimmed_reference, reference_trim = alpha_trim(reference)
        trimmed_candidate, candidate_trim = alpha_trim(candidate)
        normalized_reference = aspect_fit_pad(trimmed_reference)
        normalized_candidate = aspect_fit_pad(trimmed_candidate)
        details = {
            "policy": policy,
            "referenceAlphaTrim": reference_trim,
            "candidateAlphaTrim": candidate_trim,
            "normalizedDimensions": list(NORMALIZED_SIZE),
            "opaquePixelsCropped": False,
        }
    else:
        raise ExecutionError(f"unsupported image normalization policy: {policy}")
    reference_rgb = composite_rgb(normalized_reference)
    candidate_rgb = composite_rgb(normalized_candidate)
    if metric_inclusion_mask is not None:
        excluded = np.logical_not(metric_inclusion_mask)
        reference_rgb[excluded] = 0.0
        candidate_rgb[excluded] = 0.0
    return reference_rgb, candidate_rgb, details, metric_inclusion_mask


def _ssim(reference: np.ndarray, candidate: np.ndarray) -> tuple[float, np.ndarray]:
    score, score_map = structural_similarity(
        reference, candidate, data_range=1.0, full=True
    )
    return float(score), score_map


def comparison_metrics(
    reference: np.ndarray,
    candidate: np.ndarray,
    metric_inclusion_mask: np.ndarray | None = None,
) -> tuple[dict[str, float], np.ndarray, np.ndarray]:
    if reference.shape != candidate.shape or reference.ndim != 3 or reference.shape[2] != 3:
        raise ExecutionError("comparison metric inputs must be equal RGB arrays")
    scoring_mask: np.ndarray | None = None
    if metric_inclusion_mask is not None:
        if (
            not isinstance(metric_inclusion_mask, np.ndarray)
            or metric_inclusion_mask.dtype != np.bool_
            or metric_inclusion_mask.shape != reference.shape[:2]
        ):
            raise ExecutionError("metric inclusion mask must be a matching boolean array")
        scoring_mask = metric_inclusion_mask.copy()
        # skimage's scalar SSIM omits the three-pixel window border. Preserve
        # those semantics while also omitting the declared chrome pixels.
        scoring_mask[:3, :] = False
        scoring_mask[-3:, :] = False
        scoring_mask[:, :3] = False
        scoring_mask[:, -3:] = False
        if not np.any(scoring_mask):
            raise ExecutionError("metric inclusion mask leaves no SSIM pixels")
    reference_luminance = rgb2gray(reference)
    candidate_luminance = rgb2gray(candidate)
    luminance_ssim, luminance_map = _ssim(reference_luminance, candidate_luminance)
    edge_ssim, edge_map = _ssim(sobel(reference_luminance), sobel(candidate_luminance))
    delta_e = deltaE_ciede2000(rgb2lab(reference), rgb2lab(candidate))
    delta_values = delta_e
    if scoring_mask is not None:
        luminance_ssim = float(np.mean(luminance_map[scoring_mask]))
        edge_ssim = float(np.mean(edge_map[scoring_mask]))
        delta_values = delta_e[metric_inclusion_mask]
        luminance_map = luminance_map.copy()
        delta_e = delta_e.copy()
        luminance_map[np.logical_not(metric_inclusion_mask)] = 1.0
        delta_e[np.logical_not(metric_inclusion_mask)] = 0.0
    return {
        "luminanceSSIM": luminance_ssim,
        "edgeSSIM": edge_ssim,
        # An exact element or renderer output is itself the declared focal region.
        "focalSSIM": luminance_ssim,
        "medianDeltaE": float(np.median(delta_values)),
        "p95DeltaE": float(np.percentile(delta_values, 95)),
        "severeDeltaEPercent": float(np.mean(delta_values > 20.0) * 100.0),
    }, luminance_map, delta_e


def metric_checks(
    metrics: Mapping[str, float], profile: Mapping[str, Any]
) -> dict[str, bool]:
    checks: dict[str, bool] = {}
    if "fullScreenLuminanceSSIMMinimum" in profile:
        checks["luminanceSSIM"] = (
            metrics["luminanceSSIM"] >= profile["fullScreenLuminanceSSIMMinimum"]
        )
    if "edgeSSIMMinimum" in profile:
        checks["edgeSSIM"] = metrics["edgeSSIM"] >= profile["edgeSSIMMinimum"]
    if "focalSSIMMinimum" in profile:
        checks["focalSSIM"] = metrics["focalSSIM"] >= profile["focalSSIMMinimum"]
    if "medianDeltaEMaximum" in profile:
        checks["medianDeltaE"] = (
            metrics["medianDeltaE"] <= profile["medianDeltaEMaximum"]
        )
    if "p95DeltaEMaximum" in profile:
        checks["p95DeltaE"] = metrics["p95DeltaE"] <= profile["p95DeltaEMaximum"]
    if "severeDeltaEPercentMaximum" in profile:
        checks["severeDeltaEPercent"] = (
            metrics["severeDeltaEPercent"] <= profile["severeDeltaEPercentMaximum"]
        )
    if not checks:
        raise ExecutionError("image threshold profile has no executable metric thresholds")
    return checks


def validate_direct_screen_mask_contract(authority: Mapping[str, Any]) -> None:
    """Fail closed unless every direct-screen mapping uses the fixed mask contract."""
    if authority.get("customMaskFilesAuthorized") is not False:
        raise ExecutionError("comparison authority must prohibit custom mask files")
    if authority.get("manualCropCoordinatesAuthorized") is not False:
        raise ExecutionError("comparison authority must prohibit manual crop coordinates")
    normalization_policies = authority.get("normalizationPolicies")
    if not isinstance(normalization_policies, Mapping):
        raise ExecutionError("comparison authority normalization policies are missing")
    direct_policy = normalization_policies.get(DIRECT_SCREEN_POLICY)
    if not isinstance(direct_policy, Mapping):
        raise ExecutionError("direct-screen normalization policy is missing")
    if (
        direct_policy.get("referenceCrop") != "full-image"
        or direct_policy.get("candidateCrop") != "exact declared screen element"
        or direct_policy.get("colorSpace") != "sRGB"
        or direct_policy.get("mask") != DIRECT_SCREEN_POLICY_MASK_DECLARATION
        or direct_policy.get("manualCropAllowed") is not False
        or direct_policy.get("manualMaskAllowed") is not False
    ):
        raise ExecutionError("direct-screen normalization policy mask contract drifted")
    threshold_profiles = authority.get("thresholdProfiles")
    direct_threshold = (
        threshold_profiles.get(DIRECT_SCREEN_THRESHOLD_PROFILE)
        if isinstance(threshold_profiles, Mapping)
        else None
    )
    if (
        not isinstance(direct_threshold, Mapping)
        or direct_threshold.get("maskPolicy")
        != DIRECT_SCREEN_THRESHOLD_MASK_DECLARATION
    ):
        raise ExecutionError("direct-screen threshold mask contract drifted")
    destinations = authority.get("destinations")
    if not isinstance(destinations, Mapping):
        raise ExecutionError("comparison authority destinations are missing")

    entries = authority.get("entries")
    if not isinstance(entries, list):
        raise ExecutionError("comparison authority entries are missing")
    mapping_count = 0
    forbidden_mask_fields = {
        "mask",
        "maskFile",
        "maskPath",
        "maskRect",
        "maskRegions",
    }
    expected_source_crop = {
        "mode": "full-image",
        "normalizedRect": {"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0},
        "manualCoordinatesAllowed": False,
    }

    def nested_mask_fields(value: Any) -> set[str]:
        found: set[str] = set()
        if isinstance(value, Mapping):
            for key, child in value.items():
                if key in forbidden_mask_fields:
                    found.add(str(key))
                found.update(nested_mask_fields(child))
        elif isinstance(value, list):
            for child in value:
                found.update(nested_mask_fields(child))
        return found

    for entry in entries:
        if not isinstance(entry, Mapping):
            raise ExecutionError("comparison authority contains an invalid entry")
        destination = entry.get("destination")
        mappings = entry.get("referenceMappings")
        if not isinstance(mappings, list):
            raise ExecutionError("comparison authority entry mappings are invalid")
        for mapping in mappings:
            if not isinstance(mapping, Mapping):
                raise ExecutionError("comparison authority contains an invalid mapping")
            policy = mapping.get("normalizationPolicy")
            threshold = mapping.get("thresholdProfile")
            if policy != DIRECT_SCREEN_POLICY and threshold != DIRECT_SCREEN_THRESHOLD_PROFILE:
                continue
            if policy != DIRECT_SCREEN_POLICY or threshold != DIRECT_SCREEN_THRESHOLD_PROFILE:
                raise ExecutionError(
                    "direct-screen normalization and threshold profiles must be paired"
                )
            mapping_count += 1
            profile = DESTINATION_SYSTEM_CHROME_PROFILES.get(str(destination))
            declaration = destinations.get(destination) if isinstance(destination, str) else None
            if not isinstance(profile, Mapping) or not isinstance(declaration, Mapping):
                raise ExecutionError(
                    f"direct-screen mapping destination has no mask contract: {destination}"
                )
            if declaration.get("platform") != profile.get("platform"):
                raise ExecutionError(
                    f"direct-screen destination platform differs from mask profile: {destination}"
                )
            if (
                mapping.get("scoreDisposition") != "image-metric"
                or mapping.get("referenceRole") != "full-screen"
                or mapping.get("sourceCrop") != expected_source_crop
            ):
                raise ExecutionError("direct-screen mapping crop or disposition drifted")
            focal_region = mapping.get("focalRegion")
            if (
                not isinstance(focal_region, Mapping)
                or focal_region.get("manualCoordinatesAllowed") is not False
            ):
                raise ExecutionError("direct-screen mapping permits manual focal coordinates")
            unexpected = nested_mask_fields(mapping)
            if unexpected:
                raise ExecutionError(
                    "direct-screen mapping declares an operator mask field: "
                    + ", ".join(sorted(unexpected))
                )
    if mapping_count == 0:
        raise ExecutionError("comparison authority has no executable direct-screen mappings")


def heatmap_image(luminance_map: np.ndarray, delta_e: np.ndarray) -> Image.Image:
    structural = np.clip((1.0 - luminance_map) / 2.0, 0.0, 1.0)
    perceptual = np.clip(delta_e / 20.0, 0.0, 1.0)
    level = np.maximum(structural, perceptual)
    red = np.rint(level * 255.0).astype(np.uint8)
    green = np.rint(level * (1.0 - level) * 2.0 * 255.0).astype(np.uint8)
    blue = np.zeros_like(red)
    return Image.fromarray(np.stack((red, green, blue), axis=-1), mode="RGB")


def frame_index(record: Mapping[str, Any]) -> dict[str, dict[str, float]]:
    element_frames = record.get("elementFrames")
    if not isinstance(element_frames, dict):
        raise ExecutionError("capture record lacks elementFrames")
    if element_frames.get("coordinateOrigin") != "top-left" or element_frames.get("units") != "pixels":
        raise ExecutionError("capture record elementFrames coordinates are unsupported")
    frames = element_frames.get("frames")
    if not isinstance(frames, list):
        raise ExecutionError("capture record elementFrames.frames must be an array")
    indexed: dict[str, dict[str, float]] = {}
    for item in frames:
        if not isinstance(item, dict):
            raise ExecutionError("capture record contains an invalid element frame")
        identifier = item.get("elementID")
        if not isinstance(identifier, str) or not identifier or identifier in indexed:
            raise ExecutionError("capture record element frame IDs must be non-empty and unique")
        converted: dict[str, float] = {}
        for key in ("x", "y", "width", "height"):
            value = item.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                raise ExecutionError(f"element frame {identifier}.{key} is invalid")
            converted[key] = float(value)
        if converted["width"] <= 0 or converted["height"] <= 0:
            raise ExecutionError(f"element frame {identifier} is empty")
        indexed[identifier] = converted
    return indexed


def integral_crop(frame: Mapping[str, float], dimensions: tuple[int, int]) -> tuple[int, int, int, int]:
    x0 = math.floor(frame["x"])
    y0 = math.floor(frame["y"])
    x1 = math.ceil(frame["x"] + frame["width"])
    y1 = math.ceil(frame["y"] + frame["height"])
    if x0 < 0 or y0 < 0 or x1 > dimensions[0] or y1 > dimensions[1]:
        raise ExecutionError("exact element frame extends beyond the candidate capture")
    if x1 <= x0 or y1 <= y0:
        raise ExecutionError("exact element frame produces an empty candidate")
    return x0, y0, x1, y1


def observation_index(record: Mapping[str, Any], key: str, id_key: str) -> dict[str, dict[str, Any]]:
    raw = record.get(key, [])
    if not isinstance(raw, list):
        raise ExecutionError(f"capture record {key} must be an array")
    indexed: dict[str, dict[str, Any]] = {}
    for item in raw:
        if not isinstance(item, dict):
            raise ExecutionError(f"capture record {key} contains an invalid item")
        identifier = item.get(id_key)
        if not isinstance(identifier, str) or not identifier or identifier in indexed:
            raise ExecutionError(f"capture record {key} IDs must be non-empty and unique")
        indexed[identifier] = item
    return indexed


def evaluate_operator(operator: str, observed: Any, expected: Any) -> bool:
    if operator == "equals":
        return type(observed) is type(expected) and observed == expected
    if operator == "less-than-or-equal":
        return (
            isinstance(observed, (int, float))
            and not isinstance(observed, bool)
            and observed <= expected
        )
    if operator == "greater-than-or-equal":
        return (
            isinstance(observed, (int, float))
            and not isinstance(observed, bool)
            and observed >= expected
        )
    if operator == "greater-than":
        return (
            isinstance(observed, (int, float))
            and not isinstance(observed, bool)
            and observed > expected
        )
    if operator == "equals-declared-reduce-motion-resource":
        return observed is True and expected is True
    raise ExecutionError(f"unsupported runtime probe operator: {operator}")


_MISSING = object()


def recomputed_probe_observed(
    probe_id: str,
    record: Mapping[str, Any],
    frames: Mapping[str, Mapping[str, float]],
) -> Any:
    diagnostics = record.get("runtimeDiagnostics")
    if not isinstance(diagnostics, dict):
        return _MISSING
    preview = diagnostics.get("preview")
    norse = diagnostics.get("norseBase")
    if probe_id.startswith("probe.theme.active."):
        return diagnostics.get("activeThemeID", _MISSING)
    if probe_id.startswith("probe.motion.mode."):
        return diagnostics.get("effectiveMotionMode", _MISSING)
    if probe_id.startswith("probe.motion.active-animation-count."):
        return diagnostics.get("activeThemeAnimationCount", _MISSING)
    if probe_id.startswith("probe.motion.background-resource."):
        effective = diagnostics.get("effectiveBackgroundResourceID", _MISSING)
        declared = diagnostics.get("declaredReduceMotionBackgroundResourceID", _MISSING)
        if effective is _MISSING or declared is _MISSING:
            return _MISSING
        return effective == declared
    if probe_id.startswith("probe.motion.visual-plan-revision."):
        return diagnostics.get("visualPlanRevision", _MISSING)
    if probe_id.startswith("probe.motion.preview-"):
        if not isinstance(preview, dict):
            return _MISSING
        element_id = preview.get("elementID")
        if not isinstance(element_id, str) or not element_id:
            return _MISSING
        frame = frames.get(element_id)
        exists = frame is not None
        if probe_id.startswith("probe.motion.preview-exists."):
            return exists and preview.get("exists") is True
        if not exists:
            return False
        viewport = _viewport_frame(frames, record)
        visible = (
            frame["x"] < viewport["x"] + viewport["width"]
            and frame["x"] + frame["width"] > viewport["x"]
            and frame["y"] < viewport["y"] + viewport["height"]
            and frame["y"] + frame["height"] > viewport["y"]
        )
        if probe_id.startswith("probe.motion.preview-visible."):
            return visible and preview.get("visible") is True
        if probe_id.startswith("probe.motion.preview-contained."):
            tolerance = float(record.get("scale", 1.0))
            contained = (
                frame["x"] >= viewport["x"] - tolerance
                and frame["y"] >= viewport["y"] - tolerance
                and frame["x"] + frame["width"]
                <= viewport["x"] + viewport["width"] + tolerance
                and frame["y"] + frame["height"]
                <= viewport["y"] + viewport["height"] + tolerance
            )
            return contained and preview.get("viewportContained") is True
    if not isinstance(norse, dict):
        return _MISSING
    if probe_id == "probe.norse.base-owned":
        return norse.get("owned", _MISSING)
    if probe_id == "probe.norse.base-selectable":
        return norse.get("selectable", _MISSING)
    if probe_id == "probe.norse.fallback-available":
        return norse.get("fallbackAvailable", _MISSING)
    if probe_id == "probe.norse.vault.locked-element-count":
        return norse.get("lockedElementCount", _MISSING)
    if probe_id == "probe.optional-codex.locked-renderer-covered":
        return norse.get("optionalLockedRendererCovered", _MISSING)
    return _MISSING


def parse_iso_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value:
        raise ExecutionError(f"{label} must be an ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ExecutionError(f"{label} must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise ExecutionError(f"{label} must include a timezone")
    return parsed


def _viewport_frame(frames: Mapping[str, Mapping[str, float]], record: Mapping[str, Any]) -> dict[str, float]:
    if "theme-fidelity.viewport" in frames:
        return dict(frames["theme-fidelity.viewport"])
    width = record.get("pixelWidth")
    height = record.get("pixelHeight")
    if not isinstance(width, int) or not isinstance(height, int):
        raise ExecutionError("capture record lacks viewport dimensions")
    return {"x": 0.0, "y": 0.0, "width": float(width), "height": float(height)}


def derive_bounds_assertion(
    assertion_id: str,
    candidate_ids: Sequence[str],
    frames: Mapping[str, Mapping[str, float]],
    record: Mapping[str, Any],
) -> tuple[bool, Any, str] | None:
    if not candidate_ids:
        return None
    available = [identifier for identifier in candidate_ids if identifier in frames]
    if assertion_id == "assert.element.exists":
        return len(available) == len(candidate_ids), {
            "required": list(candidate_ids), "present": available
        }, "elementFrames"
    if assertion_id == "assert.element.visible":
        viewport = _viewport_frame(frames, record)
        visible = []
        for identifier in available:
            item = frames[identifier]
            intersects = (
                item["x"] < viewport["x"] + viewport["width"]
                and item["x"] + item["width"] > viewport["x"]
                and item["y"] < viewport["y"] + viewport["height"]
                and item["y"] + item["height"] > viewport["y"]
            )
            if intersects:
                visible.append(identifier)
        return len(visible) == len(candidate_ids), {
            "required": list(candidate_ids), "visible": visible
        }, "elementFrames"
    if assertion_id in {"assert.element.viewport-contained", "assert.no-horizontal-overflow"}:
        viewport = _viewport_frame(frames, record)
        tolerance = 1.0 * float(record.get("scale", 1.0))
        contained = []
        for identifier in available:
            item = frames[identifier]
            horizontal = (
                item["x"] >= viewport["x"] - tolerance
                and item["x"] + item["width"]
                <= viewport["x"] + viewport["width"] + tolerance
            )
            vertical = (
                item["y"] >= viewport["y"] - tolerance
                and item["y"] + item["height"]
                <= viewport["y"] + viewport["height"] + tolerance
            )
            if horizontal and (vertical or assertion_id == "assert.no-horizontal-overflow"):
                contained.append(identifier)
        return len(contained) == len(candidate_ids), {
            "required": list(candidate_ids), "contained": contained
        }, "elementFrames"
    return None


def _live_rect(item: Mapping[str, Any], key: str, label: str) -> dict[str, float]:
    try:
        rectangle = validate_xcui_rect(item.get(key), f"{label}.{key}")
    except XCUIEvidenceError as error:
        raise ExecutionError(str(error)) from error
    if rectangle is None:
        raise ExecutionError(f"{label} lacks {key}")
    return rectangle


def _live_element_visible(item: Mapping[str, Any], label: str) -> bool:
    element = _live_rect(item, "elementFrame", label)
    window = _live_rect(item, "windowFrame", label)
    return rectangles_intersect(element, window)


def _live_element_contained(
    item: Mapping[str, Any], label: str, horizontal_only: bool = False
) -> bool:
    element = _live_rect(item, "elementFrame", label)
    window = _live_rect(item, "windowFrame", label)
    tolerance = 1.0
    horizontal = (
        element["x"] >= window["x"] - tolerance
        and element["x"] + element["width"]
        <= window["x"] + window["width"] + tolerance
    )
    if horizontal_only:
        return horizontal
    vertical = (
        element["y"] >= window["y"] - tolerance
        and element["y"] + element["height"]
        <= window["y"] + window["height"] + tolerance
    )
    return horizontal and vertical


def rectangles_intersect(
    first: Mapping[str, float], second: Mapping[str, float]
) -> bool:
    return (
        first["x"] < second["x"] + second["width"]
        and first["x"] + first["width"] > second["x"]
        and first["y"] < second["y"] + second["height"]
        and first["y"] + first["height"] > second["y"]
    )


def _witness(
    sidecar: ValidatedSidecar, identifier: str
) -> Mapping[str, Any]:
    item = sidecar.structural_witnesses.get(f"element:{identifier}")
    if item is None:
        raise ExecutionError(f"live structural witness is missing: {identifier}")
    return item


def _parse_witness_json(
    sidecar: ValidatedSidecar, identifier: str
) -> dict[str, Any]:
    item = _witness(sidecar, identifier)
    raw = item.get("value")
    if not isinstance(raw, str) or not raw:
        raise ExecutionError(f"live structural witness value is absent: {identifier}")
    try:
        decoded = json.loads(raw, object_pairs_hook=reject_duplicate_keys)
    except (json.JSONDecodeError, DuplicateJSONKeyError) as error:
        raise ExecutionError(
            f"live structural witness JSON is invalid: {identifier}: {error}"
        ) from error
    if not isinstance(decoded, dict):
        raise ExecutionError(f"live structural witness must contain a JSON object: {identifier}")
    return decoded


def _live_query_items(
    sidecar: ValidatedSidecar, candidate_ids: Sequence[str]
) -> list[Mapping[str, Any]]:
    items: list[Mapping[str, Any]] = []
    for identifier in candidate_ids:
        item = sidecar.candidate_captures.get(identifier)
        if item is None:
            raise ExecutionError(f"exact live candidate query is absent: {identifier}")
        items.append(item)
    return items


def _resource_sets(
    sidecar: ValidatedSidecar,
) -> tuple[set[str], set[str], set[str]]:
    document = _parse_witness_json(sidecar, DIAGNOSTIC_RESOURCES)
    if set(document) != {
        "schemaVersion",
        "requiredResourceIDs",
        "resolvedResourceIDs",
        "pickerArtworkResourceIDs",
    } or document.get("schemaVersion") != "1.0":
        raise ExecutionError("live resource witness keys are invalid")
    values: list[set[str]] = []
    for key in (
        "requiredResourceIDs",
        "resolvedResourceIDs",
        "pickerArtworkResourceIDs",
    ):
        raw = document.get(key)
        if (
            not isinstance(raw, list)
            or any(not isinstance(item, str) or not item for item in raw)
            or raw != sorted(set(raw))
        ):
            raise ExecutionError(f"live resource witness {key} is invalid")
        values.append(set(raw))
    return values[0], values[1], values[2]


def _live_state_truth(
    entry: Mapping[str, Any], sidecar: ValidatedSidecar
) -> tuple[bool, dict[str, Any]]:
    state = _parse_witness_json(sidecar, DIAGNOSTIC_STATE)
    required_keys = {
        "schemaVersion",
        "surface",
        "destination",
        "themeID",
        "codexID",
        "activeThemeID",
        "effectiveCodexID",
        "appearance",
        "messageProfile",
        "vaultState",
        "providerState",
        "providerIsOwned",
        "providerIsSelectable",
        "providerIsSelected",
        "renderedVaultState",
        "safePreviewStatus",
        "safePreviewByteCount",
        "highContrastBackgroundResourceID",
        "progressCurrent",
        "progressTarget",
        "showsSelectedArtifacts",
        "focusedArtifactID",
        "focusedArtifactState",
        "focusedArtifactIsOwned",
        "focusedArtifactIsSelectable",
    }
    if set(state) != required_keys or state.get("schemaVersion") != "1.0":
        raise ExecutionError("live state witness keys are invalid")
    launch_environment = sidecar.deterministic_seed["launchEnvironment"]
    seed_theme_id = launch_environment.get("RUNESCRIBE_QUALIFICATION_THEME_ID")
    seed_codex_id = launch_environment.get("RUNESCRIBE_QUALIFICATION_CODEX_ID")
    seed_surface = launch_environment.get("RUNESCRIBE_QUALIFICATION_SURFACE")
    seed_appearance = launch_environment.get("RUNESCRIBE_QUALIFICATION_APPEARANCE")
    seed_message_profile = launch_environment.get(
        "RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE"
    )
    seed_vault_state = launch_environment.get("RUNESCRIBE_QUALIFICATION_VAULT_STATE")
    identity_truth = (
        state.get("surface") == entry.get("surface") == seed_surface
        and state.get("destination") == entry.get("destination")
        and state.get("themeID") == entry.get("themeID") == seed_theme_id
        and state.get("codexID") == entry.get("codexID") == seed_codex_id
        and state.get("activeThemeID") == entry.get("themeID")
        and state.get("effectiveCodexID") == entry.get("codexID")
        and state.get("appearance") == seed_appearance
        and state.get("messageProfile") == seed_message_profile
        and state.get("vaultState") == seed_vault_state
    )
    surface = str(entry.get("surface"))
    codex_id = str(entry.get("codexID"))
    truthful = identity_truth
    if surface == "high-contrast":
        plan = _parse_witness_json(sidecar, DIAGNOSTIC_PLAN_INTERACTIVE)
        truthful = truthful and (
            state.get("appearance") == "high-contrast"
            and plan.get("colorMode") == "high-contrast"
            and plan.get("backgroundResourceID")
            == state.get("highContrastBackgroundResourceID")
        )
    elif surface == "received-cipher":
        truthful = truthful and (
            state.get("safePreviewStatus") == "valid"
            and isinstance(state.get("safePreviewByteCount"), int)
            and not isinstance(state.get("safePreviewByteCount"), bool)
            and state["safePreviewByteCount"] > 0
            and _witness(sidecar, "received.safe-preview").get("matchCount") == 1
        )
    elif surface == "settings-codex-card":
        truthful = truthful and (
            state.get("providerState") == "available"
            and state.get("providerIsOwned") is True
            and state.get("providerIsSelectable") is True
            and state.get("providerIsSelected") is True
            and state.get("renderedVaultState") is None
            and state.get("showsSelectedArtifacts") is True
        )
    elif surface.startswith("vault-"):
        expected_state = surface.removeprefix("vault-")
        truthful = truthful and state.get("vaultState") == expected_state
        if surface == "vault-progress":
            if codex_id == "codex.norse":
                truthful = truthful and (
                    state.get("providerIsOwned") is True
                    and state.get("renderedVaultState") == "owned"
                    and state.get("showsSelectedArtifacts") is False
                    and state.get("progressCurrent") == 1
                    and state.get("progressTarget") == 1
                    and _witness(sidecar, "theme.vault.codex.norse.owned").get(
                        "matchCount"
                    ) == 1
                )
            else:
                truthful = truthful and (
                    state.get("progressCurrent") == 3
                    and state.get("progressTarget") == 5
                    and state.get("renderedVaultState") == "progress"
                    and state.get("showsSelectedArtifacts") is False
                    and _witness(
                        sidecar, f"progression.journey.{codex_id}.progress"
                    ).get("matchCount") == 1
                )
            truthful = truthful and _witness(
                sidecar, f"progression.journey.{codex_id}.requirement-count"
            ).get("matchCount") == 1
        else:
            provider = _witness(sidecar, f"theme.vault.{codex_id}.provider-state")
            ownership = _witness(sidecar, f"theme.vault.{codex_id}.ownership-state")
            truthful = truthful and (
                provider.get("matchCount") == 1
                and ownership.get("matchCount") == 1
            )
            if codex_id == "codex.norse" and expected_state == "locked":
                truthful = truthful and (
                    state.get("providerIsOwned") is True
                    and state.get("renderedVaultState") in {"owned", "selected"}
                )
            elif codex_id == "codex.norse" and expected_state == "encountered":
                card = _witness(sidecar, "theme.vault.codex.norse.selected")
                artifact_id = f"theme.vault-artifact.{NORSE_ENCOUNTERED_ARTIFACT_ID}"
                artifact = _witness(sidecar, artifact_id)
                truthful = truthful and (
                    state.get("providerState") == "available"
                    and state.get("providerIsOwned") is True
                    and state.get("providerIsSelectable") is False
                    and state.get("providerIsSelected") is True
                    and state.get("renderedVaultState") == "selected"
                    and state.get("showsSelectedArtifacts") is False
                    and state.get("focusedArtifactID")
                    == NORSE_ENCOUNTERED_ARTIFACT_ID
                    and state.get("focusedArtifactState") == "encountered"
                    and state.get("focusedArtifactIsOwned") is False
                    and state.get("focusedArtifactIsSelectable") is False
                    and provider.get("label") == "Provider available"
                    and ownership.get("label") == "Owned and selected"
                    and card.get("value") == "Selected"
                    and artifact.get("value", "").split(", ")[:2]
                    == ["Relic", "Encountered"]
                    and artifact.get("isHittable") is False
                )
            else:
                expected = {
                    "locked": {
                        "providerState": "available",
                        "providerIsOwned": False,
                        "providerIsSelectable": False,
                        "providerIsSelected": False,
                        "showsSelectedArtifacts": False,
                        "providerLabel": "Provider available",
                        "ownershipLabel": "Not owned",
                    },
                    "encountered": {
                        "providerState": "unavailable",
                        "providerIsOwned": False,
                        "providerIsSelectable": False,
                        "providerIsSelected": False,
                        "showsSelectedArtifacts": False,
                        "providerLabel": (
                            "Provider unavailable; safe presentation in use"
                        ),
                        "ownershipLabel": "Not owned",
                    },
                    "owned": {
                        "providerState": "available",
                        "providerIsOwned": True,
                        "providerIsSelectable": True,
                        "providerIsSelected": False,
                        "showsSelectedArtifacts": False,
                        "providerLabel": "Provider available",
                        "ownershipLabel": "Owned",
                    },
                    "selected": {
                        "providerState": "available",
                        "providerIsOwned": True,
                        "providerIsSelectable": False,
                        "providerIsSelected": True,
                        "showsSelectedArtifacts": True,
                        "providerLabel": "Provider available",
                        "ownershipLabel": "Owned and selected",
                    },
                }.get(expected_state)
                if expected is None:
                    raise ExecutionError(f"unsupported live vault state: {expected_state}")
                card = _witness(
                    sidecar, f"theme.vault.{codex_id}.{expected_state}"
                )
                truthful = truthful and (
                    all(state.get(key) == expected[key] for key in (
                        "providerState",
                        "providerIsOwned",
                        "providerIsSelectable",
                        "providerIsSelected",
                        "showsSelectedArtifacts",
                    ))
                    and state.get("renderedVaultState") == expected_state
                    and provider.get("label") == expected["providerLabel"]
                    and ownership.get("label") == expected["ownershipLabel"]
                    and card.get("matchCount") == 1
                    and card.get("value") == expected_state.capitalize()
                )
    return truthful, state


def evaluate_live_structural_assertion(
    assertion_id: str,
    candidate_ids: Sequence[str],
    sidecar: ValidatedSidecar,
    entry: Mapping[str, Any],
    assertion_catalog: Mapping[str, Mapping[str, Any]],
    candidate_catalog: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    specification = assertion_catalog.get(assertion_id)
    if not isinstance(specification, dict):
        raise ExecutionError(f"structural assertion is absent from catalog: {assertion_id}")
    items = _live_query_items(sidecar, candidate_ids) if candidate_ids else []
    observed: Any
    details: dict[str, Any]
    passed = False

    if assertion_id == "assert.element.exists":
        present = [
            identifier for identifier, item in zip(candidate_ids, items)
            if item.get("matchCount") == 1
        ]
        observed = len(present) == len(candidate_ids) and bool(candidate_ids)
        details = {"requiredElementIDs": list(candidate_ids), "presentElementIDs": present}
        passed = observed is True
    elif assertion_id == "assert.element.visible":
        visible = [
            identifier for identifier, item in zip(candidate_ids, items)
            if _live_element_visible(item, identifier)
        ]
        observed = len(visible) == len(candidate_ids) and bool(candidate_ids)
        details = {"requiredElementIDs": list(candidate_ids), "visibleElementIDs": visible}
        passed = observed is True
    elif assertion_id == "assert.element.viewport-contained":
        contained = [
            identifier for identifier, item in zip(candidate_ids, items)
            if _live_element_contained(item, identifier)
        ]
        observed = len(contained) == len(candidate_ids) and bool(candidate_ids)
        details = {
            "requiredElementIDs": list(candidate_ids),
            "containedElementIDs": contained,
            "tolerancePoints": 1,
        }
        passed = observed is True
    elif assertion_id == "assert.no-horizontal-overflow":
        overflowing = [
            identifier for identifier, item in zip(candidate_ids, items)
            if not _live_element_contained(item, identifier, horizontal_only=True)
        ]
        observed = bool(overflowing)
        details = {"overflowingElementIDs": overflowing}
        passed = observed is False
    elif assertion_id == "assert.mobile-hit-targets":
        control_ids = MOBILE_HIT_TARGET_IDS.get(str(entry.get("surface")), [])
        controls = [_witness(sidecar, identifier) for identifier in control_ids]
        minimum = min(
            min(
                _live_rect(item, "elementFrame", identifier)["width"],
                _live_rect(item, "elementFrame", identifier)["height"],
            )
            for identifier, item in zip(control_ids, controls)
        )
        actionable = [
            identifier for identifier, item in zip(control_ids, controls)
            if item.get("isEnabled") is True and item.get("isHittable") is True
        ]
        observed = minimum
        details = {
            "requiredControlIDs": control_ids,
            "minimumMeasuredPoints": minimum,
            "enabledAndHittableControlIDs": actionable,
        }
        passed = (
            minimum >= specification.get("expectedMinimumPoints")
            and actionable == control_ids
        )
    elif assertion_id in {"assert.no-placeholder-art", "assert.no-system-symbol-artifact"}:
        required, resolved, picker = _resource_sets(sidecar)
        query_id = (
            "query:missing-resource"
            if assertion_id == "assert.no-placeholder-art"
            else "query:missing-picker-artwork"
        )
        query = sidecar.structural_witnesses.get(query_id)
        if query is None:
            raise ExecutionError(f"live zero-fallback query is missing: {query_id}")
        unresolved = (required if assertion_id == "assert.no-placeholder-art" else picker) - resolved
        observed = len(unresolved) + int(query.get("matchCount", -1))
        details = {
            "requiredResourceIDs": sorted(required),
            "resolvedResourceIDs": sorted(resolved),
            "pickerArtworkResourceIDs": sorted(picker),
            "unresolvedResourceIDs": sorted(unresolved),
            "fallbackQueryCount": query.get("matchCount"),
        }
        passed = observed == 0
    elif assertion_id == "assert.safe-region-no-overlap":
        plan = _parse_witness_json(sidecar, DIAGNOSTIC_PLAN_INTERACTIVE)
        region = plan.get("glyphSafeRegion")
        anchor = plan.get("sealAnchor")
        if not isinstance(region, dict) or set(region) != {"x", "y", "width", "height"}:
            raise ExecutionError("live composition plan glyph safe region is invalid")
        values = [region.get(key) for key in ("x", "y", "width", "height")]
        if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in values):
            raise ExecutionError("live composition plan glyph safe region values are invalid")
        if anchor is None:
            overlaps = False
        else:
            if not isinstance(anchor, dict) or set(anchor) != {"x", "y"}:
                raise ExecutionError("live composition plan seal anchor is invalid")
            x, y = anchor.get("x"), anchor.get("y")
            if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in (x, y)):
                raise ExecutionError("live composition plan seal anchor values are invalid")
            overlaps = (
                region["x"] <= x <= region["x"] + region["width"]
                and region["y"] <= y <= region["y"] + region["height"]
            )
        observed = overlaps
        details = {"glyphSafeRegion": region, "sealAnchor": anchor}
        passed = observed is False
    elif assertion_id == "assert.state-text-shape-truthful":
        passed, state = _live_state_truth(entry, sidecar)
        observed = passed
        details = state
    elif assertion_id == "assert.interactive-static-plan-parity":
        interactive = _parse_witness_json(sidecar, DIAGNOSTIC_PLAN_INTERACTIVE)
        static = _parse_witness_json(sidecar, DIAGNOSTIC_PLAN_STATIC)
        observed = interactive == static
        details = {
            "interactivePlanSHA256": canonical_json_sha256(interactive),
            "staticPlanSHA256": canonical_json_sha256(static),
        }
        passed = observed is True
    elif assertion_id in {"assert.all-three-relics-present", "assert.all-six-seals-present"}:
        kind = "relic" if assertion_id == "assert.all-three-relics-present" else "seal"
        theme_component = str(entry.get("codexID")).removeprefix("codex.")
        prefix = f"theme.artifact-picker.{kind}.{theme_component}."
        expected_ids = sorted(identifier for identifier in candidate_catalog if identifier.startswith(prefix))
        present = [
            identifier
            for identifier in expected_ids
            if _witness(sidecar, identifier).get("matchCount") == 1
        ]
        set_query_id = f"query:{kind}-picker-set"
        set_query = sidecar.structural_witnesses.get(set_query_id)
        if set_query is None:
            raise ExecutionError(f"live exact picker-set query is missing: {set_query_id}")
        observed = sorted(present)
        details = {
            "expectedCandidateIDs": expected_ids,
            "observedCandidateIDs": observed,
            "prefixQueryCount": set_query.get("matchCount"),
        }
        passed = (
            len(expected_ids) == specification.get("expectedCount")
            and observed == expected_ids
            and set_query.get("matchCount") == len(expected_ids)
        )
    elif assertion_id == "assert.mastery-frame-crest-title-present":
        theme_component = str(entry.get("codexID")).removeprefix("codex.")
        component_ids = sorted(
            identifier for identifier in candidate_catalog
            if identifier.startswith(f"theme.mastery.frame.frame.{theme_component}.")
            or identifier.startswith(f"theme.mastery.crest.crest.{theme_component}.")
        )
        title_id = MASTERY_TITLE_BY_CODEX.get(str(entry.get("codexID")))
        if title_id is None:
            raise ExecutionError("mastery title witness is undeclared")
        component_ids.append(f"theme.mastery.title.{title_id}")
        component_ids.sort()
        observed = sorted(
            identifier
            for identifier in component_ids
            if _witness(sidecar, identifier).get("matchCount") == 1
        )
        aggregate_counts = {
            kind: sidecar.structural_witnesses.get(f"query:mastery-{kind}-set", {}).get(
                "matchCount"
            )
            for kind in ("frame", "crest", "title")
        }
        details = {
            "expectedComponentIDs": component_ids,
            "observedComponentIDs": observed,
            "prefixQueryCounts": aggregate_counts,
        }
        passed = (
            len(component_ids) == specification.get("expectedCount")
            and observed == component_ids
            and aggregate_counts == {"frame": 1, "crest": 1, "title": 1}
        )
    elif assertion_id == "assert.large-text-required-controls-visible":
        control_ids = LARGE_TEXT_CONTROL_IDS.get(str(entry.get("destination")), [])
        visible = [
            identifier for identifier in control_ids
            if _live_element_visible(_witness(sidecar, identifier), identifier)
            and _live_element_contained(_witness(sidecar, identifier), identifier)
        ]
        state = _parse_witness_json(sidecar, DIAGNOSTIC_STATE)
        dynamic_type = _witness(sidecar, DIAGNOSTIC_DYNAMIC_TYPE).get("value")
        observed = (
            visible == control_ids
            and state.get("appearance") == "accessibility-xxxl"
            and state.get("messageProfile") == "short-two-lines"
            and dynamic_type == "accessibility5"
        )
        details = {
            "requiredControlIDs": control_ids,
            "visibleContainedControlIDs": visible,
            "appearance": state.get("appearance"),
            "messageProfile": state.get("messageProfile"),
            "dynamicTypeSize": dynamic_type,
        }
        passed = observed is True
    else:
        raise ExecutionError(f"unsupported live structural assertion: {assertion_id}")

    return {
        "assertionID": assertion_id,
        "source": "xcui-sidecar-raw-query",
        "operator": specification.get("operator"),
        "expected": {key: value for key, value in specification.items() if key != "operator"},
        "observed": observed,
        "details": details,
        "result": "PASS" if passed else "FAIL",
    }


def evaluate_structural_assertion(
    assertion_id: str,
    candidate_ids: Sequence[str],
    frames: Mapping[str, Mapping[str, float]],
    record: Mapping[str, Any],
    assertion_catalog: Mapping[str, Mapping[str, Any]],
    sidecar: ValidatedSidecar | None = None,
    entry: Mapping[str, Any] | None = None,
    candidate_catalog: Mapping[str, Mapping[str, Any]] | None = None,
) -> dict[str, Any]:
    if sidecar is not None:
        if entry is None or candidate_catalog is None:
            raise ExecutionError("live structural evaluation context is incomplete")
        return evaluate_live_structural_assertion(
            assertion_id,
            candidate_ids,
            sidecar,
            entry,
            assertion_catalog,
            candidate_catalog,
        )
    derived = derive_bounds_assertion(assertion_id, candidate_ids, frames, record)
    if derived is not None:
        passed, observed, source = derived
        return {
            "assertionID": assertion_id,
            "source": source,
            "observed": observed,
            "result": "PASS" if passed else "FAIL",
        }
    observations = record.get("structuralAssertionObservations")
    observation = observations.get(assertion_id) if isinstance(observations, dict) else None
    if not isinstance(observation, dict) or "observed" not in observation:
        return {
            "assertionID": assertion_id,
            "source": None,
            "observed": None,
            "result": "FAIL",
            "failure": "missing recomputable structural observation",
        }
    source = observation.get("source")
    if not isinstance(source, str) or not source:
        return {
            "assertionID": assertion_id,
            "source": source,
            "observed": observation.get("observed"),
            "result": "FAIL",
            "failure": "structural observation source is missing",
        }
    observed = observation["observed"]
    specification = assertion_catalog.get(assertion_id)
    if not isinstance(specification, dict):
        return {
            "assertionID": assertion_id,
            "source": source,
            "observed": observed,
            "result": "FAIL",
            "failure": "structural assertion is absent from the authority catalog",
        }
    operator = specification.get("operator")
    if operator in {
        "exists", "visible", "viewport-contained", "state-text-shape-consistency",
        "composition-plan-equality", "required-controls-visible",
    }:
        passed = observed is True and specification.get("expected") is True
    elif operator in {"horizontal-overflow", "artifact-safe-region-overlap"}:
        passed = observed is False and specification.get("expected") is False
    elif operator == "minimum-hit-target":
        passed = (
            isinstance(observed, (int, float))
            and not isinstance(observed, bool)
            and observed >= specification.get("expectedMinimumPoints")
        )
    elif operator in {"placeholder-resource-count", "system-symbol-artifact-count"}:
        passed = (
            isinstance(observed, int)
            and not isinstance(observed, bool)
            and observed == specification.get("expected")
        )
    elif operator in {"relic-id-set-exact", "seal-id-set-exact", "mastery-component-set-exact"}:
        passed = (
            isinstance(observed, list)
            and all(isinstance(item, str) and item for item in observed)
            and observed == sorted(set(observed))
            and len(observed) == specification.get("expectedCount")
        )
    else:
        passed = False
    return {
        "assertionID": assertion_id,
        "source": source,
        "observed": observed,
        "details": observation.get("details"),
        "operator": operator,
        "expected": {
            key: value for key, value in specification.items() if key != "operator"
        },
        "result": "PASS" if passed else "FAIL",
    }


@dataclass(frozen=True)
class CandidateSource:
    identifier: str
    source_kind: str
    image: Image.Image | None
    provenance: dict[str, Any]


@dataclass(frozen=True)
class ExecutionContext:
    root: Path
    authority_root: Path
    capture_root: Path
    output_root: Path
    source_sha: str
    authority_sha: str
    asset_manifest_sha: str
    command: list[str]
    toolchain: dict[str, Any]
    started_at: str

    def metadata(self, destination: str) -> dict[str, Any]:
        return {
            "sourceSHA": self.source_sha,
            "comparisonAuthoritySHA256": self.authority_sha,
            "authorityAssetManifestSHA256": self.asset_manifest_sha,
            "command": self.command,
            "startTimestamp": self.started_at,
            "destination": destination,
            "toolchain": self.toolchain,
        }


class AuthorityExecutor:
    def __init__(
        self,
        root: Path,
        capture_root: Path,
        output_root: Path,
        source_sha: str,
        command: Sequence[str],
        toolchain: Mapping[str, Any],
    ) -> None:
        self.root = root.resolve()
        self.capture_root = capture_root.resolve()
        self.output_root = output_root.resolve()
        self.authority_path = (self.root / AUTHORITY_RELATIVE).resolve()
        self.asset_manifest_path = (self.root / ASSET_MANIFEST_RELATIVE).resolve()
        self.candidate_catalog_path = (self.root / CANDIDATE_CATALOG_RELATIVE).resolve()
        self.probe_catalog_path = (self.root / PROBE_CATALOG_RELATIVE).resolve()
        self.seed_catalog_path = (self.root / SEED_CATALOG_RELATIVE).resolve()
        self.authority_root = (self.root / AUTHORITY_ROOT_RELATIVE).resolve()
        if is_within(self.output_root, self.authority_root):
            raise ExecutionError("evidence output cannot be written inside immutable authority")
        if not SOURCE_SHA_PATTERN.fullmatch(source_sha):
            raise ExecutionError("source SHA must be a full lowercase Git SHA")
        self.authority = load_json(self.authority_path, "comparison authority")
        self.asset_manifest = load_json(self.asset_manifest_path, "authority asset manifest")
        self.candidate_catalog = load_json(self.candidate_catalog_path, "candidate catalog")
        self.probe_catalog = load_json(self.probe_catalog_path, "runtime probe catalog")
        self.seed_catalog = load_json(self.seed_catalog_path, "seed catalog")
        self.context = ExecutionContext(
            root=self.root,
            authority_root=self.authority_root,
            capture_root=self.capture_root,
            output_root=self.output_root,
            source_sha=source_sha,
            authority_sha=sha256_file(self.authority_path),
            asset_manifest_sha=sha256_file(self.asset_manifest_path),
            command=list(command),
            toolchain=dict(toolchain),
            started_at=utc_timestamp(),
        )
        self.probes = self._index_catalog(self.probe_catalog, "probes", "id")
        self.candidates = self._index_catalog(self.candidate_catalog, "candidates", "id")
        self.seeds = self._index_catalog(self.seed_catalog, "seeds", "id")

    @staticmethod
    def _index_catalog(document: Mapping[str, Any], key: str, id_key: str) -> dict[str, dict[str, Any]]:
        items = document.get(key)
        if not isinstance(items, list):
            raise ExecutionError(f"catalog {key} must be an array")
        indexed: dict[str, dict[str, Any]] = {}
        for item in items:
            if not isinstance(item, dict):
                raise ExecutionError(f"catalog {key} contains an invalid item")
            identifier = item.get(id_key)
            if not isinstance(identifier, str) or not identifier or identifier in indexed:
                raise ExecutionError(f"catalog {key} IDs must be non-empty and unique")
            indexed[identifier] = item
        return indexed

    def validate_authority_shape(self) -> None:
        if self.authority.get("schemaVersion") != SCHEMA_VERSION:
            raise ExecutionError("comparison authority schemaVersion must be 1.2")
        entries = self.authority.get("entries")
        if not isinstance(entries, list) or len(entries) != EXPECTED_ENTRY_COUNT:
            raise ExecutionError("comparison authority must contain exactly 400 entries")
        mapping_count = sum(
            len(entry.get("referenceMappings", []))
            for entry in entries if isinstance(entry, dict)
        )
        if mapping_count != EXPECTED_MAPPING_COUNT:
            raise ExecutionError("comparison authority must contain exactly 1104 mappings")
        if self.authority.get("expectedReferenceMappingCount") != EXPECTED_MAPPING_COUNT:
            raise ExecutionError("comparison authority mapping declaration is invalid")
        validate_direct_screen_mask_contract(self.authority)

    def capture_paths(self, entry: Mapping[str, Any]) -> tuple[Path, Path]:
        theme = entry.get("theme")
        surface = entry.get("surface")
        destination = entry.get("destination")
        if not all(isinstance(value, str) and value for value in (theme, surface, destination)):
            raise ExecutionError("authority entry identity is invalid")
        stem = f"{theme.lower()}--{surface}--{destination}"
        return self.capture_root / f"{stem}.png", self.capture_root / f"{stem}.capture.json"

    def load_bound_capture(
        self, entry: Mapping[str, Any]
    ) -> tuple[
        Path,
        Image.Image,
        Path,
        dict[str, Any],
        dict[str, dict[str, float]],
        ValidatedSidecar | None,
    ]:
        png_path, record_path = self.capture_paths(entry)
        image = load_rgba(png_path, "candidate capture")
        record = load_json(record_path, "candidate capture record")
        expected = {
            "themeName": entry["theme"],
            "themeID": entry["themeID"],
            "codexID": entry["codexID"],
            "surface": entry["surface"],
            "destination": DESTINATION_DISPLAY_NAMES[entry["destination"]],
        }
        for key, value in expected.items():
            if record.get(key) != value:
                raise ExecutionError(
                    f"capture record {key} does not match {entry['id']}: "
                    f"{record.get(key)!r} != {value!r}"
                )
        if record.get("pngSHA256") != sha256_file(png_path):
            raise ExecutionError(f"capture PNG hash binding failed: {entry['id']}")
        if [record.get("pixelWidth"), record.get("pixelHeight")] != [image.width, image.height]:
            raise ExecutionError(f"capture dimensions binding failed: {entry['id']}")
        seed_id = entry.get("seedID")
        expected_seed = self.seeds.get(seed_id) if isinstance(seed_id, str) else None
        if expected_seed is None:
            raise ExecutionError(f"entry uses an undeclared deterministic seed: {entry['id']}")
        sidecar: ValidatedSidecar | None = None
        try:
            requires_xcui = bool(
                candidate_ids_for_entry(entry)
                or xcui_probe_ids_for_entry(entry, self.probes)
            )
            if requires_xcui:
                sidecar = validate_sidecar(
                    self.capture_root / sidecar_name(entry),
                    entry,
                    self.probes,
                    self.seeds,
                    self.candidates,
                    self.capture_root,
                )
                if sidecar.deterministic_seed != expected_seed:
                    raise ExecutionError(
                        f"XCUI sidecar deterministic seed differs from catalog: {entry['id']}"
                    )
        except XCUIEvidenceError as error:
            raise ExecutionError(str(error)) from error
        return png_path, image, record_path, record, frame_index(record), sidecar

    def candidate_source(
        self,
        mapping: Mapping[str, Any],
        capture_path: Path,
        capture: Image.Image,
        record: Mapping[str, Any],
        frames: Mapping[str, Mapping[str, float]],
        sidecar: ValidatedSidecar | None,
    ) -> CandidateSource:
        keys = [key for key in SOURCE_KEYS if key in mapping]
        if len(keys) != 1:
            raise ExecutionError(f"mapping must have exactly one candidate source: {mapping.get('mappingID')}")
        key = keys[0]
        identifier = mapping[key]
        if not isinstance(identifier, str) or not identifier:
            raise ExecutionError(f"mapping candidate source is invalid: {mapping.get('mappingID')}")
        if key == PROBE_SOURCE_KEY:
            if identifier not in self.probes:
                raise ExecutionError(f"mapping candidate probe is undeclared: {identifier}")
            return CandidateSource(identifier, "runtime-probe", None, {"probeID": identifier})
        if identifier not in self.candidates:
            raise ExecutionError(f"mapping candidate ID is undeclared: {identifier}")
        declared_operation = self.candidates[identifier].get("captureOperation")
        if mapping.get("candidateCaptureOperation") != declared_operation:
            raise ExecutionError(f"mapping capture operation drifted for {identifier}")
        if key == ELEMENT_SOURCE_KEY:
            if declared_operation != XCUI_OPERATION:
                raise ExecutionError(
                    f"element candidate is not declared as an XCUI screenshot: {identifier}"
                )
            if sidecar is None:
                raise ExecutionError(
                    f"independent XCUI evidence sidecar is missing: {identifier}"
                )
            item = sidecar.candidate_captures.get(identifier)
            if item is None:
                raise ExecutionError(
                    f"exact XCUI candidate attachment is absent: {identifier}"
                )
            try:
                candidate_path = resolve_xcui_attachment(
                    self.capture_root,
                    item.get("attachmentName"),
                    f"candidate element {identifier}",
                )
            except XCUIEvidenceError as error:
                raise ExecutionError(str(error)) from error
            candidate_image = load_rgba(candidate_path, "XCUI candidate element screenshot")
            if sha256_file(candidate_path) != item["sha256"]:
                raise ExecutionError(
                    f"XCUI candidate attachment hash changed before use: {identifier}"
                )
            if candidate_path.stat().st_size != item["byteCount"]:
                raise ExecutionError(
                    f"XCUI candidate attachment byte count changed before use: {identifier}"
                )
            if candidate_image.size != (item["pixelWidth"], item["pixelHeight"]):
                raise ExecutionError(
                    f"XCUI candidate attachment dimensions changed before use: {identifier}"
                )
            return CandidateSource(
                identifier,
                XCUI_OPERATION,
                candidate_image,
                {
                    "attachment": str(candidate_path),
                    "attachmentSHA256": item["sha256"],
                    "byteCount": item["byteCount"],
                    "pixelWidth": item["pixelWidth"],
                    "pixelHeight": item["pixelHeight"],
                    "declaredOperation": item["declaredOperation"],
                    "actualOperation": item["actualOperation"],
                    "xcuiSidecar": str(sidecar.path),
                    "xcuiSidecarSHA256": sidecar.sha256,
                    "sourceTest": sidecar.source_test,
                    "queryPredicate": item["queryPredicate"],
                    "matchCount": item["matchCount"],
                    "elementIdentifier": item["elementIdentifier"],
                    "coordinateOrigin": item["coordinateOrigin"],
                    "coordinateUnits": item["coordinateUnits"],
                    "elementFrame": item["elementFrame"],
                    "windowFrame": item["windowFrame"],
                    "label": item["label"],
                    "value": item["value"],
                    "isEnabled": item["isEnabled"],
                    "isHittable": item["isHittable"],
                    "manualCoordinatesUsed": False,
                },
            )
        renderer_outputs = observation_index(record, "rendererOutputs", "outputID")
        output = renderer_outputs.get(identifier)
        if output is None:
            raise ExecutionError(f"exact renderer output is absent: {identifier}")
        if output.get("usesPrimaryCapture") is True:
            renderer_path = capture_path
            renderer_image = capture.copy()
        else:
            renderer_path = resolve_within(
                self.capture_root, output.get("attachmentName"), "renderer attachment"
            )
            renderer_image = load_rgba(renderer_path, "renderer output")
        expected_hash = output.get("sha256")
        if not isinstance(expected_hash, str) or expected_hash != sha256_file(renderer_path):
            raise ExecutionError(f"renderer output hash binding failed: {identifier}")
        return CandidateSource(
            identifier,
            "deterministic-renderer-output",
            renderer_image,
            {
                "rendererOutput": str(renderer_path),
                "rendererOutputSHA256": expected_hash,
                "captureOperation": declared_operation,
                "manualCoordinatesUsed": False,
            },
        )

    def evaluate_probe(
        self,
        probe_id: str,
        record: Mapping[str, Any],
        frames: Mapping[str, Mapping[str, float]],
        capture_path: Path,
        capture: Image.Image,
        destination: str,
        sidecar: ValidatedSidecar | None,
    ) -> dict[str, Any]:
        catalog = self.probes.get(probe_id)
        if catalog is None:
            raise ExecutionError(f"runtime probe is undeclared: {probe_id}")
        started = utc_timestamp()
        catalog_source = catalog.get("source")
        if isinstance(catalog_source, str) and catalog_source.startswith("xcui-"):
            failures: list[str] = []
            observed: Any = None
            details: dict[str, Any] = {}
            try:
                if sidecar is None:
                    raise ExecutionError(
                        "independent XCUI evidence sidecar is missing"
                    )
                evidence = sidecar.probe_evidence.get(probe_id)
                if evidence is None:
                    raise ExecutionError(
                        "exact independently bound XCUI probe evidence is missing"
                    )
                container = validate_xcui_rect(
                    evidence.get("containerFrame"),
                    f"{probe_id}.containerFrame",
                )
                element = validate_xcui_rect(
                    evidence.get("elementFrame"),
                    f"{probe_id}.elementFrame",
                    nullable=True,
                )
                if container is None:
                    raise ExecutionError("XCUI probe container frame is absent")
                observed = recompute_xcui_probe_observed(
                    probe_id, evidence, element, container
                )
                if not evaluate_operator(
                    str(catalog.get("operator")), observed, catalog.get("expected")
                ):
                    failures.append(
                        "independently bound XCUI probe does not satisfy the catalog"
                    )
                try:
                    attachment_path = resolve_xcui_attachment(
                        self.capture_root,
                        evidence.get("attachmentName"),
                        f"XCUI probe {probe_id}",
                    )
                except XCUIEvidenceError as error:
                    raise ExecutionError(str(error)) from error
                details = {
                    "xcuiSidecar": str(sidecar.path),
                    "xcuiSidecarSHA256": sidecar.sha256,
                    "sourceTest": sidecar.source_test,
                    "queryPredicate": evidence.get("queryPredicate"),
                    "matchCount": evidence.get("matchCount"),
                    "candidateID": evidence.get("candidateID"),
                    "attachment": str(attachment_path),
                    "attachmentSHA256": evidence.get("attachmentSHA256"),
                    "pixelWidth": evidence.get("pixelWidth"),
                    "pixelHeight": evidence.get("pixelHeight"),
                    "coordinateOrigin": evidence.get("coordinateOrigin"),
                    "coordinateUnits": evidence.get("coordinateUnits"),
                    "elementFrame": evidence.get("elementFrame"),
                    "containerFrame": evidence.get("containerFrame"),
                }
            except (ExecutionError, XCUIEvidenceError, OSError, ValueError) as error:
                failures.append(str(error))
            return {
                **self.context.metadata(destination),
                "probeID": probe_id,
                "source": catalog_source,
                "operator": catalog.get("operator"),
                "expected": catalog.get("expected"),
                "observed": observed,
                "observationDetails": details,
                "startTimestamp": started,
                "endTimestamp": utc_timestamp(),
                "result": "PASS" if not failures else "FAIL",
                "failures": failures,
            }
        if probe_id.startswith("probe.motion.frame-stability."):
            failures: list[str] = []
            details: dict[str, Any] = {}
            observed: Any = None
            try:
                stability = record.get("reduceMotionStability")
                if not isinstance(stability, dict):
                    raise ExecutionError("Reduce Motion stability evidence is missing")
                capture_b_path = resolve_within(
                    self.capture_root,
                    stability.get("captureBAttachmentName"),
                    "Reduce Motion capture B",
                )
                capture_b = load_rgba(capture_b_path, "Reduce Motion capture B")
                if capture_b.size != capture.size:
                    raise ExecutionError("Reduce Motion A/B dimensions differ")
                if stability.get("captureASHA256") != sha256_file(capture_path):
                    raise ExecutionError("Reduce Motion capture A hash binding failed")
                if stability.get("captureBSHA256") != sha256_file(capture_b_path):
                    raise ExecutionError("Reduce Motion capture B hash binding failed")
                timestamp_a = parse_iso_timestamp(
                    stability.get("captureATimestamp"), "Reduce Motion capture A timestamp"
                )
                timestamp_b = parse_iso_timestamp(
                    stability.get("captureBTimestamp"), "Reduce Motion capture B timestamp"
                )
                separation = (timestamp_b - timestamp_a).total_seconds()
                declared_separation = stability.get("separationSeconds")
                if (
                    isinstance(declared_separation, bool)
                    or not isinstance(declared_separation, (int, float))
                    or not math.isclose(
                        separation, float(declared_separation), abs_tol=0.01, rel_tol=0.0
                    )
                ):
                    raise ExecutionError("Reduce Motion separation binding failed")
                profile = self.authority.get("thresholdProfiles", {}).get(
                    "runtime-reduce-motion-v1", {}
                )
                minimum_separation = profile.get("minimumCaptureSeparationSeconds")
                if (
                    isinstance(minimum_separation, bool)
                    or not isinstance(minimum_separation, (int, float))
                    or separation < float(minimum_separation)
                ):
                    failures.append("Reduce Motion captures are not separated by 1.5 seconds")
                preview = record.get("runtimeDiagnostics", {}).get("preview", {})
                element_id = preview.get("elementID")
                frame = frames.get(element_id) if isinstance(element_id, str) else None
                if frame is None:
                    raise ExecutionError("Reduce Motion preview frame is missing")
                box = integral_crop(frame, capture.size)
                capture_a_region = capture.crop(box)
                capture_b_region = capture_b.crop(box)
                pixels_a, pixels_b, normalization, metric_mask = normalize_pair(
                    capture_a_region,
                    capture_b_region,
                    "focal-complete-image-aspect-fit-v1",
                )
                metrics, luminance_map, delta_e = comparison_metrics(
                    pixels_a, pixels_b, metric_mask
                )
                observed = metrics["luminanceSSIM"]
                declared_ssim = stability.get("luminanceSSIM")
                if (
                    isinstance(declared_ssim, bool)
                    or not isinstance(declared_ssim, (int, float))
                    or not math.isclose(observed, float(declared_ssim), abs_tol=1e-6, rel_tol=0.0)
                ):
                    failures.append("Reduce Motion recorded SSIM does not match recomputation")
                if not evaluate_operator(
                    str(catalog.get("operator")), observed, catalog.get("expected")
                ):
                    failures.append("Reduce Motion frame stability is below the catalog threshold")
                relative = Path(str(record.get("themeName", "unknown")).lower()) / destination
                output_b = self.output_root / "reduce-motion" / relative / capture_b_path.name
                output_b.parent.mkdir(parents=True, exist_ok=True)
                try:
                    os.link(capture_b_path, output_b)
                except FileExistsError:
                    if sha256_file(output_b) != sha256_file(capture_b_path):
                        raise ExecutionError("Reduce Motion output collision")
                except OSError:
                    shutil.copy2(capture_b_path, output_b)
                heatmap_path = self.output_root / "reduce-motion" / relative / (
                    safe_stem(probe_id) + ".heatmap.png"
                )
                atomic_write_png(heatmap_path, heatmap_image(luminance_map, delta_e))
                details = {
                    "captureA": str(capture_path),
                    "captureASHA256": sha256_file(capture_path),
                    "captureB": str(output_b),
                    "captureBSHA256": sha256_file(output_b),
                    "captureATimestamp": stability.get("captureATimestamp"),
                    "captureBTimestamp": stability.get("captureBTimestamp"),
                    "separationSeconds": separation,
                    "elementID": element_id,
                    "pixelCrop": [box[0], box[1], box[2] - box[0], box[3] - box[1]],
                    "normalization": normalization,
                    "heatmap": str(heatmap_path),
                    "heatmapSHA256": sha256_file(heatmap_path),
                }
            except (ExecutionError, OSError, ValueError) as error:
                failures.append(str(error))
            return {
                **self.context.metadata(destination),
                "probeID": probe_id,
                "source": catalog.get("source"),
                "operator": catalog.get("operator"),
                "expected": catalog.get("expected"),
                "observed": observed,
                "observationDetails": details,
                "startTimestamp": started,
                "endTimestamp": utc_timestamp(),
                "result": "PASS" if not failures else "FAIL",
                "failures": failures,
            }
        observations = observation_index(record, "runtimeProbeObservations", "probeID")
        observation = observations.get(probe_id)
        if observation is None:
            return {
                **self.context.metadata(destination),
                "probeID": probe_id,
                "source": catalog.get("source"),
                "operator": catalog.get("operator"),
                "expected": catalog.get("expected"),
                "observed": None,
                "startTimestamp": started,
                "endTimestamp": utc_timestamp(),
                "result": "FAIL",
                "failures": ["exact runtime probe observation is missing"],
            }
        recomputed = recomputed_probe_observed(probe_id, record, frames)
        if recomputed is _MISSING:
            passed = False
            failure = "runtime probe value cannot be recomputed from bound diagnostics"
        elif type(observation.get("observed")) is not type(recomputed) or observation.get("observed") != recomputed:
            passed = False
            failure = "runtime probe observation differs from recomputed diagnostics"
        elif observation.get("source") != catalog.get("source"):
            passed = False
            failure = "runtime probe source differs from the catalog"
        else:
            passed = evaluate_operator(
                str(catalog.get("operator")), recomputed, catalog.get("expected")
            )
            failure = None if passed else "runtime probe value does not satisfy the catalog"
        return {
            **self.context.metadata(destination),
            "probeID": probe_id,
            "source": catalog.get("source"),
            "operator": catalog.get("operator"),
            "expected": catalog.get("expected"),
            "observed": recomputed if recomputed is not _MISSING else None,
            "observationDetails": observation.get("details"),
            "startTimestamp": started,
            "endTimestamp": utc_timestamp(),
            "result": "PASS" if passed else "FAIL",
            "failures": [] if passed else [failure],
        }

    def reference_image(self, mapping: Mapping[str, Any]) -> tuple[Path, Image.Image]:
        path = resolve_within(
            self.authority_root, mapping.get("referenceAsset"), "reference asset"
        )
        expected_hash = mapping.get("referenceSHA256")
        if not isinstance(expected_hash, str) or not SHA256_PATTERN.fullmatch(expected_hash):
            raise ExecutionError(f"reference hash is invalid: {mapping.get('mappingID')}")
        if sha256_file(path) != expected_hash:
            raise ExecutionError(f"reference hash binding failed: {mapping.get('mappingID')}")
        image = load_rgba(path, "authority reference")
        if mapping.get("referenceDimensions") != [image.width, image.height]:
            raise ExecutionError(f"reference dimensions drifted: {mapping.get('mappingID')}")
        crop = mapping.get("sourceCrop")
        if crop != {
            "mode": "full-image",
            "normalizedRect": {"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0},
            "manualCoordinatesAllowed": False,
        }:
            raise ExecutionError(f"reference source crop is not full-image: {mapping.get('mappingID')}")
        return path, image

    def materialize_candidate(
        self, entry: Mapping[str, Any], mapping: Mapping[str, Any], source: CandidateSource
    ) -> tuple[Path, str]:
        if source.image is None:
            raise ExecutionError("runtime probe does not have a materialized image candidate")
        relative = Path(entry["theme"].lower()) / entry["surface"] / entry["destination"]
        path = self.output_root / "focal-captures" / relative / (
            safe_stem(str(mapping["mappingID"])) + ".candidate.png"
        )
        atomic_write_png(path, source.image)
        return path, sha256_file(path)

    def execute_mapping(
        self,
        entry: Mapping[str, Any],
        mapping: Mapping[str, Any],
        capture_path: Path,
        capture: Image.Image,
        record: Mapping[str, Any],
        frames: Mapping[str, Mapping[str, float]],
        sidecar: ValidatedSidecar | None,
        probe_results: Mapping[str, Mapping[str, Any]],
    ) -> dict[str, Any]:
        destination = str(entry["destination"])
        started = utc_timestamp()
        failures: list[str] = []
        output: dict[str, Any] = {
            **self.context.metadata(destination),
            "mappingID": mapping.get("mappingID"),
            "scoreDisposition": mapping.get("scoreDisposition"),
            "normalizationPolicy": mapping.get("normalizationPolicy"),
            "thresholdProfile": mapping.get("thresholdProfile"),
            "startTimestamp": started,
        }
        try:
            reference_path, reference = self.reference_image(mapping)
            source = self.candidate_source(
                mapping, capture_path, capture, record, frames, sidecar
            )
            output.update(
                {
                    "reference": str(reference_path),
                    "referenceSHA256": sha256_file(reference_path),
                    "referenceDimensions": [reference.width, reference.height],
                    "candidateID": source.identifier,
                    "candidateSourceKind": source.source_kind,
                    "candidateProvenance": source.provenance,
                }
            )
            disposition = mapping.get("scoreDisposition")
            if disposition == "negative-invariant":
                probe_result = probe_results.get(source.identifier)
                if probe_result is None or probe_result.get("result") != "PASS":
                    failures.append("mapped negative-invariant probe failed")
                output["probeResult"] = probe_result
            elif disposition in {"image-metric", "structural-assertion"}:
                candidate_path, candidate_hash = self.materialize_candidate(entry, mapping, source)
                output.update(
                    {
                        "candidate": str(candidate_path),
                        "candidateSHA256": candidate_hash,
                        "candidateDimensions": [source.image.width, source.image.height],
                    }
                )
                assertion_results = [
                    evaluate_structural_assertion(
                        assertion_id,
                        [source.identifier],
                        frames,
                        record,
                        self.authority.get("structuralAssertionCatalog", {}),
                        sidecar,
                        entry,
                        self.candidates,
                    )
                    for assertion_id in mapping.get("structuralAssertionIDs", [])
                ]
                output["structuralAssertionResults"] = assertion_results
                failures.extend(
                    f"structural assertion failed: {item['assertionID']}"
                    for item in assertion_results if item["result"] != "PASS"
                )
                if disposition == "image-metric":
                    policy = mapping.get("normalizationPolicy")
                    reference_pixels, candidate_pixels, normalization, metric_mask = normalize_pair(
                        reference,
                        source.image,
                        str(policy),
                        destination=destination,
                    )
                    metrics, luminance_map, delta_e = comparison_metrics(
                        reference_pixels, candidate_pixels, metric_mask
                    )
                    profiles = self.authority.get("thresholdProfiles")
                    profile = profiles.get(mapping.get("thresholdProfile")) if isinstance(profiles, dict) else None
                    if not isinstance(profile, dict):
                        raise ExecutionError("mapping threshold profile is undeclared")
                    checks = metric_checks(metrics, profile)
                    relative = Path(entry["theme"].lower()) / entry["surface"] / entry["destination"]
                    heatmap_path = self.output_root / "heatmaps" / relative / (
                        safe_stem(str(mapping["mappingID"])) + ".heatmap.png"
                    )
                    atomic_write_png(heatmap_path, heatmap_image(luminance_map, delta_e))
                    output.update(
                        {
                            "normalization": normalization,
                            "metrics": metrics,
                            "thresholds": profile,
                            "checks": checks,
                            "heatmap": str(heatmap_path),
                            "heatmapSHA256": sha256_file(heatmap_path),
                        }
                    )
                    failures.extend(
                        f"image metric failed: {name}" for name, passed in checks.items() if not passed
                    )
            else:
                raise ExecutionError(f"unsupported score disposition: {disposition}")
        except (ExecutionError, OSError, ValueError) as error:
            failures.append(str(error))
        output.update(
            {
                "endTimestamp": utc_timestamp(),
                "result": "PASS" if not failures else "FAIL",
                "failures": failures,
            }
        )
        return output

    def materialize_final_capture(self, entry: Mapping[str, Any], capture_path: Path) -> Path:
        target = self.output_root / "final" / capture_path.name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            target.unlink()
        try:
            os.link(capture_path, target)
        except OSError:
            shutil.copy2(capture_path, target)
        return target

    def execute_entry(self, entry: Mapping[str, Any]) -> dict[str, Any]:
        destination = str(entry.get("destination"))
        started = utc_timestamp()
        failures: list[str] = []
        mapping_results: list[dict[str, Any]] = []
        probe_results: list[dict[str, Any]] = []
        structural_results: list[dict[str, Any]] = []
        try:
            (
                capture_path,
                capture,
                record_path,
                record,
                frames,
                sidecar,
            ) = self.load_bound_capture(entry)
            final_capture = self.materialize_final_capture(entry, capture_path)
            probe_results = [
                self.evaluate_probe(
                    probe_id,
                    record,
                    frames,
                    capture_path,
                    capture,
                    destination,
                    sidecar,
                )
                for probe_id in entry.get("runtimeProbeIDs", [])
            ]
            probe_by_id = {result["probeID"]: result for result in probe_results}
            element_candidates = sorted(
                {
                    mapping[ELEMENT_SOURCE_KEY]
                    for mapping in entry.get("referenceMappings", [])
                    if ELEMENT_SOURCE_KEY in mapping
                }
            )
            structural_results = [
                evaluate_structural_assertion(
                    assertion_id,
                    element_candidates,
                    frames,
                    record,
                    self.authority.get("structuralAssertionCatalog", {}),
                    sidecar,
                    entry,
                    self.candidates,
                )
                for assertion_id in entry.get("entryStructuralAssertionIDs", [])
            ]
            mapping_results = [
                self.execute_mapping(
                    entry,
                    mapping,
                    capture_path,
                    capture,
                    record,
                    frames,
                    sidecar,
                    probe_by_id,
                )
                for mapping in entry.get("referenceMappings", [])
            ]
            relative = Path(entry["theme"].lower()) / entry["surface"] / destination
            for mapping_result in mapping_results:
                report_path = self.output_root / "comparisons" / relative / (
                    safe_stem(str(mapping_result["mappingID"])) + ".json"
                )
                atomic_write_json(report_path, mapping_result)
                mapping_result["report"] = str(report_path)
                mapping_result["reportSHA256"] = sha256_file(report_path)
            for probe_result in probe_results:
                report_path = self.output_root / "runtime-probes" / (
                    safe_stem(str(probe_result["probeID"]))
                ) / (safe_stem(str(entry["id"])) + ".json")
                atomic_write_json(report_path, probe_result)
                probe_result["report"] = str(report_path)
                probe_result["reportSHA256"] = sha256_file(report_path)
            layout_report = {
                **self.context.metadata(destination),
                "entryID": entry["id"],
                "startTimestamp": started,
                "endTimestamp": utc_timestamp(),
                "assertions": structural_results,
                "result": (
                    "PASS"
                    if all(item["result"] == "PASS" for item in structural_results)
                    else "FAIL"
                ),
                "failures": [
                    f"structural assertion failed: {item['assertionID']}"
                    for item in structural_results if item["result"] != "PASS"
                ],
            }
            layout_path = self.output_root / "responsive-layout" / relative / "assertions.json"
            atomic_write_json(layout_path, layout_report)
            layout_binding = {
                "path": str(layout_path),
                "sha256": sha256_file(layout_path),
            }
            failures.extend(
                f"runtime probe failed: {item['probeID']}"
                for item in probe_results if item["result"] != "PASS"
            )
            failures.extend(
                f"entry structural assertion failed: {item['assertionID']}"
                for item in structural_results if item["result"] != "PASS"
            )
            failures.extend(
                f"mapping failed: {item['mappingID']}"
                for item in mapping_results if item["result"] != "PASS"
            )
            capture_details: dict[str, Any] = {
                "path": str(final_capture),
                "sha256": sha256_file(final_capture),
                "record": str(record_path),
                "recordSHA256": sha256_file(record_path),
            }
            if sidecar is not None:
                capture_details["xcuiEvidence"] = {
                    "path": str(sidecar.path),
                    "sha256": sidecar.sha256,
                    "sourceTest": sidecar.source_test,
                    "candidateElementCaptureCount": len(
                        sidecar.candidate_captures
                    ),
                    "structuralWitnessCount": len(sidecar.structural_witnesses),
                    "xcuiProbeEvidenceCount": len(sidecar.probe_evidence),
                }
        except (ExecutionError, OSError, KeyError, ValueError) as error:
            failures.append(str(error))
            capture_details = {}
            layout_binding = {}
        return {
            **self.context.metadata(destination),
            "entryID": entry.get("id"),
            "theme": entry.get("theme"),
            "surface": entry.get("surface"),
            "destination": destination,
            "comparisonMode": entry.get("comparisonMode"),
            "startTimestamp": started,
            "endTimestamp": utc_timestamp(),
            "capture": capture_details,
            "responsiveLayout": layout_binding,
            "mappingResults": mapping_results,
            "structuralAssertionResults": structural_results,
            "runtimeProbeResults": probe_results,
            "result": "PASS" if not failures else "FAIL",
            "failures": failures,
        }

    def run(self) -> dict[str, Any]:
        self.validate_authority_shape()
        if not self.capture_root.is_dir():
            raise ExecutionError(f"capture root is missing: {self.capture_root}")
        if self.output_root.exists() and any(self.output_root.iterdir()):
            raise ExecutionError(f"evidence output root must be empty: {self.output_root}")
        self.output_root.mkdir(parents=True, exist_ok=True)
        entries = [self.execute_entry(entry) for entry in self.authority["entries"]]
        mapping_count = sum(len(entry["mappingResults"]) for entry in entries)
        passing_entries = sum(entry["result"] == "PASS" for entry in entries)
        passing_mappings = sum(
            mapping["result"] == "PASS"
            for entry in entries for mapping in entry["mappingResults"]
        )
        unique_probe_results: dict[tuple[str, str], str] = {}
        for entry in entries:
            for probe in entry["runtimeProbeResults"]:
                unique_probe_results[(entry["entryID"], probe["probeID"])] = probe["result"]
        finished = utc_timestamp()
        failures: list[str] = []
        if len(entries) != EXPECTED_ENTRY_COUNT:
            failures.append("evidence entry count is not 400")
        if mapping_count != EXPECTED_MAPPING_COUNT:
            failures.append("evidence mapping count is not 1104")
        if passing_entries != EXPECTED_ENTRY_COUNT:
            failures.append(f"{EXPECTED_ENTRY_COUNT - passing_entries} authority entries failed")
        if passing_mappings != EXPECTED_MAPPING_COUNT:
            failures.append(f"{EXPECTED_MAPPING_COUNT - passing_mappings} authority mappings failed")
        negative_entries = [
            entry for entry in entries if entry["comparisonMode"] == "negative-invariant"
        ]
        negative_document = {
            **self.context.metadata("all-declared-destinations"),
            "startTimestamp": self.context.started_at,
            "endTimestamp": finished,
            "entryCount": len(negative_entries),
            "entries": [
                {
                    "entryID": entry["entryID"],
                    "result": entry["result"],
                    "mappingResults": entry["mappingResults"],
                    "runtimeProbeResults": entry["runtimeProbeResults"],
                    "failures": entry["failures"],
                }
                for entry in negative_entries
            ],
            "result": (
                "PASS"
                if len(negative_entries) == 4
                and all(entry["result"] == "PASS" for entry in negative_entries)
                else "FAIL"
            ),
            "failures": []
            if len(negative_entries) == 4
            and all(entry["result"] == "PASS" for entry in negative_entries)
            else ["Norse Base vault negative-invariant coverage failed"],
        }
        negative_path = (
            self.output_root / "negative-mutations" / "norse-base-vault-invariant.json"
        )
        atomic_write_json(negative_path, negative_document)
        reduce_motion_entries = [entry for entry in entries if entry["surface"] == "reduce-motion"]
        reduce_motion_document = {
            **self.context.metadata("all-declared-destinations"),
            "startTimestamp": self.context.started_at,
            "endTimestamp": finished,
            "entryCount": len(reduce_motion_entries),
            "probeEvaluationCount": sum(
                len(entry["runtimeProbeResults"]) for entry in reduce_motion_entries
            ),
            "entries": [
                {
                    "entryID": entry["entryID"],
                    "result": entry["result"],
                    "runtimeProbeResults": entry["runtimeProbeResults"],
                    "failures": entry["failures"],
                }
                for entry in reduce_motion_entries
            ],
            "result": (
                "PASS"
                if len(reduce_motion_entries) == 20
                and all(entry["result"] == "PASS" for entry in reduce_motion_entries)
                else "FAIL"
            ),
            "failures": []
            if len(reduce_motion_entries) == 20
            and all(entry["result"] == "PASS" for entry in reduce_motion_entries)
            else ["Reduce Motion visual/runtime coverage failed"],
        }
        reduce_motion_path = (
            self.output_root / "reduce-motion" / "reduce-motion-runtime-evidence.json"
        )
        atomic_write_json(reduce_motion_path, reduce_motion_document)
        index = {
            "schemaVersion": SCHEMA_VERSION,
            "sourceSHA": self.context.source_sha,
            "comparisonAuthoritySHA256": self.context.authority_sha,
            "authorityAssetManifestSHA256": self.context.asset_manifest_sha,
            "command": self.context.command,
            "startTimestamp": self.context.started_at,
            "endTimestamp": finished,
            "destination": "all-declared-destinations",
            "toolchain": self.context.toolchain,
            "entryCount": len(entries),
            "mappingCount": mapping_count,
            "passingEntryCount": passing_entries,
            "passingMappingCount": passing_mappings,
            "runtimeProbeEvaluationCount": len(unique_probe_results),
            "aggregateEvidence": {
                "norseBaseVaultInvariant": {
                    "path": str(negative_path),
                    "sha256": sha256_file(negative_path),
                },
                "reduceMotion": {
                    "path": str(reduce_motion_path),
                    "sha256": sha256_file(reduce_motion_path),
                },
            },
            "result": "PASS" if not failures else "FAIL",
            "failures": failures,
            "entries": entries,
        }
        index_path = self.output_root / "visual-comparison-index.json"
        atomic_write_json(index_path, index)
        summary = {
            key: index[key]
            for key in (
                "schemaVersion", "sourceSHA", "comparisonAuthoritySHA256",
                "authorityAssetManifestSHA256", "startTimestamp", "endTimestamp",
                "entryCount", "mappingCount", "passingEntryCount", "passingMappingCount",
                "runtimeProbeEvaluationCount", "result", "failures",
            )
        }
        summary.update(
            {
                "index": str(index_path),
                "indexSHA256": sha256_file(index_path),
                "outputHashesSHA256": canonical_json_sha256(
                    [
                        {
                            "path": path.relative_to(self.output_root).as_posix(),
                            "sha256": sha256_file(path),
                        }
                        for path in sorted(self.output_root.rglob("*")) if path.is_file()
                    ]
                ),
            }
        )
        atomic_write_json(self.output_root / "gate-summary.json", summary)
        return index


def git_output(root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", *arguments], cwd=root, check=False,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise ExecutionError(f"git {' '.join(arguments)} failed: {detail}")
    return completed.stdout.strip()


def source_sha(root: Path) -> str:
    value = git_output(root, "rev-parse", "HEAD")
    if not SOURCE_SHA_PATTERN.fullmatch(value):
        raise ExecutionError("repository HEAD is not a full lowercase Git SHA")
    return value


def require_clean_source(
    root: Path,
    output_root: Path,
    source_exclusions: Sequence[Path] = (),
) -> None:
    arguments = ["status", "--porcelain=v1", "--untracked-files=all", "--", "."]
    exclusions = [output_root.resolve(), *(path.resolve() for path in source_exclusions)]
    seen: set[str] = set()
    for exclusion in exclusions:
        if not is_within(exclusion, root):
            continue
        relative = exclusion.relative_to(root.resolve()).as_posix()
        if relative in seen:
            continue
        seen.add(relative)
        arguments.append(f":(exclude){relative}")
    status = git_output(root, *arguments)
    if status:
        raise ExecutionError("source worktree must be clean before final evidence execution")


def default_toolchain() -> dict[str, Any]:
    return {
        "python": subprocess.run(
            ["python3", "--version"], check=False, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True,
        ).stdout.strip(),
        "pillow": getattr(Image, "__version__", "unknown"),
        "numpy": np.__version__,
    }
