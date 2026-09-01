#!/usr/bin/env python3
"""Detect authority-image reuse inside shipping Production visual resources.

The checker is intentionally configured entirely by command-line paths.  It
does not know the name or location of a particular remediation package.  The
package manifest supplies protected authority classifications and the exact
candidate catalog supplies the narrowly permitted byte identities.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import io
import json
import math
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterator, Sequence


DEPENDENCY_ERRORS: list[str] = []
try:
    import cv2
except Exception as error:  # pragma: no cover - exercised by dependency guard
    cv2 = None  # type: ignore[assignment]
    DEPENDENCY_ERRORS.append(f"OpenCV unavailable: {type(error).__name__}: {error}")
try:
    import numpy as np
except Exception as error:  # pragma: no cover - exercised by dependency guard
    np = None  # type: ignore[assignment]
    DEPENDENCY_ERRORS.append(f"NumPy unavailable: {type(error).__name__}: {error}")
try:
    from PIL import Image, ImageCms, ImageOps
except Exception as error:  # pragma: no cover - exercised by dependency guard
    Image = ImageCms = ImageOps = None  # type: ignore[assignment]
    DEPENDENCY_ERRORS.append(f"Pillow unavailable: {type(error).__name__}: {error}")


SCHEMA_VERSION = "1.0"
SUPPORTED_RASTER_SUFFIXES = frozenset(
    {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff"}
)
SUPPORTED_VISUAL_SUFFIXES = SUPPORTED_RASTER_SUFFIXES | frozenset({".pdf"})
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SIGNATURE_SIZE = (48, 48)
FEATURE_MAX_EDGE = 900
FEATURE_LIMIT = 1200
FEATURE_DISTANCE_LIMIT = 105.0
MIN_FEATURE_MATCHES = 10
MIN_FEATURE_INLIERS = 8

PROTECTED_AUTHORITY_MARKERS = (
    "authoritative",
    "controlling",
    "reference",
    "supporting",
    "secondary",
    "rejected",
)
IGNORED_AUTHORITIES = frozenset(
    {
        "hash-locked-comparison-mask",
        "index-only",
        "owner-supplied-full-resolution-source",
    }
)


class GuardError(RuntimeError):
    """A fail-closed input, manifest, decoding, or dependency error."""


@dataclass(frozen=True)
class AssetRecord:
    logical_path: str
    authority: str
    sha256: str
    dimensions: tuple[int, int]
    actual_path: Path
    category: str


@dataclass(frozen=True)
class ExactCandidate:
    record: AssetRecord
    expected_shipping_tail: str


@dataclass
class Fingerprint:
    logical_path: str
    actual_path: Path
    byte_sha256: str
    pixel_sha256: str
    dimensions: tuple[int, int]
    signature: Any
    information_score: float


@dataclass
class FeatureSet:
    points: Any
    descriptors: Any
    dimensions: tuple[int, int]


@dataclass(frozen=True)
class Finding:
    code: str
    kind: str
    shippingPath: str
    authorityPath: str
    detail: str
    metrics: dict[str, Any]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise GuardError(f"unreadable input {path}: {error}") from error
    return digest.hexdigest()


def contained_path(root: Path, candidate: Path, label: str) -> Path:
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise GuardError(f"{label} is unavailable: {candidate}: {error}") from error
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise GuardError(f"{label} escapes its declared root: {candidate}") from error
    return resolved


def load_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GuardError(f"{label} is unreadable or malformed: {path}: {error}") from error


def classify_authority(value: str) -> str:
    normalized = value.strip().lower()
    if not normalized:
        raise GuardError("asset authority must be a nonempty string")
    if "production-candidate" in normalized:
        return "candidate"
    if normalized in IGNORED_AUTHORITIES:
        return "ignored"
    if any(marker in normalized for marker in PROTECTED_AUTHORITY_MARKERS):
        return "protected"
    raise GuardError(f"unrecognized asset authority classification: {value}")


def parse_dimensions(value: Any, context: str) -> tuple[int, int]:
    if (
        not isinstance(value, list)
        or len(value) != 2
        or any(isinstance(item, bool) or not isinstance(item, int) for item in value)
        or any(item <= 0 for item in value)
    ):
        raise GuardError(f"{context} dimensions must be two positive integers")
    return value[0], value[1]


def parse_manifest(package_root: Path, manifest_path: Path) -> list[AssetRecord]:
    payload = load_json(manifest_path, "asset manifest")
    if not isinstance(payload, dict) or not isinstance(payload.get("assets"), list):
        raise GuardError("asset manifest must be an object with an assets array")
    assets = payload["assets"]
    declared_count = payload.get("assetCount")
    if (
        isinstance(declared_count, bool)
        or not isinstance(declared_count, int)
        or declared_count != len(assets)
    ):
        raise GuardError("asset manifest assetCount does not equal the assets array length")

    records: list[AssetRecord] = []
    seen_paths: set[str] = set()
    for index, item in enumerate(assets):
        context = f"asset manifest entry {index}"
        if not isinstance(item, dict):
            raise GuardError(f"{context} must be an object")
        logical_path = item.get("path")
        authority = item.get("authority")
        digest = item.get("sha256")
        if not isinstance(logical_path, str) or not logical_path:
            raise GuardError(f"{context} path must be a nonempty string")
        pure_path = PurePosixPath(logical_path)
        if pure_path.is_absolute() or ".." in pure_path.parts or "\\" in logical_path:
            raise GuardError(f"{context} path must be a package-relative POSIX path")
        if logical_path in seen_paths:
            raise GuardError(f"asset manifest contains duplicate path: {logical_path}")
        seen_paths.add(logical_path)
        if not isinstance(authority, str):
            raise GuardError(f"{context} authority must be a string")
        category = classify_authority(authority)
        if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
            raise GuardError(f"{context} sha256 must be a lowercase SHA-256 digest")
        dimensions = parse_dimensions(item.get("dimensions"), context)
        actual_path = contained_path(
            package_root,
            package_root / Path(*pure_path.parts),
            f"asset manifest entry {logical_path}",
        )
        if not actual_path.is_file():
            raise GuardError(f"asset manifest entry is not a file: {logical_path}")
        if actual_path.suffix.lower() not in SUPPORTED_RASTER_SUFFIXES:
            raise GuardError(f"asset manifest entry is not a supported raster: {logical_path}")
        actual_digest = sha256_file(actual_path)
        if actual_digest != digest:
            raise GuardError(
                f"asset manifest digest mismatch for {logical_path}: "
                f"declared {digest}, actual {actual_digest}"
            )
        if "byteCount" in item:
            byte_count = item["byteCount"]
            if (
                isinstance(byte_count, bool)
                or not isinstance(byte_count, int)
                or byte_count != actual_path.stat().st_size
            ):
                raise GuardError(f"asset manifest byteCount mismatch for {logical_path}")
        records.append(
            AssetRecord(
                logical_path=logical_path,
                authority=authority,
                sha256=digest,
                dimensions=dimensions,
                actual_path=actual_path,
                category=category,
            )
        )
    return records


def walk_objects(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk_objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_objects(child)


def expected_shipping_tail(logical_path: str) -> str:
    parts = PurePosixPath(logical_path).parts
    if len(parts) < 2:
        raise GuardError(
            f"exact candidate path needs a role directory and filename: {logical_path}"
        )
    return PurePosixPath(*parts[-2:]).as_posix()


def parse_exact_candidates(
    catalog_path: Path,
    records: Sequence[AssetRecord],
) -> list[ExactCandidate]:
    payload = load_json(catalog_path, "exact-candidate catalog")
    by_path = {record.logical_path: record for record in records}
    candidates: dict[str, ExactCandidate] = {}
    exact_objects = [
        item
        for item in walk_objects(payload)
        if item.get("evaluationKind") == "resource-byte-identity"
    ]
    if not exact_objects:
        raise GuardError(
            "exact-candidate catalog contains no resource-byte-identity declarations"
        )
    for index, item in enumerate(exact_objects):
        context = f"exact-candidate declaration {index}"
        if item.get("thresholdProfile") != "exact-resource-v1":
            raise GuardError(f"{context} must use exact-resource-v1")
        if item.get("renderMode") != "resolved-resource-export":
            raise GuardError(f"{context} must use resolved-resource-export")
        logical_path = item.get("referenceAsset")
        digest = item.get("referenceSHA256")
        dimensions = parse_dimensions(item.get("referenceDimensions"), context)
        if not isinstance(logical_path, str) or logical_path not in by_path:
            raise GuardError(f"{context} referenceAsset is absent from the asset manifest")
        if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
            raise GuardError(f"{context} referenceSHA256 is malformed")
        record = by_path[logical_path]
        if record.category != "candidate":
            raise GuardError(f"{context} does not reference a production candidate")
        if digest != record.sha256 or dimensions != record.dimensions:
            raise GuardError(f"{context} disagrees with the asset manifest")
        candidate = ExactCandidate(record, expected_shipping_tail(logical_path))
        previous = candidates.get(logical_path)
        if previous is not None and previous != candidate:
            raise GuardError(f"conflicting exact-candidate declarations for {logical_path}")
        candidates[logical_path] = candidate
    return [candidates[path] for path in sorted(candidates)]


def normalize_rgba(path: Path) -> Any:
    if Image is None or ImageCms is None or ImageOps is None:
        raise GuardError("Pillow dependency is unavailable")
    try:
        with Image.open(path) as source:
            source.load()
            oriented = ImageOps.exif_transpose(source)
            rgba = oriented.convert("RGBA")
            icc_profile = source.info.get("icc_profile")
            if icc_profile:
                alpha = rgba.getchannel("A")
                source_profile = ImageCms.ImageCmsProfile(io.BytesIO(icc_profile))
                destination_profile = ImageCms.createProfile("sRGB")
                rgb = ImageCms.profileToProfile(
                    rgba.convert("RGB"),
                    source_profile,
                    destination_profile,
                    outputMode="RGB",
                )
                rgba = Image.merge("RGBA", (*rgb.split(), alpha))
            return rgba.copy()
    except Exception as error:
        raise GuardError(
            f"unable to decode and normalize raster {path}: "
            f"{type(error).__name__}: {error}"
        ) from error


def normalized_pixel_sha256(image: Any) -> str:
    width, height = image.size
    digest = hashlib.sha256()
    digest.update(width.to_bytes(8, "big"))
    digest.update(height.to_bytes(8, "big"))
    digest.update(image.tobytes())
    return digest.hexdigest()


def signature_array(image: Any) -> tuple[Any, float]:
    if np is None or cv2 is None:
        raise GuardError("NumPy or OpenCV dependency is unavailable")
    resized = image.resize(SIGNATURE_SIZE, Image.Resampling.LANCZOS)
    array = np.asarray(resized, dtype=np.float32)
    alpha = array[:, :, 3:4] / 255.0
    premultiplied = np.concatenate((array[:, :, :3] * alpha, array[:, :, 3:4]), axis=2)
    composite = array[:, :, :3] * alpha + 127.0 * (1.0 - alpha)
    gray = cv2.cvtColor(composite.astype(np.uint8), cv2.COLOR_RGB2GRAY)
    edge = cv2.Laplacian(gray, cv2.CV_32F)
    information = max(float(np.std(composite)), float(np.std(edge)))
    return premultiplied, round(information, 6)


def fingerprint(
    path: Path,
    logical_path: str,
    *,
    byte_identity_path: Path | None = None,
) -> Fingerprint:
    image = normalize_rgba(path)
    signature, information = signature_array(image)
    return Fingerprint(
        logical_path=logical_path,
        actual_path=path,
        byte_sha256=sha256_file(byte_identity_path or path),
        pixel_sha256=normalized_pixel_sha256(image),
        dimensions=image.size,
        signature=signature,
        information_score=information,
    )


def validate_record_dimensions(record: AssetRecord, value: Fingerprint) -> None:
    if value.dimensions != record.dimensions:
        raise GuardError(
            f"asset manifest dimensions mismatch for {record.logical_path}: "
            f"declared {record.dimensions}, decoded {value.dimensions}"
        )


def discover_shipping_visuals(repository_root: Path) -> list[tuple[str, str, Path]]:
    discovered: list[tuple[str, str, Path]] = []
    try:
        entries = repository_root.rglob("*")
        for path in entries:
            if not path.is_file() or path.suffix.lower() not in SUPPORTED_VISUAL_SUFFIXES:
                continue
            relative = path.relative_to(repository_root)
            parts = relative.parts
            production_index = next(
                (
                    index
                    for index in range(len(parts) - 1)
                    if parts[index] == "Resources" and parts[index + 1] == "Production"
                ),
                None,
            )
            if production_index is None:
                continue
            actual = contained_path(repository_root, path, "shipping visual asset")
            tail_parts = parts[production_index + 2 :]
            if not tail_parts:
                raise GuardError(
                    f"shipping visual asset has no Production-relative path: {relative}"
                )
            discovered.append(
                (
                    relative.as_posix(),
                    PurePosixPath(*tail_parts).as_posix(),
                    actual,
                )
            )
    except OSError as error:
        raise GuardError(f"unable to enumerate repository: {error}") from error
    if not discovered:
        raise GuardError("repository contains no shipping Resources/Production visual assets")
    return sorted(discovered, key=lambda item: item[0])


def render_pdf_pages(
    pdf_path: Path,
    logical_path: str,
    workspace: Path,
    sequence: int,
) -> list[tuple[str, Path]]:
    renderer = shutil.which("pdftoppm")
    if renderer is None:
        raise GuardError(
            "pdftoppm is required to inspect shipping PDF visual assets but is unavailable"
        )
    prefix = workspace / f"pdf-{sequence:05d}"
    try:
        completed = subprocess.run(
            [renderer, "-png", "-r", "144", str(pdf_path), str(prefix)],
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise GuardError(f"unable to render shipping PDF {logical_path}: {error}") from error
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise GuardError(
            f"unable to render shipping PDF {logical_path}: "
            f"pdftoppm exited {completed.returncode}: {detail}"
        )
    pages = sorted(workspace.glob(f"{prefix.name}-*.png"))
    if not pages:
        raise GuardError(f"shipping PDF rendered no pages: {logical_path}")
    if len(pages) > 100:
        raise GuardError(f"shipping PDF has an unreasonable page count: {logical_path}")
    return [
        (f"{logical_path}#page={page_index}", page_path)
        for page_index, page_path in enumerate(pages, start=1)
    ]


def correlation(first: Any, second: Any) -> float:
    if np is None:
        raise GuardError("NumPy dependency is unavailable")
    left = first.astype(np.float64).reshape(-1)
    right = second.astype(np.float64).reshape(-1)
    left -= left.mean()
    right -= right.mean()
    denominator = float(np.linalg.norm(left) * np.linalg.norm(right))
    if denominator <= 1e-9:
        return 0.0
    return float(np.dot(left, right) / denominator)


def signature_metrics(first: Fingerprint, second: Fingerprint) -> dict[str, float]:
    if np is None or cv2 is None:
        raise GuardError("NumPy or OpenCV dependency is unavailable")
    difference = np.abs(first.signature - second.signature)
    first_rgb = np.clip(first.signature[:, :, :3], 0, 255).astype(np.uint8)
    second_rgb = np.clip(second.signature[:, :, :3], 0, 255).astype(np.uint8)
    first_gray = cv2.cvtColor(first_rgb, cv2.COLOR_RGB2GRAY)
    second_gray = cv2.cvtColor(second_rgb, cv2.COLOR_RGB2GRAY)
    first_edge = cv2.Laplacian(first_gray, cv2.CV_32F)
    second_edge = cv2.Laplacian(second_gray, cv2.CV_32F)
    return {
        "meanAbsoluteError": round(float(difference.mean()), 6),
        "p95AbsoluteError": round(float(np.percentile(difference, 95)), 6),
        "luminanceCorrelation": round(correlation(first_gray, second_gray), 6),
        "edgeCorrelation": round(correlation(first_edge, second_edge), 6),
    }


def aspect_ratio_matches(first: tuple[int, int], second: tuple[int, int]) -> bool:
    first_ratio = first[0] / first[1]
    second_ratio = second[0] / second[1]
    return abs(first_ratio - second_ratio) / max(first_ratio, second_ratio) <= 0.006


def is_whole_image_transform(
    first: Fingerprint,
    second: Fingerprint,
) -> tuple[bool, dict[str, float]]:
    metrics = signature_metrics(first, second)
    information = min(first.information_score, second.information_score)
    metrics["informationScore"] = round(information, 6)
    matches = (
        information >= 8.0
        and metrics["meanAbsoluteError"] <= 4.0
        and metrics["p95AbsoluteError"] <= 14.0
        and metrics["luminanceCorrelation"] >= 0.994
        and metrics["edgeCorrelation"] >= 0.965
    )
    return matches, metrics


def work_rgb_gray_and_alpha(path: Path) -> tuple[Any, Any, Any]:
    if np is None or cv2 is None:
        raise GuardError("NumPy or OpenCV dependency is unavailable")
    image = normalize_rgba(path)
    width, height = image.size
    scale = min(1.0, FEATURE_MAX_EDGE / max(width, height))
    if scale < 1.0:
        image = image.resize(
            (max(1, round(width * scale)), max(1, round(height * scale))),
            Image.Resampling.LANCZOS,
        )
    array = np.asarray(image, dtype=np.float32)
    alpha = array[:, :, 3:4] / 255.0
    rgb = np.clip(array[:, :, :3] * alpha + 255.0 * (1.0 - alpha), 0, 255).astype(
        np.uint8
    )
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    alpha_channel = np.clip(array[:, :, 3], 0, 255).astype(np.uint8)
    return rgb, gray, alpha_channel


def work_rgb_and_gray(path: Path) -> tuple[Any, Any]:
    rgb, gray, _ = work_rgb_gray_and_alpha(path)
    return rgb, gray


def extract_features(path: Path) -> FeatureSet:
    if cv2 is None or np is None:
        raise GuardError("OpenCV or NumPy dependency is unavailable")
    _, gray = work_rgb_and_gray(path)
    try:
        detector = cv2.SIFT_create(
            nfeatures=FEATURE_LIMIT,
            contrastThreshold=0.018,
            edgeThreshold=10,
        )
    except Exception as error:
        raise GuardError(f"OpenCV SIFT support is unavailable: {error}") from error
    keypoints, descriptors = detector.detectAndCompute(gray, None)
    if not keypoints or descriptors is None:
        return FeatureSet(
            points=np.empty((0, 2), dtype=np.float32),
            descriptors=np.empty((0, 128), dtype=np.float32),
            dimensions=(gray.shape[1], gray.shape[0]),
        )
    points = np.asarray([keypoint.pt for keypoint in keypoints], dtype=np.float32)
    return FeatureSet(points, descriptors.astype(np.float32), (gray.shape[1], gray.shape[0]))


def intersection_geometry(
    source_dimensions: tuple[int, int],
    target_dimensions: tuple[int, int],
    matrix: Any,
) -> tuple[float, float, float, float, float]:
    if np is None or cv2 is None:
        raise GuardError("NumPy or OpenCV dependency is unavailable")
    source_width, source_height = source_dimensions
    target_width, target_height = target_dimensions
    corners = np.asarray(
        [[[0.0, 0.0], [source_width, 0.0], [source_width, source_height], [0.0, source_height]]],
        dtype=np.float32,
    )
    transformed = cv2.transform(corners, matrix)[0]
    left = max(0.0, float(transformed[:, 0].min()))
    top = max(0.0, float(transformed[:, 1].min()))
    right = min(float(target_width), float(transformed[:, 0].max()))
    bottom = min(float(target_height), float(transformed[:, 1].max()))
    width = max(0.0, right - left)
    height = max(0.0, bottom - top)
    area = width * height
    projected_area = abs(float(np.linalg.det(matrix[:, :2]))) * source_width * source_height
    target_area = target_width * target_height
    source_coverage = area / projected_area if projected_area > 0 else 0.0
    target_coverage = area / target_area if target_area > 0 else 0.0
    return width, height, area, source_coverage, target_coverage


def verify_feature_geometry(
    source: Fingerprint,
    target: Fingerprint,
    source_features: FeatureSet,
    target_features: FeatureSet,
    matches: Sequence[tuple[int, int, float]],
) -> dict[str, Any] | None:
    if cv2 is None or np is None:
        raise GuardError("OpenCV or NumPy dependency is unavailable")
    unique: list[tuple[int, int, float]] = []
    used_query: set[int] = set()
    used_train: set[int] = set()
    for query_index, train_index, distance in sorted(matches, key=lambda item: item[2]):
        if query_index in used_query or train_index in used_train:
            continue
        used_query.add(query_index)
        used_train.add(train_index)
        unique.append((query_index, train_index, distance))
    if len(unique) < MIN_FEATURE_MATCHES:
        return None

    source_points = np.asarray(
        [source_features.points[train] for _, train, _ in unique], dtype=np.float32
    )
    target_points = np.asarray(
        [target_features.points[query] for query, _, _ in unique], dtype=np.float32
    )
    cv2.setRNGSeed(0)
    matrix, mask = cv2.estimateAffinePartial2D(
        source_points,
        target_points,
        method=cv2.RANSAC,
        ransacReprojThreshold=3.0,
        maxIters=4000,
        confidence=0.999,
        refineIters=20,
    )
    if matrix is None or mask is None:
        return None
    inliers = int(mask.reshape(-1).sum())
    inlier_ratio = inliers / len(unique)
    if inliers < MIN_FEATURE_INLIERS or inlier_ratio < 0.58:
        return None
    a, b = float(matrix[0, 0]), float(matrix[0, 1])
    c, d = float(matrix[1, 0]), float(matrix[1, 1])
    scale_x = math.hypot(a, c)
    scale_y = math.hypot(b, d)
    if min(scale_x, scale_y) <= 1e-6:
        return None
    uniform_error = abs(scale_x - scale_y) / max(scale_x, scale_y)
    rotation_degrees = abs(math.degrees(math.atan2(c, a)))
    rotation_degrees = min(rotation_degrees, abs(360.0 - rotation_degrees))
    if uniform_error > 0.025 or rotation_degrees > 2.0:
        return None

    width, height, area, source_coverage, target_coverage = intersection_geometry(
        source_features.dimensions,
        target_features.dimensions,
        matrix,
    )
    if (
        width < 48
        or height < 48
        or area < 4096
        or max(source_coverage, target_coverage) < 0.60
        or min(source_coverage, target_coverage) < 0.08
    ):
        return None

    source_rgb, _, source_alpha = work_rgb_gray_and_alpha(source.actual_path)
    target_rgb, _, _ = work_rgb_gray_and_alpha(target.actual_path)
    target_width, target_height = target_features.dimensions
    warped = cv2.warpAffine(
        source_rgb,
        matrix,
        (target_width, target_height),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0),
    )
    source_mask = np.where(source_alpha >= 32, 255, 0).astype(np.uint8)
    valid_mask = cv2.warpAffine(
        source_mask,
        matrix,
        (target_width, target_height),
        flags=cv2.INTER_NEAREST,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
    valid_mask = cv2.erode(valid_mask, np.ones((5, 5), dtype=np.uint8), iterations=1)
    valid = valid_mask > 0
    if int(valid.sum()) < 4096:
        return None
    difference = np.abs(warped.astype(np.int16) - target_rgb.astype(np.int16))[valid]
    mean_error = float(difference.mean())
    close_fraction = float((np.max(difference, axis=1) <= 16).mean())
    warped_gray = cv2.cvtColor(warped, cv2.COLOR_RGB2GRAY)[valid]
    target_gray = cv2.cvtColor(target_rgb, cv2.COLOR_RGB2GRAY)[valid]
    luminance_correlation = correlation(warped_gray, target_gray)
    if mean_error > 18.0 or close_fraction < 0.60 or luminance_correlation < 0.96:
        return None
    return {
        "featureMatches": len(unique),
        "featureInliers": inliers,
        "inlierRatio": round(inlier_ratio, 6),
        "scale": round((scale_x + scale_y) / 2.0, 6),
        "rotationDegrees": round(rotation_degrees, 6),
        "sourceCoverage": round(source_coverage, 6),
        "shippingCoverage": round(target_coverage, 6),
        "meanAbsoluteError": round(mean_error, 6),
        "closePixelFraction": round(close_fraction, 6),
        "luminanceCorrelation": round(luminance_correlation, 6),
    }


def relative_input_path(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def finding(
    code: str,
    kind: str,
    shipping_path: str,
    authority_path: str,
    detail: str,
    metrics: dict[str, Any] | None = None,
) -> Finding:
    return Finding(code, kind, shipping_path, authority_path, detail, metrics or {})


def run_guard(
    repository_root_value: Path,
    package_root_value: Path,
    manifest_value: Path,
    exact_catalog_value: Path,
) -> dict[str, Any]:
    if DEPENDENCY_ERRORS:
        raise GuardError("; ".join(sorted(DEPENDENCY_ERRORS)))
    try:
        repository_root = repository_root_value.resolve(strict=True)
        package_root = package_root_value.resolve(strict=True)
    except OSError as error:
        raise GuardError(f"repository or package root is unavailable: {error}") from error
    if not repository_root.is_dir():
        raise GuardError("repository root must be a directory")
    if not package_root.is_dir():
        raise GuardError("package root must be a directory")
    manifest_input = (
        manifest_value if manifest_value.is_absolute() else package_root / manifest_value
    )
    catalog_input = (
        exact_catalog_value
        if exact_catalog_value.is_absolute()
        else package_root / exact_catalog_value
    )
    manifest_path = contained_path(package_root, manifest_input, "asset manifest")
    exact_catalog_path = contained_path(
        package_root, catalog_input, "exact-candidate catalog"
    )
    if not manifest_path.is_file() or not exact_catalog_path.is_file():
        raise GuardError("manifest and exact-candidate catalog inputs must be files")

    records = parse_manifest(package_root, manifest_path)
    catalog_exact_candidates = parse_exact_candidates(exact_catalog_path, records)
    approved_candidates = [
        ExactCandidate(record, expected_shipping_tail(record.logical_path))
        for record in records
        if record.category == "candidate"
    ]
    catalog_candidate_paths = {
        candidate.record.logical_path for candidate in catalog_exact_candidates
    }
    approved_candidate_paths = {
        candidate.record.logical_path for candidate in approved_candidates
    }
    if not catalog_candidate_paths.issubset(approved_candidate_paths):
        raise GuardError("exact-candidate catalog escapes the approved candidate manifest set")
    protected_records = sorted(
        (record for record in records if record.category == "protected"),
        key=lambda record: record.logical_path,
    )
    if not protected_records:
        raise GuardError("asset manifest declares no protected authority rasters")

    authority_fingerprints: list[tuple[AssetRecord, Fingerprint]] = []
    for record in protected_records:
        value = fingerprint(record.actual_path, record.logical_path)
        validate_record_dimensions(record, value)
        authority_fingerprints.append((record, value))
    candidate_fingerprints: list[tuple[ExactCandidate, Fingerprint]] = []
    for candidate in sorted(
        approved_candidates, key=lambda item: item.record.logical_path
    ):
        value = fingerprint(candidate.record.actual_path, candidate.record.logical_path)
        validate_record_dimensions(candidate.record, value)
        candidate_fingerprints.append((candidate, value))

    shipping_records = discover_shipping_visuals(repository_root)
    has_shipping_pdfs = any(path.suffix.lower() == ".pdf" for _, _, path in shipping_records)
    render_workspace_context = (
        tempfile.TemporaryDirectory(prefix="reference-boundary-pdf-")
        if has_shipping_pdfs
        else None
    )
    render_workspace = (
        Path(render_workspace_context.name) if render_workspace_context is not None else None
    )
    shipping_fingerprints: list[tuple[str, str, Fingerprint]] = []
    try:
        for sequence, (shipping_path, production_tail, actual_path) in enumerate(
            shipping_records
        ):
            if actual_path.suffix.lower() == ".pdf":
                if render_workspace is None:
                    raise GuardError("internal PDF-render workspace is unavailable")
                for page_path, rendered_path in render_pdf_pages(
                    actual_path,
                    shipping_path,
                    render_workspace,
                    sequence,
                ):
                    shipping_fingerprints.append(
                        (
                            page_path,
                            f"{production_tail}#{page_path.rsplit('=', 1)[-1]}",
                            fingerprint(
                                rendered_path,
                                page_path,
                                byte_identity_path=actual_path,
                            ),
                        )
                    )
            else:
                shipping_fingerprints.append(
                    (shipping_path, production_tail, fingerprint(actual_path, shipping_path))
                )
    except Exception:
        if render_workspace_context is not None:
            render_workspace_context.cleanup()
        raise

    protected_by_bytes: dict[str, list[tuple[AssetRecord, Fingerprint]]] = {}
    protected_by_pixels: dict[str, list[tuple[AssetRecord, Fingerprint]]] = {}
    for item in authority_fingerprints:
        protected_by_bytes.setdefault(item[1].byte_sha256, []).append(item)
        protected_by_pixels.setdefault(item[1].pixel_sha256, []).append(item)
    candidate_by_bytes: dict[str, list[tuple[ExactCandidate, Fingerprint]]] = {}
    candidate_by_pixels: dict[str, list[tuple[ExactCandidate, Fingerprint]]] = {}
    for item in candidate_fingerprints:
        candidate_by_bytes.setdefault(item[1].byte_sha256, []).append(item)
        candidate_by_pixels.setdefault(item[1].pixel_sha256, []).append(item)

    findings: list[Finding] = []
    allowed_matches: list[dict[str, str]] = []
    unresolved: list[tuple[str, str, Fingerprint]] = []
    for shipping_path, production_tail, value in shipping_fingerprints:
        exact_byte_matches = candidate_by_bytes.get(value.byte_sha256, [])
        if exact_byte_matches:
            valid = sorted(
                (
                    candidate
                    for candidate, _ in exact_byte_matches
                    if production_tail == candidate.expected_shipping_tail
                ),
                key=lambda candidate: candidate.record.logical_path,
            )
            if valid:
                allowed_matches.append(
                    {
                        "shippingPath": shipping_path,
                        "authorityPath": valid[0].record.logical_path,
                        "sha256": value.byte_sha256,
                    }
                )
                continue
            candidate = sorted(
                (candidate for candidate, _ in exact_byte_matches),
                key=lambda item: item.record.logical_path,
            )[0]
            findings.append(
                finding(
                    "PRB-106",
                    "exact-candidate-wrong-resource-identity",
                    shipping_path,
                    candidate.record.logical_path,
                    "approved candidate bytes appear outside the declared Production role and filename",
                    {
                        "actualProductionTail": production_tail,
                        "expectedProductionTail": candidate.expected_shipping_tail,
                        "sha256": value.byte_sha256,
                    },
                )
            )
            continue

        protected_byte_matches = protected_by_bytes.get(value.byte_sha256, [])
        if protected_byte_matches:
            record, _ = sorted(
                protected_byte_matches, key=lambda item: item[0].logical_path
            )[0]
            findings.append(
                finding(
                    "PRB-101",
                    "protected-exact-byte-identity",
                    shipping_path,
                    record.logical_path,
                    "shipping raster is byte-identical to a protected authority raster",
                    {"sha256": value.byte_sha256},
                )
            )
            continue

        protected_pixel_matches = protected_by_pixels.get(value.pixel_sha256, [])
        if protected_pixel_matches:
            record, _ = sorted(
                protected_pixel_matches, key=lambda item: item[0].logical_path
            )[0]
            findings.append(
                finding(
                    "PRB-102",
                    "protected-decoded-pixel-identity",
                    shipping_path,
                    record.logical_path,
                    "shipping raster decodes to the same normalized pixels as a protected authority raster",
                    {
                        "dimensions": list(value.dimensions),
                        "normalizedPixelSHA256": value.pixel_sha256,
                    },
                )
            )
            continue

        candidate_pixel_matches = candidate_by_pixels.get(value.pixel_sha256, [])
        if candidate_pixel_matches:
            candidate, _ = sorted(
                candidate_pixel_matches,
                key=lambda item: item[0].record.logical_path,
            )[0]
            findings.append(
                finding(
                    "PRB-105",
                    "exact-candidate-reencoded",
                    shipping_path,
                    candidate.record.logical_path,
                    "approved candidate pixels were decoded or re-encoded instead of preserving exact bytes",
                    {
                        "actualSHA256": value.byte_sha256,
                        "expectedSHA256": candidate.record.sha256,
                        "normalizedPixelSHA256": value.pixel_sha256,
                    },
                )
            )
            continue

        whole_match: Finding | None = None
        comparison_sources: list[tuple[str, str, Fingerprint]] = [
            ("protected", record.logical_path, source)
            for record, source in authority_fingerprints
        ] + [
            ("candidate", candidate.record.logical_path, source)
            for candidate, source in candidate_fingerprints
        ]
        for category, authority_path, source in comparison_sources:
            if not aspect_ratio_matches(source.dimensions, value.dimensions):
                continue
            matches, metrics = is_whole_image_transform(source, value)
            if not matches:
                continue
            if category == "candidate":
                whole_match = finding(
                    "PRB-105",
                    "exact-candidate-transformed",
                    shipping_path,
                    authority_path,
                    "approved candidate was resized or otherwise transformed instead of preserving exact identity",
                    metrics,
                )
            else:
                operation = (
                    "reencoded" if source.dimensions == value.dimensions else "uniformly resized"
                )
                whole_match = finding(
                    "PRB-103",
                    "protected-whole-image-transform",
                    shipping_path,
                    authority_path,
                    f"shipping raster is a {operation} whole protected authority raster",
                    metrics,
                )
            break
        if whole_match is not None:
            findings.append(whole_match)
        else:
            unresolved.append((shipping_path, production_tail, value))

    unique_feature_sources: list[tuple[str, str, Fingerprint]] = []
    seen_feature_pixels: set[tuple[str, str]] = set()
    for category, authority_path, value in [
        *(
            ("protected", record.logical_path, value)
            for record, value in authority_fingerprints
        ),
        *(
            (
                (
                    "catalog-candidate"
                    if candidate.record.logical_path in catalog_candidate_paths
                    else "candidate"
                ),
                candidate.record.logical_path,
                value,
            )
            for candidate, value in candidate_fingerprints
        ),
    ]:
        key = (category, value.pixel_sha256)
        if key in seen_feature_pixels:
            continue
        seen_feature_pixels.add(key)
        unique_feature_sources.append((category, authority_path, value))

    source_features: list[FeatureSet] = []
    descriptor_blocks: list[Any] = []
    descriptor_owners: list[int] = []
    descriptor_locals: list[int] = []
    for owner, (_, _, source) in enumerate(unique_feature_sources):
        features = extract_features(source.actual_path)
        source_features.append(features)
        if len(features.descriptors) == 0:
            continue
        descriptor_blocks.append(features.descriptors)
        descriptor_owners.extend([owner] * len(features.descriptors))
        descriptor_locals.extend(range(len(features.descriptors)))

    if descriptor_blocks and unresolved:
        all_descriptors = np.vstack(descriptor_blocks).astype(np.float32)
        owner_array = np.asarray(descriptor_owners, dtype=np.int32)
        local_array = np.asarray(descriptor_locals, dtype=np.int32)
        for shipping_path, _, value in unresolved:
            target_features = extract_features(value.actual_path)
            if len(target_features.descriptors) < MIN_FEATURE_MATCHES:
                continue
            cv2.setRNGSeed(0)
            matcher = cv2.FlannBasedMatcher(
                {"algorithm": 1, "trees": 6},
                {"checks": 96},
            )
            neighbor_count = min(12, len(all_descriptors))
            raw_matches = matcher.knnMatch(
                target_features.descriptors,
                all_descriptors,
                k=neighbor_count,
            )
            grouped: dict[int, dict[int, tuple[int, int, float]]] = {}
            for query_index, neighbors in enumerate(raw_matches):
                per_owner: dict[int, tuple[int, int, float]] = {}
                for match in neighbors:
                    if match.distance > FEATURE_DISTANCE_LIMIT:
                        continue
                    owner = int(owner_array[match.trainIdx])
                    local = int(local_array[match.trainIdx])
                    current = per_owner.get(owner)
                    proposed = (query_index, local, float(match.distance))
                    if current is None or proposed[2] < current[2]:
                        per_owner[owner] = proposed
                for owner, proposed in per_owner.items():
                    grouped.setdefault(owner, {})[query_index] = proposed
            qualified = [
                (owner, list(matches.values()))
                for owner, matches in grouped.items()
                if len(matches) >= MIN_FEATURE_MATCHES
            ]

            def ranked(category: str, limit: int) -> list[tuple[int, list[Any]]]:
                return sorted(
                    (
                        item
                        for item in qualified
                        if unique_feature_sources[item[0]][0] == category
                    ),
                    key=lambda item: (
                        -len(item[1]),
                        unique_feature_sources[item[0]][1],
                    ),
                )[:limit]

            candidates = [
                *ranked("catalog-candidate", len(catalog_exact_candidates)),
                *ranked("candidate", 10),
                *ranked("protected", 16),
            ]
            for owner, matches in candidates:
                category, authority_path, source = unique_feature_sources[owner]
                metrics = verify_feature_geometry(
                    source,
                    value,
                    source_features[owner],
                    target_features,
                    matches,
                )
                if metrics is None:
                    continue
                if category in {"candidate", "catalog-candidate"}:
                    findings.append(
                        finding(
                            "PRB-105",
                            "exact-candidate-cropped-or-embedded",
                            shipping_path,
                            authority_path,
                            "approved candidate is cropped, resized, or embedded instead of preserving exact resource identity",
                            metrics,
                        )
                    )
                else:
                    findings.append(
                        finding(
                            "PRB-104",
                            "protected-large-region-crop-or-embedding",
                            shipping_path,
                            authority_path,
                            "a meaningful large region of a protected authority raster is cropped or embedded in the shipping raster",
                            metrics,
                        )
                    )
                break

    findings_by_key: dict[tuple[str, str, str, str, str], Finding] = {}
    for item in findings:
        key = (
            item.code,
            item.shippingPath,
            item.authorityPath,
            item.kind,
            json.dumps(item.metrics, sort_keys=True),
        )
        findings_by_key[key] = item
    findings = [findings_by_key[key] for key in sorted(findings_by_key)]
    allowed_matches = sorted(
        allowed_matches,
        key=lambda item: (item["shippingPath"], item["authorityPath"]),
    )
    result = "FAIL" if findings else "PASS"
    report = {
        "schemaVersion": SCHEMA_VERSION,
        "result": result,
        "inputs": {
            "repositoryRoot": repository_root.as_posix(),
            "packageRoot": package_root.as_posix(),
            "assetManifest": {
                "path": relative_input_path(package_root, manifest_path),
                "sha256": sha256_file(manifest_path),
            },
            "exactCandidateCatalog": {
                "path": relative_input_path(package_root, exact_catalog_path),
                "sha256": sha256_file(exact_catalog_path),
            },
        },
        "policy": {
            "shippingScope": "Resources/Production raster images and rendered PDF pages only",
            "protectedAuthorityMarkers": list(PROTECTED_AUTHORITY_MARKERS),
            "ignoredAuthorities": sorted(IGNORED_AUTHORITIES),
            "exactCandidatePolicy": "exact bytes and declared Production role/filename only",
            "signatureSize": list(SIGNATURE_SIZE),
            "featureMaxEdge": FEATURE_MAX_EDGE,
            "largeRegionMinimumSourceOrShippingCoverage": 0.60,
            "largeRegionMinimumOppositeCoverage": 0.08,
        },
        "summary": {
            "manifestAssetCount": len(records),
            "protectedAuthorityCount": len(protected_records),
            "approvedProductionCandidateCount": len(approved_candidates),
            "catalogExactCandidateCount": len(catalog_exact_candidates),
            "shippingVisualAssetCount": len(shipping_records),
            "shippingRasterAssetCount": sum(
                path.suffix.lower() in SUPPORTED_RASTER_SUFFIXES
                for _, _, path in shipping_records
            ),
            "shippingPDFAssetCount": sum(
                path.suffix.lower() == ".pdf" for _, _, path in shipping_records
            ),
            "renderedShippingImageCount": len(shipping_fingerprints),
            "allowedExactIdentityCount": len(allowed_matches),
            "findingCount": len(findings),
        },
        "allowedExactIdentities": allowed_matches,
        "findings": [asdict(item) for item in findings],
    }
    if render_workspace_context is not None:
        render_workspace_context.cleanup()
    return report


def error_report(message: str) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "result": "ERROR",
        "summary": {"findingCount": 0},
        "errors": [message],
    }


def render_report(report: dict[str, Any]) -> str:
    return json.dumps(report, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def write_or_print(report: dict[str, Any], output: Path | None) -> None:
    rendered = render_report(report)
    if output is None:
        sys.stdout.write(rendered)
        return
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8")
    except OSError as error:
        raise GuardError(f"unable to write report {output}: {error}") from error


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="Detect forbidden authority-image reuse in shipping Production rasters."
    )
    value.add_argument("--repository-root", required=True, type=Path)
    value.add_argument("--package-root", required=True, type=Path)
    value.add_argument(
        "--asset-manifest",
        required=True,
        type=Path,
        help="Manifest file contained by --package-root.",
    )
    value.add_argument(
        "--exact-candidate-catalog",
        required=True,
        type=Path,
        help="Catalog contained by --package-root that declares resource-byte-identity candidates.",
    )
    value.add_argument("--output", type=Path)
    return value


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        report = run_guard(
            arguments.repository_root,
            arguments.package_root,
            arguments.asset_manifest,
            arguments.exact_candidate_catalog,
        )
        write_or_print(report, arguments.output)
    except GuardError as error:
        report = error_report(str(error))
        try:
            write_or_print(report, arguments.output)
        except GuardError:
            sys.stdout.write(render_report(report))
        return 2
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
