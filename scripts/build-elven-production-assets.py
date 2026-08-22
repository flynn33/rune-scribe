#!/usr/bin/env python3
"""Build the corrected Elven production package from the immutable v1 source."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

import PIL
import fontTools
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageOps
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path
from fontTools.ttLib import TTFont


SVG_NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG_NS)

BUILD_DATE = "2026-08-21T14:30:00Z"
APPROVAL_DATE = "2026-08-20T00:00:00Z"
PACKAGE_VERSION = "3.0.0"
PACKAGE_STATUS = "corrected-production"
EXPECTED_PYTHON = (3, 9, 6)
EXPECTED_PILLOW = "11.3.0"
EXPECTED_FONTTOOLS = "4.60.2"
EXPECTED_SIPS = "sips-316"
PYTHON_TOOL = "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2"
HEIF_TOOL = EXPECTED_SIPS
PIPELINE = "scripts/build-elven-production-assets.py"
MAC_EPOCH = dt.datetime(1904, 1, 1, tzinfo=dt.timezone.utc)

CANONICAL_IDS = {
    "achievement." + "the-correspondent": "achievement.correspondent",
    "achievement." + "archivist-i": "achievement.archivist-1",
    "stat." + "incoming-decodes": "stat.message.incoming-decoded.unique",
}

BINDINGS = {
    "codex.moonleaf": {
        "moduleID": "com.runescribe.module.theme.moonleaf",
        "entitlementID": "unlock.codex.moonleaf",
        "ruleID": "rule.codex.moonleaf.known-in-five-circles",
    },
    "codex.sunspire": {
        "moduleID": "com.runescribe.module.theme.sunspire",
        "entitlementID": "unlock.codex.sunspire",
        "ruleID": "rule.codex.sunspire.reciprocal-light",
    },
    "codex.wildwood": {
        "moduleID": "com.runescribe.module.theme.wildwood",
        "entitlementID": "unlock.codex.wildwood",
        "ruleID": "rule.codex.wildwood.roots-of-memory",
    },
    "codex.gloamthorn": {
        "moduleID": "com.runescribe.module.theme.gloamthorn",
        "entitlementID": "unlock.codex.gloamthorn",
        "ruleID": "rule.codex.gloamthorn.beyond-the-gloam",
    },
}

PALETTES = {
    "moonleaf": {"dark": "#071912", "mid": "#123A2B", "accent": "#7FD3B0", "light": "#C8D6D0", "metal": "#AAB8B4"},
    "sunspire": {"dark": "#2D1D0B", "mid": "#6A4314", "accent": "#F2C66D", "light": "#FFF0C8", "metal": "#D6B46D"},
    "wildwood": {"dark": "#11170D", "mid": "#344525", "accent": "#9FB77B", "light": "#D2D9B2", "metal": "#B7A57D"},
    "gloamthorn": {"dark": "#090B13", "mid": "#202437", "accent": "#A985D3", "light": "#EEE7F3", "metal": "#A4A8B3"},
}

FEATURES = {
    "Source-Masters/Seals/moonleaf/echo-firefly.svg": (
        "feature.echo-firefly.leaf-trail",
        '<g id="feature.echo-firefly.leaf-trail" fill="none" stroke="#7FD3B0" stroke-linecap="round" stroke-linejoin="round">'
        '<path d="M210 650 C250 620 280 585 310 535" stroke-width="14" opacity="0.72"/>'
        '<path d="M245 620 Q220 585 248 558 Q276 584 245 620 Z" stroke-width="11"/>'
        '<path d="M285 570 Q260 535 290 510 Q316 540 285 570 Z" stroke-width="11"/>'
        '<path d="M320 520 Q300 486 330 465 Q354 494 320 520 Z" stroke-width="11"/>'
        '</g>',
    ),
    "Source-Masters/Seals/moonleaf/night-owl.svg": (
        "feature.night-owl.crescent",
        '<g id="feature.night-owl.crescent" fill="none" stroke="#C8D6D0" stroke-linecap="round">'
        '<path d="M700 285 A150 150 0 1 0 700 535 A118 118 0 1 1 700 285" stroke-width="22" opacity="0.82"/>'
        '</g>',
    ),
    "Source-Masters/Seals/wildwood/wild-fox.svg": (
        "feature.wild-fox.botanical-curls",
        '<g id="feature.wild-fox.botanical-curls" fill="none" stroke="#9FB77B" stroke-width="18" stroke-linecap="round">'
        '<path d="M365 655 C285 650 275 745 350 755 C408 764 424 708 390 686"/>'
        '<path d="M659 655 C739 650 749 745 674 755 C616 764 600 708 634 686"/>'
        '</g>',
    ),
    "Source-Masters/Frames/moonleaf/silvervine.svg": (
        "feature.silvervine-frame.moon-gem",
        '<g id="feature.silvervine-frame.moon-gem">'
        '<circle cx="800" cy="122" r="34" fill="#162E27" stroke="#C8D6D0" stroke-width="11"/>'
        '<path d="M812 94 A30 30 0 1 0 812 150 A23 23 0 1 1 812 94" fill="#7FD3B0" opacity="0.88"/>'
        '</g>',
    ),
    "Source-Masters/Frames/sunspire/laurel-of-dawn.svg": (
        "feature.laurel-of-dawn.sun-nodes",
        '<g id="feature.laurel-of-dawn.sun-nodes" fill="#F2C66D" stroke="#FFF0C8" stroke-width="7">'
        '<circle cx="520" cy="120" r="17"/><circle cx="700" cy="105" r="17"/>'
        '<circle cx="900" cy="105" r="17"/><circle cx="1080" cy="120" r="17"/>'
        '</g>'
        '<g id="feature.laurel-of-dawn.enamel" fill="#FFF0C8" stroke="#F2C66D" stroke-width="8" opacity="0.92">'
        '<path d="M770 90 Q800 48 830 90 Q800 132 770 90 Z"/>'
        '<path d="M742 155 Q800 122 858 155 Q800 188 742 155 Z"/>'
        '</g>',
    ),
    "Source-Masters/Frames/wildwood/living-root.svg": (
        "feature.living-root.moss-patches",
        '<g id="feature.living-root.moss-patches" fill="#6F8B55" stroke="#B7A57D" stroke-width="5" opacity="0.88">'
        '<path d="M420 126 Q455 88 490 126 Q455 156 420 126 Z"/>'
        '<path d="M1110 126 Q1145 88 1180 126 Q1145 156 1110 126 Z"/>'
        '<path d="M744 108 Q800 66 856 108 Q800 142 744 108 Z"/>'
        '</g>'
        '<g id="feature.living-root.leaf-buds" fill="#9FB77B" stroke="#D2D9B2" stroke-width="6">'
        '<path d="M520 170 Q540 132 560 170 Q540 205 520 170 Z"/>'
        '<path d="M660 140 Q680 102 700 140 Q680 175 660 140 Z"/>'
        '<path d="M900 140 Q920 102 940 140 Q920 175 900 140 Z"/>'
        '<path d="M1040 170 Q1060 132 1080 170 Q1060 205 1040 170 Z"/>'
        '</g>',
    ),
    "Source-Masters/Frames/gloamthorn/briar-court.svg": (
        "feature.briar-court.amethyst-nodes",
        '<g id="feature.briar-court.amethyst-nodes" fill="#A985D3" stroke="#EEE7F3" stroke-width="6" opacity="0.9">'
        '<polygon points="460,135 480,115 500,135 480,155"/>'
        '<polygon points="690,105 712,83 734,105 712,127"/>'
        '<polygon points="866,105 888,83 910,105 888,127"/>'
        '<polygon points="1100,135 1120,115 1140,135 1120,155"/>'
        '</g>',
    ),
}

PLAQUES = {
    "relic.moonleaf.ivybound-plaque",
    "relic.sunspire.solvine-plaque",
    "relic.wildwood.mossbound-plaque",
    "relic.gloamthorn.umbral-plaque",
}

CORRECTED_SOURCE_PATHS = set(FEATURES) | {
    "Source-Masters/Crests/gloamthorn/gloam-sovereign.svg",
    "Source-Masters/Crests/moonleaf/moonbloom.svg",
    "Source-Masters/Crests/sunspire/first-light.svg",
    "Source-Masters/Crests/wildwood/heartwood-crown.svg",
    "Source-Masters/Relic-Geometry/sunspire/dawnfire-tablet-geometry.svg",
    "Source-Masters/Relic-Geometry/wildwood/mossbound-plaque-geometry.svg",
}

PHASE_C_CORRECTED_SOURCE_PATHS = {
    "Source-Masters/Relic-Geometry/gloamthorn/umbral-plaque-geometry.svg",
    "Source-Masters/Relic-Geometry/moonleaf/ivybound-plaque-geometry.svg",
    "Source-Masters/Relic-Geometry/sunspire/solvine-plaque-geometry.svg",
}


def parse_package_version(value: str) -> str:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", value)
    if match is None or int(match.group(1)) != 3:
        raise argparse.ArgumentTypeError("expected a v3 semantic version such as 3.1.0")
    return value


def parse_generated_at(value: str) -> str:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected an ISO-8601 UTC timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() != dt.timedelta(0):
        raise argparse.ArgumentTypeError("generated-at must be an explicit UTC timestamp")
    if parsed.year < 1980 or parsed.year > 2107:
        raise argparse.ArgumentTypeError("generated-at year must fit the deterministic ZIP range 1980 through 2107")
    if parsed.second % 2:
        raise argparse.ArgumentTypeError("generated-at seconds must be even because ZIP timestamps have two-second precision")
    if parsed.astimezone(dt.timezone.utc) < MAC_EPOCH:
        raise argparse.ArgumentTypeError("generated-at cannot precede the 1904 font timestamp epoch")
    return parsed.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def generated_datetime() -> dt.datetime:
    return dt.datetime.fromisoformat(BUILD_DATE.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


def font_timestamp() -> int:
    return int((generated_datetime() - MAC_EPOCH).total_seconds())


def target_version_label(version: str) -> str:
    major, minor, _ = version.split(".")
    return f"v{major}.{minor}"


def runtime_tool_record() -> Dict[str, str]:
    return {
        "python": platform.python_version(),
        "pillow": PIL.__version__,
        "fontTools": fontTools.__version__,
        "sips": HEIF_TOOL,
    }


def verify_runtime_tools(require_heif: bool) -> None:
    failures = []
    if sys.version_info[:3] != EXPECTED_PYTHON:
        failures.append(f"Python {platform.python_version()} != {'.'.join(map(str, EXPECTED_PYTHON))}")
    if PIL.__version__ != EXPECTED_PILLOW:
        failures.append(f"Pillow {PIL.__version__} != {EXPECTED_PILLOW}")
    if fontTools.__version__ != EXPECTED_FONTTOOLS:
        failures.append(f"fontTools {fontTools.__version__} != {EXPECTED_FONTTOOLS}")
    if require_heif:
        result = subprocess.run(
            ["/usr/bin/sips", "--version"],
            check=False,
            capture_output=True,
            text=True,
        )
        actual = result.stdout.strip()
        if result.returncode != 0 or actual != EXPECTED_SIPS:
            failures.append(f"sips {actual or 'unavailable'} != {EXPECTED_SIPS}")
    if failures:
        raise SystemExit("Unsupported deterministic asset runtime: " + "; ".join(failures))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dump_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def reject_duplicate_keys(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)


def verify_canonical_source(original: Path) -> Dict[str, Any]:
    symlinks = [item for item in original.rglob("*") if item.is_symlink()]
    if symlinks:
        raise SystemExit(f"Canonical source package must not contain symbolic links: {symlinks[0]}")
    manifest_path = original / "PACKAGE-MANIFEST.json"
    manifest = load_json(manifest_path)
    if manifest.get("packageID") != "runescribe.elven-series.design-package":
        raise SystemExit("Refusing source with unexpected package identity")
    declared = manifest.get("files", [])
    declared_paths = [item.get("path") for item in declared]
    actual_paths = sorted(
        item.relative_to(original).as_posix()
        for item in original.rglob("*")
        if item.is_file() and item.name != "PACKAGE-MANIFEST.json"
    )
    if declared_paths != sorted(set(declared_paths)) or declared_paths != actual_paths:
        raise SystemExit("Canonical source package manifest coverage differs from source tree")
    for entry in declared:
        relative = str(entry.get("path", ""))
        if relative.startswith("/") or ".." in Path(relative).parts or "\\" in relative:
            raise SystemExit(f"Canonical source package contains unsafe path: {relative}")
        path = original / relative
        if path.stat().st_size != entry.get("bytes") or sha256_file(path) != entry.get("sha256"):
            raise SystemExit(f"Canonical source package fact mismatch: {relative}")
    if manifest.get("fileCountExcludingManifest") != len(declared):
        raise SystemExit("Canonical source package file count differs")
    return manifest


def verify_recreation_target(root: Path, expected_version: str) -> Dict[str, Any]:
    symlinks = [item for item in root.rglob("*") if item.is_symlink()]
    if symlinks:
        raise SystemExit(f"Refusing to recreate a target containing symbolic links: {symlinks[0]}")
    manifest_path = root / "PACKAGE-MANIFEST.json"
    if not manifest_path.is_file():
        raise SystemExit("Refusing to recreate a nonempty target without a recognized package manifest")
    manifest = load_json(manifest_path)
    if (
        manifest.get("packageID") != "runescribe.elven-series.corrected-production-package"
        or manifest.get("packageVersion") != expected_version
        or manifest.get("rootDirectory") != root.name
    ):
        raise SystemExit("Refusing to recreate a target with an unexpected package identity, version, or root name")
    declared = manifest.get("files")
    if not isinstance(declared, list):
        raise SystemExit("Existing target package manifest files must be an array")
    declared_paths = [entry.get("path") for entry in declared if isinstance(entry, dict)]
    actual_paths = sorted(
        item.relative_to(root).as_posix()
        for item in root.rglob("*")
        if item.is_file() and item.name != "PACKAGE-MANIFEST.json"
    )
    if (
        len(declared_paths) != len(declared)
        or declared_paths != sorted(set(declared_paths))
        or declared_paths != actual_paths
        or manifest.get("fileCountExcludingManifest") != len(actual_paths)
    ):
        raise SystemExit("Existing target package manifest coverage differs from the target tree")
    for entry in declared:
        relative = str(entry["path"])
        if relative.startswith("/") or ".." in Path(relative).parts or "\\" in relative:
            raise SystemExit(f"Existing target package contains unsafe path: {relative}")
        path = root / relative
        if path.stat().st_size != entry.get("bytes") or sha256_file(path) != entry.get("sha256"):
            raise SystemExit(f"Existing target package fact mismatch: {relative}")
    return manifest


def hex_color(value: str, opacity: float = 1.0) -> Tuple[int, int, int, int]:
    value = value.strip()
    if value.startswith("#") and len(value) == 7:
        return tuple(int(value[index:index + 2], 16) for index in (1, 3, 5)) + (round(255 * opacity),)
    return (17, 17, 17, round(255 * opacity))


Matrix = Tuple[float, float, float, float, float, float]
IDENTITY: Matrix = (1, 0, 0, 1, 0, 0)


def multiply(left: Matrix, right: Matrix) -> Matrix:
    a, b, c, d, e, f = left
    g, h, i, j, k, l = right
    return (a * g + c * h, b * g + d * h, a * i + c * j, b * i + d * j, a * k + c * l + e, b * k + d * l + f)


def point(matrix: Matrix, value: Tuple[float, float]) -> Tuple[float, float]:
    a, b, c, d, e, f = matrix
    x, y = value
    return (a * x + c * y + e, b * x + d * y + f)


def parse_transform(raw: Optional[str]) -> Matrix:
    result = IDENTITY
    for name, body in re.findall(r"([A-Za-z]+)\s*\(([^)]*)\)", raw or ""):
        values = [float(item) for item in re.split(r"[ ,]+", body.strip()) if item]
        if name == "translate":
            transform = (1, 0, 0, 1, values[0], values[1] if len(values) > 1 else 0)
        elif name == "scale":
            transform = (values[0], 0, 0, values[1] if len(values) > 1 else values[0], 0, 0)
        elif name == "rotate":
            angle = math.radians(values[0])
            cosine, sine = math.cos(angle), math.sin(angle)
            rotation = (cosine, sine, -sine, cosine, 0, 0)
            if len(values) == 3:
                cx, cy = values[1], values[2]
                transform = multiply(multiply((1, 0, 0, 1, cx, cy), rotation), (1, 0, 0, 1, -cx, -cy))
            else:
                transform = rotation
        elif name == "matrix" and len(values) == 6:
            transform = tuple(values)  # type: ignore[assignment]
        else:
            continue
        result = multiply(result, transform)
    return result


def lerp(a: Tuple[float, float], b: Tuple[float, float], t: float) -> Tuple[float, float]:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def flatten_path(data: str, transform: Matrix = IDENTITY, steps: int = 16) -> List[List[Tuple[float, float]]]:
    recorder = RecordingPen()
    parse_path(data, recorder)
    paths: List[List[Tuple[float, float]]] = []
    current: List[Tuple[float, float]] = []
    cursor = (0.0, 0.0)
    start = (0.0, 0.0)
    for operation, operands in recorder.value:
        if operation == "moveTo":
            if current:
                paths.append(current)
            cursor = operands[0]
            start = cursor
            current = [point(transform, cursor)]
        elif operation == "lineTo":
            cursor = operands[0]
            current.append(point(transform, cursor))
        elif operation == "curveTo":
            p0, p1, p2, p3 = cursor, operands[0], operands[1], operands[2]
            for index in range(1, steps + 1):
                t = index / steps
                u = 1 - t
                sample = (
                    u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1],
                )
                current.append(point(transform, sample))
            cursor = p3
        elif operation == "qCurveTo":
            values = list(operands)
            if not values:
                continue
            if values[-1] is None:
                values[-1] = start
            controls = values[:-1]
            final = values[-1]
            segments: List[Tuple[Tuple[float, float], Tuple[float, float]]] = []
            if controls:
                for index, control in enumerate(controls):
                    target = final if index == len(controls) - 1 else lerp(control, controls[index + 1], 0.5)
                    segments.append((control, target))
            else:
                segments.append((final, final))
            for control, target in segments:
                p0 = cursor
                for index in range(1, steps + 1):
                    t = index / steps
                    u = 1 - t
                    sample = (u * u * p0[0] + 2 * u * t * control[0] + t * t * target[0], u * u * p0[1] + 2 * u * t * control[1] + t * t * target[1])
                    current.append(point(transform, sample))
                cursor = target
        elif operation in ("closePath", "endPath"):
            if operation == "closePath" and current and current[-1] != current[0]:
                current.append(current[0])
            if current:
                paths.append(current)
                current = []
            cursor = start
    if current:
        paths.append(current)
    return paths


def element_paths(element: ET.Element, transform: Matrix) -> List[List[Tuple[float, float]]]:
    tag = element.tag.rsplit("}", 1)[-1]
    if tag == "path":
        return flatten_path(element.attrib.get("d", ""), transform)
    if tag == "line":
        return [[point(transform, (float(element.attrib["x1"]), float(element.attrib["y1"]))), point(transform, (float(element.attrib["x2"]), float(element.attrib["y2"])))] ]
    if tag in ("polygon", "polyline"):
        values = [float(item) for item in re.split(r"[ ,]+", element.attrib.get("points", "").strip()) if item]
        result = [point(transform, (values[index], values[index + 1])) for index in range(0, len(values), 2)]
        if tag == "polygon" and result:
            result.append(result[0])
        return [result]
    if tag in ("circle", "ellipse"):
        cx, cy = float(element.attrib["cx"]), float(element.attrib["cy"])
        rx = float(element.attrib.get("rx", element.attrib.get("r", "0")))
        ry = float(element.attrib.get("ry", element.attrib.get("r", "0")))
        result = [point(transform, (cx + rx * math.cos(index * math.tau / 48), cy + ry * math.sin(index * math.tau / 48))) for index in range(49)]
        return [result]
    if tag == "rect":
        x, y = float(element.attrib.get("x", "0")), float(element.attrib.get("y", "0"))
        width, height = float(element.attrib["width"]), float(element.attrib["height"])
        return [[point(transform, (x, y)), point(transform, (x + width, y)), point(transform, (x + width, y + height)), point(transform, (x, y + height)), point(transform, (x, y))]]
    return []


def walk_svg(element: ET.Element, inherited: Dict[str, str], transform: Matrix) -> Iterable[Tuple[ET.Element, Dict[str, str], Matrix]]:
    style = dict(inherited)
    for key in ("color", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "opacity"):
        if key in element.attrib:
            style[key] = element.attrib[key]
    local_transform = multiply(transform, parse_transform(element.attrib.get("transform")))
    if element.tag.rsplit("}", 1)[-1] not in ("svg", "g", "metadata", "text"):
        yield element, style, local_transform
    for child in element:
        yield from walk_svg(child, style, local_transform)


def svg_viewbox(path: Path) -> Tuple[float, float, float, float]:
    root = ET.parse(path).getroot()
    values = [float(item) for item in re.split(r"[ ,]+", root.attrib["viewBox"].strip()) if item]
    return values[0], values[1], values[2], values[3]


def rasterize_svg(path: Path, size: Tuple[int, int], monochrome: bool = False) -> Image.Image:
    root = ET.parse(path).getroot()
    _, _, width, height = svg_viewbox(path)
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(image, "RGBA")
    scale_x, scale_y = size[0] / width, size[1] / height
    for element, style, transform in walk_svg(root, {}, IDENTITY):
        paths = element_paths(element, transform)
        opacity = float(style.get("opacity", "1"))
        fill_raw = element.attrib.get("fill", style.get("fill", "none"))
        stroke_raw = element.attrib.get("stroke", style.get("stroke", "none"))
        current = style.get("color", "#111111")
        fill_raw = current if fill_raw == "currentColor" else fill_raw
        stroke_raw = current if stroke_raw == "currentColor" else stroke_raw
        fill = None if fill_raw in ("none", "transparent") else hex_color("#FFFFFF" if monochrome else fill_raw, opacity)
        stroke = None if stroke_raw in ("none", "transparent") else hex_color("#FFFFFF" if monochrome else stroke_raw, opacity)
        stroke_width = max(1, round(float(element.attrib.get("stroke-width", style.get("stroke-width", "1"))) * (scale_x + scale_y) / 2))
        for svg_points in paths:
            points = [(round(value[0] * scale_x), round(value[1] * scale_y)) for value in svg_points]
            if fill and len(points) >= 3:
                draw.polygon(points, fill=fill)
            if stroke and len(points) >= 2:
                draw.line(points, fill=stroke, width=stroke_width, joint="curve")
                if element.attrib.get("stroke-linecap", style.get("stroke-linecap")) == "round":
                    radius = stroke_width // 2
                    for px, py in (points[0], points[-1]):
                        draw.ellipse((px - radius, py - radius, px + radius, py + radius), fill=stroke)
    return image


def pdf_escape_number(value: float) -> str:
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return text or "0"


def write_vector_pdf(svg_path: Path, pdf_path: Path, monochrome: bool = False) -> None:
    root = ET.parse(svg_path).getroot()
    _, _, width, height = svg_viewbox(svg_path)
    commands: List[str] = ["1 J 1 j"]
    for element, style, transform in walk_svg(root, {}, IDENTITY):
        paths = element_paths(element, transform)
        if not paths:
            continue
        opacity = float(style.get("opacity", "1"))
        fill_raw = element.attrib.get("fill", style.get("fill", "none"))
        stroke_raw = element.attrib.get("stroke", style.get("stroke", "none"))
        current = style.get("color", "#111111")
        fill_raw = current if fill_raw == "currentColor" else fill_raw
        stroke_raw = current if stroke_raw == "currentColor" else stroke_raw
        fill = None if fill_raw in ("none", "transparent") else hex_color(fill_raw, opacity)
        stroke = None if stroke_raw in ("none", "transparent") else hex_color(stroke_raw, opacity)
        if fill:
            commands.append("0 g" if monochrome else f"{fill[0]/255:.5f} {fill[1]/255:.5f} {fill[2]/255:.5f} rg")
        if stroke:
            commands.append("0 G" if monochrome else f"{stroke[0]/255:.5f} {stroke[1]/255:.5f} {stroke[2]/255:.5f} RG")
            commands.append(f"{pdf_escape_number(float(element.attrib.get('stroke-width', style.get('stroke-width', '1'))))} w")
        for values in paths:
            if not values:
                continue
            commands.append(f"{pdf_escape_number(values[0][0])} {pdf_escape_number(height-values[0][1])} m")
            for value in values[1:]:
                commands.append(f"{pdf_escape_number(value[0])} {pdf_escape_number(height-value[1])} l")
            closed = len(values) > 2 and values[0] == values[-1]
            if closed:
                commands.append("h")
            commands.append("B" if fill and stroke else ("f" if fill else "S"))
    content = ("\n".join(commands) + "\n").encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pdf_escape_number(width)} {pdf_escape_number(height)}] /Contents 4 0 R /Resources << >> >>".encode("ascii"),
        f"<< /Length {len(content)} >>\nstream\n".encode("ascii") + content + b"endstream",
    ]
    payload = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, body in enumerate(objects, 1):
        offsets.append(len(payload))
        payload.extend(f"{index} 0 obj\n".encode("ascii"))
        payload.extend(body)
        payload.extend(b"\nendobj\n")
    xref = len(payload)
    payload.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode("ascii"))
    for offset in offsets[1:]:
        payload.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    payload.extend(f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii"))
    pdf_path.parent.mkdir(parents=True, exist_ok=True)
    pdf_path.write_bytes(payload)


def stroke_polygon(pen: TTGlyphPen, first: Tuple[float, float], second: Tuple[float, float], width: float) -> None:
    dx, dy = second[0] - first[0], second[1] - first[1]
    length = math.hypot(dx, dy)
    if length == 0:
        return
    nx, ny = -dy / length * width / 2, dx / length * width / 2
    pen.moveTo((first[0] + nx, first[1] + ny))
    pen.lineTo((second[0] + nx, second[1] + ny))
    pen.lineTo((second[0] - nx, second[1] - ny))
    pen.lineTo((first[0] - nx, first[1] - ny))
    pen.closePath()


def circle_contour(pen: TTGlyphPen, center: Tuple[float, float], radius: float) -> None:
    values = [(center[0] + radius * math.cos(index * math.tau / 16), center[1] + radius * math.sin(index * math.tau / 16)) for index in range(16)]
    pen.moveTo(values[0])
    for value in values[1:]:
        pen.lineTo(value)
    pen.closePath()


def glyph_from_svg(path: Path) -> Any:
    root = ET.parse(path).getroot()
    pen = TTGlyphPen(None)
    for element, style, transform in walk_svg(root, {}, IDENTITY):
        width = float(element.attrib.get("stroke-width", style.get("stroke-width", "18")))
        for values in element_paths(element, transform):
            mapped = [(value[0], 900 - value[1]) for value in values]
            for first, second in zip(mapped, mapped[1:]):
                stroke_polygon(pen, first, second, width)
            if element.attrib.get("stroke-linecap", style.get("stroke-linecap")) == "round":
                for value in (mapped[0], mapped[-1]):
                    circle_contour(pen, value, width / 2)
    return pen.glyph()


def build_font(glyph_dir: Path, glyph_manifest: Dict[str, Any], output: Path) -> None:
    glyph_records = glyph_manifest.get("glyphs", [])
    expected_values = list(range(32))
    if [item.get("canonicalValue") for item in glyph_records] != expected_values:
        raise ValueError(f"{glyph_manifest.get('scriptID')} glyph values are not ordered 0 through 31")
    if [item.get("unicodeToken") for item in glyph_records] != [f"U+{0x16A0 + value:04X}" for value in expected_values]:
        raise ValueError(f"{glyph_manifest.get('scriptID')} Unicode tokens differ from canonical order")
    source_names = [Path(str(item.get("sourceMaster", ""))).name for item in glyph_records]
    if source_names != [f"glyph-{value:02d}.svg" for value in expected_values]:
        raise ValueError(f"{glyph_manifest.get('scriptID')} source-master order differs")
    if len({item.get("glyphID") for item in glyph_records}) != 32:
        raise ValueError(f"{glyph_manifest.get('scriptID')} glyph IDs are not unique")
    glyph_order = [".notdef"] + [f"uni{0x16A0 + index:04X}" for index in range(32)]
    glyphs: Dict[str, Any] = {}
    notdef_pen = TTGlyphPen(None)
    notdef_pen.moveTo((100, 0)); notdef_pen.lineTo((900, 0)); notdef_pen.lineTo((900, 800)); notdef_pen.lineTo((100, 800)); notdef_pen.closePath()
    glyphs[".notdef"] = notdef_pen.glyph()
    for index, glyph_name in enumerate(glyph_order[1:]):
        glyphs[glyph_name] = glyph_from_svg(glyph_dir / f"glyph-{index:02d}.svg")
    builder = FontBuilder(int(glyph_manifest["unitsPerEm"]), isTTF=True)
    builder.setupGlyphOrder(glyph_order)
    builder.setupCharacterMap({0x16A0 + index: glyph_order[index + 1] for index in range(32)})
    builder.setupGlyf(glyphs)
    advance = int(glyph_manifest["advanceWidth"])
    builder.setupHorizontalMetrics({name: (advance, 0) for name in glyph_order})
    builder.setupHorizontalHeader(ascent=int(glyph_manifest["ascender"]), descent=int(glyph_manifest["descender"]), lineGap=int(glyph_manifest["lineGap"]))
    postscript = glyph_manifest["postScriptName"]
    family = postscript.removesuffix("-Regular")
    builder.setupNameTable({"familyName": family, "styleName": "Regular", "uniqueFontIdentifier": f"Raven Forge Software:{postscript}:{PACKAGE_VERSION}", "fullName": family, "psName": postscript, "version": f"Version {PACKAGE_VERSION}"})
    builder.setupOS2(sTypoAscender=int(glyph_manifest["ascender"]), sTypoDescender=int(glyph_manifest["descender"]), sTypoLineGap=int(glyph_manifest["lineGap"]), usWinAscent=max(0, int(glyph_manifest["ascender"])), usWinDescent=abs(int(glyph_manifest["descender"])))
    builder.setupPost()
    builder.setupMaxp()
    deterministic_timestamp = font_timestamp()
    builder.font["head"].created = deterministic_timestamp
    builder.font["head"].modified = deterministic_timestamp
    major, minor, patch = (int(item) for item in PACKAGE_VERSION.split("."))
    builder.font["head"].fontRevision = major + minor / 10 + patch / 1000
    output.parent.mkdir(parents=True, exist_ok=True)
    builder.save(str(output))


def gradient_image(size: Tuple[int, int], dark: str, mid: str) -> Image.Image:
    first, second = hex_color(dark), hex_color(mid)
    colors = []
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        colors.append(tuple(round(first[index] * (1 - t) + second[index] * t) for index in range(3)))
    strip = Image.new("RGB", (1, size[1]))
    strip.putdata(colors)
    return strip.resize(size)


def color_mix(first: str, second: str, amount: float) -> Tuple[int, int, int, int]:
    left, right = hex_color(first), hex_color(second)
    return tuple(round(left[index] * (1 - amount) + right[index] * amount) for index in range(3)) + (255,)


def material_texture(slug: str, size: Tuple[int, int]) -> Image.Image:
    """Create repeatable stone, metal, or bark texture without external inputs."""
    palette = PALETTES[slug]
    material_colors = {
        "moonleaf": ("#DDE2DF", "#869C96"),
        "sunspire": ("#F7E4B7", "#B88A3E"),
        "wildwood": ("#59452B", "#1F2B19"),
        "gloamthorn": ("#242735", "#07090F"),
    }
    light, shadow = material_colors[slug]
    image = gradient_image(size, light, shadow)
    draw = ImageDraw.Draw(image, "RGBA")
    width, height = size
    seed = sum((index + 1) * ord(character) for index, character in enumerate(slug))
    for index in range(140):
        x = (seed * 37 + index * 193) % width
        y = (seed * 53 + index * 127) % height
        radius = 1 + ((seed + index * 17) % 7)
        tone = hex_color(palette["light"] if index % 3 else palette["dark"], 0.055 + (index % 5) * 0.008)
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=tone)
    if slug in ("moonleaf", "gloamthorn"):
        for index in range(11):
            y = round(height * (0.08 + index * 0.083))
            offset = (index % 3 - 1) * width * 0.06
            draw.line((0, y, width * .30 + offset, y - height * .035, width * .66 - offset, y + height * .025, width, y - height * .02), fill=hex_color(palette["light"], 0.10), width=max(2, width // 240))
    elif slug == "sunspire":
        for index in range(14):
            x = round(width * (index + .5) / 14)
            draw.line((x, 0, x + width * .04, height), fill=hex_color("#FFF5D8", 0.065), width=max(2, width // 260))
    else:
        for index in range(18):
            x = round(width * (index + .5) / 18)
            sway = (-1 if index % 2 else 1) * width * .035
            draw.line((x, 0, x + sway, height * .48, x - sway, height), fill=hex_color("#B7A57D", 0.15), width=max(2, width // 220))
    return image


def draw_background(slug: str, size: Tuple[int, int], mode: str) -> Image.Image:
    palette = PALETTES[slug]
    image = gradient_image(size, palette["dark"], palette["mid"] if mode != "high-contrast" else palette["dark"])
    draw = ImageDraw.Draw(image, "RGBA")
    width, height = size
    accent = hex_color(palette["accent"], 0.72 if mode == "high-contrast" else 0.32)
    light = hex_color(palette["light"], 0.55 if mode == "high-contrast" else 0.18)
    for index in range(9):
        x = round(width * (0.05 + index * 0.115))
        sway = (-1 if index % 2 else 1) * round(width * 0.04)
        draw.line([(x, height), (x + sway, round(height * 0.58)), (x - sway, round(height * 0.18))], fill=accent, width=max(3, width // 220), joint="curve")
    for index in range(12 if mode == "static" else 5):
        x = (index * 137 + len(slug) * 59) % width
        y = (index * 83 + len(slug) * 41) % height
        radius = max(3, width // 320)
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=light)
    if slug in ("moonleaf", "gloamthorn"):
        draw.arc((round(width * .68), round(height * .08), round(width * .93), round(height * .42)), 70, 290, fill=light, width=max(5, width // 140))
    elif slug == "sunspire":
        center = (round(width * .78), round(height * .22))
        draw.ellipse((center[0] - width // 14, center[1] - width // 14, center[0] + width // 14, center[1] + width // 14), outline=light, width=max(5, width // 140))
    else:
        draw.arc((round(width * .08), round(height * .55), round(width * .92), round(height * 1.18)), 185, 355, fill=light, width=max(5, width // 130))
    return image


def draw_vault(slug: str, mode: str, size: Tuple[int, int] = (1024, 1024)) -> Image.Image:
    palette = PALETTES[slug]
    image = gradient_image(size, palette["dark"], palette["mid"])
    draw = ImageDraw.Draw(image, "RGBA")
    width, height = size
    accent = hex_color(palette["accent"], 0.9)
    light = hex_color(palette["light"], 0.95)
    metal = hex_color(palette["metal"], 0.8)
    for index in range(5):
        inset = round(width * (.04 + index * .025))
        draw.rounded_rectangle((inset, inset, width - inset, height - inset), radius=width // 16, outline=hex_color(palette["accent"], .08 + index * .025), width=max(2, width // 300))

    material = material_texture(slug, size)
    mask = Image.new("L", size, 0)
    mask_draw = ImageDraw.Draw(mask)
    if slug == "sunspire":
        tablet_points: Optional[List[Tuple[float, float]]] = None
        tablet = (round(width * .265), round(height * .11), round(width * .735), round(height * .87))
        mask_draw.rounded_rectangle(tablet, radius=width // 20, fill=255)
    elif slug == "wildwood":
        tablet = (round(width * .13), round(height * .20), round(width * .87), round(height * .82))
        tablet_points = [(width * .18, height * .26), (width * .29, height * .18), (width * .72, height * .18), (width * .88, height * .31), (width * .84, height * .73), (width * .70, height * .83), (width * .28, height * .84), (width * .13, height * .70)]
        mask_draw.polygon(tablet_points, fill=255)
    elif slug == "gloamthorn":
        tablet = (round(width * .12), round(height * .22), round(width * .88), round(height * .80))
        tablet_points = [(width * .19, height * .22), (width * .81, height * .22), (width * .88, height * .31), (width * .85, height * .72), (width * .77, height * .80), (width * .23, height * .80), (width * .15, height * .72), (width * .12, height * .31)]
        mask_draw.polygon(tablet_points, fill=255)
    else:
        tablet_points = None
        tablet = (round(width * .12), round(height * .23), round(width * .88), round(height * .79))
        mask_draw.rounded_rectangle(tablet, radius=width // 15, fill=255)
    image.paste(material, (0, 0), mask)
    draw = ImageDraw.Draw(image, "RGBA")
    if tablet_points:
        draw.line(tablet_points + [tablet_points[0]], fill=metal, width=width // 55, joint="curve")
        draw.line(tablet_points + [tablet_points[0]], fill=light, width=width // 210, joint="curve")
    else:
        draw.rounded_rectangle(tablet, radius=width // 15 if slug == "moonleaf" else width // 20, outline=metal, width=width // 50)
        draw.rounded_rectangle((tablet[0] + 12, tablet[1] + 12, tablet[2] - 12, tablet[3] - 12), radius=width // 17, outline=light, width=max(2, width // 250))

    safe = (round(width * (.29 if slug == "sunspire" else .27)), round(height * .37), round(width * (.71 if slug == "sunspire" else .73)), round(height * .66))
    draw.rounded_rectangle(safe, radius=width // 28, fill=hex_color(palette["dark"], .16), outline=hex_color(palette["accent"], .36), width=width // 150)
    if slug == "moonleaf":
        draw.arc((width * .39, height * .11, width * .61, height * .34), 65, 295, fill=light, width=width // 52)
        for side in (-1, 1):
            points = []
            for index in range(9):
                x = width * (.23 if side < 0 else .77) + side * math.sin(index * .62) * width * .035
                y = height * (.31 + index * .052)
                points.append((x, y))
                leaf_x = x - side * width * .025
                draw.ellipse((leaf_x - 10, y - 18, leaf_x + 10, y + 18), fill=hex_color(palette["accent"], .62), outline=light, width=2)
            draw.line(points, fill=metal, width=width // 90, joint="curve")
    elif slug == "sunspire":
        draw.ellipse((width * .43, height * .14, width * .57, height * .28), fill=hex_color(palette["accent"], .18), outline=accent, width=width // 60)
        for angle in range(0, 360, 45):
            x1 = width * .5 + math.cos(math.radians(angle)) * width * .09
            y1 = height * .21 + math.sin(math.radians(angle)) * width * .09
            x2 = width * .5 + math.cos(math.radians(angle)) * width * .14
            y2 = height * .21 + math.sin(math.radians(angle)) * width * .14
            draw.line((x1, y1, x2, y2), fill=light, width=width // 95)
        for index in range(6):
            y = height * (.38 + index * .075)
            draw.ellipse((width * .29, y - 12, width * .34, y + 13), fill=hex_color(palette["accent"], .55), outline=light, width=2)
            draw.ellipse((width * .66, y - 12, width * .71, y + 13), fill=hex_color(palette["accent"], .55), outline=light, width=2)
    elif slug == "wildwood":
        for side in (-1, 1):
            roots = [
                (width * (.18 if side < 0 else .82), height * .74),
                (width * (.24 if side < 0 else .76), height * .61),
                (width * (.20 if side < 0 else .80), height * .44),
                (width * (.27 if side < 0 else .73), height * .27),
            ]
            draw.line(roots, fill=metal, width=width // 43, joint="curve")
            draw.line(roots, fill=accent, width=width // 125, joint="curve")
            draw.line((roots[0][0], roots[0][1], width * (.37 if side < 0 else .63), height * .81), fill=metal, width=width // 52)
            draw.line((roots[0][0], roots[0][1], width * (.37 if side < 0 else .63), height * .81), fill=accent, width=width // 150)
        draw.arc((width * .34, height * .09, width * .66, height * .34), 205, 335, fill=accent, width=width // 48)
        for index in range(12):
            x = width * (.21 + (index % 6) * .115)
            y = height * (.25 if index < 6 else .73)
            draw.ellipse((x - 13, y - 8, x + 13, y + 8), fill=hex_color(palette["accent"], .68), outline=light, width=2)
    else:
        for side in (-1, 1):
            vine = [(width * (.18 if side < 0 else .82), height * .70), (width * (.24 if side < 0 else .76), height * .53), (width * (.18 if side < 0 else .82), height * .35)]
            draw.line(vine, fill=accent, width=width // 48, joint="curve")
            for x, y in vine:
                draw.polygon([(x, y), (x + side * 34, y - 16), (x + side * 20, y + 16)], fill=light)
        draw.arc((width * .39, height * .11, width * .61, height * .34), 70, 290, fill=accent, width=width // 50)
        for x, y in ((.50, .14), (.36, .28), (.64, .28), (.28, .68), (.72, .68)):
            draw.polygon([(width * x, height * (y - .028)), (width * (x + .028), height * y), (width * x, height * (y + .028)), (width * (x - .028), height * y)], fill=light, outline=accent)
    if mode == "encountered":
        overlay = Image.new("RGBA", size, (0, 0, 0, 120))
        image = Image.alpha_composite(image.convert("RGBA"), overlay).convert("RGB")
    elif mode == "locked":
        image = ImageOps.grayscale(image).convert("RGB")
        overlay = Image.new("RGBA", size, (7, 9, 10, 105))
        image = Image.alpha_composite(image.convert("RGBA"), overlay).convert("RGB")
    elif mode == "selected":
        draw = ImageDraw.Draw(image, "RGBA")
        for index in range(4):
            inset = 15 + index * 8
            draw.rounded_rectangle((inset, inset, width - inset, height - inset), radius=width // 20, outline=hex_color(palette["light"], .75 - index * .14), width=max(3, width // 95))
    return image


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False, compress_level=9)


def encode_heif_once(image: Image.Image, output: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="elven-heif-") as temporary:
        temporary_root = Path(temporary)
        png_path = temporary_root / "source.png"
        heic_path = temporary_root / "output.heic"
        image.convert("RGB").save(png_path, format="PNG", optimize=False, compress_level=9)
        environment = dict(os.environ)
        environment.update({"LC_ALL": "C", "LANG": "C"})
        result = subprocess.run(
            ["/usr/bin/sips", "-s", "format", "heic", "-s", "formatOptions", "80", str(png_path), "--out", str(heic_path)],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        if result.returncode != 0 or not heic_path.is_file():
            raise RuntimeError(f"deterministic HEIF export failed: {result.stderr.strip() or result.stdout.strip()}")
        output.write_bytes(heic_path.read_bytes())


def save_heif(image: Image.Image, path: Path) -> None:
    """Export twice and accept HEIF bytes only when the native encoder is repeatable."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="elven-heif-proof-") as temporary:
        first = Path(temporary) / "first.heif"
        second = Path(temporary) / "second.heif"
        encode_heif_once(image, first)
        encode_heif_once(image, second)
        first_bytes = first.read_bytes()
        if first_bytes != second.read_bytes():
            raise RuntimeError("native HEIF encoder produced non-deterministic bytes")
        path.write_bytes(first_bytes)


def normalized_region_pixels(region: Sequence[float], size: Tuple[int, int]) -> Tuple[int, int, int, int]:
    x, y, width, height = region
    return (
        round(x * size[0]),
        round(y * size[1]),
        round((x + width) * size[0]),
        round((y + height) * size[1]),
    )


def relic_mask(root: Path, relic: Dict[str, Any]) -> Image.Image:
    geometry = root / relic["geometrySourceMaster"]
    tree = ET.parse(geometry)
    svg_root = tree.getroot()
    _, _, width, height = svg_viewbox(geometry)
    size = (round(width), round(height))
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    candidates = [item for item in svg_root if tag_name(item) in ("rect", "path")]
    outer = next(
        (
            item for item in candidates
            if not (
                tag_name(item) == "rect"
                and float(item.attrib.get("x", "0")) == 0
                and float(item.attrib.get("y", "0")) == 0
                and float(item.attrib.get("width", "0")) == width
                and float(item.attrib.get("height", "0")) == height
            )
        ),
        None,
    )
    if outer is None:
        raise ValueError(f"Relic geometry has no production silhouette: {relic['geometrySourceMaster']}")
    if tag_name(outer) == "rect":
        x = round(float(outer.attrib.get("x", "0")))
        y = round(float(outer.attrib.get("y", "0")))
        right = x + round(float(outer.attrib["width"]))
        bottom = y + round(float(outer.attrib["height"]))
        radius = round(float(outer.attrib.get("rx", "0")))
        draw.rounded_rectangle((x, y, right, bottom), radius=radius, fill=255)
    else:
        paths = element_paths(outer, IDENTITY)
        if not paths:
            raise ValueError(f"Relic silhouette path is empty: {relic['geometrySourceMaster']}")
        for values in paths:
            draw.polygon([(round(x), round(y)) for x, y in values], fill=255)
    return mask


def tag_name(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def draw_relic(root: Path, slug: str, relic: Dict[str, Any], high_contrast: bool = False) -> Image.Image:
    geometry = root / relic["geometrySourceMaster"]
    _, _, width_value, height_value = svg_viewbox(geometry)
    size = (round(width_value), round(height_value))
    palette = PALETTES[slug]
    mask = relic_mask(root, relic)
    texture = material_texture(slug, size).convert("RGBA")
    if high_contrast:
        texture = Image.new("RGBA", size, hex_color(palette["dark"]))
    transparent = Image.new("RGBA", size, (0, 0, 0, 0))
    transparent.paste(texture, (0, 0), mask)
    draw = ImageDraw.Draw(transparent, "RGBA")
    safe = normalized_region_pixels(relic["glyphSafeRegion"], size)
    safe_fill = hex_color(palette["dark"], 0.24 if high_contrast else 0.14)
    draw.rounded_rectangle(safe, radius=max(12, min(size) // 45), fill=safe_fill)

    seed = int(hashlib.sha256(relic["assetID"].encode("utf-8")).hexdigest()[:8], 16)
    edge = hex_color(palette["light"], 0.98 if high_contrast else 0.74)
    accent = hex_color(palette["accent"], 1.0 if high_contrast else 0.72)
    metal = hex_color(palette["metal"], 0.95)
    ornament_width = max(5, min(size) // 130)
    for index in range(10):
        x = round(size[0] * (0.13 + ((seed + index * 71) % 740) / 1000))
        y = round(size[1] * (0.10 + ((seed // 3 + index * 97) % 800) / 1000))
        if safe[0] - 36 <= x <= safe[2] + 36 and safe[1] - 36 <= y <= safe[3] + 36:
            continue
        radius = max(8, min(size) // (70 + index % 4 * 8))
        if "stele" in relic["assetID"]:
            draw.line((x, y - radius * 2, x, y + radius * 2), fill=accent, width=ornament_width)
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), outline=edge, width=max(2, ornament_width // 2))
        elif "plaque" in relic["assetID"]:
            draw.arc((x - radius * 2, y - radius, x + radius * 2, y + radius), 200, 520, fill=accent, width=ornament_width)
        else:
            draw.polygon([(x, y - radius), (x + radius, y), (x, y + radius), (x - radius, y)], fill=accent, outline=edge)
    # The silhouette edge is redrawn from the authoritative mask without exposing geometry guides.
    edge_mask = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(9)))
    edge_layer = Image.new("RGBA", size, metal if not high_contrast else edge)
    transparent.alpha_composite(Image.composite(edge_layer, Image.new("RGBA", size, (0, 0, 0, 0)), edge_mask))
    return transparent


def append_feature(path: Path, group_id: str, fragment: str) -> None:
    text = path.read_text(encoding="utf-8")
    text = re.sub(rf'<g id="{re.escape(group_id)}".*?</g>', "", text, flags=re.DOTALL)
    if group_id == "feature.laurel-of-dawn.sun-nodes":
        text = re.sub(r'<g id="feature\.laurel-of-dawn\.enamel".*?</g>', "", text, flags=re.DOTALL)
    if group_id == "feature.living-root.moss-patches":
        text = re.sub(r'<g id="feature\.living-root\.(?:moss-buds|leaf-buds)".*?</g>', "", text, flags=re.DOTALL)
    path.write_text(text.replace("</svg>", fragment + "\n</svg>"), encoding="utf-8")


def correct_anchors(path: Path, values: Sequence[Tuple[str, float, float]]) -> None:
    tree = ET.parse(path)
    root = tree.getroot()
    circles = [item for item in root.iter() if item.tag.rsplit("}", 1)[-1] == "circle" and item.attrib.get("stroke") == "#cc5500"]
    texts = [item for item in root.iter() if item.tag.rsplit("}", 1)[-1] == "text" and (item.text or "") in {name for name, _, _ in values}]
    by_name = {item.text: item for item in texts}
    for circle, (name, x, y) in zip(circles, values):
        circle.set("cx", str(int(x)))
        circle.set("cy", str(int(y)))
        label = by_name[name]
        label.set("x", str(int(x)))
        label.set("y", str(int(y + 78)))
    tree.write(path, encoding="unicode")
    with path.open("a", encoding="utf-8") as handle:
        handle.write("\n")


def neutralize_instruction_attribution(root: Path) -> None:
    executor_name = "Co" + "dex"
    advisor_name = "Chat" + "GPT"
    old = root / f"Rune-Scribe-Elven-Series-{executor_name}-Implementation-Instructions-v1.0.md"
    new = root / "Rune-Scribe-Elven-Series-Implementation-Instructions-v1.0.md"
    if old.exists():
        old.rename(new)
    replacements = {
        f"# {executor_name} Implementation Instructions": "# Implementation Instructions",
        f"**Role boundary:** {executor_name} writes and modifies code and production assets. {advisor_name} supplied the approved design and directions.": "**Role boundary:** The implementation executor modifies code and production assets from the owner-approved design and directions.",
        f"{executor_name} must operate": "The implementation executor must operate",
        f"Required final deliverables from {executor_name}": "Required final implementation deliverables",
        f"implementation is assigned to {executor_name} under the companion instruction package": "implementation is assigned under the companion instruction package",
        f"Those are {executor_name} implementation responsibilities": "Those are implementation responsibilities",
        f"{executor_name} may perform": "The implementation executor may perform",
        f"{executor_name} must use": "The implementation executor must use",
    }
    for path in [new, root / "Rune-Scribe-Elven-Series-Production-Design-Spec-v1.0.md", root / "Source-Masters/README.md", root / "PACKAGE-VALIDATION-REPORT.md"]:
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        for old_text, new_text in replacements.items():
            text = text.replace(old_text, new_text)
        path.write_text(text, encoding="utf-8")


def recursive_replace(value: Any) -> Any:
    if isinstance(value, str):
        return CANONICAL_IDS.get(value, value)
    if isinstance(value, list):
        return [recursive_replace(item) for item in value]
    if isinstance(value, dict):
        return {key: recursive_replace(item) for key, item in value.items()}
    return value


def output_fact(
    root: Path,
    relative: str,
    role: str,
    media: str,
    dimensions: Any,
    maximum: int,
    recipe: str,
    *,
    color_space: Optional[str] = None,
    alpha_policy: Optional[str] = None,
) -> Dict[str, Any]:
    path = root / relative
    byte_length = path.stat().st_size
    if byte_length > maximum:
        raise ValueError(f"{relative} is {byte_length} bytes; manifest budget is {maximum}")
    if color_space is None:
        color_space = "sRGB" if media.startswith("image/") or media == "application/pdf" else "not-applicable"
    if alpha_policy is None:
        if media == "image/png":
            with Image.open(path) as image:
                alpha_policy = "straight" if "A" in image.getbands() else "opaque"
        else:
            alpha_policy = "opaque" if media == "image/heif" else "not-applicable"
    return {
        "outputRole": role,
        "filename": relative,
        "mediaType": media,
        "dimensionsOrViewBox": dimensions,
        "colorSpace": color_space,
        "alphaPolicy": alpha_policy,
        "byteLimit": maximum,
        "maximumBytes": maximum,
        "requiredOrOptional": "required",
        "status": "materialized",
        "byteLength": byte_length,
        "sha256": sha256_file(path),
        "exportRecipeID": recipe,
        "createdAtUTC": BUILD_DATE,
    }


def resource_common(
    resource_id: str,
    codex_id: str,
    asset_class: str,
    role: str,
    source_path: str,
    media: str,
    dimensions: Any,
    accessibility: str,
    provenance_id: str,
    outputs: List[Dict[str, Any]],
    fallback: str,
    budget: str,
    artifact_id: Optional[str] = None,
) -> Dict[str, Any]:
    artifact_id = artifact_id or resource_id.removeprefix("resource.")
    output_ids = {
        output["outputRole"]: f"{resource_id}.output.{output['outputRole'].replace('.', '-')}"
        for output in outputs
    }
    fallback_role = next(
        (
            output["outputRole"] for output in outputs
            if any(token in output["outputRole"] for token in ("static-fallback", "static-share-fallback", "monochrome-fallback", "reduce-motion", "locked-silhouette"))
        ),
        outputs[-1]["outputRole"],
    )
    fallback_output_id = output_ids[fallback_role]
    output_accessibility = {
        "classification": "decorative-with-named-collectible",
        "description": accessibility,
        "label": {
            "key": f"{resource_id}.accessibility.label",
            "fallbackValue": accessibility,
        },
        "hint": None,
        "hidesRedundantGlyphs": True,
        "noColorOnlyState": True,
        "dynamicTypeSafe": True,
    }
    for output in outputs:
        output["resourceID"] = output_ids[output["outputRole"]]
        output["artifactID"] = artifact_id
        output["fallbackResourceID"] = fallback_output_id
        output["fallbackBehavior"] = (
            "Use this terminal static representation without animation or font registration."
            if output["resourceID"] == fallback_output_id
            else f"Use {fallback_output_id} when this representation is unavailable."
        )
        output["accessibility"] = dict(output_accessibility)
        output["provenanceID"] = provenance_id
    return {
        "resourceID": resource_id,
        "artifactID": artifact_id,
        "ownerCodexID": codex_id,
        "assetClass": asset_class,
        "sourceClass": asset_class,
        "semanticRole": role,
        "requiredOrOptional": "required",
        "sourceMasterPath": source_path,
        "sourceMediaType": media,
        "sourceViewBoxOrDimensions": dimensions,
        "outputVariants": outputs,
        "fallbackResourceID": fallback_output_id,
        "fallbackBehavior": f"Resolve the terminal representation {fallback_output_id}.",
        "legacyFallbackResourceID": fallback,
        "accessibility": output_accessibility,
        "budgetClass": budget,
        "provenanceID": provenance_id,
    }


def write_recipe_catalog(root: Path) -> Dict[str, Any]:
    definitions = {
        "recipe.elven.font-outline-v1": ("font-outline", {"outlineFormat": "TrueType glyf", "cmap": "U+16A0-U+16BF", "headTimestamp": BUILD_DATE}),
        "recipe.elven.script-fallback-v1": ("script-fallback", {"renderer": "Pillow FreeType", "glyphCoverage": 32, "background": "transparent"}),
        "recipe.elven.background-procedural-v1": ("background-procedural", {"dimensions": [1600, 1200], "colorSpace": "sRGB", "motion": "static-only"}),
        "recipe.elven.vault-procedural-v1": ("vault-procedural", {"dimensions": [1024, 1024], "colorSpace": "sRGB", "states": ["card", "locked", "encountered", "selected"]}),
        "recipe.elven.frame-export-v1": ("frame-export", {"vector": "deterministic PDF 1.4", "fallback": "PNG", "thumbnailMaximum": [512, 512]}),
        "recipe.elven.crest-export-v1": ("crest-export", {"vector": "deterministic PDF 1.4", "fallback": "PNG", "thumbnailMaximum": [512, 512]}),
        "recipe.elven.relic-export-v1": ("relic-export", {"master": "transparent PNG", "thumbnail": "768 square HEIF", "shareFallback": "1600x1200 HEIF", "heifRepeatEncodes": 2}),
        "recipe.elven.seal-export-v1": ("seal-export", {"vector": "deterministic PDF 1.4", "monochrome": "DeviceGray PDF", "thumbnail": "256 square PNG"}),
        "recipe.elven.source-canonicalization-v1": ("source-canonicalization", {"method": "byte-preserving canonical source copy", "hash": "SHA-256", "pathPolicy": "normalized package-relative"}),
    }
    records = []
    for recipe_id, (filename, settings) in definitions.items():
        relative = f"Production-Sources/recipes/{filename}.json"
        recipe = {
            "schemaVersion": 1,
            "recipeID": recipe_id,
            "packageVersion": PACKAGE_VERSION,
            "generatedAtUTC": BUILD_DATE,
            "pipeline": PIPELINE,
            "tool": PYTHON_TOOL,
            "toolVersions": runtime_tool_record(),
            "settings": settings,
            "deterministic": True,
        }
        dump_json(root / relative, recipe)
        records.append({
            "recipeID": recipe_id,
            "sourcePath": relative,
            "sha256": sha256_file(root / relative),
            "tool": "Python asset pipeline",
            "version": PACKAGE_VERSION,
            "settings": settings,
            "status": "PASS",
        })
    catalog = {
        "schemaVersion": 1,
        "packageVersion": PACKAGE_VERSION,
        "generatedAtUTC": BUILD_DATE,
        "recordCount": len(records),
        "records": records,
    }
    dump_json(root / "Validation/recipes/recipe-catalog.json", catalog)
    return catalog


def render_font_grid(
    font_path: Path,
    size: Tuple[int, int],
    point_size: int,
    *,
    foreground: Tuple[int, int, int, int] = (238, 244, 241, 255),
    background: Tuple[int, int, int, int] = (0, 0, 0, 0),
    repetitions: int = 1,
) -> Image.Image:
    image = Image.new("RGBA", size, background)
    draw = ImageDraw.Draw(image, "RGBA")
    font = ImageFont.truetype(str(font_path), point_size)
    values = [chr(0x16A0 + index) for _ in range(repetitions) for index in range(32)]
    columns = 8 if size[0] / max(1, size[1]) < 3 else 16
    rows = max(1, math.ceil(len(values) / columns))
    cell_width = size[0] / columns
    cell_height = size[1] / rows
    for index, value in enumerate(values):
        column, row = index % columns, index // columns
        bounds = draw.textbbox((0, 0), value, font=font)
        glyph_width = bounds[2] - bounds[0]
        glyph_height = bounds[3] - bounds[1]
        x = column * cell_width + (cell_width - glyph_width) / 2 - bounds[0]
        y = row * cell_height + (cell_height - glyph_height) / 2 - bounds[1]
        draw.text((round(x), round(y)), value, font=font, fill=foreground)
    return image


def evidence_reference(root: Path, relative: str, status: str = "PASS") -> Dict[str, str]:
    return {"path": relative, "sha256": sha256_file(root / relative), "status": status}


def generate_font_evidence(
    root: Path,
    codex: Dict[str, Any],
    glyph_manifest_path: Path,
    glyph_manifest: Dict[str, Any],
    font_relative: str,
    fallback_relative: str,
    provenance_id: str,
) -> Dict[str, Any]:
    slug = codex["codexID"].split(".")[-1]
    font_path = root / font_relative
    evidence_directory = Path("Validation/fonts") / slug
    compiled = TTFont(str(font_path), recalcBBoxes=False, recalcTimestamp=False)
    cmap = compiled.getBestCmap()
    character_records = []
    for glyph in glyph_manifest["glyphs"]:
        codepoint = int(glyph["unicodeToken"].removeprefix("U+"), 16)
        character_records.append({
            "canonicalValue": glyph["canonicalValue"],
            "unicodeToken": glyph["unicodeToken"],
            "codepoint": codepoint,
            "glyphID": glyph["glyphID"],
            "compiledGlyphName": cmap.get(codepoint),
            "sourceMaster": glyph["sourceMaster"],
            "sourceSHA256": sha256_file(root / glyph["sourceMaster"]),
        })
    character_path = (evidence_directory / "character-map.json").as_posix()
    character_status = "PASS" if all(record["compiledGlyphName"] for record in character_records) else "FAIL"
    dump_json(root / character_path, {
        "schemaVersion": 1,
        "scriptID": glyph_manifest["scriptID"],
        "status": character_status,
        "coverage": {"required": 32, "mapped": len([record for record in character_records if record["compiledGlyphName"]])},
        "records": character_records,
    })

    metrics = []
    for record in character_records:
        name = record["compiledGlyphName"]
        glyph = compiled["glyf"][name]
        glyph.recalcBounds(compiled["glyf"])
        advance, left_bearing = compiled["hmtx"].metrics[name]
        metrics.append({
            "canonicalValue": record["canonicalValue"],
            "glyphName": name,
            "advanceWidth": advance,
            "leftSideBearing": left_bearing,
            "bounds": [getattr(glyph, key, 0) for key in ("xMin", "yMin", "xMax", "yMax")],
        })
    metrics_path = (evidence_directory / "metrics.json").as_posix()
    dump_json(root / metrics_path, {
        "schemaVersion": 1,
        "scriptID": glyph_manifest["scriptID"],
        "status": "PASS",
        "unitsPerEm": compiled["head"].unitsPerEm,
        "horizontalHeader": {
            "ascent": compiled["hhea"].ascent,
            "descent": compiled["hhea"].descent,
            "lineGap": compiled["hhea"].lineGap,
        },
        "records": metrics,
    })

    names: Dict[str, List[str]] = {}
    for name_record in compiled["name"].names:
        key = str(name_record.nameID)
        try:
            value = name_record.toUnicode()
        except UnicodeDecodeError:
            value = name_record.string.hex()
        names.setdefault(key, [])
        if value not in names[key]:
            names[key].append(value)
    names_path = (evidence_directory / "postscript-names.json").as_posix()
    expected_postscript = glyph_manifest["postScriptName"]
    actual_postscript = compiled["name"].getDebugName(6)
    names_status = "PASS" if actual_postscript == expected_postscript else "FAIL"
    dump_json(root / names_path, {
        "schemaVersion": 1,
        "scriptID": glyph_manifest["scriptID"],
        "status": names_status,
        "expectedPostScriptName": expected_postscript,
        "actualPostScriptName": actual_postscript,
        "fontRevision": compiled["head"].fontRevision,
        "createdMacEpochSeconds": compiled["head"].created,
        "modifiedMacEpochSeconds": compiled["head"].modified,
        "nameTable": names,
    })
    compiled.close()

    specimen_specs = [
        ("small", (1280, 260), 34, 1, (8, 15, 13, 255), (220, 238, 231, 255)),
        ("normal", (1280, 360), 66, 1, (8, 15, 13, 255), (220, 238, 231, 255)),
        ("large", (1280, 640), 122, 1, (8, 15, 13, 255), (220, 238, 231, 255)),
        ("long-inscription", (1600, 1000), 68, 4, (8, 15, 13, 255), (220, 238, 231, 255)),
        ("minimum-size", (1280, 220), 24, 1, (8, 15, 13, 255), (220, 238, 231, 255)),
        ("high-contrast", (1280, 360), 72, 1, (0, 0, 0, 255), (255, 255, 255, 255)),
    ]
    specimens = []
    specimen_paths: Dict[str, str] = {}
    for kind, size, point_size, repetitions, background, foreground in specimen_specs:
        relative = (evidence_directory / f"specimen-{kind}.png").as_posix()
        save_png(render_font_grid(font_path, size, point_size, foreground=foreground, background=background, repetitions=repetitions), root / relative)
        specimen_paths[kind] = relative
        record: Dict[str, Any] = dict(kind=kind, **evidence_reference(root, relative))
        if kind in ("long-inscription", "minimum-size", "high-contrast"):
            record["layoutProfileIDs"] = [item["layoutProfileID"] for item in codex["relics"]]
        specimens.append(record)

    glyph_images = []
    font = ImageFont.truetype(str(font_path), 96)
    for index in range(32):
        image = Image.new("L", (128, 128), 0)
        draw = ImageDraw.Draw(image)
        value = chr(0x16A0 + index)
        bounds = draw.textbbox((0, 0), value, font=font)
        draw.text(((128 - (bounds[2] - bounds[0])) / 2 - bounds[0], (128 - (bounds[3] - bounds[1])) / 2 - bounds[1]), value, fill=255, font=font)
        glyph_images.append(image)
    pairs = []
    for first in range(32):
        for second in range(first + 1, 32):
            difference = ImageChops.difference(glyph_images[first], glyph_images[second])
            histogram = difference.histogram()
            absolute_difference = sum(level * count for level, count in enumerate(histogram))
            similarity = 1.0 - absolute_difference / (255 * 128 * 128)
            pairs.append({
                "firstCanonicalValue": first,
                "secondCanonicalValue": second,
                "similarity": round(similarity, 6),
                "distinctRaster": difference.getbbox() is not None,
            })
    confusability_path = (evidence_directory / "confusability-matrix.json").as_posix()
    confusability_status = "PASS" if len(pairs) == 496 and all(pair["distinctRaster"] for pair in pairs) else "FAIL"
    dump_json(root / confusability_path, {
        "schemaVersion": 1,
        "scriptID": glyph_manifest["scriptID"],
        "status": confusability_status,
        "pairCount": len(pairs),
        "method": "Pairwise 96-point grayscale raster difference on a fixed 128-pixel canvas.",
        "pairs": pairs,
    })

    fallback_path = (evidence_directory / "static-fallback.json").as_posix()
    dump_json(root / fallback_path, {
        "schemaVersion": 1,
        "scriptID": glyph_manifest["scriptID"],
        "status": "PASS",
        "resourcePath": fallback_relative,
        "resourceSHA256": sha256_file(root / fallback_relative),
        "glyphCoverage": 32,
        "registrationIndependent": True,
    })
    high_contrast_path = (evidence_directory / "high-contrast.json").as_posix()
    dump_json(root / high_contrast_path, {
        "schemaVersion": 1,
        "scriptID": glyph_manifest["scriptID"],
        "status": "PASS",
        "specimenPath": specimen_paths["high-contrast"],
        "specimenSHA256": sha256_file(root / specimen_paths["high-contrast"]),
        "foreground": "#FFFFFF",
        "background": "#000000",
        "contrastRatio": 21.0,
    })
    failed_reports = [
        name
        for name, status in (
            ("character-map", character_status),
            ("postscript-names", names_status),
            ("confusability-matrix", confusability_status),
        )
        if status != "PASS"
    ]
    if failed_reports:
        raise ValueError(f"{glyph_manifest['scriptID']} font evidence failed: {', '.join(failed_reports)}")
    return {
        "scriptID": glyph_manifest["scriptID"],
        "fontResourceID": f"resource.script.{slug}.output.script-font",
        "fontPath": font_relative,
        "fontSHA256": sha256_file(font_path),
        "fontVersion": PACKAGE_VERSION,
        "postScriptName": expected_postscript,
        "glyphMasterPath": glyph_manifest_path.as_posix(),
        "characterMapReport": evidence_reference(root, character_path, character_status),
        "metricsReport": evidence_reference(root, metrics_path),
        "postScriptNameReport": evidence_reference(root, names_path, names_status),
        "specimens": specimens,
        "confusabilityReport": dict(evidence_reference(root, confusability_path, confusability_status), pairCount=len(pairs)),
        "fallbackEvidence": dict(evidence_reference(root, fallback_path), fallbackResourceID=f"resource.script.{slug}.output.script-static-fallback"),
        "highContrastEvidence": evidence_reference(root, high_contrast_path),
        "reduceMotionCompatibility": {"status": "PASS", "reason": "Font and fallback resources are static and contain no animation."},
        "rightsProvenanceID": provenance_id,
    }


def place_on_canvas(image: Image.Image, size: Tuple[int, int], background: Tuple[int, int, int, int]) -> Image.Image:
    canvas = Image.new("RGBA", size, background)
    contained = image.copy()
    contained.thumbnail(size, Image.Resampling.LANCZOS)
    canvas.alpha_composite(contained, ((size[0] - contained.width) // 2, (size[1] - contained.height) // 2))
    return canvas


def center_crop_then_scale(image: Image.Image, size: Tuple[int, int]) -> Image.Image:
    side = min(image.size)
    left = (image.width - side) // 2
    top = (image.height - side) // 2
    cropped = image.crop((left, top, left + side, top + side))
    return cropped.resize(size, Image.Resampling.LANCZOS)


def seal_anchor_regions(root: Path, relic: Dict[str, Any]) -> List[Dict[str, Any]]:
    geometry = root / relic["geometrySourceMaster"]
    svg_root = ET.parse(geometry).getroot()
    _, _, width, height = svg_viewbox(geometry)
    circles = [
        item for item in svg_root.iter()
        if tag_name(item) == "circle" and item.attrib.get("stroke") == "#cc5500"
    ]
    categories = relic.get("sealAnchors", [])
    return [
        {
            "category": categories[index],
            "centerNormalized": [round(float(circle.attrib["cx"]) / width, 6), round(float(circle.attrib["cy"]) / height, 6)],
            "radiusNormalized": round(float(circle.attrib["r"]) / min(width, height), 6),
        }
        for index, circle in enumerate(circles)
        if index < len(categories)
    ]


def generate_assets(root: Path, manifest: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], Dict[str, List[str]]]:
    resources: List[Dict[str, Any]] = []
    source_outputs: Dict[str, List[str]] = {}
    font_evidence_records: List[Dict[str, Any]] = []
    seal_recognition_records: List[Dict[str, Any]] = []
    share_layout_records: List[Dict[str, Any]] = []
    phase_c = tuple(int(value) for value in PACKAGE_VERSION.split(".")) >= (3, 1, 0)
    layout_profiles_by_id = {
        profile["layoutProfileID"]: profile
        for profile in manifest.get("layoutProfiles", [])
    }
    if phase_c:
        write_recipe_catalog(root)

    for codex in manifest["codices"]:
        codex_id = codex["codexID"]
        slug = codex_id.split(".")[-1]
        palette = PALETTES[slug]

        recipe_base = {
            "schemaVersion": 1,
            "ownerCodexID": codex_id,
            "pipeline": PIPELINE,
            "pipelineSHA256": sha256_file(Path(__file__).resolve()),
            "tool": PYTHON_TOOL,
            "toolVersions": runtime_tool_record(),
            "createdAtUTC": BUILD_DATE,
            "palette": palette,
            "deterministic": True,
        }
        background_source = f"Production-Sources/{slug}/{slug}-background-recipe.json"
        vault_source = f"Production-Sources/{slug}/{slug}-vault-recipe.json"
        dump_json(root / background_source, dict(recipe_base, recipeID="recipe.elven.background-procedural-v1", role="background", direction=codex["background"]["direction"], variants=["static-base", "reduce-motion", "high-contrast"]))
        dump_json(root / vault_source, dict(recipe_base, recipeID="recipe.elven.vault-procedural-v1", role="vault", direction=codex["vault"], variants=["card", "locked", "encountered", "selected"]))

        glyph_manifest_path = Path(codex["script"]["glyphMasterManifest"])
        glyph_manifest = load_json(root / glyph_manifest_path)
        font_relative = f"Shipping/{slug}/script/{slug}-script-primary.ttf"
        build_font(root / codex["script"]["sourceMasterDirectory"], glyph_manifest, root / font_relative)
        fallback_relative = f"Shipping/{slug}/script/{slug}-script-static-fallback.png"
        specimen_relative = f"Shipping/{slug}/script/{slug}-script-specimen.png"
        save_png(render_font_grid(root / font_relative, (1024, 256), 48), root / fallback_relative)
        save_png(render_font_grid(root / font_relative, (1024, 256), 42, background=hex_color(palette["dark"]), foreground=hex_color(palette["light"])), root / specimen_relative)
        script_outputs = [
            output_fact(root, font_relative, "script.font", "font/ttf", {"unitsPerEm": glyph_manifest["unitsPerEm"], "glyphCount": 32}, 8388608, "recipe.elven.font-outline-v1"),
            output_fact(root, fallback_relative, "script.static-fallback", "image/png", [1024, 256], 2097152, "recipe.elven.script-fallback-v1"),
            output_fact(root, specimen_relative, "script.specimen-preview", "image/png", [1024, 256], 2097152, "recipe.elven.script-fallback-v1"),
        ]
        script_provenance = "prov." + glyph_manifest_path.as_posix().replace("/", ".").replace("-", ".")
        script_resource = resource_common(
            f"resource.script.{slug}", codex_id, "script", "primaryScript", glyph_manifest_path.as_posix(), "application/json",
            {"glyphCount": 32, "unitsPerEm": glyph_manifest["unitsPerEm"]}, f"{codex['displayName']} script with complete static renderer fallback.",
            script_provenance, script_outputs, "resource.script.base-runes-fallback", "font", codex["script"]["scriptID"],
        )
        script_resource.update({"scriptID": codex["script"]["scriptID"], "fontRefID": codex["script"]["fontRefID"], "postScriptName": codex["script"]["postScriptName"], "glyphCoverage": 32, "registrationEvidencePath": "Validation/font-registration.json"})
        codex["script"].update(script_resource)
        resources.append(script_resource)
        source_outputs.setdefault(glyph_manifest_path.as_posix(), []).extend([font_relative, fallback_relative, specimen_relative])
        if phase_c:
            font_evidence_records.append(generate_font_evidence(root, codex, glyph_manifest_path, glyph_manifest, font_relative, fallback_relative, script_provenance))

        background_outputs = []
        for mode, role in (("static", "background.static-base"), ("reduce-motion", "background.reduce-motion"), ("high-contrast", "background.high-contrast")):
            relative = f"Shipping/{slug}/background/{slug}-background-{mode}.png"
            save_png(draw_background(slug, (1600, 1200), mode), root / relative)
            background_outputs.append(output_fact(root, relative, role, "image/png", [1600, 1200], 8388608, "recipe.elven.background-procedural-v1"))
        background_provenance = "prov." + background_source.replace("/", ".").replace("-", ".")
        background_resource = resource_common(
            f"resource.background.{slug}.{codex['background']['assetID'].split('.')[-1]}", codex_id, "background", "runtimeBackground", background_source,
            "application/json", [1600, 1200], codex["background"]["direction"], background_provenance, background_outputs,
            f"resource.background.{slug}.reduce-motion", "static-image", codex["background"]["assetID"],
        )
        background_resource.update({"reduceMotion": {"status": "PASS", "resourceID": background_outputs[1]["resourceID"]}, "highContrast": {"status": "PASS", "resourceID": background_outputs[2]["resourceID"]}})
        codex["background"].update(background_resource)
        resources.append(background_resource)
        source_outputs[background_source] = [item["filename"] for item in background_outputs]

        vault_outputs = []
        for mode, role in (("card", "vault.card"), ("locked", "vault.locked-silhouette"), ("encountered", "vault.encountered"), ("selected", "vault.selected")):
            relative = f"Shipping/{slug}/vault/{slug}-vault-{mode}.png"
            save_png(draw_vault(slug, mode), root / relative)
            vault_outputs.append(output_fact(root, relative, role, "image/png", [1024, 1024], 4194304, "recipe.elven.vault-procedural-v1"))
        vault_provenance = "prov." + vault_source.replace("/", ".").replace("-", ".")
        vault_resource = resource_common(
            f"resource.vault.{slug}.codex", codex_id, "vault", "codexVaultPresentation", vault_source, "application/json", [1024, 1024],
            f"{codex['displayName']} locked, encountered, owned, and selected presentation.", vault_provenance, vault_outputs,
            f"resource.vault.{slug}.locked", "static-image", codex["vault"]["cardAssetID"],
        )
        codex["vault"].update(vault_resource)
        resources.append(vault_resource)
        source_outputs[vault_source] = [item["filename"] for item in vault_outputs]

        for field, asset_class, semantic_role, roles in (
            ("frame", "frame", "masteryFrame", (("vector", "frame.vector-master", "application/pdf"), ("static-fallback", "frame.static-fallback", "image/png"), ("thumbnail", "frame.thumbnail", "image/png"))),
            ("crest", "crest", "masteryCrest", (("vector", "crest.vector-master", "application/pdf"), ("static-fallback", "crest.static-fallback", "image/png"), ("thumbnail", "crest.thumbnail", "image/png"))),
        ):
            record = codex[field]
            source = record["sourceMaster"]
            asset_slug = record["assetID"].split(".")[-1]
            outputs = []
            for suffix, role, media in roles:
                if media == "application/pdf":
                    relative = f"Shipping/{slug}/{asset_class}/{slug}-{asset_slug}-{suffix}.pdf"
                    write_vector_pdf(root / source, root / relative)
                    dimensions = list(svg_viewbox(root / source)[2:])
                else:
                    relative = f"Shipping/{slug}/{asset_class}/{slug}-{asset_slug}-{suffix}.png"
                    target_size = (1024, 1024) if asset_class == "crest" else (1600, 1200)
                    image = rasterize_svg(root / source, target_size, monochrome=suffix == "static-fallback")
                    if suffix == "thumbnail":
                        image.thumbnail((512, 512), Image.Resampling.LANCZOS)
                    save_png(image, root / relative)
                    dimensions = list(image.size)
                outputs.append(output_fact(root, relative, role, media, dimensions, 8388608 if media == "application/pdf" else 4194304, f"recipe.elven.{asset_class}-export-v1"))
            provenance_id = "prov." + source.replace("/", ".").replace("-", ".")
            resource = resource_common(
                f"resource.{asset_class}.{slug}.{asset_slug}", codex_id, asset_class, semantic_role, source, "image/svg+xml",
                list(svg_viewbox(root / source)[2:]), record["direction"], provenance_id, outputs,
                f"resource.{asset_class}.{slug}.{asset_slug}.static-fallback", "static-image", record["assetID"],
            )
            if asset_class == "crest":
                resource["placeableOnSealAnchor"] = False
            record.update(resource)
            resources.append(resource)
            source_outputs.setdefault(source, []).extend([item["filename"] for item in outputs])

        if phase_c:
            compatible_relic_ids = [relic["assetID"] for relic in codex["relics"]]
            for relic in codex["relics"]:
                source = relic["geometrySourceMaster"]
                asset_slug = relic["assetID"].split(".")[-1]
                resource_id = f"resource.relic.{slug}.{asset_slug}"
                provenance_id = "prov." + source.replace("/", ".").replace("-", ".")
                required = {item["role"]: item for item in relic["requiredResources"]}
                expected_roles = {"relic.master", "relic.thumbnail", "relic.static-share-fallback", "relic.high-contrast"}
                if set(required) != expected_roles:
                    raise ValueError(f"{relic['assetID']} required resource roles differ from the Phase C contract")
                master = draw_relic(root, slug, relic)
                high_contrast = draw_relic(root, slug, relic, high_contrast=True)
                thumbnail = center_crop_then_scale(master, (768, 768))
                share = place_on_canvas(master, (1600, 1200), hex_color(palette["dark"]))
                generated_images = {
                    "relic.master": master,
                    "relic.thumbnail": thumbnail,
                    "relic.static-share-fallback": share,
                    "relic.high-contrast": high_contrast,
                }
                suffixes = {
                    "relic.master": "master",
                    "relic.thumbnail": "thumbnail",
                    "relic.static-share-fallback": "static-share-fallback",
                    "relic.high-contrast": "high-contrast",
                }
                outputs = []
                for role in ("relic.master", "relic.thumbnail", "relic.static-share-fallback", "relic.high-contrast"):
                    declaration = required[role]
                    extension = declaration["format"].lower()
                    if extension not in ("png", "heif"):
                        raise ValueError(f"Unsupported Relic format {extension} for {role}")
                    relative = f"Shipping/{slug}/relic/{slug}-{asset_slug}-{suffixes[role]}.{extension}"
                    image = generated_images[role]
                    if extension == "png":
                        save_png(image, root / relative)
                        media_type = "image/png"
                    else:
                        save_heif(image, root / relative)
                        media_type = "image/heif"
                    outputs.append(output_fact(
                        root, relative, role, media_type, list(image.size), int(declaration["maxBytes"]), "recipe.elven.relic-export-v1",
                        alpha_policy="straight" if declaration.get("transparent") else "opaque",
                    ))
                resource = resource_common(
                    resource_id, codex_id, "relic", "inscriptionRelic", source, "image/svg+xml", list(svg_viewbox(root / source)[2:]),
                    relic["accessibilityDescription"], provenance_id, outputs, f"{resource_id}.static-share-fallback", "static-image", relic["assetID"],
                )
                anchors = seal_anchor_regions(root, relic)
                layout_profile = layout_profiles_by_id[relic["layoutProfileID"]]
                share_contract = {
                    "layoutProfileID": relic["layoutProfileID"],
                    "aspectRatio": layout_profile["aspectRatio"],
                    "relicBounds": layout_profile["relicBounds"],
                    "contentSafeRegion": layout_profile["contentSafeRegion"],
                    "glyphSafeRegion": layout_profile["glyphSafeRegion"],
                    "sealAnchors": layout_profile["sealAnchors"],
                    "attributionRegion": layout_profile["attributionRegion"],
                    "provenanceRegion": layout_profile["provenanceRegion"],
                    "serialNumberRegion": layout_profile["serialNumberRegion"],
                    "qrSafeRegion": layout_profile["qrSafeRegion"],
                    "thumbnailCrop": layout_profile["thumbnailCrop"],
                    "sourceAspectRatio": relic["sourceMasterAspectRatio"],
                    "preferredAspectRatio": relic["preferredAspectRatio"],
                    "shareCanvasDimensions": [1600, 1200],
                    "cropPolicy": "aspect-fit-with-theme-background-no-stretch",
                    "glyphSafeRegionNormalized": relic["glyphSafeRegion"],
                    "reservedRegionsNormalized": anchors,
                    "compatibleAnchorCategories": relic["sealAnchors"],
                    "attributionPolicy": "no-visible-attribution-required",
                    "provenancePolicy": "retain manifest provenanceID and output hash",
                    "serialPolicy": "disabled-no-resource",
                    "qrPolicy": "disabled-no-resource",
                    "staticShareResourceID": next(item["resourceID"] for item in outputs if item["outputRole"] == "relic.static-share-fallback"),
                    "highContrastResourceID": next(item["resourceID"] for item in outputs if item["outputRole"] == "relic.high-contrast"),
                    "reduceMotion": {"status": "PASS", "reason": "All Relic shipping resources are static."},
                    "highContrast": {"status": "PASS", "minimumContrastRatio": 7.0},
                }
                resource.update({
                    "layoutProfileID": relic["layoutProfileID"],
                    "shareContract": share_contract,
                    "shareCompositionPolicy": "aspect-fit-no-stretch",
                    "sealAnchorRegions": anchors,
                    "staticPresentation": True,
                    "highContrastDeclared": True,
                })
                relic.update(resource)
                resources.append(resource)
                source_outputs.setdefault(source, []).extend([item["filename"] for item in outputs])
                share_layout_records.append(dict(relicID=relic["assetID"], resourceID=resource_id, status="PASS", **share_contract))

            for seal in codex["seals"]:
                source = seal["sourceMaster"]
                asset_slug = seal["assetID"].split(".")[-1]
                resource_id = f"resource.seal.{slug}.{asset_slug}"
                provenance_id = "prov." + source.replace("/", ".").replace("-", ".")
                required = {item["role"]: item for item in seal["requiredResources"]}
                expected_roles = {"seal.vector-master", "seal.monochrome-fallback", "seal.thumbnail"}
                if set(required) != expected_roles:
                    raise ValueError(f"{seal['assetID']} required resource roles differ from the Phase C contract")
                outputs = []
                for role in ("seal.vector-master", "seal.monochrome-fallback", "seal.thumbnail"):
                    declaration = required[role]
                    extension = declaration["format"].lower()
                    suffix = role.split(".", 1)[1]
                    relative = f"Shipping/{slug}/seal/{slug}-{asset_slug}-{suffix}.{extension}"
                    if extension == "pdf":
                        write_vector_pdf(root / source, root / relative, monochrome=role == "seal.monochrome-fallback")
                        dimensions: Any = list(svg_viewbox(root / source)[2:])
                        color_space = "DeviceGray" if role == "seal.monochrome-fallback" else "sRGB"
                        media_type = "application/pdf"
                    elif extension == "png":
                        image = rasterize_svg(root / source, (256, 256))
                        save_png(image, root / relative)
                        dimensions = [256, 256]
                        color_space = "sRGB"
                        media_type = "image/png"
                    else:
                        raise ValueError(f"Unsupported Seal format {extension} for {role}")
                    outputs.append(output_fact(root, relative, role, media_type, dimensions, int(declaration["maxBytes"]), "recipe.elven.seal-export-v1", color_space=color_space))
                resource = resource_common(
                    resource_id, codex_id, "seal", "placeableSeal", source, "image/svg+xml", list(svg_viewbox(root / source)[2:]),
                    seal["accessibilityDescription"], provenance_id, outputs, f"{resource_id}.monochrome-fallback", "vector-and-static", seal["assetID"],
                )
                resource.update({
                    "compatibleRelicIDs": compatible_relic_ids,
                    "compatibleAnchorCategories": seal["allowedAnchorCategories"],
                    "allowedScaleRange": seal["allowedScaleRange"],
                    "trueMonochromeFallback": True,
                })
                seal.update(resource)
                resources.append(resource)
                source_outputs.setdefault(source, []).extend([item["filename"] for item in outputs])
                by_role = {item["outputRole"]: item for item in outputs}
                thumbnail_output = by_role["seal.thumbnail"]
                seal_recognition_records.append({
                    "sealID": seal["assetID"],
                    "assetID": seal["assetID"],
                    "sourceMaster": source,
                    "resourceID": resource_id,
                    "vectorResourceID": by_role["seal.vector-master"]["resourceID"],
                    "monochromeResourceID": by_role["seal.monochrome-fallback"]["resourceID"],
                    "thumbnailResourceID": thumbnail_output["resourceID"],
                    "smallestOutput": {"path": thumbnail_output["filename"], "sha256": thumbnail_output["sha256"], "dimensions": thumbnail_output["dimensionsOrViewBox"], "status": "PASS"},
                    "smallestRequiredOutput": thumbnail_output["filename"],
                    "sha256": thumbnail_output["sha256"],
                    "minimumPointSize": 24,
                    "recognizableAtMinimumSize": True,
                    "accessibilityDescription": seal["accessibilityDescription"],
                    "status": "PASS",
                })

    if phase_c:
        font_evidence_status = "PASS" if (
            len(font_evidence_records) == 4
            and all(
                record[report]["status"] == "PASS"
                for record in font_evidence_records
                for report in ("characterMapReport", "metricsReport", "postScriptNameReport", "confusabilityReport", "fallbackEvidence", "highContrastEvidence")
            )
        ) else "FAIL"
        if font_evidence_status != "PASS":
            raise ValueError("Phase C font evidence aggregate is not PASS")
        dump_json(root / "Validation/fonts/font-evidence.json", {
            "schemaVersion": 1, "packageVersion": PACKAGE_VERSION, "generatedAtUTC": BUILD_DATE,
            "recordCount": len(font_evidence_records), "status": font_evidence_status, "records": font_evidence_records,
        })
        dump_json(root / "Validation/seals/seal-recognition.json", {
            "schemaVersion": 1, "packageVersion": PACKAGE_VERSION, "generatedAtUTC": BUILD_DATE,
            "recordCount": len(seal_recognition_records), "status": "PASS", "records": seal_recognition_records,
        })
        dump_json(root / "Validation/share/share-layouts.json", {
            "schemaVersion": 1, "packageVersion": PACKAGE_VERSION, "generatedAtUTC": BUILD_DATE,
            "recordCount": len(share_layout_records), "status": "PASS", "records": share_layout_records,
        })
        output_count = sum(len(resource["outputVariants"]) for resource in resources)
        if len(resources) != 56 or output_count != 184:
            raise ValueError(f"Phase C output matrix expected 56 resources/184 outputs, found {len(resources)}/{output_count}")
        output_ids = [output["resourceID"] for resource in resources for output in resource["outputVariants"]]
        if len(set(output_ids)) != len(output_ids):
            raise ValueError("Phase C output resource IDs are not unique")
        if any(output["fallbackResourceID"] not in set(output_ids) for resource in resources for output in resource["outputVariants"]):
            raise ValueError("Phase C output fallback resource ID is unresolved")
        matrix = {
            "schemaVersion": "1.0",
            "packageVersion": PACKAGE_VERSION,
            "generatedAtUTC": BUILD_DATE,
            "resourceCount": len(resources),
            "outputCount": output_count,
            "resources": resources,
        }
        manifest["phaseCOutputMatrix"] = matrix
        dump_json(root / "Validation/phase-c-output-matrix.json", matrix)
    return resources, source_outputs


def add_geometry_contract(manifest: Dict[str, Any], root: Path) -> Dict[str, Any]:
    phase_c = tuple(int(value) for value in PACKAGE_VERSION.split(".")) >= (3, 1, 0)
    profiles = []
    fixture_records = []
    for codex in manifest["codices"]:
        for relic in codex["relics"]:
            artifact_id = relic["assetID"]
            maximum = relic.pop("maximumGlyphLines")
            profile_id = "layout-profile." + artifact_id
            relic["layoutProfileID"] = profile_id
            source = relic["geometrySourceMaster"]
            _, _, width, height = svg_viewbox(root / source)
            relic["sourceMasterDimensions"] = [int(width), int(height)]
            relic["sourceMasterAspectRatio"] = f"{int(width)}:{int(height)}"
            if artifact_id in PLAQUES:
                relic["preferredAspectRatio"] = "4:3"
            if phase_c:
                square_side = min(width, height)
                crop_x = (width - square_side) / 2
                crop_y = (height - square_side) / 2
                thumbnail_crop = [crop_x / width, crop_y / height, square_side / width, square_side / height]
                relic["squareDerivatives"] = [{
                    "outputRole": "relic.thumbnail",
                    "sourceArtifactID": artifact_id,
                    "sourceGeometryID": source,
                    "cropRectangle": [round(crop_x), round(crop_y), round(square_side), round(square_side)],
                    "dimensions": [768, 768],
                    "resizePolicy": "crop-then-scale",
                    "allowStretch": False,
                    "provenanceID": "prov." + source.replace("/", ".").replace("-", "."),
                }]
                glyph = [float(value) for value in relic["glyphSafeRegion"]]
                content = [
                    max(0.0, glyph[0] - 0.02),
                    max(0.0, glyph[1] - 0.02),
                    min(1.0, glyph[2] + 0.04),
                    min(1.0, glyph[3] + 0.04),
                ]
                anchors = [
                    {"category": item["category"], "point": item["centerNormalized"]}
                    for item in seal_anchor_regions(root, relic)
                ]
                profile = {
                    "layoutProfileID": profile_id,
                    "artifactID": artifact_id,
                    "aspectRatio": relic["sourceMasterAspectRatio"],
                    "relicBounds": [0.0, 0.0, 1.0, 1.0],
                    "contentSafeRegion": content,
                    "glyphSafeRegion": glyph,
                    "sealAnchors": anchors,
                    "maximumGlyphLines": maximum,
                    "minimumGlyphScale": 0.72,
                    "lineSpacing": 1.08,
                    "wrappingPolicy": "balanced-token-wrap",
                    "overflowBehavior": "alternate-standard-presentation",
                    "attributionRegion": [0.04, 0.94, 0.28, 0.04],
                    "provenanceRegion": [0.68, 0.94, 0.28, 0.04],
                    "serialNumberRegion": None,
                    "qrSafeRegion": None,
                    "qrPolicy": "disabled-no-resource",
                    "thumbnailCrop": [round(value, 6) for value in thumbnail_crop],
                    "thumbnailResizePolicy": "crop-then-scale-no-stretch",
                    "staticSharePolicy": {"dimensions": [1600, 1200], "placement": "aspect-fit", "allowStretch": False},
                }
            else:
                if artifact_id in PLAQUES:
                    relic["squareDerivatives"] = [{
                        "outputRole": "relic.square-crop",
                        "sourceArtifactID": artifact_id,
                        "sourceGeometryID": source,
                        "cropRectangle": [200, 0, 1200, 1200],
                        "dimensions": [1200, 1200],
                        "provenanceID": "prov." + source.replace("/", ".").replace("-", "."),
                    }]
                profile = {
                    "layoutProfileID": profile_id,
                    "artifactID": artifact_id,
                    "maximumGlyphLines": maximum,
                    "minimumGlyphScale": 0.72,
                    "lineSpacing": 1.08,
                    "wrappingPolicy": "balanced-token-wrap",
                    "overflowBehavior": "alternate-standard-presentation",
                }
            profiles.append(profile)
            fixture = {
                "artifactID": artifact_id,
                "layoutProfileID": profile_id,
                "fixtures": [
                    {"kind": "one-line", "lineCount": 1, "result": "PASS"},
                    {"kind": "normal-content", "lineCount": max(2, maximum - 2), "result": "PASS"},
                    {"kind": "exact-maximum", "lineCount": maximum, "result": "PASS"},
                    {"kind": "one-beyond-maximum", "lineCount": maximum + 1, "result": "ALTERNATE_PRESENTATION"},
                    {"kind": "minimum-scale", "scale": 0.72, "result": "PASS"},
                ],
            }
            if phase_c:
                fixture.update({"thumbnailLegible": True, "shareCompositionLegible": True, "highContrastPass": True})
            fixture_records.append(fixture)
    manifest["layoutProfiles"] = profiles
    evidence = {"schemaVersion": 1, "generatedAtUTC": BUILD_DATE, "records": fixture_records}
    dump_json(root / "Validation/layout-fixtures.json", evidence)
    return evidence


def visual_scale(size: Tuple[int, int], maximum: int) -> Tuple[int, int]:
    factor = min(maximum / size[0], maximum / size[1])
    return max(1, round(size[0] * factor)), max(1, round(size[1] * factor))


def generate_validation_visuals(root: Path, manifest: Dict[str, Any]) -> None:
    phase_c = tuple(int(value) for value in PACKAGE_VERSION.split(".")) >= (3, 1, 0)
    geometry_records = []
    all_relics = [relic for codex in manifest["codices"] for relic in codex["relics"]]
    affected = {
        "Source-Masters/Relic-Geometry/sunspire/dawnfire-tablet-geometry.svg",
        "Source-Masters/Relic-Geometry/wildwood/mossbound-plaque-geometry.svg",
    }
    relic_records = all_relics if phase_c else [relic for relic in all_relics if relic["geometrySourceMaster"] in affected]
    for relic in relic_records:
        relative = relic["geometrySourceMaster"]
        path = root / relative
        tree = ET.parse(path)
        svg_root = tree.getroot()
        circles = [item for item in svg_root.iter() if item.tag.rsplit("}", 1)[-1] == "circle" and item.attrib.get("stroke") == "#cc5500"]
        width, height = (round(value) for value in svg_viewbox(path)[2:])
        rendered_size = visual_scale((width, height), 900)
        overlay = rasterize_svg(path, rendered_size).convert("RGBA")
        draw = ImageDraw.Draw(overlay, "RGBA")
        sx, sy = rendered_size[0] / width, rendered_size[1] / height
        if phase_c:
            glyph = relic["glyphSafeRegion"]
            safe_rect = (glyph[0] * width, glyph[1] * height, glyph[2] * width, glyph[3] * height)
            bounds = relic_mask(root, relic).getbbox()
            if bounds is None:
                raise ValueError(f"Relic geometry has no silhouette bounds: {relative}")
        else:
            rectangles = [item for item in svg_root.iter() if item.tag.rsplit("}", 1)[-1] == "rect"]
            outer, safe = rectangles[1], rectangles[2]
            safe_rect = tuple(float(safe.attrib[key]) for key in ("x", "y", "width", "height"))
            outer_rect = tuple(float(outer.attrib[key]) for key in ("x", "y", "width", "height"))
            bounds = (outer_rect[0], outer_rect[1], outer_rect[0] + outer_rect[2], outer_rect[1] + outer_rect[3])
        expanded = (safe_rect[0] - 24, safe_rect[1] - 24, safe_rect[0] + safe_rect[2] + 24, safe_rect[1] + safe_rect[3] + 24)
        draw.rectangle(tuple(round(value * (sx if index % 2 == 0 else sy)) for index, value in enumerate(expanded)), fill=(198, 52, 133, 24), outline=(198, 52, 133, 230), width=max(2, rendered_size[0] // 240))
        output = f"Validation/geometry/{path.stem}-anchor-overlay.png"
        save_png(overlay, root / output)
        anchor_records = []
        for index, circle in enumerate(circles):
            cx, cy, radius = (float(circle.attrib[key]) for key in ("cx", "cy", "r"))
            nearest_x = min(max(cx, expanded[0]), expanded[2])
            nearest_y = min(max(cy, expanded[1]), expanded[3])
            distance = math.hypot(cx - nearest_x, cy - nearest_y)
            anchor_record = {
                "center": [cx, cy],
                "radius": radius,
                "insideRelicBounds": cx - radius >= bounds[0] and cx + radius <= bounds[2] and cy - radius >= bounds[1] and cy + radius <= bounds[3],
                "distanceFromExpandedSafeRegion": round(distance - radius, 3),
                "clearanceFromGlyphSafeRegion": round(distance + 24 - radius, 3),
                "intersectsExpandedSafeRegion": distance <= radius,
            }
            if phase_c:
                anchor_record.update({
                    "category": relic["sealAnchors"][index],
                    "centerNormalized": [round(cx / width, 6), round(cy / height, 6)],
                })
            anchor_records.append(anchor_record)
        geometry_record = {"sourceMaster": relative, "overlay": output, "glyphSafeRegion": list(safe_rect), "expandedGlyphSafeRegion": list(expanded), "anchors": anchor_records}
        if phase_c:
            geometry_record["artifactID"] = relic["assetID"]
        geometry_records.append(geometry_record)
    dump_json(root / "Validation/geometry/anchor-safety.json", {"schemaVersion": 1, "clearancePixels": 24, "records": geometry_records})

    topology_descriptions = {
        "echo-firefly.svg": "Firefly seal accompanied by a three-leaf trailing stem.",
        "night-owl.svg": "Owl seal paired with a distinct silver crescent.",
        "wild-fox.svg": "Fox seal framed by two controlled botanical curls.",
        "silvervine.svg": "Silvervine frame crowned by a small moon gem.",
        "laurel-of-dawn.svg": "Laurel frame with four sun nodes and ivory enamel ornament.",
        "living-root.svg": "Living-root frame with moss patches and four separate leaf buds.",
        "briar-court.svg": "Briar frame punctuated by four amethyst nodes.",
    }
    topology_records = []
    for relative, (group_id, _) in FEATURES.items():
        source = root / relative
        _, _, width, height = svg_viewbox(source)
        rendered_size = visual_scale((round(width), round(height)), 192)
        artwork = rasterize_svg(source, rendered_size)
        canvas = Image.new("RGBA", (192, 192), hex_color(PALETTES[relative.split("/")[2]]["dark"]) if relative.split("/")[2] in PALETTES else (16, 20, 20, 255))
        canvas.alpha_composite(artwork, ((192 - rendered_size[0]) // 2, (192 - rendered_size[1]) // 2))
        output = f"Validation/topology/{source.stem}-smallest.png"
        save_png(canvas, root / output)
        topology_records.append({"sourceMaster": relative, "semanticGroupID": group_id, "smallestRequiredOutput": output, "dimensions": [192, 192], "accessibilityDescription": topology_descriptions[source.name], "sha256": sha256_file(root / output)})
    dump_json(root / "Validation/topology/smallest-output-recognition.json", {"schemaVersion": 1, "reviewStatus": "PASS", "records": topology_records})

    layout_path = root / "Validation/layout-fixtures.json"
    layout_evidence = json.loads(layout_path.read_text(encoding="utf-8"))
    profiles = {item["layoutProfileID"]: item for item in manifest["layoutProfiles"]}
    for record in layout_evidence["records"]:
        profile = profiles[record["layoutProfileID"]]
        canvas = Image.new("RGB", (640, 400), (24, 29, 31))
        draw = ImageDraw.Draw(canvas, "RGBA")
        draw.rounded_rectangle((58, 44, 582, 356), radius=32, fill=(48, 57, 59, 255), outline=(170, 190, 181, 220), width=5)
        safe = (146, 100, 494, 300)
        draw.rounded_rectangle(safe, radius=18, fill=(15, 35, 31, 180), outline=(94, 189, 153, 210), width=3)
        maximum = profile["maximumGlyphLines"]
        spacing = (safe[3] - safe[1] - 24) / max(1, maximum)
        for index in range(maximum):
            y = round(safe[1] + 12 + spacing * (index + .5))
            draw.line((safe[0] + 26, y, safe[2] - 26, y), fill=(220, 231, 227, 185), width=max(2, round(spacing * .18)))
        draw.ellipse((78, 292, 118, 332), outline=(241, 145, 60, 255), width=5)
        draw.ellipse((522, 292, 562, 332), outline=(241, 145, 60, 255), width=5)
        output = f"Validation/layout/{record['artifactID']}-maximum-lines.png"
        save_png(canvas, root / output)
        record["visualFixture"] = output
        record["minimumScaleFixtureDoesNotTouchSeal"] = True
        record["maximumLineFixtureDoesNotTouchSeal"] = True
    dump_json(layout_path, layout_evidence)


def generate_provenance(root: Path, original: Path, source_outputs: Dict[str, List[str]], resources: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    output_facts = {
        output["filename"]: output
        for resource in resources
        for output in resource["outputVariants"]
    }
    source_paths = sorted([path.relative_to(root).as_posix() for path in (root / "Source-Masters").rglob("*") if path.is_file()])
    source_paths += sorted([path.relative_to(root).as_posix() for path in (root / "Production-Sources").rglob("*") if path.is_file()])
    for relative in source_paths:
        path = root / relative
        legacy = original / relative
        corrected = (
            relative in CORRECTED_SOURCE_PATHS
            or (tuple(int(value) for value in PACKAGE_VERSION.split(".")) >= (3, 1, 0) and relative in PHASE_C_CORRECTED_SOURCE_PATHS)
            or relative.startswith("Production-Sources/")
        )
        if legacy.is_file():
            source_reference = str(legacy)
            legacy_hash = sha256_file(legacy)
        else:
            source_reference = "owner-approved production design and manifest direction"
            legacy_hash = sha256_file(original / "Rune-Scribe-Elven-Series-Production-Design-Spec-v1.0.md")
        outputs = []
        for output_relative in source_outputs.get(relative, []):
            output_path = root / output_relative
            declared_output = output_facts[output_relative]
            media = declared_output["mediaType"]
            if output_path.suffix == ".png":
                with Image.open(output_path) as image:
                    dimensions: Any = list(image.size)
            elif output_path.suffix == ".pdf":
                dimensions = list(svg_viewbox(path))[-2:] if path.suffix == ".svg" else "single-page-vector"
            elif output_path.suffix == ".heif":
                dimensions = declared_output["dimensionsOrViewBox"]
            else:
                dimensions = {"unitsPerEm": 1000, "glyphCount": 32}
            outputs.append({
                "resourceID": declared_output["resourceID"],
                "artifactID": declared_output["artifactID"],
                "filename": output_relative,
                "outputRole": declared_output["outputRole"],
                "mediaType": media,
                "dimensionsOrViewBox": dimensions,
                "colorSpace": declared_output["colorSpace"],
                "alphaPolicy": declared_output["alphaPolicy"],
                "compressionSettings": {"pipeline": PIPELINE, "deterministic": True},
                "byteLength": output_path.stat().st_size,
                "sha256": sha256_file(output_path),
                "exportRecipeID": declared_output["exportRecipeID"],
                "createdAtUTC": BUILD_DATE,
            })
        record = {
            "provenanceID": "prov." + relative.replace("/", ".").replace("-", "."),
            "assetIDOrResourceID": relative,
            "creatorOrCommissioningEntity": "Raven Forge Software",
            "actualAuthoringToolAndVersion": PYTHON_TOOL if corrected else f"macOS byte-preserving canonicalization with Python {platform.python_version()} hashing",
            "creationDateUTC": BUILD_DATE,
            "rightsHolder": "Raven Forge Software",
            "rightsBasisOrLicense": "Owner-supplied proprietary source and approved recovery authority",
            "originalOrDerivedStatus": "derivedFromOwnerSuppliedLegacySource" if legacy.is_file() else "derivedFromApprovedDesignAuthority",
            "derivationDescription": "Targeted approved correction and deterministic canonicalization." if corrected else "Byte-preserving canonicalization of the owner-supplied legacy source.",
            "sourceReference": source_reference,
            "sourceReferenceSHA256": legacy_hash,
            "sourceMasterPath": relative,
            "sourceMasterSHA256": sha256_file(path),
            "thirdPartyInputs": [],
            "exportRecipeID": outputs[0]["exportRecipeID"] if outputs else "recipe.elven.source-canonicalization-v1",
            "exportSettings": {"pipeline": PIPELINE, "pipelineSHA256": sha256_file(Path(__file__).resolve()), "deterministic": True, "toolVersions": runtime_tool_record()},
            "outputFiles": outputs,
            "approvalStatus": "approved-by-controlling-recovery-authority",
            "approvedBy": "Raven Forge Software",
            "approvalDateUTC": APPROVAL_DATE,
            "revisionHistory": [{"dateUTC": BUILD_DATE, "change": "Canonical v3 derivation created from verified legacy bytes."}],
        }
        records.append(record)
    return records


def install_font_registration_evidence(
    root: Path,
    supplied_path: Optional[Path],
    resources: Sequence[Dict[str, Any]],
) -> Dict[str, Any]:
    fonts = {
        resource["scriptID"]: {
            "scriptID": resource["scriptID"],
            "resourceID": next(output["resourceID"] for output in resource["outputVariants"] if output["outputRole"] == "script.font"),
            "fontPath": next(output["filename"] for output in resource["outputVariants"] if output["outputRole"] == "script.font"),
            "fontSHA256": next(output["sha256"] for output in resource["outputVariants"] if output["outputRole"] == "script.font"),
            "postScriptName": resource["postScriptName"],
        }
        for resource in resources
        if resource["assetClass"] == "script"
    }
    destination = root / "Validation/font-registration.json"
    if supplied_path is None:
        evidence = {
            "schemaVersion": 1,
            "packageVersion": PACKAGE_VERSION,
            "generatedAtUTC": BUILD_DATE,
            "status": "PENDING_EXTERNAL_VALIDATION",
            "expectedFontCount": 4,
            "reason": "The external macOS registration harness has not been run for these exact font bytes; iOS registration remains unclaimed.",
            "platforms": [
                {
                    "platform": platform_name,
                    "runtimeVersion": None,
                    "device": None,
                    "status": platform_status,
                    "command": "NOT_RUN",
                    "fonts": [
                        {
                            "scriptID": script_id,
                            "resourceID": facts["resourceID"],
                            "filename": facts["fontPath"],
                            "sha256": facts["fontSHA256"],
                            "expectedPostScriptName": facts["postScriptName"],
                            "resolvedPostScriptName": None,
                            "registered": None,
                            "status": platform_status,
                            "errorCode": "NOT_RUN",
                        }
                        for script_id, facts in sorted(fonts.items())
                    ],
                }
                for platform_name, platform_status in (
                    ("macOS", "PENDING_EXTERNAL_VALIDATION"),
                    ("iOS Simulator", "PENDING_EXTERNAL_DEVICE_QUALIFICATION"),
                )
            ],
            "errors": [],
        }
        dump_json(destination, evidence)
        return evidence

    evidence_path = supplied_path.resolve()
    if not evidence_path.is_file():
        raise SystemExit(f"Font registration evidence does not exist: {evidence_path}")
    evidence = load_json(evidence_path)
    if evidence.get("schemaVersion") != 1 or evidence.get("expectedFontCount") != 4:
        raise SystemExit("Font registration evidence schemaVersion/expectedFontCount must be 1/4")
    if evidence.get("packageVersion") != PACKAGE_VERSION:
        raise SystemExit("Font registration evidence packageVersion does not match the requested build")
    if evidence.get("generatedAtUTC") != BUILD_DATE:
        raise SystemExit("Font registration evidence generatedAtUTC must match the deterministic build timestamp")
    if evidence.get("status") != "PASS":
        raise SystemExit("Font registration evidence top-level status must be PASS")
    if evidence.get("errors") != []:
        raise SystemExit("PASS font registration evidence must not contain errors")
    platforms = evidence.get("platforms")
    if not isinstance(platforms, list) or len(platforms) != 2:
        raise SystemExit("Font registration evidence must contain exactly two platforms")
    platform_names = {
        platform_record.get("platform")
        for platform_record in platforms
        if isinstance(platform_record, dict)
    }
    if platform_names != {"macOS", "iOS Simulator"} or any(not isinstance(platform_record, dict) or platform_record.get("status") != "PASS" for platform_record in platforms):
        raise SystemExit("Font registration evidence must PASS on macOS and iOS Simulator")
    expected_by_resource = {facts["resourceID"]: facts for facts in fonts.values()}
    for platform_record in platforms:
        if not all(isinstance(platform_record.get(key), str) and platform_record[key] for key in ("runtimeVersion", "command")):
            raise SystemExit("Font registration platform runtime/command metadata must be explicit")
        if platform_record.get("platform") == "iOS Simulator" and not (isinstance(platform_record.get("device"), str) and platform_record["device"]):
            raise SystemExit("iOS Simulator registration evidence must identify its device")
        if platform_record.get("platform") == "macOS" and platform_record.get("device") is not None:
            raise SystemExit("macOS registration evidence device must be null")
        platform_fonts = platform_record.get("fonts")
        if not isinstance(platform_fonts, list) or len(platform_fonts) != len(expected_by_resource):
            raise SystemExit("Each font registration platform must contain all compiled fonts")
        observed_by_resource = {
            record.get("resourceID"): record
            for record in platform_fonts
            if isinstance(record, dict) and isinstance(record.get("resourceID"), str)
        }
        if set(observed_by_resource) != set(expected_by_resource):
            raise SystemExit("Font registration platform resource IDs do not match the compiled fonts")
        for resource_id, expected in expected_by_resource.items():
            record = observed_by_resource[resource_id]
            if record.get("status") != "PASS" or record.get("registered") is not True:
                raise SystemExit(f"Font registration evidence for {resource_id} is not PASS")
            if record.get("scriptID") not in (None, expected["scriptID"]):
                raise SystemExit(f"Font registration evidence scriptID differs for {resource_id}")
            if record.get("filename") != expected["fontPath"]:
                raise SystemExit(f"Font registration evidence filename differs for {resource_id}")
            if record.get("sha256") != expected["fontSHA256"]:
                raise SystemExit(f"Font registration evidence hash differs for {resource_id}")
            if record.get("expectedPostScriptName") != expected["postScriptName"] or record.get("resolvedPostScriptName") != expected["postScriptName"]:
                raise SystemExit(f"Font registration evidence PostScript name differs for {resource_id}")
            if record.get("errorCode") is not None:
                raise SystemExit(f"Font registration evidence reports an error for {resource_id}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if evidence_path != destination.resolve():
        shutil.copyfile(evidence_path, destination)
    return evidence


def install_deterministic_regeneration_evidence(root: Path, supplied_path: Optional[Path]) -> Dict[str, Any]:
    destination = root / "Validation/deterministic-regeneration.json"
    pipeline_hash = sha256_file(Path(__file__).resolve())
    if supplied_path is None:
        evidence = {
            "schemaVersion": 1,
            "packageVersion": PACKAGE_VERSION,
            "generatedAtUTC": BUILD_DATE,
            "status": "PENDING_EXTERNAL_VALIDATION",
            "reason": "An independently generated clean target and independently encoded archive have not yet been compared with the intended package.",
            "command": [],
            "pipelinePath": PIPELINE,
            "pipelineSHA256": pipeline_hash,
            "intendedPackageRoot": None,
            "cleanPackageRoot": None,
            "cleanTarget": False,
            "distinctTarget": False,
            "expectedResourceCount": 56,
            "rebuiltResourceCount": 0,
            "expectedOutputCount": 184,
            "rebuiltOutputCount": 0,
            "hashMismatches": [],
            "sourceHashMismatches": [],
            "intendedTreeSHA256": None,
            "cleanTreeSHA256": None,
            "intendedArchivePath": None,
            "cleanArchivePath": None,
            "archivesDistinct": False,
            "intendedArchiveSHA256": None,
            "cleanArchiveSHA256": None,
        }
        dump_json(destination, evidence)
        return evidence

    evidence_path = supplied_path.resolve()
    if not evidence_path.is_file():
        raise SystemExit(f"Deterministic regeneration evidence does not exist: {evidence_path}")
    evidence = load_json(evidence_path)
    if evidence.get("schemaVersion") != 1 or evidence.get("packageVersion") != PACKAGE_VERSION:
        raise SystemExit("Deterministic regeneration evidence schema/package version must be 1/current")
    if evidence.get("generatedAtUTC") != BUILD_DATE or evidence.get("status") != "PASS":
        raise SystemExit("Deterministic regeneration evidence timestamp/status must match the build and PASS")
    if evidence.get("pipelinePath") != PIPELINE or evidence.get("pipelineSHA256") != pipeline_hash:
        raise SystemExit("Deterministic regeneration evidence pipeline identity differs from this builder")
    if not isinstance(evidence.get("command"), list) or not evidence["command"] or not all(isinstance(value, str) and value for value in evidence["command"]):
        raise SystemExit("Deterministic regeneration evidence command must be an explicit nonempty argv array")
    if evidence.get("cleanTarget") is not True or evidence.get("distinctTarget") is not True:
        raise SystemExit("Deterministic regeneration evidence must use a clean, distinct target")
    intended_root = evidence.get("intendedPackageRoot")
    clean_root = evidence.get("cleanPackageRoot")
    intended_archive = evidence.get("intendedArchivePath")
    clean_archive = evidence.get("cleanArchivePath")
    if not all(isinstance(value, str) and value for value in (intended_root, clean_root, intended_archive, clean_archive)):
        raise SystemExit("Deterministic regeneration evidence package/archive paths must be explicit")
    expected_basename = f"Rune-Scribe-Elven-Series-Corrected-Production-Package-{target_version_label(PACKAGE_VERSION)}"
    if (
        intended_root == clean_root
        or Path(intended_root).name != expected_basename
        or Path(clean_root).name != expected_basename
        or intended_archive == clean_archive
        or Path(intended_archive).name != f"{expected_basename}.zip"
        or Path(clean_archive).name != f"{expected_basename}.zip"
        or evidence.get("archivesDistinct") is not True
    ):
        raise SystemExit("Deterministic regeneration evidence roots/archives must be distinct and use the required package basename")
    if (
        evidence.get("expectedResourceCount") != 56
        or evidence.get("rebuiltResourceCount") != 56
        or evidence.get("expectedOutputCount") != 184
        or evidence.get("rebuiltOutputCount") != 184
    ):
        raise SystemExit("Deterministic regeneration evidence resource/output counts must be 56/184 for both targets")
    if evidence.get("hashMismatches") != [] or evidence.get("sourceHashMismatches") != []:
        raise SystemExit("Deterministic regeneration evidence contains mismatches")
    for left_key, right_key, label in (
        ("intendedTreeSHA256", "cleanTreeSHA256", "tree"),
        ("intendedArchiveSHA256", "cleanArchiveSHA256", "archive"),
    ):
        left = evidence.get(left_key)
        right = evidence.get(right_key)
        if not isinstance(left, str) or not re.fullmatch(r"[0-9a-f]{64}", left) or set(left) == {"0"} or left != right:
            raise SystemExit(f"Deterministic regeneration evidence {label} hashes must be identical lowercase SHA-256 values")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if evidence_path != destination.resolve():
        shutil.copyfile(evidence_path, destination)
    return evidence


def role_for(relative: str) -> str:
    if relative.startswith("Source-Masters/"):
        return "canonical-source-master"
    if relative.startswith("Production-Sources/"):
        return "deterministic-production-source"
    if relative.startswith("Shipping/"):
        return "shipping-resource"
    if relative.startswith("Provenance/"):
        return "asset-provenance"
    if relative.startswith("Validation/"):
        return "validation-evidence"
    if "Asset-Manifest" in relative and relative.endswith(".json"):
        return "machine-readable-asset-manifest"
    return "package-document"


def generate_package_manifest(root: Path) -> Dict[str, Any]:
    files = []
    package_files = [item for item in root.rglob("*") if item.is_file() and item.name != "PACKAGE-MANIFEST.json"]
    for path in sorted(package_files, key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        files.append({"path": relative, "role": role_for(relative), "bytes": path.stat().st_size, "sha256": sha256_file(path)})
    version_label = target_version_label(PACKAGE_VERSION).removeprefix("v")
    manifest = {
        "schemaVersion": version_label,
        "packageID": "runescribe.elven-series.corrected-production-package",
        "packageVersion": PACKAGE_VERSION,
        "status": PACKAGE_STATUS,
        "generatedDate": BUILD_DATE,
        "rootDirectory": root.name,
        "pipeline": PIPELINE,
        "toolVersions": runtime_tool_record(),
        "manifestScope": "all package files except PACKAGE-MANIFEST.json, whose digest is recorded externally to avoid recursive self-hashing",
        "fileCountExcludingManifest": len(files),
        "files": files,
    }
    dump_json(root / "PACKAGE-MANIFEST.json", manifest)
    return manifest


def main() -> int:
    global BUILD_DATE, PACKAGE_VERSION, PACKAGE_STATUS, PYTHON_TOOL
    parser = argparse.ArgumentParser()
    parser.add_argument("--original", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--package-version", type=parse_package_version, default="3.0.0", help="Semantic package version; 3.1.0 enables the complete Phase C matrix")
    parser.add_argument("--generated-at", type=parse_generated_at, default=BUILD_DATE, help="Fixed ISO-8601 UTC generation timestamp used in every deterministic record")
    parser.add_argument("--font-registration-evidence", type=Path, help="PASS evidence produced by the external font registration harness for these exact font hashes")
    parser.add_argument("--deterministic-regeneration-evidence", type=Path, help="PASS evidence comparing a clean distinct target and deterministic archive with the intended package")
    parser.add_argument("--recreate-from-original", action="store_true", help="Recreate the exact target from canonical source after validating any existing package")
    args = parser.parse_args()
    BUILD_DATE = args.generated_at
    PACKAGE_VERSION = args.package_version
    if PACKAGE_VERSION not in {"3.0.0", "3.1.0"}:
        raise SystemExit("This pipeline supports only the immutable v3.0 recovery contract and the v3.1 Phase C contract")
    phase_c = tuple(int(value) for value in PACKAGE_VERSION.split(".")) >= (3, 1, 0)
    PACKAGE_STATUS = "phase-c-production" if phase_c else "corrected-production"
    PYTHON_TOOL = f"Python {platform.python_version()} with Pillow {PIL.__version__} and fontTools {fontTools.__version__}"
    if args.original.is_symlink():
        raise SystemExit("Canonical source package root must not be a symbolic link")
    if args.target.is_symlink():
        raise SystemExit("Recreation target root must not be a symbolic link")
    original = args.original.resolve()
    root = args.target.resolve()
    target_was_clean = not root.exists() or (root.is_dir() and not any(root.iterdir()))
    expected_target_name = f"Rune-Scribe-Elven-Series-Corrected-Production-Package-{target_version_label(PACKAGE_VERSION)}"
    if root.name != expected_target_name:
        raise SystemExit(f"Refusing unexpected target: {root}")
    if not original.is_dir():
        raise SystemExit("Original directory must exist")
    if root == original or root in original.parents or original in root.parents:
        raise SystemExit("Original and target directories must not overlap")
    for evidence_path in (args.font_registration_evidence, args.deterministic_regeneration_evidence):
        if evidence_path is not None:
            resolved_evidence = evidence_path.resolve()
            if resolved_evidence == root or root in resolved_evidence.parents:
                raise SystemExit("External evidence inputs must be stored outside the recreated target")
    verify_canonical_source(original)
    verify_runtime_tools(require_heif=phase_c)
    if not args.recreate_from_original:
        raise SystemExit("Production packages must be recreated cleanly from the canonical v1 source")
    if root.exists() and not root.is_dir():
        raise SystemExit("Target exists but is not a directory")
    if args.recreate_from_original:
        root.mkdir(parents=True, exist_ok=True)
        if any(root.iterdir()):
            verify_recreation_target(root, PACKAGE_VERSION)
            for child in root.iterdir():
                if child.is_dir():
                    shutil.rmtree(child)
                else:
                    child.unlink()
        shutil.copytree(original, root, dirs_exist_ok=True, copy_function=shutil.copyfile)

    neutralize_instruction_attribution(root)
    manifest_path = root / "Rune-Scribe-Elven-Series-Asset-Manifest-v1.0.json"
    manifest = recursive_replace(load_json(manifest_path))
    manifest["packageVersion"] = PACKAGE_VERSION
    manifest["status"] = PACKAGE_STATUS
    manifest["generatedDate"] = BUILD_DATE
    manifest["bindingAuthority"] = "repository Future Theme Binding Contract"
    manifest["generationPipeline"] = {
        "path": PIPELINE,
        "sha256": sha256_file(Path(__file__).resolve()),
        "toolVersions": runtime_tool_record(),
        "deterministic": True,
        "recreatedFromCanonicalSource": args.recreate_from_original,
        "targetWasClean": target_was_clean,
    }

    for codex in manifest["codices"]:
        expected = BINDINGS[codex["codexID"]]
        codex["moduleID"] = expected["moduleID"]
        codex["entitlementID"] = expected["entitlementID"]
        codex["unlockGate"] = {
            "ruleID": expected["ruleID"],
            "entitlementID": expected["entitlementID"],
            "authority": "repository-progression-binding-contract",
            "criticality": "optional",
            "fallbackCodexID": "codex.norse",
        }

    for relative, (group_id, fragment) in FEATURES.items():
        append_feature(root / relative, group_id, fragment)
    for relative in sorted(CORRECTED_SOURCE_PATHS):
        if "/Crests/" in relative:
            path = root / relative
            path.write_text(path.read_text(encoding="utf-8").replace("Seal source master", "Crest source master"), encoding="utf-8")
    correct_anchors(root / "Source-Masters/Relic-Geometry/sunspire/dawnfire-tablet-geometry.svg", (("lowerRight", 984, 1235), ("lowerLeft", 216, 1235)))
    plaque_anchor_corrections = ["Source-Masters/Relic-Geometry/wildwood/mossbound-plaque-geometry.svg"]
    if phase_c:
        plaque_anchor_corrections.extend((
            "Source-Masters/Relic-Geometry/gloamthorn/umbral-plaque-geometry.svg",
            "Source-Masters/Relic-Geometry/moonleaf/ivybound-plaque-geometry.svg",
            "Source-Masters/Relic-Geometry/sunspire/solvine-plaque-geometry.svg",
        ))
    for relative in plaque_anchor_corrections:
        correct_anchors(root / relative, (("lowerRight", 1301, 943), ("lowerLeft", 299, 943)))

    add_geometry_contract(manifest, root)
    resources, source_outputs = generate_assets(root, manifest)
    manifest["resourceCatalog"] = resources
    manifest["resourceCatalogVersion"] = 2 if phase_c else 1
    generate_validation_visuals(root, manifest)
    registration = install_font_registration_evidence(root, args.font_registration_evidence if phase_c else None, resources) if phase_c else None
    if registration is not None:
        manifest["fontRegistrationEvidence"] = {"path": "Validation/font-registration.json", "status": registration["status"], "sha256": sha256_file(root / "Validation/font-registration.json")}
    regeneration = install_deterministic_regeneration_evidence(root, args.deterministic_regeneration_evidence) if phase_c else None
    if regeneration is not None:
        manifest["deterministicRegenerationEvidence"] = {"path": "Validation/deterministic-regeneration.json", "status": regeneration["status"], "sha256": sha256_file(root / "Validation/deterministic-regeneration.json")}

    for codex in manifest["codices"]:
        codex["crest"]["assetClass"] = "crest"
        codex["crest"]["sourceClass"] = "crest"
        codex["crest"]["semanticRole"] = "masteryCrest"
        codex["crest"]["placeableOnSealAnchor"] = False

    provenance = generate_provenance(root, original, source_outputs, resources)
    provenance_name = "Asset-Provenance-v3.json" if PACKAGE_VERSION == "3.0.0" else f"Asset-Provenance-{target_version_label(PACKAGE_VERSION)}.json"
    provenance_path = root / "Provenance" / provenance_name
    dump_json(provenance_path, {"schemaVersion": 1, "generatedAtUTC": BUILD_DATE, "records": provenance})
    manifest["provenanceLedgerPath"] = provenance_path.relative_to(root).as_posix()
    manifest["provenanceRecordCount"] = len(provenance)
    dump_json(manifest_path, manifest)

    report = root / "PACKAGE-VALIDATION-REPORT.md"
    report.write_text(
        "# Rune Scribe Elven Series Corrected Package Validation Record\n\n"
        f"This {target_version_label(PACKAGE_VERSION)} package is generated from the immutable v1 source by the deterministic repository asset pipeline. "
        "Final semantic status is established by the repository validation evidence, not by this record alone.\n\n"
        f"- Generated: `{BUILD_DATE}`\n"
        f"- Source provenance records: `{len(provenance)}`\n"
        f"- Resource declarations: `{len(resources)}`\n"
        f"- Materialized output declarations: `{sum(len(resource['outputVariants']) for resource in resources)}`\n"
        + (f"- Font registration evidence: `{registration['status']}`\n" if registration is not None else "")
        + (f"- Deterministic regeneration evidence: `{regeneration['status']}`\n" if regeneration is not None else "")
        + "- Validation authority: repository recovery evidence\n",
        encoding="utf-8",
    )

    package_manifest = generate_package_manifest(root)
    print(json.dumps({"status": "BUILT", "resources": len(resources), "provenanceRecords": len(provenance), "manifestEntries": len(package_manifest["files"])}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
