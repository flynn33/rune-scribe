#!/usr/bin/env python3
"""Refresh the four generated Elven script pins after rebuilding the fonts."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
THEMES = ("moonleaf", "sunspire", "wildwood", "gloamthorn")
SUFFIXES = (
    "primary.ttf", "specimen-high-contrast.png", "specimen.png",
    "static-fallback.png",
)


def replace_one(source: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, source, count=1, flags=re.DOTALL)
    if count != 1:
        raise ValueError(f"Expected one {label}; found {count}")
    return updated


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    for slug in THEMES:
        title = slug.title()
        module = ROOT / "Packages/RuneScribeArchitecture/Sources" / f"RuneScribeTheme{title}Module"
        production = module / "Resources/Production"
        manifest_path = production / "Resource-Integrity-Manifest-v1.0.json"
        pins_path = module / f"{title}V43ResourcePins.swift"
        manifest = manifest_path.read_text()
        pins = pins_path.read_text()
        byte_delta = 0
        for suffix in SUFFIXES:
            name = f"{slug}-script-{suffix}"
            relative = f"Production/script/{name}"
            file = production / "script" / name
            new_bytes = file.stat().st_size
            new_sha = digest(file)
            path_text = f'"path": "{relative}"'
            path_index = manifest.find(path_text)
            if path_index < 0:
                raise ValueError(f"Missing manifest entry: {relative}")
            object_start = manifest.rfind("{", 0, path_index)
            object_end = manifest.find("}", path_index) + 1
            if object_start < 0 or object_end < 1:
                raise ValueError(f"Malformed manifest entry: {relative}")
            entry = manifest[object_start:object_end]
            old_count = re.search(r'"bytes": (\d+)', entry)
            if old_count is None:
                raise ValueError(f"Missing byte count: {relative}")
            byte_delta += new_bytes - int(old_count.group(1))
            entry = replace_one(
                entry, r'("bytes": )\d+', rf'\g<1>{new_bytes}',
                f"{relative} bytes",
            )
            entry = replace_one(
                entry, r'("sha256": ")[0-9a-f]+(")',
                rf'\g<1>{new_sha}\g<2>', f"{relative} hash",
            )
            manifest = manifest[:object_start] + entry + manifest[object_end:]
            pin_pattern = (
                rf'(relativePath: "{re.escape(relative)}",\n.*?sha256Hex: ")'
                rf'[0-9a-f]+(",\n\s+byteCount: )\d+'
            )
            pins = replace_one(
                pins, pin_pattern,
                rf'\g<1>{new_sha}\g<2>{new_bytes}', relative,
            )
        manifest_path.write_text(manifest)
        pins = replace_one(
            pins, r'(integrityManifestByteCount = )\d+',
            rf'\g<1>{manifest_path.stat().st_size}', f"{slug} manifest byte pin",
        )
        pins = replace_one(
            pins, r'(integrityManifestSHA256Hex = ")[0-9a-f]+(")',
            rf'\g<1>{digest(manifest_path)}\g<2>', f"{slug} manifest hash pin",
        )
        shipping = re.search(r'productionShippingByteCount = (\d+)', pins)
        if shipping is None:
            raise ValueError(f"Missing shipping byte pin: {slug}")
        pins = replace_one(
            pins, r'(productionShippingByteCount = )\d+',
            rf'\g<1>{int(shipping.group(1)) + byte_delta}',
            f"{slug} shipping byte pin",
        )
        pins_path.write_text(pins)
        print(f"{title}: four script resources pinned; shipping delta {byte_delta:+d}")

    moonleaf = (
        ROOT / "Packages/RuneScribeArchitecture/Sources"
        / "RuneScribeThemeMoonleafModule/Resources/Production/script/moonleaf-script-primary.ttf"
    )
    parity_path = ROOT / "RuneScribMacParityTests/RuneScribeMacParityTests.swift"
    parity = parity_path.read_text()
    parity = replace_one(
        parity, r'(moonleafFontByteCount = )[\d_]+',
        rf'\g<1>{moonleaf.stat().st_size}', "macOS Moonleaf byte pin",
    )
    parity = replace_one(
        parity, r'(moonleafFontSHA256Hex =\n\s+")[0-9a-f]+(")',
        rf'\g<1>{digest(moonleaf)}\g<2>', "macOS Moonleaf hash pin",
    )
    parity_path.write_text(parity)


if __name__ == "__main__":
    main()
