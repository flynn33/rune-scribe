#!/usr/bin/env python3
"""Build and verify the Sunspire, Wildwood, and Gloamthorn v4.3 assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

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
        FRAME_SOURCE_MASTERS,
        PANEL_CAP_INSETS,
        PANEL_TARGET_SIZES,
        RELIC_SOURCE_MASTERS,
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
        FRAME_SLICE_POLICIES,
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
        FRAME_SOURCE_MASTERS,
        PANEL_CAP_INSETS,
        PANEL_TARGET_SIZES,
        RELIC_SOURCE_MASTERS,
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
        FRAME_SLICE_POLICIES,
    )


ACCEPTED_PACKAGE_VERSION = "4.3.0"
CREATED_AT = "2026-08-27T00:00:00Z"
PIPELINE = "scripts/build-sunspire-wildwood-gloamthorn-v43-assets.py"
BACKGROUND_RENDERER = "scripts/theme_v43_background_master.py"

FRAME_VECTOR_PDF_LOCKS = {
    "sunspire": (
        "656ccf129f331672876123ffaa330c916f50d5829a40649be178f992f6fdaf03",
        "415baac64db3e7e3697194a71d09bf9d6c2ad6a213125285095c2a191672ba5e",
    ),
    "wildwood": (
        "381cdd2fcf44bbd164ed7e7401a413df726367b484a2b15c5d455f5fe0c18cd9",
        "b9fec1f2e0e7d1a9f3537be883886b90a29fb3795759171d2a8560bc17dcce33",
    ),
    "gloamthorn": (
        "048d120d0d5d430522cf9a9a0480abd4c7411bbcae490604498bc06dedc79aff",
        "e91c0b6a4e8c23d5d4876fbead496aa940cb805a02fdc1401e2bd47fccb9fcc5",
    ),
}


@dataclass(frozen=True)
class AuthorityInput:
    label: str
    relative_path: str
    sha256: str


@dataclass(frozen=True)
class RelicConfig:
    slug: str
    size: tuple[int, int]
    source_label: str
    crop: tuple[int, int, int, int]
    mask: str


@dataclass(frozen=True)
class SealSource:
    slug: str
    source_label: str
    crop: tuple[int, int, int, int]
    ellipse: tuple[float, float, float, float]


@dataclass(frozen=True)
class ThemeConfig:
    title: str
    slug: str
    module_id: str
    codex_id: str
    module_directory: str
    background_slug: str
    frame_slug: str
    crest_slug: str
    relics: tuple[RelicConfig, ...]
    seals: tuple[str, ...]
    authority_seals: tuple[SealSource, ...]
    inputs: tuple[AuthorityInput, ...]


THEMES = (
    ThemeConfig(
        title="Sunspire",
        slug="sunspire",
        module_id="com.runescribe.module.theme.sunspire",
        codex_id="codex.sunspire",
        module_directory="RuneScribeThemeSunspireModule",
        background_slug="hall-of-first-light",
        frame_slug="laurel-of-dawn",
        crest_slug="first-light",
        relics=(
            RelicConfig(
                "dawnfire-tablet",
                (1200, 1600),
                "catalog",
                (68, 283, 555, 810),
                "sunspire-tablet",
            ),
            RelicConfig("solvine-plaque", (1600, 1200), "catalog", (54, 932, 354, 1183), "sunspire-plaque"),
            RelicConfig("auric-stele", (1200, 1600), "catalog", (67, 1192, 355, 1462), "sunspire-stele"),
        ),
        seals=("sunleaf-crest", "golden-lark", "dawnflower", "sunwheel", "radiant-spire", "echo-ember"),
        authority_seals=(
            SealSource(
                "sunleaf-crest",
                "style-board",
                (40, 646, 270, 933),
                (0.02, 0.00, 0.98, 1.00),
            ),
            SealSource(
                "golden-lark",
                "style-board",
                (873, 722, 1057, 918),
                (0.00, 0.00, 1.00, 1.00),
            ),
        ),
        inputs=(
            AuthorityInput("catalog", "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/approved-source-full-004-941x1672.png", "6186c6ecd82e25409904daa2460b3fc1953d7a8209a5f224649285f7de8d696f"),
            AuthorityInput("style-board", "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/approved-source-full-013-1122x1402.png", "ea52db7c2f8a89354069b6f64a4751cb62ea439a968c6c1ba8309f8ac3145f5d"),
        ),
    ),
    ThemeConfig(
        title="Wildwood",
        slug="wildwood",
        module_id="com.runescribe.module.theme.wildwood",
        codex_id="codex.wildwood",
        module_directory="RuneScribeThemeWildwoodModule",
        background_slug="oldgrowth-hollow",
        frame_slug="living-root",
        crest_slug="heartwood-crown",
        relics=(
            RelicConfig(
                "rootsong-tablet",
                (1600, 1200),
                "catalog",
                (28, 280, 553, 800),
                "wildwood-tablet",
            ),
            RelicConfig(
                "mossbound-plaque",
                (1600, 1200),
                "catalog",
                (64, 844, 405, 1178),
                "wildwood-plaque",
            ),
            RelicConfig("elderbark-stele", (1200, 1600), "catalog", (105, 1192, 366, 1560), "wildwood-stele"),
        ),
        seals=("rooted-tree", "lantern-moth", "acorn-knot", "fern-spiral", "wild-fox", "echo-seed"),
        authority_seals=(
            SealSource("rooted-tree", "style-board", (774, 209, 1026, 461), (0.00, 0.00, 1.00, 1.00)),
            SealSource("lantern-moth", "style-board", (773, 653, 1027, 907), (0.00, 0.00, 1.00, 1.00)),
        ),
        inputs=(
            AuthorityInput("catalog", "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/approved-source-full-006-941x1672.png", "cb56d7415fdebae60d2bef7141001d7de3539732e16d1df71db5765a4810a792"),
            AuthorityInput("style-board", "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/approved-source-full-008-1122x1402.png", "d3e77551f5698ec82bc492001a3e478bcda81b76f721e171f2417dea1e1952b5"),
        ),
    ),
    ThemeConfig(
        title="Gloamthorn",
        slug="gloamthorn",
        module_id="com.runescribe.module.theme.gloamthorn",
        codex_id="codex.gloamthorn",
        module_directory="RuneScribeThemeGloamthornModule",
        background_slug="twilight-briar",
        frame_slug="briar-court",
        crest_slug="gloam-sovereign",
        relics=(
            RelicConfig(
                "nightthorn-tablet",
                (1600, 1200),
                "catalog",
                (40, 288, 545, 801),
                "gloamthorn-tablet",
            ),
            RelicConfig("umbral-plaque", (1600, 1200), "catalog", (46, 868, 322, 1104), "gloamthorn-plaque"),
            RelicConfig("duskbriar-stele", (1200, 1600), "catalog", (45, 1145, 337, 1480), "gloamthorn-stele"),
        ),
        seals=("echo-wisp", "eclipse-bloom", "nightglass-moth", "pact-crown", "thornmoon", "veiled-serpent"),
        authority_seals=(),
        inputs=(
            AuthorityInput("catalog", "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/approved-source-full-017-941x1672.png", "804a3142fc740cd152325f026be84e7c04704487671a1d2f989db4ed2d4cbcb3"),
        ),
    ),
)


BACKGROUND_SOURCE_MASTERS = {
    "sunspire": BackgroundMasterSpec(
        relative_path=(
            "docs/verification/theme-fidelity-v4-3/source-masters/sunspire/"
            "sunspire-environment-production-master-v4.3.png"
        ),
        sha256="1bc17b1ebb451caf8e0704f7f567cd4fa1ab3ca2939c0ca8ec01ff7218e80966",
        focal_point=(0.5, 0.5),
    ),
    "wildwood": BackgroundMasterSpec(
        relative_path=(
            "docs/verification/theme-fidelity-v4-3/source-masters/wildwood/"
            "wildwood-environment-production-master-v4.3.png"
        ),
        sha256="3aa724df0aa33106a16be9316e2e6cc8df3fd6b091c0e25eaa2bf166143b4be3",
        focal_point=(0.5, 0.5),
    ),
    "gloamthorn": BackgroundMasterSpec(
        relative_path=(
            "docs/verification/theme-fidelity-v4-3/source-masters/gloamthorn/"
            "gloamthorn-environment-production-master-v4.3.png"
        ),
        sha256="46ddc0e5b3e535e6f5886d4b4815c10d5b707017d574011d98dc400fa47911bc",
        focal_point=(0.5, 0.5),
    ),
}

BACKGROUND_VISUAL_AUTHORITY_LABELS = {
    "sunspire": "style-board",
    "wildwood": "style-board",
    "gloamthorn": "catalog",
}


@dataclass(frozen=True)
class ResourceSpec:
    resource_id: str
    relative_path: str
    role: str
    media_type: str
    maximum_bytes: int
    pixel_size: tuple[int, int] | None
    rights_id: str


REVIEW_EXPLANATION_KEYS = {"comment", "comments", "detail", "details", "note", "notes", "reason"}


def color_master_blockers(
    theme: str,
    required_seals: Sequence[str],
    available_seals: Sequence[str],
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
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False, compress_level=9)


def fit(image: Image.Image, size: tuple[int, int], *, margin: int = 0) -> Image.Image:
    result = Image.new("RGBA", size, (0, 0, 0, 0))
    source = image.convert("RGBA")
    bounds = source.getchannel("A").point(lambda value: 255 if value >= 6 else 0).getbbox()
    if bounds is not None:
        source = source.crop(bounds)
    available = (max(1, size[0] - margin * 2), max(1, size[1] - margin * 2))
    scale = min(available[0] / source.width, available[1] / source.height)
    source = source.resize(
        (max(1, round(source.width * scale)), max(1, round(source.height * scale))),
        Image.Resampling.LANCZOS,
    )
    result.alpha_composite(source, ((size[0] - source.width) // 2, (size[1] - source.height) // 2))
    return result


def rounded_mask(size: tuple[int, int], inset: int, radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (inset, inset, size[0] - inset - 1, size[1] - inset - 1),
        radius=radius,
        fill=255,
    )
    return mask.filter(ImageFilter.GaussianBlur(1.1))


def polygon_mask(size: tuple[int, int], points: Sequence[tuple[float, float]]) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon([(round(x * size[0]), round(y * size[1])) for x, y in points], fill=255)
    return mask.filter(ImageFilter.GaussianBlur(1.1))


def dark_panel_mask(image: Image.Image, low: float, high: float) -> Image.Image:
    values = []
    for red, green, blue, _ in image.getdata():
        luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        chroma = max(red, green, blue) - min(red, green, blue)
        signal = luminance + chroma * 0.24
        if signal <= low:
            values.append(0)
        elif signal >= high:
            values.append(255)
        else:
            unit = (signal - low) / (high - low)
            values.append(round(unit * unit * (3 - 2 * unit) * 255))
    mask = Image.new("L", image.size)
    mask.putdata(values)
    return mask.filter(ImageFilter.MaxFilter(7)).filter(ImageFilter.GaussianBlur(1.1))


def isolate_object(source: Image.Image, crop: tuple[int, int, int, int], mask_kind: str) -> Image.Image:
    image = source.convert("RGBA").crop(crop)
    if mask_kind == "sunspire-tablet":
        mask = polygon_mask(
            image.size,
            ((0.08, 0.12), (0.33, 0.09), (0.42, 0.01), (0.58, 0.01), (0.67, 0.09),
             (0.92, 0.12), (0.99, 0.22), (0.99, 0.91), (0.92, 0.99), (0.08, 0.99),
             (0.01, 0.91), (0.01, 0.22)),
        )
    elif mask_kind == "wildwood-tablet":
        mask = rounded_mask(image.size, 2, round(min(image.size) * 0.12))
    elif mask_kind == "gloamthorn-tablet":
        mask = rounded_mask(image.size, 3, round(min(image.size) * 0.14))
    elif mask_kind.endswith("-plaque"):
        thresholds = {
            "sunspire-plaque": (50, 90),
            "wildwood-plaque": (25, 55),
            "gloamthorn-plaque": (18, 40),
        }
        mask = ImageChops.multiply(
            dark_panel_mask(image, *thresholds[mask_kind]),
            rounded_mask(image.size, 3, round(min(image.size) * 0.11)),
        )
    elif mask_kind.endswith("-stele"):
        thresholds = {
            "sunspire-stele": (50, 90),
            "wildwood-stele": (25, 55),
            "gloamthorn-stele": (18, 40),
        }
        shape = polygon_mask(
            image.size,
            ((0.14, 0.01), (0.86, 0.01), (0.96, 0.17), (0.96, 0.91),
             (0.84, 0.99), (0.16, 0.99), (0.04, 0.91), (0.04, 0.17)),
        )
        mask = ImageChops.multiply(dark_panel_mask(image, *thresholds[mask_kind]), shape)
    elif mask_kind == "stele":
        mask = polygon_mask(
            image.size,
            ((0.20, 0.00), (0.80, 0.00), (0.96, 0.16), (0.96, 0.88), (0.86, 1.00),
             (0.14, 1.00), (0.04, 0.88), (0.04, 0.16)),
        )
    else:
        mask = rounded_mask(image.size, 1, round(min(image.size) * 0.12))
    image.putalpha(ImageChops.multiply(image.getchannel("A"), mask))
    return image


def isolate_seal(
    source: Image.Image,
    crop: tuple[int, int, int, int],
    ellipse: tuple[float, float, float, float],
) -> Image.Image:
    image = source.convert("RGBA").crop(crop)
    mask = Image.new("L", image.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.ellipse(
        (
            round(ellipse[0] * image.width), round(ellipse[1] * image.height),
            round(ellipse[2] * image.width), round(ellipse[3] * image.height),
        ),
        fill=255,
    )
    mask = mask.filter(ImageFilter.GaussianBlur(1.2))
    image.putalpha(mask)
    return image


def high_contrast_variant(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    alpha = rgba.getchannel("A")
    rgb = ImageEnhance.Contrast(rgba.convert("RGB")).enhance(1.34)
    rgb = ImageEnhance.Sharpness(rgb).enhance(1.18)
    result = rgb.convert("RGBA")
    result.putalpha(alpha)
    return result


def source_background(
    config: ThemeConfig,
    master: Image.Image,
    size: tuple[int, int],
    mode: str,
) -> Image.Image:
    specification = BACKGROUND_SOURCE_MASTERS[config.slug]
    return render_background_variant(
        master,
        size,
        mode=mode,
        focal_point=specification.focal_point,
    )


def render_script_specimen(font_path: Path, colors: tuple[tuple[int, int, int], tuple[int, int, int]], high_contrast: bool) -> Image.Image:
    image = Image.new("RGBA", (1600, 600), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype(str(font_path), 112 if high_contrast else 102)
    foreground = (255, 255, 255, 255) if high_contrast else (*colors[0], 255)
    shadow = (*colors[1], 210)
    tokens = [chr(0x16A0 + index) for index in range(32)]
    for index, token in enumerate(tokens):
        row, column = divmod(index, 16)
        x = 43 + column * 96
        y = 72 + row * 238
        draw.text((x + 3, y + 4), token, font=font, fill=shadow)
        draw.text((x, y), token, font=font, fill=foreground)
    return image


def rasterize_pdf(pdf_path: Path, size: tuple[int, int]) -> Image.Image:
    with tempfile.TemporaryDirectory(prefix="theme-v43-pdf-") as temporary:
        output = Path(temporary) / "render.png"
        result = subprocess.run(
            ["/usr/bin/sips", "-s", "format", "png", str(pdf_path), "--out", str(output)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0 or not output.is_file():
            raise RuntimeError(f"PDF rasterization failed for {pdf_path.name}: {result.stderr.strip()}")
        return Image.open(output).convert("RGBA").resize(size, Image.Resampling.LANCZOS)


def normalize_frame_vector_pdf(pdf_path: Path, slug: str) -> None:
    """Scale the locked 1600x1200 owner vector onto the required 2048x1536 page."""
    source_sha, output_sha = FRAME_VECTOR_PDF_LOCKS[slug]
    data = pdf_path.read_bytes()
    current_sha = hashlib.sha256(data).hexdigest()
    if current_sha == output_sha:
        return
    if current_sha != source_sha:
        raise SystemExit(f"{slug.title()} owner frame vector differs: {pdf_path.name}")
    match = re.search(
        rb"4 0 obj\s*<<\s*/Length\s+\d+\s*>>\s*stream\r?\n(.*?)\r?\nendstream",
        data,
        re.DOTALL,
    )
    if match is None or b"/MediaBox [0 0 1600 1200]" not in data:
        raise SystemExit(f"{slug.title()} owner frame vector structure differs: {pdf_path.name}")
    content = b"q\n1.28 0 0 1.28 0 0 cm\n" + match.group(1) + b"\nQ\n"
    objects = [
        b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        b"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
        b"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2048 1536] /Contents 4 0 R /Resources << >> >>\nendobj\n",
        b"4 0 obj\n<< /Length " + str(len(content)).encode("ascii")
        + b" >>\nstream\n" + content + b"endstream\nendobj\n",
    ]
    normalized = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for pdf_object in objects:
        offsets.append(len(normalized))
        normalized.extend(pdf_object)
    xref_offset = len(normalized)
    normalized.extend(b"xref\n0 5\n0000000000 65535 f \n")
    for offset in offsets:
        normalized.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    normalized.extend(b"trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n")
    normalized.extend(str(xref_offset).encode("ascii"))
    normalized.extend(b"\n%%EOF\n")
    if hashlib.sha256(normalized).hexdigest() != output_sha:
        raise SystemExit(f"{slug.title()} normalized frame vector differs: {pdf_path.name}")
    pdf_path.write_bytes(normalized)


def pdf_dimensions(pdf_path: Path) -> tuple[int, int]:
    match = re.search(
        rb"/MediaBox\s*\[\s*(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+"
        rb"(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*\]",
        pdf_path.read_bytes(),
    )
    if match is None:
        raise SystemExit(f"PDF MediaBox absent: {pdf_path.name}")
    x1, y1, x2, y2 = (float(value) for value in match.groups())
    return round(x2 - x1), round(y2 - y1)


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
    base = ImageOps.fit(background.convert("RGB"), size, method=Image.Resampling.LANCZOS).convert("RGBA")
    base = Image.alpha_composite(base, Image.new("RGBA", size, (0, 0, 0, 88)))
    base = Image.alpha_composite(base, frame_overlay.convert("RGBA"))
    base.alpha_composite(fit(relic, (1040, 760), margin=40), (280, 70))
    base.alpha_composite(fit(crest, (180, 180), margin=8), (710, 24))
    if mode == "encountered":
        base = ImageEnhance.Color(base.convert("RGB")).enhance(0.48).convert("RGBA")
    elif mode == "locked":
        base = ImageOps.grayscale(base.convert("RGB")).convert("RGBA")
        base = Image.alpha_composite(base, Image.new("RGBA", size, (0, 0, 0, 100)))
    elif mode == "selected":
        selected = ImageEnhance.Contrast(base.convert("RGB")).enhance(1.16).convert("RGBA")
        base = Image.alpha_composite(selected, frame_overlay.convert("RGBA"))
    elif mode == "unavailable":
        base = ImageEnhance.Color(base.convert("RGB")).enhance(0.12).convert("RGBA")
        base = Image.alpha_composite(base, Image.new("RGBA", size, (0, 0, 0, 150)))
    return base.convert("RGB").quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).convert("RGB")


def theme_colors(slug: str) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    return {
        "sunspire": ((242, 198, 109), (45, 36, 23)),
        "wildwood": ((172, 190, 119), (13, 30, 21)),
        "gloamthorn": ((204, 157, 222), (12, 17, 28)),
    }[slug]


def resource_specs(config: ThemeConfig) -> list[ResourceSpec]:
    specs: list[ResourceSpec] = []
    maximum = 16 * 1024 * 1024
    background_rights = f"prov.Production.Sources.{config.slug}.{config.slug}.background.recipe.json"
    vault_rights = f"prov.Production.Sources.{config.slug}.{config.slug}.vault.recipe.json"
    frame_vector_rights = f"prov.Source.Masters.Frames.{config.slug}.{config.frame_slug.replace('-', '.')}.svg"
    crest_vector_rights = f"prov.Source.Masters.Crests.{config.slug}.{config.crest_slug.replace('-', '.')}.svg"
    accepted_rights = accepted_recipe_rights_id(config.slug)
    script_rights = f"prov.Source.Masters.Glyphs.{config.slug}.glyph.master.json"

    def add(resource_id: str, path: str, role: str, media: str, size: tuple[int, int] | None, rights: str, limit: int = maximum) -> None:
        specs.append(ResourceSpec(resource_id, "Production/" + path, role, media, limit, size, rights))

    background_base = f"resource.background.{config.slug}.{config.background_slug}.output"
    add(background_base + ".background-static-base", f"background/{config.slug}-background-static.png", "background.static-base", "image/png", (2048, 2732), background_rights)
    add(background_base + ".background-reduce-motion", f"background/{config.slug}-background-reduce-motion.png", "background.reduce-motion", "image/png", (2048, 2732), background_rights)
    add(background_base + ".background-high-contrast", f"background/{config.slug}-background-high-contrast.png", "background.high-contrast", "image/png", (2048, 2732), background_rights)
    add(background_base + ".background-macos-wide-crop", f"background/{config.slug}-background-macos-wide.png", "background.macos-wide-crop", "image/png", (3200, 1800), background_rights)

    crest_base = f"resource.crest.{config.slug}.{config.crest_slug}.output"
    add(crest_base + ".crest-static-fallback", f"crest/{config.slug}-{config.crest_slug}-static-fallback.png", "crest.static-fallback", "image/png", (1024, 1024), accepted_rights)
    add(crest_base + ".crest-thumbnail", f"crest/{config.slug}-{config.crest_slug}-thumbnail.png", "crest.thumbnail", "image/png", (512, 512), accepted_rights, 4 * 1024 * 1024)
    add(crest_base + ".crest-vector-master", f"crest/{config.slug}-{config.crest_slug}-vector.pdf", "crest.vector-master", "application/pdf", (1024, 1024), crest_vector_rights, 4 * 1024 * 1024)

    frame_base = f"resource.frame.{config.slug}.{config.frame_slug}.output"
    add(frame_base + ".frame-static-fallback", f"frame/{config.slug}-{config.frame_slug}-static-fallback.png", "frame.static-fallback", "image/png", (2048, 1536), accepted_rights)
    add(frame_base + ".frame-thumbnail", f"frame/{config.slug}-{config.frame_slug}-thumbnail.png", "frame.thumbnail", "image/png", (512, 384), accepted_rights, 4 * 1024 * 1024)
    add(frame_base + ".frame-vector-master", f"frame/{config.slug}-{config.frame_slug}-vector.pdf", "frame.vector-master", "application/pdf", (2048, 1536), frame_vector_rights, 4 * 1024 * 1024)

    for relic in config.relics:
        rights = (
            accepted_rights
            if relic.slug in RELIC_SOURCE_MASTERS[config.slug]
            else f"prov.Source.Masters.Relic.Geometry.{config.slug}.{relic.slug.replace('-', '.')}.geometry.svg"
        )
        base = f"resource.relic.{config.slug}.{relic.slug}.output"
        prefix = f"relic/{config.slug}-{relic.slug}"
        add(base + ".relic-master", prefix + "-master.png", "relic.master", "image/png", relic.size, rights)
        add(base + ".relic-thumbnail", prefix + "-thumbnail.png", "relic.thumbnail", "image/png", (512, 512), rights, 4 * 1024 * 1024)
        add(base + ".relic-static-share-fallback", prefix + "-static-share-fallback.png", "relic.static-share-fallback", "image/png", relic.size, rights)
        add(base + ".relic-high-contrast", prefix + "-high-contrast.png", "relic.high-contrast", "image/png", relic.size, rights)

    add(f"resource.script.{config.slug}.output.script-font", f"script/{config.slug}-script-primary.ttf", "script.font", "font/ttf", None, script_rights, 8 * 1024 * 1024)
    add(f"resource.script.{config.slug}.output.script-static-fallback", f"script/{config.slug}-script-static-fallback.png", "script.static-fallback", "image/png", (1600, 600), script_rights, 8 * 1024 * 1024)
    add(f"resource.script.{config.slug}.output.script-specimen-standard", f"script/{config.slug}-script-specimen.png", "script.specimen-standard", "image/png", (1600, 600), script_rights, 8 * 1024 * 1024)
    add(f"resource.script.{config.slug}.output.script-specimen-high-contrast", f"script/{config.slug}-script-specimen-high-contrast.png", "script.specimen-high-contrast", "image/png", (1600, 600), script_rights, 8 * 1024 * 1024)

    for seal in config.seals:
        accepted_source = SEAL_SOURCE_MASTERS[config.slug].get(seal)
        raster_rights = (
            accepted_source.rights_id
            if accepted_source is not None
            else f"prov.Source.Masters.Seals.{config.slug}.{seal.replace('-', '.')}.svg"
        )
        vector_rights = f"prov.Source.Masters.Seals.{config.slug}.{seal.replace('-', '.')}.svg"
        color_size = accepted_source.pixel_size if accepted_source is not None else (1024, 1024)
        base = f"resource.seal.{config.slug}.{seal}.output"
        prefix = f"seal/{config.slug}-{seal}"
        add(base + ".seal-vector-master", prefix + "-vector-master.pdf", "seal.vector-master", "application/pdf", (1024, 1024), vector_rights, 4 * 1024 * 1024)
        add(base + ".seal-color-master", prefix + "-color-master.png", "seal.color-master", "image/png", color_size, raster_rights, 12 * 1024 * 1024)
        add(base + ".seal-monochrome-fallback", prefix + "-monochrome-fallback.png", "seal.monochrome-fallback", "image/png", color_size, raster_rights, 12 * 1024 * 1024)
        add(base + ".seal-thumbnail", prefix + "-thumbnail.png", "seal.thumbnail", "image/png", (512, 512), raster_rights, 4 * 1024 * 1024)

    for panel, size in PANEL_TARGET_SIZES.items():
        add(f"resource.panel.{config.slug}.{panel}", f"panel/{config.slug}-{panel}.png", f"panel.{panel}", "image/png", size, accepted_rights, 8 * 1024 * 1024)

    for filename, role in (
        ("card", "vault.card"),
        ("encountered", "vault.encountered"),
        ("locked", "vault.locked-silhouette"),
        ("selected", "vault.selected"),
        ("unavailable", "vault.unavailable"),
    ):
        suffix = role.split(".")[-1]
        add(f"resource.vault.{config.slug}.codex.output.vault-{suffix}", f"vault/{config.slug}-vault-{filename}.png", role, "image/png", (1600, 900), vault_rights)
    return sorted(specs, key=lambda value: value.relative_path)


def resources_root(repo_root: Path, config: ThemeConfig) -> Path:
    return repo_root / "Packages/RuneScribeArchitecture/Sources" / config.module_directory / "Resources"


def load_authority(config: ThemeConfig, authority_root: Path) -> tuple[dict[str, Image.Image], list[dict[str, Any]]]:
    images: dict[str, Image.Image] = {}
    facts = []
    for item in config.inputs:
        path = authority_root / item.relative_path
        actual = sha256_file(path)
        if actual != item.sha256:
            raise SystemExit(f"{config.title} authority input differs: {item.relative_path}")
        images[item.label] = Image.open(path).convert("RGB")
        facts.append({
            "dimensions": list(images[item.label].size),
            "label": item.label,
            "path": item.relative_path,
            "sha256": actual,
        })
    return images, facts


def background_recipe_document(
    repo_root: Path,
    config: ThemeConfig,
    authority_facts: Sequence[dict[str, Any]],
    background_master: Image.Image,
    background_master_fact: dict[str, Any],
    output_facts: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    specification = BACKGROUND_SOURCE_MASTERS[config.slug]
    return {
        "schemaVersion": "1.0",
        "id": f"prov.Production.Sources.{config.slug}.{config.slug}.background.recipe.json",
        "theme": config.title,
        "asset": f"background.{config.slug}.{config.background_slug}",
        "generatedAtUTC": CREATED_AT,
        "pipeline": PIPELINE,
        "pipelineSHA256": sha256_file(repo_root / PIPELINE),
        "renderer": BACKGROUND_RENDERER,
        "rendererSHA256": sha256_file(repo_root / BACKGROUND_RENDERER),
        "productionSourceMaster": background_master_fact,
        "visualAuthorityReference": next(
            item
            for item in authority_facts
            if item["label"] == BACKGROUND_VISUAL_AUTHORITY_LABELS[config.slug]
        ),
        "outputLayouts": {
            "phonePortrait": output_layout_record(
                background_master,
                (2048, 2732),
                specification.focal_point,
            ),
            "macOSWide": output_layout_record(
                background_master,
                (3200, 1800),
                specification.focal_point,
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
    config: ThemeConfig,
    background_master: Image.Image,
    background_master_fact: dict[str, Any],
) -> dict[str, Any]:
    specification = BACKGROUND_SOURCE_MASTERS[config.slug]
    return {
        "asset": f"background.{config.slug}.{config.background_slug}",
        "source": background_master_fact,
        "layouts": {
            "phonePortrait": output_layout_record(
                background_master,
                (2048, 2732),
                specification.focal_point,
            ),
            "macOSWide": output_layout_record(
                background_master,
                (3200, 1800),
                specification.focal_point,
            ),
        },
        "transformation": "continuous-master focal aspect-fill, one uniform scale per output, and prebuilt deterministic accessibility variants; no tiling, patch compositing, seams, nonuniform stretch, or completed-image blur",
    }


def render_background_outputs(
    repo_root: Path,
    config: ThemeConfig,
    production: Path,
) -> tuple[dict[str, Image.Image], Image.Image, dict[str, Any]]:
    specification = BACKGROUND_SOURCE_MASTERS[config.slug]
    background_master, background_master_fact = load_background_master(repo_root, specification)
    backgrounds = {
        "static": source_background(config, background_master, (2048, 2732), "standard"),
        "reduce-motion": source_background(
            config,
            background_master,
            (2048, 2732),
            "reduce-motion",
        ),
        "high-contrast": source_background(
            config,
            background_master,
            (2048, 2732),
            "high-contrast",
        ),
        "macos-wide": source_background(config, background_master, (3200, 1800), "standard"),
    }
    for name, image in backgrounds.items():
        save_png(image, production / f"background/{config.slug}-background-{name}.png")
    return backgrounds, background_master, background_master_fact


def load_accepted_role_masters(
    repo_root: Path,
    config: ThemeConfig,
) -> tuple[
    Image.Image,
    dict[str, Any],
    Image.Image,
    dict[str, Any],
    dict[str, tuple[Image.Image, dict[str, Any]]],
]:
    frame_master, frame_fact = load_source_master(
        repo_root,
        FRAME_SOURCE_MASTERS[config.slug],
    )
    crest_master, crest_fact = load_source_master(
        repo_root,
        CREST_SOURCE_MASTERS[config.slug],
    )
    relic_masters = {
        slug: load_source_master(repo_root, specification)
        for slug, specification in RELIC_SOURCE_MASTERS[config.slug].items()
    }
    return frame_master, frame_fact, crest_master, crest_fact, relic_masters


def render_relic_variants(
    master: Image.Image,
    target_size: tuple[int, int],
    prefix: Path,
) -> Image.Image:
    production_master = uniform_aspect_fit(master, target_size)
    save_png(production_master, Path(str(prefix) + "-master.png"))
    save_png(production_master.copy(), Path(str(prefix) + "-static-share-fallback.png"))
    save_png(high_contrast_variant(production_master), Path(str(prefix) + "-high-contrast.png"))
    save_png(
        uniform_aspect_fit(production_master, (512, 512)),
        Path(str(prefix) + "-thumbnail.png"),
    )
    return production_master


def render_accepted_frame_crest_and_panels(
    production: Path,
    config: ThemeConfig,
    frame_master: Image.Image,
    crest_master: Image.Image,
) -> tuple[Image.Image, Image.Image, Image.Image]:
    frame = uniform_aspect_fit(frame_master, (2048, 1536))
    save_png(frame, production / f"frame/{config.slug}-{config.frame_slug}-static-fallback.png")
    save_png(
        uniform_aspect_fit(frame_master, (512, 384)),
        production / f"frame/{config.slug}-{config.frame_slug}-thumbnail.png",
    )
    crest = uniform_aspect_fit(crest_master, (1024, 1024))
    save_png(crest, production / f"crest/{config.slug}-{config.crest_slug}-static-fallback.png")
    save_png(
        uniform_aspect_fit(crest_master, (512, 512)),
        production / f"crest/{config.slug}-{config.crest_slug}-thumbnail.png",
    )
    for panel, image in panel_assets(config.slug, frame_master).items():
        save_png(image, production / f"panel/{config.slug}-{panel}.png")
    vault_frame = render_nine_slice_frame(
        frame_master,
        (1600, 900),
        PANEL_CAP_INSETS["card-border"],
        FRAME_SLICE_POLICIES[config.slug],
    )
    return frame, crest, vault_frame


def panel_cap_insets_record(config: ThemeConfig) -> dict[str, dict[str, int] | None]:
    return {
        f"resource.panel.{config.slug}.{name}": caps.as_dict() if caps is not None else None
        for name, caps in PANEL_CAP_INSETS.items()
    }


def accepted_master_recipe_relative_path(config: ThemeConfig) -> str:
    return (
        "docs/verification/theme-fidelity-v4-3/inventory/recipes/"
        f"{config.title}-Accepted-Source-Master-Recipe-v4.3.json"
    )


def accepted_master_output(
    config: ThemeConfig,
    output: Mapping[str, Any],
) -> bool:
    role = str(output.get("role", ""))
    if role in {
        "frame.static-fallback",
        "frame.thumbnail",
        "crest.static-fallback",
        "crest.thumbnail",
    } or role.startswith("panel.") or role.startswith("vault."):
        return True
    resource_id = str(output.get("resourceID", ""))
    if role.startswith("relic."):
        return any(
            f"resource.relic.{config.slug}.{slug}.output." in resource_id
            for slug in RELIC_SOURCE_MASTERS[config.slug]
        )
    if role.startswith("seal."):
        return any(
            f"resource.seal.{config.slug}.{slug}.output." in resource_id
            for slug in SEAL_SOURCE_MASTERS[config.slug]
        )
    return False


def accepted_master_recipe_document(
    repo_root: Path,
    config: ThemeConfig,
    frame_fact: dict[str, Any],
    crest_fact: dict[str, Any],
    relic_facts: Mapping[str, dict[str, Any]],
    seal_facts: Mapping[str, dict[str, Any]],
    output_facts: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    source_facts = [
        frame_fact,
        crest_fact,
        *relic_facts.values(),
        *seal_facts.values(),
    ]
    source_records = {
        item["acceptanceRecord"]["path"]: item["acceptanceRecord"]
        for item in source_facts
    }
    return {
        "schemaVersion": "1.0",
        "id": accepted_recipe_rights_id(config.slug),
        "theme": config.title,
        "generatedAtUTC": CREATED_AT,
        "ownerReview": "PENDING",
        "pipeline": PIPELINE,
        "pipelineSHA256": sha256_file(repo_root / PIPELINE),
        "sourceMasters": source_facts,
        "sourceRecords": [source_records[path] for path in sorted(source_records)],
        "frameLayouts": {
            "staticFallback": aspect_fit_record(
                tuple(frame_fact["dimensions"]),
                (2048, 1536),
            ),
            "thumbnail": aspect_fit_record(
                tuple(frame_fact["dimensions"]),
                (512, 384),
            ),
        },
        "crestLayouts": {
            "staticFallback": aspect_fit_record(
                tuple(crest_fact["dimensions"]),
                (1024, 1024),
            ),
            "thumbnail": aspect_fit_record(
                tuple(crest_fact["dimensions"]),
                (512, 512),
            ),
        },
        "relicLayouts": {
            slug: {
                "master": aspect_fit_record(
                    tuple(fact["dimensions"]),
                    next(relic.size for relic in config.relics if relic.slug == slug),
                ),
                "thumbnail": aspect_fit_record(
                    next(relic.size for relic in config.relics if relic.slug == slug),
                    (512, 512),
                ),
            }
            for slug, fact in relic_facts.items()
        },
        "sealLayouts": {
            slug: seal_render_recipe_record(tuple(fact["dimensions"]))
            for slug, fact in seal_facts.items()
        },
        "panelNineSlicePolicy": panel_policy_record(config.slug),
        "transformationPolicy": [
            "verify each repository-local accepted source master and its acceptance record against pinned SHA-256 values",
            "render Frame and Crest fallbacks with one uniform aspect-fit scale and transparent letterboxing when required",
            "render accepted Relic variants from the complete clean master without inscription reconstruction, blur slabs, patches, or source-screen compositing",
            "compose Panel assets from four independent uniformly scaled protected corners and the contiguous between-corner edge intervals; never resize the complete frame nonuniformly",
            "preserve every accepted Seal color master as an exact decoded RGBA pixel copy and derive only alpha-preserving monochrome and thumbnail variants",
            "derive deterministic High Contrast and thumbnail variants and encode lossless PNG outputs",
        ],
        "outputs": [
            item for item in output_facts if accepted_master_output(config, item)
        ],
        "rightsOwner": "Raven Forge Software",
        "licenseNotice": "Project-local proprietary production masters; owner visual review remains pending",
    }


def accepted_master_extraction_recipes(
    config: ThemeConfig,
    frame_fact: dict[str, Any],
    crest_fact: dict[str, Any],
    relic_facts: Mapping[str, dict[str, Any]],
    seal_facts: Mapping[str, dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    recipes = [
        {
            "asset": f"frame.{config.slug}.{config.frame_slug}",
            "source": frame_fact,
            "transformation": "pinned accepted transparent master loaded unchanged, then rendered by deterministic uniform aspect-fit for static fallback and thumbnail",
        },
        {
            "asset": f"crest.{config.slug}.{config.crest_slug}",
            "source": crest_fact,
            "transformation": "pinned accepted transparent master loaded unchanged, then rendered by deterministic uniform aspect-fit for static fallback and thumbnail",
        },
        {
            "asset": f"panel.{config.slug}.chrome-set",
            "source": frame_fact,
            "policy": panel_policy_record(config.slug),
            "transformation": "protected-corner and contiguous-edge nine-slice composition with one shared cross-axis scale; transparent center; no complete-frame nonuniform resize",
        },
    ]
    recipes.extend(
        {
            "asset": f"relic.{config.slug}.{slug}",
            "source": fact,
            "transformation": "pinned complete clean master with identity-size uniform aspect-fit; deterministic thumbnail and High Contrast derivation; no reconstruction blur, patch, or inscription slab",
        }
        for slug, fact in relic_facts.items()
    )
    recipes.extend(
        {
            "asset": f"seal.{config.slug}.{slug}",
            "source": fact,
            "recipe": seal_render_recipe_record(tuple(fact["dimensions"])),
            "transformation": "decoded RGBA pixels preserved exactly for the color master; explicit alpha-preserving monochrome fallback and uniform aspect-fit thumbnail derived deterministically",
        }
        for slug, fact in (seal_facts or {}).items()
    )
    return recipes


def build_theme(repo_root: Path, authority_root: Path, config: ThemeConfig) -> None:
    resources = resources_root(repo_root, config)
    production = resources / "Production"
    images, authority_facts = load_authority(config, authority_root)
    backgrounds, background_master, background_master_fact = render_background_outputs(
        repo_root,
        config,
        production,
    )

    (
        frame_master,
        frame_master_fact,
        crest_master,
        crest_master_fact,
        accepted_relic_sources,
    ) = load_accepted_role_masters(repo_root, config)
    accepted_seal_sources = {
        slug: load_seal_source_master(repo_root, SEAL_SOURCE_MASTERS[config.slug][slug])
        for slug in config.seals
        if slug in SEAL_SOURCE_MASTERS[config.slug]
    }

    relic_masters: dict[str, Image.Image] = {}
    for relic in config.relics:
        prefix = production / f"relic/{config.slug}-{relic.slug}"
        if relic.slug in accepted_relic_sources:
            source, _ = accepted_relic_sources[relic.slug]
            relic_masters[relic.slug] = render_relic_variants(source, relic.size, prefix)
        else:
            source = isolate_object(images[relic.source_label], relic.crop, relic.mask)
            master = fit(source, relic.size, margin=round(min(relic.size) * 0.035))
            relic_masters[relic.slug] = master
            save_png(master, Path(str(prefix) + "-master.png"))
            save_png(master.copy(), Path(str(prefix) + "-static-share-fallback.png"))
            save_png(high_contrast_variant(master), Path(str(prefix) + "-high-contrast.png"))
            save_png(fit(master, (512, 512), margin=16), Path(str(prefix) + "-thumbnail.png"))

    authority_seals: dict[str, Image.Image] = {}
    for seal in config.authority_seals:
        isolated = isolate_seal(images[seal.source_label], seal.crop, seal.ellipse)
        master = fit(isolated, (1024, 1024), margin=35)
        authority_seals[seal.slug] = master
        prefix = production / f"seal/{config.slug}-{seal.slug}"
        color, monochrome, thumbnail = render_seal_variants(master)
        save_png(color, Path(str(prefix) + "-color-master.png"))
        save_png(monochrome, Path(str(prefix) + "-monochrome-fallback.png"))
        save_png(thumbnail, Path(str(prefix) + "-thumbnail.png"))

    for slug, (source, _) in accepted_seal_sources.items():
        color, monochrome, thumbnail = render_seal_variants(source)
        prefix = production / f"seal/{config.slug}-{slug}"
        save_png(color, Path(str(prefix) + "-color-master.png"))
        save_png(monochrome, Path(str(prefix) + "-monochrome-fallback.png"))
        save_png(thumbnail, Path(str(prefix) + "-thumbnail.png"))

    normalize_frame_vector_pdf(
        production / f"frame/{config.slug}-{config.frame_slug}-vector.pdf",
        config.slug,
    )

    default_relic = relic_masters[config.relics[0].slug]
    frame, crest, vault_frame = render_accepted_frame_crest_and_panels(
        production,
        config,
        frame_master,
        crest_master,
    )

    font = production / f"script/{config.slug}-script-primary.ttf"
    specimen = render_script_specimen(font, theme_colors(config.slug), False)
    specimen_high = render_script_specimen(font, theme_colors(config.slug), True)
    save_png(specimen, production / f"script/{config.slug}-script-specimen.png")
    save_png(specimen.copy(), production / f"script/{config.slug}-script-static-fallback.png")
    save_png(specimen_high, production / f"script/{config.slug}-script-specimen-high-contrast.png")

    for mode in ("card", "encountered", "locked", "selected", "unavailable"):
        card = vault_card(backgrounds["macos-wide"], default_relic, vault_frame, crest, mode)
        save_png(card, production / f"vault/{config.slug}-vault-{mode}.png")

    obsolete = [
        production / f"relic/{config.slug}-{relic.slug}-{suffix}.heif"
        for relic in config.relics
        for suffix in ("thumbnail", "static-share-fallback")
    ] + [
        production / f"seal/{config.slug}-{seal}-monochrome-fallback.pdf"
        for seal in config.seals
    ] + [
        production / f"seal/{config.slug}-{seal}-picker-specimen.png"
        for seal in config.seals
    ]
    for path in obsolete:
        if path.is_file():
            path.unlink()

    specs = resource_specs(config)
    records = []
    for spec in specs:
        path = resources / spec.relative_path
        if not path.is_file():
            raise SystemExit(f"Missing {config.title} resource: {spec.relative_path}")
        byte_count = path.stat().st_size
        if byte_count > spec.maximum_bytes:
            raise SystemExit(f"{config.title} resource exceeds byte budget: {spec.relative_path}")
        if spec.pixel_size is not None:
            if path.suffix == ".png":
                with Image.open(path) as image:
                    actual_size = image.size
            elif path.suffix == ".pdf":
                actual_size = pdf_dimensions(path)
            else:
                actual_size = None
            if actual_size is not None and actual_size != spec.pixel_size:
                raise SystemExit(f"{config.title} resource dimensions differ: {spec.relative_path}")
        records.append({
            "bytes": byte_count,
            "path": spec.relative_path,
            "resourceID": spec.resource_id,
            "role": spec.role,
            "sha256": sha256_file(path),
        })

    integrity = {
        "acceptedPackageVersion": ACCEPTED_PACKAGE_VERSION,
        "codexID": config.codex_id,
        "files": records,
        "moduleID": config.module_id,
        "schemaVersion": "1.0",
    }
    integrity_path = production / "Resource-Integrity-Manifest-v1.0.json"
    write_json(integrity_path, integrity)
    write_module_manifest(resources, config, specs, integrity_path)
    module_manifest = resources / "module-manifest.json"
    write_pins(repo_root, config, specs, records, integrity_path, module_manifest)

    output_facts = []
    for spec, record in zip(specs, records):
        path = resources / spec.relative_path
        alpha: bool | None = None
        if path.suffix == ".png":
            with Image.open(path) as image:
                alpha = "A" in image.getbands()
        output_facts.append({
            **record,
            "dimensions": list(spec.pixel_size) if spec.pixel_size else None,
            "hasAlpha": alpha,
            "mediaType": spec.media_type,
            "rightsID": spec.rights_id,
        })

    recipe_relative_path = f"docs/verification/theme-fidelity-v4-3/inventory/recipes/{config.title}-Background-Extraction-Recipe-v4.3.json"
    recipe_path = repo_root / recipe_relative_path
    background_recipe = background_recipe_document(
        repo_root,
        config,
        authority_facts,
        background_master,
        background_master_fact,
        output_facts,
    )
    write_json(recipe_path, background_recipe)

    accepted_relic_facts = {
        slug: fact for slug, (_, fact) in accepted_relic_sources.items()
    }
    accepted_seal_facts = {
        slug: fact for slug, (_, fact) in accepted_seal_sources.items()
    }
    accepted_recipe_relative_path = accepted_master_recipe_relative_path(config)
    accepted_recipe_path = repo_root / accepted_recipe_relative_path
    write_json(
        accepted_recipe_path,
        accepted_master_recipe_document(
            repo_root,
            config,
            frame_master_fact,
            crest_master_fact,
            accepted_relic_facts,
            accepted_seal_facts,
            output_facts,
        ),
    )

    extraction_recipes = []
    for relic in config.relics:
        if relic.slug in accepted_relic_facts:
            continue
        extraction_recipes.append({
            "asset": f"relic.{config.slug}.{relic.slug}",
            "crop": list(relic.crop),
            "source": relic.source_label,
            "transformation": "owner-source object isolation, source-pixel inscription-field reconstruction when specified, alpha normalization, and lossless aspect-fit resampling",
        })
    for seal in config.authority_seals:
        extraction_recipes.append({
            "asset": f"seal.{config.slug}.{seal.slug}",
            "crop": list(seal.crop),
            "source": seal.source_label,
            "transformation": "owner-source medallion isolation, alpha normalization, and lossless aspect-fit resampling",
        })
    extraction_recipes.append(
        background_extraction_recipe(config, background_master, background_master_fact)
    )
    extraction_recipes.extend(
        accepted_master_extraction_recipes(
            config,
            frame_master_fact,
            crest_master_fact,
            accepted_relic_facts,
            accepted_seal_facts,
        )
    )
    blockers = color_master_blockers(
        config.slug,
        config.seals,
        (*tuple(seal.slug for seal in config.authority_seals), *accepted_seal_sources),
    )
    provenance = {
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
        "relicSourceMasters": accepted_relic_facts,
        "sealSourceMasters": accepted_seal_facts,
        "authorityPolicy": "offline owner-archive extraction and repository-local production source masters only; authoring inputs are not bundled or read at runtime",
        "blockers": blockers,
        "codexID": config.codex_id,
        "extractionRecipes": extraction_recipes,
        "generatedAtUTC": CREATED_AT,
        "outputs": output_facts,
        "panelCapInsets": panel_cap_insets_record(config),
        "panelNineSlicePolicy": panel_policy_record(config.slug),
        "pipeline": PIPELINE,
        "pipelineSHA256": sha256_file(repo_root / PIPELINE),
        "schemaVersion": "1.0",
        "targetScaleReview": {
            "implementationReview": "PASS",
            "ownerReview": "PENDING",
            "reason": "The continuous environment and accepted Frame, Crest, clean Relic, and detailed Seal masters use pinned deterministic aspect-fill, aspect-fit, RGBA-preserving, and protected nine-slice recipes; owner visual review remains pending.",
        },
        "theme": config.title,
    }
    provenance_path = repo_root / f"docs/verification/theme-fidelity-v4-3/inventory/{config.title}-Production-Asset-Provenance-v4.3.json"
    write_json(provenance_path, provenance)


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def write_pins(
    repo_root: Path,
    config: ThemeConfig,
    specs: Sequence[ResourceSpec],
    records: Sequence[dict[str, Any]],
    integrity_path: Path,
    module_manifest_path: Path,
) -> None:
    type_name = f"{config.title}V43ResourcePins"
    definition_name = f"{config.title}ThemeResourceDefinition"
    lines = [
        "import Foundation",
        "import RuneScribeContracts",
        "",
        f"enum {type_name} {{",
        f"    static let integrityManifestByteCount = {integrity_path.stat().st_size}",
        f"    static let integrityManifestSHA256Hex = {swift_string(sha256_file(integrity_path))}",
        f"    static let moduleManifestByteCount = {module_manifest_path.stat().st_size}",
        f"    static let moduleManifestSHA256Hex = {swift_string(sha256_file(module_manifest_path))}",
        f"    static let productionShippingByteCount = {sum(record['bytes'] for record in records)}",
        "",
        f"    static let productionDefinitions: [{definition_name}] = [",
    ]
    media_names = {"image/png": ".png", "application/pdf": ".pdf", "font/ttf": ".ttf"}
    for spec, record in zip(specs, records):
        path = Path(spec.relative_path)
        lines.extend([
            f"        {definition_name}(",
            f"            id: ThemeResourceID(rawValue: {swift_string(spec.resource_id)})!,",
            f"            resource: ApplicationResource(name: {swift_string(path.stem)}, fileExtension: {swift_string(path.suffix.removeprefix('.'))}, ownerModuleID: {swift_string(config.module_id)}),",
            f"            relativePath: {swift_string(spec.relative_path)},",
            f"            role: ThemeResourceRoleID(rawValue: {swift_string(spec.role)})!,",
            f"            mediaType: {media_names[spec.media_type]},",
            "            requirement: .required,",
            f"            sha256Hex: {swift_string(record['sha256'])},",
            f"            byteCount: {record['bytes']},",
            f"            maximumByteCount: {spec.maximum_bytes},",
            f"            pixelWidth: {spec.pixel_size[0] if spec.pixel_size else 'nil'},",
            f"            pixelHeight: {spec.pixel_size[1] if spec.pixel_size else 'nil'},",
            f"            rightsID: ThemeProvenanceID(rawValue: {swift_string(spec.rights_id)})!",
            "        ),",
        ])
    lines.extend(["    ]", "}", ""])
    destination = repo_root / "Packages/RuneScribeArchitecture/Sources" / config.module_directory / f"{type_name}.swift"
    destination.write_text("\n".join(lines), encoding="utf-8")


def write_module_manifest(resources: Path, config: ThemeConfig, specs: Sequence[ResourceSpec], integrity_path: Path) -> None:
    path = resources / "module-manifest.json"
    current = json.loads(path.read_text(encoding="utf-8"))
    files = [path, integrity_path] + [resources / spec.relative_path for spec in specs]
    current["runtimeRequirements"]["requiredResources"] = [
        {
            "fileExtension": file.suffix.removeprefix("."),
            "name": file.stem,
            "ownerModuleID": config.module_id,
            "subdirectory": None,
        }
        for file in files
    ]
    write_json(path, current)


def refresh_backgrounds_only(
    repo_root: Path,
    authority_root: Path,
    config: ThemeConfig,
) -> dict[str, Any]:
    resources = resources_root(repo_root, config)
    production = resources / "Production"
    _, authority_facts = load_authority(config, authority_root)
    _, background_master, background_master_fact = render_background_outputs(
        repo_root,
        config,
        production,
    )

    specs = resource_specs(config)
    records = []
    for spec in specs:
        path = resources / spec.relative_path
        if not path.is_file():
            raise SystemExit(f"Missing {config.title} resource: {spec.relative_path}")
        byte_count = path.stat().st_size
        if byte_count > spec.maximum_bytes:
            raise SystemExit(f"{config.title} resource exceeds byte budget: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".png":
            with Image.open(path) as image:
                if image.size != spec.pixel_size:
                    raise SystemExit(f"{config.title} resource dimensions differ: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".pdf":
            if pdf_dimensions(path) != spec.pixel_size:
                raise SystemExit(f"{config.title} resource dimensions differ: {spec.relative_path}")
        records.append({
            "bytes": byte_count,
            "path": spec.relative_path,
            "resourceID": spec.resource_id,
            "role": spec.role,
            "sha256": sha256_file(path),
        })

    integrity = {
        "acceptedPackageVersion": ACCEPTED_PACKAGE_VERSION,
        "codexID": config.codex_id,
        "files": records,
        "moduleID": config.module_id,
        "schemaVersion": "1.0",
    }
    integrity_path = production / "Resource-Integrity-Manifest-v1.0.json"
    write_json(integrity_path, integrity)
    write_module_manifest(resources, config, specs, integrity_path)
    module_manifest = resources / "module-manifest.json"
    write_pins(repo_root, config, specs, records, integrity_path, module_manifest)

    output_facts = []
    for spec, record in zip(specs, records):
        path = resources / spec.relative_path
        alpha: bool | None = None
        if path.suffix == ".png":
            with Image.open(path) as image:
                alpha = "A" in image.getbands()
        output_facts.append({
            **record,
            "dimensions": list(spec.pixel_size) if spec.pixel_size else None,
            "hasAlpha": alpha,
            "mediaType": spec.media_type,
            "rightsID": spec.rights_id,
        })

    recipe_relative_path = f"docs/verification/theme-fidelity-v4-3/inventory/recipes/{config.title}-Background-Extraction-Recipe-v4.3.json"
    recipe_path = repo_root / recipe_relative_path
    recipe = background_recipe_document(
        repo_root,
        config,
        authority_facts,
        background_master,
        background_master_fact,
        output_facts,
    )
    write_json(recipe_path, recipe)

    provenance_path = repo_root / f"docs/verification/theme-fidelity-v4-3/inventory/{config.title}-Production-Asset-Provenance-v4.3.json"
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    background_asset = f"background.{config.slug}.{config.background_slug}"
    extraction_recipes = [
        record
        for record in provenance.get("extractionRecipes", [])
        if record.get("asset") != background_asset
    ]
    extraction_recipes.append(
        background_extraction_recipe(config, background_master, background_master_fact)
    )
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
        "theme": config.title,
    }


def refresh_accepted_masters_only(
    repo_root: Path,
    authority_root: Path,
    config: ThemeConfig,
) -> dict[str, Any]:
    resources = resources_root(repo_root, config)
    production = resources / "Production"
    _, authority_facts = load_authority(config, authority_root)
    background_master, background_master_fact = load_background_master(
        repo_root,
        BACKGROUND_SOURCE_MASTERS[config.slug],
    )
    (
        frame_master,
        frame_master_fact,
        crest_master,
        crest_master_fact,
        accepted_relic_sources,
    ) = load_accepted_role_masters(repo_root, config)
    accepted_seal_sources = {
        slug: load_seal_source_master(repo_root, SEAL_SOURCE_MASTERS[config.slug][slug])
        for slug in config.seals
        if slug in SEAL_SOURCE_MASTERS[config.slug]
    }
    for slug, (source, _) in accepted_seal_sources.items():
        color, monochrome, thumbnail = render_seal_variants(source)
        prefix = production / f"seal/{config.slug}-{slug}"
        save_png(color, Path(str(prefix) + "-color-master.png"))
        save_png(monochrome, Path(str(prefix) + "-monochrome-fallback.png"))
        save_png(thumbnail, Path(str(prefix) + "-thumbnail.png"))

    relic_masters: dict[str, Image.Image] = {}
    for relic in config.relics:
        prefix = production / f"relic/{config.slug}-{relic.slug}"
        if relic.slug in accepted_relic_sources:
            source, _ = accepted_relic_sources[relic.slug]
            relic_masters[relic.slug] = render_relic_variants(source, relic.size, prefix)
        else:
            with Image.open(Path(str(prefix) + "-master.png")) as opened:
                relic_masters[relic.slug] = opened.convert("RGBA")

    frame, crest, vault_frame = render_accepted_frame_crest_and_panels(
        production,
        config,
        frame_master,
        crest_master,
    )
    with Image.open(production / f"background/{config.slug}-background-macos-wide.png") as opened:
        wide_background = opened.convert("RGB")
    default_relic = relic_masters[config.relics[0].slug]
    for mode in ("card", "encountered", "locked", "selected", "unavailable"):
        save_png(
            vault_card(wide_background, default_relic, vault_frame, crest, mode),
            production / f"vault/{config.slug}-vault-{mode}.png",
        )

    specs = resource_specs(config)
    records = []
    for spec in specs:
        path = resources / spec.relative_path
        if not path.is_file():
            raise SystemExit(f"Missing {config.title} resource: {spec.relative_path}")
        byte_count = path.stat().st_size
        if byte_count > spec.maximum_bytes:
            raise SystemExit(f"{config.title} resource exceeds byte budget: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".png":
            with Image.open(path) as image:
                if image.size != spec.pixel_size:
                    raise SystemExit(f"{config.title} resource dimensions differ: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".pdf":
            if pdf_dimensions(path) != spec.pixel_size:
                raise SystemExit(f"{config.title} resource dimensions differ: {spec.relative_path}")
        records.append({
            "bytes": byte_count,
            "path": spec.relative_path,
            "resourceID": spec.resource_id,
            "role": spec.role,
            "sha256": sha256_file(path),
        })

    integrity = {
        "acceptedPackageVersion": ACCEPTED_PACKAGE_VERSION,
        "codexID": config.codex_id,
        "files": records,
        "moduleID": config.module_id,
        "schemaVersion": "1.0",
    }
    integrity_path = production / "Resource-Integrity-Manifest-v1.0.json"
    write_json(integrity_path, integrity)
    write_module_manifest(resources, config, specs, integrity_path)
    module_manifest = resources / "module-manifest.json"
    write_pins(repo_root, config, specs, records, integrity_path, module_manifest)

    output_facts = []
    for spec, record in zip(specs, records):
        path = resources / spec.relative_path
        alpha: bool | None = None
        if path.suffix == ".png":
            with Image.open(path) as image:
                alpha = "A" in image.getbands()
        output_facts.append({
            **record,
            "dimensions": list(spec.pixel_size) if spec.pixel_size else None,
            "hasAlpha": alpha,
            "mediaType": spec.media_type,
            "rightsID": spec.rights_id,
        })

    background_recipe_relative_path = (
        f"docs/verification/theme-fidelity-v4-3/inventory/recipes/"
        f"{config.title}-Background-Extraction-Recipe-v4.3.json"
    )
    background_recipe_path = repo_root / background_recipe_relative_path
    write_json(
        background_recipe_path,
        background_recipe_document(
            repo_root,
            config,
            authority_facts,
            background_master,
            background_master_fact,
            output_facts,
        ),
    )

    accepted_relic_facts = {
        slug: fact for slug, (_, fact) in accepted_relic_sources.items()
    }
    accepted_seal_facts = {
        slug: fact for slug, (_, fact) in accepted_seal_sources.items()
    }
    accepted_recipe_relative_path = accepted_master_recipe_relative_path(config)
    accepted_recipe_path = repo_root / accepted_recipe_relative_path
    write_json(
        accepted_recipe_path,
        accepted_master_recipe_document(
            repo_root,
            config,
            frame_master_fact,
            crest_master_fact,
            accepted_relic_facts,
            accepted_seal_facts,
            output_facts,
        ),
    )

    provenance_path = repo_root / (
        f"docs/verification/theme-fidelity-v4-3/inventory/"
        f"{config.title}-Production-Asset-Provenance-v4.3.json"
    )
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    replaced_assets = {
        f"background.{config.slug}.{config.background_slug}",
        f"frame.{config.slug}.{config.frame_slug}",
        f"crest.{config.slug}.{config.crest_slug}",
        f"panel.{config.slug}.chrome-set",
        *(f"relic.{config.slug}.{slug}" for slug in accepted_relic_facts),
        *(f"seal.{config.slug}.{slug}" for slug in accepted_seal_facts),
    }
    extraction_recipes = [
        record
        for record in provenance.get("extractionRecipes", [])
        if record.get("asset") not in replaced_assets
    ]
    extraction_recipes.extend([
        background_extraction_recipe(
            config,
            background_master,
            background_master_fact,
        ),
        *accepted_master_extraction_recipes(
            config,
            frame_master_fact,
            crest_master_fact,
            accepted_relic_facts,
            accepted_seal_facts,
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
        "panelCapInsets": panel_cap_insets_record(config),
        "panelNineSlicePolicy": panel_policy_record(config.slug),
        "pipelineSHA256": sha256_file(repo_root / PIPELINE),
        "relicSourceMasters": accepted_relic_facts,
        "sealSourceMasters": accepted_seal_facts,
        "blockers": color_master_blockers(
            config.slug,
            config.seals,
            (*tuple(seal.slug for seal in config.authority_seals), *accepted_seal_sources),
        ),
        "targetScaleReview": {
            "implementationReview": "PASS",
            "ownerReview": "PENDING",
            "reason": "The continuous environment and accepted Frame, Crest, clean Relic, and detailed Seal masters use pinned deterministic aspect-fill, aspect-fit, RGBA-preserving, and protected nine-slice recipes; owner visual review remains pending.",
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
        "theme": config.title,
    }


def check_theme(repo_root: Path, authority_root: Path, config: ThemeConfig) -> dict[str, Any]:
    resources = resources_root(repo_root, config)
    production = resources / "Production"
    manifest_path = production / "Resource-Integrity-Manifest-v1.0.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    specs = resource_specs(config)
    records = manifest.get("files")
    if manifest.get("acceptedPackageVersion") != ACCEPTED_PACKAGE_VERSION or not isinstance(records, list):
        raise SystemExit(f"{config.title} v4.3 integrity manifest identity differs")
    if len(records) != len(specs):
        raise SystemExit(f"{config.title} output count differs: {len(records)} != {len(specs)}")
    expected_paths = {spec.relative_path for spec in specs}
    if {record.get("path") for record in records} != expected_paths:
        raise SystemExit(f"{config.title} integrity path set differs")
    actual_paths = {
        "Production/" + str(path.relative_to(production))
        for path in production.rglob("*")
        if path.is_file() and path != manifest_path
    }
    if actual_paths != expected_paths:
        raise SystemExit(f"{config.title} Production directory contains unpinned resources")
    by_path = {spec.relative_path: spec for spec in specs}
    alpha_required = {
        "relic.master", "relic.thumbnail", "relic.static-share-fallback", "relic.high-contrast",
        "seal.color-master", "seal.monochrome-fallback", "seal.thumbnail",
        "frame.static-fallback", "frame.thumbnail", "crest.static-fallback", "crest.thumbnail",
        "script.static-fallback", "script.specimen-standard", "script.specimen-high-contrast",
        "panel.card-border", "panel.corner-ornament", "panel.divider", "panel.primary-button", "panel.tab-selector",
    }
    for record in records:
        spec = by_path[record["path"]]
        path = resources / spec.relative_path
        if path.stat().st_size != record["bytes"] or sha256_file(path) != record["sha256"]:
            raise SystemExit(f"{config.title} integrity mismatch: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".pdf":
            if pdf_dimensions(path) != spec.pixel_size:
                raise SystemExit(f"{config.title} dimensions differ: {spec.relative_path}")
        if spec.pixel_size is not None and path.suffix == ".png":
            with Image.open(path) as image:
                if image.size != spec.pixel_size:
                    raise SystemExit(f"{config.title} dimensions differ: {spec.relative_path}")
                if spec.role in alpha_required and "A" not in image.getbands():
                    raise SystemExit(f"{config.title} alpha channel absent: {spec.relative_path}")
                if spec.role == "seal.thumbnail" and image.size != (512, 512):
                    raise SystemExit(f"{config.title} seal thumbnail dimensions differ: {spec.relative_path}")
    load_authority(config, authority_root)
    _, background_master_fact = load_background_master(
        repo_root,
        BACKGROUND_SOURCE_MASTERS[config.slug],
    )
    provenance_path = repo_root / f"docs/verification/theme-fidelity-v4-3/inventory/{config.title}-Production-Asset-Provenance-v4.3.json"
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if len(provenance.get("outputs", [])) != len(specs):
        raise SystemExit(f"{config.title} provenance coverage differs")
    recipe_reference = provenance.get("backgroundRecipe", {})
    recipe_path = repo_root / recipe_reference.get("path", "")
    if not recipe_path.is_file() or sha256_file(recipe_path) != recipe_reference.get("sha256"):
        raise SystemExit(f"{config.title} background recipe differs")
    recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
    if recipe.get("ownerReview") != "PENDING" or len(recipe.get("outputs", [])) != 4:
        raise SystemExit(f"{config.title} background recipe coverage differs")
    if recipe.get("productionSourceMaster") != background_master_fact:
        raise SystemExit(f"{config.title} background recipe source master differs")
    if provenance.get("backgroundSourceMaster") != background_master_fact:
        raise SystemExit(f"{config.title} provenance source master differs")
    expected_renderer = {
        "path": BACKGROUND_RENDERER,
        "sha256": sha256_file(repo_root / BACKGROUND_RENDERER),
    }
    if (
        recipe.get("renderer") != BACKGROUND_RENDERER
        or recipe.get("rendererSHA256") != expected_renderer["sha256"]
        or provenance.get("backgroundRenderer") != expected_renderer
    ):
        raise SystemExit(f"{config.title} background renderer provenance differs")
    (
        frame_master,
        frame_master_fact,
        crest_master,
        crest_master_fact,
        accepted_relic_sources,
    ) = load_accepted_role_masters(repo_root, config)
    accepted_relic_facts = {
        slug: fact for slug, (_, fact) in accepted_relic_sources.items()
    }
    accepted_seal_sources = {
        slug: load_seal_source_master(repo_root, SEAL_SOURCE_MASTERS[config.slug][slug])
        for slug in config.seals
        if slug in SEAL_SOURCE_MASTERS[config.slug]
    }
    accepted_seal_facts = {
        slug: fact for slug, (_, fact) in accepted_seal_sources.items()
    }
    accepted_recipe_reference = provenance.get("acceptedSourceMasterRecipe", {})
    try:
        accepted_recipe = load_accepted_recipe(
            repo_root,
            accepted_master_recipe_relative_path(config),
            accepted_recipe_reference,
        )
    except ValueError as error:
        raise SystemExit(
            f"{config.title} accepted source-master recipe differs: {error}"
        ) from error
    expected_source_facts = [
        frame_master_fact,
        crest_master_fact,
        *accepted_relic_facts.values(),
        *accepted_seal_facts.values(),
    ]
    expected_accepted_outputs = [
        item for item in provenance["outputs"] if accepted_master_output(config, item)
    ]
    if (
        accepted_recipe.get("ownerReview") != "PENDING"
        or accepted_recipe.get("id") != accepted_recipe_rights_id(config.slug)
        or accepted_recipe.get("sourceMasters") != expected_source_facts
        or accepted_recipe.get("panelNineSlicePolicy") != panel_policy_record(config.slug)
        or accepted_recipe.get("outputs") != expected_accepted_outputs
        or provenance.get("frameSourceMaster") != frame_master_fact
        or provenance.get("crestSourceMaster") != crest_master_fact
        or provenance.get("relicSourceMasters") != accepted_relic_facts
        or provenance.get("sealSourceMasters") != accepted_seal_facts
        or provenance.get("blockers")
        != color_master_blockers(
            config.slug,
            config.seals,
            (*tuple(seal.slug for seal in config.authority_seals), *accepted_seal_sources),
        )
        or provenance.get("panelCapInsets") != panel_cap_insets_record(config)
        or provenance.get("panelNineSlicePolicy") != panel_policy_record(config.slug)
    ):
        raise SystemExit(f"{config.title} accepted source-master provenance differs")
    expected_frame = uniform_aspect_fit(frame_master, (2048, 1536))
    with Image.open(
        production / f"frame/{config.slug}-{config.frame_slug}-static-fallback.png"
    ) as actual_frame:
        if ImageChops.difference(actual_frame.convert("RGBA"), expected_frame).getbbox() is not None:
            raise SystemExit(f"{config.title} accepted Frame output differs")
    expected_crest = uniform_aspect_fit(crest_master, (1024, 1024))
    with Image.open(
        production / f"crest/{config.slug}-{config.crest_slug}-static-fallback.png"
    ) as actual_crest:
        if ImageChops.difference(actual_crest.convert("RGBA"), expected_crest).getbbox() is not None:
            raise SystemExit(f"{config.title} accepted Crest output differs")
    expected_panels = panel_assets(config.slug, frame_master)
    for panel, expected_panel in expected_panels.items():
        with Image.open(production / f"panel/{config.slug}-{panel}.png") as actual_panel:
            if ImageChops.difference(actual_panel.convert("RGBA"), expected_panel).getbbox() is not None:
                raise SystemExit(f"{config.title} protected Panel output differs: {panel}")
    for slug, (source, _) in accepted_seal_sources.items():
        expected_color, expected_monochrome, expected_thumbnail = render_seal_variants(source)
        for suffix, expected in (
            ("color-master", expected_color),
            ("monochrome-fallback", expected_monochrome),
            ("thumbnail", expected_thumbnail),
        ):
            with Image.open(
                production / f"seal/{config.slug}-{slug}-{suffix}.png"
            ) as actual:
                if ImageChops.difference(actual.convert("RGBA"), expected).getbbox() is not None:
                    raise SystemExit(
                        f"{config.title} accepted Seal output differs: {slug}/{suffix}"
                    )
    qualification_failures = production_qualification_failures(
        provenance,
        resources=resources,
        manifest_records=records,
        theme=config.slug,
        required_seals=config.seals,
        supporting_documents=(
            ("acceptedSourceMasterRecipe", accepted_recipe),
            ("backgroundRecipe", recipe),
        ),
    )
    if qualification_failures:
        raise SystemExit(
            f"{config.title} production qualification blocked: "
            + "; ".join(qualification_failures)
        )
    if provenance.get("pipelineSHA256") != sha256_file(repo_root / PIPELINE):
        raise SystemExit(f"{config.title} pipeline provenance differs")
    return {
        "backgroundRecipeSHA256": sha256_file(recipe_path),
        "integrityManifestSHA256": sha256_file(manifest_path),
        "provenanceSHA256": sha256_file(provenance_path),
        "resourceCount": len(specs),
        "shippingBytes": sum(record["bytes"] for record in records),
        "status": "PASS",
        "theme": config.title,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--authority-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--backgrounds-only", action="store_true")
    parser.add_argument("--accepted-masters-only", action="store_true")
    parser.add_argument("--theme", choices=[config.slug for config in THEMES], action="append")
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()
    authority_root = args.authority_root.resolve()
    selected = [config for config in THEMES if not args.theme or config.slug in args.theme]
    if args.backgrounds_only or args.accepted_masters_only:
        if args.check or (args.backgrounds_only and args.accepted_masters_only):
            raise SystemExit("refresh modes and --check are mutually exclusive")
        refresh = (
            refresh_backgrounds_only
            if args.backgrounds_only
            else refresh_accepted_masters_only
        )
        reports = [refresh(repo_root, authority_root, config) for config in selected]
        print(json.dumps({"reports": reports, "status": "REFRESHED"}, indent=2, sort_keys=True))
        return 0
    if not args.check:
        for config in selected:
            build_theme(repo_root, authority_root, config)
    reports = [check_theme(repo_root, authority_root, config) for config in selected]
    print(json.dumps({"reports": reports, "status": "PASS"}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
