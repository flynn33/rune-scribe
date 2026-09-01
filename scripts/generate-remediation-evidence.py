#!/usr/bin/env python3
"""Assemble deterministic remediation evidence and owner-test artifacts."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
from typing import Any, Iterable
import zipfile
import zlib

try:
    from jsonschema import Draft202012Validator
except ImportError:  # pragma: no cover - surfaced as a deterministic environment failure
    Draft202012Validator = None  # type: ignore[assignment]


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_PREFIX = "docs/verification/remediation-v1"
ARTIFACT_PREFIX = "artifacts/remediation-v1"
ARTIFACT_ROOT = ROOT / ARTIFACT_PREFIX
VERSION = "1.0.40"
BUILD = "40"
SCHEMA_VERSION = "1.0"
EXPECTED_BUNDLE_IDENTIFIER = "com.runescribe.app"
EXPECTED_PACKAGE_MANIFEST_SHA256 = (
    "f55dcd4724d07800479d8acd7b41ad62674d90cd53b315c70447c8024e7f2313"
)
EXPECTED_GATE_CATALOG_SHA256 = (
    "3ea8bb864224d2de1ddf7521b4f2a8ca8b9379f5e028bc94e3525ef77845f8d3"
)
EXPECTED_FINDING_MATRIX_SHA256 = (
    "e9e973a590c3fe7504eecf1e22f3bca021d942b1daeeea68b26162b16b2d597e"
)
EXPECTED_TEST_MATRIX_SHA256 = (
    "04a91856646f01af203ce0f685fe94951ac15a2184b8340f21764712533142f1"
)
EXPECTED_BASELINE_REVISION = "5e4e08ad17a54378ffed2b3a66691594961fe047"
EXPECTED_BASELINE_MANIFEST_AGGREGATE = (
    "fe59cb5da32a0632b76a61c1071933a7f23b4ad1583bc4b902d6d391ee8e69b4"
)
EXPECTED_BASELINE_ARCHIVE_SHA256 = (
    "75df2709f203de247064204090f00c58806792e235e45e6f196650e79cf724dc"
)
EXPECTED_BASELINE_FILE_COUNT = 991
BASELINE_MANIFEST_EXCLUDES = (
    ".DS_Store",
    ".build",
    ".git",
    "DerivedData",
    "artifacts/remediation-v1",
    "docs/verification/remediation-v1",
    "docs/verification/remediation-v1/SOURCE-MANIFEST.before.json",
)

GATE_CATALOG = f"{EVIDENCE_PREFIX}/REMEDIATION-GATES-v1.0.json"
TEST_MATRIX_CATALOG = f"{EVIDENCE_PREFIX}/TEST-MATRIX-v1.0.csv"
FINDING_MATRIX_CATALOG = f"{EVIDENCE_PREFIX}/FINDING-CLOSURE-MATRIX-v1.0.json"
SOURCE_MANIFEST = f"{EVIDENCE_PREFIX}/SOURCE-MANIFEST.json"
BASELINE = f"{EVIDENCE_PREFIX}/Baseline.json"
SOURCE_MANIFEST_BEFORE = f"{EVIDENCE_PREFIX}/SOURCE-MANIFEST.before.json"
DEFECT_CLOSURE = f"{EVIDENCE_PREFIX}/DefectClosure.json"
EVIDENCE_INDEX = f"{EVIDENCE_PREFIX}/EvidenceIndex.json"
COMPLETION_JSON = f"{EVIDENCE_PREFIX}/CompletionReport.json"
COMPLETION_MARKDOWN = f"{EVIDENCE_PREFIX}/CompletionReport.md"
EVIDENCE_HANDOFF = f"{EVIDENCE_PREFIX}/OwnerTestCandidateHandoff.md"
COMPLETION_LOG = f"{EVIDENCE_PREFIX}/GateRun/check-remediation-completion.log"
TEST_EXECUTION_INDEX = f"{EVIDENCE_PREFIX}/TestExecutionIndex.json"
PUBLICATION_AUDIT_RECORD = f"{EVIDENCE_PREFIX}/PublicationAudit.json"
IPAD_QUALIFICATION_SCHEMA = f"{EVIDENCE_PREFIX}/IPAD-QUALIFICATION.schema.json"

MACOS_ZIP = f"{ARTIFACT_PREFIX}/RuneScrib-macOS-Release.app.zip"
IPHONE_ZIP = f"{ARTIFACT_PREFIX}/RuneScrib-iPhoneSimulator-Release.app.zip"
IPAD_QUALIFICATION = (
    f"{ARTIFACT_PREFIX}/RuneScrib-iPadSimulator-Qualification.json"
)
OWNER_ZIP = f"{ARTIFACT_PREFIX}/Rune-Scribe-Owner-Test-Candidate-v1.0.zip"
PAYLOAD_ZIP = f"{ARTIFACT_PREFIX}/Rune-Scribe-Owner-Test-Payload-v1.0.zip"
EXTERNAL_SHA256SUMS = f"{ARTIFACT_PREFIX}/SHA256SUMS"
ARTIFACT_HANDOFF = f"{ARTIFACT_PREFIX}/OWNER-TEST-CANDIDATE-HANDOFF.md"
SCREENSHOT_INDEX = f"{ARTIFACT_PREFIX}/Screenshot-Index.md"
TEST_SUMMARY = f"{ARTIFACT_PREFIX}/Test-Summary.json"
ADJACENT_COMPLETION_JSON = f"{ARTIFACT_PREFIX}/CompletionReport.json"
ADJACENT_COMPLETION_MARKDOWN = f"{ARTIFACT_PREFIX}/CompletionReport.md"

RECORD_GATES: dict[str, tuple[str, ...]] = {
    "ShareBuilderValidation.json": (
        "RC-008", "RC-010", "RC-011", "RC-012", "RC-013",
    ),
    "CipherInvitationValidation.json": ("RC-009", "RC-014", "RC-015"),
    "BaseThemeFailureValidation.json": ("RC-016", "RC-017", "RC-018"),
    "AppearanceDefaultsValidation.json": ("RC-019", "RC-020"),
    "ThemeRootBackgroundValidation.json": ("RC-021",),
    "NorseProductionProvenanceValidation.json": (
        "RC-006", "RC-007", "RC-022",
    ),
    "SourceManifestValidation.json": (
        "RC-001", "RC-002", "RC-003", "RC-004",
    ),
    "CompatibilityValidation.json": ("RC-024", "RC-025"),
    "SecurityPrivacyValidation.json": ("RC-026", "RC-027"),
    "AccessibilityValidation.json": ("RC-036", "RC-037"),
    "NegativeMutations.json": ("RC-029",),
    "FullRegression.json": (
        "RC-005", "RC-023", "RC-028", "RC-031", "RC-032", "RC-033",
        "RC-034", "RC-035", "RC-038", "RC-039", "RC-040", "RC-041",
        "RC-042",
    ),
    "AttributionAudit.json": ("RC-030",),
}

RECORD_BUILD_ORDER = (
    "NegativeMutations.json",
    "ShareBuilderValidation.json",
    "CipherInvitationValidation.json",
    "BaseThemeFailureValidation.json",
    "AppearanceDefaultsValidation.json",
    "ThemeRootBackgroundValidation.json",
    "NorseProductionProvenanceValidation.json",
    "SourceManifestValidation.json",
    "CompatibilityValidation.json",
    "SecurityPrivacyValidation.json",
    "AccessibilityValidation.json",
    "AttributionAudit.json",
)

FINDING_IDS = tuple(f"RSA-{index:03d}" for index in range(1, 13))
GATE_IDS = tuple(f"RC-{index:03d}" for index in range(1, 43))

NON_RECORD_TOP_LEVEL_JSON = {
    "Baseline.json",
    "CompletionReport.json",
    "DefectClosure.json",
    "EvidenceIndex.json",
    "REMEDIATION-GATES-v1.0.json",
    "FINDING-CLOSURE-MATRIX-v1.0.json",
    "SOURCE-MANIFEST.before.json",
    "SOURCE-MANIFEST.json",
    "TestExecutionIndex.json",
    "PublicationAudit.json",
    "IPAD-QUALIFICATION.schema.json",
}

TERMINAL_INDEX_PATHS = {
    GATE_CATALOG,
    TEST_MATRIX_CATALOG,
    FINDING_MATRIX_CATALOG,
    SOURCE_MANIFEST,
    COMPLETION_JSON,
    COMPLETION_MARKDOWN,
    DEFECT_CLOSURE,
    TEST_EXECUTION_INDEX,
    PUBLICATION_AUDIT_RECORD,
    IPAD_QUALIFICATION_SCHEMA,
}

FIXED_NON_GATING_BOUNDARIES = (
    "App Store Connect records",
    "live CloudKit account/container",
    "live Game Center sandbox",
    "distribution signing and public upload",
)

WORKSPACE_SCREENSHOT_CLAIM = "workspace/settings/vault screenshots"
WORKSPACE_SCREENSHOT_CLAIM_PATHS = (
    f"{EVIDENCE_PREFIX}/Screenshots/iphone-workspace-moonleaf.png",
    f"{EVIDENCE_PREFIX}/Screenshots/iphone-settings-moonleaf.png",
    f"{EVIDENCE_PREFIX}/Screenshots/iphone-vault-moonleaf.png",
)
CLOUD_GAME_CENTER_CLAIM = "cloud/game center test logs"
PERFORMANCE_RESOURCE_CLAIM = "performance/resource report"
EVIDENCE_INDEX_CLAIM = "all remediation JSON evidence"
CLAIM_EVIDENCE_PREFIX = f"{EVIDENCE_PREFIX}/ClaimEvidence"
CLOUD_GAME_CENTER_RESULTS = (
    f"{EVIDENCE_PREFIX}/GateRun/CloudGameCenter-Test-Results.json"
)
PERFORMANCE_RESOURCE_RESULTS = (
    f"{EVIDENCE_PREFIX}/GateRun/Performance-Resource-Results.json"
)
BUILT_PRODUCT_INSPECTION_RESULTS = (
    f"{EVIDENCE_PREFIX}/GateRun/Built-Product-Inspection.json"
)
NO_GIT_QUALIFICATION_RESULT = (
    f"{EVIDENCE_PREFIX}/GateRun/NoGit-Completion-Result.json"
)
STRUCTURED_TEST_LOG_KEYS = {
    "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
    "version", "build", "suiteName", "totals", "rawLog", "rawLogSHA256",
    "executions",
}
STRUCTURED_TEST_LOG_EXECUTION_KEYS = {
    "testID", "scenario", "result", "suiteName", "command",
    "requiredEvidence",
}
CLAIM_EVIDENCE_KEYS = {
    "schemaVersion", "status", "claim", "sourceManifestSHA256",
    "sourceRevision", "version", "build", "gateIDs", "testIDs",
    "executions", "artifacts", "semanticMarkers",
}
CLAIM_EXECUTION_KEYS = {
    "testID", "result", "suiteName", "command", "requiredEvidence",
    "log", "logSHA256",
}
CLAIM_ARTIFACT_KEYS = {"path", "sha256", "kind"}
NO_GIT_RESULT_KEYS = {
    "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
    "version", "build", "testID", "command", "expectedOutput",
    "expectedOutputSHA256",
}
CLOUD_GAME_CENTER_MARKERS = (
    "deterministic-offline-unavailable",
    "queue",
    "retry-merge",
    "account-change",
    "corruption-quarantine",
    "monotonic-reporting",
    "no-ownership-path",
    "privacy-offline-utility",
    "built-entitlement-configuration-inspection",
)
PERFORMANCE_RESOURCE_MARKERS = (
    "preview-churn-cancel",
    "large-inscriptions",
    "cache-release",
    "optional-provider-fallback",
    "bounded-session-retention",
    "preview-under-4-mib",
    "preview-4:3",
    "theme-budgets",
)
PLATFORM_SCREENSHOT_CLAIM_PATHS: dict[str, tuple[str, ...]] = {
    "macOS screenshots": tuple(
        f"{EVIDENCE_PREFIX}/Screenshots/{name}" for name in (
            "macos-optional-provider.png",
            "macos-share-builder.png",
            "macos-share-builder-moonleaf.png",
            "optional-provider-workspace.png",
        )
    ),
    "iPhone screenshots": tuple(
        f"{EVIDENCE_PREFIX}/Screenshots/{name}" for name in (
            "iphone-appearance-defaults.png",
            "iphone-base-failure-banner.png",
            "iphone-cipher-share.png",
            "iphone-norse-result.png",
            "iphone-norse-workspace.png",
            "iphone-settings-codices.png",
            "iphone-settings-moonleaf.png",
            "iphone-share-builder-cipher.png",
            "iphone-share-builder-established.png",
            "iphone-share-builder-first.png",
            "iphone-share-builder-message.png",
            "iphone-vault-moonleaf.png",
            "iphone-vault.png",
            "iphone-workspace-moonleaf.png",
        )
    ),
    "iPad screenshots": (
        f"{EVIDENCE_PREFIX}/Screenshots/ipad-share-builder.png",
    ),
}
PLATFORM_SCREENSHOT_CLAIM_PLATFORMS = {
    "macOS screenshots": "macOS",
    "iPhone screenshots": "iPhone Simulator",
    "iPad screenshots": "iPad Simulator",
}
WRITTEN_SCREENSHOT_CONTRACTS: dict[str, tuple[str, str]] = {
    f"{EVIDENCE_PREFIX}/Screenshots/macos-share-builder-moonleaf.png": (
        "macOS",
        "Moonleaf selected in the macOS Share Builder, demonstrating the "
        "optional provider's themed builder surface.",
    ),
}
DOMAIN_RESULT_PRODUCER = "scripts/capture-remediation-domain-results.py"
EXPECTED_DOMAIN_PRODUCER_SHA256 = (
    "e57a86bcb6e310de5035298ceb3afeec6d5699aa31bd4ee9b1a3868cd6a5a8d7"
)
EXPECTED_DOMAIN_PRODUCER_POLICY_SHA256 = (
    "6c99db1d6169d568851486ef59a6b5db7942299597629dd250a788bf0b8a1a23"
)
SHIPPING_CHECKER_PATH = "scripts/check-shipping-products.sh"
EXPECTED_SHIPPING_CHECKER_SHA256 = (
    "23e7900963a7bc2cf0e2fd505eaea095961d023c40b4bb4fa03a5264b80c675e"
)
EXPECTED_SHIPPING_CHECK_COUNT = 101
DOMAIN_SHIPPING_VALIDATION_LOG = (
    f"{EVIDENCE_PREFIX}/GateRun/shipping-products.log"
)

# Each implementation expectation is grounded in the exact ordered source-area
# controls selected here. The package digest locks both arrays and their order.
IMPLEMENTATION_SOURCE_AREA_INDEXES: dict[str, tuple[tuple[int, ...], ...]] = {
    "RSA-001": ((0, 1), (0, 1, 2, 3, 4), (0, 1)),
    "RSA-002": ((0, 1, 2, 3), (0, 1, 2, 3), (3, 4, 5)),
    "RSA-003": ((0, 1, 2), (0, 1, 2), (1, 2)),
    "RSA-004": ((0, 1, 2), (2, 3, 4), (4, 5), (0, 1, 2, 3, 6)),
    "RSA-005": ((0, 1), (0, 1), (0, 2, 3, 4)),
    "RSA-006": ((0,), (0,), (1, 2)),
    "RSA-007": ((0, 1), (0, 1), (2, 3)),
    "RSA-008": ((0,), (0, 1, 2, 3), (0, 1), (1, 2, 3)),
    "RSA-009": ((0, 1, 2, 3), (0, 3), (3,), (0, 1, 2, 3)),
    "RSA-010": ((0, 3), (0, 1, 2), (0, 1, 2, 3)),
    "RSA-011": ((0, 1, 2),),
    "RSA-012": ((0,), (0,)),
}

# Every locked source-area expectation resolves to one exact, reviewable path
# tuple. Implementation expectations below are derived only from these fixed
# tuples, never from caller-selected filenames or token similarity.
SOURCE_AREA_PATHS: dict[str, tuple[tuple[str, ...], ...]] = {
    "RSA-001": (
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ThemeVisualComponents.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession+ThemeArtifacts.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContentView.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/SettingsView.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/VaultProgressView.swift",),
    ),
    "RSA-002": (
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Messages/MessageSend.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Messages/ShareArtifactRegistry.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ShareBuilderModel.swift",
        ),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/Policy.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeIOGateway.swift",
        ),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Resources/module-manifest.json",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/OutboundSharePresentationBuilder.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ReceivedPresentationSummary.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ShareBuilderModel.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/ShareBuilderView.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Sharing/SharePolicy.swift",
        ),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession+Progression.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession+ShareBuilder.swift",
        ),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContentView.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeMessageComposeView.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeNativeShareView.swift",
        ),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/CipherLibraryView.swift",),
    ),
    "RSA-003": (
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/CipherLibraryView.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession+Commands.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Application/RuneScribeCoreApplicationService.swift",),
    ),
    "RSA-004": (
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/NorseThemeModule.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/NorseThemeQualification.swift",
        ),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/NorseBaseThemeResources.swift",),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/ThemeCoordinatorContracts.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeThemeContribution.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeThemeEndpoints.swift",
        ),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/Resources/module-manifest.json",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeThemeCoordinatorModule/ThemeCoordinatorService.swift",
        ),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RootView.swift",),
        ("scripts/check-shipping-products.sh",),
    ),
    "RSA-005": (
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/RuntimeSettingsContracts.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/RuntimeArtifactSelectionContracts.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeRuntimeCore/RuntimeSettingsGateway.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Presentation/RuneScribeUISession+AppearanceDefaults.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/SettingsView.swift",),
    ),
    "RSA-006": (
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v2.0.json",),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Source/Norse-Production-Provenance-Tooling.md",
            "scripts/check-norse-production-provenance.py",
            "scripts/generate-norse-production-provenance.py",
        ),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Metadata/Norse-Production-Asset-Provenance-v2.0.json",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v2.0.json",
        ),
    ),
    "RSA-007": (
        (
            "docs/product-roadmap/Rune-Scribe-Codex-Current-App-Delta-and-Implementation-Roadmap-v1.0.md",
            "docs/product-roadmap/Rune-Scribe-Codex-Roadmap-Remediation-Amendment-v1.1.md",
            "docs/product-roadmap/Rune-Scribe-Codex-System-Spec-v1.0.md",
        ),
        ("docs/architecture/RoadmapAlignment.md",),
        ("docs/verification/roadmap-alignment.json",),
        ("scripts/check-roadmap-alignment.sh",),
    ),
    "RSA-008": (
        ("scripts/generate-source-manifest.py",),
        ("scripts/check-roadmap-completion.py",),
        ("scripts/check-documentation-alignment.py",),
        (
            "scripts/capture-remediation-domain-results.py",
            "scripts/check-remediation-completion.py",
            "scripts/generate-remediation-evidence.py",
        ),
    ),
    "RSA-009": (
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/CoreModule.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeCoreModule/Resources/module-manifest.json",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/ProgressionCatalogResources.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/ProgressionModule.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeProgressionModule/Resources/module-manifest.json",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Resources/module-manifest.json",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/UIModule.swift",
            "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/RuneScribeUISessionTests.swift",
            "RuneScrib.xcodeproj/project.pbxproj",
            "project.yml",
            "scripts/check-remediation-completion.py",
            "scripts/generate-remediation-evidence.py",
        ),
        ("CHANGELOG.md",),
        ("docs/APP_STORE_SUBMISSION.md",),
        (
            "scripts/capture-remediation-domain-results.py",
            "scripts/generate-remediation-evidence.py",
        ),
    ),
    "RSA-010": (
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContactsView.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ImportConfirmView.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/LockView.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ReceivedMessageView.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RootView.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/SimulatorAccessibilityQualification.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/UnlockRevealView.swift",
        ),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/RuneTheme.swift",),
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/SemanticThemePresentation.swift",),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeAccessibilityPreferences.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeApplicationResourcePresentation.swift",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/RuntimeSimulatorQualification.swift",
            "RuneScrib/AppHost/RuneScribeRuntimeComposition.swift",
        ),
    ),
    "RSA-011": (
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views/ContentView.swift",),
        (
            "docs/superpowers/plans/2026-06-26-phase4-messages.md",
            "docs/superpowers/plans/2026-06-27-phase4-file-based-sharing.md",
        ),
        ("README.md",),
    ),
    "RSA-012": (
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeContracts/RuntimeArtifactSelectionContracts.swift",),
    ),
}

IMPLEMENTATION_PATHS: dict[str, tuple[tuple[str, ...], ...]] = {
    finding_id: tuple(
        tuple(sorted({
            path
            for source_index in indexes
            for path in SOURCE_AREA_PATHS[finding_id][source_index]
        }))
        for indexes in IMPLEMENTATION_SOURCE_AREA_INDEXES[finding_id]
    )
    for finding_id in IMPLEMENTATION_SOURCE_AREA_INDEXES
}
_DOMAIN_CAPTURE_PATH = "scripts/capture-remediation-domain-results.py"
IMPLEMENTATION_PATHS["RSA-009"] = tuple(
    tuple(sorted(
        (set(paths) - {_DOMAIN_CAPTURE_PATH})
        | ({_DOMAIN_CAPTURE_PATH} if index == 1 else set())
    ))
    for index, paths in enumerate(IMPLEMENTATION_PATHS["RSA-009"])
)


def is_shipping_source_config_or_project_path(relative: str) -> bool:
    return relative.startswith((
        "Packages/RuneScribeArchitecture/Sources/",
        "RuneScrib/",
        "Config/",
    )) or relative in {
        "Packages/RuneScribeArchitecture/Package.swift",
        "RuneScrib.xcodeproj/project.pbxproj",
        "project.yml",
    }


REMOVED_IMPLEMENTATION_PATHS: dict[str, dict[str, tuple[str, ...]]] = {
    finding_id: (
        {
            "Remove active placeholder/candidate ambiguity": (
                "Packages/RuneScribeArchitecture/Sources/"
                "RuneScribeNorseThemeModule/Resources/Source/"
                "make_norse_base_placeholders.swift",
            )
        }
        if finding_id == "RSA-006" else {}
    )
    for finding_id in FINDING_IDS
}


def validate_global_shipping_path_coverage(
    changed_final_paths: set[str], removed_paths: set[str]
) -> None:
    globally_locked_files = {
        path
        for policy in (SOURCE_AREA_PATHS, IMPLEMENTATION_PATHS)
        for finding_paths in policy.values()
        for expectation_paths in finding_paths
        for path in expectation_paths
    }
    missing_shipping_bindings = sorted(
        path
        for path in changed_final_paths - globally_locked_files
        if is_shipping_source_config_or_project_path(path)
    )
    if missing_shipping_bindings:
        raise EvidenceError(
            "exact path policy omits baseline-changed shipping source/config/project "
            "paths: " + ", ".join(missing_shipping_bindings)
        )
    globally_locked_removed_files = {
        path
        for finding_bindings in REMOVED_IMPLEMENTATION_PATHS.values()
        for paths in finding_bindings.values()
        for path in paths
    }
    baseline_deleted_shipping_paths = {
        path
        for path in removed_paths
        if is_shipping_source_config_or_project_path(path)
    }
    missing_shipping_tombstones = sorted(
        baseline_deleted_shipping_paths - globally_locked_removed_files
    )
    unexpected_shipping_tombstones = sorted(
        globally_locked_removed_files - baseline_deleted_shipping_paths
    )
    if missing_shipping_tombstones:
        raise EvidenceError(
            "exact removal policy omits deleted shipping paths: "
            + ", ".join(missing_shipping_tombstones)
        )
    if unexpected_shipping_tombstones:
        raise EvidenceError(
            "exact removal policy names paths not deleted from the baseline: "
            + ", ".join(unexpected_shipping_tombstones)
        )

# Exact expectation-specific locked TEST-MATRIX IDs. Their union covers every
# gate assigned to the corresponding finding, without reusing one broad union
# for every prose expectation.
TEST_EXPECTATION_IDS: dict[str, tuple[tuple[str, ...], ...]] = {
    "RSA-001": (
        ("T-005", "T-006", "T-010", "T-011", "T-012", "T-013", "T-014", "T-112", "T-113", "T-114"),
        ("T-010", "T-011", "T-012", "T-013", "T-014", "T-023", "T-112", "T-113", "T-114"),
        ("T-015",),
    ),
    "RSA-002": (
        ("T-020", "T-021", "T-024", "T-032", "T-033", "T-038"),
        ("T-042",),
        ("T-025", "T-026", "T-027", "T-028", "T-029", "T-030", "T-031"),
        ("T-035", "T-036", "T-037"),
        ("T-022", "T-023", "T-065", "T-115", "T-116"),
    ),
    "RSA-003": (
        ("T-040", "T-041", "T-042"),
        ("T-043", "T-092"),
        ("T-044", "T-045", "T-046", "T-054", "T-090", "T-091", "T-093"),
        ("T-047",),
    ),
    "RSA-004": (
        ("T-050", "T-051", "T-052", "T-055"),
        ("T-054", "T-093"),
        ("T-053",),
        ("T-031", "T-056", "T-094", "T-095"),
    ),
    "RSA-005": (
        ("T-033", "T-034", "T-060", "T-061", "T-066", "T-067"),
        ("T-062", "T-063"),
        ("T-064", "T-065", "T-115"),
        ("T-022", "T-024", "T-032", "T-060"),
    ),
    "RSA-006": (
        ("T-080", "T-081"),
        ("T-082",),
        ("T-055", "T-056", "T-118"),
    ),
    "RSA-007": (("T-002",), ("T-002",), ("T-120",)),
    "RSA-008": (
        ("T-004", "T-015", "T-047", "T-072", "T-101"),
        ("T-005",),
        ("T-006", "T-120"),
    ),
    "RSA-009": (
        ("T-120",),
        ("T-096", "T-097", "T-112", "T-113", "T-114"),
        ("T-119", "T-121"),
    ),
    "RSA-010": (
        ("T-070", "T-071", "T-072"),
        ("T-023", "T-070", "T-071", "T-112", "T-113", "T-114"),
        ("T-073",),
    ),
    "RSA-011": (("T-083",),),
    "RSA-012": (("T-084",), ("T-085",), ("T-111",)),
}

GATE_SCREENSHOT_CLAIMS = {
    "Screenshots/iphone-norse-workspace.png",
    "Screenshots/iphone-norse-result.png",
    "Screenshots/optional-provider-workspace.png",
    "Screenshots/iphone-share-builder-message.png",
    "Screenshots/iphone-share-builder-cipher.png",
    "Screenshots/iphone-base-failure-banner.png",
    "Screenshots/iphone-appearance-defaults.png",
}
HUMAN_CLAIM_IGNORED_TOKENS = {
    "and", "evidence", "log", "logs", "report", "reports", "screenshot",
    "screenshots", "test", "tests",
}

PACKAGE_REQUIRED_FILES = (
    "controls/REMEDIATION-GATES-v1.0.json",
    "controls/FINDING-CLOSURE-MATRIX-v1.0.json",
    "controls/TEST-MATRIX-v1.0.csv",
    "references/audit/Rune-Scribe-Roadmap-Audit-Findings-v1.0.json",
    "schemas/EVIDENCE-RECORD.schema.json",
    "schemas/COMPLETION-REPORT.schema.json",
    "schemas/REMEDIATION-STATE.schema.json",
    "templates/OWNER-TEST-CANDIDATE-HANDOFF.md",
)

RECORD_REQUIRED_KEYS = {
    "logs",
    "artifacts",
    "startedAt",
    "endedAt",
    "notes",
}
TEST_EXECUTION_KEYS = {
    "result",
    "suiteName",
    "command",
    "log",
    "requiredEvidence",
    "evidence",
}
SUITE_KEYS = {
    "name", "platform", "kind", "executed", "passed", "failed", "skipped",
    "log",
}
SCREENSHOT_KEYS = {"path", "platform", "description"}
SIMULATOR_KEYS = {"name", "udid", "runtime"}
TOP_LEVEL_INPUT_KEYS = {
    "schemaVersion",
    "sourceRevision",
    "environment",
    "records",
    "findings",
    "screenshots",
    "suites",
    "simulators",
    "bundleIdentifier",
    "resetCommands",
    "seedCommands",
    "nonGatingExternal",
    "tests",
    "publicationAudit",
}

PUBLICATION_AUDIT_KEYS = {
    "command",
    "log",
    "checkedAt",
    "branch",
    "defaultBranch",
    "remoteInspectionPerformed",
    "headTags",
    "sourceMergedToDefault",
    "releasePublished",
    "uploadPerformed",
    "notarizationPerformed",
    "testFlightPerformed",
    "appStorePerformed",
    "rolloutPerformed",
}

FINDING_INPUT_KEYS = {
    "changedFiles",
    "removedFiles",
    "removalBindings",
    "implementationBindings",
    "sourceAreaBindings",
    "testBindings",
}
IPAD_QUALIFICATION_KEYS = {
    "schemaVersion",
    "status",
    "sourceManifestSHA256",
    "sourceRevision",
    "version",
    "build",
    "simulator",
    "iOSProduct",
    "suites",
    "screenshots",
}
IPAD_PRODUCT_KEYS = {"path", "sha256", "bundleIdentifier"}
IPAD_SUITE_KEYS = {
    "name", "result", "executed", "passed", "failed", "skipped", "log",
    "logSHA256",
}
IPAD_SCREENSHOT_KEYS = {"path", "sha256"}

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xca\xfe\xba\xbf",
    b"\xbe\xba\xfe\xca",
    b"\xbf\xba\xfe\xca",
}

HEX_40 = re.compile(r"[0-9a-f]{40}")
HEX_64 = re.compile(r"[0-9a-f]{64}")
TEST_ID = re.compile(r"T-[0-9]{3}")
GATE_ID = re.compile(r"RC-[0-9]{3}")
SIMULATOR_UDID = re.compile(
    r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
)
BUNDLE_IDENTIFIER = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+"
)


class EvidenceError(ValueError):
    """Raised when inputs cannot produce truthful deterministic evidence."""


def json_bytes(document: object) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def no_git_command(source_hash: str) -> str:
    return (
        "python3 scripts/check-remediation-completion.py --no-git-child "
        f"--expected-source-hash {source_hash}"
    )


def no_git_expected_output() -> str:
    return (
        "PASS: 42 required gates validate against one source tree "
        "(copied tree without Git ancestry)\n"
    )


def completion_checker_expected_output(source_revision: str | None) -> bytes:
    metadata = (
        "Git revision and source manifest"
        if source_revision is not None
        else "source manifest without Git ancestry"
    )
    return (
        "PASS: 42 required gates validate against one source tree "
        f"({metadata})\n"
    ).encode("utf-8")


def load_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        raise EvidenceError(f"{label} is invalid or unreadable: {exception}") from exception


def validate_completion_schema(document: object, schema: dict[str, Any], label: str) -> None:
    if Draft202012Validator is None:
        raise EvidenceError("jsonschema is required for terminal completion validation")
    errors = sorted(
        Draft202012Validator(schema).iter_errors(document),
        key=lambda error: (list(error.absolute_path), error.message),
    )
    if errors:
        details = "; ".join(error.message for error in errors[:8])
        raise EvidenceError(f"{label} violates COMPLETION-REPORT.schema.json: {details}")


def ipad_qualification_schema() -> dict[str, Any]:
    simulator_properties = {
        "name": {"type": "string", "minLength": 1},
        "udid": {
            "type": "string",
            "pattern": (
                "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-"
                "[0-9A-F]{4}-[0-9A-F]{12}$"
            ),
        },
        "runtime": {"type": "string", "minLength": 1},
    }
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://ravenforgesoftware.com/schemas/runescribe-ipad-qualification-v1.json",
        "title": "Rune Scribe iPad Simulator Qualification",
        "type": "object",
        "additionalProperties": False,
        "required": sorted(IPAD_QUALIFICATION_KEYS),
        "properties": {
            "schemaVersion": {"const": SCHEMA_VERSION},
            "status": {"const": "PASS"},
            "sourceManifestSHA256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
            "sourceRevision": {
                "type": ["string", "null"],
                "pattern": "^[0-9a-f]{40}$",
            },
            "version": {"const": VERSION},
            "build": {"const": BUILD},
            "simulator": {
                "type": "object", "additionalProperties": False,
                "required": sorted(SIMULATOR_KEYS), "properties": simulator_properties,
            },
            "iOSProduct": {
                "type": "object", "additionalProperties": False,
                "required": sorted(IPAD_PRODUCT_KEYS),
                "properties": {
                    "path": {"const": IPHONE_ZIP},
                    "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                    "bundleIdentifier": {"const": EXPECTED_BUNDLE_IDENTIFIER},
                },
            },
            "suites": {
                "type": "array", "minItems": 1,
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": sorted(IPAD_SUITE_KEYS),
                    "properties": {
                        "name": {"type": "string", "minLength": 1},
                        "result": {"const": "PASS"},
                        "executed": {"type": "integer", "minimum": 1},
                        "passed": {"type": "integer", "minimum": 1},
                        "failed": {"const": 0}, "skipped": {"const": 0},
                        "log": {"type": "string", "minLength": 1},
                        "logSHA256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                    },
                },
            },
            "screenshots": {
                "type": "array", "minItems": 1,
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": sorted(IPAD_SCREENSHOT_KEYS),
                    "properties": {
                        "path": {"type": "string", "minLength": 1},
                        "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                    },
                },
            },
        },
    }


def normalized_relative(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError(f"{label} must be a nonempty repository-relative path")
    if value != value.strip() or "\\" in value or "\0" in value or "\n" in value:
        raise EvidenceError(f"{label} is not a canonical repository-relative path")
    relative = PurePosixPath(value)
    if relative.is_absolute() or ".." in relative.parts or relative.as_posix() != value:
        raise EvidenceError(f"{label} is not a safe repository-relative path")
    return value


def repository_file(root: Path, relative: str, label: str) -> Path:
    normalized_relative(relative, label)
    path = root / relative
    if not path.is_file() or path.is_symlink():
        raise EvidenceError(f"{label} is missing or is not a regular file: {relative}")
    try:
        path.resolve().relative_to(root.resolve())
    except (OSError, ValueError) as exception:
        raise EvidenceError(f"{label} resolves outside the repository: {relative}") from exception
    return path


def nonempty_strings(
    value: object,
    label: str,
    *,
    allow_empty: bool = False,
    single_line: bool = False,
) -> list[str]:
    if not isinstance(value, list):
        raise EvidenceError(f"{label} must be an array")
    if not allow_empty and not value:
        raise EvidenceError(f"{label} must not be empty")
    if not all(isinstance(item, str) and item.strip() for item in value):
        raise EvidenceError(f"{label} must contain only nonempty strings")
    values = list(value)
    if len(values) != len(set(values)):
        raise EvidenceError(f"{label} must not contain duplicates")
    if single_line and any("\n" in item or "\r" in item or "```" in item for item in values):
        raise EvidenceError(f"{label} entries must be single-line Markdown-safe text")
    return values


def iso_timestamp(value: object, label: str) -> datetime:
    if not isinstance(value, str):
        raise EvidenceError(f"{label} must be an ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exception:
        raise EvidenceError(f"{label} must be an ISO-8601 timestamp") from exception
    if parsed.tzinfo is None:
        raise EvidenceError(f"{label} must include a timezone")
    return parsed


def run(
    arguments: list[str],
    *,
    cwd: Path,
    label: str,
    require_success: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        arguments,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    if require_success and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic output"
        raise EvidenceError(f"{label} failed: {detail}")
    return result


def git_metadata(
    root: Path,
    manifest_path: Path,
    requested_revision: object,
) -> tuple[str | None, str | None]:
    top = run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=root,
        label="Git repository lookup",
        require_success=False,
    )
    if top.returncode != 0:
        if requested_revision is not None:
            raise EvidenceError("sourceRevision must be null when Git is unavailable")
        return None, None
    try:
        if Path(top.stdout.strip()).resolve() != root.resolve():
            if requested_revision is not None:
                raise EvidenceError("sourceRevision must be null when Git is unavailable")
            return None, None
    except OSError:
        if requested_revision is not None:
            raise EvidenceError("sourceRevision must be null when Git is unavailable")
        return None, None
    if not isinstance(requested_revision, str) or HEX_40.fullmatch(requested_revision) is None:
        raise EvidenceError(
            "sourceRevision must be a lowercase 40-character commit revision in Git"
        )
    revision = requested_revision
    ancestor = run(
        ["git", "merge-base", "--is-ancestor", revision, "HEAD"],
        cwd=root,
        label="source revision ancestry",
        require_success=False,
    )
    if ancestor.returncode != 0:
        raise EvidenceError("sourceRevision is not an existing ancestor of HEAD")
    branch = run(
        ["git", "branch", "--show-current"], cwd=root, label="Git branch"
    ).stdout.strip()
    if not branch:
        raise EvidenceError("terminal evidence requires a named Git branch")
    relative_manifest = manifest_path.relative_to(root).as_posix()
    committed_manifest = run(
        ["git", "show", f"{revision}:{relative_manifest}"],
        cwd=root,
        label="committed source manifest lookup",
    ).stdout.encode("utf-8")
    if committed_manifest != manifest_path.read_bytes():
        raise EvidenceError(
            "SOURCE-MANIFEST.json must be committed unchanged at the source revision"
        )
    terminal_boundaries = (
        COMPLETION_JSON, DEFECT_CLOSURE, EVIDENCE_INDEX, TEST_EXECUTION_INDEX,
        PUBLICATION_AUDIT_RECORD, OWNER_ZIP, PAYLOAD_ZIP,
    )
    for relative in terminal_boundaries:
        terminal_at_source = run(
            ["git", "cat-file", "-e", f"{revision}:{relative}"],
            cwd=root,
            label="source revision terminal-evidence boundary",
            require_success=False,
        )
        if terminal_at_source.returncode == 0:
            raise EvidenceError(
                "sourceRevision must identify the source commit before terminal evidence; "
                f"found {relative}"
            )
    return revision, branch


def verify_package(package_root: Path) -> dict[str, dict[str, object]]:
    if not package_root.is_dir():
        raise EvidenceError(f"package root is not a directory: {package_root}")
    package_manifest_path = package_root / "PACKAGE-MANIFEST.json"
    if (
        not package_manifest_path.is_file()
        or package_manifest_path.is_symlink()
        or sha256_file(package_manifest_path) != EXPECTED_PACKAGE_MANIFEST_SHA256
    ):
        raise EvidenceError("PACKAGE-MANIFEST.json differs from the locked package")
    manifest = load_json(package_manifest_path, "package manifest")
    if not isinstance(manifest, dict) or manifest.get("packageVersion") != "1.0":
        raise EvidenceError("package manifest does not identify remediation package v1.0")
    entries = manifest.get("files")
    if not isinstance(entries, list) or manifest.get("fileCount") != len(entries):
        raise EvidenceError("package manifest file inventory is invalid")
    by_path: dict[str, dict[str, object]] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise EvidenceError(f"package manifest files[{index}] must be an object")
        relative = normalized_relative(entry.get("path"), f"package files[{index}].path")
        if relative in by_path:
            raise EvidenceError(f"duplicate package manifest path: {relative}")
        expected_bytes = entry.get("bytes")
        expected_digest = entry.get("sha256")
        expected_mode = entry.get("mode")
        expected_executable = entry.get("executable")
        if type(expected_bytes) is not int or expected_bytes < 0:
            raise EvidenceError(f"invalid package byte count for {relative}")
        if not isinstance(expected_digest, str) or HEX_64.fullmatch(expected_digest) is None:
            raise EvidenceError(f"invalid package SHA-256 for {relative}")
        if not isinstance(expected_mode, str) or re.fullmatch(r"0[0-7]{3}", expected_mode) is None:
            raise EvidenceError(f"invalid package mode for {relative}")
        if type(expected_executable) is not bool:
            raise EvidenceError(f"invalid package executable flag for {relative}")
        path = package_root / relative
        if not path.is_file() or path.is_symlink():
            raise EvidenceError(f"package file is missing or unsafe: {relative}")
        if path.stat().st_size != expected_bytes or sha256_file(path) != expected_digest:
            raise EvidenceError(f"package file differs from its manifest: {relative}")
        actual_mode = f"{stat.S_IMODE(path.stat().st_mode):04o}"
        actual_executable = bool(path.stat().st_mode & 0o111)
        if actual_mode != expected_mode or actual_executable != expected_executable:
            raise EvidenceError(f"package file mode differs from its manifest: {relative}")
        by_path[relative] = entry
    discovered = {
        path.relative_to(package_root).as_posix()
        for path in package_root.rglob("*")
        if path.is_file() and path.name != "PACKAGE-MANIFEST.json"
    }
    if discovered != set(by_path):
        raise EvidenceError("package file inventory differs from PACKAGE-MANIFEST.json")
    for relative in PACKAGE_REQUIRED_FILES:
        if relative not in by_path:
            raise EvidenceError(f"package manifest omits required input: {relative}")
    return by_path


def load_controls(
    package_root: Path,
    repository_root: Path,
) -> tuple[
    dict[str, tuple[str, ...]],
    dict[str, tuple[str, ...]],
    dict[str, dict[str, tuple[str, ...]]],
    dict[str, str],
    list[dict[str, str]],
    str,
    dict[str, str],
]:
    verify_package(package_root)
    package_gates_path = package_root / "controls/REMEDIATION-GATES-v1.0.json"
    if sha256_file(package_gates_path) != EXPECTED_GATE_CATALOG_SHA256:
        raise EvidenceError("remediation gate catalog differs from the locked digest")
    if repository_file(repository_root, GATE_CATALOG, "locked gate catalog").read_bytes() != package_gates_path.read_bytes():
        raise EvidenceError("repository gate catalog differs from the supplied package")
    gate_document = load_json(package_gates_path, "remediation gate catalog")
    gate_rows = gate_document.get("gates") if isinstance(gate_document, dict) else None
    if not isinstance(gate_rows, list) or len(gate_rows) != 42:
        raise EvidenceError("remediation gate catalog must contain exactly 42 gates")
    requirements: dict[str, tuple[str, ...]] = {}
    for row in gate_rows:
        if not isinstance(row, dict) or row.get("required") is not True:
            raise EvidenceError("every remediation gate must be an object marked required")
        gate_id = row.get("id")
        if not isinstance(gate_id, str) or GATE_ID.fullmatch(gate_id) is None:
            raise EvidenceError("remediation gate catalog contains an invalid gate ID")
        claims = nonempty_strings(
            row.get("requiredEvidence"), f"{gate_id}.requiredEvidence"
        )
        if gate_id in requirements:
            raise EvidenceError(f"duplicate remediation gate: {gate_id}")
        requirements[gate_id] = tuple(claims)
    if set(requirements) != set(GATE_IDS):
        raise EvidenceError("remediation gate IDs differ from RC-001 through RC-042")

    assigned = [gate for gates in RECORD_GATES.values() for gate in gates]
    if len(assigned) != 42 or set(assigned) != set(GATE_IDS):
        raise EvidenceError("internal evidence-record gate assignment is incomplete")
    if len(assigned) != len(set(assigned)):
        raise EvidenceError("internal evidence-record gate assignment overlaps")

    closure_path = package_root / "controls/FINDING-CLOSURE-MATRIX-v1.0.json"
    if sha256_file(closure_path) != EXPECTED_FINDING_MATRIX_SHA256:
        raise EvidenceError("finding closure matrix differs from the locked digest")
    closure_document = load_json(
        closure_path,
        "finding closure matrix",
    )
    closure_rows = (
        closure_document.get("findings") if isinstance(closure_document, dict) else None
    )
    if not isinstance(closure_rows, list) or len(closure_rows) != 12:
        raise EvidenceError("finding closure matrix must contain exactly 12 findings")
    finding_gates: dict[str, tuple[str, ...]] = {}
    finding_controls: dict[str, dict[str, tuple[str, ...]]] = {}
    for row in closure_rows:
        if not isinstance(row, dict):
            raise EvidenceError("finding closure matrix contains a non-object finding")
        finding_id = row.get("id")
        if not isinstance(finding_id, str) or finding_id not in FINDING_IDS:
            raise EvidenceError("finding closure matrix contains an invalid finding ID")
        gates = nonempty_strings(row.get("gates"), f"{finding_id}.gates")
        if not set(gates).issubset(requirements):
            raise EvidenceError(f"{finding_id} references an unknown remediation gate")
        if finding_id in finding_gates:
            raise EvidenceError(f"duplicate finding closure: {finding_id}")
        expected_keys = {
            "gates", "id", "implementation", "phases", "primarySourceAreas",
            "severity", "tests", "title",
        }
        if set(row) != expected_keys:
            raise EvidenceError(f"{finding_id} closure keys differ from the locked schema")
        implementation = nonempty_strings(
            row.get("implementation"), f"{finding_id}.implementation"
        )
        source_areas = nonempty_strings(
            row.get("primarySourceAreas"), f"{finding_id}.primarySourceAreas"
        )
        tests = nonempty_strings(row.get("tests"), f"{finding_id}.tests")
        nonempty_strings(row.get("phases"), f"{finding_id}.phases")
        if not isinstance(row.get("severity"), str) or not row["severity"].strip():
            raise EvidenceError(f"{finding_id}.severity must be nonempty")
        if not isinstance(row.get("title"), str) or not row["title"].strip():
            raise EvidenceError(f"{finding_id}.title must be nonempty")
        finding_gates[finding_id] = tuple(gates)
        finding_controls[finding_id] = {
            "implementation": tuple(implementation),
            "sourceAreas": tuple(source_areas),
            "tests": tuple(tests),
        }
    if set(finding_gates) != set(FINDING_IDS):
        raise EvidenceError("finding closure IDs differ from RSA-001 through RSA-012")

    audit_document = load_json(
        package_root
        / "references/audit/Rune-Scribe-Roadmap-Audit-Findings-v1.0.json",
        "audited findings",
    )
    audit_rows = audit_document.get("findings") if isinstance(audit_document, dict) else None
    if not isinstance(audit_rows, list):
        raise EvidenceError("audited findings document is invalid")
    original_statuses: dict[str, str] = {}
    for row in audit_rows:
        if not isinstance(row, dict):
            continue
        finding_id = row.get("id")
        status = row.get("status")
        if finding_id in FINDING_IDS and isinstance(status, str) and status:
            original_statuses[finding_id] = status
    if set(original_statuses) != set(FINDING_IDS):
        raise EvidenceError("audited findings do not provide every original status")

    matrix_path = package_root / "controls/TEST-MATRIX-v1.0.csv"
    if sha256_file(matrix_path) != EXPECTED_TEST_MATRIX_SHA256:
        raise EvidenceError("test matrix differs from the locked digest")
    try:
        with matrix_path.open(newline="", encoding="utf-8") as stream:
            reader = csv.DictReader(stream)
            expected_headers = {
                "testID", "area", "platform", "kind", "scenario", "precondition",
                "action", "expectedResult", "requiredEvidence", "gateIDs",
            }
            if reader.fieldnames is None or set(reader.fieldnames) != expected_headers:
                raise EvidenceError("test matrix headers differ from the locked schema")
            test_rows = list(reader)
    except (OSError, csv.Error) as exception:
        raise EvidenceError(f"test matrix is unreadable: {exception}") from exception
    if len(test_rows) != 87:
        raise EvidenceError("test matrix must contain exactly 87 locked rows")
    seen_tests: set[str] = set()
    gate_test_counts = {gate_id: 0 for gate_id in GATE_IDS}
    matrix_screenshots: dict[str, str] = {}
    for index, row in enumerate(test_rows, start=2):
        test_id = row.get("testID", "")
        scenario = row.get("scenario", "")
        if TEST_ID.fullmatch(test_id) is None or test_id in seen_tests:
            raise EvidenceError(f"test matrix line {index} has an invalid or duplicate test ID")
        for header in expected_headers:
            field = row.get(header)
            if not isinstance(field, str) or not field.strip() or field != field.strip():
                raise EvidenceError(
                    f"test matrix line {index} has an invalid {header} field"
                )
            if "\n" in field or "\r" in field or "\0" in field:
                raise EvidenceError(
                    f"test matrix line {index} has a noncanonical {header} field"
                )
        gates = row.get("gateIDs", "").split(";")
        if (
            not gates
            or len(gates) != len(set(gates))
            or not all(gate in requirements for gate in gates)
        ):
            raise EvidenceError(f"test matrix line {index} references an unknown gate")
        required_evidence = row["requiredEvidence"]
        if required_evidence.endswith(".png"):
            expected_platform = row["platform"]
            prior = matrix_screenshots.get(required_evidence)
            if prior is not None and prior != expected_platform:
                raise EvidenceError(
                    f"test matrix assigns conflicting platforms to {required_evidence}"
                )
            matrix_screenshots[required_evidence] = expected_platform
        seen_tests.add(test_id)
        for gate in gates:
            gate_test_counts[gate] += 1
    missing_tests = sorted(gate for gate, count in gate_test_counts.items() if count == 0)
    if missing_tests:
        raise EvidenceError("test matrix omits gates: " + ", ".join(missing_tests))
    catalog_claims = {claim for claims in requirements.values() for claim in claims}
    for claim in (
        WORKSPACE_SCREENSHOT_CLAIM,
        CLOUD_GAME_CENTER_CLAIM,
        PERFORMANCE_RESOURCE_CLAIM,
        EVIDENCE_INDEX_CLAIM,
    ):
        if claim not in catalog_claims:
            raise EvidenceError(f"locked artifact policy claim is absent: {claim}")
    if (
        set(IMPLEMENTATION_SOURCE_AREA_INDEXES) != set(FINDING_IDS)
        or set(SOURCE_AREA_PATHS) != set(FINDING_IDS)
        or set(IMPLEMENTATION_PATHS) != set(FINDING_IDS)
        or set(REMOVED_IMPLEMENTATION_PATHS) != set(FINDING_IDS)
        or set(TEST_EXPECTATION_IDS) != set(FINDING_IDS)
    ):
        raise EvidenceError("internal expectation-specific binding policy is incomplete")
    rows_by_id = {row["testID"]: row for row in test_rows}
    for finding_id in FINDING_IDS:
        control = finding_controls[finding_id]
        source_policy = IMPLEMENTATION_SOURCE_AREA_INDEXES[finding_id]
        exact_source_paths = SOURCE_AREA_PATHS[finding_id]
        exact_implementation_paths = IMPLEMENTATION_PATHS[finding_id]
        exact_removed_paths = REMOVED_IMPLEMENTATION_PATHS[finding_id]
        test_policy = TEST_EXPECTATION_IDS[finding_id]
        if len(source_policy) != len(control["implementation"]):
            raise EvidenceError(
                f"{finding_id} implementation binding policy differs from locked controls"
            )
        if len(test_policy) != len(control["tests"]):
            raise EvidenceError(
                f"{finding_id} test binding policy differs from locked controls"
            )
        if len(exact_source_paths) != len(control["sourceAreas"]):
            raise EvidenceError(
                f"{finding_id} exact source-area policy differs from locked controls"
            )
        if len(exact_implementation_paths) != len(control["implementation"]):
            raise EvidenceError(
                f"{finding_id} exact implementation policy differs from locked controls"
            )
        if not set(exact_removed_paths).issubset(control["implementation"]):
            raise EvidenceError(
                f"{finding_id} removal binding policy differs from locked controls"
            )
        if any(list(paths) != sorted(set(paths)) for paths in exact_source_paths):
            raise EvidenceError(f"{finding_id} exact source-area paths are not canonical")
        if any(list(paths) != sorted(set(paths)) for paths in exact_implementation_paths):
            raise EvidenceError(f"{finding_id} exact implementation paths are not canonical")
        for indexes in source_policy:
            if (
                not indexes
                or len(indexes) != len(set(indexes))
                or any(index < 0 or index >= len(control["sourceAreas"]) for index in indexes)
            ):
                raise EvidenceError(f"{finding_id} source binding policy is invalid")
        covered_gates: set[str] = set()
        for test_ids in test_policy:
            if not test_ids or len(test_ids) != len(set(test_ids)):
                raise EvidenceError(f"{finding_id} test binding policy is invalid")
            for test_id in test_ids:
                if test_id not in rows_by_id:
                    raise EvidenceError(
                        f"{finding_id} test binding policy references unknown {test_id}"
                    )
                row_gates = set(rows_by_id[test_id]["gateIDs"].split(";"))
                if not row_gates.intersection(finding_gates[finding_id]):
                    raise EvidenceError(
                        f"{finding_id} test binding policy places {test_id} outside finding gates"
                    )
                covered_gates.update(row_gates.intersection(finding_gates[finding_id]))
        if not set(finding_gates[finding_id]).issubset(covered_gates):
            raise EvidenceError(
                f"{finding_id} test binding policy omits locked finding gates"
            )
    return (
        requirements,
        finding_gates,
        finding_controls,
        original_statuses,
        test_rows,
        sha256_file(matrix_path),
        matrix_screenshots,
    )


def load_source_manifest(root: Path) -> tuple[dict[str, Any], str, set[str]]:
    path = repository_file(root, SOURCE_MANIFEST, "final source manifest")
    document = load_json(path, "final source manifest")
    if not isinstance(document, dict):
        raise EvidenceError("final source manifest root must be an object")
    source_hash = document.get("aggregateSHA256")
    files = document.get("files")
    if not isinstance(source_hash, str) or HEX_64.fullmatch(source_hash) is None:
        raise EvidenceError("final source manifest has an invalid aggregateSHA256")
    if not isinstance(files, list):
        raise EvidenceError("final source manifest files must be an array")
    manifest_paths: set[str] = set()
    for index, record in enumerate(files):
        if not isinstance(record, dict):
            raise EvidenceError(f"final source manifest files[{index}] must be an object")
        relative = normalized_relative(
            record.get("path"), f"final source manifest files[{index}].path"
        )
        if relative in manifest_paths:
            raise EvidenceError(f"final source manifest duplicates {relative}")
        manifest_paths.add(relative)
    verifier = root / "scripts/generate-source-manifest.py"
    if not verifier.is_file():
        raise EvidenceError("source-manifest verifier is missing")
    run(
        [sys.executable, str(verifier), str(root), str(path), "--verify"],
        cwd=root,
        label="final source-manifest verification",
    )
    return document, source_hash, manifest_paths


def manifest_record_projection(
    document: object, label: str
) -> dict[str, tuple[str, int, str, bool]]:
    """Validate either supported manifest schema and return comparable records."""
    if not isinstance(document, dict) or document.get("schemaVersion") not in {"1.0", "1.1"}:
        raise EvidenceError(f"{label} has an unsupported schemaVersion")
    files = document.get("files")
    if not isinstance(files, list) or document.get("fileCount") != len(files):
        raise EvidenceError(f"{label} fileCount/files differ")
    projection: dict[str, tuple[str, int, str, bool]] = {}
    aggregate = hashlib.sha256()
    schema = document["schemaVersion"]
    for index, record in enumerate(files):
        record_label = f"{label}.files[{index}]"
        expected_keys = (
            {"path", "bytes", "sha256", "executable"}
            if schema == "1.0"
            else {"path", "kind", "bytes", "sha256", "executable"}
        )
        if not isinstance(record, dict) or set(record) != expected_keys:
            raise EvidenceError(f"{record_label} keys differ")
        relative = normalized_relative(record.get("path"), f"{record_label}.path")
        kind = record.get("kind", "file")
        byte_count = record.get("bytes")
        digest = record.get("sha256")
        executable = record.get("executable")
        if (
            kind not in {"file", "symlink"}
            or type(byte_count) is not int or byte_count < 0
            or not isinstance(digest, str) or HEX_64.fullmatch(digest) is None
            or type(executable) is not bool
            or relative in projection
        ):
            raise EvidenceError(f"{record_label} values are invalid or duplicate")
        projection[relative] = (kind, byte_count, digest, executable)
        if schema == "1.0":
            serialized = (
                f"{relative}\0{byte_count}\0{digest}\0{1 if executable else 0}\n"
            )
        else:
            serialized = (
                f"{relative}\0{kind}\0{byte_count}\0{digest}\0"
                f"{1 if executable else 0}\n"
            )
        aggregate.update(serialized.encode("utf-8"))
    if list(projection) != sorted(projection):
        raise EvidenceError(f"{label} file records are not sorted")
    if document.get("aggregateSHA256") != aggregate.hexdigest():
        raise EvidenceError(f"{label} aggregateSHA256 differs from its records")
    return projection


def git_revision_manifest_projection(
    root: Path, revision: str, excludes: Iterable[str]
) -> dict[str, tuple[str, int, str, bool]]:
    """Reconstruct the baseline manifest records from the exact Git tree."""
    normalized_excludes = sorted(set(excludes))

    def excluded(relative: str) -> bool:
        parts = relative.split("/")
        return any(
            relative == entry
            or relative.startswith(entry + "/")
            or ("/" not in entry and entry in parts)
            for entry in normalized_excludes
        )

    with tempfile.TemporaryDirectory(prefix="runescribe-baseline-archive-") as temporary:
        archive_path = Path(temporary) / "baseline.tar"
        archived = subprocess.run(
            [
                "git", "archive", "--format=tar", "--output", str(archive_path),
                revision,
            ],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
            timeout=300,
        )
        if archived.returncode != 0:
            raise EvidenceError("cannot reconstruct Baseline.json repository.head")
        projection: dict[str, tuple[str, int, str, bool]] = {}
        try:
            with tarfile.open(archive_path, "r:") as archive:
                for member in archive.getmembers():
                    relative = PurePosixPath(member.name).as_posix().rstrip("/")
                    if not relative or excluded(relative) or member.isdir():
                        continue
                    if member.isfile():
                        stream = archive.extractfile(member)
                        if stream is None:
                            raise EvidenceError(
                                f"cannot read baseline archive member {relative}"
                            )
                        data = stream.read()
                        kind = "file"
                    elif member.issym():
                        data = member.linkname.encode("utf-8")
                        kind = "symlink"
                    else:
                        raise EvidenceError(
                            f"unsupported baseline archive member {relative}"
                        )
                    projection[relative] = (
                        kind,
                        len(data),
                        sha256_bytes(data),
                        bool(member.mode & 0o111) if kind == "file" else False,
                    )
        except (OSError, tarfile.TarError) as exception:
            raise EvidenceError(f"cannot inspect baseline Git archive: {exception}") from exception
    return dict(sorted(projection.items()))


def validate_counts(value: object, label: str) -> dict[str, int]:
    keys = {"executed", "passed", "failed", "skipped"}
    if not isinstance(value, dict) or set(value) != keys:
        raise EvidenceError(f"{label} must contain executed, passed, failed, and skipped")
    if not all(type(value.get(key)) is int and value[key] >= 0 for key in keys):
        raise EvidenceError(f"{label} counts must be nonnegative integers")
    if value["passed"] + value["failed"] + value["skipped"] != value["executed"]:
        raise EvidenceError(f"{label} counts do not add up")
    return {key: value[key] for key in sorted(keys)}


def compact_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def load_domain_producer(root: Path) -> Any:
    """Load the exact source-bound executor after locking its full source and policy."""
    producer_path = repository_file(root, DOMAIN_RESULT_PRODUCER, "domain producer")
    producer_digest = sha256_file(producer_path)
    if producer_digest != EXPECTED_DOMAIN_PRODUCER_SHA256:
        raise EvidenceError("domain producer source differs from the locked executable")
    module_name = "_runescribe_domain_producer_" + producer_digest[:16]
    spec = importlib.util.spec_from_file_location(module_name, producer_path)
    if spec is None or spec.loader is None:
        raise EvidenceError("domain producer cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exception:
        raise EvidenceError(f"domain producer cannot be imported: {exception}") from exception
    policy = {
        "schemaVersion": getattr(module, "SCHEMA_VERSION", None),
        "version": getattr(module, "VERSION", None),
        "build": getattr(module, "BUILD", None),
        "packagePath": getattr(module, "PACKAGE_PATH", None),
        "previewTest": getattr(module, "PREVIEW_TEST", None),
        "cloudMarkers": getattr(module, "CLOUD_MARKERS", None),
        "performanceMarkers": getattr(module, "PERFORMANCE_MARKERS", None),
        "cloudTestSources": getattr(module, "CLOUD_TEST_SOURCES", None),
        "performanceTestSources": getattr(module, "PERFORMANCE_TEST_SOURCES", None),
        "cloudCaseTests": getattr(module, "CLOUD_CASE_TESTS", None),
        "performanceCaseTests": getattr(module, "PERFORMANCE_CASE_TESTS", None),
        "themeSpecs": getattr(module, "THEME_SPECS", None),
    }
    digest = sha256_bytes(compact_json(policy).encode("utf-8"))
    if digest != EXPECTED_DOMAIN_PRODUCER_POLICY_SHA256:
        raise EvidenceError("domain producer semantic policy differs from the locked policy")
    if (
        tuple(module.CLOUD_MARKERS) != CLOUD_GAME_CENTER_MARKERS
        or tuple(module.PERFORMANCE_MARKERS) != PERFORMANCE_RESOURCE_MARKERS
        or len(module.ALL_TEST_SOURCES) != 34
        or module.SHIPPING_CHECKER_PATH != SHIPPING_CHECKER_PATH
        or module.EXPECTED_SHIPPING_CHECKER_SHA256
        != EXPECTED_SHIPPING_CHECKER_SHA256
        or module.EXPECTED_SHIPPING_CHECK_COUNT != EXPECTED_SHIPPING_CHECK_COUNT
        or module.SHIPPING_VALIDATION_LOG != DOMAIN_SHIPPING_VALIDATION_LOG
    ):
        raise EvidenceError("domain producer catalog differs from locked remediation claims")
    shipping_checker = repository_file(
        root, SHIPPING_CHECKER_PATH, "shipping-product checker"
    )
    if sha256_file(shipping_checker) != EXPECTED_SHIPPING_CHECKER_SHA256:
        raise EvidenceError(
            "shipping-product checker source differs from the locked executable"
        )
    return module


def derive_domain_products_and_budgets(
    root: Path, producer: Any
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    products: list[dict[str, Any]] = []
    budgets: list[dict[str, Any]] = []
    for relative, platform in ((MACOS_ZIP, "macOS"), (IPHONE_ZIP, "iOS")):
        path = repository_file(root, relative, f"{platform} built product inspection")
        try:
            product, product_budgets = producer.inspect_app_zip(
                path, relative, platform, root
            )
        except Exception as exception:
            raise EvidenceError(
                f"cannot inspect built product {relative}: {exception}"
            ) from exception
        products.append(product)
        budgets.extend(product_budgets)
    return products, budgets


def expected_domain_execution(
    root: Path, producer: Any, identifier: str
) -> dict[str, Any]:
    source_relative = producer.ALL_TEST_SOURCES[identifier]
    source_path = repository_file(root, source_relative, f"domain test {identifier}")
    scratch = Path("/__runescribe_domain_scratch__")
    return {
        "identifier": identifier,
        "framework": "XCTest" if "/" in identifier else "Swift Testing",
        "command": producer.display_command(
            producer.test_command(identifier, scratch), scratch
        ),
        "exitStatus": 0,
        "observedTestCount": 1,
        "result": "PASS",
        "sourcePath": source_relative,
        "sourceSHA256": sha256_file(source_path),
    }


def validate_preview_measurement(value: object, label: str) -> dict[str, Any]:
    keys = {
        "schemaVersion", "testIdentifier", "previewBytes",
        "previewWidthPixels", "previewHeightPixels",
    }
    if not isinstance(value, dict) or set(value) != keys:
        raise EvidenceError(f"{label} preview measurement keys differ")
    if (
        value.get("schemaVersion") != SCHEMA_VERSION
        or not isinstance(value.get("testIdentifier"), str)
        or any(type(value.get(key)) is not int for key in (
            "previewBytes", "previewWidthPixels", "previewHeightPixels"
        ))
    ):
        raise EvidenceError(f"{label} preview measurement is invalid")
    preview_bytes = value["previewBytes"]
    width = value["previewWidthPixels"]
    height = value["previewHeightPixels"]
    if not 0 < preview_bytes < 4 * 1024 * 1024:
        raise EvidenceError(f"{label} preview byte budget fails")
    if width <= 0 or height <= 0 or width * 3 != height * 4:
        raise EvidenceError(f"{label} preview dimensions are not exactly 4:3")
    return dict(value)


def validate_built_product_inspection(
    *, root: Path, source_hash: str, source_revision: str | None,
    expected_raw_log: str,
) -> tuple[dict[str, Any], list[dict[str, Any]], Any]:
    relative = BUILT_PRODUCT_INSPECTION_RESULTS
    document = load_json(repository_file(root, relative, relative), relative)
    expected_keys = {
        "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
        "version", "build", "rawLog", "rawLogSHA256", "producer", "products",
        "shippingValidation",
    }
    if not isinstance(document, dict) or set(document) != expected_keys:
        raise EvidenceError(f"{relative} keys differ from its locked inspection schema")
    expected_scalars = {
        "schemaVersion": SCHEMA_VERSION,
        "status": "PASS",
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "version": VERSION,
        "build": BUILD,
        "rawLog": expected_raw_log,
        "producer": {
            "path": DOMAIN_RESULT_PRODUCER,
            "sha256": EXPECTED_DOMAIN_PRODUCER_SHA256,
        },
    }
    for key, expected in expected_scalars.items():
        if document.get(key) != expected:
            raise EvidenceError(f"{relative}.{key} differs")
    raw_path = repository_file(root, expected_raw_log, f"{relative}.rawLog")
    if document.get("rawLogSHA256") != sha256_file(raw_path):
        raise EvidenceError(f"{relative}.rawLogSHA256 differs")
    producer = load_domain_producer(root)
    products, budgets = derive_domain_products_and_budgets(root, producer)
    if document.get("products") != products:
        raise EvidenceError(f"{relative}.products differ from exact app ZIP inspection")
    shipping_validation, shipping_output = producer.run_shipping_product_validation(
        root=root,
        macos_zip=repository_file(root, MACOS_ZIP, "macOS shipping product"),
        ios_zip=repository_file(root, IPHONE_ZIP, "iOS shipping product"),
        output_relative=DOMAIN_SHIPPING_VALIDATION_LOG,
    )
    shipping_log = repository_file(
        root, DOMAIN_SHIPPING_VALIDATION_LOG, "domain shipping-product log"
    )
    if shipping_log.read_bytes() != shipping_output:
        raise EvidenceError(
            "domain shipping-product log differs from a fresh locked inspection"
        )
    if document.get("shippingValidation") != shipping_validation:
        raise EvidenceError(
            f"{relative}.shippingValidation differs from the locked shipping checker"
        )
    raw_text = raw_path.read_text(encoding="utf-8", errors="strict")
    if "domainCaptureResult=PASS" not in raw_text:
        raise EvidenceError(f"{relative}.rawLog lacks producer PASS")
    for product in products:
        if f"productInspection={compact_json(product)}" not in raw_text:
            raise EvidenceError(f"{relative}.rawLog omits {product['platform']} inspection")
    if f"shippingProductValidation={compact_json(shipping_validation)}" not in raw_text:
        raise EvidenceError(f"{relative}.rawLog omits locked shipping-product validation")
    return dict(document), budgets, producer


def validate_structured_suite_results(
    *,
    root: Path,
    source_hash: str,
    source_revision: str | None,
    suites: dict[str, dict[str, Any]],
    tests: dict[str, dict[str, Any]],
    rows_by_id: dict[str, dict[str, str]],
) -> dict[str, dict[str, Any]]:
    parsed: dict[str, dict[str, Any]] = {}
    seen_logs: set[str] = set()
    for suite_name, suite in suites.items():
        relative = normalized_relative(suite.get("log"), f"suite {suite_name!r} log")
        if (
            not relative.startswith(f"{EVIDENCE_PREFIX}/GateRun/")
            or not relative.endswith(".json")
            or relative in seen_logs
        ):
            raise EvidenceError(
                f"suite {suite_name!r} must have one unique structured GateRun JSON log"
            )
        seen_logs.add(relative)
        document = load_json(repository_file(root, relative, f"suite {suite_name!r} log"), relative)
        if not isinstance(document, dict) or set(document) != STRUCTURED_TEST_LOG_KEYS:
            raise EvidenceError(f"{relative} keys differ from structured suite-result schema")
        expected_scalars = {
            "schemaVersion": SCHEMA_VERSION,
            "status": "PASS",
            "sourceManifestSHA256": source_hash,
            "sourceRevision": source_revision,
            "version": VERSION,
            "build": BUILD,
            "suiteName": suite_name,
        }
        for key, expected in expected_scalars.items():
            if document.get(key) != expected:
                raise EvidenceError(f"{relative}.{key} differs")
        totals = validate_counts(document.get("totals"), f"{relative}.totals")
        if totals != {
            key: suite[key] for key in ("executed", "failed", "passed", "skipped")
        }:
            raise EvidenceError(f"{relative}.totals differ from the declared suite")
        raw_log = normalized_relative(document.get("rawLog"), f"{relative}.rawLog")
        if raw_log == relative:
            raise EvidenceError(f"{relative}.rawLog may not self-reference")
        raw_path = repository_file(root, raw_log, f"{relative}.rawLog")
        if document.get("rawLogSHA256") != sha256_file(raw_path):
            raise EvidenceError(f"{relative}.rawLogSHA256 differs")
        raw_text = raw_path.read_text(encoding="utf-8", errors="strict")
        entries = document.get("executions")
        if not isinstance(entries, list) or not entries:
            raise EvidenceError(f"{relative}.executions must be nonempty")
        expected_ids = sorted(
            test_id for test_id, execution in tests.items()
            if execution["suiteName"] == suite_name
        )
        seen_ids: set[str] = set()
        for index, entry in enumerate(entries):
            label = f"{relative}.executions[{index}]"
            if not isinstance(entry, dict) or set(entry) != STRUCTURED_TEST_LOG_EXECUTION_KEYS:
                raise EvidenceError(f"{label} keys differ")
            test_id = entry.get("testID")
            if test_id not in expected_ids or test_id in seen_ids:
                raise EvidenceError(f"{label}.testID is invalid or duplicate")
            seen_ids.add(test_id)
            expected_entry = {
                "testID": test_id,
                "scenario": rows_by_id[test_id]["scenario"],
                "result": "PASS",
                "suiteName": suite_name,
                "command": tests[test_id]["command"],
                "requiredEvidence": rows_by_id[test_id]["requiredEvidence"],
            }
            if entry != expected_entry:
                raise EvidenceError(f"{label} differs from the locked execution")
            for marker in expected_entry.values():
                if str(marker) not in raw_text:
                    raise EvidenceError(f"{relative}.rawLog omits {marker!r}")
        if seen_ids != set(expected_ids):
            raise EvidenceError(f"{relative}.executions differ from its exact suite bindings")
        parsed[suite_name] = dict(document)
    return parsed


def validate_domain_result_report(
    *,
    root: Path,
    relative: str,
    source_hash: str,
    source_revision: str | None,
    expected_test_ids: tuple[str, ...],
    expected_markers: tuple[str, ...],
    suite_results: dict[str, dict[str, Any]],
    tests: dict[str, dict[str, Any]],
    performance: bool,
    producer: Any,
    theme_budgets: list[dict[str, Any]],
    product_inspection: dict[str, Any] | None = None,
) -> dict[str, Any]:
    document = load_json(repository_file(root, relative, relative), relative)
    common_keys = {
        "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
        "version", "build", "testIDs", "semanticMarkers", "executions", "cases",
        "rawLog", "rawLogSHA256", "producer",
    }
    required_keys = common_keys | ({"metrics"} if performance else {"builtInspection"})
    if not isinstance(document, dict) or set(document) != required_keys:
        raise EvidenceError(f"{relative} keys differ from its locked result schema")
    expected_scalars = {
        "schemaVersion": SCHEMA_VERSION, "status": "PASS",
        "sourceManifestSHA256": source_hash, "sourceRevision": source_revision,
        "version": VERSION, "build": BUILD,
        "testIDs": list(expected_test_ids),
        "semanticMarkers": list(expected_markers),
    }
    for key, expected in expected_scalars.items():
        if document.get(key) != expected:
            raise EvidenceError(f"{relative}.{key} differs")
    expected_producer = {
        "path": DOMAIN_RESULT_PRODUCER,
        "sha256": EXPECTED_DOMAIN_PRODUCER_SHA256,
    }
    if sha256_file(repository_file(root, DOMAIN_RESULT_PRODUCER, "domain producer")) != (
        EXPECTED_DOMAIN_PRODUCER_SHA256
    ):
        raise EvidenceError("domain producer source differs from the locked executable")
    if document.get("producer") != expected_producer:
        raise EvidenceError(f"{relative}.producer differs from the executable producer")
    raw_log = normalized_relative(document.get("rawLog"), f"{relative}.rawLog")
    if raw_log == relative:
        raise EvidenceError(f"{relative}.rawLog may not self-reference")
    raw_path = repository_file(root, raw_log, f"{relative}.rawLog")
    if document.get("rawLogSHA256") != sha256_file(raw_path):
        raise EvidenceError(f"{relative}.rawLogSHA256 differs")
    expected_raw_logs = {
        suite_results[tests[test_id]["suiteName"]]["rawLog"]
        for test_id in expected_test_ids
    }
    if expected_raw_logs != {raw_log}:
        raise EvidenceError(f"{relative}.rawLog differs from its test suites")
    raw_text = raw_path.read_text(encoding="utf-8", errors="strict")
    if "domainCaptureResult=PASS" not in raw_text:
        raise EvidenceError(f"{relative}.rawLog was not emitted by the domain producer")
    test_sources = (
        producer.PERFORMANCE_TEST_SOURCES
        if performance else producer.CLOUD_TEST_SOURCES
    )
    expected_executions = [
        expected_domain_execution(root, producer, identifier)
        for identifier in test_sources
    ]
    if document.get("executions") != expected_executions:
        raise EvidenceError(
            f"{relative}.executions differ from exact source-bound Swift test results"
        )
    for execution in expected_executions:
        if f"domainExecution={compact_json(execution)}" not in raw_text:
            raise EvidenceError(
                f"{relative}.rawLog omits exact execution {execution['identifier']}"
            )
    case_mapping = (
        producer.PERFORMANCE_CASE_TESTS
        if performance else producer.CLOUD_CASE_TESTS
    )
    expected_cases = producer.build_cases(
        case_mapping, list(expected_test_ids), not performance
    )
    if document.get("cases") != expected_cases:
        raise EvidenceError(
            f"{relative}.cases differ from exact scenario-to-test bindings"
        )
    for case in expected_cases:
        if f"semanticCase={compact_json(case)}" not in raw_text:
            raise EvidenceError(f"{relative}.rawLog omits exact case {case['marker']}")
    if performance:
        metrics = document.get("metrics")
        if not isinstance(metrics, dict) or set(metrics) != {
            "preview", "themeResourceBudgets"
        }:
            raise EvidenceError(f"{relative}.metrics keys differ")
        preview = validate_preview_measurement(metrics.get("preview"), relative)
        if preview["testIdentifier"] != producer.PREVIEW_TEST:
            raise EvidenceError(f"{relative}.metrics preview test identity differs")
        if metrics.get("themeResourceBudgets") != theme_budgets:
            raise EvidenceError(
                f"{relative}.metrics Theme budgets differ from complete app ZIP resources"
            )
        if f"previewMeasurement={compact_json(preview)}" not in raw_text:
            raise EvidenceError(f"{relative}.rawLog omits exact preview measurement")
        for budget in theme_budgets:
            if f"themeBudgetInspection={compact_json(budget)}" not in raw_text:
                raise EvidenceError(
                    f"{relative}.rawLog omits exact {budget['platform']} "
                    f"{budget['theme']} Theme budget"
                )
    else:
        inspection = document.get("builtInspection")
        if product_inspection is None:
            raise EvidenceError(f"{relative} has no validated built-product inspection")
        expected_products = product_inspection["products"]
        if not isinstance(inspection, dict) or inspection != {
            "result": "PASS",
            "record": BUILT_PRODUCT_INSPECTION_RESULTS,
            "recordSHA256": sha256_file(root / BUILT_PRODUCT_INSPECTION_RESULTS),
            "products": expected_products,
        }:
            raise EvidenceError(f"{relative}.builtInspection differs")
        for product in expected_products:
            if f"productInspection={compact_json(product)}" not in raw_text:
                raise EvidenceError(
                    f"{relative}.rawLog omits derived {product['platform']} inspection"
                )
    for test_id in expected_test_ids:
        if relative not in tests[test_id]["evidence"]:
            raise EvidenceError(f"{test_id} does not bind exact domain result {relative}")
    return dict(document)


def validate_domain_execution_log(
    *, root: Path, producer: Any, cloud_document: dict[str, Any],
    performance_document: dict[str, Any], product_inspection: dict[str, Any],
    theme_budgets: list[dict[str, Any]],
) -> None:
    raw_relative = cloud_document.get("rawLog")
    if raw_relative != performance_document.get("rawLog"):
        raise EvidenceError("domain reports do not share one exact execution log")
    raw_path = repository_file(root, raw_relative, "domain execution log")
    normalized = raw_path.read_text(encoding="utf-8", errors="strict").replace(
        "\r\n", "\n"
    )
    marker = "DOMAIN_EXECUTION_LOG schemaVersion=1.0\n"
    if normalized.count(marker) != 1:
        raise EvidenceError("domain execution log must contain one exact producer boundary")
    _prefix, actual_tail = normalized.split(marker, 1)
    expected_executions = [
        expected_domain_execution(root, producer, identifier)
        for identifier in producer.ALL_TEST_SOURCES
    ]
    metrics = performance_document["metrics"]
    expected_tail = producer.domain_tail(
        expected_executions,
        producer.build_cases(producer.CLOUD_CASE_TESTS, ["T-096", "T-097"], True),
        producer.build_cases(producer.PERFORMANCE_CASE_TESTS, ["T-116"]),
        metrics["preview"],
        theme_budgets,
        product_inspection["products"],
        product_inspection["shippingValidation"],
    )
    if marker + actual_tail != expected_tail:
        raise EvidenceError("domain execution log differs from exact normalized results")


def validate_png(path: Path, label: str) -> tuple[int, int]:
    try:
        data = path.read_bytes()
    except OSError as exception:
        raise EvidenceError(f"{label} is unreadable: {exception}") from exception
    if (
        len(data) < 45
        or data[:8] != PNG_SIGNATURE
        or data[12:16] != b"IHDR"
    ):
        raise EvidenceError(f"{label} is not a canonical PNG")
    offset = 8
    chunks: list[bytes] = []
    width = height = 0
    while offset < len(data):
        if offset + 12 > len(data):
            raise EvidenceError(f"{label} has a truncated PNG chunk")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            raise EvidenceError(f"{label} has a truncated PNG chunk payload")
        chunk_type = data[offset + 4:offset + 8]
        chunk_data = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length:end])[0]
        if zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF != expected_crc:
            raise EvidenceError(f"{label} has a PNG CRC mismatch")
        if not chunks:
            if chunk_type != b"IHDR" or length != 13:
                raise EvidenceError(f"{label} has an invalid PNG IHDR")
            width, height = struct.unpack(">II", chunk_data[:8])
        chunks.append(chunk_type)
        offset = end
        if chunk_type == b"IEND":
            if length != 0 or offset != len(data):
                raise EvidenceError(f"{label} has an invalid final PNG IEND")
            break
    if not chunks or chunks[-1] != b"IEND" or b"IDAT" not in chunks:
        raise EvidenceError(f"{label} omits PNG image data or IEND")
    if width == 0 or height == 0:
        raise EvidenceError(f"{label} has invalid zero dimensions")
    return width, height


def canonical_matrix_evidence(required: str) -> str | None:
    if required.endswith(".png"):
        return f"{EVIDENCE_PREFIX}/Screenshots/{required}"
    if required in RECORD_GATES:
        return record_path(required)
    special = {
        "Baseline.json": BASELINE,
        "CompletionReport.json": COMPLETION_JSON,
        "SourceManifestValidation.json": record_path("SourceManifestValidation.json"),
        "NegativeMutations.json": record_path("NegativeMutations.json"),
        "AttributionAudit.json": record_path("AttributionAudit.json"),
        "AccessibilityValidation.json": record_path("AccessibilityValidation.json"),
        "SecurityPrivacyValidation.json": record_path("SecurityPrivacyValidation.json"),
        "CompatibilityValidation.json": record_path("CompatibilityValidation.json"),
        "ShareBuilderValidation.json": record_path("ShareBuilderValidation.json"),
        "CipherInvitationValidation.json": record_path("CipherInvitationValidation.json"),
        "BaseThemeFailureValidation.json": record_path("BaseThemeFailureValidation.json"),
        "AppearanceDefaultsValidation.json": record_path("AppearanceDefaultsValidation.json"),
        "NorseProductionProvenanceValidation.json": record_path(
            "NorseProductionProvenanceValidation.json"
        ),
        "ThemeRootBackgroundValidation.json": record_path(
            "ThemeRootBackgroundValidation.json"
        ),
        "swift-package.log": f"{EVIDENCE_PREFIX}/GateRun/swift-package.log",
        "shipping-products.log": f"{EVIDENCE_PREFIX}/GateRun/shipping-products.log",
        "candidate zip": OWNER_ZIP,
        "check-remediation-completion log": COMPLETION_LOG,
        "shipping product log": f"{EVIDENCE_PREFIX}/GateRun/shipping-products.log",
        "negative mutation results": record_path("NegativeMutations.json"),
        "built Info.plists": BUILT_PRODUCT_INSPECTION_RESULTS,
    }
    if required in special:
        return special[required]
    paths = required_claim_paths(required)
    return paths[0] if len(paths) == 1 else None


def generated_test_evidence_paths() -> set[str]:
    return {
        COMPLETION_JSON,
        OWNER_ZIP,
        PAYLOAD_ZIP,
        TEST_EXECUTION_INDEX,
        COMPLETION_LOG,
        PUBLICATION_AUDIT_RECORD,
        NO_GIT_QUALIFICATION_RESULT,
        *[record_path(name) for name in RECORD_GATES],
    }


def validate_publication_audit(
    value: object,
    root: Path,
    source_revision: str | None,
    branch: str | None,
) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != PUBLICATION_AUDIT_KEYS:
        raise EvidenceError("publicationAudit keys differ from the locked audit schema")
    command = value.get("command")
    if (
        not isinstance(command, str)
        or not command.strip()
        or command != command.strip()
        or "\n" in command
        or "```" in command
    ):
        raise EvidenceError("publicationAudit.command must be one exact single-line command")
    log = normalized_relative(value.get("log"), "publicationAudit.log")
    log_path = repository_file(root, log, "publicationAudit.log")
    iso_timestamp(value.get("checkedAt"), "publicationAudit.checkedAt")
    default_branch = value.get("defaultBranch")
    if not isinstance(default_branch, str) or not default_branch.strip():
        raise EvidenceError("publicationAudit.defaultBranch must be nonempty")
    if value.get("branch") != branch:
        raise EvidenceError("publicationAudit.branch differs from the current branch")
    if branch is not None and branch == default_branch:
        raise EvidenceError("terminal evidence may not be generated on the default branch")
    if value.get("remoteInspectionPerformed") is not True:
        raise EvidenceError("publicationAudit must confirm remote inspection was performed")
    head_tags = value.get("headTags")
    if not isinstance(head_tags, list) or head_tags:
        raise EvidenceError("publicationAudit.headTags must be an empty array")
    false_fields = {
        "sourceMergedToDefault",
        "releasePublished",
        "uploadPerformed",
        "notarizationPerformed",
        "testFlightPerformed",
        "appStorePerformed",
        "rolloutPerformed",
    }
    if any(value.get(key) is not False for key in false_fields):
        raise EvidenceError("publicationAudit reports a prohibited publication action")
    text_value = log_path.read_text(encoding="utf-8", errors="replace")
    required_markers = [
        "PUBLICATION_AUDIT_PASS",
        default_branch,
        "REMOTE_INSPECTION_PERFORMED=true",
        "HEAD_TAGS=NONE",
        "SOURCE_MERGED_TO_DEFAULT=false",
        "RELEASE_PUBLISHED=false",
        "UPLOAD_PERFORMED=false",
        "NOTARIZATION_PERFORMED=false",
        "TESTFLIGHT_PERFORMED=false",
        "APPSTORE_PERFORMED=false",
        "ROLLOUT_PERFORMED=false",
    ]
    if branch is not None:
        required_markers.append(branch)
    if source_revision is not None:
        required_markers.append(source_revision)
    missing = [marker for marker in required_markers if marker not in text_value]
    if missing:
        raise EvidenceError(
            "publicationAudit.log omits required markers: " + ", ".join(missing)
        )
    if source_revision is not None:
        tags = run(
            ["git", "tag", "--points-at", source_revision],
            cwd=root,
            label="source revision tag inspection",
        ).stdout.splitlines()
        if tags:
            raise EvidenceError("source revision already has a Git tag")
        default_refs = [f"refs/remotes/origin/{default_branch}", default_branch]
        default_ref = None
        for candidate in default_refs:
            exists = run(
                ["git", "rev-parse", "--verify", candidate],
                cwd=root,
                label="default branch lookup",
                require_success=False,
            )
            if exists.returncode == 0:
                default_ref = candidate
                break
        if default_ref is None:
            raise EvidenceError("publication audit cannot resolve the default branch")
        merged = run(
            ["git", "merge-base", "--is-ancestor", source_revision, default_ref],
            cwd=root,
            label="default branch merge inspection",
            require_success=False,
        )
        if merged.returncode == 0:
            raise EvidenceError("source revision is already merged to the default branch")
        if merged.returncode != 1:
            raise EvidenceError("default branch merge inspection failed")
    return dict(value)


def validate_input(
    document: object,
    root: Path,
    source_hash: str,
    manifest_document: dict[str, Any],
    manifest_paths: set[str],
    revision: str | None,
    branch: str | None,
    test_rows: list[dict[str, str]],
    matrix_screenshots: dict[str, str],
    finding_gates: dict[str, tuple[str, ...]],
    finding_controls: dict[str, dict[str, tuple[str, ...]]],
) -> dict[str, Any]:
    if not isinstance(document, dict) or set(document) != TOP_LEVEL_INPUT_KEYS:
        raise EvidenceError(
            "input root keys must be exactly: " + ", ".join(sorted(TOP_LEVEL_INPUT_KEYS))
        )
    if document.get("schemaVersion") != SCHEMA_VERSION:
        raise EvidenceError("input schemaVersion must be 1.0")
    if document.get("sourceRevision") != revision:
        raise EvidenceError("input sourceRevision differs from the validated source revision")

    environment = document.get("environment")
    required_environment = {"operatingSystem", "architecture", "xcode", "swift"}
    if (
        not isinstance(environment, dict)
        or not required_environment.issubset(environment)
        or not all(isinstance(key, str) and isinstance(value, str) and value.strip()
                   for key, value in environment.items())
    ):
        raise EvidenceError(
            "environment must contain nonempty operatingSystem, architecture, xcode, and swift strings"
        )

    suites_value = document.get("suites")
    if not isinstance(suites_value, list) or not suites_value:
        raise EvidenceError("suites must be a nonempty array")
    suites: dict[str, dict[str, Any]] = {}
    for index, value in enumerate(suites_value):
        label = f"suites[{index}]"
        if not isinstance(value, dict) or set(value) != SUITE_KEYS:
            raise EvidenceError(f"{label} keys differ from the suite schema")
        name = value.get("name")
        if not isinstance(name, str) or not name.strip() or name in suites:
            raise EvidenceError(f"{label}.name must be nonempty and unique")
        for key in ("platform", "kind"):
            if not isinstance(value.get(key), str) or not value[key].strip():
                raise EvidenceError(f"{label}.{key} must be a nonempty string")
        counts = validate_counts(
            {key: value.get(key) for key in ("executed", "passed", "failed", "skipped")},
            label,
        )
        if counts["failed"] != 0 or counts["skipped"] != 0:
            raise EvidenceError(
                f"{label} cannot support terminal PASS with failed or skipped tests"
            )
        if counts["executed"] == 0 or counts["passed"] == 0:
            raise EvidenceError(f"{label} must record at least one executed and passed check")
        log = normalized_relative(value.get("log"), f"{label}.log")
        if log != COMPLETION_LOG:
            repository_file(root, log, f"{label}.log")
        suites[name] = dict(value)

    screenshots_value = document.get("screenshots")
    if not isinstance(screenshots_value, list) or not screenshots_value:
        raise EvidenceError("screenshots must be a nonempty array")
    screenshots: list[dict[str, str]] = []
    screenshot_paths: set[str] = set()
    screenshot_basenames: set[str] = set()
    screenshot_platforms: set[str] = set()
    for index, value in enumerate(screenshots_value):
        label = f"screenshots[{index}]"
        if not isinstance(value, dict) or set(value) != SCREENSHOT_KEYS:
            raise EvidenceError(f"{label} keys differ from the screenshot schema")
        path = normalized_relative(value.get("path"), f"{label}.path")
        if not path.startswith(f"{EVIDENCE_PREFIX}/Screenshots/") or not path.endswith(".png"):
            raise EvidenceError(f"{label}.path must be a PNG under {EVIDENCE_PREFIX}/Screenshots")
        repository_file(root, path, f"{label}.path")
        validate_png(root / path, f"{label}.path")
        platform = value.get("platform")
        description = value.get("description")
        if not isinstance(platform, str) or not platform.strip():
            raise EvidenceError(f"{label}.platform must be a nonempty string")
        if not isinstance(description, str) or not description.strip() or "\n" in description:
            raise EvidenceError(f"{label}.description must be nonempty single-line text")
        basename = Path(path).name
        if path in screenshot_paths or basename in screenshot_basenames:
            raise EvidenceError("screenshot paths and basenames must be unique")
        screenshot_paths.add(path)
        screenshot_basenames.add(basename)
        screenshot_platforms.add(platform)
        screenshots.append(dict(value))
    expected_screenshot_paths = {
        f"{EVIDENCE_PREFIX}/Screenshots/{name}" for name in matrix_screenshots
    } | {
        f"{EVIDENCE_PREFIX}/{claim}" for claim in GATE_SCREENSHOT_CLAIMS
    } | set(WORKSPACE_SCREENSHOT_CLAIM_PATHS) | {
        path
        for paths in PLATFORM_SCREENSHOT_CLAIM_PATHS.values()
        for path in paths
    }
    missing_screenshots = sorted(expected_screenshot_paths - screenshot_paths)
    if missing_screenshots:
        raise EvidenceError(
            "screenshots omit locked gate/test evidence: " + ", ".join(missing_screenshots)
        )
    by_path = {item["path"]: item for item in screenshots}
    for name, expected_platform in matrix_screenshots.items():
        path = f"{EVIDENCE_PREFIX}/Screenshots/{name}"
        if by_path[path]["platform"] != expected_platform:
            raise EvidenceError(
                f"{path} platform differs from the locked test matrix"
            )
    for claim, paths in PLATFORM_SCREENSHOT_CLAIM_PATHS.items():
        expected_platform = PLATFORM_SCREENSHOT_CLAIM_PLATFORMS[claim]
        for path in paths:
            if by_path[path]["platform"] != expected_platform:
                raise EvidenceError(
                    f"{path} platform differs from the platform screenshot contract"
                )
    for path, (expected_platform, expected_description) in (
        WRITTEN_SCREENSHOT_CONTRACTS.items()
    ):
        if by_path[path]["platform"] != expected_platform:
            raise EvidenceError(f"{path} platform differs from the written contract")
        if by_path[path]["description"] != expected_description:
            raise EvidenceError(f"{path} description differs from the written contract")
    required_platforms = {"macOS", "iPhone Simulator", "iPad Simulator"}
    if not required_platforms.issubset(screenshot_platforms):
        raise EvidenceError(
            "screenshots must identify macOS, iPhone Simulator, and iPad Simulator evidence"
        )

    simulator_values = document.get("simulators")
    if not isinstance(simulator_values, dict) or set(simulator_values) != {"iPhone", "iPad"}:
        raise EvidenceError("simulators must contain exactly iPhone and iPad")
    simulators: dict[str, dict[str, str]] = {}
    for family in ("iPhone", "iPad"):
        value = simulator_values.get(family)
        if not isinstance(value, dict) or set(value) != SIMULATOR_KEYS:
            raise EvidenceError(f"simulators.{family} keys differ from the simulator schema")
        if not all(isinstance(value.get(key), str) and value[key].strip()
                   for key in SIMULATOR_KEYS):
            raise EvidenceError(f"simulators.{family} values must be nonempty strings")
        if SIMULATOR_UDID.fullmatch(value["udid"]) is None:
            raise EvidenceError(f"simulators.{family}.udid is not a canonical Simulator UDID")
        if family.lower() not in value["name"].lower() or "ios" not in value["runtime"].lower():
            raise EvidenceError(
                f"simulators.{family} must identify the selected {family} iOS Simulator"
            )
        simulators[family] = dict(value)

    bundle_id = document.get("bundleIdentifier")
    if not isinstance(bundle_id, str) or BUNDLE_IDENTIFIER.fullmatch(bundle_id) is None:
        raise EvidenceError("bundleIdentifier must be a reverse-DNS identifier")
    if bundle_id != EXPECTED_BUNDLE_IDENTIFIER:
        raise EvidenceError(
            f"bundleIdentifier must equal the shipping identifier {EXPECTED_BUNDLE_IDENTIFIER}"
        )
    reset_commands = nonempty_strings(
        document.get("resetCommands"), "resetCommands", single_line=True
    )
    seed_commands = nonempty_strings(
        document.get("seedCommands"), "seedCommands", single_line=True
    )
    non_gating = nonempty_strings(
        document.get("nonGatingExternal"), "nonGatingExternal"
    )
    if tuple(non_gating) != FIXED_NON_GATING_BOUNDARIES:
        raise EvidenceError(
            "nonGatingExternal must preserve the four locked external boundaries in order"
        )

    publication_audit = validate_publication_audit(
        document.get("publicationAudit"), root, revision, branch
    )

    rows_by_id = {row["testID"]: row for row in test_rows}
    tests_value = document.get("tests")
    if not isinstance(tests_value, dict) or set(tests_value) != set(rows_by_id):
        raise EvidenceError("tests must bind exactly all 87 locked TEST-MATRIX rows")
    generated_evidence = generated_test_evidence_paths()
    tests: dict[str, dict[str, Any]] = {}
    for test_id in sorted(rows_by_id):
        row = rows_by_id[test_id]
        value = tests_value.get(test_id)
        label = f"tests.{test_id}"
        if not isinstance(value, dict) or set(value) != TEST_EXECUTION_KEYS:
            raise EvidenceError(f"{label} keys differ from the execution-binding schema")
        if value.get("result") != "PASS":
            raise EvidenceError(f"{label}.result must be PASS")
        suite_name = value.get("suiteName")
        if not isinstance(suite_name, str) or suite_name not in suites:
            raise EvidenceError(f"{label}.suiteName references an unknown suite")
        command = value.get("command")
        if (
            not isinstance(command, str)
            or not command.strip()
            or command != command.strip()
            or "\n" in command
        ):
            raise EvidenceError(f"{label}.command must be exact single-line text")
        simulator_family = {
            "iPhone Simulator": "iPhone",
            "iPad Simulator": "iPad",
        }.get(row["platform"])
        if (
            simulator_family is not None
            and simulators[simulator_family]["udid"] not in command
        ):
            raise EvidenceError(
                f"{label}.command must bind the selected {simulator_family} Simulator UDID"
            )
        log = normalized_relative(value.get("log"), f"{label}.log")
        if log != suites[suite_name]["log"]:
            raise EvidenceError(f"{label}.log must equal its suite log")
        if log != COMPLETION_LOG:
            repository_file(root, log, f"{label}.log")
        if value.get("requiredEvidence") != row["requiredEvidence"]:
            raise EvidenceError(
                f"{label}.requiredEvidence differs from the locked matrix row"
            )
        evidence = nonempty_strings(value.get("evidence"), f"{label}.evidence")
        normalized_evidence: list[str] = []
        for index, path_value in enumerate(evidence):
            relative = normalized_relative(path_value, f"{label}.evidence[{index}]")
            if (
                relative not in generated_evidence
                and not relative.startswith(CLAIM_EVIDENCE_PREFIX + "/")
            ):
                repository_file(root, relative, f"{label}.evidence[{index}]")
            normalized_evidence.append(relative)
        if normalized_evidence != sorted(set(normalized_evidence)):
            raise EvidenceError(f"{label}.evidence must be unique and sorted")
        if log not in normalized_evidence:
            raise EvidenceError(f"{label}.evidence must include its exact suite log")
        required_paths = set(required_claim_paths(row["requiredEvidence"]))
        if not required_paths.issubset(normalized_evidence):
            raise EvidenceError(
                f"{label}.evidence omits exact locked required evidence: "
                + ", ".join(sorted(required_paths - set(normalized_evidence)))
            )
        if row["requiredEvidence"] == "screenshots" and not any(
            path.startswith(f"{EVIDENCE_PREFIX}/Screenshots/")
            for path in normalized_evidence
        ):
            raise EvidenceError(f"{label}.evidence must bind screenshots")
        tests[test_id] = {
            "result": "PASS",
            "suiteName": suite_name,
            "command": command,
            "log": log,
            "requiredEvidence": row["requiredEvidence"],
            "evidence": normalized_evidence,
        }
    if not set(WORKSPACE_SCREENSHOT_CLAIM_PATHS).issubset(tests["T-071"]["evidence"]):
        raise EvidenceError(
            "T-071 must bind the exact optional-provider workspace, Settings, and Vault PNGs"
        )
    if tests["T-006"]["command"] != no_git_command(source_hash):
        raise EvidenceError(
            "T-006 command must be the exact copied-tree/no-Git completion-checker command"
        )
    if NO_GIT_QUALIFICATION_RESULT not in tests["T-006"]["evidence"]:
        raise EvidenceError("T-006 must bind the generated copied-tree/no-Git result")
    for test_id in ("T-096", "T-097"):
        if not {
            BUILT_PRODUCT_INSPECTION_RESULTS,
            DOMAIN_SHIPPING_VALIDATION_LOG,
        }.issubset(tests[test_id]["evidence"]):
            raise EvidenceError(
                f"{test_id} must bind the exact built-product inspection and "
                "shipping-product log"
            )
    if DOMAIN_SHIPPING_VALIDATION_LOG not in tests["T-116"]["evidence"]:
        raise EvidenceError("T-116 must bind the exact shipping-product log")
    distribution_test = tests["T-121"]
    if publication_audit["log"] not in distribution_test["evidence"]:
        raise EvidenceError("T-121 must bind the exact publication-audit log")
    if distribution_test["command"] != publication_audit["command"]:
        raise EvidenceError("T-121 command must equal publicationAudit.command")
    distribution_test["evidence"] = sorted(set(
        distribution_test["evidence"] + [PUBLICATION_AUDIT_RECORD]
    ))
    suite_binding_counts = {
        suite_name: sum(
            execution["suiteName"] == suite_name for execution in tests.values()
        )
        for suite_name in suites
    }
    unbound_suites = sorted(
        suite_name for suite_name, count in suite_binding_counts.items() if count == 0
    )
    if unbound_suites:
        raise EvidenceError("suites are not bound to locked tests: " + ", ".join(unbound_suites))
    for suite_name, bound_count in suite_binding_counts.items():
        if suites[suite_name]["executed"] != bound_count:
            raise EvidenceError(
                f"suite {suite_name!r} executed count differs from its "
                f"{bound_count} exact locked bindings"
            )

    suite_results = validate_structured_suite_results(
        root=root,
        source_hash=source_hash,
        source_revision=revision,
        suites=suites,
        tests=tests,
        rows_by_id=rows_by_id,
    )
    built_product_inspection, theme_budgets, domain_producer = (
        validate_built_product_inspection(
        root=root,
        source_hash=source_hash,
        source_revision=revision,
        expected_raw_log=suite_results[tests["T-096"]["suiteName"]]["rawLog"],
        )
    )
    domain_results = {
        CLOUD_GAME_CENTER_RESULTS: validate_domain_result_report(
            root=root,
            relative=CLOUD_GAME_CENTER_RESULTS,
            source_hash=source_hash,
            source_revision=revision,
            expected_test_ids=("T-096", "T-097"),
            expected_markers=CLOUD_GAME_CENTER_MARKERS,
            suite_results=suite_results,
            tests=tests,
            performance=False,
            producer=domain_producer,
            theme_budgets=theme_budgets,
            product_inspection=built_product_inspection,
        ),
        PERFORMANCE_RESOURCE_RESULTS: validate_domain_result_report(
            root=root,
            relative=PERFORMANCE_RESOURCE_RESULTS,
            source_hash=source_hash,
            source_revision=revision,
            expected_test_ids=("T-116",),
            expected_markers=PERFORMANCE_RESOURCE_MARKERS,
            suite_results=suite_results,
            tests=tests,
            performance=True,
            producer=domain_producer,
            theme_budgets=theme_budgets,
        ),
    }
    validate_domain_execution_log(
        root=root,
        producer=domain_producer,
        cloud_document=domain_results[CLOUD_GAME_CENTER_RESULTS],
        performance_document=domain_results[PERFORMANCE_RESOURCE_RESULTS],
        product_inspection=built_product_inspection,
        theme_budgets=theme_budgets,
    )

    records_value = document.get("records")
    if not isinstance(records_value, dict) or set(records_value) != set(RECORD_GATES):
        raise EvidenceError("records must contain exactly the 13 named evidence records")
    records: dict[str, dict[str, Any]] = {}
    generated_prefixes = (
        f"{EVIDENCE_PREFIX}/Attachments/",
        CLAIM_EVIDENCE_PREFIX + "/",
    )
    generated_exact = {
        DEFECT_CLOSURE, EVIDENCE_INDEX, COMPLETION_JSON, COMPLETION_MARKDOWN,
        EVIDENCE_HANDOFF, COMPLETION_LOG, OWNER_ZIP, PAYLOAD_ZIP,
        TEST_EXECUTION_INDEX, EXTERNAL_SHA256SUMS,
        PUBLICATION_AUDIT_RECORD,
        ARTIFACT_HANDOFF, SCREENSHOT_INDEX, TEST_SUMMARY,
        ADJACENT_COMPLETION_JSON, ADJACENT_COMPLETION_MARKDOWN,
    } | {f"{EVIDENCE_PREFIX}/{name}" for name in RECORD_GATES}
    for record_name in RECORD_GATES:
        value = records_value.get(record_name)
        label = f"records.{record_name}"
        if not isinstance(value, dict) or set(value) != RECORD_REQUIRED_KEYS:
            raise EvidenceError(f"{label} keys differ from the record-input schema")
        logs = nonempty_strings(value.get("logs"), f"{label}.logs", allow_empty=True)
        artifacts = nonempty_strings(
            value.get("artifacts"), f"{label}.artifacts", allow_empty=True
        )
        for kind, paths in (("logs", logs), ("artifacts", artifacts)):
            for index, path_value in enumerate(paths):
                relative = normalized_relative(path_value, f"{label}.{kind}[{index}]")
                if relative in generated_exact or relative.startswith(generated_prefixes):
                    raise EvidenceError(
                        f"{label}.{kind}[{index}] must not name a generator-owned output"
                    )
                repository_file(root, relative, f"{label}.{kind}[{index}]")
        started = iso_timestamp(value.get("startedAt"), f"{label}.startedAt")
        ended = iso_timestamp(value.get("endedAt"), f"{label}.endedAt")
        if ended < started:
            raise EvidenceError(f"{label} endedAt precedes startedAt")
        notes = nonempty_strings(value.get("notes"), f"{label}.notes", allow_empty=True)
        assigned_tests = [
            test_id for test_id, row in rows_by_id.items()
            if set(row["gateIDs"].split(";")).intersection(RECORD_GATES[record_name])
        ]
        if not assigned_tests:
            raise EvidenceError(f"{label} has no locked TEST-MATRIX assignments")
        records[record_name] = {
            "commands": sorted({tests[test_id]["command"] for test_id in assigned_tests}),
            "suiteNames": sorted({tests[test_id]["suiteName"] for test_id in assigned_tests}),
            "logs": logs,
            "artifacts": artifacts,
            "startedAt": value["startedAt"],
            "endedAt": value["endedAt"],
            "notes": notes,
        }

    findings_value = document.get("findings")
    if not isinstance(findings_value, dict) or set(findings_value) != set(FINDING_IDS):
        raise EvidenceError("findings must contain exactly RSA-001 through RSA-012")
    baseline = load_json(root / BASELINE, "baseline evidence")
    baseline_revision = None
    if isinstance(baseline, dict):
        repository = baseline.get("repository")
        if isinstance(repository, dict) and isinstance(repository.get("head"), str):
            baseline_revision = repository["head"]
    current_projection = manifest_record_projection(
        manifest_document, "SOURCE-MANIFEST.json"
    )
    before_document = load_json(
        repository_file(root, SOURCE_MANIFEST_BEFORE, "SOURCE-MANIFEST.before.json"),
        "SOURCE-MANIFEST.before.json",
    )
    before_projection = manifest_record_projection(
        before_document, "SOURCE-MANIFEST.before.json"
    )
    changed_at_revision: set[str]
    if revision is not None:
        if (
            not isinstance(baseline_revision, str)
            or HEX_40.fullmatch(baseline_revision) is None
        ):
            raise EvidenceError("Baseline.json contains an invalid baseline revision")
        source_baseline = baseline.get("sourceBaseline") if isinstance(baseline, dict) else None
        expected_baseline_values = {
            "packageArchiveSHA256": EXPECTED_BASELINE_ARCHIVE_SHA256,
            "sourceManifestPath": SOURCE_MANIFEST_BEFORE,
            "sourceManifestSHA256": EXPECTED_BASELINE_MANIFEST_AGGREGATE,
            "sourceManifestFileCount": EXPECTED_BASELINE_FILE_COUNT,
        }
        baseline_repository = (
            baseline.get("repository") if isinstance(baseline, dict) else None
        )
        expected_before_keys = {
            "aggregateSHA256", "excludes", "fileCount", "files", "rootName",
            "schemaVersion",
        }
        if (
            baseline_revision != EXPECTED_BASELINE_REVISION
            or not isinstance(baseline_repository, dict)
            or baseline_repository.get("originMain") != EXPECTED_BASELINE_REVISION
            or not isinstance(source_baseline, dict)
            or any(
                source_baseline.get(key) != expected
                for key, expected in expected_baseline_values.items()
            )
            or set(before_document) != expected_before_keys
            or before_document.get("schemaVersion") != "1.0"
            or before_document.get("rootName") != "Rune-Scribe-Remediation-v1"
            or before_document.get("excludes") != list(BASELINE_MANIFEST_EXCLUDES)
            or before_document.get("aggregateSHA256")
            != EXPECTED_BASELINE_MANIFEST_AGGREGATE
            or before_document.get("fileCount") != EXPECTED_BASELINE_FILE_COUNT
        ):
            raise EvidenceError("Baseline.json/SOURCE-MANIFEST.before.json anchors differ")
        ancestry = run(
            ["git", "merge-base", "--is-ancestor", baseline_revision, revision],
            cwd=root,
            label="baseline revision ancestry",
            require_success=False,
        )
        if ancestry.returncode != 0 or baseline_revision == revision:
            raise EvidenceError(
                "Baseline.json revision must strictly precede sourceRevision"
            )
        excludes = before_document.get("excludes") if isinstance(before_document, dict) else None
        if not isinstance(excludes, list) or not all(
            isinstance(item, str) for item in excludes
        ):
            raise EvidenceError("SOURCE-MANIFEST.before.json excludes are invalid")
        reconstructed_before = git_revision_manifest_projection(
            root, baseline_revision, excludes
        )
        if reconstructed_before != before_projection:
            raise EvidenceError(
                "SOURCE-MANIFEST.before.json differs from Baseline.json repository.head"
            )
        changed = subprocess.run(
            [
                "git", "diff", "--name-only", "--no-renames", "-z",
                baseline_revision, revision, "--",
            ],
            cwd=root,
            check=False,
            capture_output=True,
            timeout=300,
        )
        if changed.returncode != 0:
            detail = changed.stderr.decode("utf-8", errors="replace").strip()
            raise EvidenceError(
                "baseline-to-source changed-file inventory failed: "
                + (detail or "no diagnostic output")
            )
        try:
            changed_at_revision = {
                value.decode("utf-8")
                for value in changed.stdout.split(b"\0")
                if value
            }
        except UnicodeDecodeError as exception:
            raise EvidenceError(
                "baseline-to-source changed-file inventory contains invalid UTF-8"
            ) from exception
        if any(
            not relative
            or PurePosixPath(relative).is_absolute()
            or ".." in PurePosixPath(relative).parts
            or PurePosixPath(relative).as_posix() != relative
            for relative in changed_at_revision
        ):
            raise EvidenceError(
                "baseline-to-source changed-file inventory contains unsafe paths"
            )
        projection_changed_final_paths = {
            path
            for path, record in current_projection.items()
            if before_projection.get(path) != record
        }
        projection_removed_paths = set(before_projection) - set(current_projection)
        git_changed_final_paths = changed_at_revision & set(current_projection)
        git_removed_paths = (
            changed_at_revision & set(before_projection)
        ) - set(current_projection)
        if git_changed_final_paths != projection_changed_final_paths:
            raise EvidenceError(
                "baseline-to-source Git diff differs from final manifest "
                "byte/hash/executable changes"
            )
        if git_removed_paths != projection_removed_paths:
            raise EvidenceError(
                "baseline-to-source Git diff differs from before-manifest deletions"
            )
    else:
        changed_at_revision = {
            path
            for path, record in current_projection.items()
            if before_projection.get(path) != record
        } | (set(before_projection) - set(current_projection))
    changed_final_paths = changed_at_revision & set(current_projection)
    removed_at_revision = changed_at_revision - set(current_projection)
    validate_global_shipping_path_coverage(
        changed_final_paths, removed_at_revision
    )
    findings: dict[str, dict[str, Any]] = {}
    for finding_id in FINDING_IDS:
        value = findings_value.get(finding_id)
        label = f"findings.{finding_id}"
        if not isinstance(value, dict) or set(value) != FINDING_INPUT_KEYS:
            raise EvidenceError(f"{label} keys differ from the finding-binding schema")
        changed_files = nonempty_strings(
            value.get("changedFiles"), f"{label}.changedFiles", allow_empty=True
        )
        for index, relative_value in enumerate(changed_files):
            relative = normalized_relative(relative_value, f"{label}.changedFiles[{index}]")
            repository_file(root, relative, f"{label}.changedFiles[{index}]")
            if relative not in manifest_paths:
                raise EvidenceError(
                    f"{label}.changedFiles[{index}] is absent from SOURCE-MANIFEST.json"
                )
            if relative not in changed_final_paths:
                raise EvidenceError(
                    f"{label}.changedFiles[{index}] did not change from the recorded baseline"
                )
        control = finding_controls[finding_id]
        removed_files = nonempty_strings(
            value.get("removedFiles"), f"{label}.removedFiles", allow_empty=True
        )
        removal_bindings = value.get("removalBindings")
        exact_removal_bindings = REMOVED_IMPLEMENTATION_PATHS[finding_id]
        if not isinstance(removal_bindings, dict) or set(removal_bindings) != set(
            exact_removal_bindings
        ):
            raise EvidenceError(f"{label}.removalBindings differ from locked removal policy")
        normalized_removal_bindings: dict[str, list[str]] = {}
        for expectation, exact_paths in exact_removal_bindings.items():
            paths = nonempty_strings(
                removal_bindings.get(expectation),
                f"{label}.removalBindings[{expectation!r}]",
            )
            normalized_paths = [
                normalized_relative(path, f"{label}.removalBindings[{expectation!r}]")
                for path in paths
            ]
            if normalized_paths != list(exact_paths):
                raise EvidenceError(
                    f"{label}.removalBindings[{expectation!r}] differs from exact tombstones"
                )
            normalized_removal_bindings[expectation] = normalized_paths
        expected_removed_files = sorted({
            path for paths in exact_removal_bindings.values() for path in paths
        })
        if removed_files != expected_removed_files:
            raise EvidenceError(f"{label}.removedFiles differ from locked tombstones")
        for relative in removed_files:
            if (
                relative not in before_projection
                or relative in current_projection
                or relative not in removed_at_revision
            ):
                raise EvidenceError(
                    f"{label}.removedFiles does not prove exact baseline-to-final removal: {relative}"
                )
        file_binding_values: dict[str, dict[str, list[str]]] = {}
        binding_unions: dict[str, set[str]] = {}
        for input_key, control_key in (
            ("implementationBindings", "implementation"),
            ("sourceAreaBindings", "sourceAreas"),
        ):
            bindings = value.get(input_key)
            expectations = set(control[control_key])
            if not isinstance(bindings, dict) or set(bindings) != expectations:
                raise EvidenceError(
                    f"{label}.{input_key} must bind every exact locked expectation"
                )
            normalized_bindings: dict[str, list[str]] = {}
            for expectation in control[control_key]:
                paths = nonempty_strings(
                    bindings.get(expectation), f"{label}.{input_key}[{expectation!r}]"
                )
                normalized_paths: list[str] = []
                for path_value in paths:
                    relative = normalized_relative(
                        path_value, f"{label}.{input_key}[{expectation!r}]"
                    )
                    repository_file(
                        root, relative, f"{label}.{input_key}[{expectation!r}]"
                    )
                    if relative not in manifest_paths:
                        raise EvidenceError(
                            f"{label}.{input_key} binds a file absent from SOURCE-MANIFEST.json"
                        )
                    normalized_paths.append(relative)
                if normalized_paths != sorted(set(normalized_paths)):
                    raise EvidenceError(
                        f"{label}.{input_key}[{expectation!r}] must be unique and sorted"
                    )
                expectation_index = control[control_key].index(expectation)
                exact_paths = list(
                    SOURCE_AREA_PATHS[finding_id][expectation_index]
                    if input_key == "sourceAreaBindings"
                    else IMPLEMENTATION_PATHS[finding_id][expectation_index]
                )
                if normalized_paths != exact_paths:
                    raise EvidenceError(
                        f"{label}.{input_key}[{expectation!r}] differs from its exact locked path set"
                    )
                normalized_bindings[expectation] = normalized_paths
                binding_unions.setdefault(input_key, set()).update(normalized_paths)
            file_binding_values[input_key] = normalized_bindings
        implementation_files = binding_unions.get("implementationBindings", set())
        source_area_files = binding_unions.get("sourceAreaBindings", set())
        expected_changed_files = implementation_files & changed_final_paths
        if expected_changed_files != set(changed_files):
            raise EvidenceError(
                f"{label}.changedFiles must exactly equal changed locked implementation bindings"
            )
        if (
            any(not path.startswith("docs/") for path in implementation_files)
            and not any(not path.startswith("docs/") for path in changed_files)
        ):
            raise EvidenceError(
                f"{label} has no baseline-changed non-document implementation file"
            )
        if not implementation_files.issubset(source_area_files):
            raise EvidenceError(
                f"{label}.implementationBindings must be grounded in locked source areas"
            )

        test_bindings_value = value.get("testBindings")
        test_expectations = set(control["tests"])
        if not isinstance(test_bindings_value, dict) or set(test_bindings_value) != test_expectations:
            raise EvidenceError(f"{label}.testBindings must bind every locked test expectation")
        normalized_test_bindings: dict[str, list[str]] = {}
        covered_finding_gates: set[str] = set()
        for expectation_index, expectation in enumerate(control["tests"]):
            test_ids = nonempty_strings(
                test_bindings_value.get(expectation),
                f"{label}.testBindings[{expectation!r}]",
            )
            expected_test_ids = list(TEST_EXPECTATION_IDS[finding_id][expectation_index])
            if test_ids != expected_test_ids:
                raise EvidenceError(
                    f"{label}.testBindings[{expectation!r}] differs from its "
                    "expectation-specific locked test set"
                )
            for test_id in test_ids:
                if test_id not in tests:
                    raise EvidenceError(f"{label}.testBindings references unknown {test_id}")
                row_gates = set(rows_by_id[test_id]["gateIDs"].split(";"))
                if not row_gates.intersection(finding_gates[finding_id]):
                    raise EvidenceError(
                        f"{label}.testBindings references {test_id} outside its finding gates"
                    )
                covered_finding_gates.update(row_gates.intersection(finding_gates[finding_id]))
            normalized_test_bindings[expectation] = test_ids
        if not set(finding_gates[finding_id]).issubset(covered_finding_gates):
            raise EvidenceError(f"{label}.testBindings do not cover every locked finding gate")
        findings[finding_id] = {
            "changedFiles": changed_files,
            "removedFiles": removed_files,
            "removalBindings": normalized_removal_bindings,
            **file_binding_values,
            "testBindings": normalized_test_bindings,
        }

    return {
        "sourceRevision": document.get("sourceRevision"),
        "environment": dict(environment),
        "suites": suites,
        "screenshots": screenshots,
        "simulators": simulators,
        "bundleIdentifier": bundle_id,
        "resetCommands": reset_commands,
        "seedCommands": seed_commands,
        "nonGatingExternal": non_gating,
        "tests": tests,
        "testRows": rows_by_id,
        "suiteResults": suite_results,
        "domainResults": domain_results,
        "builtProductInspection": built_product_inspection,
        "publicationAudit": publication_audit,
        "records": records,
        "findings": findings,
    }


class StagedOutputs:
    """Build generated files off-tree and publish them transactionally."""

    def __init__(self, repository_root: Path, staging_root: Path) -> None:
        self.repository_root = repository_root
        self.staging_root = staging_root
        self.files: set[str] = set()
        self.managed_targets: set[str] = set()
        self.backups: set[str] = set()

    def staged_path(self, relative: str) -> Path:
        return self.staging_root / "new" / relative

    def backup_path(self, relative: str) -> Path:
        return self.staging_root / "backup" / relative

    def write_bytes(self, relative: str, data: bytes) -> None:
        normalized_relative(relative, "generated output path")
        path = self.staged_path(relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.files.add(relative)

    def write_json(self, relative: str, document: object) -> None:
        self.write_bytes(relative, json_bytes(document))

    def resolve(self, relative: str) -> Path:
        staged = self.staged_path(relative)
        if staged.is_file():
            return staged
        repository = self.repository_root / relative
        if repository.is_file() and not repository.is_symlink():
            return repository
        raise EvidenceError(f"bound evidence file does not exist: {relative}")

    def digest(self, relative: str) -> str:
        return sha256_file(self.resolve(relative))

    def publish(self, relatives: Iterable[str] | None = None) -> None:
        selected = sorted(set(relatives if relatives is not None else self.files))
        for relative in selected:
            source = self.staged_path(relative)
            if not source.is_file():
                raise EvidenceError(f"staged output is missing: {relative}")
            target = self.repository_root / relative
            ancestor = self.repository_root
            for part in PurePosixPath(relative).parts[:-1]:
                ancestor = ancestor / part
                if ancestor.is_symlink():
                    raise EvidenceError(
                        f"refusing to traverse a symlinked output parent: {relative}"
                    )
            if target.is_symlink() or (target.exists() and not target.is_file()):
                raise EvidenceError(f"refusing to replace unsafe output target: {relative}")
            target.parent.mkdir(parents=True, exist_ok=True)
            if relative not in self.managed_targets and target.exists():
                backup = self.backup_path(relative)
                backup.parent.mkdir(parents=True, exist_ok=True)
                os.replace(target, backup)
                self.backups.add(relative)
            os.replace(source, target)
            self.managed_targets.add(relative)

    def rollback(self) -> None:
        for relative in sorted(self.managed_targets, reverse=True):
            target = self.repository_root / relative
            if target.is_file() or target.is_symlink():
                target.unlink()
        for relative in sorted(self.backups):
            backup = self.backup_path(relative)
            target = self.repository_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if backup.exists():
                os.replace(backup, target)
        self.managed_targets.clear()
        self.backups.clear()

    def verify(self) -> list[str]:
        differences: list[str] = []
        for relative in sorted(self.files):
            expected = self.staged_path(relative)
            actual = self.repository_root / relative
            if not actual.is_file() or actual.is_symlink():
                differences.append(f"missing generated output: {relative}")
            elif sha256_file(expected) != sha256_file(actual):
                differences.append(f"generated output differs: {relative}")
        return differences


def test_rows_for_gate(
    test_rows: list[dict[str, str]], gate_id: str
) -> list[dict[str, str]]:
    rows = [row for row in test_rows if gate_id in row["gateIDs"].split(";")]
    return sorted(rows, key=lambda row: (row["testID"], row["scenario"]))


def test_label(row: dict[str, str]) -> str:
    return f"{row['testID']}: {row['scenario']}"


def record_path(record_name: str) -> str:
    return f"{EVIDENCE_PREFIX}/{record_name}"


def attachment_path(record_name: str) -> str:
    return f"{EVIDENCE_PREFIX}/Attachments/{Path(record_name).stem}-Test-Matrix.md"


def record_claims(
    record_name: str, gate_requirements: dict[str, tuple[str, ...]]
) -> list[str]:
    claims: set[str] = set()
    for gate_id in RECORD_GATES[record_name]:
        claims.update(gate_requirements[gate_id])
    return sorted(claims)


def make_test_attachment(
    record_name: str,
    input_data: dict[str, Any],
    matrix_digest: str,
    outputs: StagedOutputs,
) -> bytes:
    lines = [
        f"# {Path(record_name).stem} Test Assignments",
        "",
        f"Source test-matrix SHA-256: `{matrix_digest}`",
        "",
        "Every row below is an exact locked TEST-MATRIX execution binding. Paths and hashes identify the immutable result inputs used by this record.",
        "",
        "| Test | Result | Suite | Command | Log / SHA-256 | Required evidence | Bound evidence / SHA-256 |",
        "|---|---|---|---|---|---|---|",
    ]
    assigned_gates = set(RECORD_GATES[record_name])
    rows = [
        row for row in input_data["testRows"].values()
        if assigned_gates.intersection(row["gateIDs"].split(";"))
    ]
    for row in sorted(rows, key=lambda item: item["testID"]):
        execution = input_data["tests"][row["testID"]]
        log = execution["log"]
        log_cell = f"`{log}`<br>`{outputs.digest(log)}`"
        evidence_cells = [
            f"`{path}`<br>`{outputs.digest(path)}`" for path in execution["evidence"]
        ]
        escape = lambda value: value.replace("|", "\\|")
        lines.append(
            "| "
            + " | ".join((
                f"{row['testID']}: {escape(row['scenario'])}",
                execution["result"],
                escape(execution["suiteName"]),
                f"`{escape(execution['command'])}`",
                log_cell,
                escape(row["requiredEvidence"]),
                "<br>".join(evidence_cells),
            ))
            + " |"
        )
        lines.append(
            f"<!-- {row['testID']} area={escape(row['area'])}; "
            f"platform={escape(row['platform'])}; "
            f"kind={escape(row['kind'])}; precondition={escape(row['precondition'])}; "
            f"action={escape(row['action'])}; expected={escape(row['expectedResult'])};"
            f" gates={escape(row['gateIDs'])} -->"
        )
    return ("\n".join(lines).rstrip() + "\n").encode("utf-8")


def explicit_claim_path(claim: str) -> str | None:
    record_paths = {name: record_path(name) for name in RECORD_GATES}
    special = {
        "Baseline.json": BASELINE,
        "SOURCE-MANIFEST.before.json": SOURCE_MANIFEST_BEFORE,
        "SOURCE-MANIFEST.json": SOURCE_MANIFEST,
        "CompletionReport.json": COMPLETION_JSON,
        "CompletionReport.md": COMPLETION_MARKDOWN,
        "DefectClosure.json": DEFECT_CLOSURE,
        "Rune-Scribe-Owner-Test-Candidate-v1.0.zip": OWNER_ZIP,
        "SHA256SUMS": EXTERNAL_SHA256SUMS,
        "swift-package.log": f"{EVIDENCE_PREFIX}/GateRun/swift-package.log",
        "shipping-products.log": f"{EVIDENCE_PREFIX}/GateRun/shipping-products.log",
        "candidate zip": OWNER_ZIP,
        "check-remediation-completion log": COMPLETION_LOG,
        "shipping product log": f"{EVIDENCE_PREFIX}/GateRun/shipping-products.log",
        "negative mutation results": record_path("NegativeMutations.json"),
        "built Info.plists": BUILT_PRODUCT_INSPECTION_RESULTS,
        EVIDENCE_INDEX_CLAIM: EVIDENCE_INDEX,
        **record_paths,
    }
    if claim in special:
        return special[claim]
    if claim.endswith(".png") and "/" not in claim:
        return f"{EVIDENCE_PREFIX}/Screenshots/{claim}"
    if "/" not in claim:
        return None
    if claim.startswith(("docs/", "artifacts/")):
        return claim
    if claim.startswith(("GateRun/", "Screenshots/", "Attachments/")):
        return f"{EVIDENCE_PREFIX}/{claim}"
    return None


def claim_evidence_path(claim: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", claim.lower()).strip("-")[:72]
    suffix = sha256_bytes(claim.encode("utf-8"))[:12]
    return f"{CLAIM_EVIDENCE_PREFIX}/{slug}-{suffix}.json"


def required_claim_paths(claim: str) -> tuple[str, ...]:
    explicit = explicit_claim_path(claim)
    if explicit is not None:
        return (explicit,)
    if claim == WORKSPACE_SCREENSHOT_CLAIM:
        return WORKSPACE_SCREENSHOT_CLAIM_PATHS
    if claim in PLATFORM_SCREENSHOT_CLAIM_PATHS:
        return PLATFORM_SCREENSHOT_CLAIM_PATHS[claim]
    return (claim_evidence_path(claim),)


def claims_requiring_typed_indexes(
    gate_requirements: dict[str, tuple[str, ...]],
    test_rows: Iterable[dict[str, str]],
) -> tuple[str, ...]:
    claims = {
        claim
        for required in gate_requirements.values()
        for claim in required
        if required_claim_paths(claim) == (claim_evidence_path(claim),)
    }
    claims.update(
        row["requiredEvidence"]
        for row in test_rows
        if required_claim_paths(row["requiredEvidence"])
        == (claim_evidence_path(row["requiredEvidence"]),)
    )
    return tuple(sorted(claims))


def build_claim_evidence_documents(
    *,
    input_data: dict[str, Any],
    gate_requirements: dict[str, tuple[str, ...]],
    source_hash: str,
    source_revision: str | None,
    outputs: StagedOutputs,
) -> None:
    generated = generated_test_evidence_paths() | {
        DEFECT_CLOSURE,
        EVIDENCE_INDEX,
        COMPLETION_MARKDOWN,
        EVIDENCE_HANDOFF,
        EXTERNAL_SHA256SUMS,
        ARTIFACT_HANDOFF,
        SCREENSHOT_INDEX,
        TEST_SUMMARY,
        ADJACENT_COMPLETION_JSON,
        ADJACENT_COMPLETION_MARKDOWN,
    }
    rows_by_id = input_data["testRows"]
    for claim in claims_requiring_typed_indexes(
        gate_requirements, rows_by_id.values()
    ):
        path = claim_evidence_path(claim)
        catalog_gate_ids = {
            gate_id
            for gate_id, requirements in gate_requirements.items()
            if claim in requirements
        }
        exact_matrix_ids = {
            test_id
            for test_id, row in rows_by_id.items()
            if row["requiredEvidence"] == claim
        }
        matrix_gate_ids = {
            gate_id
            for test_id in exact_matrix_ids
            for gate_id in rows_by_id[test_id]["gateIDs"].split(";")
        }
        gate_ids = sorted(catalog_gate_ids | matrix_gate_ids)
        test_ids = sorted(exact_matrix_ids | {
            test_id
            for test_id, row in rows_by_id.items()
            if catalog_gate_ids.intersection(row["gateIDs"].split(";"))
        })
        if not test_ids:
            raise EvidenceError(f"typed claim index has no locked tests: {claim}")
        executions: list[dict[str, str]] = []
        artifact_kinds: dict[str, str] = {}
        for test_id in test_ids:
            execution = input_data["tests"][test_id]
            suite_result = input_data["suiteResults"][execution["suiteName"]]
            log = execution["log"]
            raw_log = suite_result["rawLog"]
            executions.append({
                "testID": test_id,
                "result": "PASS",
                "suiteName": execution["suiteName"],
                "command": execution["command"],
                "requiredEvidence": rows_by_id[test_id]["requiredEvidence"],
                "log": log,
                "logSHA256": outputs.digest(log),
            })
            artifact_kinds[log] = "structured-suite-result"
            artifact_kinds[raw_log] = "raw-test-log"
            for relative in execution["evidence"]:
                if (
                    relative == path
                    or relative.startswith(CLAIM_EVIDENCE_PREFIX + "/")
                    or relative in generated
                ):
                    continue
                artifact_kinds.setdefault(relative, "test-evidence")
        if CLOUD_GAME_CENTER_RESULTS in artifact_kinds:
            artifact_kinds[CLOUD_GAME_CENTER_RESULTS] = "domain-result"
        if PERFORMANCE_RESOURCE_RESULTS in artifact_kinds:
            artifact_kinds[PERFORMANCE_RESOURCE_RESULTS] = "domain-result"
        if BUILT_PRODUCT_INSPECTION_RESULTS in artifact_kinds:
            artifact_kinds[BUILT_PRODUCT_INSPECTION_RESULTS] = "product-inspection"
        if "T-006" in test_ids:
            artifact_kinds[NO_GIT_QUALIFICATION_RESULT] = "test-evidence"
        if claim == CLOUD_GAME_CENTER_CLAIM:
            artifact_kinds[CLOUD_GAME_CENTER_RESULTS] = "domain-result"
            semantic_markers = list(CLOUD_GAME_CENTER_MARKERS)
        elif claim == PERFORMANCE_RESOURCE_CLAIM:
            artifact_kinds[PERFORMANCE_RESOURCE_RESULTS] = "domain-result"
            semantic_markers = list(PERFORMANCE_RESOURCE_MARKERS)
        elif claim == EVIDENCE_INDEX_CLAIM:
            # This marker is only a cross-reference. The checker independently
            # proves the final EvidenceIndex inventory and every recorded hash.
            semantic_markers = ["evidence-index-exhaustive-cross-check"]
        else:
            semantic_markers = []
        artifacts = [
            {
                "path": relative,
                "sha256": outputs.digest(relative),
                "kind": artifact_kinds[relative],
            }
            for relative in sorted(artifact_kinds)
        ]
        if not artifacts:
            raise EvidenceError(f"typed claim index has no underlying artifacts: {claim}")
        outputs.write_json(path, {
            "schemaVersion": SCHEMA_VERSION,
            "status": "PASS",
            "claim": claim,
            "sourceManifestSHA256": source_hash,
            "sourceRevision": source_revision,
            "version": VERSION,
            "build": BUILD,
            "gateIDs": gate_ids,
            "testIDs": test_ids,
            "executions": executions,
            "artifacts": artifacts,
            "semanticMarkers": semantic_markers,
        })


def named_claim_path(claim: str) -> str | None:
    paths = required_claim_paths(claim)
    return paths[0] if len(paths) == 1 else None


def aggregate_suites(
    suite_names: Iterable[str], suites: dict[str, dict[str, Any]]
) -> dict[str, int]:
    counts = {"executed": 0, "passed": 0, "failed": 0, "skipped": 0}
    for suite_name in suite_names:
        suite = suites[suite_name]
        for key in counts:
            counts[key] += suite[key]
    return counts


def add_unique(values: list[str], additions: Iterable[str]) -> list[str]:
    return sorted(set(values).union(additions))


def build_record(
    record_name: str,
    *,
    input_data: dict[str, Any],
    gate_requirements: dict[str, tuple[str, ...]],
    finding_gates: dict[str, tuple[str, ...]],
    source_hash: str,
    source_revision: str | None,
    outputs: StagedOutputs,
    extra_artifacts: Iterable[str] = (),
    extra_logs: Iterable[str] = (),
) -> dict[str, Any]:
    configured = input_data["records"][record_name]
    self_path = record_path(record_name)
    claims = record_claims(record_name, gate_requirements)
    logs = list(configured["logs"])
    for suite_name in configured["suiteNames"]:
        logs.append(input_data["suites"][suite_name]["log"])
    logs = add_unique(logs, extra_logs)
    artifacts = add_unique(
        list(configured["artifacts"]),
        extra_artifacts,
    )
    assigned_gates = set(RECORD_GATES[record_name])
    artifacts = add_unique(
        artifacts,
        (
            relative
            for finding_id, gates in finding_gates.items()
            if assigned_gates.intersection(gates)
            for relative in input_data["findings"][finding_id]["changedFiles"]
        ),
    )
    if record_name == "SourceManifestValidation.json":
        artifacts = add_unique(artifacts, [NO_GIT_QUALIFICATION_RESULT])

    screenshot_paths = [item["path"] for item in input_data["screenshots"]]
    if any("screenshot" in claim.lower() for claim in claims):
        artifacts = add_unique(artifacts, screenshot_paths)

    deferred_terminal_authorities: set[str] = set()
    for claim in claims:
        for required_path in required_claim_paths(claim):
            if required_path == self_path:
                continue
            if claim == EVIDENCE_INDEX_CLAIM and required_path == EVIDENCE_INDEX:
                deferred_terminal_authorities.add(required_path)
                continue
            if required_path.endswith(".log"):
                logs = add_unique(logs, [required_path])
            else:
                artifacts = add_unique(artifacts, [required_path])

    if not logs:
        raise EvidenceError(f"{record_name} has no bound logs")
    if not artifacts:
        raise EvidenceError(f"{record_name} has no bound artifacts")
    for relative in logs + artifacts:
        outputs.resolve(relative)

    binding_paths = sorted(
        set(logs + artifacts + [self_path]) | deferred_terminal_authorities
    )
    evidence_bindings: dict[str, list[str]] = {}
    for claim in claims:
        candidates = list(required_claim_paths(claim))
        if not set(candidates).issubset(binding_paths):
            raise EvidenceError(
                f"{record_name} does not bind the exact artifact policy for {claim!r}"
            )
        evidence_bindings[claim] = sorted(candidates)

    artifact_hashes = {
        relative: outputs.digest(relative) for relative in sorted(set(logs + artifacts))
    }
    notes = add_unique(
        configured["notes"],
        [f"Exact locked test executions: {attachment_path(record_name)}"],
    )
    commands = list(configured["commands"])
    if record_name == "FullRegression.json":
        commands = add_unique(commands, ["python3 scripts/check-remediation-completion.py"])
    record = {
        "schemaVersion": SCHEMA_VERSION,
        "recordID": f"remediation-v1-{Path(record_name).stem.lower()}",
        "gateIDs": list(RECORD_GATES[record_name]),
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "version": VERSION,
        "build": BUILD,
        "result": "PASS",
        "commands": commands,
        "environment": input_data["environment"],
        "startedAt": configured["startedAt"],
        "endedAt": configured["endedAt"],
        "failures": [],
        "artifacts": artifacts,
        "logs": logs,
        "evidenceClaims": claims,
        "evidenceBindings": evidence_bindings,
        "artifactSHA256": artifact_hashes,
        "testSummary": aggregate_suites(configured["suiteNames"], input_data["suites"]),
        "notes": notes,
        "nonGatingExternal": input_data["nonGatingExternal"],
    }
    outputs.write_json(self_path, record)
    return record


def finding_evidence_paths(finding_gates: Iterable[str]) -> list[str]:
    required = set(finding_gates)
    selected = [
        record_path(name)
        for name, gates in RECORD_GATES.items()
        if required.intersection(gates)
    ]
    covered = set().union(
        *(set(RECORD_GATES[Path(path).name]) for path in selected)
    ) if selected else set()
    if not required.issubset(covered):
        raise EvidenceError("internal finding-to-record evidence coverage is incomplete")
    return sorted(selected)


def finding_tests(
    gate_ids: Iterable[str], test_rows: list[dict[str, str]]
) -> list[str]:
    required = set(gate_ids)
    labels = {
        test_label(row)
        for row in test_rows
        if required.intersection(row["gateIDs"].split(";"))
    }
    if not labels:
        raise EvidenceError("a finding has no tests in the locked test matrix")
    return sorted(labels)


def build_findings(
    *,
    input_data: dict[str, Any],
    finding_gates: dict[str, tuple[str, ...]],
    original_statuses: dict[str, str],
    test_rows: list[dict[str, str]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    defect_findings: list[dict[str, Any]] = []
    completion_findings: list[dict[str, Any]] = []
    for finding_id in FINDING_IDS:
        gates = list(finding_gates[finding_id])
        evidence = finding_evidence_paths(gates)
        finding_input = input_data["findings"][finding_id]
        bound_test_ids = sorted({
            test_id
            for test_ids in finding_input["testBindings"].values()
            for test_id in test_ids
        })
        rows_by_id = {row["testID"]: row for row in test_rows}
        tests = [test_label(rows_by_id[test_id]) for test_id in bound_test_ids]
        defect_findings.append({
            "id": finding_id,
            "originalStatus": original_statuses[finding_id],
            "changedFiles": finding_input["changedFiles"],
            "removedFiles": finding_input["removedFiles"],
            "removalBindings": finding_input["removalBindings"],
            "implementationBindings": finding_input["implementationBindings"],
            "sourceAreaBindings": finding_input["sourceAreaBindings"],
            "testBindings": finding_input["testBindings"],
            "tests": tests,
            "evidence": evidence,
            "finalStatus": "CLOSED",
            "gateIDs": gates,
        })
        completion_findings.append({
            "id": finding_id,
            "status": "CLOSED",
            "gateIDs": gates,
            "evidence": evidence,
        })
    return defect_findings, completion_findings


def build_test_summary(
    input_data: dict[str, Any], source_hash: str, source_revision: str | None, outputs: StagedOutputs
) -> dict[str, Any]:
    suite_names = sorted(input_data["suites"])
    totals = aggregate_suites(suite_names, input_data["suites"])
    suites: list[dict[str, Any]] = []
    for name in suite_names:
        source = input_data["suites"][name]
        suites.append({
            "name": name,
            "platform": source["platform"],
            "kind": source["kind"],
            "executed": source["executed"],
            "passed": source["passed"],
            "failed": source["failed"],
            "skipped": source["skipped"],
            "log": source["log"],
            "logSHA256": outputs.digest(source["log"]),
        })
    return {
        "schemaVersion": SCHEMA_VERSION,
        "status": "PASS",
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "version": VERSION,
        "build": BUILD,
        "totals": totals,
        "suites": suites,
    }


def build_test_execution_index(
    *,
    input_data: dict[str, Any],
    source_hash: str,
    source_revision: str | None,
    matrix_digest: str,
    outputs: StagedOutputs,
) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    for test_id in sorted(input_data["testRows"]):
        locked = input_data["testRows"][test_id]
        execution = input_data["tests"][test_id]
        gates = locked["gateIDs"].split(";")
        attachments = sorted(
            attachment_path(record_name)
            for record_name, record_gates in RECORD_GATES.items()
            if set(gates).intersection(record_gates)
        )
        rows.append({
            "testID": test_id,
            "area": locked["area"],
            "platform": locked["platform"],
            "kind": locked["kind"],
            "scenario": locked["scenario"],
            "precondition": locked["precondition"],
            "action": locked["action"],
            "expectedResult": locked["expectedResult"],
            "requiredEvidence": locked["requiredEvidence"],
            "gateIDs": gates,
            "result": execution["result"],
            "suiteName": execution["suiteName"],
            "command": execution["command"],
            "log": execution["log"],
            "logSHA256": outputs.digest(execution["log"]),
            "evidence": execution["evidence"],
            "evidenceSHA256": {
                path: outputs.digest(path) for path in execution["evidence"]
            },
            "attachments": attachments,
            "attachmentSHA256": {
                path: outputs.digest(path) for path in attachments
            },
        })
    return {
        "schemaVersion": SCHEMA_VERSION,
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "testMatrixSHA256": matrix_digest,
        "requiredTestCount": len(rows),
        "passedTestCount": len(rows),
        "failedTestCount": 0,
        "tests": rows,
    }


def build_screenshot_index(
    input_data: dict[str, Any], source_hash: str, outputs: StagedOutputs
) -> bytes:
    lines = [
        "# Rune Scribe Remediation Screenshot Index",
        "",
        f"Version/build: `{VERSION} / {BUILD}`",
        f"Source manifest: `{source_hash}`",
        "",
        "| Owner package path | Platform | Description | SHA-256 |",
        "|---|---|---|---|",
    ]
    for screenshot in sorted(input_data["screenshots"], key=lambda item: item["path"]):
        repository_path = screenshot["path"]
        within = PurePosixPath(repository_path).relative_to(
            PurePosixPath(f"{EVIDENCE_PREFIX}/Screenshots")
        ).as_posix()
        archive_path = f"Screenshots/{within}"
        description = screenshot["description"].replace("|", "\\|")
        platform = screenshot["platform"].replace("|", "\\|")
        lines.append(
            f"| `{archive_path}` | {platform} | {description} | `{outputs.digest(repository_path)}` |"
        )
    return ("\n".join(lines) + "\n").encode("utf-8")


def build_handoff(
    input_data: dict[str, Any], source_hash: str, source_revision: str | None
) -> bytes:
    iphone = input_data["simulators"]["iPhone"]
    ipad = input_data["simulators"]["iPad"]
    reset = "\n".join(f"{command}" for command in input_data["resetCommands"])
    seed = "\n".join(f"{command}" for command in input_data["seedCommands"])
    revision_text = source_revision or "not applicable"
    text = f"""# Rune Scribe Owner-Test Candidate Handoff

**Candidate status:** `RELEASE_CANDIDATE_READY`<br>
**Version/build:** `{VERSION} / {BUILD}`<br>
**Source manifest:** `{source_hash}`<br>
**Source revision:** `{revision_text}`

## Report authority

The outer candidate ZIP is a deterministic envelope. Its internal schema-valid `CompletionReport.json` and `CompletionReport.md` truthfully bind the nested `Rune-Scribe-Owner-Test-Payload-v1.0.zip`. The adjacent external reports beside the outer ZIP truthfully bind the finalized outer-envelope SHA-256.

## Included products

- `RuneScrib-macOS-Release.app.zip`
- `RuneScrib-iPhoneSimulator-Release.app.zip`
- `RuneScrib-iPadSimulator-Qualification.json`
- `SOURCE-MANIFEST.json`
- `Screenshot-Index.md` and `Screenshots/`
- `TestSummaries/Test-Summary.json`

## Verify package contents

```bash
shasum -a 256 -c SHA256SUMS
```

## macOS launch

```bash
unzip RuneScrib-macOS-Release.app.zip -d macos-app
open macos-app/RuneScrib.app
```

No distribution signature or notarization is claimed.

## iPhone Simulator install and launch

Device: `{iphone['name']}` / `{iphone['runtime']}` / `{iphone['udid']}`

```bash
xcrun simctl bootstatus {iphone['udid']} -b
unzip RuneScrib-iPhoneSimulator-Release.app.zip -d iphone-app
xcrun simctl install {iphone['udid']} iphone-app/RuneScrib.app
xcrun simctl launch {iphone['udid']} {input_data['bundleIdentifier']}
```

## iPad Simulator install and launch

Device: `{ipad['name']}` / `{ipad['runtime']}` / `{ipad['udid']}`

```bash
xcrun simctl bootstatus {ipad['udid']} -b
unzip RuneScrib-iPhoneSimulator-Release.app.zip -d ipad-app
xcrun simctl install {ipad['udid']} ipad-app/RuneScrib.app
xcrun simctl launch {ipad['udid']} {input_data['bundleIdentifier']}
```

## Reset commands

```bash
{reset}
```

## Seed commands

```bash
{seed}
```

## Candidate review focus

- Norse and Elven-series visual presentation.
- Quick Share and Customize Share.
- Cipher Library themed invitation sharing.
- Appearance defaults, Vault, and Archive.
- Emergency Base Theme warning and decode fallback.
- Encode/decode and legacy import compatibility.

These are review suggestions, not unfinished engineering gates.

## External non-gating boundaries

"""
    text += "\n".join(f"- {item}." for item in input_data["nonGatingExternal"])
    text += """

No physical hardware, live account, public upload, release tag, notarization, TestFlight submission, App Store submission, or staged rollout was required or performed.
"""
    return text.encode("utf-8")


def build_completion_report(
    *,
    source_hash: str,
    source_revision: str | None,
    branch: str | None,
    completion_findings: list[dict[str, Any]],
    owner_path: str,
    owner_digest: str,
    platform_qualification: dict[str, str],
    publication_audit: dict[str, Any],
) -> dict[str, Any]:
    if any(
        publication_audit[key] is not False
        for key in (
            "sourceMergedToDefault", "releasePublished", "uploadPerformed",
            "notarizationPerformed", "testFlightPerformed", "appStorePerformed",
            "rolloutPerformed",
        )
    ):
        raise EvidenceError("completion report cannot claim an unsafe publication boundary")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "status": "RELEASE_CANDIDATE_READY",
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "branch": branch,
        "version": VERSION,
        "build": BUILD,
        "requiredGateCount": 42,
        "passedGateCount": 42,
        "failedGateCount": 0,
        "findingClosures": completion_findings,
        "platformQualification": platform_qualification,
        "ownerTestPackage": {"path": owner_path, "sha256": owner_digest},
        "physicalHardwareRequired": False,
        "liveAccountsRequired": False,
        "publicDistributionPerformed": False,
        "attributionAudit": "PASS",
        "nonGatingExternal": list(FIXED_NON_GATING_BOUNDARIES),
    }


def completion_markdown(
    source_hash: str,
    source_revision: str | None,
    branch: str | None,
    owner_path: str,
    owner_digest: str,
    completion_findings: list[dict[str, Any]],
    outputs: StagedOutputs,
) -> bytes:
    lines = [
        "# Rune Scribe Remediation Completion Report",
        "",
        "**Status:** `RELEASE_CANDIDATE_READY`  ",
        f"**Version/build:** `{VERSION} / {BUILD}`  ",
        f"**Source manifest:** `{source_hash}`  ",
        f"**Branch/revision:** `{branch or 'not applicable'}` / `{source_revision or 'not applicable'}`",
        "",
        "RELEASE_CANDIDATE_READY",
        f"All required remediation gates passed against SOURCE-MANIFEST {source_hash}.",
        "macOS host and Release qualification passed.",
        "iPhone Simulator qualification passed.",
        "iPad Simulator qualification passed.",
        "No physical-hardware test was required or used as a gate.",
        "No live-account test was required or used as a gate.",
        "Owner-test candidate artifacts were produced.",
        "No public distribution, upload, tag, release, or rollout was performed.",
        "",
        "## Finding closure",
        "",
        "| Finding | Status | Evidence |",
        "|---|---|---|",
    ]
    for closure in completion_findings:
        evidence = ", ".join(f"`{path}`" for path in closure["evidence"])
        lines.append(f"| {closure['id']} | CLOSED | {evidence} |")
    lines.extend([
        "",
        "## Final artifacts",
        "",
        f"- macOS Release app ZIP: `{MACOS_ZIP}` / `{outputs.digest(MACOS_ZIP)}`",
        f"- iOS Simulator Release app ZIP: `{IPHONE_ZIP}` / `{outputs.digest(IPHONE_ZIP)}`",
        f"- iPad Simulator qualification: `{IPAD_QUALIFICATION}` / `{outputs.digest(IPAD_QUALIFICATION)}`",
        f"- bound owner-test package: `{owner_path}` / `{owner_digest}`",
        f"- screenshot index: `{SCREENSHOT_INDEX}`",
        f"- test summary: `{TEST_SUMMARY}`",
        "",
        "## Report authority",
        "",
        "This report truthfully binds the package path and SHA-256 shown above. The internal report binds the nested payload; the adjacent external report binds the outer candidate envelope.",
        "",
        "## External boundary",
        "",
        "physicalHardwareRequired=false  ",
        "liveAccountsRequired=false  ",
        "publicDistributionPerformed=false  ",
        "nonGatingExternal:",
        *[f"- {item}" for item in FIXED_NON_GATING_BOUNDARIES],
        "",
        "No physical hardware, live account, public upload, release tag, notarization, TestFlight submission, App Store submission, or staged rollout was required or performed.",
    ])
    return ("\n".join(lines) + "\n").encode("utf-8")


def zip_info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_STORED
    info.external_attr = (0o100644 & 0xFFFF) << 16
    return info


def write_zip_path(archive: zipfile.ZipFile, name: str, source: Path) -> None:
    with source.open("rb") as input_stream, archive.open(zip_info(name), "w") as output:
        shutil.copyfileobj(input_stream, output, length=1024 * 1024)


def write_deterministic_zip(
    target: Path,
    source_members: dict[str, str],
    byte_members: dict[str, bytes],
    outputs: StagedOutputs,
) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target, "w", allowZip64=True) as archive:
        for name in sorted(set(source_members) | set(byte_members)):
            if name in byte_members:
                archive.writestr(zip_info(name), byte_members[name])
            else:
                write_zip_path(archive, name, outputs.resolve(source_members[name]))


def build_owner_payload(
    *,
    outputs: StagedOutputs,
    input_data: dict[str, Any],
) -> None:
    source_members: dict[str, str] = {
        "RuneScrib-macOS-Release.app.zip": MACOS_ZIP,
        "RuneScrib-iPhoneSimulator-Release.app.zip": IPHONE_ZIP,
        "RuneScrib-iPadSimulator-Qualification.json": IPAD_QUALIFICATION,
        "IPAD-QUALIFICATION.schema.json": IPAD_QUALIFICATION_SCHEMA,
        "SOURCE-MANIFEST.json": SOURCE_MANIFEST,
        "OWNER-TEST-CANDIDATE-HANDOFF.md": ARTIFACT_HANDOFF,
        "Screenshot-Index.md": SCREENSHOT_INDEX,
        "TestSummaries/Test-Summary.json": TEST_SUMMARY,
        "TestSummaries/TEST-MATRIX-v1.0.csv": TEST_MATRIX_CATALOG,
        "TestSummaries/FINDING-CLOSURE-MATRIX-v1.0.json": FINDING_MATRIX_CATALOG,
        "PublicationAudit.json": PUBLICATION_AUDIT_RECORD,
        f"PublicationAudit/{Path(input_data['publicationAudit']['log']).name}": (
            input_data["publicationAudit"]["log"]
        ),
    }
    byte_members: dict[str, bytes] = {}
    for screenshot in input_data["screenshots"]:
        relative = PurePosixPath(screenshot["path"]).relative_to(
            PurePosixPath(f"{EVIDENCE_PREFIX}/Screenshots")
        ).as_posix()
        source_members[f"Screenshots/{relative}"] = screenshot["path"]

    member_digests = {
        name: outputs.digest(relative) for name, relative in source_members.items()
    }
    member_digests.update({name: sha256_bytes(data) for name, data in byte_members.items()})
    sums = "".join(
        f"{digest}  {name}\n" for name, digest in sorted(member_digests.items())
    ).encode("utf-8")
    byte_members["SHA256SUMS"] = sums

    write_deterministic_zip(
        outputs.staged_path(PAYLOAD_ZIP), source_members, byte_members, outputs
    )
    outputs.files.add(PAYLOAD_ZIP)


def build_owner_envelope(
    *,
    outputs: StagedOutputs,
    completion_json: bytes,
    completion_markdown_data: bytes,
) -> None:
    readme = f"""# Rune Scribe Owner-Test Candidate Envelope

This deterministic outer envelope contains one immutable owner-test payload and schema-valid reports that truthfully bind that payload.

- Payload: `{Path(PAYLOAD_ZIP).name}`
- Internal report authority: payload SHA-256
- Adjacent external report authority: outer candidate SHA-256

Verify this envelope with `shasum -a 256 -c SHA256SUMS`, then extract the nested payload and verify its own `SHA256SUMS` before following `OWNER-TEST-CANDIDATE-HANDOFF.md`.
""".encode("utf-8")
    source_members = {Path(PAYLOAD_ZIP).name: PAYLOAD_ZIP}
    byte_members = {
        "CompletionReport.json": completion_json,
        "CompletionReport.md": completion_markdown_data,
        "README.md": readme,
    }
    member_digests = {
        name: outputs.digest(relative) for name, relative in source_members.items()
    }
    member_digests.update({name: sha256_bytes(data) for name, data in byte_members.items()})
    byte_members["SHA256SUMS"] = "".join(
        f"{digest}  {name}\n" for name, digest in sorted(member_digests.items())
    ).encode("utf-8")
    write_deterministic_zip(
        outputs.staged_path(OWNER_ZIP), source_members, byte_members, outputs
    )
    outputs.files.add(OWNER_ZIP)


def validate_app_zip(path: Path, platform: str, bundle_identifier: str) -> dict[str, str]:
    try:
        with zipfile.ZipFile(path) as archive:
            corrupt = archive.testzip()
            if corrupt is not None:
                raise EvidenceError(f"{path.name} is corrupt at {corrupt}")
            candidates: list[str] = []
            files: dict[str, zipfile.ZipInfo] = {}
            for info in archive.infolist():
                name = info.filename
                pure = PurePosixPath(name)
                normalized = pure.as_posix().rstrip("/")
                mode = (info.external_attr >> 16) & 0xFFFF
                if (
                    not name
                    or pure.is_absolute()
                    or ".." in pure.parts
                    or "\\" in name
                    or "\0" in name
                    or (mode & 0o170000) == 0o120000
                ):
                    raise EvidenceError(f"{path.name} has an unsafe member: {name!r}")
                if normalized and not info.is_dir():
                    file_type = mode & 0o170000
                    if file_type not in {0, 0o100000}:
                        raise EvidenceError(
                            f"{path.name} has a non-regular member: {normalized}"
                        )
                    if normalized in files:
                        raise EvidenceError(
                            f"{path.name} has a duplicate member: {normalized}"
                        )
                    files[normalized] = info
                if platform == "macOS" and re.search(r"\.app/Contents/Info\.plist$", name):
                    candidates.append(name)
                if (
                    platform == "iOS"
                    and re.search(r"\.app/Info\.plist$", name)
                    and "/Contents/" not in name
                ):
                    candidates.append(name)
            if len(candidates) != 1:
                raise EvidenceError(
                    f"{path.name} must contain exactly one {platform} app Info.plist"
                )
            info_name = candidates[0].rstrip("/")
            app_match = re.match(r"^(.+\.app)(?:/|$)", info_name)
            if app_match is None:
                raise EvidenceError(f"{path.name} has no canonical app root")
            app_root = app_match.group(1)
            if PurePosixPath(app_root).name != "RuneScrib.app":
                raise EvidenceError(f"{path.name} app root is not RuneScrib.app")
            if any(not name.startswith(app_root + "/") for name in files):
                raise EvidenceError(f"{path.name} contains files outside its one app root")
            plist = plistlib.loads(archive.read(candidates[0]))
            if not isinstance(plist, dict):
                raise EvidenceError(f"{path.name} app Info.plist is not a dictionary")
            if plist.get("CFBundleShortVersionString") != VERSION:
                raise EvidenceError(f"{path.name} marketing version is not {VERSION}")
            if str(plist.get("CFBundleVersion")) != BUILD:
                raise EvidenceError(f"{path.name} build is not {BUILD}")
            if plist.get("CFBundleIdentifier") != bundle_identifier:
                raise EvidenceError(
                    f"{path.name} bundle identifier is not {bundle_identifier}"
                )
            if plist.get("CFBundlePackageType") != "APPL":
                raise EvidenceError(f"{path.name} CFBundlePackageType is not APPL")
            executable = plist.get("CFBundleExecutable")
            if (
                not isinstance(executable, str)
                or not executable
                or "/" in executable
                or "\\" in executable
            ):
                raise EvidenceError(f"{path.name} has an invalid CFBundleExecutable")
            executable_path = (
                f"{app_root}/Contents/MacOS/{executable}"
                if platform == "macOS"
                else f"{app_root}/{executable}"
            )
            executable_info = files.get(executable_path)
            if executable_info is None:
                raise EvidenceError(f"{path.name} omits declared executable {executable_path}")
            executable_mode = (executable_info.external_attr >> 16) & 0xFFFF
            if executable_info.file_size < 28 or not executable_mode & 0o111:
                raise EvidenceError(
                    f"{path.name} declared executable is empty or not executable"
                )
            with archive.open(executable_info) as stream:
                if stream.read(4) not in MACHO_MAGICS:
                    raise EvidenceError(
                        f"{path.name} declared executable is not a nonempty Mach-O"
                    )
            if platform == "macOS":
                resource_prefix = f"{app_root}/Contents/Resources/"
                if not any(
                    name.startswith(resource_prefix) and info.file_size > 0
                    for name, info in files.items()
                ):
                    raise EvidenceError(f"{path.name} has no nonempty macOS resources")
            else:
                supported = plist.get("CFBundleSupportedPlatforms")
                if not isinstance(supported, list) or "iPhoneSimulator" not in supported:
                    raise EvidenceError(
                        f"{path.name} is not an iPhoneSimulator product"
                    )
                non_product_files = {
                    info_name,
                    executable_path,
                    f"{app_root}/PkgInfo",
                }
                if not any(
                    name not in non_product_files and info.file_size > 0
                    for name, info in files.items()
                ):
                    raise EvidenceError(f"{path.name} has no nonempty iOS resources")
            return {
                "path": path.name,
                "sha256": sha256_file(path),
                "bundleIdentifier": bundle_identifier,
                "appRoot": app_root,
                "executable": executable_path,
            }
    except (
        OSError, KeyError, RuntimeError, zipfile.BadZipFile,
        plistlib.InvalidFileException,
    ) as exception:
        raise EvidenceError(f"{path.name} is not a valid app ZIP: {exception}") from exception


def validate_ipad_qualification(
    document: object,
    *,
    root: Path,
    source_hash: str,
    source_revision: str | None,
    selected_simulator: dict[str, str],
    bundle_identifier: str,
    ios_product_digest: str,
    input_data: dict[str, Any],
) -> dict[str, Any]:
    if Draft202012Validator is None:
        raise EvidenceError("jsonschema is required for iPad qualification validation")
    schema_errors = sorted(
        Draft202012Validator(ipad_qualification_schema()).iter_errors(document),
        key=lambda error: (list(error.absolute_path), error.message),
    )
    if schema_errors:
        details = "; ".join(error.message for error in schema_errors[:8])
        raise EvidenceError(
            f"iPad qualification violates IPAD-QUALIFICATION.schema.json: {details}"
        )
    if not isinstance(document, dict) or set(document) != IPAD_QUALIFICATION_KEYS:
        raise EvidenceError("iPad qualification keys differ from the locked schema")
    expected_scalars = {
        "schemaVersion": SCHEMA_VERSION,
        "status": "PASS",
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "version": VERSION,
        "build": BUILD,
    }
    for key, expected in expected_scalars.items():
        if document.get(key) != expected:
            raise EvidenceError(f"iPad qualification {key} differs")
    if document.get("simulator") != selected_simulator:
        raise EvidenceError("iPad qualification simulator differs from the selected iPad")
    product = document.get("iOSProduct")
    expected_product = {
        "path": IPHONE_ZIP,
        "sha256": ios_product_digest,
        "bundleIdentifier": bundle_identifier,
    }
    if not isinstance(product, dict) or set(product) != IPAD_PRODUCT_KEYS or product != expected_product:
        raise EvidenceError("iPad qualification iOSProduct differs from the validated product")

    required_ipad_test_ids = {
        test_id for test_id, row in input_data["testRows"].items()
        if row["platform"] == "iPad Simulator"
    }
    required_suite_names = {
        input_data["tests"][test_id]["suiteName"] for test_id in required_ipad_test_ids
    }
    suite_values = document.get("suites")
    if not isinstance(suite_values, list) or not suite_values:
        raise EvidenceError("iPad qualification suites must be nonempty")
    seen_suites: set[str] = set()
    for index, suite in enumerate(suite_values):
        label = f"iPad qualification suites[{index}]"
        if not isinstance(suite, dict) or set(suite) != IPAD_SUITE_KEYS:
            raise EvidenceError(f"{label} keys differ")
        name = suite.get("name")
        if not isinstance(name, str) or name in seen_suites or name not in input_data["suites"]:
            raise EvidenceError(f"{label}.name is invalid")
        seen_suites.add(name)
        if suite.get("result") != "PASS":
            raise EvidenceError(f"{label}.result must be PASS")
        counts = validate_counts(
            {key: suite.get(key) for key in ("executed", "passed", "failed", "skipped")},
            label,
        )
        if (
            counts["failed"] != 0
            or counts["skipped"] != 0
            or counts["executed"] == 0
            or counts["passed"] == 0
        ):
            raise EvidenceError(f"{label} cannot support PASS")
        log = normalized_relative(suite.get("log"), f"{label}.log")
        log_path = repository_file(root, log, f"{label}.log")
        if log != input_data["suites"][name]["log"]:
            raise EvidenceError(f"{label}.log differs from the bound suite")
        if suite.get("logSHA256") != sha256_file(log_path):
            raise EvidenceError(f"{label}.logSHA256 differs")
    if not required_suite_names.issubset(seen_suites):
        raise EvidenceError("iPad qualification omits locked iPad test suites")

    required_ipad_screenshots = {
        f"{EVIDENCE_PREFIX}/Screenshots/{row['requiredEvidence']}"
        for row in input_data["testRows"].values()
        if row["platform"] == "iPad Simulator" and row["requiredEvidence"].endswith(".png")
    }
    screenshots = document.get("screenshots")
    if not isinstance(screenshots, list) or not screenshots:
        raise EvidenceError("iPad qualification screenshots must be nonempty")
    seen_screenshots: set[str] = set()
    for index, screenshot in enumerate(screenshots):
        label = f"iPad qualification screenshots[{index}]"
        if not isinstance(screenshot, dict) or set(screenshot) != IPAD_SCREENSHOT_KEYS:
            raise EvidenceError(f"{label} keys differ")
        relative = normalized_relative(screenshot.get("path"), f"{label}.path")
        path = repository_file(root, relative, f"{label}.path")
        validate_png(path, f"{label}.path")
        if relative in seen_screenshots or screenshot.get("sha256") != sha256_file(path):
            raise EvidenceError(f"{label} path/hash is invalid")
        seen_screenshots.add(relative)
    if not required_ipad_screenshots.issubset(seen_screenshots):
        raise EvidenceError("iPad qualification omits locked iPad screenshots")
    return dict(document)


def derive_platform_qualification(
    input_data: dict[str, Any],
    ipad_qualification: dict[str, Any],
) -> dict[str, str]:
    required = {
        "macOS": {"T-112"},
        "iPhoneSimulator": {"T-113"},
        "iPadSimulator": {"T-023", "T-114"},
    }
    results: dict[str, str] = {}
    for platform, test_ids in required.items():
        if any(input_data["tests"][test_id]["result"] != "PASS" for test_id in test_ids):
            raise EvidenceError(f"{platform} qualification has a non-PASS locked test")
        results[platform] = "PASS"
    if ipad_qualification.get("status") != "PASS":
        raise EvidenceError("iPad qualification is not PASS")
    return results


def supporting_json_paths(root: Path, outputs: StagedOutputs) -> list[str]:
    paths: set[str] = set()
    physical_root = root / EVIDENCE_PREFIX
    if physical_root.is_dir():
        for path in physical_root.rglob("*.json"):
            relative = path.relative_to(root).as_posix()
            paths.add(relative)
    staged_root = outputs.staged_path(EVIDENCE_PREFIX)
    if staged_root.is_dir():
        for path in staged_root.rglob("*.json"):
            relative = path.relative_to(outputs.staging_root / "new").as_posix()
            paths.add(relative)
    records = {record_path(name) for name in RECORD_GATES}
    supporting: list[str] = []
    for relative in sorted(paths):
        within = PurePosixPath(relative).relative_to(PurePosixPath(EVIDENCE_PREFIX))
        if relative in records:
            continue
        if len(within.parts) == 1 and within.name in NON_RECORD_TOP_LEVEL_JSON:
            continue
        if len(within.parts) == 1:
            raise EvidenceError(
                f"unexpected top-level JSON must be removed or classified: {relative}"
            )
        document = load_json(outputs.resolve(relative), f"supporting JSON {relative}")
        if not isinstance(document, (dict, list)):
            raise EvidenceError(f"supporting JSON root must be an object or array: {relative}")
        supporting.append(relative)
    return supporting


def build_evidence_index(
    *,
    outputs: StagedOutputs,
    source_hash: str,
    source_revision: str | None,
    supporting: list[str],
) -> dict[str, Any]:
    records = sorted(record_path(name) for name in RECORD_GATES)
    digest_paths = set(records) | set(supporting) | TERMINAL_INDEX_PATHS
    return {
        "schemaVersion": SCHEMA_VERSION,
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "evidenceRecords": records,
        "supportingJSON": sorted(supporting),
        "sha256": {
            relative: outputs.digest(relative) for relative in sorted(digest_paths)
        },
    }


def build_all_outputs(
    *,
    root: Path,
    outputs: StagedOutputs,
    input_data: dict[str, Any],
    gate_requirements: dict[str, tuple[str, ...]],
    finding_gates: dict[str, tuple[str, ...]],
    original_statuses: dict[str, str],
    test_rows: list[dict[str, str]],
    matrix_digest: str,
    matrix_bytes: bytes,
    finding_matrix_bytes: bytes,
    source_hash: str,
    source_revision: str | None,
    branch: str | None,
    platform_qualification: dict[str, str],
    completion_schema: dict[str, Any],
    completion_log_data: bytes,
) -> None:
    if sha256_bytes(matrix_bytes) != EXPECTED_TEST_MATRIX_SHA256:
        raise EvidenceError("staged test matrix differs from the locked digest")
    if sha256_bytes(finding_matrix_bytes) != EXPECTED_FINDING_MATRIX_SHA256:
        raise EvidenceError("staged finding matrix differs from the locked digest")
    outputs.write_bytes(TEST_MATRIX_CATALOG, matrix_bytes)
    outputs.write_bytes(FINDING_MATRIX_CATALOG, finding_matrix_bytes)
    outputs.write_json(IPAD_QUALIFICATION_SCHEMA, ipad_qualification_schema())
    outputs.write_bytes(COMPLETION_LOG, completion_log_data)
    publication_audit = dict(input_data["publicationAudit"])
    publication_audit.update({
        "schemaVersion": SCHEMA_VERSION,
        "status": "PASS",
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "version": VERSION,
        "build": BUILD,
        "logSHA256": outputs.digest(publication_audit["log"]),
    })
    outputs.write_json(PUBLICATION_AUDIT_RECORD, publication_audit)
    expected_no_git_output = no_git_expected_output()
    outputs.write_json(NO_GIT_QUALIFICATION_RESULT, {
        "schemaVersion": SCHEMA_VERSION,
        "status": "PASS",
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "version": VERSION,
        "build": BUILD,
        "testID": "T-006",
        "command": no_git_command(source_hash),
        "expectedOutput": expected_no_git_output,
        "expectedOutputSHA256": sha256_bytes(expected_no_git_output.encode("utf-8")),
    })
    build_claim_evidence_documents(
        input_data=input_data,
        gate_requirements=gate_requirements,
        source_hash=source_hash,
        source_revision=source_revision,
        outputs=outputs,
    )
    for record_name in RECORD_BUILD_ORDER:
        build_record(
            record_name,
            input_data=input_data,
            gate_requirements=gate_requirements,
            finding_gates=finding_gates,
            source_hash=source_hash,
            source_revision=source_revision,
            outputs=outputs,
        )

    defect_findings, completion_findings = build_findings(
        input_data=input_data,
        finding_gates=finding_gates,
        original_statuses=original_statuses,
        test_rows=test_rows,
    )
    outputs.write_json(DEFECT_CLOSURE, {
        "schemaVersion": SCHEMA_VERSION,
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "version": VERSION,
        "build": BUILD,
        "findings": defect_findings,
    })

    outputs.write_json(
        TEST_SUMMARY,
        build_test_summary(input_data, source_hash, source_revision, outputs),
    )
    outputs.write_bytes(
        SCREENSHOT_INDEX,
        build_screenshot_index(input_data, source_hash, outputs),
    )
    handoff = build_handoff(input_data, source_hash, source_revision)
    outputs.write_bytes(ARTIFACT_HANDOFF, handoff)
    outputs.write_bytes(EVIDENCE_HANDOFF, handoff)

    build_owner_payload(outputs=outputs, input_data=input_data)
    payload_digest = outputs.digest(PAYLOAD_ZIP)
    internal_completion_document = build_completion_report(
        source_hash=source_hash,
        source_revision=source_revision,
        branch=branch,
        completion_findings=completion_findings,
        owner_path=Path(PAYLOAD_ZIP).name,
        owner_digest=payload_digest,
        platform_qualification=platform_qualification,
        publication_audit=input_data["publicationAudit"],
    )
    validate_completion_schema(
        internal_completion_document, completion_schema, "internal completion report"
    )
    internal_completion_json = json_bytes(internal_completion_document)
    internal_completion_markdown = completion_markdown(
        source_hash,
        source_revision,
        branch,
        Path(PAYLOAD_ZIP).name,
        payload_digest,
        completion_findings,
        outputs,
    )
    build_owner_envelope(
        outputs=outputs,
        completion_json=internal_completion_json,
        completion_markdown_data=internal_completion_markdown,
    )
    owner_digest = outputs.digest(OWNER_ZIP)
    completion_document = build_completion_report(
        source_hash=source_hash,
        source_revision=source_revision,
        branch=branch,
        completion_findings=completion_findings,
        owner_path=OWNER_ZIP,
        owner_digest=owner_digest,
        platform_qualification=platform_qualification,
        publication_audit=input_data["publicationAudit"],
    )
    validate_completion_schema(
        completion_document, completion_schema, "external completion report"
    )
    completion_json_data = json_bytes(completion_document)
    completion_markdown_data = completion_markdown(
        source_hash,
        source_revision,
        branch,
        OWNER_ZIP,
        owner_digest,
        completion_findings,
        outputs,
    )
    outputs.write_bytes(COMPLETION_JSON, completion_json_data)
    outputs.write_bytes(ADJACENT_COMPLETION_JSON, completion_json_data)
    outputs.write_bytes(COMPLETION_MARKDOWN, completion_markdown_data)
    outputs.write_bytes(ADJACENT_COMPLETION_MARKDOWN, completion_markdown_data)
    externally_checksummed = (
        MACOS_ZIP,
        IPHONE_ZIP,
        IPAD_QUALIFICATION,
        PAYLOAD_ZIP,
        OWNER_ZIP,
        ADJACENT_COMPLETION_JSON,
        ADJACENT_COMPLETION_MARKDOWN,
        ARTIFACT_HANDOFF,
        SCREENSHOT_INDEX,
        TEST_SUMMARY,
    )
    external_sums = "".join(
        f"{outputs.digest(relative)}  {Path(relative).name}\n"
        for relative in externally_checksummed
    ).encode("utf-8")
    outputs.write_bytes(EXTERNAL_SHA256SUMS, external_sums)

    for record_name in RECORD_GATES:
        outputs.write_bytes(
            attachment_path(record_name),
            make_test_attachment(record_name, input_data, matrix_digest, outputs),
        )
    outputs.write_json(
        TEST_EXECUTION_INDEX,
        build_test_execution_index(
            input_data=input_data,
            source_hash=source_hash,
            source_revision=source_revision,
            matrix_digest=matrix_digest,
            outputs=outputs,
        ),
    )

    supporting = supporting_json_paths(root, outputs)
    full_artifacts = [
        BASELINE,
        GATE_CATALOG,
        TEST_MATRIX_CATALOG,
        FINDING_MATRIX_CATALOG,
        IPAD_QUALIFICATION_SCHEMA,
        SOURCE_MANIFEST,
        DEFECT_CLOSURE,
        COMPLETION_JSON,
        COMPLETION_MARKDOWN,
        EVIDENCE_HANDOFF,
        MACOS_ZIP,
        IPHONE_ZIP,
        IPAD_QUALIFICATION,
        PAYLOAD_ZIP,
        OWNER_ZIP,
        EXTERNAL_SHA256SUMS,
        ARTIFACT_HANDOFF,
        SCREENSHOT_INDEX,
        TEST_SUMMARY,
        ADJACENT_COMPLETION_JSON,
        ADJACENT_COMPLETION_MARKDOWN,
        TEST_EXECUTION_INDEX,
        PUBLICATION_AUDIT_RECORD,
        NO_GIT_QUALIFICATION_RESULT,
        *[attachment_path(name) for name in RECORD_GATES],
        *[record_path(name) for name in RECORD_GATES if name != "FullRegression.json"],
        *[item["path"] for item in input_data["screenshots"]],
        *supporting,
    ]
    build_record(
        "FullRegression.json",
        input_data=input_data,
        gate_requirements=gate_requirements,
        finding_gates=finding_gates,
        source_hash=source_hash,
        source_revision=source_revision,
        outputs=outputs,
        extra_artifacts=full_artifacts,
    )
    outputs.write_json(
        EVIDENCE_INDEX,
        build_evidence_index(
            outputs=outputs,
            source_hash=source_hash,
            source_revision=source_revision,
            supporting=supporting,
        ),
    )


def checker_output(root: Path) -> bytes:
    checker = root / "scripts/check-remediation-completion.py"
    if not checker.is_file():
        raise EvidenceError("completion checker is missing")
    result = run(
        [sys.executable, str(checker)],
        cwd=root,
        label="remediation completion checker",
        require_success=False,
    )
    output = (result.stdout + result.stderr).replace("\r\n", "\n").encode("utf-8")
    if result.returncode != 0:
        detail = output.decode("utf-8", errors="replace").strip()
        raise EvidenceError(f"remediation completion checker failed: {detail}")
    if not output.startswith(b"PASS: 42 required gates"):
        raise EvidenceError("completion checker returned success without the terminal PASS line")
    return output


def template_changed_final_paths(root: Path) -> set[str]:
    before_document = load_json(
        repository_file(root, SOURCE_MANIFEST_BEFORE, "template baseline manifest"),
        "template baseline manifest",
    )
    before_projection = manifest_record_projection(
        before_document, "SOURCE-MANIFEST.before.json"
    )
    final_path = root / SOURCE_MANIFEST
    if final_path.is_file() and not final_path.is_symlink():
        final_document = load_json(final_path, "template final manifest")
    else:
        manifest_script = repository_file(
            root, "scripts/generate-source-manifest.py", "source-manifest generator"
        )
        spec = importlib.util.spec_from_file_location(
            "_runescribe_template_source_manifest", manifest_script
        )
        if spec is None or spec.loader is None:
            raise EvidenceError("source-manifest generator cannot be loaded for template")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        excludes = module.canonical_excludes(root, final_path)
        final_document = module.build_manifest(root, excludes)
    final_projection = manifest_record_projection(final_document, "current source tree")
    return {
        path
        for path, record in final_projection.items()
        if before_projection.get(path) != record
    }


def generated_output_template(
    test_rows: list[dict[str, str]],
    finding_gates: dict[str, tuple[str, ...]],
    finding_controls: dict[str, dict[str, tuple[str, ...]]],
    matrix_screenshots: dict[str, str],
    changed_final_paths: set[str],
) -> dict[str, Any]:
    placeholder_log = f"{EVIDENCE_PREFIX}/GateRun/replace-suite-results.json"
    record_template = {
        name: {
            "logs": [],
            "artifacts": [],
            "startedAt": "2026-08-23T00:00:00Z",
            "endedAt": "2026-08-23T00:00:00Z",
            "notes": [],
        }
        for name in RECORD_GATES
    }
    rows_by_id = {row["testID"]: row for row in test_rows}
    findings: dict[str, Any] = {}
    for finding_id in FINDING_IDS:
        source_expectations = finding_controls[finding_id]["sourceAreas"]
        source_area_bindings = {
            expectation: list(SOURCE_AREA_PATHS[finding_id][index])
            for index, expectation in enumerate(source_expectations)
        }
        implementation_bindings = {
            expectation: list(IMPLEMENTATION_PATHS[finding_id][index])
            for index, expectation in enumerate(
                finding_controls[finding_id]["implementation"]
            )
        }
        findings[finding_id] = {
            "changedFiles": sorted({
                path for paths in implementation_bindings.values() for path in paths
                if path in changed_final_paths
            }),
            "removedFiles": sorted({
                path
                for paths in REMOVED_IMPLEMENTATION_PATHS[finding_id].values()
                for path in paths
            }),
            "removalBindings": {
                expectation: list(paths)
                for expectation, paths in REMOVED_IMPLEMENTATION_PATHS[finding_id].items()
            },
            "implementationBindings": implementation_bindings,
            "sourceAreaBindings": source_area_bindings,
            "testBindings": {
                expectation: list(TEST_EXPECTATION_IDS[finding_id][index])
                for index, expectation in enumerate(finding_controls[finding_id]["tests"])
            },
        }
    test_bindings: dict[str, Any] = {}
    publication_command = (
        "replace with exact local and remote publication inspection command"
    )
    for row in test_rows:
        evidence = sorted({placeholder_log, *required_claim_paths(row["requiredEvidence"])})
        if row["requiredEvidence"] == "screenshots":
            evidence.extend(WORKSPACE_SCREENSHOT_CLAIM_PATHS)
        if row["testID"] in {"T-096", "T-097"}:
            evidence.append(CLOUD_GAME_CENTER_RESULTS)
            evidence.append(BUILT_PRODUCT_INSPECTION_RESULTS)
        if row["testID"] == "T-116":
            evidence.append(PERFORMANCE_RESOURCE_RESULTS)
        if row["testID"] == "T-006":
            evidence.append(NO_GIT_QUALIFICATION_RESULT)
        if row["testID"] == "T-121":
            evidence.append(placeholder_log)
        test_bindings[row["testID"]] = {
            "result": "PASS",
            "suiteName": "replace-with-suite-name",
            "command": (
                publication_command if row["testID"] == "T-121" else (
                    "python3 scripts/check-remediation-completion.py --no-git-child "
                    "--expected-source-hash replace-with-source-manifest-sha256"
                    if row["testID"] == "T-006"
                    else "replace with exact executed command"
                )
            ),
            "log": placeholder_log,
            "requiredEvidence": row["requiredEvidence"],
            "evidence": sorted(set(evidence)),
        }
    screenshot_platforms = {
        **matrix_screenshots,
        "iphone-share-builder-message.png": "iPhone Simulator",
        "optional-provider-workspace.png": "macOS",
        "iphone-workspace-moonleaf.png": "iPhone Simulator",
        "iphone-settings-moonleaf.png": "iPhone Simulator",
        "iphone-vault-moonleaf.png": "iPhone Simulator",
    }
    screenshot_platforms.update({
        PurePosixPath(path).name: PLATFORM_SCREENSHOT_CLAIM_PLATFORMS[claim]
        for claim, paths in PLATFORM_SCREENSHOT_CLAIM_PATHS.items()
        for path in paths
    })
    return {
        "schemaVersion": SCHEMA_VERSION,
        "sourceRevision": "replace-with-lowercase-40-character-source-commit",
        "environment": {
            "operatingSystem": "replace",
            "architecture": "replace",
            "xcode": "replace",
            "swift": "replace",
        },
        "records": record_template,
        "findings": findings,
        "tests": test_bindings,
        "screenshots": [
            {
                "path": f"{EVIDENCE_PREFIX}/Screenshots/{name}",
                "platform": platform,
                "description": WRITTEN_SCREENSHOT_CONTRACTS.get(
                    f"{EVIDENCE_PREFIX}/Screenshots/{name}",
                    (platform, "replace with the exact captured state"),
                )[1],
            }
            for name, platform in sorted(screenshot_platforms.items())
        ],
        "suites": [
            {
                "name": "replace-with-suite-name",
                "platform": "replace",
                "kind": "replace",
                "executed": len(test_rows),
                "passed": len(test_rows),
                "failed": 0,
                "skipped": 0,
                "log": placeholder_log,
            }
        ],
        "simulators": {
            "iPhone": {"name": "replace", "udid": "replace", "runtime": "replace"},
            "iPad": {"name": "replace", "udid": "replace", "runtime": "replace"},
        },
        "bundleIdentifier": "com.runescribe.app",
        "resetCommands": ["replace with exact reset command"],
        "seedCommands": ["replace with exact seed command"],
        "nonGatingExternal": list(FIXED_NON_GATING_BOUNDARIES),
        "publicationAudit": {
            "command": publication_command,
            "log": placeholder_log,
            "checkedAt": "2026-08-23T00:00:00Z",
            "branch": "replace-with-current-remediation-branch",
            "defaultBranch": "main",
            "remoteInspectionPerformed": True,
            "headTags": [],
            "sourceMergedToDefault": False,
            "releasePublished": False,
            "uploadPerformed": False,
            "notarizationPerformed": False,
            "testFlightPerformed": False,
            "appStorePerformed": False,
            "rolloutPerformed": False,
        },
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Assemble the 13 remediation evidence records, terminal reports, "
            "checksums, and deterministic owner-test ZIP."
        ),
        epilog=(
            "Generation requires a final committed SOURCE-MANIFEST.json, all declared "
            "logs/screenshots, both Release app ZIPs, and the iPad qualification JSON. "
            "Use --validate-only for a non-writing construction check or --verify to "
            "compare existing outputs byte-for-byte."
        ),
    )
    parser.add_argument(
        "--package-root",
        type=Path,
        required=True,
        help="path to Rune-Scribe-Codex-Remediation-Package-v1.0",
    )
    parser.add_argument("--input", type=Path, help="required qualification input JSON")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--validate-only",
        action="store_true",
        help="validate and stage all content without writing repository outputs",
    )
    modes.add_argument(
        "--verify",
        action="store_true",
        help="verify existing generated outputs without changing them",
    )
    modes.add_argument(
        "--print-input-template",
        action="store_true",
        help="print the deterministic input shape and exit",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    if args.print_input_template:
        package_root = args.package_root.resolve()
        (
            _, finding_gates, finding_controls, _, test_rows, _, matrix_screenshots,
        ) = load_controls(package_root, ROOT.resolve())
        print(json.dumps(
            generated_output_template(
                test_rows,
                finding_gates,
                finding_controls,
                matrix_screenshots,
                template_changed_final_paths(ROOT.resolve()),
            ),
            indent=2,
            sort_keys=True,
        ))
        return 0
    if args.input is None:
        raise EvidenceError("--input is required")

    root = ROOT.resolve()
    package_root = args.package_root.resolve()
    input_path = args.input.resolve()
    if not input_path.is_file() or input_path.is_symlink():
        raise EvidenceError(f"input is missing or is not a regular file: {input_path}")

    (
        gate_requirements,
        finding_gates,
        finding_controls,
        original_statuses,
        test_rows,
        matrix_digest,
        matrix_screenshots,
    ) = load_controls(package_root, root)
    completion_schema_value = load_json(
        package_root / "schemas/COMPLETION-REPORT.schema.json",
        "completion report schema",
    )
    if not isinstance(completion_schema_value, dict):
        raise EvidenceError("completion report schema root must be an object")
    completion_schema = completion_schema_value
    matrix_bytes = (package_root / "controls/TEST-MATRIX-v1.0.csv").read_bytes()
    finding_matrix_bytes = (
        package_root / "controls/FINDING-CLOSURE-MATRIX-v1.0.json"
    ).read_bytes()
    manifest_document, source_hash, manifest_paths = load_source_manifest(root)
    input_document = load_json(input_path, "qualification input")
    requested_revision = (
        input_document.get("sourceRevision") if isinstance(input_document, dict) else None
    )
    source_manifest_path = root / SOURCE_MANIFEST
    source_revision, branch = git_metadata(
        root,
        source_manifest_path,
        requested_revision,
    )
    input_data = validate_input(
        input_document,
        root,
        source_hash,
        manifest_document,
        manifest_paths,
        source_revision,
        branch,
        test_rows,
        matrix_screenshots,
        finding_gates,
        finding_controls,
    )

    app_products: dict[str, dict[str, str]] = {}
    for relative, platform in ((MACOS_ZIP, "macOS"), (IPHONE_ZIP, "iOS")):
        app_products[platform] = validate_app_zip(
            repository_file(root, relative, f"{platform} Release app ZIP"),
            platform,
            input_data["bundleIdentifier"],
        )
    ipad_document = load_json(
        repository_file(root, IPAD_QUALIFICATION, "iPad qualification"),
        "iPad qualification",
    )
    ipad_qualification = validate_ipad_qualification(
        ipad_document,
        root=root,
        source_hash=source_hash,
        source_revision=source_revision,
        selected_simulator=input_data["simulators"]["iPad"],
        bundle_identifier=input_data["bundleIdentifier"],
        ios_product_digest=app_products["iOS"]["sha256"],
        input_data=input_data,
    )
    platform_qualification = derive_platform_qualification(
        input_data, ipad_qualification
    )

    staging_parent: Path | None = None
    if not args.validate_only and not args.verify:
        if ARTIFACT_ROOT.is_symlink() or (
            ARTIFACT_ROOT.exists() and not ARTIFACT_ROOT.is_dir()
        ):
            raise EvidenceError(f"artifact output root is unsafe: {ARTIFACT_ROOT}")
        ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
        staging_parent = ARTIFACT_ROOT
    with tempfile.TemporaryDirectory(
        prefix=".evidence-stage-",
        dir=staging_parent,
    ) as temporary:
        outputs = StagedOutputs(root, Path(temporary))
        def rebuild(completion_log_data: bytes) -> None:
            build_all_outputs(
                root=root,
                outputs=outputs,
                input_data=input_data,
                gate_requirements=gate_requirements,
                finding_gates=finding_gates,
                original_statuses=original_statuses,
                test_rows=test_rows,
                matrix_digest=matrix_digest,
                matrix_bytes=matrix_bytes,
                finding_matrix_bytes=finding_matrix_bytes,
                source_hash=source_hash,
                source_revision=source_revision,
                branch=branch,
                platform_qualification=platform_qualification,
                completion_schema=completion_schema,
                completion_log_data=completion_log_data,
            )

        if args.verify:
            existing_completion_log = repository_file(
                root, COMPLETION_LOG, "captured completion-checker log"
            ).read_bytes()
            rebuild(existing_completion_log)
        else:
            rebuild(completion_checker_expected_output(source_revision))

        if args.validate_only:
            print(
                f"PASS: inputs construct {len(RECORD_GATES)} evidence records for "
                f"{len(GATE_IDS)} gates; no outputs written"
            )
            return 0
        if args.verify:
            differences = outputs.verify()
            if differences:
                for difference in differences:
                    print(f"FAIL: {difference}", file=sys.stderr)
                return 1
            captured = checker_output(root)
            if (root / COMPLETION_LOG).read_bytes() != captured:
                raise EvidenceError(
                    "captured completion-checker log differs from the current deterministic result"
                )
            print(
                f"PASS: {len(outputs.files)} generated outputs are deterministic and current"
            )
            return 0

        try:
            outputs.publish()
            captured = checker_output(root)
            stable = False
            for _ in range(3):
                rebuild(captured)
                outputs.publish()
                next_capture = checker_output(root)
                if next_capture == captured:
                    stable = True
                    break
                captured = next_capture
            if not stable:
                raise EvidenceError(
                    "completion-checker log did not reach a deterministic fixed point"
                )
        except Exception:
            outputs.rollback()
            raise
        print(
            f"PASS: generated {len(RECORD_GATES)} evidence records for 42 gates and "
            f"{OWNER_ZIP}"
        )
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EvidenceError as exception:
        print(f"FAIL: {exception}", file=sys.stderr)
        raise SystemExit(2)
