#!/usr/bin/env python3
"""Isolated negative-mutation coverage for the Elven Phase C validator."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from fontTools.ttLib import TTFont


ASSET_MANIFEST = "Rune-Scribe-Elven-Series-Asset-Manifest-v1.0.json"
PACKAGE_MANIFEST = "PACKAGE-MANIFEST.json"


def load(root: Path, relative: str) -> Dict[str, Any]:
    return json.loads((root / relative).read_text(encoding="utf-8"))


def dump(root: Path, relative: str, value: Any) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def manifest(root: Path) -> Dict[str, Any]:
    return load(root, ASSET_MANIFEST)


def resources(value: Dict[str, Any], asset_class: str) -> List[Dict[str, Any]]:
    return [item for item in value.get("resourceCatalog", []) if item.get("assetClass") == asset_class]


def output_with_role(value: Dict[str, Any], role: str) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    for resource in value.get("resourceCatalog", []):
        for output in resource.get("outputVariants", []):
            if output.get("outputRole") == role:
                return resource, output
    raise ValueError(f"missing output role {role}")


def font_path(root: Path, value: Dict[str, Any]) -> Path:
    _, output = output_with_role(value, "script.font")
    return root / output["filename"]


def mutate_missing_relic(root: Path) -> None:
    value = manifest(root)
    victim = resources(value, "relic")[0]
    value["resourceCatalog"].remove(victim)
    dump(root, ASSET_MANIFEST, value)


def mutate_missing_relic_role(root: Path) -> None:
    value = manifest(root)
    resource = resources(value, "relic")[0]
    resource["outputVariants"] = [item for item in resource["outputVariants"] if item["outputRole"] != "relic.high-contrast"]
    dump(root, ASSET_MANIFEST, value)


def mutate_relic_geometry(root: Path) -> None:
    value = manifest(root)
    value["codices"][0]["relics"][0]["sourceMasterDimensions"] = [1599, 1200]
    dump(root, ASSET_MANIFEST, value)


def mutate_relic_protected_region(root: Path) -> None:
    value = manifest(root)
    value["layoutProfiles"][0]["glyphSafeRegion"] = [0.9, 0.9, 0.2, 0.2]
    dump(root, ASSET_MANIFEST, value)


def mutate_relic_crop(root: Path) -> None:
    value = manifest(root)
    crop = value["codices"][0]["relics"][0]["squareDerivatives"][0]
    crop["allowStretch"] = True
    dump(root, ASSET_MANIFEST, value)


def mutate_relic_layout_fixture(root: Path) -> None:
    value = load(root, "Validation/layout-fixtures.json")
    value["records"].pop(0)
    dump(root, "Validation/layout-fixtures.json", value)


def mutate_relic_anchor(root: Path) -> None:
    value = load(root, "Validation/geometry/anchor-safety.json")
    value["records"][0]["anchors"][0]["intersectsExpandedSafeRegion"] = True
    dump(root, "Validation/geometry/anchor-safety.json", value)


def mutate_missing_seal(root: Path) -> None:
    value = manifest(root)
    value["resourceCatalog"].remove(resources(value, "seal")[0])
    dump(root, ASSET_MANIFEST, value)


def mutate_missing_seal_fallback(root: Path) -> None:
    value = manifest(root)
    resource = resources(value, "seal")[0]
    resource["outputVariants"] = [item for item in resource["outputVariants"] if item["outputRole"] != "seal.monochrome-fallback"]
    dump(root, ASSET_MANIFEST, value)


def mutate_inferred_seal_role(root: Path) -> None:
    value = manifest(root)
    output_with_role(value, "seal.thumbnail")[1].pop("outputRole")
    dump(root, ASSET_MANIFEST, value)


def mutate_crest_anchor(root: Path) -> None:
    value = manifest(root)
    value["codices"][0]["crest"]["placeableOnSealAnchor"] = True
    resources(value, "crest")[0]["placeableOnSealAnchor"] = True
    dump(root, ASSET_MANIFEST, value)


def mutate_seal_hash(root: Path) -> None:
    value = manifest(root)
    output_with_role(value, "seal.thumbnail")[1]["sha256"] = "0" * 64
    dump(root, ASSET_MANIFEST, value)


def first_seal_source(root: Path) -> Path:
    value = manifest(root)
    return root / value["codices"][0]["seals"][0]["sourceMaster"]


def insert_svg(root: Path, fragment: str) -> None:
    path = first_seal_source(root)
    text = path.read_text(encoding="utf-8")
    path.write_text(text.replace("</svg>", fragment + "</svg>"), encoding="utf-8")


def mutate_svg_script(root: Path) -> None:
    insert_svg(root, "<script>1</script>")


def mutate_svg_external(root: Path) -> None:
    reference = "ht" + "tps://invalid.example/item.png"
    insert_svg(root, f'<image href="{reference}" width="1" height="1"/>')


def mutate_svg_duplicate_id(root: Path) -> None:
    path = first_seal_source(root)
    text = path.read_text(encoding="utf-8")
    import re
    match = re.search(r"\bid=([\"'])([^\"']+)\1", text)
    duplicate = match.group(2) if match else "duplicate"
    fragment = f'<g id="{duplicate}"/><g id="{duplicate}"/>' if match is None else f'<g id="{duplicate}"/>'
    path.write_text(text.replace("</svg>", fragment + "</svg>"), encoding="utf-8")


def mutate_svg_topology(root: Path) -> None:
    first_seal_source(root).write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"/>\n', encoding="utf-8")


def mutate_monochrome(root: Path) -> None:
    value = manifest(root)
    _, output = output_with_role(value, "seal.monochrome-fallback")
    path = root / output["filename"]
    payload = path.read_bytes()
    path.write_bytes(payload.replace(b"%%EOF", b"1 0 0 rg\n%%EOF"))


def mutate_seal_recognition(root: Path) -> None:
    relative = "Validation/seals/seal-recognition.json"
    value = load(root, relative)
    value["records"].pop(0)
    dump(root, relative, value)


def mutate_seal_anchors(root: Path) -> None:
    value = manifest(root)
    resources(value, "seal")[0]["compatibleAnchorCategories"] = []
    dump(root, ASSET_MANIFEST, value)


def mutate_missing_glyph(root: Path) -> None:
    value = manifest(root)
    relative = value["codices"][0]["script"]["glyphMasterManifest"]
    glyphs = load(root, relative)
    glyphs["glyphs"].pop()
    dump(root, relative, glyphs)


def mutate_cmap_alias(root: Path) -> None:
    value = manifest(root)
    path = font_path(root, value)
    font = TTFont(path)
    try:
        for table in font["cmap"].tables:
            if table.isUnicode() and 0x16A0 in table.cmap:
                table.cmap[0x16A1] = table.cmap[0x16A0]
        font.save(path)
    finally:
        font.close()


def mutate_postscript_name(root: Path) -> None:
    value = manifest(root)
    path = font_path(root, value)
    font = TTFont(path)
    try:
        font["name"].setName("WrongScript-Regular", 6, 3, 1, 0x409)
        font.save(path)
    finally:
        font.close()


def mutate_missing_font_fallback(root: Path) -> None:
    value = manifest(root)
    resource = resources(value, "script")[0]
    resource["outputVariants"] = [item for item in resource["outputVariants"] if item["outputRole"] != "script.static-fallback"]
    dump(root, ASSET_MANIFEST, value)


def registration_path(root: Path) -> str:
    return "Validation/fonts/font-registration.json" if (root / "Validation/fonts/font-registration.json").is_file() else "Validation/font-registration.json"


def mutate_registration(root: Path) -> None:
    relative = registration_path(root)
    value = load(root, relative)
    value["status"] = "PASS"
    value["platforms"][0]["status"] = "PASS"
    value["platforms"][0]["fonts"][0]["registered"] = False
    dump(root, relative, value)


def mutate_missing_specimen(root: Path) -> None:
    relative = "Validation/fonts/font-evidence.json"
    value = load(root, relative)
    value["records"][0]["specimens"].pop()
    dump(root, relative, value)


def mutate_duplicate_outline(root: Path) -> None:
    value = manifest(root)
    path = font_path(root, value)
    font = TTFont(path)
    try:
        cmap = font.getBestCmap()
        first, second = cmap[0x16A0], cmap[0x16A1]
        font["glyf"][second] = copy.deepcopy(font["glyf"][first])
        font.save(path)
    finally:
        font.close()


def mutate_font_metrics(root: Path) -> None:
    value = manifest(root)
    path = font_path(root, value)
    font = TTFont(path)
    try:
        font["hhea"].ascent += 1
        font.save(path)
    finally:
        font.close()


def mutate_font_table(root: Path) -> None:
    value = manifest(root)
    path = font_path(root, value)
    font = TTFont(path)
    try:
        del font["post"]
        font.save(path)
    finally:
        font.close()


def mutate_font_fallback_evidence(root: Path) -> None:
    relative = "Validation/fonts/font-evidence.json"
    value = load(root, relative)
    value["records"][0].pop("fallbackEvidence")
    dump(root, relative, value)


def mutate_share_role(root: Path) -> None:
    value = manifest(root)
    resource = resources(value, "relic")[0]
    resource["outputVariants"] = [item for item in resource["outputVariants"] if item["outputRole"] != "relic.static-share-fallback"]
    dump(root, ASSET_MANIFEST, value)


def mutate_accessibility(root: Path) -> None:
    value = manifest(root)
    value["resourceCatalog"][0]["outputVariants"][0]["accessibility"]["noColorOnlyState"] = False
    dump(root, ASSET_MANIFEST, value)


def mutate_unresolved_fallback(root: Path) -> None:
    value = manifest(root)
    value["resourceCatalog"][0]["outputVariants"][0]["fallbackResourceID"] = "resource.missing.output"
    dump(root, ASSET_MANIFEST, value)


def mutate_fallback_cycle(root: Path) -> None:
    value = manifest(root)
    outputs = value["resourceCatalog"][0]["outputVariants"][:2]
    outputs[0]["fallbackResourceID"] = outputs[1]["resourceID"]
    outputs[1]["fallbackResourceID"] = outputs[0]["resourceID"]
    dump(root, ASSET_MANIFEST, value)


def mutate_reserved_share(root: Path) -> None:
    value = manifest(root)
    resources(value, "relic")[0]["shareContract"].pop("reservedRegionsNormalized")
    dump(root, ASSET_MANIFEST, value)


def mutate_motion_role(root: Path) -> None:
    value = manifest(root)
    output_with_role(value, "background.static-base")[1]["outputRole"] = "background.motion"
    dump(root, ASSET_MANIFEST, value)


def provenance_path(value: Dict[str, Any]) -> str:
    return value["provenanceLedgerPath"]


def mutate_provenance_output(root: Path) -> None:
    value = manifest(root)
    relative = provenance_path(value)
    ledger = load(root, relative)
    record = next(item for item in ledger["records"] if item.get("outputFiles"))
    record["outputFiles"].pop()
    dump(root, relative, ledger)


def mutate_provenance_field(root: Path) -> None:
    value = manifest(root)
    relative = provenance_path(value)
    ledger = load(root, relative)
    ledger["records"][0].pop("rightsHolder")
    dump(root, relative, ledger)


def mutate_recipe_missing(root: Path) -> None:
    relative = "Validation/recipes/recipe-catalog.json"
    value = load(root, relative)
    value["records"].pop()
    value["recordCount"] -= 1
    dump(root, relative, value)


def mutate_recipe_nondeterministic(root: Path) -> None:
    catalog = load(root, "Validation/recipes/recipe-catalog.json")
    relative = catalog["records"][0]["sourcePath"]
    value = load(root, relative)
    value["deterministic"] = False
    dump(root, relative, value)


def mutate_regeneration(root: Path) -> None:
    relative = "Validation/deterministic-regeneration.json"
    value = load(root, relative)
    value["status"] = "FAIL"
    dump(root, relative, value)


def mutate_budget(root: Path) -> None:
    value = manifest(root)
    output = value["resourceCatalog"][0]["outputVariants"][0]
    output["maximumBytes"] = 1
    output["byteLimit"] = 1
    dump(root, ASSET_MANIFEST, value)


def mutate_module_budget(root: Path) -> None:
    value = manifest(root)
    _, output = output_with_role(value, "background.static-base")
    path = root / output["filename"]
    with path.open("r+b") as handle:
        handle.truncate(34 * 1024 * 1024)


def mutate_hash(root: Path) -> None:
    value = manifest(root)
    value["resourceCatalog"][0]["outputVariants"][0]["sha256"] = "0" * 64
    dump(root, ASSET_MANIFEST, value)


def mutate_length(root: Path) -> None:
    value = manifest(root)
    value["resourceCatalog"][0]["outputVariants"][0]["byteLength"] += 1
    dump(root, ASSET_MANIFEST, value)


def mutate_missing_output(root: Path) -> None:
    value = manifest(root)
    path = root / value["resourceCatalog"][0]["outputVariants"][0]["filename"]
    path.unlink()


def mutate_package_manifest(root: Path) -> None:
    value = load(root, PACKAGE_MANIFEST)
    value["files"].pop()
    value["fileCountExcludingManifest"] -= 1
    dump(root, PACKAGE_MANIFEST, value)


def mutate_traversal(root: Path) -> None:
    value = manifest(root)
    value["resourceCatalog"][0]["outputVariants"][0]["filename"] = "Shipping/../escape.png"
    dump(root, ASSET_MANIFEST, value)


def mutate_duplicate_json(root: Path) -> None:
    path = root / ASSET_MANIFEST
    text = path.read_text(encoding="utf-8")
    path.write_text(text.replace("{", '{"schemaVersion":"duplicate",', 1), encoding="utf-8")


def mutate_invalid_json(root: Path) -> None:
    (root / "Validation/phase-c-output-matrix.json").write_text("{ invalid\n", encoding="utf-8")


def mutate_symlink(root: Path) -> None:
    os.symlink("../PACKAGE-MANIFEST.json", root / "Validation/forbidden-link")


def mutate_archive(root: Path) -> None:
    Path(str(root) + ".zip").write_bytes(b"not a zip")


def mutate_publication(root: Path) -> None:
    term = "Open" + "A" + "I"
    (root / "Validation/publication-mutation.txt").write_text("created by " + term + "\n", encoding="utf-8")


def mutate_shipping_format(root: Path) -> None:
    (root / "Shipping/forbidden.html").write_text("<html></html>\n", encoding="utf-8")


@dataclass(frozen=True)
class Mutation:
    name: str
    scope: str
    codes: Tuple[str, ...]
    apply: Callable[[Path], None]


MUTATIONS = (
    Mutation("relic-missing", "relics", ("PHC-REL-002", "PHC-REL-005"), mutate_missing_relic),
    Mutation("relic-role-missing", "relics", ("PHC-REL-007",), mutate_missing_relic_role),
    Mutation("relic-geometry", "relics", ("PHC-REL-014",), mutate_relic_geometry),
    Mutation("relic-protected-region", "relics", ("PHC-REL-033",), mutate_relic_protected_region),
    Mutation("relic-crop-stretch", "relics", ("PHC-REL-029",), mutate_relic_crop),
    Mutation("relic-layout-missing", "relics", ("PHC-REL-019",), mutate_relic_layout_fixture),
    Mutation("relic-anchor-unsafe", "relics", ("PHC-REL-025",), mutate_relic_anchor),
    Mutation("seal-missing", "seals", ("PHC-SEA-002", "PHC-SEA-005"), mutate_missing_seal),
    Mutation("seal-fallback-missing", "seals", ("PHC-SEA-007",), mutate_missing_seal_fallback),
    Mutation("seal-role-undeclared", "seals", ("PHC-SEA-007",), mutate_inferred_seal_role),
    Mutation("crest-anchor-enabled", "seals", ("PHC-SEA-036", "PHC-SEA-037"), mutate_crest_anchor),
    Mutation("seal-hash", "seals", ("PHC-SEA-040",), mutate_seal_hash),
    Mutation("svg-script", "seals", ("PHC-SEA-016",), mutate_svg_script),
    Mutation("svg-external-reference", "seals", ("PHC-SEA-018",), mutate_svg_external),
    Mutation("svg-duplicate-id", "seals", ("PHC-SEA-019",), mutate_svg_duplicate_id),
    Mutation("svg-no-topology", "seals", ("PHC-SEA-020",), mutate_svg_topology),
    Mutation("seal-not-monochrome", "seals", ("PHC-SEA-025",), mutate_monochrome),
    Mutation("seal-recognition-missing", "seals", ("PHC-SEA-004", "PHC-SEA-032"), mutate_seal_recognition),
    Mutation("seal-anchor-mismatch", "seals", ("PHC-SEA-029",), mutate_seal_anchors),
    Mutation("font-glyph-missing", "fonts", ("PHC-FNT-006", "PHC-FNT-007"), mutate_missing_glyph),
    Mutation("font-cmap-alias", "fonts", ("PHC-FNT-033",), mutate_cmap_alias),
    Mutation("font-postscript-name", "fonts", ("PHC-FNT-035",), mutate_postscript_name),
    Mutation("font-fallback-missing", "fonts", ("PHC-FNT-014",), mutate_missing_font_fallback),
    Mutation("font-registration-invalid", "fonts", ("PHC-FNT-050",), mutate_registration),
    Mutation("font-specimen-missing", "fonts", ("PHC-FNT-027",), mutate_missing_specimen),
    Mutation("font-outline-duplicate", "fonts", ("PHC-FNT-042",), mutate_duplicate_outline),
    Mutation("font-metrics", "fonts", ("PHC-FNT-039",), mutate_font_metrics),
    Mutation("font-table", "fonts", ("PHC-FNT-044",), mutate_font_table),
    Mutation("font-fallback-evidence", "fonts", ("PHC-FNT-024",), mutate_font_fallback_evidence),
    Mutation("share-role-missing", "share-accessibility-fallbacks", ("PHC-SHR-008",), mutate_share_role),
    Mutation("accessibility-color-only", "share-accessibility-fallbacks", ("PHC-SHR-006",), mutate_accessibility),
    Mutation("fallback-unresolved", "share-accessibility-fallbacks", ("PHC-SHR-012",), mutate_unresolved_fallback),
    Mutation("fallback-cycle", "share-accessibility-fallbacks", ("PHC-SHR-015",), mutate_fallback_cycle),
    Mutation("share-reserved-missing", "share-accessibility-fallbacks", ("PHC-SHR-022",), mutate_reserved_share),
    Mutation("motion-role-invented", "share-accessibility-fallbacks", ("PHC-SHR-009",), mutate_motion_role),
    Mutation("provenance-output-missing", "provenance-recipes", ("PHC-PRO-016",), mutate_provenance_output),
    Mutation("provenance-field-missing", "provenance-recipes", ("PHC-PRO-006",), mutate_provenance_field),
    Mutation("recipe-missing", "provenance-recipes", ("PHC-REC-004",), mutate_recipe_missing),
    Mutation("recipe-nondeterministic", "provenance-recipes", ("PHC-REC-007",), mutate_recipe_nondeterministic),
    Mutation("regeneration-failed", "provenance-recipes", ("PHC-DET-003",), mutate_regeneration),
    Mutation("resource-budget", "budgets-integrity", ("PHC-BUD-003",), mutate_budget),
    Mutation("catalog-budget", "budgets-integrity", ("PHC-BUD-005",), mutate_module_budget),
    Mutation("output-hash", "budgets-integrity", ("PHC-INT-004",), mutate_hash),
    Mutation("output-length", "budgets-integrity", ("PHC-INT-003",), mutate_length),
    Mutation("output-file-missing", "budgets-integrity", ("PHC-INT-002",), mutate_missing_output),
    Mutation("package-manifest-coverage", "budgets-integrity", ("PHC-INT-015",), mutate_package_manifest),
    Mutation("path-traversal", "output-matrix", ("PHC-PATH-001",), mutate_traversal),
    Mutation("json-duplicate-key", "budgets-integrity", ("PHC-JSON-002",), mutate_duplicate_json),
    Mutation("json-corrupt", "budgets-integrity", ("PHC-JSON-001",), mutate_invalid_json),
    Mutation("symlink", "budgets-integrity", ("PHC-PATH-002",), mutate_symlink),
    Mutation("archive-corrupt", "budgets-integrity", ("PHC-ZIP-002", "PHC-ZIP-009"), mutate_archive),
    Mutation("publication-attribution", "publication", ("PHC-PUB-002",), mutate_publication),
    Mutation("shipping-format", "publication", ("PHC-PUB-005",), mutate_shipping_format),
)


def tree_fingerprint(root: Path, archive: Path) -> str:
    value = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        value.update(relative.encode("utf-8") + b"\0")
        if path.is_symlink():
            value.update(b"link\0" + os.readlink(path).encode("utf-8"))
        elif path.is_file():
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    value.update(chunk)
    if archive.is_file():
        value.update(b"archive\0")
        with archive.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                value.update(chunk)
    return value.hexdigest()


def run_validator(validator: Path, root: Path, repo: Path, report: Path, scope: str) -> Tuple[int, Dict[str, Any]]:
    result = subprocess.run(
        [sys.executable, str(validator), "--package-root", str(root), "--repo-root", str(repo), "--output", str(report), "--scope", scope],
        check=False,
        capture_output=True,
        text=True,
        timeout=180,
    )
    try:
        payload = json.loads(report.read_text(encoding="utf-8"))
    except Exception as error:
        payload = {"status": "FAIL", "issues": [{"code": "HARNESS-REPORT-001", "message": str(error)}]}
    return result.returncode, payload


def inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run isolated negative mutations against the Elven Phase C validator.")
    parser.add_argument("--package-root", type=Path)
    parser.add_argument("--repo-root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--mutation", action="append", choices=tuple(item.name for item in MUTATIONS))
    parser.add_argument("--list-mutations", action="store_true")
    parser.add_argument("--exercise-on-failing-baseline", action="store_true", help="development-only execution; result cannot be PASS")
    arguments = parser.parse_args(argv)
    if arguments.list_mutations:
        for item in MUTATIONS:
            print(f"{item.name}\t{item.scope}\t{','.join(item.codes)}")
        raise SystemExit(0)
    missing = [name for name in ("package_root", "repo_root", "output") if getattr(arguments, name) is None]
    if missing:
        parser.error("required arguments missing: " + ", ".join("--" + item.replace("_", "-") for item in missing))
    return arguments


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = parse_arguments(argv)
    package_root = arguments.package_root.resolve()
    repo_root = arguments.repo_root.resolve()
    output = arguments.output.resolve()
    if inside(output, package_root):
        raise SystemExit("refusing an output path inside the immutable input package")
    validator = repo_root / "scripts/validate-elven-phase-c-package.py"
    archive = Path(str(package_root) + ".zip")
    before = tree_fingerprint(package_root, archive)
    selected_names = set(arguments.mutation or [item.name for item in MUTATIONS])
    selected = [item for item in MUTATIONS if item.name in selected_names]
    results: List[Dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="elven-phase-c-validator-") as temporary:
        temporary_root = Path(temporary)
        baseline_report = temporary_root / "baseline.json"
        baseline_exit, baseline = run_validator(validator, package_root, repo_root, baseline_report, "aggregate")
        baseline_passed = baseline_exit == 0 and baseline.get("status") == "PASS"
        if baseline_passed or arguments.exercise_on_failing_baseline:
            for index, mutation in enumerate(selected):
                case_root = temporary_root / f"case-{index:03d}" / package_root.name
                case_root.parent.mkdir(parents=True)
                shutil.copytree(package_root, case_root, symlinks=True)
                if archive.is_file():
                    shutil.copy2(archive, Path(str(case_root) + ".zip"))
                try:
                    mutation.apply(case_root)
                    case_report = temporary_root / f"report-{index:03d}.json"
                    exit_code, payload = run_validator(validator, case_root, repo_root, case_report, mutation.scope)
                    observed = sorted({item.get("code") for item in payload.get("issues", []) if isinstance(item, dict) and isinstance(item.get("code"), str)})
                    detected = exit_code != 0 and payload.get("status") == "FAIL" and any(code in observed for code in mutation.codes)
                    results.append({
                        "mutation": mutation.name,
                        "scope": mutation.scope,
                        "expectedAnyCode": list(mutation.codes),
                        "validatorExitCode": exit_code,
                        "validatorStatus": payload.get("status"),
                        "observedCodes": observed,
                        "status": "PASS" if detected else "FAIL",
                    })
                except Exception as error:
                    results.append({
                        "mutation": mutation.name,
                        "scope": mutation.scope,
                        "expectedAnyCode": list(mutation.codes),
                        "status": "FAIL",
                        "harnessError": f"{type(error).__name__}: {error}",
                    })
                shutil.rmtree(case_root.parent)
    after = tree_fingerprint(package_root, archive)
    input_unchanged = before == after
    all_detected = len(results) == len(selected) and all(item.get("status") == "PASS" for item in results)
    if not baseline_passed and not arguments.exercise_on_failing_baseline:
        status = "BLOCKED_BASELINE"
    elif not baseline_passed:
        status = "NON_ACCEPTANCE_EXERCISE" if all_detected and input_unchanged else "FAIL"
    else:
        status = "PASS" if all_detected and input_unchanged else "FAIL"
    report = {
        "schemaVersion": 1,
        "harness": "elven-phase-c-validator-negative-mutations",
        "packageRoot": str(package_root),
        "repositoryRoot": str(repo_root),
        "status": status,
        "baseline": {
            "exitCode": baseline_exit,
            "status": baseline.get("status"),
            "issueCodes": sorted({item.get("code") for item in baseline.get("issues", []) if isinstance(item, dict) and isinstance(item.get("code"), str)}),
        },
        "inputFingerprintBefore": before,
        "inputFingerprintAfter": after,
        "inputUnchanged": input_unchanged,
        "selectedMutationCount": len(selected),
        "passedMutationCount": sum(item.get("status") == "PASS" for item in results),
        "failedMutationCount": sum(item.get("status") == "FAIL" for item in results),
        "mutations": results,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("status", "inputUnchanged", "selectedMutationCount", "passedMutationCount", "failedMutationCount")}, indent=2))
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
