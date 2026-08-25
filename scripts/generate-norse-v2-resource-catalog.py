#!/usr/bin/env python3
"""Generate the exact Norse v2 resource catalog, integrity record, and pins."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import sys
from typing import Any

from PIL import Image


MODULE_ID = "com.runescribe.module.theme.norse"
RESOURCE_ROOT_RELATIVE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources"
)
PRODUCTION_RELATIVE = RESOURCE_ROOT_RELATIVE / "Production"
INTEGRITY_BASENAME = "Norse-Resource-Integrity-Manifest-v2.0.json"
INTEGRITY_RELATIVE = PRODUCTION_RELATIVE / "Metadata" / INTEGRITY_BASENAME
MODULE_MANIFEST_RELATIVE = RESOURCE_ROOT_RELATIVE / "module-manifest.json"
APPLICATION_CATALOG_RELATIVE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
    "NorseApplicationResourceCatalog.swift"
)
PINS_RELATIVE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "NorseV2ResourcePins.swift"
)
PROVENANCE_BASENAMES = {
    "Norse-Production-Asset-Provenance-v2.0.json",
}

MEDIA_BY_EXTENSION = {
    "json": "application/json",
    "pdf": "application/pdf",
    "png": "image/png",
    "ttf": "font/ttf",
    "wav": "audio/wav",
}


@dataclass(frozen=True)
class ResourceSpec:
    handle: str
    role: str
    relative_path: str
    required: bool = True

    @property
    def path(self) -> Path:
        return Path(self.relative_path)

    @property
    def extension(self) -> str:
        return self.path.suffix.removeprefix(".")

    @property
    def application_name(self) -> str:
        return self.path.stem

    @property
    def media_type(self) -> str:
        return MEDIA_BY_EXTENSION[self.extension]


def spec(handle: str, role: str, path: str, required: bool = True) -> ResourceSpec:
    return ResourceSpec(handle, role, path, required)


def resource_specs() -> tuple[ResourceSpec, ...]:
    values: list[ResourceSpec] = []
    for slug in ("runestone-tablet", "dragonwood-plaque", "stormforged-stele"):
        prefix = f"resource.relic.norse.{slug}"
        values.extend(
            (
                spec(prefix + ".master", "relic.master", f"Production/Relics/relic.norse.{slug}.png"),
                spec(prefix + ".thumbnail", "relic.thumbnail", f"Production/Relics/relic.norse.{slug}.thumbnail.png"),
                spec(prefix + ".static-share-fallback", "relic.static-share-fallback", f"Production/ShareFallbacks/share-fallback.norse.{slug}.png"),
                spec(prefix + ".high-contrast", "relic.high-contrast", f"Production/Relics/relic.norse.{slug}.high-contrast.png"),
                spec(prefix + ".geometry", "relic.geometry", f"Production/Geometry/relic.norse.{slug}.geometry.json"),
            )
        )

    for slug in ("valknut", "ravenshield", "mjolnir", "wolkin", "yggdrasil", "berserk"):
        prefix = f"resource.seal.norse.{slug}"
        values.extend(
            (
                spec(prefix + ".vector-master", "seal.vector-master", f"Production/Seals/seal.norse.{slug}.vector-master.pdf"),
                spec(prefix + ".monochrome-fallback", "seal.monochrome-fallback", f"Production/Seals/seal.norse.{slug}.monochrome.png"),
                spec(prefix + ".thumbnail", "seal.thumbnail", f"Production/Seals/seal.norse.{slug}.thumbnail.png"),
            )
        )

    values.extend(
        (
            spec("resource.frame.norse.carved-knotwork.vector-master", "frame.vector-master", "Production/Frame/frame.norse.carved-knotwork.vector-master.pdf"),
            spec("resource.frame.norse.carved-knotwork.static-fallback", "frame.static-fallback", "Production/Frame/frame.norse.carved-knotwork.static-fallback.png"),
            spec("resource.crest.norse.raven-mastery.vector-master", "crest.vector-master", "Production/Crest/crest.norse.raven-mastery.vector-master.pdf"),
            spec("resource.crest.norse.raven-mastery.static-fallback", "crest.static-fallback", "Production/Crest/crest.norse.raven-mastery.static-fallback.png"),
            spec("resource.crest.norse.raven-mastery.thumbnail", "crest.thumbnail", "Production/Crest/crest.norse.raven-mastery.thumbnail.png"),
            spec("resource.background.norse.cold-sea-hall.standard", "background.static-base", "Production/Background/background.norse.cold-sea-hall.standard.png"),
            spec("resource.background.norse.cold-sea-hall.reduce-motion", "background.reduce-motion", "Production/Background/background.norse.cold-sea-hall.reduce-motion.png"),
            spec("resource.background.norse.cold-sea-hall.high-contrast", "background.high-contrast", "Production/Background/background.norse.cold-sea-hall.high-contrast.png"),
            spec("resource.background.norse.cold-sea-hall.macos-wide-crop", "background.macos-wide-crop", "Production/Background/background.norse.cold-sea-hall.macos-wide-crop.png"),
        )
    )

    for state, role in (
        ("owned", "vault.card"),
        ("locked", "vault.locked-silhouette"),
        ("encountered", "vault.encountered"),
        ("selected", "vault.selected"),
        ("unavailable", "vault.unavailable"),
    ):
        values.append(
            spec(
                f"resource.codex-card.norse.{state}",
                role,
                f"Production/CodexCard/codex-card.norse.{state}.png",
            )
        )

    for variant in ("card-border", "corner-ornament", "divider", "primary-button", "tab-selector"):
        values.append(
            spec(
                f"resource.panel.norse.{variant}",
                f"panel.{variant}",
                f"Production/Panel/panel.norse.{variant}.png",
            )
        )

    values.extend(
        (
            spec("resource.font.norse.noto-sans-runic", "script.font", "NotoSansRunic-Regular.ttf"),
            spec("resource.script.norse.mapping", "script.mapping", "Production/Metadata/Norse-Script-Mapping-v1.0.json"),
            spec("resource.script.norse.specimen.standard", "script.specimen-standard", "Production/Script/script.base-runes.specimen.standard.png"),
            spec("resource.script.norse.specimen.high-contrast", "script.specimen-high-contrast", "Production/Script/script.base-runes.specimen.high-contrast.png"),
            spec("resource.script.norse.specimen.static-fallback", "script.static-fallback", "Production/Script/script.base-runes.specimen.static-fallback.png"),
            spec("resource.accessibility.norse.en", "accessibility-localization", "Production/Localization/norse-accessibility.en.json"),
            spec("resource.localization.norse.en", "localization.strings", "Production/Localization/norse-content.en.json"),
            spec("resource.palette.norse.semantic", "semantic-palette", "Production/Metadata/Norse-Semantic-Palette-v1.0.json"),
            spec("resource.headings.norse", "decorative-heading-catalog", "Production/Metadata/Norse-Decorative-Heading-Slots-v1.0.json"),
            spec("resource.progression-bindings.norse", "progression-binding-catalog", "Production/Metadata/Norse-Progression-Bindings-v2.0.json"),
        )
    )

    for tier in ("minor", "relic", "codex", "mastery"):
        values.extend(
            (
                spec(f"resource.sound.norse.unlock-{tier}", "unlock-sound", f"Production/Audio/sound.norse.unlock-{tier}.wav"),
                spec(f"resource.effect.norse.reveal-{tier}", "unlock-animation-cue", f"Production/Animation/effect.norse.reveal-{tier}.json"),
            )
        )

    ordered = tuple(sorted(values, key=lambda value: value.handle))
    if len(ordered) != 70:
        raise ValueError(f"Norse v2 resource inventory must contain 70 entries, got {len(ordered)}")
    if len({value.handle for value in ordered}) != len(ordered):
        raise ValueError("duplicate Norse v2 resource handle")
    if len({value.relative_path for value in ordered}) != len(ordered):
        raise ValueError("duplicate Norse v2 resource path")
    if len({(value.application_name, value.extension) for value in ordered}) != len(ordered):
        raise ValueError("colliding flattened Norse v2 resource basename")
    return ordered


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def png_metadata(path: Path) -> tuple[dict[str, int], str, bool]:
    with Image.open(path) as image:
        image.verify()
    with Image.open(path) as image:
        if image.format != "PNG":
            raise ValueError(f"invalid PNG resource: {path}")
        alpha = "A" in image.getbands()
        return {"width": image.width, "height": image.height}, image.mode, alpha


def integrity_resource(root: Path, value: ResourceSpec) -> dict[str, Any]:
    path = root / RESOURCE_ROOT_RELATIVE / value.path
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"missing regular Norse v2 resource: {value.relative_path}")
    result: dict[str, Any] = {
        "resourceHandle": value.handle,
        "path": value.relative_path,
        "semanticRole": value.role,
        "mediaType": value.media_type,
        "byteLength": path.stat().st_size,
        "sha256": sha256_file(path),
        "requiredForActiveContent": value.required,
        "activeInCurrentCatalog": True,
    }
    if value.extension == "png":
        dimensions, color_mode, alpha = png_metadata(path)
        result["dimensions"] = dimensions
        result["colorMode"] = color_mode
        result["hasAlpha"] = alpha
    return result


def ensure_exact_files(root: Path, specs: tuple[ResourceSpec, ...]) -> None:
    resource_root = root / RESOURCE_ROOT_RELATIVE
    expected = {value.path for value in specs}
    actual = {
        path.relative_to(resource_root)
        for path in resource_root.rglob("*")
        if path.is_file()
        and not path.is_symlink()
        and "Source" not in path.relative_to(resource_root).parts
        and path.relative_to(resource_root) != Path("module-manifest.json")
        and path.name not in PROVENANCE_BASENAMES
        and path.name != INTEGRITY_BASENAME
    }
    missing = sorted(str(path) for path in expected - actual)
    extra = sorted(str(path) for path in actual - expected)
    if missing or extra:
        parts = []
        if missing:
            parts.append("missing: " + ", ".join(missing))
        if extra:
            parts.append("unexpected: " + ", ".join(extra))
        raise ValueError("Norse v2 shipping file set differs; " + "; ".join(parts))


def manifest_document(resources: list[dict[str, Any]]) -> dict[str, Any]:
    static_bytes = sum(
        value["byteLength"]
        for value in resources
        if value["mediaType"] in {"image/png", "application/pdf"}
    )
    font_bytes = sum(value["byteLength"] for value in resources if value["mediaType"] == "font/ttf")
    sound_bytes = sum(value["byteLength"] for value in resources if value["mediaType"] == "audio/wav")
    animation_bytes = sum(value["byteLength"] for value in resources if value["semanticRole"] == "unlock-animation-cue")
    return {
        "schemaVersion": "2.0",
        "manifestID": "norse-resource-integrity.v2",
        "moduleID": MODULE_ID,
        "generationScope": "Exact Norse v2 production resources derived from the controlling visual authority; distribution is not authorized.",
        "formatPolicy": {
            "colorSpace": "sRGB",
            "raster": "lossless PNG",
            "vectorContract": "lossless raster PDF wrapper where a faithful vector source is unavailable",
            "metadata": "nonessential authoring metadata stripped",
        },
        "sourceOnlyExclusions": [
            "Resources/Source",
            "docs/verification/theme-fidelity-v4/source-masters",
            "docs/verification/theme-fidelity-v4/generated",
        ],
        "budgetSummary": {
            "uniquePhysicalBytes": sum(value["byteLength"] for value in resources),
            "staticImageBytes": static_bytes,
            "fontBytes": font_bytes,
            "animationBytes": animation_bytes,
            "soundBytes": sound_bytes,
            "largestResourceBytes": max(value["byteLength"] for value in resources),
        },
        "resources": resources,
    }


def encoded_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=False, ensure_ascii=False) + "\n").encode("utf-8")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        temporary.write_bytes(data)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def application_catalog_source(specs: tuple[ResourceSpec, ...]) -> str:
    mappings = "\n".join(
        f'        "{value.handle}": resource("{value.application_name}", "{value.extension}"),'
        for value in specs
    )
    return f'''public enum NorseApplicationResourceCatalog {{
    public static let moduleManifest = resource("module-manifest", "json")
    public static let integrityManifest = resource("{Path(INTEGRITY_BASENAME).stem}", "json")
    public static let notoSansRunic = resource("NotoSansRunic-Regular", "ttf")

    public static let resourcesByHandle: [String: ApplicationResource] = [
{mappings}
    ]

    private static func resource(_ name: String, _ fileExtension: String) -> ApplicationResource {{
        ApplicationResource(
            name: name,
            fileExtension: fileExtension,
            ownerModuleID: RuneScribeModuleIDs.norseTheme
        )
    }}
}}
'''


def pins_source(resources: list[dict[str, Any]], integrity_data: bytes) -> str:
    rows: list[str] = []
    for value in resources:
        dimensions = value.get("dimensions")
        if dimensions:
            dimension_source = (
                ".init(width: " + str(dimensions["width"])
                + ", height: " + str(dimensions["height"]) + ")"
            )
        else:
            dimension_source = "nil"
        rows.append(
            "        Resource("
            f'resourceHandle: "{value["resourceHandle"]}", '
            f'semanticRole: "{value["semanticRole"]}", '
            f'mediaType: "{value["mediaType"]}", '
            f'byteLength: {value["byteLength"]}, '
            f'sha256: "{value["sha256"]}", '
            f'requiredForActiveContent: {str(value["requiredForActiveContent"]).lower()}, '
            f"dimensions: {dimension_source}),"
        )
    joined = "\n".join(rows)
    return f'''import Foundation

enum NorseV2ResourcePins {{
    static let resourceCount = {len(resources)}
    static let integrityManifestByteCount = {len(integrity_data)}
    static let integrityManifestSHA256 = "{hashlib.sha256(integrity_data).hexdigest()}"
}}

extension NorseProductionManifest {{
    static let frozenResources: [Resource] = [
{joined}
    ]
}}
'''


def update_module_manifest(root: Path, specs: tuple[ResourceSpec, ...]) -> None:
    path = root / MODULE_MANIFEST_RELATIVE
    document = json.loads(path.read_text(encoding="utf-8"))
    required = [
        {
            "name": "module-manifest",
            "fileExtension": "json",
            "subdirectory": None,
            "ownerModuleID": MODULE_ID,
        },
        {
            "name": Path(INTEGRITY_BASENAME).stem,
            "fileExtension": "json",
            "subdirectory": None,
            "ownerModuleID": MODULE_ID,
        },
    ]
    required.extend(
        {
            "name": value.application_name,
            "fileExtension": value.extension,
            "subdirectory": None,
            "ownerModuleID": MODULE_ID,
        }
        for value in specs
    )
    document["runtimeRequirements"]["requiredResources"] = required
    atomic_write(path, encoded_json(document))


def generate(root: Path) -> None:
    specs = resource_specs()
    ensure_exact_files(root, specs)
    resources = [integrity_resource(root, value) for value in specs]
    integrity_data = encoded_json(manifest_document(resources))
    atomic_write(root / INTEGRITY_RELATIVE, integrity_data)
    atomic_write(
        root / APPLICATION_CATALOG_RELATIVE,
        application_catalog_source(specs).encode("utf-8"),
    )
    atomic_write(root / PINS_RELATIVE, pins_source(resources, integrity_data).encode("utf-8"))
    update_module_manifest(root, specs)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        generate(arguments.root.resolve())
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Generated exact 70-resource Norse v2 catalog and integrity pins")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
