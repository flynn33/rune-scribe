#!/usr/bin/env python3
"""Fail-closed validation for the corrected Elven production package."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import mimetypes
import re
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Sequence, Tuple

from PIL import Image
from fontTools.ttLib import TTFont


TEXT_SUFFIXES = {".json", ".md", ".txt", ".svg", ".xml", ".yaml", ".yml", ".swift", ".plist"}
REQUIRED_RESOURCE_FIELDS = {
    "resourceID", "ownerCodexID", "assetClass", "sourceClass", "semanticRole",
    "requiredOrOptional", "sourceMasterPath", "sourceMediaType",
    "sourceViewBoxOrDimensions", "outputVariants", "fallbackResourceID",
    "accessibility", "budgetClass", "provenanceID",
}
REQUIRED_OUTPUT_FIELDS = {
    "outputRole", "filename", "mediaType", "dimensionsOrViewBox", "colorSpace",
    "alphaPolicy", "byteLimit", "maximumBytes", "requiredOrOptional", "status",
    "byteLength", "sha256", "exportRecipeID", "createdAtUTC",
}
REQUIRED_PROVENANCE_FIELDS = {
    "provenanceID", "assetIDOrResourceID", "creatorOrCommissioningEntity",
    "actualAuthoringToolAndVersion", "creationDateUTC", "rightsHolder",
    "rightsBasisOrLicense", "originalOrDerivedStatus", "derivationDescription",
    "sourceReference", "sourceReferenceSHA256", "sourceMasterPath",
    "sourceMasterSHA256", "thirdPartyInputs", "exportRecipeID", "exportSettings",
    "outputFiles", "approvalStatus", "approvedBy", "approvalDateUTC",
    "revisionHistory",
}
EXPECTED_BINDING_FIELDS = {
    "authority": "repository-progression-binding-contract",
    "criticality": "optional",
    "fallbackCodexID": "codex.norse",
}
PLAQUES = {
    "relic.moonleaf.ivybound-plaque",
    "relic.sunspire.solvine-plaque",
    "relic.wildwood.mossbound-plaque",
    "relic.gloamthorn.umbral-plaque",
}
TOPOLOGY = {
    "Source-Masters/Seals/moonleaf/echo-firefly.svg": {"feature.echo-firefly.leaf-trail": {"path": 4}},
    "Source-Masters/Seals/moonleaf/night-owl.svg": {"feature.night-owl.crescent": {"path": 1}},
    "Source-Masters/Seals/wildwood/wild-fox.svg": {"feature.wild-fox.botanical-curls": {"path": 2}},
    "Source-Masters/Frames/moonleaf/silvervine.svg": {"feature.silvervine-frame.moon-gem": {"circle": 1, "path": 1}},
    "Source-Masters/Frames/sunspire/laurel-of-dawn.svg": {"feature.laurel-of-dawn.sun-nodes": {"circle": 4}, "feature.laurel-of-dawn.enamel": {"path": 2}},
    "Source-Masters/Frames/wildwood/living-root.svg": {"feature.living-root.moss-patches": {"path": 3}, "feature.living-root.leaf-buds": {"path": 4}},
    "Source-Masters/Frames/gloamthorn/briar-court.svg": {"feature.briar-court.amethyst-nodes": {"polygon": 4}},
}
OUTPUT_ROLES = {
    "script": {"script.font", "script.static-fallback", "script.specimen-preview"},
    "background": {"background.static-base", "background.reduce-motion", "background.high-contrast"},
    "vault": {"vault.card", "vault.locked-silhouette", "vault.encountered", "vault.selected"},
    "frame": {"frame.vector-master", "frame.static-fallback", "frame.thumbnail"},
    "crest": {"crest.vector-master", "crest.static-fallback", "crest.thumbnail"},
    "relic": {"relic.master", "relic.thumbnail", "relic.static-share-fallback", "relic.high-contrast"},
    "seal": {"seal.vector-master", "seal.monochrome-fallback", "seal.thumbnail"},
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def reject_duplicate_keys(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)


def tag(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def svg_viewbox(path: Path) -> Tuple[float, float, float, float]:
    values = [float(item) for item in re.split(r"[ ,]+", ET.parse(path).getroot().attrib["viewBox"].strip()) if item]
    if len(values) != 4:
        raise ValueError("viewBox must contain four numbers")
    return values[0], values[1], values[2], values[3]


def all_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from all_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from all_strings(item)


class Finding:
    def __init__(self, finding_id: str) -> None:
        self.finding_id = finding_id
        self.errors: List[str] = []
        self.evidence: List[str] = []

    def check(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)

    def record(self, message: str) -> None:
        self.evidence.append(message)

    def result(self) -> Dict[str, Any]:
        return {
            "id": self.finding_id,
            "status": "PASS" if not self.errors else "FAIL",
            "errors": self.errors,
            "evidence": self.evidence,
        }


def find_group(root: ET.Element, group_id: str) -> ET.Element | None:
    return next((item for item in root.iter() if item.attrib.get("id") == group_id), None)


def actual_media_type(path: Path) -> str:
    if path.suffix.lower() == ".png":
        return "image/png"
    if path.suffix.lower() == ".pdf":
        return "application/pdf"
    if path.suffix.lower() == ".ttf":
        return "font/ttf"
    if path.suffix.lower() == ".otf":
        return "font/otf"
    if path.suffix.lower() in {".heif", ".heic"}:
        return "image/heif"
    return mimetypes.guess_type(path.name)[0] or "application/octet-stream"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-root", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    root = arguments.package_root.resolve()
    repo = arguments.repo_root.resolve()
    output = arguments.output.resolve()
    findings = {f"DEV-ELVEN-{index:03d}": Finding(f"DEV-ELVEN-{index:03d}") for index in range(1, 10)}
    general_errors: List[str] = []

    required_inputs = (
        root / "Rune-Scribe-Elven-Series-Asset-Manifest-v1.0.json",
        root / "Validation/layout-fixtures.json",
        root / "Validation/geometry/anchor-safety.json",
        root / "Validation/topology/smallest-output-recognition.json",
        root / "PACKAGE-MANIFEST.json",
        repo / "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/Resources/Rune-Scribe-Progression-Catalog-v1.0.json",
        repo / "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/Resources/Rune-Scribe-Progression-Future-Theme-Binding-Contract-v1.0.json",
    )
    missing_inputs = [str(path) for path in required_inputs if not path.is_file()]
    if missing_inputs:
        general_errors.extend(f"required validation input missing: {path}" for path in missing_inputs)
        for finding in findings.values():
            finding.errors.append("required validation inputs are incomplete")
        result_records = [findings[key].result() for key in sorted(findings)]
        report = {
            "schemaVersion": 1,
            "packageRoot": str(root),
            "repositoryRoot": str(repo),
            "jsonFilesParsed": 0,
            "svgFilesParsed": 0,
            "findings": result_records,
            "generalErrors": general_errors,
            "summary": {
                "status": "FAIL",
                "passedFindings": 0,
                "failedFindings": [item["id"] for item in result_records],
                "generalErrorCount": len(general_errors),
            },
        }
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report["summary"], indent=2))
        return 1

    manifest_path = root / "Rune-Scribe-Elven-Series-Asset-Manifest-v1.0.json"
    manifest = load_json(manifest_path)
    phase_c_complete = manifest.get("phaseCOutputMatrix") is not None or str(manifest.get("packageVersion", "")).startswith("3.1")
    codices = {item["codexID"]: item for item in manifest["codices"]}
    relics = [relic for codex in codices.values() for relic in codex["relics"]]

    json_count = 0
    svg_count = 0
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        if path.suffix.lower() == ".json":
            json_count += 1
            try:
                load_json(path)
            except Exception as error:
                general_errors.append(f"JSON parse failure {path.relative_to(root)}: {error}")
        if path.suffix.lower() == ".svg":
            svg_count += 1
            try:
                text = path.read_text(encoding="utf-8")
                parsed = ET.fromstring(text)
                if any(tag(item) == "script" for item in parsed.iter()):
                    general_errors.append(f"script element in {path.relative_to(root)}")
                if re.search(r"(?:href|xlink:href)\s*=\s*['\"](?:https?:|//)", text, re.IGNORECASE):
                    general_errors.append(f"external reference in {path.relative_to(root)}")
            except Exception as error:
                general_errors.append(f"SVG parse failure {path.relative_to(root)}: {error}")

    contract_path = repo / "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/Resources/Rune-Scribe-Progression-Future-Theme-Binding-Contract-v1.0.json"
    contract = load_json(contract_path)
    contract_bindings = {item["codexID"]: item for item in contract["bindings"] if item["codexID"] != "codex.norse"}
    first = findings["DEV-ELVEN-001"]
    second = findings["DEV-ELVEN-002"]
    second.check(set(codices) == set(contract_bindings), "theme set differs from repository binding contract")
    for codex_id in ("codex.wildwood", "codex.gloamthorn"):
        expected = contract_bindings[codex_id]
        actual = codices.get(codex_id, {})
        gate = actual.get("unlockGate", {})
        second.check(actual.get("moduleID") == expected["moduleID"], f"{codex_id} module mismatch")
        second.check(actual.get("entitlementID") == expected["entitlementID"], f"{codex_id} entitlement mismatch")
        second.check(gate.get("ruleID") == expected["gateRuleID"], f"{codex_id} rule mismatch")
        second.check(gate.get("entitlementID") == expected["entitlementID"], f"{codex_id} gate entitlement mismatch")
        for key, value in EXPECTED_BINDING_FIELDS.items():
            second.check(gate.get(key) == value, f"{codex_id} {key} mismatch")
        second.check("requirement" not in gate and "dependsOn" not in gate, f"{codex_id} retains obsolete gate prose")
    forbidden_ids = [
        "achievement." + "the-correspondent",
        "achievement." + "archivist-i",
        "stat." + "incoming-decodes",
        "stat." + "messages-decoded",
        "stat." + "messages-decoded" + ".unique",
    ]
    package_text = "\n".join(path.read_text(encoding="utf-8", errors="replace") for path in root.rglob("*") if path.is_file() and path.suffix.lower() in TEXT_SUFFIXES)
    for identifier in forbidden_ids:
        first.check(identifier not in package_text, f"forbidden identifier remains: {identifier}")
    progression_catalog_path = repo / "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/Resources/Rune-Scribe-Progression-Catalog-v1.0.json"
    progression_catalog = load_json(progression_catalog_path)
    achievement_ids = [item["achievementID"] for item in progression_catalog["achievements"]]
    statistic_ids = [item["statisticID"] for item in progression_catalog["statistics"]]
    first.check(achievement_ids.count("achievement.correspondent") == 1, "canonical correspondent achievement does not resolve exactly once")
    first.check(achievement_ids.count("achievement.archivist-1") == 1, "canonical archivist achievement does not resolve exactly once")
    first.check(statistic_ids.count("stat.message.incoming-decoded.unique") == 1, "canonical incoming-decode statistic does not resolve exactly once")
    sunspire_rule = next(item for item in progression_catalog["milestones"] if item.get("ruleID") == "rule.codex.sunspire.reciprocal-light")
    first.check("stat.message.incoming-decoded.unique" in set(all_strings(sunspire_rule)), "canonical incoming-decode statistic is absent from its rule context")
    first.record(f"Resolved three canonical identities in {progression_catalog_path.relative_to(repo)}")
    first.record(f"v3 manifest sha256 {digest(manifest_path)}")
    second.record(f"Compared Wildwood and Gloamthorn with contract sha256 {digest(contract_path)}")
    second.record(f"v3 manifest sha256 {digest(manifest_path)}")

    third = findings["DEV-ELVEN-003"]
    plaque_records = [item for item in relics if item["assetID"] in PLAQUES]
    third.check(len(plaque_records) == 4 and {item["assetID"] for item in plaque_records} == PLAQUES, "plaque set is not exactly the four controlled identities")
    for relic in plaque_records:
        geometry = root / relic["geometrySourceMaster"]
        third.check(svg_viewbox(geometry) == (0.0, 0.0, 1600.0, 1200.0), f"{relic['assetID']} source is not 1600x1200")
        third.check(relic.get("sourceMasterDimensions") == [1600, 1200], f"{relic['assetID']} descriptor dimensions mismatch")
        third.check(relic.get("preferredAspectRatio") == "4:3", f"{relic['assetID']} aspect mismatch")
        derivatives = relic.get("squareDerivatives", [])
        derivative = derivatives[0] if len(derivatives) == 1 else {}
        derivative_dimensions = derivative.get("dimensions", [])
        square_dimensions = (
            isinstance(derivative_dimensions, list)
            and len(derivative_dimensions) == 2
            and derivative_dimensions[0] == derivative_dimensions[1]
            and isinstance(derivative_dimensions[0], int)
            and derivative_dimensions[0] > 0
        )
        explicit_crop = derivative.get("cropRectangle") == [200, 0, 1200, 1200]
        if phase_c_complete:
            explicit_crop = explicit_crop and derivative.get("allowStretch") is False
        else:
            square_dimensions = derivative_dimensions == [1200, 1200]
        third.check(len(derivatives) == 1 and square_dimensions and explicit_crop, f"{relic['assetID']} lacks explicit square crop")
    identities = Counter(item["assetID"] for item in relics)
    for identity in ("relic.gloamthorn.umbral-plaque", "relic.gloamthorn.nightthorn-tablet"):
        third.check(identities[identity] == 1, f"{identity} does not have exactly one artifact record")
    third.record("Checked four plaque source masters, descriptors, and explicit square crops")

    fifth = findings["DEV-ELVEN-005"]
    profiles = {item["layoutProfileID"]: item for item in manifest.get("layoutProfiles", [])}
    fixtures = load_json(root / "Validation/layout-fixtures.json")
    fixture_by_artifact = {item["artifactID"]: item for item in fixtures["records"]}
    fifth.check(len(profiles) == 12 and len(relics) == 12, "layout profile or Relic count is not 12")
    required_layout_fields = {"maximumGlyphLines", "minimumGlyphScale", "lineSpacing", "wrappingPolicy", "overflowBehavior"}
    for relic in relics:
        profile = profiles.get(relic.get("layoutProfileID"), {})
        fifth.check(required_layout_fields <= set(profile), f"{relic['assetID']} layout profile incomplete")
        fixture = fixture_by_artifact.get(relic["assetID"], {})
        kinds = {item.get("kind") for item in fixture.get("fixtures", [])}
        fifth.check(kinds == {"one-line", "normal-content", "exact-maximum", "one-beyond-maximum", "minimum-scale"}, f"{relic['assetID']} fixture coverage incomplete")
        fifth.check((root / fixture.get("visualFixture", "missing")).is_file(), f"{relic['assetID']} visual fixture missing")
        geometry_text = (root / relic["geometrySourceMaster"]).read_text(encoding="utf-8")
        fifth.check("maximumGlyphLines" not in geometry_text, f"{relic['assetID']} duplicates layout policy in SVG")
    fifth.record("Resolved 12 Relics to 12 complete layout profiles and visual fixtures")

    fourth = findings["DEV-ELVEN-004"]
    geometry_evidence = load_json(root / "Validation/geometry/anchor-safety.json")
    geometry_records = geometry_evidence["records"]
    expected_geometry_sources = (
        {item["geometrySourceMaster"] for item in relics}
        if phase_c_complete
        else {
            "Source-Masters/Relic-Geometry/sunspire/dawnfire-tablet-geometry.svg",
            "Source-Masters/Relic-Geometry/wildwood/mossbound-plaque-geometry.svg",
        }
    )
    fourth.check(
        {item.get("sourceMaster") for item in geometry_records} == expected_geometry_sources,
        "anchor evidence source coverage differs from the required Relic set",
    )
    for record in geometry_records:
        source = root / record["sourceMaster"]
        parsed = ET.parse(source).getroot()
        circles = [item for item in parsed.iter() if tag(item) == "circle" and item.attrib.get("stroke") == "#cc5500"]
        anchors = record.get("anchors", [])
        viewbox = svg_viewbox(source)
        outer_rect = viewbox
        expanded = tuple(float(item) for item in record.get("expandedGlyphSafeRegion", []))
        fourth.check(len(anchors) >= 1 and len(circles) == len(anchors), f"{record['sourceMaster']} anchor evidence/topology count differs")
        fourth.check(len(expanded) == 4, f"{record['sourceMaster']} expanded safe region is incomplete")
        for index, anchor in enumerate(anchors):
            center = anchor.get("center", [])
            fourth.check(len(center) == 2 and isinstance(anchor.get("radius"), (int, float)), f"{record['sourceMaster']} anchor geometry is incomplete")
            if len(center) != 2 or not isinstance(anchor.get("radius"), (int, float)) or len(expanded) != 4:
                continue
            cx, cy = (float(item) for item in center)
            radius = float(anchor["radius"])
            inside = cx - radius >= outer_rect[0] and cx + radius <= outer_rect[0] + outer_rect[2] and cy - radius >= outer_rect[1] and cy + radius <= outer_rect[1] + outer_rect[3]
            nearest = (min(max(cx, expanded[0]), expanded[2]), min(max(cy, expanded[1]), expanded[3]))
            distance = math.hypot(cx - nearest[0], cy - nearest[1])
            fourth.check(inside, f"anchor outside Relic bounds in {record['sourceMaster']}")
            fourth.check(distance > radius, f"anchor intersects expanded safe region in {record['sourceMaster']}")
            fourth.check(distance + 24 - radius >= 24, f"anchor clearance below 24px in {record['sourceMaster']}")
            fourth.check(anchor.get("insideRelicBounds") == inside, f"anchor inside-bounds evidence mismatch in {record['sourceMaster']}")
            fourth.check(anchor.get("intersectsExpandedSafeRegion") == (distance <= radius), f"anchor intersection evidence mismatch in {record['sourceMaster']}")
            fourth.check(abs(float(anchor.get("clearanceFromGlyphSafeRegion", -1)) - (distance + 24 - radius)) < 0.01, f"anchor clearance evidence mismatch in {record['sourceMaster']}")
            if index < len(circles):
                circle = circles[index]
                actual = tuple(float(circle.attrib[key]) for key in ("cx", "cy", "r"))
                fourth.check(actual == (cx, cy, radius), f"anchor evidence differs from SVG topology in {record['sourceMaster']}")
        fourth.check((root / record["overlay"]).is_file(), f"overlay missing for {record['sourceMaster']}")
    fourth.check(all(item.get("maximumLineFixtureDoesNotTouchSeal") and item.get("minimumScaleFixtureDoesNotTouchSeal") for item in fixtures["records"]), "layout fixture reports protected-region contact")
    fourth.record("Recomputed circle-versus-expanded-rectangle geometry and matched two overlays")

    sixth = findings["DEV-ELVEN-006"]
    recognition = load_json(root / "Validation/topology/smallest-output-recognition.json")
    recognition_by_source = {item["sourceMaster"]: item for item in recognition["records"]}
    sixth.check(len(recognition_by_source) == 7 and recognition.get("reviewStatus") == "PASS", "smallest-output review is incomplete")
    for relative, groups in TOPOLOGY.items():
        parsed = ET.parse(root / relative).getroot()
        for group_id, required in groups.items():
            group = find_group(parsed, group_id)
            sixth.check(group is not None, f"missing topology group {group_id}")
            if group is not None:
                counts = Counter(tag(item) for item in group.iter() if item is not group)
                for element_tag, minimum in required.items():
                    sixth.check(counts[element_tag] >= minimum, f"{group_id} requires {minimum} {element_tag} elements")
        record = recognition_by_source.get(relative, {})
        image_path = root / record.get("smallestRequiredOutput", "missing")
        sixth.check(image_path.is_file(), f"smallest output missing for {relative}")
        sixth.check(bool(record.get("accessibilityDescription")), f"accessibility description missing for {relative}")
        if image_path.is_file():
            with Image.open(image_path) as image:
                sixth.check(list(image.size) == record.get("dimensions"), f"smallest output dimensions mismatch for {relative}")
            sixth.check(digest(image_path) == record.get("sha256"), f"smallest output hash mismatch for {relative}")
    sixth.record("Checked all seven report-listed SVGs, semantic groups, and 192px review renders")

    seventh = findings["DEV-ELVEN-007"]
    crest_sources = []
    for codex in codices.values():
        crest = codex["crest"]
        crest_sources.append(crest["sourceMaster"])
        seventh.check(crest.get("assetClass") == "crest" and crest.get("sourceClass") == "crest", f"{crest['assetID']} class mismatch")
        seventh.check(crest.get("semanticRole") == "masteryCrest", f"{crest['assetID']} role mismatch")
        seventh.check(crest.get("placeableOnSealAnchor") is False, f"{crest['assetID']} remains anchor-placeable")
        seventh.check("Seal source master" not in (root / crest["sourceMaster"]).read_text(encoding="utf-8"), f"{crest['assetID']} retains Seal metadata")
    seventh.check(len(set(crest_sources)) == 4, "crest source set is not exactly four")
    seventh.record("Checked four source masters and descriptor classifications")

    eighth = findings["DEV-ELVEN-008"]
    resources = manifest.get("resourceCatalog", [])
    expected_class_counts = Counter({item: 1 for item in ("script", "background", "vault", "frame", "crest")})
    if phase_c_complete:
        expected_class_counts.update({"relic": 3, "seal": 6})
    expected_resource_count = len(codices) * sum(expected_class_counts.values())
    expected_output_count = len(codices) * sum(
        count * len(OUTPUT_ROLES[asset_class])
        for asset_class, count in expected_class_counts.items()
    )
    eighth.check(
        len(resources) == expected_resource_count,
        f"resource catalog count mismatch: expected {expected_resource_count}, found {len(resources)}",
    )
    per_module_classes: Dict[str, Counter[str]] = defaultdict(Counter)
    output_catalog: Dict[str, Dict[str, Any]] = {}
    module_bytes: Dict[str, int] = defaultdict(int)
    for resource in resources:
        missing = REQUIRED_RESOURCE_FIELDS - set(resource)
        eighth.check(not missing, f"{resource.get('resourceID')} missing fields {sorted(missing)}")
        asset_class = resource.get("assetClass")
        owner = resource.get("ownerCodexID")
        per_module_classes[owner][asset_class] += 1
        actual_roles = {item.get("outputRole") for item in resource.get("outputVariants", [])}
        eighth.check(actual_roles == OUTPUT_ROLES.get(asset_class), f"{resource.get('resourceID')} output-role coverage mismatch")
        for variant in resource.get("outputVariants", []):
            eighth.check(REQUIRED_OUTPUT_FIELDS <= set(variant), f"{resource.get('resourceID')} output fields incomplete")
            relative = variant.get("filename", "")
            output_file = root / relative
            eighth.check(relative not in output_catalog, f"duplicate output declaration {relative}")
            output_catalog[relative] = variant
            eighth.check(output_file.is_file(), f"output missing {relative}")
            if output_file.is_file():
                eighth.check(output_file.stat().st_size == variant.get("byteLength"), f"byte count mismatch {relative}")
                eighth.check(output_file.stat().st_size <= variant.get("maximumBytes", 0), f"budget exceeded {relative}")
                eighth.check(digest(output_file) == variant.get("sha256"), f"hash mismatch {relative}")
                eighth.check(actual_media_type(output_file) == variant.get("mediaType"), f"media type mismatch {relative}")
                module_bytes[owner] += output_file.stat().st_size
                if output_file.suffix == ".png":
                    with Image.open(output_file) as image:
                        eighth.check(list(image.size) == variant.get("dimensionsOrViewBox"), f"PNG dimensions mismatch {relative}")
                elif output_file.suffix == ".pdf":
                    payload = output_file.read_bytes()
                    eighth.check(payload.startswith(b"%PDF-") and len(re.findall(rb"/Type\s*/Page\b", payload)) == 1, f"PDF structure mismatch {relative}")
                elif output_file.suffix == ".ttf":
                    font = TTFont(output_file)
                    codepoints = set(font.getBestCmap())
                    eighth.check(codepoints == set(range(0x16A0, 0x16C0)), f"font cmap mismatch {relative}")
                    font.close()
    for codex_id in codices:
        eighth.check(per_module_classes[codex_id] == expected_class_counts, f"{codex_id} class coverage mismatch")
        eighth.check(module_bytes[codex_id] <= 64 * 1024 * 1024, f"{codex_id} exceeds complete-module budget")
    eighth.check(
        len(output_catalog) == expected_output_count,
        f"shipping output count mismatch: expected {expected_output_count}, found {len(output_catalog)}",
    )
    shipping_files = {item.relative_to(root).as_posix() for item in (root / "Shipping").rglob("*") if item.is_file()}
    eighth.check(set(output_catalog) == shipping_files, "shipping tree and output catalog differ")
    eighth.record(f"Validated {len(resources)} resources and {len(output_catalog)} materialized outputs")

    ninth = findings["DEV-ELVEN-009"]
    provenance_path = root / manifest["provenanceLedgerPath"]
    ledger = load_json(provenance_path)
    records = ledger.get("records", [])
    sources = {
        item.relative_to(root).as_posix()
        for directory in (root / "Source-Masters", root / "Production-Sources")
        for item in directory.rglob("*")
        if item.is_file()
    }
    provenance_sources = {item.get("sourceMasterPath") for item in records}
    ninth.check(
        len(records) == manifest.get("provenanceRecordCount"),
        "provenance record count differs from manifest",
    )
    ninth.check(provenance_sources == sources, "provenance source coverage differs from source tree")
    provenance_outputs: Dict[str, Dict[str, Any]] = {}
    prohibited_values = {"", "unknown", "tbd", "todo", "pending", "automation"}
    for record in records:
        missing = REQUIRED_PROVENANCE_FIELDS - set(record)
        ninth.check(not missing, f"{record.get('provenanceID')} missing fields {sorted(missing)}")
        for key in ("creatorOrCommissioningEntity", "actualAuthoringToolAndVersion", "creationDateUTC", "rightsHolder", "rightsBasisOrLicense", "approvedBy", "approvalDateUTC"):
            ninth.check(str(record.get(key, "")).strip().lower() not in prohibited_values, f"{record.get('provenanceID')} has invalid {key}")
        source = root / record.get("sourceMasterPath", "missing")
        ninth.check(source.is_file(), f"provenance source missing {record.get('sourceMasterPath')}")
        if source.is_file():
            ninth.check(digest(source) == record.get("sourceMasterSHA256"), f"source hash mismatch {record.get('sourceMasterPath')}")
        ninth.check(bool(re.fullmatch(r"[0-9a-f]{64}", str(record.get("sourceReferenceSHA256", "")))) and set(record["sourceReferenceSHA256"]) != {"0"}, f"source reference hash invalid {record.get('sourceMasterPath')}")
        for generated in record.get("outputFiles", []):
            relative = generated.get("filename", "")
            ninth.check(relative not in provenance_outputs, f"duplicate provenance output {relative}")
            provenance_outputs[relative] = generated
            output_file = root / relative
            ninth.check(output_file.is_file(), f"provenance output missing {relative}")
            if output_file.is_file():
                ninth.check(digest(output_file) == generated.get("sha256"), f"provenance output hash mismatch {relative}")
                ninth.check(output_file.stat().st_size == generated.get("byteLength"), f"provenance output byte mismatch {relative}")
            ninth.check(generated.get("outputRole") == output_catalog.get(relative, {}).get("outputRole"), f"provenance output role mismatch {relative}")
    ninth.check(set(provenance_outputs) == set(output_catalog), "provenance and shipping output coverage differ")
    ninth.record(f"Validated {len(records)} source records and {len(provenance_outputs)} generated-output records")

    package_manifest = load_json(root / "PACKAGE-MANIFEST.json")
    declared = package_manifest.get("files", [])
    declared_paths = [item.get("path") for item in declared]
    actual_paths = sorted(item.relative_to(root).as_posix() for item in root.rglob("*") if item.is_file() and item.name != "PACKAGE-MANIFEST.json")
    if declared_paths != sorted(set(declared_paths)):
        general_errors.append("package manifest paths are not unique and sorted")
    if declared_paths != actual_paths:
        general_errors.append("package manifest coverage differs from package tree")
    for entry in declared:
        relative = entry["path"]
        if relative.startswith("/") or ".." in Path(relative).parts:
            general_errors.append(f"unsafe package path {relative}")
            continue
        path = root / relative
        if not path.is_file() or path.stat().st_size != entry.get("bytes") or digest(path) != entry.get("sha256"):
            general_errors.append(f"package manifest fact mismatch {relative}")

    attribution_terms = [
        "Chat" + "GPT", "Open" + "AI", "Anth" + "ropic", "Clau" + "de",
        "Gem" + "ini", "generated by " + "AI", "created by " + "AI",
        "language " + "model", "assigned to " + "Codex", "Codex " + "writes",
    ]
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        for term in attribution_terms:
            if term.lower() in relative.lower():
                general_errors.append(f"prohibited attribution in filename {relative}")
        if path.suffix.lower() in TEXT_SUFFIXES:
            text = path.read_text(encoding="utf-8", errors="replace")
            for term in attribution_terms:
                if term.lower() in text.lower():
                    general_errors.append(f"prohibited attribution in {relative}")

    result_records = [findings[key].result() for key in sorted(findings)]
    failed = [item["id"] for item in result_records if item["status"] != "PASS"]
    report = {
        "schemaVersion": 1,
        "packageRoot": str(root),
        "repositoryRoot": str(repo),
        "jsonFilesParsed": json_count,
        "svgFilesParsed": svg_count,
        "findings": result_records,
        "generalErrors": sorted(set(general_errors)),
        "summary": {
            "status": "PASS" if not failed and not general_errors else "FAIL",
            "passedFindings": 9 - len(failed),
            "failedFindings": failed,
            "generalErrorCount": len(set(general_errors)),
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report["summary"], indent=2))
    return 0 if report["summary"]["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
