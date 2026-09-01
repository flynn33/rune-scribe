#!/usr/bin/env python3
"""Build deterministic Norse production-asset candidates from supplied masters."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
from typing import Any, Iterable
import zlib

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps


LEGACY_SOURCE_ROOT_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/source-masters/norse"
)
V43_SOURCE_ROOT_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4-3/source-masters/norse"
)
OUTPUT_ROOT_RELATIVE = Path("docs/verification/theme-fidelity-v4-3/generated/norse")
TARGET_ROOT_RELATIVE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "Resources/Production"
)
BUILDER_RELATIVE = Path("scripts/build-norse-production-assets.py")
DERIVATION_RELATIVE = Path("Metadata/Norse-Production-Asset-Derivation-v4.3.json")
FONT_RELATIVE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "Resources/NotoSansRunic-Regular.ttf"
)
SCRIPT_MAPPING_RELATIVE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "Resources/Production/Metadata/Norse-Script-Mapping-v1.0.json"
)
CATALOG_PORTRAIT_SOURCE = "runestone-tablet-catalog-authoring.png"
CATALOG_OWNER_REGION_SOURCE = "runestone-tablet-catalog-owner-region.png"
RUNESTONE_MESSAGE_EXTRACTOR_RELATIVE = Path(
    "scripts/extract-norse-runestone-message-source.py"
)
RUNESTONE_MESSAGE_OWNER_REGION_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4-3/source-masters/norse/"
    "runestone-tablet-message-owner-region.png"
)
RUNESTONE_MESSAGE_BLANK_STONE_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/source-masters/norse/"
    "runestone-tablet-authoring.png"
)
V43_SOURCE_FILES = frozenset(
    {CATALOG_PORTRAIT_SOURCE, CATALOG_OWNER_REGION_SOURCE}
)

RESAMPLING = Image.Resampling.LANCZOS
PNG_SAVE_OPTIONS = {"compress_level": 9, "optimize": False}

RELICS = (
    ("runestone-tablet", "runestone-tablet-authoring.png", (2048, 1536)),
    ("dragonwood-plaque", "dragonwood-plaque-authoring.png", (1536, 2048)),
    ("stormforged-stele", "stormforged-stele-authoring.png", (1536, 2048)),
)
SEALS = (
    "valknut",
    "ravenshield",
    "mjolnir",
    "wolkin",
    "yggdrasil",
    "berserk",
)
SEAL_MASTER_SIZES = {
    "valknut": (1015, 1024),
    "ravenshield": (1024, 1015),
    "mjolnir": (1003, 1024),
    "wolkin": (1013, 1024),
    "yggdrasil": (1024, 991),
    "berserk": (1024, 981),
}
CARD_STATES = ("owned", "locked", "encountered", "selected", "unavailable")

RECIPE_DEFINITIONS: dict[str, dict[str, Any]] = {
    "magenta-matte-standard-v1": {
        "operations": [
            "soft-magenta-matte",
            "three-by-three-median-edge-cleanup",
            "partial-alpha-magenta-despill",
            "lanczos-resize",
        ],
        "parameters": {
            "balanceCeiling": 120,
            "balanceFeather": 80,
            "chromaFloor": 40,
            "chromaFeather": 90,
            "keyFloor": 130,
            "keyFeather": 80,
            "matteClamp": [6, 249],
        },
    },
    "magenta-matte-contain-v1": {
        "operations": [
            "soft-magenta-matte",
            "three-by-three-median-edge-cleanup",
            "partial-alpha-magenta-despill",
            "lanczos-resize",
            "aspect-fit-transparent-pad",
        ],
        "parameters": {"alignment": "center", "cropping": False},
    },
    "owner-board-portrait-catalog-thumbnail-v1": {
        "operations": [
            "validate-owner-region-digest-and-bounds",
            "apply-fixed-reviewed-silhouette-mask",
            "replace-complete-glyph-bearing-field-from-accepted-blank-stone-source",
            "preserve-portrait-frame-crest-and-shadow",
            "lanczos-aspect-fit-transparent-pad",
        ],
        "parameters": {
            "ownerSourceSHA256": "e9c1f4a00ebbd7666d409193dc39222494e2414b48d9b42bbfacfb14cd087bd6",
            "ownerSourceDimensions": [1536, 1024],
            "extractionBounds": {"x": 655, "y": 104, "width": 142, "height": 185},
            "storedOwnerRegionSHA256": "57d4d5f00b5cb213a987eeb7ff56cb56d9d3da07e96bf054fce0fbca5c738409",
            "glyphFreeAuthoringSHA256": "e03573c99335fa553b71e2e49a1011d1d10ca1d4270501c6fd4cc88b3f9669b2",
            "authoringDimensions": [768, 1024],
            "outputDimensions": [512, 512],
            "alignment": "center",
            "cropping": False,
            "runtimeGlyphSource": "production Script renderer",
        },
    },
    "owner-board-near-square-message-static-fallback-v1": {
        "operations": [
            "validate-pinned-owner-region-and-blank-stone-digests",
            "apply-fixed-reviewed-silhouette-mask",
            "reflect-unobscured-owner-frame-quadrant-into-seal-occlusion",
            "replace-complete-glyph-bearing-field-from-accepted-blank-stone-source",
            "preserve-raven-crest",
            "lanczos-uniform-scale",
            "transparent-center-pad",
        ],
        "parameters": {
            "extractorPath": RUNESTONE_MESSAGE_EXTRACTOR_RELATIVE.as_posix(),
            "ownerRegionSHA256": "75648b01d5caad185182aa5f78d73b078b2e7886b044b612092a8eb56eafe1ee",
            "blankStoneSHA256": "dd8369aa680633db99f5bdeb32e1c046d6f26802ad8e8a90d533e3077898911d",
            "outputDimensions": [1600, 1600],
            "alignment": "center",
            "cropping": False,
            "nonUniformScaling": False,
            "runtimeGlyphSource": "production Script renderer",
            "runtimeSealSource": "user-selected production Seal",
        },
    },
    "magenta-matte-high-contrast-v1": {
        "operations": [
            "soft-magenta-matte",
            "three-by-three-median-edge-cleanup",
            "partial-alpha-magenta-despill",
            "lanczos-resize",
            "fixed-high-contrast-transform",
        ],
        "parameters": {
            "color": 0.55,
            "contrast": 1.48,
            "sharpness": 1.1,
            "innerFaceInsetRatios": [0.14, 0.18, 0.14, 0.17],
            "innerFaceLuminanceScale": 0.09,
            "innerFaceLuminanceCeiling": 24,
            "innerFaceFeatherRatio": 0.008,
        },
    },
    "authority-exact-byte-copy-v1": {
        "operations": [
            "validate-source-png",
            "copy-authority-bytes-without-transformation",
        ],
        "parameters": {
            "cropping": False,
            "resizing": False,
            "reencoding": False,
            "byteIdentity": True,
        },
    },
    "lossless-alpha-pdf-wrapper-v1": {
        "operations": ["rgb-channel-extraction", "alpha-soft-mask", "flate-pdf-wrapper"],
        "parameters": {
            "colorFilter": "FlateDecode",
            "alphaFilter": "FlateDecode",
            "bitsPerComponent": 8,
            "lossyEncoding": False,
        },
    },
    "frame-static-fallback-v1": {
        "operations": [
            "soft-magenta-matte",
            "partial-alpha-magenta-despill",
            "lanczos-resize",
        ],
        "parameters": {"cropping": False, "longEdge": 1600},
    },
    "crest-static-fallback-v1": {
        "operations": [
            "soft-magenta-matte",
            "partial-alpha-magenta-despill",
            "lanczos-resize",
        ],
        "parameters": {"cropping": False, "dimensions": [1024, 1024]},
    },
    "crest-thumbnail-v1": {
        "operations": [
            "soft-magenta-matte",
            "partial-alpha-magenta-despill",
            "lanczos-resize",
        ],
        "parameters": {"cropping": False, "dimensions": [512, 512]},
    },
    "background-static-normalization-v1": {
        "operations": ["rgb-normalization", "lanczos-resize"],
        "parameters": {"motion": False},
    },
    "background-high-contrast-v1": {
        "operations": [
            "rgb-normalization",
            "lanczos-resize",
            "fixed-high-contrast-transform",
        ],
        "parameters": {"color": 0.82, "contrast": 1.3, "sharpness": 1.08},
    },
    "background-macos-wide-crop-v1": {
        "operations": ["rgb-normalization", "center-crop-16-by-10", "lanczos-resize"],
        "parameters": {"alignment": "center", "cropping": True},
    },
    "codex-card-owned-v1": {
        "operations": ["rgb-normalization", "center-fit-16-by-9", "lanczos-resize"],
        "parameters": {"brightness": 1.0, "color": 1.0, "contrast": 1.0},
    },
    "codex-card-locked-v1": {
        "operations": ["center-fit-16-by-9", "grayscale", "fixed-state-transform"],
        "parameters": {"brightness": 0.46, "contrast": 1.08},
    },
    "codex-card-encountered-v1": {
        "operations": ["center-fit-16-by-9", "fixed-state-transform"],
        "parameters": {"brightness": 0.78, "color": 0.55, "contrast": 0.95},
    },
    "codex-card-selected-v1": {
        "operations": ["center-fit-16-by-9", "fixed-state-transform"],
        "parameters": {"brightness": 1.06, "color": 1.06, "contrast": 1.16},
    },
    "codex-card-unavailable-v1": {
        "operations": ["center-fit-16-by-9", "grayscale", "fixed-state-transform"],
        "parameters": {"brightness": 0.3, "contrast": 0.82},
    },
    "panel-card-border-v1": {
        "operations": ["magenta-matte", "nine-slice-frame-composition"],
        "parameters": {"dimensions": [1600, 900], "transparentInterior": True},
    },
    "panel-corner-ornament-v1": {
        "operations": ["magenta-matte", "top-left-ornament-crop", "lanczos-resize"],
        "parameters": {"dimensions": [512, 512]},
    },
    "panel-divider-v1": {
        "operations": ["magenta-matte", "top-rail-crop", "aspect-fit-transparent-pad"],
        "parameters": {"dimensions": [1600, 240]},
    },
    "panel-primary-button-v1": {
        "operations": [
            "codex-card-center-fit",
            "fixed-state-transform",
            "nine-slice-frame-composition",
        ],
        "parameters": {"dimensions": [1200, 320]},
    },
    "panel-tab-selector-v1": {
        "operations": [
            "codex-card-center-fit",
            "fixed-state-transform",
            "nine-slice-frame-composition",
        ],
        "parameters": {"dimensions": [1200, 240]},
    },
    "script-specimen-standard-v1": {
        "operations": ["validate-32-glyph-mapping", "freetype-rasterization"],
        "parameters": {"dimensions": [1600, 600], "glyphOrder": "U+16A0-through-U+16BF"},
    },
    "script-specimen-high-contrast-v1": {
        "operations": ["validate-32-glyph-mapping", "freetype-rasterization"],
        "parameters": {
            "dimensions": [1600, 600],
            "glyphOrder": "U+16A0-through-U+16BF",
            "palette": "black-and-white",
        },
    },
    "script-specimen-static-fallback-v1": {
        "operations": ["validate-32-glyph-mapping", "freetype-rasterization"],
        "parameters": {
            "dimensions": [1600, 600],
            "glyphOrder": "U+16A0-through-U+16BF",
            "motion": False,
        },
    },
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _clamp_unit(value: float) -> float:
    return max(0.0, min(1.0, value))


def _smoothstep(value: float) -> float:
    value = _clamp_unit(value)
    return value * value * (3.0 - 2.0 * value)


def _key_strength(red: int, green: int, blue: int) -> float:
    minimum_magenta = min(red, blue)
    balance = abs(red - blue)
    return _smoothstep(
        min(
            _clamp_unit((minimum_magenta - 130.0) / 80.0),
            _clamp_unit((minimum_magenta - green - 40.0) / 90.0),
            _clamp_unit((120.0 - balance) / 80.0),
        )
    )


def _normalized_rgba(image: Image.Image) -> Image.Image:
    return image.convert("RGBA")


def _pixel_data(image: Image.Image) -> Iterable[Any]:
    flattened = getattr(image, "get_flattened_data", None)
    return flattened() if flattened is not None else image.getdata()


def _clear_fully_transparent_rgb(image: Image.Image) -> Image.Image:
    rgba = _normalized_rgba(image)
    cleaned: list[tuple[int, int, int, int]] = []
    for red, green, blue, alpha in _pixel_data(rgba):
        if alpha == 0:
            cleaned.append((0, 0, 0, 0))
        else:
            cleaned.append((red, green, blue, alpha))
    result = Image.new("RGBA", rgba.size, (0, 0, 0, 0))
    result.putdata(cleaned)
    return result


def _despill_partial_alpha(image: Image.Image) -> Image.Image:
    rgba = _clear_fully_transparent_rgb(image)
    cleaned: list[tuple[int, int, int, int]] = []
    for red, green, blue, alpha in _pixel_data(rgba):
        if 0 < alpha < 255:
            spill = max(0, min(red, blue) - green)
            cleaned.append((max(0, red - spill), green, max(0, blue - spill), alpha))
        else:
            cleaned.append((red, green, blue, alpha))
    result = Image.new("RGBA", rgba.size, (0, 0, 0, 0))
    result.putdata(cleaned)
    return result


def chroma_key_magenta(image: Image.Image) -> Image.Image:
    """Extract a soft matte, clean its edge, and remove partial-alpha magenta spill."""

    rgb = image.convert("RGB")
    alpha_values = [
        int(round(255.0 * (1.0 - _key_strength(red, green, blue))))
        for red, green, blue in _pixel_data(rgb)
    ]
    alpha = Image.new("L", rgb.size, 255)
    alpha.putdata(alpha_values)
    alpha = alpha.filter(ImageFilter.MedianFilter(size=3))
    clamp = tuple(0 if value <= 6 else 255 if value >= 249 else value for value in range(256))
    alpha = alpha.point(clamp)

    despilled: list[tuple[int, int, int, int]] = []
    for (red, green, blue), opacity in zip(_pixel_data(rgb), _pixel_data(alpha)):
        if opacity == 0:
            despilled.append((0, 0, 0, 0))
            continue
        despilled.append((red, green, blue, opacity))
    result = Image.new("RGBA", rgb.size, (0, 0, 0, 0))
    result.putdata(despilled)
    return _despill_partial_alpha(result)


def resize_exact(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    resized = image.resize(size, resample=RESAMPLING)
    if resized.mode == "RGBA":
        return _despill_partial_alpha(resized)
    return resized


def contain_rgba(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    contained = ImageOps.contain(_normalized_rgba(image), size, method=RESAMPLING)
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    offset = ((size[0] - contained.width) // 2, (size[1] - contained.height) // 2)
    canvas.alpha_composite(contained, offset)
    return _despill_partial_alpha(canvas)


def pad_rgba_without_cropping(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    rgba = _normalized_rgba(image)
    if rgba.width > size[0] or rgba.height > size[1]:
        raise ValueError(
            f"source {rgba.width}x{rgba.height} exceeds no-crop canvas {size[0]}x{size[1]}"
        )
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    offset = ((size[0] - rgba.width) // 2, (size[1] - rgba.height) // 2)
    canvas.alpha_composite(rgba, offset)
    return _clear_fully_transparent_rgb(canvas)


def pad_rgba_with_minimum_margin(
    image: Image.Image,
    size: tuple[int, int],
    margin: int,
) -> Image.Image:
    if margin <= 0 or margin * 2 >= min(size):
        raise ValueError("minimum margin must leave a positive inner canvas")
    inner_size = (size[0] - margin * 2, size[1] - margin * 2)
    contained = ImageOps.contain(_normalized_rgba(image), inner_size, method=RESAMPLING)
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    offset = ((size[0] - contained.width) // 2, (size[1] - contained.height) // 2)
    canvas.alpha_composite(contained, offset)
    return _clear_fully_transparent_rgb(canvas)


def high_contrast_rgba(image: Image.Image) -> Image.Image:
    rgba = _normalized_rgba(image)
    alpha = rgba.getchannel("A")
    rgb = rgba.convert("RGB")
    rgb = ImageEnhance.Color(rgb).enhance(0.55)
    rgb = ImageEnhance.Contrast(rgb).enhance(1.48)
    rgb = ImageEnhance.Sharpness(rgb).enhance(1.1)

    bounds = alpha.getbbox()
    if bounds is not None:
        left, top, right, bottom = bounds
        width = right - left
        height = bottom - top
        face_bounds = (
            left + round(width * 0.14),
            top + round(height * 0.18),
            right - round(width * 0.14),
            bottom - round(height * 0.17),
        )
        if face_bounds[2] > face_bounds[0] and face_bounds[3] > face_bounds[1]:
            mask = Image.new("L", rgba.size, 0)
            radius = max(1, round(min(width, height) * 0.06))
            ImageDraw.Draw(mask).rounded_rectangle(face_bounds, radius=radius, fill=255)
            feather = max(1, round(min(width, height) * 0.008))
            mask = mask.filter(ImageFilter.GaussianBlur(radius=feather))
            mask = Image.composite(mask, Image.new("L", rgba.size, 0), alpha)

            luminance = ImageOps.grayscale(rgb).point(
                lambda value: min(24, round(value * 0.09))
            )
            dark_face = Image.merge("RGB", (luminance, luminance, luminance))
            rgb = Image.composite(dark_face, rgb, mask)
    red, green, blue = rgb.split()
    return _despill_partial_alpha(Image.merge("RGBA", (red, green, blue, alpha)))


def high_contrast_background(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGB")
    rgb = ImageEnhance.Color(rgb).enhance(0.82)
    rgb = ImageEnhance.Contrast(rgb).enhance(1.3)
    return ImageEnhance.Sharpness(rgb).enhance(1.08)


def codex_card_variant(image: Image.Image, state: str) -> Image.Image:
    base = ImageOps.fit(
        image.convert("RGB"),
        (1600, 900),
        method=RESAMPLING,
        centering=(0.5, 0.5),
    )
    if state == "owned":
        return base
    if state in {"locked", "unavailable"}:
        result = ImageOps.grayscale(base).convert("RGB")
        if state == "locked":
            result = ImageEnhance.Contrast(result).enhance(1.08)
            return ImageEnhance.Brightness(result).enhance(0.46)
        result = ImageEnhance.Contrast(result).enhance(0.82)
        return ImageEnhance.Brightness(result).enhance(0.3)
    if state == "encountered":
        result = ImageEnhance.Color(base).enhance(0.55)
        result = ImageEnhance.Contrast(result).enhance(0.95)
        return ImageEnhance.Brightness(result).enhance(0.78)
    if state == "selected":
        result = ImageEnhance.Color(base).enhance(1.06)
        result = ImageEnhance.Contrast(result).enhance(1.16)
        return ImageEnhance.Brightness(result).enhance(1.06)
    raise ValueError(f"unsupported Codex-card state: {state}")


def nine_slice_frame(
    frame: Image.Image,
    size: tuple[int, int],
    border: int,
) -> Image.Image:
    source = _normalized_rgba(frame)
    if border * 2 >= min(size):
        raise ValueError("nine-slice border must leave a positive center")
    inset = max(1, int(round(min(source.size) * 0.23)))
    if inset * 2 >= min(source.size):
        raise ValueError("nine-slice source inset is too large")
    width, height = source.size
    target_width, target_height = size
    result = Image.new("RGBA", size, (0, 0, 0, 0))

    slices = (
        ((0, 0, inset, inset), (0, 0, border, border)),
        ((width - inset, 0, width, inset), (target_width - border, 0, target_width, border)),
        (
            (0, height - inset, inset, height),
            (0, target_height - border, border, target_height),
        ),
        (
            (width - inset, height - inset, width, height),
            (target_width - border, target_height - border, target_width, target_height),
        ),
        ((inset, 0, width - inset, inset), (border, 0, target_width - border, border)),
        (
            (inset, height - inset, width - inset, height),
            (border, target_height - border, target_width - border, target_height),
        ),
        ((0, inset, inset, height - inset), (0, border, border, target_height - border)),
        (
            (width - inset, inset, width, height - inset),
            (target_width - border, border, target_width, target_height - border),
        ),
    )
    for source_box, target_box in slices:
        target_size = (target_box[2] - target_box[0], target_box[3] - target_box[1])
        piece = resize_exact(source.crop(source_box), target_size)
        result.alpha_composite(piece, (target_box[0], target_box[1]))
    return _clear_fully_transparent_rgb(result)


def panel_ornament(frame: Image.Image, card: Image.Image, variant: str) -> Image.Image:
    keyed_frame = _normalized_rgba(frame)
    if variant == "card-border":
        return nine_slice_frame(keyed_frame, (1600, 900), 150)
    if variant == "corner-ornament":
        side = int(round(min(keyed_frame.size) * 0.42))
        return resize_exact(keyed_frame.crop((0, 0, side, side)), (512, 512))
    if variant == "divider":
        rail_height = int(round(keyed_frame.height * 0.18))
        rail = keyed_frame.crop((0, 0, keyed_frame.width, rail_height))
        return resize_exact(rail, (1600, 240))
    if variant in {"primary-button", "tab-selector"}:
        size = (1200, 320) if variant == "primary-button" else (1200, 240)
        base = ImageOps.fit(card.convert("RGB"), size, method=RESAMPLING, centering=(0.5, 0.5))
        if variant == "primary-button":
            base = ImageEnhance.Contrast(base).enhance(1.12)
            base = ImageEnhance.Brightness(base).enhance(0.82)
            border = 68
        else:
            base = ImageEnhance.Color(base).enhance(0.7)
            base = ImageEnhance.Brightness(base).enhance(0.62)
            border = 50
        result = base.convert("RGBA")
        result.alpha_composite(nine_slice_frame(keyed_frame, size, border))
        return _clear_fully_transparent_rgb(result)
    raise ValueError(f"unsupported panel ornament: {variant}")


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_script_contract(repo_root: Path) -> tuple[list[str], Path]:
    mapping_path = repo_root / SCRIPT_MAPPING_RELATIVE
    font_path = repo_root / FONT_RELATIVE
    try:
        mapping = json.loads(
            mapping_path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except (json.JSONDecodeError, OSError) as error:
        raise ValueError(f"unable to read Script mapping: {error}") from error
    glyphs = mapping.get("glyphs") if isinstance(mapping, dict) else None
    if not isinstance(glyphs, list) or len(glyphs) != 32:
        raise ValueError("Script mapping must contain exactly 32 glyphs")
    expected_tokens = [chr(0x16A0 + value) for value in range(32)]
    for value, (record, token) in enumerate(zip(glyphs, expected_tokens)):
        expected = {
            "value": value,
            "glyphID": f"base-rune-{value:02d}",
            "textToken": token,
            "unicodeScalar": f"U+{0x16A0 + value:04X}",
        }
        if record != expected:
            raise ValueError(f"Script mapping glyph {value} differs from the exact contract")
    rendering_font = mapping.get("renderingFont")
    if not isinstance(rendering_font, dict):
        raise ValueError("Script mapping lacks renderingFont")
    if rendering_font.get("repositorySourcePath") != str(FONT_RELATIVE):
        raise ValueError("Script mapping font path differs from the repository font")
    if not font_path.is_file() or font_path.is_symlink():
        raise ValueError(f"missing regular Script font: {FONT_RELATIVE}")
    if rendering_font.get("sha256") != sha256_file(font_path):
        raise ValueError("Script font digest differs from the mapping contract")
    return expected_tokens, font_path


def script_specimen(repo_root: Path, variant: str) -> Image.Image:
    tokens, font_path = load_script_contract(repo_root)
    palette = {
        "standard": ((11, 22, 31), (220, 187, 125), (83, 68, 45)),
        "high-contrast": ((0, 0, 0), (255, 255, 255), (255, 255, 255)),
        "static-fallback": ((18, 25, 31), (213, 218, 220), (74, 83, 88)),
    }
    if variant not in palette:
        raise ValueError(f"unsupported Script specimen variant: {variant}")
    background, foreground, rule = palette[variant]
    image = Image.new("RGB", (1600, 600), background)
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype(str(font_path), 92)
    cell_width, cell_height = 200, 150
    for column in range(1, 8):
        x = column * cell_width
        draw.line((x, 0, x, image.height), fill=rule, width=2)
    for row in range(1, 4):
        y = row * cell_height
        draw.line((0, y, image.width, y), fill=rule, width=2)
    for index, token in enumerate(tokens):
        column = index % 8
        row = index // 8
        bounds = draw.textbbox((0, 0), token, font=font)
        glyph_width = bounds[2] - bounds[0]
        glyph_height = bounds[3] - bounds[1]
        x = column * cell_width + (cell_width - glyph_width) // 2 - bounds[0]
        y = row * cell_height + (cell_height - glyph_height) // 2 - bounds[1]
        draw.text((x, y), token, fill=foreground, font=font)
    return image


def lossless_pdf_bytes(image: Image.Image) -> bytes:
    rgba = _normalized_rgba(image)
    width, height = rgba.size
    rgb_data = rgba.convert("RGB").tobytes()
    alpha_data = rgba.getchannel("A").tobytes()
    rgb_stream = zlib.compress(rgb_data, level=9)
    alpha_stream = zlib.compress(alpha_data, level=9)
    content = f"q\n{width} 0 0 {height} 0 0 cm\n/Im0 Do\nQ\n".encode("ascii")

    objects = (
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] "
            "/Resources << /XObject << /Im0 4 0 R >> >> /Contents 6 0 R >>"
        ).encode("ascii"),
        (
            f"<< /Type /XObject /Subtype /Image /Width {width} /Height {height} "
            "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode "
            f"/SMask 5 0 R /Length {len(rgb_stream)} >>\nstream\n"
        ).encode("ascii")
        + rgb_stream
        + b"\nendstream",
        (
            f"<< /Type /XObject /Subtype /Image /Width {width} /Height {height} "
            "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode "
            f"/Length {len(alpha_stream)} >>\nstream\n"
        ).encode("ascii")
        + alpha_stream
        + b"\nendstream",
        f"<< /Length {len(content)} >>\nstream\n".encode("ascii")
        + content
        + b"endstream",
    )
    result = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for number, value in enumerate(objects, start=1):
        offsets.append(len(result))
        result.extend(f"{number} 0 obj\n".encode("ascii"))
        result.extend(value)
        result.extend(b"\nendobj\n")
    xref_offset = len(result)
    result.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    result.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        result.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    result.extend(
        (
            f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref_offset}\n%%EOF\n"
        ).encode("ascii")
    )
    return bytes(result)


def save_lossless_pdf(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        temporary.write_bytes(lossless_pdf_bytes(image))
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def planned_outputs() -> list[dict[str, Any]]:
    outputs: list[dict[str, Any]] = []
    for slug, source, master_size in RELICS:
        resource_id = f"relic.norse.{slug}"
        thumbnail_source = CATALOG_PORTRAIT_SOURCE if slug == "runestone-tablet" else source
        thumbnail_recipe = (
            "owner-board-portrait-catalog-thumbnail-v1"
            if slug == "runestone-tablet"
            else "magenta-matte-contain-v1"
        )
        thumbnail_kind = (
            "relic-catalog-thumbnail"
            if slug == "runestone-tablet"
            else "relic-thumbnail"
        )
        thumbnail_additional_sources = (
            [CATALOG_OWNER_REGION_SOURCE, source]
            if slug == "runestone-tablet"
            else []
        )
        static_share_source = (
            f"@repo/{RUNESTONE_MESSAGE_OWNER_REGION_RELATIVE}"
            if slug == "runestone-tablet"
            else source
        )
        static_share_additional_sources = (
            [
                f"@repo/{RUNESTONE_MESSAGE_BLANK_STONE_RELATIVE}",
                f"@repo/{RUNESTONE_MESSAGE_EXTRACTOR_RELATIVE}",
            ]
            if slug == "runestone-tablet"
            else []
        )
        static_share_recipe = (
            "owner-board-near-square-message-static-fallback-v1"
            if slug == "runestone-tablet"
            else "magenta-matte-contain-v1"
        )
        static_share_size = (
            (1600, 1600) if slug == "runestone-tablet" else (1600, 1200)
        )
        static_share_kind = (
            "relic-message-static-share"
            if slug == "runestone-tablet"
            else "relic-static-share"
        )
        outputs.extend(
            (
                {
                    "path": f"Relics/{resource_id}.png",
                    "source": source,
                    "targetPath": f"Relics/{resource_id}.png",
                    "resourceID": resource_id,
                    "variant": "standard",
                    "recipeID": "magenta-matte-standard-v1",
                    "size": master_size,
                    "kind": "relic-standard",
                },
                {
                    "path": f"Relics/{resource_id}.thumbnail.png",
                    "source": thumbnail_source,
                    "additionalSources": thumbnail_additional_sources,
                    "targetPath": f"Relics/{resource_id}.thumbnail.png",
                    "resourceID": resource_id,
                    "variant": "thumbnail-512",
                    "recipeID": thumbnail_recipe,
                    "size": (512, 512),
                    "kind": thumbnail_kind,
                },
                {
                    "path": f"ShareFallbacks/share-fallback.norse.{slug}.png",
                    "source": static_share_source,
                    "additionalSources": static_share_additional_sources,
                    "targetPath": f"ShareFallbacks/share-fallback.norse.{slug}.png",
                    "resourceID": resource_id,
                    "variant": "static-share-fallback",
                    "recipeID": static_share_recipe,
                    "size": static_share_size,
                    "kind": static_share_kind,
                },
                {
                    "path": f"Relics/{resource_id}.high-contrast.png",
                    "source": source,
                    "targetPath": f"Relics/{resource_id}.high-contrast.png",
                    "resourceID": resource_id,
                    "variant": "high-contrast",
                    "recipeID": "magenta-matte-high-contrast-v1",
                    "size": master_size,
                    "kind": "relic-high-contrast",
                },
            )
        )

    for slug in SEALS:
        resource_id = f"seal.norse.{slug}"
        color_source = f"seals/{resource_id}.png"
        outputs.extend(
            (
                {
                    "path": f"Seals/{resource_id}.png",
                    "source": color_source,
                    "targetPath": f"Seals/{resource_id}.png",
                    "resourceID": resource_id,
                    "variant": "color-master",
                    "recipeID": "authority-exact-byte-copy-v1",
                    "size": SEAL_MASTER_SIZES[slug],
                    "kind": "seal-exact",
                    "byteIdentitySource": True,
                },
            )
        )
        for source_suffix, output_suffix, variant, size in (
            (".monochrome.png", ".monochrome.png", "monochrome", SEAL_MASTER_SIZES[slug]),
            (".thumbnail.png", ".thumbnail.png", "thumbnail-512", (512, 512)),
        ):
            filename = f"{resource_id}{output_suffix}"
            outputs.append(
                {
                    "path": f"Seals/{filename}",
                    "source": f"seals/{resource_id}{source_suffix}",
                    "targetPath": f"Seals/{filename}",
                    "resourceID": resource_id,
                    "variant": variant,
                    "recipeID": "authority-exact-byte-copy-v1",
                    "size": size,
                    "kind": "seal-exact",
                    "byteIdentitySource": True,
                }
            )

    outputs.extend(
        (
            {
                "path": "Intermediates/frame.norse.carved-knotwork.standard.png",
                "source": "mastery-frame-authoring.png",
                "targetPath": None,
                "promotionStatus": "derivation-only",
                "resourceID": "frame.norse.carved-knotwork",
                "variant": "standard-raster-intermediate",
                "recipeID": "magenta-matte-standard-v1",
                "size": (1639, 2048),
                "kind": "keyed-exact",
            },
            {
                "path": "Frame/frame.norse.carved-knotwork.static-fallback.png",
                "source": "mastery-frame-authoring.png",
                "targetPath": "Frame/frame.norse.carved-knotwork.static-fallback.png",
                "resourceID": "frame.norse.carved-knotwork",
                "variant": "static-fallback",
                "recipeID": "frame-static-fallback-v1",
                "size": (1280, 1600),
                "kind": "keyed-exact",
            },
            {
                "path": "Frame/frame.norse.carved-knotwork.vector-master.pdf",
                "source": "mastery-frame-authoring.png",
                "targetPath": "Frame/frame.norse.carved-knotwork.vector-master.pdf",
                "resourceID": "frame.norse.carved-knotwork",
                "variant": "standard",
                "recipeID": "lossless-alpha-pdf-wrapper-v1",
                "inputPreparationRecipeID": "magenta-matte-standard-v1",
                "size": (1639, 2048),
                "kind": "keyed-exact",
                "format": "pdf",
            },
            {
                "path": "Intermediates/crest.norse.raven-mastery.standard.png",
                "source": "raven-mastery-crest-authoring.png",
                "targetPath": None,
                "promotionStatus": "derivation-only",
                "resourceID": "crest.norse.raven-mastery",
                "variant": "standard-raster-intermediate",
                "recipeID": "magenta-matte-standard-v1",
                "size": (2048, 2048),
                "kind": "keyed-exact",
            },
            {
                "path": "Crest/crest.norse.raven-mastery.static-fallback.png",
                "source": "raven-mastery-crest-authoring.png",
                "targetPath": "Crest/crest.norse.raven-mastery.static-fallback.png",
                "resourceID": "crest.norse.raven-mastery",
                "variant": "static-fallback",
                "recipeID": "crest-static-fallback-v1",
                "size": (1024, 1024),
                "kind": "keyed-exact",
            },
            {
                "path": "Crest/crest.norse.raven-mastery.thumbnail.png",
                "source": "raven-mastery-crest-authoring.png",
                "targetPath": "Crest/crest.norse.raven-mastery.thumbnail.png",
                "resourceID": "crest.norse.raven-mastery",
                "variant": "thumbnail-512",
                "recipeID": "crest-thumbnail-v1",
                "size": (512, 512),
                "kind": "keyed-exact",
            },
            {
                "path": "Crest/crest.norse.raven-mastery.vector-master.pdf",
                "source": "raven-mastery-crest-authoring.png",
                "targetPath": "Crest/crest.norse.raven-mastery.vector-master.pdf",
                "resourceID": "crest.norse.raven-mastery",
                "variant": "standard",
                "recipeID": "lossless-alpha-pdf-wrapper-v1",
                "inputPreparationRecipeID": "magenta-matte-standard-v1",
                "size": (2048, 2048),
                "kind": "keyed-exact",
                "format": "pdf",
            },
        )
    )

    background_id = "background.norse.cold-sea-hall"
    for variant, filename, recipe_id, size, kind in (
        (
            "standard",
            f"{background_id}.standard.png",
            "background-static-normalization-v1",
            (3072, 2048),
            "background-standard",
        ),
        (
            "reduce-motion",
            f"{background_id}.reduce-motion.png",
            "background-static-normalization-v1",
            (3072, 2048),
            "background-reduce-motion",
        ),
        (
            "high-contrast",
            f"{background_id}.high-contrast.png",
            "background-high-contrast-v1",
            (3072, 2048),
            "background-high-contrast",
        ),
        (
            "macos-wide-crop",
            f"{background_id}.macos-wide-crop.png",
            "background-macos-wide-crop-v1",
            (3072, 1920),
            "background-macos-wide",
        ),
    ):
        outputs.append(
            {
                "path": f"Background/{filename}",
                "source": "cold-sea-hall-authoring.png",
                "targetPath": f"Background/{filename}",
                "resourceID": background_id,
                "variant": variant,
                "recipeID": recipe_id,
                "size": size,
                "kind": kind,
            }
        )

    for state in CARD_STATES:
        outputs.append(
            {
                "path": f"CodexCard/codex-card.norse.{state}.png",
                "source": "codex-card-authoring.png",
                "targetPath": f"CodexCard/codex-card.norse.{state}.png",
                "resourceID": "codex.norse",
                "variant": state,
                "recipeID": f"codex-card-{state}-v1",
                "size": (1600, 900),
                "kind": "codex-card",
            }
        )

    for variant, size in (
        ("card-border", (1600, 900)),
        ("corner-ornament", (512, 512)),
        ("divider", (1600, 240)),
        ("primary-button", (1200, 320)),
        ("tab-selector", (1200, 240)),
    ):
        spec = {
            "path": f"Panel/panel.norse.{variant}.png",
            "source": "mastery-frame-authoring.png",
            "targetPath": f"Panel/panel.norse.{variant}.png",
            "resourceID": f"panel.norse.{variant}",
            "variant": variant,
            "recipeID": f"panel-{variant}-v1",
            "size": size,
            "kind": "panel-ornament",
        }
        if variant in {"primary-button", "tab-selector"}:
            spec["additionalSources"] = ["codex-card-authoring.png"]
        outputs.append(spec)

    for variant in ("standard", "high-contrast", "static-fallback"):
        outputs.append(
            {
                "path": f"Script/script.base-runes.specimen.{variant}.png",
                "source": f"@repo/{FONT_RELATIVE}",
                "additionalSources": [f"@repo/{SCRIPT_MAPPING_RELATIVE}"],
                "targetPath": f"Script/script.base-runes.specimen.{variant}.png",
                "resourceID": "script.base-runes",
                "variant": variant,
                "recipeID": f"script-specimen-{variant}-v1",
                "size": (1600, 600),
                "kind": "script-specimen",
            }
        )
    return outputs


def required_sources() -> tuple[str, ...]:
    references = {
        reference
        for item in planned_outputs()
        for reference in (str(item["source"]), *map(str, item.get("additionalSources", [])))
        if not reference.startswith("@repo/")
    }
    return tuple(sorted(references))


def required_source_references() -> tuple[str, ...]:
    return tuple(
        sorted(
            {
                reference
                for item in planned_outputs()
                for reference in (
                    str(item["source"]),
                    *map(str, item.get("additionalSources", [])),
                )
            }
        )
    )


def _is_magenta_key_pixel(pixel: tuple[int, int, int]) -> bool:
    return _key_strength(*pixel) >= 0.9


def _source_path(
    legacy_source_root: Path,
    v43_source_root: Path,
    relative: str,
) -> Path:
    root = v43_source_root if relative in V43_SOURCE_FILES else legacy_source_root
    return root / relative


def validate_sources(
    legacy_source_root: Path,
    v43_source_root: Path | None = None,
) -> None:
    v43_source_root = legacy_source_root if v43_source_root is None else v43_source_root
    failures: list[str] = []
    keyed_sources = {
        source for _, source, _ in RELICS
    } | {"mastery-frame-authoring.png", "raven-mastery-crest-authoring.png"}
    for relative in required_sources():
        path = _source_path(legacy_source_root, v43_source_root, relative)
        if not path.is_file() or path.is_symlink():
            failures.append(f"missing regular source: {relative}")
            continue
        try:
            with Image.open(path) as image:
                image.verify()
            with Image.open(path) as image:
                if image.format != "PNG":
                    failures.append(f"source is not PNG: {relative}")
                    continue
                if image.width <= 0 or image.height <= 0:
                    failures.append(f"source has invalid dimensions: {relative}")
                if relative in keyed_sources:
                    rgb = image.convert("RGB")
                    corners = (
                        rgb.getpixel((0, 0)),
                        rgb.getpixel((rgb.width - 1, 0)),
                        rgb.getpixel((0, rgb.height - 1)),
                        rgb.getpixel((rgb.width - 1, rgb.height - 1)),
                    )
                    if sum(_is_magenta_key_pixel(pixel) for pixel in corners) < 3:
                        failures.append(f"source lacks the expected magenta authoring matte: {relative}")
                if relative == CATALOG_PORTRAIT_SOURCE:
                    if image.mode != "RGBA" or image.size != (768, 1024):
                        failures.append(
                            "Runestone catalog authoring source must be 768x1024 RGBA"
                        )
                    elif image.getchannel("A").getextrema() != (0, 255):
                        failures.append(
                            "Runestone catalog authoring source must contain true alpha"
                        )
                    elif sha256_file(path) != RECIPE_DEFINITIONS[
                        "owner-board-portrait-catalog-thumbnail-v1"
                    ]["parameters"]["glyphFreeAuthoringSHA256"]:
                        failures.append("Runestone catalog authoring source digest differs")
                if relative == CATALOG_OWNER_REGION_SOURCE:
                    if image.size != (142, 185):
                        failures.append("Runestone catalog owner region dimensions differ")
                    elif sha256_file(path) != RECIPE_DEFINITIONS[
                        "owner-board-portrait-catalog-thumbnail-v1"
                    ]["parameters"]["storedOwnerRegionSHA256"]:
                        failures.append("Runestone catalog owner region digest differs")
                if relative.startswith("seals/"):
                    if image.mode != "RGBA" or image.getchannel("A").getextrema() != (0, 255):
                        failures.append(f"Seal source must contain true alpha: {relative}")
                    limit = 512 if relative.endswith(".thumbnail.png") else 1024
                    if image.width > limit or image.height > limit:
                        failures.append(
                            f"Seal source exceeds its no-crop {limit}-pixel canvas: {relative}"
                        )
        except (OSError, ValueError) as error:
            failures.append(f"unable to read source {relative}: {error}")
    if failures:
        raise ValueError("; ".join(failures))


def _load_normalized(
    legacy_source_root: Path,
    v43_source_root: Path,
    relative: str,
) -> Image.Image:
    with Image.open(_source_path(legacy_source_root, v43_source_root, relative)) as image:
        if relative.startswith("seals/") or relative == CATALOG_PORTRAIT_SOURCE:
            return image.convert("RGBA")
        return image.convert("RGB")


def _source_record(
    legacy_source_root: Path,
    v43_source_root: Path,
    relative: str,
) -> dict[str, Any]:
    path = _source_path(legacy_source_root, v43_source_root, relative)
    recorded_root = (
        V43_SOURCE_ROOT_RELATIVE
        if relative in V43_SOURCE_FILES
        else LEGACY_SOURCE_ROOT_RELATIVE
    )
    with Image.open(path) as image:
        alpha = image.getchannel("A") if "A" in image.getbands() else None
        return {
            "path": str(recorded_root / relative),
            "sha256": sha256_file(path),
            "pixelDimensions": {"width": image.width, "height": image.height},
            "mode": image.mode,
            "alpha": _alpha_record(alpha),
        }


def _repository_source_record(repo_root: Path, reference: str) -> dict[str, Any]:
    if not reference.startswith("@repo/"):
        raise ValueError(f"invalid repository source reference: {reference}")
    relative = Path(reference.removeprefix("@repo/"))
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"unsafe repository source reference: {reference}")
    path = repo_root / relative
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"missing regular repository source: {relative}")
    media_type = {
        ".json": "application/json",
        ".ttf": "font/ttf",
    }.get(path.suffix.lower(), "application/octet-stream")
    return {
        "path": str(relative),
        "sha256": sha256_file(path),
        "mediaType": media_type,
        "alpha": {"present": False},
    }


def _alpha_record(alpha: Image.Image | None) -> dict[str, Any]:
    if alpha is None:
        return {"present": False}
    histogram = alpha.histogram()
    minimum, maximum = alpha.getextrema()
    return {
        "present": True,
        "extrema": [minimum, maximum],
        "transparentPixelCount": histogram[0],
        "partialAlphaPixelCount": sum(histogram[1:255]),
        "opaquePixelCount": histogram[255],
    }


def _output_record(
    path: Path,
    spec: dict[str, Any],
    source_records: list[dict[str, Any]],
    rendered: Image.Image,
) -> dict[str, Any]:
    primary = source_records[0]
    alpha = rendered.getchannel("A") if "A" in rendered.getbands() else None
    target_relative = spec.get("targetPath")
    record = {
        "path": str(OUTPUT_ROOT_RELATIVE / spec["path"]),
        "targetPath": (
            str(TARGET_ROOT_RELATIVE / str(target_relative))
            if target_relative is not None
            else None
        ),
        "promotionStatus": spec.get("promotionStatus", "candidate"),
        "resourceID": spec["resourceID"],
        "variant": spec["variant"],
        "recipeID": spec["recipeID"],
        "sourcePath": primary["path"],
        "sourceSHA256": primary["sha256"],
        "sourceInputs": [
            {"path": source["path"], "sha256": source["sha256"]}
            for source in source_records
        ],
        "sha256": sha256_file(path),
        "mediaType": "application/pdf" if path.suffix.lower() == ".pdf" else "image/png",
        "pixelDimensions": {"width": rendered.width, "height": rendered.height},
        "mode": rendered.mode,
        "alpha": _alpha_record(alpha),
    }
    if "inputPreparationRecipeID" in spec:
        record["inputPreparationRecipeID"] = spec["inputPreparationRecipeID"]
    if path.suffix.lower() == ".pdf":
        record["losslessRasterWrapper"] = True
        record["alpha"]["pdfRepresentation"] = "soft-mask"
    return record


def render_output(
    spec: dict[str, Any],
    repo_root: Path,
    legacy_source_root: Path,
    source_cache: dict[str, Image.Image],
    keyed_cache: dict[str, Image.Image],
    base_cache: dict[str, Image.Image],
    v43_source_root: Path | None = None,
) -> Image.Image:
    v43_source_root = (
        legacy_source_root if v43_source_root is None else v43_source_root
    )
    source_name = str(spec["source"])
    kind = str(spec["kind"])
    size = tuple(spec["size"])

    if kind == "script-specimen":
        return script_specimen(repo_root, str(spec["variant"]))
    if kind == "relic-message-static-share":
        extractor_path = repo_root / RUNESTONE_MESSAGE_EXTRACTOR_RELATIVE
        module_spec = importlib.util.spec_from_file_location(
            "norse_runestone_message_extractor_for_asset_builder",
            extractor_path,
        )
        if module_spec is None or module_spec.loader is None:
            raise ValueError(f"unable to load Runestone message extractor: {extractor_path}")
        extractor = importlib.util.module_from_spec(module_spec)
        sys.modules[module_spec.name] = extractor
        module_spec.loader.exec_module(extractor)
        owner_region, blank_stone = extractor.validate_stored_sources(repo_root)
        rendered = extractor.render_static_fallback(owner_region, blank_stone)
        if rendered.size != size or rendered.mode != "RGBA":
            raise ValueError("Runestone message fallback contract differs")
        return rendered
    if source_name.startswith("@repo/"):
        raise ValueError(f"non-image source used for image recipe: {source_name}")
    if source_name not in source_cache:
        source_cache[source_name] = _load_normalized(
            legacy_source_root,
            v43_source_root,
            source_name,
        )
    source = source_cache[source_name]

    if kind == "relic-catalog-thumbnail":
        return contain_rgba(source, size)
    if kind.startswith("relic-"):
        original_size = next(target for _, name, target in RELICS if name == source_name)
        master_key = f"{source_name}:{original_size[0]}x{original_size[1]}"
        if master_key not in base_cache:
            if source_name not in keyed_cache:
                keyed_cache[source_name] = chroma_key_magenta(source)
            keyed = keyed_cache[source_name]
            base_cache[master_key] = resize_exact(keyed, original_size)
        master = base_cache[master_key]
        if kind == "relic-standard":
            return master.copy()
        if kind == "relic-thumbnail" or kind == "relic-static-share":
            return contain_rgba(master, size)
        if kind == "relic-high-contrast":
            return high_contrast_rgba(master)

    if kind == "seal-exact":
        return source.copy()
    if kind == "keyed-exact":
        if source_name not in keyed_cache:
            keyed_cache[source_name] = chroma_key_magenta(source)
        keyed = keyed_cache[source_name]
        return resize_exact(keyed, size)
    if kind == "seal-pad":
        return pad_rgba_without_cropping(source, size)
    if kind == "seal-margin":
        margin = 24 if min(size) == 1024 else 12
        return pad_rgba_with_minimum_margin(source, size, margin)
    if kind.startswith("background-"):
        standard_key = "background-standard"
        if standard_key not in base_cache:
            base_cache[standard_key] = resize_exact(source.convert("RGB"), (3072, 2048))
        standard = base_cache[standard_key]
        if kind in {"background-standard", "background-reduce-motion"}:
            return standard.copy()
        if kind == "background-high-contrast":
            return high_contrast_background(standard)
        if kind == "background-macos-wide":
            return ImageOps.fit(
                source.convert("RGB"),
                size,
                method=RESAMPLING,
                centering=(0.5, 0.5),
            )
    if kind == "codex-card":
        return codex_card_variant(source, str(spec["variant"]))
    if kind == "panel-ornament":
        card_name = "codex-card-authoring.png"
        if card_name not in source_cache:
            source_cache[card_name] = _load_normalized(
                legacy_source_root,
                v43_source_root,
                card_name,
            )
        if source_name not in keyed_cache:
            keyed_cache[source_name] = chroma_key_magenta(source)
        return panel_ornament(
            keyed_cache[source_name],
            source_cache[card_name],
            str(spec["variant"]),
        )
    raise ValueError(f"unsupported output kind: {kind}")


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        image.save(temporary, format="PNG", **PNG_SAVE_OPTIONS)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def copy_exact_bytes(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.tmp")
    try:
        temporary.write_bytes(source.read_bytes())
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def _write_json(value: Any, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        temporary.write_text(
            json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _ensure_output_scope(output_root: Path, allowed: Iterable[str]) -> None:
    resolved = output_root.resolve()
    if resolved == Path(resolved.anchor):
        raise ValueError("output root cannot be a filesystem root")
    allowed_paths = {Path(value) for value in allowed} | {DERIVATION_RELATIVE}
    if not output_root.exists():
        return
    unexpected = sorted(
        str(path.relative_to(output_root))
        for path in output_root.rglob("*")
        if path.is_file()
        and not path.name.startswith(".")
        and path.relative_to(output_root) not in allowed_paths
    )
    if unexpected:
        raise ValueError("staging directory contains unexpected files: " + ", ".join(unexpected))


def build(
    repo_root: Path,
    legacy_source_root: Path,
    output_root: Path,
    v43_source_root: Path | None = None,
) -> Path:
    repo_root = repo_root.resolve()
    legacy_source_root = legacy_source_root.resolve()
    v43_source_root = (
        (repo_root / V43_SOURCE_ROOT_RELATIVE).resolve()
        if v43_source_root is None
        else v43_source_root.resolve()
    )
    output_root = output_root.resolve()
    if (
        legacy_source_root == v43_source_root
        or legacy_source_root == output_root
        or v43_source_root == output_root
        or legacy_source_root in output_root.parents
        or output_root in legacy_source_root.parents
        or v43_source_root in output_root.parents
        or output_root in v43_source_root.parents
    ):
        raise ValueError("source and output roots must be separate, non-nested directories")
    validate_sources(legacy_source_root, v43_source_root)
    load_script_contract(repo_root)
    plan = planned_outputs()
    _ensure_output_scope(output_root, (str(spec["path"]) for spec in plan))

    sources: dict[str, dict[str, Any]] = {}
    for reference in required_source_references():
        sources[reference] = (
            _repository_source_record(repo_root, reference)
            if reference.startswith("@repo/")
            else _source_record(legacy_source_root, v43_source_root, reference)
        )
    source_cache: dict[str, Image.Image] = {}
    keyed_cache: dict[str, Image.Image] = {}
    base_cache: dict[str, Image.Image] = {}
    output_records: list[dict[str, Any]] = []
    for spec in plan:
        relative = Path(str(spec["path"]))
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"unsafe staged output path: {relative}")
        destination = output_root / relative
        rendered = render_output(
            spec,
            repo_root,
            legacy_source_root,
            source_cache,
            keyed_cache,
            base_cache,
            v43_source_root=v43_source_root,
        )
        expected_size = tuple(spec["size"])
        if rendered.size != expected_size:
            raise ValueError(
                f"rendered dimensions differ for {relative}: {rendered.size} != {expected_size}"
            )
        if spec.get("byteIdentitySource") is True:
            source_reference = str(spec["source"])
            if source_reference.startswith("@repo/"):
                exact_source = repo_root / source_reference.removeprefix("@repo/")
            else:
                exact_source = _source_path(
                    legacy_source_root,
                    v43_source_root,
                    source_reference,
                )
            copy_exact_bytes(exact_source, destination)
        elif spec.get("format", "png") == "pdf":
            save_lossless_pdf(rendered, destination)
        else:
            save_png(rendered, destination)
        input_references = [
            str(spec["source"]),
            *map(str, spec.get("additionalSources", [])),
        ]
        output_records.append(
            _output_record(
                destination,
                spec,
                [sources[reference] for reference in input_references],
                rendered,
            )
        )

    builder_path = repo_root / BUILDER_RELATIVE
    document = {
        "schemaVersion": "1.0",
        "collectionID": "norse.production-asset-candidates.v4.3",
        "sourceRoots": {
            "legacyV4": str(LEGACY_SOURCE_ROOT_RELATIVE),
            "v4_3": str(V43_SOURCE_ROOT_RELATIVE),
        },
        "stagingRoot": str(OUTPUT_ROOT_RELATIVE),
        "targetRoot": str(TARGET_ROOT_RELATIVE),
        "derivation": {
            "builderPath": str(BUILDER_RELATIVE),
            "builderSHA256": sha256_file(builder_path),
            "deterministic": True,
            "nonessentialImageMetadata": "stripped",
        },
        "recipes": [
            {"recipeID": recipe_id, **RECIPE_DEFINITIONS[recipe_id]}
            for recipe_id in sorted(RECIPE_DEFINITIONS)
        ],
        "sources": [sources[path] for path in sorted(sources)],
        "outputs": sorted(output_records, key=lambda record: record["path"]),
    }
    derivation_path = output_root / DERIVATION_RELATIVE
    _write_json(document, derivation_path)
    return derivation_path


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=repo_root)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--v4-3-source-root", type=Path)
    parser.add_argument("--output-root", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    repo_root = arguments.repo_root.resolve()
    legacy_source_root = (
        arguments.source_root.resolve()
        if arguments.source_root is not None
        else repo_root / LEGACY_SOURCE_ROOT_RELATIVE
    )
    v43_source_root = (
        arguments.v4_3_source_root.resolve()
        if arguments.v4_3_source_root is not None
        else repo_root / V43_SOURCE_ROOT_RELATIVE
    )
    output_root = (
        arguments.output_root.resolve()
        if arguments.output_root is not None
        else repo_root / OUTPUT_ROOT_RELATIVE
    )
    try:
        derivation_path = build(
            repo_root,
            legacy_source_root,
            output_root,
            v43_source_root,
        )
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Built {len(planned_outputs())} Norse production-asset candidates")
    print(f"Derivation record: {derivation_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
