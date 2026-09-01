#!/usr/bin/env python3
"""Extract Moonleaf received-presentation identity resources from owner sources."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from typing import Any, Iterable

from PIL import Image, ImageChops

try:
    from scripts.moonleaf_received_identity_runtime_evidence import (
        RuntimeEvidenceError,
        validate_runtime_state,
    )
except ModuleNotFoundError:
    from moonleaf_received_identity_runtime_evidence import (  # type: ignore[no-redef]
        RuntimeEvidenceError,
        validate_runtime_state,
    )


CREATED_AT = "2026-08-27T00:00:00Z"
PIPELINE = "scripts/extract-moonleaf-received-identity-v43.py"
PRODUCTION_RELATIVE_ROOT = (
    "Packages/RuneScribeArchitecture/Sources/"
    "RuneScribeThemeMoonleafModule/Resources/Production/received"
)
EVIDENCE_RELATIVE_ROOT = (
    "docs/verification/theme-fidelity-v4-3/source-masters/moonleaf"
)
PROVENANCE_FILENAME = "Moonleaf-Received-Identity-Extraction-v4.3.json"
MASK_SUPERSAMPLING = 8


@dataclass(frozen=True)
class SourceSpec:
    label: str
    relative_path: str
    sha256: str
    semantic_map_pixel_sha256_rgba: str
    decoded_pixel_sha256_rgba: str
    golden_relative_path: str
    golden_sha256: str
    duplicate_relative_path: str


@dataclass(frozen=True)
class AssetSpec:
    key: str
    resource_id: str
    role: str
    surface: str
    source_label: str
    bounds: tuple[int, int, int, int]
    output_filename: str

    @property
    def source_region_filename(self) -> str:
        return f"{self.output_filename.removesuffix('.png')}.source-region.png"


SOURCE_SPECS = {
    "received-primary": SourceSpec(
        label="received-primary",
        relative_path=(
            "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/"
            "approved-source-full-029-941x1672.png"
        ),
        sha256="d7266005ded25354980969d37c67be24efc00c491a080a19d6adc88f840d8e63",
        semantic_map_pixel_sha256_rgba="3dc24ec9a26f3b2df4f5d226bfaeecb643b08e1fc1903e3a9cd2d3fc4d5f77d0",
        decoded_pixel_sha256_rgba="e01d727d3882914a0b6323d5c1f4a7b8ccf63403bbecbdab2c786a4dbe48e71a",
        golden_relative_path=(
            "04-ASSETS/00-CONTROLLING-GOLDENS/Moonleaf/"
            "moonleaf-received-cipher-final-a.png"
        ),
        golden_sha256="23b96619f911ffc58be81e95869ea16b39b2e689a6b6164be77829d8e2a85b67",
        duplicate_relative_path=(
            "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/"
            "approved-source-full-033-941x1672.png"
        ),
    ),
    "received-share": SourceSpec(
        label="received-share",
        relative_path=(
            "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/"
            "approved-source-full-009-941x1672.png"
        ),
        sha256="3b2720262795e86840b38d7bac8da702f16d4290a2f3e8e395e0ed198b33890e",
        semantic_map_pixel_sha256_rgba="dfb2fb1f16d9b0e9302208cf6d21d57c3debcbb8f5fdbcc3f7ba8fdfb88ea20f",
        decoded_pixel_sha256_rgba="603ead20542138675c977e82a55fb3cc12f93f9da344095f1163024e5bc56410",
        golden_relative_path=(
            "04-ASSETS/00-CONTROLLING-GOLDENS/Moonleaf/"
            "moonleaf-received-cipher-final-b.png"
        ),
        golden_sha256="79446a4e03976835f5727b3e9285f00e004602cba8c9496122bed115b0657db4",
        duplicate_relative_path=(
            "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/"
            "approved-source-full-014-941x1672.png"
        ),
    ),
}


ASSET_SPECS = (
    AssetSpec(
        key="primary-sender-avatar",
        resource_id="resource.received.moonleaf.primary.sender-avatar",
        role="received.primary.sender-avatar",
        surface="received-primary",
        source_label="received-primary",
        bounds=(56, 228, 163, 335),
        output_filename="moonleaf-received-primary-sender-avatar.png",
    ),
    AssetSpec(
        key="share-sender-avatar",
        resource_id="resource.received.moonleaf.share.sender-avatar",
        role="received.share.sender-avatar",
        surface="received-share-card",
        source_label="received-share",
        bounds=(60, 224, 159, 323),
        output_filename="moonleaf-received-share-sender-avatar.png",
    ),
    AssetSpec(
        key="share-codex-badge",
        resource_id="resource.received.moonleaf.share.codex-badge",
        role="received.share.codex-badge",
        surface="received-share-card",
        source_label="received-share",
        bounds=(657, 247, 700, 290),
        output_filename="moonleaf-received-share-codex-badge.png",
    ),
    AssetSpec(
        key="primary-medallion",
        resource_id="resource.received.moonleaf.primary.medallion",
        role="received.primary.medallion",
        surface="received-primary",
        source_label="received-primary",
        bounds=(688, 880, 881, 1073),
        output_filename="moonleaf-received-primary-medallion.png",
    ),
    AssetSpec(
        key="share-medallion",
        resource_id="resource.received.moonleaf.share.medallion",
        role="received.share.medallion",
        surface="received-share-card",
        source_label="received-share",
        bounds=(625, 865, 766, 1006),
        output_filename="moonleaf-received-share-medallion.png",
    ),
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_pixels(image: Image.Image, mode: str) -> str:
    return hashlib.sha256(image.convert(mode).tobytes()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False, compress_level=9)


def ellipse_alpha(size: tuple[int, int], samples: int = MASK_SUPERSAMPLING) -> Image.Image:
    """Return deterministic subpixel coverage for an ellipse touching all four edges."""
    width, height = size
    if width <= 0 or height <= 0 or samples <= 0:
        raise ValueError("ellipse dimensions and sampling must be positive")
    center_x = width / 2.0
    center_y = height / 2.0
    radius_x = width / 2.0
    radius_y = height / 2.0
    offsets = tuple((index + 0.5) / samples for index in range(samples))
    sample_count = samples * samples
    data = bytearray(width * height)
    offset = 0
    for pixel_y in range(height):
        for pixel_x in range(width):
            inside = 0
            for sample_y in offsets:
                normalized_y = (pixel_y + sample_y - center_y) / radius_y
                normalized_y_squared = normalized_y * normalized_y
                for sample_x in offsets:
                    normalized_x = (pixel_x + sample_x - center_x) / radius_x
                    if normalized_x * normalized_x + normalized_y_squared <= 1.0:
                        inside += 1
            data[offset] = round(255 * inside / sample_count)
            offset += 1
    return Image.frombytes("L", size, bytes(data))


def validate_sources(authority_root: Path) -> dict[str, Image.Image]:
    sources: dict[str, Image.Image] = {}
    for label, spec in SOURCE_SPECS.items():
        source_path = authority_root / spec.relative_path
        golden_path = authority_root / spec.golden_relative_path
        duplicate_path = authority_root / spec.duplicate_relative_path
        if sha256_file(source_path) != spec.sha256:
            raise SystemExit(f"Moonleaf source digest differs: {spec.relative_path}")
        if sha256_file(golden_path) != spec.golden_sha256:
            raise SystemExit(f"Moonleaf golden digest differs: {spec.golden_relative_path}")
        if sha256_file(duplicate_path) != spec.sha256:
            raise SystemExit(f"Moonleaf duplicate source digest differs: {spec.duplicate_relative_path}")
        source = Image.open(source_path).convert("RGB")
        golden = Image.open(golden_path).convert("RGB")
        duplicate = Image.open(duplicate_path).convert("RGB")
        if source.size != (941, 1672) or golden.size != source.size or duplicate.size != source.size:
            raise SystemExit(f"Moonleaf received source dimensions differ: {label}")
        if sha256_pixels(source, "RGBA") != spec.decoded_pixel_sha256_rgba:
            raise SystemExit(f"Moonleaf received source pixels differ: {label}")
        if source.tobytes() != golden.tobytes() or source.tobytes() != duplicate.tobytes():
            raise SystemExit(f"Moonleaf received source aliases differ by pixel: {label}")
        sources[label] = source
    return sources


def max_channel_difference(first: Image.Image, second: Image.Image) -> int:
    difference = ImageChops.difference(first.convert("RGB"), second.convert("RGB"))
    return max(extrema[1] for extrema in difference.getextrema())


def image_dimensions(path: Path) -> list[int]:
    with Image.open(path) as image:
        return list(image.size)


def normalized_medallion_comparison(outputs: dict[str, Image.Image]) -> dict[str, Any]:
    primary = outputs["primary-medallion"].convert("RGBA")
    share = outputs["share-medallion"].convert("RGBA").resize(
        primary.size,
        Image.Resampling.LANCZOS,
    )
    primary_bytes = primary.tobytes()
    share_bytes = share.tobytes()
    exact_pixels = 0
    compared_pixels = 0
    absolute_channel_difference = 0
    maximum_channel_difference = 0
    for offset in range(0, len(primary_bytes), 4):
        if primary_bytes[offset + 3] < 250 or share_bytes[offset + 3] < 250:
            continue
        compared_pixels += 1
        primary_rgb = primary_bytes[offset : offset + 3]
        share_rgb = share_bytes[offset : offset + 3]
        if primary_rgb == share_rgb:
            exact_pixels += 1
        for primary_channel, share_channel in zip(primary_rgb, share_rgb):
            difference = abs(primary_channel - share_channel)
            absolute_channel_difference += difference
            maximum_channel_difference = max(maximum_channel_difference, difference)
    if compared_pixels == 0:
        raise SystemExit("Moonleaf medallion comparison has no opaque pixels")
    exact_agreement = exact_pixels / compared_pixels
    mean_difference = absolute_channel_difference / (compared_pixels * 3)
    return {
        "method": (
            "uniformly resize the share medallion to the primary square with Lanczos; "
            "compare RGB only where both alpha values are at least 250"
        ),
        "primaryDimensions": list(primary.size),
        "shareDimensions": list(outputs["share-medallion"].size),
        "comparedOpaquePixels": compared_pixels,
        "exactRGBPixelAgreementFraction": round(exact_agreement, 8),
        "meanAbsoluteChannelDifference": round(mean_difference, 8),
        "maximumChannelDifference": maximum_channel_difference,
        "pixelIdenticalAfterUniformScale": exact_agreement == 1.0,
        "decision": "use separate primary and share medallion resources",
    }


def build_assets(
    authority_root: Path,
    production_root: Path,
    evidence_root: Path,
    pipeline_path: Path,
) -> dict[str, Any]:
    sources = validate_sources(authority_root)
    production_root.mkdir(parents=True, exist_ok=True)
    evidence_root.mkdir(parents=True, exist_ok=True)
    outputs: dict[str, Image.Image] = {}
    records: list[dict[str, Any]] = []

    for spec in ASSET_SPECS:
        source = sources[spec.source_label]
        left, top, right, bottom = spec.bounds
        if right - left != bottom - top:
            raise SystemExit(f"Moonleaf identity extraction is not square: {spec.key}")
        region = source.crop(spec.bounds).convert("RGB")
        alpha = ellipse_alpha(region.size)
        output = region.convert("RGBA")
        output.putalpha(alpha)
        output_path = production_root / spec.output_filename
        source_region_path = evidence_root / spec.source_region_filename
        save_png(output, output_path)
        save_png(region, source_region_path)
        outputs[spec.key] = output

        reconstructed = Image.alpha_composite(region.convert("RGBA"), output).convert("RGB")
        alpha_histogram = alpha.histogram()
        transparent_pixels = alpha_histogram[0]
        opaque_pixels = alpha_histogram[255]
        edge_pixels = region.width * region.height - transparent_pixels - opaque_pixels
        records.append({
            "key": spec.key,
            "resourceID": spec.resource_id,
            "role": spec.role,
            "surface": spec.surface,
            "sourceLabel": spec.source_label,
            "sourcePath": SOURCE_SPECS[spec.source_label].relative_path,
            "sourceSHA256": SOURCE_SPECS[spec.source_label].sha256,
            "boundsLTRBExclusive": list(spec.bounds),
            "dimensions": list(region.size),
            "mask": {
                "kind": "ellipse",
                "boundary": "the four exact source-crop edges",
                "coverageSampling": f"{MASK_SUPERSAMPLING}x{MASK_SUPERSAMPLING}",
                "transparentPixels": transparent_pixels,
                "edgePixels": edge_pixels,
                "opaquePixels": opaque_pixels,
            },
            "transformation": (
                "source-pixel crop plus geometric ellipse alpha coverage; "
                "no resize, rotation, color adjustment, filtering, or content repair"
            ),
            "sourceRegionEvidence": {
                "path": f"{EVIDENCE_RELATIVE_ROOT}/{spec.source_region_filename}",
                "sha256": sha256_file(source_region_path),
                "pixelSHA256RGB": sha256_pixels(region, "RGB"),
            },
            "output": {
                "path": f"{PRODUCTION_RELATIVE_ROOT}/{spec.output_filename}",
                "sha256": sha256_file(output_path),
                "pixelSHA256RGBA": sha256_pixels(output, "RGBA"),
                "bytes": output_path.stat().st_size,
                "mediaType": "image/png",
                "dimensions": list(output.size),
                "hasAlpha": True,
            },
            "comparisonBackToSource": {
                "method": (
                    "alpha-composite the extracted RGBA pixels over their unchanged RGB "
                    "source region and compare with that exact source region"
                ),
                "maximumChannelDifference": max_channel_difference(region, reconstructed),
                "sourceRGBPlaneMaximumDifference": max_channel_difference(region, output),
            },
        })

    reuse_assessment = normalized_medallion_comparison(outputs)
    if reuse_assessment["pixelIdenticalAfterUniformScale"]:
        raise SystemExit("Moonleaf received medallions unexpectedly became pixel-identical")

    provenance = {
        "schemaVersion": "1.0",
        "id": "moonleaf.received-identity.extraction.v4.3",
        "theme": "Moonleaf",
        "generatedAtUTC": CREATED_AT,
        "pipeline": PIPELINE,
        "pipelineSHA256": sha256_file(pipeline_path),
        "authorityPolicy": (
            "offline extraction from owner-supplied full-resolution received-state sources; "
            "neither owner sources nor source-region evidence are runtime resources"
        ),
        "sourceSelection": {
            "controllingReceivedStates": [
                SOURCE_SPECS["received-primary"].golden_relative_path,
                SOURCE_SPECS["received-share"].golden_relative_path,
            ],
            "styleBoardReviewed": {
                "path": (
                    "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/"
                    "approved-source-full-002-1122x1402.png"
                ),
                "sha256": "2d1696abd8a7ddbfe81b89c2eb84933a516ba5a4bf8eaa2dae0edcbb3d3758ef",
                "use": "motif corroboration only; not an extraction source",
            },
            "decision": (
                "use received-state owner sources because their sender identities, compact "
                "badge, and medallions are the exact controlling screen objects"
            ),
        },
        "authorityInputs": [
            {
                "label": spec.label,
                "path": spec.relative_path,
                "sha256": spec.sha256,
                "semanticMapPixelSHA256RGBA": spec.semantic_map_pixel_sha256_rgba,
                "decodedPixelSHA256RGBA": spec.decoded_pixel_sha256_rgba,
                "dimensions": [941, 1672],
                "controllingGolden": {
                    "path": spec.golden_relative_path,
                    "sha256": spec.golden_sha256,
                    "pixelIdentical": True,
                },
                "duplicateOwnerSource": {
                    "path": spec.duplicate_relative_path,
                    "sha256": spec.sha256,
                    "byteIdentical": True,
                },
            }
            for spec in SOURCE_SPECS.values()
        ],
        "recipe": {
            "cropCoordinates": "left, top, right-exclusive, bottom-exclusive source pixels",
            "mask": (
                "ellipse touching the crop edges with deterministic 8x8 subpixel coverage"
            ),
            "resampling": "none",
            "colorTransformation": "none",
            "encoding": "lossless PNG with ancillary metadata omitted",
        },
        "reuseAssessment": reuse_assessment,
        "qualityReview": {
            "oneHundredPercent": "PASS",
            "twoHundredPercent": "PASS",
            "transparentEdgeReview": "PASS",
            "sourceRegionRoundTrip": "PASS",
            "targetDeviceRuntime": "PENDING_PROVIDER_BINDING",
        },
        "outputs": records,
        "rightsOwner": "Raven Forge Software",
        "licenseNotice": "Owner-supplied proprietary source",
    }
    write_json(evidence_root / PROVENANCE_FILENAME, provenance)
    return provenance


def expected_paths(production_root: Path, evidence_root: Path) -> Iterable[Path]:
    for spec in ASSET_SPECS:
        yield production_root / spec.output_filename
        yield evidence_root / spec.source_region_filename
    yield evidence_root / PROVENANCE_FILENAME


def check_assets(
    authority_root: Path,
    production_root: Path,
    evidence_root: Path,
    pipeline_path: Path,
) -> dict[str, Any]:
    sources = validate_sources(authority_root)
    provenance_path = evidence_root / PROVENANCE_FILENAME
    if not provenance_path.is_file():
        raise SystemExit("Moonleaf received identity provenance is absent")
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if provenance.get("pipeline") != PIPELINE:
        raise SystemExit("Moonleaf received identity pipeline path differs")
    if provenance.get("pipelineSHA256") != sha256_file(pipeline_path):
        raise SystemExit("Moonleaf received identity pipeline digest differs")
    records = provenance.get("outputs")
    if not isinstance(records, list) or len(records) != len(ASSET_SPECS):
        raise SystemExit("Moonleaf received identity provenance coverage differs")
    records_by_key = {record.get("key"): record for record in records}
    outputs: dict[str, Image.Image] = {}

    for spec in ASSET_SPECS:
        if spec.key not in records_by_key:
            raise SystemExit(f"Moonleaf identity provenance key absent: {spec.key}")
        record = records_by_key[spec.key]
        source_region = sources[spec.source_label].crop(spec.bounds).convert("RGB")
        expected_output = source_region.convert("RGBA")
        expected_output.putalpha(ellipse_alpha(source_region.size))
        output_path = production_root / spec.output_filename
        source_region_path = evidence_root / spec.source_region_filename
        if not output_path.is_file() or not source_region_path.is_file():
            raise SystemExit(f"Moonleaf identity extraction is absent: {spec.key}")
        output = Image.open(output_path).convert("RGBA")
        evidence = Image.open(source_region_path).convert("RGB")
        if output.size != source_region.size or output.tobytes() != expected_output.tobytes():
            raise SystemExit(f"Moonleaf identity output pixels differ: {spec.key}")
        if evidence.size != source_region.size or evidence.tobytes() != source_region.tobytes():
            raise SystemExit(f"Moonleaf source-region evidence differs: {spec.key}")
        if record.get("resourceID") != spec.resource_id or record.get("role") != spec.role:
            raise SystemExit(f"Moonleaf identity resource binding differs: {spec.key}")
        if record.get("boundsLTRBExclusive") != list(spec.bounds):
            raise SystemExit(f"Moonleaf identity source bounds differ: {spec.key}")
        if record.get("output", {}).get("sha256") != sha256_file(output_path):
            raise SystemExit(f"Moonleaf identity output digest differs: {spec.key}")
        if record.get("sourceRegionEvidence", {}).get("sha256") != sha256_file(source_region_path):
            raise SystemExit(f"Moonleaf identity evidence digest differs: {spec.key}")
        comparison = record.get("comparisonBackToSource", {})
        if comparison.get("maximumChannelDifference") != 0:
            raise SystemExit(f"Moonleaf identity source comparison differs: {spec.key}")
        if comparison.get("sourceRGBPlaneMaximumDifference") != 0:
            raise SystemExit(f"Moonleaf identity RGB plane differs: {spec.key}")
        outputs[spec.key] = output

    expected_reuse_assessment = normalized_medallion_comparison(outputs)
    if provenance.get("reuseAssessment") != expected_reuse_assessment:
        raise SystemExit("Moonleaf medallion reuse assessment differs")
    if expected_reuse_assessment["pixelIdenticalAfterUniformScale"]:
        raise SystemExit("Moonleaf medallions must not share one received-state resource")
    try:
        validate_runtime_state(pipeline_path.resolve().parents[1], provenance)
    except RuntimeEvidenceError as error:
        raise SystemExit(f"Moonleaf target-device runtime evidence differs: {error}") from error
    return {
        "status": "PASS",
        "assetCount": len(ASSET_SPECS),
        "sourceCount": len(SOURCE_SPECS),
        "pipelineSHA256": sha256_file(pipeline_path),
        "provenanceSHA256": sha256_file(provenance_path),
        "outputs": [
            {
                "key": spec.key,
                "sha256": sha256_file(production_root / spec.output_filename),
                "dimensions": image_dimensions(production_root / spec.output_filename),
            }
            for spec in ASSET_SPECS
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--authority-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()
    authority_root = args.authority_root.resolve()
    pipeline_path = repo_root / PIPELINE
    production_root = repo_root / PRODUCTION_RELATIVE_ROOT
    evidence_root = repo_root / EVIDENCE_RELATIVE_ROOT
    if not args.check:
        build_assets(authority_root, production_root, evidence_root, pipeline_path)
    summary = check_assets(authority_root, production_root, evidence_root, pipeline_path)
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
