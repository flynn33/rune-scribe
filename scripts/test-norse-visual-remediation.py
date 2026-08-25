#!/usr/bin/env python3
"""Prove the Norse remediation validator rejects all required regressions."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional, Sequence


MutationFunction = Callable[[Path], list[str]]


@dataclass(frozen=True)
class Mutation:
    mutation_id: str
    instruction: str
    expected_gate: str
    apply: MutationFunction


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if path.exists():
            os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def read_text(root: Path, relative: str) -> str:
    path = root / relative
    if not path.is_file():
        raise RuntimeError(f"mutation target is missing: {relative}")
    return path.read_text(encoding="utf-8")


def replace_once(root: Path, relative: str, old: str, new: str) -> list[str]:
    path = root / relative
    source = read_text(root, relative)
    count = source.count(old)
    if count != 1:
        raise RuntimeError(
            f"expected one mutation anchor in {relative}, found {count}: {old!r}"
        )
    atomic_write(path, source.replace(old, new, 1).encode("utf-8"))
    return [relative]


def replace_all(root: Path, relative: str, old: str, new: str) -> list[str]:
    path = root / relative
    source = read_text(root, relative)
    count = source.count(old)
    if count < 1:
        raise RuntimeError(f"mutation anchor is missing in {relative}: {old!r}")
    atomic_write(path, source.replace(old, new).encode("utf-8"))
    return [relative]


def replace_regex_once(
    root: Path,
    relative: str,
    pattern: str,
    replacement: str,
    flags: int = 0,
) -> list[str]:
    path = root / relative
    source = read_text(root, relative)
    mutated, count = re.subn(pattern, replacement, source, count=1, flags=flags)
    if count != 1:
        raise RuntimeError(
            f"expected one regular-expression anchor in {relative}, found {count}: {pattern!r}"
        )
    atomic_write(path, mutated.encode("utf-8"))
    return [relative]


SEMANTIC_PLAN = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
    "SemanticThemePresentation.swift"
)
VISUAL_COMPONENTS = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/"
    "ThemeVisualComponents.swift"
)
SHARE_RENDERER = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/"
    "ShareArtifactRenderer.swift"
)
UI_SESSION = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/"
    "RuneScribeUISession.swift"
)
ARTIFACT_SELECTION = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/"
    "RuneScribeUISession+ThemeArtifacts.swift"
)
RUNTIME_PRESENTATION = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/"
    "RuntimeApplicationResourcePresentation.swift"
)
RUNTIME_OPAQUE_REGISTRY = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/"
    "RuntimeOpaqueResourceRegistry.swift"
)
SHARE_PRESENTATION_CONTRACTS = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
    "SharePresentationContracts.swift"
)
NORSE_DESCRIPTOR = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "NorseBaseThemeDescriptor.swift"
)
NORSE_TEST = (
    "Packages/RuneScribeArchitecture/Tests/RuneScribeNorseThemeModuleTests/"
    "NorseBaseThemeModuleTests.swift"
)
NORSE_V2_GENERATOR = "scripts/generate-norse-v2-resource-catalog.py"
NORSE_V2_CATALOG = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
    "NorseApplicationResourceCatalog.swift"
)
NORSE_MASTERY_ANIMATION = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "Resources/Production/Animation/effect.norse.reveal-mastery.json"
)
FALLBACK_BINDING = (
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/"
    "ReceivedPresentationAvailabilityBinding.swift"
)


def remove_active_relic(root: Path) -> list[str]:
    return replace_once(
        root,
        SEMANTIC_PLAN,
        "relics = try descriptor.codex.relics.compactMap { relic in",
        "relics = []\n        _ = try descriptor.codex.relics.compactMap { relic in",
    )


def replace_interactive_preview(root: Path) -> list[str]:
    return replace_once(root, VISUAL_COMPONENTS, "ThemeArtifactCanvas(", "Color(")


def stop_resolving_codex_card(root: Path) -> list[str]:
    return replace_once(
        root,
        SEMANTIC_PLAN,
        "card: try image(vault.cardResourceID)",
        "card: try image(vault.lockedSilhouetteResourceID)",
    )


def remove_selected_seal_thumbnail(root: Path) -> list[str]:
    return replace_regex_once(
        root,
        SEMANTIC_PLAN,
        r"(var\s+selectedSeal\s*:\s*ThemeArtifactVisualPlan\?\s*\{).*?\n\s*\}",
        r"\1\n        nil\n    }",
        re.DOTALL,
    )


def remove_vault_images(root: Path) -> list[str]:
    return replace_all(
        root,
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VaultProgressView.swift",
        "ThemeArtifactTile(",
        "Text(",
    )


def hardcode_norse_in_generic_view(root: Path) -> list[str]:
    return replace_once(
        root,
        VISUAL_COMPONENTS,
        'identifierPrefix: String = "theme.codex-card"',
        'identifierPrefix: String = "codex.norse"',
    )


def import_norse_provider(root: Path) -> list[str]:
    path = root / VISUAL_COMPONENTS
    source = read_text(root, VISUAL_COMPONENTS)
    if "import RuneScribeNorseThemeModule" in source:
        raise RuntimeError("provider import mutation is already present")
    match = re.search(r"(?:^import .+\n)+", source, re.MULTILINE)
    if match is None:
        raise RuntimeError("Swift import block is missing")
    mutated = source[: match.end()] + "import RuneScribeNorseThemeModule\n" + source[match.end() :]
    atomic_write(path, mutated.encode("utf-8"))
    return [VISUAL_COMPONENTS]


def bypass_runtime_with_bundle(root: Path) -> list[str]:
    path = root / VISUAL_COMPONENTS
    source = read_text(root, VISUAL_COMPONENTS)
    marker = "\nprivate let bypassedThemeResourceBundle = Bundle.module\n\n"
    first_declaration = re.search(r"^(?:struct|enum|final class|class)\s+", source, re.MULTILINE)
    if first_declaration is None:
        raise RuntimeError("visual component declaration is missing")
    mutated = source[: first_declaration.start()] + marker + source[first_declaration.start() :]
    atomic_write(path, mutated.encode("utf-8"))
    return [VISUAL_COMPONENTS]


def corrupt_hash_fixture(root: Path) -> list[str]:
    accepted = "615b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b"
    corrupted = "715b6c1166a8c51816dc1536784acbf486547e3bed03dbfdd70910e10066793b"
    path = root / NORSE_TEST
    source = read_text(root, NORSE_TEST)
    if source.count(accepted) < 2:
        raise RuntimeError("frozen hash fixture anchors are missing")
    atomic_write(path, source.replace(accepted, corrupted, 1).encode("utf-8"))
    return [NORSE_TEST]


def publish_partial_state(root: Path) -> list[str]:
    path = root / UI_SESSION
    source = read_text(root, UI_SESSION)
    assignment = re.search(
        r"^\s*activeThemeVisualPresentation\s*=\s*visualPresentation\s*\n",
        source,
        re.MULTILINE,
    )
    function = re.search(
        r"private\s+func\s+resolveAndCommitTheme\s*\([^\{]+\{\n",
        source,
        re.DOTALL,
    )
    if assignment is None or function is None or assignment.start() < function.end():
        raise RuntimeError("atomic visual-state commit anchor is missing")
    line = assignment.group(0)
    without_commit = source[: assignment.start()] + source[assignment.end() :]
    insertion = function.end()
    mutated = without_commit[:insertion] + line + without_commit[insertion:]
    atomic_write(path, mutated.encode("utf-8"))
    return [UI_SESSION]


def allow_stale_adoption(root: Path) -> list[str]:
    return replace_all(
        root,
        UI_SESSION,
        "guard themeAdoptionGeneration == adoptionGeneration else",
        "guard true else",
    )


def allow_locked_selection(root: Path) -> list[str]:
    return replace_once(
        root,
        ARTIFACT_SELECTION,
        "$0.id == artifactID && $0.isSelectable",
        "$0.id == artifactID",
    )


def remove_high_contrast(root: Path) -> list[str]:
    return replace_once(
        root,
        SHARE_RENDERER,
        "case .highContrast: relic.highContrastResourceID",
        "case .highContrast: relic.staticFallbackResourceID",
    )


def remove_reduce_motion(root: Path) -> list[str]:
    return replace_once(
        root,
        SHARE_RENDERER,
        "descriptor.codex.background.reduceMotionResourceID",
        "descriptor.codex.background.staticBaseResourceID",
    )


def remove_accessibility_label(root: Path) -> list[str]:
    return replace_once(
        root,
        SHARE_RENDERER,
        ".accessibilityLabel(Text(plan.accessibilityLabel))",
        ".accessibilityValue(Text(plan.accessibilityLabel))",
    )


def exceed_decoded_cache_budget(root: Path) -> list[str]:
    return replace_regex_once(
        root,
        RUNTIME_PRESENTATION,
        r"(static\s+let\s+maximumDecodedByteCount\s*=\s*)64\s*\*\s*1_024\s*\*\s*1_024",
        r"\g<1>512 * 1_024 * 1_024",
    )


def weaken_theme_resource_per_item_budget(root: Path) -> list[str]:
    return replace_once(
        root,
        RUNTIME_OPAQUE_REGISTRY,
        "maximumImageBytes: 8 * 1_024 * 1_024,",
        "maximumImageBytes: 16 * 1_024 * 1_024,",
    )


def undersize_provider_inventory_budget(root: Path) -> list[str]:
    return replace_once(
        root,
        SHARE_PRESENTATION_CONTRACTS,
        "public static let maximumDeclaredResourceBytes: UInt64 = 112 * 1024 * 1024",
        "public static let maximumDeclaredResourceBytes: UInt64 = 64 * 1024 * 1024",
    )


def blank_on_optional_provider_failure(root: Path) -> list[str]:
    return replace_once(
        root,
        FALLBACK_BINDING,
        ": RuneScribeCodexIDs.norse,",
        ": presentation.requestedSelection.codexID,",
    )


def change_script_identity(root: Path) -> list[str]:
    return replace_once(
        root,
        NORSE_DESCRIPTOR,
        'ScriptID(rawValue: "script.base-runes")!',
        'ScriptID(rawValue: "script.changed-runes")!',
    )


def alter_v2_generator_source(root: Path) -> list[str]:
    return replace_once(
        root,
        NORSE_V2_GENERATOR,
        'spec(prefix + ".master", "relic.master",',
        'spec(prefix + ".master", "relic.changed-master",',
    )


def alter_generated_application_catalog(root: Path) -> list[str]:
    return replace_once(
        root,
        NORSE_V2_CATALOG,
        '"resource.relic.norse.runestone-tablet.master":',
        '"resource.relic.norse.runestone-tablet.changed-master":',
    )


def introduce_legacy_current_content_id(root: Path) -> list[str]:
    return replace_once(
        root,
        NORSE_MASTERY_ANIMATION,
        '"resourceRole": "crest.norse.raven-mastery"',
        '"resourceRole": "crest.norse.forge-master"',
    )


def alter_norse_asset_byte(root: Path) -> list[str]:
    manifest_relative = (
        "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
        "Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v2.0.json"
    )
    manifest_path = root / manifest_relative
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    first = manifest["resources"][0]
    target = manifest_path.parents[2] / first["path"]
    if not target.is_file() or target.is_symlink():
        raise RuntimeError(f"accepted asset does not resolve exactly: {first['path']}")
    relative = target.relative_to(root).as_posix()
    atomic_write(target, target.read_bytes() + b"\x00")
    return [relative]


def change_version_build(root: Path) -> list[str]:
    relative = "project.yml"
    path = root / relative
    source = read_text(root, relative)
    anchors = (
        ('MARKETING_VERSION: "1.0.39"', 'MARKETING_VERSION: "1.0.40"'),
        ('CURRENT_PROJECT_VERSION: "39"', 'CURRENT_PROJECT_VERSION: "40"'),
    )
    for old, new in anchors:
        if source.count(old) != 1:
            raise RuntimeError(f"version/build mutation anchor differs: {old!r}")
        source = source.replace(old, new, 1)
    atomic_write(path, source.encode("utf-8"))
    return [relative]


MUTATIONS = (
    Mutation(
        "remove-active-relic-from-plan",
        "Remove the active Relic resource from the visual plan.",
        "NRV-004",
        remove_active_relic,
    ),
    Mutation(
        "replace-interactive-artifact-preview-with-color",
        "Replace the interactive Artifact preview with a plain Color.",
        "NRV-008",
        replace_interactive_preview,
    ),
    Mutation(
        "stop-resolving-norse-codex-card",
        "Stop resolving the Norse Codex card.",
        "NRV-004",
        stop_resolving_codex_card,
    ),
    Mutation(
        "remove-selected-seal-thumbnail",
        "Remove the selected Seal thumbnail from the picker.",
        "NRV-007",
        remove_selected_seal_thumbnail,
    ),
    Mutation(
        "remove-vault-image-rendering",
        "Remove Vault image rendering while retaining text.",
        "NRV-010",
        remove_vault_images,
    ),
    Mutation(
        "hardcode-norse-in-generic-view",
        "Hard-code codex.norse in the generic production visual view.",
        "NRV-017",
        hardcode_norse_in_generic_view,
    ),
    Mutation(
        "import-norse-provider-from-ui",
        "Import RuneScribeNorseThemeModule from the production UI target.",
        "NRV-017",
        import_norse_provider,
    ),
    Mutation(
        "bypass-runtime-resolution-with-bundle-module",
        "Bypass runtime resource resolution with Bundle.module.",
        "NRV-005",
        bypass_runtime_with_bundle,
    ),
    Mutation(
        "corrupt-resource-hash-fixture",
        "Corrupt a resource hash in a test fixture.",
        "NRV-002",
        corrupt_hash_fixture,
    ),
    Mutation(
        "publish-partial-visual-state",
        "Publish a partial visual state before all required resources resolve.",
        "NRV-006",
        publish_partial_state,
    ),
    Mutation(
        "allow-stale-selection-adoption",
        "Allow a stale selection task to overwrite a newer selection.",
        "NRV-006",
        allow_stale_adoption,
    ),
    Mutation(
        "allow-locked-artifact-selection",
        "Allow locked Artifact selection.",
        "NRV-013",
        allow_locked_selection,
    ),
    Mutation(
        "remove-high-contrast-fallback",
        "Remove High Contrast fallback.",
        "NRV-015",
        remove_high_contrast,
    ),
    Mutation(
        "remove-reduce-motion-fallback",
        "Remove Reduce Motion fallback.",
        "NRV-015",
        remove_reduce_motion,
    ),
    Mutation(
        "remove-accessibility-label",
        "Remove an accessibility label.",
        "NRV-015",
        remove_accessibility_label,
    ),
    Mutation(
        "exceed-decoded-resource-cache-budget",
        "Exceed decoded-resource cache budget.",
        "NRV-005",
        exceed_decoded_cache_budget,
    ),
    Mutation(
        "weaken-theme-resource-per-item-budget",
        "Raise the Theme resource per-item budget above 8 MiB.",
        "NRV-005",
        weaken_theme_resource_per_item_budget,
    ),
    Mutation(
        "undersize-provider-inventory-budget",
        "Reduce provider inventory capacity below the exact Norse v2 catalog.",
        "NRV-005",
        undersize_provider_inventory_budget,
    ),
    Mutation(
        "blank-ui-on-optional-provider-failure",
        "Make optional provider failure blank the UI instead of falling back.",
        "NRV-014",
        blank_on_optional_provider_failure,
    ),
    Mutation(
        "change-script-base-runes",
        "Change script.base-runes.",
        "NRV-004",
        change_script_identity,
    ),
    Mutation(
        "alter-norse-v2-generator-source",
        "Change the accepted Norse v2 resource generator source.",
        "NRV-002",
        alter_v2_generator_source,
    ),
    Mutation(
        "alter-generated-norse-application-catalog",
        "Make the generated application catalog differ from the pinned v2 generator.",
        "NRV-002",
        alter_generated_application_catalog,
    ),
    Mutation(
        "introduce-legacy-norse-current-content-id",
        "Reintroduce a legacy Norse artifact ID into current v2 content.",
        "NRV-002",
        introduce_legacy_current_content_id,
    ),
    Mutation(
        "alter-norse-production-asset-byte",
        "Change a Norse production asset byte.",
        "NRV-002",
        alter_norse_asset_byte,
    ),
    Mutation(
        "change-version-build",
        "Change version/build.",
        "NRV-024",
        change_version_build,
    ),
)


def copy_repository(source: Path, destination: Path) -> None:
    ignored = shutil.ignore_patterns(
        ".git",
        ".build",
        "build",
        "DerivedData",
        "*.xcresult",
        "__pycache__",
        ".DS_Store",
    )
    shutil.copytree(source, destination, symlinks=True, ignore=ignored)


SOURCE_FINGERPRINT_IGNORED_DIRECTORIES = frozenset({
    ".git",
    ".build",
    "build",
    "DerivedData",
    "__pycache__",
})


def source_fingerprint_includes(root: Path, path: Path) -> bool:
    relative = path.relative_to(root)
    if path.name == ".DS_Store":
        return False
    return not any(
        part in SOURCE_FINGERPRINT_IGNORED_DIRECTORIES
        or part.endswith(".xcresult")
        for part in relative.parts
    )


def source_fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    roots = [
        root / "Packages",
        root / "RuneScribTests",
        root / "RuneScribIOSTests",
        root / "RuneScribIOSUITests",
        root / "RuneScribMacParityTests",
        root / "RuneScribArchitectureTests",
        root / "scripts",
        root / "project.yml",
        root / "RuneScrib.xcodeproj/project.pbxproj",
    ]
    files: list[Path] = []
    for candidate in roots:
        if candidate.is_file():
            files.append(candidate)
        elif candidate.is_dir():
            files.extend(
                path
                for path in candidate.rglob("*")
                if path.is_file() and source_fingerprint_includes(root, path)
            )
    for path in sorted(files, key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        data = path.read_bytes()
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def run_validator(root: Path) -> tuple[int, dict[str, Any], str]:
    command = [
        sys.executable,
        str(root / "scripts/check-norse-visual-remediation.py"),
        "--repo-root",
        str(root),
        "--profile",
        "implementation",
        "--format",
        "json",
    ]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"validator did not emit JSON ({error}); stderr={result.stderr.strip()!r}"
        ) from error
    return result.returncode, payload, shlex.join(command)


def git_sha(root: Path) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip().lower()
    return value if re.fullmatch(r"[0-9a-f]{40}", value) else "0" * 40


def tool_version(command: Sequence[str]) -> str:
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    output = (result.stdout or result.stderr).strip()
    return "; ".join(output.splitlines()) if output else "unavailable"


def execute(arguments: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    root = arguments.repo_root.resolve()
    started = utc_now()
    before_fingerprint = source_fingerprint(root)
    failures: list[str] = []
    results: list[dict[str, Any]] = []
    selected = [
        mutation
        for mutation in MUTATIONS
        if not arguments.only or mutation.mutation_id in arguments.only
    ]
    unknown = set(arguments.only or []) - {mutation.mutation_id for mutation in MUTATIONS}
    if unknown:
        failures.append(f"unknown mutation IDs: {', '.join(sorted(unknown))}")

    with tempfile.TemporaryDirectory(prefix="runescribe-nrv-mutations-") as temporary:
        sandbox = Path(temporary) / "repository"
        copy_repository(root, sandbox)
        pristine_files = {
            path.relative_to(sandbox).as_posix(): path.read_bytes()
            for path in sandbox.rglob("*")
            if path.is_file()
        }
        baseline_code, baseline_payload, baseline_command = run_validator(sandbox)
        if baseline_code != 0 or baseline_payload.get("result") != "PASS":
            finding_summary = [
                f"{item.get('gate')}/{item.get('rule')}"
                for item in baseline_payload.get("findings", [])
                if isinstance(item, dict)
            ]
            failures.append(
                "unmutated implementation profile is not PASS: "
                + ", ".join(finding_summary[:20])
            )
        else:
            for mutation in selected:
                mutation_started = utc_now()
                targets: list[str] = []
                originals: dict[str, bytes] = {}
                detected_rules: list[str] = []
                target_hashes: dict[str, dict[str, str]] = {}
                validator_command = baseline_command
                actual_outcome = "RUNNER_ERROR"
                restored = False
                restored_validator = "NOT_RUN"
                detail: Optional[str] = None
                try:
                    targets = mutation.apply(sandbox)
                    if not targets or len(targets) != len(set(targets)):
                        raise RuntimeError("mutation did not report a unique nonempty target set")
                    # The mutation function has already changed each target.  Its
                    # pristine counterpart comes from the immutable in-memory
                    # snapshot made immediately after the temporary copy.
                    for relative in targets:
                        if relative not in pristine_files:
                            raise RuntimeError(f"pristine target is missing: {relative}")
                        originals[relative] = pristine_files[relative]
                        if (sandbox / relative).read_bytes() == originals[relative]:
                            raise RuntimeError(f"mutation made no byte change: {relative}")
                        target_hashes[relative] = {
                            "before": hashlib.sha256(originals[relative]).hexdigest(),
                            "mutated": hashlib.sha256(
                                (sandbox / relative).read_bytes()
                            ).hexdigest(),
                        }
                    code, payload, validator_command = run_validator(sandbox)
                    detected_rules = sorted(
                        {
                            f"{item.get('gate')}/{item.get('rule')}"
                            for item in payload.get("findings", [])
                            if isinstance(item, dict)
                        }
                    )
                    detected_gates = {
                        item.get("gate")
                        for item in payload.get("findings", [])
                        if isinstance(item, dict)
                    }
                    if code != 0 and mutation.expected_gate in detected_gates:
                        actual_outcome = "REJECTED"
                    elif code == 0:
                        actual_outcome = "UNEXPECTED_PASS"
                        detail = "validator accepted the known regression"
                    else:
                        actual_outcome = "WRONG_GATE"
                        detail = (
                            f"validator failed without expected gate {mutation.expected_gate}; "
                            f"detected={detected_rules}"
                        )
                except Exception as error:  # runner records and continues safely
                    detail = str(error)
                finally:
                    try:
                        for relative, data in originals.items():
                            atomic_write(sandbox / relative, data)
                        restored = all(
                            (sandbox / relative).read_bytes() == data
                            for relative, data in originals.items()
                        ) and bool(originals)
                        for relative in originals:
                            target_hashes.setdefault(relative, {})["restored"] = hashlib.sha256(
                                (sandbox / relative).read_bytes()
                            ).hexdigest()
                        if restored:
                            restored_code, restored_payload, _ = run_validator(sandbox)
                            restored_validator = (
                                "PASS"
                                if restored_code == 0 and restored_payload.get("result") == "PASS"
                                else "FAIL"
                            )
                        else:
                            restored_validator = "FAIL"
                    except Exception as error:
                        restored = False
                        restored_validator = "FAIL"
                        detail = f"{detail + '; ' if detail else ''}restore error: {error}"

                passed = (
                    actual_outcome == "REJECTED"
                    and restored
                    and restored_validator == "PASS"
                )
                if not passed:
                    failures.append(
                        f"{mutation.mutation_id}: outcome={actual_outcome}, "
                        f"restored={restored}, restoredValidator={restored_validator}"
                        + (f", detail={detail}" if detail else "")
                    )
                results.append(
                    {
                        "id": mutation.mutation_id,
                        "instruction": mutation.instruction,
                        "expectedGate": mutation.expected_gate,
                        "expectedOutcome": "REJECTED",
                        "actualOutcome": actual_outcome,
                        "result": "PASS" if passed else "FAIL",
                        "targets": targets,
                        "targetSHA256": target_hashes,
                        "command": validator_command,
                        "detectedRules": detected_rules,
                        "sourceRestored": restored,
                        "restoredValidatorResult": restored_validator,
                        "startTimestamp": mutation_started,
                        "endTimestamp": utc_now(),
                        "failure": detail,
                    }
                )

    after_fingerprint = source_fingerprint(root)
    original_untouched = before_fingerprint == after_fingerprint
    if not original_untouched:
        failures.append("original repository source fingerprint changed while mutations ran")
    complete_run = not arguments.only and len(results) == len(MUTATIONS)
    if not complete_run:
        failures.append("partial mutation selection cannot produce blocking PASS evidence")

    output = None
    if arguments.output:
        output = (
            arguments.output.resolve()
            if arguments.output.is_absolute()
            else (root / arguments.output).resolve()
        )
    command = shlex.join([sys.executable, *sys.argv])
    artifact_paths = [
        (
            output.relative_to(root).as_posix()
            if output is not None and output.is_relative_to(root)
            else str(output)
        )
    ] if output is not None else []
    payload = {
        "schemaVersion": "1.0",
        "sourceSHA": git_sha(root),
        "command": command,
        "destination": {
            "kind": "isolated-temporary-copy",
            "validatorProfile": "implementation",
            "originalRepository": str(root),
        },
        "startTimestamp": started,
        "endTimestamp": utc_now(),
        "result": "PASS" if not failures else "FAIL",
        "failures": failures,
        "artifactPaths": artifact_paths,
        "toolchainVersions": {
            "python": platform.python_version(),
            "host": platform.platform(),
            "xcode": tool_version(("xcodebuild", "-version")),
            "swift": tool_version(("swift", "--version")),
            "validator": "scripts/check-norse-visual-remediation.py",
        },
        "expectedMutationCount": len(MUTATIONS),
        "executedMutationCount": len(results),
        "sourceRestoration": {
            "strategy": "temporary repository copy; exact target bytes restored after each mutation",
            "originalWorktreeUntouched": original_untouched,
            "beforeFingerprint": before_fingerprint,
            "afterFingerprint": after_fingerprint,
        },
        "mutations": results,
    }
    return (0 if not failures else 1), payload


def parse_arguments(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to the script's repository)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="write the evidence JSON atomically; otherwise emit it only to stdout",
    )
    parser.add_argument(
        "--only",
        action="append",
        help="run one mutation ID (repeatable); partial runs intentionally return FAIL",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="list the exact 25 mutation IDs and expected gates without running them",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = parse_arguments(argv)
    if arguments.list:
        for mutation in MUTATIONS:
            print(f"{mutation.mutation_id}\t{mutation.expected_gate}\t{mutation.instruction}")
        return 0
    code, payload = execute(arguments)
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if arguments.output:
        output = (
            arguments.output.resolve()
            if arguments.output.is_absolute()
            else (arguments.repo_root.resolve() / arguments.output).resolve()
        )
        atomic_write(output, encoded)
    print(encoded.decode("utf-8"), end="")
    return code


if __name__ == "__main__":
    sys.exit(main())
