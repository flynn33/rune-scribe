#!/usr/bin/env python3
"""Build and verify the Moonleaf v4.3 production visual resource set."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

try:
    from scripts.theme_v43_background_master import (
        BackgroundMasterSpec,
        VARIANT_ADJUSTMENTS,
        load_background_master,
        output_layout_record,
        render_background_variant,
    )
    from scripts.theme_v43_accepted_masters import (
        CREST_SOURCE_MASTERS,
        FRAME_SLICE_POLICIES,
        FRAME_SOURCE_MASTERS,
        PANEL_CAP_INSETS,
        PANEL_TARGET_SIZES,
        SEAL_SOURCE_MASTERS,
        accepted_recipe_rights_id,
        aspect_fit_record,
        load_accepted_recipe,
        load_seal_source_master,
        load_source_master,
        panel_assets,
        panel_policy_record,
        render_nine_slice_frame,
        render_seal_variants,
        seal_render_recipe_record,
        uniform_aspect_fit,
    )
except ModuleNotFoundError:
    from theme_v43_background_master import (
        BackgroundMasterSpec,
        VARIANT_ADJUSTMENTS,
        load_background_master,
        output_layout_record,
        render_background_variant,
    )
    from theme_v43_accepted_masters import (
        CREST_SOURCE_MASTERS,
        FRAME_SLICE_POLICIES,
        FRAME_SOURCE_MASTERS,
        PANEL_CAP_INSETS,
        PANEL_TARGET_SIZES,
        SEAL_SOURCE_MASTERS,
        accepted_recipe_rights_id,
        aspect_fit_record,
        load_accepted_recipe,
        load_seal_source_master,
        load_source_master,
        panel_assets,
        panel_policy_record,
        render_nine_slice_frame,
        render_seal_variants,
        seal_render_recipe_record,
        uniform_aspect_fit,
    )

try:
    from scripts.moonleaf_received_identity_runtime_evidence import (
        RuntimeEvidenceError,
        qualification_document as received_identity_qualification_document,
    )
except ModuleNotFoundError:
    from moonleaf_received_identity_runtime_evidence import (  # type: ignore[no-redef]
        RuntimeEvidenceError,
        qualification_document as received_identity_qualification_document,
    )


MODULE_ID = "com.runescribe.module.theme.moonleaf"
CODEX_ID = "codex.moonleaf"
ACCEPTED_PACKAGE_VERSION = "4.3.0"
CREATED_AT = "2026-08-27T00:00:00Z"
PIPELINE = "scripts/build-moonleaf-v43-assets.py"
BACKGROUND_RENDERER = "scripts/theme_v43_background_master.py"
RECEIVED_IDENTITY_RIGHTS_ID = (
    "prov.Theme.Fidelity.v4.3.Source.Masters.moonleaf."
    "Moonleaf.Received.Identity.Extraction.v4.3.json"
)
RECEIVED_IDENTITY_EVIDENCE = (
    "docs/verification/theme-fidelity-v4-3/source-masters/moonleaf/"
    "Moonleaf-Received-Identity-Extraction-v4.3.json"
)

BACKGROUND_SOURCE_MASTER = BackgroundMasterSpec(
    relative_path=(
        "docs/verification/theme-fidelity-v4-3/source-masters/moonleaf/"
        "moonleaf-environment-production-master-v4.3.png"
    ),
    sha256="c159a92c2a65b70e2df6e2ce88ebe0c18230b0c88ab93ada381841c7b51d7373",
    focal_point=(0.5, 0.5),
)

OWNER_ARCHIVE_INPUTS = {
    "style-board": (
        "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/approved-source-full-002-1122x1402.png",
        "2d1696abd8a7ddbfe81b89c2eb84933a516ba5a4bf8eaa2dae0edcbb3d3758ef",
    ),
    "catalog": (
        "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/approved-source-full-022-941x1672.png",
        "cb49801223d93c34a3927a1a67a0b7c5428d28b1b55f6e1a1d737a2ecce33827",
    ),
}

MOONLEAF_SEALS = (
    "crescentleaf",
    "echo-firefly",
    "moonwell",
    "night-owl",
    "starflower",
    "woodland-stag",
)

REVIEW_EXPLANATION_KEYS = {"comment", "comments", "detail", "details", "note", "notes", "reason"}


@dataclass(frozen=True)
class ResourceSpec:
    resource_id: str
    relative_path: str
    role: str
    media_type: str
    maximum_bytes: int
    pixel_size: tuple[int, int] | None
    rights_id: str


def color_master_blockers(
    theme: str,
    required_seals: Sequence[str],
    available_seals: Iterable[str],
) -> list[dict[str, str]]:
    available = set(available_seals)
    return [
        {
            "asset": f"seal.{theme}.{slug}",
            "assetClass": "seal.color-master",
            "status": "BLOCKED",
            "reason": "A required detailed Seal color master is not present in the production asset set.",
        }
        for slug in required_seals
        if slug not in available
    ]


def _declared_quality_failures(value: Any, path: str) -> list[str]:
    failures: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "ownerReview":
                continue
            if key.casefold() in REVIEW_EXPLANATION_KEYS:
                continue
            failures.extend(_declared_quality_failures(child, f"{path}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            failures.extend(_declared_quality_failures(child, f"{path}[{index}]"))
    elif isinstance(value, bool):
        if not value:
            failures.append(f"{path} declares false")
    elif isinstance(value, str):
        status = value.strip().upper()
        if status not in {"PASS", "PASSED"}:
            failures.append(f"{path} declares {value!r}")
    return failures


def production_qualification_failures(
    provenance: dict[str, Any],
    *,
    resources: Path,
    manifest_records: Sequence[dict[str, Any]],
    theme: str,
    required_seals: Sequence[str],
    supporting_documents: Sequence[tuple[str, dict[str, Any]]] = (),
) -> list[str]:
    failures: list[str] = []
    blockers = provenance.get("blockers", [])
    if not isinstance(blockers, list):
        failures.append("provenance.blockers must be a list")
    elif blockers:
        failures.append(f"provenance records {len(blockers)} production blocker(s)")

    target_scale_review = provenance.get("targetScaleReview")
    if not isinstance(target_scale_review, dict):
        failures.append("provenance.targetScaleReview is absent")
    else:
        if target_scale_review.get("implementationReview") != "PASS":
            failures.append("provenance.targetScaleReview.implementationReview is not PASS")
        if target_scale_review.get("ownerReview") != "PENDING":
            failures.append("provenance.targetScaleReview.ownerReview must remain PENDING")
        failures.extend(_declared_quality_failures(target_scale_review, "provenance.targetScaleReview"))

    if "qualityReview" in provenance:
        failures.extend(_declared_quality_failures(provenance["qualityReview"], "provenance.qualityReview"))
    for label, document in supporting_documents:
        document_blockers = document.get("blockers", [])
        if not isinstance(document_blockers, list):
            failures.append(f"{label}.blockers must be a list")
        elif document_blockers:
            failures.append(f"{label} records {len(document_blockers)} production blocker(s)")
        if "qualityReview" in document:
            failures.extend(_declared_quality_failures(document["qualityReview"], f"{label}.qualityReview"))

    output_paths = {
        record.get("path")
        for record in provenance.get("outputs", [])
        if isinstance(record, dict) and record.get("role") == "seal.color-master"
    }
    manifest_paths = {
        record.get("path")
        for record in manifest_records
        if isinstance(record, dict) and record.get("role") == "seal.color-master"
    }
    for slug in required_seals:
        relative_path = f"Production/seal/{theme}-{slug}-color-master.png"
        if relative_path not in output_paths:
            failures.append(f"required Seal color master is absent from provenance: {relative_path}")
        if relative_path not in manifest_paths:
            failures.append(f"required Seal color master is absent from the integrity manifest: {relative_path}")
        if not (resources / relative_path).is_file():
            failures.append(f"required Seal color master file is absent: {relative_path}")
    return failures


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False, compress_level=9)


def fit(image: Image.Image, size: tuple[int, int], *, margin: int = 0) -> Image.Image:
    result = Image.new("RGBA", size, (0, 0, 0, 0))
    available = (max(1, size[0] - 2 * margin), max(1, size[1] - 2 * margin))
    contained = image.convert("RGBA").copy()
    alpha_bounds = contained.getchannel("A").point(lambda value: 255 if value >= 8 else 0).getbbox()
    if alpha_bounds is not None:
        padding = max(2, round(min(contained.size) * 0.018))
        alpha_bounds = (
            max(0, alpha_bounds[0] - padding),
            max(0, alpha_bounds[1] - padding),
            min(contained.width, alpha_bounds[2] + padding),
            min(contained.height, alpha_bounds[3] + padding),
        )
        contained = contained.crop(alpha_bounds)
    scale = min(available[0] / contained.width, available[1] / contained.height)
    contained = contained.resize(
        (max(1, round(contained.width * scale)), max(1, round(contained.height * scale))),
        Image.Resampling.LANCZOS,
    )
    result.alpha_composite(contained, ((size[0] - contained.width) // 2, (size[1] - contained.height) // 2))
    return result


def smoothstep(value: float, low: float, high: float) -> int:
    if value <= low:
        return 0
    if value >= high:
        return 255
    unit = (value - low) / (high - low)
    return round((unit * unit * (3 - 2 * unit)) * 255)


def isolate_from_dark_panel(
    source: Image.Image,
    crop: tuple[int, int, int, int],
    *,
    low: float,
    high: float,
    ellipse: tuple[int, int, int, int] | None = None,
    polygon: Sequence[tuple[float, float]] | None = None,
    maximum_filter_size: int = 7,
) -> Image.Image:
    image = source.convert("RGB").crop(crop)
    pixels = list(image.getdata())
    alpha_values = []
    for red, green, blue in pixels:
        luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        chroma = max(red, green, blue) - min(red, green, blue)
        signal = luminance + chroma * 0.28
        alpha_values.append(smoothstep(signal, low, high))
    alpha = Image.new("L", image.size)
    alpha.putdata(alpha_values)
    alpha = alpha.filter(ImageFilter.MaxFilter(maximum_filter_size)).filter(ImageFilter.GaussianBlur(1.2))
    if ellipse is not None:
        ellipse_mask = Image.new("L", image.size, 0)
        draw = ImageDraw.Draw(ellipse_mask)
        draw.ellipse(ellipse, fill=255)
        ellipse_mask = ellipse_mask.filter(ImageFilter.GaussianBlur(1.2))
        alpha = ImageChops.multiply(alpha, ellipse_mask)
    if polygon is not None:
        polygon_mask = Image.new("L", image.size, 0)
        draw = ImageDraw.Draw(polygon_mask)
        points = [(round(x * image.width), round(y * image.height)) for x, y in polygon]
        draw.polygon(points, fill=255)
        polygon_mask = polygon_mask.filter(ImageFilter.GaussianBlur(1.2))
        alpha = ImageChops.multiply(alpha, polygon_mask)
    rgba = image.convert("RGBA")
    rgba.putalpha(alpha)
    return rgba


def blank_tablet_inscription(image: Image.Image) -> Image.Image:
    result = image.convert("RGBA")
    width, height = result.size
    safe = (
        round(width * 0.12),
        round(height * 0.18),
        round(width * 0.92),
        round(height * 0.78),
    )
    field_size = (safe[2] - safe[0], safe[3] - safe[1])
    randomizer = random.Random(0x4D4F4F4E)
    field = Image.new("RGBA", field_size, (190, 189, 182, 255))
    field_pixels = []
    for y in range(field_size[1]):
        vertical = 5 * math.sin(y / 37.0)
        for x in range(field_size[0]):
            grain = randomizer.randint(-6, 6) + round(vertical)
            field_pixels.append((190 + grain, 189 + grain, 182 + grain, 255))
    field.putdata(field_pixels)
    field = field.filter(ImageFilter.GaussianBlur(0.55))
    feather = Image.new("L", field_size, 0)
    feather_draw = ImageDraw.Draw(feather)
    edge = max(8, min(field_size) // 16)
    feather_draw.rounded_rectangle(
        (edge, edge, field_size[0] - edge - 1, field_size[1] - edge - 1),
        radius=edge,
        fill=255,
    )
    feather = feather.filter(ImageFilter.GaussianBlur(edge / 2))
    result.paste(field, safe[:2], feather)
    return result


def high_contrast_variant(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    alpha = rgba.getchannel("A")
    rgb = ImageEnhance.Contrast(rgba.convert("RGB")).enhance(1.30)
    rgb = ImageEnhance.Sharpness(rgb).enhance(1.18)
    rgb = ImageEnhance.Color(rgb).enhance(0.82)
    result = rgb.convert("RGBA")
    result.putalpha(alpha)
    return result


def moonleaf_environment(master: Image.Image, size: tuple[int, int], *, mode: str) -> Image.Image:
    return render_background_variant(
        master,
        size,
        mode=mode,
        focal_point=BACKGROUND_SOURCE_MASTER.focal_point,
    )


def draw_leaf(draw: ImageDraw.ImageDraw, center: tuple[float, float], radius: float, vertical: bool) -> None:
    x, y = center
    if vertical:
        box = (x - radius * 0.55, y - radius, x + radius * 0.55, y + radius)
    else:
        box = (x - radius, y - radius * 0.55, x + radius, y + radius * 0.55)
    draw.ellipse(box, fill=(133, 151, 137, 225), outline=(229, 225, 211, 235), width=max(1, round(radius / 7)))
    if vertical:
        draw.line((x, y - radius * .72, x, y + radius * .72), fill=(78, 96, 83, 230), width=max(1, round(radius / 10)))
    else:
        draw.line((x - radius * .72, y, x + radius * .72, y), fill=(78, 96, 83, 230), width=max(1, round(radius / 10)))


def render_script_specimen(font_path: Path, *, high_contrast: bool) -> Image.Image:
    size = (1600, 600)
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(image, "RGBA")
    font = ImageFont.truetype(str(font_path), 106 if high_contrast else 98)
    foreground = (255, 253, 245, 255) if high_contrast else (218, 222, 213, 255)
    shadow = (0, 0, 0, 210)
    tokens = [chr(0x16A0 + index) for index in range(32)]
    for index, token in enumerate(tokens):
        row = index // 16
        column = index % 16
        x = 46 + column * 96
        y = 72 + row * 238
        draw.text((x + 3, y + 4), token, font=font, fill=shadow)
        draw.text((x, y), token, font=font, fill=foreground)
    divider_y = 296
    draw.line((56, divider_y, 1544, divider_y), fill=(180, 187, 174, 185), width=4)
    for x in range(120, 1540, 180):
        draw_leaf(draw, (x, divider_y), 18, False)
    return image


def vault_card(
    background: Image.Image,
    relic: Image.Image,
    frame_overlay: Image.Image,
    crest: Image.Image,
    mode: str,
) -> Image.Image:
    size = (1600, 900)
    if frame_overlay.size != size:
        raise ValueError("vault frame overlay dimensions differ")
    base = ImageOps.fit(background.convert("RGB"), size, method=Image.Resampling.LANCZOS, centering=(0.5, 0.42)).convert("RGBA")
    base = Image.alpha_composite(base, Image.new("RGBA", size, (2, 15, 17, 82)))
    base = Image.alpha_composite(base, frame_overlay.convert("RGBA"))
    relic_layer = fit(relic, (980, 720), margin=30)
    base.alpha_composite(relic_layer, (310, 90))
    crest_layer = fit(crest, (190, 190), margin=5)
    base.alpha_composite(crest_layer, (705, 24))
    if mode == "locked":
        grayscale = ImageOps.grayscale(base.convert("RGB")).convert("RGBA")
        base = Image.alpha_composite(grayscale, Image.new("RGBA", size, (2, 10, 12, 118)))
        draw = ImageDraw.Draw(base, "RGBA")
        for offset in range(-400, 1700, 180):
            draw.line((offset, 900, offset + 620, 0), fill=(184, 190, 181, 70), width=14)
    elif mode == "encountered":
        base = ImageEnhance.Color(base.convert("RGB")).enhance(0.45).convert("RGBA")
        base = Image.alpha_composite(base, Image.new("RGBA", size, (37, 89, 73, 48)))
    elif mode == "selected":
        draw = ImageDraw.Draw(base, "RGBA")
        for inset, alpha in ((22, 235), (38, 175), (54, 95)):
            draw.rounded_rectangle((inset, inset, size[0] - inset, size[1] - inset), radius=52, outline=(204, 230, 216, alpha), width=8)
    elif mode == "unavailable":
        base = ImageEnhance.Color(base.convert("RGB")).enhance(0.18).convert("RGBA")
        base = Image.alpha_composite(base, Image.new("RGBA", size, (4, 8, 10, 142)))
        draw = ImageDraw.Draw(base, "RGBA")
        draw.line((210, 760, 1390, 140), fill=(205, 207, 198, 155), width=24)
        draw.line((210, 140, 1390, 760), fill=(205, 207, 198, 155), width=24)
        for point in ((210, 760), (1390, 140), (210, 140), (1390, 760)):
            draw_leaf(draw, point, 34, True)
    return base.convert("RGB").quantize(colors=224, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).convert("RGB")


def rasterize_pdf(pdf_path: Path, size: tuple[int, int]) -> Image.Image:
    with tempfile.TemporaryDirectory(prefix="moonleaf-pdf-") as temporary:
        output = Path(temporary) / "render.png"
        result = subprocess.run(
            ["/usr/bin/sips", "-s", "format", "png", str(pdf_path), "--out", str(output)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0 or not output.is_file():
            raise RuntimeError(f"PDF rasterization failed for {pdf_path.name}: {result.stderr.strip()}")
        rendered = Image.open(output).convert("RGBA")
        return rendered.resize(size, Image.Resampling.LANCZOS)


def resource_specs() -> list[ResourceSpec]:
    specs: list[ResourceSpec] = []
    background_rights = "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json"
    vault_rights = "prov.Production.Sources.moonleaf.moonleaf.vault.recipe.json"
    frame_vector_rights = "prov.Source.Masters.Frames.moonleaf.silvervine.svg"
    crest_vector_rights = "prov.Source.Masters.Crests.moonleaf.moonbloom.svg"
    accepted_rights = accepted_recipe_rights_id("moonleaf")
    script_rights = "prov.Source.Masters.Glyphs.moonleaf.glyph.master.json"

    def add(resource_id: str, path: str, role: str, media: str, size: tuple[int, int] | None, rights: str, maximum: int = 16 * 1024 * 1024) -> None:
        specs.append(ResourceSpec(resource_id, "Production/" + path, role, media, maximum, size, rights))

    add("resource.background.moonleaf.moonlit-canopy.output.background-static-base", "background/moonleaf-background-static.png", "background.static-base", "image/png", (2048, 2732), background_rights)
    add("resource.background.moonleaf.moonlit-canopy.output.background-reduce-motion", "background/moonleaf-background-reduce-motion.png", "background.reduce-motion", "image/png", (2048, 2732), background_rights)
    add("resource.background.moonleaf.moonlit-canopy.output.background-high-contrast", "background/moonleaf-background-high-contrast.png", "background.high-contrast", "image/png", (2048, 2732), background_rights)
    add("resource.background.moonleaf.moonlit-canopy.output.background-macos-wide-crop", "background/moonleaf-background-macos-wide.png", "background.macos-wide-crop", "image/png", (3200, 1800), background_rights)

    add("resource.crest.moonleaf.moonbloom.output.crest-static-fallback", "crest/moonleaf-moonbloom-static-fallback.png", "crest.static-fallback", "image/png", (1024, 1024), accepted_rights)
    add("resource.crest.moonleaf.moonbloom.output.crest-thumbnail", "crest/moonleaf-moonbloom-thumbnail.png", "crest.thumbnail", "image/png", (512, 512), accepted_rights, 4 * 1024 * 1024)
    add("resource.crest.moonleaf.moonbloom.output.crest-vector-master", "crest/moonleaf-moonbloom-vector.pdf", "crest.vector-master", "application/pdf", (1024, 1024), crest_vector_rights, 4 * 1024 * 1024)

    add("resource.frame.moonleaf.silvervine.output.frame-static-fallback", "frame/moonleaf-silvervine-static-fallback.png", "frame.static-fallback", "image/png", (2048, 1536), accepted_rights)
    add("resource.frame.moonleaf.silvervine.output.frame-thumbnail", "frame/moonleaf-silvervine-thumbnail.png", "frame.thumbnail", "image/png", (512, 384), accepted_rights, 4 * 1024 * 1024)
    add("resource.frame.moonleaf.silvervine.output.frame-vector-master", "frame/moonleaf-silvervine-vector.pdf", "frame.vector-master", "application/pdf", (1600, 1200), frame_vector_rights, 4 * 1024 * 1024)

    relic_shapes = {
        "tablet": (1600, 1200),
        "ivybound-plaque": (1600, 1200),
        "whisperbark-stele": (1200, 1600),
    }
    for slug, size in relic_shapes.items():
        rights = "prov.Source.Masters.Relic.Geometry.moonleaf." + slug.replace("-", ".") + ".geometry.svg"
        base = f"resource.relic.moonleaf.{slug}.output"
        prefix = f"relic/moonleaf-{slug}"
        add(base + ".relic-master", prefix + "-master.png", "relic.master", "image/png", size, rights)
        add(base + ".relic-thumbnail", prefix + "-thumbnail.png", "relic.thumbnail", "image/png", (512, 512), rights, 4 * 1024 * 1024)
        add(base + ".relic-static-share-fallback", prefix + "-static-share-fallback.png", "relic.static-share-fallback", "image/png", size, rights)
        add(base + ".relic-high-contrast", prefix + "-high-contrast.png", "relic.high-contrast", "image/png", size, rights)

    add("resource.script.moonleaf.output.script-font", "script/moonleaf-script-primary.ttf", "script.font", "font/ttf", None, script_rights, 8 * 1024 * 1024)
    add("resource.script.moonleaf.output.script-static-fallback", "script/moonleaf-script-static-fallback.png", "script.static-fallback", "image/png", (1600, 600), script_rights, 8 * 1024 * 1024)
    add("resource.script.moonleaf.output.script-specimen-standard", "script/moonleaf-script-specimen.png", "script.specimen-standard", "image/png", (1600, 600), script_rights, 8 * 1024 * 1024)
    add("resource.script.moonleaf.output.script-specimen-high-contrast", "script/moonleaf-script-specimen-high-contrast.png", "script.specimen-high-contrast", "image/png", (1600, 600), script_rights, 8 * 1024 * 1024)

    for slug in MOONLEAF_SEALS:
        accepted_source = SEAL_SOURCE_MASTERS["moonleaf"].get(slug)
        raster_rights = (
            accepted_source.rights_id
            if accepted_source is not None
            else "prov.Source.Masters.Seals.moonleaf." + slug.replace("-", ".") + ".svg"
        )
        vector_rights = "prov.Source.Masters.Seals.moonleaf." + slug.replace("-", ".") + ".svg"
        color_size = accepted_source.pixel_size if accepted_source is not None else (1024, 1024)
        base = f"resource.seal.moonleaf.{slug}.output"
        prefix = f"seal/moonleaf-{slug}"
        add(base + ".seal-vector-master", prefix + "-vector-master.pdf", "seal.vector-master", "application/pdf", (1024, 1024), vector_rights, 4 * 1024 * 1024)
        add(base + ".seal-color-master", prefix + "-color-master.png", "seal.color-master", "image/png", color_size, raster_rights, 12 * 1024 * 1024)
        add(base + ".seal-monochrome-fallback", prefix + "-monochrome-fallback.png", "seal.monochrome-fallback", "image/png", color_size, raster_rights, 12 * 1024 * 1024)
        add(base + ".seal-thumbnail", prefix + "-thumbnail.png", "seal.thumbnail", "image/png", (512, 512), raster_rights, 4 * 1024 * 1024)

    for role, filename in (
        ("panel.card-border", "moonleaf-card-border.png"),
        ("panel.corner-ornament", "moonleaf-corner-ornament.png"),
        ("panel.divider", "moonleaf-divider.png"),
        ("panel.primary-button", "moonleaf-primary-button.png"),
        ("panel.tab-selector", "moonleaf-tab-selector.png"),
    ):
        size = {
            "panel.card-border": (1600, 1000),
            "panel.corner-ornament": (512, 512),
            "panel.divider": (1600, 128),
            "panel.primary-button": (1200, 320),
            "panel.tab-selector": (1000, 240),
        }[role]
        add("resource.panel.moonleaf." + role.split(".")[-1], "panel/" + filename, role, "image/png", size, accepted_rights, 8 * 1024 * 1024)

    for mode, role in (
        ("card", "vault.card"),
        ("encountered", "vault.encountered"),
        ("locked", "vault.locked-silhouette"),
        ("selected", "vault.selected"),
        ("unavailable", "vault.unavailable"),
    ):
        add(f"resource.vault.moonleaf.codex.output.vault-{role.split('.')[-1]}", f"vault/moonleaf-vault-{mode}.png", role, "image/png", (1600, 900), vault_rights)

    for resource_id, filename, role, size in (
        (
            "resource.received.moonleaf.primary.sender-avatar",
            "moonleaf-received-primary-sender-avatar.png",
            "received.primary.sender-avatar",
            (107, 107),
        ),
        (
            "resource.received.moonleaf.share.sender-avatar",
            "moonleaf-received-share-sender-avatar.png",
            "received.share.sender-avatar",
            (99, 99),
        ),
        (
            "resource.received.moonleaf.share.codex-badge",
            "moonleaf-received-share-codex-badge.png",
            "received.share.codex-badge",
            (43, 43),
        ),
        (
            "resource.received.moonleaf.primary.medallion",
            "moonleaf-received-primary-medallion.png",
            "received.primary.medallion",
            (193, 193),
        ),
        (
            "resource.received.moonleaf.share.medallion",
            "moonleaf-received-share-medallion.png",
            "received.share.medallion",
            (141, 141),
        ),
    ):
        add(
            resource_id,
            "received/" + filename,
            role,
            "image/png",
            size,
            RECEIVED_IDENTITY_RIGHTS_ID,
            1 * 1024 * 1024,
        )
    return sorted(specs, key=lambda item: item.relative_path)


def background_recipe_document(
    repo_root: Path,
    authority_facts: Sequence[dict[str, Any]],
    background_master: Image.Image,
    background_master_fact: dict[str, Any],
    output_facts: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "schemaVersion": "1.0",
        "id": "prov.Production.Sources.moonleaf.moonleaf.background.recipe.json",
        "theme": "Moonleaf",
        "asset": "background.moonleaf.moonlit-canopy",
        "generatedAtUTC": CREATED_AT,
        "pipeline": PIPELINE,
        "pipelineSHA256": sha256_file(repo_root / PIPELINE),
        "renderer": BACKGROUND_RENDERER,
        "rendererSHA256": sha256_file(repo_root / BACKGROUND_RENDERER),
        "productionSourceMaster": background_master_fact,
        "visualAuthorityReference": next(
            item for item in authority_facts if item["label"] == "style-board"
        ),
        "outputLayouts": {
            "phonePortrait": output_layout_record(
                background_master,
                (2048, 2732),
                BACKGROUND_SOURCE_MASTER.focal_point,
            ),
            "macOSWide": output_layout_record(
                background_master,
                (3200, 1800),
                BACKGROUND_SOURCE_MASTER.focal_point,
            ),
        },
        "variantAdjustments": {
            "standard": VARIANT_ADJUSTMENTS["standard"],
            "reduceMotion": VARIANT_ADJUSTMENTS["reduce-motion"],
            "highContrast": VARIANT_ADJUSTMENTS["high-contrast"],
        },
        "transformationSteps": [
            "verify the repository-local continuous environment source master against its pinned SHA-256",
            "compute a theme-focal aspect-fill crop in source coordinates for each output canvas",
            "sample the single crop with one uniform source-to-output scale and no nonuniform stretch",
            "prebuild deterministic standard, Reduce Motion, and High Contrast variants",
            "encode lossless PNG outputs without tiling, seams, reference-screen compositing, or completed-image blur",
        ],
        "outputs": [item for item in output_facts if item["role"].startswith("background.")],
        "rightsOwner": "Raven Forge Software",
        "licenseNotice": "Project-local proprietary production master; owner visual review remains pending",
        "ownerReview": "PENDING",
    }


def background_extraction_recipe(
    background_master: Image.Image,
    background_master_fact: dict[str, Any],
) -> dict[str, Any]:
    return {
        "asset": "background.moonleaf.moonlit-canopy",
        "source": background_master_fact,
        "layouts": {
            "phonePortrait": output_layout_record(
                background_master,
                (2048, 2732),
                BACKGROUND_SOURCE_MASTER.focal_point,
            ),
            "macOSWide": output_layout_record(
                background_master,
                (3200, 1800),
                BACKGROUND_SOURCE_MASTER.focal_point,
            ),
        },
        "transformation": "continuous-master focal aspect-fill, one uniform scale per output, and prebuilt deterministic accessibility variants; no tiling, patch compositing, seams, nonuniform stretch, or completed-image blur",
    }


def render_background_outputs(
    repo_root: Path,
    production: Path,
) -> tuple[dict[str, Image.Image], Image.Image, dict[str, Any]]:
    background_master, background_master_fact = load_background_master(
        repo_root,
        BACKGROUND_SOURCE_MASTER,
    )
    backgrounds = {
        "static": moonleaf_environment(background_master, (2048, 2732), mode="standard"),
        "reduce-motion": moonleaf_environment(
            background_master,
            (2048, 2732),
            mode="reduce-motion",
        ),
        "high-contrast": moonleaf_environment(
            background_master,
            (2048, 2732),
            mode="high-contrast",
        ),
        "macos-wide": moonleaf_environment(background_master, (3200, 1800), mode="standard"),
    }
    for name, image in backgrounds.items():
        save_png(image, production / f"background/moonleaf-background-{name}.png")
    return backgrounds, background_master, background_master_fact


def load_accepted_role_masters(
    repo_root: Path,
) -> tuple[Image.Image, dict[str, Any], Image.Image, dict[str, Any]]:
    frame_master, frame_fact = load_source_master(
        repo_root,
        FRAME_SOURCE_MASTERS["moonleaf"],
    )
    crest_master, crest_fact = load_source_master(
        repo_root,
        CREST_SOURCE_MASTERS["moonleaf"],
    )
    return frame_master, frame_fact, crest_master, crest_fact


def render_accepted_frame_crest_and_panels(
    production: Path,
    frame_master: Image.Image,
    crest_master: Image.Image,
) -> tuple[Image.Image, Image.Image, Image.Image]:
    frame = uniform_aspect_fit(frame_master, (2048, 1536))
    save_png(frame, production / "frame/moonleaf-silvervine-static-fallback.png")
    save_png(
        uniform_aspect_fit(frame_master, (512, 384)),
        production / "frame/moonleaf-silvervine-thumbnail.png",
    )
    crest = uniform_aspect_fit(crest_master, (1024, 1024))
    save_png(crest, production / "crest/moonleaf-moonbloom-static-fallback.png")
    save_png(
        uniform_aspect_fit(crest_master, (512, 512)),
        production / "crest/moonleaf-moonbloom-thumbnail.png",
    )
    for panel, image in panel_assets("moonleaf", frame_master).items():
        save_png(image, production / f"panel/moonleaf-{panel}.png")
    vault_frame = render_nine_slice_frame(
        frame_master,
        (1600, 900),
        PANEL_CAP_INSETS["card-border"],
        FRAME_SLICE_POLICIES["moonleaf"],
    )
    return frame, crest, vault_frame


def panel_cap_insets_record() -> dict[str, dict[str, int] | None]:
    return {
        f"resource.panel.moonleaf.{name}": caps.as_dict() if caps is not None else None
        for name, caps in PANEL_CAP_INSETS.items()
    }


def accepted_master_recipe_relative_path() -> str:
    return (
        "docs/verification/theme-fidelity-v4-3/inventory/recipes/"
        "Moonleaf-Accepted-Source-Master-Recipe-v4.3.json"
    )


def accepted_master_output(output: dict[str, Any]) -> bool:
    role = str(output.get("role", ""))
    if role in {
        "frame.static-fallback",
        "frame.thumbnail",
        "crest.static-fallback",
        "crest.thumbnail",
    } or role.startswith("panel.") or role.startswith("vault."):
        return True
    if not role.startswith("seal."):
        return False
    resource_id = str(output.get("resourceID", ""))
    return any(
        f"resource.seal.moonleaf.{slug}.output." in resource_id
        for slug in SEAL_SOURCE_MASTERS["moonleaf"]
    )


def accepted_master_recipe_document(
    repo_root: Path,
    frame_fact: dict[str, Any],
    crest_fact: dict[str, Any],
    seal_facts: Mapping[str, dict[str, Any]],
    output_facts: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    source_facts = [frame_fact, crest_fact, *seal_facts.values()]
    source_records = {
        item["acceptanceRecord"]["path"]: item["acceptanceRecord"]
        for item in source_facts
    }
    return {
        "schemaVersion": "1.0",
        "id": accepted_recipe_rights_id("moonleaf"),
        "theme": "Moonleaf",
        "generatedAtUTC": CREATED_AT,
        "ownerReview": "PENDING",
        "pipeline": PIPELINE,
        "pipelineSHA256": sha256_file(repo_root / PIPELINE),
        "sourceMasters": source_facts,
        "sourceRecords": [source_records[path] for path in sorted(source_records)],
        "frameLayouts": {
            "staticFallback": aspect_fit_record(tuple(frame_fact["dimensions"]), (2048, 1536)),
            "thumbnail": aspect_fit_record(tuple(frame_fact["dimensions"]), (512, 384)),
        },
        "crestLayouts": {
            "staticFallback": aspect_fit_record(tuple(crest_fact["dimensions"]), (1024, 1024)),
            "thumbnail": aspect_fit_record(tuple(crest_fact["dimensions"]), (512, 512)),
        },
        "sealLayouts": {
            slug: seal_render_recipe_record(tuple(fact["dimensions"]))
            for slug, fact in seal_facts.items()
        },
        "panelNineSlicePolicy": panel_policy_record("moonleaf"),
        "transformationPolicy": [
            "verify each repository-local accepted source master and its acceptance record against pinned SHA-256 values",
            "render Frame and Crest fallbacks with one uniform aspect-fit scale and transparent letterboxing when required",
            "compose Panel assets from four independent uniformly scaled protected corners and the contiguous between-corner edge intervals; never resize the complete frame nonuniformly",
            "preserve every accepted Seal color master as an exact decoded RGBA pixel copy and derive only alpha-preserving monochrome and thumbnail variants",
            "encode deterministic lossless PNG outputs without source-screen compositing",
        ],
        "outputs": [item for item in output_facts if accepted_master_output(item)],
        "rightsOwner": "Raven Forge Software",
        "licenseNotice": "Project-local proprietary production masters; owner visual review remains pending",
    }


def accepted_master_extraction_recipes(
    frame_fact: dict[str, Any],
    crest_fact: dict[str, Any],
    seal_facts: Mapping[str, dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    recipes = [
        {
            "asset": "frame.moonleaf.silvervine",
            "source": frame_fact,
            "transformation": "pinned accepted transparent master loaded unchanged, then rendered by deterministic uniform aspect-fit for static fallback and thumbnail",
        },
        {
            "asset": "crest.moonleaf.moonbloom",
            "source": crest_fact,
            "transformation": "pinned accepted transparent master loaded unchanged, then rendered by deterministic uniform aspect-fit for static fallback and thumbnail",
        },
        {
            "asset": "panel.moonleaf.chrome-set",
            "source": frame_fact,
            "policy": panel_policy_record("moonleaf"),
            "transformation": "protected-corner and contiguous-edge nine-slice composition with one shared cross-axis scale; transparent center; no complete-frame nonuniform resize",
        },
    ]
    recipes.extend(
        {
            "asset": f"seal.moonleaf.{slug}",
            "source": fact,
            "recipe": seal_render_recipe_record(tuple(fact["dimensions"])),
            "transformation": "decoded RGBA pixels preserved exactly for the color master; explicit alpha-preserving monochrome fallback and uniform aspect-fit thumbnail derived deterministically",
        }
        for slug, fact in (seal_facts or {}).items()
    )
    return recipes


def build_assets(repo_root: Path, authority_root: Path) -> None:
    resources = repo_root / "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/Resources"
    production = resources / "Production"
    authority_images: dict[str, Image.Image] = {}
    authority_facts = []
    for label, (relative, expected_hash) in OWNER_ARCHIVE_INPUTS.items():
        path = authority_root / relative
        actual_hash = sha256_file(path)
        if actual_hash != expected_hash:
            raise SystemExit(f"Moonleaf authority input differs: {relative}")
        authority_images[label] = Image.open(path).convert("RGB")
        authority_facts.append({"label": label, "path": relative, "sha256": actual_hash, "dimensions": list(authority_images[label].size)})

    backgrounds, background_master, background_master_fact = render_background_outputs(
        repo_root,
        production,
    )
    wide_background = backgrounds["macos-wide"]
    (
        frame_master,
        frame_master_fact,
        crest_master,
        crest_master_fact,
    ) = load_accepted_role_masters(repo_root)
    tablet = isolate_from_dark_panel(authority_images["catalog"], (60, 332, 531, 726), low=30, high=67)
    tablet = blank_tablet_inscription(tablet)
    ivybound = isolate_from_dark_panel(
        authority_images["catalog"],
        (74, 880, 306, 1100),
        low=27,
        high=55,
        ellipse=(3, 0, 229, 218),
        maximum_filter_size=5,
    )
    whisperbark = isolate_from_dark_panel(
        authority_images["catalog"],
        (85, 1185, 305, 1500),
        low=26,
        high=55,
        polygon=((0.50, 0.00), (0.80, 0.12), (0.84, 0.60), (0.98, 0.91), (0.76, 1.00), (0.24, 1.00), (0.02, 0.91), (0.16, 0.60), (0.20, 0.12)),
        maximum_filter_size=5,
    )
    relics = {
        "tablet": fit(tablet, (1600, 1200), margin=44),
        "ivybound-plaque": fit(ivybound, (1600, 1200), margin=70),
        "whisperbark-stele": fit(whisperbark, (1200, 1600), margin=55),
    }
    for slug, master in relics.items():
        prefix = production / f"relic/moonleaf-{slug}"
        save_png(master, Path(str(prefix) + "-master.png"))
        save_png(master.copy(), Path(str(prefix) + "-static-share-fallback.png"))
        save_png(high_contrast_variant(master), Path(str(prefix) + "-high-contrast.png"))
        save_png(fit(master, (512, 512), margin=18), Path(str(prefix) + "-thumbnail.png"))

    crescent = isolate_from_dark_panel(
        authority_images["style-board"],
        (753, 263, 1031, 559),
        low=55,
        high=95,
        ellipse=(18, 0, 252, 294),
        maximum_filter_size=5,
    )
    stag = isolate_from_dark_panel(authority_images["style-board"], (753, 678, 1025, 1005), low=18, high=50, ellipse=(7, 2, 265, 324))
    authority_seals = {
        "crescentleaf": fit(crescent, (1024, 1024), margin=45),
        "woodland-stag": fit(stag, (1024, 1024), margin=45),
    }
    for slug, master in authority_seals.items():
        color, monochrome, thumbnail = render_seal_variants(master)
        save_png(color, production / f"seal/moonleaf-{slug}-color-master.png")
        save_png(thumbnail, production / f"seal/moonleaf-{slug}-thumbnail.png")
        save_png(monochrome, production / f"seal/moonleaf-{slug}-monochrome-fallback.png")

    accepted_seal_sources = {
        slug: load_seal_source_master(repo_root, SEAL_SOURCE_MASTERS["moonleaf"][slug])
        for slug in MOONLEAF_SEALS
        if slug in SEAL_SOURCE_MASTERS["moonleaf"]
    }
    for slug, (source, _) in accepted_seal_sources.items():
        color, monochrome, thumbnail = render_seal_variants(source)
        prefix = production / f"seal/moonleaf-{slug}"
        save_png(color, Path(str(prefix) + "-color-master.png"))
        save_png(monochrome, Path(str(prefix) + "-monochrome-fallback.png"))
        save_png(thumbnail, Path(str(prefix) + "-thumbnail.png"))

    frame, crest, vault_frame = render_accepted_frame_crest_and_panels(
        production,
        frame_master,
        crest_master,
    )

    font = production / "script/moonleaf-script-primary.ttf"
    specimen = render_script_specimen(font, high_contrast=False)
    specimen_high = render_script_specimen(font, high_contrast=True)
    save_png(specimen, production / "script/moonleaf-script-specimen.png")
    save_png(specimen.copy(), production / "script/moonleaf-script-static-fallback.png")
    save_png(specimen_high, production / "script/moonleaf-script-specimen-high-contrast.png")

    for mode in ("card", "encountered", "locked", "selected", "unavailable"):
        image = vault_card(wide_background, relics["tablet"], vault_frame, crest, mode)
        save_png(image, production / f"vault/moonleaf-vault-{mode}.png")

    obsolete = [
        production / f"relic/moonleaf-{slug}-{suffix}.heif"
        for slug in ("tablet", "ivybound-plaque", "whisperbark-stele")
        for suffix in ("thumbnail", "static-share-fallback")
    ] + [
        production / f"seal/moonleaf-{slug}-monochrome-fallback.pdf"
        for slug in MOONLEAF_SEALS
    ] + [
        production / "relic/moonleaf-tablet-catalog-specimen.png"
    ]
    for path in obsolete:
        if path.is_file():
            path.unlink()

    specs = resource_specs()
    records = []
    for spec in specs:
        path = resources / spec.relative_path
        if not path.is_file():
            raise SystemExit(f"Missing generated Moonleaf resource: {spec.relative_path}")
        byte_count = path.stat().st_size
        if byte_count > spec.maximum_bytes:
            raise SystemExit(f"Moonleaf resource exceeds its byte budget: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".png":
            with Image.open(path) as image:
                if image.size != spec.pixel_size:
                    raise SystemExit(f"Moonleaf resource dimensions differ: {spec.relative_path}")
        records.append({
            "path": spec.relative_path,
            "bytes": byte_count,
            "sha256": sha256_file(path),
            "resourceID": spec.resource_id,
            "role": spec.role,
        })
    integrity = {
        "schemaVersion": "1.0",
        "codexID": CODEX_ID,
        "moduleID": MODULE_ID,
        "acceptedPackageVersion": ACCEPTED_PACKAGE_VERSION,
        "files": records,
    }
    integrity_path = production / "Resource-Integrity-Manifest-v1.0.json"
    write_json(integrity_path, integrity)
    write_module_manifest(resources, specs, integrity_path)
    write_pins(repo_root, specs, records, integrity_path, resources / "module-manifest.json")

    output_facts = []
    for spec, record in zip(specs, records):
        path = resources / spec.relative_path
        alpha = None
        if path.suffix == ".png":
            with Image.open(path) as image:
                alpha = "A" in image.getbands()
        output_facts.append({
            **record,
            "mediaType": spec.media_type,
            "dimensions": list(spec.pixel_size) if spec.pixel_size else None,
            "hasAlpha": alpha,
            "rightsID": spec.rights_id,
        })
    recipe_relative_path = "docs/verification/theme-fidelity-v4-3/inventory/recipes/Moonleaf-Background-Extraction-Recipe-v4.3.json"
    recipe_path = repo_root / recipe_relative_path
    background_recipe = background_recipe_document(
        repo_root,
        authority_facts,
        background_master,
        background_master_fact,
        output_facts,
    )
    write_json(recipe_path, background_recipe)
    accepted_recipe_relative_path = accepted_master_recipe_relative_path()
    accepted_recipe_path = repo_root / accepted_recipe_relative_path
    write_json(
        accepted_recipe_path,
        accepted_master_recipe_document(
            repo_root,
            frame_master_fact,
            crest_master_fact,
            {slug: fact for slug, (_, fact) in accepted_seal_sources.items()},
            output_facts,
        ),
    )
    provenance = {
        "schemaVersion": "1.0",
        "theme": "Moonleaf",
        "codexID": CODEX_ID,
        "generatedAtUTC": CREATED_AT,
        "pipeline": PIPELINE,
        "pipelineSHA256": sha256_file(repo_root / PIPELINE),
        "authorityPolicy": "offline owner-archive extraction and repository-local production source masters only; authoring inputs are not bundled or read at runtime",
        "authorityInputs": authority_facts,
        "backgroundRenderer": {
            "path": BACKGROUND_RENDERER,
            "sha256": sha256_file(repo_root / BACKGROUND_RENDERER),
        },
        "backgroundSourceMaster": background_master_fact,
        "backgroundRecipe": {"path": recipe_relative_path, "sha256": sha256_file(recipe_path)},
        "acceptedSourceMasterRecipe": {
            "path": accepted_recipe_relative_path,
            "sha256": sha256_file(accepted_recipe_path),
        },
        "frameSourceMaster": frame_master_fact,
        "crestSourceMaster": crest_master_fact,
        "relicSourceMasters": {},
        "sealSourceMasters": {
            slug: fact for slug, (_, fact) in accepted_seal_sources.items()
        },
        "blockers": color_master_blockers(
            "moonleaf",
            MOONLEAF_SEALS,
            (*authority_seals, *accepted_seal_sources),
        ),
        "receivedIdentityExtraction": {
            "path": RECEIVED_IDENTITY_EVIDENCE,
            "sha256": sha256_file(repo_root / RECEIVED_IDENTITY_EVIDENCE),
            "pipeline": "scripts/extract-moonleaf-received-identity-v43.py",
            "scope": "five exact received-state identity resources copied into the production manifest without reconstruction",
        },
        "extractionRecipes": [
            {"asset": "relic.moonleaf.tablet", "source": "catalog", "crop": [60, 332, 531, 726], "transformation": "owner-archive source-pixel isolation, blank inscription-field reconstruction, and aspect-fit lossless resampling"},
            {"asset": "relic.moonleaf.ivybound-plaque", "source": "catalog", "crop": [74, 880, 306, 1100], "transformation": "owner-archive source-pixel isolation, elliptical silhouette masking, alpha-bounds normalization, and aspect-fit lossless resampling"},
            {"asset": "relic.moonleaf.whisperbark-stele", "source": "catalog", "crop": [85, 1185, 305, 1500], "transformation": "owner-archive source-pixel isolation, stele silhouette masking, alpha-bounds normalization, and aspect-fit lossless resampling"},
            {"asset": "seal.moonleaf.crescentleaf", "source": "style-board", "crop": [753, 263, 1031, 559], "transformation": "owner-archive source-pixel isolation and alpha-preserving lossless resampling"},
            {"asset": "seal.moonleaf.woodland-stag", "source": "style-board", "crop": [753, 678, 1025, 1005], "transformation": "owner-archive elliptical medallion isolation and alpha-preserving lossless resampling"},
            background_extraction_recipe(background_master, background_master_fact),
            *accepted_master_extraction_recipes(
                frame_master_fact,
                crest_master_fact,
                {slug: fact for slug, (_, fact) in accepted_seal_sources.items()},
            ),
        ],
        "targetScaleReview": {
            "implementationReview": "PASS",
            "ownerReview": "PENDING",
            "reason": "The continuous environment plus accepted Frame, Crest, and detailed Seal masters use pinned deterministic aspect-fill, aspect-fit, RGBA-preserving, and protected nine-slice recipes; owner visual review remains pending.",
        },
        "panelCapInsets": panel_cap_insets_record(),
        "panelNineSlicePolicy": panel_policy_record("moonleaf"),
        "outputs": output_facts,
    }
    write_json(repo_root / "docs/verification/theme-fidelity-v4-3/inventory/Moonleaf-Production-Asset-Provenance-v4.3.json", provenance)


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def write_pins(
    repo_root: Path,
    specs: Sequence[ResourceSpec],
    records: Sequence[dict[str, Any]],
    integrity_path: Path,
    module_manifest_path: Path,
) -> None:
    lines = [
        "import Foundation",
        "import RuneScribeContracts",
        "",
        "enum MoonleafV43ResourcePins {",
        f"    static let integrityManifestByteCount = {integrity_path.stat().st_size}",
        f"    static let integrityManifestSHA256Hex = {swift_string(sha256_file(integrity_path))}",
        f"    static let moduleManifestByteCount = {module_manifest_path.stat().st_size}",
        f"    static let moduleManifestSHA256Hex = {swift_string(sha256_file(module_manifest_path))}",
        f"    static let productionShippingByteCount = {sum(record['bytes'] for record in records)}",
        "",
        "    static let productionDefinitions: [MoonleafThemeResourceDefinition] = [",
    ]
    for spec, record in zip(specs, records):
        extension = Path(spec.relative_path).suffix.removeprefix(".")
        name = Path(spec.relative_path).stem
        media = {
            "image/png": ".png",
            "application/pdf": ".pdf",
            "font/ttf": ".ttf",
        }[spec.media_type]
        pixel_width = str(spec.pixel_size[0]) if spec.pixel_size else "nil"
        pixel_height = str(spec.pixel_size[1]) if spec.pixel_size else "nil"
        lines.extend([
            "        MoonleafThemeResourceDefinition(",
            f"            id: ThemeResourceID(rawValue: {swift_string(spec.resource_id)})!,",
            f"            resource: ApplicationResource(name: {swift_string(name)}, fileExtension: {swift_string(extension)}, ownerModuleID: {swift_string(MODULE_ID)}),",
            f"            relativePath: {swift_string(spec.relative_path)},",
            f"            role: ThemeResourceRoleID(rawValue: {swift_string(spec.role)})!,",
            f"            mediaType: {media},",
            "            requirement: .required,",
            f"            sha256Hex: {swift_string(record['sha256'])},",
            f"            byteCount: {record['bytes']},",
            f"            maximumByteCount: {spec.maximum_bytes},",
            f"            pixelWidth: {pixel_width},",
            f"            pixelHeight: {pixel_height},",
            f"            rightsID: ThemeProvenanceID(rawValue: {swift_string(spec.rights_id)})!",
            "        ),",
        ])
    lines.extend(["    ]", "}", ""])
    destination = repo_root / "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/MoonleafV43ResourcePins.swift"
    destination.write_text("\n".join(lines), encoding="utf-8")


def write_module_manifest(resources: Path, specs: Sequence[ResourceSpec], integrity_path: Path) -> None:
    current = json.loads((resources / "module-manifest.json").read_text(encoding="utf-8"))
    files = [resources / "module-manifest.json", integrity_path] + [resources / spec.relative_path for spec in specs]
    required = []
    for path in files:
        required.append({
            "name": path.stem,
            "fileExtension": path.suffix.removeprefix("."),
            "subdirectory": None,
            "ownerModuleID": MODULE_ID,
        })
    current["runtimeRequirements"]["requiredResources"] = required
    write_json(resources / "module-manifest.json", current)


def refresh_backgrounds_only(repo_root: Path, authority_root: Path) -> dict[str, Any]:
    resources = repo_root / "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/Resources"
    production = resources / "Production"
    authority_facts = []
    for label, (relative, expected_hash) in OWNER_ARCHIVE_INPUTS.items():
        path = authority_root / relative
        actual_hash = sha256_file(path)
        if actual_hash != expected_hash:
            raise SystemExit(f"Moonleaf authority input differs: {relative}")
        with Image.open(path) as image:
            dimensions = list(image.size)
        authority_facts.append({
            "label": label,
            "path": relative,
            "sha256": actual_hash,
            "dimensions": dimensions,
        })

    _, background_master, background_master_fact = render_background_outputs(
        repo_root,
        production,
    )
    specs = resource_specs()
    records = []
    for spec in specs:
        path = resources / spec.relative_path
        if not path.is_file():
            raise SystemExit(f"Missing Moonleaf resource: {spec.relative_path}")
        byte_count = path.stat().st_size
        if byte_count > spec.maximum_bytes:
            raise SystemExit(f"Moonleaf resource exceeds byte budget: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".png":
            with Image.open(path) as image:
                if image.size != spec.pixel_size:
                    raise SystemExit(f"Moonleaf resource dimensions differ: {spec.relative_path}")
        records.append({
            "path": spec.relative_path,
            "bytes": byte_count,
            "sha256": sha256_file(path),
            "resourceID": spec.resource_id,
            "role": spec.role,
        })

    integrity = {
        "schemaVersion": "1.0",
        "codexID": CODEX_ID,
        "moduleID": MODULE_ID,
        "acceptedPackageVersion": ACCEPTED_PACKAGE_VERSION,
        "files": records,
    }
    integrity_path = production / "Resource-Integrity-Manifest-v1.0.json"
    write_json(integrity_path, integrity)
    write_module_manifest(resources, specs, integrity_path)
    module_manifest = resources / "module-manifest.json"
    write_pins(repo_root, specs, records, integrity_path, module_manifest)

    output_facts = []
    for spec, record in zip(specs, records):
        path = resources / spec.relative_path
        alpha = None
        if path.suffix == ".png":
            with Image.open(path) as image:
                alpha = "A" in image.getbands()
        output_facts.append({
            **record,
            "mediaType": spec.media_type,
            "dimensions": list(spec.pixel_size) if spec.pixel_size else None,
            "hasAlpha": alpha,
            "rightsID": spec.rights_id,
        })

    recipe_relative_path = "docs/verification/theme-fidelity-v4-3/inventory/recipes/Moonleaf-Background-Extraction-Recipe-v4.3.json"
    recipe_path = repo_root / recipe_relative_path
    recipe = background_recipe_document(
        repo_root,
        authority_facts,
        background_master,
        background_master_fact,
        output_facts,
    )
    write_json(recipe_path, recipe)

    provenance_path = repo_root / "docs/verification/theme-fidelity-v4-3/inventory/Moonleaf-Production-Asset-Provenance-v4.3.json"
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    extraction_recipes = [
        record
        for record in provenance.get("extractionRecipes", [])
        if record.get("asset") != "background.moonleaf.moonlit-canopy"
    ]
    extraction_recipes.append(background_extraction_recipe(background_master, background_master_fact))
    provenance.update({
        "authorityInputs": authority_facts,
        "authorityPolicy": "offline owner-archive extraction and repository-local production source masters only; authoring inputs are not bundled or read at runtime",
        "backgroundRecipe": {"path": recipe_relative_path, "sha256": sha256_file(recipe_path)},
        "backgroundSourceMaster": background_master_fact,
        "backgroundRenderer": {
            "path": BACKGROUND_RENDERER,
            "sha256": sha256_file(repo_root / BACKGROUND_RENDERER),
        },
        "extractionRecipes": extraction_recipes,
        "outputs": output_facts,
        "pipelineSHA256": sha256_file(repo_root / PIPELINE),
        "targetScaleReview": {
            "implementationReview": "PASS",
            "ownerReview": "PENDING",
            "reason": "The continuous 1672 by 941 environment source master is rendered with a pinned focal aspect-fill recipe and one uniform scale per output; owner visual review remains pending.",
        },
    })
    write_json(provenance_path, provenance)
    return {
        "backgroundRecipeSHA256": sha256_file(recipe_path),
        "integrityManifestSHA256": sha256_file(integrity_path),
        "ownerReview": "PENDING",
        "provenanceSHA256": sha256_file(provenance_path),
        "status": "REFRESHED",
        "theme": "Moonleaf",
    }


def refresh_accepted_masters_only(repo_root: Path, authority_root: Path) -> dict[str, Any]:
    resources = repo_root / "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/Resources"
    production = resources / "Production"
    authority_facts = []
    for label, (relative, expected_hash) in OWNER_ARCHIVE_INPUTS.items():
        path = authority_root / relative
        actual_hash = sha256_file(path)
        if actual_hash != expected_hash:
            raise SystemExit(f"Moonleaf authority input differs: {relative}")
        with Image.open(path) as image:
            dimensions = list(image.size)
        authority_facts.append({
            "label": label,
            "path": relative,
            "sha256": actual_hash,
            "dimensions": dimensions,
        })
    background_master, background_master_fact = load_background_master(
        repo_root,
        BACKGROUND_SOURCE_MASTER,
    )
    (
        frame_master,
        frame_master_fact,
        crest_master,
        crest_master_fact,
    ) = load_accepted_role_masters(repo_root)
    accepted_seal_sources = {
        slug: load_seal_source_master(repo_root, SEAL_SOURCE_MASTERS["moonleaf"][slug])
        for slug in MOONLEAF_SEALS
        if slug in SEAL_SOURCE_MASTERS["moonleaf"]
    }
    for slug, (source, _) in accepted_seal_sources.items():
        color, monochrome, thumbnail = render_seal_variants(source)
        prefix = production / f"seal/moonleaf-{slug}"
        save_png(color, Path(str(prefix) + "-color-master.png"))
        save_png(monochrome, Path(str(prefix) + "-monochrome-fallback.png"))
        save_png(thumbnail, Path(str(prefix) + "-thumbnail.png"))
    _, crest, vault_frame = render_accepted_frame_crest_and_panels(
        production,
        frame_master,
        crest_master,
    )
    with Image.open(production / "background/moonleaf-background-macos-wide.png") as opened:
        wide_background = opened.convert("RGB")
    with Image.open(production / "relic/moonleaf-tablet-master.png") as opened:
        default_relic = opened.convert("RGBA")
    for mode in ("card", "encountered", "locked", "selected", "unavailable"):
        save_png(
            vault_card(wide_background, default_relic, vault_frame, crest, mode),
            production / f"vault/moonleaf-vault-{mode}.png",
        )

    specs = resource_specs()
    records = []
    for spec in specs:
        path = resources / spec.relative_path
        if not path.is_file():
            raise SystemExit(f"Missing Moonleaf resource: {spec.relative_path}")
        byte_count = path.stat().st_size
        if byte_count > spec.maximum_bytes:
            raise SystemExit(f"Moonleaf resource exceeds byte budget: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".png":
            with Image.open(path) as image:
                if image.size != spec.pixel_size:
                    raise SystemExit(f"Moonleaf resource dimensions differ: {spec.relative_path}")
        records.append({
            "path": spec.relative_path,
            "bytes": byte_count,
            "sha256": sha256_file(path),
            "resourceID": spec.resource_id,
            "role": spec.role,
        })
    integrity = {
        "schemaVersion": "1.0",
        "codexID": CODEX_ID,
        "moduleID": MODULE_ID,
        "acceptedPackageVersion": ACCEPTED_PACKAGE_VERSION,
        "files": records,
    }
    integrity_path = production / "Resource-Integrity-Manifest-v1.0.json"
    write_json(integrity_path, integrity)
    write_module_manifest(resources, specs, integrity_path)
    module_manifest = resources / "module-manifest.json"
    write_pins(repo_root, specs, records, integrity_path, module_manifest)

    output_facts = []
    for spec, record in zip(specs, records):
        path = resources / spec.relative_path
        alpha = None
        if path.suffix == ".png":
            with Image.open(path) as image:
                alpha = "A" in image.getbands()
        output_facts.append({
            **record,
            "mediaType": spec.media_type,
            "dimensions": list(spec.pixel_size) if spec.pixel_size else None,
            "hasAlpha": alpha,
            "rightsID": spec.rights_id,
        })

    background_recipe_relative_path = (
        "docs/verification/theme-fidelity-v4-3/inventory/recipes/"
        "Moonleaf-Background-Extraction-Recipe-v4.3.json"
    )
    background_recipe_path = repo_root / background_recipe_relative_path
    write_json(
        background_recipe_path,
        background_recipe_document(
            repo_root,
            authority_facts,
            background_master,
            background_master_fact,
            output_facts,
        ),
    )
    accepted_recipe_relative_path = accepted_master_recipe_relative_path()
    accepted_recipe_path = repo_root / accepted_recipe_relative_path
    write_json(
        accepted_recipe_path,
        accepted_master_recipe_document(
            repo_root,
            frame_master_fact,
            crest_master_fact,
            {slug: fact for slug, (_, fact) in accepted_seal_sources.items()},
            output_facts,
        ),
    )

    provenance_path = repo_root / "docs/verification/theme-fidelity-v4-3/inventory/Moonleaf-Production-Asset-Provenance-v4.3.json"
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    replaced_assets = {
        "background.moonleaf.moonlit-canopy",
        "frame.moonleaf.silvervine",
        "crest.moonleaf.moonbloom",
        "panel.moonleaf.chrome-set",
        *(f"seal.moonleaf.{slug}" for slug in accepted_seal_sources),
    }
    extraction_recipes = [
        record
        for record in provenance.get("extractionRecipes", [])
        if record.get("asset") not in replaced_assets
    ]
    extraction_recipes.extend([
        background_extraction_recipe(background_master, background_master_fact),
        *accepted_master_extraction_recipes(
            frame_master_fact,
            crest_master_fact,
            {slug: fact for slug, (_, fact) in accepted_seal_sources.items()},
        ),
    ])
    provenance.update({
        "acceptedSourceMasterRecipe": {
            "path": accepted_recipe_relative_path,
            "sha256": sha256_file(accepted_recipe_path),
        },
        "authorityInputs": authority_facts,
        "authorityPolicy": "offline owner-archive extraction and repository-local production source masters only; authoring inputs are not bundled or read at runtime",
        "backgroundRecipe": {
            "path": background_recipe_relative_path,
            "sha256": sha256_file(background_recipe_path),
        },
        "backgroundRenderer": {
            "path": BACKGROUND_RENDERER,
            "sha256": sha256_file(repo_root / BACKGROUND_RENDERER),
        },
        "backgroundSourceMaster": background_master_fact,
        "crestSourceMaster": crest_master_fact,
        "extractionRecipes": extraction_recipes,
        "frameSourceMaster": frame_master_fact,
        "outputs": output_facts,
        "panelCapInsets": panel_cap_insets_record(),
        "panelNineSlicePolicy": panel_policy_record("moonleaf"),
        "pipelineSHA256": sha256_file(repo_root / PIPELINE),
        "relicSourceMasters": {},
        "sealSourceMasters": {
            slug: fact for slug, (_, fact) in accepted_seal_sources.items()
        },
        "blockers": color_master_blockers(
            "moonleaf",
            MOONLEAF_SEALS,
            (*("crescentleaf", "woodland-stag"), *accepted_seal_sources),
        ),
        "targetScaleReview": {
            "implementationReview": "PASS",
            "ownerReview": "PENDING",
            "reason": "The continuous environment plus accepted Frame, Crest, and detailed Seal masters use pinned deterministic aspect-fill, aspect-fit, RGBA-preserving, and protected nine-slice recipes; owner visual review remains pending.",
        },
    })
    write_json(provenance_path, provenance)
    return {
        "acceptedSourceMasterRecipeSHA256": sha256_file(accepted_recipe_path),
        "backgroundRecipeSHA256": sha256_file(background_recipe_path),
        "integrityManifestSHA256": sha256_file(integrity_path),
        "ownerReview": "PENDING",
        "provenanceSHA256": sha256_file(provenance_path),
        "status": "REFRESHED",
        "theme": "Moonleaf",
    }


def check_assets(repo_root: Path, authority_root: Path) -> None:
    resources = repo_root / "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/Resources"
    production = resources / "Production"
    manifest_path = production / "Resource-Integrity-Manifest-v1.0.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    specs = resource_specs()
    records = manifest.get("files")
    if manifest.get("acceptedPackageVersion") != ACCEPTED_PACKAGE_VERSION or not isinstance(records, list):
        raise SystemExit("Moonleaf v4.3 integrity manifest identity differs")
    if len(records) != len(specs):
        raise SystemExit(f"Moonleaf output count differs: {len(records)} != {len(specs)}")
    expected_paths = {spec.relative_path for spec in specs}
    if {record.get("path") for record in records} != expected_paths:
        raise SystemExit("Moonleaf integrity manifest path set differs")
    spec_by_path = {spec.relative_path: spec for spec in specs}
    alpha_required = {
        "relic.master", "relic.thumbnail", "relic.static-share-fallback", "relic.high-contrast",
        "seal.color-master", "seal.monochrome-fallback", "seal.thumbnail", "frame.static-fallback", "frame.thumbnail", "crest.static-fallback", "crest.thumbnail",
        "script.static-fallback", "script.specimen-standard", "script.specimen-high-contrast",
        "panel.card-border", "panel.corner-ornament", "panel.divider", "panel.primary-button", "panel.tab-selector",
        "received.primary.sender-avatar", "received.share.sender-avatar", "received.share.codex-badge",
        "received.primary.medallion", "received.share.medallion",
    }
    for record in records:
        spec = spec_by_path[record["path"]]
        path = resources / spec.relative_path
        if path.stat().st_size != record["bytes"] or sha256_file(path) != record["sha256"]:
            raise SystemExit(f"Moonleaf integrity mismatch: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".png":
            with Image.open(path) as image:
                if image.size != spec.pixel_size:
                    raise SystemExit(f"Moonleaf dimensions differ: {spec.relative_path}")
                if spec.role in alpha_required and "A" not in image.getbands():
                    raise SystemExit(f"Moonleaf alpha channel absent: {spec.relative_path}")
                if spec.role in alpha_required and image.getchannel("A").getextrema()[0] != 0:
                    raise SystemExit(f"Moonleaf transparent pixels absent: {spec.relative_path}")
                if spec.role == "seal.thumbnail" and image.size != (512, 512):
                    raise SystemExit(f"Moonleaf Seal thumbnail dimensions differ: {spec.relative_path}")
    for _, (relative, expected_hash) in OWNER_ARCHIVE_INPUTS.items():
        if sha256_file(authority_root / relative) != expected_hash:
            raise SystemExit(f"Moonleaf authority input differs: {relative}")
    _, background_master_fact = load_background_master(repo_root, BACKGROUND_SOURCE_MASTER)
    provenance_path = repo_root / "docs/verification/theme-fidelity-v4-3/inventory/Moonleaf-Production-Asset-Provenance-v4.3.json"
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if len(provenance.get("outputs", [])) != len(specs):
        raise SystemExit("Moonleaf provenance output coverage differs")
    received_reference = provenance.get("receivedIdentityExtraction", {})
    received_evidence_path = repo_root / received_reference.get("path", "")
    if (
        received_reference.get("path") != RECEIVED_IDENTITY_EVIDENCE
        or not received_evidence_path.is_file()
        or received_reference.get("sha256") != sha256_file(received_evidence_path)
    ):
        raise SystemExit("Moonleaf received identity evidence differs")
    received_evidence = json.loads(received_evidence_path.read_text(encoding="utf-8"))
    received_outputs = received_evidence.get("outputs", [])
    expected_received_ids = {
        spec.resource_id for spec in specs if spec.role.startswith("received.")
    }
    if {record.get("resourceID") for record in received_outputs} != expected_received_ids:
        raise SystemExit("Moonleaf received identity evidence coverage differs")
    try:
        qualified_received_evidence = received_identity_qualification_document(
            repo_root,
            received_evidence,
        )
    except RuntimeEvidenceError as error:
        raise SystemExit(
            f"Moonleaf target-device runtime evidence differs: {error}"
        ) from error
    recipe_reference = provenance.get("backgroundRecipe", {})
    recipe_path = repo_root / recipe_reference.get("path", "")
    if not recipe_path.is_file() or sha256_file(recipe_path) != recipe_reference.get("sha256"):
        raise SystemExit("Moonleaf background recipe differs")
    recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
    if recipe.get("ownerReview") != "PENDING" or len(recipe.get("outputs", [])) != 4:
        raise SystemExit("Moonleaf background recipe coverage differs")
    if recipe.get("productionSourceMaster") != background_master_fact:
        raise SystemExit("Moonleaf background recipe source master differs")
    if provenance.get("backgroundSourceMaster") != background_master_fact:
        raise SystemExit("Moonleaf provenance source master differs")
    expected_renderer = {
        "path": BACKGROUND_RENDERER,
        "sha256": sha256_file(repo_root / BACKGROUND_RENDERER),
    }
    if (
        recipe.get("renderer") != BACKGROUND_RENDERER
        or recipe.get("rendererSHA256") != expected_renderer["sha256"]
        or provenance.get("backgroundRenderer") != expected_renderer
    ):
        raise SystemExit("Moonleaf background renderer provenance differs")
    frame_master, frame_master_fact, crest_master, crest_master_fact = (
        load_accepted_role_masters(repo_root)
    )
    accepted_seal_sources = {
        slug: load_seal_source_master(repo_root, SEAL_SOURCE_MASTERS["moonleaf"][slug])
        for slug in MOONLEAF_SEALS
        if slug in SEAL_SOURCE_MASTERS["moonleaf"]
    }
    accepted_seal_facts = {
        slug: fact for slug, (_, fact) in accepted_seal_sources.items()
    }
    accepted_recipe_reference = provenance.get("acceptedSourceMasterRecipe", {})
    try:
        accepted_recipe = load_accepted_recipe(
            repo_root,
            accepted_master_recipe_relative_path(),
            accepted_recipe_reference,
        )
    except ValueError as error:
        raise SystemExit(
            f"Moonleaf accepted source-master recipe differs: {error}"
        ) from error
    expected_accepted_outputs = [
        item for item in provenance["outputs"] if accepted_master_output(item)
    ]
    if (
        accepted_recipe.get("ownerReview") != "PENDING"
        or accepted_recipe.get("id") != accepted_recipe_rights_id("moonleaf")
        or accepted_recipe.get("sourceMasters")
        != [frame_master_fact, crest_master_fact, *accepted_seal_facts.values()]
        or accepted_recipe.get("panelNineSlicePolicy") != panel_policy_record("moonleaf")
        or accepted_recipe.get("outputs") != expected_accepted_outputs
        or provenance.get("frameSourceMaster") != frame_master_fact
        or provenance.get("crestSourceMaster") != crest_master_fact
        or provenance.get("relicSourceMasters") != {}
        or provenance.get("sealSourceMasters") != accepted_seal_facts
        or provenance.get("blockers")
        != color_master_blockers(
            "moonleaf",
            MOONLEAF_SEALS,
            (*("crescentleaf", "woodland-stag"), *accepted_seal_sources),
        )
        or provenance.get("panelCapInsets") != panel_cap_insets_record()
        or provenance.get("panelNineSlicePolicy") != panel_policy_record("moonleaf")
    ):
        raise SystemExit("Moonleaf accepted source-master provenance differs")
    expected_frame = uniform_aspect_fit(frame_master, (2048, 1536))
    with Image.open(production / "frame/moonleaf-silvervine-static-fallback.png") as actual_frame:
        if ImageChops.difference(actual_frame.convert("RGBA"), expected_frame).getbbox() is not None:
            raise SystemExit("Moonleaf accepted Frame output differs")
    expected_crest = uniform_aspect_fit(crest_master, (1024, 1024))
    with Image.open(production / "crest/moonleaf-moonbloom-static-fallback.png") as actual_crest:
        if ImageChops.difference(actual_crest.convert("RGBA"), expected_crest).getbbox() is not None:
            raise SystemExit("Moonleaf accepted Crest output differs")
    expected_panels = panel_assets("moonleaf", frame_master)
    for panel, expected_panel in expected_panels.items():
        with Image.open(production / f"panel/moonleaf-{panel}.png") as actual_panel:
            if ImageChops.difference(actual_panel.convert("RGBA"), expected_panel).getbbox() is not None:
                raise SystemExit(f"Moonleaf protected Panel output differs: {panel}")
    for slug, (source, _) in accepted_seal_sources.items():
        expected_color, expected_monochrome, expected_thumbnail = render_seal_variants(source)
        for suffix, expected in (
            ("color-master", expected_color),
            ("monochrome-fallback", expected_monochrome),
            ("thumbnail", expected_thumbnail),
        ):
            with Image.open(production / f"seal/moonleaf-{slug}-{suffix}.png") as actual:
                if ImageChops.difference(actual.convert("RGBA"), expected).getbbox() is not None:
                    raise SystemExit(
                        f"Moonleaf accepted Seal output differs: {slug}/{suffix}"
                    )
    qualification_failures = production_qualification_failures(
        provenance,
        resources=resources,
        manifest_records=records,
        theme="moonleaf",
        required_seals=MOONLEAF_SEALS,
        supporting_documents=(
            ("receivedIdentityExtraction", qualified_received_evidence),
            ("acceptedSourceMasterRecipe", accepted_recipe),
            ("backgroundRecipe", recipe),
        ),
    )
    if qualification_failures:
        raise SystemExit("Moonleaf production qualification blocked: " + "; ".join(qualification_failures))
    if provenance.get("pipelineSHA256") != sha256_file(repo_root / PIPELINE):
        raise SystemExit("Moonleaf pipeline provenance differs")
    print(json.dumps({
        "status": "PASS",
        "theme": "Moonleaf",
        "resourceCount": len(specs),
        "shippingBytes": sum(record["bytes"] for record in records),
        "integrityManifestSHA256": sha256_file(manifest_path),
        "backgroundRecipeSHA256": sha256_file(recipe_path),
        "provenanceSHA256": sha256_file(provenance_path),
    }, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--authority-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--backgrounds-only", action="store_true")
    parser.add_argument("--accepted-masters-only", action="store_true")
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()
    authority_root = args.authority_root.resolve()
    if args.backgrounds_only or args.accepted_masters_only:
        if args.check or (args.backgrounds_only and args.accepted_masters_only):
            raise SystemExit("refresh modes and --check are mutually exclusive")
        refresh = (
            refresh_backgrounds_only
            if args.backgrounds_only
            else refresh_accepted_masters_only
        )
        print(json.dumps(refresh(repo_root, authority_root), indent=2))
        return 0
    if args.check:
        check_assets(repo_root, authority_root)
    else:
        build_assets(repo_root, authority_root)
        check_assets(repo_root, authority_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
