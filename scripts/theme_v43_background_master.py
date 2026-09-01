#!/usr/bin/env python3
"""Deterministic v4.3 Theme background rendering from continuous source masters."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from PIL import Image, ImageEnhance


@dataclass(frozen=True)
class BackgroundMasterSpec:
    relative_path: str
    sha256: str
    focal_point: tuple[float, float] = (0.5, 0.5)


VARIANT_ADJUSTMENTS: dict[str, dict[str, float]] = {
    "standard": {
        "brightness": 1.0,
        "color": 1.0,
        "contrast": 1.0,
        "sharpness": 1.0,
    },
    "reduce-motion": {
        "brightness": 0.96,
        "color": 0.90,
        "contrast": 0.96,
        "sharpness": 1.0,
    },
    "high-contrast": {
        "brightness": 0.92,
        "color": 0.88,
        "contrast": 1.30,
        "sharpness": 1.14,
    },
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_background_master(
    repo_root: Path,
    spec: BackgroundMasterSpec,
) -> tuple[Image.Image, dict[str, Any]]:
    path = repo_root / spec.relative_path
    if not path.is_file():
        raise SystemExit(f"Theme background source master is absent: {spec.relative_path}")
    actual_sha256 = sha256_file(path)
    if actual_sha256 != spec.sha256:
        raise SystemExit(f"Theme background source master differs: {spec.relative_path}")
    with Image.open(path) as source:
        master = source.convert("RGB")
    return master, {
        "contentClass": "continuous-art-directed-environment",
        "dimensions": list(master.size),
        "focalPoint": list(spec.focal_point),
        "path": spec.relative_path,
        "runtimeBundled": False,
        "sha256": actual_sha256,
    }


def aspect_fill_crop_box(
    source_size: tuple[int, int],
    output_size: tuple[int, int],
    focal_point: tuple[float, float] = (0.5, 0.5),
) -> tuple[float, float, float, float]:
    source_width, source_height = source_size
    output_width, output_height = output_size
    if min(source_width, source_height, output_width, output_height) <= 0:
        raise ValueError("source and output dimensions must be positive")
    focal_x, focal_y = focal_point
    if not 0.0 <= focal_x <= 1.0 or not 0.0 <= focal_y <= 1.0:
        raise ValueError("focal point components must be in the closed unit interval")

    source_ratio = source_width / source_height
    output_ratio = output_width / output_height
    if source_ratio > output_ratio:
        crop_height = float(source_height)
        crop_width = crop_height * output_ratio
        left = min(max(focal_x * source_width - crop_width / 2, 0.0), source_width - crop_width)
        top = 0.0
    else:
        crop_width = float(source_width)
        crop_height = crop_width / output_ratio
        left = 0.0
        top = min(max(focal_y * source_height - crop_height / 2, 0.0), source_height - crop_height)
    return (left, top, left + crop_width, top + crop_height)


def render_background_variant(
    master: Image.Image,
    output_size: tuple[int, int],
    *,
    mode: str,
    focal_point: tuple[float, float] = (0.5, 0.5),
) -> Image.Image:
    try:
        adjustments = VARIANT_ADJUSTMENTS[mode]
    except KeyError as error:
        raise ValueError(f"unsupported Theme background mode: {mode}") from error

    crop_box = aspect_fill_crop_box(master.size, output_size, focal_point)
    resampling = (
        Image.Resampling.BILINEAR
        if output_size[0] > output_size[1]
        else Image.Resampling.BICUBIC
    )
    rendered = master.convert("RGB").transform(
        output_size,
        Image.Transform.EXTENT,
        crop_box,
        resample=resampling,
    )
    if adjustments["contrast"] != 1.0:
        rendered = ImageEnhance.Contrast(rendered).enhance(adjustments["contrast"])
    if adjustments["color"] != 1.0:
        rendered = ImageEnhance.Color(rendered).enhance(adjustments["color"])
    if adjustments["brightness"] != 1.0:
        rendered = ImageEnhance.Brightness(rendered).enhance(adjustments["brightness"])
    if adjustments["sharpness"] != 1.0:
        rendered = ImageEnhance.Sharpness(rendered).enhance(adjustments["sharpness"])
    return rendered


def output_layout_record(
    master: Image.Image,
    output_size: tuple[int, int],
    focal_point: tuple[float, float],
) -> dict[str, Any]:
    crop_box = aspect_fill_crop_box(master.size, output_size, focal_point)
    crop_width = crop_box[2] - crop_box[0]
    crop_height = crop_box[3] - crop_box[1]
    return {
        "canvas": list(output_size),
        "cropBoxSourcePixels": [round(value, 6) for value in crop_box],
        "focalPoint": list(focal_point),
        "resampling": "bilinear" if output_size[0] > output_size[1] else "bicubic",
        "scale": round(output_size[0] / crop_width, 9),
        "sourceCropAspectRatio": round(crop_width / crop_height, 9),
        "transformation": "single continuous-master aspect-fill crop with one uniform scale",
    }
