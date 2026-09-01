#!/usr/bin/env python3
"""Pinned v4.3 source-master loading and protected frame composition."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from PIL import Image, ImageEnhance, ImageOps


SOURCE_MASTER_ROOT = "docs/verification/theme-fidelity-v4-3/source-masters"


@dataclass(frozen=True)
class SourceMasterSpec:
    asset_id: str
    role: str
    relative_path: str
    sha256: str
    pixel_size: tuple[int, int]
    acceptance_record_path: str
    acceptance_record_sha256: str
    rights_id: str


@dataclass(frozen=True)
class SealSourceMasterSpec:
    theme: str
    slug: str
    relative_path: str
    sha256: str
    pixel_size: tuple[int, int]
    acceptance_record_path: str
    acceptance_record_sha256: str

    @property
    def seal_id(self) -> str:
        return f"seal.{self.theme}.{self.slug}"

    @property
    def rights_id(self) -> str:
        return accepted_recipe_rights_id(self.theme)


@dataclass(frozen=True)
class CapInsets:
    top: int
    left: int
    bottom: int
    right: int

    def as_dict(self) -> dict[str, int]:
        return {
            "bottom": self.bottom,
            "left": self.left,
            "right": self.right,
            "top": self.top,
        }


@dataclass(frozen=True)
class FrameSlicePolicy:
    source_cap_insets: CapInsets
    horizontal_sample: tuple[int, int]
    vertical_sample: tuple[int, int]


PANEL_TARGET_SIZES: Mapping[str, tuple[int, int]] = {
    "card-border": (1600, 1000),
    "corner-ornament": (512, 512),
    "divider": (1600, 128),
    "primary-button": (1200, 320),
    "tab-selector": (1000, 240),
}

# These pixel insets are the exact values applied by
# ThemeChromeNineSliceGeometry in the shared Swift presentation layer.
PANEL_CAP_INSETS: Mapping[str, CapInsets | None] = {
    "card-border": CapInsets(top=150, left=170, bottom=150, right=170),
    "corner-ornament": None,
    "divider": CapInsets(top=48, left=360, bottom=48, right=360),
    "primary-button": CapInsets(top=104, left=190, bottom=104, right=190),
    "tab-selector": CapInsets(top=76, left=170, bottom=76, right=170),
}

# Corners are isolated from the accepted source without mirroring. Quiet edge
# samples deliberately exclude protected corner and midpoint ornament before
# one-axis edge stretching.
FRAME_SLICE_POLICIES: Mapping[str, FrameSlicePolicy] = {
    "moonleaf": FrameSlicePolicy(
        source_cap_insets=CapInsets(top=280, left=360, bottom=280, right=360),
        horizontal_sample=(600, 936),
        vertical_sample=(400, 624),
    ),
    "sunspire": FrameSlicePolicy(
        source_cap_insets=CapInsets(top=280, left=360, bottom=280, right=360),
        horizontal_sample=(600, 936),
        vertical_sample=(400, 624),
    ),
    "wildwood": FrameSlicePolicy(
        source_cap_insets=CapInsets(top=280, left=320, bottom=280, right=320),
        horizontal_sample=(570, 878),
        vertical_sample=(420, 666),
    ),
    "gloamthorn": FrameSlicePolicy(
        source_cap_insets=CapInsets(top=300, left=320, bottom=300, right=320),
        horizontal_sample=(420, 600),
        vertical_sample=(350, 500),
    ),
}


MOONLEAF_SUNSPIRE_ORNAMENT_RECORD = (
    "docs/verification/theme-fidelity-v4-3/source-masters/"
    "moonleaf-sunspire-frame-crest-master-record-v4.3.json"
)
MOONLEAF_SUNSPIRE_ORNAMENT_RECORD_SHA256 = (
    "0e0bbf1581ac99538aa68989e9079c77e90b061d72298aacca037f6516a54ef3"
)
WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD = (
    "docs/verification/theme-fidelity-v4-3/source-masters/"
    "wildwood-gloamthorn-ornament-master-record-v4.3.json"
)
WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD_SHA256 = (
    "50f3fac8dba3b920499ed0fabba4d59dbdfcea8b573bbe2f10abaf86a1edab8a"
)
RELIC_RECORD = (
    "docs/verification/theme-fidelity-v4-3/source-masters/"
    "environment-and-relic-master-record-v4.3.json"
)
RELIC_RECORD_SHA256 = "5cd76eacc482a65fdaffa8d4ec69731a1db51f0e2a133938ed30c1cbbd89e72c"

SEAL_RECORDS: Mapping[str, tuple[str, str]] = {
    "moonleaf": (
        f"{SOURCE_MASTER_ROOT}/moonleaf/seals/Moonleaf-Seal-Source-Masters-v4.3.json",
        "904fb9b845f7bfd58c0b68ac4c37ea45ad284afd1110e6e2a8af48e697f91741",
    ),
    "sunspire": (
        f"{SOURCE_MASTER_ROOT}/sunspire/seals/sunspire-seal-source-master-record-v4-3.json",
        "fe9811d706daa558e0f82866f16741a55e89d8fb0a10a0f059de64e7569add7d",
    ),
    "wildwood": (
        f"{SOURCE_MASTER_ROOT}/wildwood/seals/Wildwood-Seal-Source-Masters-v4.3.json",
        "2fd436ee68c78ccd438288eacaf616273285fb8a65bb9c9406a3396385cdc2fc",
    ),
    "gloamthorn": (
        f"{SOURCE_MASTER_ROOT}/gloamthorn/seals/Gloamthorn-Seal-Source-Masters-v4.3.json",
        "ffa14ced33e7f46f78966e23b8d1c583015d16bddbe7e45fcc33bcb94c8e4a03",
    ),
}


def accepted_recipe_rights_id(theme: str) -> str:
    return f"prov.Production.Sources.{theme}.accepted.source.masters.recipe.json"


FRAME_SOURCE_MASTERS: Mapping[str, SourceMasterSpec] = {
    "moonleaf": SourceMasterSpec(
        asset_id="moonleaf-silvervine-frame",
        role="Frame",
        relative_path=(
            f"{SOURCE_MASTER_ROOT}/moonleaf/"
            "moonleaf-silvervine-frame-production-master-v4.3.png"
        ),
        sha256="0ea0fb618d19523b357225a2453f39fe0bac25a4dc5155168bc51ef51abd6b28",
        pixel_size=(1536, 1024),
        acceptance_record_path=MOONLEAF_SUNSPIRE_ORNAMENT_RECORD,
        acceptance_record_sha256=MOONLEAF_SUNSPIRE_ORNAMENT_RECORD_SHA256,
        rights_id=accepted_recipe_rights_id("moonleaf"),
    ),
    "sunspire": SourceMasterSpec(
        asset_id="sunspire-laurel-of-dawn-frame",
        role="Frame",
        relative_path=(
            f"{SOURCE_MASTER_ROOT}/sunspire/"
            "sunspire-laurel-of-dawn-frame-production-master-v4.3.png"
        ),
        sha256="0194d53a9c29d866eaeda63e5ef08837d2a6b0b5a69d96e146f4b38a77e3dba3",
        pixel_size=(1536, 1024),
        acceptance_record_path=MOONLEAF_SUNSPIRE_ORNAMENT_RECORD,
        acceptance_record_sha256=MOONLEAF_SUNSPIRE_ORNAMENT_RECORD_SHA256,
        rights_id=accepted_recipe_rights_id("sunspire"),
    ),
    "wildwood": SourceMasterSpec(
        asset_id="frame.wildwood.living-root",
        role="Frame",
        relative_path=(
            f"{SOURCE_MASTER_ROOT}/wildwood/ornament/"
            "wildwood-living-root-frame-production-master-v4.3.png"
        ),
        sha256="41005f47b1ae190337f01b77f22220458d51bd7ef5251e1429b0e3dbb948a0aa",
        pixel_size=(1448, 1086),
        acceptance_record_path=WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD,
        acceptance_record_sha256=WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD_SHA256,
        rights_id=accepted_recipe_rights_id("wildwood"),
    ),
    "gloamthorn": SourceMasterSpec(
        asset_id="frame.gloamthorn.briar-court",
        role="Frame",
        relative_path=(
            f"{SOURCE_MASTER_ROOT}/gloamthorn/ornament/"
            "gloamthorn-briar-court-frame-production-master-v4.3.png"
        ),
        sha256="65c9c0eea4b9891a718075aa34ec340db3d174b04dc6a355d293d6c3b7df53e7",
        pixel_size=(1448, 1086),
        acceptance_record_path=WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD,
        acceptance_record_sha256=WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD_SHA256,
        rights_id=accepted_recipe_rights_id("gloamthorn"),
    ),
}


CREST_SOURCE_MASTERS: Mapping[str, SourceMasterSpec] = {
    "moonleaf": SourceMasterSpec(
        asset_id="moonleaf-moonbloom-crest",
        role="Crest",
        relative_path=(
            f"{SOURCE_MASTER_ROOT}/moonleaf/"
            "moonleaf-moonbloom-crest-production-master-v4.3.png"
        ),
        sha256="0fd535931d1d439a5c5fbe0908b3966d877a7a450f0da6ca11f5f11db36f9771",
        pixel_size=(1280, 1920),
        acceptance_record_path=MOONLEAF_SUNSPIRE_ORNAMENT_RECORD,
        acceptance_record_sha256=MOONLEAF_SUNSPIRE_ORNAMENT_RECORD_SHA256,
        rights_id=accepted_recipe_rights_id("moonleaf"),
    ),
    "sunspire": SourceMasterSpec(
        asset_id="sunspire-first-light-crest",
        role="Crest",
        relative_path=(
            f"{SOURCE_MASTER_ROOT}/sunspire/"
            "sunspire-first-light-crest-production-master-v4.3.png"
        ),
        sha256="3a89b411b58f017bcb8f41b9581425baf3dd8c7b4e324b0f20a3a75e2172c70e",
        pixel_size=(1280, 1920),
        acceptance_record_path=MOONLEAF_SUNSPIRE_ORNAMENT_RECORD,
        acceptance_record_sha256=MOONLEAF_SUNSPIRE_ORNAMENT_RECORD_SHA256,
        rights_id=accepted_recipe_rights_id("sunspire"),
    ),
    "wildwood": SourceMasterSpec(
        asset_id="crest.wildwood.heartwood-crown",
        role="Crest",
        relative_path=(
            f"{SOURCE_MASTER_ROOT}/wildwood/ornament/"
            "wildwood-heartwood-crown-crest-production-master-v4.3.png"
        ),
        sha256="6203b8d5adcd326f91fadf17c96e2e7147aef9992338e31fa8c316c702453a42",
        pixel_size=(1254, 1254),
        acceptance_record_path=WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD,
        acceptance_record_sha256=WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD_SHA256,
        rights_id=accepted_recipe_rights_id("wildwood"),
    ),
    "gloamthorn": SourceMasterSpec(
        asset_id="crest.gloamthorn.gloam-sovereign",
        role="Crest",
        relative_path=(
            f"{SOURCE_MASTER_ROOT}/gloamthorn/ornament/"
            "gloamthorn-gloam-sovereign-crest-production-master-v4.3.png"
        ),
        sha256="19acfb86790a6c2fe983c740d143bc439ff5ba46bf20942d2dee5a2f6ee84789",
        pixel_size=(1254, 1254),
        acceptance_record_path=WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD,
        acceptance_record_sha256=WILDWOOD_GLOAMTHORN_ORNAMENT_RECORD_SHA256,
        rights_id=accepted_recipe_rights_id("gloamthorn"),
    ),
}


RELIC_SOURCE_MASTERS: Mapping[str, Mapping[str, SourceMasterSpec]] = {
    "moonleaf": {},
    "sunspire": {
        "dawnfire-tablet": SourceMasterSpec(
            asset_id="sunspire.dawnfire-tablet.clean-master",
            role="Relic",
            relative_path=(
                f"{SOURCE_MASTER_ROOT}/sunspire/"
                "sunspire-dawnfire-tablet-clean-production-master-v4.3.png"
            ),
            sha256="19322a7f35deda05349807bd315f1e9abee6a082ba9f9557423653b54396b9c9",
            pixel_size=(1200, 1600),
            acceptance_record_path=RELIC_RECORD,
            acceptance_record_sha256=RELIC_RECORD_SHA256,
            rights_id=accepted_recipe_rights_id("sunspire"),
        ),
    },
    "wildwood": {
        "rootsong-tablet": SourceMasterSpec(
            asset_id="wildwood.rootsong-tablet.clean-master",
            role="Relic",
            relative_path=(
                f"{SOURCE_MASTER_ROOT}/wildwood/"
                "wildwood-rootsong-tablet-clean-production-master-v4.3.png"
            ),
            sha256="c36bbb1aff2685502081e441da0ab0bffea3651a67774093ef86c646cdf532e5",
            pixel_size=(1600, 1200),
            acceptance_record_path=RELIC_RECORD,
            acceptance_record_sha256=RELIC_RECORD_SHA256,
            rights_id=accepted_recipe_rights_id("wildwood"),
        ),
        "mossbound-plaque": SourceMasterSpec(
            asset_id="wildwood.mossbound-plaque.clean-master",
            role="Relic",
            relative_path=(
                f"{SOURCE_MASTER_ROOT}/wildwood/"
                "wildwood-mossbound-plaque-clean-production-master-v4.3.png"
            ),
            sha256="d599ff51f2d7a43c123c4541b64e2870a26dd57a3dd0bba0579c5ed60672465d",
            pixel_size=(1600, 1200),
            acceptance_record_path=RELIC_RECORD,
            acceptance_record_sha256=RELIC_RECORD_SHA256,
            rights_id=accepted_recipe_rights_id("wildwood"),
        ),
    },
    "gloamthorn": {
        "nightthorn-tablet": SourceMasterSpec(
            asset_id="gloamthorn.nightthorn-tablet.clean-master",
            role="Relic",
            relative_path=(
                f"{SOURCE_MASTER_ROOT}/gloamthorn/"
                "gloamthorn-nightthorn-tablet-clean-production-master-v4.3.png"
            ),
            sha256="f5b024959ef7146102064cb0a3222291ccb378729dbc83b89949a1329ffda795",
            pixel_size=(1600, 1200),
            acceptance_record_path=RELIC_RECORD,
            acceptance_record_sha256=RELIC_RECORD_SHA256,
            rights_id=accepted_recipe_rights_id("gloamthorn"),
        ),
    },
}


def _seal_spec(
    theme: str,
    slug: str,
    filename: str,
    sha256: str,
    pixel_size: tuple[int, int],
) -> SealSourceMasterSpec:
    record_path, record_sha = SEAL_RECORDS[theme]
    return SealSourceMasterSpec(
        theme=theme,
        slug=slug,
        relative_path=f"{SOURCE_MASTER_ROOT}/{theme}/seals/{filename}",
        sha256=sha256,
        pixel_size=pixel_size,
        acceptance_record_path=record_path,
        acceptance_record_sha256=record_sha,
    )


SEAL_SOURCE_MASTERS: Mapping[str, Mapping[str, SealSourceMasterSpec]] = {
    "moonleaf": {
        "night-owl": _seal_spec(
            "moonleaf", "night-owl", "moonleaf-night-owl-production-master-v4.3.png",
            "d19520baa7371d7ef5db39943324ab168395a248c35a477d8a8e8b1be1fa6393", (1024, 1024),
        ),
        "moonwell": _seal_spec(
            "moonleaf", "moonwell", "moonleaf-moonwell-production-master-v4.3.png",
            "2e4f51c1f3837ecf6f04ec656253a6b9982494ca9f562ac23e2a3b46a94d7bf5", (1024, 1024),
        ),
        "starflower": _seal_spec(
            "moonleaf", "starflower", "moonleaf-starflower-production-master-v4.3.png",
            "7efa6463069e83bd56031d7751f3812a56d62cb21cae8d8b5a406ff39f1086a3", (1024, 1024),
        ),
        "echo-firefly": _seal_spec(
            "moonleaf", "echo-firefly", "moonleaf-echo-firefly-production-master-v4.3.png",
            "29fede6ac2b69dc7f93cd505b0e3d67bcce7bfdd7fefda413a129609e3806c51", (1024, 1024),
        ),
    },
    "sunspire": {
        "dawnflower": _seal_spec(
            "sunspire", "dawnflower", "sunspire-dawnflower-color-master-v4-3.png",
            "c5eefb8c0c2a56f97109ac582a08db7262856bfddeb199e09b1fc4e428f3ad15", (1254, 1254),
        ),
        "sunwheel": _seal_spec(
            "sunspire", "sunwheel", "sunspire-sunwheel-color-master-v4-3.png",
            "bde40aeeaea0e81ebedd4f17836510e44dd072b23dc9c83e53bcac591c561d32", (1254, 1254),
        ),
        "radiant-spire": _seal_spec(
            "sunspire", "radiant-spire", "sunspire-radiant-spire-color-master-v4-3.png",
            "8a4ad746476c82448b451f038c726491ae2fabd91f5c13f2536643736048ec0f", (1254, 1254),
        ),
        "echo-ember": _seal_spec(
            "sunspire", "echo-ember", "sunspire-echo-ember-color-master-v4-3.png",
            "3094e3821982d952fda520476adc2df2d7dd430d574dd324cc5ee096ccdf537b", (1254, 1254),
        ),
    },
    "wildwood": {
        "acorn-knot": _seal_spec(
            "wildwood", "acorn-knot", "wildwood-acorn-knot-production-master-v4.3.png",
            "27e2a8a92dc286754cc5d8a51fbab471add997a38c2ffc6e5f1ce20cc2301136", (1024, 1024),
        ),
        "fern-spiral": _seal_spec(
            "wildwood", "fern-spiral", "wildwood-fern-spiral-production-master-v4.3.png",
            "cffc7bf657fb96f4c0c71e338ec7f40ec4a068c62fee3a7ba2d37ebea717a3ec", (1024, 1024),
        ),
        "wild-fox": _seal_spec(
            "wildwood", "wild-fox", "wildwood-wild-fox-production-master-v4.3.png",
            "f7978d0a2fcfff65f9a23ce799fef2e66f93c8003e343e76523b6ca3440c4c32", (1024, 1024),
        ),
        "echo-seed": _seal_spec(
            "wildwood", "echo-seed", "wildwood-echo-seed-production-master-v4.3.png",
            "0315bf69e15472ad106fd0ea66da3795828beea99dc4f0df161f85c5db166580", (1024, 1024),
        ),
    },
    "gloamthorn": {
        "thornmoon": _seal_spec(
            "gloamthorn", "thornmoon", "gloamthorn-thornmoon-production-master-v4.3.png",
            "2b3c2f258444946f4babeedbbbf9ea2c3300e6c4fceb1017c3291f22a820cd1a", (1024, 1024),
        ),
        "nightglass-moth": _seal_spec(
            "gloamthorn", "nightglass-moth", "gloamthorn-nightglass-moth-production-master-v4.3.png",
            "a2d4373d24d2f3b50e1d2b8daf7a8d3de63445bd5b1315828cb30deedc036cc7", (1024, 1024),
        ),
        "eclipse-bloom": _seal_spec(
            "gloamthorn", "eclipse-bloom", "gloamthorn-eclipse-bloom-production-master-v4.3.png",
            "76ea85b7df541bd4f7576b3ae8b6be732aca25e655127d1f100b3e9fd43cef61", (1024, 1024),
        ),
        "veiled-serpent": _seal_spec(
            "gloamthorn", "veiled-serpent", "gloamthorn-veiled-serpent-production-master-v4.3.png",
            "fdf1911e20e9567dfc7737e191c52376815dbdcea07e0ece0de40e91d7899c54", (1024, 1024),
        ),
        "pact-crown": _seal_spec(
            "gloamthorn", "pact-crown", "gloamthorn-pact-crown-production-master-v4.3.png",
            "b352c3166ed39c4a85d2665c6f54feb10a153cdcb405e60599d887bd5a265ea2", (1024, 1024),
        ),
        "echo-wisp": _seal_spec(
            "gloamthorn", "echo-wisp", "gloamthorn-echo-wisp-production-master-v4.3.png",
            "db3afe786cb5c27ddb1a0f670e2ff1c9593346247e841d82a8d58f6150613ee3", (1024, 1024),
        ),
    },
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _record_output_path(value: str) -> str:
    if value.startswith("docs/"):
        return value
    return f"{SOURCE_MASTER_ROOT}/{value}"


def _record_asset(document: Mapping[str, Any], asset_id: str) -> Mapping[str, Any]:
    candidates = document.get("assets", document.get("records", []))
    if not isinstance(candidates, list):
        raise ValueError("acceptance record does not contain an asset list")
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        if candidate.get("assetID", candidate.get("id")) == asset_id:
            return candidate
    raise ValueError(f"acceptance record does not contain {asset_id}")


def load_source_master(
    repo_root: Path,
    specification: SourceMasterSpec,
) -> tuple[Image.Image, dict[str, Any]]:
    record_path = repo_root / specification.acceptance_record_path
    if not record_path.is_file():
        raise ValueError(f"accepted source-master record is absent: {specification.acceptance_record_path}")
    record_sha = sha256_file(record_path)
    if record_sha != specification.acceptance_record_sha256:
        raise ValueError(f"accepted source-master record hash differs: {specification.acceptance_record_path}")
    document = json.loads(record_path.read_text(encoding="utf-8"))
    record = _record_asset(document, specification.asset_id)
    owner_review = record.get("ownerReview", document.get("ownerReview"))
    if owner_review != "PENDING":
        raise ValueError(f"accepted source-master owner review differs: {specification.asset_id}")

    record_dimensions = record.get("dimensions")
    if isinstance(record_dimensions, dict):
        record_size = (record_dimensions.get("width"), record_dimensions.get("height"))
    else:
        record_size = tuple(record_dimensions or ())
    record_output = record.get("outputPath", record.get("output"))
    if (
        record.get("sha256") != specification.sha256
        or record_size != specification.pixel_size
        or _record_output_path(str(record_output)) != specification.relative_path
        or str(record.get("role", "")).casefold() != specification.role.casefold()
    ):
        raise ValueError(f"accepted source-master record differs: {specification.asset_id}")

    path = repo_root / specification.relative_path
    if not path.is_file():
        raise ValueError(f"accepted source master is absent: {specification.relative_path}")
    actual_sha = sha256_file(path)
    if actual_sha != specification.sha256:
        raise ValueError(f"accepted source-master hash differs: {specification.relative_path}")
    with Image.open(path) as opened:
        if opened.size != specification.pixel_size or "A" not in opened.getbands():
            raise ValueError(f"accepted source-master image contract differs: {specification.relative_path}")
        image = opened.convert("RGBA")
    if image.getchannel("A").getextrema()[0] != 0:
        raise ValueError(f"accepted source master has no transparent pixels: {specification.relative_path}")

    return image, {
        "acceptanceRecord": {
            "ownerReview": "PENDING",
            "path": specification.acceptance_record_path,
            "sha256": record_sha,
        },
        "assetID": specification.asset_id,
        "dimensions": list(specification.pixel_size),
        "hasAlpha": True,
        "path": specification.relative_path,
        "rightsID": specification.rights_id,
        "role": specification.role,
        "runtimeBundled": False,
        "sha256": actual_sha,
    }


def _seal_record_asset(
    document: Mapping[str, Any],
    seal_id: str,
) -> Mapping[str, Any]:
    assets = document.get("assets")
    if not isinstance(assets, list):
        raise ValueError("Seal acceptance record does not contain an asset list")
    for asset in assets:
        if isinstance(asset, dict) and asset.get("sealID") == seal_id:
            return asset
    raise ValueError(f"Seal acceptance record does not contain {seal_id}")


def _validate_portable_record(document: Mapping[str, Any], record_path: str) -> None:
    serialized = json.dumps(document, ensure_ascii=True).casefold()
    forbidden_paths = ("/users/", ".codex", "generated_images", "/tmp/")
    if any(token in serialized for token in forbidden_paths):
        raise ValueError(f"Seal acceptance record contains a machine-local path: {record_path}")
    identity = document.get("referencePackageIdentity", document.get("packageIdentity"))
    if identity != "Rune-Scribe-Theme-Fidelity-v4.3-Canonical-Authority-and-Remediation":
        raise ValueError(f"Seal acceptance record package identity differs: {record_path}")
    roots = [value for key, value in document.items() if str(key).endswith("Root")]
    if any(root != "." for root in roots):
        raise ValueError(f"Seal acceptance record has a non-portable path root: {record_path}")


def load_seal_source_master(
    repo_root: Path,
    specification: SealSourceMasterSpec,
) -> tuple[Image.Image, dict[str, Any]]:
    record_path = repo_root / specification.acceptance_record_path
    if not record_path.is_file():
        raise ValueError(
            f"Seal acceptance record is absent: {specification.acceptance_record_path}"
        )
    record_sha = sha256_file(record_path)
    if record_sha != specification.acceptance_record_sha256:
        raise ValueError(
            f"Seal acceptance record hash differs: {specification.acceptance_record_path}"
        )
    document = json.loads(record_path.read_text(encoding="utf-8"))
    if document.get("ownerReview") != "PENDING":
        raise ValueError(f"Seal owner review differs: {specification.seal_id}")
    _validate_portable_record(document, specification.acceptance_record_path)
    record = _seal_record_asset(document, specification.seal_id)

    if specification.theme == "sunspire":
        output = record.get("output")
        if not isinstance(output, dict):
            raise ValueError(f"Seal output record is absent: {specification.seal_id}")
        path = output.get("path")
        sha256 = output.get("sha256")
        dimensions = tuple(output.get("dimensions", ()))
        accepted = output.get("acceptance") == "ACCEPTED_AS_SOURCE_MASTER_CANDIDATE"
        target_scale = "64 px" in str(output.get("smallScaleReview", ""))
        alpha_recorded = output.get("pixelFormat") == "RGBA" and output.get("cornerAlpha") == 0
    else:
        output = record
        path = output.get("outputPath")
        sha256 = output.get("sha256")
        dimensions = tuple(output.get("dimensions", ()))
        review = output.get("review")
        accepted = isinstance(review, dict) and review.get("selection") == "ACCEPTED_FOR_IMPLEMENTATION_INPUT"
        target_scale = isinstance(review, dict) and review.get("targetScale") == "PASS_AT_64_PX"
        alpha = output.get("alpha")
        alpha_recorded = isinstance(alpha, dict) and alpha.get("present") is True and alpha.get("exteriorTransparent") is True

    if (
        path != specification.relative_path
        or sha256 != specification.sha256
        or dimensions != specification.pixel_size
        or not accepted
        or not target_scale
        or not alpha_recorded
    ):
        raise ValueError(f"Seal acceptance state differs: {specification.seal_id}")

    source_path = repo_root / specification.relative_path
    if not source_path.is_file():
        raise ValueError(f"Seal source master is absent: {specification.relative_path}")
    actual_sha = sha256_file(source_path)
    if actual_sha != specification.sha256:
        raise ValueError(f"Seal source-master hash differs: {specification.relative_path}")
    raw = source_path.read_bytes().lower()
    forbidden_metadata = (
        b"open" + b"ai",
        b"chat" + b"gpt",
        b"dall" + b"-e",
        b"c2" + b"pa",
        b"content " + b"credentials",
        b"generated" + b"_images",
        b"adobe:" + b"generative",
        b"ai " + b"generated",
    )
    if any(token in raw for token in forbidden_metadata):
        raise ValueError(f"Seal source master contains forbidden metadata: {specification.relative_path}")
    with Image.open(source_path) as opened:
        if opened.mode != "RGBA" or opened.size != specification.pixel_size:
            raise ValueError(f"Seal source-master image contract differs: {specification.relative_path}")
        if set(opened.info) - {"aspect"}:
            raise ValueError(f"Seal source master contains unapproved PNG metadata: {specification.relative_path}")
        image = opened.copy()
    alpha = image.getchannel("A")
    if alpha.getextrema() != (0, 255):
        raise ValueError(f"Seal source master has incomplete alpha range: {specification.relative_path}")
    corner_alpha = (
        alpha.getpixel((0, 0)),
        alpha.getpixel((image.width - 1, 0)),
        alpha.getpixel((0, image.height - 1)),
        alpha.getpixel((image.width - 1, image.height - 1)),
    )
    if max(corner_alpha) > 1:
        raise ValueError(f"Seal source master has an opaque exterior corner: {specification.relative_path}")
    bounds = alpha.point(lambda value: 255 if value > 1 else 0).getbbox()
    if bounds is None or bounds[0] <= 0 or bounds[1] <= 0 or bounds[2] >= image.width or bounds[3] >= image.height:
        raise ValueError(f"Seal source master lacks transparent exterior margin: {specification.relative_path}")

    return image, {
        "acceptanceRecord": {
            "ownerReview": "PENDING",
            "path": specification.acceptance_record_path,
            "sha256": record_sha,
        },
        "assetID": specification.seal_id,
        "dimensions": list(specification.pixel_size),
        "hasAlpha": True,
        "path": specification.relative_path,
        "rightsID": specification.rights_id,
        "role": "Seal",
        "runtimeBundled": False,
        "sha256": actual_sha,
        "targetScaleReview": "PASS_AT_64_PX",
    }


def render_seal_variants(
    source: Image.Image,
) -> tuple[Image.Image, Image.Image, Image.Image]:
    """Preserve the complete color master and derive explicit alpha-safe variants."""
    color = source.copy()
    alpha = color.getchannel("A")
    monochrome = ImageEnhance.Contrast(
        ImageOps.grayscale(color.convert("RGB"))
    ).enhance(1.20).convert("RGBA")
    monochrome.putalpha(alpha)
    thumbnail = uniform_aspect_fit(color, (512, 512))
    return color, monochrome, thumbnail


def seal_render_recipe_record(
    source_size: tuple[int, int],
) -> dict[str, Any]:
    return {
        "colorMaster": {
            "method": "decoded-RGBA-pixel-identity-copy",
            "outputPixels": list(source_size),
            "sourcePixels": list(source_size),
            "metadataPolicy": "deterministic PNG encoding with no inherited ancillary metadata",
        },
        "monochromeFallback": {
            "method": "luminance conversion with 1.20 contrast and exact source alpha",
            "outputPixels": list(source_size),
        },
        "thumbnail": aspect_fit_record(source_size, (512, 512)),
    }


def load_accepted_recipe(
    repo_root: Path,
    expected_relative_path: str,
    reference: Mapping[str, Any],
) -> dict[str, Any]:
    if reference.get("path") != expected_relative_path:
        raise ValueError("accepted source-master recipe path differs")
    path = repo_root / expected_relative_path
    if not path.is_file():
        raise ValueError("accepted source-master recipe is absent")
    if reference.get("sha256") != sha256_file(path):
        raise ValueError("accepted source-master recipe hash differs")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("accepted source-master recipe is unreadable") from error
    if document.get("ownerReview") != "PENDING":
        raise ValueError("accepted source-master recipe owner review differs")
    return document


def uniform_aspect_fit(
    source: Image.Image,
    target_size: tuple[int, int],
    *,
    resampling: Image.Resampling = Image.Resampling.LANCZOS,
) -> Image.Image:
    if min(source.size) <= 0 or min(target_size) <= 0:
        raise ValueError("source and target dimensions must be positive")
    scale = min(target_size[0] / source.width, target_size[1] / source.height)
    rendered_size = (
        max(1, round(source.width * scale)),
        max(1, round(source.height * scale)),
    )
    rendered = source.convert("RGBA").resize(rendered_size, resampling)
    result = Image.new("RGBA", target_size, (0, 0, 0, 0))
    result.alpha_composite(
        rendered,
        ((target_size[0] - rendered.width) // 2, (target_size[1] - rendered.height) // 2),
    )
    return result


def aspect_fit_record(source_size: tuple[int, int], target_size: tuple[int, int]) -> dict[str, Any]:
    scale = min(target_size[0] / source_size[0], target_size[1] / source_size[1])
    rendered_size = [
        max(1, round(source_size[0] * scale)),
        max(1, round(source_size[1] * scale)),
    ]
    return {
        "method": "uniform-aspect-fit",
        "offsetPixels": [
            (target_size[0] - rendered_size[0]) // 2,
            (target_size[1] - rendered_size[1]) // 2,
        ],
        "outputPixels": list(target_size),
        "renderedPixels": rendered_size,
        "resampling": "LANCZOS",
        "sourcePixels": list(source_size),
        "uniformScale": scale,
    }


def _validate_slice_policy(source: Image.Image, policy: FrameSlicePolicy) -> None:
    caps = policy.source_cap_insets
    if caps.left + caps.right >= source.width or caps.top + caps.bottom >= source.height:
        raise ValueError("source cap insets leave no stretchable edge region")
    if not (caps.left <= policy.horizontal_sample[0] < policy.horizontal_sample[1] <= source.width - caps.right):
        raise ValueError("horizontal edge sample overlaps protected source corners")
    if not (caps.top <= policy.vertical_sample[0] < policy.vertical_sample[1] <= source.height - caps.bottom):
        raise ValueError("vertical edge sample overlaps protected source corners")


def _render_edge(
    source: Image.Image,
    box: tuple[int, int, int, int],
    size: tuple[int, int],
    *,
    orientation: str,
) -> Image.Image:
    """Uniformly normalize edge thickness, then stretch only its running axis."""
    if min(size) <= 0:
        raise ValueError("slice target dimensions must be positive")
    edge = source.crop(box)
    if orientation == "horizontal":
        scale = size[1] / edge.height
        normalized = edge.resize(
            (max(1, round(edge.width * scale)), size[1]),
            Image.Resampling.LANCZOS,
        )
    elif orientation == "vertical":
        scale = size[0] / edge.width
        normalized = edge.resize(
            (size[0], max(1, round(edge.height * scale))),
            Image.Resampling.LANCZOS,
        )
    else:
        raise ValueError(f"unsupported edge orientation: {orientation}")
    return normalized.resize(size, Image.Resampling.LANCZOS)


def _fit_corner(
    result: Image.Image,
    corner: Image.Image,
    region: tuple[int, int, int, int],
    *,
    horizontal_anchor: str,
    vertical_anchor: str,
) -> None:
    width = region[2] - region[0]
    height = region[3] - region[1]
    rendered_size = _corner_fit_size(corner.size, (width, height))
    rendered = corner.resize(
        rendered_size,
        Image.Resampling.LANCZOS,
    )
    x = region[0] if horizontal_anchor == "left" else region[2] - rendered.width
    y = region[1] if vertical_anchor == "top" else region[3] - rendered.height
    result.alpha_composite(rendered, (x, y))


def _corner_fit_size(
    source_size: tuple[int, int],
    target_size: tuple[int, int],
) -> tuple[int, int]:
    scale = min(target_size[0] / source_size[0], target_size[1] / source_size[1])
    return (
        max(1, round(source_size[0] * scale)),
        max(1, round(source_size[1] * scale)),
    )


def render_nine_slice_frame(
    source: Image.Image,
    target_size: tuple[int, int],
    target_cap_insets: CapInsets,
    policy: FrameSlicePolicy,
) -> Image.Image:
    """Compose uniformly scaled protected corners with contiguous edge slices."""
    frame = source.convert("RGBA")
    _validate_slice_policy(frame, policy)
    caps = policy.source_cap_insets
    target = target_cap_insets
    if target.left + target.right >= target_size[0] or target.top + target.bottom >= target_size[1]:
        raise ValueError("target cap insets leave no stretchable center")

    result = Image.new("RGBA", target_size, (0, 0, 0, 0))
    # One uniform scale is shared by every corner and every edge cross-axis.
    # This is the key continuity invariant: the final row/column of each corner
    # meets the immediately adjacent source row/column of its edge at the same
    # scale. The larger Swift cap inset merely protects transparent padding.
    scale = min(
        target.left / caps.left,
        target.right / caps.right,
        target.top / caps.top,
        target.bottom / caps.bottom,
    )
    top_left_size = (round(caps.left * scale), round(caps.top * scale))
    top_right_size = (round(caps.right * scale), round(caps.top * scale))
    bottom_left_size = (round(caps.left * scale), round(caps.bottom * scale))
    bottom_right_size = (round(caps.right * scale), round(caps.bottom * scale))
    join_overlap = 2
    top_edge_left = max(0, top_left_size[0] - join_overlap)
    top_edge_right = min(target_size[0], target_size[0] - top_right_size[0] + join_overlap)
    bottom_edge_left = max(0, bottom_left_size[0] - join_overlap)
    bottom_edge_right = min(target_size[0], target_size[0] - bottom_right_size[0] + join_overlap)
    left_edge_top = max(0, top_left_size[1] - join_overlap)
    left_edge_bottom = min(target_size[1], target_size[1] - bottom_left_size[1] + join_overlap)
    right_edge_top = max(0, top_right_size[1] - join_overlap)
    right_edge_bottom = min(target_size[1], target_size[1] - bottom_right_size[1] + join_overlap)

    # Each edge is the complete source interval immediately between its two
    # protected corners. It is uniformly scaled across its thickness and only
    # stretched along its running axis. A two-pixel underlap prevents subpixel
    # alpha pinholes, with corners composited last to retain exact silhouettes.
    top_edge = _render_edge(
        frame,
        (caps.left, 0, frame.width - caps.right, caps.top),
        (top_edge_right - top_edge_left, top_left_size[1]),
        orientation="horizontal",
    )
    bottom_edge = _render_edge(
        frame,
        (caps.left, frame.height - caps.bottom, frame.width - caps.right, frame.height),
        (bottom_edge_right - bottom_edge_left, bottom_left_size[1]),
        orientation="horizontal",
    )
    left_edge = _render_edge(
        frame,
        (0, caps.top, caps.left, frame.height - caps.bottom),
        (top_left_size[0], left_edge_bottom - left_edge_top),
        orientation="vertical",
    )
    right_edge = _render_edge(
        frame,
        (frame.width - caps.right, caps.top, frame.width, frame.height - caps.bottom),
        (top_right_size[0], right_edge_bottom - right_edge_top),
        orientation="vertical",
    )
    result.alpha_composite(top_edge, (top_edge_left, 0))
    result.alpha_composite(
        bottom_edge,
        (bottom_edge_left, target_size[1] - bottom_left_size[1]),
    )
    result.alpha_composite(left_edge, (0, left_edge_top))
    result.alpha_composite(right_edge, (target_size[0] - top_right_size[0], right_edge_top))

    corners = (
        (
            frame.crop((0, 0, caps.left, caps.top)),
            (0, 0, target.left, target.top),
            "left",
            "top",
        ),
        (
            frame.crop((frame.width - caps.right, 0, frame.width, caps.top)),
            (target_size[0] - target.right, 0, target_size[0], target.top),
            "right",
            "top",
        ),
        (
            frame.crop((0, frame.height - caps.bottom, caps.left, frame.height)),
            (0, target_size[1] - target.bottom, target.left, target_size[1]),
            "left",
            "bottom",
        ),
        (
            frame.crop((frame.width - caps.right, frame.height - caps.bottom, frame.width, frame.height)),
            (
                target_size[0] - target.right,
                target_size[1] - target.bottom,
                target_size[0],
                target_size[1],
            ),
            "right",
            "bottom",
        ),
    )
    for index, (corner, region, horizontal_anchor, vertical_anchor) in enumerate(corners):
        rendered_size = (
            top_left_size,
            top_right_size,
            bottom_left_size,
            bottom_right_size,
        )[index]
        rendered = corner.resize(rendered_size, Image.Resampling.LANCZOS)
        x = region[0] if horizontal_anchor == "left" else region[2] - rendered.width
        y = region[1] if vertical_anchor == "top" else region[3] - rendered.height
        result.alpha_composite(rendered, (x, y))
    return result


def panel_assets(theme: str, frame_master: Image.Image) -> dict[str, Image.Image]:
    policy = FRAME_SLICE_POLICIES[theme]
    outputs: dict[str, Image.Image] = {}
    for name, target_size in PANEL_TARGET_SIZES.items():
        target_caps = PANEL_CAP_INSETS[name]
        if target_caps is None:
            source_caps = policy.source_cap_insets
            corner = frame_master.convert("RGBA").crop(
                (0, 0, source_caps.left, source_caps.top)
            )
            outputs[name] = uniform_aspect_fit(corner, target_size)
        else:
            outputs[name] = render_nine_slice_frame(
                frame_master,
                target_size,
                target_caps,
                policy,
            )
    return outputs


def panel_policy_record(theme: str) -> dict[str, Any]:
    policy = FRAME_SLICE_POLICIES[theme]
    return {
        "composition": "independent uniformly scaled protected corners plus the four contiguous between-corner edge intervals; transparent center; no whole-frame nonuniform resize",
        "edgePreparation": "one shared uniform scale for every corner and edge cross-axis, followed by running-axis-only edge stretch",
        "edgeResampling": "LANCZOS one-axis edge stretch",
        "joinPolicy": "each edge begins at the source pixel adjacent to its protected corner, uses the same cross-axis scale as that corner, and underlaps the corner by two target pixels",
        "horizontalEdgeInterval": [
            policy.source_cap_insets.left,
            FRAME_SOURCE_MASTERS[theme].pixel_size[0] - policy.source_cap_insets.right,
        ],
        "protectedContentScale": "minimum target-to-source cap ratio shared by all four sides",
        "sourceCapInsets": policy.source_cap_insets.as_dict(),
        "targetOutputs": {
            name: {
                "capInsets": caps.as_dict() if caps is not None else None,
                "dimensions": list(PANEL_TARGET_SIZES[name]),
            }
            for name, caps in PANEL_CAP_INSETS.items()
        },
        "verticalEdgeInterval": [
            policy.source_cap_insets.top,
            FRAME_SOURCE_MASTERS[theme].pixel_size[1] - policy.source_cap_insets.bottom,
        ],
    }
