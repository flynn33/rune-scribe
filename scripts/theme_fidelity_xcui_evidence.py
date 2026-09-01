#!/usr/bin/env python3
"""Shared contract for independently captured Theme-fidelity XCUI evidence."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any, Mapping, Sequence

from PIL import Image, UnidentifiedImageError


SCHEMA_VERSION = "1.0"
CONTRACT_V42 = "v4.2"
CONTRACT_V43 = "v4.3"
SUPPORTED_CONTRACTS = frozenset({CONTRACT_V42, CONTRACT_V43})
UI_TEST_TARGET_KIND = "com.apple.product-type.bundle.ui-testing"
HOSTED_TEST_IDENTIFIER = "ThemeFidelityMatrixTests/testCaptureThemeFidelityMatrix()"
XCUI_TEST_IDENTIFIER = (
    "ThemeFidelityAuthorityUITests/testCaptureThemeFidelityAuthority()"
)
UI_TEST_TARGETS_BY_ROLE = {
    "iphone-xcui": "RuneScribIOSUITests",
    "ipad-xcui": "RuneScribIOSUITests",
    "macos-xcui": "RuneScribMacParityUITests",
}
XCUI_OPERATION = "xcui-element-screenshot"
LOCKED_QUERY_PREDICATE = (
    "identifier CONTAINS[c] 'codex.norse' AND identifier CONTAINS[c] 'locked'"
)
AUTHORITY_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/"
    "02-COMPARISON-AUTHORITY/Comparison-Authority-v1.2.json"
)
PROBE_CATALOG_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/"
    "02-COMPARISON-AUTHORITY/Runtime-Probe-Catalog-v1.2.json"
)
SEED_CATALOG_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/"
    "02-COMPARISON-AUTHORITY/Deterministic-Seed-Catalog-v1.2.json"
)
CANDIDATE_CATALOG_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4/authority/v4.2/"
    "02-COMPARISON-AUTHORITY/Candidate-Capture-Catalog-v1.2.json"
)
V43_AUTHORITY_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4-3/authority/"
    "03-COMPARISON-AUTHORITY/Comparison-Authority-v1.3.json"
)
V43_PROBE_CATALOG_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4-3/authority/"
    "03-COMPARISON-AUTHORITY/Runtime-Probe-Catalog-v1.3.json"
)
V43_SEED_CATALOG_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4-3/authority/"
    "03-COMPARISON-AUTHORITY/Deterministic-Seed-Catalog-v1.3.json"
)
V43_CANDIDATE_CATALOG_RELATIVE = Path(
    "docs/verification/theme-fidelity-v4-3/authority/"
    "03-COMPARISON-AUTHORITY/Responsive-Candidate-Catalog-v1.3.json"
)
CONTRACT_PATHS = {
    CONTRACT_V42: {
        "schemaVersion": "1.2",
        "authority": AUTHORITY_RELATIVE,
        "probes": PROBE_CATALOG_RELATIVE,
        "seeds": SEED_CATALOG_RELATIVE,
        "candidates": CANDIDATE_CATALOG_RELATIVE,
    },
    CONTRACT_V43: {
        "schemaVersion": "1.3",
        "authority": V43_AUTHORITY_RELATIVE,
        "probes": V43_PROBE_CATALOG_RELATIVE,
        "seeds": V43_SEED_CATALOG_RELATIVE,
        "candidates": V43_CANDIDATE_CATALOG_RELATIVE,
    },
}
CONTRACT_INVENTORY_COUNTS = {
    CONTRACT_V42: (380, 672, 4, 1056),
    CONTRACT_V43: (325, 341, 4, 670),
}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
CANDIDATE_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
STEM_PATTERN = (
    r"(?P<theme>norse|moonleaf|sunspire|wildwood|gloamthorn)--"
    r"(?P<surface>[a-z0-9-]+)--"
    r"(?P<destination>iphone-portrait|ipad-portrait|macos-standard|macos-resized)"
)
CANDIDATE_ATTACHMENT_NAME = re.compile(
    rf"^{STEM_PATTERN}--candidate-element--"
    r"(?P<candidate>[A-Za-z0-9][A-Za-z0-9._-]*)\.png$"
)
XCUI_SIDECAR_NAME = re.compile(rf"^{STEM_PATTERN}\.xcui\.json$")
XCUI_QUERY_ATTACHMENT_NAME = re.compile(rf"^{STEM_PATTERN}--xcui-query\.png$")
SOURCE_TEST_KEYS = {"targetName", "targetKind", "testIdentifier", "bundleRole"}
DETERMINISTIC_SEED_KEYS = {
    "id",
    "theme",
    "surface",
    "launchEnvironment",
    "operatorInputRequired",
}
SIDECAR_KEYS = {
    "schemaVersion",
    "entryID",
    "theme",
    "surface",
    "destination",
    "deterministicSeed",
    "primaryCaptureAttachmentName",
    "captureRecordAttachmentName",
    "sourceTest",
    "candidateElementCaptures",
    "structuralWitnesses",
    "xcuiProbeEvidence",
}
CANDIDATE_CAPTURE_KEYS = {
    "candidateID",
    "elementIdentifier",
    "attachmentName",
    "declaredOperation",
    "actualOperation",
    "sha256",
    "byteCount",
    "pixelWidth",
    "pixelHeight",
    "queryPredicate",
    "matchCount",
    "coordinateOrigin",
    "coordinateUnits",
    "elementFrame",
    "windowFrame",
    "label",
    "value",
    "isEnabled",
    "isHittable",
}
STRUCTURAL_WITNESS_KEYS = {
    "witnessID",
    "queryPredicate",
    "matchCount",
    "elementIdentifier",
    "coordinateOrigin",
    "coordinateUnits",
    "elementFrame",
    "windowFrame",
    "label",
    "value",
    "isEnabled",
    "isHittable",
}
PROBE_EVIDENCE_KEYS = {
    "probeID",
    "source",
    "operator",
    "expected",
    "observed",
    "queryPredicate",
    "matchCount",
    "candidateID",
    "attachmentName",
    "attachmentSHA256",
    "pixelWidth",
    "pixelHeight",
    "coordinateOrigin",
    "coordinateUnits",
    "elementFrame",
    "containerFrame",
}
RECT_KEYS = {"x", "y", "width", "height"}

DIAGNOSTIC_PLAN_INTERACTIVE = "theme-fidelity.diagnostic.plan.interactive"
DIAGNOSTIC_PLAN_STATIC = "theme-fidelity.diagnostic.plan.static"
DIAGNOSTIC_RESOURCES = "theme-fidelity.diagnostic.resources"
DIAGNOSTIC_STATE = "theme-fidelity.diagnostic.state"
DIAGNOSTIC_DYNAMIC_TYPE = "theme-fidelity.diagnostic.dynamic-type"
MISSING_RESOURCE_PREFIX = "theme-fidelity.missing-resource."
MISSING_PICKER_ARTWORK_PREFIX = "theme-fidelity.missing-picker-artwork."
NORSE_ENCOUNTERED_ARTIFACT_ID = "relic.norse.dragonwood-plaque"

MOBILE_HIT_TARGET_IDS = {
    "workspace-empty": [
        "workspace.artifact-control.relic",
        "workspace.artifact-control.seal",
        "workspace.artifact-control.frame",
    ],
    "share-builder": [
        "share-builder.reset-defaults",
        "share-builder.save-defaults",
        "share-builder.share",
    ],
}
LARGE_TEXT_CONTROL_IDS = {
    destination: [
        "workspace.result.edit",
        "workspace.result.copy",
        "message.quick-share",
        "message.customize-share",
        "workspace.result.clear",
    ] + ([] if destination.startswith("macos-") else ["message.imessage-share"])
    for destination in (
        "iphone-portrait",
        "ipad-portrait",
        "macos-standard",
        "macos-resized",
    )
}
MASTERY_TITLE_BY_CODEX = {
    "codex.norse": "title.norse.master-of-runes",
    "codex.gloamthorn": "title.master-scribe",
    "codex.moonleaf": "title.master-scribe",
    "codex.sunspire": "title.master-scribe",
    "codex.wildwood": "title.master-scribe",
}


class XCUIEvidenceError(ValueError):
    """Raised when XCUI evidence is absent, ambiguous, or not hash-bound."""


class DuplicateJSONKeyError(ValueError):
    pass


def reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    decoded: dict[str, Any] = {}
    for key, value in pairs:
        if key in decoded:
            raise DuplicateJSONKeyError(f"duplicate JSON key: {key}")
        decoded[key] = value
    return decoded


def load_json(path: Path, label: str = "JSON document") -> dict[str, Any]:
    try:
        decoded = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, DuplicateJSONKeyError) as error:
        raise XCUIEvidenceError(f"{label} is invalid: {path}: {error}") from error
    if not isinstance(decoded, dict):
        raise XCUIEvidenceError(f"{label} must be a JSON object: {path}")
    return decoded


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def entry_stem(entry: Mapping[str, Any]) -> str:
    values = (entry.get("theme"), entry.get("surface"), entry.get("destination"))
    if not all(isinstance(value, str) and value for value in values):
        raise XCUIEvidenceError("authority entry identity is invalid")
    return f"{values[0].lower()}--{values[1]}--{values[2]}"


def sidecar_name(entry: Mapping[str, Any]) -> str:
    return entry_stem(entry) + ".xcui.json"


def candidate_attachment_name(entry: Mapping[str, Any], candidate_id: str) -> str:
    if CANDIDATE_ID_PATTERN.fullmatch(candidate_id) is None:
        raise XCUIEvidenceError(f"candidate ID is not filename-safe: {candidate_id!r}")
    return f"{entry_stem(entry)}--candidate-element--{candidate_id}.png"


def query_attachment_name(entry: Mapping[str, Any]) -> str:
    return entry_stem(entry) + "--xcui-query.png"


def primary_capture_name(entry: Mapping[str, Any]) -> str:
    return entry_stem(entry) + ".png"


def capture_record_name(entry: Mapping[str, Any]) -> str:
    return entry_stem(entry) + ".capture.json"


def bundle_role_for_destination(destination: str) -> str:
    return {
        "iphone-portrait": "iphone-xcui",
        "ipad-portrait": "ipad-xcui",
        "macos-standard": "macos-xcui",
        "macos-resized": "macos-xcui",
    }.get(destination, "")


def candidate_ids_for_entry(entry: Mapping[str, Any]) -> list[str]:
    mappings = entry.get("referenceMappings")
    if not isinstance(mappings, list):
        raise XCUIEvidenceError(f"authority entry mappings are invalid: {entry.get('id')}")
    identifiers = {
        mapping["candidateElementID"]
        for mapping in mappings
        if isinstance(mapping, dict)
        and isinstance(mapping.get("candidateElementID"), str)
    }
    return sorted(identifiers)


def xcui_probe_ids_for_entry(
    entry: Mapping[str, Any], probe_catalog: Mapping[str, Mapping[str, Any]]
) -> list[str]:
    raw = entry.get("runtimeProbeIDs")
    if not isinstance(raw, list):
        raise XCUIEvidenceError(f"authority entry runtime probes are invalid: {entry.get('id')}")
    identifiers: list[str] = []
    for probe_id in raw:
        catalog = probe_catalog.get(probe_id) if isinstance(probe_id, str) else None
        if catalog is None:
            raise XCUIEvidenceError(f"authority entry uses an unknown runtime probe: {probe_id!r}")
        source = catalog.get("source")
        if isinstance(source, str) and source.startswith("xcui-"):
            identifiers.append(probe_id)
    return identifiers


def index_probes(document: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    records = document.get("probes")
    if not isinstance(records, list):
        raise XCUIEvidenceError("runtime probe catalog is invalid")
    indexed: dict[str, dict[str, Any]] = {}
    for record in records:
        if not isinstance(record, dict):
            raise XCUIEvidenceError("runtime probe catalog contains a non-object record")
        identifier = record.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in indexed:
            raise XCUIEvidenceError("runtime probe catalog IDs must be non-empty and unique")
        indexed[identifier] = record
    return indexed


def _validate_seed_shape(seed: Any, label: str) -> dict[str, Any]:
    if not isinstance(seed, dict) or set(seed) != DETERMINISTIC_SEED_KEYS:
        raise XCUIEvidenceError(f"{label} keys are invalid")
    for key in ("id", "theme", "surface"):
        if not isinstance(seed.get(key), str) or not seed[key]:
            raise XCUIEvidenceError(f"{label} {key} is invalid")
    environment = seed.get("launchEnvironment")
    if (
        not isinstance(environment, dict)
        or not environment
        or any(
            not isinstance(key, str)
            or not key
            or not isinstance(value, str)
            for key, value in environment.items()
        )
    ):
        raise XCUIEvidenceError(f"{label} launchEnvironment is invalid")
    if seed.get("operatorInputRequired") is not False:
        raise XCUIEvidenceError(f"{label} must not require operator input")
    return seed


def index_seeds(
    document: Mapping[str, Any], schema_version: str = "1.2"
) -> dict[str, dict[str, Any]]:
    records = document.get("seeds")
    if (
        document.get("schemaVersion") != schema_version
        or not isinstance(records, list)
        or len(records) != 100
        or document.get("seedCount") != len(records)
    ):
        raise XCUIEvidenceError("deterministic seed catalog is invalid")
    indexed: dict[str, dict[str, Any]] = {}
    for raw_record in records:
        record = _validate_seed_shape(raw_record, "deterministic seed catalog record")
        identifier = record["id"]
        if identifier in indexed:
            raise XCUIEvidenceError("deterministic seed catalog IDs must be unique")
        indexed[identifier] = record
    return indexed


def index_entries(document: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    records = document.get("entries")
    if not isinstance(records, list) or len(records) != 400:
        raise XCUIEvidenceError("comparison authority must contain exactly 400 entries")
    indexed: dict[str, dict[str, Any]] = {}
    for record in records:
        if not isinstance(record, dict):
            raise XCUIEvidenceError("comparison authority contains a non-object entry")
        identifier = record.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in indexed:
            raise XCUIEvidenceError("comparison authority entry IDs must be non-empty and unique")
        indexed[identifier] = record
    return indexed


def index_candidates(
    document: Mapping[str, Any], schema_version: str = "1.2"
) -> dict[str, dict[str, Any]]:
    records = document.get("candidates")
    if (
        document.get("schemaVersion") != schema_version
        or document.get("candidateCount") != 188
        or not isinstance(records, list)
        or len(records) != 188
    ):
        raise XCUIEvidenceError("candidate capture catalog is invalid")
    indexed: dict[str, dict[str, Any]] = {}
    for record in records:
        if not isinstance(record, dict):
            raise XCUIEvidenceError("candidate capture catalog contains a non-object record")
        identifier = record.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in indexed:
            raise XCUIEvidenceError("candidate capture catalog IDs must be non-empty and unique")
        indexed[identifier] = record
    return indexed


def structural_assertion_ids(entry: Mapping[str, Any]) -> set[str]:
    identifiers: set[str] = set()
    entry_ids = entry.get("entryStructuralAssertionIDs")
    if not isinstance(entry_ids, list) or any(
        not isinstance(identifier, str) or not identifier for identifier in entry_ids
    ):
        raise XCUIEvidenceError(
            f"authority entry structural assertions are invalid: {entry.get('id')}"
        )
    identifiers.update(entry_ids)
    mappings = entry.get("referenceMappings")
    if not isinstance(mappings, list):
        raise XCUIEvidenceError(f"authority entry mappings are invalid: {entry.get('id')}")
    for mapping in mappings:
        mapping_ids = mapping.get("structuralAssertionIDs") if isinstance(mapping, dict) else None
        if not isinstance(mapping_ids, list) or any(
            not isinstance(identifier, str) or not identifier for identifier in mapping_ids
        ):
            raise XCUIEvidenceError(
                f"authority mapping structural assertions are invalid: {entry.get('id')}"
            )
        identifiers.update(mapping_ids)
    return identifiers


def exact_identifier_predicate(identifier: str) -> str:
    if CANDIDATE_ID_PATTERN.fullmatch(identifier) is None:
        raise XCUIEvidenceError(f"XCUI identifier is not predicate-safe: {identifier!r}")
    return f"identifier == '{identifier}'"


def _exact_witness(identifier: str) -> dict[str, Any]:
    return {
        "witnessID": f"element:{identifier}",
        "queryPredicate": exact_identifier_predicate(identifier),
        "expectedMatchCount": 1,
        "expectedElementIdentifier": identifier,
    }


def _prefix_count_witness(
    witness_id: str, prefix: str, expected_count: int
) -> dict[str, Any]:
    return {
        "witnessID": witness_id,
        "queryPredicate": f"identifier BEGINSWITH '{prefix}'",
        "expectedMatchCount": expected_count,
        "expectedElementIdentifier": None,
    }


def expected_structural_witnesses(
    entry: Mapping[str, Any],
    candidates: Mapping[str, Mapping[str, Any]],
) -> list[dict[str, Any]]:
    """Return the exact raw UI queries required to recompute catalog assertions."""
    assertions = structural_assertion_ids(entry)
    surface = entry.get("surface")
    destination = entry.get("destination")
    codex_id = entry.get("codexID")
    if not all(
        isinstance(value, str) and value
        for value in (surface, destination, codex_id)
    ):
        raise XCUIEvidenceError(f"authority entry witness identity is invalid: {entry.get('id')}")

    by_id: dict[str, dict[str, Any]] = {}

    def add(specification: dict[str, Any]) -> None:
        witness_id = specification["witnessID"]
        existing = by_id.get(witness_id)
        if existing is not None and existing != specification:
            raise XCUIEvidenceError(
                f"conflicting structural witness specification: {witness_id}"
            )
        by_id[witness_id] = specification

    def add_exact(identifier: str) -> None:
        add(_exact_witness(identifier))

    # Every live capture is gated on this exact settled launch tuple before a
    # generic candidate such as screen.workspace can be observed.
    add_exact(DIAGNOSTIC_STATE)

    if "assert.mobile-hit-targets" in assertions:
        controls = MOBILE_HIT_TARGET_IDS.get(surface)
        if controls is None:
            raise XCUIEvidenceError(f"mobile hit-target witness route is absent: {surface}")
        for identifier in controls:
            add_exact(identifier)

    if "assert.no-placeholder-art" in assertions:
        add_exact(DIAGNOSTIC_RESOURCES)
        add({
            "witnessID": "query:missing-resource",
            "queryPredicate": f"identifier BEGINSWITH '{MISSING_RESOURCE_PREFIX}'",
            "expectedMatchCount": 0,
            "expectedElementIdentifier": None,
        })

    if "assert.no-system-symbol-artifact" in assertions:
        add_exact(DIAGNOSTIC_RESOURCES)
        add({
            "witnessID": "query:missing-picker-artwork",
            "queryPredicate": (
                f"identifier BEGINSWITH '{MISSING_PICKER_ARTWORK_PREFIX}'"
            ),
            "expectedMatchCount": 0,
            "expectedElementIdentifier": None,
        })

    if "assert.safe-region-no-overlap" in assertions:
        add_exact(DIAGNOSTIC_PLAN_INTERACTIVE)

    if "assert.interactive-static-plan-parity" in assertions:
        add_exact(DIAGNOSTIC_PLAN_INTERACTIVE)
        add_exact(DIAGNOSTIC_PLAN_STATIC)

    if "assert.state-text-shape-truthful" in assertions:
        add_exact(DIAGNOSTIC_STATE)
        if surface == "high-contrast":
            add_exact(DIAGNOSTIC_PLAN_INTERACTIVE)
        if surface == "received-cipher":
            add_exact("received.safe-preview")
        elif surface in {
            "vault-locked", "vault-encountered", "vault-owned", "vault-selected"
        }:
            add_exact(f"theme.vault.{codex_id}.provider-state")
            add_exact(f"theme.vault.{codex_id}.ownership-state")
            state = surface.removeprefix("vault-")
            if codex_id == "codex.norse" and state == "encountered":
                add_exact("theme.vault.codex.norse.selected")
                add_exact(
                    f"theme.vault-artifact.{NORSE_ENCOUNTERED_ARTIFACT_ID}"
                )
            elif codex_id != "codex.norse" or state != "locked":
                add_exact(f"theme.vault.{codex_id}.{state}")
        elif surface == "vault-progress":
            if codex_id == "codex.norse":
                add_exact("theme.vault.codex.norse.owned")
            else:
                add_exact(f"progression.journey.{codex_id}.progress")
            add_exact(f"progression.journey.{codex_id}.requirement-count")

    theme_component = codex_id.removeprefix("codex.")
    if "assert.all-three-relics-present" in assertions:
        prefix = f"theme.artifact-picker.relic.{theme_component}."
        exact = sorted(identifier for identifier in candidates if identifier.startswith(prefix))
        if len(exact) != 3:
            raise XCUIEvidenceError(
                f"candidate catalog relic set differs from exactly three: {entry.get('id')}"
            )
        for identifier in exact:
            add_exact(identifier)
        add(_prefix_count_witness("query:relic-picker-set", prefix, len(exact)))

    if "assert.all-six-seals-present" in assertions:
        prefix = f"theme.artifact-picker.seal.{theme_component}."
        exact = sorted(identifier for identifier in candidates if identifier.startswith(prefix))
        if len(exact) != 6:
            raise XCUIEvidenceError(
                f"candidate catalog seal set differs from exactly six: {entry.get('id')}"
            )
        for identifier in exact:
            add_exact(identifier)
        add(_prefix_count_witness("query:seal-picker-set", prefix, len(exact)))

    if "assert.mastery-frame-crest-title-present" in assertions:
        prefixes = (
            f"theme.mastery.frame.frame.{theme_component}.",
            f"theme.mastery.crest.crest.{theme_component}.",
        )
        for prefix in prefixes:
            exact = sorted(identifier for identifier in candidates if identifier.startswith(prefix))
            if len(exact) != 1:
                raise XCUIEvidenceError(
                    f"candidate catalog mastery component differs from exactly one: {entry.get('id')}"
                )
            add_exact(exact[0])
        add(_prefix_count_witness(
            "query:mastery-frame-set", "theme.mastery.frame.", 1
        ))
        add(_prefix_count_witness(
            "query:mastery-crest-set", "theme.mastery.crest.", 1
        ))
        title_id = MASTERY_TITLE_BY_CODEX.get(codex_id)
        if title_id is None:
            raise XCUIEvidenceError(f"mastery title witness is undeclared: {codex_id}")
        add_exact(f"theme.mastery.title.{title_id}")
        add(_prefix_count_witness(
            "query:mastery-title-set", "theme.mastery.title.", 1
        ))

    if "assert.large-text-required-controls-visible" in assertions:
        add_exact(DIAGNOSTIC_STATE)
        add_exact(DIAGNOSTIC_DYNAMIC_TYPE)
        controls = LARGE_TEXT_CONTROL_IDS.get(destination)
        if controls is None:
            raise XCUIEvidenceError(f"large-text witness destination is absent: {destination}")
        for identifier in controls:
            add_exact(identifier)

    return [by_id[identifier] for identifier in sorted(by_id)]


@dataclass(frozen=True)
class ExpectedInventory:
    sidecars: frozenset[str]
    candidate_pngs: frozenset[str]
    query_pngs: frozenset[str]

    @property
    def attachments(self) -> frozenset[str]:
        return self.sidecars | self.candidate_pngs | self.query_pngs


def contract_specification(contract_version: str) -> Mapping[str, Any]:
    specification = CONTRACT_PATHS.get(contract_version)
    if specification is None:
        raise XCUIEvidenceError(
            f"unsupported Theme-fidelity evidence contract: {contract_version!r}"
        )
    return specification


def capture_candidate_ids_for_entry(
    entry: Mapping[str, Any],
    probes: Mapping[str, Mapping[str, Any]],
    candidates: Mapping[str, Mapping[str, Any]],
    contract_version: str,
) -> list[str]:
    """Return mapped candidates plus any authority-required probe-only capture."""
    contract_specification(contract_version)
    identifiers = set(candidate_ids_for_entry(entry))
    if contract_version == CONTRACT_V43:
        probe_ids = xcui_probe_ids_for_entry(entry, probes)
        if any(probe_id.startswith("probe.motion.preview-") for probe_id in probe_ids):
            codex_id = entry.get("codexID")
            if not isinstance(codex_id, str) or not codex_id.startswith("codex."):
                raise XCUIEvidenceError(
                    f"v4.3 preview probe Codex identity is invalid: {entry.get('id')}"
                )
            prefix = (
                "theme.artifact-preview.relic."
                + codex_id.removeprefix("codex.")
                + "."
            )
            matches = sorted(
                candidate_id
                for candidate_id in candidates
                if candidate_id.startswith(prefix)
            )
            if len(matches) != 1:
                raise XCUIEvidenceError(
                    f"v4.3 preview probe candidate is not unique: {entry.get('id')}"
                )
            identifiers.add(matches[0])
    return sorted(identifiers)


def expected_inventory(
    authority: Mapping[str, Any],
    probes: Mapping[str, Mapping[str, Any]],
    destinations: set[str] | None = None,
    *,
    candidates: Mapping[str, Mapping[str, Any]] | None = None,
    contract_version: str = CONTRACT_V42,
) -> ExpectedInventory:
    contract_specification(contract_version)
    if contract_version == CONTRACT_V43 and candidates is None:
        raise XCUIEvidenceError("v4.3 XCUI inventory requires the responsive candidate catalog")
    entries = index_entries(authority)
    sidecars: set[str] = set()
    candidate_pngs: set[str] = set()
    query_pngs: set[str] = set()
    for entry in entries.values():
        destination = entry.get("destination")
        if destinations is not None and destination not in destinations:
            continue
        capture_candidates = capture_candidate_ids_for_entry(
            entry,
            probes,
            candidates or {},
            contract_version,
        )
        xcui_probes = xcui_probe_ids_for_entry(entry, probes)
        if capture_candidates or xcui_probes:
            sidecars.add(sidecar_name(entry))
        candidate_pngs.update(
            candidate_attachment_name(entry, candidate_id)
            for candidate_id in capture_candidates
        )
        if "probe.norse.vault.locked-element-count" in xcui_probes:
            query_pngs.add(query_attachment_name(entry))
    inventory = ExpectedInventory(
        frozenset(sidecars), frozenset(candidate_pngs), frozenset(query_pngs)
    )
    if destinations is None:
        actual = (
            len(inventory.sidecars),
            len(inventory.candidate_pngs),
            len(inventory.query_pngs),
            len(inventory.attachments),
        )
        expected = CONTRACT_INVENTORY_COUNTS[contract_version]
        if actual != expected:
            raise XCUIEvidenceError(
                f"{contract_version} authority-derived XCUI attachment counts differ: "
                f"actual={actual}, expected={expected}"
            )
    return inventory


def expected_inventory_for_role(
    authority: Mapping[str, Any],
    probes: Mapping[str, Mapping[str, Any]],
    role: str,
    *,
    candidates: Mapping[str, Mapping[str, Any]] | None = None,
    contract_version: str = CONTRACT_V42,
) -> ExpectedInventory:
    destinations = {
        "iphone-xcui": {"iphone-portrait"},
        "ipad-xcui": {"ipad-portrait"},
        "macos-xcui": {"macos-standard", "macos-resized"},
    }.get(role)
    if destinations is None:
        raise XCUIEvidenceError(f"unknown XCUI result-bundle role: {role}")
    return expected_inventory(
        authority,
        probes,
        destinations,
        candidates=candidates,
        contract_version=contract_version,
    )


def resolve_attachment(root: Path, name: Any, label: str) -> Path:
    if not isinstance(name, str) or Path(name).name != name or not name:
        raise XCUIEvidenceError(f"{label} filename is invalid")
    path = (root / name).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as error:
        raise XCUIEvidenceError(f"{label} escapes the capture root") from error
    if not path.is_file():
        raise XCUIEvidenceError(f"{label} is missing: {name}")
    return path


def image_dimensions(path: Path, label: str) -> tuple[int, int]:
    try:
        with Image.open(path) as image:
            image.load()
            if image.format != "PNG":
                raise XCUIEvidenceError(f"{label} is not a PNG image: {path.name}")
            return image.size
    except (OSError, UnidentifiedImageError) as error:
        raise XCUIEvidenceError(f"{label} cannot be decoded: {path.name}: {error}") from error


def _positive_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate_image_binding(
    root: Path,
    attachment_name: Any,
    declared_hash: Any,
    declared_bytes: Any,
    pixel_width: Any,
    pixel_height: Any,
    label: str,
) -> Path:
    path = resolve_attachment(root, attachment_name, label)
    if not isinstance(declared_hash, str) or SHA256_PATTERN.fullmatch(declared_hash) is None:
        raise XCUIEvidenceError(f"{label} SHA-256 is invalid")
    if sha256_file(path) != declared_hash:
        raise XCUIEvidenceError(f"{label} SHA-256 binding failed")
    if not _positive_integer(declared_bytes) or path.stat().st_size != declared_bytes:
        raise XCUIEvidenceError(f"{label} byte-count binding failed")
    if not _positive_integer(pixel_width) or not _positive_integer(pixel_height):
        raise XCUIEvidenceError(f"{label} dimensions are invalid")
    if image_dimensions(path, label) != (pixel_width, pixel_height):
        raise XCUIEvidenceError(f"{label} dimension binding failed")
    return path


def validate_rect(value: Any, label: str, nullable: bool = False) -> dict[str, float] | None:
    if value is None and nullable:
        return None
    if not isinstance(value, dict) or set(value) != RECT_KEYS:
        raise XCUIEvidenceError(f"{label} rectangle keys are invalid")
    converted: dict[str, float] = {}
    for key in ("x", "y", "width", "height"):
        raw = value.get(key)
        if isinstance(raw, bool) or not isinstance(raw, (int, float)) or not math.isfinite(raw):
            raise XCUIEvidenceError(f"{label}.{key} is invalid")
        converted[key] = float(raw)
    if converted["width"] <= 0 or converted["height"] <= 0:
        raise XCUIEvidenceError(f"{label} rectangle is empty")
    return converted


def rectangles_intersect(first: Mapping[str, float], second: Mapping[str, float]) -> bool:
    return (
        first["x"] < second["x"] + second["width"]
        and first["x"] + first["width"] > second["x"]
        and first["y"] < second["y"] + second["height"]
        and first["y"] + first["height"] > second["y"]
    )


def rectangle_contains(container: Mapping[str, float], element: Mapping[str, float]) -> bool:
    return (
        element["x"] >= container["x"]
        and element["y"] >= container["y"]
        and element["x"] + element["width"] <= container["x"] + container["width"]
        and element["y"] + element["height"] <= container["y"] + container["height"]
    )


def expected_preview_candidate(entry: Mapping[str, Any]) -> str:
    matches = [
        identifier
        for identifier in candidate_ids_for_entry(entry)
        if identifier.startswith("theme.artifact-preview.")
    ]
    if len(matches) != 1:
        raise XCUIEvidenceError(
            f"XCUI preview evidence lacks one exact artifact-preview candidate: {entry.get('id')}"
        )
    return matches[0]


def recompute_probe_observed(
    probe_id: str,
    evidence: Mapping[str, Any],
    element_frame: Mapping[str, float] | None,
    container_frame: Mapping[str, float],
) -> Any:
    match_count = evidence.get("matchCount")
    if isinstance(match_count, bool) or not isinstance(match_count, int) or match_count < 0:
        raise XCUIEvidenceError(f"XCUI probe matchCount is invalid: {probe_id}")
    if probe_id == "probe.norse.vault.locked-element-count":
        return match_count
    if probe_id.startswith("probe.motion.preview-exists."):
        return match_count == 1 and element_frame is not None
    if probe_id.startswith("probe.motion.preview-visible."):
        return (
            match_count == 1
            and element_frame is not None
            and rectangles_intersect(element_frame, container_frame)
        )
    if probe_id.startswith("probe.motion.preview-contained."):
        return (
            match_count == 1
            and element_frame is not None
            and rectangle_contains(container_frame, element_frame)
        )
    raise XCUIEvidenceError(f"unsupported XCUI runtime probe: {probe_id}")


@dataclass(frozen=True)
class ValidatedSidecar:
    path: Path
    sha256: str
    document: dict[str, Any]
    source_test: dict[str, str]
    deterministic_seed: dict[str, Any]
    candidate_captures: dict[str, dict[str, Any]]
    structural_witnesses: dict[str, dict[str, Any]]
    probe_evidence: dict[str, dict[str, Any]]


def _validate_raw_element_query(
    item: Mapping[str, Any],
    *,
    label: str,
    expected_predicate: str,
    expected_count: int,
    expected_identifier: str | None,
) -> None:
    if item.get("queryPredicate") != expected_predicate:
        raise XCUIEvidenceError(f"{label} query predicate differs")
    match_count = item.get("matchCount")
    if (
        isinstance(match_count, bool)
        or not isinstance(match_count, int)
        or match_count != expected_count
    ):
        raise XCUIEvidenceError(f"{label} exact query count differs")
    if item.get("coordinateOrigin") != "top-left" or item.get("coordinateUnits") != "points":
        raise XCUIEvidenceError(f"{label} coordinate contract differs")
    window = validate_rect(item.get("windowFrame"), f"{label}.windowFrame")
    if window is None:
        raise XCUIEvidenceError(f"{label} window frame is absent")
    element = validate_rect(
        item.get("elementFrame"), f"{label}.elementFrame", nullable=True
    )
    if expected_identifier is None:
        if (
            item.get("elementIdentifier") is not None
            or element is not None
            or item.get("label") is not None
            or item.get("value") is not None
            or item.get("isEnabled") is not None
            or item.get("isHittable") is not None
        ):
            raise XCUIEvidenceError(f"{label} aggregate query contains element values")
        return
    if expected_count != 1 or expected_identifier is None or element is None:
        raise XCUIEvidenceError(f"{label} element binding is absent")
    if item.get("elementIdentifier") != expected_identifier:
        raise XCUIEvidenceError(f"{label} exact element identifier differs")
    if not isinstance(item.get("label"), str):
        raise XCUIEvidenceError(f"{label} accessibility label is invalid")
    value = item.get("value")
    if value is not None and not isinstance(value, str):
        raise XCUIEvidenceError(f"{label} accessibility value is invalid")
    if not isinstance(item.get("isEnabled"), bool) or not isinstance(
        item.get("isHittable"), bool
    ):
        raise XCUIEvidenceError(f"{label} enabled/hittable values are invalid")


def _validate_readiness_witness(
    item: Mapping[str, Any],
    entry: Mapping[str, Any],
    deterministic_seed: Mapping[str, Any],
) -> None:
    raw = item.get("value")
    if not isinstance(raw, str) or not raw:
        raise XCUIEvidenceError("settled qualification readiness value is absent")
    try:
        document = json.loads(raw, object_pairs_hook=reject_duplicate_keys)
    except (json.JSONDecodeError, DuplicateJSONKeyError) as error:
        raise XCUIEvidenceError(
            f"settled qualification readiness value is invalid: {error}"
        ) from error
    if not isinstance(document, dict):
        raise XCUIEvidenceError("settled qualification readiness value is not an object")

    environment = deterministic_seed["launchEnvironment"]
    launch_identity = {
        "themeID": environment.get("RUNESCRIBE_QUALIFICATION_THEME_ID"),
        "codexID": environment.get("RUNESCRIBE_QUALIFICATION_CODEX_ID"),
        "surface": environment.get("RUNESCRIBE_QUALIFICATION_SURFACE"),
    }
    entry_identity = {
        "themeID": entry.get("themeID"),
        "codexID": entry.get("codexID"),
        "surface": entry.get("surface"),
    }
    if launch_identity != entry_identity:
        raise XCUIEvidenceError(
            "deterministic launch identity differs from the authority entry"
        )

    expected = {
        "schemaVersion": "1.0",
        **entry_identity,
        "destination": entry.get("destination"),
        "appearance": environment.get("RUNESCRIBE_QUALIFICATION_APPEARANCE"),
        "messageProfile": environment.get(
            "RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE"
        ),
        "vaultState": environment.get("RUNESCRIBE_QUALIFICATION_VAULT_STATE"),
        "activeThemeID": entry.get("themeID"),
        "effectiveCodexID": entry.get("codexID"),
    }
    for key, expected_value in expected.items():
        if key not in document or type(document[key]) is not type(expected_value):
            raise XCUIEvidenceError(
                f"settled qualification readiness {key} binding failed"
            )
        if document[key] != expected_value:
            raise XCUIEvidenceError(
                f"settled qualification readiness {key} binding failed"
            )


def _validate_attachment_metadata(
    name: str,
    source_test: Mapping[str, Any],
    attachment_records: Mapping[str, Mapping[str, Any]] | None,
) -> None:
    if attachment_records is None:
        return
    record = attachment_records.get(name)
    if record is None:
        raise XCUIEvidenceError(f"extraction report lacks XCUI attachment metadata: {name}")
    exact = {
        "testIdentifier": source_test["testIdentifier"],
        "resultBundleRole": source_test["bundleRole"],
        "sourceTargetName": source_test["targetName"],
        "sourceTargetKind": source_test["targetKind"],
    }
    for key, expected in exact.items():
        if record.get(key) != expected:
            raise XCUIEvidenceError(f"XCUI attachment {name} {key} binding failed")


def validate_sidecar(
    path: Path,
    entry: Mapping[str, Any],
    probes: Mapping[str, Mapping[str, Any]],
    seeds: Mapping[str, Mapping[str, Any]],
    candidates: Mapping[str, Mapping[str, Any]],
    capture_root: Path,
    attachment_records: Mapping[str, Mapping[str, Any]] | None = None,
    *,
    contract_version: str = CONTRACT_V42,
) -> ValidatedSidecar:
    document = load_json(path, "XCUI evidence sidecar")
    if set(document) != SIDECAR_KEYS:
        raise XCUIEvidenceError(f"XCUI sidecar keys are invalid: {path.name}")
    expected_identity = {
        "schemaVersion": SCHEMA_VERSION,
        "entryID": entry.get("id"),
        "theme": entry.get("theme"),
        "surface": entry.get("surface"),
        "destination": entry.get("destination"),
        "primaryCaptureAttachmentName": primary_capture_name(entry),
        "captureRecordAttachmentName": capture_record_name(entry),
    }
    for key, expected in expected_identity.items():
        if document.get(key) != expected:
            raise XCUIEvidenceError(f"XCUI sidecar {key} binding failed: {path.name}")
    if path.name != sidecar_name(entry):
        raise XCUIEvidenceError(f"XCUI sidecar filename differs from its authority entry: {path.name}")

    seed_id = entry.get("seedID")
    expected_seed = seeds.get(seed_id) if isinstance(seed_id, str) else None
    if expected_seed is None:
        raise XCUIEvidenceError(f"authority entry uses an unknown deterministic seed: {seed_id!r}")
    expected_seed = _validate_seed_shape(
        expected_seed, "deterministic seed catalog record"
    )
    if (
        expected_seed.get("theme") != entry.get("theme")
        or expected_seed.get("surface") != entry.get("surface")
    ):
        raise XCUIEvidenceError(
            f"deterministic seed catalog identity differs from authority entry: {path.name}"
        )
    deterministic_seed = _validate_seed_shape(
        document.get("deterministicSeed"), "XCUI sidecar deterministicSeed"
    )
    if deterministic_seed != expected_seed:
        raise XCUIEvidenceError(
            f"XCUI sidecar deterministic seed binding failed: {path.name}"
        )

    source_test = document.get("sourceTest")
    if not isinstance(source_test, dict) or set(source_test) != SOURCE_TEST_KEYS:
        raise XCUIEvidenceError(f"XCUI sidecar sourceTest keys are invalid: {path.name}")
    expected_role = bundle_role_for_destination(str(entry.get("destination")))
    expected_target = UI_TEST_TARGETS_BY_ROLE.get(expected_role)
    if (
        source_test.get("targetName") != expected_target
        or source_test.get("targetKind") != UI_TEST_TARGET_KIND
        or source_test.get("testIdentifier") != XCUI_TEST_IDENTIFIER
        or source_test.get("bundleRole") != expected_role
    ):
        raise XCUIEvidenceError(f"XCUI sidecar sourceTest is not an independent UI test: {path.name}")
    _validate_attachment_metadata(path.name, source_test, attachment_records)

    expected_candidates = capture_candidate_ids_for_entry(
        entry,
        probes,
        candidates,
        contract_version,
    )
    raw_candidates = document.get("candidateElementCaptures")
    if not isinstance(raw_candidates, list):
        raise XCUIEvidenceError(f"candidateElementCaptures must be an array: {path.name}")
    candidate_captures: dict[str, dict[str, Any]] = {}
    for item in raw_candidates:
        if not isinstance(item, dict) or set(item) != CANDIDATE_CAPTURE_KEYS:
            raise XCUIEvidenceError(f"candidate element capture keys are invalid: {path.name}")
        candidate_id = item.get("candidateID")
        if (
            not isinstance(candidate_id, str)
            or candidate_id not in expected_candidates
            or candidate_id in candidate_captures
        ):
            raise XCUIEvidenceError(f"candidate element ID is unexpected or duplicated: {candidate_id!r}")
        expected_name = candidate_attachment_name(entry, candidate_id)
        if item.get("attachmentName") != expected_name:
            raise XCUIEvidenceError(f"candidate attachment filename differs: {candidate_id}")
        if item.get("declaredOperation") != XCUI_OPERATION:
            raise XCUIEvidenceError(f"candidate declared operation differs: {candidate_id}")
        if item.get("actualOperation") != XCUI_OPERATION:
            raise XCUIEvidenceError(f"candidate actual operation differs: {candidate_id}")
        _validate_raw_element_query(
            item,
            label=f"candidate element {candidate_id}",
            expected_predicate=exact_identifier_predicate(candidate_id),
            expected_count=1,
            expected_identifier=candidate_id,
        )
        validate_image_binding(
            capture_root,
            item.get("attachmentName"),
            item.get("sha256"),
            item.get("byteCount"),
            item.get("pixelWidth"),
            item.get("pixelHeight"),
            f"candidate element {candidate_id}",
        )
        _validate_attachment_metadata(expected_name, source_test, attachment_records)
        if attachment_records is not None:
            metadata = attachment_records[expected_name]
            if metadata.get("sha256") != item.get("sha256") or metadata.get("bytes") != item.get("byteCount"):
                raise XCUIEvidenceError(f"candidate extraction metadata differs: {candidate_id}")
        candidate_captures[candidate_id] = item
    if list(candidate_captures) != expected_candidates:
        raise XCUIEvidenceError(f"candidate element capture set/order differs: {path.name}")

    expected_witnesses = expected_structural_witnesses(entry, candidates)
    raw_witnesses = document.get("structuralWitnesses")
    if not isinstance(raw_witnesses, list):
        raise XCUIEvidenceError(f"structuralWitnesses must be an array: {path.name}")
    structural_witnesses: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(raw_witnesses):
        if not isinstance(item, dict) or set(item) != STRUCTURAL_WITNESS_KEYS:
            raise XCUIEvidenceError(f"structural witness keys are invalid: {path.name}")
        if index >= len(expected_witnesses):
            raise XCUIEvidenceError(f"structural witness set contains extras: {path.name}")
        specification = expected_witnesses[index]
        witness_id = item.get("witnessID")
        if (
            witness_id != specification["witnessID"]
            or not isinstance(witness_id, str)
            or witness_id in structural_witnesses
        ):
            raise XCUIEvidenceError(
                f"structural witness is unexpected, reordered, or duplicated: {witness_id!r}"
            )
        _validate_raw_element_query(
            item,
            label=f"structural witness {witness_id}",
            expected_predicate=specification["queryPredicate"],
            expected_count=specification["expectedMatchCount"],
            expected_identifier=specification["expectedElementIdentifier"],
        )
        structural_witnesses[witness_id] = item
    if len(structural_witnesses) != len(expected_witnesses):
        raise XCUIEvidenceError(f"structural witness set/order differs: {path.name}")
    readiness = structural_witnesses.get(f"element:{DIAGNOSTIC_STATE}")
    if readiness is None:
        raise XCUIEvidenceError(f"settled qualification readiness is absent: {path.name}")
    _validate_readiness_witness(readiness, entry, deterministic_seed)
    if "assert.large-text-required-controls-visible" in structural_assertion_ids(entry):
        dynamic_type = structural_witnesses.get(
            f"element:{DIAGNOSTIC_DYNAMIC_TYPE}"
        )
        if dynamic_type is None:
            raise XCUIEvidenceError(
                f"large-text dynamic-type witness is absent: {path.name}"
            )
        if dynamic_type.get("value") != "accessibility5":
            raise XCUIEvidenceError(
                f"large-text dynamic-type witness is not accessibility5: {path.name}"
            )

    expected_probe_ids = xcui_probe_ids_for_entry(entry, probes)
    raw_probe_evidence = document.get("xcuiProbeEvidence")
    if not isinstance(raw_probe_evidence, list):
        raise XCUIEvidenceError(f"xcuiProbeEvidence must be an array: {path.name}")
    probe_evidence: dict[str, dict[str, Any]] = {}
    for item in raw_probe_evidence:
        if not isinstance(item, dict) or set(item) != PROBE_EVIDENCE_KEYS:
            raise XCUIEvidenceError(f"XCUI probe evidence keys are invalid: {path.name}")
        probe_id = item.get("probeID")
        if (
            not isinstance(probe_id, str)
            or probe_id not in expected_probe_ids
            or probe_id in probe_evidence
        ):
            raise XCUIEvidenceError(f"XCUI probe is unexpected or duplicated: {probe_id!r}")
        catalog = probes[probe_id]
        for key in ("source", "operator", "expected"):
            if item.get(key) != catalog.get(key):
                raise XCUIEvidenceError(f"XCUI probe {key} differs from catalog: {probe_id}")
        if item.get("coordinateOrigin") != "top-left" or item.get("coordinateUnits") != "points":
            raise XCUIEvidenceError(f"XCUI probe coordinate contract differs: {probe_id}")
        container = validate_rect(item.get("containerFrame"), f"{probe_id}.containerFrame")
        element = validate_rect(item.get("elementFrame"), f"{probe_id}.elementFrame", nullable=True)
        if container is None:
            raise XCUIEvidenceError(f"XCUI probe container frame is absent: {probe_id}")

        if probe_id == "probe.norse.vault.locked-element-count":
            expected_candidate = None
            expected_attachment = query_attachment_name(entry)
            expected_predicate = LOCKED_QUERY_PREDICATE
            if element is not None:
                raise XCUIEvidenceError("locked-element query cannot declare an element frame")
        else:
            preview_candidates = [
                candidate_id
                for candidate_id in expected_candidates
                if candidate_id.startswith("theme.artifact-preview.")
            ]
            if len(preview_candidates) != 1:
                raise XCUIEvidenceError(
                    f"XCUI preview evidence lacks one exact artifact-preview candidate: "
                    f"{entry.get('id')}"
                )
            expected_candidate = preview_candidates[0]
            expected_attachment = candidate_attachment_name(entry, expected_candidate)
            expected_predicate = f"identifier == '{expected_candidate}'"
            if element is None:
                raise XCUIEvidenceError(f"XCUI preview probe element frame is absent: {probe_id}")
        if item.get("candidateID") != expected_candidate:
            raise XCUIEvidenceError(f"XCUI probe candidate binding differs: {probe_id}")
        if item.get("queryPredicate") != expected_predicate:
            raise XCUIEvidenceError(f"XCUI probe query predicate differs: {probe_id}")
        if item.get("attachmentName") != expected_attachment:
            raise XCUIEvidenceError(f"XCUI probe attachment filename differs: {probe_id}")
        attachment_path = validate_image_binding(
            capture_root,
            item.get("attachmentName"),
            item.get("attachmentSHA256"),
            (capture_root / expected_attachment).stat().st_size
            if (capture_root / expected_attachment).is_file()
            else None,
            item.get("pixelWidth"),
            item.get("pixelHeight"),
            f"XCUI probe {probe_id}",
        )
        _validate_attachment_metadata(expected_attachment, source_test, attachment_records)
        if attachment_records is not None and attachment_records[expected_attachment].get("sha256") != item.get("attachmentSHA256"):
            raise XCUIEvidenceError(f"XCUI probe extraction hash differs: {probe_id}")
        observed = recompute_probe_observed(probe_id, item, element, container)
        if type(item.get("observed")) is not type(observed) or item.get("observed") != observed:
            raise XCUIEvidenceError(f"XCUI probe observation differs from bound UI evidence: {probe_id}")
        if probe_id == "probe.norse.vault.locked-element-count" and observed != 0:
            raise XCUIEvidenceError("Norse locked-element XCUI query count must be zero")
        if attachment_path.name != expected_attachment:
            raise XCUIEvidenceError(f"XCUI probe attachment path differs: {probe_id}")
        probe_evidence[probe_id] = item
    if list(probe_evidence) != expected_probe_ids:
        raise XCUIEvidenceError(f"XCUI probe evidence set/order differs: {path.name}")

    return ValidatedSidecar(
        path=path.resolve(),
        sha256=sha256_file(path),
        document=document,
        source_test={key: str(source_test[key]) for key in SOURCE_TEST_KEYS},
        deterministic_seed=deterministic_seed,
        candidate_captures=candidate_captures,
        structural_witnesses=structural_witnesses,
        probe_evidence=probe_evidence,
    )


def load_repository_authority(
    root: Path,
    contract_version: str = CONTRACT_V42,
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    specification = contract_specification(contract_version)
    authority = load_json(root / specification["authority"], "comparison authority")
    probe_document = load_json(root / specification["probes"], "runtime probe catalog")
    if authority.get("schemaVersion") != specification["schemaVersion"]:
        raise XCUIEvidenceError("comparison authority schema version differs from its contract")
    if probe_document.get("schemaVersion") != specification["schemaVersion"]:
        raise XCUIEvidenceError("runtime probe catalog schema version differs from its contract")
    return authority, index_probes(probe_document)


def load_repository_seeds(
    root: Path, contract_version: str = CONTRACT_V42
) -> dict[str, dict[str, Any]]:
    specification = contract_specification(contract_version)
    seed_document = load_json(root / specification["seeds"], "deterministic seed catalog")
    return index_seeds(seed_document, str(specification["schemaVersion"]))


def load_repository_candidates(
    root: Path, contract_version: str = CONTRACT_V42
) -> dict[str, dict[str, Any]]:
    specification = contract_specification(contract_version)
    candidate_document = load_json(
        root / specification["candidates"], "candidate capture catalog"
    )
    return index_candidates(candidate_document, str(specification["schemaVersion"]))
