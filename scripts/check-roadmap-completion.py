#!/usr/bin/env python3
"""Validate the source-controlled roadmap-completion shipping boundary."""

from __future__ import annotations

import copy
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_ROOT = ROOT / "Packages/RuneScribeArchitecture"
SOURCE_MANIFEST = ROOT / "docs/verification/remediation-v1/SOURCE-MANIFEST.json"
ERRORS: list[str] = []

PROVIDERS = {
    "moonleaf": {
        "product": "RuneScribeThemeMoonleafModule",
        "moduleID": "com.runescribe.module.theme.moonleaf",
        "role": "runescribe.theme.moonleaf",
        "codexID": "codex.moonleaf",
        "entitlement": "unlock.codex.moonleaf",
        "outputs": 65,
        "bytes": 70_543_811,
    },
    "sunspire": {
        "product": "RuneScribeThemeSunspireModule",
        "moduleID": "com.runescribe.module.theme.sunspire",
        "role": "runescribe.theme.sunspire",
        "codexID": "codex.sunspire",
        "entitlement": "unlock.codex.sunspire",
        "outputs": 60,
        "bytes": 76_011_959,
    },
    "wildwood": {
        "product": "RuneScribeThemeWildwoodModule",
        "moduleID": "com.runescribe.module.theme.wildwood",
        "role": "runescribe.theme.wildwood",
        "codexID": "codex.wildwood",
        "entitlement": "unlock.codex.wildwood",
        "outputs": 60,
        "bytes": 85_212_927,
    },
    "gloamthorn": {
        "product": "RuneScribeThemeGloamthornModule",
        "moduleID": "com.runescribe.module.theme.gloamthorn",
        "role": "runescribe.theme.gloamthorn",
        "codexID": "codex.gloamthorn",
        "entitlement": "unlock.codex.gloamthorn",
        "outputs": 60,
        "bytes": 68_300_382,
    },
}

EXPECTED_CAPABILITIES = {
    "resources.read",
    "runtime.contributions.publish",
    "runtime.resources.opaque.publish",
}
EXPECTED_ENTITLEMENTS = {
    "com.apple.developer.game-center": True,
    "com.apple.developer.icloud-container-identifiers": ["iCloud.com.runescribe.app"],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.ubiquity-kvstore-identifier":
        "$(TeamIdentifierPrefix)com.runescribe.app",
}

EVIDENCE_ROOT = ROOT / "docs/verification/roadmap-completion"
REQUIRED_JSON_EVIDENCE = (
    "Baseline.json",
    "DefectLedger.json",
    "ElvenAssetMaterialization.json",
    "FoundationCompletion.json",
    "PhaseDProviderIntegration.json",
    "PhaseEProgressionBinding.json",
    "PhaseFSharingAndEncounters.json",
    "CloudSyncValidation.json",
    "GameCenterValidation.json",
    "PerformanceAndResourceBudget.json",
    "AccessibilityValidation.json",
    "CompatibilityMatrix.json",
    "FullRegression.json",
    "NegativeMutations.json",
    "AttributionAudit.json",
)
REQUIRED_MARKDOWN_EVIDENCE = (
    "DocumentationSupportChecklist.md",
    "SecurityPrivacyReview.md",
    "FinalSelfAudit.md",
    "OwnerTestAndNoShipHandoff.md",
)


def error(message: str) -> None:
    ERRORS.append(message)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exception:
        error(f"{path.relative_to(ROOT)}: invalid or missing JSON: {exception}")
        return {}
    if not isinstance(value, dict):
        error(f"{path.relative_to(ROOT)}: JSON root must be an object")
        return {}
    return value


def git_available() -> bool:
    if not (ROOT / ".git").exists():
        return False
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False
    try:
        return Path(result.stdout.strip()).resolve() == ROOT.resolve()
    except OSError:
        return False


def validate_source_manifest() -> None:
    if not SOURCE_MANIFEST.is_file():
        if not git_available():
            error(
                "Git metadata is absent and the final deterministic source manifest is missing"
            )
        return
    # This manifest is immutable evidence for the completed remediation-v1 source
    # boundary, not a rolling manifest for later releases. Current source binding is
    # validated by the active qualification package. Keep the historical document
    # self-consistent without requiring later source trees to match old file bytes.
    document = load_json(SOURCE_MANIFEST)
    files = document.get("files")
    if not isinstance(files, list):
        error("historical deterministic source manifest files must be an array")
        return
    if document.get("fileCount") != len(files):
        error("historical deterministic source manifest fileCount differs")
    paths: set[str] = set()
    aggregate = hashlib.sha256()
    for index, record in enumerate(files):
        if not isinstance(record, dict):
            error(f"historical deterministic source manifest file {index} is not an object")
            continue
        relative = record.get("path")
        kind = record.get("kind")
        byte_count = record.get("bytes")
        digest = record.get("sha256")
        executable = record.get("executable")
        if not isinstance(relative, str) or not relative or relative in paths:
            error(f"historical deterministic source manifest path {index} is invalid or duplicated")
            continue
        paths.add(relative)
        if kind not in {"file", "symlink"}:
            error(f"historical deterministic source manifest kind differs for {relative}")
            continue
        if not isinstance(byte_count, int) or byte_count < 0:
            error(f"historical deterministic source manifest bytes differ for {relative}")
            continue
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            error(f"historical deterministic source manifest digest differs for {relative}")
            continue
        if not isinstance(executable, bool):
            error(f"historical deterministic source manifest executable flag differs for {relative}")
            continue
        aggregate.update(
            f"{relative}\0{kind}\0{byte_count}\0{digest}\0{1 if executable else 0}\n".encode(
                "utf-8"
            )
        )
    if document.get("aggregateSHA256") != aggregate.hexdigest():
        error("historical deterministic source manifest aggregateSHA256 differs")


def validate_integrity_manifest(
    key: str,
    record: dict[str, Any],
    resource_root: Path,
    manifest: dict[str, Any],
) -> list[str]:
    findings: list[str] = []
    if manifest.get("schemaVersion") != "1.0":
        findings.append(f"{key}: integrity schema differs")
    if manifest.get("codexID") != record["codexID"]:
        findings.append(f"{key}: integrity Codex identity differs")
    if manifest.get("moduleID") != record["moduleID"]:
        findings.append(f"{key}: integrity module identity differs")
    if manifest.get("acceptedPackageVersion") != "4.3.0":
        findings.append(f"{key}: accepted package version differs")

    files = manifest.get("files")
    if not isinstance(files, list) or len(files) != record["outputs"]:
        findings.append(
            f"{key}: integrity file count must be {record['outputs']}"
        )
        return findings

    seen_paths: set[str] = set()
    seen_resources: set[str] = set()
    byte_total = 0
    for index, entry in enumerate(files):
        if not isinstance(entry, dict):
            findings.append(f"{key}: integrity file {index} is not an object")
            continue
        relative = entry.get("path")
        resource_id = entry.get("resourceID")
        expected_bytes = entry.get("bytes")
        expected_hash = entry.get("sha256")
        if not isinstance(relative, str) or relative.startswith("/") or ".." in Path(relative).parts:
            findings.append(f"{key}: integrity file {index} has unsafe path")
            continue
        if relative in seen_paths:
            findings.append(f"{key}: duplicate integrity path {relative}")
        seen_paths.add(relative)
        if not isinstance(resource_id, str) or resource_id in seen_resources:
            findings.append(f"{key}: duplicate or invalid resource ID at {relative}")
        else:
            seen_resources.add(resource_id)
        path = resource_root / relative
        if not path.is_file():
            findings.append(f"{key}: missing output {relative}")
            continue
        data = path.read_bytes()
        if expected_bytes != len(data):
            findings.append(f"{key}: byte count differs for {relative}")
        if expected_hash != hashlib.sha256(data).hexdigest():
            findings.append(f"{key}: SHA-256 differs for {relative}")
        byte_total += len(data)
    if byte_total != record["bytes"]:
        findings.append(
            f"{key}: output bytes {byte_total} differ from {record['bytes']}"
        )
    return findings


def validate_provider(key: str, record: dict[str, Any]) -> list[str]:
    findings: list[str] = []
    source_root = PACKAGE_ROOT / "Sources" / record["product"]
    resource_root = source_root / "Resources"
    module_manifest = load_json(resource_root / "module-manifest.json")
    expected_manifest = {
        "moduleID": record["moduleID"],
        "defaultRole": record["role"],
        "criticality": "optional",
        "policyClass": "policy.theme-provider",
        "moduleType": "service",
        "diagnosticsVisibleInProduction": False,
    }
    for field, expected in expected_manifest.items():
        if module_manifest.get(field) != expected:
            findings.append(f"{key}: module manifest {field} differs")
    if set(module_manifest.get("capabilitiesRequested", [])) != EXPECTED_CAPABILITIES:
        findings.append(f"{key}: module capabilities differ")
    requirements = module_manifest.get("runtimeRequirements", {})
    if requirements.get("requiredServices") != ["ApplicationResourceLocator"]:
        findings.append(f"{key}: application resource locator is not required")
    entitlement = module_manifest.get("entitlementRequirement", {})
    if entitlement != {"kind": "earned", "identifier": record["entitlement"]}:
        findings.append(f"{key}: entitlement requirement differs")

    integrity_path = (
        resource_root / "Production/Resource-Integrity-Manifest-v1.0.json"
    )
    integrity = load_json(integrity_path)
    findings.extend(
        validate_integrity_manifest(key, record, resource_root, integrity)
    )

    swift = "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(source_root.glob("*.swift"))
    )
    forbidden = {
        "SwiftUI": "UI framework",
        "RuneScribeProgressionModule": "Progression implementation",
        "CloudKit": "cloud framework",
        "GameKit": "game service framework",
        "MessageUI": "message framework",
        "Contacts": "contact framework",
        "UserDefaults": "persistent settings",
        "FileManager": "direct file access",
        "URLSession": "direct network access",
        "SecItem": "direct secure storage",
    }
    for token, label in forbidden.items():
        if re.search(rf"\b{re.escape(token)}\b", swift):
            findings.append(f"{key}: provider references prohibited {label}")
    if "context.publishTheme" not in swift:
        findings.append(f"{key}: provider does not publish through runtime context")
    if "ownerScopedResourceBundles" not in swift:
        findings.append(f"{key}: provider lacks owner-scoped bundle mapping")
    if "codex.norse" not in swift:
        findings.append(f"{key}: provider lacks Norse fallback identity")
    if record["codexID"] not in swift or record["entitlement"] not in swift:
        findings.append(f"{key}: compiled binding identity differs")
    return findings


def dump_package() -> dict[str, Any]:
    result = subprocess.run(
        ["swift", "package", "--package-path", str(PACKAGE_ROOT), "dump-package"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        error(f"swift package dump-package failed: {result.stderr.strip()}")
        return {}
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exception:
        error(f"swift package dump-package returned invalid JSON: {exception}")
        return {}


def validate_package_graph() -> None:
    package = dump_package()
    products = {item.get("name") for item in package.get("products", [])}
    required = {record["product"] for record in PROVIDERS.values()}.union(
        {"RuneScribeCloudSyncModule", "RuneScribeGameCenterModule"}
    )
    missing = sorted(required - products)
    if missing:
        error(f"architecture package lacks products: {', '.join(missing)}")
    targets = {item.get("name"): item for item in package.get("targets", [])}
    for record in PROVIDERS.values():
        target = targets.get(record["product"], {})
        dependencies = {
            item.get("byName", [None])[0]
            for item in target.get("dependencies", [])
            if isinstance(item, dict) and item.get("byName")
        }
        if dependencies != {"RuneScribeContracts", "RuneScribeRuntimeCore"}:
            error(f"{record['product']}: target dependencies differ")
    expected_dependencies = {
        "RuneScribeProgressionSyncDomain": {"RuneScribeContracts"},
        "RuneScribeCloudSyncModule": {"RuneScribeProgressionSyncDomain"},
        "RuneScribeGameCenterModule": {"RuneScribeContracts"},
    }
    for product, expected in expected_dependencies.items():
        target = targets.get(product, {})
        dependencies = {
            item.get("byName", [None])[0]
            for item in target.get("dependencies", [])
            if isinstance(item, dict) and item.get("byName")
        }
        if dependencies != expected:
            error(f"{product}: target dependencies differ")
    progression_dependencies = {
        item.get("byName", [None])[0]
        for item in targets.get("RuneScribeProgressionModule", {}).get("dependencies", [])
        if isinstance(item, dict) and item.get("byName")
    }
    if "RuneScribeProgressionSyncDomain" not in progression_dependencies:
        error("Progression target does not own its synchronization domain")


def validate_host() -> None:
    host = (ROOT / "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift").read_text(
        encoding="utf-8"
    )
    platform_environment = (
        ROOT
        / "Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/Qualification/ApplePlatformServiceEnvironment.swift"
    ).read_text(encoding="utf-8")
    for record in PROVIDERS.values():
        bootstrap = f"{record['product']}Bootstrap"
        for required in (
            f"import {record['product']}",
            f"{bootstrap}.ownerScopedResourceBundles",
            f"{bootstrap}.register(with: runtime)",
        ):
            if required not in host:
                error(f"host lacks {required}")
    for required in (
        "platformEnvironment = .normalRoute(",
        "RuneScribeServiceKeys.cloudSyncTransport",
        "RuneScribeServiceKeys.gameCenterReporting",
    ):
        if required not in host:
            error(f"host lacks runtime-owned platform integration: {required}")
    for required in (
        "@MainActor public init(",
        "AppleCloudKitProgressionTransport()",
        "AppleGameCenterReportingAdapter()",
    ):
        if required not in platform_environment:
            error(
                "platform environment lacks runtime-owned production integration: "
                + required
            )


def validate_entitlements() -> None:
    for relative in (
        "Config/RuneScrib-macOS.entitlements",
        "Config/RuneScrib-iOS.entitlements",
    ):
        path = ROOT / relative
        try:
            document = plistlib.loads(path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as exception:
            error(f"{relative}: invalid or missing entitlements: {exception}")
            continue
        for key, expected in EXPECTED_ENTITLEMENTS.items():
            if document.get(key) != expected:
                error(f"{relative}: {key} differs")


def validate_game_center_catalog() -> None:
    path = (
        PACKAGE_ROOT
        / "Sources/RuneScribeGameCenterModule/Resources/GameCenter-Achievement-Catalog-v1.0.json"
    )
    catalog = load_json(path)
    achievements = catalog.get("achievements", [])
    if len(achievements) != 15:
        error("Game Center catalog must contain 15 achievements")
        return
    identifiers = [item.get("gameCenterIdentifier") for item in achievements]
    if len(set(identifiers)) != len(identifiers):
        error("Game Center catalog contains duplicate identifiers")
    if catalog.get("pointTotal") != 220 or sum(
        item.get("points", 0) for item in achievements
    ) != 220:
        error("Game Center catalog point total differs")
    if catalog.get("leaderboardsEnabled") is not False:
        error("Game Center leaderboards must remain disabled")
    placeholder_terms = ("placeholder", "example", "temporary", "tbd", "todo", "beta")
    for identifier in identifiers:
        if not isinstance(identifier, str) or any(
            term in identifier.lower() for term in placeholder_terms
        ):
            error(f"Game Center catalog has invalid production identifier: {identifier}")


def validate_cloud_privacy_boundary() -> None:
    policy_root = PACKAGE_ROOT / "Sources/RuneScribeCloudSyncModule"
    domain_root = PACKAGE_ROOT / "Sources/RuneScribeProgressionSyncDomain"
    if {path.name for path in policy_root.glob("*.swift")} != {"CloudSyncPolicy.swift"}:
        error("Cloud orchestration policy source file inventory differs")
    required_domain_files = {
        "CloudProgressionSchema.swift",
        "CloudProgressionCodec.swift",
        "CloudProgressionMerge.swift",
    }
    if {path.name for path in domain_root.glob("*.swift")} != required_domain_files:
        error("Progression synchronization domain source file inventory differs")
    codec = (domain_root / "CloudProgressionCodec.swift").read_text(encoding="utf-8")
    required_rejections = (
        "cipherkey",
        "plaintext",
        "contact",
        "phonenumber",
        "emailaddress",
        "rawrelationship",
        "messagetext",
        "messagebytes",
        "qrcode",
        "keychain",
        "privatelog",
        "packagebytes",
        "encryptedpackage",
    )
    for field in required_rejections:
        if f'"{field}"' not in codec:
            error(f"Cloud codec lacks prohibited-field rejection: {field}")


def validate_external_service_runtime_binding() -> None:
    required_sources = {
        "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/ProgressionModule.swift": (
            "context.progressionExternalSyncClient()",
            "ProgressionExternalSnapshotSubmitProcessor",
            "client.mergeDeliveries()",
            "client.acknowledge(",
        ),
        "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/ProgressionServiceActor.swift": (
            "func externalSyncState(",
            "func applyExternalMerge(",
            "repository.commit(",
        ),
        "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeProgressionExternalSync.swift": (
            "RuntimeProgressionExternalProjectionMapper",
            "knownStatisticIDs",
            "knownAchievementIDs",
            "knownCodexIDs",
            "knownTitleIDs",
        ),
        "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCloudGameCenterCoordinator.swift": (
            "func progressionMergeDeliveries()",
            "func acknowledgeProgressionMerge(",
            "private func processCloudIfPossible()",
            "private func processGameCenterIfPossible()",
            "cloudAccountOperationEpoch",
            "gameCenterOperationEpoch",
        ),
        "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeCloudGameCenterGateway.swift": (
            "func cloudClient(",
            "func gameCenterClient(",
            "runtimeGeneration",
        ),
        "Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/Cloud/AppleCloudKitProgressionTransport.swift": (
            "container.privateCloudDatabase",
            "CloudSyncFetchResultDTO.maximumPayloadByteCount",
            "accountScopeDigest",
        ),
        "Packages/RuneScribeArchitecture/Sources/RuneScribePlatform/GameCenter/AppleGameCenterReportingAdapter.swift": (
            "func accountScopeDigest()",
            "GKAchievement.report(",
        ),
    }
    for relative, tokens in required_sources.items():
        path = ROOT / relative
        if not path.is_file():
            error(f"external-service production binding is missing: {relative}")
            continue
        source = path.read_text(encoding="utf-8")
        for token in tokens:
            if token not in source:
                error(f"external-service production binding lacks {token}: {relative}")

    required_tests = (
        "Packages/RuneScribeArchitecture/Tests/RuneScribeCloudSyncModuleTests/CloudProgressionMergeTests.swift",
        "Packages/RuneScribeArchitecture/Tests/RuneScribeGameCenterModuleTests/GameCenterReportingTests.swift",
        "Packages/RuneScribeArchitecture/Tests/RuneScribeProgressionModuleTests/ProgressionExternalSyncTests.swift",
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterGatewayTests.swift",
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/RuntimeExternalServicesSettingsPresentationTests.swift",
    )
    for relative in required_tests:
        if not (ROOT / relative).is_file():
            error(f"external-service regression suite is missing: {relative}")


def validate_sharing_boundary() -> None:
    required = (
        "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/SharePresentationContracts.swift",
        "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Domain/Formats/SharePresentationSectionCodec.swift",
        "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Messages/SharePresentationLifecycle.swift",
        "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ShareArtifactRenderer.swift",
        "Packages/RuneScribeArchitecture/Tests/RuneScribeCoreModuleTests/SharePresentationSectionTests.swift",
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/ShareArtifactRendererTests.swift",
    )
    for relative in required:
        if not (ROOT / relative).is_file():
            error(f"sharing completion file is missing: {relative}")


def validate_version() -> None:
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    if 'MARKETING_VERSION: "1.0.41"' not in project:
        error("marketing version changed")
    if 'CURRENT_PROJECT_VERSION: "41"' not in project:
        error("build number changed")


def validate_negative_controls() -> None:
    key = "moonleaf"
    record = PROVIDERS[key]
    resource_root = PACKAGE_ROOT / "Sources" / record["product"] / "Resources"
    manifest = load_json(
        resource_root / "Production/Resource-Integrity-Manifest-v1.0.json"
    )
    mutated = copy.deepcopy(manifest)
    if isinstance(mutated.get("files"), list) and mutated["files"]:
        mutated["files"][0]["sha256"] = "0" * 64
        findings = validate_integrity_manifest(key, record, resource_root, mutated)
        if not any("SHA-256 differs" in finding for finding in findings):
            error("internal negative control failed for provider hash mutation")
    else:
        error("internal negative control cannot mutate provider manifest")


def validate_evidence() -> None:
    has_git = git_available()
    for filename in REQUIRED_MARKDOWN_EVIDENCE:
        path = EVIDENCE_ROOT / filename
        if not path.is_file() or not path.read_text(encoding="utf-8").strip():
            error(f"required roadmap-completion evidence is missing or empty: {filename}")

    for filename in REQUIRED_JSON_EVIDENCE:
        path = EVIDENCE_ROOT / filename
        document = load_json(path)
        if not document:
            continue
        relative = path.relative_to(ROOT)
        if document.get("schemaVersion") != "1.0":
            error(f"{relative}: schemaVersion must be 1.0")
        commands = document.get("command")
        if not isinstance(commands, list) or not commands or not all(
            isinstance(command, str) and command.strip() for command in commands
        ):
            error(f"{relative}: command must be a nonempty string array")
        if not isinstance(document.get("environment"), dict):
            error(f"{relative}: environment must be an object")
        revision = document.get("sourceRevision")
        if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
            error(f"{relative}: sourceRevision must be a lowercase 40-character Git SHA")
        elif has_git:
            exists = subprocess.run(
                ["git", "cat-file", "-e", f"{revision}^{{commit}}"],
                cwd=ROOT,
                check=False,
                capture_output=True,
            )
            ancestor = subprocess.run(
                ["git", "merge-base", "--is-ancestor", revision, "HEAD"],
                cwd=ROOT,
                check=False,
                capture_output=True,
            )
            if exists.returncode != 0 or ancestor.returncode != 0:
                error(f"{relative}: sourceRevision is not an existing ancestor of HEAD")
        if document.get("result") != "PASS":
            error(f"{relative}: result must be PASS")
        if document.get("failures") != []:
            error(f"{relative}: failures must be an empty array")
        artifact_paths = document.get("artifactPaths")
        if not isinstance(artifact_paths, list) or not artifact_paths:
            error(f"{relative}: artifactPaths must be a nonempty array")
            continue
        for artifact in artifact_paths:
            if not isinstance(artifact, str):
                error(f"{relative}: artifactPaths entries must be strings")
                continue
            artifact_path = Path(artifact)
            if artifact_path.is_absolute() or ".." in artifact_path.parts:
                error(f"{relative}: artifact path is not repository-relative: {artifact}")
                continue
            if not (ROOT / artifact_path).exists():
                error(f"{relative}: artifact path does not exist: {artifact}")


def main() -> int:
    validate_source_manifest()
    validate_package_graph()
    all_resource_ids: set[str] = set()
    for key, record in PROVIDERS.items():
        findings = validate_provider(key, record)
        ERRORS.extend(findings)
        integrity = load_json(
            PACKAGE_ROOT
            / "Sources"
            / record["product"]
            / "Resources/Production/Resource-Integrity-Manifest-v1.0.json"
        )
        for entry in integrity.get("files", []):
            resource_id = entry.get("resourceID")
            if resource_id in all_resource_ids:
                error(f"duplicate production resource ID across providers: {resource_id}")
            all_resource_ids.add(resource_id)
    expected_output_count = sum(record["outputs"] for record in PROVIDERS.values())
    if len(all_resource_ids) != expected_output_count:
        error(
            f"production output resource count is {len(all_resource_ids)}, "
            f"expected {expected_output_count}"
        )
    validate_host()
    validate_entitlements()
    validate_game_center_catalog()
    validate_cloud_privacy_boundary()
    validate_external_service_runtime_binding()
    validate_sharing_boundary()
    validate_version()
    validate_negative_controls()
    validate_evidence()

    if ERRORS:
        print("Roadmap-completion guard failed:")
        for finding in sorted(set(ERRORS)):
            print(f"- {finding}")
        return 1
    print(
        "Roadmap-completion guard passed: four providers, 245 exact outputs, "
        "cloud privacy, Game Center catalog, sharing boundary, entitlements, and host integration."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
