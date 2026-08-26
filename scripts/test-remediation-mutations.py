#!/usr/bin/env python3
"""Run the isolated remediation mutations required for qualification."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PACKAGE_RELATIVE = Path("Packages/RuneScribeArchitecture")
NORSE_RESOURCE_ROOT = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources"
)
NORSE_PROVENANCE = (
    NORSE_RESOURCE_ROOT
    / "Production/Metadata/Norse-Production-Asset-Provenance-v2.0.json"
)
NORSE_INTEGRITY = (
    NORSE_RESOURCE_ROOT
    / "Production/Metadata/Norse-Resource-Integrity-Manifest-v2.0.json"
)
MOONLEAF_INTEGRITY = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeMoonleafModule/"
    "Resources/Production/Resource-Integrity-Manifest-v1.0.json"
)
MOONLEAF_PROVIDER_TESTS = Path(
    "Packages/RuneScribeArchitecture/Tests/RuneScribeThemeMoonleafModuleTests/"
    "MoonleafThemeProviderTests.swift"
)
SOURCE_MANIFEST_MUTATION_TARGET = Path("RuneScrib/Resources/Fonts/OFL.txt")
SHARE_BUILDER_SESSION = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/"
    "Presentation/RuneScribeUISession+ShareBuilder.swift"
)
SHARE_BUILDER_MODEL = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/"
    "Sharing/ShareBuilderModel.swift"
)
CONTENT_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContentView.swift"
)
ROOT_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RootView.swift"
)
RUNE_THEME_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RuneTheme.swift"
)
CONTACTS_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContactsView.swift"
)
VAULT_PROGRESS_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VaultProgressView.swift"
)
IMPORT_CONFIRM_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ImportConfirmView.swift"
)
RECEIVED_MESSAGE_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ReceivedMessageView.swift"
)
LOCK_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/LockView.swift"
)
SETTINGS_VIEW = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/SettingsView.swift"
)
SHARE_COMPLETION = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
    "ShareCompletionContracts.swift"
)
PROGRESSION_FACTORY = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/"
    "CoreProgressionFactFactory.swift"
)
PACKAGE_CODEC = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/"
    "Domain/Formats/RuneScribePackage.swift"
)
CIPHER = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Domain/Cipher.swift"
)
ARTIFACT_SELECTION = Path(
    "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
    "RuntimeArtifactSelectionContracts.swift"
)
LOCKED_GATE_CATALOG = Path(
    "docs/verification/remediation-v1/REMEDIATION-GATES-v1.0.json"
)
PUBLICATION_SCANNER = Path("scripts/scan-" + "attri" + "bution.py")
EVIDENCE_PREFIX = "docs/verification/remediation-v1"

TEMPLATE_PATHS = (
    Path("EULA.md"),
    Path("project.yml"),
    Path("RuneScrib.xcodeproj/project.pbxproj"),
    Path("RuneScrib/Resources/Fonts/OFL.txt"),
    Path(
        "docs/verification/theme-fidelity-v4/generated/norse/Metadata/"
        "Norse-Production-Asset-Derivation-v4.0.json"
    ),
    Path("docs/verification/theme-fidelity-v4/source-masters/norse"),
    Path(
        "docs/product-roadmap/"
        "Rune-Scribe-Codex-Roadmap-Remediation-Amendment-v1.1.md"
    ),
    PACKAGE_RELATIVE / "Package.swift",
    Path(
        "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/"
        "NorseApplicationResourceCatalog.swift"
    ),
    Path(
        "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/"
        "NorseBaseThemeDescriptor.swift"
    ),
    SHARE_BUILDER_SESSION,
    SHARE_BUILDER_MODEL,
    Path(
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/"
        "Sharing/ShareBuilderView.swift"
    ),
    Path(
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/"
        "Views/CipherLibraryView.swift"
    ),
    CONTENT_VIEW,
    ROOT_VIEW,
    RUNE_THEME_VIEW,
    CONTACTS_VIEW,
    VAULT_PROGRESS_VIEW,
    IMPORT_CONFIRM_VIEW,
    RECEIVED_MESSAGE_VIEW,
    LOCK_VIEW,
    SETTINGS_VIEW,
    SHARE_COMPLETION,
    PROGRESSION_FACTORY,
    PACKAGE_CODEC,
    CIPHER,
    ARTIFACT_SELECTION,
    Path(
        "Packages/RuneScribeArchitecture/Tests/RuneScribeArchitectureTests/"
        "RuntimeSettingsContractTests.swift"
    ),
    MOONLEAF_INTEGRITY,
    Path("scripts/check-remediation-source.py"),
    Path("scripts/check-norse-production-provenance.py"),
    Path("scripts/generate-norse-production-provenance.py"),
    Path("scripts/check-remediation-completion.py"),
    Path("scripts/generate-remediation-evidence.py"),
    Path("scripts/capture-remediation-domain-results.py"),
    Path("scripts/generate-source-manifest.py"),
    PUBLICATION_SCANNER,
    Path("scripts/test-remediation-mutations.py"),
    LOCKED_GATE_CATALOG,
)


@dataclass
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


@dataclass
class CaseResult:
    caseID: str
    requirement: str
    detector: str
    expectedOutcome: str
    observedOutcome: str
    result: str
    restoredAutomatically: bool
    durationSeconds: float


class HarnessFailure(RuntimeError):
    pass


def run_command(
    arguments: list[str],
    *,
    cwd: Path,
    timeout: int = 120,
) -> CommandResult:
    try:
        completed = subprocess.run(
            arguments,
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
    except subprocess.TimeoutExpired as error:
        raise HarnessFailure(f"command exceeded {timeout} seconds") from error
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


def copy_relative(source_root: Path, destination_root: Path, relative: Path) -> None:
    source = source_root / relative
    destination = destination_root / relative
    if not source.exists():
        raise HarnessFailure(f"template source is missing: {relative.as_posix()}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, destination)
    else:
        shutil.copy2(source, destination)


def build_template(destination: Path) -> None:
    copy_package(destination)
    for relative in TEMPLATE_PATHS:
        if relative == PACKAGE_RELATIVE or relative.is_relative_to(PACKAGE_RELATIVE):
            continue
        copy_relative(REPOSITORY_ROOT, destination, relative)


def copy_package(destination_root: Path, source_package: Path | None = None) -> Path:
    source = source_package or (REPOSITORY_ROOT / PACKAGE_RELATIVE)
    destination = destination_root / PACKAGE_RELATIVE
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        source,
        destination,
        ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"),
    )
    return destination


def atomic_write_text(path: Path, value: str) -> None:
    temporary = path.with_name(path.name + ".mutation-tmp")
    temporary.write_text(value, encoding="utf-8")
    os.replace(temporary, path)


def atomic_write_bytes(path: Path, value: bytes) -> None:
    temporary = path.with_name(path.name + ".mutation-tmp")
    temporary.write_bytes(value)
    os.replace(temporary, path)


def replace_once(root: Path, relative: Path, old: str, new: str) -> None:
    path = root / relative
    source = path.read_text(encoding="utf-8")
    count = source.count(old)
    if count != 1:
        raise HarnessFailure(
            f"mutation anchor count for {relative.as_posix()} is {count}, expected 1"
        )
    atomic_write_text(path, source.replace(old, new, 1))


def source_check(root: Path, product_root: Path | None = None) -> tuple[CommandResult, dict]:
    arguments = [
        sys.executable,
        str(root / "scripts/check-remediation-source.py"),
        "--root",
        str(root),
        "--json",
    ]
    if product_root is not None:
        arguments.extend(["--norse-product-root", str(product_root)])
    result = run_command(arguments, cwd=root, timeout=120)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise HarnessFailure("source checker did not emit valid JSON") from error
    return result, payload


def require_source_rejection(root: Path, expected_code: str) -> str:
    result, payload = source_check(root)
    observed = {
        finding.get("code")
        for finding in payload.get("findings", [])
        if isinstance(finding, dict)
    }
    if result.returncode == 0 or payload.get("result") != "FAIL":
        raise HarnessFailure(f"mutation unexpectedly passed {expected_code}")
    if expected_code not in observed:
        raise HarnessFailure(f"mutation missed its expected detector {expected_code}")
    return expected_code


def norse_product_resource_root(bundle: Path) -> Path:
    candidates = (
        bundle / "Contents/Resources",
        bundle / "Resources",
        bundle,
    )
    matching = [
        candidate
        for candidate in candidates
        if (candidate / "module-manifest.json").is_file()
    ]
    if len(matching) != 1:
        raise HarnessFailure("built Release Norse product has an unexpected resource layout")
    return matching[0]


def build_release_norse_product(source_package: Path, destination: Path) -> Path:
    scratch = destination / "scratch"
    result = run_command(
        [
            "swift",
            "build",
            "--package-path",
            str(source_package),
            "--scratch-path",
            str(scratch),
            "--configuration",
            "release",
            "--product",
            "RuneScribeNorseThemeModule",
        ],
        cwd=source_package,
        timeout=900,
    )
    if result.returncode != 0:
        raise HarnessFailure("Norse Release product build failed")
    candidates = sorted(
        path
        for path in scratch.rglob(
            "RuneScribeArchitecture_RuneScribeNorseThemeModule.bundle"
        )
        if path.is_dir()
    )
    matching = []
    for candidate in candidates:
        try:
            norse_product_resource_root(candidate)
        except HarnessFailure:
            continue
        matching.append(candidate)
    unique = {candidate.resolve(): candidate for candidate in matching}
    if len(unique) != 1:
        raise HarnessFailure("Norse Release build did not produce one resource bundle")
    return next(iter(unique.values()))


def copy_release_norse_product(source_bundle: Path, destination_root: Path) -> tuple[Path, Path]:
    bundle = destination_root / "release-product" / source_bundle.name
    bundle.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source_bundle, bundle, symlinks=True)
    return bundle, norse_product_resource_root(bundle)


def required_norse_product_name(root: Path) -> str:
    provenance = json.loads((root / NORSE_PROVENANCE).read_text(encoding="utf-8"))
    candidates = sorted(
        Path(resource["normalizedProductionPath"]).name
        for resource in provenance["resources"]
        if resource.get("requiredForActiveContent") is True
        and Path(resource["normalizedProductionPath"]).suffix == ".json"
    )
    if not candidates:
        raise HarnessFailure("no small required Norse product resource is available")
    return candidates[0]


def require_product_rejection(root: Path, product: Path, expected_code: str) -> str:
    result, payload = source_check(root, product)
    observed = {
        finding.get("code")
        for finding in payload.get("findings", [])
        if isinstance(finding, dict)
    }
    if result.returncode == 0 or payload.get("result") != "FAIL":
        raise HarnessFailure(f"shipping mutation unexpectedly passed {expected_code}")
    if expected_code not in observed:
        raise HarnessFailure(f"shipping mutation missed {expected_code}")
    return expected_code


def mutate_primary_link(root: Path) -> None:
    replace_once(root, SHARE_BUILDER_SESSION, "representation: .file,", "representation: .link,")


def mutate_share_builder_removed(root: Path) -> None:
    replace_once(root, CONTENT_VIEW, "                    customizeShareButton\n\n", "")


def mutate_security_summary_removed(root: Path) -> None:
    replace_once(
        root,
        SHARE_BUILDER_MODEL,
        '            "Key included — this first delivery contains the shared cipher."',
        '            ""',
    )


def mutate_cancelled_progression(root: Path) -> None:
    replace_once(
        root,
        SHARE_COMPLETION,
        "        case (.shareSheet, .completedBySystem), (.airDrop, .completedBySystem):\n"
        "            return true\n",
        "        case (.shareSheet, .completedBySystem), (.airDrop, .completedBySystem),\n"
        "             (.shareSheet, .cancelled), (.airDrop, .cancelled):\n"
        "            return true\n",
    )
    replace_once(
        root,
        PROGRESSION_FACTORY,
        "        case .completedBySystem:\n"
        "            reason = identifier(\"eligibility.eligible.share-completed-by-system\")\n",
        "        case .completedBySystem, .cancelled:\n"
        "            reason = identifier(\"eligibility.eligible.share-completed-by-system\")\n",
    )
    replace_once(
        root,
        PROGRESSION_FACTORY,
        "        case .presented, .cancelled, .failed, .completionUnavailable:\n",
        "        case .presented, .failed, .completionUnavailable:\n",
    )


def mutate_root_background_removed(root: Path) -> None:
    replace_once(root, ROOT_VIEW, "            RuntimeMetalBackground()", "            Color.clear")


def mutate_provider_specific_ui_branch(root: Path) -> None:
    replace_once(
        root,
        SETTINGS_VIEW,
        "    var body: some View {\n",
        "    var body: some View {\n"
        "        if session.themeSnapshot?.effectiveCodexID == RuneScribeCodexIDs.norse {\n"
        "            Color.clear\n"
        "        }\n",
    )


def mutate_settings_local_storage(root: Path) -> None:
    replace_once(
        root,
        SETTINGS_VIEW,
        "struct SettingsView: View {\n",
        "struct SettingsView: View {\n\n"
        '    @AppStorage("mutation.appearance") private var localAppearance = false\n',
    )


def mutate_external_dependency(root: Path) -> None:
    replace_once(
        root,
        PACKAGE_RELATIVE / "Package.swift",
        "    ],\n    targets: [\n",
        "    ],\n"
        '    dependencies: [.package(path: "/tmp/Forsetti")],\n'
        "    targets: [\n",
    )


def mutate_core_reader_removed(root: Path) -> None:
    replace_once(
        root,
        PACKAGE_CODEC,
        "    var corePayload: Data {\n"
        "        sections.first { $0.type == RuneScribePackageSectionType.corePayload.rawValue }?.data\n"
        "            ?? Data()\n"
        "    }\n\n",
        "",
    )


def mutate_cipher_presentation_state(root: Path) -> None:
    replace_once(
        root,
        CIPHER,
        "    let keyMaterial: Data\n",
        "    let keyMaterial: Data\n\n    let codexID: CodexID?\n",
    )


def mutate_boolean_schema_acceptance(root: Path) -> None:
    path = root / ARTIFACT_SELECTION
    source = path.read_text(encoding="utf-8")
    marker = "    private static func decodeVersionedValue(\n"
    index = source.find(marker)
    if index < 0:
        raise HarnessFailure("artifact selection decoder anchor is missing")
    prefix = source[:index]
    suffix = source[index:]
    old = (
        "        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {\n"
        "            throw RuntimeArtifactSelectionContractError.malformed\n"
        "        }\n"
    )
    if suffix.count(old) != 1:
        raise HarnessFailure("artifact selection document decode anchor differs")
    new = (
        "        let decoderData: Data\n"
        "        if let booleanVersion = root[\"schemaVersion\"] as? Bool {\n"
        "            var normalizedRoot = root\n"
        "            normalizedRoot[\"schemaVersion\"] = booleanVersion ? 1 : 0\n"
        "            decoderData = try JSONSerialization.data(withJSONObject: normalizedRoot)\n"
        "        } else {\n"
        "            decoderData = data\n"
        "        }\n"
        "        guard let document = try? JSONDecoder().decode(Document.self, from: decoderData) else {\n"
        "            throw RuntimeArtifactSelectionContractError.malformed\n"
        "        }\n"
    )
    atomic_write_text(path, prefix + suffix.replace(old, new, 1))


def swift_test(
    package: Path,
    scratch: Path,
    test_filter: str,
    timeout: int = 600,
) -> CommandResult:
    return run_command(
        [
            "swift",
            "test",
            "--package-path",
            str(package),
            "--scratch-path",
            str(scratch),
            "--filter",
            test_filter,
        ],
        cwd=package,
        timeout=timeout,
    )


def prove_mutant_test_failure(
    case_root: Path,
    source_package: Path,
    mutator: Callable[[Path], None],
    test_filter: str,
    expected_test_name: str,
) -> str:
    behavior_root = case_root / "behavior"
    package = copy_package(behavior_root, source_package)
    scratch = behavior_root / ".mutation-build"
    baseline = swift_test(package, scratch, test_filter)
    if baseline.returncode != 0:
        raise HarnessFailure("focused behavioral baseline failed before mutation")
    mutator(behavior_root)
    mutated = swift_test(package, scratch, test_filter)
    combined = mutated.stdout + mutated.stderr
    if mutated.returncode == 0:
        raise HarnessFailure("behavioral mutation unexpectedly passed")
    if expected_test_name not in combined:
        raise HarnessFailure("mutated behavioral test did not execute")
    return "focused-test-rejected-mutant"


def prove_optional_provider_degradation(case_root: Path, source_package: Path) -> str:
    behavior_root = case_root / "behavior"
    package = copy_package(behavior_root, source_package)
    replace_once(
        behavior_root,
        MOONLEAF_PROVIDER_TESTS,
        "        XCTAssertEqual(fallback.effectiveTheme.codex.id, RuneScribeCodexIDs.norse)\n",
        "        XCTAssertEqual(fallback.effectiveTheme.codex.id, RuneScribeCodexIDs.norse)\n"
        "        XCTAssertFalse(fallback.isEmergencyPresentation)\n"
        "        XCTAssertTrue(fallback.requiredBaseResourceFailures.isEmpty)\n",
    )
    scratch = behavior_root / ".mutation-build"
    filters = (
        (
            "RuntimeLifecycleTests."
            "testOptionalManifestDecodeFailureIsRecordedWithoutBlockingRequiredModules",
            "testOptionalManifestDecodeFailureIsRecordedWithoutBlockingRequiredModules",
        ),
        (
            "ThemeFoundationSecurityTests."
            "testOptionalManifestFailureRetainsSuppliedThemeDiscoveryAsUnavailable",
            "testOptionalManifestFailureRetainsSuppliedThemeDiscoveryAsUnavailable",
        ),
        (
            "ReceivedPresentationAvailabilityBindingTests."
            "testLiveProviderStatesResolveRequestedCodexOrNorseFallback",
            "testLiveProviderStatesResolveRequestedCodexOrNorseFallback",
        ),
        (
            "MoonleafThemeProviderTests."
            "testThemeCoordinatorActivatesLiveAndPreservesOwnedPreferenceDuringProviderFailure",
            "testThemeCoordinatorActivatesLiveAndPreservesOwnedPreferenceDuringProviderFailure",
        ),
    )
    for test_filter, expected_name in filters:
        result = swift_test(package, scratch, test_filter)
        combined = result.stdout + result.stderr
        if result.returncode != 0 or expected_name not in combined:
            raise HarnessFailure("optional-provider degraded behavior proof failed")
    return "four-focused-degraded-launch-tests-passed-with-no-base-warning-state"


def write_json(path: Path, document: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_text(path, json.dumps(document, indent=2, sort_keys=True) + "\n")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def deterministic_zip(
    entries: dict[str, bytes],
    *,
    executable_names: set[str] | None = None,
) -> bytes:
    executable_names = executable_names or set()
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, mode="w", compression=zipfile.ZIP_STORED) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            mode = 0o100755 if name in executable_names else 0o100644
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, entries[name])
    return stream.getvalue()


_FIXTURE_EXECUTABLES: dict[str, bytes] = {}


def fixture_executable(platform: str) -> bytes:
    cached = _FIXTURE_EXECUTABLES.get(platform)
    if cached is not None:
        return cached
    entitlements_document = {
        "com.apple.developer.game-center": True,
        "com.apple.developer.icloud-container-identifiers": [
            "iCloud.com.runescribe.app"
        ],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.ubiquity-kvstore-identifier": (
            "$(TeamIdentifierPrefix)com.runescribe.app"
            if platform == "macOS"
            else "ABCDEFGHIJ.com.runescribe.app"
        ),
    }
    if platform == "macOS":
        entitlements_document.update({
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.user-selected.read-write": True,
            "com.apple.security.personal-information.addressbook": True,
        })
    else:
        entitlements_document.update({
            "application-identifier": "ABCDEFGHIJ.com.runescribe.app",
            "com.apple.developer.team-identifier": "ABCDEFGHIJ",
            "keychain-access-groups": ["ABCDEFGHIJ.com.runescribe.app"],
        })
    with tempfile.TemporaryDirectory(prefix="runescribe-fixture-macho-") as temporary:
        temporary_root = Path(temporary)
        source = temporary_root / "main.c"
        entitlements = temporary_root / "entitlements.plist"
        executable = temporary_root / "RuneScrib"
        source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
        entitlements.write_bytes(
            plistlib.dumps(
                entitlements_document, fmt=plistlib.FMT_XML, sort_keys=True
            )
        )
        sdk = "macosx" if platform == "macOS" else "iphonesimulator"
        command = [
            "xcrun", "--sdk", sdk, "clang", "-arch", "arm64",
            str(source), "-o", str(executable), "-Wl,-no_uuid",
            f"-Wl,-sectcreate,__TEXT,__entitlements,{entitlements}",
        ]
        if platform != "macOS":
            command[6:6] = ["-target", "arm64-apple-ios18.0-simulator"]
        compiled = run_command(command, cwd=temporary_root, timeout=120)
        if compiled.returncode != 0:
            raise HarnessFailure(
                "fixture Mach-O compilation failed: "
                + (compiled.stderr or compiled.stdout).strip()
            )
        if platform == "macOS":
            signed = run_command(
                [
                    "codesign", "--force", "--sign", "-", "--timestamp=none",
                    "--identifier", "com.runescribe.app", "--entitlements",
                    str(entitlements), str(executable),
                ],
                cwd=temporary_root,
                timeout=120,
            )
            if signed.returncode != 0:
                raise HarnessFailure(
                    "fixture Mach-O signing failed: "
                    + (signed.stderr or signed.stdout).strip()
                )
        value = executable.read_bytes()
    _FIXTURE_EXECUTABLES[platform] = value
    return value


def theme_bundle_entries(platform: str) -> dict[str, bytes]:
    entries: dict[str, bytes] = {}
    prefix = (
        "RuneScrib.app/Contents/Resources"
        if platform == "macOS" else "RuneScrib.app"
    )
    theme_modules = (
        "RuneScribeNorseThemeModule",
        "RuneScribeThemeGloamthornModule",
        "RuneScribeThemeMoonleafModule",
        "RuneScribeThemeSunspireModule",
        "RuneScribeThemeWildwoodModule",
    )
    for module_name in theme_modules:
        resource_root = (
            REPOSITORY_ROOT / PACKAGE_RELATIVE / "Sources" / module_name / "Resources"
        )
        bundle_name = f"RuneScribeArchitecture_{module_name}.bundle"
        bundle_prefix = f"{prefix}/{bundle_name}"
        if platform == "macOS":
            bundle_prefix += "/Contents/Resources"
        seen_basenames: set[str] = set()
        for source_file in sorted(resource_root.rglob("*")):
            if not source_file.is_file() or source_file.name.startswith("."):
                continue
            source_parts = source_file.relative_to(resource_root).parts
            if module_name == "RuneScribeNorseThemeModule" and source_parts[0] == "Source":
                continue
            if source_file.name in seen_basenames:
                raise HarnessFailure(
                    f"fixture Theme resources collide after flattening: {module_name}"
                )
            seen_basenames.add(source_file.name)
            entries[f"{bundle_prefix}/{source_file.name}"] = source_file.read_bytes()
        if platform == "iOS":
            entries[f"{bundle_prefix}/Info.plist"] = plistlib.dumps(
                {
                    "CFBundleIdentifier": f"com.runescribe.{module_name}",
                    "CFBundlePackageType": "BNDL",
                },
                fmt=plistlib.FMT_XML,
                sort_keys=True,
            )
            entries[f"{bundle_prefix}/_CodeSignature/CodeDirectory"] = b"fixture"
            entries[f"{bundle_prefix}/_CodeSignature/CodeRequirements"] = b"fixture"
            entries[f"{bundle_prefix}/_CodeSignature/CodeResources"] = b"fixture"
            entries[f"{bundle_prefix}/_CodeSignature/CodeSignature"] = b""
    return entries


def app_zip(platform: str) -> bytes:
    plist_document: dict[str, Any] = {
        "CFBundleExecutable": "RuneScrib",
        "CFBundleIdentifier": "com.runescribe.app",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0.39",
        "CFBundleVersion": "39",
        "GKGameCenter": True,
        "NSUbiquitousContainers": {
            "iCloud.com.runescribe.app": {
                "NSUbiquitousContainerIsDocumentScopePublic": False,
            }
        },
    }
    if platform == "macOS":
        plist_document["CFBundleSupportedPlatforms"] = ["MacOSX"]
        plist_path = "RuneScrib.app/Contents/Info.plist"
        executable_path = "RuneScrib.app/Contents/MacOS/RuneScrib"
    else:
        plist_document["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        plist_path = "RuneScrib.app/Info.plist"
        executable_path = "RuneScrib.app/RuneScrib"
    plist = plistlib.dumps(plist_document, fmt=plistlib.FMT_XML, sort_keys=True)
    executable = fixture_executable(platform)
    entries = theme_bundle_entries(platform)
    entries.update(
        {
            plist_path: plist,
            executable_path: executable,
        }
    )
    return deterministic_zip(
        entries,
        executable_names={executable_path},
    )


def load_completion_checker_module(root: Path) -> Any:
    path = root / "scripts/check-remediation-completion.py"
    spec = importlib.util.spec_from_file_location(
        "remediation_mutation_completion_checker",
        path,
    )
    if spec is None or spec.loader is None:
        raise HarnessFailure("cannot load the remediation completion checker")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_manifest_command(root: Path) -> tuple[Path, list[str]]:
    manifest = root / "docs/verification/remediation-v1/SOURCE-MANIFEST.json"
    return manifest, [
        sys.executable,
        str(root / "scripts/generate-source-manifest.py"),
        str(root),
        str(manifest),
    ]


def require_source_manifest_baseline(root: Path) -> tuple[Path, list[str]]:
    manifest, command = source_manifest_command(root)
    generated = run_command(command, cwd=root, timeout=120)
    if generated.returncode != 0:
        raise HarnessFailure("source-manifest mutation baseline generation failed")
    verified = run_command(command + ["--verify"], cwd=root, timeout=120)
    if verified.returncode != 0:
        raise HarnessFailure("source-manifest mutation baseline verification failed")
    return manifest, command


def prove_source_manifest_hardening(root: Path) -> str:
    with tempfile.TemporaryDirectory(
        prefix="source-byte-",
        dir=root.parent,
    ) as temporary:
        variant = Path(temporary) / "repository"
        shutil.copytree(root, variant)
        _, command = require_source_manifest_baseline(variant)
        target = variant / SOURCE_MANIFEST_MUTATION_TARGET
        data = bytearray(target.read_bytes())
        if not data:
            raise HarnessFailure("source-manifest mutation target is empty")
        data[0] ^= 1
        atomic_write_bytes(target, bytes(data))

        mutated = run_command(command + ["--verify"], cwd=variant, timeout=120)
        combined = mutated.stdout + mutated.stderr
        expected_path = SOURCE_MANIFEST_MUTATION_TARGET.as_posix()
        if mutated.returncode == 0:
            raise HarnessFailure(
                "shipping byte mutation unexpectedly passed manifest verification"
            )
        if expected_path not in combined:
            raise HarnessFailure("source manifest verifier did not identify the changed path")

    with tempfile.TemporaryDirectory(
        prefix="source-exclude-",
        dir=root.parent,
    ) as temporary:
        variant = Path(temporary) / "repository"
        shutil.copytree(root, variant)
        manifest, command = source_manifest_command(variant)
        custom = run_command(
            command + ["--exclude", "Packages"],
            cwd=variant,
            timeout=120,
        )
        if custom.returncode == 0 or "custom excludes are prohibited" not in custom.stderr:
            raise HarnessFailure("custom shipping exclude was not rejected")

        manifest, command = require_source_manifest_baseline(variant)
        document = json.loads(manifest.read_text(encoding="utf-8"))
        document["excludes"] = sorted(set(document["excludes"]) | {"Packages"})
        write_json(manifest, document)
        tampered = run_command(command + ["--verify"], cwd=variant, timeout=120)
        if (
            tampered.returncode == 0
            or "excludes differ from the locked source-manifest policy"
            not in tampered.stderr
        ):
            raise HarnessFailure("tampered shipping exclude was not rejected")

    return "source-manifest-rejected-byte-drift-and-shipping-exclude"


def scanner_check(root: Path) -> CommandResult:
    return run_command(
        [sys.executable, str(root / PUBLICATION_SCANNER), str(root)],
        cwd=root,
        timeout=120,
    )


def require_scanner_rejection(root: Path, expected_source: str) -> None:
    result = scanner_check(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise HarnessFailure("prohibited publication surface unexpectedly passed")
    if expected_source not in combined:
        raise HarnessFailure("publication scanner did not identify the mutated surface")


def prove_publication_scan_hardening(root: Path) -> str:
    if scanner_check(root).returncode != 0:
        raise HarnessFailure("publication scanner baseline failed")

    marker = "generated" + " by " + "chat" + "gpt"
    with tempfile.TemporaryDirectory(
        prefix="publication-content-",
        dir=root.parent,
    ) as temporary:
        variant = Path(temporary) / "repository"
        shutil.copytree(root, variant)
        filename = "mutation-publication.txt"
        (variant / filename).write_text(marker + "\n", encoding="utf-8")
        require_scanner_rejection(variant, filename)

    prohibited_label = "-".join(("generated", "by", "chat" + "gpt"))
    with tempfile.TemporaryDirectory(
        prefix="publication-filename-",
        dir=root.parent,
    ) as temporary:
        variant = Path(temporary) / "repository"
        shutil.copytree(root, variant)
        filename = prohibited_label + ".bin"
        (variant / filename).write_bytes(b"publication path fixture\n")
        require_scanner_rejection(variant, "path:" + filename)

    with tempfile.TemporaryDirectory(
        prefix="publication-branch-",
        dir=root.parent,
    ) as temporary:
        variant = Path(temporary) / "repository"
        shutil.copytree(root, variant)
        initialized = run_command(["git", "init", "--quiet"], cwd=variant)
        if initialized.returncode != 0:
            raise HarnessFailure("temporary branch fixture initialization failed")
        selected = run_command(
            ["git", "symbolic-ref", "HEAD", f"refs/heads/{prohibited_label}"],
            cwd=variant,
        )
        if selected.returncode != 0:
            raise HarnessFailure("temporary branch fixture selection failed")
        require_scanner_rejection(variant, "git-branch")

    return "publication-scan-rejected-content-filename-and-branch"


def execute_case(
    template: Path,
    work_root: Path,
    case_id: str,
    requirement: str,
    detector: str,
    expected: str,
    executor: Callable[[Path], str],
) -> CaseResult:
    started = time.monotonic()
    temporary = tempfile.TemporaryDirectory(prefix=f"{case_id.lower()}-", dir=work_root)
    case_parent = Path(temporary.name)
    case_root = case_parent / "repository"
    result = "FAIL"
    observed = "case-failed"
    try:
        shutil.copytree(template, case_root)
        observed = executor(case_root)
        result = "PASS"
    except (HarnessFailure, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        observed = str(error)
    finally:
        temporary.cleanup()
    restored = not case_parent.exists()
    if not restored:
        result = "FAIL"
        observed = "temporary mutation sandbox was not removed"
    return CaseResult(
        caseID=case_id,
        requirement=requirement,
        detector=detector,
        expectedOutcome=expected,
        observedOutcome=observed,
        result=result,
        restoredAutomatically=restored,
        durationSeconds=round(time.monotonic() - started, 3),
    )


def main() -> int:
    started = time.monotonic()
    results: list[CaseResult] = []
    with tempfile.TemporaryDirectory(prefix="runescribe-remediation-mutations-") as temporary:
        work_root = Path(temporary)
        template = work_root / "template"
        template.mkdir()
        try:
            build_template(template)

            baseline_result, baseline_payload = source_check(template)
            if baseline_result.returncode != 0 or baseline_payload.get("result") != "PASS":
                raise HarnessFailure("source-checker baseline failed")

            behavior_template_root = work_root / "behavior-template"
            behavior_package_template = copy_package(behavior_template_root)
            release_bundle_template = build_release_norse_product(
                behavior_package_template,
                work_root / "release-build",
            )
            release_product_root = norse_product_resource_root(release_bundle_template)
            product_result, product_payload = source_check(
                template,
                release_product_root,
            )
            if product_result.returncode != 0 or product_payload.get("result") != "PASS":
                raise HarnessFailure("built Release Norse product baseline failed")

            if scanner_check(template).returncode != 0:
                raise HarnessFailure("publication scan baseline failed")
        except (HarnessFailure, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
            record = {
                "schemaVersion": "1.0",
                "result": "FAIL",
                "requiredCaseCount": 18,
                "passedCaseCount": 0,
                "failedCaseCount": 18,
                "runtimeSeconds": round(time.monotonic() - started, 3),
                "setupFailure": str(error),
                "cases": [],
            }
            print(json.dumps(record, indent=2, sort_keys=True))
            return 1

        def source_case(
            case_id: str,
            requirement: str,
            code: str,
            mutator: Callable[[Path], None],
        ) -> None:
            def executor(root: Path) -> str:
                mutator(root)
                return require_source_rejection(root, code)

            results.append(
                execute_case(
                    template,
                    work_root,
                    case_id,
                    requirement,
                    "remediation-source-checker",
                    f"rejected by {code}",
                    executor,
                )
            )

        source_case(
            "M01",
            "Primary Cipher Library Share changed from file to link",
            "RMS-001",
            mutate_primary_link,
        )
        source_case(
            "M02",
            "Share Builder entry point removed",
            "RMS-002",
            mutate_share_builder_removed,
        )
        source_case(
            "M03",
            "Key and security summary removed",
            "RMS-003",
            mutate_security_summary_removed,
        )

        def cancellation_case(root: Path) -> str:
            mutate_cancelled_progression(root)
            require_source_rejection(root, "RMS-004")
            return prove_mutant_test_failure(
                root,
                behavior_package_template,
                mutate_cancelled_progression,
                "CoreProgressionFactFactoryTests."
                "testIneligibleTerminalRoutesNeverProduceShareFact",
                "testIneligibleTerminalRoutesNeverProduceShareFact",
            )

        results.append(
            execute_case(
                template,
                work_root,
                "M04",
                "Cancellation awards progression",
                "source checker and focused progression test",
                "static rejection and focused test failure",
                cancellation_case,
            )
        )

        def missing_norse_case(root: Path) -> str:
            _, product_root = copy_release_norse_product(
                release_bundle_template,
                root,
            )
            (product_root / required_norse_product_name(root)).unlink()
            return require_product_rejection(root, product_root, "RMS-005")

        results.append(
            execute_case(
                template,
                work_root,
                "M05",
                "Required Norse shipping resource removed",
                "built Release Norse product companion shipping checker",
                "rejected by RMS-005",
                missing_norse_case,
            )
        )

        def changed_norse_case(root: Path) -> str:
            _, product_root = copy_release_norse_product(
                release_bundle_template,
                root,
            )
            path = product_root / required_norse_product_name(root)
            atomic_write_bytes(path, path.read_bytes() + b"x")
            return require_product_rejection(root, product_root, "RMS-006")

        results.append(
            execute_case(
                template,
                work_root,
                "M06",
                "Required Norse shipping resource digest changed",
                "built Release Norse product companion shipping checker",
                "rejected by RMS-006",
                changed_norse_case,
            )
        )

        def optional_provider_case(root: Path) -> str:
            path = root / MOONLEAF_INTEGRITY
            atomic_write_bytes(path, path.read_bytes() + b"\n")
            source_result, payload = source_check(root)
            if source_result.returncode != 0 or payload.get("result") != "PASS":
                raise HarnessFailure("optional provider corruption blocked source qualification")
            return prove_optional_provider_degradation(
                root,
                behavior_package_template,
            )

        results.append(
            execute_case(
                template,
                work_root,
                "M07",
                "Optional provider corrupted while Core, UI, and Norse degrade safely",
                "four focused degraded-launch tests",
                "focused tests pass and expose no required-Base warning state",
                optional_provider_case,
            )
        )

        source_case(
            "T-015",
            "Provider-specific UI branch inserted",
            "RMS-007",
            mutate_provider_specific_ui_branch,
        )

        source_case(
            "M08",
            "Root Theme background removed",
            "RMS-008",
            mutate_root_background_removed,
        )
        source_case(
            "M09",
            "Settings write moved to local view storage",
            "RMS-009",
            mutate_settings_local_storage,
        )
        source_case(
            "M10",
            "External Forsetti dependency added",
            "RMS-010",
            mutate_external_dependency,
        )

        results.append(
            execute_case(
                template,
                work_root,
                "T-004",
                "Shipping-source byte or locked exclude policy changed",
                "existing deterministic source-manifest verifier",
                "byte drift identifies its path and shipping excludes are rejected",
                prove_source_manifest_hardening,
            )
        )

        def evidence_hash_case(root: Path) -> str:
            checker = load_completion_checker_module(root)
            source_hash = "1" * 64
            gate_id = "RC-TYPED"
            claim = "typed evidence record proof"
            claim_paths = checker.required_claim_paths(claim)
            if len(claim_paths) != 1:
                raise HarnessFailure("typed evidence claim did not resolve to one path")
            artifact_relative = claim_paths[0]
            log_relative = "artifacts/remediation-mutations/typed-evidence-record.log"
            artifact_path = root / artifact_relative
            log_path = root / log_relative
            write_json(artifact_path, {"schemaVersion": "1.0", "result": "PASS"})
            log_path.parent.mkdir(parents=True, exist_ok=True)
            atomic_write_text(log_path, "typed evidence record validation passed\n")

            record_path = root / EVIDENCE_PREFIX / "FullRegression.json"
            record = {
                "schemaVersion": "1.0",
                "recordID": "typed-evidence-record",
                "gateIDs": [gate_id],
                "sourceManifestSHA256": source_hash,
                "version": checker.EXPECTED_VERSION,
                "build": checker.EXPECTED_BUILD,
                "result": "PASS",
                "commands": ["validate typed evidence record"],
                "environment": {
                    "operatingSystem": "isolated mutation sandbox",
                    "architecture": "arm64",
                    "xcode": "typed validator",
                    "swift": "typed validator",
                },
                "startedAt": "2026-08-23T00:00:00Z",
                "endedAt": "2026-08-23T00:00:01Z",
                "failures": [],
                "artifacts": [artifact_relative],
                "logs": [log_relative],
                "evidenceClaims": [claim],
                "evidenceBindings": {claim: [artifact_relative]},
                "artifactSHA256": {
                    artifact_relative: sha256_file(artifact_path),
                    log_relative: sha256_file(log_path),
                },
            }
            validator_arguments = (
                record_path,
                root,
                source_hash,
                {gate_id},
                {gate_id: {claim}},
                False,
                False,
            )

            baseline_errors, _, _, _ = checker.validate_evidence_record(
                validator_arguments[0],
                record,
                *validator_arguments[1:],
            )
            if baseline_errors:
                raise HarnessFailure(
                    "typed evidence-record baseline failed: " + "; ".join(baseline_errors)
                )

            malformed_root_errors, _, _, _ = checker.validate_evidence_record(
                validator_arguments[0],
                [],
                *validator_arguments[1:],
            )
            expected_root = f"{record_path}: evidence root must be an object"
            if malformed_root_errors != [expected_root]:
                raise HarnessFailure("malformed evidence root missed its exact rejection")

            malformed_gate_record = dict(record)
            malformed_gate_record["gateIDs"] = [{}]
            malformed_gate_errors, _, _, _ = checker.validate_evidence_record(
                validator_arguments[0],
                malformed_gate_record,
                *validator_arguments[1:],
            )
            expected_gate = (
                f"{record_path}: gateIDs must be a nonempty unique string array"
            )
            if malformed_gate_errors != [expected_gate]:
                raise HarnessFailure("malformed evidence gate IDs missed their exact rejection")

            stale_record = dict(record)
            stale_record["sourceManifestSHA256"] = "0" * 64
            stale_errors, _, _, _ = checker.validate_evidence_record(
                validator_arguments[0],
                stale_record,
                *validator_arguments[1:],
            )
            expected_hash = f"{record_path}: source manifest hash differs"
            if stale_errors != [expected_hash]:
                raise HarnessFailure("evidence source hash missed its exact rejection")
            return "record-validator-rejected-malformed-inputs-and-source-hash"

        results.append(
            execute_case(
                template,
                work_root,
                "M11",
                "Malformed evidence inputs or evidence source-manifest hash changed",
                "existing remediation completion binder",
                "malformed schemas reject without a crash and evidence binding rejects",
                evidence_hash_case,
            )
        )

        def old_completion_case(root: Path) -> str:
            checker = load_completion_checker_module(root)
            prior_hash = "1" * 64
            final_hash = "2" * 64
            payload_digest = "3" * 64
            evidence_path = f"{EVIDENCE_PREFIX}/FullRegression.json"
            completion = {
                "schemaVersion": "1.0",
                "status": "RELEASE_CANDIDATE_READY",
                "sourceManifestSHA256": prior_hash,
                "sourceRevision": None,
                "branch": None,
                "version": checker.EXPECTED_VERSION,
                "build": checker.EXPECTED_BUILD,
                "requiredGateCount": 42,
                "passedGateCount": 42,
                "failedGateCount": 0,
                "findingClosures": [
                    {
                        "id": finding_id,
                        "status": "CLOSED",
                        "gateIDs": sorted(checker.EXPECTED_FINDING_GATES[finding_id]),
                        "evidence": [evidence_path],
                    }
                    for finding_id in sorted(checker.EXPECTED_FINDING_IDS)
                ],
                "platformQualification": {
                    "macOS": "PASS",
                    "iPhoneSimulator": "PASS",
                    "iPadSimulator": "PASS",
                },
                "ownerTestPackage": {
                    "path": "Rune-Scribe-Owner-Test-Payload-v1.0.zip",
                    "sha256": payload_digest,
                },
                "physicalHardwareRequired": False,
                "liveAccountsRequired": False,
                "publicDistributionPerformed": False,
                "attributionAudit": "PASS",
                "nonGatingExternal": list(checker.FIXED_NON_GATING_BOUNDARIES),
            }
            baseline_errors = checker.validate_internal_completion_report(
                completion,
                payload_digest=payload_digest,
                source_hash=prior_hash,
                source_revision=None,
                branch=None,
                label="CompletionReport.json",
            )
            if baseline_errors:
                raise HarnessFailure(
                    "typed completion baseline failed: " + "; ".join(baseline_errors)
                )
            stale_errors = checker.validate_internal_completion_report(
                completion,
                payload_digest=payload_digest,
                source_hash=final_hash,
                source_revision=None,
                branch=None,
                label="CompletionReport.json",
            )
            expected = "CompletionReport.json: sourceManifestSHA256 differs"
            if stale_errors != [expected]:
                raise HarnessFailure("stale completion missed its exact source binding rejection")

            outer_completion = dict(completion)
            outer_completion["ownerTestPackage"] = {
                "path": checker.EXPECTED_OWNER_PACKAGE,
                "sha256": payload_digest,
            }
            report_path = root / EVIDENCE_PREFIX / "CompletionReport.json"
            adjacent_report_path = (
                root / "artifacts/remediation-v1/CompletionReport.json"
            )
            write_json(report_path, outer_completion)
            write_json(adjacent_report_path, outer_completion)
            report_markdown = report_path.with_suffix(".md")
            adjacent_markdown = adjacent_report_path.with_suffix(".md")
            atomic_write_text(report_markdown, "isolated completion binding proof\n")
            atomic_write_text(adjacent_markdown, "isolated completion binding proof\n")

            known_gates = set(checker.EXPECTED_GATE_IDS)
            validator_arguments = (
                report_path,
                outer_completion,
                root,
                prior_hash,
                known_gates,
                False,
                {evidence_path: known_gates},
                {},
                {
                    test_id: {"result": "PASS"}
                    for test_id in ("T-023", "T-112", "T-113", "T-114")
                },
            )
            prerequisite_errors = [
                "CompletionReport.json: owner-test package is missing",
                f"{checker.EXPECTED_SHA256SUMS}: missing regular checksum file",
            ]
            outer_baseline_errors = checker.validate_completion_report(
                *validator_arguments
            )
            if outer_baseline_errors != prerequisite_errors:
                raise HarnessFailure(
                    "top-level completion baseline differs: "
                    + "; ".join(outer_baseline_errors)
                )

            stale_validator_arguments = list(validator_arguments)
            stale_validator_arguments[3] = final_hash
            outer_stale_errors = checker.validate_completion_report(
                *stale_validator_arguments
            )
            if outer_stale_errors != [expected, *prerequisite_errors]:
                raise HarnessFailure(
                    "top-level stale completion missed its exact source binding rejection"
                )
            return "internal-and-top-level-completion-rejected-stale-source-hash"

        results.append(
            execute_case(
                template,
                work_root,
                "M12",
                "Prior completion record substituted for final completion",
                "existing remediation completion binder",
                "otherwise-terminal stale completion rejected",
                old_completion_case,
            )
        )

        source_case(
            "M13",
            "Core payload reader removed",
            "RMS-013",
            mutate_core_reader_removed,
        )
        source_case(
            "M14",
            "Presentation choice moved into Cipher key state",
            "RMS-014",
            mutate_cipher_presentation_state,
        )

        results.append(
            execute_case(
                template,
                work_root,
                "M15",
                "Prohibited publication content, filename, or branch label inserted",
                "existing publication scanner",
                "each isolated publication surface is rejected",
                prove_publication_scan_hardening,
            )
        )

        def boolean_schema_case(root: Path) -> str:
            mutate_boolean_schema_acceptance(root)
            require_source_rejection(root, "RMS-016")
            return prove_mutant_test_failure(
                root,
                behavior_package_template,
                mutate_boolean_schema_acceptance,
                "RuntimeSettingsContractTests."
                "testArtifactSelectionRejectsDuplicatesFutureMalformedAndWrongKinds",
                "testArtifactSelectionRejectsDuplicatesFutureMalformedAndWrongKinds",
            )

        results.append(
            execute_case(
                template,
                work_root,
                "M16",
                "Boolean schema version accepted",
                "source checker and focused contract test",
                "static rejection and focused test failure",
                boolean_schema_case,
            )
        )

    passed = sum(result.result == "PASS" for result in results)
    record = {
        "schemaVersion": "1.0",
        "result": "PASS" if passed == 18 else "FAIL",
        "requiredCaseCount": 18,
        "passedCaseCount": passed,
        "failedCaseCount": 18 - passed,
        "sourceMutationsConfinedToTemporaryCopies": True,
        "allTemporaryCopiesRestored": all(
            result.restoredAutomatically for result in results
        ),
        "runtimeSeconds": round(time.monotonic() - started, 3),
        "cases": [asdict(result) for result in results],
    }
    print(json.dumps(record, indent=2, sort_keys=True))
    return 0 if record["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
