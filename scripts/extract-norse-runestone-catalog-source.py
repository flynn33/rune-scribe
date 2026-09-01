#!/usr/bin/env python3
"""Build the portrait Norse Runestone catalog source from owner-supplied art."""

from __future__ import annotations

import argparse
from io import BytesIO
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageOps


OWNER_SOURCE_SHA256 = "e9c1f4a00ebbd7666d409193dc39222494e2414b48d9b42bbfacfb14cd087bd6"
OWNER_SOURCE_SIZE = (1536, 1024)
OWNER_EXTRACTION_BOUNDS = (655, 104, 797, 289)
OWNER_REGION_SIZE = (142, 185)
OWNER_REGION_SHA256 = "57d4d5f00b5cb213a987eeb7ff56cb56d9d3da07e96bf054fce0fbca5c738409"

LEGACY_SOURCE_ROOT_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/source-masters/norse"
)
V43_SOURCE_ROOT_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4-3/source-masters/norse"
)
OWNER_REGION_RELATIVE = (
    V43_SOURCE_ROOT_RELATIVE / "runestone-tablet-catalog-owner-region.png"
)
LANDSCAPE_SOURCE_RELATIVE = (
    LEGACY_SOURCE_ROOT_RELATIVE / "runestone-tablet-authoring.png"
)
OUTPUT_RELATIVE = (
    V43_SOURCE_ROOT_RELATIVE / "runestone-tablet-catalog-authoring.png"
)
RECORD_RELATIVE = (
    V43_SOURCE_ROOT_RELATIVE / "runestone-tablet-catalog-extraction.json"
)

LANDSCAPE_SOURCE_SHA256 = "dd8369aa680633db99f5bdeb32e1c046d6f26802ad8e8a90d533e3077898911d"
LANDSCAPE_FIELD_BOUNDS = (354, 297, 1095, 796)
STONE_BRIGHTNESS = 0.82
UPSCALE = 4
AUTHORING_SIZE = (768, 1024)
OBJECT_FIT_SIZE = (720, 960)
THUMBNAIL_SIZE = (512, 512)

# Fixed, owner-object silhouette at source-region pixel coordinates. It retains
# the complete frame and shadow while excluding the surrounding catalog panel.
SILHOUETTE_POLYGON = (
    (31, 11),
    (19, 20),
    (9, 44),
    (9, 166),
    (37, 175),
    (116, 175),
    (125, 171),
    (134, 158),
    (133, 40),
    (127, 24),
    (114, 12),
    (91, 6),
    (69, 4),
)

# The complete inscription field is replaced from the accepted glyph-free
# Runestone source. The runtime Script renderer remains the only glyph source.
FIELD_POLYGON = (
    (31, 48),
    (36, 43),
    (51, 40),
    (91, 40),
    (106, 43),
    (111, 48),
    (112, 140),
    (106, 148),
    (99, 151),
    (42, 151),
    (35, 148),
    (29, 140),
    (29, 52),
)
GLYPH_BEARING_BOUNDS = (37, 48, 110, 145)
CREST_EXCLUSION_BOUNDS = (42, -4, 100, 54)

PNG_SAVE_OPTIONS = {"compress_level": 9, "optimize": False}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def png_bytes(image: Image.Image) -> bytes:
    buffer = BytesIO()
    image.save(buffer, format="PNG", **PNG_SAVE_OPTIONS)
    return buffer.getvalue()


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        temporary.write_bytes(data)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def load_png(path: Path, mode: str) -> Image.Image:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"missing regular source: {path}")
    with Image.open(path) as image:
        image.verify()
    with Image.open(path) as image:
        if image.format != "PNG":
            raise ValueError(f"source is not PNG: {path}")
        return image.convert(mode)


def import_owner_region(owner_source: Path) -> bytes:
    if sha256_file(owner_source) != OWNER_SOURCE_SHA256:
        raise ValueError("owner source digest differs from the approved source")
    owner = load_png(owner_source, "RGB")
    if owner.size != OWNER_SOURCE_SIZE:
        raise ValueError("owner source dimensions differ from the approved source")
    region = owner.crop(OWNER_EXTRACTION_BOUNDS)
    if region.size != OWNER_REGION_SIZE:
        raise ValueError("owner extraction bounds produced unexpected dimensions")
    encoded = png_bytes(region)
    if sha256_bytes(encoded) != OWNER_REGION_SHA256:
        raise ValueError("owner extraction differs from the pinned region")
    return encoded


def validate_stored_sources(repo_root: Path) -> tuple[Image.Image, Image.Image]:
    owner_region_path = repo_root / OWNER_REGION_RELATIVE
    landscape_path = repo_root / LANDSCAPE_SOURCE_RELATIVE
    if sha256_file(owner_region_path) != OWNER_REGION_SHA256:
        raise ValueError("stored owner region digest differs")
    if sha256_file(landscape_path) != LANDSCAPE_SOURCE_SHA256:
        raise ValueError("glyph-free landscape source digest differs")
    owner_region = load_png(owner_region_path, "RGB")
    landscape = load_png(landscape_path, "RGB")
    if owner_region.size != OWNER_REGION_SIZE:
        raise ValueError("stored owner region dimensions differ")
    if landscape.size != (1448, 1086):
        raise ValueError("glyph-free landscape source dimensions differ")
    return owner_region, landscape


def scaled_points(points: tuple[tuple[int, int], ...]) -> list[tuple[int, int]]:
    return [(x * UPSCALE, y * UPSCALE) for x, y in points]


def render_authoring_source(owner_region: Image.Image, landscape: Image.Image) -> Image.Image:
    scaled_size = (OWNER_REGION_SIZE[0] * UPSCALE, OWNER_REGION_SIZE[1] * UPSCALE)
    scaled_owner = owner_region.resize(scaled_size, Image.Resampling.LANCZOS)

    alpha = Image.new("L", scaled_size, 0)
    ImageDraw.Draw(alpha).polygon(scaled_points(SILHOUETTE_POLYGON), fill=255)
    alpha = alpha.filter(ImageFilter.GaussianBlur(radius=0.6 * UPSCALE))
    object_image = scaled_owner.convert("RGBA")
    object_image.putalpha(alpha)

    stone = landscape.crop(LANDSCAPE_FIELD_BOUNDS)
    stone = ImageEnhance.Brightness(stone).enhance(STONE_BRIGHTNESS)

    field_mask = Image.new("L", scaled_size, 0)
    ImageDraw.Draw(field_mask).polygon(scaled_points(FIELD_POLYGON), fill=255)
    crest_mask = Image.new("L", scaled_size, 0)
    ImageDraw.Draw(crest_mask).ellipse(
        tuple(value * UPSCALE for value in CREST_EXCLUSION_BOUNDS),
        fill=255,
    )
    field_mask = ImageChops.darker(field_mask, ImageOps.invert(crest_mask))
    field_mask = field_mask.filter(ImageFilter.GaussianBlur(radius=1.2 * UPSCALE))
    field_bounds = field_mask.getbbox()
    if field_bounds is None:
        raise ValueError("glyph replacement field is empty")

    patch = ImageOps.fit(
        stone,
        (field_bounds[2] - field_bounds[0], field_bounds[3] - field_bounds[1]),
        method=Image.Resampling.LANCZOS,
        centering=(0.52, 0.5),
    ).convert("RGBA")
    patch_layer = Image.new("RGBA", scaled_size, (0, 0, 0, 0))
    patch_layer.alpha_composite(patch, (field_bounds[0], field_bounds[1]))
    glyph_free = Image.composite(patch_layer, object_image, field_mask)

    contained = ImageOps.contain(
        glyph_free,
        OBJECT_FIT_SIZE,
        method=Image.Resampling.LANCZOS,
    )
    canvas = Image.new("RGBA", AUTHORING_SIZE, (0, 0, 0, 0))
    canvas.alpha_composite(
        contained,
        (
            (AUTHORING_SIZE[0] - contained.width) // 2,
            (AUTHORING_SIZE[1] - contained.height) // 2,
        ),
    )
    canvas.putdata(
        [
            (0, 0, 0, 0) if pixel[3] == 0 else pixel
            for pixel in canvas.getdata()
        ]
    )
    return canvas


def extraction_record(output_data: bytes, output: Image.Image) -> dict[str, Any]:
    alpha = output.getchannel("A")
    histogram = alpha.histogram()
    return {
        "schemaVersion": "1.0",
        "recordID": "norse.runestone-tablet.catalog-portrait-extraction.v1",
        "sourceAuthority": {
            "logicalID": "owner-supplied-norse-codex-board",
            "sha256": OWNER_SOURCE_SHA256,
            "pixelDimensions": {"width": OWNER_SOURCE_SIZE[0], "height": OWNER_SOURCE_SIZE[1]},
            "extractionBounds": {
                "x": OWNER_EXTRACTION_BOUNDS[0],
                "y": OWNER_EXTRACTION_BOUNDS[1],
                "width": OWNER_REGION_SIZE[0],
                "height": OWNER_REGION_SIZE[1],
            },
        },
        "storedOwnerRegion": {
            "path": OWNER_REGION_RELATIVE.as_posix(),
            "sha256": OWNER_REGION_SHA256,
            "pixelDimensions": {"width": OWNER_REGION_SIZE[0], "height": OWNER_REGION_SIZE[1]},
            "containsCompleteUIScreen": False,
        },
        "glyphFreeFieldSource": {
            "path": LANDSCAPE_SOURCE_RELATIVE.as_posix(),
            "sha256": LANDSCAPE_SOURCE_SHA256,
            "sourceBounds": list(LANDSCAPE_FIELD_BOUNDS),
        },
        "transformation": {
            "operations": [
                "exact owner-region crop",
                "fixed silhouette mask with full frame and shadow extent",
                "Lanczos four-times working-scale expansion",
                "complete glyph-field replacement from accepted blank stone source",
                "crest exclusion",
                "Lanczos portrait contain on transparent canvas",
                "nonessential PNG metadata removal",
            ],
            "silhouettePolygon": [list(point) for point in SILHOUETTE_POLYGON],
            "fieldPolygon": [list(point) for point in FIELD_POLYGON],
            "glyphBearingBounds": list(GLYPH_BEARING_BOUNDS),
            "crestExclusionBounds": list(CREST_EXCLUSION_BOUNDS),
            "stoneBrightnessScale": STONE_BRIGHTNESS,
            "runtimeGlyphPolicy": "No glyph pixels are baked into this master; production Script rendering supplies glyphs.",
            "cropping": False,
            "aspectFit": True,
        },
        "output": {
            "path": OUTPUT_RELATIVE.as_posix(),
            "sha256": sha256_bytes(output_data),
            "pixelDimensions": {"width": output.width, "height": output.height},
            "mode": output.mode,
            "alpha": {
                "present": True,
                "extrema": list(alpha.getextrema()),
                "transparentPixelCount": histogram[0],
                "partialAlphaPixelCount": sum(histogram[1:255]),
                "opaquePixelCount": histogram[255],
            },
            "thumbnailTargetDimensions": {"width": THUMBNAIL_SIZE[0], "height": THUMBNAIL_SIZE[1]},
        },
        "review": {
            "inspectionScales": ["100%", "200%", "target-device"],
            "edgeStatus": "transparent silhouette retains the approved frame, ornament, and shadow",
            "glyphStatus": "glyph-free; inscription field reserved for production Script rendering",
        },
    }


def encoded_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def build(repo_root: Path) -> tuple[bytes, bytes]:
    owner_region, landscape = validate_stored_sources(repo_root)
    output = render_authoring_source(owner_region, landscape)
    if output.size != AUTHORING_SIZE or output.mode != "RGBA":
        raise ValueError("authoring output contract differs")
    if output.getchannel("A").getextrema() != (0, 255):
        raise ValueError("authoring output lacks true transparency")
    output_data = png_bytes(output)
    return output_data, encoded_json(extraction_record(output_data, output))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--owner-source", type=Path)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args(sys.argv[1:] if argv is None else argv)
    repo_root = arguments.repo_root.resolve()
    try:
        if arguments.owner_source is not None:
            if arguments.check:
                raise ValueError("--owner-source and --check cannot be combined")
            atomic_write(
                repo_root / OWNER_REGION_RELATIVE,
                import_owner_region(arguments.owner_source.resolve()),
            )
        output_data, record_data = build(repo_root)
        output_path = repo_root / OUTPUT_RELATIVE
        record_path = repo_root / RECORD_RELATIVE
        if arguments.check:
            if output_path.read_bytes() != output_data:
                raise ValueError("stored portrait authoring source differs")
            if record_path.read_bytes() != record_data:
                raise ValueError("stored extraction record differs")
            print(f"PASS: deterministic Runestone catalog extraction ({sha256_bytes(output_data)})")
            return 0
        atomic_write(output_path, output_data)
        atomic_write(record_path, record_data)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"WROTE: {repo_root / OUTPUT_RELATIVE}")
    print(f"WROTE: {repo_root / RECORD_RELATIVE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
