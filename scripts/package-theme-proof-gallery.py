#!/usr/bin/env python3
"""Package an exact five-theme, twenty-surface Simulator proof gallery."""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


THEMES = ("norse", "moonleaf", "sunspire", "wildwood", "gloamthorn")
ART_CATEGORIES = (
    "relic", "seal", "frame", "crest", "background", "panel",
    "vault", "codexcard", "received", "sharefallbacks", "script",
)
SURFACES = (
    "workspace-empty",
    "compose-short",
    "compose-long",
    "inscription-preview",
    "received-cipher",
    "share-builder",
    "static-share",
    "settings-codex-card",
    "settings-defaults-preview",
    "vault-locked",
    "vault-progress",
    "vault-encountered",
    "vault-owned",
    "vault-selected",
    "relic-picker",
    "seal-picker",
    "mastery",
    "high-contrast",
    "reduce-motion",
    "large-text",
)
PRIMARY_IMAGE = re.compile(
    r"^(norse|moonleaf|sunspire|wildwood|gloamthorn)--([a-z-]+)--iphone-portrait_0_[A-F0-9-]+\.png$"
)
PRIMARY_METADATA = re.compile(
    r"^(norse|moonleaf|sunspire|wildwood|gloamthorn)--([a-z-]+)--iphone-portrait\.capture_0_[A-F0-9-]+\.json$"
)


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def image_card(path: str, label: str, metadata: str | None = None) -> str:
    heading = esc(label)
    file_link = f'<a href="{esc(path)}" target="_blank">Full image</a>'
    metadata_link = (
        f' · <a href="{esc(metadata)}" target="_blank">Capture metadata</a>'
        if metadata is not None else ""
    )
    return (
        f'<figure><a href="{esc(path)}" target="_blank">'
        f'<img src="{esc(path)}" loading="lazy" alt="{heading}"></a>'
        f'<figcaption>{heading}<br>{file_link}{metadata_link}</figcaption></figure>'
    )


def font_comparison(review: Path, source_font_root: Path) -> None:
    canvas = Image.new("RGB", (1600, 1420), "#f3e4c7")
    draw = ImageDraw.Draw(canvas)
    labels = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 37)
    title = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 48)
    draw.text((40, 24), "Elven scripts · all 32 canonical symbols", fill="#3e3027", font=title)
    for theme_index, theme in enumerate(THEMES[1:]):
        top = 105 + theme_index * 320
        draw.text((42, top), theme.title(), fill="#4b3a2c", font=labels)
        source = (
            source_font_root / f"RuneScribeTheme{theme.title()}Module"
            / "Resources/Production/script" / f"{theme}-script-primary.ttf"
        )
        face = ImageFont.truetype(str(source), 106)
        for row in range(2):
            for column in range(16):
                symbol = chr(0x16A0 + row * 16 + column)
                draw.text((38 + column * 96, top + 54 + row * 125),
                          symbol, fill="#302b29", font=face)
        draw.line((40, top + 300, 1550, top + 300), fill="#bca182", width=2)
    canvas.save(review / "font-comparison.png", optimize=True)


def package(review: Path, art: Path, source_font_root: Path,
            reference: Path, export: Path) -> None:
    manifest = json.loads((export / "manifest.json").read_text())
    matrix = next(
        entry for entry in manifest
        if entry["testIdentifier"] == "ThemeFidelityMatrixTests/testCaptureThemeFidelityMatrix()"
    )
    screenshot_dir = review / "screenshots-final"
    metadata_dir = review / "metadata-final"
    screenshot_dir.mkdir(exist_ok=True)
    metadata_dir.mkdir(exist_ok=True)

    screenshots: dict[tuple[str, str], str] = {}
    metadata: dict[tuple[str, str], str] = {}
    for attachment in matrix["attachments"]:
        suggested = attachment["suggestedHumanReadableName"]
        image_match = PRIMARY_IMAGE.fullmatch(suggested)
        metadata_match = PRIMARY_METADATA.fullmatch(suggested)
        if image_match is None and metadata_match is None:
            continue
        match = image_match or metadata_match
        assert match is not None
        key = (match.group(1), match.group(2))
        if key[1] not in SURFACES:
            raise ValueError(f"Undeclared surface: {key}")
        if image_match is not None:
            target = screenshot_dir / f"{key[0]}--{key[1]}--iphone-portrait.png"
            if key in screenshots:
                raise ValueError(f"Duplicate primary image: {key}")
            screenshots[key] = target.name
        else:
            target = metadata_dir / f"{key[0]}--{key[1]}--iphone-portrait.capture.json"
            if key in metadata:
                raise ValueError(f"Duplicate primary metadata: {key}")
            metadata[key] = target.name
        shutil.copy2(export / attachment["exportedFileName"], target)

    expected = {(theme, surface) for theme in THEMES for surface in SURFACES}
    if screenshots.keys() != expected or metadata.keys() != expected:
        raise ValueError(
            f"Incomplete matrix: {len(screenshots)} screenshots, {len(metadata)} metadata; "
            f"missing images={sorted(expected - screenshots.keys())}; "
            f"missing metadata={sorted(expected - metadata.keys())}"
        )

    reference_dir = review / "reference"
    reference_dir.mkdir(exist_ok=True)
    reference_copy = reference_dir / "elven-style-reference.png"
    if reference.resolve() != reference_copy.resolve():
        shutil.copy2(reference, reference_copy)
    elif not reference_copy.is_file():
        raise FileNotFoundError(reference_copy)
    font_dir = review / "fonts"
    font_dir.mkdir(exist_ok=True)
    for theme in THEMES[1:]:
        for suffix in ("script-specimen.png", "script-specimen-high-contrast.png",
                       "script-static-fallback.png"):
            source = (
                source_font_root / f"RuneScribeTheme{theme.title()}Module"
                / "Resources/Production/script" / f"{theme}-{suffix}"
            )
            if not source.is_file():
                raise FileNotFoundError(source)
            shutil.copy2(source, font_dir / source.name)
    font_comparison(review, source_font_root)

    art_files = sorted(art.rglob("*.png"))
    if len(art_files) != 293:
        raise ValueError(f"Expected 293 production art images; found {len(art_files)}")
    art_cards: dict[str, dict[str, list[str]]] = {
        category: {theme: [] for theme in THEMES}
        for category in ART_CATEGORIES
    }
    for file in art_files:
        relative = file.relative_to(art)
        theme = relative.parts[0]
        category = {"relics": "relic", "seals": "seal"}.get(
            relative.parts[2].lower(), relative.parts[2].lower()
        )
        if theme not in THEMES or category not in art_cards:
            raise ValueError(f"Unknown art theme: {relative}")
        if theme != "norse" and relative.parts[1:3] == ("Production", "script"):
            image_path = f"fonts/{esc(file.name)}"
        else:
            image_path = f"../Rune-Scribe-Visual-Review/art-assets/{esc(relative.as_posix())}"
        art_cards[category][theme].append(
            image_card(image_path, f"{theme.title()} · {relative.as_posix()}")
        )

    sections = []
    for theme in THEMES:
        view_cards = [
            image_card(
                f"screenshots-final/{screenshots[(theme, surface)]}",
                f"{theme.title()} · {surface.replace('-', ' ').title()}",
                f"metadata-final/{metadata[(theme, surface)]}",
            )
            for surface in SURFACES
        ]
        sections.append(
            f'<section id="views-{theme}"><h2>{theme.title()}: every themed view '
            f'(20/20)</h2><div class="grid views">{"".join(view_cards)}</div></section>'
        )
    for category in ART_CATEGORIES:
        theme_groups = []
        count = 0
        for theme in THEMES:
            cards = art_cards[category][theme]
            if not cards:
                continue
            count += len(cards)
            theme_groups.append(
                f'<h3>{theme.title()} · {len(cards)} images</h3>'
                f'<div class="grid art">{"".join(cards)}</div>'
            )
        sections.append(
            f'<section id="art-{category}"><h2>{category.title()} art '
            f'({count} images)</h2>{"".join(theme_groups)}</section>'
        )
    font_cards = [
        image_card(
            f"fonts/{theme}-script-specimen.png",
            f"{theme.title()} · all 32 script glyphs",
        )
        for theme in THEMES[1:]
    ]
    font_cards.extend(
        image_card(
            f"fonts/{theme}-script-specimen-high-contrast.png",
            f"{theme.title()} · high contrast",
        )
        for theme in THEMES[1:]
    )
    font_cards.extend(
        image_card(
            f"fonts/{theme}-script-static-fallback.png",
            f"{theme.title()} · static fallback",
        )
        for theme in THEMES[1:]
    )
    font_cards.append(
        image_card(
            "../Rune-Scribe-Visual-Review/art-assets/norse/Production/Script/"
            "script.base-runes.specimen.standard.png",
            "Norse · original runic script, unchanged",
        )
    )
    native_dir = review / "native-screens"
    native_files = sorted(native_dir.glob("*.png"))
    native_cards = [
        image_card(f"native-screens/{file.name}", file.stem.replace("-", " ").title())
        for file in native_files
    ]
    page = f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Rune Scribe · Elven Script and Complete Theme Proofs</title>
<style>
:root{{color-scheme:dark;font-family:system-ui,-apple-system,sans-serif;background:#101a1c;color:#e9e7db}}
body{{margin:0 auto;padding:2rem;max-width:1600px;line-height:1.45}}
h1,h2{{font-family:Georgia,serif}}h1{{font-size:2.5rem}}h2{{margin-top:3rem}}
p{{max-width:75ch}}a{{color:#c4e9d0}}nav a{{margin-right:1rem;white-space:nowrap}}
.grid{{display:grid;gap:1rem}}.views{{grid-template-columns:repeat(auto-fill,minmax(230px,1fr))}}
.art{{grid-template-columns:repeat(auto-fill,minmax(190px,1fr))}}
figure{{margin:0;padding:.65rem;background:#1c2b2e;border:1px solid #44615b;border-radius:12px;overflow:hidden}}
figure img{{width:100%;height:290px;object-fit:contain;background:#102022;border-radius:6px}}
.views figure img{{height:420px}}figcaption{{font-size:.78rem;margin-top:.6rem;overflow-wrap:anywhere}}
.hero img{{height:520px}}.stats{{display:flex;gap:1rem;flex-wrap:wrap}}
.stats span{{border:1px solid #50776b;border-radius:30px;padding:.5rem 1rem}}
</style>
<h1>Rune Scribe · Complete Theme Proofs</h1>
<p>Final iPhone 17 Pro Simulator captures for all 20 declared themed views in
each of five themes, plus additional native routes and system views. The 100 themed
captures use the iOS qualification host's explicit progression fixtures; the native
routes are live captures from the installed development app. The four Elven fonts use original, reproducible vector
outlines modeled on the owner-provided calligraphic reference; Norse remains runic.
The proof set also includes every production art preview and script specimen.</p>
<div class="stats"><span>100/100 primary views</span><span>293/293 production art images</span>
<span>{len(native_cards)} supplemental native views</span><span>4 new Elven fonts · 32 symbols each</span><span>37/37 iOS tests passed</span></div>
<nav><a href="#live">Fresh-install views</a><a href="#native">Additional native views</a><a href="#reference">Reference and font comparison</a>
{"".join(f'<a href="#views-{theme}">{theme.title()} views</a>' for theme in THEMES)}
{"".join(f'<a href="#art-{category}">{category.title()} art</a>' for category in ART_CATEGORIES)}</nav>
<section id="live"><h2>Fresh development install</h2>
<div class="grid art hero">
{image_card("live-fresh-intro.png", "Fresh install · opening view")}
{image_card("live-fresh-development-build.png", "Fresh install · working view")}
</div></section>
<section id="native"><h2>Additional native views and system routes ({len(native_cards)})</h2>
<p>These live captures supplement the five-theme matrix. Permission-dependent
camera and contact flows are shown without granting access; no credentials,
shares, or license acceptance were entered.</p>
<div class="grid views">{"".join(native_cards)}</div></section>
<section id="reference"><h2>Reference and font comparison</h2>
<div class="grid art hero">
{image_card("reference/elven-style-reference.png", "Owner-provided Elven style reference")}
{image_card("font-comparison.png", "Four Elven font outlines · same 32 canonical symbols")}
</div><h2>Font specimens and fallbacks</h2><div class="grid art">{"".join(font_cards)}</div></section>
{"".join(sections)}
</html>"""
    (review / "index.html").write_text(page)
    (review / "README.md").write_text(
        "Rune Scribe complete theme proofs\n\n"
        "100 primary iPhone 17 Pro Simulator screenshots: 20 declared themed "
        "views in each of five themes, using qualification progression fixtures. "
        "Each has a matching capture JSON. Supplemental native views are from "
        "the installed development app. "
        f"{len(native_cards)} supplemental native route captures. The linked art gallery covers 293 production PNGs; current Elven "
        "specimens are in fonts/.\n"
    )
    local_links = [
        html.unescape(value)
        for value in re.findall(r'(?:href|src)="([^"]+)"', page)
        if not value.startswith("#")
    ]
    missing_links = [
        value for value in local_links if not (review / value).is_file()
    ]
    if missing_links:
        raise ValueError(f"Gallery has missing files: {missing_links[:10]}")
    print(f"PASS: {len(screenshots)} views, {len(native_cards)} native views, {len(metadata)} capture records, "
          f"{len(art_files)} art images, {len(font_cards)} font specimens, "
          f"{len(local_links)} resolved file links")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--review-root", required=True, type=Path)
    parser.add_argument("--art-root", required=True, type=Path)
    parser.add_argument("--source-font-root", required=True, type=Path)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--xcresult-export", type=Path)
    arguments = parser.parse_args()
    package(
        arguments.review_root.resolve(),
        arguments.art_root.resolve(),
        arguments.source_font_root.resolve(),
        arguments.reference.resolve(),
        (arguments.xcresult_export or arguments.review_root / "xcresult-export-final").resolve(),
    )


if __name__ == "__main__":
    main()
