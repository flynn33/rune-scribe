#!/usr/bin/env python3
"""Build original calligraphic outlines for the four Elven Codex scripts.

The transport alphabet remains U+16A0 through U+16BF.  Each glyph is drawn
as a variable-width pen outline, rather than relying on a runic system font.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from PIL import Image, ImageDraw, ImageFont


UNITS_PER_EM = 1000
ADVANCE = 760
FIRST_CODEPOINT = 0x16A0
GLYPH_COUNT = 32
TIMESTAMP = 3870504000  # Fixed epoch for deterministic font bytes.

THEMES = {
    "moonleaf": ("RavenForgeMoonleafScript-Regular", 1.28, 0.00, 0.00),
    "sunspire": ("RavenForgeSunspireScript-Regular", 1.38, 0.05, 0.00),
    "wildwood": ("RavenForgeWildwoodScript-Regular", 1.22, -0.04, 0.05),
    "gloamthorn": ("RavenForgeGloamthornScript-Regular", 1.32, 0.02, -0.05),
}
MODULES = {
    "moonleaf": "RuneScribeThemeMoonleafModule",
    "sunspire": "RuneScribeThemeSunspireModule",
    "wildwood": "RuneScribeThemeWildwoodModule",
    "gloamthorn": "RuneScribeThemeGloamthornModule",
}
SPECIMEN_COLORS = {
    "moonleaf": "#D5F6E9",
    "sunspire": "#FFF0BE",
    "wildwood": "#D9E9C9",
    "gloamthorn": "#E8D8F4",
}


def bezier(points: tuple[tuple[float, float], ...], t: float) -> tuple[float, float]:
    p0, p1, p2, p3 = points
    u = 1 - t
    return (
        u**3 * p0[0] + 3 * u**2 * t * p1[0] + 3 * u * t**2 * p2[0] + t**3 * p3[0],
        u**3 * p0[1] + 3 * u**2 * t * p1[1] + 3 * u * t**2 * p2[1] + t**3 * p3[1],
    )


def tangent(points: tuple[tuple[float, float], ...], t: float) -> tuple[float, float]:
    p0, p1, p2, p3 = points
    u = 1 - t
    return (
        3 * u**2 * (p1[0] - p0[0]) + 6 * u * t * (p2[0] - p1[0]) + 3 * t**2 * (p3[0] - p2[0]),
        3 * u**2 * (p1[1] - p0[1]) + 6 * u * t * (p2[1] - p1[1]) + 3 * t**2 * (p3[1] - p2[1]),
    )


def polygon(pen: TTGlyphPen, points: list[tuple[float, float]]) -> None:
    if len(points) < 3:
        return
    pen.moveTo(tuple(round(value) for value in points[0]))
    for point in points[1:]:
        pen.lineTo(tuple(round(value) for value in point))
    pen.closePath()


def pen_curve(
    pen: TTGlyphPen,
    control: tuple[tuple[float, float], ...],
    width: float,
    *,
    samples: int = 25,
    taper_start: bool = True,
    taper_end: bool = True,
) -> None:
    """Turn a flowing centerline into a tapered broad-pen contour."""
    left: list[tuple[float, float]] = []
    right: list[tuple[float, float]] = []
    for step in range(samples + 1):
        t = step / samples
        x, y = bezier(control, t)
        dx, dy = tangent(control, t)
        length = max(1.0, math.hypot(dx, dy))
        nx, ny = -dy / length, dx / length
        begin = min(1.0, t * 7 + 0.08) if taper_start else 1.0
        end = min(1.0, (1 - t) * 7 + 0.08) if taper_end else 1.0
        nib_angle = 0.72 + 0.28 * abs(nx * 0.6 + ny * 0.8)
        half = width * begin * end * nib_angle / 2
        left.append((x + nx * half, y + ny * half))
        right.append((x - nx * half, y - ny * half))
    polygon(pen, left + list(reversed(right)))


def oval(pen: TTGlyphPen, x: float, y: float, rx: float, ry: float) -> None:
    outer = [
        (x + rx * math.cos(step * math.tau / 20), y + ry * math.sin(step * math.tau / 20))
        for step in range(20)
    ]
    polygon(pen, outer)


def teardrop(pen: TTGlyphPen, x: float, y: float, size: float) -> None:
    polygon(pen, [
        (x, y + size * 1.3),
        (x + size * 0.8, y + size * 0.15),
        (x + size * 0.5, y - size * 0.85),
        (x, y - size),
        (x - size * 0.55, y - size * 0.75),
        (x - size * 0.7, y + size * 0.15),
    ])


def draw_glyph(index: int, weight: float, arch: float, slant: float):
    pen = TTGlyphPen(None)
    family = index % 8
    mark = index // 8
    bend = (family - 3.5) * 7 + arch * 80
    lean = slant * 90

    # Entry and exit tails establish a handwriting rhythm in adjacent glyphs.
    pen_curve(pen, ((28, 245), (110, 225), (150, 350), (258, 359)), 18 * weight)
    pen_curve(pen, ((475, 319), (565, 268), (658, 340), (744, 365)), 18 * weight)

    # The tall, slanted principal stroke and its curled cap define the script.
    pen_curve(
        pen,
        ((214 + lean, -118), (330 + bend, 178), (275 + bend, 608), (425 + lean, 866)),
        32 * weight,
        samples=39,
    )
    pen_curve(pen, ((425 + lean, 866), (475, 803), (383, 752), (323, 793)), 19 * weight)

    if family == 0:  # Single open bowl with a small returning eye.
        pen_curve(pen, ((256, 360), (394, 568), (652, 571), (623, 369)), 29 * weight)
        pen_curve(pen, ((623, 369), (610, 246), (472, 219), (392, 330)), 22 * weight)
        pen_curve(pen, ((392, 330), (336, 421), (497, 460), (509, 351)), 15 * weight)
    elif family == 1:  # Two overlapping bowls.
        pen_curve(pen, ((283, 459), (367, 628), (557, 610), (578, 448)), 24 * weight)
        pen_curve(pen, ((340, 314), (468, 482), (661, 435), (586, 249)), 27 * weight)
        pen_curve(pen, ((586, 249), (495, 164), (406, 240), (456, 354)), 17 * weight)
    elif family == 2:  # Leftward curl and descending flourish.
        pen_curve(pen, ((317, 473), (128, 653), (42, 376), (232, 374)), 26 * weight)
        pen_curve(pen, ((232, 374), (380, 353), (513, 504), (575, 512)), 19 * weight)
        pen_curve(pen, ((575, 512), (666, 481), (658, 237), (486, 211)), 28 * weight)
    elif family == 3:  # Twin eyes and high sweeping terminal.
        pen_curve(pen, ((280, 403), (408, 641), (602, 553), (547, 391)), 28 * weight)
        pen_curve(pen, ((547, 391), (471, 266), (332, 385), (423, 491)), 19 * weight)
        pen_curve(pen, ((466, 349), (565, 503), (693, 411), (652, 253)), 22 * weight)
        pen_curve(pen, ((417, 680), (494, 770), (591, 732), (650, 790)), 14 * weight)
    elif family == 4:  # Extended undercurl and transverse pen stroke.
        pen_curve(pen, ((251, 445), (410, 619), (625, 520), (590, 355)), 27 * weight)
        pen_curve(pen, ((590, 355), (540, 128), (343, 183), (370, 339)), 23 * weight)
        pen_curve(pen, ((126, 220), (217, 90), (534, 143), (664, 161)), 17 * weight)
        pen_curve(pen, ((290, 589), (438, 649), (548, 632), (668, 640)), 13 * weight)
    elif family == 5:  # Open upper wing over a narrow lower bowl.
        pen_curve(pen, ((265, 532), (410, 765), (617, 654), (591, 502)), 25 * weight)
        pen_curve(pen, ((323, 327), (429, 480), (629, 431), (590, 261)), 29 * weight)
        pen_curve(pen, ((590, 261), (546, 181), (445, 194), (437, 294)), 18 * weight)
    elif family == 6:  # Crossed vine-like ligature.
        pen_curve(pen, ((224, 334), (406, 663), (683, 680), (630, 362)), 29 * weight)
        pen_curve(pen, ((630, 362), (588, 197), (361, 213), (451, 452)), 20 * weight)
        pen_curve(pen, ((300, 590), (404, 467), (514, 357), (632, 317)), 16 * weight)
        pen_curve(pen, ((479, 643), (535, 749), (633, 763), (688, 821)), 13 * weight)
    else:  # Long final flourish and spiral.
        pen_curve(pen, ((291, 489), (383, 657), (590, 603), (611, 438)), 26 * weight)
        pen_curve(pen, ((611, 438), (633, 284), (475, 252), (447, 355)), 21 * weight)
        pen_curve(pen, ((447, 355), (458, 433), (539, 431), (534, 372)), 15 * weight)
        pen_curve(pen, ((453, 212), (589, 99), (675, 184), (749, 220)), 18 * weight)

    # The four consonant series change the body as well as its tehta. This
    # keeps all 32 signs distinguishable at inscription size while preserving
    # the shared, flowing hand of the alphabet.
    if mark == 1:  # Descending return and a small open lower eye.
        pen_curve(pen, ((367, 282), (435, 133), (572, -164), (683, -141)), 24 * weight)
        pen_curve(pen, ((683, -141), (735, -129), (718, -55), (646, -66)), 15 * weight)
        pen_curve(pen, ((495, 72), (382, 45), (386, -55), (467, -81)), 14 * weight)
    elif mark == 2:  # Rising wing and a sweeping crossbar.
        pen_curve(pen, ((268, 594), (356, 773), (568, 859), (717, 789)), 23 * weight)
        pen_curve(pen, ((717, 789), (663, 744), (619, 773), (586, 817)), 13 * weight)
        pen_curve(pen, ((156, 436), (304, 489), (517, 462), (695, 550)), 21 * weight)
    elif mark == 3:  # Double spiral and long closing flourish.
        pen_curve(pen, ((297, 276), (213, 125), (368, 73), (441, 171)), 21 * weight)
        pen_curve(pen, ((441, 171), (520, 299), (624, 260), (576, 192)), 15 * weight)
        pen_curve(pen, ((484, 188), (590, 72), (699, 151), (754, 169)), 20 * weight)
        pen_curve(pen, ((219, 692), (259, 792), (390, 853), (502, 817)), 15 * weight)

    # Tehta-like accents are individual vector marks, not bitmap decorations.
    accent_x = 405 + family * 8
    if mark == 0:
        teardrop(pen, accent_x, 748, 15 * weight)
    elif mark == 1:
        teardrop(pen, accent_x - 29, 758, 13 * weight)
        teardrop(pen, accent_x + 28, 773, 13 * weight)
    elif mark == 2:
        teardrop(pen, accent_x - 37, 748, 11 * weight)
        teardrop(pen, accent_x, 782, 15 * weight)
        teardrop(pen, accent_x + 36, 747, 11 * weight)
    else:
        pen_curve(pen, ((accent_x - 66, 754), (accent_x - 12, 821), (accent_x + 43, 763), (accent_x + 82, 804)), 14 * weight)
        teardrop(pen, accent_x + 8, 830, 13 * weight)
    if family in (2, 5, 7):
        oval(pen, 485 + family * 2, 188, 9 * weight, 13 * weight)
    return pen.glyph()


def build_theme(slug: str, output: Path) -> None:
    postscript, weight, arch, slant = THEMES[slug]
    glyph_order = [".notdef"] + [f"uni{FIRST_CODEPOINT + index:04X}" for index in range(GLYPH_COUNT)]
    empty = TTGlyphPen(None)
    glyphs = {".notdef": empty.glyph()}
    glyphs.update({
        glyph_order[index + 1]: draw_glyph(index, weight, arch, slant)
        for index in range(GLYPH_COUNT)
    })
    builder = FontBuilder(UNITS_PER_EM, isTTF=True)
    builder.setupGlyphOrder(glyph_order)
    builder.setupCharacterMap({FIRST_CODEPOINT + index: glyph_order[index + 1] for index in range(GLYPH_COUNT)})
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({name: (ADVANCE, 0) for name in glyph_order})
    builder.setupHorizontalHeader(ascent=850, descent=-230, lineGap=50)
    family = postscript.removesuffix("-Regular")
    builder.setupNameTable({
        "familyName": family,
        "styleName": "Regular",
        "uniqueFontIdentifier": f"Raven Forge Software:{postscript}:calligraphic-1",
        "fullName": family,
        "psName": postscript,
        "version": "Version 1.0",
    })
    builder.setupOS2(
        sTypoAscender=850, sTypoDescender=-230, sTypoLineGap=50,
        usWinAscent=900, usWinDescent=230,
    )
    builder.setupPost()
    builder.setupMaxp()
    builder.font["head"].created = TIMESTAMP
    builder.font["head"].modified = TIMESTAMP
    output.parent.mkdir(parents=True, exist_ok=True)
    builder.save(str(output))


def build_specimen(slug: str, font_path: Path, output: Path, high_contrast: bool) -> None:
    image = Image.new("RGBA", (1600, 600), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    face = ImageFont.truetype(str(font_path), 102)
    ink = "#FFFFFF" if high_contrast else SPECIMEN_COLORS[slug]
    for row in range(2):
        for column in range(16):
            codepoint = FIRST_CODEPOINT + row * 16 + column
            x = 48 + column * 96
            y = 68 + row * 276
            draw.text((x, y), chr(codepoint), font=face, fill=ink)
    rule = "#FFFFFF" if high_contrast else ink
    draw.line((65, 291, 1535, 291), fill=rule, width=3)
    for x in (200, 500, 800, 1100, 1400):
        draw.ellipse((x - 6, 285, x + 6, 297), fill=rule)
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output, optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--output-directory", type=Path)
    group.add_argument("--repository-root", type=Path)
    args = parser.parse_args()
    for slug in THEMES:
        if args.repository_root is not None:
            output = (
                args.repository_root / "Packages/RuneScribeArchitecture/Sources"
                / MODULES[slug] / "Resources/Production/script"
            )
        else:
            output = args.output_directory
        font = output / f"{slug}-script-primary.ttf"
        build_theme(slug, font)
        standard = output / f"{slug}-script-specimen.png"
        build_specimen(slug, font, standard, False)
        build_specimen(slug, font, output / f"{slug}-script-specimen-high-contrast.png", True)
        build_specimen(slug, font, output / f"{slug}-script-static-fallback.png", False)


if __name__ == "__main__":
    main()
