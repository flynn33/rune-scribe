#!/usr/bin/env python3
"""Replace baked Wildwood checker fields with deterministic real alpha."""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from scipy import ndimage


@dataclass(frozen=True)
class RelicAlphaSpec:
    slug: str
    relative_path: str
    input_sha256: str
    intermediate_sha256: str
    output_sha256: str


SPECS = (
    RelicAlphaSpec(
        slug="rootsong-tablet",
        relative_path=(
            "docs/verification/theme-fidelity-v4-3/source-masters/wildwood/"
            "wildwood-rootsong-tablet-clean-production-master-v4.3.png"
        ),
        input_sha256="b911efa5aefa223973163ecc7fc10ff4632922142bedf5d8b29d0905be9f6625",
        intermediate_sha256="f7be7e1546149c31cd3f71cf37841153ef9b148876a42d3c9f40e3ac58ae740e",
        output_sha256="c36bbb1aff2685502081e441da0ab0bffea3651a67774093ef86c646cdf532e5",
    ),
    RelicAlphaSpec(
        slug="mossbound-plaque",
        relative_path=(
            "docs/verification/theme-fidelity-v4-3/source-masters/wildwood/"
            "wildwood-mossbound-plaque-clean-production-master-v4.3.png"
        ),
        input_sha256="57d4606967361c2833c9ca17761998db740cd6ca2ab8ddd3e4f78682cf35736c",
        intermediate_sha256="39cf3aa94ee3661e9fb3d28b9ea414f38f90ebd7c8c6102e4e54225c9947bbee",
        output_sha256="d599ff51f2d7a43c123c4541b64e2870a26dd57a3dd0bba0579c5ed60672465d",
    ),
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def derive_alpha(source: Image.Image) -> Image.Image:
    rgba = np.asarray(source.convert("RGBA")).copy()
    rgb = rgba[:, :, :3]
    original_alpha = rgba[:, :, 3]
    floating = rgb.astype(np.float32)
    mean = floating.mean(axis=2)
    chroma = floating.max(axis=2) - floating.min(axis=2)
    height, width = mean.shape

    segmentation = np.full((height, width), cv2.GC_PR_BGD, dtype=np.uint8)
    segmentation[(mean > 230) & (chroma < 18)] = cv2.GC_BGD
    segmentation[original_alpha == 0] = cv2.GC_BGD

    y, x = np.ogrid[:height, :width]
    plausible_object = (
        (x > 180) & (x < width - 180) & (y > 20) & (y < height - 20)
    )
    segmentation[
        plausible_object & ((mean < 232) | (chroma > 16)) & (original_alpha > 0)
    ] = cv2.GC_PR_FGD
    segmentation[
        plausible_object & ((mean < 185) | (chroma > 38)) & (original_alpha > 0)
    ] = cv2.GC_FGD
    segmentation[250:950, 350:1250] = cv2.GC_FGD

    background_model = np.zeros((1, 65), np.float64)
    foreground_model = np.zeros((1, 65), np.float64)
    cv2.grabCut(
        cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR),
        segmentation,
        None,
        background_model,
        foreground_model,
        8,
        cv2.GC_INIT_WITH_MASK,
    )
    foreground = np.isin(segmentation, (cv2.GC_FGD, cv2.GC_PR_FGD))
    labels, _ = ndimage.label(foreground, np.ones((3, 3), dtype=bool))
    center_component = labels[height // 2, width // 2]
    if center_component == 0:
        raise ValueError("center foreground component is absent")
    object_mask = labels == center_component
    object_mask |= foreground & (ndimage.distance_transform_edt(~object_mask) <= 4)

    _, nearest_inside = ndimage.distance_transform_edt(
        ~object_mask,
        return_indices=True,
    )
    alpha = cv2.GaussianBlur(
        object_mask.astype(np.float32) * 255.0,
        (0, 0),
        0.65,
    )
    alpha[alpha < 8] = 0
    alpha[alpha > 247] = 255
    alpha = np.rint(alpha).astype(np.uint8)

    # Edge RGB is borrowed from the nearest retained object pixel so the
    # antialias transition cannot carry a white or gray checker matte.
    partial = (alpha > 0) & (alpha < 255)
    nearest_rgb = rgb[nearest_inside[0], nearest_inside[1]]
    rgba[partial, :3] = nearest_rgb[partial]
    rgba[:, :, 3] = alpha
    rgba[alpha == 0, :3] = 0

    # The opaque object field is the preservation boundary: its RGB is exact.
    original_opaque = original_alpha == 255
    if not np.array_equal(rgba[original_opaque, :3], rgb[original_opaque]):
        raise ValueError("opaque object pixels changed")
    return Image.fromarray(rgba)


def validate_output(image: Image.Image, relative_path: str) -> dict[str, object]:
    if image.mode != "RGBA" or image.size != (1600, 1200):
        raise ValueError(f"image contract differs: {relative_path}")
    alpha = image.getchannel("A")
    if alpha.getextrema() != (0, 255):
        raise ValueError(f"alpha range differs: {relative_path}")
    if max(
        alpha.getpixel((0, 0)),
        alpha.getpixel((1599, 0)),
        alpha.getpixel((0, 1199)),
        alpha.getpixel((1599, 1199)),
    ) != 0:
        raise ValueError(f"transparent exterior differs: {relative_path}")
    rgba = np.asarray(image)
    if np.any(rgba[rgba[:, :, 3] == 0, :3]):
        raise ValueError(f"transparent pixels retain a color-key field: {relative_path}")
    return {
        "alphaExtrema": list(alpha.getextrema()),
        "contentBounds": list(alpha.getbbox() or ()),
        "opaquePixels": int(np.count_nonzero(rgba[:, :, 3] == 255)),
        "partialAlphaPixels": int(np.count_nonzero((rgba[:, :, 3] > 0) & (rgba[:, :, 3] < 255))),
        "transparentPixels": int(np.count_nonzero(rgba[:, :, 3] == 0)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()
    reports = []
    for spec in SPECS:
        path = repo_root / spec.relative_path
        actual_sha = sha256_file(path)
        if args.check:
            if spec.output_sha256 == "PENDING" or actual_sha != spec.output_sha256:
                raise SystemExit(f"remediated source hash differs: {spec.relative_path}")
            with Image.open(path) as opened:
                facts = validate_output(opened.convert("RGBA"), spec.relative_path)
            reports.append({"path": spec.relative_path, "sha256": actual_sha, **facts})
            continue
        if actual_sha == spec.output_sha256:
            with Image.open(path) as opened:
                facts = validate_output(opened.convert("RGBA"), spec.relative_path)
            reports.append({"path": spec.relative_path, "sha256": actual_sha, **facts})
            continue
        if actual_sha not in {spec.input_sha256, spec.intermediate_sha256}:
            raise SystemExit(f"checker-bearing source hash differs: {spec.relative_path}")
        with Image.open(path) as opened:
            source = opened.convert("RGBA")
        output = derive_alpha(source)
        facts = validate_output(output, spec.relative_path)
        output.save(path, format="PNG", compress_level=9, optimize=False)
        reports.append({"path": spec.relative_path, "sha256": sha256_file(path), **facts})
    print(json.dumps({"status": "PASS", "outputs": reports}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
