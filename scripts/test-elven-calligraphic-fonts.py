#!/usr/bin/env python3
"""Check the four compiled calligraphic scripts and reproducible sources."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile

from fontTools.ttLib import TTFont


ROOT = Path(__file__).resolve().parent.parent
GENERATOR = ROOT / "scripts/make-elven-calligraphic-fonts.py"
THEMES = {
    "moonleaf": "RuneScribeThemeMoonleafModule",
    "sunspire": "RuneScribeThemeSunspireModule",
    "wildwood": "RuneScribeThemeWildwoodModule",
    "gloamthorn": "RuneScribeThemeGloamthornModule",
}
EXPECTED_CODEPOINTS = set(range(0x16A0, 0x16C0))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_font(slug: str, path: Path) -> None:
    font = TTFont(path)
    cmap = font.getBestCmap()
    assert set(cmap) == EXPECTED_CODEPOINTS, f"{slug}: incomplete transport alphabet"
    assert font["name"].getDebugName(6) == f"RavenForge{slug.title()}Script-Regular"
    assert font["head"].unitsPerEm == 1000
    assert all(font["glyf"][name].numberOfContours > 4 for name in cmap.values())
    assert len({font["glyf"][name].compile(font["glyf"]) for name in cmap.values()}) == 32
    assert all(font["glyf"][name].yMin < 0 for name in cmap.values())


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="RuneScribe-Font-Check-") as temporary:
        output = Path(temporary)
        subprocess.run(
            [sys.executable, str(GENERATOR), "--output-directory", str(output)],
            check=True,
        )
        hashes = set()
        for slug, module in THEMES.items():
            production = (
                ROOT / "Packages/RuneScribeArchitecture/Sources" / module
                / "Resources/Production/script"
            )
            for suffix in (
                "primary.ttf", "specimen.png",
                "specimen-high-contrast.png", "static-fallback.png",
            ):
                name = f"{slug}-script-{suffix}"
                assert sha256(output / name) == sha256(production / name), name
            font_path = production / f"{slug}-script-primary.ttf"
            verify_font(slug, font_path)
            hashes.add(sha256(font_path))
        assert len(hashes) == len(THEMES), "theme-specific font outlines collapsed"
    print("Elven calligraphic font checks passed: four reproducible fonts, 32 glyphs each.")


if __name__ == "__main__":
    main()
