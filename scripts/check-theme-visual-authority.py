#!/usr/bin/env python3
"""Validate the repository-owned Theme visual authority manifest."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple, Union

from PIL import Image, UnidentifiedImageError


SCHEMA_VERSION = "1.0"
DEFAULT_MANIFEST = Path(
    "docs/verification/theme-fidelity-v4/authority/asset-manifest.json"
)
IMAGE_EXTENSIONS = {
    ".bmp",
    ".gif",
    ".jpeg",
    ".jpg",
    ".png",
    ".tif",
    ".tiff",
    ".webp",
}
MANIFEST_KEYS = {
    "schemaVersion",
    "assetCount",
    "authorityRoot",
    "shippingRoots",
    "rejectedRoots",
    "rejectedAssetSHA256",
    "assets",
    "comparisons",
}
ASSET_KEYS = {
    "path",
    "sha256",
    "dimensions",
    "theme",
    "role",
    "tier",
}
COMPARISON_KEYS = {"id", "reference", "mask", "focalRegion"}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
PLACEHOLDER_PATTERN = re.compile(
    r"(?:^|[._-])(dummy|placeholder|sample|temp|temporary|todo)(?:[._-]|$)",
    flags=re.IGNORECASE,
)
REJECTED_PATH_TOKENS = {
    "90-rejected-baselines",
    "rejected",
    "rejected-baselines",
}
REFERENCE_PATH_TOKENS = {
    "00-controlling-goldens",
    "authority",
    "goldens",
    "reference-slices",
}


class DuplicateJSONKeyError(ValueError):
    pass


@dataclass(frozen=True, order=True)
class Finding:
    code: str
    path: str
    message: str


def reject_duplicate_keys(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateJSONKeyError("duplicate JSON key: {}".format(key))
        value[key] = item
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def path_tokens(path: Path) -> Set[str]:
    tokens: Set[str] = set()
    for part in path.parts:
        lowered = part.lower()
        tokens.add(lowered)
        tokens.update(item for item in re.split(r"[^a-z0-9]+", lowered) if item)
    return tokens


def is_image_path(path: Path) -> bool:
    return path.suffix.lower() in IMAGE_EXTENSIONS


def image_dimensions(path: Path) -> Tuple[int, int]:
    with Image.open(path) as image:
        image.load()
        return image.size


def placeholder_reason(path: Path, role: Optional[str] = None) -> Optional[str]:
    if PLACEHOLDER_PATTERN.search(path.stem):
        return "filename marks the image as a placeholder"
    if role is not None and "placeholder" in role.lower():
        return "manifest role marks the image as a placeholder"
    try:
        with Image.open(path) as image:
            image.load()
            rgba = image.convert("RGBA")
            if rgba.getchannel("A").getextrema()[1] == 0:
                return "image is fully transparent"
            if role is None or "mask" not in role.lower():
                extrema = rgba.getextrema()
                if all(low == high for low, high in extrema):
                    return "image is a single solid value"
    except (OSError, UnidentifiedImageError) as error:
        return "image cannot be decoded: {}".format(error)
    return None


class AuthorityChecker:
    def __init__(self, root: Path, manifest_path: Path) -> None:
        self.root = root.resolve()
        self.manifest_path = manifest_path.resolve()
        self.findings: List[Finding] = []
        self.manifest: Dict[str, Any] = {}
        self.manifest_sha256: Optional[str] = None
        self.declared_assets: Dict[str, Dict[str, Any]] = {}
        self.declared_inventory_paths: Set[str] = set()
        self.asset_digests: Set[str] = set()
        self.rejected_digests: Set[str] = set()
        self.authority_root: Optional[Path] = None
        self.shipping_roots: List[Path] = []
        self.rejected_roots: List[Path] = []

    def add(self, code: str, path: Union[Path, str], message: str) -> None:
        if isinstance(path, Path):
            display = self.display_path(path)
        else:
            display = path
        self.findings.append(Finding(code, display, message))

    def display_path(self, path: Path) -> str:
        try:
            return path.resolve().relative_to(self.root).as_posix()
        except ValueError:
            return str(path)

    def resolve_relative(self, raw: Any, label: str) -> Optional[Path]:
        if not isinstance(raw, str) or not raw.strip():
            self.add("invalid-path", label, "path must be a non-empty string")
            return None
        relative = Path(raw)
        if relative.is_absolute():
            self.add("invalid-path", raw, "path must be repository-relative")
            return None
        resolved = (self.root / relative).resolve()
        try:
            resolved.relative_to(self.root)
        except ValueError:
            self.add("invalid-path", raw, "path escapes the repository root")
            return None
        return resolved

    def resolve_authority_asset(self, raw: Any, label: str) -> Optional[Path]:
        if self.authority_root is None:
            return None
        if not isinstance(raw, str) or not raw.strip():
            self.add("invalid-path", label, "path must be a non-empty string")
            return None
        relative = Path(raw)
        if relative.is_absolute():
            self.add("invalid-path", raw, "asset path must be authorityRoot-relative")
            return None
        resolved = (self.authority_root / relative).resolve()
        try:
            resolved.relative_to(self.authority_root)
        except ValueError:
            self.add("invalid-path", raw, "asset path escapes authorityRoot")
            return None
        return resolved

    def load_manifest(self) -> bool:
        try:
            self.manifest_path.relative_to(self.root)
        except ValueError:
            self.add(
                "invalid-manifest-path",
                self.manifest_path,
                "manifest must be inside the repository root",
            )
            return False
        if not self.manifest_path.is_file():
            self.add("missing-manifest", self.manifest_path, "authority manifest is missing")
            return False
        try:
            raw = self.manifest_path.read_text(encoding="utf-8")
            decoded = json.loads(raw, object_pairs_hook=reject_duplicate_keys)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
            self.add("invalid-manifest", self.manifest_path, str(error))
            return False
        if not isinstance(decoded, dict):
            self.add("invalid-manifest", self.manifest_path, "manifest root must be an object")
            return False
        self.manifest = decoded
        self.manifest_sha256 = sha256_file(self.manifest_path)
        unknown = sorted(set(decoded) - MANIFEST_KEYS)
        if unknown:
            self.add(
                "unknown-manifest-field",
                self.manifest_path,
                "unknown top-level fields: {}".format(", ".join(unknown)),
            )
        if decoded.get("schemaVersion") != SCHEMA_VERSION:
            self.add(
                "invalid-schema-version",
                self.manifest_path,
                "schemaVersion must be {}".format(SCHEMA_VERSION),
            )
        return True

    def configure_roots(self) -> None:
        raw_authority = self.manifest.get("authorityRoot")
        self.authority_root = self.resolve_relative(raw_authority, "authorityRoot")
        if self.authority_root is not None and not self.authority_root.is_dir():
            self.add(
                "missing-authority-root",
                self.authority_root,
                "authority root is missing or is not a directory",
            )

        raw_shipping = self.manifest.get("shippingRoots")
        if not isinstance(raw_shipping, list) or not raw_shipping:
            self.add(
                "invalid-shipping-roots",
                self.manifest_path,
                "shippingRoots must be a non-empty array",
            )
        else:
            for index, raw in enumerate(raw_shipping):
                path = self.resolve_relative(raw, "shippingRoots[{}]".format(index))
                if path is None:
                    continue
                if not path.is_dir():
                    self.add(
                        "missing-shipping-root",
                        path,
                        "shipping root is missing or is not a directory",
                    )
                self.shipping_roots.append(path)

        raw_rejected = self.manifest.get("rejectedRoots", [])
        if not isinstance(raw_rejected, list):
            self.add(
                "invalid-rejected-roots",
                self.manifest_path,
                "rejectedRoots must be an array",
            )
        else:
            for index, raw in enumerate(raw_rejected):
                path = self.resolve_relative(raw, "rejectedRoots[{}]".format(index))
                if path is None:
                    continue
                if path.exists() and not path.is_dir():
                    self.add(
                        "invalid-rejected-root",
                        path,
                        "rejected root exists but is not a directory",
                    )
                self.rejected_roots.append(path)

        raw_digests = self.manifest.get("rejectedAssetSHA256", [])
        if not isinstance(raw_digests, list):
            self.add(
                "invalid-rejected-digests",
                self.manifest_path,
                "rejectedAssetSHA256 must be an array",
            )
        else:
            for index, digest in enumerate(raw_digests):
                if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
                    self.add(
                        "invalid-rejected-digest",
                        self.manifest_path,
                        "rejectedAssetSHA256[{}] must be a lowercase SHA-256".format(index),
                    )
                else:
                    self.rejected_digests.add(digest)

    def validate_assets(self) -> None:
        assets = self.manifest.get("assets")
        if not isinstance(assets, list) or not assets:
            self.add(
                "invalid-asset-inventory",
                self.manifest_path,
                "assets must be a non-empty array",
            )
            return
        asset_count = self.manifest.get("assetCount")
        if asset_count is not None and asset_count != len(assets):
            self.add(
                "asset-count-mismatch",
                self.manifest_path,
                "assetCount does not match the assets array",
            )

        for index, record in enumerate(assets):
            label = "assets[{}]".format(index)
            if not isinstance(record, dict):
                self.add("invalid-asset-record", label, "asset entry must be an object")
                continue
            unknown = sorted(set(record) - ASSET_KEYS)
            missing = sorted(ASSET_KEYS - set(record))
            if unknown:
                self.add(
                    "unknown-asset-field",
                    label,
                    "unknown fields: {}".format(", ".join(unknown)),
                )
            if missing:
                self.add(
                    "missing-asset-field",
                    label,
                    "missing fields: {}".format(", ".join(missing)),
                )
                continue

            raw_path = record["path"]
            path = self.resolve_authority_asset(raw_path, "{}.path".format(label))
            if path is None:
                continue
            if raw_path in self.declared_assets:
                self.add("duplicate-asset-path", path, "asset path is declared more than once")
                continue
            inventory_path = self.display_path(path)
            if inventory_path in self.declared_inventory_paths:
                self.add("duplicate-asset-path", path, "asset path resolves more than once")
                continue
            self.declared_assets[raw_path] = record
            self.declared_inventory_paths.add(inventory_path)

            if not is_image_path(path):
                self.add("invalid-asset-type", path, "authority asset must be an image")

            for field in ("theme", "role", "tier"):
                value = record[field]
                if not isinstance(value, str) or not value.strip():
                    self.add(
                        "invalid-asset-metadata",
                        path,
                        "{} must be a non-empty string".format(field),
                    )
            tier = record["tier"] if isinstance(record["tier"], str) else ""
            role = record["role"] if isinstance(record["role"], str) else ""
            if "rejected" in tier.lower() or "placeholder" in tier.lower():
                self.add(
                    "prohibited-authority-tier",
                    path,
                    "authority tier cannot be rejected or placeholder",
                )
            if path_tokens(Path(raw_path)) & REJECTED_PATH_TOKENS:
                self.add(
                    "rejected-authority-asset",
                    path,
                    "rejected-baseline path cannot be declared as authority",
                )

            expected_hash = record["sha256"]
            if not isinstance(expected_hash, str) or SHA256_PATTERN.fullmatch(expected_hash) is None:
                self.add(
                    "invalid-asset-sha256",
                    path,
                    "sha256 must be a lowercase 64-character digest",
                )
                expected_hash = None
            else:
                self.asset_digests.add(expected_hash)
            expected_dimensions = record["dimensions"]
            valid_dimensions = (
                isinstance(expected_dimensions, list)
                and len(expected_dimensions) == 2
                and all(
                    isinstance(item, int) and not isinstance(item, bool) and item > 0
                    for item in expected_dimensions
                )
            )
            if not valid_dimensions:
                self.add(
                    "invalid-asset-dimensions",
                    path,
                    "dimensions must contain two positive integers",
                )

            if not path.is_file():
                self.add("missing-asset", path, "declared authority asset is missing")
                continue
            try:
                actual_hash = sha256_file(path)
                actual_dimensions = image_dimensions(path)
            except (OSError, UnidentifiedImageError) as error:
                self.add("invalid-image", path, "image cannot be decoded: {}".format(error))
                continue
            self.asset_digests.add(actual_hash)
            if expected_hash is not None and actual_hash != expected_hash:
                self.add("stale-sha256", path, "asset SHA-256 does not match the manifest")
            if valid_dimensions and list(actual_dimensions) != expected_dimensions:
                self.add("stale-dimensions", path, "asset dimensions do not match the manifest")
            reason = placeholder_reason(path, role)
            if reason is not None:
                self.add("placeholder-asset", path, reason)

    def validate_declared_inventory(self) -> None:
        if self.authority_root is None or not self.authority_root.is_dir():
            return
        actual = {
            self.display_path(path)
            for path in self.authority_root.rglob("*")
            if path.is_file() and is_image_path(path)
        }
        declared = self.declared_inventory_paths
        for relative in sorted(actual - declared):
            self.add(
                "undeclared-authority-asset",
                relative,
                "image exists under authorityRoot but is absent from the manifest",
            )

    def collect_rejected_digests(self) -> None:
        for root in self.rejected_roots:
            if not root.is_dir():
                continue
            for path in sorted(root.rglob("*")):
                if path.is_file() and is_image_path(path):
                    try:
                        self.rejected_digests.add(sha256_file(path))
                    except OSError as error:
                        self.add(
                            "unreadable-rejected-asset",
                            path,
                            "cannot hash rejected asset: {}".format(error),
                        )

    def validate_shipping_assets(self) -> None:
        for root in self.shipping_roots:
            if not root.is_dir():
                continue
            for path in sorted(root.rglob("*")):
                if not path.is_file() or not is_image_path(path):
                    continue
                reason = placeholder_reason(path)
                if reason is not None:
                    self.add("placeholder-asset", path, reason)
                try:
                    digest = sha256_file(path)
                except OSError as error:
                    self.add("unreadable-shipping-asset", path, str(error))
                    continue
                relative_shipping_path = path.relative_to(root)
                directory_tokens = {
                    part.lower() for part in relative_shipping_path.parent.parts
                }
                rejected_tokens = path_tokens(relative_shipping_path)
                if digest in self.asset_digests or directory_tokens & REFERENCE_PATH_TOKENS:
                    self.add(
                        "reference-asset-shipped",
                        path,
                        "reference authority must not appear in a shipping resource root",
                    )
                if digest in self.rejected_digests or rejected_tokens & REJECTED_PATH_TOKENS:
                    self.add(
                        "rejected-asset-shipped",
                        path,
                        "rejected baseline must not appear in a shipping resource root",
                    )

    def validate_comparisons(self) -> None:
        comparisons = self.manifest.get("comparisons", [])
        if not isinstance(comparisons, list):
            self.add(
                "invalid-comparison-inventory",
                self.manifest_path,
                "comparisons must be an array",
            )
            return
        identifiers: Set[str] = set()
        for index, record in enumerate(comparisons):
            label = "comparisons[{}]".format(index)
            if not isinstance(record, dict):
                self.add("invalid-comparison-record", label, "comparison must be an object")
                continue
            unknown = sorted(set(record) - COMPARISON_KEYS)
            required = {"id", "reference", "focalRegion"}
            missing = sorted(required - set(record))
            if unknown:
                self.add(
                    "unknown-comparison-field",
                    label,
                    "unknown fields: {}".format(", ".join(unknown)),
                )
            if missing:
                self.add(
                    "missing-comparison-field",
                    label,
                    "missing fields: {}".format(", ".join(missing)),
                )
                continue
            identifier = record["id"]
            if not isinstance(identifier, str) or IDENTIFIER_PATTERN.fullmatch(identifier) is None:
                self.add(
                    "invalid-comparison-id",
                    label,
                    "id must be a stable identifier",
                )
            elif identifier in identifiers:
                self.add("duplicate-comparison-id", label, "comparison id is duplicated")
            else:
                identifiers.add(identifier)

            reference = record["reference"]
            reference_record = self.declared_assets.get(reference)
            if reference_record is None:
                self.add(
                    "unknown-comparison-reference",
                    label,
                    "reference must name a declared authority asset",
                )
                continue
            dimensions = reference_record.get("dimensions")
            focal = record["focalRegion"]
            if not self.valid_region(focal, dimensions):
                self.add(
                    "invalid-focal-region",
                    label,
                    "focalRegion must be an in-bounds x,y,width,height rectangle at least 7 pixels wide and high",
                )
            mask = record.get("mask")
            if mask is not None:
                mask_record = self.declared_assets.get(mask)
                if mask_record is None:
                    self.add(
                        "unknown-comparison-mask",
                        label,
                        "mask must name a declared authority asset",
                    )
                elif "mask" not in str(mask_record.get("role", "")).lower():
                    self.add(
                        "invalid-comparison-mask-role",
                        mask,
                        "comparison mask must use a mask role",
                    )
                elif mask_record.get("dimensions") != dimensions:
                    self.add(
                        "comparison-mask-dimensions",
                        mask,
                        "comparison mask dimensions must match its reference",
                    )

    @staticmethod
    def valid_region(region: Any, dimensions: Any) -> bool:
        if not (
            isinstance(region, list)
            and len(region) == 4
            and all(isinstance(item, int) and not isinstance(item, bool) for item in region)
            and isinstance(dimensions, list)
            and len(dimensions) == 2
        ):
            return False
        x, y, width, height = region
        image_width, image_height = dimensions
        return (
            x >= 0
            and y >= 0
            and width >= 7
            and height >= 7
            and x + width <= image_width
            and y + height <= image_height
        )

    def run(self) -> Dict[str, Any]:
        if self.load_manifest():
            self.configure_roots()
            self.validate_assets()
            self.validate_declared_inventory()
            self.collect_rejected_digests()
            self.validate_shipping_assets()
            self.validate_comparisons()
        findings = sorted(set(self.findings))
        result = {
            "schemaVersion": SCHEMA_VERSION,
            "result": "PASS" if not findings else "FAIL",
            "manifest": self.display_path(self.manifest_path),
            "manifestSHA256": self.manifest_sha256,
            "declaredAssetCount": len(self.declared_assets),
            "comparisonCount": len(self.manifest.get("comparisons", []))
            if isinstance(self.manifest.get("comparisons", []), list)
            else 0,
            "findings": [asdict(finding) for finding in findings],
        }
        return result


def atomic_write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate immutable Theme visual authority assets and shipping separation."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root. Defaults to the parent of scripts/.",
    )
    parser.add_argument("--output", type=Path, help="Optional JSON result path.")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_arguments(argv)
    root = args.root.resolve()
    manifest = root / DEFAULT_MANIFEST
    checker = AuthorityChecker(root, manifest)
    result = checker.run()
    if args.output is not None:
        output = (args.output if args.output.is_absolute() else root / args.output).resolve()
        protected = output == manifest.resolve()
        if checker.authority_root is not None:
            try:
                output.relative_to(checker.authority_root.resolve())
                protected = True
            except ValueError:
                pass
        if protected:
            result["result"] = "FAIL"
            result["findings"] = sorted(
                result["findings"]
                + [
                    asdict(
                        Finding(
                            "immutable-output-path",
                            checker.display_path(output),
                            "checker output must not be written inside authorityRoot",
                        )
                    )
                ],
                key=lambda item: (item["code"], item["path"], item["message"]),
            )
        else:
            rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
            atomic_write_text(output, rendered)
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    sys.stdout.write(rendered)
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
