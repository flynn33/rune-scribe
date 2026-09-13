#!/usr/bin/env python3
"""Execute source-bound domain qualification and emit deterministic evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from typing import Any
import unicodedata
import zipfile


SCHEMA_VERSION = "1.0"
VERSION = "1.0.40"
BUILD = "40"
EXPECTED_BUNDLE_IDENTIFIER = "com.runescribe.app"
EXPECTED_CLOUD_CONTAINER = "iCloud.com.runescribe.app"
PACKAGE_PATH = "Packages/RuneScribeArchitecture"
PRODUCER_PATH = "scripts/capture-remediation-domain-results.py"
PREVIEW_OUTPUT_ENV = "RUNE_SCRIBE_PREVIEW_QUALIFICATION_OUTPUT"
PREVIEW_TEST = (
    "RuneScribeUIModuleTests.ShareArtifactRendererTests/"
    "testStaticRendererProducesBoundedFourByThreePreview"
)
BUILT_PRODUCT_INSPECTION = (
    "docs/verification/remediation-v1/GateRun/Built-Product-Inspection.json"
)
SHIPPING_CHECKER_PATH = "scripts/check-shipping-products.sh"
EXPECTED_SHIPPING_CHECKER_SHA256 = (
    "8ab315354440eeaca9fc2798d6a58c2855b630becb42cda7e619d7adfd5bffe0"
)
EXPECTED_SHIPPING_CHECK_COUNT = 101
SHIPPING_VALIDATION_LOG = (
    "docs/verification/remediation-v1/GateRun/shipping-products.log"
)
LOCKED_SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

CLOUD_MARKERS = (
    "deterministic-offline-unavailable", "queue", "retry-merge",
    "account-change", "corruption-quarantine", "monotonic-reporting",
    "no-ownership-path", "privacy-offline-utility",
    "built-entitlement-configuration-inspection",
)
PERFORMANCE_MARKERS = (
    "preview-churn-cancel", "large-inscriptions", "cache-release",
    "optional-provider-fallback", "bounded-session-retention",
    "preview-under-4-mib", "preview-4:3", "theme-budgets",
)

CLOUD_TEST_SOURCES = {
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

PERFORMANCE_TEST_SOURCES = {
    "RuneScribeUIModuleTests.ShareBuilderModelTests/testRapidPreviewGenerationsRejectEveryStaleCompletionAndInvalidation":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/ShareBuilderModelTests.swift",
    "RuneScribeUIModuleTests.ShareArtifactRendererTests/testRenderPlanCoversShortMediumLongPaginatedAndOverflowInscriptions":
        "Packages/RuneScribeArchitecture/Tests/RuneScribeUIModuleTests/ShareArtifactRendererTests.swift",
    PREVIEW_TEST:
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
ALL_TEST_SOURCES = {**CLOUD_TEST_SOURCES, **PERFORMANCE_TEST_SOURCES}

CLOUD_CASE_TESTS = {
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

PERFORMANCE_CASE_TESTS = {
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
    "preview-under-4-mib": (PREVIEW_TEST,),
    "preview-4:3": (PREVIEW_TEST,),
    "theme-budgets": tuple(
        identifier for identifier in PERFORMANCE_TEST_SOURCES
        if "testProductionResourcesPassPhysicalBudgets" in identifier
        or "testModuleManifestAndImmutableResourcesRemainExact" in identifier
    ),
}

THEME_SPECS = (
    (
        "Norse", "RuneScribeArchitecture_RuneScribeNorseThemeModule.bundle",
        "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Metadata/Norse-Resource-Integrity-Manifest-v2.0.json",
        "Norse-Resource-Integrity-Manifest-v2.0.json", "resources", "byteLength",
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

RESERVED_LOG_PREFIXES = (
    "domainExecution=", "semanticCase=", "previewMeasurement=",
    "themeBudgetInspection=", "productInspection=", "shippingProductValidation=",
    "domainCaptureResult=",
    "semanticMarker=", "metric.",
)
ENTITLEMENT_SUFFIXES = (".xcent", ".entitlements")
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


class CaptureError(ValueError):
    """Raised when executable qualification cannot support the locked claims."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def execution_environment(**updates: str) -> dict[str, str]:
    return {
        **os.environ,
        "PATH": LOCKED_SYSTEM_PATH,
        "LC_ALL": "C",
        "LANG": "C",
        **updates,
    }


def canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def write_json(path: Path, document: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_json(path: Path, label: str) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exception:
        raise CaptureError(f"{label} is invalid: {exception}") from exception


def safe_member_name(name: str) -> bool:
    pure = PurePosixPath(name)
    return bool(name) and not pure.is_absolute() and ".." not in pure.parts and not any(
        marker in name for marker in ("\\", "\0")
    )


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
        return {"sha256": sha256_bytes(value), "bytes": len(value)}
    return str(value)


def normalized_relative(path: Path, root: Path, label: str) -> str:
    try:
        relative = path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as exception:
        raise CaptureError(f"{label} must be inside the repository root") from exception
    if not relative or ".." in PurePosixPath(relative).parts:
        raise CaptureError(f"{label} is unsafe")
    return relative


def safe_extract_app_zip(path: Path, destination: Path, label: str) -> Path:
    """Extract one canonical, regular-file-only RuneScrib.app archive."""
    try:
        with zipfile.ZipFile(path) as archive:
            entries: dict[str, zipfile.ZipInfo] = {}
            destination_aliases: dict[tuple[str, ...], tuple[str, ...]] = {}
            for info in archive.infolist():
                raw_name = info.filename
                name = raw_name.rstrip("/")
                canonical_name = PurePosixPath(raw_name).as_posix().rstrip("/")
                if (
                    not safe_member_name(raw_name)
                    or not name
                    or name != canonical_name
                ):
                    raise CaptureError(f"{label} contains an unsafe ZIP member")
                if name in entries:
                    raise CaptureError(f"{label} contains duplicate ZIP member {name}")
                parts = PurePosixPath(name).parts
                if not parts or parts[0] != "RuneScrib.app":
                    raise CaptureError(f"{label} contains files outside RuneScrib.app")
                for depth in range(1, len(parts) + 1):
                    original_prefix = parts[:depth]
                    destination_key = tuple(
                        unicodedata.normalize("NFC", part).casefold()
                        for part in original_prefix
                    )
                    prior_prefix = destination_aliases.setdefault(
                        destination_key, original_prefix
                    )
                    if prior_prefix != original_prefix:
                        raise CaptureError(
                            f"{label} contains colliding destination aliases"
                        )
                mode = (info.external_attr >> 16) & 0xFFFF
                kind = stat.S_IFMT(mode)
                if kind == stat.S_IFLNK:
                    raise CaptureError(f"{label} contains archive symlink {name}")
                elif not info.is_dir() and kind not in {0, stat.S_IFREG}:
                    raise CaptureError(f"{label} contains unsupported ZIP member {name}")
                entries[name] = info
            if not entries:
                raise CaptureError(f"{label} contains no app members")

            for name, info in sorted(entries.items()):
                target = destination.joinpath(*PurePosixPath(name).parts)
                app_root = destination / "RuneScrib.app"
                try:
                    target.resolve(strict=False).relative_to(app_root.resolve(strict=False))
                except ValueError as exception:
                    raise CaptureError(
                        f"{label} member escapes the canonical app root"
                    ) from exception
                target.parent.mkdir(parents=True, exist_ok=True)
                if info.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                mode = (info.external_attr >> 16) & 0xFFFF
                target.write_bytes(archive.read(info))
                target.chmod(stat.S_IMODE(mode) or 0o644)
    except zipfile.BadZipFile as exception:
        raise CaptureError(f"{label} is not a valid ZIP") from exception
    app = destination / "RuneScrib.app"
    if not app.is_dir() or app.is_symlink():
        raise CaptureError(f"{label} does not extract to one regular RuneScrib.app")
    return app


def run_shipping_product_validation(
    *, root: Path, macos_zip: Path, ios_zip: Path, output_relative: str
) -> tuple[dict[str, Any], bytes]:
    checker = root / SHIPPING_CHECKER_PATH
    if (
        not checker.is_file()
        or checker.is_symlink()
        or sha256_file(checker) != EXPECTED_SHIPPING_CHECKER_SHA256
    ):
        raise CaptureError("shipping-product checker differs from the locked executable")
    with tempfile.TemporaryDirectory(prefix="runescribe-shipping-products-") as temporary:
        extraction = Path(temporary)
        macos_app = safe_extract_app_zip(
            macos_zip, extraction / "macOS", "macOS app ZIP"
        )
        ios_app = safe_extract_app_zip(
            ios_zip, extraction / "iOS", "iOS app ZIP"
        )
        command = [
            "/bin/bash", SHIPPING_CHECKER_PATH,
            "--macos-app", str(macos_app),
            "--ios-app", str(ios_app),
        ]
        result = subprocess.run(
            command,
            cwd=root,
            check=False,
            capture_output=True,
            env=execution_environment(),
            timeout=900,
        )
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).decode(
            "utf-8", errors="replace"
        ).strip()[-4000:]
        raise CaptureError(f"shipping-product checker failed: {detail}")
    if result.stderr:
        raise CaptureError("shipping-product checker emitted unexpected stderr")
    try:
        output_text = result.stdout.decode("utf-8")
    except UnicodeDecodeError as exception:
        raise CaptureError("shipping-product checker output is not UTF-8") from exception
    expected_summary = (
        f"Shipping-product inspection: {EXPECTED_SHIPPING_CHECK_COUNT} checks, "
        "0 failures."
    )
    expected_terminal = "T-028 shipping-product/configuration inspection passed."
    lines = output_text.splitlines()
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
        or not output_text.endswith("\n")
    ):
        raise CaptureError("shipping-product checker output semantics differ")
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
        "log": output_relative,
        "logSHA256": sha256_bytes(result.stdout),
    }
    return summary, result.stdout


def inspect_theme_budgets(
    archive: zipfile.ZipFile,
    files: dict[str, zipfile.ZipInfo],
    root: Path,
    platform: str,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for theme, bundle_name, source_relative, manifest_name, entries_key, bytes_key in THEME_SPECS:
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
            raise CaptureError(
                f"{platform} app ZIP must contain one {theme} shipping resource manifest"
            )
        manifest_member = candidates[0]
        manifest_bytes = archive.read(files[manifest_member])
        source_path = root / source_relative
        if not source_path.is_file() or manifest_bytes != source_path.read_bytes():
            raise CaptureError(
                f"{platform} {theme} resource manifest differs from current source"
            )
        try:
            document = json.loads(manifest_bytes)
        except (UnicodeDecodeError, json.JSONDecodeError) as exception:
            raise CaptureError(f"{platform} {theme} resource manifest is invalid") from exception
        entries = document.get(entries_key) if isinstance(document, dict) else None
        if not isinstance(entries, list) or not entries:
            raise CaptureError(f"{platform} {theme} resource inventory is empty")
        bundle_prefix = manifest_member[: -len(manifest_name)]
        resource_root = root / source_relative.split("/Resources/", 1)[0] / "Resources"
        expected_source_files: dict[str, Path] = {}
        for source_file in sorted(resource_root.rglob("*")):
            if not source_file.is_file():
                continue
            source_parts = source_file.relative_to(resource_root).parts
            if theme == "Norse" and source_parts and source_parts[0] == "Source":
                continue
            if source_file.name.startswith("."):
                continue
            if source_file.name in expected_source_files:
                raise CaptureError(f"{theme} shipping resources have a flattened-name collision")
            expected_source_files[source_file.name] = source_file
        actual_bundle_members = {
            name[len(bundle_prefix):]: name
            for name in files
            if name.startswith(bundle_prefix) and name[len(bundle_prefix):]
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
            raise CaptureError(
                f"{platform} {theme} complete bundle inventory differs; "
                f"missing={sorted(missing)} unexpected={sorted(unexpected)}"
            )
        for basename, source_file in expected_source_files.items():
            member_data = archive.read(files[actual_bundle_members[basename]])
            if member_data != source_file.read_bytes():
                raise CaptureError(
                    f"{platform} {theme} bundle member differs from source: {basename}"
                )
        seen_members: set[str] = set()
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict):
                raise CaptureError(f"{platform} {theme} resource {index} is invalid")
            relative = entry.get("path")
            expected_bytes = entry.get(bytes_key)
            expected_digest = entry.get("sha256")
            if (
                not isinstance(relative, str) or not relative
                or type(expected_bytes) is not int or expected_bytes <= 0
                or not isinstance(expected_digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", expected_digest) is None
            ):
                raise CaptureError(f"{platform} {theme} resource {index} metadata is invalid")
            member = bundle_prefix + PurePosixPath(relative).name
            if member in seen_members or member not in files:
                raise CaptureError(
                    f"{platform} {theme} resource is missing or duplicated: {relative}"
                )
            seen_members.add(member)
            data = archive.read(files[member])
            if len(data) != expected_bytes or sha256_bytes(data) != expected_digest:
                raise CaptureError(
                    f"{platform} {theme} resource differs from its manifest: {relative}"
                )
        physical_members = [files[name] for name in actual_bundle_members.values()]
        total = sum(info.file_size for info in physical_members)
        largest = max((info.file_size for info in physical_members), default=0)
        static_bytes = sum(
            info.file_size for basename, member in actual_bundle_members.items()
            if PurePosixPath(basename).suffix.lower() in {".png", ".heif", ".pdf"}
            for info in (files[member],)
        )
        font_bytes = sum(
            info.file_size for basename, member in actual_bundle_members.items()
            if PurePosixPath(basename).suffix.lower() in {".ttf", ".otf"}
            for info in (files[member],)
        )
        animation_names = {
            PurePosixPath(str(entry.get("path"))).name
            for entry in entries
            if str(entry.get("semanticRole", entry.get("role", "")))
            == "unlock-animation-cue"
            or "animation" in str(entry.get("semanticRole", entry.get("role", "")))
        }
        animation_bytes = sum(
            files[member].file_size for basename, member in actual_bundle_members.items()
            if basename in animation_names
        )
        sound_bytes = sum(
            info.file_size for basename, member in actual_bundle_members.items()
            if PurePosixPath(basename).suffix.lower() in {".wav", ".caf", ".m4a"}
            for info in (files[member],)
        )
        limits = {
            "uniquePhysicalBytes": 112 * 1024 * 1024,
            "largestResourceBytes": 8 * 1024 * 1024,
            "staticImageBytes": (
                96 * 1024 * 1024
            ),
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
            raise CaptureError(f"{platform} {theme} resource budget fails")
        results.append({
            "platform": platform, "theme": theme,
            "manifestPath": manifest_member,
            "manifestSHA256": sha256_bytes(manifest_bytes),
            "sourceManifestPath": source_relative,
            "resourceCount": len(actual_bundle_members), "observed": observed,
            "limits": limits, "result": "PASS",
        })
    return results


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


def executable_entitlements(
    executable_bytes: bytes,
    *,
    platform: str,
    simulator: bool,
) -> tuple[list[str], list[dict[str, Any]]]:
    with tempfile.TemporaryDirectory(prefix="runescribe-built-entitlements-") as temporary:
        executable = Path(temporary) / "RuneScrib"
        executable.write_bytes(executable_bytes)
        executable.chmod(0o755)
        lipo = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(executable)], check=False,
            capture_output=True, text=True, timeout=60,
        )
        architectures = lipo.stdout.split() if lipo.returncode == 0 else []
        if platform == "macOS":
            if architectures != ["arm64"]:
                raise CaptureError("macOS executable architecture set must be exactly arm64")
            expected_platform = "1"
        else:
            if not architectures or any(item not in {"arm64", "x86_64"} for item in architectures):
                raise CaptureError("iOS Simulator executable architecture set is invalid")
            expected_platform = "7"
        inspections: list[dict[str, Any]] = []
        normalized_entitlements: list[object] = []
        for architecture in architectures:
            load_commands = subprocess.run(
                ["/usr/bin/otool", "-arch", architecture, "-l", str(executable)],
                check=False, capture_output=True, text=True, timeout=60,
            )
            if load_commands.returncode != 0:
                raise CaptureError(f"cannot inspect {platform} {architecture} load commands")
            platforms: list[str] = []
            lines = load_commands.stdout.splitlines()
            for index, line in enumerate(lines):
                if line.strip() != "cmd LC_BUILD_VERSION":
                    continue
                for candidate in lines[index + 1:index + 9]:
                    if candidate.strip().startswith("platform "):
                        platforms.append(candidate.split()[-1])
                        break
            if not platforms or any(value != expected_platform for value in platforms):
                raise CaptureError(
                    f"{platform} {architecture} LC_BUILD_VERSION platform differs"
                )
            method: str
            entitlement_bytes: bytes
            if simulator:
                otool = subprocess.run(
                    [
                        "/usr/bin/otool", "-arch", architecture, "-X", "-s",
                        "__TEXT", "__entitlements", str(executable),
                    ],
                    check=False, capture_output=True, text=True, timeout=60,
                )
                if otool.returncode != 0:
                    raise CaptureError(
                        f"cannot extract {platform} {architecture} embedded entitlements"
                    )
                decoded = bytearray()
                for line in otool.stdout.splitlines():
                    fields = line.split()
                    for word in fields[1:]:
                        if re.fullmatch(r"[0-9a-fA-F]+", word) and len(word) % 2 == 0:
                            decoded.extend(bytes.fromhex(word)[::-1])
                entitlement_bytes = bytes(decoded).rstrip(b"\0")
                method = "otool-__TEXT-__entitlements"
            else:
                codesign = subprocess.run(
                    [
                        "/usr/bin/codesign", "-d", "--arch", architecture,
                        "--entitlements", ":-", str(executable),
                    ],
                    check=False, capture_output=True, timeout=60,
                )
                if codesign.returncode != 0:
                    raise CaptureError(
                        f"cannot extract {platform} {architecture} signed entitlements"
                    )
                entitlement_bytes = codesign.stdout
                method = "codesign"
            try:
                entitlement = plistlib.loads(entitlement_bytes)
            except (plistlib.InvalidFileException, ValueError) as exception:
                raise CaptureError(
                    f"{platform} {architecture} entitlements are not a plist"
                ) from exception
            if not isinstance(entitlement, dict):
                raise CaptureError(f"{platform} {architecture} entitlements are not a dictionary")
            policy_errors = entitlement_policy_errors(
                entitlement, platform=platform, architecture=architecture
            )
            if policy_errors:
                raise CaptureError("; ".join(policy_errors))
            normalized = json_safe_plist_value(entitlement)
            normalized_entitlements.append(normalized)
            inspections.append({
                "architecture": architecture,
                "method": method,
                "sha256": sha256_bytes(canonical_json(normalized).encode("utf-8")),
                "entitlements": normalized,
            })
        if len({canonical_json(value) for value in normalized_entitlements}) != 1:
            raise CaptureError(f"{platform} entitlements differ across executable architectures")
        return architectures, inspections


def inspect_app_zip(
    path: Path, relative: str, platform: str, root: Path
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        with zipfile.ZipFile(path) as archive:
            files: dict[str, zipfile.ZipInfo] = {}
            for info in archive.infolist():
                name = info.filename.rstrip("/")
                if not safe_member_name(info.filename):
                    raise CaptureError(f"unsafe app ZIP member: {info.filename!r}")
                if name and not info.is_dir():
                    if name in files:
                        raise CaptureError(f"duplicate app ZIP member: {name}")
                    files[name] = info
            if platform == "macOS":
                candidates = [name for name in files if re.search(r"\.app/Contents/Info\.plist$", name)]
            else:
                candidates = [
                    name for name in files
                    if re.search(r"\.app/Info\.plist$", name) and "/Contents/" not in name
                ]
            if len(candidates) != 1:
                raise CaptureError(f"{relative} does not contain one {platform} Info.plist")
            info_name = candidates[0]
            info_bytes = archive.read(files[info_name])
            info = plistlib.loads(info_bytes)
            if not isinstance(info, dict):
                raise CaptureError(f"{relative} Info.plist is not a dictionary")
            if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_IDENTIFIER:
                raise CaptureError(f"{relative} bundle identifier differs")
            expected_info = {
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": BUILD,
            }
            for key, expected in expected_info.items():
                if info.get(key) != expected:
                    raise CaptureError(f"{relative} {key} differs")
            supported_platforms = info.get("CFBundleSupportedPlatforms")
            expected_platforms = ["MacOSX"] if platform == "macOS" else ["iPhoneSimulator"]
            if supported_platforms != expected_platforms:
                raise CaptureError(f"{relative} supported platform differs")
            executable_name = info.get("CFBundleExecutable")
            if not isinstance(executable_name, str) or not executable_name:
                raise CaptureError(f"{relative} CFBundleExecutable is invalid")
            app_root = info_name.rsplit("/", 1)[0]
            executable_name_in_zip = (
                f"{app_root}/MacOS/{executable_name}"
                if platform == "macOS" else f"{app_root}/{executable_name}"
            )
            executable_info = files.get(executable_name_in_zip)
            if executable_info is None:
                raise CaptureError(f"{relative} declared executable is missing")
            executable_bytes = archive.read(executable_info)
            if (
                len(executable_bytes) < 32
                or executable_bytes[:4] not in {
                    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
                    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
                    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
                }
                or not ((executable_info.external_attr >> 16) & 0o111)
            ):
                raise CaptureError(f"{relative} declared executable is not an executable Mach-O")
            architectures, entitlement_inspections = executable_entitlements(
                executable_bytes,
                platform=platform,
                simulator=platform != "macOS",
            )
            entitlements = entitlement_inspections[0]["entitlements"]
            product = {
                "platform": platform, "path": relative, "sha256": sha256_file(path),
                "infoPlistPath": info_name, "infoPlistSHA256": sha256_bytes(info_bytes),
                "executablePath": executable_name_in_zip,
                "executableSHA256": sha256_bytes(executable_bytes),
                "architectures": architectures,
                "entitlementInspections": entitlement_inspections,
                "configuration": {
                    "CFBundleIdentifier": info.get("CFBundleIdentifier"),
                    "CFBundlePackageType": info.get("CFBundlePackageType"),
                    "CFBundleShortVersionString": info.get("CFBundleShortVersionString"),
                    "CFBundleVersion": info.get("CFBundleVersion"),
                    "CFBundleSupportedPlatforms": supported_platforms,
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
            return product, inspect_theme_budgets(archive, files, root, platform)
    except (
        OSError, KeyError, RuntimeError, zipfile.BadZipFile,
        plistlib.InvalidFileException, ValueError,
    ) as exception:
        if isinstance(exception, CaptureError):
            raise
        raise CaptureError(f"cannot inspect {relative}: {exception}") from exception


def test_command(identifier: str, scratch: Path) -> list[str]:
    test_filter = (
        "^" + re.escape(identifier) + "$" if "/" in identifier else identifier
    )
    return [
        "swift", "test", "--package-path", PACKAGE_PATH,
        "--scratch-path", str(scratch), "--skip-update", "--skip-build",
        "--filter", test_filter,
    ]


def display_command(arguments: list[str], scratch: Path) -> str:
    displayed = ["${DOMAIN_SCRATCH}" if value == str(scratch) else value for value in arguments]
    return shlex.join(displayed)


def verify_pass_output(identifier: str, framework: str, output: str) -> None:
    if framework == "Swift Testing":
        function = identifier.split(".", 1)[1]
        if not re.search(rf"✔ Test {re.escape(function)} passed(?: after|\.)", output):
            raise CaptureError(f"Swift Testing result did not PASS exact identity {identifier}")
        if "Test run with 1 test" not in output:
            raise CaptureError(f"Swift Testing result count differs for {identifier}")
        return
    suite, method = identifier.split("/", 1)
    module, class_name = suite.split(".", 1)
    exact = f"Test Case '-[{module}.{class_name} {method}]' passed"
    if exact not in output or "Executed 1 test, with 0 failures" not in output:
        raise CaptureError(f"XCTest result did not PASS exact identity {identifier}")


def execute_tests(
    root: Path, source_hash: str
) -> tuple[list[dict[str, Any]], dict[str, int | str]]:
    package = root / PACKAGE_PATH
    if not (package / "Package.swift").is_file():
        raise CaptureError("RuneScribeArchitecture package is missing")
    scratch = Path(tempfile.gettempdir()) / "runescribe-domain-qualification" / source_hash
    scratch.mkdir(parents=True, exist_ok=True)
    list_command = [
        "swift", "test", "--package-path", PACKAGE_PATH,
        "--scratch-path", str(scratch), "--skip-update", "list",
    ]
    listed = subprocess.run(
        list_command, cwd=root, check=False, capture_output=True, text=True,
        env=execution_environment(), timeout=900,
    )
    if listed.returncode != 0:
        raise CaptureError("swift test list failed: " + (listed.stderr or listed.stdout).strip())
    inventory = {line.strip() for line in listed.stdout.splitlines() if line.strip()}
    missing = sorted(set(ALL_TEST_SOURCES) - inventory)
    if missing:
        raise CaptureError("locked Swift test identities are missing: " + ", ".join(missing))

    executions: list[dict[str, Any]] = []
    preview_measurement: dict[str, int | str] | None = None
    with tempfile.TemporaryDirectory(prefix="runescribe-preview-qualification-") as temporary:
        preview_path = Path(temporary) / "preview.json"
        for identifier in ALL_TEST_SOURCES:
            source_relative = ALL_TEST_SOURCES[identifier]
            source_path = root / source_relative
            if not source_path.is_file():
                raise CaptureError(f"test source is missing: {source_relative}")
            framework = "XCTest" if "/" in identifier else "Swift Testing"
            command = test_command(identifier, scratch)
            environment = execution_environment()
            if identifier == PREVIEW_TEST:
                environment[PREVIEW_OUTPUT_ENV] = str(preview_path)
            result = subprocess.run(
                command, cwd=root, check=False, capture_output=True, text=True,
                env=environment, timeout=900,
            )
            output = result.stdout + result.stderr
            if result.returncode != 0:
                raise CaptureError(
                    f"locked Swift test failed: {identifier}: " + output.strip()[-2000:]
                )
            verify_pass_output(identifier, framework, output)
            executions.append({
                "identifier": identifier, "framework": framework,
                "command": display_command(command, scratch), "exitStatus": 0,
                "observedTestCount": 1, "result": "PASS",
                "sourcePath": source_relative, "sourceSHA256": sha256_file(source_path),
            })
            if identifier == PREVIEW_TEST:
                document = load_json(preview_path, "renderer preview qualification output")
                expected_keys = {
                    "schemaVersion", "testIdentifier", "previewBytes",
                    "previewWidthPixels", "previewHeightPixels",
                }
                if not isinstance(document, dict) or set(document) != expected_keys:
                    raise CaptureError("renderer preview qualification schema differs")
                if (
                    document.get("schemaVersion") != SCHEMA_VERSION
                    or document.get("testIdentifier") != PREVIEW_TEST
                    or any(type(document.get(key)) is not int for key in (
                        "previewBytes", "previewWidthPixels", "previewHeightPixels"
                    ))
                ):
                    raise CaptureError("renderer preview qualification values are invalid")
                preview_measurement = dict(document)
    if preview_measurement is None:
        raise CaptureError("renderer preview qualification output is missing")
    preview_bytes = int(preview_measurement["previewBytes"])
    width = int(preview_measurement["previewWidthPixels"])
    height = int(preview_measurement["previewHeightPixels"])
    if not 0 < preview_bytes < 4 * 1024 * 1024:
        raise CaptureError("renderer preview byte budget fails")
    if width <= 0 or height <= 0 or width * 3 != height * 4:
        raise CaptureError("renderer preview dimensions are not exact 4:3")
    return executions, preview_measurement


def build_cases(
    mapping: dict[str, tuple[str, ...]], test_ids: list[str],
    built_inspection: bool = False,
) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for marker, identifiers in mapping.items():
        artifacts = [BUILT_PRODUCT_INSPECTION] if built_inspection and not identifiers else []
        cases.append({
            "marker": marker, "result": "PASS", "testIDs": test_ids,
            "executedTests": list(identifiers), "artifacts": artifacts,
        })
    return cases


def domain_tail(
    executions: list[dict[str, Any]],
    cloud_cases: list[dict[str, Any]],
    performance_cases: list[dict[str, Any]],
    preview: dict[str, int | str],
    budgets: list[dict[str, Any]],
    products: list[dict[str, Any]],
    shipping_validation: dict[str, Any],
) -> str:
    lines = ["DOMAIN_EXECUTION_LOG schemaVersion=1.0"]
    lines.extend("domainExecution=" + canonical_json(item) for item in executions)
    lines.extend("semanticCase=" + canonical_json(item) for item in cloud_cases)
    lines.extend("semanticCase=" + canonical_json(item) for item in performance_cases)
    lines.append("previewMeasurement=" + canonical_json(preview))
    lines.extend("themeBudgetInspection=" + canonical_json(item) for item in budgets)
    lines.extend("productInspection=" + canonical_json(item) for item in products)
    lines.append("shippingProductValidation=" + canonical_json(shipping_validation))
    lines.append("domainCaptureResult=PASS")
    return "\n".join(lines) + "\n"


def validate_suite_prefix(value: str) -> str:
    normalized = value.replace("\r\n", "\n")
    if not normalized.endswith("\n"):
        normalized += "\n"
    if any(
        line.startswith(RESERVED_LOG_PREFIXES)
        or line == "DOMAIN_EXECUTION_LOG schemaVersion=1.0"
        for line in normalized.splitlines()
    ):
        raise CaptureError("suite log input contains reserved domain evidence lines")
    return normalized


def split_existing_log(value: str) -> tuple[str, str]:
    marker = "DOMAIN_EXECUTION_LOG schemaVersion=1.0\n"
    normalized = value.replace("\r\n", "\n")
    if normalized.count(marker) != 1:
        raise CaptureError("existing raw log does not contain one domain execution boundary")
    prefix, tail = normalized.split(marker, 1)
    return validate_suite_prefix(prefix), marker + tail


def build_documents(
    *, root: Path, source_hash: str, source_revision: str | None,
    raw_relative: str, raw_digest: str, executions: list[dict[str, Any]],
    preview: dict[str, int | str], products: list[dict[str, Any]],
    budgets: list[dict[str, Any]], inspection_relative: str,
    inspection_digest: str | None, shipping_validation: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    producer = {"path": PRODUCER_PATH, "sha256": sha256_file(root / PRODUCER_PATH)}
    common = {
        "schemaVersion": SCHEMA_VERSION, "status": "PASS",
        "sourceManifestSHA256": source_hash, "sourceRevision": source_revision,
        "version": VERSION, "build": BUILD, "rawLog": raw_relative,
        "rawLogSHA256": raw_digest, "producer": producer,
    }
    inspection = {
        **common,
        "products": products,
        "shippingValidation": shipping_validation,
    }
    if inspection_digest is None:
        inspection_digest = sha256_bytes(
            (json.dumps(inspection, indent=2, sort_keys=True) + "\n").encode("utf-8")
        )
    cloud_executions = [item for item in executions if item["identifier"] in CLOUD_TEST_SOURCES]
    performance_executions = [
        item for item in executions if item["identifier"] in PERFORMANCE_TEST_SOURCES
    ]
    cloud = {
        **common, "testIDs": ["T-096", "T-097"],
        "semanticMarkers": list(CLOUD_MARKERS), "executions": cloud_executions,
        "cases": build_cases(CLOUD_CASE_TESTS, ["T-096", "T-097"], True),
        "builtInspection": {
            "result": "PASS", "record": inspection_relative,
            "recordSHA256": inspection_digest, "products": products,
        },
    }
    performance = {
        **common, "testIDs": ["T-116"],
        "semanticMarkers": list(PERFORMANCE_MARKERS),
        "executions": performance_executions,
        "cases": build_cases(PERFORMANCE_CASE_TESTS, ["T-116"]),
        "metrics": {"preview": preview, "themeResourceBudgets": budgets},
    }
    return inspection, cloud, performance


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--source-manifest", type=Path, required=True)
    parser.add_argument("--source-revision")
    parser.add_argument("--suite-log-input", type=Path)
    parser.add_argument("--raw-output", type=Path, required=True)
    parser.add_argument("--macos-app-zip", type=Path, required=True)
    parser.add_argument("--ios-app-zip", type=Path, required=True)
    parser.add_argument("--cloud-output", type=Path, required=True)
    parser.add_argument("--performance-output", type=Path, required=True)
    parser.add_argument("--inspection-output", type=Path, required=True)
    parser.add_argument("--shipping-output", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        manifest = load_json(args.source_manifest, "source manifest")
        source_hash = manifest.get("aggregateSHA256") if isinstance(manifest, dict) else None
        if not isinstance(source_hash, str) or re.fullmatch(r"[0-9a-f]{64}", source_hash) is None:
            raise CaptureError("source manifest aggregateSHA256 is invalid")
        mac_product, mac_budgets = inspect_app_zip(
            args.macos_app_zip,
            normalized_relative(args.macos_app_zip, root, "macOS app ZIP"),
            "macOS", root,
        )
        ios_product, ios_budgets = inspect_app_zip(
            args.ios_app_zip,
            normalized_relative(args.ios_app_zip, root, "iOS app ZIP"),
            "iOS", root,
        )
        products = [mac_product, ios_product]
        budgets = mac_budgets + ios_budgets
        shipping_output = args.shipping_output or (root / SHIPPING_VALIDATION_LOG)
        shipping_relative = normalized_relative(
            shipping_output, root, "shipping-product output"
        )
        if shipping_relative != SHIPPING_VALIDATION_LOG:
            raise CaptureError(
                "shipping-product output must use the locked repository-relative path"
            )
        shipping_validation, shipping_output_bytes = run_shipping_product_validation(
            root=root,
            macos_zip=args.macos_app_zip,
            ios_zip=args.ios_app_zip,
            output_relative=shipping_relative,
        )
        executions, preview = execute_tests(root, source_hash)
        expected_tail = domain_tail(
            executions,
            build_cases(CLOUD_CASE_TESTS, ["T-096", "T-097"], True),
            build_cases(PERFORMANCE_CASE_TESTS, ["T-116"]),
            preview, budgets, products, shipping_validation,
        )
        raw_relative = normalized_relative(args.raw_output, root, "raw output")
        inspection_relative = normalized_relative(
            args.inspection_output, root, "built product inspection output"
        )
        if args.verify_only:
            if args.suite_log_input is not None:
                raise CaptureError("--verify-only does not accept --suite-log-input")
            prefix, current_tail = split_existing_log(
                args.raw_output.read_text(encoding="utf-8")
            )
            if current_tail != expected_tail:
                raise CaptureError("existing domain raw log differs from fresh execution")
            expected_raw = prefix + expected_tail
            raw_digest = sha256_bytes(expected_raw.encode("utf-8"))
            inspection_document, cloud_document, performance_document = build_documents(
                root=root, source_hash=source_hash, source_revision=args.source_revision,
                raw_relative=raw_relative, raw_digest=raw_digest,
                executions=executions, preview=preview, products=products, budgets=budgets,
                inspection_relative=inspection_relative,
                inspection_digest=sha256_file(args.inspection_output),
                shipping_validation=shipping_validation,
            )
            for path, expected, label in (
                (args.inspection_output, inspection_document, "built product inspection"),
                (args.cloud_output, cloud_document, "Cloud/Game Center result"),
                (args.performance_output, performance_document, "performance result"),
            ):
                if load_json(path, label) != expected:
                    raise CaptureError(f"existing {label} differs from fresh execution")
            if sha256_file(args.raw_output) != raw_digest:
                raise CaptureError("existing raw log digest differs from fresh execution")
            if shipping_output.read_bytes() != shipping_output_bytes:
                raise CaptureError(
                    "existing shipping-product log differs from fresh execution"
                )
        else:
            if args.suite_log_input is None:
                raise CaptureError("capture mode requires --suite-log-input")
            prefix = validate_suite_prefix(args.suite_log_input.read_text(encoding="utf-8"))
            args.raw_output.parent.mkdir(parents=True, exist_ok=True)
            shipping_output.parent.mkdir(parents=True, exist_ok=True)
            shipping_output.write_bytes(shipping_output_bytes)
            args.raw_output.write_text(prefix + expected_tail, encoding="utf-8")
            raw_digest = sha256_file(args.raw_output)
            inspection_document, _, _ = build_documents(
                root=root, source_hash=source_hash, source_revision=args.source_revision,
                raw_relative=raw_relative, raw_digest=raw_digest,
                executions=executions, preview=preview, products=products, budgets=budgets,
                inspection_relative=inspection_relative, inspection_digest=None,
                shipping_validation=shipping_validation,
            )
            write_json(args.inspection_output, inspection_document)
            _, cloud_document, performance_document = build_documents(
                root=root, source_hash=source_hash, source_revision=args.source_revision,
                raw_relative=raw_relative, raw_digest=raw_digest,
                executions=executions, preview=preview, products=products, budgets=budgets,
                inspection_relative=inspection_relative,
                inspection_digest=sha256_file(args.inspection_output),
                shipping_validation=shipping_validation,
            )
            write_json(args.cloud_output, cloud_document)
            write_json(args.performance_output, performance_document)
    except (
        CaptureError, OSError, UnicodeDecodeError, json.JSONDecodeError,
        subprocess.TimeoutExpired,
    ) as exception:
        print(f"FAIL: {exception}", file=sys.stderr)
        return 2
    action = "replayed and matched" if args.verify_only else "executed and emitted"
    print(f"PASS: source-bound domain qualification {action}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
