#!/usr/bin/env python3
"""Validate remediation evidence against one deterministic source tree."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
from typing import Any
import zipfile
import zlib


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_EVIDENCE_ROOT = ROOT / "docs/verification/remediation-v1"
DEFAULT_GATES = DEFAULT_EVIDENCE_ROOT / "REMEDIATION-GATES-v1.0.json"
DEFAULT_SOURCE_MANIFEST = DEFAULT_EVIDENCE_ROOT / "SOURCE-MANIFEST.json"
SOURCE_MANIFEST_BEFORE = (
    "docs/verification/remediation-v1/SOURCE-MANIFEST.before.json"
)
BASELINE_RECORD = "docs/verification/remediation-v1/Baseline.json"
BASELINE_MANIFEST_EXCLUDES = (
    ".DS_Store",
    ".build",
    ".git",
    "DerivedData",
    "artifacts/remediation-v1",
    "docs/verification/remediation-v1",
    "docs/verification/remediation-v1/SOURCE-MANIFEST.before.json",
)
EXPECTED_BASELINE_REVISION = "5e4e08ad17a54378ffed2b3a66691594961fe047"
EXPECTED_BASELINE_AGGREGATE_SHA256 = (
    "fe59cb5da32a0632b76a61c1071933a7f23b4ad1583bc4b902d6d391ee8e69b4"
)
EXPECTED_BASELINE_FILE_COUNT = 991
EXPECTED_BASELINE_PACKAGE_SHA256 = (
    "75df2709f203de247064204090f00c58806792e235e45e6f196650e79cf724dc"
)
HEX_40 = re.compile(r"[0-9a-f]{40}")
HEX_64 = re.compile(r"[0-9a-f]{64}")
EXPECTED_VERSION = "1.0.39"
EXPECTED_BUILD = "39"
EXPECTED_GATE_CATALOG_SHA256 = (
    "3ea8bb864224d2de1ddf7521b4f2a8ca8b9379f5e028bc94e3525ef77845f8d3"
)
EXPECTED_FINDING_MATRIX_SHA256 = (
    "e9e973a590c3fe7504eecf1e22f3bca021d942b1daeeea68b26162b16b2d597e"
)
EXPECTED_TEST_MATRIX_SHA256 = (
    "04a91856646f01af203ce0f685fe94951ac15a2184b8340f21764712533142f1"
)
EXPECTED_BUNDLE_IDENTIFIER = "com.runescribe.app"
EXPECTED_CLOUD_CONTAINER = "iCloud.com.runescribe.app"
EXPECTED_GATE_IDS = {f"RC-{index:03d}" for index in range(1, 43)}
EXPECTED_FINDING_IDS = {f"RSA-{index:03d}" for index in range(1, 13)}
EXPECTED_FINDING_GATES = {
    "RSA-001": {"RC-005", "RC-006", "RC-007", "RC-033", "RC-034", "RC-035"},
    "RSA-002": {
        "RC-008", "RC-009", "RC-010", "RC-011", "RC-012", "RC-013",
        "RC-036", "RC-037",
    },
    "RSA-003": {"RC-009", "RC-014", "RC-015", "RC-025"},
    "RSA-004": {"RC-016", "RC-017", "RC-018", "RC-026"},
    "RSA-005": {"RC-012", "RC-019", "RC-020", "RC-036"},
    "RSA-006": {"RC-018", "RC-022", "RC-039"},
    "RSA-007": {"RC-002", "RC-041"},
    "RSA-008": {"RC-004", "RC-005", "RC-029", "RC-041"},
    "RSA-009": {
        "RC-027", "RC-033", "RC-034", "RC-035", "RC-040", "RC-041",
        "RC-042",
    },
    "RSA-010": {"RC-021", "RC-033", "RC-034", "RC-035"},
    "RSA-011": {"RC-023"},
    "RSA-012": {"RC-024", "RC-032"},
}
EXPECTED_FINDING_STATUSES = {
    "RSA-001": "remediation-present-in-attached-snapshot; merge lineage unverified",
    "RSA-002": "open",
    "RSA-003": "open",
    "RSA-004": "open",
    "RSA-005": "open",
    "RSA-006": "open",
    "RSA-007": "requires formal amendment",
    "RSA-008": "open for distributable audit snapshots",
    "RSA-009": "expected owner/distribution work remains",
    "RSA-010": "open",
    "RSA-011": "open",
    "RSA-012": "open",
}
FIXED_NON_GATING_BOUNDARIES = (
    "App Store Connect records",
    "live CloudKit account/container",
    "live Game Center sandbox",
    "distribution signing and public upload",
)
WORKSPACE_SCREENSHOT_CLAIM = "workspace/settings/vault screenshots"
WORKSPACE_SCREENSHOT_CLAIM_PATHS = (
    "docs/verification/remediation-v1/Screenshots/iphone-workspace-moonleaf.png",
    "docs/verification/remediation-v1/Screenshots/iphone-settings-moonleaf.png",
    "docs/verification/remediation-v1/Screenshots/iphone-vault-moonleaf.png",
)
CLOUD_GAME_CENTER_CLAIM = "cloud/game center test logs"
PERFORMANCE_RESOURCE_CLAIM = "performance/resource report"
EVIDENCE_INDEX_CLAIM = "all remediation JSON evidence"
EVIDENCE_INDEX_PATH = "docs/verification/remediation-v1/EvidenceIndex.json"
CLAIM_EVIDENCE_PREFIX = "docs/verification/remediation-v1/ClaimEvidence"
CLOUD_GAME_CENTER_RESULTS = (
    "docs/verification/remediation-v1/GateRun/CloudGameCenter-Test-Results.json"
)
PERFORMANCE_RESOURCE_RESULTS = (
    "docs/verification/remediation-v1/GateRun/Performance-Resource-Results.json"
)
BUILT_PRODUCT_INSPECTION_RESULTS = (
    "docs/verification/remediation-v1/GateRun/Built-Product-Inspection.json"
)
NO_GIT_QUALIFICATION_RESULT = (
    "docs/verification/remediation-v1/GateRun/NoGit-Completion-Result.json"
)
NO_GIT_CHILD_OUTPUT = (
    "PASS: 42 required gates validate against one source tree "
    "(copied tree without Git ancestry)\n"
)
NO_GIT_RESULT_KEYS = {
    "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
    "version", "build", "testID", "command", "expectedOutput",
    "expectedOutputSHA256",
}
NO_GIT_CHILD_MODE = False
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
DOMAIN_APP_PRODUCTS = (
    ("macOS", "artifacts/remediation-v1/RuneScrib-macOS-Release.app.zip"),
    ("iOS", "artifacts/remediation-v1/RuneScrib-iPhoneSimulator-Release.app.zip"),
)
DOMAIN_RESULT_PRODUCER = "scripts/capture-remediation-domain-results.py"
EXPECTED_DOMAIN_PRODUCER_SHA256 = (
    "102c1d263d335bc6c4ad88f3025ca0e92e519321b9f5c077bcc7df366e675d1f"
)
SHIPPING_CHECKER_PATH = "scripts/check-shipping-products.sh"
EXPECTED_SHIPPING_CHECKER_SHA256 = (
    "7a054350e086de7bc920cdd265b608c541200160704ae221bc32715d32aa1134"
)
EXPECTED_SHIPPING_CHECK_COUNT = 101
DOMAIN_SHIPPING_VALIDATION_LOG = (
    "docs/verification/remediation-v1/GateRun/shipping-products.log"
)
LOCKED_SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
DOMAIN_PACKAGE_PATH = "Packages/RuneScribeArchitecture"
DOMAIN_SCRATCH_TOKEN = "${DOMAIN_SCRATCH}"
DOMAIN_REPLAY_OUTPUT = (
    b"PASS: source-bound domain qualification replayed and matched\n"
)
ICLOUD_ENTITLEMENT_KEYS = {
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
    "com.apple.developer.ubiquity-kvstore-identifier",
}
MACOS_REQUIRED_TRUE_ENTITLEMENTS = {
    "com.apple.security.app-sandbox",
    "com.apple.security.personal-information.addressbook",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.developer.game-center",
}
MACOS_OPTIONAL_SIGNING_ENTITLEMENTS = {
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "com.apple.security.get-task-allow",
    "com.apple.developer.icloud-container-environment",
}
IOS_ALLOWED_ENTITLEMENTS = {
    "application-identifier",
    "com.apple.developer.team-identifier",
    "get-task-allow",
    "keychain-access-groups",
    "com.apple.developer.game-center",
    *ICLOUD_ENTITLEMENT_KEYS,
    "com.apple.developer.icloud-container-environment",
}
TEAM_PREFIX = re.compile(r"[A-Z0-9]{10}")
DOMAIN_EXECUTION_KEYS = {
    "identifier", "framework", "command", "exitStatus", "observedTestCount",
    "result", "sourcePath", "sourceSHA256",
}
DOMAIN_PREVIEW_TEST = (
    "RuneScribeUIModuleTests.ShareArtifactRendererTests/"
    "testStaticRendererProducesBoundedFourByThreePreview"
)
DOMAIN_CLOUD_TEST_SOURCES = {
    "RuneScribeCloudSyncModuleTests.offlineQueueCoalescesRevisionsAndAcknowledgesIdempotently()":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeCloudSyncModuleTests/CloudSyncPolicyTests.swift",
    "RuneScribeCloudSyncModuleTests.twoDeviceMergeIsCommutativeIdempotentAndPreservesDomainRules()":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeCloudSyncModuleTests/CloudProgressionMergeTests.swift",
    "RuneScribeCloudSyncModuleTests.corruptOrSecretBearingRemoteIsQuarantinedWithoutChangingLocalTruth()":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeCloudSyncModuleTests/CloudProgressionMergeTests.swift",
    "RuneScribeCloudSyncModuleTests.accountChangeAndOfflineModesPreserveLocalWithoutRemoteOverwrite()":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeCloudSyncModuleTests/CloudProgressionMergeTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testOfflineCloudFailureRemainsDurablyQueuedForRetry":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testSaveConflictRefetchesAndRetriesWithoutDroppingQueuedRevision":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testCorruptRemoteIsQuarantinedAndReplacedWithValidatedLocalReplica":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testIdleAccountChangeRequiresExplicitRebindAndPreservesLocalProjection":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
    "RuneScribeGameCenterModuleTests.percentageMappingIsWholeNumberMonotonicAndOverflowSafe()":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeGameCenterModuleTests/GameCenterReportingTests.swift",
    "RuneScribeGameCenterModuleTests.mappingUsesOnlyLocalProgressionAndLaterOptInIncludesPriorCompletion()":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeGameCenterModuleTests/GameCenterReportingTests.swift",
    "RuneScribeGameCenterModuleTests.outboxCoalescesMonotonicallyAndHandlesRetryDenialAndDuplicateCallbacks()":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeGameCenterModuleTests/GameCenterReportingTests.swift",
    "RuneScribeGameCenterModuleTests.accountChangeDropsOnlyRemoteAcknowledgementsAndRequeuesLocalTruth()":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeGameCenterModuleTests/GameCenterReportingTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testGameCenterNeverAuthenticatesBeforeOptInAndPersistsAcknowledgement":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testPriorCompletionReportsOnceAndDuplicateSnapshotCallbackIsIdempotent":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testGameCenterDenialPreservesQueueAndLaterExplicitOptInReplays":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testAutomaticGameCenterProbeRecoversOfflineReportWithoutNewInput":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testGameCenterAccountChangeRequeuesPriorLocalCompletionForNewScope":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
    "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testMissingServicesAndStorePreserveLocalFirstStatusAndQueuedTruth":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeRuntimeCoreTests/RuntimeCloudGameCenterCoordinatorTests.swift",
}
DOMAIN_PERFORMANCE_TEST_SOURCES = {
    "RuneScribeUIModuleTests.ShareBuilderModelTests/testRapidPreviewGenerationsRejectEveryStaleCompletionAndInvalidation":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/ShareBuilderModelTests.swift",
    "RuneScribeUIModuleTests.ShareArtifactRendererTests/testRenderPlanCoversShortMediumLongPaginatedAndOverflowInscriptions":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/ShareArtifactRendererTests.swift",
    DOMAIN_PREVIEW_TEST:
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/ShareArtifactRendererTests.swift",
    "RuneScribeUIModuleTests.RuntimeApplicationResourcePresentationTests/testDecodedThemeResourceCacheDeduplicatesEvictsAndReleases":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/RuntimeApplicationResourcePresentationTests.swift",
    "RuneScribeUIModuleTests.RuntimeApplicationResourcePresentationTests/testThemeImageReferenceLeaseSurvivesPurgeAndReleasesOnDeinit":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/RuntimeApplicationResourcePresentationTests.swift",
    "RuneScribeNorseThemeModuleTests.NorseBaseThemeModuleTests/testMissingOrCorruptOptionalResourceIsOmittedWithoutBaseFailure":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeNorseThemeModuleTests/NorseBaseThemeModuleTests.swift",
    "RuneScribeUIModuleTests.ReceivedPresentationAvailabilityBindingTests/testLiveProviderStatesResolveRequestedCodexOrNorseFallback":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/ReceivedPresentationAvailabilityBindingTests.swift",
    "RuneScribeCoreModuleTests.CoreApplicationProgressionIntegrationTests/testUnavailableOutboxRepeatedTerminalsKeepOnePhysicalArtifactBound":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeCoreModuleTests/CoreApplicationProgressionIntegrationTests.swift",
    "RuneScribeCoreModuleTests.CoreApplicationProgressionIntegrationTests/testReleasedPreparedMetadataWindowPlusOneCompactsByPersistedChronology":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeCoreModuleTests/CoreApplicationProgressionIntegrationTests.swift",
    "RuneScribeUIModuleTests.RuneScribeUISessionTests/testContentViewLockCleanupClearsSensitiveStateAndReleasesArtifactOnce":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/RuneScribeUISessionTests.swift",
    "RuneScribeUIModuleTests.RuneScribeUISessionTests/testStopReleasesClientWithoutTakingOwnershipFromRuntimeShareProvider":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/RuneScribeUISessionTests.swift",
    "RuneScribeNorseThemeModuleTests.NorseBaseThemeModuleTests/testProductionResourcesPassPhysicalBudgetsWithoutChargingLogicalReuseTwice":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeNorseThemeModuleTests/NorseBaseThemeModuleTests.swift",
    "RuneScribeThemeGloamthornModuleTests.GloamthornThemeProviderTests/testModuleManifestAndImmutableResourcesRemainExact":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeThemeGloamthornModuleTests/GloamthornThemeProviderTests.swift",
    "RuneScribeThemeMoonleafModuleTests.MoonleafThemeProviderTests/testModuleManifestAndImmutableResourcesRemainExact":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeThemeMoonleafModuleTests/MoonleafThemeProviderTests.swift",
    "RuneScribeThemeSunspireModuleTests.SunspireThemeProviderTests/testModuleManifestAndImmutableResourcesRemainExact":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeThemeSunspireModuleTests/SunspireThemeProviderTests.swift",
    "RuneScribeThemeWildwoodModuleTests.WildwoodThemeProviderTests/testModuleManifestAndImmutableResourcesRemainExact":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeThemeWildwoodModuleTests/WildwoodThemeProviderTests.swift",
}
DOMAIN_CLOUD_CASE_TESTS = {
    "deterministic-offline-unavailable": (
        "RuneScribeCloudSyncModuleTests.accountChangeAndOfflineModesPreserveLocalWithoutRemoteOverwrite()",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testMissingServicesAndStorePreserveLocalFirstStatusAndQueuedTruth",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testAutomaticGameCenterProbeRecoversOfflineReportWithoutNewInput",
    ),
    "queue": (
        "RuneScribeCloudSyncModuleTests.offlineQueueCoalescesRevisionsAndAcknowledgesIdempotently()",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testOfflineCloudFailureRemainsDurablyQueuedForRetry",
        "RuneScribeGameCenterModuleTests.outboxCoalescesMonotonicallyAndHandlesRetryDenialAndDuplicateCallbacks()",
    ),
    "retry-merge": (
        "RuneScribeCloudSyncModuleTests.twoDeviceMergeIsCommutativeIdempotentAndPreservesDomainRules()",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testSaveConflictRefetchesAndRetriesWithoutDroppingQueuedRevision",
        "RuneScribeGameCenterModuleTests.outboxCoalescesMonotonicallyAndHandlesRetryDenialAndDuplicateCallbacks()",
    ),
    "account-change": (
        "RuneScribeCloudSyncModuleTests.accountChangeAndOfflineModesPreserveLocalWithoutRemoteOverwrite()",
        "RuneScribeGameCenterModuleTests.accountChangeDropsOnlyRemoteAcknowledgementsAndRequeuesLocalTruth()",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testIdleAccountChangeRequiresExplicitRebindAndPreservesLocalProjection",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testGameCenterAccountChangeRequeuesPriorLocalCompletionForNewScope",
    ),
    "corruption-quarantine": (
        "RuneScribeCloudSyncModuleTests.corruptOrSecretBearingRemoteIsQuarantinedWithoutChangingLocalTruth()",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testCorruptRemoteIsQuarantinedAndReplacedWithValidatedLocalReplica",
    ),
    "monotonic-reporting": (
        "RuneScribeGameCenterModuleTests.percentageMappingIsWholeNumberMonotonicAndOverflowSafe()",
        "RuneScribeGameCenterModuleTests.outboxCoalescesMonotonicallyAndHandlesRetryDenialAndDuplicateCallbacks()",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testPriorCompletionReportsOnceAndDuplicateSnapshotCallbackIsIdempotent",
    ),
    "no-ownership-path": (
        "RuneScribeGameCenterModuleTests.mappingUsesOnlyLocalProgressionAndLaterOptInIncludesPriorCompletion()",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testGameCenterNeverAuthenticatesBeforeOptInAndPersistsAcknowledgement",
    ),
    "privacy-offline-utility": (
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testMissingServicesAndStorePreserveLocalFirstStatusAndQueuedTruth",
        "RuneScribeRuntimeCoreTests.RuntimeCloudGameCenterCoordinatorTests/testGameCenterDenialPreservesQueueAndLaterExplicitOptInReplays",
    ),
    "built-entitlement-configuration-inspection": (),
}
DOMAIN_PERFORMANCE_CASE_TESTS = {
    "preview-churn-cancel": (
        "RuneScribeUIModuleTests.ShareBuilderModelTests/testRapidPreviewGenerationsRejectEveryStaleCompletionAndInvalidation",
    ),
    "large-inscriptions": (
        "RuneScribeUIModuleTests.ShareArtifactRendererTests/testRenderPlanCoversShortMediumLongPaginatedAndOverflowInscriptions",
    ),
    "cache-release": (
        "RuneScribeUIModuleTests.RuntimeApplicationResourcePresentationTests/testDecodedThemeResourceCacheDeduplicatesEvictsAndReleases",
        "RuneScribeUIModuleTests.RuntimeApplicationResourcePresentationTests/testThemeImageReferenceLeaseSurvivesPurgeAndReleasesOnDeinit",
    ),
    "optional-provider-fallback": (
        "RuneScribeNorseThemeModuleTests.NorseBaseThemeModuleTests/testMissingOrCorruptOptionalResourceIsOmittedWithoutBaseFailure",
        "RuneScribeUIModuleTests.ReceivedPresentationAvailabilityBindingTests/testLiveProviderStatesResolveRequestedCodexOrNorseFallback",
    ),
    "bounded-session-retention": (
        "RuneScribeCoreModuleTests.CoreApplicationProgressionIntegrationTests/testUnavailableOutboxRepeatedTerminalsKeepOnePhysicalArtifactBound",
        "RuneScribeCoreModuleTests.CoreApplicationProgressionIntegrationTests/testReleasedPreparedMetadataWindowPlusOneCompactsByPersistedChronology",
        "RuneScribeUIModuleTests.RuneScribeUISessionTests/testContentViewLockCleanupClearsSensitiveStateAndReleasesArtifactOnce",
        "RuneScribeUIModuleTests.RuneScribeUISessionTests/testStopReleasesClientWithoutTakingOwnershipFromRuntimeShareProvider",
    ),
    "preview-under-4-mib": (DOMAIN_PREVIEW_TEST,),
    "preview-4:3": (DOMAIN_PREVIEW_TEST,),
    "theme-budgets": tuple(
        identifier for identifier in DOMAIN_PERFORMANCE_TEST_SOURCES
        if "testProductionResourcesPassPhysicalBudgets" in identifier
        or "testModuleManifestAndImmutableResourcesRemainExact" in identifier
    ),
}
DOMAIN_THEME_SPECS = (
    (
        "Norse", "RuneScribeArchitecture_RuneScribeNorseThemeModule.bundle",
        "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v1.0.json",
        "Norse-Resource-Integrity-Manifest-v1.0.json", "resources", "byteLength",
    ),
    *tuple(
        (
            name, f"RuneScribeArchitecture_RuneScribeTheme{name}Module.bundle",
            f"Packages/RuneScribeArchitecture/Sources/RuneScribeTheme{name}Module/Resources/Production/Resource-Integrity-Manifest-v1.0.json",
            "Resource-Integrity-Manifest-v1.0.json", "files", "bytes",
        )
        for name in ("Gloamthorn", "Moonleaf", "Sunspire", "Wildwood")
    ),
)
PLATFORM_SCREENSHOT_CLAIM_PATHS: dict[str, tuple[str, ...]] = {
    "macOS screenshots": tuple(
        f"docs/verification/remediation-v1/Screenshots/{name}" for name in (
            "macos-optional-provider.png", "macos-share-builder.png",
            "macos-share-builder-moonleaf.png",
            "optional-provider-workspace.png",
        )
    ),
    "iPhone screenshots": tuple(
        f"docs/verification/remediation-v1/Screenshots/{name}" for name in (
            "iphone-appearance-defaults.png", "iphone-base-failure-banner.png",
            "iphone-cipher-share.png", "iphone-norse-result.png",
            "iphone-norse-workspace.png", "iphone-settings-codices.png",
            "iphone-settings-moonleaf.png", "iphone-share-builder-cipher.png",
            "iphone-share-builder-established.png", "iphone-share-builder-first.png",
            "iphone-share-builder-message.png", "iphone-vault-moonleaf.png",
            "iphone-vault.png", "iphone-workspace-moonleaf.png",
        )
    ),
    "iPad screenshots": (
        "docs/verification/remediation-v1/Screenshots/ipad-share-builder.png",
    ),
}
PLATFORM_SCREENSHOT_CLAIM_PLATFORMS = {
    "macOS screenshots": "macOS",
    "iPhone screenshots": "iPhone Simulator",
    "iPad screenshots": "iPad Simulator",
}
WRITTEN_SCREENSHOT_CONTRACTS: dict[str, tuple[str, str]] = {
    "docs/verification/remediation-v1/Screenshots/macos-share-builder-moonleaf.png": (
        "macOS",
        "Moonleaf selected in the macOS Share Builder, demonstrating the "
        "optional provider's themed builder surface.",
    ),
}
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

# Exact repository paths for each ordered primarySourceAreas entry in the
# immutable finding matrix. These are source-manifest members, never caller-
# selected prose matches. Implementation bindings below are derived only from
# these locked tuples and IMPLEMENTATION_SOURCE_AREA_INDEXES.
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
        ("Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v1.0.json",),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Source/Norse-Production-Provenance-Tooling.md",
            "scripts/check-norse-production-provenance.py",
            "scripts/generate-norse-production-provenance.py",
        ),
        (
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Metadata/Norse-Production-Asset-Provenance-v1.0.json",
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v1.0.json",
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
            for source_index in source_indexes
            for path in SOURCE_AREA_PATHS[finding_id][source_index]
        }))
        for source_indexes in implementation_policy
    )
    for finding_id, implementation_policy in IMPLEMENTATION_SOURCE_AREA_INDEXES.items()
}
_DOMAIN_CAPTURE_PATH = "scripts/capture-remediation-domain-results.py"
IMPLEMENTATION_PATHS["RSA-009"] = tuple(
    tuple(sorted(
        (set(paths) - {_DOMAIN_CAPTURE_PATH})
        | ({_DOMAIN_CAPTURE_PATH} if index == 1 else set())
    ))
    for index, paths in enumerate(IMPLEMENTATION_PATHS["RSA-009"])
)

REMOVED_IMPLEMENTATION_PATHS: dict[str, dict[str, tuple[str, ...]]] = {
    finding_id: ({
        "Remove active placeholder/candidate ambiguity": (
            "Packages/RuneScribeArchitecture/Sources/"
            "RuneScribeNorseThemeModule/Resources/Source/"
            "make_norse_base_placeholders.swift",
        ),
    } if finding_id == "RSA-006" else {})
    for finding_id in EXPECTED_FINDING_IDS
}


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
    "RSA-006": (("T-080", "T-081"), ("T-082",), ("T-055", "T-056", "T-118")),
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
EXPECTED_OWNER_PACKAGE = (
    "artifacts/remediation-v1/Rune-Scribe-Owner-Test-Candidate-v1.0.zip"
)
EXPECTED_PAYLOAD_PACKAGE = (
    "artifacts/remediation-v1/Rune-Scribe-Owner-Test-Payload-v1.0.zip"
)
EXPECTED_TEST_EXECUTION_INDEX = (
    "docs/verification/remediation-v1/TestExecutionIndex.json"
)
EXPECTED_TEST_MATRIX = "docs/verification/remediation-v1/TEST-MATRIX-v1.0.csv"
EXPECTED_FINDING_MATRIX = (
    "docs/verification/remediation-v1/FINDING-CLOSURE-MATRIX-v1.0.json"
)
EXPECTED_PUBLICATION_AUDIT = (
    "docs/verification/remediation-v1/PublicationAudit.json"
)
EXPECTED_IPAD_QUALIFICATION_SCHEMA = (
    "docs/verification/remediation-v1/IPAD-QUALIFICATION.schema.json"
)
EXPECTED_SHA256SUMS = "artifacts/remediation-v1/SHA256SUMS"
REQUIRED_ENVELOPE_BASENAMES = {
    "Rune-Scribe-Owner-Test-Payload-v1.0.zip",
    "CompletionReport.json",
    "CompletionReport.md",
    "README.md",
    "SHA256SUMS",
}
REQUIRED_PAYLOAD_BASENAMES = {
    "RuneScrib-macOS-Release.app.zip",
    "RuneScrib-iPhoneSimulator-Release.app.zip",
    "RuneScrib-iPadSimulator-Qualification.json",
    "SOURCE-MANIFEST.json",
    "OWNER-TEST-CANDIDATE-HANDOFF.md",
    "Screenshot-Index.md",
    "Test-Summary.json",
    "TEST-MATRIX-v1.0.csv",
    "FINDING-CLOSURE-MATRIX-v1.0.json",
    "PublicationAudit.json",
    "IPAD-QUALIFICATION.schema.json",
    "SHA256SUMS",
}
REQUIRED_PAYLOAD_PATHS = {
    "RuneScrib-macOS-Release.app.zip",
    "RuneScrib-iPhoneSimulator-Release.app.zip",
    "RuneScrib-iPadSimulator-Qualification.json",
    "IPAD-QUALIFICATION.schema.json",
    "SOURCE-MANIFEST.json",
    "OWNER-TEST-CANDIDATE-HANDOFF.md",
    "Screenshot-Index.md",
    "PublicationAudit.json",
    "TestSummaries/Test-Summary.json",
    "TestSummaries/TEST-MATRIX-v1.0.csv",
    "TestSummaries/FINDING-CLOSURE-MATRIX-v1.0.json",
    "SHA256SUMS",
}
REQUIRED_EXTERNAL_CHECKSUM_BASENAMES = {
    "RuneScrib-macOS-Release.app.zip",
    "RuneScrib-iPhoneSimulator-Release.app.zip",
    "RuneScrib-iPadSimulator-Qualification.json",
    "Rune-Scribe-Owner-Test-Payload-v1.0.zip",
    "Rune-Scribe-Owner-Test-Candidate-v1.0.zip",
    "CompletionReport.json",
    "CompletionReport.md",
    "OWNER-TEST-CANDIDATE-HANDOFF.md",
    "Screenshot-Index.md",
    "Test-Summary.json",
}
INDEX_TERMINAL_FILES = {
    "docs/verification/remediation-v1/REMEDIATION-GATES-v1.0.json",
    EXPECTED_TEST_MATRIX,
    EXPECTED_FINDING_MATRIX,
    "docs/verification/remediation-v1/SOURCE-MANIFEST.json",
    "docs/verification/remediation-v1/CompletionReport.json",
    "docs/verification/remediation-v1/CompletionReport.md",
    "docs/verification/remediation-v1/DefectClosure.json",
    EXPECTED_TEST_EXECUTION_INDEX,
    EXPECTED_PUBLICATION_AUDIT,
    EXPECTED_IPAD_QUALIFICATION_SCHEMA,
}
TERMINAL_MARKDOWN_LINES = (
    "RELEASE_CANDIDATE_READY",
    "All required remediation gates passed against SOURCE-MANIFEST {source_hash}.",
    "macOS host and Release qualification passed.",
    "iPhone Simulator qualification passed.",
    "iPad Simulator qualification passed.",
    "No physical-hardware test was required or used as a gate.",
    "No live-account test was required or used as a gate.",
    "Owner-test candidate artifacts were produced.",
    "No public distribution, upload, tag, release, or rollout was performed.",
)
EVIDENCE_INDEX = "EvidenceIndex.json"
EVIDENCE_EXEMPT = {
    "Baseline.json",
    "DefectClosure.json",
    EVIDENCE_INDEX,
    "REMEDIATION-GATES-v1.0.json",
    "FINDING-CLOSURE-MATRIX-v1.0.json",
    "SOURCE-MANIFEST.before.json",
    "SOURCE-MANIFEST.json",
    "TestExecutionIndex.json",
    "PublicationAudit.json",
    "IPAD-QUALIFICATION.schema.json",
}

TEST_MATRIX_HEADERS = (
    "testID", "area", "platform", "kind", "scenario", "precondition",
    "action", "expectedResult", "requiredEvidence", "gateIDs",
)
TEST_EXECUTION_KEYS = {
    "testID", "area", "platform", "kind", "scenario", "precondition",
    "action", "expectedResult", "requiredEvidence", "gateIDs", "result",
    "suiteName", "command", "log", "logSHA256", "evidence", "evidenceSHA256",
    "attachments", "attachmentSHA256",
}
TEST_INDEX_KEYS = {
    "schemaVersion", "sourceManifestSHA256", "sourceRevision",
    "testMatrixSHA256", "requiredTestCount", "passedTestCount",
    "failedTestCount", "tests",
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_available(root: Path) -> bool:
    if not (root / ".git").exists():
        return False
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False
    try:
        return Path(result.stdout.strip()).resolve() == root.resolve()
    except OSError:
        return False


def git_revision_is_ancestor(root: Path, revision: str) -> bool:
    exists = subprocess.run(
        ["git", "cat-file", "-e", f"{revision}^{{commit}}"],
        cwd=root,
        check=False,
        capture_output=True,
    )
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", revision, "HEAD"],
        cwd=root,
        check=False,
        capture_output=True,
    )
    return exists.returncode == 0 and ancestor.returncode == 0


def valid_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def repository_relative_file(
    value: object,
    repository_root: Path,
) -> bool:
    if not isinstance(value, str) or not value:
        return False
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        return False
    candidate = repository_root / relative
    if not candidate.is_file() or candidate.is_symlink():
        return False
    try:
        candidate.resolve().relative_to(repository_root.resolve())
    except ValueError:
        return False
    return True


def artifact_digest_map_valid(
    digest_map: object,
    required_paths: set[str],
    repository_root: Path,
) -> bool:
    if not isinstance(digest_map, dict) or set(digest_map) != required_paths:
        return False
    for relative, digest in digest_map.items():
        if (
            not isinstance(relative, str)
            or not repository_relative_file(relative, repository_root)
            or not isinstance(digest, str)
            or HEX_64.fullmatch(digest) is None
            or sha256_file(repository_root / relative) != digest
        ):
            return False
    return True


REMEDIATION_RECORD_NAMES = {
    "ShareBuilderValidation.json", "CipherInvitationValidation.json",
    "BaseThemeFailureValidation.json", "AppearanceDefaultsValidation.json",
    "ThemeRootBackgroundValidation.json",
    "NorseProductionProvenanceValidation.json", "SourceManifestValidation.json",
    "CompatibilityValidation.json", "SecurityPrivacyValidation.json",
    "AccessibilityValidation.json", "NegativeMutations.json",
    "FullRegression.json", "AttributionAudit.json",
}


def explicit_claim_path(claim: str) -> str | None:
    special = {
        "Baseline.json": "docs/verification/remediation-v1/Baseline.json",
        "SOURCE-MANIFEST.before.json": (
            "docs/verification/remediation-v1/SOURCE-MANIFEST.before.json"
        ),
        "SOURCE-MANIFEST.json": "docs/verification/remediation-v1/SOURCE-MANIFEST.json",
        "CompletionReport.json": "docs/verification/remediation-v1/CompletionReport.json",
        "CompletionReport.md": "docs/verification/remediation-v1/CompletionReport.md",
        "DefectClosure.json": "docs/verification/remediation-v1/DefectClosure.json",
        "Rune-Scribe-Owner-Test-Candidate-v1.0.zip": EXPECTED_OWNER_PACKAGE,
        "SHA256SUMS": EXPECTED_SHA256SUMS,
        "swift-package.log": "docs/verification/remediation-v1/GateRun/swift-package.log",
        "shipping-products.log": (
            "docs/verification/remediation-v1/GateRun/shipping-products.log"
        ),
        "candidate zip": EXPECTED_OWNER_PACKAGE,
        "check-remediation-completion log": (
            "docs/verification/remediation-v1/GateRun/check-remediation-completion.log"
        ),
        "shipping product log": (
            "docs/verification/remediation-v1/GateRun/shipping-products.log"
        ),
        "negative mutation results": (
            "docs/verification/remediation-v1/NegativeMutations.json"
        ),
        "built Info.plists": BUILT_PRODUCT_INSPECTION_RESULTS,
        EVIDENCE_INDEX_CLAIM: EVIDENCE_INDEX_PATH,
        **{
            name: f"docs/verification/remediation-v1/{name}"
            for name in REMEDIATION_RECORD_NAMES
        },
    }
    if claim in special:
        return special[claim]
    if claim.endswith(".png") and "/" not in claim:
        return f"docs/verification/remediation-v1/Screenshots/{claim}"
    if "/" not in claim:
        return None
    if claim.startswith(("docs/", "artifacts/")):
        return claim
    if claim.startswith(("GateRun/", "Screenshots/", "Attachments/")):
        return f"docs/verification/remediation-v1/{claim}"
    return None


def claim_evidence_path(claim: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", claim.lower()).strip("-")[:72]
    suffix = hashlib.sha256(claim.encode("utf-8")).hexdigest()[:12]
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


def claim_bindings_match(claim: str, references: list[str]) -> bool:
    return len(references) == len(set(references)) and set(references) == set(
        required_claim_paths(claim)
    )


def read_bounded_text(path: Path, maximum_bytes: int = 16 * 1024 * 1024) -> str:
    if path.stat().st_size > maximum_bytes:
        return ""
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def repository_relative(path: Path, repository_root: Path) -> str | None:
    try:
        return path.resolve().relative_to(repository_root.resolve()).as_posix()
    except (OSError, ValueError):
        return None


def unique_string_array(value: object, *, allow_empty: bool = False) -> list[str] | None:
    if (
        not isinstance(value, list)
        or (not allow_empty and not value)
        or not all(isinstance(item, str) and item for item in value)
        or len(value) != len(set(value))
    ):
        return None
    return value


def validate_png_bytes(data: bytes, label: str) -> list[str]:
    errors: list[str] = []
    if len(data) < 45 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        return [f"{label}: file is not a canonical PNG"]
    offset = 8
    chunks: list[bytes] = []
    width = height = 0
    while offset < len(data):
        if offset + 12 > len(data):
            return [f"{label}: PNG chunk is truncated"]
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            return [f"{label}: PNG chunk payload is truncated"]
        chunk_type = data[offset + 4:offset + 8]
        chunk_data = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length:end])[0]
        if zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF != expected_crc:
            return [f"{label}: PNG chunk CRC differs"]
        if not chunks:
            if chunk_type != b"IHDR" or length != 13:
                return [f"{label}: PNG IHDR is invalid"]
            width, height = struct.unpack(">II", chunk_data[:8])
        chunks.append(chunk_type)
        offset = end
        if chunk_type == b"IEND":
            if length != 0 or offset != len(data):
                return [f"{label}: PNG IEND is not final"]
            break
    if width == 0 or height == 0:
        errors.append(f"{label}: PNG has zero dimensions")
    if not chunks or chunks[-1] != b"IEND" or b"IDAT" not in chunks:
        errors.append(f"{label}: PNG omits IDAT or IEND")
    return errors


def validate_png_path(path: Path, label: str) -> list[str]:
    try:
        data = path.read_bytes()
    except OSError as exception:
        return [f"{label}: unreadable PNG: {exception}"]
    return validate_png_bytes(data, label)


def expected_ipad_qualification_schema() -> dict[str, Any]:
    simulator_keys = {"name", "udid", "runtime"}
    product_keys = {"path", "sha256", "bundleIdentifier"}
    suite_keys = {
        "name", "result", "executed", "passed", "failed", "skipped",
        "log", "logSHA256",
    }
    screenshot_keys = {"path", "sha256"}
    root_keys = {
        "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
        "version", "build", "simulator", "iOSProduct", "suites", "screenshots",
    }
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://ravenforgesoftware.com/schemas/runescribe-ipad-qualification-v1.json",
        "title": "Rune Scribe iPad Simulator Qualification",
        "type": "object", "additionalProperties": False,
        "required": sorted(root_keys),
        "properties": {
            "schemaVersion": {"const": "1.0"}, "status": {"const": "PASS"},
            "sourceManifestSHA256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
            "sourceRevision": {
                "type": ["string", "null"], "pattern": "^[0-9a-f]{40}$",
            },
            "version": {"const": EXPECTED_VERSION}, "build": {"const": EXPECTED_BUILD},
            "simulator": {
                "type": "object", "additionalProperties": False,
                "required": sorted(simulator_keys),
                "properties": {
                    "name": {"type": "string", "minLength": 1},
                    "udid": {
                        "type": "string",
                        "pattern": (
                            "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-"
                            "[0-9A-F]{4}-[0-9A-F]{12}$"
                        ),
                    },
                    "runtime": {"type": "string", "minLength": 1},
                },
            },
            "iOSProduct": {
                "type": "object", "additionalProperties": False,
                "required": sorted(product_keys),
                "properties": {
                    "path": {
                        "const": "artifacts/remediation-v1/"
                        "RuneScrib-iPhoneSimulator-Release.app.zip"
                    },
                    "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                    "bundleIdentifier": {"const": EXPECTED_BUNDLE_IDENTIFIER},
                },
            },
            "suites": {
                "type": "array", "minItems": 1,
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": sorted(suite_keys),
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
                    "required": sorted(screenshot_keys),
                    "properties": {
                        "path": {"type": "string", "minLength": 1},
                        "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                    },
                },
            },
        },
    }


def validate_ipad_schema_file(repository_root: Path) -> list[str]:
    path = repository_root / EXPECTED_IPAD_QUALIFICATION_SCHEMA
    try:
        document = load_json(path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return [f"{EXPECTED_IPAD_QUALIFICATION_SCHEMA}: invalid or missing: {exception}"]
    if document != expected_ipad_qualification_schema():
        return [f"{EXPECTED_IPAD_QUALIFICATION_SCHEMA}: differs from the defined schema"]
    return []


def load_locked_test_matrix(
    repository_root: Path,
) -> tuple[list[str], dict[str, dict[str, str]]]:
    relative = EXPECTED_TEST_MATRIX
    path = repository_root / relative
    errors: list[str] = []
    if not path.is_file() or path.is_symlink():
        return [f"{relative}: locked test matrix copy is missing"], {}
    if sha256_file(path) != EXPECTED_TEST_MATRIX_SHA256:
        return [f"{relative}: differs from the locked test matrix digest"], {}
    try:
        with path.open(newline="", encoding="utf-8") as stream:
            reader = csv.DictReader(stream)
            if tuple(reader.fieldnames or ()) != TEST_MATRIX_HEADERS:
                return [f"{relative}: headers differ from the locked schema"], {}
            rows = list(reader)
    except (OSError, csv.Error) as exception:
        return [f"{relative}: unreadable test matrix: {exception}"], {}
    by_id: dict[str, dict[str, str]] = {}
    for index, row in enumerate(rows, start=2):
        test_id = row.get("testID", "")
        if not re.fullmatch(r"T-[0-9]{3}", test_id) or test_id in by_id:
            errors.append(f"{relative}: invalid or duplicate test ID on line {index}")
            continue
        if set(row) != set(TEST_MATRIX_HEADERS) or any(
            not isinstance(row.get(key), str)
            or not row[key]
            or row[key] != row[key].strip()
            or any(character in row[key] for character in ("\n", "\r", "\0"))
            for key in TEST_MATRIX_HEADERS
        ):
            errors.append(f"{relative}: noncanonical field on line {index}")
            continue
        gates = row["gateIDs"].split(";")
        if len(gates) != len(set(gates)) or not set(gates).issubset(EXPECTED_GATE_IDS):
            errors.append(f"{relative}: invalid gateIDs on line {index}")
        by_id[test_id] = dict(row)
    if len(rows) != 87 or len(by_id) != 87:
        errors.append(f"{relative}: must contain exactly 87 locked rows")
    return errors, by_id


def canonical_test_evidence(required: str) -> str | None:
    prefix = "docs/verification/remediation-v1"
    if required.endswith(".png"):
        return f"{prefix}/Screenshots/{required}"
    if required.endswith("Validation.json") or required in {
        "AttributionAudit.json", "NegativeMutations.json",
    }:
        return f"{prefix}/{required}"
    special = {
        "Baseline.json": f"{prefix}/Baseline.json",
        "CompletionReport.json": f"{prefix}/CompletionReport.json",
        "swift-package.log": f"{prefix}/GateRun/swift-package.log",
        "shipping-products.log": f"{prefix}/GateRun/shipping-products.log",
        "candidate zip": EXPECTED_OWNER_PACKAGE,
    }
    if required in special:
        return special[required]
    paths = required_claim_paths(required)
    return paths[0] if len(paths) == 1 else None


def validate_test_execution_index(
    repository_root: Path,
    source_hash: str,
    has_git: bool,
) -> tuple[list[str], dict[str, dict[str, str]], dict[str, dict[str, Any]], str | None]:
    matrix_errors, locked_rows = load_locked_test_matrix(repository_root)
    errors = list(matrix_errors)
    relative = EXPECTED_TEST_EXECUTION_INDEX
    path = repository_root / relative
    try:
        document = load_json(path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return errors + [f"{relative}: invalid or missing: {exception}"], locked_rows, {}, None
    if not isinstance(document, dict) or set(document) != TEST_INDEX_KEYS:
        return errors + [f"{relative}: keys differ from the test-index schema"], locked_rows, {}, None
    expected_scalars = {
        "schemaVersion": "1.0",
        "sourceManifestSHA256": source_hash,
        "testMatrixSHA256": EXPECTED_TEST_MATRIX_SHA256,
        "requiredTestCount": 87,
        "passedTestCount": 87,
        "failedTestCount": 0,
    }
    for key, expected in expected_scalars.items():
        if document.get(key) != expected or (
            key.endswith("Count") and type(document.get(key)) is not int
        ):
            errors.append(f"{relative}: {key} differs")
    revision = document.get("sourceRevision")
    if has_git:
        if not isinstance(revision, str) or HEX_40.fullmatch(revision) is None:
            errors.append(f"{relative}: Git-backed index requires sourceRevision")
        elif not git_revision_is_ancestor(repository_root, revision):
            errors.append(f"{relative}: sourceRevision is not an ancestor of HEAD")
    elif NO_GIT_CHILD_MODE:
        if revision is not None and (
            not isinstance(revision, str) or HEX_40.fullmatch(revision) is None
        ):
            errors.append(f"{relative}: copied-tree sourceRevision is invalid")
    elif revision is not None:
        errors.append(f"{relative}: sourceRevision must be null without Git")
    tests = document.get("tests")
    if not isinstance(tests, list) or len(tests) != 87:
        errors.append(f"{relative}: tests must contain exactly 87 executions")
        tests = []
    executions: dict[str, dict[str, Any]] = {}
    exact_matrix_screenshots = {
        f"docs/verification/remediation-v1/Screenshots/{row['requiredEvidence']}"
        for row in locked_rows.values()
        if row["requiredEvidence"].endswith(".png")
    }
    evidenced_matrix_screenshots: set[str] = set()
    for index, execution in enumerate(tests):
        label = f"{relative}: tests[{index}]"
        if not isinstance(execution, dict) or set(execution) != TEST_EXECUTION_KEYS:
            errors.append(f"{label} keys differ from the execution schema")
            continue
        test_id = execution.get("testID")
        if not isinstance(test_id, str) or test_id not in locked_rows or test_id in executions:
            errors.append(f"{label} has an invalid or duplicate test ID")
            continue
        executions[test_id] = execution
        locked = locked_rows[test_id]
        for field in TEST_MATRIX_HEADERS:
            expected: object = (
                locked[field].split(";") if field == "gateIDs" else locked[field]
            )
            if execution.get(field) != expected:
                errors.append(f"{label}.{field} differs from locked row {test_id}")
        if execution.get("result") != "PASS":
            errors.append(f"{label}.result must be PASS")
        for field in ("suiteName", "command"):
            if not isinstance(execution.get(field), str) or not execution[field].strip():
                errors.append(f"{label}.{field} must be nonempty")
        log = execution.get("log")
        if not repository_relative_file(log, repository_root):
            errors.append(f"{label}.log is missing or unsafe")
        elif execution.get("logSHA256") != sha256_file(repository_root / log):
            errors.append(f"{label}.logSHA256 differs")
        evidence = unique_string_array(execution.get("evidence"))
        if evidence is None or not all(
            repository_relative_file(item, repository_root) for item in evidence or []
        ):
            errors.append(f"{label}.evidence is invalid or missing")
            evidence = []
        expected_named = canonical_test_evidence(locked["requiredEvidence"])
        if expected_named is not None and expected_named not in evidence:
            errors.append(f"{label}.evidence omits exact required evidence {expected_named}")
        if isinstance(log, str) and log not in evidence:
            errors.append(f"{label}.evidence omits its execution log")
        if test_id in {"T-096", "T-097"} and not {
            BUILT_PRODUCT_INSPECTION_RESULTS,
            DOMAIN_SHIPPING_VALIDATION_LOG,
        }.issubset(evidence):
            errors.append(
                f"{label}.evidence omits the exact built-product inspection or "
                "shipping-product log"
            )
        if test_id == "T-116" and DOMAIN_SHIPPING_VALIDATION_LOG not in evidence:
            errors.append(f"{label}.evidence omits the exact shipping-product log")
        digest_map = execution.get("evidenceSHA256")
        if not artifact_digest_map_valid(digest_map, set(evidence), repository_root):
            errors.append(f"{label}.evidenceSHA256 does not exactly bind evidence")
        for screenshot in set(evidence) & exact_matrix_screenshots:
            evidenced_matrix_screenshots.add(screenshot)
            errors.extend(validate_png_path(repository_root / screenshot, label))
        attachments = unique_string_array(execution.get("attachments"))
        if attachments is None or not all(
            repository_relative_file(item, repository_root) for item in attachments or []
        ):
            errors.append(f"{label}.attachments are invalid or missing")
            attachments = []
        if not artifact_digest_map_valid(
            execution.get("attachmentSHA256"), set(attachments), repository_root
        ):
            errors.append(f"{label}.attachmentSHA256 does not exactly bind attachments")
        for attachment in attachments:
            text = read_bounded_text(repository_root / attachment)
            required_fragments = [
                test_id, "PASS", str(execution.get("suiteName", "")),
                str(execution.get("command", "")), str(log or ""),
                str(execution.get("logSHA256", "")), locked["requiredEvidence"],
                *[locked[field] for field in TEST_MATRIX_HEADERS],
                *evidence,
                *(
                    list(digest_map.values()) if isinstance(digest_map, dict) else []
                ),
            ]
            for fragment in required_fragments:
                escaped = fragment.replace("|", "\\|")
                if fragment and fragment not in text and escaped not in text:
                    errors.append(f"{label}: attachment omits bound value {fragment!r}")
                    break
    if set(executions) != set(locked_rows):
        errors.append(f"{relative}: execution IDs differ from all 87 locked test IDs")
    workspace_execution = executions.get("T-071", {})
    workspace_evidence = workspace_execution.get("evidence")
    if not isinstance(workspace_evidence, list):
        workspace_evidence = []
    for screenshot in WORKSPACE_SCREENSHOT_CLAIM_PATHS:
        if screenshot not in workspace_evidence:
            errors.append(f"{relative}: T-071 omits exact workspace screenshot {screenshot}")
        elif repository_relative_file(screenshot, repository_root):
            errors.extend(validate_png_path(
                repository_root / screenshot, f"{relative}: T-071"
            ))
    missing_screenshots = sorted(exact_matrix_screenshots - evidenced_matrix_screenshots)
    if missing_screenshots:
        errors.append(
            f"{relative}: exact named matrix screenshots are missing: "
            + ", ".join(missing_screenshots)
        )
    screenshot_index_path = (
        repository_root / "artifacts/remediation-v1/Screenshot-Index.md"
    )
    screenshot_index = (
        read_bounded_text(screenshot_index_path)
        if screenshot_index_path.is_file() and not screenshot_index_path.is_symlink()
        else ""
    )
    if not screenshot_index:
        errors.append("artifacts/remediation-v1/Screenshot-Index.md is missing or unreadable")
    platform_screenshot_contracts = {
        path: PLATFORM_SCREENSHOT_CLAIM_PLATFORMS[claim]
        for claim, paths in PLATFORM_SCREENSHOT_CLAIM_PATHS.items()
        for path in paths
    }
    indexed_screenshots = exact_matrix_screenshots | set(platform_screenshot_contracts)
    for screenshot in sorted(indexed_screenshots):
        basename = Path(screenshot).name
        platforms = {
            row["platform"] for row in locked_rows.values()
            if row["requiredEvidence"] == basename
        }
        if screenshot in platform_screenshot_contracts:
            platforms.add(platform_screenshot_contracts[screenshot])
        digest = (
            sha256_file(repository_root / screenshot)
            if repository_relative_file(screenshot, repository_root) else ""
        )
        description = WRITTEN_SCREENSHOT_CONTRACTS.get(screenshot, ("", ""))[1]
        for required in (
            f"Screenshots/{basename}", digest, *sorted(platforms), description,
        ):
            if required and required not in screenshot_index:
                errors.append(
                    f"artifacts/remediation-v1/Screenshot-Index.md omits {required}"
                )
    return errors, locked_rows, executions, revision if isinstance(revision, str) else None


def validate_count_object(value: object, label: str) -> tuple[list[str], dict[str, int]]:
    errors: list[str] = []
    keys = {"executed", "passed", "failed", "skipped"}
    if not isinstance(value, dict) or set(value) != keys:
        return [f"{label}: keys differ from the count schema"], {}
    if not all(type(value.get(key)) is int and value[key] >= 0 for key in keys):
        return [f"{label}: counts must be nonnegative integers"], {}
    if value["passed"] + value["failed"] + value["skipped"] != value["executed"]:
        errors.append(f"{label}: counts do not add up")
    return errors, {key: value[key] for key in keys}


def validate_structured_suite_results(
    repository_root: Path,
    source_hash: str,
    source_revision: str | None,
    locked_rows: dict[str, dict[str, str]],
    executions: dict[str, dict[str, Any]],
) -> tuple[list[str], dict[str, dict[str, Any]]]:
    """Validate exact per-suite result documents and their independently captured logs."""
    errors: list[str] = []
    parsed: dict[str, dict[str, Any]] = {}
    suite_names = {
        execution.get("suiteName")
        for execution in executions.values()
        if isinstance(execution.get("suiteName"), str)
    }
    log_to_suite: dict[str, str] = {}
    for suite_name in sorted(suite_names):
        suite_ids = sorted(
            test_id for test_id, execution in executions.items()
            if execution.get("suiteName") == suite_name
        )
        log_values = {
            executions[test_id].get("log") for test_id in suite_ids
            if isinstance(executions[test_id].get("log"), str)
        }
        label = f"structured suite result {suite_name!r}"
        if len(log_values) != 1:
            errors.append(f"{label}: executions must bind one exact result JSON")
            continue
        relative = next(iter(log_values))
        if (
            not relative.startswith("docs/verification/remediation-v1/GateRun/")
            or not relative.endswith(".json")
            or relative in log_to_suite
            or not repository_relative_file(relative, repository_root)
        ):
            errors.append(f"{label}: result path is not a unique GateRun JSON")
            continue
        log_to_suite[relative] = suite_name
        try:
            document = load_json(repository_root / relative)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
            errors.append(f"{relative}: invalid structured suite result: {exception}")
            continue
        if not isinstance(document, dict) or set(document) != STRUCTURED_TEST_LOG_KEYS:
            errors.append(f"{relative}: keys differ from structured suite-result schema")
            continue
        expected_scalars: dict[str, object] = {
            "schemaVersion": "1.0", "status": "PASS",
            "sourceManifestSHA256": source_hash,
            "sourceRevision": source_revision,
            "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
            "suiteName": suite_name,
        }
        for key, expected in expected_scalars.items():
            if document.get(key) != expected:
                errors.append(f"{relative}: {key} differs")
        count_errors, totals = validate_count_object(
            document.get("totals"), f"{relative}.totals"
        )
        errors.extend(count_errors)
        expected_totals = {
            "executed": len(suite_ids), "passed": len(suite_ids),
            "failed": 0, "skipped": 0,
        }
        if totals and totals != expected_totals:
            errors.append(f"{relative}.totals differ from exact suite executions")
        raw_log = document.get("rawLog")
        raw_text = ""
        if (
            not isinstance(raw_log, str)
            or raw_log == relative
            or not repository_relative_file(raw_log, repository_root)
        ):
            errors.append(f"{relative}.rawLog is missing, unsafe, or self-referential")
        else:
            raw_path = repository_root / raw_log
            if document.get("rawLogSHA256") != sha256_file(raw_path):
                errors.append(f"{relative}.rawLogSHA256 differs")
            raw_text = read_bounded_text(raw_path)
            if not raw_text:
                errors.append(f"{relative}.rawLog is empty, too large, or not UTF-8")
        entries = document.get("executions")
        seen_ids: set[str] = set()
        if not isinstance(entries, list) or len(entries) != len(suite_ids):
            errors.append(f"{relative}.executions differ from exact suite bindings")
            entries = []
        for index, entry in enumerate(entries):
            entry_label = f"{relative}.executions[{index}]"
            if not isinstance(entry, dict) or set(entry) != STRUCTURED_TEST_LOG_EXECUTION_KEYS:
                errors.append(f"{entry_label}: keys differ")
                continue
            test_id = entry.get("testID")
            if test_id not in suite_ids or test_id in seen_ids:
                errors.append(f"{entry_label}.testID is invalid or duplicate")
                continue
            seen_ids.add(test_id)
            expected_entry = {
                "testID": test_id,
                "scenario": locked_rows[test_id]["scenario"],
                "result": "PASS",
                "suiteName": suite_name,
                "command": executions[test_id].get("command"),
                "requiredEvidence": locked_rows[test_id]["requiredEvidence"],
            }
            if entry != expected_entry:
                errors.append(f"{entry_label} differs from the locked execution")
            # These markers are required in the independently captured bounded raw log;
            # the structured JSON is an index, not the authority for the PASS claim.
            for marker in expected_entry.values():
                if str(marker) not in raw_text:
                    errors.append(f"{relative}.rawLog omits {marker!r}")
        if seen_ids != set(suite_ids):
            errors.append(f"{relative}.executions omit exact suite test IDs")
        parsed[suite_name] = document
    if set(executions) == set(locked_rows) and not suite_names:
        errors.append("structured suite results: no suite names were present")
    return errors, parsed


def json_safe_plist_value(value: object) -> object:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, list):
        return [json_safe_plist_value(item) for item in value]
    if isinstance(value, dict):
        return {
            str(key): json_safe_plist_value(item)
            for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))
        }
    if isinstance(value, bytes):
        return {
            "sha256": hashlib.sha256(value).hexdigest(),
            "bytes": len(value),
        }
    return str(value)


def entitlement_policy_errors(
    entitlement: dict[str, Any], *, platform: str, architecture: str
) -> list[str]:
    label = f"{platform} {architecture}"
    errors: list[str] = []
    if any(not isinstance(key, str) for key in entitlement):
        return [f"{label} entitlement keys are not strings"]

    if entitlement.get("com.apple.developer.icloud-container-identifiers") != [
        EXPECTED_CLOUD_CONTAINER
    ]:
        errors.append(f"{label} iCloud container identifiers differ")
    if entitlement.get("com.apple.developer.icloud-services") != ["CloudKit"]:
        errors.append(f"{label} iCloud service declaration differs")
    kvstore = entitlement.get("com.apple.developer.ubiquity-kvstore-identifier")
    concrete_kvstore = (
        isinstance(kvstore, str)
        and re.fullmatch(r"[A-Z0-9]{10}\.com\.runescribe\.app", kvstore) is not None
    )
    if kvstore != "$(TeamIdentifierPrefix)com.runescribe.app" and not concrete_kvstore:
        errors.append(f"{label} ubiquity key-value store identifier differs")
    if concrete_kvstore:
        team_identifier = entitlement.get("com.apple.developer.team-identifier")
        application_identifier = entitlement.get("application-identifier")
        if application_identifier is None:
            application_identifier = entitlement.get("com.apple.application-identifier")
        expected_prefix: str | None = None
        if isinstance(team_identifier, str) and team_identifier:
            expected_prefix = team_identifier
        elif (
            isinstance(application_identifier, str)
            and application_identifier.endswith(".com.runescribe.app")
        ):
            expected_prefix = application_identifier[: -len(".com.runescribe.app")]
        if (
            expected_prefix is None
            or TEAM_PREFIX.fullmatch(expected_prefix) is None
            or kvstore != f"{expected_prefix}.com.runescribe.app"
        ):
            errors.append(
                f"{label} ubiquity key-value store prefix differs from the signing team"
            )
    environment = entitlement.get("com.apple.developer.icloud-container-environment")
    if environment is not None and environment not in {"Development", "Production"}:
        errors.append(f"{label} iCloud container environment is invalid")

    if platform == "macOS":
        for key in sorted(MACOS_REQUIRED_TRUE_ENTITLEMENTS):
            if entitlement.get(key) is not True:
                errors.append(f"{label} required entitlement {key} is absent")
        allowed = (
            MACOS_REQUIRED_TRUE_ENTITLEMENTS
            | ICLOUD_ENTITLEMENT_KEYS
            | MACOS_OPTIONAL_SIGNING_ENTITLEMENTS
        )
        unexpected = sorted(set(entitlement) - allowed)
        if unexpected:
            errors.append(
                f"{label} contains unexpected entitlements: {', '.join(unexpected)}"
            )
        get_task_allow = "com.apple.security.get-task-allow"
        if get_task_allow in entitlement and entitlement[get_task_allow] is not False:
            errors.append(f"{label} Release product enables get-task-allow")
        application_identifier = entitlement.get("com.apple.application-identifier")
        team_identifier = entitlement.get("com.apple.developer.team-identifier")
        if application_identifier is not None or team_identifier is not None:
            if (
                not isinstance(team_identifier, str)
                or TEAM_PREFIX.fullmatch(team_identifier) is None
                or application_identifier
                != f"{team_identifier}.com.runescribe.app"
            ):
                errors.append(f"{label} signing-injected identifiers are inconsistent")
    elif platform == "iOS":
        unexpected = sorted(set(entitlement) - IOS_ALLOWED_ENTITLEMENTS)
        if unexpected:
            errors.append(
                f"{label} contains unexpected entitlements: {', '.join(unexpected)}"
            )
        if "get-task-allow" in entitlement and entitlement["get-task-allow"] is not False:
            errors.append(f"{label} Release product enables get-task-allow")
        if entitlement.get("com.apple.developer.game-center") is not True:
            errors.append(f"{label} required Game Center entitlement is absent")
        groups = entitlement.get("keychain-access-groups")
        application_identifier = entitlement.get("application-identifier")
        if (
            not isinstance(groups, list)
            or len(groups) != 1
            or not isinstance(application_identifier, str)
            or groups[0] != application_identifier
            or not application_identifier.endswith(".com.runescribe.app")
        ):
            errors.append(
                f"{label} keychain access group does not preserve com.runescribe.app"
            )
        team_identifier = entitlement.get("com.apple.developer.team-identifier")
        if team_identifier is not None and (
            not isinstance(team_identifier, str)
            or TEAM_PREFIX.fullmatch(team_identifier) is None
            or application_identifier != f"{team_identifier}.com.runescribe.app"
        ):
            errors.append(f"{label} signing-injected team identifier is inconsistent")
    else:
        errors.append(f"{label} entitlement platform is unsupported")
    return errors


def derive_domain_executable_entitlements(
    executable_bytes: bytes,
    *,
    platform: str,
    simulator: bool,
) -> tuple[list[str], list[str], list[dict[str, Any]]]:
    errors: list[str] = []
    inspections: list[dict[str, Any]] = []
    normalized_entitlements: list[object] = []
    with tempfile.TemporaryDirectory(
        prefix="runescribe-checker-built-entitlements-"
    ) as temporary:
        executable = Path(temporary) / "RuneScrib"
        executable.write_bytes(executable_bytes)
        executable.chmod(0o755)
        try:
            lipo = subprocess.run(
                ["/usr/bin/lipo", "-archs", str(executable)],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as exception:
            return [f"cannot inspect {platform} executable architectures: {exception}"], [], []
        architectures = lipo.stdout.split() if lipo.returncode == 0 else []
        if platform == "macOS":
            if architectures != ["arm64"]:
                errors.append("macOS executable architecture set must be exactly arm64")
            expected_platform = "1"
        else:
            if not architectures or any(
                item not in {"arm64", "x86_64"} for item in architectures
            ):
                errors.append("iOS Simulator executable architecture set is invalid")
            expected_platform = "7"
        if errors:
            return errors, architectures, []
        for architecture in architectures:
            try:
                load_commands = subprocess.run(
                    ["/usr/bin/otool", "-arch", architecture, "-l", str(executable)],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
            except (OSError, subprocess.TimeoutExpired) as exception:
                errors.append(
                    f"cannot inspect {platform} {architecture} load commands: {exception}"
                )
                continue
            if load_commands.returncode != 0:
                errors.append(f"cannot inspect {platform} {architecture} load commands")
                continue
            platforms: list[str] = []
            lines = load_commands.stdout.splitlines()
            for line_index, line in enumerate(lines):
                if line.strip() != "cmd LC_BUILD_VERSION":
                    continue
                for candidate in lines[line_index + 1:line_index + 9]:
                    if candidate.strip().startswith("platform "):
                        platforms.append(candidate.split()[-1])
                        break
            if not platforms or any(value != expected_platform for value in platforms):
                errors.append(
                    f"{platform} {architecture} LC_BUILD_VERSION platform differs"
                )
                continue
            method: str
            entitlement_bytes: bytes
            if simulator:
                try:
                    otool = subprocess.run(
                        [
                            "/usr/bin/otool", "-arch", architecture, "-X", "-s",
                            "__TEXT", "__entitlements", str(executable),
                        ],
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=60,
                    )
                except (OSError, subprocess.TimeoutExpired) as exception:
                    errors.append(
                        f"cannot extract {platform} {architecture} embedded "
                        f"entitlements: {exception}"
                    )
                    continue
                if otool.returncode != 0:
                    errors.append(
                        f"cannot extract {platform} {architecture} embedded entitlements"
                    )
                    continue
                decoded = bytearray()
                for line in otool.stdout.splitlines():
                    fields = line.split()
                    for word in fields[1:]:
                        if re.fullmatch(r"[0-9a-fA-F]+", word) and len(word) % 2 == 0:
                            decoded.extend(bytes.fromhex(word)[::-1])
                entitlement_bytes = bytes(decoded).rstrip(b"\0")
                method = "otool-__TEXT-__entitlements"
            else:
                try:
                    codesign = subprocess.run(
                        [
                            "/usr/bin/codesign", "-d", "--arch", architecture,
                            "--entitlements", ":-", str(executable),
                        ],
                        check=False,
                        capture_output=True,
                        timeout=60,
                    )
                except (OSError, subprocess.TimeoutExpired) as exception:
                    errors.append(
                        f"cannot extract {platform} {architecture} signed "
                        f"entitlements: {exception}"
                    )
                    continue
                if codesign.returncode != 0:
                    errors.append(
                        f"cannot extract {platform} {architecture} signed entitlements"
                    )
                    continue
                entitlement_bytes = codesign.stdout
                method = "codesign"
            try:
                entitlement = plistlib.loads(entitlement_bytes)
            except (plistlib.InvalidFileException, ValueError) as exception:
                errors.append(
                    f"{platform} {architecture} entitlements are not a plist: {exception}"
                )
                continue
            if not isinstance(entitlement, dict):
                errors.append(
                    f"{platform} {architecture} entitlements are not a dictionary"
                )
                continue
            errors.extend(entitlement_policy_errors(
                entitlement, platform=platform, architecture=architecture
            ))
            normalized = json_safe_plist_value(entitlement)
            normalized_entitlements.append(normalized)
            inspections.append({
                "architecture": architecture,
                "method": method,
                "sha256": hashlib.sha256(
                    canonical_json_line(normalized).encode("utf-8")
                ).hexdigest(),
                "entitlements": normalized,
            })
    if len({canonical_json_line(value) for value in normalized_entitlements}) != 1:
        errors.append(f"{platform} entitlements differ across executable architectures")
    return errors, architectures, inspections


def derive_domain_product_inspection(
    repository_root: Path,
    platform: str,
    relative: str,
) -> tuple[list[str], dict[str, Any]]:
    errors: list[str] = []
    path = repository_root / relative
    if not repository_relative_file(relative, repository_root):
        return [f"domain product inspection: missing {relative}"], {}
    try:
        with zipfile.ZipFile(path) as archive:
            files, zip_errors = safe_zip_files(
                archive, f"domain product inspection {platform}"
            )
            errors.extend(zip_errors)
            if platform == "macOS":
                info_names = [
                    name for name in files
                    if re.search(r"\.app/Contents/Info\.plist$", name)
                ]
            else:
                info_names = [
                    name for name in files
                    if re.search(r"\.app/Info\.plist$", name)
                    and "/Contents/" not in name
                ]
            if len(info_names) != 1:
                return errors + [
                    f"domain product inspection: {relative} lacks one {platform} Info.plist"
                ], {}
            info_name = info_names[0]
            info_bytes = archive.read(files[info_name])
            info = plistlib.loads(info_bytes)
            if not isinstance(info, dict):
                return errors + [
                    f"domain product inspection: {relative} Info.plist is not a dictionary"
                ], {}
            expected_info = {
                "CFBundleIdentifier": EXPECTED_BUNDLE_IDENTIFIER,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": EXPECTED_VERSION,
                "CFBundleVersion": EXPECTED_BUILD,
                "CFBundleSupportedPlatforms": (
                    ["MacOSX"] if platform == "macOS" else ["iPhoneSimulator"]
                ),
            }
            for key, expected in expected_info.items():
                if info.get(key) != expected:
                    errors.append(
                        f"domain product inspection: {relative} {key} differs"
                    )
            executable_name = info.get("CFBundleExecutable")
            if not isinstance(executable_name, str) or not executable_name:
                return errors + [
                    f"domain product inspection: {relative} CFBundleExecutable is invalid"
                ], {}
            app_root = info_name.rsplit("/", 1)[0]
            executable_relative = (
                f"{app_root}/MacOS/{executable_name}"
                if platform == "macOS" else f"{app_root}/{executable_name}"
            )
            executable_info = files.get(executable_relative)
            if executable_info is None:
                return errors + [
                    f"domain product inspection: {relative} declared executable is missing"
                ], {}
            executable_bytes = archive.read(executable_info)
            unix_mode = (executable_info.external_attr >> 16) & 0xFFFF
            if (
                len(executable_bytes) < 32
                or executable_bytes[:4] not in MACHO_MAGICS
                or not (unix_mode & 0o111)
            ):
                return errors + [
                    f"domain product inspection: {relative} declared executable is "
                    "not an executable Mach-O"
                ], {}
            entitlement_errors, architectures, entitlement_inspections = (
                derive_domain_executable_entitlements(
                    executable_bytes,
                    platform=platform,
                    simulator=platform != "macOS",
                )
            )
            errors.extend(entitlement_errors)
            if not entitlement_inspections:
                return errors, {}
            entitlements = entitlement_inspections[0]["entitlements"]
            product = {
                "platform": platform,
                "path": relative,
                "sha256": sha256_file(path),
                "infoPlistPath": info_name,
                "infoPlistSHA256": hashlib.sha256(info_bytes).hexdigest(),
                "executablePath": executable_relative,
                "executableSHA256": hashlib.sha256(executable_bytes).hexdigest(),
                "architectures": architectures,
                "entitlementInspections": entitlement_inspections,
                "configuration": {
                    "CFBundleIdentifier": info.get("CFBundleIdentifier"),
                    "CFBundlePackageType": info.get("CFBundlePackageType"),
                    "CFBundleShortVersionString": info.get(
                        "CFBundleShortVersionString"
                    ),
                    "CFBundleVersion": info.get("CFBundleVersion"),
                    "CFBundleSupportedPlatforms": info.get(
                        "CFBundleSupportedPlatforms"
                    ),
                    "GKGameCenter": json_safe_plist_value(info.get("GKGameCenter")),
                    "NSUbiquitousContainers": json_safe_plist_value(
                        info.get("NSUbiquitousContainers")
                    ),
                    "cloudKitContainerIdentifiers": entitlements[
                        "com.apple.developer.icloud-container-identifiers"
                    ],
                    "cloudKitServices": entitlements[
                        "com.apple.developer.icloud-services"
                    ],
                    "gameCenterEntitlement": entitlements[
                        "com.apple.developer.game-center"
                    ],
                },
            }
            return errors, product
    except (
        OSError, KeyError, RuntimeError, zipfile.BadZipFile,
        plistlib.InvalidFileException, ValueError,
    ) as exception:
        return [f"domain product inspection failed for {relative}: {exception}"], {}


def canonical_json_line(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def validate_shipping_validation_log(
    repository_root: Path,
) -> tuple[list[str], dict[str, Any]]:
    errors: list[str] = []
    checker_path = repository_root / SHIPPING_CHECKER_PATH
    if not repository_relative_file(SHIPPING_CHECKER_PATH, repository_root):
        errors.append("shipping-product checker is missing or unsafe")
    elif sha256_file(checker_path) != EXPECTED_SHIPPING_CHECKER_SHA256:
        errors.append("shipping-product checker differs from the locked executable")
    log_path = repository_root / DOMAIN_SHIPPING_VALIDATION_LOG
    if not repository_relative_file(DOMAIN_SHIPPING_VALIDATION_LOG, repository_root):
        return errors + ["shipping-product validation log is missing or unsafe"], {}
    try:
        output = log_path.read_bytes()
        text = output.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exception:
        return errors + [f"shipping-product validation log is unreadable: {exception}"], {}
    lines = text.splitlines()
    expected_summary = (
        f"Shipping-product inspection: {EXPECTED_SHIPPING_CHECK_COUNT} checks, "
        "0 failures."
    )
    expected_terminal = "T-028 shipping-product/configuration inspection passed."
    signature_messages = {
        "macOS": {
            "ad-hoc": (
                "INFO: macOS product uses an ad hoc local signature; "
                "distribution identity is not assessed."
            ),
            "non-ad-hoc": "INFO: macOS product uses a non-ad-hoc signature.",
        },
        "iOS": {
            "ad-hoc": (
                "INFO: iOS product uses an ad hoc local signature; "
                "distribution identity is not assessed."
            ),
            "non-ad-hoc": "INFO: iOS product uses a non-ad-hoc signature.",
        },
    }
    info_lines = [line for line in lines[:-2] if line.startswith("INFO: ")]
    signature_kinds: dict[str, str] = {}
    for platform, line in zip(("macOS", "iOS"), info_lines):
        matches = [
            kind for kind, expected in signature_messages[platform].items()
            if line == expected
        ]
        if len(matches) == 1:
            signature_kinds[platform] = matches[0]
    if (
        len(lines) != EXPECTED_SHIPPING_CHECK_COUNT + 4
        or sum(line.startswith("PASS: ") for line in lines)
        != EXPECTED_SHIPPING_CHECK_COUNT
        or len(info_lines) != 2
        or len(lines) < 12
        or info_lines != [lines[9], lines[11]]
        or set(signature_kinds) != {"macOS", "iOS"}
        or any(
            not line.startswith("PASS: ")
            for index, line in enumerate(lines[:-2])
            if index not in {9, 11}
        )
        or lines[-2:] != [expected_summary, expected_terminal]
        or not text.endswith("\n")
    ):
        errors.append("shipping-product validation log semantics differ")
    summary = {
        "result": "PASS",
        "checkerPath": SHIPPING_CHECKER_PATH,
        "checkerSHA256": EXPECTED_SHIPPING_CHECKER_SHA256,
        "command": (
            "/bin/bash scripts/check-shipping-products.sh "
            "--macos-app ${EXTRACTED_MACOS_APP} "
            "--ios-app ${EXTRACTED_IOS_APP}"
        ),
        "checkCount": EXPECTED_SHIPPING_CHECK_COUNT,
        "signatureKinds": signature_kinds,
        "log": DOMAIN_SHIPPING_VALIDATION_LOG,
        "logSHA256": hashlib.sha256(output).hexdigest(),
    }
    return errors, summary


def derive_domain_theme_budgets(
    repository_root: Path,
) -> tuple[list[str], list[dict[str, Any]]]:
    errors: list[str] = []
    results: list[dict[str, Any]] = []
    for platform, relative in DOMAIN_APP_PRODUCTS:
        path = repository_root / relative
        if not repository_relative_file(relative, repository_root):
            errors.append(f"domain Theme budget inspection: missing {relative}")
            continue
        try:
            with zipfile.ZipFile(path) as archive:
                files, zip_errors = safe_zip_files(
                    archive, f"domain Theme budget inspection {platform}"
                )
                errors.extend(zip_errors)
                for (
                    theme, bundle_name, source_relative, manifest_name,
                    entries_key, bytes_key,
                ) in DOMAIN_THEME_SPECS:
                    supported_manifest_suffixes = (
                        f"/{bundle_name}/{manifest_name}",
                        f"/{bundle_name}/Resources/{manifest_name}",
                        f"/{bundle_name}/Contents/Resources/{manifest_name}",
                    )
                    candidates = [
                        name for name in files
                        if name in {
                            f"{bundle_name}/{manifest_name}",
                            f"{bundle_name}/Resources/{manifest_name}",
                            f"{bundle_name}/Contents/Resources/{manifest_name}",
                        }
                        or name.endswith(supported_manifest_suffixes)
                    ]
                    if len(candidates) != 1:
                        errors.append(
                            f"domain Theme budget inspection: {relative} must contain "
                            f"one {theme} shipping resource manifest"
                        )
                        continue
                    manifest_member = candidates[0]
                    manifest_bytes = archive.read(files[manifest_member])
                    source_path = repository_root / source_relative
                    if (
                        not repository_relative_file(source_relative, repository_root)
                        or manifest_bytes != source_path.read_bytes()
                    ):
                        errors.append(
                            f"domain Theme budget inspection: {platform} {theme} "
                            "resource manifest differs from current source"
                        )
                        continue
                    try:
                        manifest = json.loads(manifest_bytes)
                    except (UnicodeDecodeError, json.JSONDecodeError) as exception:
                        errors.append(
                            f"domain Theme budget inspection: {platform} {theme} "
                            f"manifest is invalid: {exception}"
                        )
                        continue
                    entries = manifest.get(entries_key) if isinstance(manifest, dict) else None
                    if not isinstance(entries, list) or not entries:
                        errors.append(
                            f"domain Theme budget inspection: {platform} {theme} "
                            "resource inventory is empty"
                        )
                        continue
                    bundle_prefix = manifest_member[: -len(manifest_name)]
                    resource_root = (
                        repository_root
                        / source_relative.split("/Resources/", 1)[0]
                        / "Resources"
                    )
                    expected_source_files: dict[str, Path] = {}
                    valid = True
                    for source_file in sorted(resource_root.rglob("*")):
                        if not source_file.is_file():
                            continue
                        source_parts = source_file.relative_to(resource_root).parts
                        if theme == "Norse" and source_parts and source_parts[0] == "Source":
                            continue
                        if source_file.name.startswith("."):
                            continue
                        if source_file.name in expected_source_files:
                            errors.append(
                                f"domain Theme budget inspection: {theme} shipping "
                                "resources have a flattened-name collision"
                            )
                            valid = False
                            continue
                        expected_source_files[source_file.name] = source_file
                    actual_bundle_members = {
                        name[len(bundle_prefix):]: name
                        for name in files
                        if name.startswith(bundle_prefix)
                        and name[len(bundle_prefix):]
                    }
                    allowed_packaging_members = {
                        "Info.plist",
                        "_CodeSignature/CodeDirectory",
                        "_CodeSignature/CodeRequirements",
                        "_CodeSignature/CodeResources",
                        "_CodeSignature/CodeSignature",
                    }
                    unexpected = (
                        set(actual_bundle_members)
                        - set(expected_source_files)
                        - allowed_packaging_members
                    )
                    missing = set(expected_source_files) - set(actual_bundle_members)
                    if unexpected or missing:
                        errors.append(
                            f"domain Theme budget inspection: {platform} {theme} complete "
                            f"bundle inventory differs; missing={sorted(missing)} "
                            f"unexpected={sorted(unexpected)}"
                        )
                        valid = False
                    for basename, source_file in expected_source_files.items():
                        member = actual_bundle_members.get(basename)
                        if member is None:
                            continue
                        if archive.read(files[member]) != source_file.read_bytes():
                            errors.append(
                                f"domain Theme budget inspection: {platform} {theme} "
                                f"bundle member differs from source: {basename}"
                            )
                            valid = False
                    seen_members: set[str] = set()
                    for entry_index, entry in enumerate(entries):
                        if not isinstance(entry, dict):
                            errors.append(
                                f"domain Theme budget inspection: {platform} {theme} "
                                f"resource {entry_index} is invalid"
                            )
                            valid = False
                            continue
                        resource_relative = entry.get("path")
                        expected_bytes = entry.get(bytes_key)
                        expected_digest = entry.get("sha256")
                        if (
                            not isinstance(resource_relative, str)
                            or not resource_relative
                            or type(expected_bytes) is not int
                            or expected_bytes <= 0
                            or not isinstance(expected_digest, str)
                            or HEX_64.fullmatch(expected_digest) is None
                        ):
                            errors.append(
                                f"domain Theme budget inspection: {platform} {theme} "
                                f"resource {entry_index} metadata is invalid"
                            )
                            valid = False
                            continue
                        member = bundle_prefix + PurePosixPath(resource_relative).name
                        if member in seen_members or member not in files:
                            errors.append(
                                f"domain Theme budget inspection: {platform} {theme} "
                                f"resource is missing or duplicated: {resource_relative}"
                            )
                            valid = False
                            continue
                        seen_members.add(member)
                        data = archive.read(files[member])
                        if (
                            len(data) != expected_bytes
                            or hashlib.sha256(data).hexdigest() != expected_digest
                        ):
                            errors.append(
                                f"domain Theme budget inspection: {platform} {theme} "
                                f"resource differs from its manifest: {resource_relative}"
                            )
                            valid = False
                            continue
                    if not valid:
                        continue
                    physical_members = [
                        files[name] for name in actual_bundle_members.values()
                    ]
                    total = sum(info.file_size for info in physical_members)
                    largest = max(
                        (info.file_size for info in physical_members), default=0
                    )
                    static_bytes = sum(
                        files[member].file_size
                        for basename, member in actual_bundle_members.items()
                        if PurePosixPath(basename).suffix.lower()
                        in {".png", ".heif", ".pdf"}
                    )
                    font_bytes = sum(
                        files[member].file_size
                        for basename, member in actual_bundle_members.items()
                        if PurePosixPath(basename).suffix.lower() in {".ttf", ".otf"}
                    )
                    animation_names = {
                        PurePosixPath(str(entry.get("path"))).name
                        for entry in entries if isinstance(entry, dict)
                        if (
                            str(entry.get("semanticRole", entry.get("role", "")))
                            == "unlock-animation-cue"
                            or "animation" in str(
                                entry.get("semanticRole", entry.get("role", ""))
                            )
                        )
                    }
                    animation_bytes = sum(
                        files[member].file_size
                        for basename, member in actual_bundle_members.items()
                        if basename in animation_names
                    )
                    sound_bytes = sum(
                        files[member].file_size
                        for basename, member in actual_bundle_members.items()
                        if PurePosixPath(basename).suffix.lower()
                        in {".wav", ".caf", ".m4a"}
                    )
                    limits = {
                        "uniquePhysicalBytes": 64 * 1024 * 1024,
                        "largestResourceBytes": 8 * 1024 * 1024,
                        "staticImageBytes": 32 * 1024 * 1024,
                        "fontBytes": 16 * 1024 * 1024,
                        "animationBytes": 16 * 1024 * 1024,
                        "soundBytes": 8 * 1024 * 1024,
                    }
                    observed = {
                        "uniquePhysicalBytes": total,
                        "largestResourceBytes": largest,
                        "staticImageBytes": static_bytes,
                        "fontBytes": font_bytes,
                        "animationBytes": animation_bytes,
                        "soundBytes": sound_bytes,
                    }
                    if any(observed[key] > limits[key] for key in limits):
                        errors.append(
                            f"domain Theme budget inspection: {platform} {theme} budget fails"
                        )
                        continue
                    results.append({
                        "platform": platform,
                        "theme": theme,
                        "manifestPath": manifest_member,
                        "manifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
                        "sourceManifestPath": source_relative,
                        "resourceCount": len(actual_bundle_members),
                        "observed": observed,
                        "limits": limits,
                        "result": "PASS",
                    })
        except (
            OSError, KeyError, RuntimeError, zipfile.BadZipFile, ValueError,
        ) as exception:
            errors.append(
                f"domain Theme budget inspection failed for {relative}: {exception}"
            )
    return errors, results


def expected_domain_execution(
    repository_root: Path,
    identifier: str,
    source_relative: str,
) -> tuple[list[str], dict[str, Any]]:
    if not repository_relative_file(source_relative, repository_root):
        return [f"domain execution source is missing: {source_relative}"], {}
    test_filter = (
        "^" + re.escape(identifier) + "$" if "/" in identifier else identifier
    )
    command = shlex.join([
        "swift", "test", "--package-path", DOMAIN_PACKAGE_PATH,
        "--scratch-path", DOMAIN_SCRATCH_TOKEN, "--skip-update", "--skip-build",
        "--filter", test_filter,
    ])
    return [], {
        "identifier": identifier,
        "framework": "XCTest" if "/" in identifier else "Swift Testing",
        "command": command,
        "exitStatus": 0,
        "observedTestCount": 1,
        "result": "PASS",
        "sourcePath": source_relative,
        "sourceSHA256": sha256_file(repository_root / source_relative),
    }


def expected_domain_executions(
    repository_root: Path,
    sources: dict[str, str],
) -> tuple[list[str], list[dict[str, Any]]]:
    errors: list[str] = []
    results: list[dict[str, Any]] = []
    for identifier, source_relative in sources.items():
        execution_errors, execution = expected_domain_execution(
            repository_root, identifier, source_relative
        )
        errors.extend(execution_errors)
        if execution:
            results.append(execution)
    return errors, results


def expected_domain_cases(
    mapping: dict[str, tuple[str, ...]],
    test_ids: tuple[str, ...],
    *,
    built_inspection: bool,
) -> list[dict[str, Any]]:
    return [
        {
            "marker": marker,
            "result": "PASS",
            "testIDs": list(test_ids),
            "executedTests": list(identifiers),
            "artifacts": (
                [BUILT_PRODUCT_INSPECTION_RESULTS]
                if built_inspection and not identifiers else []
            ),
        }
        for marker, identifiers in mapping.items()
    ]


def validate_domain_result_report(
    repository_root: Path,
    *,
    relative: str,
    source_hash: str,
    source_revision: str | None,
    expected_test_ids: tuple[str, ...],
    expected_markers: tuple[str, ...],
    suite_results: dict[str, dict[str, Any]],
    executions: dict[str, dict[str, Any]],
    performance: bool,
) -> tuple[list[str], dict[str, Any]]:
    errors: list[str] = []
    try:
        document = load_json(repository_root / relative)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return [f"{relative}: invalid or missing domain result: {exception}"], {}
    common_keys = {
        "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
        "version", "build", "testIDs", "semanticMarkers", "cases",
        "rawLog", "rawLogSHA256", "producer", "executions",
    }
    required_keys = common_keys | ({"metrics"} if performance else {"builtInspection"})
    if not isinstance(document, dict) or set(document) != required_keys:
        return [f"{relative}: keys differ from its locked result schema"], {}
    expected_scalars: dict[str, object] = {
        "schemaVersion": "1.0", "status": "PASS",
        "sourceManifestSHA256": source_hash, "sourceRevision": source_revision,
        "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
        "testIDs": list(expected_test_ids),
        "semanticMarkers": list(expected_markers),
    }
    for key, expected in expected_scalars.items():
        if document.get(key) != expected:
            errors.append(f"{relative}.{key} differs")
    expected_producer = {
        "path": DOMAIN_RESULT_PRODUCER,
        "sha256": EXPECTED_DOMAIN_PRODUCER_SHA256,
    }
    if repository_relative_file(DOMAIN_RESULT_PRODUCER, repository_root):
        if sha256_file(repository_root / DOMAIN_RESULT_PRODUCER) != (
            EXPECTED_DOMAIN_PRODUCER_SHA256
        ):
            errors.append(
                f"{relative}.producer source differs from the locked executable"
            )
    else:
        errors.append(f"{relative}.producer is missing or unsafe")
    if document.get("producer") != expected_producer:
        errors.append(f"{relative}.producer differs from the bound executable producer")
    if any(test_id not in executions for test_id in expected_test_ids):
        errors.append(f"{relative}: locked test executions are missing")
        return errors, document
    raw_log = document.get("rawLog")
    raw_text = ""
    if not isinstance(raw_log, str) or not repository_relative_file(raw_log, repository_root):
        errors.append(f"{relative}.rawLog is missing or unsafe")
    else:
        raw_path = repository_root / raw_log
        if document.get("rawLogSHA256") != sha256_file(raw_path):
            errors.append(f"{relative}.rawLogSHA256 differs")
        raw_text = read_bounded_text(raw_path)
        expected_raw_logs = {
            suite_results.get(str(executions[test_id].get("suiteName")), {}).get("rawLog")
            for test_id in expected_test_ids
        }
        if expected_raw_logs != {raw_log}:
            errors.append(f"{relative}.rawLog differs from its exact test suites")
    domain_sources = (
        DOMAIN_PERFORMANCE_TEST_SOURCES if performance else DOMAIN_CLOUD_TEST_SOURCES
    )
    execution_errors, expected_execution_records = expected_domain_executions(
        repository_root, domain_sources
    )
    errors.extend(execution_errors)
    execution_records = document.get("executions")
    if execution_records != expected_execution_records:
        errors.append(
            f"{relative}.executions differ from exact source-bound Swift test executions"
        )
    case_mapping = (
        DOMAIN_PERFORMANCE_CASE_TESTS if performance else DOMAIN_CLOUD_CASE_TESTS
    )
    expected_case_records = expected_domain_cases(
        case_mapping,
        expected_test_ids,
        built_inspection=not performance,
    )
    if document.get("cases") != expected_case_records:
        errors.append(
            f"{relative}.cases differ from exact executed-test/artifact bindings"
        )
    if performance:
        metrics = document.get("metrics")
        if not isinstance(metrics, dict) or set(metrics) != {
            "preview", "themeResourceBudgets"
        }:
            errors.append(f"{relative}.metrics keys differ")
        else:
            preview = metrics.get("preview")
            if (
                not isinstance(preview, dict)
                or set(preview) != {
                    "schemaVersion", "testIdentifier", "previewBytes",
                    "previewWidthPixels", "previewHeightPixels",
                }
                or preview.get("schemaVersion") != "1.0"
                or preview.get("testIdentifier") != DOMAIN_PREVIEW_TEST
                or any(type(preview.get(key)) is not int for key in (
                    "previewBytes", "previewWidthPixels", "previewHeightPixels"
                ))
            ):
                errors.append(f"{relative}.metrics.preview schema differs")
            else:
                preview_bytes = preview["previewBytes"]
                width = preview["previewWidthPixels"]
                height = preview["previewHeightPixels"]
                if not 0 < preview_bytes < 4 * 1024 * 1024:
                    errors.append(f"{relative}.metrics.preview byte budget fails")
                if width <= 0 or height <= 0 or width * 3 != height * 4:
                    errors.append(f"{relative}.metrics.preview dimensions are not exact 4:3")
            budget_errors, expected_budgets = derive_domain_theme_budgets(
                repository_root
            )
            errors.extend(budget_errors)
            if metrics.get("themeResourceBudgets") != expected_budgets:
                errors.append(
                    f"{relative}.metrics.themeResourceBudgets differ from app ZIP bytes"
                )
    else:
        products: list[dict[str, Any]] = []
        for platform, product_path in DOMAIN_APP_PRODUCTS:
            product_errors, product = derive_domain_product_inspection(
                repository_root, platform, product_path
            )
            errors.extend(product_errors)
            if product:
                products.append(product)
        shipping_errors, shipping_validation = validate_shipping_validation_log(
            repository_root
        )
        errors.extend(shipping_errors)
        inspection_document: object = None
        inspection_path = repository_root / BUILT_PRODUCT_INSPECTION_RESULTS
        try:
            inspection_document = load_json(inspection_path)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
            errors.append(
                f"{BUILT_PRODUCT_INSPECTION_RESULTS}: invalid or missing: {exception}"
            )
        inspection_keys = {
            "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
            "version", "build", "rawLog", "rawLogSHA256", "producer", "products",
            "shippingValidation",
        }
        expected_inspection_document = {
            "schemaVersion": "1.0", "status": "PASS",
            "sourceManifestSHA256": source_hash,
            "sourceRevision": source_revision,
            "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
            "rawLog": raw_log,
            "rawLogSHA256": (
                sha256_file(repository_root / raw_log)
                if isinstance(raw_log, str)
                and repository_relative_file(raw_log, repository_root)
                else None
            ),
            "producer": expected_producer,
            "products": products,
            "shippingValidation": shipping_validation,
        }
        if (
            not isinstance(inspection_document, dict)
            or set(inspection_document) != inspection_keys
            or inspection_document != expected_inspection_document
        ):
            errors.append(
                f"{BUILT_PRODUCT_INSPECTION_RESULTS}: differs from exact app ZIP inspection"
            )
        inspection_digest = (
            sha256_file(inspection_path)
            if repository_relative_file(BUILT_PRODUCT_INSPECTION_RESULTS, repository_root)
            else ""
        )
        expected_inspection = {
            "result": "PASS",
            "record": BUILT_PRODUCT_INSPECTION_RESULTS,
            "recordSHA256": inspection_digest,
            "products": products,
        }
        if document.get("builtInspection") != expected_inspection:
            errors.append(
                f"{relative}.builtInspection differs from independently inspected app ZIPs"
            )
        for test_id in expected_test_ids:
            evidence = executions[test_id].get("evidence")
            if (
                not isinstance(evidence, list)
                or BUILT_PRODUCT_INSPECTION_RESULTS not in evidence
            ):
                errors.append(
                    f"{test_id} does not bind exact built-product inspection record"
                )
    for test_id in expected_test_ids:
        evidence = executions[test_id].get("evidence")
        if not isinstance(evidence, list) or relative not in evidence:
            errors.append(f"{test_id} does not bind exact domain result {relative}")
    return errors, document


def validate_domain_execution_log(
    repository_root: Path,
    cloud_document: dict[str, Any],
    performance_document: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    raw_log = cloud_document.get("rawLog")
    if (
        not isinstance(raw_log, str)
        or raw_log != performance_document.get("rawLog")
        or not repository_relative_file(raw_log, repository_root)
    ):
        return ["domain result reports do not share one safe raw execution log"]
    raw_path = repository_root / raw_log
    try:
        raw_text = raw_path.read_text(encoding="utf-8", errors="strict")
    except (OSError, UnicodeDecodeError) as exception:
        return [f"domain execution log is unreadable: {exception}"]
    raw_digest = sha256_file(raw_path)
    if (
        cloud_document.get("rawLogSHA256") != raw_digest
        or performance_document.get("rawLogSHA256") != raw_digest
    ):
        errors.append("domain result reports do not bind the exact shared raw log")
    boundary = "DOMAIN_EXECUTION_LOG schemaVersion=1.0\n"
    if "\r" in raw_text or raw_text.count(boundary) != 1:
        return errors + [
            "domain execution log must contain one exact normalized execution boundary"
        ]
    prefix, _ = raw_text.split(boundary, 1)
    reserved_prefixes = (
        "domainExecution=", "semanticCase=", "previewMeasurement=",
        "themeBudgetInspection=", "productInspection=", "shippingProductValidation=",
        "domainCaptureResult=",
        "semanticMarker=", "metric.",
    )
    if not prefix.endswith("\n") or any(
        line == boundary.rstrip("\n") or line.startswith(reserved_prefixes)
        for line in prefix.splitlines()
    ):
        errors.append("domain execution log suite prefix contains reserved evidence lines")
    cloud_executions = cloud_document.get("executions")
    performance_executions = performance_document.get("executions")
    cloud_cases = cloud_document.get("cases")
    performance_cases = performance_document.get("cases")
    metrics = performance_document.get("metrics")
    inspection = cloud_document.get("builtInspection")
    if not all(isinstance(value, list) for value in (
        cloud_executions, performance_executions, cloud_cases, performance_cases,
    )) or not isinstance(metrics, dict) or not isinstance(inspection, dict):
        return errors + ["domain execution log cannot derive its strict report inventory"]
    preview = metrics.get("preview")
    budgets = metrics.get("themeResourceBudgets")
    products = inspection.get("products")
    if not isinstance(preview, dict) or not isinstance(budgets, list) or not isinstance(
        products, list
    ):
        return errors + ["domain execution log report inventory is malformed"]
    shipping_errors, shipping_validation = validate_shipping_validation_log(
        repository_root
    )
    errors.extend(shipping_errors)
    try:
        inspection_document = load_json(
            repository_root / BUILT_PRODUCT_INSPECTION_RESULTS
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return errors + [f"built-product inspection is unreadable: {exception}"]
    if (
        not isinstance(inspection_document, dict)
        or inspection_document.get("shippingValidation") != shipping_validation
    ):
        errors.append(
            "built-product inspection shipping validation differs from the locked log"
        )
    expected_lines = [boundary.rstrip("\n")]
    expected_lines.extend(
        "domainExecution=" + canonical_json_line(item)
        for item in [*cloud_executions, *performance_executions]
    )
    expected_lines.extend(
        "semanticCase=" + canonical_json_line(item)
        for item in [*cloud_cases, *performance_cases]
    )
    expected_lines.append("previewMeasurement=" + canonical_json_line(preview))
    expected_lines.extend(
        "themeBudgetInspection=" + canonical_json_line(item) for item in budgets
    )
    expected_lines.extend(
        "productInspection=" + canonical_json_line(item) for item in products
    )
    expected_lines.append(
        "shippingProductValidation=" + canonical_json_line(shipping_validation)
    )
    expected_lines.append("domainCaptureResult=PASS")
    expected_tail = "\n".join(expected_lines) + "\n"
    if raw_text != prefix + expected_tail:
        errors.append(
            "domain execution log differs from exact execution/case/measurement inventory"
        )
    return errors


def validate_domain_capture_replay(
    repository_root: Path,
    manifest_path: Path,
    source_revision: str | None,
    cloud_document: dict[str, Any],
) -> list[str]:
    raw_log = cloud_document.get("rawLog")
    if not isinstance(raw_log, str) or not repository_relative_file(
        raw_log, repository_root
    ):
        return ["domain capture replay lacks one safe raw log"]
    producer = repository_root / DOMAIN_RESULT_PRODUCER
    if not producer.is_file() or producer.is_symlink():
        return ["domain capture replay producer is missing or unsafe"]
    if sha256_file(producer) != EXPECTED_DOMAIN_PRODUCER_SHA256:
        return ["domain capture replay producer differs from the locked executable"]
    shipping_checker = repository_root / SHIPPING_CHECKER_PATH
    if not shipping_checker.is_file() or shipping_checker.is_symlink():
        return ["domain capture replay shipping-product checker is missing or unsafe"]
    if sha256_file(shipping_checker) != EXPECTED_SHIPPING_CHECKER_SHA256:
        return [
            "domain capture replay shipping-product checker differs from the locked executable"
        ]
    command = [
        sys.executable, DOMAIN_RESULT_PRODUCER,
        "--root", str(repository_root),
        "--source-manifest", str(manifest_path),
        "--raw-output", str(repository_root / raw_log),
        "--macos-app-zip", str(repository_root / DOMAIN_APP_PRODUCTS[0][1]),
        "--ios-app-zip", str(repository_root / DOMAIN_APP_PRODUCTS[1][1]),
        "--cloud-output", str(repository_root / CLOUD_GAME_CENTER_RESULTS),
        "--performance-output", str(repository_root / PERFORMANCE_RESOURCE_RESULTS),
        "--inspection-output", str(repository_root / BUILT_PRODUCT_INSPECTION_RESULTS),
        "--shipping-output", str(repository_root / DOMAIN_SHIPPING_VALIDATION_LOG),
    ]
    if source_revision is not None:
        command.extend(["--source-revision", source_revision])
    command.append("--verify-only")
    try:
        result = subprocess.run(
            command,
            cwd=repository_root,
            check=False,
            capture_output=True,
            env={
                **os.environ,
                "PATH": LOCKED_SYSTEM_PATH,
                "LC_ALL": "C",
                "LANG": "C",
            },
            timeout=3600,
        )
    except (OSError, subprocess.TimeoutExpired) as exception:
        return [f"domain capture replay could not complete: {exception}"]
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).decode(
            "utf-8", errors="replace"
        ).strip()[-2000:]
        return [f"domain capture replay failed: {detail}"]
    errors: list[str] = []
    if result.stderr:
        errors.append("domain capture replay emitted unexpected stderr")
    if result.stdout != DOMAIN_REPLAY_OUTPUT:
        errors.append("domain capture replay output differs from the locked terminal line")
    return errors


def validate_no_git_qualification_document(
    repository_root: Path,
    source_hash: str,
    source_revision: str | None,
    executions: dict[str, dict[str, Any]],
) -> list[str]:
    relative = NO_GIT_QUALIFICATION_RESULT
    try:
        document = load_json(repository_root / relative)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return [f"{relative}: invalid or missing: {exception}"]
    if not isinstance(document, dict) or set(document) != NO_GIT_RESULT_KEYS:
        return [f"{relative}: keys differ from the no-Git result schema"]
    expected_command = (
        "python3 scripts/check-remediation-completion.py --no-git-child "
        f"--expected-source-hash {source_hash}"
    )
    expected: dict[str, object] = {
        "schemaVersion": "1.0", "status": "PASS",
        "sourceManifestSHA256": source_hash,
        "sourceRevision": source_revision,
        "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
        "testID": "T-006", "command": expected_command,
        "expectedOutput": NO_GIT_CHILD_OUTPUT,
        "expectedOutputSHA256": hashlib.sha256(
            NO_GIT_CHILD_OUTPUT.encode("utf-8")
        ).hexdigest(),
    }
    errors = [
        f"{relative}.{key} differs"
        for key, value in expected.items() if document.get(key) != value
    ]
    execution = executions.get("T-006", {})
    if execution.get("command") != expected_command:
        errors.append("T-006 command differs from the guarded copied-tree invocation")
    evidence = execution.get("evidence")
    if not isinstance(evidence, list) or relative not in evidence:
        errors.append(f"T-006 does not bind exact no-Git result {relative}")
    return errors


def validate_completion_checker_log(
    repository_root: Path,
    *,
    git_backed_source: bool,
) -> list[str]:
    relative = "docs/verification/remediation-v1/GateRun/check-remediation-completion.log"
    if not repository_relative_file(relative, repository_root):
        return [f"{relative}: missing or unsafe"]
    metadata = (
        "Git revision and source manifest"
        if git_backed_source else "source manifest without Git ancestry"
    )
    expected = (
        f"PASS: 42 required gates validate against one source tree ({metadata})\n"
    ).encode("utf-8")
    if (repository_root / relative).read_bytes() != expected:
        return [f"{relative}: content differs from the exact terminal checker result"]
    return []


def run_copied_tree_no_git_check(
    repository_root: Path,
    source_hash: str,
) -> list[str]:
    try:
        document = load_json(repository_root / NO_GIT_QUALIFICATION_RESULT)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return [f"copied-tree no-Git check lacks a valid result binding: {exception}"]
    expected_output = document.get("expectedOutput") if isinstance(document, dict) else None
    expected_digest = (
        document.get("expectedOutputSHA256") if isinstance(document, dict) else None
    )
    if expected_output != NO_GIT_CHILD_OUTPUT:
        return ["copied-tree no-Git expected output differs from the locked terminal line"]
    with tempfile.TemporaryDirectory(prefix="remediation-no-git-") as temporary:
        copied_root = Path(temporary) / "repository"
        try:
            shutil.copytree(
                repository_root,
                copied_root,
                symlinks=True,
                ignore=shutil.ignore_patterns(
                    ".git", ".build", ".swiftpm", "DerivedData", "__pycache__",
                    "*.pyc",
                ),
            )
        except OSError as exception:
            return [f"copied-tree no-Git setup failed: {exception}"]
        if (copied_root / ".git").exists() or git_available(copied_root):
            return ["copied-tree no-Git setup retained Git ancestry"]
        command = [
            "python3", "scripts/check-remediation-completion.py",
            "--no-git-child", "--expected-source-hash", source_hash,
        ]
        try:
            result = subprocess.run(
                command,
                cwd=copied_root,
                check=False,
                capture_output=True,
            )
        except OSError as exception:
            return [f"copied-tree no-Git checker could not execute: {exception}"]
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).decode("utf-8", errors="replace").strip()
        return [f"copied-tree no-Git checker failed: {detail}"]
    if result.stderr:
        return ["copied-tree no-Git checker emitted unexpected stderr"]
    if result.stdout != NO_GIT_CHILD_OUTPUT.encode("utf-8"):
        return ["copied-tree no-Git checker output differs from the locked terminal line"]
    actual_digest = hashlib.sha256(result.stdout).hexdigest()
    if expected_digest != actual_digest:
        return ["copied-tree no-Git checker output hash differs from its bound result"]
    return []


def validate_ipad_qualification_document(
    document: object,
    *,
    repository_root: Path,
    source_hash: str,
    source_revision: str | None,
    locked_rows: dict[str, dict[str, str]],
    executions: dict[str, dict[str, Any]],
    ios_product_digest: str,
    label: str = "iPad qualification",
) -> list[str]:
    errors: list[str] = []
    required_keys = {
        "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
        "version", "build", "simulator", "iOSProduct", "suites", "screenshots",
    }
    if not isinstance(document, dict) or set(document) != required_keys:
        return [f"{label}: keys differ from the qualification schema"]
    expected = {
        "schemaVersion": "1.0", "status": "PASS",
        "sourceManifestSHA256": source_hash, "sourceRevision": source_revision,
        "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
    }
    for key, value in expected.items():
        if document.get(key) != value:
            errors.append(f"{label}: {key} differs")
    simulator = document.get("simulator")
    if not isinstance(simulator, dict) or set(simulator) != {"name", "udid", "runtime"}:
        errors.append(f"{label}: simulator keys differ")
        simulator = {}
    elif (
        not all(isinstance(simulator.get(key), str) and simulator[key].strip()
                for key in ("name", "udid", "runtime"))
        or "ipad" not in simulator.get("name", "").lower()
        or "ios" not in simulator.get("runtime", "").lower()
        or re.fullmatch(
            r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
            simulator.get("udid", ""),
        ) is None
    ):
        errors.append(f"{label}: selected simulator identity is invalid")
    ipad_test_ids = {
        test_id for test_id, row in locked_rows.items()
        if row["platform"] == "iPad Simulator"
    }
    if ipad_test_ids != {"T-023", "T-114"}:
        errors.append(f"{label}: locked iPad test set differs")
    simulator_udid = simulator.get("udid") if isinstance(simulator, dict) else None
    if isinstance(simulator_udid, str):
        for test_id in sorted(ipad_test_ids):
            execution = executions.get(test_id, {})
            if simulator_udid not in str(execution.get("command", "")):
                errors.append(
                    f"{label}: {test_id} command is not bound to selected simulator {simulator_udid}"
                )
    product = document.get("iOSProduct")
    expected_product = {
        "path": "artifacts/remediation-v1/RuneScrib-iPhoneSimulator-Release.app.zip",
        "sha256": ios_product_digest,
        "bundleIdentifier": EXPECTED_BUNDLE_IDENTIFIER,
    }
    if not isinstance(product, dict) or product != expected_product:
        errors.append(f"{label}: iOSProduct differs from the validated iOS app ZIP")
    required_suites = {
        str(executions[test_id].get("suiteName"))
        for test_id in ipad_test_ids if test_id in executions
    }
    suites = document.get("suites")
    seen_suites: set[str] = set()
    if not isinstance(suites, list) or not suites:
        errors.append(f"{label}: suites must be nonempty")
        suites = []
    for index, suite in enumerate(suites):
        suite_label = f"{label}: suites[{index}]"
        suite_keys = {
            "name", "result", "executed", "passed", "failed", "skipped",
            "log", "logSHA256",
        }
        if not isinstance(suite, dict) or set(suite) != suite_keys:
            errors.append(f"{suite_label} keys differ")
            continue
        name = suite.get("name")
        if not isinstance(name, str) or not name or name in seen_suites:
            errors.append(f"{suite_label}.name is invalid or duplicate")
        else:
            seen_suites.add(name)
        counts = {key: suite.get(key) for key in ("executed", "passed", "failed", "skipped")}
        if (
            suite.get("result") != "PASS"
            or not all(type(counts[key]) is int and counts[key] >= 0 for key in counts)
            or counts.get("executed") != counts.get("passed")
            or counts.get("executed", 0) <= 0
            or counts.get("failed") != 0
            or counts.get("skipped") != 0
        ):
            errors.append(f"{suite_label}: PASS counts are invalid")
        log = suite.get("log")
        if not repository_relative_file(log, repository_root):
            errors.append(f"{suite_label}.log is missing or unsafe")
        elif suite.get("logSHA256") != sha256_file(repository_root / log):
            errors.append(f"{suite_label}.logSHA256 differs")
        if isinstance(name, str):
            expected_logs = {
                execution.get("log") for test_id, execution in executions.items()
                if test_id in ipad_test_ids and execution.get("suiteName") == name
            }
            if expected_logs and {log} != expected_logs:
                errors.append(f"{suite_label}.log differs from locked test executions")
    if not required_suites.issubset(seen_suites):
        errors.append(f"{label}: omits locked iPad test suites")
    required_screenshots = {
        f"docs/verification/remediation-v1/Screenshots/{locked_rows[test_id]['requiredEvidence']}"
        for test_id in ipad_test_ids
        if locked_rows[test_id]["requiredEvidence"].endswith(".png")
    }
    screenshots = document.get("screenshots")
    seen_screenshots: set[str] = set()
    if not isinstance(screenshots, list) or not screenshots:
        errors.append(f"{label}: screenshots must be nonempty")
        screenshots = []
    for index, screenshot in enumerate(screenshots):
        shot_label = f"{label}: screenshots[{index}]"
        if not isinstance(screenshot, dict) or set(screenshot) != {"path", "sha256"}:
            errors.append(f"{shot_label} keys differ")
            continue
        shot_path = screenshot.get("path")
        if not repository_relative_file(shot_path, repository_root) or shot_path in seen_screenshots:
            errors.append(f"{shot_label}.path is missing, unsafe, or duplicate")
            continue
        seen_screenshots.add(shot_path)
        errors.extend(validate_png_path(repository_root / shot_path, shot_label))
        if screenshot.get("sha256") != sha256_file(repository_root / shot_path):
            errors.append(f"{shot_label}.sha256 differs")
    if not required_screenshots.issubset(seen_screenshots):
        errors.append(f"{label}: omits exact locked iPad screenshots")
    return errors


def validate_test_summary(
    repository_root: Path,
    source_hash: str,
    source_revision: str | None,
    executions: dict[str, dict[str, Any]],
) -> list[str]:
    relative = "artifacts/remediation-v1/Test-Summary.json"
    path = repository_root / relative
    try:
        document = load_json(path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return [f"{relative}: invalid or missing: {exception}"]
    required_keys = {
        "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
        "version", "build", "totals", "suites",
    }
    errors: list[str] = []
    if not isinstance(document, dict) or set(document) != required_keys:
        return [f"{relative}: keys differ from the test-summary schema"]
    expected = {
        "schemaVersion": "1.0", "status": "PASS",
        "sourceManifestSHA256": source_hash, "sourceRevision": source_revision,
        "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
    }
    for key, value in expected.items():
        if document.get(key) != value:
            errors.append(f"{relative}: {key} differs")
    count_keys = {"executed", "passed", "failed", "skipped"}
    totals = document.get("totals")
    if (
        not isinstance(totals, dict) or set(totals) != count_keys
        or not all(type(totals.get(key)) is int and totals[key] >= 0 for key in count_keys)
        or totals.get("passed") + totals.get("failed") + totals.get("skipped")
            != totals.get("executed")
        or totals.get("failed") != 0 or totals.get("skipped") != 0
    ):
        errors.append(f"{relative}: PASS totals are invalid")
    suites = document.get("suites")
    seen: dict[str, dict[str, Any]] = {}
    aggregate = {key: 0 for key in count_keys}
    suite_keys = {
        "name", "platform", "kind", "executed", "passed", "failed", "skipped",
        "log", "logSHA256",
    }
    if not isinstance(suites, list) or not suites:
        errors.append(f"{relative}: suites must be nonempty")
        suites = []
    for index, suite in enumerate(suites):
        label = f"{relative}: suites[{index}]"
        if not isinstance(suite, dict) or set(suite) != suite_keys:
            errors.append(f"{label} keys differ")
            continue
        name = suite.get("name")
        if not isinstance(name, str) or not name or name in seen:
            errors.append(f"{label}.name is invalid or duplicate")
            continue
        seen[name] = suite
        valid_suite_counts = True
        for key in count_keys:
            value = suite.get(key)
            if type(value) is not int or value < 0:
                errors.append(f"{label}.{key} is invalid")
                valid_suite_counts = False
            else:
                aggregate[key] += value
        if (
            not valid_suite_counts
            or suite["passed"] + suite["failed"] + suite["skipped"]
                != suite["executed"]
            or suite.get("failed") != 0 or suite.get("skipped") != 0
            or suite.get("executed", 0) <= 0
        ):
            errors.append(f"{label}: PASS counts are inconsistent")
        for key in ("platform", "kind"):
            if not isinstance(suite.get(key), str) or not suite[key].strip():
                errors.append(f"{label}.{key} must be nonempty")
        log = suite.get("log")
        if not repository_relative_file(log, repository_root):
            errors.append(f"{label}.log is missing or unsafe")
        elif suite.get("logSHA256") != sha256_file(repository_root / log):
            errors.append(f"{label}.logSHA256 differs")
    if isinstance(totals, dict) and aggregate != totals:
        errors.append(f"{relative}: totals do not equal the suite aggregate")
    binding_counts = {
        suite_name: sum(
            execution.get("suiteName") == suite_name for execution in executions.values()
        )
        for suite_name in seen
    }
    if set(binding_counts) != {
        str(execution.get("suiteName")) for execution in executions.values()
    }:
        errors.append(f"{relative}: suite names differ from locked test executions")
    for suite_name, count in binding_counts.items():
        if seen[suite_name].get("executed", 0) < count:
            errors.append(
                f"{relative}: suite {suite_name!r} executed count is below {count} bindings"
            )
        expected_logs = {
            execution.get("log") for execution in executions.values()
            if execution.get("suiteName") == suite_name
        }
        if expected_logs != {seen[suite_name].get("log")}:
            errors.append(f"{relative}: suite {suite_name!r} log differs from executions")
    return errors


def validate_publication_audit_record(
    repository_root: Path,
    source_hash: str,
    source_revision: str | None,
    executions: dict[str, dict[str, Any]],
) -> list[str]:
    relative = EXPECTED_PUBLICATION_AUDIT
    path = repository_root / relative
    try:
        document = load_json(path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return [f"{relative}: invalid or missing publication audit: {exception}"]
    input_keys = {
        "command", "log", "checkedAt", "branch", "defaultBranch",
        "remoteInspectionPerformed", "headTags", "sourceMergedToDefault",
        "releasePublished", "uploadPerformed", "notarizationPerformed",
        "testFlightPerformed", "appStorePerformed", "rolloutPerformed",
    }
    required_keys = input_keys | {
        "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision",
        "version", "build", "logSHA256",
    }
    errors: list[str] = []
    if not isinstance(document, dict) or set(document) != required_keys:
        return [f"{relative}: keys differ from the publication-audit schema"]
    expected = {
        "schemaVersion": "1.0", "status": "PASS",
        "sourceManifestSHA256": source_hash, "sourceRevision": source_revision,
        "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
        "remoteInspectionPerformed": True, "headTags": [],
        "sourceMergedToDefault": False, "releasePublished": False,
        "uploadPerformed": False, "notarizationPerformed": False,
        "testFlightPerformed": False, "appStorePerformed": False,
        "rolloutPerformed": False,
    }
    for key, value in expected.items():
        if document.get(key) != value:
            errors.append(f"{relative}: {key} differs")
    command = document.get("command")
    if not isinstance(command, str) or not command.strip() or "\n" in command:
        errors.append(f"{relative}: command must be exact nonempty single-line text")
    checked_at = valid_timestamp(document.get("checkedAt"))
    if checked_at is None or checked_at.tzinfo is None:
        errors.append(f"{relative}: checkedAt must be timezone-aware ISO-8601")
    branch = document.get("branch")
    default_branch = document.get("defaultBranch")
    if git_available(repository_root):
        if branch != current_git_branch(repository_root):
            errors.append(f"{relative}: branch differs from the current Git branch")
    elif NO_GIT_CHILD_MODE:
        if (
            not isinstance(branch, str)
            or not branch
            or len(branch) > 200
        ):
            errors.append(f"{relative}: copied-tree branch is invalid")
    elif branch is not None:
        errors.append(f"{relative}: branch must be null without Git")
    if (
        not isinstance(default_branch, str) or not default_branch
        or branch == default_branch
    ):
        errors.append(f"{relative}: defaultBranch is invalid or is the current branch")
    log = document.get("log")
    log_text = ""
    if not repository_relative_file(log, repository_root):
        errors.append(f"{relative}: publication inspection log is missing or unsafe")
    else:
        log_path = repository_root / log
        if document.get("logSHA256") != sha256_file(log_path):
            errors.append(f"{relative}: logSHA256 differs")
        log_text = read_bounded_text(log_path)
    required_markers = {
        "PUBLICATION_AUDIT_PASS", "REMOTE_INSPECTION_PERFORMED=true",
        "HEAD_TAGS=NONE", "SOURCE_MERGED_TO_DEFAULT=false",
        "RELEASE_PUBLISHED=false", "UPLOAD_PERFORMED=false",
        "NOTARIZATION_PERFORMED=false", "TESTFLIGHT_PERFORMED=false",
        "APPSTORE_PERFORMED=false", "ROLLOUT_PERFORMED=false",
    }
    if isinstance(branch, str):
        required_markers.add(branch)
    if isinstance(default_branch, str):
        required_markers.add(default_branch)
    if source_revision is not None:
        required_markers.add(source_revision)
    missing_markers = sorted(marker for marker in required_markers if marker not in log_text)
    if missing_markers:
        errors.append(f"{relative}: publication log omits: " + ", ".join(missing_markers))
    t121 = executions.get("T-121", {})
    if t121.get("command") != command:
        errors.append(f"{relative}: T-121 command differs from the audit command")
    evidence = t121.get("evidence")
    if not isinstance(evidence, list) or relative not in evidence or log not in evidence:
        errors.append(f"{relative}: T-121 does not bind the audit record and log")
    if source_revision is not None and git_available(repository_root):
        tag_result = subprocess.run(
            ["git", "tag", "--points-at", source_revision],
            cwd=repository_root, check=False, capture_output=True, text=True,
        )
        if tag_result.returncode != 0 or tag_result.stdout.strip():
            errors.append(f"{relative}: source revision is tagged or tag inspection failed")
        if isinstance(default_branch, str):
            refs = (f"refs/remotes/origin/{default_branch}", default_branch)
            resolved = next((ref for ref in refs if subprocess.run(
                ["git", "rev-parse", "--verify", ref], cwd=repository_root,
                check=False, capture_output=True,
            ).returncode == 0), None)
            if resolved is None:
                errors.append(f"{relative}: default branch cannot be resolved locally")
            else:
                merge_result = subprocess.run(
                    ["git", "merge-base", "--is-ancestor", source_revision, resolved],
                    cwd=repository_root, check=False, capture_output=True,
                )
                if merge_result.returncode == 0:
                    errors.append(f"{relative}: source revision is already merged to default")
                elif merge_result.returncode != 1:
                    errors.append(f"{relative}: default-branch merge inspection failed")
    return errors


def current_git_branch(repository_root: Path) -> str | None:
    result = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=repository_root,
        check=False,
        capture_output=True,
        text=True,
    )
    branch = result.stdout.strip()
    return branch if result.returncode == 0 and branch else None


def parse_sha256sums(text: str, label: str) -> tuple[dict[str, str], list[str]]:
    checksums: dict[str, str] = {}
    errors: list[str] = []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip():
            continue
        match = re.fullmatch(r"([0-9a-f]{64})[ \t]+\*?(.+)", raw_line)
        if match is None:
            errors.append(f"{label}: malformed SHA256SUMS line {line_number}")
            continue
        digest, name = match.groups()
        name = name.strip()
        relative = PurePosixPath(name)
        if (
            not name
            or relative.is_absolute()
            or ".." in relative.parts
            or "\\" in name
            or "\0" in name
            or name in checksums
        ):
            errors.append(f"{label}: unsafe or duplicate SHA256SUMS path on line {line_number}")
            continue
        checksums[name] = digest
    if not checksums:
        errors.append(f"{label}: SHA256SUMS is empty")
    return checksums, errors


def safe_zip_files(
    archive: zipfile.ZipFile,
    label: str,
) -> tuple[dict[str, zipfile.ZipInfo], list[str]]:
    files: dict[str, zipfile.ZipInfo] = {}
    errors: list[str] = []
    for info in archive.infolist():
        name = info.filename
        relative = PurePosixPath(name)
        unix_mode = (info.external_attr >> 16) & 0xFFFF
        if (
            not name
            or relative.is_absolute()
            or ".." in relative.parts
            or "\\" in name
            or "\0" in name
            or stat.S_ISLNK(unix_mode)
        ):
            errors.append(f"{label}: unsafe ZIP member {name!r}")
            continue
        normalized = relative.as_posix().rstrip("/")
        if not normalized or info.is_dir():
            continue
        file_type = unix_mode & 0o170000
        if file_type not in {0, stat.S_IFREG}:
            errors.append(f"{label}: non-regular ZIP member {normalized}")
            continue
        if normalized in files:
            errors.append(f"{label}: duplicate ZIP member {normalized}")
            continue
        files[normalized] = info
    return files, errors


def validate_app_zip(
    data: bytes,
    platform: str,
    label: str,
    bundle_identifier: str = EXPECTED_BUNDLE_IDENTIFIER,
) -> list[str]:
    errors: list[str] = []
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            files, zip_errors = safe_zip_files(archive, label)
            errors.extend(zip_errors)
            corrupt = archive.testzip()
            if corrupt is not None:
                errors.append(f"{label}: corrupt nested app ZIP member {corrupt}")
            if platform == "macOS":
                candidates = [
                    name for name in files
                    if re.search(r"\.app/Contents/Info\.plist$", name)
                ]
            else:
                candidates = [
                    name for name in files
                    if re.search(r"\.app/Info\.plist$", name)
                    and "/Contents/" not in name
                ]
            if len(candidates) != 1:
                errors.append(f"{label}: expected exactly one {platform} app Info.plist")
                return errors
            info_name = candidates[0].rstrip("/")
            app_match = re.match(r"^(.+\.app)(?:/|$)", info_name)
            if app_match is None:
                errors.append(f"{label}: app Info.plist has no canonical app root")
                return errors
            app_root = app_match.group(1)
            if PurePosixPath(app_root).name != "RuneScrib.app":
                errors.append(f"{label}: app root is not RuneScrib.app")
                return errors
            app_roots = {
                match.group(1)
                for name in files
                if (match := re.match(r"^(.+?\.app)(?:/|$)", name)) is not None
            }
            if app_roots != {app_root} or any(
                not name.startswith(app_root + "/") for name in files
            ):
                errors.append(f"{label}: ZIP must contain one safe app root only")
                return errors
            try:
                plist = plistlib.loads(archive.read(files[candidates[0]]))
            except (KeyError, plistlib.InvalidFileException, ValueError) as exception:
                errors.append(f"{label}: invalid app Info.plist: {exception}")
                return errors
            if not isinstance(plist, dict):
                errors.append(f"{label}: app Info.plist root must be a dictionary")
            else:
                if plist.get("CFBundleShortVersionString") != EXPECTED_VERSION:
                    errors.append(f"{label}: built app marketing version differs")
                if str(plist.get("CFBundleVersion")) != EXPECTED_BUILD:
                    errors.append(f"{label}: built app build differs")
                if plist.get("CFBundleIdentifier") != bundle_identifier:
                    errors.append(f"{label}: built app bundle identifier differs")
                if plist.get("CFBundlePackageType") != "APPL":
                    errors.append(f"{label}: CFBundlePackageType must be APPL")
                executable = plist.get("CFBundleExecutable")
                if (
                    not isinstance(executable, str)
                    or not executable
                    or "/" in executable
                    or "\\" in executable
                ):
                    errors.append(f"{label}: CFBundleExecutable is invalid")
                    return errors
                executable_path = (
                    f"{app_root}/Contents/MacOS/{executable}"
                    if platform == "macOS"
                    else f"{app_root}/{executable}"
                )
                executable_info = files.get(executable_path)
                if executable_info is None:
                    errors.append(f"{label}: declared executable is missing")
                    return errors
                executable_mode = (executable_info.external_attr >> 16) & 0xFFFF
                if executable_info.file_size < 28 or not executable_mode & 0o111:
                    errors.append(f"{label}: declared executable is empty or not executable")
                else:
                    magic = archive.read(executable_info)[:4]
                    if magic not in MACHO_MAGICS:
                        errors.append(f"{label}: declared executable is not Mach-O")
                if platform == "macOS":
                    resource_prefix = f"{app_root}/Contents/Resources/"
                    if not any(
                        name.startswith(resource_prefix) and info.file_size > 0
                        for name, info in files.items()
                    ):
                        errors.append(f"{label}: app has no nonempty Resources member")
                else:
                    supported = plist.get("CFBundleSupportedPlatforms")
                    if not isinstance(supported, list) or "iPhoneSimulator" not in supported:
                        errors.append(f"{label}: app is not an iPhoneSimulator product")
                    non_resources = {
                        info_name, executable_path, f"{app_root}/PkgInfo",
                    }
                    if not any(
                        name not in non_resources and info.file_size > 0
                        for name, info in files.items()
                    ):
                        errors.append(f"{label}: app has no nonempty resource")
    except (OSError, KeyError, RuntimeError, zipfile.BadZipFile) as exception:
        errors.append(f"{label}: invalid nested app ZIP: {exception}")
    return errors


def checksum_for_member(
    checksums: dict[str, str],
    member_name: str,
) -> str | None:
    matches = [
        digest for name, digest in checksums.items()
        if name == member_name or PurePosixPath(name).name == PurePosixPath(member_name).name
    ]
    return matches[0] if len(matches) == 1 else None


def validate_deterministic_zip(
    archive: zipfile.ZipFile,
    files: dict[str, zipfile.ZipInfo],
    label: str,
) -> list[str]:
    errors: list[str] = []
    ordered = [info.filename.rstrip("/") for info in archive.infolist() if not info.is_dir()]
    if ordered != sorted(ordered):
        errors.append(f"{label}: members are not in deterministic sorted order")
    for name, info in files.items():
        mode = (info.external_attr >> 16) & 0xFFFF
        if info.date_time != (1980, 1, 1, 0, 0, 0):
            errors.append(f"{label}: {name} has a nondeterministic timestamp")
        if mode != 0o100644:
            errors.append(f"{label}: {name} has a nondeterministic mode")
        if info.compress_type != zipfile.ZIP_STORED:
            errors.append(f"{label}: {name} has a nondeterministic compression method")
    return errors


def validate_exact_archive_checksums(
    archive: zipfile.ZipFile,
    files: dict[str, zipfile.ZipInfo],
    label: str,
) -> list[str]:
    errors: list[str] = []
    sums_info = files.get("SHA256SUMS")
    if sums_info is None:
        return [f"{label}: SHA256SUMS is missing"]
    try:
        sums_text = archive.read(sums_info).decode("utf-8")
    except (KeyError, UnicodeDecodeError) as exception:
        return [f"{label}: SHA256SUMS is unreadable: {exception}"]
    checksums, parse_errors = parse_sha256sums(sums_text, f"{label} SHA256SUMS")
    errors.extend(parse_errors)
    expected_names = set(files) - {"SHA256SUMS"}
    if set(checksums) != expected_names:
        errors.append(f"{label}: SHA256SUMS must exactly enumerate every other member")
    for name in sorted(expected_names & set(checksums)):
        actual = hashlib.sha256(archive.read(files[name])).hexdigest()
        if checksums[name] != actual:
            errors.append(f"{label}: checksum differs for {name}")
    return errors


def validate_internal_completion_report(
    document: object,
    *,
    payload_digest: str,
    source_hash: str,
    source_revision: str | None,
    branch: str | None,
    label: str,
) -> list[str]:
    errors: list[str] = []
    required = {
        "schemaVersion", "status", "sourceManifestSHA256", "sourceRevision", "branch",
        "version", "build", "requiredGateCount", "passedGateCount", "failedGateCount",
        "findingClosures", "platformQualification", "ownerTestPackage",
        "physicalHardwareRequired", "liveAccountsRequired",
        "publicDistributionPerformed", "attributionAudit", "nonGatingExternal",
    }
    if not isinstance(document, dict) or set(document) != required:
        return [f"{label}: keys differ from the completion-report schema"]
    expected = {
        "schemaVersion": "1.0", "status": "RELEASE_CANDIDATE_READY",
        "sourceManifestSHA256": source_hash, "sourceRevision": source_revision,
        "branch": branch,
        "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
        "requiredGateCount": 42, "passedGateCount": 42, "failedGateCount": 0,
        "platformQualification": {
            "macOS": "PASS", "iPhoneSimulator": "PASS", "iPadSimulator": "PASS",
        },
        "ownerTestPackage": {
            "path": "Rune-Scribe-Owner-Test-Payload-v1.0.zip",
            "sha256": payload_digest,
        },
        "physicalHardwareRequired": False, "liveAccountsRequired": False,
        "publicDistributionPerformed": False, "attributionAudit": "PASS",
    }
    for key, value in expected.items():
        if document.get(key) != value:
            errors.append(f"{label}: {key} differs")
    for key in ("requiredGateCount", "passedGateCount", "failedGateCount"):
        if type(document.get(key)) is not int:
            errors.append(f"{label}: {key} must be an integer")
    for key in (
        "physicalHardwareRequired", "liveAccountsRequired", "publicDistributionPerformed",
    ):
        if type(document.get(key)) is not bool:
            errors.append(f"{label}: {key} must be Boolean")
    closures = document.get("findingClosures")
    seen: set[str] = set()
    if not isinstance(closures, list) or len(closures) != 12:
        errors.append(f"{label}: findingClosures must contain exactly 12 items")
    else:
        for index, closure in enumerate(closures):
            closure_label = f"{label}: findingClosures[{index}]"
            if not isinstance(closure, dict) or set(closure) != {
                "id", "status", "gateIDs", "evidence",
            }:
                errors.append(f"{closure_label} keys differ")
                continue
            finding_id = closure.get("id")
            if finding_id not in EXPECTED_FINDING_IDS or finding_id in seen:
                errors.append(f"{closure_label} has an invalid or duplicate ID")
                continue
            seen.add(finding_id)
            if closure.get("status") != "CLOSED":
                errors.append(f"{closure_label}.status must be CLOSED")
            if set(closure.get("gateIDs", [])) != EXPECTED_FINDING_GATES[finding_id]:
                errors.append(f"{closure_label}.gateIDs differ")
            evidence = unique_string_array(closure.get("evidence"))
            if evidence is None:
                errors.append(f"{closure_label}.evidence is invalid")
        if seen != EXPECTED_FINDING_IDS:
            errors.append(f"{label}: finding closure IDs differ")
    external = unique_string_array(document.get("nonGatingExternal"))
    if external != list(FIXED_NON_GATING_BOUNDARIES):
        errors.append(f"{label}: nonGatingExternal differs from the completion schema")
    branch = document.get("branch")
    if branch is not None and (not isinstance(branch, str) or not branch or len(branch) > 200):
        errors.append(f"{label}: branch is invalid")
    return errors


def validate_owner_package(
    owner_path: Path,
    repository_root: Path,
    source_hash: str,
    source_revision: str | None,
    source_branch: str | None,
    locked_rows: dict[str, dict[str, str]],
    executions: dict[str, dict[str, Any]],
) -> list[str]:
    label = "owner-test package"
    errors: list[str] = []
    try:
        with zipfile.ZipFile(owner_path) as archive:
            files, zip_errors = safe_zip_files(archive, label)
            errors.extend(zip_errors)
            corrupt = archive.testzip()
            if corrupt is not None:
                errors.append(f"{label}: corrupt ZIP member {corrupt}")
            if set(files) != REQUIRED_ENVELOPE_BASENAMES:
                errors.append(f"{label}: outer envelope members differ from the locked layout")
                return errors
            errors.extend(validate_deterministic_zip(archive, files, label))
            errors.extend(validate_exact_archive_checksums(archive, files, label))
            payload_name = "Rune-Scribe-Owner-Test-Payload-v1.0.zip"
            payload_data = archive.read(files[payload_name])
            payload_digest = hashlib.sha256(payload_data).hexdigest()
            external_payload = repository_root / EXPECTED_PAYLOAD_PACKAGE
            if not external_payload.is_file() or external_payload.is_symlink():
                errors.append(f"{label}: external payload sidecar is missing")
            elif payload_data != external_payload.read_bytes():
                errors.append(f"{label}: nested and external payload bytes differ")
            try:
                internal_completion = json.loads(
                    archive.read(files["CompletionReport.json"]).decode("utf-8")
                )
            except (UnicodeDecodeError, json.JSONDecodeError) as exception:
                errors.append(f"{label}: internal CompletionReport.json is invalid: {exception}")
                internal_completion = {}
            errors.extend(validate_internal_completion_report(
                internal_completion,
                payload_digest=payload_digest,
                source_hash=source_hash,
                source_revision=source_revision,
                branch=source_branch,
                label=f"{label} internal CompletionReport.json",
            ))
            internal_markdown = archive.read(files["CompletionReport.md"]).decode(
                "utf-8", errors="replace"
            )
            for required in (
                "RELEASE_CANDIDATE_READY", payload_name, payload_digest,
                f"All required remediation gates passed against SOURCE-MANIFEST {source_hash}.",
            ):
                if required not in internal_markdown:
                    errors.append(f"{label}: internal CompletionReport.md omits {required}")
            errors.extend(markdown_contradiction_errors(
                internal_markdown, f"{label} internal CompletionReport.md"
            ))
            readme = archive.read(files["README.md"]).decode("utf-8", errors="replace")
            if payload_name not in readme or "SHA256SUMS" not in readme:
                errors.append(f"{label}: envelope README omits payload verification guidance")

            try:
                with zipfile.ZipFile(io.BytesIO(payload_data)) as payload:
                    payload_files, payload_zip_errors = safe_zip_files(
                        payload, f"{label} payload"
                    )
                    errors.extend(payload_zip_errors)
                    corrupt_payload = payload.testzip()
                    if corrupt_payload is not None:
                        errors.append(f"{label}: corrupt payload member {corrupt_payload}")
                    errors.extend(validate_deterministic_zip(
                        payload, payload_files, f"{label} payload"
                    ))
                    errors.extend(validate_exact_archive_checksums(
                        payload, payload_files, f"{label} payload"
                    ))
                    payload_basenames: dict[str, list[str]] = {}
                    for name in payload_files:
                        payload_basenames.setdefault(PurePosixPath(name).name, []).append(name)
                    for basename in sorted(REQUIRED_PAYLOAD_BASENAMES):
                        if len(payload_basenames.get(basename, [])) != 1:
                            errors.append(f"{label}: payload must contain exactly one {basename}")
                    missing_required_paths = sorted(
                        REQUIRED_PAYLOAD_PATHS - set(payload_files)
                    )
                    if missing_required_paths:
                        errors.append(
                            f"{label}: payload omits locked paths: "
                            + ", ".join(missing_required_paths)
                        )
                    unexpected_payload_paths = sorted(
                        name for name in payload_files
                        if name not in REQUIRED_PAYLOAD_PATHS
                        and not name.startswith("Screenshots/")
                        and not name.startswith("PublicationAudit/")
                    )
                    if unexpected_payload_paths:
                        errors.append(
                            f"{label}: payload has unexpected paths: "
                            + ", ".join(unexpected_payload_paths)
                        )
                    if any(PurePosixPath(name).name.startswith("CompletionReport")
                           for name in payload_files):
                        errors.append(f"{label}: payload may not contain self-referential reports")
                    for summary_basename in (
                        "Test-Summary.json", "TEST-MATRIX-v1.0.csv",
                        "FINDING-CLOSURE-MATRIX-v1.0.json",
                    ):
                        summary_names = payload_basenames.get(summary_basename, [])
                        if summary_names and not summary_names[0].startswith("TestSummaries/"):
                            errors.append(
                                f"{label}: {summary_basename} must be under TestSummaries/"
                            )
                    exact_shots = {
                        f"Screenshots/{row['requiredEvidence']}"
                        for row in locked_rows.values()
                        if row["requiredEvidence"].endswith(".png")
                    } | {
                        "Screenshots/"
                        + PurePosixPath(path).relative_to(
                            "docs/verification/remediation-v1/Screenshots"
                        ).as_posix()
                        for paths in PLATFORM_SCREENSHOT_CLAIM_PATHS.values()
                        for path in paths
                    }
                    missing_shots = sorted(exact_shots - set(payload_files))
                    if missing_shots:
                        errors.append(
                            f"{label}: payload omits exact matrix screenshots: "
                            + ", ".join(missing_shots)
                        )
                    for shot_name in sorted(name for name in payload_files if name.startswith("Screenshots/")):
                        external_shot = (
                            repository_root / "docs/verification/remediation-v1/Screenshots"
                            / PurePosixPath(shot_name).relative_to("Screenshots")
                        )
                        shot_data = payload.read(payload_files[shot_name])
                        if not external_shot.is_file() or external_shot.is_symlink():
                            errors.append(f"{label}: external screenshot is missing for {shot_name}")
                        elif shot_data != external_shot.read_bytes():
                            errors.append(f"{label}: packaged screenshot differs for {shot_name}")
                        errors.extend(validate_png_bytes(
                            shot_data, f"{label}: packaged screenshot {shot_name}"
                        ))
                    required_external_matches = {
                        "RuneScrib-macOS-Release.app.zip": (
                            "artifacts/remediation-v1/RuneScrib-macOS-Release.app.zip"
                        ),
                        "RuneScrib-iPhoneSimulator-Release.app.zip": (
                            "artifacts/remediation-v1/RuneScrib-iPhoneSimulator-Release.app.zip"
                        ),
                        "RuneScrib-iPadSimulator-Qualification.json": (
                            "artifacts/remediation-v1/RuneScrib-iPadSimulator-Qualification.json"
                        ),
                        "SOURCE-MANIFEST.json": (
                            "docs/verification/remediation-v1/SOURCE-MANIFEST.json"
                        ),
                        "OWNER-TEST-CANDIDATE-HANDOFF.md": (
                            "artifacts/remediation-v1/OWNER-TEST-CANDIDATE-HANDOFF.md"
                        ),
                        "Screenshot-Index.md": (
                            "artifacts/remediation-v1/Screenshot-Index.md"
                        ),
                        "Test-Summary.json": "artifacts/remediation-v1/Test-Summary.json",
                        "TEST-MATRIX-v1.0.csv": EXPECTED_TEST_MATRIX,
                        "FINDING-CLOSURE-MATRIX-v1.0.json": EXPECTED_FINDING_MATRIX,
                        "PublicationAudit.json": EXPECTED_PUBLICATION_AUDIT,
                        "IPAD-QUALIFICATION.schema.json": (
                            EXPECTED_IPAD_QUALIFICATION_SCHEMA
                        ),
                    }
                    member_bytes: dict[str, bytes] = {}
                    for basename, external_relative in required_external_matches.items():
                        matches = payload_basenames.get(basename, [])
                        external = repository_root / external_relative
                        if len(matches) != 1 or not external.is_file() or external.is_symlink():
                            continue
                        data = payload.read(payload_files[matches[0]])
                        member_bytes[basename] = data
                        if data != external.read_bytes():
                            errors.append(f"{label}: payload/external bytes differ for {basename}")
                    mac_data = member_bytes.get("RuneScrib-macOS-Release.app.zip", b"")
                    ios_data = member_bytes.get("RuneScrib-iPhoneSimulator-Release.app.zip", b"")
                    errors.extend(validate_app_zip(
                        mac_data, "macOS", f"{label} payload macOS product"
                    ))
                    errors.extend(validate_app_zip(
                        ios_data, "iOS", f"{label} payload iOS product"
                    ))
                    ipad_data = member_bytes.get(
                        "RuneScrib-iPadSimulator-Qualification.json", b""
                    )
                    try:
                        ipad_document = json.loads(ipad_data.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError) as exception:
                        errors.append(f"{label}: payload iPad qualification is invalid: {exception}")
                        ipad_document = {}
                    errors.extend(validate_ipad_qualification_document(
                        ipad_document,
                        repository_root=repository_root,
                        source_hash=source_hash,
                        source_revision=source_revision,
                        locked_rows=locked_rows,
                        executions=executions,
                        ios_product_digest=hashlib.sha256(ios_data).hexdigest(),
                        label=f"{label} payload iPad qualification",
                    ))
                    audit_data = member_bytes.get("PublicationAudit.json", b"")
                    try:
                        packaged_audit = json.loads(audit_data.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError) as exception:
                        errors.append(f"{label}: payload publication audit is invalid: {exception}")
                        packaged_audit = {}
                    if isinstance(packaged_audit, dict):
                        audit_log = packaged_audit.get("log")
                        if isinstance(audit_log, str):
                            packed_log_name = f"PublicationAudit/{Path(audit_log).name}"
                            if packed_log_name not in payload_files:
                                errors.append(f"{label}: payload omits publication-audit log")
                            else:
                                external_log = repository_root / audit_log
                                packed_log = payload.read(payload_files[packed_log_name])
                                if not external_log.is_file() or packed_log != external_log.read_bytes():
                                    errors.append(f"{label}: packaged publication-audit log differs")
            except (KeyError, RuntimeError, zipfile.BadZipFile) as exception:
                errors.append(f"{label}: nested payload is not a ZIP: {exception}")
    except (OSError, KeyError, RuntimeError, zipfile.BadZipFile) as exception:
        errors.append(f"{label}: invalid ZIP: {exception}")
    return errors


def validate_external_checksums(repository_root: Path) -> list[str]:
    errors: list[str] = []
    sums_path = repository_root / EXPECTED_SHA256SUMS
    if not sums_path.is_file() or sums_path.is_symlink():
        return [f"{EXPECTED_SHA256SUMS}: missing regular checksum file"]
    checksums, parse_errors = parse_sha256sums(
        read_bounded_text(sums_path),
        EXPECTED_SHA256SUMS,
    )
    errors.extend(parse_errors)
    seen_basenames: set[str] = set()
    for name, digest in checksums.items():
        relative = Path(name)
        candidate = (
            repository_root / relative
            if relative.parts and relative.parts[0] == "artifacts"
            else sums_path.parent / relative
        )
        if not candidate.is_file() or candidate.is_symlink():
            errors.append(f"{EXPECTED_SHA256SUMS}: missing referenced file {name}")
            continue
        if sha256_file(candidate) != digest:
            errors.append(f"{EXPECTED_SHA256SUMS}: checksum differs for {name}")
        seen_basenames.add(candidate.name)
    missing = sorted(REQUIRED_EXTERNAL_CHECKSUM_BASENAMES - seen_basenames)
    if missing:
        errors.append(
            f"{EXPECTED_SHA256SUMS}: missing required checksums: " + ", ".join(missing)
        )
    return errors


def validate_version_surfaces(repository_root: Path) -> list[str]:
    errors: list[str] = []
    surfaces = (
        (
            repository_root / "project.yml",
            r'MARKETING_VERSION:\s*"?([^"\s;]+)"?',
            EXPECTED_VERSION,
            "MARKETING_VERSION",
        ),
        (
            repository_root / "project.yml",
            r'CURRENT_PROJECT_VERSION:\s*"?([^"\s;]+)"?',
            EXPECTED_BUILD,
            "CURRENT_PROJECT_VERSION",
        ),
        (
            repository_root / "RuneScrib.xcodeproj/project.pbxproj",
            r"MARKETING_VERSION\s*=\s*([^;\s]+)",
            EXPECTED_VERSION,
            "generated MARKETING_VERSION",
        ),
        (
            repository_root / "RuneScrib.xcodeproj/project.pbxproj",
            r"CURRENT_PROJECT_VERSION\s*=\s*([^;\s]+)",
            EXPECTED_BUILD,
            "generated CURRENT_PROJECT_VERSION",
        ),
    )
    for path, pattern, expected, label in surfaces:
        text = read_bounded_text(path)
        values = re.findall(pattern, text)
        if not values:
            errors.append(f"{path.name}: {label} is missing")
        elif any(value != expected for value in values):
            errors.append(f"{path.name}: every {label} must be {expected}")
    return errors


def validate_completion_markdown(
    evidence_root: Path,
    source_hash: str,
) -> list[str]:
    path = evidence_root / "CompletionReport.md"
    if not path.is_file() or path.is_symlink():
        return ["CompletionReport.md is missing or not a regular file"]
    text = read_bounded_text(path)
    errors: list[str] = []
    for template in TERMINAL_MARKDOWN_LINES:
        required = template.format(source_hash=source_hash)
        if required not in text:
            errors.append(f"CompletionReport.md: missing terminal statement: {required}")
    errors.extend(markdown_contradiction_errors(text, "CompletionReport.md"))
    return errors


def markdown_contradiction_errors(text: str, label: str) -> list[str]:
    contradictions = (
        re.compile(
            r"(?im)^\s*(?:\*\*)?status(?:\*\*)?\s*:?\s*`?"
            r"(?:open|blocked|failed|incomplete|not[ -]ready|shipped)\b"
        ),
        re.compile(r"(?im)^\s*\|\s*RSA-\d{3}\s*\|\s*(?:open|blocked|failed)\b"),
        re.compile(
            r"(?i)\b(?:required\s+gates?|remediation)\b[^\n.]{0,100}"
            r"\b(?:remain(?:s)?\s+open|blocked|failed|incomplete)\b"
        ),
        re.compile(
            r"(?i)\b(?:publicly\s+shipped|has\s+shipped|was\s+shipped|"
            r"(?<!no\s)public\s+(?:upload|distribution)\s+(?:was\s+)?performed)\b"
        ),
    )
    return [f"{label}: contains contradictory shipped/open/blocked status text"] \
        if any(pattern.search(text) for pattern in contradictions) else []


def validate_evidence_index(
    evidence_root: Path,
    repository_root: Path,
    source_hash: str,
    has_git: bool,
) -> tuple[list[str], list[str], list[str], str | None]:
    path = evidence_root / EVIDENCE_INDEX
    errors: list[str] = []
    try:
        document = load_json(path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return [f"{EVIDENCE_INDEX} is invalid or missing: {exception}"], [], [], None
    if not isinstance(document, dict):
        return [f"{EVIDENCE_INDEX} root must be an object"], [], [], None
    expected_keys = {
        "schemaVersion",
        "sourceManifestSHA256",
        "sourceRevision",
        "evidenceRecords",
        "supportingJSON",
        "sha256",
    }
    if set(document) != expected_keys:
        errors.append(f"{EVIDENCE_INDEX}: keys differ from the index schema")
    if document.get("schemaVersion") != "1.0":
        errors.append(f"{EVIDENCE_INDEX}: schemaVersion must be 1.0")
    if document.get("sourceManifestSHA256") != source_hash:
        errors.append(f"{EVIDENCE_INDEX}: source manifest hash differs")

    records = unique_string_array(document.get("evidenceRecords"))
    supporting = unique_string_array(document.get("supportingJSON"), allow_empty=True)
    if records is None:
        errors.append(f"{EVIDENCE_INDEX}: evidenceRecords must be a nonempty unique array")
        records = []
    if supporting is None:
        errors.append(f"{EVIDENCE_INDEX}: supportingJSON must be a unique string array")
        supporting = []
    if set(records) & set(supporting):
        errors.append(f"{EVIDENCE_INDEX}: record and supporting paths overlap")
    exact_record_paths = {
        f"docs/verification/remediation-v1/{name}"
        for name in REMEDIATION_RECORD_NAMES
    }
    if set(records) != exact_record_paths:
        errors.append(
            f"{EVIDENCE_INDEX}: evidenceRecords must contain the exact 13 remediation records"
        )

    evidence_relative = repository_relative(evidence_root, repository_root)
    if evidence_relative is None:
        errors.append(f"{EVIDENCE_INDEX}: evidence root is outside the repository")
        evidence_prefix = ""
    else:
        evidence_prefix = evidence_relative.rstrip("/") + "/"
    for relative in records + supporting:
        if (
            not relative.startswith(evidence_prefix)
            or not relative.endswith(".json")
            or not repository_relative_file(relative, repository_root)
        ):
            errors.append(f"{EVIDENCE_INDEX}: invalid indexed JSON path {relative}")

    discovered: set[str] = set()
    if evidence_root.is_dir():
        for candidate in evidence_root.rglob("*.json"):
            within_evidence = candidate.relative_to(evidence_root).as_posix()
            if "/" not in within_evidence and candidate.name in (
                EVIDENCE_EXEMPT | {"CompletionReport.json"}
            ):
                continue
            relative = repository_relative(candidate, repository_root)
            if relative is not None:
                discovered.add(relative)
    indexed = set(records) | set(supporting)
    if discovered != indexed:
        missing = sorted(discovered - indexed)
        invented = sorted(indexed - discovered)
        if missing:
            errors.append(
                f"{EVIDENCE_INDEX}: unindexed JSON evidence: " + ", ".join(missing)
            )
        if invented:
            errors.append(
                f"{EVIDENCE_INDEX}: indexed paths are not discoverable JSON: "
                + ", ".join(invented)
            )

    required_hash_paths = indexed | INDEX_TERMINAL_FILES
    if not artifact_digest_map_valid(
        document.get("sha256"),
        required_hash_paths,
        repository_root,
    ):
        errors.append(
            f"{EVIDENCE_INDEX}: sha256 must exactly bind indexed and terminal evidence files"
        )

    revision = document.get("sourceRevision")
    if has_git:
        if not isinstance(revision, str) or HEX_40.fullmatch(revision) is None:
            errors.append(f"{EVIDENCE_INDEX}: Git-backed index requires sourceRevision")
        elif not git_revision_is_ancestor(repository_root, revision):
            errors.append(f"{EVIDENCE_INDEX}: sourceRevision is not an ancestor of HEAD")
    elif NO_GIT_CHILD_MODE:
        if revision is not None and (
            not isinstance(revision, str) or HEX_40.fullmatch(revision) is None
        ):
            errors.append(f"{EVIDENCE_INDEX}: copied-tree sourceRevision is invalid")
    elif revision is not None:
        errors.append(f"{EVIDENCE_INDEX}: sourceRevision must be null without Git")
    return errors, records, supporting, revision if isinstance(revision, str) else None


def claim_artifact_exclusions() -> set[str]:
    return {
        "docs/verification/remediation-v1/CompletionReport.json",
        "docs/verification/remediation-v1/CompletionReport.md",
        "docs/verification/remediation-v1/DefectClosure.json",
        "docs/verification/remediation-v1/EvidenceIndex.json",
        "docs/verification/remediation-v1/OwnerTestCandidateHandoff.md",
        EXPECTED_OWNER_PACKAGE,
        EXPECTED_PAYLOAD_PACKAGE,
        EXPECTED_TEST_EXECUTION_INDEX,
        "docs/verification/remediation-v1/GateRun/check-remediation-completion.log",
        EXPECTED_PUBLICATION_AUDIT,
        NO_GIT_QUALIFICATION_RESULT,
        EXPECTED_SHA256SUMS,
        "artifacts/remediation-v1/OWNER-TEST-CANDIDATE-HANDOFF.md",
        "artifacts/remediation-v1/Screenshot-Index.md",
        "artifacts/remediation-v1/Test-Summary.json",
        "artifacts/remediation-v1/CompletionReport.json",
        "artifacts/remediation-v1/CompletionReport.md",
        *(
            f"docs/verification/remediation-v1/{name}"
            for name in REMEDIATION_RECORD_NAMES
        ),
    }


def expected_claim_artifacts(
    repository_root: Path,
    test_ids: list[str],
    executions: dict[str, dict[str, Any]],
    suite_results: dict[str, dict[str, Any]],
) -> list[dict[str, str]]:
    kinds_by_path: dict[str, str] = {}
    for test_id in test_ids:
        execution = executions[test_id]
        suite_name = str(execution.get("suiteName"))
        suite_path = execution.get("log")
        suite_result = suite_results.get(suite_name, {})
        raw_log = suite_result.get("rawLog")
        if isinstance(suite_path, str):
            kinds_by_path[suite_path] = "structured-suite-result"
        if isinstance(raw_log, str):
            kinds_by_path[raw_log] = "raw-test-log"
        evidence = execution.get("evidence")
        if isinstance(evidence, list):
            for relative in evidence:
                if (
                    not isinstance(relative, str)
                    or relative.startswith(CLAIM_EVIDENCE_PREFIX + "/")
                    or relative in claim_artifact_exclusions()
                ):
                    continue
                kinds_by_path.setdefault(relative, "test-evidence")
    for domain_path in (CLOUD_GAME_CENTER_RESULTS, PERFORMANCE_RESOURCE_RESULTS):
        if domain_path in kinds_by_path:
            kinds_by_path[domain_path] = "domain-result"
    if BUILT_PRODUCT_INSPECTION_RESULTS in kinds_by_path:
        kinds_by_path[BUILT_PRODUCT_INSPECTION_RESULTS] = "product-inspection"
    if "T-006" in test_ids:
        kinds_by_path[NO_GIT_QUALIFICATION_RESULT] = "test-evidence"
    return [
        {"path": relative, "sha256": sha256_file(repository_root / relative), "kind": kind}
        for relative, kind in sorted(kinds_by_path.items())
        if repository_relative_file(relative, repository_root)
    ]


def validate_claim_evidence_documents(
    repository_root: Path,
    *,
    source_hash: str,
    source_revision: str | None,
    gate_requirements: dict[str, set[str]],
    locked_rows: dict[str, dict[str, str]],
    executions: dict[str, dict[str, Any]],
    suite_results: dict[str, dict[str, Any]],
    indexed_supporting: list[str],
) -> list[str]:
    """Validate ClaimEvidence as a typed index over independently proven results."""
    errors: list[str] = []
    gate_claims = {
        claim
        for claims in gate_requirements.values()
        for claim in claims
        if required_claim_paths(claim)[0].startswith(CLAIM_EVIDENCE_PREFIX + "/")
    }
    matrix_claims = {
        row["requiredEvidence"] for row in locked_rows.values()
        if required_claim_paths(row["requiredEvidence"])[0].startswith(
            CLAIM_EVIDENCE_PREFIX + "/"
        )
    }
    generic_claims = sorted(gate_claims | matrix_claims)
    expected_paths = {claim_evidence_path(claim) for claim in generic_claims}
    indexed_claim_paths = {
        relative for relative in indexed_supporting
        if relative.startswith(CLAIM_EVIDENCE_PREFIX + "/")
    }
    if indexed_claim_paths != expected_paths:
        errors.append(
            "ClaimEvidence inventory differs from every exact generic gate claim"
        )
    for claim in generic_claims:
        relative = claim_evidence_path(claim)
        label = f"ClaimEvidence {claim!r}"
        try:
            document = load_json(repository_root / relative)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
            errors.append(f"{label}: invalid or missing: {exception}")
            continue
        if not isinstance(document, dict) or set(document) != CLAIM_EVIDENCE_KEYS:
            errors.append(f"{label}: keys differ from the typed claim schema")
            continue
        catalog_gates = {
            gate_id for gate_id, claims in gate_requirements.items() if claim in claims
        }
        exact_matrix_ids = {
            test_id for test_id, row in locked_rows.items()
            if row["requiredEvidence"] == claim
        }
        expected_gates = sorted(catalog_gates | {
            gate_id
            for test_id in exact_matrix_ids
            for gate_id in locked_rows[test_id]["gateIDs"].split(";")
        })
        expected_test_ids = sorted(exact_matrix_ids | {
            test_id for test_id, row in locked_rows.items()
            if set(row["gateIDs"].split(";")).intersection(catalog_gates)
        })
        expected_scalars: dict[str, object] = {
            "schemaVersion": "1.0", "status": "PASS", "claim": claim,
            "sourceManifestSHA256": source_hash,
            "sourceRevision": source_revision,
            "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
            "gateIDs": expected_gates, "testIDs": expected_test_ids,
        }
        for key, expected in expected_scalars.items():
            if document.get(key) != expected:
                errors.append(f"{label}: {key} differs")
        expected_executions: list[dict[str, object]] = []
        for test_id in expected_test_ids:
            execution = executions.get(test_id, {})
            expected_executions.append({
                "testID": test_id,
                "result": "PASS",
                "suiteName": execution.get("suiteName"),
                "command": execution.get("command"),
                "requiredEvidence": locked_rows[test_id]["requiredEvidence"],
                "log": execution.get("log"),
                "logSHA256": execution.get("logSHA256"),
            })
        claim_executions = document.get("executions")
        if (
            not isinstance(claim_executions, list)
            or any(
                not isinstance(item, dict) or set(item) != CLAIM_EXECUTION_KEYS
                for item in claim_executions
            )
            or claim_executions != expected_executions
        ):
            errors.append(f"{label}: executions differ from the exact TestExecutionIndex slice")
        expected_artifacts = expected_claim_artifacts(
            repository_root, expected_test_ids, executions, suite_results
        )
        artifacts = document.get("artifacts")
        if (
            not isinstance(artifacts, list)
            or any(
                not isinstance(item, dict) or set(item) != CLAIM_ARTIFACT_KEYS
                for item in artifacts
            )
            or artifacts != expected_artifacts
        ):
            errors.append(
                f"{label}: artifacts differ from independently hashed suite/test evidence"
            )
        if any(
            isinstance(item, dict) and item.get("path") == relative
            for item in (artifacts if isinstance(artifacts, list) else [])
        ):
            errors.append(f"{label}: may not self-reference")
        if claim == CLOUD_GAME_CENTER_CLAIM:
            expected_markers = list(CLOUD_GAME_CENTER_MARKERS)
        elif claim == PERFORMANCE_RESOURCE_CLAIM:
            expected_markers = list(PERFORMANCE_RESOURCE_MARKERS)
        elif claim == "all remediation JSON evidence":
            expected_markers = ["evidence-index-exhaustive-cross-check"]
        else:
            expected_markers = []
        if document.get("semanticMarkers") != expected_markers:
            errors.append(f"{label}: semanticMarkers differ")
    return errors


def safe_extract_git_archive(archive_path: Path, destination: Path) -> list[str]:
    errors: list[str] = []
    deferred_symlinks: list[tarfile.TarInfo] = []
    destination = destination.resolve()

    def traverses_symlink(target: Path) -> bool:
        parent = target.parent
        while parent != destination:
            if destination not in parent.parents or parent.is_symlink():
                return True
            parent = parent.parent
        return False

    with tarfile.open(archive_path, mode="r:") as archive:
        for member in archive.getmembers():
            relative = PurePosixPath(member.name)
            if (
                not member.name
                or relative.is_absolute()
                or ".." in relative.parts
                or "\\" in member.name
                or "\0" in member.name
            ):
                errors.append(f"sourceRevision archive contains unsafe path {member.name!r}")
                continue
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                if traverses_symlink(target):
                    errors.append(f"sourceRevision archive traverses a symlink at {member.name}")
                    continue
                stream = archive.extractfile(member)
                if stream is None:
                    errors.append(f"sourceRevision archive cannot read {member.name}")
                    continue
                with target.open("wb") as output:
                    while True:
                        chunk = stream.read(1024 * 1024)
                        if not chunk:
                            break
                        output.write(chunk)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
            elif member.issym():
                deferred_symlinks.append(member)
            else:
                errors.append(f"sourceRevision archive has unsupported entry {member.name}")
        for member in deferred_symlinks:
            relative = PurePosixPath(member.name)
            target = destination.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            if traverses_symlink(target):
                errors.append(f"sourceRevision archive traverses a symlink at {member.name}")
                continue
            try:
                os.symlink(member.linkname, target)
            except OSError as exception:
                errors.append(f"sourceRevision archive cannot create {member.name}: {exception}")
    return errors


def validate_revision_projection(
    repository_root: Path,
    revision: str,
    manifest_document: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    terminal_boundaries = (
        "docs/verification/remediation-v1/CompletionReport.json",
        "docs/verification/remediation-v1/DefectClosure.json",
        "docs/verification/remediation-v1/EvidenceIndex.json",
        EXPECTED_TEST_EXECUTION_INDEX,
        EXPECTED_PUBLICATION_AUDIT,
        EXPECTED_OWNER_PACKAGE,
        EXPECTED_PAYLOAD_PACKAGE,
    )
    for relative in terminal_boundaries:
        present = subprocess.run(
            ["git", "cat-file", "-e", f"{revision}:{relative}"],
            cwd=repository_root, check=False, capture_output=True,
        )
        if present.returncode == 0:
            errors.append(
                f"sourceRevision contains terminal evidence before qualification: {relative}"
            )
    if errors:
        return errors
    with tempfile.TemporaryDirectory(prefix="remediation-source-revision-") as temporary:
        temporary_root = Path(temporary)
        archive_path = temporary_root / "source.tar"
        source_root = temporary_root / "source"
        source_root.mkdir()
        archived = subprocess.run(
            ["git", "archive", "--format=tar", "--output", str(archive_path), revision],
            cwd=repository_root,
            check=False,
            capture_output=True,
            text=True,
        )
        if archived.returncode != 0:
            detail = archived.stderr.strip() or archived.stdout.strip()
            return [f"sourceRevision archive failed: {detail}"]
        try:
            errors.extend(safe_extract_git_archive(archive_path, source_root))
        except (OSError, tarfile.TarError) as exception:
            return [f"sourceRevision archive is invalid: {exception}"]
        if errors:
            return errors
        projected_manifest = source_root / "docs/verification/remediation-v1/SOURCE-MANIFEST.json"
        generated = subprocess.run(
            [
                sys.executable,
                str(repository_root / "scripts/generate-source-manifest.py"),
                str(source_root),
                str(projected_manifest),
            ],
            cwd=repository_root,
            check=False,
            capture_output=True,
            text=True,
        )
        if generated.returncode != 0:
            detail = generated.stderr.strip() or generated.stdout.strip()
            return [f"sourceRevision projection manifest failed: {detail}"]
        try:
            projected = load_json(projected_manifest)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
            return [f"sourceRevision projection manifest is invalid: {exception}"]
        if projected != manifest_document:
            errors.append(
                "sourceRevision does not project to the exact final SOURCE-MANIFEST"
            )
    return errors


def validate_source_manifest(
    repository_root: Path,
    manifest_path: Path,
    errors: list[str],
) -> str:
    try:
        source = load_json(manifest_path)
    except (OSError, json.JSONDecodeError) as exception:
        errors.append(f"{manifest_path}: invalid or missing source manifest: {exception}")
        return ""
    if not isinstance(source, dict):
        errors.append(f"{manifest_path}: source manifest root must be an object")
        return ""
    source_hash = source.get("aggregateSHA256")
    if not isinstance(source_hash, str) or HEX_64.fullmatch(source_hash) is None:
        errors.append(f"{manifest_path}: aggregateSHA256 must be lowercase 64-character hex")
        return ""
    result = subprocess.run(
        [
            sys.executable,
            str(repository_root / "scripts/generate-source-manifest.py"),
            str(repository_root),
            str(manifest_path),
            "--verify",
        ],
        cwd=repository_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        errors.append(f"source manifest does not match the current tree: {detail}")
    return source_hash


def manifest_record_projection(
    document: object,
    label: str,
) -> tuple[list[str], dict[str, tuple[int, str, bool]]]:
    """Validate either source-manifest schema and project comparable fields."""
    errors: list[str] = []
    if (
        not isinstance(document, dict)
        or document.get("schemaVersion") not in {"1.0", "1.1"}
    ):
        return [f"{label}: schemaVersion is unsupported"], {}
    files = document.get("files")
    if not isinstance(files, list) or document.get("fileCount") != len(files):
        return [f"{label}: fileCount/files differ"], {}
    projection: dict[str, tuple[int, str, bool]] = {}
    aggregate = hashlib.sha256()
    schema = document["schemaVersion"]
    for index, record in enumerate(files):
        record_label = f"{label}: files[{index}]"
        expected_keys = (
            {"path", "bytes", "sha256", "executable"}
            if schema == "1.0"
            else {"path", "kind", "bytes", "sha256", "executable"}
        )
        if not isinstance(record, dict) or set(record) != expected_keys:
            errors.append(f"{record_label} keys differ")
            continue
        relative = record.get("path")
        relative_path = PurePosixPath(relative) if isinstance(relative, str) else None
        kind = record.get("kind", "file")
        byte_count = record.get("bytes")
        digest = record.get("sha256")
        executable = record.get("executable")
        if (
            not isinstance(relative, str)
            or not relative
            or relative != relative.strip()
            or "\\" in relative
            or "\0" in relative
            or "\n" in relative
            or relative_path is None
            or relative_path.is_absolute()
            or ".." in relative_path.parts
            or relative_path.as_posix() != relative
            or kind not in {"file", "symlink"}
            or type(byte_count) is not int
            or byte_count < 0
            or not isinstance(digest, str)
            or HEX_64.fullmatch(digest) is None
            or type(executable) is not bool
            or relative in projection
        ):
            errors.append(f"{record_label} values are invalid or duplicate")
            continue
        projection[relative] = (byte_count, digest, executable)
        if schema == "1.0":
            serialized = (
                f"{relative}\0{byte_count}\0{digest}\0"
                f"{1 if executable else 0}\n"
            )
        else:
            serialized = (
                f"{relative}\0{kind}\0{byte_count}\0{digest}\0"
                f"{1 if executable else 0}\n"
            )
        aggregate.update(serialized.encode("utf-8"))
    if list(projection) != sorted(projection):
        errors.append(f"{label}: file records are not sorted")
    if document.get("aggregateSHA256") != aggregate.hexdigest():
        errors.append(f"{label}: aggregateSHA256 differs from its records")
    return (errors, {}) if errors else ([], projection)


def baseline_commit_projection(
    repository_root: Path,
    revision: str,
) -> tuple[list[str], dict[str, tuple[int, str, bool]]]:
    errors: list[str] = []
    projection: dict[str, tuple[int, str, bool]] = {}
    with tempfile.TemporaryDirectory(
        prefix="remediation-baseline-revision-"
    ) as temporary:
        temporary_root = Path(temporary)
        archive_path = temporary_root / "baseline.tar"
        source_root = temporary_root / "source"
        source_root.mkdir()
        archived = subprocess.run(
            [
                "git", "archive", "--format=tar", "--output",
                str(archive_path), revision,
            ],
            cwd=repository_root,
            check=False,
            capture_output=True,
            text=True,
        )
        if archived.returncode != 0:
            detail = archived.stderr.strip() or archived.stdout.strip()
            return [f"baseline revision archive failed: {detail}"], {}
        try:
            errors.extend(safe_extract_git_archive(archive_path, source_root))
        except (OSError, tarfile.TarError) as exception:
            return [f"baseline revision archive is invalid: {exception}"], {}
        if errors:
            return errors, {}

        def excluded(relative: str) -> bool:
            parts = relative.split("/")
            return any(
                relative == entry
                or relative.startswith(entry + "/")
                or ("/" not in entry and entry in parts)
                for entry in BASELINE_MANIFEST_EXCLUDES
            )

        for candidate in sorted(
            source_root.rglob("*"),
            key=lambda item: item.relative_to(source_root).as_posix(),
        ):
            relative = candidate.relative_to(source_root).as_posix()
            if excluded(relative) or candidate.is_dir():
                continue
            if candidate.is_symlink() or not candidate.is_file():
                errors.append(
                    f"baseline revision has unsupported source entry: {relative}"
                )
                continue
            metadata = candidate.stat()
            projection[relative] = (
                metadata.st_size,
                sha256_file(candidate),
                bool(metadata.st_mode & stat.S_IXUSR),
            )
    return (errors, {}) if errors else ([], projection)


def baseline_changed_manifest_paths(
    repository_root: Path,
    final_manifest: object,
    *,
    has_git: bool,
    source_revision: str | None,
) -> tuple[list[str], set[str], set[str], set[str], set[str]]:
    before_path = repository_root / SOURCE_MANIFEST_BEFORE
    if not repository_relative_file(SOURCE_MANIFEST_BEFORE, repository_root):
        return (
            [f"{SOURCE_MANIFEST_BEFORE}: missing or unsafe baseline manifest"],
            set(), set(), set(), set(),
        )
    try:
        before_manifest = load_json(before_path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return (
            [f"{SOURCE_MANIFEST_BEFORE}: invalid JSON: {exception}"],
            set(), set(), set(), set(),
        )
    expected_before_keys = {
        "aggregateSHA256", "excludes", "fileCount", "files", "rootName",
        "schemaVersion",
    }
    before_shape_errors: list[str] = []
    if not isinstance(before_manifest, dict) or set(before_manifest) != expected_before_keys:
        before_shape_errors.append("SOURCE-MANIFEST.before.json: keys differ")
    else:
        if before_manifest.get("excludes") != list(BASELINE_MANIFEST_EXCLUDES):
            before_shape_errors.append(
                "SOURCE-MANIFEST.before.json: excludes differ from the baseline policy"
            )
        if (
            before_manifest.get("aggregateSHA256")
                != EXPECTED_BASELINE_AGGREGATE_SHA256
            or before_manifest.get("fileCount") != EXPECTED_BASELINE_FILE_COUNT
            or before_manifest.get("rootName") != "Rune-Scribe-Remediation-v1"
        ):
            before_shape_errors.append(
                "SOURCE-MANIFEST.before.json: differs from the immutable task baseline"
            )
    before_errors, before_projection = manifest_record_projection(
        before_manifest,
        "SOURCE-MANIFEST.before.json",
    )
    final_errors, final_projection = manifest_record_projection(
        final_manifest,
        "SOURCE-MANIFEST.json",
    )
    errors = before_shape_errors + before_errors + final_errors
    if errors:
        return errors, set(), set(), set(), set()
    projection_changed_final_paths = {
        relative
        for relative, record in final_projection.items()
        if before_projection.get(relative) != record
    }
    projection_deleted_paths = set(before_projection) - set(final_projection)
    changed_final_paths = projection_changed_final_paths
    deleted_paths = projection_deleted_paths
    if has_git:
        try:
            baseline = load_json(repository_root / BASELINE_RECORD)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
            return (
                [f"{BASELINE_RECORD}: invalid or missing: {exception}"],
                set(), set(), set(), set(),
            )
        repository = baseline.get("repository") if isinstance(baseline, dict) else None
        source_baseline = (
            baseline.get("sourceBaseline") if isinstance(baseline, dict) else None
        )
        baseline_revision = (
            repository.get("head") if isinstance(repository, dict) else None
        )
        if (
            not isinstance(baseline_revision, str)
            or HEX_40.fullmatch(baseline_revision) is None
            or not isinstance(source_revision, str)
            or HEX_40.fullmatch(source_revision) is None
        ):
            return [
                f"{BASELINE_RECORD}: baseline head/sourceRevision binding is invalid"
            ], set(), set(), set(), set()
        if baseline_revision != EXPECTED_BASELINE_REVISION:
            errors.append(
                f"{BASELINE_RECORD}: repository.head differs from the immutable task baseline"
            )
        if (
            not isinstance(source_baseline, dict)
            or source_baseline.get("sourceManifestPath") != SOURCE_MANIFEST_BEFORE
            or source_baseline.get("sourceManifestSHA256")
                != EXPECTED_BASELINE_AGGREGATE_SHA256
            or source_baseline.get("sourceManifestFileCount")
                != EXPECTED_BASELINE_FILE_COUNT
            or source_baseline.get("packageArchiveSHA256")
                != EXPECTED_BASELINE_PACKAGE_SHA256
        ):
            errors.append(
                f"{BASELINE_RECORD}: source baseline differs from the before manifest"
            )
        if repository.get("originMain") != baseline_revision:
            errors.append(f"{BASELINE_RECORD}: baseline head and originMain differ")
        exists = subprocess.run(
            ["git", "cat-file", "-e", f"{baseline_revision}^{{commit}}"],
            cwd=repository_root,
            check=False,
            capture_output=True,
        )
        ordered = subprocess.run(
            [
                "git", "merge-base", "--is-ancestor",
                baseline_revision, source_revision,
            ],
            cwd=repository_root,
            check=False,
            capture_output=True,
        )
        if (
            exists.returncode != 0
            or baseline_revision == source_revision
            or ordered.returncode != 0
        ):
            errors.append(
                f"{BASELINE_RECORD}: baseline head must strictly precede sourceRevision"
            )
        archive_errors, commit_projection = baseline_commit_projection(
            repository_root, baseline_revision
        )
        errors.extend(archive_errors)
        if commit_projection and commit_projection != before_projection:
            errors.append(
                "SOURCE-MANIFEST.before.json does not project from Baseline.json "
                "repository.head"
            )
        diff = subprocess.run(
            [
                "git", "diff", "--name-only", "--no-renames", "-z",
                baseline_revision, source_revision, "--",
            ],
            cwd=repository_root,
            check=False,
            capture_output=True,
        )
        if diff.returncode != 0:
            detail = diff.stderr.decode("utf-8", errors="replace").strip()
            errors.append(f"baseline-to-sourceRevision Git diff failed: {detail}")
        else:
            try:
                diff_paths = {
                    value.decode("utf-8")
                    for value in diff.stdout.split(b"\0") if value
                }
            except UnicodeDecodeError as exception:
                errors.append(
                    f"baseline-to-sourceRevision Git diff paths are invalid: {exception}"
                )
                diff_paths = set()
            if any(
                not relative
                or PurePosixPath(relative).is_absolute()
                or ".." in PurePosixPath(relative).parts
                or PurePosixPath(relative).as_posix() != relative
                for relative in diff_paths
            ):
                errors.append("baseline-to-sourceRevision Git diff has unsafe paths")
            git_changed_final_paths = diff_paths & set(final_projection)
            git_deleted_paths = (
                (diff_paths & set(before_projection)) - set(final_projection)
            )
            if git_changed_final_paths != projection_changed_final_paths:
                errors.append(
                    "baseline-to-sourceRevision Git diff differs from final manifest "
                    "byte/hash/executable changes"
                )
            if git_deleted_paths != projection_deleted_paths:
                errors.append(
                    "baseline-to-sourceRevision Git diff differs from before-manifest "
                    "deletions"
                )
            changed_final_paths = git_changed_final_paths
            deleted_paths = git_deleted_paths
    changed_shipping_paths = {
        relative
        for relative in changed_final_paths
        if is_shipping_source_config_or_project_path(relative)
    }
    deleted_shipping_paths = {
        relative
        for relative in deleted_paths
        if is_shipping_source_config_or_project_path(relative)
    }
    return errors, changed_final_paths, changed_shipping_paths, deleted_paths, deleted_shipping_paths


def validate_evidence_record(
    path: Path,
    record: object,
    repository_root: Path,
    source_hash: str,
    known_gates: set[str],
    gate_requirements: dict[str, set[str]],
    has_git: bool,
    evidence_index_valid: bool,
) -> tuple[list[str], set[str], str | None, dict[str, set[str]]]:
    errors: list[str] = []
    if not isinstance(record, dict):
        return [f"{path}: evidence root must be an object"], set(), None, {}
    required_keys = {
        "schemaVersion",
        "recordID",
        "gateIDs",
        "sourceManifestSHA256",
        "version",
        "build",
        "result",
        "commands",
        "environment",
        "startedAt",
        "endedAt",
        "failures",
        "artifacts",
        "logs",
        "evidenceClaims",
        "evidenceBindings",
        "artifactSHA256",
    }
    missing = sorted(required_keys - set(record))
    if missing:
        errors.append(f"{path}: missing evidence keys: {', '.join(missing)}")
    if record.get("schemaVersion") != "1.0":
        errors.append(f"{path}: schemaVersion must be 1.0")
    record_id = record.get("recordID")
    if (
        not isinstance(record_id, str)
        or not record_id.strip()
        or len(record_id) > 160
    ):
        errors.append(f"{path}: recordID must be nonempty and at most 160 characters")
        record_id = None

    gate_ids = record.get("gateIDs")
    validated_gate_ids: set[str] = set()
    if (
        not isinstance(gate_ids, list)
        or not gate_ids
        or not all(isinstance(gate_id, str) for gate_id in gate_ids)
        or len(gate_ids) != len(set(gate_ids))
    ):
        errors.append(f"{path}: gateIDs must be a nonempty unique string array")
    else:
        unknown = sorted(set(gate_ids) - known_gates)
        if unknown:
            errors.append(f"{path}: unknown gate IDs: {', '.join(unknown)}")
        validated_gate_ids = set(gate_ids) & known_gates

    if record.get("sourceManifestSHA256") != source_hash:
        errors.append(f"{path}: source manifest hash differs")
    if record.get("version") != EXPECTED_VERSION:
        errors.append(f"{path}: version must be {EXPECTED_VERSION}")
    if record.get("build") != EXPECTED_BUILD:
        errors.append(f"{path}: build must be {EXPECTED_BUILD}")

    result = record.get("result")
    if result not in {"PASS", "FAIL", "NON_GATING_EXTERNAL"}:
        errors.append(f"{path}: result is invalid")
    commands = record.get("commands")
    if (
        not isinstance(commands, list)
        or (result == "PASS" and not commands)
        or not all(isinstance(command, str) and command.strip() for command in commands)
    ):
        errors.append(f"{path}: commands must record the nonempty commands executed")
    environment = record.get("environment")
    required_environment = {"operatingSystem", "architecture", "xcode", "swift"}
    if (
        not isinstance(environment, dict)
        or not required_environment.issubset(environment)
        or not all(
            isinstance(environment.get(key), str) and environment[key].strip()
            for key in required_environment
        )
    ):
        errors.append(f"{path}: environment must identify OS, architecture, Xcode, and Swift")
    failures = record.get("failures")
    if not isinstance(failures, list) or not all(isinstance(item, str) for item in failures):
        errors.append(f"{path}: failures must be a string array")
    elif result == "PASS" and failures:
        errors.append(f"{path}: PASS evidence may not contain failures")

    started = valid_timestamp(record.get("startedAt"))
    ended = valid_timestamp(record.get("endedAt"))
    if started is None or ended is None:
        errors.append(f"{path}: startedAt and endedAt must be ISO-8601 timestamps")
    elif started.tzinfo is None or ended.tzinfo is None or ended < started:
        errors.append(f"{path}: evidence timestamps must be ordered and timezone-aware")

    artifacts = record.get("artifacts")
    if (
        not isinstance(artifacts, list)
        or not artifacts
        or not all(isinstance(artifact, str) for artifact in artifacts)
        or len(artifacts) != len(set(artifacts))
    ):
        errors.append(f"{path}: artifacts must be a nonempty array")
    elif not all(
        repository_relative_file(artifact, repository_root) for artifact in artifacts
    ):
        errors.append(f"{path}: every artifact must be an existing repository-relative path")

    logs = record.get("logs")
    if (
        not isinstance(logs, list)
        or not logs
        or not all(isinstance(log, str) for log in logs)
        or len(logs) != len(set(logs))
    ):
        errors.append(f"{path}: logs must be a nonempty unique string array")
    elif not all(
        repository_relative_file(log, repository_root) for log in logs
    ):
        errors.append(f"{path}: logs must contain existing repository-relative paths")

    bound_files: set[str] = set()
    if isinstance(artifacts, list) and all(isinstance(item, str) for item in artifacts):
        bound_files.update(artifacts)
    if isinstance(logs, list) and all(isinstance(item, str) for item in logs):
        bound_files.update(logs)
    if not artifact_digest_map_valid(
        record.get("artifactSHA256"),
        bound_files,
        repository_root,
    ):
        errors.append(f"{path}: artifactSHA256 must exactly bind every artifact and log")

    binding_files = set(bound_files)
    record_relative = repository_relative(path, repository_root)
    if record_relative is not None:
        binding_files.add(record_relative)

    evidence_claims = record.get("evidenceClaims")
    claims_by_gate: dict[str, set[str]] = {}
    if (
        not isinstance(evidence_claims, list)
        or not evidence_claims
        or not all(isinstance(claim, str) and claim.strip() for claim in evidence_claims)
        or len(evidence_claims) != len(set(evidence_claims))
    ):
        errors.append(f"{path}: evidenceClaims must be a nonempty unique string array")
    elif validated_gate_ids:
        claimed = set(evidence_claims)
        allowed = set().union(
            *(gate_requirements.get(gate_id, set()) for gate_id in validated_gate_ids)
        )
        unknown_claims = sorted(claimed - allowed)
        if unknown_claims:
            errors.append(
                f"{path}: evidenceClaims are not required by its gates: "
                + ", ".join(unknown_claims)
            )
        for gate_id in validated_gate_ids:
            gate_claims = claimed & gate_requirements.get(gate_id, set())
            if not gate_claims:
                errors.append(f"{path}: no evidenceClaim supports {gate_id}")
            claims_by_gate[gate_id] = gate_claims

        bindings = record.get("evidenceBindings")
        if not isinstance(bindings, dict) or set(bindings) != claimed:
            errors.append(f"{path}: evidenceBindings must map every exact evidenceClaim")
        else:
            for claim, references in bindings.items():
                deferred_index_authority = (
                    claim == EVIDENCE_INDEX_CLAIM
                    and references == [EVIDENCE_INDEX_PATH]
                    and path.name == "FullRegression.json"
                    and evidence_index_valid
                    and EVIDENCE_INDEX_PATH not in binding_files
                    and isinstance(record.get("artifactSHA256"), dict)
                    and EVIDENCE_INDEX_PATH not in record["artifactSHA256"]
                )
                if (
                    not isinstance(references, list)
                    or not references
                    or not all(isinstance(reference, str) for reference in references)
                    or len(references) != len(set(references))
                    or (
                        claim == EVIDENCE_INDEX_CLAIM
                        and not deferred_index_authority
                    )
                    or (
                        not deferred_index_authority
                        and not set(references).issubset(binding_files)
                    )
                    or not all(
                        repository_relative_file(reference, repository_root)
                        for reference in references
                    )
                    or not claim_bindings_match(claim, references)
                ):
                    errors.append(
                        f"{path}: evidence binding for {claim!r} is invalid or unrelated"
                    )
                else:
                    for reference in references:
                        if reference.endswith(".png"):
                            errors.extend(validate_png_path(
                                repository_root / reference,
                                f"{path}: evidence binding for {claim!r}",
                            ))

    for optional_array in ("notes", "nonGatingExternal"):
        value = record.get(optional_array)
        if value is not None and (
            not isinstance(value, list)
            or not all(isinstance(item, str) and item.strip() for item in value)
        ):
            errors.append(f"{path}: {optional_array} must be a string array")

    test_summary = record.get("testSummary")
    if test_summary is not None:
        summary_keys = {"executed", "passed", "failed", "skipped"}
        if (
            not isinstance(test_summary, dict)
            or set(test_summary) != summary_keys
            or not all(
                type(test_summary.get(key)) is int and test_summary[key] >= 0
                for key in summary_keys
            )
            or test_summary.get("passed", 0)
                + test_summary.get("failed", 0)
                + test_summary.get("skipped", 0)
                != test_summary.get("executed", -1)
            or (result == "PASS" and test_summary.get("failed") != 0)
        ):
            errors.append(f"{path}: testSummary counts are invalid or inconsistent")

    revision = record.get("sourceRevision")
    if has_git:
        if not isinstance(revision, str) or HEX_40.fullmatch(revision) is None:
            errors.append(f"{path}: Git-backed evidence requires a lowercase commit revision")
        elif not git_revision_is_ancestor(repository_root, revision):
            errors.append(f"{path}: sourceRevision is not an existing ancestor of HEAD")
    elif NO_GIT_CHILD_MODE:
        if revision is not None and (
            not isinstance(revision, str) or HEX_40.fullmatch(revision) is None
        ):
            errors.append(f"{path}: copied-tree sourceRevision is invalid")
    elif revision is not None:
        errors.append(f"{path}: sourceRevision must be null when Git is unavailable")

    if errors or result != "PASS":
        validated_gate_ids = set()
        claims_by_gate = {}
    return errors, validated_gate_ids, record_id, claims_by_gate


def validate_completion_report(
    path: Path,
    completion: object,
    repository_root: Path,
    source_hash: str,
    known_gates: set[str],
    has_git: bool,
    record_gates_by_path: dict[str, set[str]],
    locked_rows: dict[str, dict[str, str]],
    executions: dict[str, dict[str, Any]],
) -> list[str]:
    errors: list[str] = []
    if not isinstance(completion, dict):
        return ["CompletionReport.json root must be an object"]
    adjacent_json = repository_root / "artifacts/remediation-v1/CompletionReport.json"
    adjacent_markdown = repository_root / "artifacts/remediation-v1/CompletionReport.md"
    evidence_markdown = path.with_suffix(".md")
    if (
        not adjacent_json.is_file() or adjacent_json.is_symlink()
        or adjacent_json.read_bytes() != path.read_bytes()
    ):
        errors.append("CompletionReport.json: adjacent artifact report differs or is missing")
    if (
        not adjacent_markdown.is_file() or adjacent_markdown.is_symlink()
        or not evidence_markdown.is_file() or adjacent_markdown.read_bytes() != evidence_markdown.read_bytes()
    ):
        errors.append("CompletionReport.md: adjacent artifact report differs or is missing")
    required = {
        "schemaVersion",
        "status",
        "sourceManifestSHA256",
        "version",
        "build",
        "requiredGateCount",
        "passedGateCount",
        "failedGateCount",
        "findingClosures",
        "platformQualification",
        "ownerTestPackage",
        "physicalHardwareRequired",
        "liveAccountsRequired",
        "publicDistributionPerformed",
        "attributionAudit",
    }
    allowed = required | {"sourceRevision", "branch", "nonGatingExternal"}
    missing = sorted(required - set(completion))
    extra = sorted(set(completion) - allowed)
    if missing:
        errors.append("CompletionReport.json: missing keys: " + ", ".join(missing))
    if extra:
        errors.append("CompletionReport.json: unexpected keys: " + ", ".join(extra))
    expected = {
        "schemaVersion": "1.0",
        "status": "RELEASE_CANDIDATE_READY",
        "sourceManifestSHA256": source_hash,
        "version": EXPECTED_VERSION,
        "build": EXPECTED_BUILD,
        "requiredGateCount": 42,
        "passedGateCount": 42,
        "failedGateCount": 0,
        "physicalHardwareRequired": False,
        "liveAccountsRequired": False,
        "publicDistributionPerformed": False,
        "attributionAudit": "PASS",
    }
    for key, value in expected.items():
        if completion.get(key) != value:
            errors.append(f"CompletionReport.json: {key} differs")
    for key in ("requiredGateCount", "passedGateCount", "failedGateCount"):
        if type(completion.get(key)) is not int:
            errors.append(f"CompletionReport.json: {key} must be an integer")
    for key in (
        "physicalHardwareRequired", "liveAccountsRequired", "publicDistributionPerformed"
    ):
        if type(completion.get(key)) is not bool:
            errors.append(f"CompletionReport.json: {key} must be Boolean")

    closures = completion.get("findingClosures")
    closure_ids: set[str] = set()
    if not isinstance(closures, list) or len(closures) != 12:
        errors.append("CompletionReport.json: findingClosures must contain exactly 12 items")
    else:
        for index, closure in enumerate(closures):
            label = f"CompletionReport.json: findingClosures[{index}]"
            if not isinstance(closure, dict) or set(closure) != {
                "id", "status", "gateIDs", "evidence"
            }:
                errors.append(f"{label} keys differ from the completion schema")
                continue
            finding_id = closure.get("id")
            if (
                not isinstance(finding_id, str)
                or finding_id not in EXPECTED_FINDING_IDS
                or finding_id in closure_ids
            ):
                errors.append(f"{label} has an invalid or duplicate finding ID")
            else:
                closure_ids.add(finding_id)
            if closure.get("status") != "CLOSED":
                errors.append(f"{label} status must be CLOSED")
            gate_ids = closure.get("gateIDs")
            if (
                not isinstance(gate_ids, list)
                or not gate_ids
                or not all(isinstance(gate_id, str) for gate_id in gate_ids)
                or len(gate_ids) != len(set(gate_ids))
                or not set(gate_ids).issubset(known_gates)
            ):
                errors.append(f"{label} gateIDs are invalid")
            elif isinstance(finding_id, str) and set(gate_ids) != EXPECTED_FINDING_GATES.get(
                finding_id, set()
            ):
                errors.append(f"{label} gateIDs differ from the locked finding matrix")
            evidence = closure.get("evidence")
            if (
                not isinstance(evidence, list)
                or not evidence
                or not all(isinstance(item, str) for item in evidence)
                or len(evidence) != len(set(evidence))
                or not set(evidence).issubset(record_gates_by_path)
            ):
                errors.append(f"{label} evidence must reference validated PASS records")
            elif isinstance(gate_ids, list):
                evidenced_gates = set().union(
                    *(record_gates_by_path[item] for item in evidence)
                )
                if not set(gate_ids).issubset(evidenced_gates):
                    errors.append(f"{label} evidence does not cover every locked gate")
        if closure_ids != EXPECTED_FINDING_IDS:
            errors.append("CompletionReport.json: finding closure IDs differ")

    expected_platforms = {
        "macOS": "PASS",
        "iPhoneSimulator": "PASS",
        "iPadSimulator": "PASS",
    }
    if completion.get("platformQualification") != expected_platforms:
        errors.append("CompletionReport.json: platformQualification differs")
    required_platform_tests = {
        "macOS": {"T-112"},
        "iPhoneSimulator": {"T-113"},
        "iPadSimulator": {"T-023", "T-114"},
    }
    for platform, test_ids in required_platform_tests.items():
        if any(executions.get(test_id, {}).get("result") != "PASS" for test_id in test_ids):
            errors.append(
                f"CompletionReport.json: {platform} PASS is not derived from locked PASS tests"
            )

    owner_package = completion.get("ownerTestPackage")
    if not isinstance(owner_package, dict) or set(owner_package) != {"path", "sha256"}:
        errors.append("CompletionReport.json: ownerTestPackage is invalid")
    else:
        owner_path_value = owner_package.get("path")
        owner_digest = owner_package.get("sha256")
        if owner_path_value != EXPECTED_OWNER_PACKAGE:
            errors.append("CompletionReport.json: owner-test package path differs")
        elif not repository_relative_file(owner_path_value, repository_root):
            errors.append("CompletionReport.json: owner-test package is missing")
        elif not isinstance(owner_digest, str) or HEX_64.fullmatch(owner_digest) is None:
            errors.append("CompletionReport.json: owner-test package SHA-256 is invalid")
        else:
            owner_path = repository_root / str(owner_path_value)
            if sha256_file(owner_path) != owner_digest:
                errors.append("CompletionReport.json: owner-test package SHA-256 differs")
            errors.extend(validate_owner_package(
                owner_path,
                repository_root,
                source_hash,
                completion.get("sourceRevision")
                if isinstance(completion.get("sourceRevision"), str) else None,
                completion.get("branch")
                if isinstance(completion.get("branch"), str) else None,
                locked_rows,
                executions,
            ))

    external = unique_string_array(completion.get("nonGatingExternal"))
    if external != list(FIXED_NON_GATING_BOUNDARIES):
        errors.append(
            "CompletionReport.json: nonGatingExternal differs from the exact locked boundary"
        )
    branch = completion.get("branch")
    if has_git:
        expected_branch = current_git_branch(repository_root)
        if (
            not isinstance(branch, str)
            or not branch
            or len(branch) > 200
            or branch != expected_branch
        ):
            errors.append("CompletionReport.json: branch must match the current Git branch")
    elif NO_GIT_CHILD_MODE:
        if branch is not None and (
            not isinstance(branch, str) or not branch or len(branch) > 200
        ):
            errors.append("CompletionReport.json: copied-tree branch is invalid")
    elif branch is not None:
        errors.append("CompletionReport.json: branch must be null without Git")
    revision = completion.get("sourceRevision")
    if has_git:
        if not isinstance(revision, str) or HEX_40.fullmatch(revision) is None:
            errors.append("CompletionReport.json: Git-backed report requires sourceRevision")
        elif not git_revision_is_ancestor(repository_root, revision):
            errors.append("CompletionReport.json: sourceRevision is not an ancestor of HEAD")
    elif NO_GIT_CHILD_MODE:
        if revision is not None and (
            not isinstance(revision, str) or HEX_40.fullmatch(revision) is None
        ):
            errors.append("CompletionReport.json: copied-tree sourceRevision is invalid")
    elif revision is not None:
        errors.append("CompletionReport.json: sourceRevision must be null without Git")
    errors.extend(validate_external_checksums(repository_root))
    return errors


def load_locked_finding_controls(
    repository_root: Path,
) -> tuple[list[str], dict[str, dict[str, tuple[str, ...]]]]:
    path = repository_root / EXPECTED_FINDING_MATRIX
    if not path.is_file() or path.is_symlink():
        return [f"{EXPECTED_FINDING_MATRIX}: locked finding matrix copy is missing"], {}
    if sha256_file(path) != EXPECTED_FINDING_MATRIX_SHA256:
        return [f"{EXPECTED_FINDING_MATRIX}: differs from the locked digest"], {}
    try:
        document = load_json(path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        return [f"{EXPECTED_FINDING_MATRIX}: invalid JSON: {exception}"], {}
    rows = document.get("findings") if isinstance(document, dict) else None
    if not isinstance(rows, list) or len(rows) != 12:
        return [f"{EXPECTED_FINDING_MATRIX}: must contain exactly 12 findings"], {}
    controls: dict[str, dict[str, tuple[str, ...]]] = {}
    errors: list[str] = []
    expected_keys = {
        "gates", "id", "implementation", "phases", "primarySourceAreas",
        "severity", "tests", "title",
    }
    for index, row in enumerate(rows):
        label = f"{EXPECTED_FINDING_MATRIX}: findings[{index}]"
        if not isinstance(row, dict) or set(row) != expected_keys:
            errors.append(f"{label} keys differ")
            continue
        finding_id = row.get("id")
        if finding_id not in EXPECTED_FINDING_IDS or finding_id in controls:
            errors.append(f"{label} has an invalid or duplicate ID")
            continue
        values: dict[str, tuple[str, ...]] = {}
        for output_key, row_key in (
            ("gates", "gates"), ("implementation", "implementation"),
            ("sourceAreas", "primarySourceAreas"), ("tests", "tests"),
        ):
            parsed = unique_string_array(row.get(row_key))
            if parsed is None or not all(item.strip() for item in parsed):
                errors.append(f"{label}.{row_key} is invalid")
                parsed = []
            values[output_key] = tuple(parsed)
        if set(values["gates"]) != EXPECTED_FINDING_GATES[finding_id]:
            errors.append(f"{label}.gates differ")
        expected_source_indexes = IMPLEMENTATION_SOURCE_AREA_INDEXES.get(finding_id, ())
        expected_source_paths = SOURCE_AREA_PATHS.get(finding_id, ())
        expected_implementation_paths = IMPLEMENTATION_PATHS.get(finding_id, ())
        expected_test_ids = TEST_EXPECTATION_IDS.get(finding_id, ())
        if (
            len(expected_source_indexes) != len(values["implementation"])
            or any(
                not indexes
                or any(index < 0 or index >= len(values["sourceAreas"]) for index in indexes)
                for indexes in expected_source_indexes
            )
        ):
            errors.append(f"{label}: implementation source policy differs from controls")
        if (
            len(expected_source_paths) != len(values["sourceAreas"])
            or any(
                not paths
                or tuple(sorted(set(paths))) != paths
                for paths in expected_source_paths
            )
            or len(expected_implementation_paths) != len(values["implementation"])
            or any(
                not paths
                or tuple(sorted(set(paths))) != paths
                for paths in expected_implementation_paths
            )
        ):
            errors.append(f"{label}: exact source path policy differs from controls")
        if len(expected_test_ids) != len(values["tests"]):
            errors.append(f"{label}: test expectation policy differs from controls")
        controls[finding_id] = values
    if set(controls) != EXPECTED_FINDING_IDS:
        errors.append(f"{EXPECTED_FINDING_MATRIX}: finding IDs differ")
    return errors, controls


def expectation_matches_tests(
    expectation: str,
    test_ids: list[str],
    locked_rows: dict[str, dict[str, str]],
) -> bool:
    ignored = {
        "tests", "test", "source", "existing", "current", "assertion", "validation",
    }
    tokens = {
        token for token in re.findall(r"[a-z0-9]+", expectation.lower())
        if len(token) >= 5 and token not in ignored
    }
    corpus = " ".join(
        " ".join(locked_rows[test_id].values()).lower()
        for test_id in test_ids if test_id in locked_rows
    )
    aliases = {
        "deterministic": ("reproducibility", "byte-identical", "generator twice"),
        "regeneration": ("generator", "reproducibility"),
        "complete": ("completion", "release_candidate_ready"),
        "mislabel": ("status", "release_candidate_ready"),
    }
    return bool(tokens) and any(
        token in corpus
        or any(alias in corpus for alias in aliases.get(token, ()))
        for token in tokens
    )


def validate_defect_closure(
    path: Path,
    repository_root: Path,
    source_hash: str,
    known_gates: set[str],
    has_git: bool,
    record_gates_by_path: dict[str, set[str]],
    record_bound_files_by_path: dict[str, set[str]],
    manifest_files: set[str],
    baseline_changed_paths: set[str],
    baseline_changed_shipping_paths: set[str],
    baseline_deleted_paths: set[str],
    baseline_deleted_shipping_paths: set[str],
    locked_rows: dict[str, dict[str, str]],
    executions: dict[str, dict[str, Any]],
) -> list[str]:
    try:
        document = load_json(path)
    except (OSError, json.JSONDecodeError) as exception:
        return [f"DefectClosure.json is invalid or missing: {exception}"]
    if not isinstance(document, dict):
        return ["DefectClosure.json root must be an object"]
    required = {
        "schemaVersion", "sourceManifestSHA256", "sourceRevision", "version", "build",
        "findings",
    }
    if set(document) != required:
        return ["DefectClosure.json keys differ from the closure schema"]
    errors, finding_controls = load_locked_finding_controls(repository_root)
    expected = {
        "schemaVersion": "1.0",
        "sourceManifestSHA256": source_hash,
        "version": EXPECTED_VERSION,
        "build": EXPECTED_BUILD,
    }
    for key, value in expected.items():
        if document.get(key) != value:
            errors.append(f"DefectClosure.json: {key} differs")
    revision = document.get("sourceRevision")
    if has_git:
        if not isinstance(revision, str) or HEX_40.fullmatch(revision) is None:
            errors.append("DefectClosure.json: Git-backed closure requires sourceRevision")
        elif not git_revision_is_ancestor(repository_root, revision):
            errors.append("DefectClosure.json: sourceRevision is not an ancestor of HEAD")
    elif NO_GIT_CHILD_MODE:
        if revision is not None and (
            not isinstance(revision, str) or HEX_40.fullmatch(revision) is None
        ):
            errors.append("DefectClosure.json: copied-tree sourceRevision is invalid")
    elif revision is not None:
        errors.append("DefectClosure.json: sourceRevision must be null without Git")
    findings = document.get("findings")
    finding_ids: set[str] = set()
    if not isinstance(findings, list) or len(findings) != 12:
        errors.append("DefectClosure.json: findings must contain exactly 12 items")
        return errors
    required_finding_keys = {
        "id", "originalStatus", "changedFiles", "tests", "evidence", "finalStatus",
        "gateIDs", "implementationBindings", "sourceAreaBindings", "testBindings",
        "removedFiles", "removalBindings",
    }
    globally_bound_locked_files: set[str] = set()
    globally_bound_removed_files: set[str] = set()
    for index, finding in enumerate(findings):
        label = f"DefectClosure.json: findings[{index}]"
        if not isinstance(finding, dict) or set(finding) != required_finding_keys:
            errors.append(f"{label} keys differ from the closure schema")
            continue
        finding_id = finding.get("id")
        if (
            not isinstance(finding_id, str)
            or finding_id not in EXPECTED_FINDING_IDS
            or finding_id in finding_ids
        ):
            errors.append(f"{label} has an invalid or duplicate finding ID")
        else:
            finding_ids.add(finding_id)
        if (
            not isinstance(finding_id, str)
            or finding.get("originalStatus") != EXPECTED_FINDING_STATUSES.get(finding_id)
        ):
            errors.append(f"{label} originalStatus differs from the audited finding")
        if finding.get("finalStatus") != "CLOSED":
            errors.append(f"{label} finalStatus must be CLOSED")
        changed_files = finding.get("changedFiles")
        changed_file_set: set[str] | None = None
        parsed_changed_files = unique_string_array(changed_files, allow_empty=True)
        if parsed_changed_files is None:
            errors.append(f"{label} changedFiles are invalid or missing")
        else:
            changed_file_set = set(parsed_changed_files)
            if not all(
                item in manifest_files
                and repository_relative_file(item, repository_root)
                for item in parsed_changed_files
            ):
                errors.append(f"{label} changedFiles are not in the final source manifest")
        removal_policy = REMOVED_IMPLEMENTATION_PATHS.get(str(finding_id), {})
        expected_removed_files = {
            item for paths in removal_policy.values() for item in paths
        }
        globally_bound_removed_files.update(expected_removed_files)
        removed_files = finding.get("removedFiles")
        parsed_removed_files = unique_string_array(removed_files, allow_empty=True)
        if (
            parsed_removed_files is None
            or parsed_removed_files != sorted(expected_removed_files)
        ):
            errors.append(f"{label} removedFiles differ from the exact tombstone policy")
        removal_bindings = finding.get("removalBindings")
        if not isinstance(removal_bindings, dict) or set(removal_bindings) != set(
            removal_policy
        ):
            errors.append(f"{label} removalBindings differ from the exact removal policy")
        else:
            implementation_controls = set(
                (finding_controls.get(finding_id, {}) if isinstance(finding_id, str) else {})
                .get("implementation", ())
            )
            for expectation, expected_paths in removal_policy.items():
                paths = unique_string_array(
                    removal_bindings.get(expectation), allow_empty=True
                )
                if (
                    expectation not in implementation_controls
                    or paths != list(expected_paths)
                ):
                    errors.append(
                        f"{label} removalBindings[{expectation!r}] differs from its "
                        "locked implementation tombstone"
                    )
        if not expected_removed_files.issubset(baseline_deleted_paths):
            errors.append(
                f"{label} locked removal paths were not deleted from the exact baseline"
            )
        if expected_removed_files & manifest_files or any(
            (repository_root / relative).exists()
            for relative in expected_removed_files
        ):
            errors.append(f"{label} locked removal paths remain in the final source tree")
        control = finding_controls.get(finding_id, {}) if isinstance(finding_id, str) else {}
        binding_unions: dict[str, set[str]] = {}
        file_binding_values: dict[str, dict[str, list[str]]] = {}
        exact_path_policies = {
            "implementationBindings": IMPLEMENTATION_PATHS.get(str(finding_id), ()),
            "sourceAreaBindings": SOURCE_AREA_PATHS.get(str(finding_id), ()),
        }
        for binding_key, control_key in (
            ("implementationBindings", "implementation"),
            ("sourceAreaBindings", "sourceAreas"),
        ):
            bindings = finding.get(binding_key)
            ordered_expectations = tuple(control.get(control_key, ()))
            expectations = set(ordered_expectations)
            exact_policy = exact_path_policies[binding_key]
            if not isinstance(bindings, dict) or set(bindings) != expectations:
                errors.append(f"{label} {binding_key} must bind every locked expectation")
                continue
            normalized_bindings: dict[str, list[str]] = {}
            if len(exact_policy) != len(ordered_expectations):
                errors.append(f"{label} {binding_key} exact path policy is incomplete")
                continue
            for expectation_index, expectation in enumerate(ordered_expectations):
                paths = bindings.get(expectation)
                parsed_paths = unique_string_array(paths)
                if (
                    parsed_paths is None
                    or not all(
                        repository_relative_file(item, repository_root)
                        and item in manifest_files for item in parsed_paths or []
                    )
                ):
                    errors.append(f"{label} {binding_key}[{expectation!r}] is invalid")
                    continue
                expected_paths = list(exact_policy[expectation_index])
                if parsed_paths != expected_paths:
                    errors.append(
                        f"{label} {binding_key}[{expectation!r}] differs from its "
                        "exact source-manifest path tuple"
                    )
                normalized_bindings[expectation] = parsed_paths
                binding_unions.setdefault(binding_key, set()).update(parsed_paths)
            file_binding_values[binding_key] = normalized_bindings
        implementation_files = binding_unions.get("implementationBindings", set())
        source_area_files = binding_unions.get("sourceAreaBindings", set())
        expected_implementation_files = {
            item
            for paths in IMPLEMENTATION_PATHS.get(str(finding_id), ())
            for item in paths
        }
        expected_source_area_files = {
            item
            for paths in SOURCE_AREA_PATHS.get(str(finding_id), ())
            for item in paths
        }
        globally_bound_locked_files.update(
            expected_implementation_files | expected_source_area_files
        )
        expected_changed_files = expected_implementation_files & baseline_changed_paths
        if (
            parsed_changed_files is not None
            and parsed_changed_files != sorted(expected_changed_files)
        ):
            errors.append(
                f"{label} changedFiles differ from the baseline-changed exact locked "
                "implementation paths"
            )
        if expected_changed_files and not parsed_changed_files:
            errors.append(f"{label} omits baseline-changed implementation files")
        controls_source_or_scripts = any(
            not item.startswith("docs/")
            for item in expected_implementation_files | expected_source_area_files
        )
        if controls_source_or_scripts and not any(
            not item.startswith("docs/") for item in expected_changed_files
        ):
            errors.append(
                f"{label} has no baseline-changed non-document implementation file"
            )
        if implementation_files != expected_implementation_files:
            errors.append(f"{label} implementationBindings path union differs")
        if source_area_files != expected_source_area_files:
            errors.append(f"{label} sourceAreaBindings path union differs")
        if not implementation_files.issubset(source_area_files):
            errors.append(
                f"{label} implementationBindings must be grounded in locked source areas"
            )
        tests = finding.get("tests")
        if (
            not isinstance(tests, list)
            or not tests
            or not all(isinstance(item, str) and item.strip() for item in tests)
            or len(tests) != len(set(tests))
        ):
            errors.append(f"{label} tests are invalid")
        test_bindings = finding.get("testBindings")
        test_expectations = set(control.get("tests", ()))
        bound_test_ids: set[str] = set()
        bound_test_labels: set[str] = set()
        covered_finding_gates: set[str] = set()
        if not isinstance(test_bindings, dict) or set(test_bindings) != test_expectations:
            errors.append(f"{label} testBindings must bind every locked test expectation")
        else:
            ordered_expectations = tuple(control.get("tests", ()))
            exact_policy = TEST_EXPECTATION_IDS.get(str(finding_id), ())
            for expectation_index, expectation in enumerate(ordered_expectations):
                test_ids = test_bindings.get(expectation)
                parsed_ids = unique_string_array(test_ids)
                if parsed_ids is None or not set(parsed_ids).issubset(locked_rows):
                    errors.append(f"{label} testBindings[{expectation!r}] is invalid")
                    continue
                expected_ids = (
                    list(exact_policy[expectation_index])
                    if expectation_index < len(exact_policy) else []
                )
                if parsed_ids != expected_ids:
                    errors.append(
                        f"{label} testBindings[{expectation!r}] differs from its "
                        "expectation-specific locked test IDs"
                    )
                for test_id in parsed_ids:
                    if executions.get(test_id, {}).get("result") != "PASS":
                        errors.append(f"{label} testBindings references non-PASS {test_id}")
                    row_gates = set(locked_rows[test_id]["gateIDs"].split(";"))
                    if isinstance(finding_id, str):
                        relevant = row_gates & EXPECTED_FINDING_GATES.get(finding_id, set())
                        if not relevant:
                            errors.append(
                                f"{label} testBindings references {test_id} outside finding gates"
                            )
                        covered_finding_gates.update(relevant)
                    bound_test_ids.add(test_id)
                    bound_test_labels.add(
                        f"{test_id}: {locked_rows[test_id]['scenario']}"
                    )
        if isinstance(tests, list) and all(isinstance(item, str) for item in tests):
            if set(tests) != bound_test_labels:
                errors.append(f"{label} tests must exactly derive from testBindings")
        if isinstance(finding_id, str) and not EXPECTED_FINDING_GATES.get(
            finding_id, set()
        ).issubset(covered_finding_gates):
            errors.append(f"{label} testBindings do not cover every locked finding gate")
        evidence = finding.get("evidence")
        if (
            not isinstance(evidence, list)
            or not evidence
            or not all(isinstance(item, str) for item in evidence)
            or len(evidence) != len(set(evidence))
            or not set(evidence).issubset(record_gates_by_path)
        ):
            errors.append(f"{label} evidence must reference validated PASS records")
        gate_ids = finding.get("gateIDs")
        if (
            not isinstance(gate_ids, list)
            or not gate_ids
            or not all(isinstance(gate_id, str) for gate_id in gate_ids)
            or len(gate_ids) != len(set(gate_ids))
            or not set(gate_ids).issubset(known_gates)
        ):
            errors.append(f"{label} gateIDs are invalid")
        elif isinstance(finding_id, str) and set(gate_ids) != EXPECTED_FINDING_GATES.get(
            finding_id, set()
        ):
            errors.append(f"{label} gateIDs differ from the locked finding matrix")

        if (
            isinstance(evidence, list)
            and evidence
            and all(isinstance(item, str) for item in evidence)
            and set(evidence).issubset(record_gates_by_path)
            and isinstance(gate_ids, list)
            and all(isinstance(item, str) for item in gate_ids)
        ):
            evidenced_gates = set().union(
                *(record_gates_by_path[item] for item in evidence)
            )
            if not set(gate_ids).issubset(evidenced_gates):
                errors.append(f"{label} evidence does not cover every locked gate")
            evidence_bound_files = set().union(
                *(record_bound_files_by_path[item] for item in evidence)
            )
            if changed_file_set is not None and not changed_file_set.issubset(
                evidence_bound_files
            ):
                errors.append(
                    f"{label} evidence records do not bind every changed source file"
                )
            for test_id in sorted(bound_test_ids):
                execution = executions.get(test_id, {})
                log = execution.get("log")
                if not isinstance(log, str) or log not in evidence_bound_files:
                    errors.append(
                        f"{label} evidence records do not bind the exact test log for {test_id}"
                    )

    if finding_ids != EXPECTED_FINDING_IDS:
        errors.append("DefectClosure.json: finding IDs differ")
    missing_shipping_bindings = sorted(
        baseline_changed_shipping_paths - globally_bound_locked_files
    )
    if missing_shipping_bindings:
        errors.append(
            "DefectClosure.json: exact path policy omits baseline-changed shipping "
            "source/config/project paths: " + ", ".join(missing_shipping_bindings)
        )
    missing_shipping_tombstones = sorted(
        baseline_deleted_shipping_paths - globally_bound_removed_files
    )
    unexpected_shipping_tombstones = sorted(
        globally_bound_removed_files - baseline_deleted_shipping_paths
    )
    if missing_shipping_tombstones:
        errors.append(
            "DefectClosure.json: exact removal policy omits deleted shipping paths: "
            + ", ".join(missing_shipping_tombstones)
        )
    if unexpected_shipping_tombstones:
        errors.append(
            "DefectClosure.json: exact removal policy names paths not deleted from "
            "the baseline: " + ", ".join(unexpected_shipping_tombstones)
        )
    return errors


def main() -> int:
    global NO_GIT_CHILD_MODE
    parser = argparse.ArgumentParser()
    parser.add_argument("--gates", type=Path, default=DEFAULT_GATES)
    parser.add_argument("--evidence-root", type=Path, default=DEFAULT_EVIDENCE_ROOT)
    parser.add_argument("--source-manifest", type=Path, default=DEFAULT_SOURCE_MANIFEST)
    parser.add_argument(
        "--binding-only",
        action="store_true",
        help="validate present evidence bindings without requiring terminal completion",
    )
    parser.add_argument("--no-git-child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--expected-source-hash", help=argparse.SUPPRESS)
    args = parser.parse_args()
    NO_GIT_CHILD_MODE = args.no_git_child

    errors: list[str] = []
    repository_root = ROOT.resolve()
    evidence_root = args.evidence_root.resolve()
    manifest_path = args.source_manifest.resolve()
    gates_path = args.gates.resolve()

    if args.no_git_child:
        if args.binding_only:
            errors.append("--no-git-child may not suppress terminal validation")
        if os.path.lexists(repository_root / ".git") or git_available(repository_root):
            errors.append("--no-git-child is forbidden in a normal Git worktree")
        if (
            not isinstance(args.expected_source_hash, str)
            or HEX_64.fullmatch(args.expected_source_hash) is None
        ):
            errors.append("--no-git-child requires one exact expected source hash")
    elif args.expected_source_hash is not None:
        errors.append("--expected-source-hash is valid only for the copied-tree child")

    expected_gates_path = evidence_root / "REMEDIATION-GATES-v1.0.json"
    expected_manifest_path = evidence_root / "SOURCE-MANIFEST.json"
    if evidence_root != DEFAULT_EVIDENCE_ROOT.resolve():
        errors.append("evidence root must be docs/verification/remediation-v1")
    if gates_path != expected_gates_path:
        errors.append("gate catalog must be the locked catalog in the evidence root")
    if manifest_path != expected_manifest_path:
        errors.append("source manifest must be SOURCE-MANIFEST.json in the evidence root")
    if repository_relative(evidence_root, repository_root) is None:
        errors.append("evidence root must be inside the repository")

    try:
        gate_catalog_digest = sha256_file(gates_path)
    except OSError as exception:
        errors.append(f"invalid or missing gate catalog: {exception}")
        gate_catalog_digest = ""
    if gate_catalog_digest != EXPECTED_GATE_CATALOG_SHA256:
        errors.append("gate catalog differs from the locked remediation control")
    try:
        gates = load_json(gates_path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        errors.append(f"invalid or missing gate catalog: {exception}")
        gates = {}
    gate_records_value = gates.get("gates") if isinstance(gates, dict) else None
    gate_records = gate_records_value if isinstance(gate_records_value, list) else []
    if not gate_records:
        errors.append("gate catalog root or gates array is invalid")
    known_gates = {
        record.get("id")
        for record in gate_records
        if isinstance(record, dict) and isinstance(record.get("id"), str)
    }
    required = {
        record.get("id")
        for record in gate_records
        if (
            isinstance(record, dict)
            and isinstance(record.get("id"), str)
            and record.get("required") is True
        )
    }
    if known_gates != EXPECTED_GATE_IDS or required != EXPECTED_GATE_IDS:
        errors.append("gate catalog must contain exactly 42 required RC-001 through RC-042 gates")
    gate_requirements: dict[str, set[str]] = {}
    for record in gate_records:
        if not isinstance(record, dict) or not isinstance(record.get("id"), str):
            continue
        claims = unique_string_array(record.get("requiredEvidence"))
        if claims is None or not all(claim.strip() for claim in claims):
            errors.append(f"gate catalog {record['id']} requiredEvidence is invalid")
            continue
        gate_requirements[record["id"]] = set(claims)
    if set(gate_requirements) != EXPECTED_GATE_IDS:
        errors.append("gate catalog evidence requirements are incomplete")

    if not args.binding_only:
        errors.extend(validate_version_surfaces(repository_root))
    source_hash = validate_source_manifest(repository_root, manifest_path, errors)
    if args.no_git_child and args.expected_source_hash != source_hash:
        errors.append("copied-tree source hash differs from the parent-bound hash")
    try:
        manifest_document_value = load_json(manifest_path)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        manifest_document_value = {}
    manifest_document = (
        manifest_document_value if isinstance(manifest_document_value, dict) else {}
    )
    manifest_files = {
        record.get("path")
        for record in manifest_document.get("files", [])
        if isinstance(record, dict) and isinstance(record.get("path"), str)
    } if isinstance(manifest_document.get("files"), list) else set()
    baseline_changed_paths: set[str] = set()
    baseline_changed_shipping_paths: set[str] = set()
    baseline_deleted_paths: set[str] = set()
    baseline_deleted_shipping_paths: set[str] = set()

    has_git = git_available(repository_root)
    locked_rows: dict[str, dict[str, str]] = {}
    executions: dict[str, dict[str, Any]] = {}
    test_revision: str | None = None
    suite_results: dict[str, dict[str, Any]] = {}
    if not args.binding_only:
        errors.extend(validate_ipad_schema_file(repository_root))
        test_errors, locked_rows, executions, test_revision = validate_test_execution_index(
            repository_root, source_hash, has_git
        )
        errors.extend(test_errors)
        (
            baseline_errors,
            baseline_changed_paths,
            baseline_changed_shipping_paths,
            baseline_deleted_paths,
            baseline_deleted_shipping_paths,
        ) = baseline_changed_manifest_paths(
            repository_root,
            manifest_document,
            has_git=has_git,
            source_revision=test_revision,
        )
        errors.extend(baseline_errors)
        suite_errors, suite_results = validate_structured_suite_results(
            repository_root,
            source_hash,
            test_revision,
            locked_rows,
            executions,
        )
        errors.extend(suite_errors)
        cloud_errors, cloud_document = validate_domain_result_report(
            repository_root,
            relative=CLOUD_GAME_CENTER_RESULTS,
            source_hash=source_hash,
            source_revision=test_revision,
            expected_test_ids=("T-096", "T-097"),
            expected_markers=CLOUD_GAME_CENTER_MARKERS,
            suite_results=suite_results,
            executions=executions,
            performance=False,
        )
        errors.extend(cloud_errors)
        performance_errors, performance_document = validate_domain_result_report(
            repository_root,
            relative=PERFORMANCE_RESOURCE_RESULTS,
            source_hash=source_hash,
            source_revision=test_revision,
            expected_test_ids=("T-116",),
            expected_markers=PERFORMANCE_RESOURCE_MARKERS,
            suite_results=suite_results,
            executions=executions,
            performance=True,
        )
        errors.extend(performance_errors)
        domain_log_errors: list[str] = []
        if not cloud_errors and not performance_errors:
            domain_log_errors = validate_domain_execution_log(
                repository_root,
                cloud_document,
                performance_document,
            )
            errors.extend(domain_log_errors)
        if not cloud_errors and not performance_errors and not domain_log_errors:
            errors.extend(validate_domain_capture_replay(
                repository_root,
                manifest_path,
                test_revision,
                cloud_document,
            ))
        errors.extend(validate_no_git_qualification_document(
            repository_root, source_hash, test_revision, executions
        ))
        errors.extend(validate_completion_checker_log(
            repository_root,
            git_backed_source=has_git or (
                args.no_git_child and isinstance(test_revision, str)
            ),
        ))
        errors.extend(validate_test_summary(
            repository_root, source_hash, test_revision, executions
        ))
        mac_app_path = (
            repository_root / "artifacts/remediation-v1/RuneScrib-macOS-Release.app.zip"
        )
        ios_app_path = (
            repository_root
            / "artifacts/remediation-v1/RuneScrib-iPhoneSimulator-Release.app.zip"
        )
        mac_data = (
            mac_app_path.read_bytes()
            if mac_app_path.is_file() and not mac_app_path.is_symlink()
            else b""
        )
        ios_data = (
            ios_app_path.read_bytes()
            if ios_app_path.is_file() and not ios_app_path.is_symlink()
            else b""
        )
        errors.extend(validate_app_zip(mac_data, "macOS", "external macOS product"))
        errors.extend(validate_app_zip(ios_data, "iOS", "external iOS product"))
        ipad_path = (
            repository_root
            / "artifacts/remediation-v1/RuneScrib-iPadSimulator-Qualification.json"
        )
        try:
            ipad_document = load_json(ipad_path)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
            errors.append(f"iPad qualification is invalid or missing: {exception}")
            ipad_document = {}
        errors.extend(validate_ipad_qualification_document(
            ipad_document,
            repository_root=repository_root,
            source_hash=source_hash,
            source_revision=test_revision,
            locked_rows=locked_rows,
            executions=executions,
            ios_product_digest=hashlib.sha256(ios_data).hexdigest(),
        ))
        errors.extend(validate_publication_audit_record(
            repository_root, source_hash, test_revision, executions
        ))
    index_errors: list[str] = []
    indexed_records: list[str] = []
    indexed_supporting: list[str] = []
    index_revision: str | None = None
    index_path = evidence_root / EVIDENCE_INDEX
    if not args.binding_only or index_path.exists():
        (
            index_errors,
            indexed_records,
            indexed_supporting,
            index_revision,
        ) = validate_evidence_index(
            evidence_root,
            repository_root,
            source_hash,
            has_git,
        )
        errors.extend(index_errors)

    if indexed_records:
        record_paths = [
            repository_root / relative
            for relative in indexed_records
            if repository_relative_file(relative, repository_root)
            and (repository_root / relative).resolve().is_relative_to(evidence_root)
        ]
    elif evidence_root.is_dir():
        record_paths = [
            path for path in sorted(evidence_root.rglob("*.json"))
            if not (
                "/" not in path.relative_to(evidence_root).as_posix()
                and path.name in (EVIDENCE_EXEMPT | {"CompletionReport.json"})
            )
        ]
    else:
        errors.append(f"evidence root is missing: {evidence_root}")
        record_paths = []

    for relative in indexed_supporting:
        if (
            not repository_relative_file(relative, repository_root)
            or not (repository_root / relative).resolve().is_relative_to(evidence_root)
        ):
            continue
        path = repository_root / relative
        try:
            supporting = load_json(path)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
            errors.append(f"{path}: invalid supporting JSON: {exception}")
            continue
        if not isinstance(supporting, (dict, list)):
            errors.append(f"{path}: supporting JSON root must be an object or array")

    if not args.binding_only:
        errors.extend(validate_claim_evidence_documents(
            repository_root,
            source_hash=source_hash,
            source_revision=test_revision,
            gate_requirements=gate_requirements,
            locked_rows=locked_rows,
            executions=executions,
            suite_results=suite_results,
            indexed_supporting=indexed_supporting,
        ))

    passed: set[str] = set()
    covered_requirements: dict[str, set[str]] = {
        gate_id: set() for gate_id in known_gates
    }
    record_ids: set[str] = set()
    record_gates_by_path: dict[str, set[str]] = {}
    record_bound_files_by_path: dict[str, set[str]] = {}
    record_revisions: list[object] = []
    record_count = 0
    for path in record_paths:
        try:
            record = load_json(path)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
            errors.append(f"{path}: invalid JSON: {exception}")
            continue
        record_count += 1
        if isinstance(record, dict):
            record_revisions.append(record.get("sourceRevision"))
        findings, gate_passes, record_id, claims_by_gate = validate_evidence_record(
            path,
            record,
            repository_root,
            source_hash,
            known_gates,
            gate_requirements,
            has_git,
            not index_errors and index_path.is_file() and not index_path.is_symlink(),
        )
        errors.extend(findings)
        passed.update(gate_passes)
        for gate_id, claims in claims_by_gate.items():
            covered_requirements.setdefault(gate_id, set()).update(claims)
        relative = repository_relative(path, repository_root)
        if relative is not None and gate_passes:
            record_gates_by_path[relative] = gate_passes
            bound = {relative}
            if isinstance(record, dict):
                for key in ("artifacts", "logs"):
                    value = record.get(key)
                    if isinstance(value, list):
                        bound.update(item for item in value if isinstance(item, str))
            record_bound_files_by_path[relative] = bound
        if record_id is not None:
            if record_id in record_ids:
                errors.append(f"{path}: duplicate recordID {record_id}")
            record_ids.add(record_id)

    if args.binding_only:
        if record_count == 0:
            errors.append("binding-only validation found no remediation evidence records")
    else:
        missing = sorted(required - passed)
        if missing:
            errors.append("Missing valid PASS evidence for: " + ", ".join(missing))
        for gate_id in sorted(required):
            missing_claims = sorted(
                gate_requirements.get(gate_id, set())
                - covered_requirements.get(gate_id, set())
            )
            if missing_claims:
                errors.append(
                    f"Missing required evidence claims for {gate_id}: "
                    + ", ".join(missing_claims)
                )

        completion_path = evidence_root / "CompletionReport.json"
        try:
            completion = load_json(completion_path)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
            errors.append(f"CompletionReport.json is invalid or missing: {exception}")
            completion = {}
        errors.extend(validate_completion_report(
            completion_path,
            completion,
            repository_root,
            source_hash,
            known_gates,
            has_git,
            record_gates_by_path,
            locked_rows,
            executions,
        ))

        defect_path = evidence_root / "DefectClosure.json"
        errors.extend(validate_defect_closure(
            defect_path,
            repository_root,
            source_hash,
            known_gates,
            has_git,
            record_gates_by_path,
            record_bound_files_by_path,
            manifest_files,
            baseline_changed_paths,
            baseline_changed_shipping_paths,
            baseline_deleted_paths,
            baseline_deleted_shipping_paths,
            locked_rows,
            executions,
        ))
        try:
            defect = load_json(defect_path)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            defect = {}
        completion_closures = (
            completion.get("findingClosures") if isinstance(completion, dict) else None
        )
        defect_findings = defect.get("findings") if isinstance(defect, dict) else None
        if isinstance(completion_closures, list) and isinstance(defect_findings, list):
            completion_evidence = {
                item.get("id"): set(item.get("evidence", []))
                for item in completion_closures
                if isinstance(item, dict)
                and isinstance(item.get("id"), str)
                and isinstance(item.get("evidence"), list)
                and all(isinstance(value, str) for value in item["evidence"])
            }
            defect_evidence = {
                item.get("id"): set(item.get("evidence", []))
                for item in defect_findings
                if isinstance(item, dict)
                and isinstance(item.get("id"), str)
                and isinstance(item.get("evidence"), list)
                and all(isinstance(value, str) for value in item["evidence"])
            }
            if (
                set(completion_evidence) != EXPECTED_FINDING_IDS
                or set(defect_evidence) != EXPECTED_FINDING_IDS
                or completion_evidence != defect_evidence
            ):
                errors.append(
                    "CompletionReport.json and DefectClosure.json finding evidence sets differ"
                )
        errors.extend(validate_completion_markdown(evidence_root, source_hash))

        revision_values = list(record_revisions)
        revision_values.extend([
            index_revision,
            test_revision,
            completion.get("sourceRevision") if isinstance(completion, dict) else None,
            defect.get("sourceRevision") if isinstance(defect, dict) else None,
        ])
        source_revision: str | None = None
        if has_git:
            if (
                not revision_values
                or not all(
                    isinstance(value, str) and HEX_40.fullmatch(value) is not None
                    for value in revision_values
                )
                or len(set(revision_values)) != 1
            ):
                errors.append("all terminal evidence must bind one exact sourceRevision")
            else:
                source_revision = revision_values[0]
        elif args.no_git_child:
            if (
                not revision_values
                or any(
                    value is not None and not isinstance(value, str)
                    for value in revision_values
                )
                or len({value for value in revision_values if value is None or isinstance(value, str)}) != 1
            ):
                errors.append(
                    "all copied-tree terminal evidence must retain one opaque sourceRevision"
                )
        elif any(value is not None for value in revision_values):
            errors.append("all no-Git terminal evidence sourceRevision values must be null")

        if source_revision is not None and manifest_document:
            errors.extend(validate_revision_projection(
                repository_root,
                source_revision,
                manifest_document,
            ))

        if not errors and not args.no_git_child:
            errors.extend(run_copied_tree_no_git_check(repository_root, source_hash))

    if errors:
        for finding in sorted(set(errors)):
            print(f"FAIL: {finding}", file=sys.stderr)
        return 1
    if args.no_git_child:
        sys.stdout.write(NO_GIT_CHILD_OUTPUT)
        return 0
    mode = "present evidence records" if args.binding_only else f"{len(required)} required gates"
    metadata = (
        "Git revision and source manifest"
        if has_git
        else "source manifest without Git ancestry"
    )
    print(f"PASS: {mode} validate against one source tree ({metadata})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
