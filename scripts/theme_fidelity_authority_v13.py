#!/usr/bin/env python3
"""Validate the repository-owned Theme-fidelity v1.3 authority import."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple, Union


SCHEMA_VERSION = "1.3"
AUTHORITY_VERSION = "4.3"
DEFAULT_IMPORT_MANIFEST = Path(
    "docs/verification/theme-fidelity-v4-3/authority/IMPORT-MANIFEST-v4.3.json"
)
EXPECTED_SOURCE_PACKAGE = {
    "identity": "Rune-Scribe-Theme-Fidelity-v4.3-Canonical-Authority-and-Remediation",
    "payloadTreeSHA256": "f5afb18cac3ff92680aced4346e1fa8c50ceeda5e6264d6cecf50c753092a8b0",
    "packageManifestSHA256": "e5fea0a6f7d3f6301ee2ac59973ffccda4a4627f542fd9d1aab139afba2c3039",
    "packageValidationSHA256": "86cecdbb45935629dd72a5c2e257f204b4feb0fc26075bb92700206a92709713",
    "packageChecksumsSHA256": "bae8f9524c318c230a1d6638ad38b593e84f89b35317988165cc0630e0d1d51a",
}
EXPECTED_ACTIVE_FILES = {
    "comparisonAuthority": "03-COMPARISON-AUTHORITY/Comparison-Authority-v1.3.json",
    "comparisonSchema": "03-COMPARISON-AUTHORITY/Comparison-Authority-Schema-v1.3.json",
    "canonicalCatalog": "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-v1.3.json",
    "canonicalSchema": "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-Schema-v1.3.json",
    "responsiveCandidateCatalog": "03-COMPARISON-AUTHORITY/Responsive-Candidate-Catalog-v1.3.json",
    "responsiveSurfaceMatrix": "03-COMPARISON-AUTHORITY/Responsive-Surface-Matrix-v1.3.json",
    "runtimeProbeCatalog": "03-COMPARISON-AUTHORITY/Runtime-Probe-Catalog-v1.3.json",
    "deterministicSeedCatalog": "03-COMPARISON-AUTHORITY/Deterministic-Seed-Catalog-v1.3.json",
    "mappingCoverageReport": "03-COMPARISON-AUTHORITY/Mapping-Coverage-Report-v1.3.json",
    "mappingIndex": "03-COMPARISON-AUTHORITY/Reference-Candidate-Mapping-Index-v1.3.csv",
    "translation": "03-COMPARISON-AUTHORITY/V4.2-to-V4.3-Mapping-Translation.json",
    "conflictResolution": "03-COMPARISON-AUTHORITY/V4.2-Conflict-Resolution-Report.json",
    "assetManifest": "04-ASSETS/FULL-ASSET-MANIFEST-v4.3.json",
    "canonicalSystemChromeMask": "04-ASSETS/98-CANONICAL-MASKS/iphone-941x1672-system-chrome-mask.png",
    "gateCatalog": "06-EVIDENCE/Gate-Catalog-v4.3.json",
    "finalQualificationSchema": "06-EVIDENCE/Final-Qualification-Schema-v1.3.json",
    "packageChecksums": "SHA256SUMS.txt",
}
EXPECTED_AUTHORITY_HASHES = {
    "comparisonAuthoritySHA256": "2762104ea48819888c96937800d903b9163cb13879ab24c663adf10101abfb2e",
    "canonicalRenderCatalogSHA256": "da599d438dfcad6792e9d472fadf30eebfcdeb7904e267e174add8208b974c8e",
    "gateCatalogSHA256": "5761076edf7b55043401e94dec516c822fe40aec696862e375e34d07857e9dca",
}
EXPECTED_COUNTS = {
    "responsiveEntries": 400,
    "canonicalCandidates": 50,
    "canonicalImageMappings": 400,
    "responsiveStructuralMappings": 700,
    "negativeInvariantMappings": 4,
    "mappingInstances": 1104,
    "runtimeProbeDefinitions": 50,
    "runtimeProbeInstances": 576,
    "deterministicSeeds": 100,
    "blockingGates": 40,
    "resolvedV4_2ConflictingEntries": 21,
}
EXPECTED_IMPORTED_FILES = {
    "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-Schema-v1.3.json",
    "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-v1.3.json",
    "03-COMPARISON-AUTHORITY/Comparison-Authority-Schema-v1.3.json",
    "03-COMPARISON-AUTHORITY/Comparison-Authority-v1.3.json",
    "03-COMPARISON-AUTHORITY/Deterministic-Seed-Catalog-v1.3.json",
    "03-COMPARISON-AUTHORITY/Mapping-Coverage-Report-v1.3.json",
    "03-COMPARISON-AUTHORITY/Reference-Candidate-Mapping-Index-v1.3.csv",
    "03-COMPARISON-AUTHORITY/Responsive-Candidate-Catalog-v1.3.json",
    "03-COMPARISON-AUTHORITY/Responsive-Surface-Matrix-v1.3.json",
    "03-COMPARISON-AUTHORITY/Runtime-Probe-Catalog-v1.3.json",
    "03-COMPARISON-AUTHORITY/V4.2-Conflict-Resolution-Report.json",
    "03-COMPARISON-AUTHORITY/V4.2-to-V4.3-Mapping-Translation.json",
    "04-ASSETS/98-CANONICAL-MASKS/iphone-941x1672-system-chrome-mask.png",
    "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/FULL-RES-SOURCE-MANIFEST.json",
    "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/FULL-RES-SOURCE-SEMANTIC-MAP.json",
    "04-ASSETS/99-ORIGINAL-FULL-RES-SOURCES/OWNER-ARCHIVE-COVERAGE-REPORT.json",
    "04-ASSETS/ASSET-MANIFEST.json",
    "04-ASSETS/ASSET-QUALITY-STATUS.json",
    "04-ASSETS/ASSET-USAGE-MAP.json",
    "04-ASSETS/FULL-ASSET-MANIFEST-v4.3.json",
    "04-ASSETS/REFERENCE-SLICE-MAP.json",
    "06-EVIDENCE/Final-Qualification-Schema-v1.3.json",
    "06-EVIDENCE/Gate-Catalog-v4.3.json",
    "ASSET-AUDIT.json",
    "IMPORT-MANIFEST-v4.3.json",
    "PACKAGE-AUTHORITY-VALIDATION.json",
    "PACKAGE-MANIFEST.json",
    "PACKAGE-VALIDATION.json",
    "SHA256SUMS.txt",
}
EXPECTED_THEMES = ("Norse", "Moonleaf", "Sunspire", "Wildwood", "Gloamthorn")
EXPECTED_SURFACES = (
    "workspace-empty", "compose-short", "compose-long", "inscription-preview",
    "received-cipher", "share-builder", "static-share", "settings-codex-card",
    "settings-defaults-preview", "vault-locked", "vault-progress",
    "vault-encountered", "vault-owned", "vault-selected", "relic-picker",
    "seal-picker", "mastery", "high-contrast", "reduce-motion", "large-text",
)
EXPECTED_DESTINATIONS = (
    "iphone-portrait", "ipad-portrait", "macos-standard", "macos-resized",
)
EXPECTED_MAPPING_COUNTS = Counter({
    "structural-assertion": 700,
    "image-metric": 400,
    "negative-invariant": 4,
})
EXPECTED_CANDIDATE_MODES = Counter({
    "canonical-production-component": 32,
    "full-production-screen": 12,
    "resolved-resource-export": 6,
})
EXPECTED_GATE_IDS = (
    "PRE-001", "REPO-001", "SRC-001", "ARCH-001", "BUILD-001",
    "BUILD-002", "BUILD-003", "TEST-001", "TEST-002", "RES-001",
    "RES-002", "RES-003", "RES-004", "NOR-001", "NOR-002", "NOR-003",
    "MIG-001", "PROG-001", "PROG-002", "THEME-001", "THEME-002",
    "UI-001", "UI-002", "UI-003", "VIS-001", "VIS-002", "VIS-003",
    "VIS-004", "VIS-005", "SHARE-001", "SHARE-002", "ACCESS-001",
    "ACCESS-002", "ACCESS-003", "ACCESS-004", "NEG-001", "EVID-001",
    "EVID-002", "PUB-001", "AUDIT-001",
)
CSV_FIELDS = [
    "entryID", "mappingID", "theme", "surface", "destination", "lane",
    "referenceAsset", "referenceSHA256", "referenceRole", "scoreDisposition",
    "candidateKind", "candidateID", "productionBindingKind",
    "productionBindingID", "normalizationPolicy", "thresholdProfile",
]
FULL_SOURCE_CROP = {
    "mode": "full-image",
    "normalizedRect": {"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0},
    "manualCoordinatesAllowed": False,
}
COMMON_HOST = {
    "locale": "en-US", "calendar": "gregorian", "timeZone": "UTC",
    "colorScheme": "dark", "dynamicType": "large", "displayScale": 1.0,
    "animationsEnabled": False, "safeAreaPolicy": "production-safe-area",
    "backgroundPolicy": "production-theme-background-or-authority-panel",
    "paddingPolicy": "recipe-defined-production-padding",
}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")


class DuplicateJSONKeyError(ValueError):
    pass


@dataclass(frozen=True, order=True)
class Finding:
    code: str
    path: str
    message: str


def reject_duplicate_keys(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKeyError("duplicate JSON key: {}".format(key))
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_package_path(value: Any) -> Optional[str]:
    if not isinstance(value, str) or not value or "\\" in value:
        return None
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        return None
    return value if path.as_posix() == value else None


class AuthorityV13Checker:
    """Cross-validate the frozen v1.3 catalogs and import boundary."""

    def __init__(self, root: Path, manifest_path: Path) -> None:
        self.root = root.resolve()
        self.manifest_path = manifest_path.resolve()
        self.authority_root = self.manifest_path.parent
        self.manifest: Dict[str, Any] = {}
        self.manifest_sha256: Optional[str] = None
        self.findings: List[Finding] = []
        self.documents: Dict[str, Any] = {}
        self.active_paths: Dict[str, Path] = {}
        self.package_records: Dict[str, Dict[str, Any]] = {}
        self.checksums: Dict[str, str] = {}
        self.assets: Dict[str, Dict[str, Any]] = {}
        self.candidates: Dict[str, Dict[str, Any]] = {}
        self.responsive_candidates: Dict[str, Dict[str, Any]] = {}
        self.seeds: Dict[str, Dict[str, Any]] = {}
        self.probes: Dict[str, Dict[str, Any]] = {}
        self.entries: List[Dict[str, Any]] = []
        self.mappings: List[Tuple[Dict[str, Any], Dict[str, Any]]] = []
        self.counts = dict(EXPECTED_COUNTS)

    def display_path(self, path: Path) -> str:
        try:
            return path.resolve().relative_to(self.root).as_posix()
        except ValueError:
            return str(path)

    def add(self, code: str, path: Union[Path, str], message: str) -> None:
        label = self.display_path(path) if isinstance(path, Path) else path
        self.findings.append(Finding(code, label, message))

    def expect(self, condition: bool, code: str, path: Union[Path, str], message: str) -> None:
        if not condition:
            self.add(code, path, message)

    def exact_keys(self, value: Any, keys: Set[str], code: str, label: str) -> bool:
        if not isinstance(value, dict):
            self.add(code, label, "value must be an object")
            return False
        if set(value) != keys:
            self.add(code, label, "object fields differ from the frozen contract")
            return False
        return True

    def resolve_active(self, raw: Any, label: str) -> Optional[Path]:
        relative = safe_package_path(raw)
        if relative is None:
            self.add("invalid-path", label, "path must be canonical and package-relative")
            return None
        path = (self.authority_root / relative).resolve()
        try:
            path.relative_to(self.authority_root.resolve())
        except ValueError:
            self.add("invalid-path", label, "path escapes the authority import")
            return None
        return path

    def load_manifest(self) -> bool:
        try:
            self.manifest_path.relative_to(self.root)
        except ValueError:
            self.add("invalid-manifest-path", self.manifest_path, "manifest must be repository-relative")
            return False
        if not self.manifest_path.is_file() or self.manifest_path.is_symlink():
            self.add("missing-manifest", self.manifest_path, "v4.3 import manifest is missing or linked")
            return False
        try:
            value = load_json(self.manifest_path)
        except (OSError, UnicodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
            self.add("invalid-manifest", self.manifest_path, str(error))
            return False
        if not isinstance(value, dict):
            self.add("invalid-manifest", self.manifest_path, "manifest root must be an object")
            return False
        self.manifest = value
        self.manifest_sha256 = sha256_file(self.manifest_path)
        return True

    def validate_manifest(self) -> None:
        path = self.manifest_path
        self.exact_keys(
            self.manifest,
            {"schemaVersion", "authorityVersion", "status", "sourcePackage",
             "importPolicy", "activeFiles", "authorityHashes", "counts",
             "requiresFurtherOwnerInput"},
            "invalid-import-manifest", self.display_path(path),
        )
        self.expect(self.manifest.get("schemaVersion") == "1.0", "manifest-version-drift", path, "import schema must be 1.0")
        self.expect(self.manifest.get("authorityVersion") == AUTHORITY_VERSION, "manifest-version-drift", path, "authority version must be 4.3")
        self.expect(self.manifest.get("status") == "active-acceptance-authority", "manifest-status-drift", path, "authority must remain active")
        self.expect(self.manifest.get("sourcePackage") == EXPECTED_SOURCE_PACKAGE, "source-package-drift", path, "source package identity or hashes changed")
        self.expect(self.manifest.get("activeFiles") == EXPECTED_ACTIVE_FILES, "active-file-drift", path, "active file projection changed")
        self.expect(self.manifest.get("authorityHashes") == EXPECTED_AUTHORITY_HASHES, "authority-hash-contract-drift", path, "authority hash locks changed")
        self.expect(self.manifest.get("counts") == EXPECTED_COUNTS, "authority-count-contract-drift", path, "authority cardinalities changed")
        self.expect(self.manifest.get("requiresFurtherOwnerInput") is False, "owner-input-drift", path, "authority must not require owner input")
        policy = self.manifest.get("importPolicy", {})
        self.expect(
            isinstance(policy, dict)
            and "Reference imagery remains immutable" in policy.get("excludedContent", "")
            and "Production renderers receive no authority image bytes" in policy.get("excludedContent", ""),
            "import-policy-drift", path, "reference-byte separation policy changed",
        )
        for key, relative in EXPECTED_ACTIVE_FILES.items():
            active = self.resolve_active(relative, "activeFiles.{}".format(key))
            if active is None:
                continue
            self.active_paths[key] = active
            self.expect(active.is_file() and not active.is_symlink(), "missing-active-file", active, "active file is missing or linked")

        actual = {
            item.relative_to(self.authority_root).as_posix()
            for item in self.authority_root.rglob("*")
            if item.is_file()
        }
        self.expect(actual == EXPECTED_IMPORTED_FILES, "import-inventory-drift", self.authority_root, "imported authority file set changed")

    def validate_package_integrity(self) -> None:
        manifest_path = self.authority_root / "PACKAGE-MANIFEST.json"
        validation_path = self.authority_root / "PACKAGE-VALIDATION.json"
        sums_path = self.authority_root / "SHA256SUMS.txt"
        try:
            package = load_json(manifest_path)
            validation = load_json(validation_path)
        except (OSError, UnicodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
            self.add("invalid-package-control", self.authority_root, str(error))
            return
        self.expect(sha256_file(manifest_path) == EXPECTED_SOURCE_PACKAGE["packageManifestSHA256"], "package-control-hash-drift", manifest_path, "package manifest hash changed")
        self.expect(sha256_file(validation_path) == EXPECTED_SOURCE_PACKAGE["packageValidationSHA256"], "package-control-hash-drift", validation_path, "package validation hash changed")
        self.expect(sha256_file(sums_path) == EXPECTED_SOURCE_PACKAGE["packageChecksumsSHA256"], "package-control-hash-drift", sums_path, "package checksum index hash changed")
        self.expect(validation.get("result") == "PASS", "package-validation-drift", validation_path, "packaged validation is not PASS")
        records = package.get("files", [])
        if not isinstance(records, list):
            self.add("invalid-package-manifest", manifest_path, "files must be an array")
            return
        by_path: Dict[str, Dict[str, Any]] = {}
        for index, record in enumerate(records):
            relative = safe_package_path(record.get("path") if isinstance(record, dict) else None)
            if relative is None or relative in by_path:
                self.add("invalid-package-manifest", "files[{}]".format(index), "unsafe or duplicate path")
                continue
            by_path[relative] = record
            self.expect(isinstance(record.get("byteCount"), int) and record["byteCount"] >= 0, "invalid-package-manifest", relative, "invalid byte count")
            self.expect(isinstance(record.get("sha256"), str) and SHA256_PATTERN.fullmatch(record["sha256"]) is not None, "invalid-package-manifest", relative, "invalid SHA-256")
        self.package_records = by_path
        self.expect(len(records) == package.get("fileCount") == 264, "package-count-drift", manifest_path, "package manifest must contain 264 payload records")
        self.expect(sum(item.get("byteCount", 0) for item in records if isinstance(item, dict)) == package.get("totalPayloadBytes") == 210301763, "package-byte-count-drift", manifest_path, "package byte aggregate changed")
        tree = "".join(
            "{}  {}  {}\n".format(by_path[name].get("sha256"), by_path[name].get("byteCount"), name)
            for name in sorted(by_path)
        ).encode("utf-8")
        tree_hash = hashlib.sha256(tree).hexdigest()
        self.expect(tree_hash == package.get("payloadTreeSHA256") == EXPECTED_SOURCE_PACKAGE["payloadTreeSHA256"], "package-tree-hash-drift", manifest_path, "package payload tree changed")
        expected_sums = "".join("{}  {}\n".format(by_path[name].get("sha256"), name) for name in sorted(by_path))
        try:
            actual_sums = sums_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            self.add("invalid-package-checksums", sums_path, str(error))
            actual_sums = ""
        self.expect(actual_sums == expected_sums, "package-checksum-projection-drift", sums_path, "checksum index differs from package manifest")
        self.checksums = {name: record.get("sha256") for name, record in by_path.items()}

        controls = {"IMPORT-MANIFEST-v4.3.json", "PACKAGE-MANIFEST.json", "PACKAGE-VALIDATION.json", "SHA256SUMS.txt"}
        for relative in sorted(EXPECTED_IMPORTED_FILES - controls):
            path = self.authority_root / relative
            record = by_path.get(relative)
            if record is None or not path.is_file():
                self.add("missing-package-record", path, "imported payload lacks a package record")
                continue
            self.expect(path.stat().st_size == record.get("byteCount"), "imported-file-byte-drift", path, "imported byte count differs from package")
            self.expect(sha256_file(path) == record.get("sha256"), "imported-file-hash-drift", path, "imported hash differs from package")

    def load_documents(self) -> None:
        for key, path in self.active_paths.items():
            if path.suffix != ".json":
                continue
            try:
                self.documents[key] = load_json(path)
            except (OSError, UnicodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
                self.add("invalid-json", path, str(error))

    def validate_asset_manifest(self) -> None:
        document = self.documents.get("assetManifest")
        path = self.active_paths.get("assetManifest", self.authority_root)
        if not isinstance(document, dict):
            return
        assets = document.get("assets", [])
        self.expect(document.get("schemaVersion") == AUTHORITY_VERSION, "asset-manifest-version-drift", path, "full asset manifest must be v4.3")
        self.expect(isinstance(assets, list) and document.get("assetCount") == len(assets) == 171, "asset-count-drift", path, "full asset manifest must contain 171 records")
        if not isinstance(assets, list):
            return
        for index, item in enumerate(assets):
            if not isinstance(item, dict):
                self.add("invalid-asset-record", "assets[{}]".format(index), "record must be an object")
                continue
            relative = safe_package_path(item.get("path"))
            if relative is None or relative in self.assets:
                self.add("invalid-asset-record", "assets[{}]".format(index), "unsafe or duplicate asset path")
                continue
            self.assets[relative] = item
            package_record = self.package_records.get(relative)
            self.expect(package_record is not None, "missing-asset-package-record", relative, "asset is absent from package manifest")
            if package_record:
                self.expect(item.get("sha256") == package_record.get("sha256") and item.get("byteCount") == package_record.get("byteCount"), "asset-package-projection-drift", relative, "asset metadata differs from package record")

    def validate_seed_catalog(self) -> None:
        document = self.documents.get("deterministicSeedCatalog")
        path = self.active_paths.get("deterministicSeedCatalog", self.authority_root)
        if not isinstance(document, dict):
            return
        seeds = document.get("seeds", [])
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("catalogID") == "runescribe.theme-fidelity.deterministic-seed-catalog.v4.3", "seed-catalog-identity-drift", path, "seed catalog identity changed")
        self.expect(isinstance(seeds, list) and document.get("seedCount") == len(seeds) == 100, "seed-count-drift", path, "seed catalog must contain 100 records")
        if not isinstance(seeds, list):
            return
        combinations: Set[Tuple[Any, Any]] = set()
        for index, seed in enumerate(seeds):
            label = "seeds[{}]".format(index)
            if not self.exact_keys(seed, {"id", "theme", "surface", "launchEnvironment", "operatorInputRequired"}, "invalid-seed-record", label):
                continue
            identifier = seed.get("id")
            if not isinstance(identifier, str) or identifier in self.seeds:
                self.add("duplicate-seed-id", label, "seed ID is missing or duplicated")
                continue
            self.seeds[identifier] = seed
            combinations.add((seed.get("theme"), seed.get("surface")))
            environment = seed.get("launchEnvironment", {})
            self.expect(seed.get("operatorInputRequired") is False, "seed-operator-input-drift", label, "seed must remain autonomous")
            self.expect(isinstance(environment, dict) and environment.get("RUNESCRIBE_QUALIFICATION") == "theme-fidelity-v4.2", "seed-marker-drift", label, "qualification marker must remain theme-fidelity-v4.2")
            self.expect(environment.get("RUNESCRIBE_QUALIFICATION_SURFACE") == seed.get("surface"), "seed-surface-drift", label, "launch surface differs from seed")
            self.expect(environment.get("RUNESCRIBE_QUALIFICATION_RESET_STATE") == "1", "seed-reset-drift", label, "reset-state marker must remain 1")
        expected = {(theme, surface) for theme in EXPECTED_THEMES for surface in EXPECTED_SURFACES}
        self.expect(combinations == expected and len(self.seeds) == 100, "seed-cardinality-drift", path, "seed Theme/surface Cartesian product changed")

    def validate_probe_catalog(self) -> None:
        document = self.documents.get("runtimeProbeCatalog")
        path = self.active_paths.get("runtimeProbeCatalog", self.authority_root)
        if not isinstance(document, dict):
            return
        probes = document.get("probes", [])
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("catalogID") == "runescribe.theme-fidelity.runtime-probe-catalog.v4.3", "probe-catalog-identity-drift", path, "probe catalog identity changed")
        self.expect(isinstance(probes, list) and document.get("probeCount") == len(probes) == 50, "probe-count-drift", path, "probe catalog must contain 50 records")
        if not isinstance(probes, list):
            return
        for index, probe in enumerate(probes):
            label = "probes[{}]".format(index)
            if not self.exact_keys(probe, {"id", "source", "operator", "expected", "description", "evidencePath"}, "invalid-probe-record", label):
                continue
            identifier = probe.get("id")
            if not isinstance(identifier, str) or identifier in self.probes:
                self.add("duplicate-probe-id", label, "probe ID is missing or duplicated")
                continue
            self.probes[identifier] = probe
            evidence = probe.get("evidencePath")
            self.expect(safe_package_path(evidence) is not None and evidence.startswith("docs/verification/theme-fidelity-v4-3/runtime-probes/"), "probe-path-drift", label, "probe evidence path must remain under the v4.3 runtime-probe root")

    def validate_responsive_candidates(self) -> None:
        document = self.documents.get("responsiveCandidateCatalog")
        path = self.active_paths.get("responsiveCandidateCatalog", self.authority_root)
        if not isinstance(document, dict):
            return
        items = document.get("candidates", [])
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("catalogID") == "runescribe.theme-fidelity.responsive-candidate-catalog.v4.3", "responsive-candidate-identity-drift", path, "responsive candidate identity changed")
        self.expect(isinstance(items, list) and document.get("candidateCount") == len(items) == 188, "responsive-candidate-count-drift", path, "responsive candidate catalog must contain 188 records")
        if not isinstance(items, list):
            return
        kinds = Counter()
        for index, item in enumerate(items):
            label = "candidates[{}]".format(index)
            if not self.exact_keys(item, {"id", "kind", "captureOperation", "purpose", "missingBehavior"}, "invalid-responsive-candidate", label):
                continue
            identifier = item.get("id")
            if not isinstance(identifier, str) or identifier in self.responsive_candidates:
                self.add("duplicate-responsive-candidate-id", label, "candidate ID is missing or duplicated")
                continue
            self.responsive_candidates[identifier] = item
            kinds[item.get("kind")] += 1
            expected_operation = {"accessibility-element": "xcui-element-screenshot", "renderer-output": "deterministic-png-export"}.get(item.get("kind"))
            self.expect(item.get("captureOperation") == expected_operation, "responsive-candidate-kind-drift", label, "kind and capture operation disagree")
        self.expect(kinds == Counter({"accessibility-element": 183, "renderer-output": 5}), "responsive-candidate-kind-count-drift", path, "responsive candidate kind counts changed")

    def validate_canonical_catalog(self) -> None:
        document = self.documents.get("canonicalCatalog")
        path = self.active_paths.get("canonicalCatalog", self.authority_root)
        if not isinstance(document, dict):
            return
        items = document.get("candidates", [])
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("catalogID") == "runescribe.theme-fidelity.v4.3.canonical-render-catalog", "canonical-catalog-identity-drift", path, "canonical catalog identity changed")
        self.expect(document.get("requiresFurtherOwnerInput") is False, "canonical-owner-input-drift", path, "canonical catalog must require no owner input")
        self.expect(isinstance(items, list) and document.get("candidateCount") == len(items) == 50, "canonical-count-drift", path, "canonical catalog must contain 50 records")
        if not isinstance(items, list):
            return
        modes = Counter()
        wrappers: Set[Any] = set()
        outputs: Set[Any] = set()
        identities: Set[Tuple[Any, Tuple[Any, ...]]] = set()
        reference_paths: Set[Any] = set()
        for index, item in enumerate(items):
            label = "canonicalCandidates[{}]".format(index)
            if not isinstance(item, dict):
                self.add("invalid-canonical-candidate", label, "record must be an object")
                continue
            identifier = item.get("id")
            if not isinstance(identifier, str) or identifier in self.candidates:
                self.add("duplicate-canonical-candidate-id", label, "candidate ID is missing or duplicated")
                continue
            self.candidates[identifier] = item
            modes[item.get("renderMode")] += 1
            wrapper = item.get("requiredCanonicalWrapperID")
            output = item.get("outputPath")
            reference = item.get("referenceAsset")
            wrappers.add(wrapper)
            outputs.add(output)
            reference_paths.add(reference)
            dimensions = item.get("referenceDimensions")
            identity = (item.get("referenceSHA256"), tuple(dimensions) if isinstance(dimensions, list) else ())
            identities.add(identity)
            self.expect(wrapper == identifier + ".wrapper", "canonical-wrapper-drift", label, "wrapper ID must be candidate ID plus .wrapper")
            self.expect(safe_package_path(output) is not None and output.startswith("docs/verification/theme-fidelity-v4-3/canonical/") and "/authority/" not in output, "candidate-reference-separation", label, "candidate output must remain outside the authority import")
            self.expect(safe_package_path(reference) is not None and reference.startswith("04-ASSETS/"), "invalid-reference-path", label, "reference path must be package-relative")
            self.expect(not (self.authority_root / str(reference)).exists(), "candidate-reference-separation", label, "reference image bytes must not be imported")
            self.expect(item.get("requiredOutputDimensions") == dimensions, "canonical-dimension-drift", label, "output and reference dimensions must match exactly")
            self.expect(item.get("host") == COMMON_HOST, "canonical-host-drift", label, "canonical host contract changed")
            asset = self.assets.get(reference)
            self.expect(asset is not None, "unknown-reference-asset", label, "reference is absent from the full asset manifest")
            if asset:
                self.expect(item.get("referenceSHA256") == asset.get("sha256") and item.get("referenceByteCount") == asset.get("byteCount") and dimensions == asset.get("dimensions"), "canonical-reference-metadata-drift", label, "candidate reference metadata differs from asset manifest")
            mode = item.get("renderMode")
            expected_profile = {"full-production-screen": "canonical-screen-v1", "canonical-production-component": "canonical-component-v1", "resolved-resource-export": "exact-resource-v1"}.get(mode)
            expected_evaluation = "resource-byte-identity" if mode == "resolved-resource-export" else "visual-metric"
            self.expect(item.get("thresholdProfile") == expected_profile and item.get("evaluationKind") == expected_evaluation, "canonical-mode-policy-drift", label, "render mode, threshold, and evaluation disagree")
            mask = item.get("comparisonMask")
            expected_mask = EXPECTED_ACTIVE_FILES["canonicalSystemChromeMask"] if mode == "full-production-screen" else None
            self.expect(mask == expected_mask, "canonical-mask-drift", label, "canonical mask policy changed")
        self.expect(modes == EXPECTED_CANDIDATE_MODES, "canonical-mode-count-drift", path, "canonical render-mode counts changed")
        self.expect(len(self.candidates) == len(wrappers) == len(outputs) == 50, "canonical-cardinality-drift", path, "canonical IDs, wrappers, and outputs must be unique")
        self.expect(len(reference_paths) == 50 and len(identities) == 49, "canonical-reference-cardinality-drift", path, "expected 50 named references and 49 identities")
        self.expect(outputs.isdisjoint(reference_paths), "candidate-reference-separation", path, "candidate and reference paths overlap")

    def validate_authority(self) -> None:
        document = self.documents.get("comparisonAuthority")
        path = self.active_paths.get("comparisonAuthority", self.authority_root)
        if not isinstance(document, dict):
            return
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("authorityID") == "runescribe.theme-fidelity.v4.3.canonical-responsive-authority", "authority-identity-drift", path, "comparison authority identity changed")
        for key, value in {
            "expectedEntryCount": 400, "reviewedEntryCount": 400,
            "unreviewedEntryCount": 0, "expectedThemeSurfaceAuthorityCount": 100,
            "expectedReferenceMappingCount": 1104,
            "expectedCanonicalCandidateCount": 50,
            "expectedCanonicalImageMappingCount": 400,
            "expectedResponsiveStructuralMappingCount": 700,
            "expectedNegativeInvariantMappingCount": 4,
            "canonicalCandidateCount": 50,
        }.items():
            self.expect(document.get(key) == value, "authority-count-drift", path, "{} must equal {}".format(key, value))
        self.expect(document.get("manualCropCoordinatesAuthorized") is False and document.get("customMaskFilesAuthorized") is True and document.get("canonicalCandidateReferenceUniquenessRequired") is True and document.get("requiresFurtherOwnerInput") is False, "authority-policy-drift", path, "authority safety policy changed")
        self.expect(set(document.get("themes", {})) == set(EXPECTED_THEMES) and set(document.get("destinations", {})) == set(EXPECTED_DESTINATIONS), "authority-domain-drift", path, "Theme or destination set changed")
        normalization = document.get("normalizationPolicies", {})
        exact = normalization.get("exact-dimensions-no-resize-v1", {}) if isinstance(normalization, dict) else {}
        self.expect(set(normalization) == {"exact-dimensions-no-resize-v1", "responsive-structural-v1"} and exact == {"candidateDimensionsMustEqualReference": True, "croppingAllowed": False, "letterboxingAllowed": False, "resizingAllowed": False, "rotationAllowed": False}, "normalization-policy-drift", path, "exact-dimension policy changed")
        profiles = document.get("thresholdProfiles", {})
        self.expect(set(profiles) == {"canonical-screen-v1", "canonical-component-v1", "exact-resource-v1", "responsive-structural-v1", "runtime-reduce-motion-v1", "negative-invariant-v1", "mixed-canonical-responsive-v1"}, "threshold-policy-drift", path, "threshold profile set changed")
        exact_resource = profiles.get("exact-resource-v1", {}) if isinstance(profiles, dict) else {}
        self.expect(exact_resource.get("byteIdentityRequired") is True and exact_resource.get("sha256IdentityRequired") is True and exact_resource.get("dimensionIdentityRequired") is True, "threshold-policy-drift", path, "exact-resource identity requirements changed")
        assertions = document.get("structuralAssertionCatalog", {})
        self.expect(isinstance(assertions, dict) and len(assertions) == 14, "structural-assertion-count-drift", path, "structural assertion catalog must contain 14 definitions")
        entries = document.get("entries", [])
        self.expect(isinstance(entries, list) and len(entries) == 400, "authority-entry-count-drift", path, "authority must contain 400 entries")
        if not isinstance(entries, list):
            return
        self.entries = [entry for entry in entries if isinstance(entry, dict)]
        expected_combinations = {(t, s, d) for t in EXPECTED_THEMES for s in EXPECTED_SURFACES for d in EXPECTED_DESTINATIONS}
        combinations = {(e.get("theme"), e.get("surface"), e.get("destination")) for e in self.entries}
        self.expect(combinations == expected_combinations and len({e.get("id") for e in self.entries}) == 400, "authority-entry-cardinality-drift", path, "entry Cartesian product or IDs changed")
        disposition_counts = Counter()
        source_counts = Counter()
        used_probes: Set[str] = set()
        candidate_pairs: Dict[str, Set[Tuple[Any, Tuple[Any, ...]]]] = defaultdict(set)
        used_candidates = Counter()
        mapping_ids: Set[Any] = set()
        for entry in self.entries:
            label = str(entry.get("id"))
            self.expect(entry.get("seedID") in self.seeds, "unknown-entry-seed", label, "entry references an unknown seed")
            probes = entry.get("runtimeProbeIDs", [])
            self.expect(isinstance(probes, list) and set(probes).issubset(self.probes), "unknown-entry-probe", label, "entry references an unknown probe")
            if isinstance(probes, list):
                used_probes.update(probes)
            self.expect(entry.get("review", {}).get("reviewed") is True and entry.get("review", {}).get("status") == "approved" and entry.get("review", {}).get("requiresFurtherOwnerInput") is False, "entry-review-drift", label, "entry is not fully approved")
            output = entry.get("candidateOutputDirectory")
            self.expect(safe_package_path(output) is not None and output.startswith("docs/verification/theme-fidelity-v4-3/comparisons/"), "entry-output-path-drift", label, "comparison output path is outside v4.3 evidence")
            mappings = entry.get("referenceMappings", [])
            if not isinstance(mappings, list):
                self.add("invalid-entry-mappings", label, "referenceMappings must be an array")
                continue
            self.expect(entry.get("referenceMappingCount") == len(mappings), "entry-mapping-count-drift", label, "declared mapping count differs")
            for mapping in mappings:
                if not isinstance(mapping, dict):
                    continue
                self.mappings.append((entry, mapping))
                mid = mapping.get("mappingID")
                self.expect(mid not in mapping_ids, "duplicate-mapping-id", label, "mapping ID is duplicated")
                mapping_ids.add(mid)
                disposition = mapping.get("scoreDisposition")
                disposition_counts[disposition] += 1
                self.expect(mapping.get("sourceCrop") == FULL_SOURCE_CROP and mapping.get("focalRegion", {}).get("manualCoordinatesAllowed") is False, "manual-source-crop-drift", str(mid), "only complete reference images are authorized")
                reference = mapping.get("referenceAsset")
                asset = self.assets.get(reference)
                self.expect(asset is not None, "unknown-reference-asset", str(mid), "mapping reference is absent from asset manifest")
                if asset:
                    self.expect(mapping.get("referenceSHA256") == asset.get("sha256") and mapping.get("referenceByteCount") == asset.get("byteCount") and mapping.get("referenceDimensions") == asset.get("dimensions"), "mapping-reference-metadata-drift", str(mid), "mapping metadata differs from asset manifest")
                if disposition == "image-metric":
                    forbidden = {"candidateElementID", "candidateRendererOutputID", "candidateProbeID"} & set(mapping)
                    self.expect(not forbidden, "candidate-reference-separation", str(mid), "canonical mapping retains a responsive candidate binding")
                    candidate_id = mapping.get("candidateCanonicalOutputID")
                    source_counts["candidateCanonicalOutputID"] += 1
                    candidate = self.candidates.get(candidate_id)
                    self.expect(candidate is not None, "unknown-canonical-candidate", str(mid), "canonical candidate is not declared")
                    if candidate:
                        pair = (mapping.get("referenceSHA256"), tuple(mapping.get("referenceDimensions", [])))
                        candidate_pairs[candidate_id].add(pair)
                        used_candidates[candidate_id] += 1
                        self.expect(pair == (candidate.get("referenceSHA256"), tuple(candidate.get("referenceDimensions", []))), "canonical-reference-binding-drift", str(mid), "candidate and reference identity differ")
                        self.expect(mapping.get("canonicalRenderSpecID") == candidate_id and mapping.get("requiredCanonicalWrapperID") == candidate.get("requiredCanonicalWrapperID") and mapping.get("thresholdProfile") == candidate.get("thresholdProfile"), "canonical-render-binding-drift", str(mid), "canonical render binding differs from catalog")
                    self.expect(mapping.get("evaluationLane") == "canonical" and mapping.get("normalizationPolicy") == "exact-dimensions-no-resize-v1", "canonical-policy-drift", str(mid), "canonical mapping policy changed")
                elif disposition == "structural-assertion":
                    fields = [name for name in ("candidateElementID", "candidateRendererOutputID") if name in mapping]
                    self.expect(len(fields) == 1, "mapping-candidate-source-drift", str(mid), "responsive mapping must name exactly one candidate")
                    if fields:
                        field = fields[0]
                        source_counts[field] += 1
                        candidate = self.responsive_candidates.get(mapping.get(field))
                        expected_kind = "accessibility-element" if field == "candidateElementID" else "renderer-output"
                        self.expect(candidate is not None and candidate.get("kind") == expected_kind, "unknown-responsive-candidate", str(mid), "responsive candidate is missing or wrong kind")
                    self.expect(mapping.get("evaluationLane") == "responsive", "responsive-policy-drift", str(mid), "structural mapping lane changed")
                elif disposition == "negative-invariant":
                    source_counts["candidateProbeID"] += 1
                    self.expect(mapping.get("candidateProbeID") in self.probes and mapping.get("evaluationLane") == "runtime", "negative-invariant-binding-drift", str(mid), "negative invariant must bind a declared runtime probe")
                else:
                    self.add("unknown-mapping-disposition", str(mid), "unknown score disposition")
        self.expect(disposition_counts == EXPECTED_MAPPING_COUNTS and len(mapping_ids) == 1104, "mapping-count-drift", path, "mapping disposition counts changed")
        self.expect(source_counts == Counter({"candidateElementID": 665, "candidateCanonicalOutputID": 400, "candidateRendererOutputID": 35, "candidateProbeID": 4}), "mapping-source-cardinality-drift", path, "candidate source field counts changed")
        self.expect(set(candidate_pairs) == set(self.candidates) and all(len(value) == 1 for value in candidate_pairs.values()) and sum(used_candidates.values()) == 400, "candidate-reference-conflict", path, "canonical candidates are missing, unused, or bound to incompatible references")
        probe_instances = sum(len(entry.get("runtimeProbeIDs", [])) for entry in self.entries)
        self.counts["runtimeProbeInstances"] = probe_instances
        self.expect(used_probes == set(self.probes) and probe_instances == 576, "probe-use-cardinality-drift", path, "probe definitions or instances are missing")

    def validate_responsive_matrix(self) -> None:
        document = self.documents.get("responsiveSurfaceMatrix")
        path = self.active_paths.get("responsiveSurfaceMatrix", self.authority_root)
        if not isinstance(document, dict):
            return
        expected = []
        for entry in self.entries:
            mappings = entry.get("referenceMappings", [])
            expected.append({
                "entryID": entry.get("id"), "theme": entry.get("theme"),
                "themeID": entry.get("themeID"), "codexID": entry.get("codexID"),
                "surface": entry.get("surface"), "destination": entry.get("destination"),
                "seedID": entry.get("seedID"), "applicability": entry.get("applicability"),
                "entryStructuralAssertionIDs": entry.get("entryStructuralAssertionIDs"),
                "runtimeProbeIDs": entry.get("runtimeProbeIDs"),
                "candidateOutputDirectory": entry.get("candidateOutputDirectory"),
                "structuralMappings": [m for m in mappings if m.get("scoreDisposition") == "structural-assertion"],
                "negativeInvariantMappings": [m for m in mappings if m.get("scoreDisposition") == "negative-invariant"],
            })
        self.expect(document.get("schemaVersion") == SCHEMA_VERSION and document.get("entryCount") == 400 and document.get("entries") == expected, "responsive-matrix-projection-drift", path, "responsive matrix is not the exact 400-entry authority projection")

    def validate_mapping_index(self) -> None:
        path = self.active_paths.get("mappingIndex")
        if path is None or not path.is_file():
            return
        try:
            with path.open("r", encoding="utf-8", newline="") as stream:
                reader = csv.DictReader(stream)
                fields = reader.fieldnames
                actual = list(reader)
        except (OSError, UnicodeError, csv.Error) as error:
            self.add("invalid-mapping-index", path, str(error))
            return
        expected = []
        for entry, mapping in self.mappings:
            if "candidateCanonicalOutputID" in mapping:
                kind = "canonical-output"
                candidate_id = mapping.get("candidateCanonicalOutputID")
                former = mapping.get("v42FormerCandidateBinding", {})
                production_kind = former.get("kind", "")
                production_id = former.get("id", "")
            elif "candidateElementID" in mapping:
                kind, candidate_id, production_kind, production_id = "accessibility-element", mapping.get("candidateElementID"), "", ""
            elif "candidateRendererOutputID" in mapping:
                kind, candidate_id, production_kind, production_id = "renderer-output", mapping.get("candidateRendererOutputID"), "", ""
            else:
                kind, candidate_id, production_kind, production_id = "runtime-probe", mapping.get("candidateProbeID"), "", ""
            expected.append({
                "entryID": str(entry.get("id", "")), "mappingID": str(mapping.get("mappingID", "")),
                "theme": str(entry.get("theme", "")), "surface": str(entry.get("surface", "")),
                "destination": str(entry.get("destination", "")), "lane": str(mapping.get("evaluationLane", "")),
                "referenceAsset": str(mapping.get("referenceAsset", "")), "referenceSHA256": str(mapping.get("referenceSHA256", "")),
                "referenceRole": str(mapping.get("referenceRole", "")), "scoreDisposition": str(mapping.get("scoreDisposition", "")),
                "candidateKind": kind, "candidateID": str(candidate_id or ""),
                "productionBindingKind": str(production_kind or ""), "productionBindingID": str(production_id or ""),
                "normalizationPolicy": str(mapping.get("normalizationPolicy", "")), "thresholdProfile": str(mapping.get("thresholdProfile", "")),
            })
        self.expect(fields == CSV_FIELDS and actual == expected and len(actual) == 1104, "mapping-index-projection-drift", path, "mapping index is not the exact ordered authority projection")

    def validate_coverage_and_resolution(self) -> None:
        coverage = self.documents.get("mappingCoverageReport")
        coverage_path = self.active_paths.get("mappingCoverageReport", self.authority_root)
        if isinstance(coverage, dict):
            expected = {
                "entryCount": 400, "themeSurfaceAuthorityCount": 100,
                "mappingCount": 1104, "canonicalImageMappingCount": 400,
                "responsiveStructuralMappingCount": 700,
                "negativeInvariantMappingCount": 4, "canonicalCandidateCount": 50,
                "uniqueReferenceCount": 49, "conflictingCandidateReferenceBindings": 0,
                "missingCandidateBindings": 0, "namedReferenceAssetCount": 50,
                "uniqueReferenceIdentityCount": 49, "duplicateReferenceIdentityGroupCount": 1,
            }
            self.expect(coverage.get("schemaVersion") == SCHEMA_VERSION and all(coverage.get(k) == v for k, v in expected.items()), "coverage-report-drift", coverage_path, "coverage report counts changed")
        translation = self.documents.get("translation")
        translation_path = self.active_paths.get("translation", self.authority_root)
        image_mappings = {m.get("mappingID"): m for _, m in self.mappings if m.get("scoreDisposition") == "image-metric"}
        if isinstance(translation, dict):
            records = translation.get("records", [])
            self.expect(translation.get("recordCount") == len(records) == 400 and {x.get("mappingID") for x in records if isinstance(x, dict)} == set(image_mappings), "translation-cardinality-drift", translation_path, "translation must cover all 400 canonical mappings")
            for item in records if isinstance(records, list) else []:
                if not isinstance(item, dict):
                    continue
                candidate = self.candidates.get(item.get("v43CanonicalCandidateID"))
                self.expect(candidate is not None and item.get("v43CanonicalWrapperID") == candidate.get("requiredCanonicalWrapperID") and item.get("v43OutputDimensions") == candidate.get("requiredOutputDimensions"), "translation-binding-drift", str(item.get("mappingID")), "translation differs from canonical catalog")
        conflict = self.documents.get("conflictResolution")
        conflict_path = self.active_paths.get("conflictResolution", self.authority_root)
        if isinstance(conflict, dict):
            records = conflict.get("records", [])
            self.expect(conflict.get("result") == "RESOLVED_BY_SEPARATE_CANONICAL_OUTPUTS" and conflict.get("conflictingEntryCount") == len(records) == 21, "conflict-resolution-count-drift", conflict_path, "conflict report must contain 21 resolved entries")
            for record in records if isinstance(records, list) else []:
                resolved = record.get("resolvedMappings", []) if isinstance(record, dict) else []
                pairs = set()
                candidates = set()
                for item in resolved:
                    candidate_id = item.get("v4_3CanonicalCandidateID")
                    candidate = self.candidates.get(candidate_id)
                    pair = (item.get("referenceSHA256"), tuple(item.get("referenceDimensions", [])))
                    pairs.add(pair)
                    candidates.add(candidate_id)
                    self.expect(candidate is not None and pair == (candidate.get("referenceSHA256"), tuple(candidate.get("referenceDimensions", []))) and item.get("v4_3CanonicalWrapperID") == candidate.get("requiredCanonicalWrapperID"), "conflict-resolution-binding-drift", str(record.get("entryID")), "resolved binding differs from canonical catalog")
                self.expect(len(pairs) >= 2 and len(candidates) == len(pairs), "candidate-reference-conflict", str(record.get("entryID")), "incompatible references were not split into distinct candidates")

    def validate_gate_catalog(self) -> None:
        document = self.documents.get("gateCatalog")
        path = self.active_paths.get("gateCatalog", self.authority_root)
        if not isinstance(document, dict):
            return
        gates = document.get("gates", [])
        self.expect(document.get("schemaVersion") == AUTHORITY_VERSION and document.get("catalogID") == "runescribe.theme-fidelity.v4.3.gates", "gate-catalog-identity-drift", path, "gate catalog identity changed")
        self.expect(isinstance(gates, list) and document.get("gateCount") == len(gates) == 40, "gate-count-drift", path, "gate catalog must contain 40 gates")
        if not isinstance(gates, list):
            return
        ids = []
        orders = []
        for index, gate in enumerate(gates):
            label = "gates[{}]".format(index)
            if not self.exact_keys(gate, {"id", "order", "title", "blocking", "passCriteria", "failureAction"}, "invalid-gate-record", label):
                continue
            ids.append(gate.get("id"))
            orders.append(gate.get("order"))
            self.expect(gate.get("blocking") is True, "nonblocking-gate-drift", label, "every v4.3 gate must be blocking")
            self.expect(all(isinstance(gate.get(key), str) and gate.get(key).strip() for key in ("title", "passCriteria", "failureAction")), "invalid-gate-record", label, "gate text fields must be non-empty")
        self.expect(tuple(ids) == EXPECTED_GATE_IDS and orders == list(range(1, 41)), "gate-cardinality-drift", path, "gate IDs or execution order changed")

    def run(self) -> Dict[str, Any]:
        if self.load_manifest():
            self.validate_manifest()
            self.validate_package_integrity()
            self.load_documents()
            self.validate_asset_manifest()
            self.validate_seed_catalog()
            self.validate_probe_catalog()
            self.validate_responsive_candidates()
            self.validate_canonical_catalog()
            self.validate_authority()
            self.validate_responsive_matrix()
            self.validate_mapping_index()
            self.validate_coverage_and_resolution()
            self.validate_gate_catalog()
        findings = sorted(set(self.findings))
        return {
            "schemaVersion": SCHEMA_VERSION,
            "authorityVersion": AUTHORITY_VERSION,
            "authorityStatus": self.manifest.get("status"),
            "result": "PASS" if not findings else "FAIL",
            "manifest": self.display_path(self.manifest_path),
            "manifestSHA256": self.manifest_sha256,
            "responsiveEntryCount": len(self.entries),
            "mappingCount": len(self.mappings),
            "canonicalCandidateCount": len(self.candidates),
            "responsiveCandidateCount": len(self.responsive_candidates),
            "runtimeProbeCount": len(self.probes),
            "runtimeProbeInstanceCount": self.counts.get("runtimeProbeInstances", 0),
            "seedCount": len(self.seeds),
            "gateCount": len(self.documents.get("gateCatalog", {}).get("gates", [])) if isinstance(self.documents.get("gateCatalog"), dict) else 0,
            "findings": [asdict(finding) for finding in findings],
        }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--manifest", type=Path, default=DEFAULT_IMPORT_MANIFEST)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args(argv)
    root = arguments.root.resolve()
    manifest = arguments.manifest
    if not manifest.is_absolute():
        manifest = root / manifest
    result = AuthorityV13Checker(root, manifest).run()
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if arguments.output is not None:
        output = arguments.output if arguments.output.is_absolute() else root / arguments.output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
