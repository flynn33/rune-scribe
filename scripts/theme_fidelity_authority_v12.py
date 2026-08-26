#!/usr/bin/env python3
"""Load and validate the active Theme-fidelity v1.2 authority bundle."""

from __future__ import annotations

from collections import Counter, defaultdict
import csv
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import re
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple, Union

from PIL import Image, UnidentifiedImageError


SCHEMA_VERSION = "1.2"
AUTHORITY_VERSION = "4.2"
DEFAULT_IMPORT_MANIFEST = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/IMPORT-MANIFEST.json"
)
EXPECTED_IMPORT_ROOTS = (
    "01-CONTROLLING-DECISIONS",
    "02-COMPARISON-AUTHORITY",
    "03-AUTHORITY-ASSETS",
    "04-VERIFICATION-PATCH",
)
EXPECTED_ACTIVE_FILES = {
    "comparisonAuthority": "02-COMPARISON-AUTHORITY/Comparison-Authority-v1.2.json",
    "comparisonSchema": "02-COMPARISON-AUTHORITY/Comparison-Authority-Schema-v1.2.json",
    "candidateCatalog": "02-COMPARISON-AUTHORITY/Candidate-Capture-Catalog-v1.2.json",
    "runtimeProbeCatalog": "02-COMPARISON-AUTHORITY/Runtime-Probe-Catalog-v1.2.json",
    "deterministicSeedCatalog": "02-COMPARISON-AUTHORITY/Deterministic-Seed-Catalog-v1.2.json",
    "mappingCoverageReport": "02-COMPARISON-AUTHORITY/Mapping-Coverage-Report-v1.2.json",
    "mappingIndex": "02-COMPARISON-AUTHORITY/Reference-Candidate-Mapping-Index-v1.2.csv",
    "assetManifest": "03-AUTHORITY-ASSETS/AUTHORITY-ASSET-MANIFEST-v1.2.json",
    "gateCatalog": "04-VERIFICATION-PATCH/Gate-Catalog-v4.2.json",
    "matrix": "04-VERIFICATION-PATCH/Golden-Screenshot-Matrix-v1.2.json",
    "evidenceSchema": "04-VERIFICATION-PATCH/Visual-Comparison-Evidence-Index-Schema-v1.2.json",
}
EXPECTED_SOURCE_PACKAGE = {
    "identity": "Rune-Scribe-Theme-Fidelity-v4.2-Executable-Authority",
    "originalPackageManifestSHA256": "e3c0a9ddf371ff75ffe37855548ccbf5bb309c8dfe1a9ee64b0ffeaf36d285f0",
    "originalPackageValidationSHA256": "590472d3f1a1c3191f992ff93de2f650e2cd718c8c2fe50dec282d134a9942eb",
    "originalPackageChecksumsSHA256": "e2f287a9aa698b0bd5f007c3acd122e4eba4bbe4711a68278bedfe00febe7504",
    "v4.0ArchiveSHA256": "0f903b22d8032370b74cb89aa23300af6ba5f34c729f68b950ce52439c7ff238",
    "v4.1ArchiveSHA256": "e9884de9868acbb50657512628363dbb8d566498006b07071c4a65b68a635c1d",
}
EXPECTED_LEGACY_MANIFEST = Path(
    "docs/verification/theme-fidelity-v4/authority/asset-manifest.json"
)
EXPECTED_LEGACY_SHA256 = "68105fca6e59d053007afff72b2d966c80ac55a427209f32b0e47f148b30d6e1"
EXPECTED_ENTRY_COUNT = 400
EXPECTED_GROUP_COUNT = 100
EXPECTED_MAPPING_COUNT = 1104
EXPECTED_CANDIDATE_COUNT = 188
EXPECTED_PROBE_COUNT = 50
EXPECTED_SEED_COUNT = 100
EXPECTED_ASSET_COUNT = 113
EXPECTED_GATE_COUNT = 40
EXPECTED_FILE_COUNT = 133
EXPECTED_THEMES = ("Norse", "Moonleaf", "Sunspire", "Wildwood", "Gloamthorn")
EXPECTED_SURFACES = (
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
EXPECTED_DESTINATIONS = (
    "iphone-portrait",
    "ipad-portrait",
    "macos-standard",
    "macos-resized",
)
EXPECTED_DISPOSITIONS = {
    "image-metric": 400,
    "structural-assertion": 700,
    "negative-invariant": 4,
}
EXPECTED_REFERENCE_ROLES = {
    "focal": 380,
    "structural-only": 704,
    "full-screen": 20,
}
EXPECTED_COMPARISON_MODES = {
    "explicit-image-mappings": 60,
    "responsive-structural-plus-explicit-focal": 183,
    "negative-invariant": 4,
    "responsive-structural-only": 133,
    "runtime-behavior-plus-explicit-reference-mappings": 20,
}
EXPECTED_NORMALIZATION_USAGE = {
    "structural-reference-full-image-v1": 700,
    "focal-complete-image-aspect-fit-v1": 356,
    "renderer-complete-image-aspect-fit-v1": 24,
    "direct-screen-system-chrome-v1": 20,
    "negative-invariant-v1": 4,
}
EXPECTED_THRESHOLD_USAGE = {
    "responsive-structural-v1": 700,
    "focal-asset-v1": 380,
    "direct-screen-v1": 20,
    "negative-invariant-v1": 4,
}
EXPECTED_CANDIDATE_FIELD_USAGE = {
    "candidateElementID": 1040,
    "candidateRendererOutputID": 60,
    "candidateProbeID": 4,
}
EXPECTED_ASSET_AUTHORITY_COUNTS = {
    "approved-authority-asset": 95,
    "accepted-production-candidate": 18,
}
EXPECTED_DUPLICATE_ASSET_HASHES = {
    "0a3fb35ab47efb272dab404a081a5d4d603fef91ec9d4093a917bf77311f66a1": {
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-codex-catalog-final-alt.png",
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-codex-catalog-series.png",
    },
    "b02a1fee731eeaae5846f29a2d1e4621e2c98fb8b47a962ca64efa4fe64f1467": {
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-compose-a.png",
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-compose-final-a.png",
    },
    "23b96619f911ffc58be81e95869ea16b39b2e689a6b6164be77829d8e2a85b67": {
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-received-cipher-a.png",
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-received-cipher-final-a.png",
    },
    "79446a4e03976835f5727b3e9285f00e004602cba8c9496122bed115b0657db4": {
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-received-cipher-b.png",
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-received-cipher-final-b.png",
    },
    "fc6ba65b4683815366b14c30b3178f67f89e085b226a07a82f5b820034eabc1b": {
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-tablet-detail-a.png",
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Moonleaf/moonleaf-tablet-detail-final.png",
    },
    "e9c1f4a00ebbd7666d409193dc39222494e2414b48d9b42bbfacfb14cd087bd6": {
        "03-AUTHORITY-ASSETS/Controlling-Goldens/Norse/norse-codex-controlling-board.png",
        "03-AUTHORITY-ASSETS/Reference-Slices/Norse/00-approved-board.png",
    },
}
EXPECTED_THRESHOLD_PROFILES = {
    "direct-screen-v1": {
        "fullScreenLuminanceSSIMMinimum": 0.92,
        "edgeSSIMMinimum": 0.94,
        "focalSSIMMinimum": 0.95,
        "medianDeltaEMaximum": 4,
        "p95DeltaEMaximum": 12,
        "severeDeltaEPercentMaximum": 2,
        "maskPolicy": "Only platform-owned status/window chrome, transient cursor, and scrollbar pixels.",
    },
    "focal-asset-v1": {
        "candidateSource": "Accessibility-element snapshot or deterministic renderer output; no hand crop.",
        "focalSSIMMinimum": 0.95,
        "edgeSSIMMinimum": 0.94,
        "medianDeltaEMaximum": 4,
        "p95DeltaEMaximum": 12,
        "severeDeltaEPercentMaximum": 2,
        "maskPolicy": "No mask for pre-extracted reference slices or element snapshots.",
    },
    "responsive-structural-v1": {
        "fullScreenPixelMetricRequired": False,
        "allStructuralAssertionsRequired": True,
        "referenceHashRequired": True,
        "candidateIdentifierRequired": True,
    },
    "runtime-reduce-motion-v1": {
        "allVisualMappingsRequired": True,
        "allRuntimeProbesRequired": True,
        "minimumCaptureSeparationSeconds": 1.5,
        "minimumFrameStabilitySSIM": 0.995,
    },
    "negative-invariant-v1": {
        "requiredElementAbsence": True,
        "requiresBaseOwnership": True,
        "requiresBaseSelectable": True,
        "requiresFallbackAvailable": True,
        "requiresOptionalLockedRendererCoverage": True,
    },
}
EXPECTED_STRUCTURAL_ASSERTIONS = {
    "assert.element.exists": {"operator": "exists", "expected": True},
    "assert.element.visible": {"operator": "visible", "expected": True},
    "assert.element.viewport-contained": {
        "operator": "viewport-contained",
        "expected": True,
        "tolerancePoints": 1,
    },
    "assert.no-horizontal-overflow": {"operator": "horizontal-overflow", "expected": False},
    "assert.mobile-hit-targets": {"operator": "minimum-hit-target", "expectedMinimumPoints": 44},
    "assert.no-placeholder-art": {"operator": "placeholder-resource-count", "expected": 0},
    "assert.no-system-symbol-artifact": {"operator": "system-symbol-artifact-count", "expected": 0},
    "assert.safe-region-no-overlap": {"operator": "artifact-safe-region-overlap", "expected": False},
    "assert.state-text-shape-truthful": {"operator": "state-text-shape-consistency", "expected": True},
    "assert.interactive-static-plan-parity": {"operator": "composition-plan-equality", "expected": True},
    "assert.all-three-relics-present": {"operator": "relic-id-set-exact", "expectedCount": 3},
    "assert.all-six-seals-present": {"operator": "seal-id-set-exact", "expectedCount": 6},
    "assert.mastery-frame-crest-title-present": {
        "operator": "mastery-component-set-exact",
        "expectedCount": 3,
    },
    "assert.large-text-required-controls-visible": {
        "operator": "required-controls-visible",
        "expected": True,
    },
}
EXPECTED_FULL_SOURCE_CROP = {
    "mode": "full-image",
    "normalizedRect": {"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0},
    "manualCoordinatesAllowed": False,
}
EXPECTED_MAPPING_SEMANTICS = {
    (
        "focal",
        "image-metric",
        "focal-complete-image-aspect-fit-v1",
        "focal-asset-v1",
    ),
    (
        "focal",
        "image-metric",
        "renderer-complete-image-aspect-fit-v1",
        "focal-asset-v1",
    ),
    (
        "structural-only",
        "structural-assertion",
        "structural-reference-full-image-v1",
        "responsive-structural-v1",
    ),
    (
        "structural-only",
        "negative-invariant",
        "negative-invariant-v1",
        "negative-invariant-v1",
    ),
    (
        "full-screen",
        "image-metric",
        "direct-screen-system-chrome-v1",
        "direct-screen-v1",
    ),
}
NEGATIVE_RUNTIME_PROBES = {
    "probe.norse.vault.locked-element-count",
    "probe.norse.base-owned",
    "probe.norse.base-selectable",
    "probe.norse.fallback-available",
    "probe.optional-codex.locked-renderer-covered",
}
CSV_FIELDS = [
    "entryID",
    "mappingID",
    "theme",
    "surface",
    "destination",
    "referenceAsset",
    "referenceRole",
    "scoreDisposition",
    "candidateKind",
    "candidateID",
    "normalizationPolicy",
    "thresholdProfile",
]
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
SOURCE_SHA_PATTERN = "^[0-9a-f]{40}$"
IMAGE_EXTENSIONS = {".bmp", ".gif", ".jpeg", ".jpg", ".png", ".tif", ".tiff", ".webp"}
PLACEHOLDER_PATTERN = re.compile(
    r"(?:^|[._-])(dummy|placeholder|sample|temp|temporary|todo)(?:[._-]|$)",
    flags=re.IGNORECASE,
)
REJECTED_PATH_TOKENS = {"90-rejected-baselines", "rejected", "rejected-baselines"}
REFERENCE_PATH_TOKENS = {"00-controlling-goldens", "authority", "goldens", "reference-slices"}
PROHIBITED_META_MARKERS = tuple(
    "".join(parts).casefold()
    for parts in (
        ("open", "ai"),
        ("chat", "gpt"),
        ("anth", "ropic"),
        ("clau", "de"),
        ("artificial", " intelligence"),
        ("language", " model"),
        ("generated", " by ", "ai"),
        ("ai", "-generated"),
        ("codex", " continuation"),
        ("codex", "-required"),
    )
)


class DuplicateJSONKeyError(ValueError):
    """Raised when a JSON object repeats a key."""


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


def load_json(path: Path) -> Any:
    """Load UTF-8 JSON while rejecting repeated object keys."""
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def payload_aggregate_sha256(records: Sequence[Mapping[str, Any]]) -> str:
    encoded = json.dumps(records, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def path_tokens(path: Path) -> Set[str]:
    tokens: Set[str] = set()
    for part in path.parts:
        lowered = part.casefold()
        tokens.add(lowered)
        tokens.update(item for item in re.split(r"[^a-z0-9]+", lowered) if item)
    return tokens


def is_image_path(path: Path) -> bool:
    return path.suffix.casefold() in IMAGE_EXTENSIONS


def placeholder_reason(path: Path) -> Optional[str]:
    if PLACEHOLDER_PATTERN.search(path.stem):
        return "filename marks the image as a placeholder"
    try:
        with Image.open(path) as image:
            image.load()
            rgba = image.convert("RGBA")
            if rgba.getchannel("A").getextrema()[1] == 0:
                return "image is fully transparent"
            if all(low == high for low, high in rgba.getextrema()):
                return "image is a single solid value"
    except (OSError, UnidentifiedImageError) as error:
        return "image cannot be decoded: {}".format(error)
    return None


class AuthorityV12Checker:
    """Cross-validate the imported v1.2 authority and repository separation."""

    def __init__(self, root: Path, manifest_path: Path) -> None:
        self.root = root.resolve()
        self.manifest_path = manifest_path.resolve()
        self.authority_root = self.manifest_path.parent
        self.manifest_sha256: Optional[str] = None
        self.manifest: Dict[str, Any] = {}
        self.findings: List[Finding] = []
        self.documents: Dict[str, Any] = {}
        self.active_paths: Dict[str, Path] = {}
        self.assets: Dict[str, Dict[str, Any]] = {}
        self.candidates: Dict[str, Dict[str, Any]] = {}
        self.probes: Dict[str, Dict[str, Any]] = {}
        self.seeds: Dict[str, Dict[str, Any]] = {}
        self.entries: List[Dict[str, Any]] = []
        self.mappings: List[Tuple[Dict[str, Any], Dict[str, Any]]] = []
        self.mapping_ids: Set[str] = set()
        self.authority_asset_digests: Set[str] = set()
        self.rejected_digests: Set[str] = set()
        self.counts = {
            "entryCount": 0,
            "themeSurfaceAuthorityCount": 0,
            "mappingCount": 0,
            "candidateCount": 0,
            "runtimeProbeCount": 0,
            "seedCount": 0,
            "assetCount": 0,
            "gateCount": 0,
            "declaredDuplicateHashGroupCount": 0,
        }

    def display_path(self, path: Path) -> str:
        try:
            return path.resolve().relative_to(self.root).as_posix()
        except ValueError:
            return str(path)

    def add(self, code: str, path: Union[Path, str], message: str) -> None:
        display = self.display_path(path) if isinstance(path, Path) else path
        self.findings.append(Finding(code, display, message))

    def expect(self, condition: bool, code: str, path: Union[Path, str], message: str) -> None:
        if not condition:
            self.add(code, path, message)

    def expect_exact_keys(
        self,
        value: Any,
        expected: Set[str],
        code: str,
        label: str,
    ) -> bool:
        if not isinstance(value, dict):
            self.add(code, label, "value must be an object")
            return False
        actual = set(value)
        if actual != expected:
            missing = sorted(expected - actual)
            extra = sorted(actual - expected)
            details = []
            if missing:
                details.append("missing {}".format(", ".join(missing)))
            if extra:
                details.append("unknown {}".format(", ".join(extra)))
            self.add(code, label, "; ".join(details))
            return False
        return True

    def resolve_within(self, base: Path, raw: Any, label: str) -> Optional[Path]:
        if not isinstance(raw, str) or not raw.strip():
            self.add("invalid-path", label, "path must be a non-empty string")
            return None
        relative = Path(raw)
        if relative.is_absolute():
            self.add("invalid-path", raw, "path must be relative")
            return None
        resolved = (base / relative).resolve()
        try:
            resolved.relative_to(base.resolve())
        except ValueError:
            self.add("invalid-path", raw, "path escapes its declared root")
            return None
        return resolved

    def resolve_repo_path(self, raw: Any, label: str) -> Optional[Path]:
        return self.resolve_within(self.root, raw, label)

    def resolve_authority_path(self, raw: Any, label: str) -> Optional[Path]:
        return self.resolve_within(self.authority_root, raw, label)

    def load_import_manifest(self) -> bool:
        try:
            self.manifest_path.relative_to(self.root)
        except ValueError:
            self.add("invalid-manifest-path", self.manifest_path, "manifest must be inside the repository")
            return False
        if not self.manifest_path.is_file():
            self.add("missing-manifest", self.manifest_path, "active authority import manifest is missing")
            return False
        try:
            decoded = load_json(self.manifest_path)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
            self.add("invalid-manifest", self.manifest_path, str(error))
            return False
        if not isinstance(decoded, dict):
            self.add("invalid-manifest", self.manifest_path, "manifest root must be an object")
            return False
        self.manifest = decoded
        self.manifest_sha256 = sha256_file(self.manifest_path)
        self.expect_exact_keys(
            decoded,
            {
                "schemaVersion",
                "authorityVersion",
                "status",
                "sourcePackage",
                "importPolicy",
                "legacyAuthority",
                "repositoryPolicy",
                "activeFiles",
                "fileCount",
                "payloadAggregateSHA256",
                "files",
            },
            "invalid-import-manifest-fields",
            self.display_path(self.manifest_path),
        )
        self.expect(decoded.get("schemaVersion") == "1.0", "invalid-import-schema", self.manifest_path, "schemaVersion must be 1.0")
        self.expect(decoded.get("authorityVersion") == AUTHORITY_VERSION, "inactive-authority-version", self.manifest_path, "authorityVersion must be 4.2")
        self.expect(decoded.get("status") == "active-acceptance-authority", "inactive-authority-version", self.manifest_path, "v1.2 must be the active acceptance authority")
        return True

    def validate_import_manifest(self) -> None:
        source = self.manifest.get("sourcePackage")
        self.expect(source == EXPECTED_SOURCE_PACKAGE, "source-package-identity-drift", self.manifest_path, "source package identity and original hashes must match the approved v4.2 package")
        policy = self.manifest.get("importPolicy")
        if self.expect_exact_keys(policy, {"includedRoots", "excludedContent"}, "invalid-import-policy", "importPolicy"):
            self.expect(policy["includedRoots"] == list(EXPECTED_IMPORT_ROOTS), "invalid-import-roots", self.manifest_path, "only the controlling 01/02/03/04 roots may be imported")
            self.expect(isinstance(policy["excludedContent"], str) and bool(policy["excludedContent"].strip()), "invalid-import-policy", self.manifest_path, "excludedContent must state the repository boundary")

        active = self.manifest.get("activeFiles")
        self.expect(active == EXPECTED_ACTIVE_FILES, "active-file-set-drift", self.manifest_path, "active v1.2 file mapping must be exact")
        if isinstance(active, dict):
            for name, raw in active.items():
                path = self.resolve_authority_path(raw, "activeFiles.{}".format(name))
                if path is not None:
                    self.active_paths[name] = path
                    self.expect(path.is_file(), "missing-active-file", path, "active authority file is missing")

        legacy = self.manifest.get("legacyAuthority")
        expected_legacy = {
            "path": EXPECTED_LEGACY_MANIFEST.as_posix(),
            "sha256": EXPECTED_LEGACY_SHA256,
            "status": "historical-inactive",
        }
        self.expect(legacy == expected_legacy, "legacy-authority-status-drift", self.manifest_path, "legacy v1.0 authority must remain hash-pinned and historical-inactive")
        if isinstance(legacy, dict):
            legacy_path = self.resolve_repo_path(legacy.get("path"), "legacyAuthority.path")
            if legacy_path is not None:
                self.expect(legacy_path.is_file(), "missing-legacy-authority", legacy_path, "historical v1.0 authority is missing")
                if legacy_path.is_file():
                    self.expect(sha256_file(legacy_path) == legacy.get("sha256"), "legacy-authority-hash-drift", legacy_path, "historical v1.0 authority hash changed")

        repository_policy = self.manifest.get("repositoryPolicy")
        if not self.expect_exact_keys(repository_policy, {"shippingRoots", "rejectedRoots", "rejectedAssetSHA256"}, "invalid-repository-policy", "repositoryPolicy"):
            return
        shipping = repository_policy["shippingRoots"]
        rejected = repository_policy["rejectedRoots"]
        rejected_hashes = repository_policy["rejectedAssetSHA256"]
        self.expect(isinstance(shipping, list) and len(shipping) == 5 and all(isinstance(item, str) for item in shipping) and len(set(shipping)) == 5, "invalid-shipping-roots", self.manifest_path, "five unique Theme shipping roots are required")
        self.expect(isinstance(rejected, list) and rejected == ["docs/verification/theme-fidelity-v4/rejected"], "invalid-rejected-roots", self.manifest_path, "rejected root must preserve the repository policy")
        self.expect(isinstance(rejected_hashes, list) and len(rejected_hashes) == 5 and all(is_sha256(item) for item in rejected_hashes) and len(set(rejected_hashes)) == 5, "invalid-rejected-digests", self.manifest_path, "five unique rejected asset hashes are required")
        if isinstance(rejected_hashes, list):
            self.rejected_digests.update(item for item in rejected_hashes if is_sha256(item))

        records = self.manifest.get("files")
        if not isinstance(records, list):
            self.add("invalid-import-inventory", self.manifest_path, "files must be an array")
            return
        self.expect(self.manifest.get("fileCount") == EXPECTED_FILE_COUNT == len(records), "import-file-count-mismatch", self.manifest_path, "import must contain exactly 133 files")
        declared_paths: List[str] = []
        for index, record in enumerate(records):
            label = "files[{}]".format(index)
            if not self.expect_exact_keys(record, {"path", "byteCount", "sha256"}, "invalid-import-record", label):
                continue
            raw = record["path"]
            if isinstance(raw, str):
                declared_paths.append(raw)
                self.expect(Path(raw).parts[:1] in {(root,) for root in EXPECTED_IMPORT_ROOTS}, "invalid-import-root", raw, "imported file is outside the controlling subset")
            path = self.resolve_authority_path(raw, label)
            if path is None:
                continue
            self.expect(path.is_file(), "missing-imported-file", path, "imported file is missing")
            self.expect(isinstance(record["byteCount"], int) and not isinstance(record["byteCount"], bool) and record["byteCount"] >= 0, "invalid-import-byte-count", path, "byteCount must be a non-negative integer")
            self.expect(is_sha256(record["sha256"]), "invalid-import-sha256", path, "sha256 must be a lowercase digest")
            if path.is_file():
                self.expect(path.stat().st_size == record["byteCount"], "import-byte-count-drift", path, "imported file byte count changed")
                self.expect(sha256_file(path) == record["sha256"], "import-hash-drift", path, "imported file hash changed")
        self.expect(declared_paths == sorted(declared_paths), "import-inventory-order", self.manifest_path, "import inventory must be sorted by path")
        self.expect(len(declared_paths) == len(set(declared_paths)), "duplicate-import-path", self.manifest_path, "import inventory paths must be unique")
        actual_paths = sorted(
            path.relative_to(self.authority_root).as_posix()
            for root_name in EXPECTED_IMPORT_ROOTS
            for path in (self.authority_root / root_name).rglob("*")
            if path.is_file()
        )
        self.expect(actual_paths == declared_paths, "import-inventory-drift", self.manifest_path, "actual controlling files must exactly match the import inventory")
        aggregate = payload_aggregate_sha256(records)
        self.expect(is_sha256(self.manifest.get("payloadAggregateSHA256")) and self.manifest.get("payloadAggregateSHA256") == aggregate, "import-aggregate-drift", self.manifest_path, "payload aggregate hash does not match the imported records")
        self.validate_import_meta_boundary(actual_paths)

    def validate_import_meta_boundary(self, paths: Sequence[str]) -> None:
        for raw in paths:
            lowered_path = raw.casefold()
            for marker in PROHIBITED_META_MARKERS:
                if marker in lowered_path:
                    self.add("prohibited-import-meta", raw, "imported filename contains a prohibited meta-attribution marker")
            path = self.authority_root / raw
            if path.suffix.casefold() not in {".json", ".md", ".csv", ".txt"}:
                continue
            try:
                lowered_text = path.read_text(encoding="utf-8").casefold()
            except (OSError, UnicodeDecodeError) as error:
                self.add("unreadable-imported-text", path, str(error))
                continue
            for marker in PROHIBITED_META_MARKERS:
                if marker in lowered_text:
                    self.add("prohibited-import-meta", path, "imported content contains a prohibited meta-attribution marker")
                    break

    def load_active_documents(self) -> None:
        for name, path in self.active_paths.items():
            if name == "mappingIndex" or not path.is_file():
                continue
            try:
                decoded = load_json(path)
            except (OSError, UnicodeDecodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
                self.add("invalid-active-json", path, str(error))
                continue
            if not isinstance(decoded, dict):
                self.add("invalid-active-json", path, "document root must be an object")
                continue
            self.documents[name] = decoded

    def validate_schemas(self) -> None:
        schema = self.documents.get("comparisonSchema")
        if isinstance(schema, dict):
            properties = schema.get("properties", {})
            entries = properties.get("entries", {}) if isinstance(properties, dict) else {}
            required = schema.get("required", [])
            self.expect(schema.get("$schema") == "https://json-schema.org/draft/2020-12/schema", "comparison-schema-drift", self.active_paths["comparisonSchema"], "comparison schema draft must remain 2020-12")
            self.expect(schema.get("$id") == "runescribe.theme-fidelity.comparison-authority.schema.v1.2", "comparison-schema-drift", self.active_paths["comparisonSchema"], "comparison schema ID changed")
            self.expect(schema.get("type") == "object" and isinstance(required, list) and {"schemaVersion", "authorityID", "expectedEntryCount", "expectedReferenceMappingCount", "entries"}.issubset(required), "comparison-schema-drift", self.active_paths["comparisonSchema"], "comparison schema required fields are incomplete")
            self.expect(properties.get("schemaVersion") == {"const": SCHEMA_VERSION}, "comparison-schema-drift", self.active_paths["comparisonSchema"], "schemaVersion must be fixed to 1.2")
            self.expect(properties.get("expectedEntryCount") == {"const": EXPECTED_ENTRY_COUNT}, "comparison-schema-drift", self.active_paths["comparisonSchema"], "entry count must be fixed to 400")
            self.expect(properties.get("reviewedEntryCount") == {"const": EXPECTED_ENTRY_COUNT}, "comparison-schema-drift", self.active_paths["comparisonSchema"], "reviewed entry count must be fixed to 400")
            self.expect(properties.get("unreviewedEntryCount") == {"const": 0}, "comparison-schema-drift", self.active_paths["comparisonSchema"], "unreviewed entry count must be fixed to zero")
            self.expect(entries.get("minItems") == EXPECTED_ENTRY_COUNT and entries.get("maxItems") == EXPECTED_ENTRY_COUNT, "comparison-schema-drift", self.active_paths["comparisonSchema"], "entries must require exactly 400 records")

        evidence = self.documents.get("evidenceSchema")
        if isinstance(evidence, dict):
            properties = evidence.get("properties", {})
            entries = properties.get("entries", {}) if isinstance(properties, dict) else {}
            self.expect(evidence.get("$schema") == "https://json-schema.org/draft/2020-12/schema", "evidence-schema-drift", self.active_paths["evidenceSchema"], "evidence schema draft must remain 2020-12")
            self.expect(evidence.get("$id") == "runescribe.theme-fidelity.visual-comparison-index.schema.v1.2", "evidence-schema-drift", self.active_paths["evidenceSchema"], "evidence schema ID changed")
            self.expect(properties.get("schemaVersion") == {"const": SCHEMA_VERSION}, "evidence-schema-drift", self.active_paths["evidenceSchema"], "evidence schema version must be 1.2")
            self.expect(properties.get("sourceSHA") == {"type": "string", "pattern": SOURCE_SHA_PATTERN}, "evidence-schema-drift", self.active_paths["evidenceSchema"], "evidence sourceSHA contract changed")
            self.expect(properties.get("entryCount") == {"const": EXPECTED_ENTRY_COUNT}, "evidence-schema-drift", self.active_paths["evidenceSchema"], "evidence entry count must be 400")
            self.expect(properties.get("mappingCount") == {"const": EXPECTED_MAPPING_COUNT}, "evidence-schema-drift", self.active_paths["evidenceSchema"], "evidence mapping count must be 1104")
            self.expect(entries.get("minItems") == EXPECTED_ENTRY_COUNT and entries.get("maxItems") == EXPECTED_ENTRY_COUNT, "evidence-schema-drift", self.active_paths["evidenceSchema"], "evidence entries must require exactly 400 records")

    def validate_assets(self) -> None:
        document = self.documents.get("assetManifest")
        if not isinstance(document, dict):
            return
        path = self.active_paths["assetManifest"]
        self.expect_exact_keys(document, {"schemaVersion", "assetCount", "assets"}, "invalid-asset-manifest", self.display_path(path))
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION, "invalid-asset-schema", path, "asset schemaVersion must be 1.2")
        records = document.get("assets")
        if not isinstance(records, list):
            self.add("invalid-asset-inventory", path, "assets must be an array")
            return
        self.counts["assetCount"] = len(records)
        self.expect(document.get("assetCount") == EXPECTED_ASSET_COUNT == len(records), "asset-count-mismatch", path, "authority must declare exactly 113 assets")
        ordered_paths: List[str] = []
        assets_by_hash: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
        authority_counts: Counter[str] = Counter()
        for index, record in enumerate(records):
            label = "assets[{}]".format(index)
            if not self.expect_exact_keys(record, {"path", "byteCount", "sha256", "dimensions", "authority"}, "invalid-asset-record", label):
                continue
            raw = record["path"]
            if isinstance(raw, str):
                ordered_paths.append(raw)
            asset_path = self.resolve_authority_path(raw, label)
            if asset_path is None:
                continue
            self.expect(isinstance(raw, str) and Path(raw).parts[:1] == ("03-AUTHORITY-ASSETS",), "invalid-asset-path", asset_path, "asset must live below 03-AUTHORITY-ASSETS")
            self.expect(raw not in self.assets, "duplicate-asset-path", asset_path, "asset path is declared more than once")
            if isinstance(raw, str) and raw not in self.assets:
                self.assets[raw] = record
            self.expect(isinstance(record["byteCount"], int) and not isinstance(record["byteCount"], bool) and record["byteCount"] > 0, "invalid-asset-byte-count", asset_path, "byteCount must be positive")
            self.expect(is_sha256(record["sha256"]), "invalid-asset-sha256", asset_path, "sha256 must be a lowercase digest")
            dimensions = record["dimensions"]
            valid_dimensions = isinstance(dimensions, list) and len(dimensions) == 2 and all(isinstance(item, int) and not isinstance(item, bool) and item > 0 for item in dimensions)
            self.expect(valid_dimensions, "invalid-asset-dimensions", asset_path, "dimensions must contain two positive integers")
            authority_value = record["authority"]
            self.expect(isinstance(authority_value, str) and authority_value in EXPECTED_ASSET_AUTHORITY_COUNTS, "invalid-asset-authority", asset_path, "asset authority classification is invalid")
            if isinstance(authority_value, str):
                authority_counts[authority_value] += 1
            if is_sha256(record["sha256"]):
                assets_by_hash[record["sha256"]].append(record)
                self.authority_asset_digests.add(record["sha256"])
            self.expect(is_image_path(asset_path), "invalid-asset-type", asset_path, "authority asset must be an image")
            self.expect(asset_path.is_file(), "missing-asset", asset_path, "declared authority asset is missing")
            if not asset_path.is_file():
                continue
            self.expect(asset_path.stat().st_size == record["byteCount"], "stale-asset-byte-count", asset_path, "asset byte count does not match")
            try:
                actual_hash = sha256_file(asset_path)
                with Image.open(asset_path) as image:
                    image.load()
                    actual_dimensions = list(image.size)
            except (OSError, UnidentifiedImageError) as error:
                self.add("invalid-image", asset_path, "image cannot be decoded: {}".format(error))
                continue
            self.expect(actual_hash == record["sha256"], "stale-asset-sha256", asset_path, "asset hash does not match")
            self.expect(not valid_dimensions or actual_dimensions == dimensions, "stale-asset-dimensions", asset_path, "asset dimensions do not match")
            reason = placeholder_reason(asset_path)
            self.expect(reason is None, "placeholder-asset", asset_path, reason or "")
        self.expect(ordered_paths == sorted(ordered_paths), "asset-inventory-order", path, "asset records must be sorted by path")
        self.expect(len(ordered_paths) == len(set(ordered_paths)), "duplicate-asset-path", path, "asset paths must be unique")
        self.expect(dict(authority_counts) == EXPECTED_ASSET_AUTHORITY_COUNTS, "asset-authority-count-drift", path, "asset authority counts must be 95 approved and 18 accepted production candidates")
        actual_asset_paths = sorted(
            item.relative_to(self.authority_root).as_posix()
            for item in (self.authority_root / "03-AUTHORITY-ASSETS").rglob("*")
            if item.is_file() and is_image_path(item)
        )
        self.expect(actual_asset_paths == ordered_paths, "asset-inventory-drift", path, "asset manifest must exactly cover all imported images")
        duplicates = {
            digest: {record["path"] for record in group}
            for digest, group in assets_by_hash.items()
            if len(group) > 1
        }
        self.counts["declaredDuplicateHashGroupCount"] = len(duplicates)
        self.expect(duplicates == EXPECTED_DUPLICATE_ASSET_HASHES, "duplicate-asset-hash-drift", path, "the six declared duplicate hash groups must remain exact")
        for digest, group in assets_by_hash.items():
            if len(group) < 2:
                continue
            try:
                metadata = {(item["byteCount"], tuple(item["dimensions"]), item["authority"]) for item in group}
            except (KeyError, TypeError):
                metadata = set()
            self.expect(len(metadata) == 1, "duplicate-asset-metadata-drift", path, "duplicate hash {} has inconsistent metadata".format(digest))

    def validate_candidate_catalog(self) -> None:
        document = self.documents.get("candidateCatalog")
        if not isinstance(document, dict):
            return
        path = self.active_paths["candidateCatalog"]
        self.expect_exact_keys(document, {"schemaVersion", "catalogID", "candidateCount", "candidates"}, "invalid-candidate-catalog", self.display_path(path))
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("catalogID") == "runescribe.theme-fidelity.candidate-capture-catalog.v4.2", "candidate-catalog-identity-drift", path, "candidate catalog identity must remain v4.2/v1.2")
        records = document.get("candidates")
        if not isinstance(records, list):
            self.add("invalid-candidate-catalog", path, "candidates must be an array")
            return
        self.counts["candidateCount"] = len(records)
        self.expect(document.get("candidateCount") == EXPECTED_CANDIDATE_COUNT == len(records), "candidate-count-mismatch", path, "candidate catalog must contain exactly 188 records")
        ids: List[str] = []
        kinds: Counter[str] = Counter()
        for index, record in enumerate(records):
            label = "candidates[{}]".format(index)
            if not self.expect_exact_keys(record, {"id", "kind", "captureOperation", "purpose", "missingBehavior"}, "invalid-candidate-record", label):
                continue
            identifier = record["id"]
            if isinstance(identifier, str):
                ids.append(identifier)
                self.expect(identifier.strip() == identifier and "{" not in identifier and "}" not in identifier and bool(identifier), "invalid-candidate-id", label, "candidate ID must be exact and non-placeholder")
                self.expect(identifier not in self.candidates, "duplicate-candidate-id", label, "candidate ID is duplicated")
                if identifier not in self.candidates:
                    self.candidates[identifier] = record
            kind = record["kind"]
            operation = record["captureOperation"]
            expected_operation = {"accessibility-element": "xcui-element-screenshot", "renderer-output": "deterministic-png-export"}.get(kind) if isinstance(kind, str) else None
            self.expect(expected_operation is not None and operation == expected_operation, "candidate-operation-drift", label, "candidate kind and capture operation are inconsistent")
            if isinstance(kind, str):
                kinds[kind] += 1
            self.expect(all(isinstance(record[field], str) and bool(record[field].strip()) for field in ("purpose", "missingBehavior")), "invalid-candidate-contract", label, "candidate purpose and missing behavior must be non-empty")
        self.expect(ids == sorted(ids) and len(ids) == len(set(ids)), "candidate-order", path, "candidate IDs must be sorted and unique")
        self.expect(dict(kinds) == {"accessibility-element": 183, "renderer-output": 5}, "candidate-kind-count-drift", path, "candidate kinds must contain 183 elements and 5 renderer outputs")

    def validate_probe_catalog(self) -> None:
        document = self.documents.get("runtimeProbeCatalog")
        if not isinstance(document, dict):
            return
        path = self.active_paths["runtimeProbeCatalog"]
        self.expect_exact_keys(document, {"schemaVersion", "catalogID", "probeCount", "probes"}, "invalid-probe-catalog", self.display_path(path))
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("catalogID") == "runescribe.theme-fidelity.runtime-probe-catalog.v4.2", "probe-catalog-identity-drift", path, "probe catalog identity must remain v4.2/v1.2")
        records = document.get("probes")
        if not isinstance(records, list):
            self.add("invalid-probe-catalog", path, "probes must be an array")
            return
        self.counts["runtimeProbeCount"] = len(records)
        self.expect(document.get("probeCount") == EXPECTED_PROBE_COUNT == len(records), "probe-count-mismatch", path, "runtime probe catalog must contain exactly 50 records")
        ids: List[str] = []
        operators: Counter[str] = Counter()
        for index, record in enumerate(records):
            label = "probes[{}]".format(index)
            if not self.expect_exact_keys(record, {"id", "source", "operator", "expected", "description", "evidencePath"}, "invalid-probe-record", label):
                continue
            identifier = record["id"]
            if isinstance(identifier, str):
                ids.append(identifier)
                self.expect(identifier.strip() == identifier and identifier.startswith("probe.") and "{" not in identifier and "}" not in identifier, "invalid-probe-id", label, "probe ID must be stable and non-placeholder")
                self.expect(identifier not in self.probes, "duplicate-probe-id", label, "probe ID is duplicated")
                if identifier not in self.probes:
                    self.probes[identifier] = record
            operator = record["operator"]
            if isinstance(operator, str):
                operators[operator] += 1
            self.expect(isinstance(operator, str) and operator in {"equals", "less-than-or-equal", "equals-declared-reduce-motion-resource", "greater-than-or-equal", "greater-than"}, "invalid-probe-operator", label, "probe operator is unsupported")
            evidence = record["evidencePath"]
            evidence_path = self.resolve_repo_path(evidence, "{}.evidencePath".format(label))
            self.expect(evidence_path is not None and isinstance(evidence, str) and evidence.startswith("docs/verification/theme-fidelity-v4/runtime-probes/") and evidence.endswith("{}.json".format(identifier)), "invalid-probe-evidence-path", label, "probe evidence path must be exact and repository-confined")
            self.expect(isinstance(record["source"], str) and bool(record["source"]), "invalid-probe-source", label, "probe source is required")
            self.expect(isinstance(record["description"], str) and bool(record["description"].strip()), "invalid-probe-description", label, "probe description is required")
        self.expect(ids == sorted(ids) and len(ids) == len(set(ids)), "probe-order", path, "probe IDs must be sorted and unique")
        self.expect(dict(operators) == {"equals": 30, "less-than-or-equal": 5, "equals-declared-reduce-motion-resource": 5, "greater-than-or-equal": 5, "greater-than": 5}, "probe-operator-count-drift", path, "probe operator counts changed")

    def validate_seed_catalog(self, authority: Mapping[str, Any]) -> None:
        document = self.documents.get("deterministicSeedCatalog")
        if not isinstance(document, dict):
            return
        path = self.active_paths["deterministicSeedCatalog"]
        self.expect_exact_keys(document, {"schemaVersion", "catalogID", "seedCount", "seeds"}, "invalid-seed-catalog", self.display_path(path))
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("catalogID") == "runescribe.theme-fidelity.deterministic-seed-catalog.v4.2", "seed-catalog-identity-drift", path, "seed catalog identity must remain v4.2/v1.2")
        records = document.get("seeds")
        if not isinstance(records, list):
            self.add("invalid-seed-catalog", path, "seeds must be an array")
            return
        self.counts["seedCount"] = len(records)
        self.expect(document.get("seedCount") == EXPECTED_SEED_COUNT == len(records), "seed-count-mismatch", path, "seed catalog must contain exactly 100 records")
        ids: List[str] = []
        themes = authority.get("themes", {}) if isinstance(authority, dict) else {}
        common_keys = {
            "RUNESCRIBE_QUALIFICATION",
            "RUNESCRIBE_QUALIFICATION_THEME_ID",
            "RUNESCRIBE_QUALIFICATION_CODEX_ID",
            "RUNESCRIBE_QUALIFICATION_SURFACE",
            "RUNESCRIBE_QUALIFICATION_RESET_STATE",
            "RUNESCRIBE_QUALIFICATION_DEFAULT_RELIC_ID",
            "RUNESCRIBE_QUALIFICATION_DEFAULT_SEAL_ID",
            "RUNESCRIBE_QUALIFICATION_APPEARANCE",
            "RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE",
        }
        expected_appearance = {
            "high-contrast": "high-contrast",
            "reduce-motion": "reduce-motion",
            "large-text": "accessibility-xxxl",
        }
        expected_message = {
            "compose-long": "long-six-lines",
            "compose-short": "short-two-lines",
            "high-contrast": "short-two-lines",
            "inscription-preview": "short-two-lines",
            "large-text": "short-two-lines",
            "received-cipher": "received-six-lines",
            "reduce-motion": "short-two-lines",
            "settings-defaults-preview": "short-two-lines",
            "share-builder": "received-six-lines",
            "static-share": "received-six-lines",
        }
        for index, record in enumerate(records):
            label = "seeds[{}]".format(index)
            if not self.expect_exact_keys(record, {"id", "theme", "surface", "launchEnvironment", "operatorInputRequired"}, "invalid-seed-record", label):
                continue
            identifier = record["id"]
            theme = record["theme"]
            surface = record["surface"]
            if isinstance(identifier, str):
                ids.append(identifier)
                self.expect(identifier not in self.seeds, "duplicate-seed-id", label, "seed ID is duplicated")
                if identifier not in self.seeds:
                    self.seeds[identifier] = record
            self.expect(theme in EXPECTED_THEMES and surface in EXPECTED_SURFACES, "invalid-seed-dimensions", label, "seed Theme or surface is unknown")
            if isinstance(theme, str) and isinstance(surface, str):
                self.expect(identifier == "seed.{}.{}".format(theme.casefold(), surface), "seed-id-drift", label, "seed ID must exactly encode Theme and surface")
            self.expect(record["operatorInputRequired"] is False, "operator-input-required", label, "deterministic seeds must require no operator input")
            environment = record["launchEnvironment"]
            if not isinstance(environment, dict):
                self.add("invalid-seed-environment", label, "launchEnvironment must be an object")
                continue
            expected_keys = set(common_keys)
            if isinstance(surface, str) and surface.startswith("vault-"):
                expected_keys.add("RUNESCRIBE_QUALIFICATION_VAULT_STATE")
            self.expect(set(environment) == expected_keys, "seed-environment-keys-drift", label, "launch environment keys must be exact")
            theme_record = themes.get(theme, {}) if isinstance(themes, dict) and isinstance(theme, str) else {}
            expected_values = {
                "RUNESCRIBE_QUALIFICATION": "theme-fidelity-v4.2",
                "RUNESCRIBE_QUALIFICATION_THEME_ID": theme_record.get("themeID"),
                "RUNESCRIBE_QUALIFICATION_CODEX_ID": theme_record.get("codexID"),
                "RUNESCRIBE_QUALIFICATION_SURFACE": surface,
                "RUNESCRIBE_QUALIFICATION_RESET_STATE": "1",
                "RUNESCRIBE_QUALIFICATION_DEFAULT_RELIC_ID": theme_record.get("defaultRelicID"),
                "RUNESCRIBE_QUALIFICATION_DEFAULT_SEAL_ID": theme_record.get("defaultSealID"),
                "RUNESCRIBE_QUALIFICATION_APPEARANCE": expected_appearance.get(surface, "standard"),
                "RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE": expected_message.get(surface, "empty"),
            }
            for key, expected in expected_values.items():
                self.expect(environment.get(key) == expected, "seed-environment-value-drift", label, "{} does not match the authority".format(key))
            if isinstance(surface, str) and surface.startswith("vault-"):
                self.expect(environment.get("RUNESCRIBE_QUALIFICATION_VAULT_STATE") == surface.removeprefix("vault-"), "seed-vault-state-drift", label, "vault state must exactly match the surface")
        self.expect(ids == sorted(ids) and len(ids) == len(set(ids)), "seed-order", path, "seed IDs must be sorted and unique")
        expected_pairs = {(theme, surface) for theme in EXPECTED_THEMES for surface in EXPECTED_SURFACES}
        actual_pairs = {
            (record.get("theme"), record.get("surface"))
            for record in records
            if isinstance(record, dict)
            and isinstance(record.get("theme"), str)
            and isinstance(record.get("surface"), str)
        }
        self.expect(actual_pairs == expected_pairs, "seed-coverage-drift", path, "seed catalog must cover every Theme/surface pair exactly once")

    def validate_authority(self) -> None:
        authority = self.documents.get("comparisonAuthority")
        if not isinstance(authority, dict):
            return
        path = self.active_paths["comparisonAuthority"]
        expected_keys = {
            "schemaVersion", "authorityID", "supersedes", "approvalSemantics",
            "v40ArchiveSHA256", "v41ArchiveSHA256", "expectedEntryCount",
            "reviewedEntryCount", "unreviewedEntryCount",
            "expectedThemeSurfaceAuthorityCount", "expectedReferenceMappingCount",
            "manualCropCoordinatesAuthorized", "customMaskFilesAuthorized",
            "requiresFurtherOwnerInput", "themes", "destinations",
            "normalizationPolicies", "thresholdProfiles", "structuralAssertionCatalog",
            "surfacePolicies", "themeSurfaceAuthorities", "entries",
        }
        self.expect_exact_keys(authority, expected_keys, "invalid-authority-fields", self.display_path(path))
        self.expect(authority.get("schemaVersion") == SCHEMA_VERSION and authority.get("authorityID") == "runescribe.theme-fidelity.comparison-authority.v4.2" and authority.get("supersedes") == "runescribe.theme-fidelity.comparison-authority.v4.1", "authority-identity-drift", path, "comparison authority must be v4.2/v1.2 and supersede v4.1")
        self.expect(authority.get("v40ArchiveSHA256") == EXPECTED_SOURCE_PACKAGE["v4.0ArchiveSHA256"] and authority.get("v41ArchiveSHA256") == EXPECTED_SOURCE_PACKAGE["v4.1ArchiveSHA256"], "authority-archive-hash-drift", path, "archive hashes must match the imported package identity")
        self.expect(authority.get("expectedEntryCount") == EXPECTED_ENTRY_COUNT and authority.get("reviewedEntryCount") == EXPECTED_ENTRY_COUNT and authority.get("unreviewedEntryCount") == 0, "authority-entry-declaration-drift", path, "entry declarations must be 400 reviewed and zero unreviewed")
        self.expect(authority.get("expectedThemeSurfaceAuthorityCount") == EXPECTED_GROUP_COUNT and authority.get("expectedReferenceMappingCount") == EXPECTED_MAPPING_COUNT, "authority-count-declaration-drift", path, "authority must declare 100 groups and 1104 mappings")
        self.expect(authority.get("manualCropCoordinatesAuthorized") is False and authority.get("customMaskFilesAuthorized") is False and authority.get("requiresFurtherOwnerInput") is False, "manual-authority-prohibition-drift", path, "manual crops, custom masks, and further owner input must remain prohibited")
        themes = authority.get("themes")
        destinations = authority.get("destinations")
        surfaces = authority.get("surfacePolicies")
        normalizations = authority.get("normalizationPolicies")
        thresholds = authority.get("thresholdProfiles")
        assertions = authority.get("structuralAssertionCatalog")
        groups = authority.get("themeSurfaceAuthorities")
        self.expect(isinstance(themes, dict) and tuple(themes) == EXPECTED_THEMES, "theme-catalog-drift", path, "Theme catalog must contain the five ordered Themes")
        self.expect(isinstance(destinations, dict) and tuple(destinations) == EXPECTED_DESTINATIONS, "destination-catalog-drift", path, "destination catalog must contain the four ordered destinations")
        self.expect(isinstance(surfaces, dict) and tuple(surfaces) == EXPECTED_SURFACES, "surface-catalog-drift", path, "surface catalog must contain the twenty ordered surfaces")
        self.expect(isinstance(normalizations, dict) and set(normalizations) == set(EXPECTED_NORMALIZATION_USAGE), "normalization-catalog-drift", path, "five normalization policies are required")
        if isinstance(normalizations, dict):
            for name, policy in normalizations.items():
                self.expect(isinstance(policy, dict) and policy.get("manualCropAllowed") is False and policy.get("manualMaskAllowed") is False, "manual-normalization-drift", "normalizationPolicies.{}".format(name), "manual crops and masks must remain prohibited")
        self.expect(thresholds == EXPECTED_THRESHOLD_PROFILES, "threshold-profile-drift", path, "threshold profiles must match the fixed v1.2 acceptance policy")
        self.expect(assertions == EXPECTED_STRUCTURAL_ASSERTIONS, "structural-assertion-catalog-drift", path, "structural assertion catalog changed")
        if isinstance(themes, dict):
            for theme, record in themes.items():
                if not self.expect_exact_keys(record, {"themeID", "codexID", "defaultRelicID", "defaultSealID", "board"}, "invalid-theme-record", "themes.{}".format(theme)):
                    continue
                self.expect(record["board"] in self.assets, "unknown-theme-board", "themes.{}".format(theme), "Theme board must reference a declared asset")
        if isinstance(destinations, dict):
            for destination, record in destinations.items():
                self.expect_exact_keys(record, {"displayName", "platform", "sizeClass", "captureRule"}, "invalid-destination-record", "destinations.{}".format(destination))
        if isinstance(surfaces, dict):
            for surface, record in surfaces.items():
                if self.expect_exact_keys(record, {"seed", "capture", "assertions"}, "invalid-surface-record", "surfacePolicies.{}".format(surface)):
                    self.expect(isinstance(record["seed"], str) and bool(record["seed"].strip()) and isinstance(record["capture"], list) and bool(record["capture"]) and isinstance(record["assertions"], list) and bool(record["assertions"]), "invalid-surface-contract", "surfacePolicies.{}".format(surface), "surface seed, capture, and assertions must be non-empty")
        self.validate_theme_surface_groups(groups, path)
        self.validate_seed_catalog(authority)
        records = authority.get("entries")
        if not isinstance(records, list):
            self.add("invalid-entry-inventory", path, "entries must be an array")
            return
        self.entries = [record for record in records if isinstance(record, dict)]
        self.counts["entryCount"] = len(records)
        self.expect(len(records) == EXPECTED_ENTRY_COUNT and len(self.entries) == EXPECTED_ENTRY_COUNT, "entry-count-mismatch", path, "authority must contain exactly 400 object entries")
        expected_ids = ["{}|{}|{}".format(theme, surface, destination) for theme in EXPECTED_THEMES for surface in EXPECTED_SURFACES for destination in EXPECTED_DESTINATIONS]
        actual_ids = [record.get("id") for record in self.entries]
        self.expect(actual_ids == expected_ids and all(isinstance(item, str) for item in actual_ids) and len(actual_ids) == len(set(actual_ids)), "entry-cartesian-coverage-drift", path, "entries must exactly cover the ordered 5 by 20 by 4 matrix")
        for index, entry in enumerate(self.entries):
            self.validate_entry(entry, index, themes if isinstance(themes, dict) else {}, groups if isinstance(groups, dict) else {})
        self.validate_aggregate_mapping_semantics(path)

    def validate_theme_surface_groups(self, groups: Any, path: Path) -> None:
        if not isinstance(groups, dict):
            self.add("invalid-theme-surface-authorities", path, "themeSurfaceAuthorities must be an object")
            return
        self.counts["themeSurfaceAuthorityCount"] = len(groups)
        expected_ids = ["{}.{}".format(theme, surface) for theme in EXPECTED_THEMES for surface in EXPECTED_SURFACES]
        self.expect(list(groups) == expected_ids and len(groups) == EXPECTED_GROUP_COUNT, "theme-surface-coverage-drift", path, "Theme/surface authority groups must exactly cover the ordered 5 by 20 matrix")
        for identifier, record in groups.items():
            label = "themeSurfaceAuthorities.{}".format(identifier)
            if not self.expect_exact_keys(record, {"id", "theme", "surface", "originalReferenceAssets", "supplementalReferenceAssets", "referenceAssets", "referenceCount", "reviewStatus", "requiresFurtherOwnerInput", "mappingRule"}, "invalid-theme-surface-record", label):
                continue
            expected_id = "{}.{}".format(record["theme"], record["surface"])
            self.expect(identifier == record["id"] == expected_id, "theme-surface-id-drift", label, "group key and ID must encode Theme and surface")
            original = record["originalReferenceAssets"]
            supplemental = record["supplementalReferenceAssets"]
            references = record["referenceAssets"]
            valid_lists = all(isinstance(value, list) for value in (original, supplemental, references))
            self.expect(valid_lists, "invalid-theme-surface-references", label, "reference lists must be arrays")
            if valid_lists:
                self.expect(references == original + supplemental and len(references) == record["referenceCount"] and len(references) > 0, "theme-surface-reference-count-drift", label, "reference projection and count must be exact")
                valid_references = all(isinstance(item, str) for item in references)
                self.expect(valid_references and len(references) == len(set(references)) and all(item in self.assets for item in references), "unknown-theme-surface-reference", label, "group references must be unique declared assets")
            self.expect(record["reviewStatus"] == "approved" and record["requiresFurtherOwnerInput"] is False, "theme-surface-review-drift", label, "every group must remain approved without further owner input")
            self.expect(isinstance(record["mappingRule"], str) and bool(record["mappingRule"].strip()), "missing-theme-surface-mapping-rule", label, "mapping rule is required")

    def validate_entry(self, entry: Dict[str, Any], index: int, themes: Mapping[str, Any], groups: Mapping[str, Any]) -> None:
        label = "entries[{}]".format(index)
        expected_keys = {
            "id", "theme", "themeID", "codexID", "surface", "destination", "seedID",
            "applicability", "comparisonMode", "entryThresholdProfile",
            "themeSurfaceAuthorityID", "referenceMappingCount", "imageMetricMappingCount",
            "structuralMappingCount", "negativeInvariantMappingCount", "referenceMappings",
            "entryStructuralAssertionIDs", "runtimeProbeIDs", "candidateOutputDirectory", "review",
        }
        if not self.expect_exact_keys(entry, expected_keys, "invalid-entry-record", label):
            return
        entry_id = entry["id"]
        theme = entry["theme"]
        surface = entry["surface"]
        destination = entry["destination"]
        expected_id = "{}|{}|{}".format(theme, surface, destination)
        self.expect(entry_id == expected_id, "entry-id-drift", label, "entry ID must encode Theme, surface, and destination")
        theme_record = themes.get(theme, {}) if isinstance(themes, Mapping) and isinstance(theme, str) else {}
        self.expect(entry["themeID"] == theme_record.get("themeID") and entry["codexID"] == theme_record.get("codexID"), "entry-theme-identity-drift", label, "entry Theme and Codex IDs must match the Theme catalog")
        seed_id = entry["seedID"]
        self.expect(isinstance(seed_id, str) and seed_id == "seed.{}.{}".format(str(theme).casefold(), surface) and seed_id in self.seeds, "entry-seed-drift", label, "entry must reference its exact deterministic seed")
        group_id = "{}.{}".format(theme, surface)
        self.expect(entry["themeSurfaceAuthorityID"] == group_id and group_id in groups, "entry-group-drift", label, "entry must reference its exact Theme/surface group")
        mode = entry["comparisonMode"]
        expected_entry_profile = {
            "explicit-image-mappings": "focal-asset-v1",
            "responsive-structural-plus-explicit-focal": "responsive-structural-v1",
            "responsive-structural-only": "responsive-structural-v1",
            "runtime-behavior-plus-explicit-reference-mappings": "runtime-reduce-motion-v1",
            "negative-invariant": "negative-invariant-v1",
        }.get(mode) if isinstance(mode, str) else None
        self.expect(expected_entry_profile is not None and entry["entryThresholdProfile"] == expected_entry_profile, "entry-mode-profile-drift", label, "comparison mode and entry threshold profile are inconsistent")
        negative = mode == "negative-invariant"
        self.expect(entry["applicability"] == ("prohibited-production-state" if negative else "required"), "entry-applicability-drift", label, "entry applicability does not match its comparison mode")
        assertions = entry["entryStructuralAssertionIDs"]
        valid_assertions = isinstance(assertions, list) and all(isinstance(item, str) for item in assertions)
        self.expect(valid_assertions and len(assertions) == len(set(assertions)) and all(item in EXPECTED_STRUCTURAL_ASSERTIONS for item in assertions), "entry-assertion-drift", label, "entry structural assertions must be unique catalog IDs")
        mappings = entry["referenceMappings"]
        if not isinstance(mappings, list) or not mappings:
            self.add("invalid-entry-mappings", label, "referenceMappings must be a non-empty array")
            return
        self.expect(entry["referenceMappingCount"] == len(mappings), "entry-mapping-count-drift", label, "referenceMappingCount must equal the mappings array")
        group = groups.get(group_id, {}) if isinstance(groups, Mapping) else {}
        self.expect(isinstance(group, dict) and [mapping.get("referenceAsset") for mapping in mappings] == group.get("referenceAssets"), "entry-group-reference-projection-drift", label, "every destination must map the group references in exact order")
        score_counts: Counter[str] = Counter()
        for mapping_index, mapping in enumerate(mappings, 1):
            if not isinstance(mapping, dict):
                self.add("invalid-mapping-record", "{}.referenceMappings[{}]".format(label, mapping_index - 1), "mapping must be an object")
                continue
            self.validate_mapping(entry, mapping, mapping_index, label)
            if isinstance(mapping.get("scoreDisposition"), str):
                score_counts[mapping["scoreDisposition"]] += 1
        self.expect(entry["imageMetricMappingCount"] == score_counts["image-metric"] and entry["structuralMappingCount"] == score_counts["structural-assertion"] and entry["negativeInvariantMappingCount"] == score_counts["negative-invariant"], "entry-disposition-count-drift", label, "entry mapping disposition declarations must equal their mappings")
        if mode == "explicit-image-mappings":
            self.expect(score_counts == Counter({"image-metric": len(mappings)}), "entry-mode-semantic-drift", label, "explicit image entries must contain only image metrics")
        elif mode == "responsive-structural-only":
            self.expect(score_counts == Counter({"structural-assertion": len(mappings)}), "entry-mode-semantic-drift", label, "structural-only entries must contain only structural mappings")
        elif mode == "responsive-structural-plus-explicit-focal":
            self.expect(score_counts["image-metric"] > 0 and score_counts["structural-assertion"] > 0 and sum(score_counts.values()) == len(mappings), "entry-mode-semantic-drift", label, "mixed responsive entries require structural and image mappings")
        elif mode == "negative-invariant":
            self.expect(score_counts == Counter({"negative-invariant": 1}), "entry-mode-semantic-drift", label, "negative entries require exactly one negative mapping")
        elif mode == "runtime-behavior-plus-explicit-reference-mappings":
            self.expect(score_counts["image-metric"] > 0 and score_counts["structural-assertion"] > 0 and sum(score_counts.values()) == len(mappings), "entry-mode-semantic-drift", label, "Reduce Motion entries require structural and image mappings")
        self.validate_entry_runtime_probes(entry, label)
        expected_output = "docs/verification/theme-fidelity-v4/comparisons/{}/{}/{}".format(str(theme).casefold(), surface, destination)
        output_path = self.resolve_repo_path(entry["candidateOutputDirectory"], "{}.candidateOutputDirectory".format(label))
        self.expect(output_path is not None and entry["candidateOutputDirectory"] == expected_output, "candidate-output-directory-drift", label, "candidate output directory must be exact and repository-confined")
        review = entry["review"]
        expected_review = {
            "reviewed": True,
            "status": "approved",
            "authority": "owner-delivered executable v4.2 continuation package",
            "reviewDate": "2026-08-25",
            "requiresFurtherOwnerInput": False,
        }
        self.expect(review == expected_review, "entry-review-drift", label, "entry review must remain approved and require no further owner input")

    def validate_mapping(self, entry: Dict[str, Any], mapping: Dict[str, Any], ordinal: int, entry_label: str) -> None:
        label = "{}.referenceMappings[{}]".format(entry_label, ordinal - 1)
        common_keys = {
            "mappingID", "referenceAsset", "referenceSHA256", "referenceByteCount",
            "referenceDimensions", "sourceCrop", "referenceRole", "scoreDisposition",
            "normalizationPolicy", "thresholdProfile", "structuralAssertionIDs", "notes",
            "candidateCaptureOperation", "focalRegion",
        }
        candidate_fields = [name for name in ("candidateElementID", "candidateRendererOutputID", "candidateProbeID") if name in mapping]
        expected_keys = common_keys | set(candidate_fields)
        self.expect(set(mapping) == expected_keys and len(candidate_fields) == 1, "mapping-candidate-source-drift", label, "mapping must contain exactly one candidate source and no unknown fields")
        expected_mapping_id = "{}|reference-{:02d}".format(entry["id"], ordinal)
        mapping_id = mapping.get("mappingID")
        self.expect(mapping_id == expected_mapping_id, "mapping-id-drift", label, "mapping ID must be sequential within its entry")
        self.expect(not isinstance(mapping_id, str) or mapping_id not in self.mapping_ids, "duplicate-mapping-id", label, "mapping ID is duplicated")
        if isinstance(mapping_id, str):
            self.mapping_ids.add(mapping_id)
        reference = mapping.get("referenceAsset")
        asset = self.assets.get(reference) if isinstance(reference, str) else None
        self.expect(asset is not None, "unknown-mapping-reference", label, "mapping reference must be a declared asset")
        if asset is not None:
            self.expect(mapping.get("referenceSHA256") == asset.get("sha256") and mapping.get("referenceByteCount") == asset.get("byteCount") and mapping.get("referenceDimensions") == asset.get("dimensions"), "mapping-reference-metadata-drift", label, "mapping reference hash, byte count, and dimensions must match the asset manifest")
        self.expect(mapping.get("sourceCrop") == EXPECTED_FULL_SOURCE_CROP, "manual-source-crop-drift", label, "sourceCrop must be the complete image with manual coordinates prohibited")
        self.expect("mask" not in mapping, "custom-mask-drift", label, "custom mapping masks are prohibited")
        semantics = (mapping.get("referenceRole"), mapping.get("scoreDisposition"), mapping.get("normalizationPolicy"), mapping.get("thresholdProfile"))
        valid_semantics = all(isinstance(item, str) for item in semantics)
        self.expect(valid_semantics and semantics in EXPECTED_MAPPING_SEMANTICS, "mapping-semantic-drift", label, "mapping role, disposition, normalization, and threshold are inconsistent")
        structural_ids = mapping.get("structuralAssertionIDs")
        valid_structural_ids = isinstance(structural_ids, list) and all(isinstance(item, str) for item in structural_ids)
        self.expect(valid_structural_ids and len(structural_ids) == len(set(structural_ids)) and all(item in EXPECTED_STRUCTURAL_ASSERTIONS for item in structural_ids), "mapping-assertion-drift", label, "mapping structural assertions must be unique catalog IDs")
        if mapping.get("scoreDisposition") == "structural-assertion":
            self.expect(bool(structural_ids), "mapping-assertion-drift", label, "structural mappings require assertions")
        elif mapping.get("scoreDisposition") == "negative-invariant":
            self.expect(structural_ids == [], "mapping-assertion-drift", label, "negative mappings cannot carry structural assertions")
        self.expect(isinstance(mapping.get("notes"), str) and bool(mapping["notes"].strip()), "missing-mapping-notes", label, "mapping notes are required")
        if len(candidate_fields) == 1:
            field = candidate_fields[0]
            candidate_id = mapping.get(field)
            self.expect(isinstance(candidate_id, str) and candidate_id.strip() == candidate_id and bool(candidate_id) and "{" not in candidate_id and "}" not in candidate_id, "invalid-mapping-candidate-id", label, "candidate source must be exact and non-placeholder")
            expected_operation = {
                "candidateElementID": "xcui-element-screenshot",
                "candidateRendererOutputID": "deterministic-png-export",
                "candidateProbeID": "runtime-probe-evaluation",
            }[field]
            self.expect(mapping.get("candidateCaptureOperation") == expected_operation, "mapping-capture-operation-drift", label, "candidate field and capture operation are inconsistent")
            if field == "candidateProbeID":
                self.expect(isinstance(candidate_id, str) and candidate_id in self.probes, "unknown-mapping-probe", label, "candidate probe is absent from the runtime probe catalog")
                expected_focal = {"mode": "not-applicable-negative-invariant", "candidateProbeID": candidate_id, "manualCoordinatesAllowed": False}
            else:
                catalog = self.candidates.get(candidate_id) if isinstance(candidate_id, str) else None
                expected_kind = "accessibility-element" if field == "candidateElementID" else "renderer-output"
                self.expect(catalog is not None and catalog.get("kind") == expected_kind and catalog.get("captureOperation") == expected_operation, "unknown-mapping-candidate", label, "candidate source is absent or has the wrong catalog kind")
                focal_mode = "exact-accessibility-element-bounds" if field == "candidateElementID" else "complete-renderer-output"
                expected_focal = {"mode": focal_mode, field: candidate_id, "manualCoordinatesAllowed": False}
            self.expect(mapping.get("focalRegion") == expected_focal, "mapping-focal-region-drift", label, "focal region must derive exactly from the declared candidate source without manual coordinates")
            if common_keys.issubset(mapping) and isinstance(candidate_id, str):
                self.mappings.append((entry, mapping))

    def validate_entry_runtime_probes(self, entry: Dict[str, Any], label: str) -> None:
        probe_ids = entry.get("runtimeProbeIDs")
        if not isinstance(probe_ids, list):
            self.add("invalid-entry-runtime-probes", label, "runtimeProbeIDs must be an array")
            return
        valid_probe_ids = all(isinstance(item, str) for item in probe_ids)
        self.expect(valid_probe_ids and len(probe_ids) == len(set(probe_ids)) and all(item in self.probes for item in probe_ids), "unknown-entry-runtime-probe", label, "entry runtime probes must be unique catalog IDs")
        if not valid_probe_ids:
            return
        theme_id = entry.get("themeID")
        active_probe = "probe.theme.active.{}".format(theme_id)
        if entry.get("comparisonMode") == "negative-invariant":
            self.expect(entry.get("theme") == "Norse" and entry.get("surface") == "vault-locked" and set(probe_ids) == NEGATIVE_RUNTIME_PROBES and len(probe_ids) == 5, "negative-runtime-probe-drift", label, "negative entries require the exact five Norse vault probes")
        elif entry.get("surface") == "reduce-motion":
            expected = {
                active_probe,
                "probe.motion.mode.{}".format(theme_id),
                "probe.motion.active-animation-count.{}".format(theme_id),
                "probe.motion.background-resource.{}".format(theme_id),
                "probe.motion.visual-plan-revision.{}".format(theme_id),
                "probe.motion.preview-exists.{}".format(theme_id),
                "probe.motion.preview-visible.{}".format(theme_id),
                "probe.motion.preview-contained.{}".format(theme_id),
                "probe.motion.frame-stability.{}".format(theme_id),
            }
            self.expect(set(probe_ids) == expected and len(probe_ids) == 9, "reduce-motion-runtime-probe-drift", label, "Reduce Motion entries require the exact nine Theme probes")
        else:
            self.expect(probe_ids == [active_probe], "entry-runtime-probe-drift", label, "standard entries require only the exact active-Theme probe")

    def validate_aggregate_mapping_semantics(self, path: Path) -> None:
        mappings = [mapping for _, mapping in self.mappings]
        self.counts["mappingCount"] = len(mappings)
        self.expect(len(mappings) == EXPECTED_MAPPING_COUNT and len(self.mapping_ids) == EXPECTED_MAPPING_COUNT, "mapping-count-mismatch", path, "authority must contain exactly 1104 unique mappings")
        dispositions = Counter(mapping.get("scoreDisposition") if isinstance(mapping.get("scoreDisposition"), str) else "<invalid>" for mapping in mappings)
        roles = Counter(mapping.get("referenceRole") if isinstance(mapping.get("referenceRole"), str) else "<invalid>" for mapping in mappings)
        modes = Counter(entry.get("comparisonMode") if isinstance(entry.get("comparisonMode"), str) else "<invalid>" for entry in self.entries)
        normalizations = Counter(mapping.get("normalizationPolicy") if isinstance(mapping.get("normalizationPolicy"), str) else "<invalid>" for mapping in mappings)
        thresholds = Counter(mapping.get("thresholdProfile") if isinstance(mapping.get("thresholdProfile"), str) else "<invalid>" for mapping in mappings)
        candidate_fields = Counter(next((field for field in EXPECTED_CANDIDATE_FIELD_USAGE if field in mapping), None) for mapping in mappings)
        self.expect(dict(dispositions) == EXPECTED_DISPOSITIONS, "mapping-disposition-count-drift", path, "mapping dispositions must be 400 image, 700 structural, and 4 negative")
        self.expect(dict(roles) == EXPECTED_REFERENCE_ROLES, "mapping-role-count-drift", path, "reference roles must be 380 focal, 704 structural-only, and 20 full-screen")
        self.expect(dict(modes) == EXPECTED_COMPARISON_MODES, "entry-mode-count-drift", path, "entry comparison mode counts changed")
        self.expect(dict(normalizations) == EXPECTED_NORMALIZATION_USAGE, "normalization-usage-drift", path, "normalization policy usage counts changed")
        self.expect(dict(thresholds) == EXPECTED_THRESHOLD_USAGE, "threshold-usage-drift", path, "threshold profile usage counts changed")
        self.expect({key: candidate_fields[key] for key in EXPECTED_CANDIDATE_FIELD_USAGE} == EXPECTED_CANDIDATE_FIELD_USAGE and None not in candidate_fields, "candidate-field-count-drift", path, "candidate source field usage must be 1040 element, 60 renderer, and 4 probe mappings")
        used_candidates = {mapping.get("candidateElementID") for mapping in mappings if isinstance(mapping.get("candidateElementID"), str)} | {mapping.get("candidateRendererOutputID") for mapping in mappings if isinstance(mapping.get("candidateRendererOutputID"), str)}
        used_probes = {
            probe
            for entry in self.entries
            for probe in (
                entry.get("runtimeProbeIDs", [])
                if isinstance(entry.get("runtimeProbeIDs", []), list)
                else []
            )
            if isinstance(probe, str)
        } | {mapping.get("candidateProbeID") for mapping in mappings if isinstance(mapping.get("candidateProbeID"), str)}
        used_seeds = {entry.get("seedID") for entry in self.entries if isinstance(entry.get("seedID"), str)}
        self.expect(used_candidates.issubset(self.candidates) and len(used_candidates) == 75, "candidate-reference-coverage-drift", path, "mappings must reference the exact 70 element and 5 renderer candidate contracts")
        self.expect(used_probes == set(self.probes), "probe-reference-coverage-drift", path, "all 50 runtime probes must be used")
        self.expect(used_seeds == set(self.seeds), "seed-reference-coverage-drift", path, "all 100 deterministic seeds must be used")
        runtime_probe_usage = sum(
            len(entry.get("runtimeProbeIDs", []))
            for entry in self.entries
            if isinstance(entry.get("runtimeProbeIDs", []), list)
        )
        self.expect(runtime_probe_usage == 576, "runtime-probe-usage-count-drift", path, "entry runtime probe usage must total 576")
        negative = [entry for entry in self.entries if entry.get("comparisonMode") == "negative-invariant"]
        reduce_motion = [entry for entry in self.entries if entry.get("surface") == "reduce-motion"]
        self.expect(len(negative) == 4, "negative-entry-count-drift", path, "exactly four negative entries are required")
        self.expect(len(reduce_motion) == 20, "reduce-motion-entry-count-drift", path, "exactly twenty Reduce Motion entries are required")

    def expected_csv_rows(self) -> List[Dict[str, str]]:
        rows: List[Dict[str, str]] = []
        for entry, mapping in self.mappings:
            if "candidateElementID" in mapping:
                kind, identifier = "accessibility-element", mapping["candidateElementID"]
            elif "candidateRendererOutputID" in mapping:
                kind, identifier = "renderer-output", mapping["candidateRendererOutputID"]
            else:
                kind, identifier = "runtime-probe", mapping["candidateProbeID"]
            rows.append({
                "entryID": entry["id"],
                "mappingID": mapping["mappingID"],
                "theme": entry["theme"],
                "surface": entry["surface"],
                "destination": entry["destination"],
                "referenceAsset": mapping["referenceAsset"],
                "referenceRole": mapping["referenceRole"],
                "scoreDisposition": mapping["scoreDisposition"],
                "candidateKind": kind,
                "candidateID": identifier,
                "normalizationPolicy": mapping["normalizationPolicy"],
                "thresholdProfile": mapping["thresholdProfile"],
            })
        return rows

    def validate_mapping_index(self) -> None:
        path = self.active_paths.get("mappingIndex")
        if path is None or not path.is_file():
            return
        try:
            with path.open("r", encoding="utf-8", newline="") as handle:
                reader = csv.DictReader(handle)
                rows = list(reader)
                fields = reader.fieldnames
        except (OSError, UnicodeDecodeError, csv.Error) as error:
            self.add("invalid-mapping-index", path, str(error))
            return
        self.expect(fields == CSV_FIELDS, "mapping-index-header-drift", path, "mapping index header must be exact")
        self.expect(len(rows) == EXPECTED_MAPPING_COUNT, "mapping-index-count-drift", path, "mapping index must contain exactly 1104 rows")
        self.expect(rows == self.expected_csv_rows(), "mapping-index-projection-drift", path, "mapping index must exactly project all authority mappings in order")

    def validate_matrix(self) -> None:
        document = self.documents.get("matrix")
        if not isinstance(document, dict):
            return
        path = self.active_paths["matrix"]
        self.expect_exact_keys(document, {"schemaVersion", "matrixID", "entryCount", "mappingCount", "records"}, "invalid-matrix", self.display_path(path))
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("matrixID") == "runescribe.theme-fidelity.golden-matrix.v4.2", "matrix-identity-drift", path, "matrix identity must remain v4.2/v1.2")
        self.expect(document.get("entryCount") == EXPECTED_ENTRY_COUNT and document.get("mappingCount") == EXPECTED_MAPPING_COUNT, "matrix-count-drift", path, "matrix must declare 400 entries and 1104 mappings")
        records = document.get("records")
        expected = [{
            "entryID": entry.get("id"),
            "theme": entry.get("theme"),
            "surface": entry.get("surface"),
            "destination": entry.get("destination"),
            "comparisonMode": entry.get("comparisonMode"),
            "mappingIDs": [
                mapping.get("mappingID")
                for mapping in (
                    entry.get("referenceMappings", [])
                    if isinstance(entry.get("referenceMappings", []), list)
                    else []
                )
                if isinstance(mapping, dict)
            ],
            "runtimeProbeIDs": entry.get("runtimeProbeIDs"),
            "candidateOutputDirectory": entry.get("candidateOutputDirectory"),
        } for entry in self.entries]
        self.expect(records == expected, "matrix-projection-drift", path, "matrix must exactly project all 400 authority entries in order")

    def validate_coverage_report(self) -> None:
        document = self.documents.get("mappingCoverageReport")
        if not isinstance(document, dict):
            return
        path = self.active_paths["mappingCoverageReport"]
        expected_keys = {
            "schemaVersion", "result", "entryCount", "themeSurfaceAuthorityCount",
            "referenceMappingCount", "mappingDispositionCounts", "referenceRoleCounts",
            "entryComparisonModeCounts", "entriesByTheme", "entriesByDestination",
            "negativeInvariantEntries", "reduceMotionEntries",
            "groupsWithReferenceCandidateCountMismatch", "mappingsMissingExactCandidateSource",
            "mappingsMissingSourceCrop", "mappingsContainingPlaceholders",
            "requiresFurtherOwnerInput",
        }
        self.expect_exact_keys(document, expected_keys, "invalid-coverage-report", self.display_path(path))
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("result") == "PASS", "coverage-report-status-drift", path, "coverage report must be v1.2 PASS")
        self.expect(document.get("entryCount") == EXPECTED_ENTRY_COUNT and document.get("themeSurfaceAuthorityCount") == EXPECTED_GROUP_COUNT and document.get("referenceMappingCount") == EXPECTED_MAPPING_COUNT, "coverage-report-count-drift", path, "coverage report counts must be 400, 100, and 1104")
        self.expect(document.get("mappingDispositionCounts") == EXPECTED_DISPOSITIONS and document.get("referenceRoleCounts") == EXPECTED_REFERENCE_ROLES and document.get("entryComparisonModeCounts") == EXPECTED_COMPARISON_MODES, "coverage-report-aggregate-drift", path, "coverage report aggregates must match the authority")
        self.expect(document.get("entriesByTheme") == {theme: 80 for theme in EXPECTED_THEMES}, "coverage-report-theme-drift", path, "each Theme must have 80 entries")
        self.expect(document.get("entriesByDestination") == {destination: 100 for destination in EXPECTED_DESTINATIONS}, "coverage-report-destination-drift", path, "each destination must have 100 entries")
        negative_ids = [entry.get("id") for entry in self.entries if entry.get("comparisonMode") == "negative-invariant"]
        reduce_motion_ids = [entry.get("id") for entry in self.entries if entry.get("surface") == "reduce-motion"]
        self.expect(document.get("negativeInvariantEntries") == negative_ids and document.get("reduceMotionEntries") == reduce_motion_ids, "coverage-report-entry-list-drift", path, "negative and Reduce Motion entry lists must exactly match authority order")
        for field in ("groupsWithReferenceCandidateCountMismatch", "mappingsMissingExactCandidateSource", "mappingsMissingSourceCrop", "mappingsContainingPlaceholders"):
            self.expect(document.get(field) == [], "coverage-report-defect-drift", path, "{} must remain empty".format(field))
        self.expect(document.get("requiresFurtherOwnerInput") is False, "coverage-report-owner-input-drift", path, "coverage must require no further owner input")

    def validate_gate_catalog(self) -> None:
        document = self.documents.get("gateCatalog")
        if not isinstance(document, dict):
            return
        path = self.active_paths["gateCatalog"]
        self.expect_exact_keys(document, {"schemaVersion", "gates"}, "invalid-gate-catalog", self.display_path(path))
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION, "gate-schema-drift", path, "gate catalog schemaVersion must be 1.2")
        gates = document.get("gates")
        if not isinstance(gates, list):
            self.add("invalid-gate-catalog", path, "gates must be an array")
            return
        self.counts["gateCount"] = len(gates)
        self.expect(len(gates) == EXPECTED_GATE_COUNT, "gate-count-drift", path, "gate catalog must contain exactly 40 gates")
        ids: List[str] = []
        dependencies: Dict[str, List[str]] = {}
        for index, gate in enumerate(gates):
            label = "gates[{}]".format(index)
            if not self.expect_exact_keys(gate, {"id", "category", "blocking", "description", "requiredEvidence", "dependsOn"}, "invalid-gate-record", label):
                continue
            identifier = gate["id"]
            if isinstance(identifier, str):
                ids.append(identifier)
            self.expect(gate["blocking"] is True, "nonblocking-gate-drift", label, "every v4.2 gate must be blocking")
            self.expect(isinstance(gate["category"], str) and bool(gate["category"]) and isinstance(gate["description"], str) and bool(gate["description"].strip()), "invalid-gate-contract", label, "gate category and description are required")
            self.expect(isinstance(gate["requiredEvidence"], list) and bool(gate["requiredEvidence"]) and all(isinstance(item, str) and bool(item) for item in gate["requiredEvidence"]), "invalid-gate-evidence", label, "gate requiredEvidence must be a non-empty string array")
            dependencies_are_valid = isinstance(gate["dependsOn"], list) and all(isinstance(item, str) for item in gate["dependsOn"])
            self.expect(dependencies_are_valid and len(gate["dependsOn"]) == len(set(gate["dependsOn"])), "invalid-gate-dependencies", label, "gate dependencies must be a unique string array")
            if isinstance(identifier, str) and dependencies_are_valid:
                dependencies[identifier] = gate["dependsOn"]
        self.expect(len(ids) == len(set(ids)) == EXPECTED_GATE_COUNT, "duplicate-gate-id", path, "gate IDs must be unique")
        known = set(ids)
        self.expect(all(set(items).issubset(known) for items in dependencies.values()), "unknown-gate-dependency", path, "every dependency must reference a gate")
        visiting: Set[str] = set()
        visited: Set[str] = set()

        def visit(identifier: str) -> bool:
            if identifier in visiting:
                return False
            if identifier in visited:
                return True
            visiting.add(identifier)
            for dependency in dependencies.get(identifier, []):
                if not visit(dependency):
                    return False
            visiting.remove(identifier)
            visited.add(identifier)
            return True

        self.expect(all(visit(identifier) for identifier in ids), "gate-dependency-cycle", path, "gate dependencies must be acyclic")
        package_gate = next((gate for gate in gates if gate.get("id") == "PKG-001"), {})
        visual_gates = [gate for gate in gates if gate.get("category") == "visual"]
        self.expect("400" in package_gate.get("description", "") and "1104" in package_gate.get("description", "") and any("400" in gate.get("description", "") and "1104" in gate.get("description", "") for gate in visual_gates), "gate-authority-count-drift", path, "package and visual gates must explicitly bind 400 entries and 1104 mappings")

    def collect_rejected_digests(self) -> None:
        policy = self.manifest.get("repositoryPolicy", {})
        roots = policy.get("rejectedRoots", []) if isinstance(policy, dict) else []
        if not isinstance(roots, list):
            return
        for index, raw in enumerate(roots):
            root = self.resolve_repo_path(raw, "rejectedRoots[{}]".format(index))
            if root is None or not root.exists():
                continue
            if not root.is_dir():
                self.add("invalid-rejected-root", root, "rejected root exists but is not a directory")
                continue
            for path in sorted(root.rglob("*")):
                if path.is_file() and is_image_path(path):
                    try:
                        self.rejected_digests.add(sha256_file(path))
                    except OSError as error:
                        self.add("unreadable-rejected-asset", path, str(error))

    def validate_shipping_assets(self) -> None:
        policy = self.manifest.get("repositoryPolicy", {})
        roots = policy.get("shippingRoots", []) if isinstance(policy, dict) else []
        if not isinstance(roots, list):
            return
        for index, raw in enumerate(roots):
            root = self.resolve_repo_path(raw, "shippingRoots[{}]".format(index))
            if root is None:
                continue
            if not root.is_dir():
                self.add("missing-shipping-root", root, "shipping root is missing or is not a directory")
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
                relative = path.relative_to(root)
                directory_tokens = {part.casefold() for part in relative.parent.parts}
                tokens = path_tokens(relative)
                if digest in self.authority_asset_digests or directory_tokens & REFERENCE_PATH_TOKENS:
                    self.add("reference-asset-shipped", path, "authority reference material must not appear in a shipping resource root")
                if digest in self.rejected_digests or tokens & REJECTED_PATH_TOKENS:
                    self.add("rejected-asset-shipped", path, "rejected baseline material must not appear in a shipping resource root")

    def run(self) -> Dict[str, Any]:
        if self.load_import_manifest():
            self.validate_import_manifest()
            self.load_active_documents()
            self.validate_schemas()
            self.validate_assets()
            self.validate_candidate_catalog()
            self.validate_probe_catalog()
            self.validate_authority()
            self.validate_matrix()
            self.validate_mapping_index()
            self.validate_coverage_report()
            self.validate_gate_catalog()
            self.collect_rejected_digests()
            self.validate_shipping_assets()
        findings = sorted(set(self.findings))
        return {
            "schemaVersion": SCHEMA_VERSION,
            "authorityVersion": AUTHORITY_VERSION,
            "authorityStatus": self.manifest.get("status"),
            "result": "PASS" if not findings else "FAIL",
            "manifest": self.display_path(self.manifest_path),
            "manifestSHA256": self.manifest_sha256,
            **self.counts,
            "findings": [asdict(finding) for finding in findings],
        }
