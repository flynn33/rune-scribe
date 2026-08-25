#!/usr/bin/env python3
"""Compare a deterministic Theme capture with a manifest-pinned authority image."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
from typing import Any, Dict, Optional, Sequence, Tuple

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
) -> Tuple[Path, Any]:
    role = record.get("role")
    if not isinstance(role, str) or "mask" not in role.lower():
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


def metric_checks(metrics: Dict[str, float]) -> Dict[str, bool]:
    return {
        "luminanceSSIM": metrics["luminanceSSIM"] >= THRESHOLDS["luminanceSSIM"],
        "edgeSSIM": metrics["edgeSSIM"] >= THRESHOLDS["edgeSSIM"],
        "focalSSIM": metrics["focalSSIM"] >= THRESHOLDS["focalSSIM"],
        "medianDeltaE": metrics["medianDeltaE"] <= THRESHOLDS["medianDeltaE"],
        "p95DeltaE": metrics["p95DeltaE"] <= THRESHOLDS["p95DeltaE"],
        "fractionDeltaEAbove20": metrics["fractionDeltaEAbove20"]
        <= THRESHOLDS["maxFractionDeltaEAbove20"],
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
    Image.fromarray(pixels, mode="RGB").save(temporary, format="PNG")
    temporary.replace(path)


def compare(
    root: Path,
    manifest_path: Path,
    comparison_id: str,
    candidate_path: Path,
    output_stem: Path,
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
    candidate, resized = normalize_candidate(candidate, dimensions)

    output_json = Path(str(output_stem) + ".json")
    output_heatmap = Path(str(output_stem) + ".heatmap.png")
    inputs = {manifest_path, reference_path, candidate_path}
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
    parser.add_argument("--output", type=Path, required=True, help="Output path stem.")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_arguments(argv)
    root = args.root.resolve()
    manifest = root / DEFAULT_MANIFEST
    candidate = args.candidate if args.candidate.is_absolute() else root / args.candidate
    output = args.output if args.output.is_absolute() else root / args.output
    try:
        result = compare(root, manifest, args.comparison_id, candidate, output)
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
