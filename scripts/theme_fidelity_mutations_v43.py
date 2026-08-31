#!/usr/bin/env python3
"""Execute the 47 v4.3 Theme-fidelity negative mutations safely.

The suite never edits the source checkout.  Authority mutations run against a
temporary copy of the imported authority, the protected-reference copy test
runs against a minimal temporary shipping tree, and the remaining mutations
run against copied source/evidence or explicitly claim-scoped,
non-acceptance fixtures.
"""

from __future__ import annotations

import argparse
import ast
import copy
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Iterable, Mapping, MutableMapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
AUTHORITY_RELATIVE = Path("docs/verification/theme-fidelity-v4-3/authority")
AUTHORITY_MANIFEST_RELATIVE = AUTHORITY_RELATIVE / "IMPORT-MANIFEST-v4.3.json"
COMPARISON_RELATIVE = (
    AUTHORITY_RELATIVE
    / "03-COMPARISON-AUTHORITY/Comparison-Authority-v1.3.json"
)
CANONICAL_RELATIVE = (
    AUTHORITY_RELATIVE
    / "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-v1.3.json"
)
MASK_RELATIVE = (
    AUTHORITY_RELATIVE
    / "04-ASSETS/98-CANONICAL-MASKS/iphone-941x1672-system-chrome-mask.png"
)
AUTHORITY_VALIDATOR = Path("scripts/theme_fidelity_authority_v13.py")
REFERENCE_BOUNDARY = Path("scripts/check-production-reference-boundary.py")
MUTATION_RUNNER = Path("scripts/theme_fidelity_mutations_v43.py")
HISTORICAL_EVIDENCE = Path("docs/verification/remediation-v1/NegativeMutations.json")
QUALIFICATION_DRIVER = Path("scripts/materialize-theme-fidelity-v43-evidence.py")
CONTRACT_RELATIVE = Path(".mutation-fixtures/v4-3-negative-mutation-contract.json")
TEMPLATE_FIXTURE = Path(".mutation-fixtures/template-evidence.json")
RESOURCE_SELECTION_FIXTURE = Path(".mutation-fixtures/resource-selection.json")
TRANSITION_FIXTURE = Path(".mutation-fixtures/theme-transition.json")
PROGRESSION_FIXTURE = Path(".mutation-fixtures/progression-event.json")
DECODE_FIXTURE = Path(".mutation-fixtures/incoming-decode.json")
RUNTIME_BOUNDARY_FIXTURE = Path(".mutation-fixtures/runtime-boundary.json")
LAYOUT_FIXTURE = Path(".mutation-fixtures/responsive-accessibility.json")
SOURCE_BOUNDARY_FIXTURE = Path(".mutation-fixtures/source-boundary.json")
RUNTIME_PROBE_FIXTURE = Path(".mutation-fixtures/runtime-probe-results.json")
MAPPING_RESULTS_FIXTURE = Path(".mutation-fixtures/mapping-results.json")
GATE_RESULTS_FIXTURE = Path(".mutation-fixtures/gate-results.json")
SAFE_SHIPPING_CANDIDATE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
    "Resources/Production/Seals/seal.norse.berserk.png"
)
MOONLEAF_VALID_RESOURCE = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/"
    "Resources/Production/background/moonleaf-background-static.png"
)
BOUNDARY_SAFE_RELATIVE = Path(
    "Packages/MutationProbe/Sources/MutationProbe/Resources/Production/"
    "Seals/seal.norse.berserk.png"
)
BOUNDARY_INJECTED_RELATIVE = Path(
    "Packages/MutationProbe/Sources/MutationProbe/Resources/Production/"
    "Injected/controlling-reference-copy.png"
)

PACKAGE_ASSET_MANIFEST = Path("04-ASSETS/FULL-ASSET-MANIFEST-v4.3.json")
PACKAGE_CANONICAL_CATALOG = Path(
    "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-v1.3.json"
)
PACKAGE_PREFLIGHT = Path("05-AUTOMATION/run-v4.3-preflight.sh")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
EXPECTED_RESPONSIVE_ENTRIES = 400
EXPECTED_MAPPING_INSTANCES = 1_104
EXPECTED_RUNTIME_PROBE_INSTANCES = 576
EXPECTED_MUTATION_COUNT = 47
MINIMUM_HIT_REGION = 44.0
MINIMUM_TEMPORAL_SEPARATION = 1.5


class MutationFailure(RuntimeError):
    """Raised when the runner cannot prove a mutation safely."""


@dataclass(frozen=True)
class Finding:
    code: str
    path: str
    message: str


@dataclass(frozen=True)
class CommandResult:
    command: str
    exit_status: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class FileSnapshot:
    exists: bool
    data: bytes | None
    mode: int | None

    @property
    def sha256(self) -> str | None:
        return sha256_bytes(self.data) if self.data is not None else None


@dataclass(frozen=True)
class MutationDefinition:
    ordinal: int
    requirement: str
    category: str
    source_or_authority_file: str
    guard: str
    diagnostic_code: str
    isolation: str = "source-bound-contract-fixture"
    bound_source_or_evidence_file: str | None = None

    @property
    def mutation_id(self) -> str:
        return f"V43-MUT-{self.ordinal:03d}"


@dataclass(frozen=True)
class TextMutationSpec:
    relative: Path
    before: str
    after: str
    detail: str


MUTATION_REQUIREMENTS = (
    "Map one canonical candidate ID to a second reference SHA.",
    "Change one canonical candidate's required dimensions.",
    "Reintroduce a responsive candidateElementID into an image-metric mapping.",
    "Remove one of the 400 authority entries.",
    "Duplicate one mapping ID.",
    "Change one image mapping to structural-only.",
    "Add an undeclared crop or post-capture resize.",
    "Enlarge the package-supplied system-chrome mask by one product-content row.",
    "Lower one comparison threshold.",
    "Mark a template evidence file as acceptance evidence.",
    "Add a controlling-golden filename to production source.",
    "Load a reference PNG from an external path in the canonical harness.",
    "Copy a reference PNG into a shipping bundle under a new name.",
    "Add a test-only renderer that bypasses the production composition policy.",
    "Overlay a candidate with a reference image at partial opacity.",
    "Replace an approved Seal with a system symbol.",
    "Replace a Theme background with a generic gradient.",
    "Stretch a Relic to the wrong aspect ratio.",
    "Move a Seal outside the descriptor-approved anchors.",
    "Remove a High Contrast resource.",
    "Use the standard resource while Reduce Motion is active.",
    "Substitute the wrong Theme resource while preserving a valid hash.",
    "Reintroduce an obsolete Norse Relic or Seal as current content.",
    "Render a fallback font while reporting the primary Script active.",
    "Introduce a mixed-Theme frame during a selection transition.",
    "Make Norse appear locked.",
    "Remove Norse ownership or fallback availability.",
    "Make an optional provider failure block application launch.",
    "Add a direct production UI import of a Theme provider.",
    "Grant ownership from an Encounter/preview state.",
    "Gate incoming decode on Theme ownership.",
    "Break live progression-to-Theme reconciliation.",
    "Return a provider-owned service object across the runtime boundary.",
    "Clip the artifact preview below the viewport.",
    "Shrink a required mobile hit region below the accepted size.",
    "Create horizontal overflow in a large-text state.",
    "Remove a noncolor owned/selected/locked cue.",
    "Let Reduce Motion report an active Theme animation.",
    "Reuse the same temporal frame file without recording two separated captures.",
    "Inflate a grouped accessibility frame beyond the intended component.",
    "Change source after evidence generation.",
    "Remove one runtime-probe instance.",
    "Remove one mapping result.",
    "Point final evidence to a different authority hash.",
    "Rewrite a historical evidence file.",
    "Mark a failed gate PASS.",
    "Attempt to merge, tag, archive, notarize, upload, or release within the qualification script.",
)


SOURCE_FILES = {
    10: "docs/verification/theme-fidelity-v4-3/final-qualification.json",
    11: "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/NorseBaseThemeDescriptor.swift",
    12: "ThemeFidelityTests/ThemeCanonicalRenderHarness.swift",
    13: BOUNDARY_INJECTED_RELATIVE.as_posix(),
    14: "ThemeFidelityTests/ThemeCanonicalRenderHarness.swift",
    15: "ThemeFidelityTests/ThemeCanonicalRenderHarness.swift",
    16: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ThemeVisualComponents.swift",
    17: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RootView.swift",
    18: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/CodexProductionAssemblies.swift",
    19: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ShareArtifactRenderer.swift",
    20: "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Script/script.base-runes.specimen.high-contrast.png",
    21: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ShareArtifactRenderer.swift",
    22: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ThemeVisualComponents.swift",
    23: "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/NorseBaseThemeDescriptor.swift",
    24: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ShareArtifactRenderer.swift",
    25: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/SemanticThemePresentation.swift",
    26: "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/ThemeCoordinatorService.swift",
    27: "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/ThemeCoordinatorService.swift",
    28: "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Runtime.swift",
    29: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ThemeVisualComponents.swift",
    30: "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/ProgressionReducer.swift",
    31: "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Import/ImportUseCase.swift",
    32: "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/ThemeCoordinatorService.swift",
    33: "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/ThemeCoordinatorContracts.swift",
    34: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/CodexProductionAssemblies.swift",
    35: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContentView.swift",
    36: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/CodexProductionAssemblies.swift",
    37: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VaultProgressView.swift",
    38: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContentView.swift",
    39: "docs/verification/theme-fidelity-v4-3/runtime-probe-results.json",
    40: "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/CodexProductionAssemblies.swift",
    41: "docs/verification/theme-fidelity-v4-3/SourceBoundary.json",
    42: "docs/verification/theme-fidelity-v4-3/runtime-probe-results.json",
    43: "docs/verification/theme-fidelity-v4-3/mapping-results.json",
    44: "docs/verification/theme-fidelity-v4-3/final-qualification.json",
    45: HISTORICAL_EVIDENCE.as_posix(),
    46: "docs/verification/theme-fidelity-v4-3/gate-results.json",
    47: QUALIFICATION_DRIVER.as_posix(),
}


FIXTURE_TARGETS = {
    10: TEMPLATE_FIXTURE,
    22: RESOURCE_SELECTION_FIXTURE,
    25: TRANSITION_FIXTURE,
    30: PROGRESSION_FIXTURE,
    31: DECODE_FIXTURE,
    33: RUNTIME_BOUNDARY_FIXTURE,
    34: LAYOUT_FIXTURE,
    35: LAYOUT_FIXTURE,
    36: LAYOUT_FIXTURE,
    37: LAYOUT_FIXTURE,
    38: LAYOUT_FIXTURE,
    39: LAYOUT_FIXTURE,
    40: LAYOUT_FIXTURE,
    41: SOURCE_BOUNDARY_FIXTURE,
    42: RUNTIME_PROBE_FIXTURE,
    43: MAPPING_RESULTS_FIXTURE,
    46: GATE_RESULTS_FIXTURE,
}


CONTRACT_CODES = {
    10: "V43M-010-TEMPLATE-PROMOTION",
    11: "V43M-011-CONTROLLING-GOLDEN-IN-PRODUCTION",
    12: "V43M-012-EXTERNAL-REFERENCE-LOAD",
    13: "PRB-101",
    14: "V43M-014-BYPASS-RENDERER",
    15: "V43M-015-REFERENCE-OVERLAY",
    16: "V43M-016-SYSTEM-SEAL",
    17: "V43M-017-GENERIC-BACKGROUND",
    18: "V43M-018-RELIC-ASPECT",
    19: "V43M-019-SEAL-ANCHOR",
    20: "V43M-020-HIGH-CONTRAST-RESOURCE",
    21: "V43M-021-REDUCE-MOTION-RESOURCE",
    22: "V43M-022-MIXED-THEME-RESOURCE",
    23: "V43M-023-OBSOLETE-NORSE-CONTENT",
    24: "V43M-024-FONT-REPORTING",
    25: "V43M-025-MIXED-THEME-TRANSITION",
    26: "V43M-026-NORSE-LOCKED",
    27: "V43M-027-NORSE-FALLBACK",
    28: "V43M-028-OPTIONAL-FAILURE-LAUNCH",
    29: "V43M-029-PROVIDER-IMPORT",
    30: "V43M-030-ENCOUNTER-OWNERSHIP",
    31: "V43M-031-DECODE-OWNERSHIP-GATE",
    32: "V43M-032-LIVE-RECONCILIATION",
    33: "V43M-033-RUNTIME-BOUNDARY-TYPE",
    34: "V43M-034-PREVIEW-CONTAINMENT",
    35: "V43M-035-HIT-REGION",
    36: "V43M-036-LARGE-TEXT-OVERFLOW",
    37: "V43M-037-NONCOLOR-STATE-CUE",
    38: "V43M-038-REDUCE-MOTION-ANIMATION",
    39: "V43M-039-TEMPORAL-CAPTURE",
    40: "V43M-040-ACCESSIBILITY-GROUP-FRAME",
    41: "V43M-041-SOURCE-BOUNDARY",
    42: "V43M-042-RUNTIME-PROBE-CARDINALITY",
    43: "V43M-043-MAPPING-CARDINALITY",
    44: "V43M-044-AUTHORITY-HASH",
    45: "V43M-045-HISTORICAL-EVIDENCE",
    46: "V43M-046-FAILED-GATE-PROMOTION",
    47: "V43M-047-PUBLICATION-OPERATION",
}


TEXT_MUTATIONS = {
    11: TextMutationSpec(
        Path(SOURCE_FILES[11]),
        'sourceReference: "Rune Scribe Norse Theme Module package version 1.0",',
        'sourceReference: "moonleaf-compose-final-a.png",',
        "replace a production provenance source with controlling-golden filename moonleaf-compose-final-a.png",
    ),
    12: TextMutationSpec(
        Path(SOURCE_FILES[12]),
        '''        guard let url = bundle.url(
            forResource: "Canonical-Render-Catalog-v1.3",
            withExtension: "json"
        ) else { throw ThemeCanonicalRegistryError.missingCatalog }
        return try decode(data: Data(contentsOf: url))''',
        '''        guard bundle.url(
            forResource: "Canonical-Render-Catalog-v1.3",
            withExtension: "json"
        ) != nil else { throw ThemeCanonicalRegistryError.missingCatalog }
        let url = URL(fileURLWithPath: "/tmp/moonleaf-compose-final-a.png")
        return try decode(data: Data(contentsOf: url))''',
        "load the canonical catalog through an external /tmp reference PNG path",
    ),
    14: TextMutationSpec(
        Path(SOURCE_FILES[14]),
        "let content = try content(view, request: request)",
        '''let content = AnyView(
            Color.black.accessibilityIdentifier("ThemeFidelityBypassRenderer")
        )''',
        "replace production-composed canonical content with a test-only black bypass renderer",
    ),
    15: TextMutationSpec(
        Path(SOURCE_FILES[15]),
        "let renderer = ImageRenderer(content: content)",
        '''let renderer = ImageRenderer(
            content: content.overlay {
                Image("moonleaf-compose-final-a").opacity(0.5)
            }
        )''',
        "overlay each canonical candidate with the controlling reference image at 50 percent opacity",
    ),
    16: TextMutationSpec(
        Path(SOURCE_FILES[16]),
        '''                artwork
                    .frame(width: 42, height: 42)''',
        '''                Image(systemName: kind == .seal ? "seal" : "photo")
                    .frame(width: 42, height: 42)''',
        "replace the approved Seal artwork branch with a system symbol",
    ),
    17: TextMutationSpec(
        Path(SOURCE_FILES[17]),
        "RuntimeMetalBackground()",
        '''LinearGradient(
                colors: [.black, .gray],
                startPoint: .top,
                endPoint: .bottom
            )''',
        "replace the resolved Theme root background with a generic linear gradient",
    ),
    18: TextMutationSpec(
        Path(SOURCE_FILES[18]),
        "let height = width / aspect",
        "let height = width * aspect",
        "calculate Relic height by multiplying its aspect ratio, producing nonuniform geometry",
    ),
    19: TextMutationSpec(
        Path(SOURCE_FILES[19]),
        '''            } else {
                selectedAnchor = candidates[0]
            }''',
        '''            } else {
                selectedAnchor = ThemeSealAnchor(
                    category: .topCenter,
                    point: try ThemeNormalizedPoint(x: 0.5, y: 0.1)
                )
            }''',
        "assign the Seal to a top-center anchor explicitly absent from the descriptor-approved anchors",
    ),
    21: TextMutationSpec(
        Path(SOURCE_FILES[21]),
        '''        } else if reduceMotion {
            descriptor.codex.background.reduceMotionResourceID''',
        '''        } else if reduceMotion {
            descriptor.codex.background.staticBaseResourceID''',
        "resolve the standard static background while Reduce Motion is active",
    ),
    23: TextMutationSpec(
        Path(SOURCE_FILES[23]),
        'defaultRelicID: artifactID("relic.norse.runestone-tablet"),',
        'defaultRelicID: artifactID("relic.norse.forge-master"),',
        "make obsolete relic.norse.forge-master current as the Norse default Relic",
    ),
    24: TextMutationSpec(
        Path(SOURCE_FILES[24]),
        "plan.fontPostScriptName,",
        '"Helvetica",',
        "render glyphs with Helvetica while the plan continues reporting the primary Script name",
    ),
    26: TextMutationSpec(
        Path(SOURCE_FILES[26]),
        "state: provider.state,",
        '''state: provider.descriptor.codex.id == RuneScribeCodexIDs.norse
                    ? .locked : provider.state,''',
        "report the required-base Norse provider as locked without changing ownership",
    ),
    27: TextMutationSpec(
        Path(SOURCE_FILES[27]),
        "let owned = isBase || entitlements.contains(descriptor.codex.entitlementID)",
        "let owned = entitlements.contains(descriptor.codex.entitlementID)",
        "remove automatic ownership from the required-base Norse provider",
    ),
    28: TextMutationSpec(
        Path(SOURCE_FILES[28]),
        '''            let manifest = try ModuleManifestDecoder.decode(manifestData)
            try register(
                manifest: manifest,
                factory: factory,
                themeDiscovery: themeDiscovery
            )
        } catch {
            guard factory.descriptor.criticality == .optional else {''',
        '''            let manifest = try ModuleManifestDecoder.decode(manifestData)
            try register(
                manifest: manifest,
                factory: factory,
                themeDiscovery: themeDiscovery
            )
        } catch {
            guard factory.descriptor.criticality == .required else {''',
        "rethrow optional provider registration failures into application launch",
    ),
    29: TextMutationSpec(
        Path(SOURCE_FILES[29]),
        "import RuneScribeContracts\nimport SwiftUI",
        "import RuneScribeContracts\nimport RuneScribeNorseThemeModule\nimport SwiftUI",
        "add a direct production UI import of the Norse Theme provider module",
    ),
    32: TextMutationSpec(
        Path(SOURCE_FILES[32]),
        "providersByCodexID = records",
        "providersByCodexID = [:]",
        "discard the newly reconciled live progression-to-Theme provider records",
    ),
}


def definitions() -> tuple[MutationDefinition, ...]:
    output: list[MutationDefinition] = []
    categories = (
        (1, 10, "authority-and-candidate"),
        (11, 15, "reference-embedding"),
        (16, 25, "production-visual"),
        (26, 33, "state-and-architecture"),
        (34, 40, "responsive-and-accessibility"),
        (41, 47, "evidence-and-publication"),
    )
    for ordinal, requirement in enumerate(MUTATION_REQUIREMENTS, start=1):
        bound_source: str | None = None
        fixture_target: Path | None = None
        category = next(
            value for lower, upper, value in categories if lower <= ordinal <= upper
        )
        if ordinal <= 9:
            target = (
                MASK_RELATIVE.as_posix()
                if ordinal == 8
                else (
                    CANONICAL_RELATIVE.as_posix()
                    if ordinal in {1, 2}
                    else COMPARISON_RELATIVE.as_posix()
                )
            )
            code = "imported-file-hash-drift"
            guard = AUTHORITY_VALIDATOR.as_posix()
            isolation = "isolated-authority-copy"
        else:
            bound_source = SOURCE_FILES[ordinal]
            fixture_target = FIXTURE_TARGETS.get(ordinal)
            target = (
                fixture_target.as_posix()
                if fixture_target is not None
                else bound_source
            )
            code = CONTRACT_CODES[ordinal]
            guard = (
                REFERENCE_BOUNDARY.as_posix()
                if ordinal == 13
                else "scripts/theme_fidelity_mutations_v43.py guard-case"
            )
            isolation = (
                "isolated-minimal-shipping-copy"
                if ordinal == 13
                else (
                    "explicit-executable-non-acceptance-fixture"
                    if fixture_target is not None
                    else "isolated-source-or-evidence-copy"
                )
            )
        output.append(
            MutationDefinition(
                ordinal=ordinal,
                requirement=requirement,
                category=category,
                source_or_authority_file=target,
                guard=guard,
                diagnostic_code=code,
                isolation=isolation,
                bound_source_or_evidence_file=(
                    bound_source if fixture_target is not None else None
                ),
            )
        )
    return tuple(output)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def atomic_write(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        if path.exists():
            os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def write_json(path: Path, value: Any) -> None:
    atomic_write(path, canonical_json_bytes(value))


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def snapshot(path: Path) -> FileSnapshot:
    if not path.exists():
        return FileSnapshot(False, None, None)
    if not path.is_file() or path.is_symlink():
        raise MutationFailure(f"mutation target is not a regular file: {path}")
    return FileSnapshot(True, path.read_bytes(), path.stat().st_mode & 0o777)


def restore(path: Path, original: FileSnapshot) -> None:
    if original.exists:
        if original.data is None:
            raise MutationFailure(f"snapshot bytes are missing: {path}")
        atomic_write(path, original.data)
        if original.mode is not None:
            os.chmod(path, original.mode)
    elif path.exists():
        path.unlink()


def png_dimensions(path: Path) -> tuple[int, int]:
    header = path.read_bytes()[:24]
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise MutationFailure(f"PNG header is invalid: {path}")
    width, height = struct.unpack(">II", header[16:24])
    if width <= 0 or height <= 0:
        raise MutationFailure(f"PNG dimensions are invalid: {path}")
    return width, height


def git_output(root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
    )
    if completed.returncode != 0:
        raise MutationFailure(
            f"git {' '.join(arguments)} failed: {(completed.stderr or completed.stdout).strip()}"
        )
    return completed.stdout


def git_sha(root: Path) -> str:
    value = git_output(root, "rev-parse", "HEAD").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise MutationFailure("repository HEAD is not a commit SHA")
    return value


def git_status(root: Path) -> str:
    return git_output(root, "status", "--porcelain=v1", "--untracked-files=all")


def run_command(
    arguments: Sequence[str], *, cwd: Path, timeout: int = 300
) -> CommandResult:
    command = shlex.join([str(item) for item in arguments])
    try:
        completed = subprocess.run(
            [str(item) for item in arguments],
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
    except subprocess.TimeoutExpired as error:
        return CommandResult(command, 124, error.stdout or "", error.stderr or "timeout")
    return CommandResult(command, completed.returncode, completed.stdout, completed.stderr)


def copy_file(source_root: Path, destination_root: Path, relative: Path) -> None:
    source = source_root / relative
    if not source.is_file() or source.is_symlink():
        raise MutationFailure(f"required source file is missing or linked: {relative}")
    destination = destination_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def copy_sandbox(repository_root: Path, destination: Path) -> None:
    shutil.copytree(repository_root / AUTHORITY_RELATIVE, destination / AUTHORITY_RELATIVE)
    required = {
        AUTHORITY_VALIDATOR,
        REFERENCE_BOUNDARY,
        MUTATION_RUNNER,
        HISTORICAL_EVIDENCE,
        QUALIFICATION_DRIVER,
        SAFE_SHIPPING_CANDIDATE,
        MOONLEAF_VALID_RESOURCE,
        *(
            Path(value)
            for ordinal, value in SOURCE_FILES.items()
            if ordinal != 13
        ),
    }
    for relative in sorted(required, key=lambda item: item.as_posix()):
        if (destination / relative).exists():
            continue
        copy_file(repository_root, destination, relative)
    boundary_safe = destination / BOUNDARY_SAFE_RELATIVE
    boundary_safe.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(repository_root / SAFE_SHIPPING_CANDIDATE, boundary_safe)
    (destination / BOUNDARY_INJECTED_RELATIVE).parent.mkdir(
        parents=True, exist_ok=True
    )


def inventory_digest(root: Path) -> str:
    digest = hashlib.sha256()
    entries = sorted(
        root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()
    )
    for path in entries:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        metadata = path.lstat()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update((metadata.st_mode & 0o7777).to_bytes(4, "big"))
        if path.is_symlink():
            digest.update(b"L")
            target = os.readlink(path).encode("utf-8", "surrogateescape")
            digest.update(len(target).to_bytes(4, "big"))
            digest.update(target)
        elif path.is_dir():
            digest.update(b"D")
        elif path.is_file():
            digest.update(b"F")
            digest.update(metadata.st_size.to_bytes(8, "big"))
            digest.update(bytes.fromhex(sha256_file(path)))
        else:
            digest.update(b"O")
    return digest.hexdigest()


def mapping_inventory(authority: Mapping[str, Any]) -> list[str]:
    return [
        mapping["mappingID"]
        for entry in authority["entries"]
        for mapping in entry["referenceMappings"]
    ]


def probe_inventory(authority: Mapping[str, Any]) -> list[str]:
    return [
        f"{entry['id']}|{probe_id}"
        for entry in authority["entries"]
        for probe_id in entry["runtimeProbeIDs"]
    ]


def source_binding_paths() -> list[Path]:
    return sorted(
        {MUTATION_RUNNER, *{
            Path(value)
            for ordinal, value in SOURCE_FILES.items()
            if ordinal != 13
        }},
        key=lambda item: item.as_posix(),
    )


def build_contract(root: Path, *, source_sha: str) -> dict[str, Any]:
    authority_path = root / COMPARISON_RELATIVE
    canonical_path = root / CANONICAL_RELATIVE
    authority = load_json(authority_path)
    canonical = load_json(canonical_path)
    entries = authority.get("entries", [])
    candidates = canonical.get("candidates", [])
    if len(entries) != EXPECTED_RESPONSIVE_ENTRIES or len(candidates) != 50:
        raise MutationFailure("v4.3 authority cardinality baseline is not intact")
    mappings = mapping_inventory(authority)
    probes = probe_inventory(authority)
    if len(mappings) != EXPECTED_MAPPING_INSTANCES:
        raise MutationFailure("v4.3 mapping baseline is not intact")
    if len(probes) != EXPECTED_RUNTIME_PROBE_INSTANCES:
        raise MutationFailure("v4.3 runtime-probe baseline is not intact")
    image_mapping = next(
        mapping
        for entry in entries
        for mapping in entry["referenceMappings"]
        if mapping.get("scoreDisposition") == "image-metric"
    )
    first_candidate = candidates[0]
    mask_width, mask_height = png_dimensions(root / MASK_RELATIVE)
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise MutationFailure("source checkout SHA is invalid")
    historical_path = root / HISTORICAL_EVIDENCE
    if not historical_path.is_file():
        raise MutationFailure("historical evidence binding target is missing")
    source_bindings = {
        relative.as_posix(): sha256_file(root / relative)
        for relative in source_binding_paths()
        if (root / relative).is_file()
    }
    contract = {
        "schemaVersion": "1.0",
        "fixtureOnly": True,
        "acceptanceEvidence": False,
        "packageDeclaredMutationCount": EXPECTED_MUTATION_COUNT,
        "authority": {
            "candidateID": first_candidate["id"],
            "candidateReferenceSHA256": first_candidate["referenceSHA256"],
            "candidateDimensions": first_candidate["requiredOutputDimensions"],
            "imageMetricHasResponsiveCandidate": False,
            "responsiveEntryIDs": [entry["id"] for entry in entries],
            "mappingIDs": mappings,
            "sampleImageMappingDisposition": image_mapping["scoreDisposition"],
            "sourceCrop": copy.deepcopy(image_mapping["sourceCrop"]),
            "maskDimensions": [mask_width, mask_height],
            "canonicalScreenLuminanceSSIMMinimum": authority["thresholdProfiles"]
            ["canonical-screen-v1"]["luminanceSSIMMinimum"],
        },
        "templateBoundary": {"templateOnly": True, "acceptanceEvidence": False},
        "referenceBoundary": {
            "controllingGoldenProductionReferences": [],
            "externalReferenceLoads": [],
            "shippingReferenceCopies": [],
            "bypassRenderers": [],
            "candidateReferenceOverlays": [],
        },
        "productionVisual": {
            "sealRenderer": "provider-resource",
            "backgroundRenderer": "theme-resource",
            "relicAspectMode": "aspect-fit",
            "sealAnchorWithinDescriptor": True,
            "highContrastResourcePresent": True,
            "reduceMotionUsesDedicatedResource": True,
            "selectedThemeResourceMatches": True,
            "obsoleteCurrentNorseIDs": [],
            "fallbackFontReportedAsPrimary": False,
            "mixedThemeFrameDuringTransition": False,
        },
        "stateAndArchitecture": {
            "baseNorseAppearsLocked": False,
            "baseNorseOwned": True,
            "baseNorseSelectable": True,
            "baseNorseFallbackAvailable": True,
            "optionalProviderFailureBlocksLaunch": False,
            "directProviderImports": [],
            "encounterOrPreviewGrantsOwnership": False,
            "incomingDecodeRequiresThemeOwnership": False,
            "liveProgressionThemeReconciled": True,
            "runtimeBoundaryValueKind": "contract-or-opaque-resource",
        },
        "responsiveAndAccessibility": {
            "artifactPreview": {"maxY": 780.0, "viewportMaxY": 800.0},
            "mobileHitRegion": {"width": 44.0, "height": 44.0},
            "largeText": {"contentMaxX": 768.0, "viewportMaxX": 768.0},
            "noncolorStateCuePresent": True,
            "reduceMotionActiveThemeAnimationCount": 0,
            "temporalCapture": {
                "frameAPath": "frame-a.png",
                "frameBPath": "frame-b.png",
                "frameASHA256": sha256_bytes(b"v4.3 temporal frame A"),
                "frameBSHA256": sha256_bytes(b"v4.3 temporal frame B"),
                "captureSeparationSeconds": MINIMUM_TEMPORAL_SEPARATION,
            },
            "accessibilityGroup": {
                "componentFrame": [0.0, 0.0, 320.0, 88.0],
                "groupFrame": [0.0, 0.0, 320.0, 88.0],
            },
        },
        "evidence": {
            "sourceSHAAtGeneration": source_sha,
            "currentSourceSHA": source_sha,
            "runtimeProbeInstanceIDs": probes,
            "mappingResultIDs": mappings,
            "authoritySHA256": sha256_file(authority_path),
            "historicalEvidenceSHA256": {
                HISTORICAL_EVIDENCE.as_posix(): sha256_file(historical_path)
            },
            "gateResults": [
                {"gateID": "NEG-001", "result": "FAIL", "failureIDs": ["fixture.failure"]}
            ],
            "openFailureIDs": ["fixture.failure"],
        },
        "publication": {
            "qualificationDriverPath": QUALIFICATION_DRIVER.as_posix(),
            "commands": ["python3 scripts/materialize-theme-fidelity-v43-evidence.py --check-only"],
        },
        "sourceBindings": source_bindings,
    }
    return contract


def mutate_fixture_document(
    document: MutableMapping[str, Any], ordinal: int
) -> str:
    if ordinal == 10:
        document["acceptanceEvidence"] = True
        return "mark the template-only evidence fixture as acceptance evidence"
    if ordinal == 22:
        document["resourceThemeID"] = "moonleaf"
        document["resourceSHA256"] = document["validResources"]["moonleaf"]
        return "substitute a valid Moonleaf resource hash while Norse remains selected"
    if ordinal == 25:
        document["frameThemeIDs"] = [
            document["fromThemeID"],
            document["toThemeID"],
        ]
        return "record both the prior and selected Theme in one transition frame"
    if ordinal == 30:
        document["ownershipGranted"] = True
        return "grant ownership from an Encounter-only progression event"
    if ordinal == 31:
        document["decodeAllowed"] = False
        document["decodeGate"] = "sender-theme-ownership"
        return "deny an otherwise valid incoming decode because the sender Theme is unowned"
    if ordinal == 33:
        document["returnedValueKind"] = "provider-service-object"
        document["providerServiceObjectReturned"] = True
        return "return a provider-owned service object across the runtime boundary"
    if ordinal == 34:
        preview = document["artifactPreview"]
        preview["maxY"] = preview["viewportMaxY"] + 1
        return "move the artifact preview one point below the viewport"
    if ordinal == 35:
        document["mobileHitRegion"] = {"width": 43.0, "height": 43.0}
        return "shrink the required mobile hit region to 43 by 43 points"
    if ordinal == 36:
        large = document["largeText"]
        large["contentMaxX"] = large["viewportMaxX"] + 1
        return "extend large-text content one point beyond the viewport"
    if ordinal == 37:
        document["noncolorStateCuePresent"] = False
        return "remove the noncolor state cue"
    if ordinal == 38:
        document["reduceMotionActiveThemeAnimationCount"] = 1
        return "report one active Theme animation under Reduce Motion"
    if ordinal == 39:
        temporal = document["temporalCapture"]
        temporal["frameBPath"] = temporal["frameAPath"]
        temporal["frameBSHA256"] = temporal["frameASHA256"]
        temporal["captureSeparationSeconds"] = 0.0
        return "reuse the first temporal frame without separated capture time"
    if ordinal == 40:
        document["accessibilityGroup"]["groupFrame"] = [
            -1.0,
            -1.0,
            322.0,
            90.0,
        ]
        return "inflate the grouped accessibility frame beyond the component"
    if ordinal == 41:
        document["currentSourceSHA"] = "f" * 40
        return "change the current source SHA after evidence generation"
    if ordinal == 42:
        document["instanceIDs"].pop()
        return "remove one runtime-probe result instance"
    if ordinal == 43:
        document["mappingIDs"].pop()
        return "remove one mapping result"
    if ordinal == 46:
        document["results"][0]["result"] = "PASS"
        return "mark a gate PASS while its blocking failure remains open"
    raise MutationFailure(f"unsupported executable fixture mutation {ordinal}")


def executable_fixture_documents(
    root: Path, contract: Mapping[str, Any]
) -> dict[Path, dict[str, Any]]:
    fixture_header = {
        "schemaVersion": "1.0",
        "fixtureOnly": True,
        "acceptanceEvidence": False,
    }
    authority = contract["authority"]
    evidence = contract["evidence"]
    norse_sha = sha256_file(root / SAFE_SHIPPING_CANDIDATE)
    moonleaf_sha = sha256_file(root / MOONLEAF_VALID_RESOURCE)
    documents: dict[Path, dict[str, Any]] = {
        TEMPLATE_FIXTURE: {
            **fixture_header,
            "templateOnly": True,
            "result": "FAIL",
        },
        RESOURCE_SELECTION_FIXTURE: {
            **fixture_header,
            "selectedThemeID": "norse",
            "resourceThemeID": "norse",
            "resourceSHA256": norse_sha,
            "validResources": {
                "norse": norse_sha,
                "moonleaf": moonleaf_sha,
            },
        },
        TRANSITION_FIXTURE: {
            **fixture_header,
            "fromThemeID": "norse",
            "toThemeID": "moonleaf",
            "frameThemeIDs": ["moonleaf"],
        },
        PROGRESSION_FIXTURE: {
            **fixture_header,
            "eventKind": "encounter",
            "previewOnly": True,
            "ownershipGranted": False,
        },
        DECODE_FIXTURE: {
            **fixture_header,
            "senderThemeOwned": False,
            "decodeAllowed": True,
            "decodeGate": "cryptographic-and-payload-validity-only",
        },
        RUNTIME_BOUNDARY_FIXTURE: {
            **fixture_header,
            "returnedValueKind": "contract-dto-or-opaque-resource",
            "providerServiceObjectReturned": False,
        },
        LAYOUT_FIXTURE: {
            **fixture_header,
            "artifactPreview": {"maxY": 780.0, "viewportMaxY": 800.0},
            "mobileHitRegion": {"width": 44.0, "height": 44.0},
            "largeText": {"contentMaxX": 768.0, "viewportMaxX": 768.0},
            "noncolorStateCuePresent": True,
            "reduceMotionActiveThemeAnimationCount": 0,
            "temporalCapture": {
                "frameAPath": "frame-a.png",
                "frameBPath": "frame-b.png",
                "frameASHA256": sha256_bytes(b"v4.3 temporal frame A"),
                "frameBSHA256": sha256_bytes(b"v4.3 temporal frame B"),
                "captureSeparationSeconds": MINIMUM_TEMPORAL_SEPARATION,
            },
            "accessibilityGroup": {
                "componentFrame": [0.0, 0.0, 320.0, 88.0],
                "groupFrame": [0.0, 0.0, 320.0, 88.0],
            },
        },
        SOURCE_BOUNDARY_FIXTURE: {
            **fixture_header,
            "sourceSHAAtGeneration": evidence["sourceSHAAtGeneration"],
            "currentSourceSHA": evidence["currentSourceSHA"],
        },
        RUNTIME_PROBE_FIXTURE: {
            **fixture_header,
            "expectedInstanceCount": EXPECTED_RUNTIME_PROBE_INSTANCES,
            "instanceIDs": list(evidence["runtimeProbeInstanceIDs"]),
        },
        MAPPING_RESULTS_FIXTURE: {
            **fixture_header,
            "expectedResultCount": EXPECTED_MAPPING_INSTANCES,
            "mappingIDs": list(evidence["mappingResultIDs"]),
        },
        GATE_RESULTS_FIXTURE: {
            **fixture_header,
            "openFailureIDs": ["fixture.failure"],
            "results": [
                {
                    "gateID": "NEG-001",
                    "result": "FAIL",
                    "failureIDs": ["fixture.failure"],
                }
            ],
        },
    }
    if authority.get("candidateID") is None:
        raise MutationFailure("fixture authority identity is missing")
    definitions_by_ordinal = {item.ordinal: item for item in definitions()}
    for ordinal, relative in FIXTURE_TARGETS.items():
        definition = definitions_by_ordinal[ordinal]
        bound_relative = definition.bound_source_or_evidence_file
        if bound_relative is None:
            raise MutationFailure(
                f"fixture mutation {definition.mutation_id} has no source binding"
            )
        bindings = contract.get("sourceBindings", {})
        bound_sha = bindings.get(bound_relative) if isinstance(bindings, dict) else None
        if not isinstance(bound_sha, str) or not SHA256_PATTERN.fullmatch(bound_sha):
            raise MutationFailure(
                f"fixture mutation {definition.mutation_id} source binding is invalid"
            )
        bound_path = root / bound_relative
        if (
            not bound_path.is_file()
            or bound_path.is_symlink()
            or sha256_file(bound_path) != bound_sha
        ):
            raise MutationFailure(
                f"fixture mutation {definition.mutation_id} bound source/evidence differs"
            )
        documents[relative].setdefault("executableClaims", []).append(
            {
                "mutationID": definition.mutation_id,
                "requirement": definition.requirement,
                "scope": "executable-guard-fixture-only",
                "bindingRole": "context-integrity-only-not-semantic-proof",
                "boundSourceOrEvidenceFile": bound_relative,
                "boundSourceOrEvidenceSHA256": bound_sha,
            }
        )
    return documents


def write_executable_fixtures(
    root: Path, contract: Mapping[str, Any]
) -> None:
    for relative, document in executable_fixture_documents(root, contract).items():
        write_json(root / relative, document)


def add_finding(
    findings: list[Finding], condition: bool, code: str, path: str, message: str
) -> None:
    if not condition:
        findings.append(Finding(code, path, message))


def frame_contains(outer: Sequence[Any], inner: Sequence[Any]) -> bool:
    if len(outer) != 4 or len(inner) != 4:
        return False
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in [*outer, *inner]):
        return False
    ox, oy, ow, oh = [float(value) for value in outer]
    ix, iy, iw, ih = [float(value) for value in inner]
    return (
        ow >= 0
        and oh >= 0
        and iw >= 0
        and ih >= 0
        and ix >= ox
        and iy >= oy
        and ix + iw <= ox + ow
        and iy + ih <= oy + oh
    )


def executable_basename(value: str) -> str:
    return PurePosixPath(value.replace("\\", "/")).name.lower()


def tokens_have_forbidden_publication_operation(tokens: Sequence[str]) -> bool:
    lowered = [token.lower() for token in tokens]
    names = [executable_basename(token) for token in lowered]
    for index, name in enumerate(names):
        tail = lowered[index + 1 :]
        if name == "git" and any(
            token in {"merge", "tag", "archive"} for token in tail
        ):
            return True
        if name == "gh" and "release" in tail:
            return True
        if name in {"notarytool", "altool"}:
            return True
    return any(
        token in {"notarize", "notarization", "upload", "release"}
        for token in lowered
    )


def literal_command_tokens(
    value: ast.AST, constants: Mapping[str, Any]
) -> list[str] | None:
    if isinstance(value, ast.Name):
        literal = constants.get(value.id)
    else:
        try:
            literal = ast.literal_eval(value)
        except (ValueError, TypeError):
            return None
    if isinstance(literal, str):
        try:
            return shlex.split(literal)
        except ValueError:
            return literal.split()
    if isinstance(literal, (list, tuple)) and all(
        isinstance(item, str) for item in literal
    ):
        return list(literal)
    return None


def forbidden_publication_operations(source: str) -> list[str]:
    operations: list[str] = []
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return ["qualification driver is not valid Python"]

    subprocess_aliases = {"subprocess"}
    os_aliases = {"os"}
    process_functions: set[str] = set()
    shell_functions: set[str] = set()
    constants: dict[str, Any] = {}
    nodes = list(ast.walk(tree))
    for node in nodes:
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == "subprocess":
                    subprocess_aliases.add(alias.asname or alias.name)
                elif alias.name == "os":
                    os_aliases.add(alias.asname or alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module == "subprocess":
                for alias in node.names:
                    if alias.name in {
                        "run", "call", "check_call", "check_output", "Popen"
                    }:
                        process_functions.add(alias.asname or alias.name)
            elif node.module == "os":
                for alias in node.names:
                    if alias.name in {"system", "popen"}:
                        shell_functions.add(alias.asname or alias.name)
    for node in nodes:
        if (
            isinstance(node, (ast.Assign, ast.AnnAssign))
            and (
                isinstance(node.target, ast.Name)
                if isinstance(node, ast.AnnAssign)
                else len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
            )
        ):
            target = node.target if isinstance(node, ast.AnnAssign) else node.targets[0]
            value = node.value
            if value is not None:
                if isinstance(value, ast.Attribute) and isinstance(value.value, ast.Name):
                    if (
                        value.value.id in subprocess_aliases
                        and value.attr
                        in {"run", "call", "check_call", "check_output", "Popen"}
                    ):
                        process_functions.add(target.id)
                    elif (
                        value.value.id in os_aliases
                        and value.attr in {"system", "popen"}
                    ):
                        shell_functions.add(target.id)
                try:
                    constants[target.id] = ast.literal_eval(value)
                except (ValueError, TypeError):
                    pass

    for node in nodes:
        if not isinstance(node, ast.Call):
            continue
        function = node.func
        is_process_call = False
        if isinstance(function, ast.Attribute) and isinstance(function.value, ast.Name):
            owner = function.value.id
            is_process_call = (
                owner in subprocess_aliases
                and function.attr
                in {"run", "call", "check_call", "check_output", "Popen"}
            ) or (owner in os_aliases and function.attr in {"system", "popen"})
        elif isinstance(function, ast.Name):
            is_process_call = (
                function.id in process_functions or function.id in shell_functions
            )
        if not is_process_call:
            continue
        command_value = node.args[0] if node.args else next(
            (
                keyword.value
                for keyword in node.keywords
                if keyword.arg in {"args", "command", "cmd"}
            ),
            None,
        )
        if command_value is None:
            operations.append("process command is missing or cannot be qualified")
            continue
        tokens = literal_command_tokens(command_value, constants)
        if tokens is None:
            operations.append("dynamic process command cannot be qualified")
            continue
        lowered = [token.lower() for token in tokens]
        if tokens_have_forbidden_publication_operation(lowered):
            operations.append(" ".join(lowered))
    return sorted(set(operations))


def command_has_forbidden_publication_operation(command: str) -> bool:
    try:
        tokens = [token.lower() for token in shlex.split(command)]
    except ValueError:
        tokens = command.lower().split()
    return tokens_have_forbidden_publication_operation(tokens)


def guard_contract(root: Path, contract: Mapping[str, Any]) -> list[Finding]:
    findings: list[Finding] = []
    try:
        authority = load_json(root / COMPARISON_RELATIVE)
        canonical = load_json(root / CANONICAL_RELATIVE)
        first_candidate = canonical["candidates"][0]
        expected_entries = [entry["id"] for entry in authority["entries"]]
        expected_mappings = mapping_inventory(authority)
        expected_probes = probe_inventory(authority)
        image_mapping = next(
            mapping
            for entry in authority["entries"]
            for mapping in entry["referenceMappings"]
            if mapping.get("scoreDisposition") == "image-metric"
        )
        mask_dimensions = list(png_dimensions(root / MASK_RELATIVE))
    except (OSError, KeyError, TypeError, ValueError, StopIteration, json.JSONDecodeError) as error:
        return [Finding("V43M-000-BASELINE", "authority", f"cannot load baseline: {error}")]

    add_finding(findings, contract.get("schemaVersion") == "1.0", "V43M-000-SCHEMA", "contract", "fixture schema must be 1.0")
    add_finding(findings, contract.get("fixtureOnly") is True and contract.get("acceptanceEvidence") is False, "V43M-000-NON-ACCEPTANCE", "contract", "mutation contract must remain fixture-only and non-acceptance")
    add_finding(findings, contract.get("packageDeclaredMutationCount") == EXPECTED_MUTATION_COUNT, "V43M-000-COUNT", "contract", "package-declared mutation count must remain 47")

    authority_state = contract.get("authority", {})
    add_finding(findings, authority_state.get("candidateReferenceSHA256") == first_candidate["referenceSHA256"], "V43M-001-CANDIDATE-REFERENCE", "authority.candidateReferenceSHA256", "canonical candidate reference SHA differs")
    add_finding(findings, authority_state.get("candidateDimensions") == first_candidate["requiredOutputDimensions"], "V43M-002-CANDIDATE-DIMENSIONS", "authority.candidateDimensions", "canonical candidate dimensions differ")
    add_finding(findings, authority_state.get("imageMetricHasResponsiveCandidate") is False, "V43M-003-RESPONSIVE-CANDIDATE", "authority.imageMetricHasResponsiveCandidate", "image-metric mapping retains a responsive candidate")
    add_finding(findings, authority_state.get("responsiveEntryIDs") == expected_entries and len(expected_entries) == EXPECTED_RESPONSIVE_ENTRIES, "V43M-004-AUTHORITY-ENTRY", "authority.responsiveEntryIDs", "responsive authority entry set differs")
    actual_mapping_ids = authority_state.get("mappingIDs")
    add_finding(findings, isinstance(actual_mapping_ids, list) and actual_mapping_ids == expected_mappings and len(actual_mapping_ids) == len(set(actual_mapping_ids)), "V43M-005-MAPPING-ID", "authority.mappingIDs", "mapping IDs are missing, reordered, or duplicated")
    add_finding(findings, authority_state.get("sampleImageMappingDisposition") == "image-metric", "V43M-006-MAPPING-DISPOSITION", "authority.sampleImageMappingDisposition", "image mapping was changed to structural-only")
    add_finding(findings, authority_state.get("sourceCrop") == image_mapping["sourceCrop"], "V43M-007-NORMALIZATION", "authority.sourceCrop", "undeclared crop or resize was introduced")
    add_finding(findings, authority_state.get("maskDimensions") == mask_dimensions, "V43M-008-SYSTEM-CHROME-MASK", "authority.maskDimensions", "system-chrome mask dimensions differ")
    expected_threshold = authority["thresholdProfiles"]["canonical-screen-v1"]["luminanceSSIMMinimum"]
    add_finding(findings, authority_state.get("canonicalScreenLuminanceSSIMMinimum") == expected_threshold, "V43M-009-THRESHOLD", "authority.canonicalScreenLuminanceSSIMMinimum", "comparison threshold differs")

    template = contract.get("templateBoundary", {})
    add_finding(findings, template.get("templateOnly") is True and template.get("acceptanceEvidence") is False, CONTRACT_CODES[10], "templateBoundary", "template was promoted to acceptance evidence")
    reference = contract.get("referenceBoundary", {})
    reference_rules = (
        (11, "controllingGoldenProductionReferences", "production source names a controlling golden"),
        (12, "externalReferenceLoads", "canonical harness loads a reference from an external path"),
        (13, "shippingReferenceCopies", "shipping resources contain a copied reference"),
        (14, "bypassRenderers", "test-only renderer bypasses production composition"),
        (15, "candidateReferenceOverlays", "candidate is overlaid with a reference"),
    )
    for ordinal, key, message in reference_rules:
        add_finding(findings, reference.get(key) == [], CONTRACT_CODES[ordinal], f"referenceBoundary.{key}", message)

    visual = contract.get("productionVisual", {})
    visual_rules = (
        (16, "sealRenderer", "provider-resource", "approved Seal renderer was replaced"),
        (17, "backgroundRenderer", "theme-resource", "Theme background was replaced"),
        (18, "relicAspectMode", "aspect-fit", "Relic aspect ratio is not preserved"),
        (19, "sealAnchorWithinDescriptor", True, "Seal lies outside descriptor anchors"),
        (20, "highContrastResourcePresent", True, "High Contrast resource is missing"),
        (21, "reduceMotionUsesDedicatedResource", True, "Reduce Motion uses the standard resource"),
        (22, "selectedThemeResourceMatches", True, "resource identity belongs to the wrong Theme"),
        (23, "obsoleteCurrentNorseIDs", [], "obsolete Norse content is current"),
        (24, "fallbackFontReportedAsPrimary", False, "fallback font is reported as the primary Script"),
        (25, "mixedThemeFrameDuringTransition", False, "selection transition contains a mixed-Theme frame"),
    )
    for ordinal, key, expected, message in visual_rules:
        add_finding(findings, visual.get(key) == expected, CONTRACT_CODES[ordinal], f"productionVisual.{key}", message)

    state = contract.get("stateAndArchitecture", {})
    state_rules = (
        (26, "baseNorseAppearsLocked", False, "Norse appears locked"),
        (27, "baseNorseOwned", True, "Norse ownership is missing"),
        (27, "baseNorseFallbackAvailable", True, "Norse fallback is unavailable"),
        (28, "optionalProviderFailureBlocksLaunch", False, "optional provider failure blocks launch"),
        (29, "directProviderImports", [], "production UI imports a Theme provider"),
        (30, "encounterOrPreviewGrantsOwnership", False, "Encounter or preview granted ownership"),
        (31, "incomingDecodeRequiresThemeOwnership", False, "incoming decode is gated on Theme ownership"),
        (32, "liveProgressionThemeReconciled", True, "live progression is not reconciled into Theme state"),
        (33, "runtimeBoundaryValueKind", "contract-or-opaque-resource", "provider service object crossed runtime boundary"),
    )
    for ordinal, key, expected, message in state_rules:
        add_finding(findings, state.get(key) == expected, CONTRACT_CODES[ordinal], f"stateAndArchitecture.{key}", message)

    responsive = contract.get("responsiveAndAccessibility", {})
    preview = responsive.get("artifactPreview", {})
    add_finding(findings, isinstance(preview.get("maxY"), (int, float)) and isinstance(preview.get("viewportMaxY"), (int, float)) and preview["maxY"] <= preview["viewportMaxY"], CONTRACT_CODES[34], "responsiveAndAccessibility.artifactPreview", "artifact preview extends below viewport")
    hit = responsive.get("mobileHitRegion", {})
    add_finding(findings, isinstance(hit.get("width"), (int, float)) and isinstance(hit.get("height"), (int, float)) and hit["width"] >= MINIMUM_HIT_REGION and hit["height"] >= MINIMUM_HIT_REGION, CONTRACT_CODES[35], "responsiveAndAccessibility.mobileHitRegion", "mobile hit region is below 44 by 44 points")
    large = responsive.get("largeText", {})
    add_finding(findings, isinstance(large.get("contentMaxX"), (int, float)) and isinstance(large.get("viewportMaxX"), (int, float)) and large["contentMaxX"] <= large["viewportMaxX"], CONTRACT_CODES[36], "responsiveAndAccessibility.largeText", "large-text content overflows horizontally")
    add_finding(findings, responsive.get("noncolorStateCuePresent") is True, CONTRACT_CODES[37], "responsiveAndAccessibility.noncolorStateCuePresent", "owned, selected, or locked state lacks a noncolor cue")
    add_finding(findings, responsive.get("reduceMotionActiveThemeAnimationCount") == 0, CONTRACT_CODES[38], "responsiveAndAccessibility.reduceMotionActiveThemeAnimationCount", "Reduce Motion reports an active Theme animation")
    temporal = responsive.get("temporalCapture", {})
    temporal_ok = (
        temporal.get("frameAPath") != temporal.get("frameBPath")
        and temporal.get("frameASHA256") != temporal.get("frameBSHA256")
        and isinstance(temporal.get("captureSeparationSeconds"), (int, float))
        and temporal["captureSeparationSeconds"] >= MINIMUM_TEMPORAL_SEPARATION
    )
    add_finding(findings, temporal_ok, CONTRACT_CODES[39], "responsiveAndAccessibility.temporalCapture", "temporal captures are not distinct and separated")
    group = responsive.get("accessibilityGroup", {})
    add_finding(findings, frame_contains(group.get("componentFrame", []), group.get("groupFrame", [])), CONTRACT_CODES[40], "responsiveAndAccessibility.accessibilityGroup", "grouped accessibility frame exceeds its component")

    evidence = contract.get("evidence", {})
    add_finding(findings, evidence.get("sourceSHAAtGeneration") == evidence.get("currentSourceSHA"), CONTRACT_CODES[41], "evidence.sourceSHA", "source changed after evidence generation")
    actual_probe_ids = evidence.get("runtimeProbeInstanceIDs")
    add_finding(findings, isinstance(actual_probe_ids, list) and actual_probe_ids == expected_probes and len(actual_probe_ids) == EXPECTED_RUNTIME_PROBE_INSTANCES, CONTRACT_CODES[42], "evidence.runtimeProbeInstanceIDs", "runtime-probe instance set differs")
    actual_result_ids = evidence.get("mappingResultIDs")
    add_finding(findings, isinstance(actual_result_ids, list) and actual_result_ids == expected_mappings and len(actual_result_ids) == EXPECTED_MAPPING_INSTANCES, CONTRACT_CODES[43], "evidence.mappingResultIDs", "mapping result set differs")
    add_finding(findings, evidence.get("authoritySHA256") == sha256_file(root / COMPARISON_RELATIVE), CONTRACT_CODES[44], "evidence.authoritySHA256", "final evidence points to a different authority hash")
    historical = evidence.get("historicalEvidenceSHA256", {})
    historical_ok = isinstance(historical, dict) and bool(historical)
    if historical_ok:
        for relative, expected in historical.items():
            path = root / relative
            if not path.is_file() or sha256_file(path) != expected:
                historical_ok = False
                break
    add_finding(findings, historical_ok, CONTRACT_CODES[45], "evidence.historicalEvidenceSHA256", "historical evidence bytes changed")
    open_failures = set(evidence.get("openFailureIDs", []))
    failed_gate_promoted = any(
        item.get("result") == "PASS" and open_failures.intersection(item.get("failureIDs", []))
        for item in evidence.get("gateResults", [])
        if isinstance(item, dict)
    )
    add_finding(findings, not failed_gate_promoted, CONTRACT_CODES[46], "evidence.gateResults", "gate with an open failure was marked PASS")

    publication = contract.get("publication", {})
    commands = publication.get("commands", [])
    prohibited = [command for command in commands if isinstance(command, str) and command_has_forbidden_publication_operation(command)]
    driver_relative = publication.get("qualificationDriverPath")
    if isinstance(driver_relative, str):
        driver_path = root / driver_relative
        if driver_path.is_file():
            prohibited.extend(forbidden_publication_operations(driver_path.read_text(encoding="utf-8")))
        else:
            prohibited.append("qualification driver missing")
    else:
        prohibited.append("qualification driver path invalid")
    add_finding(findings, not prohibited, CONTRACT_CODES[47], "publication", "qualification tooling contains a prohibited publication operation: " + ", ".join(sorted(set(prohibited))))

    bindings = contract.get("sourceBindings", {})
    if not isinstance(bindings, dict) or not bindings:
        findings.append(Finding("V43M-000-SOURCE-BINDING", "sourceBindings", "source bindings are missing"))
    else:
        for relative, expected in sorted(bindings.items()):
            path = root / relative
            if not path.is_file() or not isinstance(expected, str) or sha256_file(path) != expected:
                findings.append(Finding("V43M-000-SOURCE-BINDING", relative, "source-bound fixture file differs"))
    return sorted(set(findings), key=lambda item: (item.code, item.path, item.message))


def guard_payload(root: Path, fixture_path: Path) -> dict[str, Any]:
    try:
        contract = load_json(fixture_path)
        if not isinstance(contract, dict):
            raise MutationFailure("contract root must be an object")
        findings = guard_contract(root, contract)
    except (OSError, UnicodeError, json.JSONDecodeError, MutationFailure) as error:
        findings = [Finding("V43M-000-FIXTURE", str(fixture_path), str(error))]
    return {
        "schemaVersion": "1.0",
        "fixtureOnly": True,
        "acceptanceEvidence": False,
        "result": "PASS" if not findings else "FAIL",
        "findingCount": len(findings),
        "findings": [asdict(finding) for finding in findings],
    }


def case_findings(
    root: Path, contract: Mapping[str, Any], ordinal: int
) -> list[Finding]:
    if ordinal not in CONTRACT_CODES:
        return [Finding("V43M-000-CASE", str(ordinal), "case guard ordinal is invalid")]
    code = CONTRACT_CODES[ordinal]
    definition = definitions()[ordinal - 1]
    target = Path(definition.source_or_authority_file)
    findings: list[Finding] = []

    if ordinal in TEXT_MUTATIONS:
        spec = TEXT_MUTATIONS[ordinal]
        try:
            source = (root / spec.relative).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            return [Finding("V43M-000-CASE-BASELINE", spec.relative.as_posix(), str(error))]
        before_count = source.count(spec.before)
        after_count = source.count(spec.after)
        if before_count == 0 and after_count == 1:
            findings.append(Finding(code, spec.relative.as_posix(), spec.detail))
        elif before_count != 1 or after_count != 0:
            findings.append(
                Finding(
                    "V43M-000-CASE-BASELINE",
                    spec.relative.as_posix(),
                    f"semantic anchor cardinality is before={before_count}, after={after_count}",
                )
            )
        return findings

    if ordinal in FIXTURE_TARGETS:
        relative = FIXTURE_TARGETS[ordinal]
        try:
            document = load_json(root / relative)
            if not isinstance(document, dict):
                raise MutationFailure("executable fixture root must be an object")
            baseline = executable_fixture_documents(root, contract)[relative]
            mutated = copy.deepcopy(baseline)
            mutation_detail = mutate_fixture_document(mutated, ordinal)
        except (
            OSError,
            UnicodeError,
            KeyError,
            TypeError,
            ValueError,
            json.JSONDecodeError,
            MutationFailure,
        ) as error:
            return [
                Finding(
                    "V43M-000-CASE-BASELINE",
                    target.as_posix(),
                    str(error),
                )
            ]
        if document == mutated:
            findings.append(Finding(code, target.as_posix(), mutation_detail))
        elif document != baseline:
            findings.append(
                Finding(
                    "V43M-000-CASE-BASELINE",
                    target.as_posix(),
                    "executable fixture differs from both its exact positive and declared negative states",
                )
            )
        return findings

    try:
        if ordinal == 20:
            path = root / target
            if not path.exists():
                findings.append(Finding(code, target.as_posix(), "required High Contrast resource is missing"))
            elif not path.is_file() or path.is_symlink():
                findings.append(Finding("V43M-000-CASE-BASELINE", target.as_posix(), "High Contrast resource is not a regular file"))
        elif ordinal == 44:
            document = load_json(root / target)
            observed = document.get("authoritySHA256") if isinstance(document, dict) else None
            expected = sha256_file(root / COMPARISON_RELATIVE)
            if isinstance(observed, str) and SHA256_PATTERN.fullmatch(observed) and observed != expected:
                findings.append(Finding(code, target.as_posix(), "final evidence points to a different authority hash"))
            elif observed != expected:
                findings.append(Finding("V43M-000-CASE-BASELINE", target.as_posix(), "final evidence authority hash is invalid"))
        elif ordinal == 45:
            historical = contract.get("evidence", {}).get("historicalEvidenceSHA256", {})
            expected = historical.get(HISTORICAL_EVIDENCE.as_posix()) if isinstance(historical, dict) else None
            actual = sha256_file(root / HISTORICAL_EVIDENCE)
            if not isinstance(expected, str) or not SHA256_PATTERN.fullmatch(expected):
                findings.append(Finding("V43M-000-CASE-BASELINE", target.as_posix(), "historical evidence binding is invalid"))
            elif actual != expected:
                findings.append(Finding(code, target.as_posix(), "historical evidence bytes changed"))
        elif ordinal == 47:
            source = (root / QUALIFICATION_DRIVER).read_text(encoding="utf-8")
            prohibited = forbidden_publication_operations(source)
            if prohibited:
                findings.append(Finding(code, target.as_posix(), "; ".join(prohibited)))
    except (OSError, UnicodeError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        findings.append(Finding("V43M-000-CASE-BASELINE", target.as_posix(), str(error)))
    return findings


def guard_case_payload(
    root: Path, fixture_path: Path, mutation_id: str
) -> dict[str, Any]:
    try:
        selected = selected_definitions([mutation_id])
        definition = selected[0]
        if definition.ordinal <= 9 or definition.ordinal == 13:
            raise MutationFailure("case guard does not own this mutation")
        contract = load_json(fixture_path)
        if not isinstance(contract, dict):
            raise MutationFailure("contract root must be an object")
        findings = case_findings(root, contract, definition.ordinal)
    except (OSError, UnicodeError, json.JSONDecodeError, MutationFailure) as error:
        findings = [Finding("V43M-000-CASE", mutation_id, str(error))]
    return {
        "schemaVersion": "1.0",
        "fixtureOnly": True,
        "acceptanceEvidence": False,
        "mutationID": mutation_id,
        "result": "PASS" if not findings else "FAIL",
        "findingCount": len(findings),
        "findings": [asdict(finding) for finding in findings],
    }


def set_path(document: MutableMapping[str, Any], path: Sequence[str], value: Any) -> None:
    current: MutableMapping[str, Any] = document
    for key in path[:-1]:
        child = current.get(key)
        if not isinstance(child, dict):
            raise MutationFailure(f"contract mutation path is invalid: {'.'.join(path)}")
        current = child
    current[path[-1]] = value


def mutate_contract(document: MutableMapping[str, Any], ordinal: int) -> str:
    authority = document["authority"]
    reference = document["referenceBoundary"]
    visual = document["productionVisual"]
    state = document["stateAndArchitecture"]
    responsive = document["responsiveAndAccessibility"]
    evidence = document["evidence"]
    publication = document["publication"]
    if ordinal == 1:
        authority["candidateReferenceSHA256"] = "f" * 64
        return "set the canonical candidate reference SHA to a second identity"
    if ordinal == 2:
        authority["candidateDimensions"][0] += 1
        return "increase the canonical candidate required width by one pixel"
    if ordinal == 3:
        authority["imageMetricHasResponsiveCandidate"] = True
        return "add candidateElementID semantics to an image-metric mapping"
    if ordinal == 4:
        authority["responsiveEntryIDs"].pop()
        return "remove one responsive authority entry"
    if ordinal == 5:
        authority["mappingIDs"][-1] = authority["mappingIDs"][0]
        return "replace one mapping ID with a duplicate of the first mapping ID"
    if ordinal == 6:
        authority["sampleImageMappingDisposition"] = "structural-assertion"
        return "change an image-metric mapping disposition to structural-assertion"
    if ordinal == 7:
        authority["sourceCrop"] = {
            "mode": "normalized-subrect",
            "normalizedRect": {"x": 0.0, "y": 0.0, "width": 1.0, "height": 0.9},
            "manualCoordinatesAllowed": True,
        }
        return "introduce an undeclared normalized crop before comparison"
    if ordinal == 8:
        authority["maskDimensions"][1] += 1
        return "increase the system-chrome mask height by one product-content row"
    if ordinal == 9:
        authority["canonicalScreenLuminanceSSIMMinimum"] -= 0.01
        return "lower the canonical-screen luminance SSIM minimum by 0.01"
    if ordinal == 10:
        document["templateBoundary"] = {"templateOnly": False, "acceptanceEvidence": True}
        return "promote a template record to acceptance evidence"
    if ordinal == 11:
        reference["controllingGoldenProductionReferences"].append("moonleaf-compose-final-a.png")
        return "add a controlling-golden filename to production source bindings"
    if ordinal == 12:
        reference["externalReferenceLoads"].append("/tmp/moonleaf-compose-final-a.png")
        return "load an external reference PNG from the canonical harness"
    if ordinal == 13:
        reference["shippingReferenceCopies"].append(BOUNDARY_INJECTED_RELATIVE.as_posix())
        return "copy protected reference bytes into a new shipping resource name"
    if ordinal == 14:
        reference["bypassRenderers"].append("ThemeFidelityBypassRenderer")
        return "add a test-only renderer outside the production composition policy"
    if ordinal == 15:
        reference["candidateReferenceOverlays"].append({"opacity": 0.5})
        return "overlay a candidate with reference pixels at 50 percent opacity"
    if ordinal == 16:
        visual["sealRenderer"] = "system-symbol"
        return "replace the provider Seal resource with a system symbol"
    if ordinal == 17:
        visual["backgroundRenderer"] = "generic-gradient"
        return "replace the Theme background with a generic gradient"
    if ordinal == 18:
        visual["relicAspectMode"] = "nonuniform-stretch"
        return "stretch the Relic without preserving aspect ratio"
    if ordinal == 19:
        visual["sealAnchorWithinDescriptor"] = False
        return "move the Seal beyond descriptor-approved anchor bounds"
    if ordinal == 20:
        visual["highContrastResourcePresent"] = False
        return "remove the High Contrast resource binding"
    if ordinal == 21:
        visual["reduceMotionUsesDedicatedResource"] = False
        return "resolve the standard resource while Reduce Motion is active"
    if ordinal == 22:
        visual["selectedThemeResourceMatches"] = False
        return "bind a valid resource hash owned by a different Theme"
    if ordinal == 23:
        visual["obsoleteCurrentNorseIDs"].append("relic.norse.forge-master")
        return "reintroduce an obsolete Norse content ID as current"
    if ordinal == 24:
        visual["fallbackFontReportedAsPrimary"] = True
        return "report the primary Script while rendering a fallback font"
    if ordinal == 25:
        visual["mixedThemeFrameDuringTransition"] = True
        return "publish a transition frame containing two Theme identities"
    if ordinal == 26:
        state["baseNorseAppearsLocked"] = True
        return "report required-base Norse as locked"
    if ordinal == 27:
        state["baseNorseFallbackAvailable"] = False
        return "remove required-base Norse fallback availability"
    if ordinal == 28:
        state["optionalProviderFailureBlocksLaunch"] = True
        return "make an optional provider failure block launch"
    if ordinal == 29:
        state["directProviderImports"].append("RuneScribeNorseThemeModule")
        return "add a direct Theme-provider import to production UI"
    if ordinal == 30:
        state["encounterOrPreviewGrantsOwnership"] = True
        return "grant ownership from Encounter or preview state"
    if ordinal == 31:
        state["incomingDecodeRequiresThemeOwnership"] = True
        return "require Theme ownership before incoming decode"
    if ordinal == 32:
        state["liveProgressionThemeReconciled"] = False
        return "drop live progression-to-Theme reconciliation"
    if ordinal == 33:
        state["runtimeBoundaryValueKind"] = "provider-service-object"
        return "return a provider-owned service object across the runtime boundary"
    if ordinal == 34:
        responsive["artifactPreview"]["maxY"] = responsive["artifactPreview"]["viewportMaxY"] + 1
        return "move the artifact preview one point below the viewport"
    if ordinal == 35:
        responsive["mobileHitRegion"] = {"width": 43.0, "height": 43.0}
        return "shrink a required mobile hit region to 43 by 43 points"
    if ordinal == 36:
        responsive["largeText"]["contentMaxX"] = responsive["largeText"]["viewportMaxX"] + 1
        return "extend large-text content one point beyond the viewport"
    if ordinal == 37:
        responsive["noncolorStateCuePresent"] = False
        return "remove the noncolor state cue"
    if ordinal == 38:
        responsive["reduceMotionActiveThemeAnimationCount"] = 1
        return "report one active Theme animation under Reduce Motion"
    if ordinal == 39:
        temporal = responsive["temporalCapture"]
        temporal["frameBPath"] = temporal["frameAPath"]
        temporal["frameBSHA256"] = temporal["frameASHA256"]
        temporal["captureSeparationSeconds"] = 0.0
        return "reuse the first temporal frame without separated capture time"
    if ordinal == 40:
        responsive["accessibilityGroup"]["groupFrame"] = [-1.0, -1.0, 322.0, 90.0]
        return "inflate the grouped accessibility frame beyond the component"
    if ordinal == 41:
        evidence["currentSourceSHA"] = "f" * 40
        return "change the current source SHA after evidence generation"
    if ordinal == 42:
        evidence["runtimeProbeInstanceIDs"].pop()
        return "remove one runtime-probe result instance"
    if ordinal == 43:
        evidence["mappingResultIDs"].pop()
        return "remove one mapping result"
    if ordinal == 44:
        evidence["authoritySHA256"] = "f" * 64
        return "point final evidence at a different authority hash"
    if ordinal == 45:
        key = next(iter(evidence["historicalEvidenceSHA256"]))
        evidence["historicalEvidenceSHA256"][key] = "f" * 64
        return "rewrite the bound historical evidence identity"
    if ordinal == 46:
        evidence["gateResults"][0]["result"] = "PASS"
        return "mark a gate PASS while its blocking failure remains open"
    if ordinal == 47:
        publication["commands"].append("git tag v4.3")
        return "add a prohibited git tag operation to qualification commands"
    raise MutationFailure(f"unknown mutation ordinal: {ordinal}")


def mutate_json_file(path: Path, mutation: Callable[[MutableMapping[str, Any]], str]) -> str:
    document = load_json(path)
    if not isinstance(document, dict):
        raise MutationFailure(f"JSON mutation target is not an object: {path}")
    detail = mutation(document)
    write_json(path, document)
    return detail


def authority_mutation(root: Path, ordinal: int) -> tuple[list[Path], str]:
    if ordinal in {1, 2}:
        target = root / CANONICAL_RELATIVE

        def mutate(document: MutableMapping[str, Any]) -> str:
            candidates = document.get("candidates")
            if not isinstance(candidates, list) or len(candidates) < 2:
                raise MutationFailure("canonical candidate baseline is unavailable")
            if ordinal == 1:
                candidates[0]["referenceSHA256"] = candidates[1]["referenceSHA256"]
                return (
                    f"map {candidates[0]['id']} to reference SHA "
                    f"{candidates[1]['referenceSHA256']} owned by {candidates[1]['id']}"
                )
            dimensions = candidates[0].get("requiredOutputDimensions")
            if not isinstance(dimensions, list) or len(dimensions) != 2:
                raise MutationFailure("canonical dimension baseline is unavailable")
            dimensions[0] += 1
            return f"increase {candidates[0]['id']} required width by one pixel"

        return [target], mutate_json_file(target, mutate)

    if ordinal == 8:
        target = root / MASK_RELATIVE
        width, height = png_dimensions(target)
        output = target.with_name(target.name + ".expanded.png")
        command = [
            "ffmpeg", "-v", "error", "-y", "-i", str(target),
            "-vf", "pad=iw:ih+1:0:0:color=black@0", "-frames:v", "1",
            "-pix_fmt", "rgba", str(output),
        ]
        result = run_command(command, cwd=root, timeout=120)
        if result.exit_status != 0 or not output.is_file():
            raise MutationFailure(
                "unable to create the one-row mask mutation: "
                + (result.stderr or result.stdout).strip()
            )
        try:
            if png_dimensions(output) != (width, height + 1):
                raise MutationFailure("expanded mask dimensions are not exact")
            atomic_write(target, output.read_bytes())
        finally:
            if output.exists():
                output.unlink()
        return [target], f"increase mask dimensions from {width}x{height} to {width}x{height + 1}"

    target = root / COMPARISON_RELATIVE

    def mutate(document: MutableMapping[str, Any]) -> str:
        entries = document.get("entries")
        if not isinstance(entries, list) or len(entries) != EXPECTED_RESPONSIVE_ENTRIES:
            raise MutationFailure("responsive authority baseline is unavailable")
        mappings = [
            mapping
            for entry in entries
            for mapping in entry.get("referenceMappings", [])
            if isinstance(mapping, dict)
        ]
        image_mappings = [
            mapping for mapping in mappings if mapping.get("scoreDisposition") == "image-metric"
        ]
        if not image_mappings:
            raise MutationFailure("image-metric mapping baseline is unavailable")
        sample = image_mappings[0]
        if ordinal == 3:
            former = sample.get("v42FormerCandidateBinding", {})
            sample["candidateElementID"] = former.get("id", "workspace.primary-surface")
            return f"add candidateElementID to image mapping {sample.get('mappingID')}"
        if ordinal == 4:
            removed = entries.pop()
            return f"remove responsive authority entry {removed.get('id')}"
        if ordinal == 5:
            if len(mappings) < 2:
                raise MutationFailure("mapping baseline has fewer than two records")
            original = mappings[1].get("mappingID")
            mappings[1]["mappingID"] = mappings[0].get("mappingID")
            return f"replace mapping ID {original} with duplicate {mappings[0].get('mappingID')}"
        if ordinal == 6:
            sample["scoreDisposition"] = "structural-assertion"
            return f"change {sample.get('mappingID')} from image-metric to structural-assertion"
        if ordinal == 7:
            sample["sourceCrop"] = {
                "mode": "normalized-subrect",
                "normalizedRect": {"x": 0.0, "y": 0.0, "width": 1.0, "height": 0.9},
                "manualCoordinatesAllowed": True,
            }
            return f"introduce a 90 percent-height crop in {sample.get('mappingID')}"
        if ordinal == 9:
            profile = document["thresholdProfiles"]["canonical-screen-v1"]
            prior = profile["luminanceSSIMMinimum"]
            profile["luminanceSSIMMinimum"] = round(float(prior) - 0.01, 6)
            return f"lower canonical-screen luminance SSIM minimum from {prior} to {profile['luminanceSSIMMinimum']}"
        raise MutationFailure(f"unsupported authority mutation {ordinal}")

    return [target], mutate_json_file(target, mutate)


def apply_contract_mutation(root: Path, ordinal: int) -> tuple[list[Path], str]:
    target = root / CONTRACT_RELATIVE

    def mutate(document: MutableMapping[str, Any]) -> str:
        return mutate_contract(document, ordinal)

    return [target], mutate_json_file(target, mutate)


def apply_text_mutation(root: Path, ordinal: int) -> tuple[list[Path], str]:
    spec = TEXT_MUTATIONS[ordinal]
    target = root / spec.relative
    source = target.read_text(encoding="utf-8")
    before_count = source.count(spec.before)
    after_count = source.count(spec.after)
    if before_count != 1 or after_count != 0:
        raise MutationFailure(
            f"mutation {ordinal} semantic anchor cardinality is "
            f"before={before_count}, after={after_count}"
        )
    atomic_write(target, source.replace(spec.before, spec.after, 1).encode("utf-8"))
    return [target], spec.detail


def apply_fixture_mutation(root: Path, ordinal: int) -> tuple[list[Path], str]:
    relative = FIXTURE_TARGETS[ordinal]
    target = root / relative

    def mutate(document: MutableMapping[str, Any]) -> str:
        return mutate_fixture_document(document, ordinal)

    return [target], mutate_json_file(target, mutate)


def apply_case_20_mutation(root: Path) -> tuple[list[Path], str]:
    target = root / Path(SOURCE_FILES[20])
    if not target.is_file() or target.is_symlink():
        raise MutationFailure("required High Contrast resource baseline is unavailable")
    target.unlink()
    return [target], "remove the required Norse High Contrast Script specimen resource"


def apply_case_44_mutation(root: Path) -> tuple[list[Path], str]:
    target = root / Path(SOURCE_FILES[44])

    def mutate(document: MutableMapping[str, Any]) -> str:
        document["authoritySHA256"] = "f" * 64
        return "point final evidence to an authority SHA that differs from the imported authority"

    return [target], mutate_json_file(target, mutate)


def protected_reference(package_root: Path) -> Path:
    manifest = load_json(package_root / PACKAGE_ASSET_MANIFEST)
    assets = manifest.get("assets", []) if isinstance(manifest, dict) else []
    protected_markers = (
        "authoritative", "controlling", "reference", "supporting", "secondary", "rejected"
    )
    for item in assets:
        if not isinstance(item, dict):
            continue
        authority = str(item.get("authority", "")).lower()
        logical = item.get("path")
        if not isinstance(logical, str) or not any(marker in authority for marker in protected_markers):
            continue
        path = package_root / Path(*PurePosixPath(logical).parts)
        if path.is_file() and path.suffix.lower() == ".png":
            return path
    raise MutationFailure("authority package has no protected PNG for mutation 13")


def apply_boundary_mutation(root: Path, package_root: Path) -> tuple[list[Path], str]:
    source = protected_reference(package_root)
    target = root / BOUNDARY_INJECTED_RELATIVE
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    return [target], f"copy protected reference {source.relative_to(package_root).as_posix()} to {BOUNDARY_INJECTED_RELATIVE.as_posix()}"


def apply_historical_mutation(root: Path) -> tuple[list[Path], str]:
    target = root / HISTORICAL_EVIDENCE
    atomic_write(target, target.read_bytes() + b"\n")
    return [target], f"append one newline byte to historical evidence {HISTORICAL_EVIDENCE.as_posix()}"


def apply_publication_mutation(root: Path) -> tuple[list[Path], str]:
    target = root / QUALIFICATION_DRIVER
    addition = (
        b"\n\n# isolated negative mutation\n"
        b"subprocess.run([\"git\", \"tag\", \"v4.3-mutation\"], check=True)\n"
    )
    atomic_write(target, target.read_bytes() + addition)
    return [target], "append an executable git tag operation to the qualification driver"


def apply_mutation(
    root: Path, definition: MutationDefinition, package_root: Path
) -> tuple[list[Path], str]:
    ordinal = definition.ordinal
    if ordinal <= 9:
        return authority_mutation(root, ordinal)
    if ordinal == 13:
        return apply_boundary_mutation(root, package_root)
    if ordinal in TEXT_MUTATIONS:
        return apply_text_mutation(root, ordinal)
    if ordinal in FIXTURE_TARGETS:
        return apply_fixture_mutation(root, ordinal)
    if ordinal == 20:
        return apply_case_20_mutation(root)
    if ordinal == 44:
        return apply_case_44_mutation(root)
    if ordinal == 45:
        return apply_historical_mutation(root)
    if ordinal == 47:
        return apply_publication_mutation(root)
    raise MutationFailure(f"mutation {ordinal} has no executable implementation")


def authority_guard_command(root: Path) -> list[str]:
    return [
        sys.executable,
        str(root / AUTHORITY_VALIDATOR),
        "--root",
        str(root),
        "--manifest",
        AUTHORITY_MANIFEST_RELATIVE.as_posix(),
    ]


def boundary_guard_command(root: Path, package_root: Path) -> list[str]:
    return [
        sys.executable,
        str(root / REFERENCE_BOUNDARY),
        "--repository-root",
        str(root),
        "--package-root",
        str(package_root),
        "--asset-manifest",
        PACKAGE_ASSET_MANIFEST.as_posix(),
        "--exact-candidate-catalog",
        PACKAGE_CANONICAL_CATALOG.as_posix(),
    ]


def contract_guard_command(root: Path) -> list[str]:
    return [
        sys.executable,
        str(root / MUTATION_RUNNER),
        "guard-contract",
        "--repo-root",
        str(root),
        "--fixture",
        str(root / CONTRACT_RELATIVE),
    ]


def case_guard_command(root: Path, definition: MutationDefinition) -> list[str]:
    return [
        sys.executable,
        str(root / MUTATION_RUNNER),
        "guard-case",
        "--repo-root",
        str(root),
        "--fixture",
        str(root / CONTRACT_RELATIVE),
        "--mutation-id",
        definition.mutation_id,
    ]


def guard_command(
    root: Path, definition: MutationDefinition, package_root: Path
) -> list[str]:
    if definition.ordinal <= 9:
        return authority_guard_command(root)
    if definition.ordinal == 13:
        return boundary_guard_command(root, package_root)
    return case_guard_command(root, definition)


def parse_guard_result(
    definition: MutationDefinition, result: CommandResult
) -> tuple[bool, list[str], str]:
    combined = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
    codes: list[str] = []
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        payload = None
    matching_findings: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        for item in payload.get("findings", []):
            if not isinstance(item, dict):
                continue
            code = item.get("code")
            if isinstance(code, str):
                codes.append(code)
                if code == definition.diagnostic_code:
                    matching_findings.append(item)
    expected = definition.diagnostic_code
    baseline_diagnostic_present = any(
        code.startswith("V43M-000-") for code in codes
    )
    rejected = (
        result.exit_status != 0
        and expected in set(codes)
        and not baseline_diagnostic_present
    )
    if matching_findings:
        excerpt = json.dumps(
            {"expectedDiagnosticCode": expected, "findings": matching_findings},
            indent=2,
            sort_keys=True,
        )[:4_000]
    else:
        excerpt_lines = [line for line in combined.splitlines() if line.strip()]
        excerpt = "\n".join(excerpt_lines[:12])[:4_000]
    return rejected, sorted(set(codes)), excerpt


def positive_guard_passed(result: CommandResult) -> tuple[bool, str]:
    combined = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        payload = None
    passed = result.exit_status == 0 and isinstance(payload, dict) and payload.get("result") == "PASS"
    excerpt = "\n".join(line for line in combined.splitlines() if line.strip())[:2_000]
    return passed, excerpt


def package_preflight_passed(result: CommandResult) -> tuple[bool, str]:
    marker = "Rune Scribe Theme Fidelity v4.3 preflight: PASS"
    combined = "\n".join(
        part for part in (result.stdout, result.stderr) if part
    ).strip()
    passed = result.exit_status == 0 and marker in result.stdout.splitlines()
    lines = [line for line in combined.splitlines() if line.strip()]
    return passed, "\n".join(lines[-20:])[-2_000:]


def selected_definitions(only: Sequence[str] | None) -> tuple[MutationDefinition, ...]:
    all_definitions = definitions()
    if not only:
        return all_definitions
    requested = set(only)
    known = {item.mutation_id for item in all_definitions}
    unknown = requested - known
    if unknown:
        raise MutationFailure("unknown mutation IDs: " + ", ".join(sorted(unknown)))
    return tuple(item for item in all_definitions if item.mutation_id in requested)


def resolve_package_root(value: Path | None) -> Path:
    candidate = value
    if candidate is None:
        configured = os.environ.get("RUNESCRIBE_V43_AUTHORITY_PACKAGE")
        candidate = Path(configured) if configured else None
    if candidate is None:
        raise MutationFailure(
            "--authority-package or RUNESCRIBE_V43_AUTHORITY_PACKAGE is required"
        )
    resolved = candidate.resolve()
    required = (
        resolved / PACKAGE_ASSET_MANIFEST,
        resolved / PACKAGE_CANONICAL_CATALOG,
    )
    if not resolved.is_dir() or not all(path.is_file() for path in required):
        raise MutationFailure(f"authority package is incomplete: {resolved}")
    return resolved


def file_record(
    path: Path, root: Path, original: FileSnapshot, mutated: FileSnapshot, restored: FileSnapshot
) -> dict[str, Any]:
    return {
        "path": path.relative_to(root).as_posix(),
        "originalState": "PRESENT" if original.exists else "ABSENT",
        "originalSHA256": original.sha256,
        "originalMode": original.mode,
        "mutatedState": "PRESENT" if mutated.exists else "ABSENT",
        "mutatedSHA256": mutated.sha256,
        "mutatedMode": mutated.mode,
        "restoredState": "PRESENT" if restored.exists else "ABSENT",
        "restoredSHA256": restored.sha256,
        "restoredMode": restored.mode,
        "restoredExactly": (
            original.exists == restored.exists
            and original.data == restored.data
            and original.mode == restored.mode
        ),
    }


def execute_case(
    sandbox: Path,
    repository_root: Path,
    definition: MutationDefinition,
    package_root: Path,
    pristine_inventory: str,
    original_status_sha256: str,
) -> dict[str, Any]:
    started_at = utc_now()
    started = time.monotonic()
    source_status_at_start = git_status(repository_root)
    source_head_at_start = git_sha(repository_root)
    targets: list[Path] = []
    originals: dict[Path, FileSnapshot] = {}
    mutated_snapshots: dict[Path, FileSnapshot] = {}
    restored_snapshots: dict[Path, FileSnapshot] = {}
    exact_mutation = ""
    rejection_result: CommandResult | None = None
    revalidation_result: CommandResult | None = None
    preflight_result: CommandResult | None = None
    observed_codes: list[str] = []
    diagnostic = ""
    revalidation_diagnostic = ""
    rejected = False
    restored_exactly = False
    positive_passed = False
    failure: str | None = None
    try:
        prospective_targets: list[Path]
        if definition.ordinal <= 9:
            prospective_targets = [
                sandbox
                / (
                    MASK_RELATIVE
                    if definition.ordinal == 8
                    else CANONICAL_RELATIVE
                    if definition.ordinal in {1, 2}
                    else COMPARISON_RELATIVE
                )
            ]
        else:
            prospective_targets = [
                sandbox / Path(definition.source_or_authority_file)
            ]
        originals = {path: snapshot(path) for path in prospective_targets}
        targets, exact_mutation = apply_mutation(sandbox, definition, package_root)
        if targets != prospective_targets or not targets:
            raise MutationFailure("mutation target declaration differs from actual targets")
        mutated_snapshots = {path: snapshot(path) for path in targets}
        if all(originals[path].data == mutated_snapshots[path].data for path in targets):
            raise MutationFailure("mutation made no byte change")
        rejection_result = run_command(
            guard_command(sandbox, definition, package_root),
            cwd=sandbox,
            timeout=600 if definition.ordinal == 13 else 180,
        )
        rejected, observed_codes, diagnostic = parse_guard_result(
            definition, rejection_result
        )
        if not rejected:
            failure = (
                "mutation unexpectedly passed"
                if rejection_result.exit_status == 0
                else f"guard failed without expected diagnostic {definition.diagnostic_code}"
            )
    except Exception as error:
        failure = str(error)
    finally:
        restore_errors: list[str] = []
        for path, original in originals.items():
            try:
                restore(path, original)
            except Exception as error:
                restore_errors.append(f"{path}: {error}")
        restored_snapshots = {path: snapshot(path) for path in originals}
        restored_exactly = bool(originals) and all(
            original.exists == restored_snapshots[path].exists
            and original.data == restored_snapshots[path].data
            and original.mode == restored_snapshots[path].mode
            for path, original in originals.items()
        )
        if restore_errors:
            failure = (failure + "; " if failure else "") + "; ".join(restore_errors)
        if restored_exactly:
            revalidation_result = run_command(
                guard_command(sandbox, definition, package_root),
                cwd=sandbox,
                timeout=600 if definition.ordinal == 13 else 180,
            )
            positive_passed, revalidation_diagnostic = positive_guard_passed(
                revalidation_result
            )
            preflight_result = run_command(
                [str(package_root / PACKAGE_PREFLIGHT)],
                cwd=package_root,
                timeout=300,
            )
            preflight_passed, preflight_diagnostic = package_preflight_passed(
                preflight_result
            )
            positive_passed = positive_passed and preflight_passed
            if not preflight_passed:
                revalidation_diagnostic = (
                    revalidation_diagnostic
                    + "\npackage preflight:\n"
                    + preflight_diagnostic
                ).strip()
            if not positive_passed and failure is None:
                failure = "positive revalidation did not pass after restoration"
        elif failure is None:
            failure = "mutation targets were not restored byte-for-byte"

    restored_inventory = inventory_digest(sandbox)
    source_status_at_end = git_status(repository_root)
    source_head_at_end = git_sha(repository_root)
    source_unchanged = (
        source_status_at_start == source_status_at_end
        and source_head_at_start == source_head_at_end
    )
    sandbox_clean = restored_inventory == pristine_inventory and restored_exactly
    clean = sandbox_clean and source_unchanged
    if not clean and failure is None:
        failure = (
            "temporary sandbox did not return to its pristine inventory"
            if not sandbox_clean
            else "source checkout changed while the isolated mutation ran"
        )
    passed = rejected and restored_exactly and positive_passed and clean and failure is None
    file_records = [
        file_record(
            path,
            sandbox,
            originals[path],
            mutated_snapshots.get(path, snapshot(path)),
            restored_snapshots.get(path, snapshot(path)),
        )
        for path in targets or originals
    ]
    return {
        "mutationID": definition.mutation_id,
        "ordinal": definition.ordinal,
        "category": definition.category,
        "requirement": definition.requirement,
        "sourceOrAuthorityFile": definition.source_or_authority_file,
        "boundSourceOrEvidenceFile": definition.bound_source_or_evidence_file,
        "isolationMode": definition.isolation,
        "exactMutation": exact_mutation,
        "expectedRejectingGuard": definition.guard,
        "expectedDiagnosticCode": definition.diagnostic_code,
        "command": rejection_result.command if rejection_result else shlex.join(guard_command(sandbox, definition, package_root)),
        "exitStatus": rejection_result.exit_status if rejection_result else None,
        "observedDiagnosticCodes": observed_codes,
        "diagnosticExcerpt": diagnostic,
        "expectedOutcome": "REJECTED",
        "observedOutcome": "REJECTED" if rejected else "UNEXPECTED_PASS_OR_WRONG_GUARD",
        "targets": file_records,
        "originalSHA256": file_records[0]["originalSHA256"] if file_records else None,
        "mutatedSHA256": file_records[0]["mutatedSHA256"] if file_records else None,
        "restoredSHA256": file_records[0]["restoredSHA256"] if file_records else None,
        "restoration": {
            "exactBytesRestored": restored_exactly,
            "sandboxInventoryBeforeSHA256": pristine_inventory,
            "sandboxInventoryAfterSHA256": restored_inventory,
        },
        "cleanTreeProof": {
            "originalWorktreeStatusSHA256": original_status_sha256,
            "caseStatusAtStartSHA256": sha256_bytes(
                source_status_at_start.encode("utf-8")
            ),
            "caseStatusAtEndSHA256": sha256_bytes(
                source_status_at_end.encode("utf-8")
            ),
            "caseHeadAtStart": source_head_at_start,
            "caseHeadAtEnd": source_head_at_end,
            "originalWorktreeTouched": not source_unchanged,
            "sandboxUnexpectedDeltaCount": 0 if sandbox_clean else 1,
            "result": "PASS" if clean else "FAIL",
        },
        "positiveRevalidation": {
            "affectedGate": {
                "command": revalidation_result.command if revalidation_result else None,
                "exitStatus": revalidation_result.exit_status if revalidation_result else None,
            },
            "packagePreflight": {
                "command": preflight_result.command if preflight_result else None,
                "exitStatus": preflight_result.exit_status if preflight_result else None,
                "result": (
                    "PASS"
                    if preflight_result is not None
                    and package_preflight_passed(preflight_result)[0]
                    else "FAIL"
                ),
            },
            "command": revalidation_result.command if revalidation_result else None,
            "exitStatus": revalidation_result.exit_status if revalidation_result else None,
            "diagnosticExcerpt": revalidation_diagnostic,
            "result": "PASS" if positive_passed else "FAIL",
        },
        "startTimestamp": started_at,
        "endTimestamp": utc_now(),
        "durationSeconds": round(time.monotonic() - started, 3),
        "result": "PASS" if passed else "FAIL",
        "failure": failure,
    }


def execute_suite(arguments: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    repository_root = arguments.repo_root.resolve()
    package_root = resolve_package_root(arguments.authority_package)
    selected = selected_definitions(arguments.only)
    start_timestamp = utc_now()
    started = time.monotonic()
    head_before = git_sha(repository_root)
    status_before = git_status(repository_root)
    status_before_sha = sha256_bytes(status_before.encode("utf-8"))
    package_inventory_before = inventory_digest(package_root)
    failures: list[str] = []
    if status_before and not arguments.allow_dirty_baseline:
        failures.append("original worktree is not clean; blocking mutation evidence requires a clean source checkout")
    elif status_before:
        failures.append(
            "dirty-baseline development mode is not eligible for blocking NEG-001 evidence"
        )
    cases: list[dict[str, Any]] = []
    baseline_results: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="runescribe-v43-mutations-") as directory:
        sandbox = Path(directory) / "repository"
        copy_sandbox(repository_root, sandbox)
        contract = build_contract(sandbox, source_sha=head_before)
        write_json(sandbox / CONTRACT_RELATIVE, contract)
        write_executable_fixtures(sandbox, contract)
        baseline_commands: list[
            tuple[list[str], Path, Callable[[CommandResult], tuple[bool, str]]]
        ] = [
            (authority_guard_command(sandbox), sandbox, positive_guard_passed),
            (boundary_guard_command(sandbox, package_root), sandbox, positive_guard_passed),
            (contract_guard_command(sandbox), sandbox, positive_guard_passed),
            (
                [str(package_root / PACKAGE_PREFLIGHT)],
                package_root,
                package_preflight_passed,
            ),
        ]
        baseline_commands.extend(
            (case_guard_command(sandbox, definition), sandbox, positive_guard_passed)
            for definition in definitions()
            if definition.ordinal > 9 and definition.ordinal != 13
        )
        for command, cwd, evaluator in baseline_commands:
            result = run_command(command, cwd=cwd, timeout=600)
            passed, excerpt = evaluator(result)
            baseline_results.append(
                {
                    "command": result.command,
                    "exitStatus": result.exit_status,
                    "result": "PASS" if passed else "FAIL",
                    "diagnosticExcerpt": excerpt,
                }
            )
            if not passed:
                failures.append(f"positive baseline guard failed: {result.command}")
        pristine_inventory = inventory_digest(sandbox)
        if not failures or (
            arguments.allow_dirty_baseline
            and all(item["result"] == "PASS" for item in baseline_results)
        ):
            for definition in selected:
                record = execute_case(
                    sandbox,
                    repository_root,
                    definition,
                    package_root,
                    pristine_inventory,
                    status_before_sha,
                )
                cases.append(record)
                if record["result"] != "PASS":
                    failures.append(
                        f"{definition.mutation_id}: {record.get('failure') or record['observedOutcome']}"
                    )
        else:
            failures.append("mutations were not executed because the positive baseline was invalid")

    status_after = git_status(repository_root)
    status_after_sha = sha256_bytes(status_after.encode("utf-8"))
    head_after = git_sha(repository_root)
    package_inventory_after = inventory_digest(package_root)
    original_untouched = status_before == status_after and head_before == head_after
    if not original_untouched:
        failures.append("original worktree status or HEAD changed while the isolated suite ran")
    package_untouched = package_inventory_before == package_inventory_after
    if not package_untouched:
        failures.append("authority package changed while the isolated suite ran")
    complete = not arguments.only and len(cases) == EXPECTED_MUTATION_COUNT
    if not complete:
        failures.append("partial mutation execution cannot satisfy NEG-001")
    passed_count = sum(item.get("result") == "PASS" for item in cases)
    clean_eligible = not status_before and original_untouched and package_untouched
    if not clean_eligible and not arguments.allow_dirty_baseline:
        failures.append("clean-tree qualification proof is unavailable")
    result = "PASS" if not failures and complete and clean_eligible else "FAIL"
    payload = {
        "schemaVersion": "1.0",
        "evidenceType": "v4.3-negative-mutation-suite",
        "fixtureOnly": False,
        "acceptanceEvidence": result == "PASS",
        "sourceSHA": head_before,
        "result": result,
        "expectedMutationCount": EXPECTED_MUTATION_COUNT,
        "executedMutationCount": len(cases),
        "passedMutationCount": passed_count,
        "failedMutationCount": len(cases) - passed_count,
        "allMutationsRejected": len(cases) == EXPECTED_MUTATION_COUNT and passed_count == EXPECTED_MUTATION_COUNT,
        "allOriginalBytesRestored": bool(cases) and all(item["restoration"]["exactBytesRestored"] for item in cases),
        "positiveRevalidationComplete": bool(cases) and all(item["positiveRevalidation"]["result"] == "PASS" for item in cases),
        "failClosedOnUnexpectedPass": True,
        "sourceMutationPolicy": "isolated temporary copies and source-bound non-acceptance fixtures only",
        "positiveBaselines": baseline_results,
        "startTimestamp": start_timestamp,
        "endTimestamp": utc_now(),
        "runtimeSeconds": round(time.monotonic() - started, 3),
        "originalWorktreeProof": {
            "cleanAtStart": not bool(status_before),
            "cleanAtEnd": not bool(status_after),
            "unchanged": original_untouched,
            "statusBeforeSHA256": status_before_sha,
            "statusAfterSHA256": status_after_sha,
            "headAtStart": head_before,
            "headAtEnd": head_after,
        },
        "authorityPackage": {
            "path": str(package_root),
            "assetManifestSHA256": sha256_file(package_root / PACKAGE_ASSET_MANIFEST),
            "canonicalCatalogSHA256": sha256_file(package_root / PACKAGE_CANONICAL_CATALOG),
            "inventoryBeforeSHA256": package_inventory_before,
            "inventoryAfterSHA256": package_inventory_after,
            "unchanged": package_untouched,
        },
        "failures": failures,
        "mutations": cases,
    }
    return (0 if result == "PASS" else 1), payload


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="subcommand")

    run = subparsers.add_parser("run", help="execute the isolated 47-case suite")
    run.add_argument("--repo-root", type=Path, default=REPOSITORY_ROOT)
    run.add_argument("--authority-package", type=Path)
    run.add_argument("--output", type=Path)
    run.add_argument("--only", action="append", help="run one mutation ID; partial runs intentionally fail NEG-001")
    run.add_argument("--allow-dirty-baseline", action="store_true", help="development-only execution; output remains ineligible for blocking PASS")

    guard = subparsers.add_parser("guard-contract", help="validate one fixture-only mutation contract")
    guard.add_argument("--repo-root", type=Path, required=True)
    guard.add_argument("--fixture", type=Path, required=True)

    case_guard = subparsers.add_parser(
        "guard-case", help="validate one mutation-specific source or executable fixture"
    )
    case_guard.add_argument("--repo-root", type=Path, required=True)
    case_guard.add_argument("--fixture", type=Path, required=True)
    case_guard.add_argument("--mutation-id", required=True)

    subparsers.add_parser("list", help="list all package-declared mutation IDs")
    arguments = parser.parse_args(argv)
    if arguments.subcommand is None:
        parser.error("a subcommand is required")
    return arguments


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    if arguments.subcommand == "list":
        for definition in definitions():
            print(
                f"{definition.mutation_id}\t{definition.category}\t"
                f"{definition.diagnostic_code}\t{definition.requirement}"
            )
        return 0
    if arguments.subcommand == "guard-contract":
        root = arguments.repo_root.resolve()
        fixture = arguments.fixture
        if not fixture.is_absolute():
            fixture = root / fixture
        payload = guard_payload(root, fixture.resolve())
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0 if payload["result"] == "PASS" else 1
    if arguments.subcommand == "guard-case":
        root = arguments.repo_root.resolve()
        fixture = arguments.fixture
        if not fixture.is_absolute():
            fixture = root / fixture
        payload = guard_case_payload(
            root, fixture.resolve(), arguments.mutation_id
        )
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0 if payload["result"] == "PASS" else 1
    try:
        code, payload = execute_suite(arguments)
    except (MutationFailure, OSError, UnicodeError, json.JSONDecodeError) as error:
        payload = {
            "schemaVersion": "1.0",
            "evidenceType": "v4.3-negative-mutation-suite",
            "fixtureOnly": False,
            "acceptanceEvidence": False,
            "result": "FAIL",
            "expectedMutationCount": EXPECTED_MUTATION_COUNT,
            "executedMutationCount": 0,
            "failures": [str(error)],
            "mutations": [],
        }
        code = 1
    rendered = canonical_json_bytes(payload)
    if arguments.output is not None:
        output = arguments.output
        if not output.is_absolute():
            output = arguments.repo_root.resolve() / output
        atomic_write(output.resolve(), rendered)
    sys.stdout.write(rendered.decode("utf-8"))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
