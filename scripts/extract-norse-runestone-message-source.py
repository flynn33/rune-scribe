#!/usr/bin/env python3
"""Build the glyph-free near-square Norse Runestone message Relic."""

from __future__ import annotations

import argparse
from io import BytesIO
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageOps


OWNER_SOURCE_SHA256 = "13f1854dc64f7f70b7d54742d4b99aa6e15638b6c7262e380b455192ddabefb2"
OWNER_SOURCE_SIZE = (1536, 1024)
OWNER_EXTRACTION_BOUNDS = (356, 462, 545, 651)
OWNER_REGION_SIZE = (189, 189)
OWNER_REGION_SHA256 = "75648b01d5caad185182aa5f78d73b078b2e7886b044b612092a8eb56eafe1ee"

SOURCE_ROOT_RELATIVE = Path("docs/verification/theme-fidelity-v4-3/source-masters/norse")
OWNER_REGION_RELATIVE = SOURCE_ROOT_RELATIVE / "runestone-tablet-message-owner-region.png"
RECORD_RELATIVE = SOURCE_ROOT_RELATIVE / "runestone-tablet-message-static-extraction.json"
LANDSCAPE_SOURCE_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/source-masters/norse/runestone-tablet-authoring.png"
)
OUTPUT_RELATIVE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "Resources/Production/ShareFallbacks/share-fallback.norse.runestone-tablet.png"
)

LANDSCAPE_SOURCE_SHA256 = "dd8369aa680633db99f5bdeb32e1c046d6f26802ad8e8a90d533e3077898911d"
LANDSCAPE_SOURCE_SIZE = (1448, 1086)
LANDSCAPE_FIELD_BOUNDS = (354, 297, 1095, 796)
STONE_BRIGHTNESS = 0.82

UPSCALE = 8
OUTPUT_SIZE = (1600, 1600)
OBJECT_WORKING_SIZE = (OWNER_REGION_SIZE[0] * UPSCALE, OWNER_REGION_SIZE[1] * UPSCALE)

# Reviewed outer contour for the Relic in the owner's short-message region. The
# blue presentation-board panel is removed by the warm-foreground key below.
SILHOUETTE_POLYGON = (
    (10, 42),
    (15, 32),
    (25, 24),
    (35, 20),
    (60, 18),
    (78, 17),
    (85, 14),
    (96, 14),
    (105, 16),
    (115, 18),
    (132, 19),
    (151, 21),
    (164, 27),
    (173, 36),
    (179, 48),
    (182, 60),
    (182, 139),
    (177, 155),
    (166, 168),
    (151, 176),
    (131, 180),
    (57, 180),
    (36, 177),
    (20, 168),
    (10, 155),
    (5, 140),
    (5, 55),
)
BLUE_KEY_MAXIMUM = 5

# Every controlling message instance has a user-selected Seal over this part
# of the Relic. The unobscured lower-left owner-source frame quadrant is
# reflected without rescaling to reconstruct the hidden lower-right frame.
CORNER_SOURCE_BOUNDS = (0, 105, 80, 189)
CORNER_DESTINATION = (109, 105)
CORNER_JOIN_FEATHER = 8
SELECTED_SEAL_OCCLUSION_BOUNDS = (136, 113, 189, 189)

# The owner board carries sample glyphs. The complete field is replaced with
# accepted blank Runestone material; the raven crest remains untouched.
FIELD_POLYGON = (
    (35, 55),
    (40, 49),
    (56, 45),
    (132, 45),
    (149, 53),
    (154, 63),
    (154, 139),
    (149, 149),
    (139, 156),
    (49, 156),
    (40, 150),
    (34, 141),
    (34, 63),
)
GLYPH_BEARING_BOUNDS = (43, 69, 146, 139)
CREST_EXCLUSION_BOUNDS = (65, -2, 124, 61)
FIELD_FEATHER_RADIUS = 1.2

REFERENCE_IDENTITIES = (
    {
        "logicalID": "canonical.norse.05-short-message.aae1f3bf5c",
        "sha256": "aae1f3bf5cff4b94fbc2ca6eb86eedbeb2cabb8281588c53aef5d6d13e9efbe7",
        "use": "controlling near-square frame and short-message geometry",
    },
    {
        "logicalID": "canonical.norse.06-long-message.49860b3f30",
        "sha256": "49860b3f30e633dda4c15186d6d40f80a34192265c048bf20c9dfdcf774a12a1",
        "use": "long-message frame, field, and selected-Seal placement comparison",
    },
    {
        "logicalID": "canonical.norse.08-share-preview.17232537b1",
        "sha256": "17232537b11d19ea192127b887fcf6474ee32e2471e1d8a9ff1eefc49ac56767",
        "use": "static-share scale and composition comparison",
    },
)

CORROBORATING_REFERENCE = {
    "logicalID": "owner-reference.norse.12-accessibility-variants.a074a682c4",
    "sha256": "a074a682c4a28abf7a9a80cea7577af4824b346e2672c6f7cb938f9547887cff",
    "use": "corroborates the bilateral lower-corner frame ornament used by the source reflection",
}

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


def encoded_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


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
        raise ValueError("owner source digest differs from approved source 035")
    owner = load_png(owner_source, "RGB")
    if owner.size != OWNER_SOURCE_SIZE:
        raise ValueError("owner source dimensions differ from approved source 035")
    region = owner.crop(OWNER_EXTRACTION_BOUNDS)
    if region.size != OWNER_REGION_SIZE:
        raise ValueError("owner extraction bounds produced unexpected dimensions")
    encoded = png_bytes(region)
    if sha256_bytes(encoded) != OWNER_REGION_SHA256:
        raise ValueError("owner extraction differs from the pinned short-message region")
    return encoded


def validate_stored_sources(repo_root: Path) -> tuple[Image.Image, Image.Image]:
    owner_region_path = repo_root / OWNER_REGION_RELATIVE
    landscape_path = repo_root / LANDSCAPE_SOURCE_RELATIVE
    if sha256_file(owner_region_path) != OWNER_REGION_SHA256:
        raise ValueError("stored short-message owner region digest differs")
    if sha256_file(landscape_path) != LANDSCAPE_SOURCE_SHA256:
        raise ValueError("accepted blank Runestone source digest differs")
    owner_region = load_png(owner_region_path, "RGB")
    landscape = load_png(landscape_path, "RGB")
    if owner_region.size != OWNER_REGION_SIZE:
        raise ValueError("stored short-message owner region dimensions differ")
    if landscape.size != LANDSCAPE_SOURCE_SIZE:
        raise ValueError("accepted blank Runestone source dimensions differ")
    return owner_region, landscape


def largest_connected_component(values: list[int], size: tuple[int, int]) -> set[int]:
    width, height = size
    active = [value > 0 for value in values]
    seen = [False] * (width * height)
    largest: list[int] = []

    for index, is_active in enumerate(active):
        if not is_active or seen[index]:
            continue
        stack = [index]
        seen[index] = True
        component: list[int] = []
        while stack:
            current = stack.pop()
            component.append(current)
            x = current % width
            y = current // width
            for neighbor in (current - 1, current + 1, current - width, current + width):
                if neighbor < 0 or neighbor >= width * height:
                    continue
                if seen[neighbor] or not active[neighbor]:
                    continue
                neighbor_x = neighbor % width
                neighbor_y = neighbor // width
                if abs(neighbor_x - x) + abs(neighbor_y - y) != 1:
                    continue
                seen[neighbor] = True
                stack.append(neighbor)
        if len(component) > len(largest):
            largest = component

    if not largest:
        raise ValueError("owner Relic matte contains no foreground component")
    return set(largest)


def owner_relic_layer(owner_region: Image.Image) -> Image.Image:
    shape = Image.new("L", OWNER_REGION_SIZE, 0)
    ImageDraw.Draw(shape).polygon(SILHOUETTE_POLYGON, fill=255)

    candidate_values: list[int] = []
    for (red, green, blue), shape_alpha in zip(owner_region.getdata(), shape.getdata()):
        blue_excess = min(blue - red, 2 * (blue - green))
        candidate_values.append(
            255 if shape_alpha and blue_excess <= BLUE_KEY_MAXIMUM else 0
        )

    foreground = largest_connected_component(candidate_values, OWNER_REGION_SIZE)
    alpha = Image.new("L", OWNER_REGION_SIZE, 0)
    alpha.putdata(
        [255 if index in foreground else 0 for index in range(OWNER_REGION_SIZE[0] * OWNER_REGION_SIZE[1])]
    )
    layer = owner_region.convert("RGBA")
    layer.putalpha(alpha)
    return layer.resize(OBJECT_WORKING_SIZE, Image.Resampling.LANCZOS)


def reconstruct_occluded_corner(layer: Image.Image) -> Image.Image:
    source_bounds = tuple(value * UPSCALE for value in CORNER_SOURCE_BOUNDS)
    patch = ImageOps.mirror(layer.crop(source_bounds))
    destination = tuple(value * UPSCALE for value in CORNER_DESTINATION)

    patch_layer = Image.new("RGBA", OBJECT_WORKING_SIZE, (0, 0, 0, 0))
    patch_layer.alpha_composite(patch, destination)
    blend = Image.new("L", OBJECT_WORKING_SIZE, 0)
    pixels = blend.load()
    feather = CORNER_JOIN_FEATHER * UPSCALE
    for y in range(destination[1], OBJECT_WORKING_SIZE[1]):
        y_alpha = max(0, round(255 * (y - destination[1]) / feather))
        for x in range(destination[0], OBJECT_WORKING_SIZE[0]):
            x_alpha = max(0, round(255 * (x - destination[0]) / feather))
            pixels[x, y] = min(255, x_alpha, y_alpha)
    return Image.composite(patch_layer, layer, blend)


def replace_glyph_field(layer: Image.Image, landscape: Image.Image) -> Image.Image:
    field_mask = Image.new("L", OBJECT_WORKING_SIZE, 0)
    ImageDraw.Draw(field_mask).polygon(
        [(x * UPSCALE, y * UPSCALE) for x, y in FIELD_POLYGON],
        fill=255,
    )
    crest_mask = Image.new("L", OBJECT_WORKING_SIZE, 0)
    ImageDraw.Draw(crest_mask).ellipse(
        tuple(value * UPSCALE for value in CREST_EXCLUSION_BOUNDS),
        fill=255,
    )
    field_mask = ImageChops.darker(field_mask, ImageOps.invert(crest_mask))
    field_mask = field_mask.filter(
        ImageFilter.GaussianBlur(FIELD_FEATHER_RADIUS * UPSCALE)
    )
    field_bounds = field_mask.getbbox()
    if field_bounds is None:
        raise ValueError("glyph replacement field is empty")

    stone = landscape.crop(LANDSCAPE_FIELD_BOUNDS)
    stone = ImageEnhance.Brightness(stone).enhance(STONE_BRIGHTNESS)
    # ImageOps.fit uses one uniform scale and a centered crop; it never distorts
    # the source independently by axis.
    patch = ImageOps.fit(
        stone,
        (field_bounds[2] - field_bounds[0], field_bounds[3] - field_bounds[1]),
        method=Image.Resampling.LANCZOS,
        centering=(0.52, 0.5),
    ).convert("RGBA")
    patch_layer = Image.new("RGBA", OBJECT_WORKING_SIZE, (0, 0, 0, 0))
    patch_layer.alpha_composite(patch, (field_bounds[0], field_bounds[1]))
    return Image.composite(patch_layer, layer, field_mask)


def render_static_fallback(owner_region: Image.Image, landscape: Image.Image) -> Image.Image:
    relic = owner_relic_layer(owner_region)
    relic = reconstruct_occluded_corner(relic)
    relic = replace_glyph_field(relic, landscape)

    canvas = Image.new("RGBA", OUTPUT_SIZE, (0, 0, 0, 0))
    canvas.alpha_composite(
        relic,
        (
            (OUTPUT_SIZE[0] - OBJECT_WORKING_SIZE[0]) // 2,
            (OUTPUT_SIZE[1] - OBJECT_WORKING_SIZE[1]) // 2,
        ),
    )
    canvas.putdata(
        [(0, 0, 0, 0) if pixel[3] == 0 else pixel for pixel in canvas.getdata()]
    )
    return canvas


def extraction_record(output_data: bytes, output: Image.Image) -> dict[str, Any]:
    alpha = output.getchannel("A")
    histogram = alpha.histogram()
    return {
        "schemaVersion": "1.0",
        "recordID": "norse.runestone-tablet.message-static-reconstruction.v1",
        "sourceAuthority": {
            "logicalID": "owner-supplied-full-resolution-source-035",
            "sha256": OWNER_SOURCE_SHA256,
            "pixelDimensions": {
                "width": OWNER_SOURCE_SIZE[0],
                "height": OWNER_SOURCE_SIZE[1],
            },
            "extractionBounds": {
                "x": OWNER_EXTRACTION_BOUNDS[0],
                "y": OWNER_EXTRACTION_BOUNDS[1],
                "width": OWNER_REGION_SIZE[0],
                "height": OWNER_REGION_SIZE[1],
            },
        },
        "controllingReferences": list(REFERENCE_IDENTITIES),
        "corroboratingReference": CORROBORATING_REFERENCE,
        "storedOwnerRegion": {
            "path": OWNER_REGION_RELATIVE.as_posix(),
            "sha256": OWNER_REGION_SHA256,
            "pixelDimensions": {
                "width": OWNER_REGION_SIZE[0],
                "height": OWNER_REGION_SIZE[1],
            },
            "containsCompleteUIScreen": False,
        },
        "glyphFreeFieldSource": {
            "path": LANDSCAPE_SOURCE_RELATIVE.as_posix(),
            "sha256": LANDSCAPE_SOURCE_SHA256,
            "sourceBounds": list(LANDSCAPE_FIELD_BOUNDS),
        },
        "authorityLimitation": {
            "exactCompleteObjectAvailable": False,
            "reason": (
                "The approved 05, 06, and 08 message objects all bake Script glyphs "
                "into the stone and occlude the lower-right frame with the selected "
                "Valknut Seal."
            ),
            "resolution": (
                "Use the complete visible 05 owner frame, replace the glyph field with "
                "accepted blank Runestone stone, and reconstruct only the hidden lower-right "
                "frame from the reflected unobscured lower-left owner-source quadrant; the "
                "owner-approved accessibility variant corroborates the bilateral ornament."
            ),
        },
        "transformation": {
            "operations": [
                "exact source-035 short-message object crop",
                "fixed reviewed silhouette polygon",
                "dark-blue board matte with largest-connected-component retention",
                "Lanczos eight-times uniform working-scale expansion",
                "horizontal reflection of the unobscured lower-left owner frame quadrant",
                "join-only feather for the reconstructed lower-right frame",
                "complete glyph-bearing field replacement from accepted blank stone source",
                "raven-crest exclusion from the field replacement",
                "centered transparent square padding",
                "nonessential PNG metadata removal",
            ],
            "silhouettePolygon": [list(point) for point in SILHOUETTE_POLYGON],
            "blueKeyMaximum": BLUE_KEY_MAXIMUM,
            "cornerSourceBounds": list(CORNER_SOURCE_BOUNDS),
            "cornerDestination": list(CORNER_DESTINATION),
            "cornerJoinFeather": CORNER_JOIN_FEATHER,
            "selectedSealOcclusionBounds": list(SELECTED_SEAL_OCCLUSION_BOUNDS),
            "fieldPolygon": [list(point) for point in FIELD_POLYGON],
            "glyphBearingBounds": list(GLYPH_BEARING_BOUNDS),
            "crestExclusionBounds": list(CREST_EXCLUSION_BOUNDS),
            "stoneBrightnessScale": STONE_BRIGHTNESS,
            "uniformScaleFactor": UPSCALE,
            "sourceRegionCrop": True,
            "fieldMaterialCenterCrop": True,
            "outputObjectCropping": False,
            "cropping": False,
            "aspectFit": True,
            "nonUniformScaling": False,
            "generativeFill": False,
            "referenceScreenshotEmbedded": False,
            "runtimeGlyphPolicy": (
                "No glyph pixels are baked into this fallback; production Script rendering supplies glyphs."
            ),
            "runtimeSealPolicy": (
                "No user-selected Seal is baked into this fallback; production composition supplies the Seal."
            ),
        },
        "output": {
            "path": OUTPUT_RELATIVE.as_posix(),
            "sha256": sha256_bytes(output_data),
            "pixelDimensions": {"width": output.width, "height": output.height},
            "mode": output.mode,
            "semanticRole": "relic.static-share-fallback",
            "alpha": {
                "present": True,
                "extrema": list(alpha.getextrema()),
                "transparentPixelCount": histogram[0],
                "partialAlphaPixelCount": sum(histogram[1:255]),
                "opaquePixelCount": histogram[255],
                "contentBounds": list(alpha.getbbox() or ()),
            },
        },
        "review": {
            "inspectionScales": ["100%", "200%", "target-device"],
            "edgeStatus": "transparent perimeter with complete visible frame ornament",
            "glyphStatus": "glyph-free; field reserved for production Script rendering",
            "sealStatus": "selected Seal removed; lower-right frame restored from owner-source ornament",
            "aspectStatus": "near-square source geometry preserved without axis distortion",
        },
    }


def build(repo_root: Path) -> tuple[bytes, bytes]:
    owner_region, landscape = validate_stored_sources(repo_root)
    output = render_static_fallback(owner_region, landscape)
    if output.size != OUTPUT_SIZE or output.mode != "RGBA":
        raise ValueError("static fallback output contract differs")
    if output.getchannel("A").getextrema() != (0, 255):
        raise ValueError("static fallback lacks true transparency")
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
        if arguments.check:
            if (repo_root / OUTPUT_RELATIVE).read_bytes() != output_data:
                raise ValueError("stored static fallback differs from deterministic output")
            if (repo_root / RECORD_RELATIVE).read_bytes() != record_data:
                raise ValueError("stored extraction record differs from deterministic output")
        else:
            atomic_write(repo_root / OUTPUT_RELATIVE, output_data)
            atomic_write(repo_root / RECORD_RELATIVE, record_data)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
