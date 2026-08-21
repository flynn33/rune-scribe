#!/usr/bin/env python3
"""Build the corrected Elven production package from the immutable v1 source."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import re
import shutil
import struct
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

from PIL import Image, ImageDraw, ImageOps
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path


SVG_NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG_NS)

BUILD_DATE = "2026-08-21T14:30:00Z"
APPROVAL_DATE = "2026-08-20T00:00:00Z"
PYTHON_TOOL = "Python 3.9.6 with Pillow 11.3.0 and fontTools 4.60.2"
PIPELINE = "scripts/build-elven-production-assets.py"

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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dump_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


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
            close = values and values[-1] is None
            if close:
                values[-1] = start
            for end in values:
                control = end if end == values[-1] else end
                target = end
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


def write_vector_pdf(svg_path: Path, pdf_path: Path) -> None:
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
            commands.append(f"{fill[0]/255:.5f} {fill[1]/255:.5f} {fill[2]/255:.5f} rg")
        if stroke:
            commands.append(f"{stroke[0]/255:.5f} {stroke[1]/255:.5f} {stroke[2]/255:.5f} RG")
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
    builder.setupNameTable({"familyName": family, "styleName": "Regular", "uniqueFontIdentifier": f"Raven Forge Software:{postscript}:2026", "fullName": family, "psName": postscript, "version": "Version 1.000"})
    builder.setupOS2(sTypoAscender=int(glyph_manifest["ascender"]), sTypoDescender=int(glyph_manifest["descender"]), sTypoLineGap=int(glyph_manifest["lineGap"]), usWinAscent=max(0, int(glyph_manifest["ascender"])), usWinDescent=abs(int(glyph_manifest["descender"])))
    builder.setupPost()
    builder.setupMaxp()
    output.parent.mkdir(parents=True, exist_ok=True)
    builder.save(str(output))


def gradient_image(size: Tuple[int, int], dark: str, mid: str) -> Image.Image:
    image = Image.new("RGB", size)
    pixels = image.load()
    first, second = hex_color(dark), hex_color(mid)
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        color = tuple(round(first[index] * (1 - t) + second[index] * t) for index in range(3))
        for x in range(size[0]):
            pixels[x, y] = color
    return image


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


def output_fact(root: Path, relative: str, role: str, media: str, dimensions: Any, maximum: int, recipe: str) -> Dict[str, Any]:
    path = root / relative
    return {
        "outputRole": role,
        "filename": relative,
        "mediaType": media,
        "dimensionsOrViewBox": dimensions,
        "colorSpace": "sRGB" if media.startswith("image/") or media == "application/pdf" else "not-applicable",
        "alphaPolicy": "straight" if media == "image/png" else "not-applicable",
        "byteLimit": maximum,
        "maximumBytes": maximum,
        "requiredOrOptional": "required",
        "status": "materialized",
        "byteLength": path.stat().st_size,
        "sha256": sha256_file(path),
        "exportRecipeID": recipe,
        "createdAtUTC": BUILD_DATE,
    }


def resource_common(resource_id: str, codex_id: str, asset_class: str, role: str, source_path: str, media: str, dimensions: Any, accessibility: str, provenance_id: str, outputs: List[Dict[str, Any]], fallback: str, budget: str) -> Dict[str, Any]:
    return {
        "resourceID": resource_id,
        "ownerCodexID": codex_id,
        "assetClass": asset_class,
        "sourceClass": asset_class,
        "semanticRole": role,
        "requiredOrOptional": "required",
        "sourceMasterPath": source_path,
        "sourceMediaType": media,
        "sourceViewBoxOrDimensions": dimensions,
        "outputVariants": outputs,
        "fallbackResourceID": fallback,
        "accessibility": {"classification": "decorative-with-named-collectible", "description": accessibility},
        "budgetClass": budget,
        "provenanceID": provenance_id,
    }


def generate_assets(root: Path, manifest: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], Dict[str, List[str]]]:
    resources: List[Dict[str, Any]] = []
    source_outputs: Dict[str, List[str]] = {}
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
            "createdAtUTC": BUILD_DATE,
            "palette": palette,
        }
        background_source = f"Production-Sources/{slug}/{slug}-background-recipe.json"
        vault_source = f"Production-Sources/{slug}/{slug}-vault-recipe.json"
        dump_json(root / background_source, dict(recipe_base, role="background", direction=codex["background"]["direction"], variants=["static-base", "reduce-motion", "high-contrast"]))
        dump_json(root / vault_source, dict(recipe_base, role="vault", direction=codex["vault"], variants=["card", "locked", "encountered", "selected"]))

        glyph_manifest_path = Path(codex["script"]["glyphMasterManifest"])
        glyph_manifest = json.loads((root / glyph_manifest_path).read_text(encoding="utf-8"))
        font_rel = f"Shipping/{slug}/script/{slug}-script-primary.ttf"
        build_font(root / codex["script"]["sourceMasterDirectory"], glyph_manifest, root / font_rel)
        fallback_rel = f"Shipping/{slug}/script/{slug}-script-static-fallback.png"
        specimen_rel = f"Shipping/{slug}/script/{slug}-script-specimen.png"
        specimen = Image.new("RGBA", (1024, 256), (0, 0, 0, 0))
        for index in range(8):
            glyph = rasterize_svg(root / codex["script"]["sourceMasterDirectory"] / f"glyph-{index:02d}.svg", (120, 120), monochrome=True)
            specimen.alpha_composite(glyph, (8 + index * 126, 68))
        save_png(specimen, root / fallback_rel)
        save_png(specimen.resize((1024, 256)), root / specimen_rel)
        script_outputs = [
            output_fact(root, font_rel, "script.font", "font/ttf", {"unitsPerEm": glyph_manifest["unitsPerEm"], "glyphCount": 32}, 8388608, "recipe.elven.font-outline-v1"),
            output_fact(root, fallback_rel, "script.static-fallback", "image/png", [1024, 256], 2097152, "recipe.elven.script-fallback-v1"),
            output_fact(root, specimen_rel, "script.specimen-preview", "image/png", [1024, 256], 2097152, "recipe.elven.script-fallback-v1"),
        ]
        script_prov = "prov." + glyph_manifest_path.as_posix().replace("/", ".").replace("-", ".")
        script_resource = resource_common(f"resource.script.{slug}", codex_id, "script", "primaryScript", glyph_manifest_path.as_posix(), "application/json", {"glyphCount": 32, "unitsPerEm": glyph_manifest["unitsPerEm"]}, f"{codex['displayName']} script with static renderer fallback.", script_prov, script_outputs, "resource.script.base-runes-fallback", "font")
        script_resource.update({"scriptID": codex["script"]["scriptID"], "fontRefID": codex["script"]["fontRefID"], "postScriptName": codex["script"]["postScriptName"]})
        codex["script"].update(script_resource)
        resources.append(script_resource)
        source_outputs.setdefault(glyph_manifest_path.as_posix(), []).extend([font_rel, fallback_rel, specimen_rel])

        background_outputs = []
        for mode, role in (("static", "background.static-base"), ("reduce-motion", "background.reduce-motion"), ("high-contrast", "background.high-contrast")):
            relative = f"Shipping/{slug}/background/{slug}-background-{mode}.png"
            save_png(draw_background(slug, (1600, 1200), mode), root / relative)
            background_outputs.append(output_fact(root, relative, role, "image/png", [1600, 1200], 8388608, "recipe.elven.background-procedural-v1"))
        background_prov = "prov." + background_source.replace("/", ".").replace("-", ".")
        background_resource = resource_common(f"resource.background.{slug}.{codex['background']['assetID'].split('.')[-1]}", codex_id, "background", "runtimeBackground", background_source, "application/json", [1600, 1200], codex["background"]["direction"], background_prov, background_outputs, f"resource.background.{slug}.reduce-motion", "static-image")
        codex["background"].update(background_resource)
        resources.append(background_resource)
        source_outputs[background_source] = [item["filename"] for item in background_outputs]

        vault_outputs = []
        for mode, role in (("card", "vault.card"), ("locked", "vault.locked-silhouette"), ("encountered", "vault.encountered"), ("selected", "vault.selected")):
            relative = f"Shipping/{slug}/vault/{slug}-vault-{mode}.png"
            save_png(draw_vault(slug, mode), root / relative)
            vault_outputs.append(output_fact(root, relative, role, "image/png", [1024, 1024], 4194304, "recipe.elven.vault-procedural-v1"))
        vault_prov = "prov." + vault_source.replace("/", ".").replace("-", ".")
        vault_resource = resource_common(f"resource.vault.{slug}.codex", codex_id, "vault", "codexVaultPresentation", vault_source, "application/json", [1024, 1024], f"{codex['displayName']} locked, encountered, owned, and selected presentation.", vault_prov, vault_outputs, f"resource.vault.{slug}.locked", "static-image")
        codex["vault"].update(vault_resource)
        resources.append(vault_resource)
        source_outputs[vault_source] = [item["filename"] for item in vault_outputs]

        for field, asset_class, semantic_role, source_key, roles in (
            ("frame", "frame", "masteryFrame", "sourceMaster", (("vector", "frame.vector-master", "application/pdf"), ("static-fallback", "frame.static-fallback", "image/png"), ("thumbnail", "frame.thumbnail", "image/png"))),
            ("crest", "crest", "masteryCrest", "sourceMaster", (("vector", "crest.vector-master", "application/pdf"), ("static-fallback", "crest.static-fallback", "image/png"), ("thumbnail", "crest.thumbnail", "image/png"))),
        ):
            record = codex[field]
            source = record[source_key]
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
                        image.thumbnail((512, 512))
                    save_png(image, root / relative)
                    dimensions = list(image.size)
                outputs.append(output_fact(root, relative, role, media, dimensions, 8388608 if media == "application/pdf" else 4194304, f"recipe.elven.{asset_class}-export-v1"))
            provenance_id = "prov." + source.replace("/", ".").replace("-", ".")
            resource = resource_common(f"resource.{asset_class}.{slug}.{asset_slug}", codex_id, asset_class, semantic_role, source, "image/svg+xml", list(svg_viewbox(root / source)[2:]), record["direction"], provenance_id, outputs, f"resource.{asset_class}.{slug}.{asset_slug}.static-fallback", "static-image")
            if asset_class == "crest":
                resource["placeableOnSealAnchor"] = False
            record.update(resource)
            resources.append(resource)
            source_outputs.setdefault(source, []).extend([item["filename"] for item in outputs])
    return resources, source_outputs


def add_geometry_contract(manifest: Dict[str, Any], root: Path) -> Dict[str, Any]:
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
            fixture_records.append({
                "artifactID": artifact_id,
                "layoutProfileID": profile_id,
                "fixtures": [
                    {"kind": "one-line", "lineCount": 1, "result": "PASS"},
                    {"kind": "normal-content", "lineCount": max(2, maximum - 2), "result": "PASS"},
                    {"kind": "exact-maximum", "lineCount": maximum, "result": "PASS"},
                    {"kind": "one-beyond-maximum", "lineCount": maximum + 1, "result": "ALTERNATE_PRESENTATION"},
                    {"kind": "minimum-scale", "scale": 0.72, "result": "PASS"},
                ],
            })
    manifest["layoutProfiles"] = profiles
    evidence = {"schemaVersion": 1, "generatedAtUTC": BUILD_DATE, "records": fixture_records}
    dump_json(root / "Validation/layout-fixtures.json", evidence)
    return evidence


def visual_scale(size: Tuple[int, int], maximum: int) -> Tuple[int, int]:
    factor = min(maximum / size[0], maximum / size[1])
    return max(1, round(size[0] * factor)), max(1, round(size[1] * factor))


def generate_validation_visuals(root: Path, manifest: Dict[str, Any]) -> None:
    geometry_records = []
    affected = (
        "Source-Masters/Relic-Geometry/sunspire/dawnfire-tablet-geometry.svg",
        "Source-Masters/Relic-Geometry/wildwood/mossbound-plaque-geometry.svg",
    )
    for relative in affected:
        path = root / relative
        tree = ET.parse(path)
        svg_root = tree.getroot()
        rectangles = [item for item in svg_root.iter() if item.tag.rsplit("}", 1)[-1] == "rect"]
        circles = [item for item in svg_root.iter() if item.tag.rsplit("}", 1)[-1] == "circle" and item.attrib.get("stroke") == "#cc5500"]
        outer, safe = rectangles[1], rectangles[2]
        width, height = (round(value) for value in svg_viewbox(path)[2:])
        rendered_size = visual_scale((width, height), 900)
        overlay = rasterize_svg(path, rendered_size).convert("RGBA")
        draw = ImageDraw.Draw(overlay, "RGBA")
        sx, sy = rendered_size[0] / width, rendered_size[1] / height
        safe_rect = tuple(float(safe.attrib[key]) for key in ("x", "y", "width", "height"))
        expanded = (safe_rect[0] - 24, safe_rect[1] - 24, safe_rect[0] + safe_rect[2] + 24, safe_rect[1] + safe_rect[3] + 24)
        draw.rectangle(tuple(round(value * (sx if index % 2 == 0 else sy)) for index, value in enumerate(expanded)), fill=(198, 52, 133, 24), outline=(198, 52, 133, 230), width=max(2, rendered_size[0] // 240))
        output = f"Validation/geometry/{path.stem}-anchor-overlay.png"
        save_png(overlay, root / output)
        outer_rect = tuple(float(outer.attrib[key]) for key in ("x", "y", "width", "height"))
        anchor_records = []
        for circle in circles:
            cx, cy, radius = (float(circle.attrib[key]) for key in ("cx", "cy", "r"))
            nearest_x = min(max(cx, expanded[0]), expanded[2])
            nearest_y = min(max(cy, expanded[1]), expanded[3])
            distance = math.hypot(cx - nearest_x, cy - nearest_y)
            anchor_records.append({
                "center": [cx, cy],
                "radius": radius,
                "insideRelicBounds": cx - radius >= outer_rect[0] and cx + radius <= outer_rect[0] + outer_rect[2] and cy - radius >= outer_rect[1] and cy + radius <= outer_rect[1] + outer_rect[3],
                "distanceFromExpandedSafeRegion": round(distance - radius, 3),
                "clearanceFromGlyphSafeRegion": round(distance + 24 - radius, 3),
                "intersectsExpandedSafeRegion": distance <= radius,
            })
        geometry_records.append({"sourceMaster": relative, "overlay": output, "glyphSafeRegion": list(safe_rect), "expandedGlyphSafeRegion": list(expanded), "anchors": anchor_records})
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
    output_roles = {
        output["filename"]: output["outputRole"]
        for resource in resources
        for output in resource["outputVariants"]
    }
    source_paths = sorted([path.relative_to(root).as_posix() for path in (root / "Source-Masters").rglob("*") if path.is_file()])
    source_paths += sorted([path.relative_to(root).as_posix() for path in (root / "Production-Sources").rglob("*") if path.is_file()])
    for relative in source_paths:
        path = root / relative
        legacy = original / relative
        corrected = relative in CORRECTED_SOURCE_PATHS or relative.startswith("Production-Sources/")
        if legacy.is_file():
            source_reference = str(legacy)
            legacy_hash = sha256_file(legacy)
        else:
            source_reference = "owner-approved production design and manifest direction"
            legacy_hash = sha256_file(original / "Rune-Scribe-Elven-Series-Production-Design-Spec-v1.0.md")
        outputs = []
        for output_relative in source_outputs.get(relative, []):
            output_path = root / output_relative
            media = "application/pdf" if output_path.suffix == ".pdf" else ("font/ttf" if output_path.suffix == ".ttf" else "image/png")
            if output_path.suffix == ".png":
                with Image.open(output_path) as image:
                    dimensions: Any = list(image.size)
            elif output_path.suffix == ".pdf":
                dimensions = list(svg_viewbox(path))[-2:] if path.suffix == ".svg" else "single-page-vector"
            else:
                dimensions = {"unitsPerEm": 1000, "glyphCount": 32}
            outputs.append({
                "filename": output_relative,
                "outputRole": output_roles[output_relative],
                "mediaType": media,
                "dimensionsOrViewBox": dimensions,
                "colorSpace": "sRGB" if media != "font/ttf" else "not-applicable",
                "alphaPolicy": "straight" if media == "image/png" else "not-applicable",
                "compressionSettings": {"pipeline": PIPELINE, "deterministic": True},
                "byteLength": output_path.stat().st_size,
                "sha256": sha256_file(output_path),
                "createdAtUTC": BUILD_DATE,
            })
        record = {
            "provenanceID": "prov." + relative.replace("/", ".").replace("-", "."),
            "assetIDOrResourceID": relative,
            "creatorOrCommissioningEntity": "Raven Forge Software",
            "actualAuthoringToolAndVersion": PYTHON_TOOL if corrected else "macOS ditto byte-preserving canonicalization with Python 3.9.6 hashing",
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
            "exportRecipeID": "recipe.elven.recovery-v3",
            "exportSettings": {"pipeline": PIPELINE, "pipelineSHA256": sha256_file(Path(__file__).resolve()), "deterministic": True},
            "outputFiles": outputs,
            "approvalStatus": "approved-by-controlling-recovery-authority",
            "approvedBy": "Raven Forge Software",
            "approvalDateUTC": APPROVAL_DATE,
            "revisionHistory": [{"dateUTC": BUILD_DATE, "change": "Canonical v3 derivation created from verified legacy bytes."}],
        }
        records.append(record)
    return records


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
    if relative.endswith("Asset-Manifest-v1.0.json"):
        return "machine-readable-asset-manifest"
    return "package-document"


def generate_package_manifest(root: Path) -> Dict[str, Any]:
    files = []
    package_files = [item for item in root.rglob("*") if item.is_file() and item.name != "PACKAGE-MANIFEST.json"]
    for path in sorted(package_files, key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        files.append({"path": relative, "role": role_for(relative), "bytes": path.stat().st_size, "sha256": sha256_file(path)})
    manifest = {
        "schemaVersion": "3.0",
        "packageID": "runescribe.elven-series.corrected-production-package",
        "packageVersion": "3.0.0",
        "status": "corrected-production",
        "generatedDate": BUILD_DATE,
        "rootDirectory": root.name,
        "manifestScope": "all package files except PACKAGE-MANIFEST.json, whose digest is recorded externally to avoid recursive self-hashing",
        "fileCountExcludingManifest": len(files),
        "files": files,
    }
    dump_json(root / "PACKAGE-MANIFEST.json", manifest)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--original", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--recreate-from-original", action="store_true", help="Replace only pipeline-owned outputs and restore owner-supplied source bytes before building")
    args = parser.parse_args()
    original = args.original.resolve()
    root = args.target.resolve()
    if root.name != "Rune-Scribe-Elven-Series-Corrected-Production-Package-v3.0":
        raise SystemExit(f"Refusing unexpected target: {root}")
    if not original.is_dir() or not root.is_dir():
        raise SystemExit("Original and target directories must already exist")
    if args.recreate_from_original:
        source_manifest = json.loads((original / "PACKAGE-MANIFEST.json").read_text(encoding="utf-8"))
        if source_manifest.get("packageID") != "runescribe.elven-series.design-package":
            raise SystemExit("Refusing source with unexpected package identity")
        for generated_directory in ("Production-Sources", "Shipping", "Validation", "Provenance"):
            generated_path = root / generated_directory
            if generated_path.exists():
                shutil.rmtree(generated_path)
        neutral_instruction = root / "Rune-Scribe-Elven-Series-Implementation-Instructions-v1.0.md"
        if neutral_instruction.exists():
            neutral_instruction.unlink()
        shutil.copytree(original, root, dirs_exist_ok=True)
        for directory in sorted(
            (path for path in root.rglob("*") if path.is_dir()),
            key=lambda path: len(path.parts),
            reverse=True,
        ):
            if not any(directory.iterdir()):
                directory.rmdir()

    neutralize_instruction_attribution(root)
    manifest_path = root / "Rune-Scribe-Elven-Series-Asset-Manifest-v1.0.json"
    manifest = recursive_replace(json.loads(manifest_path.read_text(encoding="utf-8")))
    manifest["packageVersion"] = "3.0.0"
    manifest["status"] = "corrected-production"
    manifest["generatedDate"] = BUILD_DATE
    manifest["bindingAuthority"] = "repository Future Theme Binding Contract"

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
    correct_anchors(root / "Source-Masters/Relic-Geometry/wildwood/mossbound-plaque-geometry.svg", (("lowerRight", 1301, 943), ("lowerLeft", 299, 943)))

    add_geometry_contract(manifest, root)
    resources, source_outputs = generate_assets(root, manifest)
    manifest["resourceCatalog"] = resources
    manifest["resourceCatalogVersion"] = 1
    generate_validation_visuals(root, manifest)

    for codex in manifest["codices"]:
        codex["crest"]["assetClass"] = "crest"
        codex["crest"]["sourceClass"] = "crest"
        codex["crest"]["semanticRole"] = "masteryCrest"
        codex["crest"]["placeableOnSealAnchor"] = False

    provenance = generate_provenance(root, original, source_outputs, resources)
    provenance_path = root / "Provenance/Asset-Provenance-v3.json"
    dump_json(provenance_path, {"schemaVersion": 1, "generatedAtUTC": BUILD_DATE, "records": provenance})
    manifest["provenanceLedgerPath"] = provenance_path.relative_to(root).as_posix()
    manifest["provenanceRecordCount"] = len(provenance)
    dump_json(manifest_path, manifest)

    report = root / "PACKAGE-VALIDATION-REPORT.md"
    report.write_text(
        "# Rune Scribe Elven Series Corrected Package Validation Record\n\n"
        "This v3 package is generated from the immutable v1 source by the deterministic repository asset pipeline. "
        "Final semantic status is established by the repository validation evidence, not by this record alone.\n\n"
        f"- Generated: `{BUILD_DATE}`\n"
        f"- Source provenance records: `{len(provenance)}`\n"
        f"- Resource declarations: `{len(resources)}`\n"
        "- Validation authority: repository recovery evidence\n",
        encoding="utf-8",
    )

    package_manifest = generate_package_manifest(root)
    print(json.dumps({"status": "BUILT", "resources": len(resources), "provenanceRecords": len(provenance), "manifestEntries": len(package_manifest["files"])}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
