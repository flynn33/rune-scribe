#!/usr/bin/env python3
"""Fail when release, roadmap, recovery, or publication documentation drifts."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import date
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ERRORS: list[str] = []
RECOVERY_STATUS = "PASS / CLOSED"
RECOVERY_ACCEPTANCE_OUTCOME = "PASS / UNBLOCKED FOR PHASE C"
CORRECTED_V31_PACKAGE_STATUS = "ACCEPTED"
PHASE_C_OUTCOME = "PHASE C: PASS / MERGED TO MAIN"
PHASE_D_READINESS = "READY_FOR_AUTHORIZATION"
PHASE_D_STATUS = "NOT_STARTED"
PULL_REQUEST_NUMBER = 45
AUDITED_SOURCE_COMMIT = "f5b74658bb6ec4d3ac251f532a4d92d389c2a2db"
EVIDENCE_COMMIT = "ee47191d131dfe3b6b3e446bc4bd88e07bc9960f"
MERGE_COMMIT = "e9e0e0c8814aaa107d7480e070f14a6fe9b09975"


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        ERRORS.append(f"missing file: {relative}")
        return ""
    return path.read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        ERRORS.append(message)


def leading_blockquote(content: str) -> str:
    lines: list[str] = []
    candidates = content.splitlines()[1:]
    while candidates and not candidates[0].strip():
        candidates.pop(0)
    for line in candidates:
        if line.startswith(">"):
            lines.append(line)
        else:
            break
    return "\n".join(lines)


def git(*arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


project = read("project.yml")
marketing_match = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', project)
build_match = re.search(r'CURRENT_PROJECT_VERSION:\s*"([^"]+)"', project)
require(marketing_match is not None, "project.yml has no MARKETING_VERSION")
require(build_match is not None, "project.yml has no CURRENT_PROJECT_VERSION")
marketing = marketing_match.group(1) if marketing_match else ""
build = build_match.group(1) if build_match else ""

project_file = read("RuneScrib.xcodeproj/project.pbxproj")
project_marketing = set(re.findall(r"MARKETING_VERSION = ([^;]+);", project_file))
project_builds = set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", project_file))
require(project_marketing == {marketing}, "generated project marketing version differs from project.yml")
require(project_builds == {build}, "generated project build differs from project.yml")

module_roots = {
    "RuneScribeCoreModule": "CoreModule.swift",
    "RuneScribeProgressionModule": "ProgressionModule.swift",
    "RuneScribeUIModule": "UIModule.swift",
}
patch = marketing.rsplit(".", 1)[-1]
for module, source_name in module_roots.items():
    base = f"Packages/RuneScribeArchitecture/Sources/{module}"
    manifest = json.loads(read(f"{base}/Resources/module-manifest.json"))
    require(manifest.get("moduleVersion") == marketing, f"{module} manifest version differs from app")
    source = read(f"{base}/{source_name}")
    require(
        re.search(rf"patch:\s*UInt\({re.escape(patch)}\)", source) is not None,
        f"{module} compiled descriptor version differs from app",
    )

changelog = read("CHANGELOG.md")
release_match = re.search(r"^## \[([^]]+)\] - (\d{4}-\d{2}-\d{2})$", changelog, re.MULTILINE)
require(release_match is not None, "CHANGELOG.md has no current release heading")
release_version = release_match.group(1) if release_match else ""
release_date = release_match.group(2) if release_match else ""
require(release_version == marketing, "CHANGELOG.md current release differs from project version")
require(f"Recovery is {RECOVERY_STATUS}" in changelog, "CHANGELOG.md lacks the closed recovery result")
require(
    f"corrected v3.1 package is {CORRECTED_V31_PACKAGE_STATUS}" in changelog,
    "CHANGELOG.md lacks the accepted corrected v3.1 package result",
)
require(PHASE_C_OUTCOME in changelog, "CHANGELOG.md lacks the merged Phase C result")
require(
    "Complete the source-controlled roadmap program" in changelog
    and "strict no-ship boundary" in changelog,
    "CHANGELOG.md lacks the roadmap-completion no-ship result",
)

readme = read("README.md")
require(
    f"version-{marketing}%20build%20{build}" in readme,
    "README version badge differs from project version",
)
require("All nine Elven Series recovery findings pass simultaneously" in readme, "README lacks current recovery result")
require(f"Recovery is {RECOVERY_STATUS}" in readme, "README lacks the closed recovery result")
require(
    re.search(
        rf"corrected v3\.1\s+package is {re.escape(CORRECTED_V31_PACKAGE_STATUS)}",
        readme,
    )
    is not None,
    "README lacks the accepted corrected v3.1 package result",
)
require("Phase C is PASS / MERGED TO MAIN" in readme, "README lacks current Phase C result")
require(
    "roadmap-completion program is source-complete" in readme
    and "and not shipped" in readme,
    "README lacks the roadmap-completion no-ship result",
)
require("## 🗺 Implementation roadmap" in readme, "README lacks the implementation roadmap")
readme_roadmap = readme.split("## 🗺 Implementation roadmap", 1)[-1].split("## 🔐 Security & privacy", 1)[0]
require(
    f"version {marketing} build {build} roadmap-completion program" in readme_roadmap,
    "README roadmap version differs from the project version",
)
require(
    "| 6 | Production Elven providers, hardening, evidence, no-ship handoff | Complete; physical-device qualification owner-only |"
    in readme_roadmap,
    "README Wave 6 roadmap scope differs",
)
require(
    "| P12 | Full Xcode, parity, device" not in readme_roadmap,
    "README roadmap retains a hardware completion gate",
)

submission = read("docs/APP_STORE_SUBMISSION.md")
require(
    f"**Last prepared for:** {marketing} (build {build}) — {release_date}" in submission,
    "App Store packet header differs from current release",
)
require(f"| **Version** | `{marketing}` |" in submission, "App Store packet version differs")
require(f"| **Build** | `{build}` |" in submission, "App Store packet build differs")
require("## What’s New (customer-facing)" in submission, "App Store packet summary differs")
require(
    "Smoke-test Share deep link and intro cadence on device" not in submission,
    "App Store packet retains a device smoke-test completion item",
)
require(
    "Smoke-test Vault/Progress, reveal accessibility, and feedback settings on device"
    not in submission,
    "App Store packet retains a device accessibility completion item",
)
require(
    "Supported Simulator and hosted coverage verifies Share deep-link routing" in submission,
    "App Store packet lacks supported-environment share validation",
)
require(
    "Supported Simulator and hosted coverage verifies Vault/Progress" in submission,
    "App Store packet lacks supported-environment progression validation",
)
require(
    "Hardware-only observations are owner-operated optional validation outside Agent Coding"
    in submission,
    "App Store packet lacks the owner-operated hardware boundary",
)
require(
    "PASS/FAIL, upload readiness, or pull-request readiness" in submission,
    "App Store packet lacks the non-gating upload and pull-request boundary",
)
privacy = read("docs/PRIVACY.md")
support = read("docs/SUPPORT.md")
documentation_support_checklist = read(
    "docs/verification/roadmap-completion/DocumentationSupportChecklist.md"
)
require(
    f"Rune Scribe {marketing} (build {build})" in privacy,
    "privacy policy application version differs",
)
require(
    "private CloudKit database" in privacy
    and "Game Center achievement reporting is also optional" in privacy
    and "does not use advertising" in privacy
    and "tracking" in privacy
    and "analytics" in privacy,
    "privacy policy lacks the optional-service and no-tracking boundary",
)
require(
    f"version {marketing} (build {build})" in support,
    "support guide application version differs",
)
require(
    "owner test required; not shipped" in support
    and "local Vault works without either Apple service" in support,
    "support guide lacks the no-ship or local-first boundary",
)
require(
    f"Rune Scribe {marketing} (build {build})" in documentation_support_checklist,
    "documentation/support checklist application version differs",
)
require(
    documentation_support_checklist.count("- [x]") >= 12
    and "- [ ]" not in documentation_support_checklist,
    "documentation/support checklist is incomplete",
)
require(
    "**NOT SHIPPED — OWNER TEST REQUIRED**" in documentation_support_checklist
    and "**Do not ship until the owner approves the test results.**"
    in documentation_support_checklist,
    "documentation/support checklist lacks the exact stop statements",
)
roadmap = read("docs/architecture/RoadmapAlignment.md")
require(
    f"**Current application:** version {marketing} build {build}" in roadmap,
    "roadmap application version differs from the project version",
)
require("Phase C is PASS / MERGED TO MAIN" in roadmap, "roadmap lacks the merged Phase C result")
require(
    "is source-complete for the authorized roadmap-completion" in roadmap
    and "deliberately **not shipped**" in roadmap,
    "roadmap lacks the source-complete no-ship result",
)
require("validated Elven Series recovery boundary" in roadmap, "roadmap lacks recovery result")
require(RECOVERY_STATUS in roadmap, "roadmap lacks the closed recovery result")
require(
    f"corrected v3.1 package is {CORRECTED_V31_PACKAGE_STATUS}" in roadmap,
    "roadmap lacks the accepted corrected v3.1 package result",
)
require("Keep Elven Series Phase C blocked" not in roadmap, "roadmap retains superseded Phase C blocker")

locked_roadmap = read(
    "docs/product-roadmap/Rune-Scribe-Codex-Current-App-Delta-and-Implementation-Roadmap-v1.0.md"
)
locked_roadmap_marker = "> **Current publication boundary — August 22, 2026.**"
locked_roadmap_end = "\n\n**Document version:**"
require(
    locked_roadmap.count(locked_roadmap_marker) == 1,
    "locked roadmap must contain exactly one current publication-boundary marker",
)
require(
    locked_roadmap.count(locked_roadmap_end) == 1,
    "locked roadmap must contain exactly one publication-boundary terminator",
)
locked_roadmap_banner = locked_roadmap.split(locked_roadmap_marker, 1)[-1].split(
    locked_roadmap_end,
    1,
)[0]
locked_roadmap_banner_text = "\n".join(
    re.sub(r"^>\s?", "", line) for line in locked_roadmap_banner.splitlines()
)
require(
    f"current application is version {marketing} build {build}" in locked_roadmap_banner_text,
    "locked roadmap banner version differs from the project version",
)
require(
    "owner-operated optional observations outside Agent Coding scope"
    in locked_roadmap_banner_text,
    "locked roadmap banner lacks the owner-operated scope boundary",
)
require(
    "pull-request readiness" in locked_roadmap_banner_text,
    "locked roadmap banner lacks the non-gating publication boundary",
)

supersession_index = read("docs/architecture/ForsettiSupersessionIndex.md")
decision_index = read("docs/architecture/decisions/README.md")
forward_compatibility = read("docs/architecture/decisions/ADR-RS-005-forward-compatibility.md")
invitation_presentation = read("docs/architecture/decisions/ADR-RS-012-cipher-invitation-presentation.md")
require(
    re.search(
        r"Hardware-only observations\s+are owner-operated optional validation outside Agent Coding scope",
        supersession_index,
    )
    is not None,
    "Forsetti supersession index lacks the owner-operated hardware boundary",
)
require(
    "physical-device decision gates remain in force" not in supersession_index,
    "Forsetti supersession index retains a hardware decision gate",
)
require(
    "physical-device evidence for supported destinations" not in forward_compatibility,
    "ADR-RS-005 retains a hardware acceptance requirement",
)
require(
    "**Status:** Accepted; typed file Artifact with QR and link fallbacks" in invitation_presentation,
    "ADR-RS-012 status differs from the completed transport decision",
)
require(
    "Blocked on physical-device spike" not in invitation_presentation,
    "ADR-RS-012 retains a hardware blocker",
)
require(
    "Accepted; typed file Artifact with QR and link fallbacks" in decision_index,
    "decision index differs from the completed ADR-RS-012 status",
)

migration_decisions = read("docs/architecture/MigrationDecisions.md")
migration_banner = leading_blockquote(migration_decisions)
migration_banner_text = re.sub(
    r"\s+",
    " ",
    "\n".join(re.sub(r"^>\s?", "", line) for line in migration_banner.splitlines()),
)
require("Historical decision record" in migration_banner_text, "migration decisions lack a historical marker")
require(
    f"version {marketing} build {build}" in migration_banner_text,
    "migration decisions current application version differs",
)
require(
    "owner-operated optional observations outside Agent Coding scope" in migration_banner_text,
    "migration decisions lack the owner-operated hardware boundary",
)
require(
    "pull-request-readiness effect" in migration_banner_text,
    "migration decisions lack the non-gating pull-request boundary",
)

historical_phase4_plans = (
    "docs/superpowers/plans/2026-06-26-phase4-messages.md",
    "docs/superpowers/plans/2026-06-27-phase4-file-based-sharing.md",
)
for relative in historical_phase4_plans:
    banner = leading_blockquote(read(relative))
    banner_text = re.sub(
        r"\s+",
        " ",
        "\n".join(re.sub(r"^>\s?", "", line) for line in banner.splitlines()),
    )
    require("Historical" in banner_text, f"{relative} lacks an immediate historical marker")
    require(
        f"version {marketing} build {build}" in banner_text,
        f"{relative} current application version differs",
    )
    require(
        "owner-operated optional observations outside Agent Coding scope" in banner_text,
        f"{relative} lacks the owner-operated hardware boundary",
    )
    require(
        "pull-request-readiness" in banner_text,
        f"{relative} lacks the non-gating pull-request boundary",
    )

roadmap_state = json.loads(read("docs/verification/roadmap-alignment.json"))
require(
    roadmap_state.get("applicationVersion") == {"marketing": marketing, "build": build},
    "roadmap ledger application version differs from the project version",
)
require("blocked-device" not in roadmap_state.get("statusVocabulary", {}), "roadmap retains a device-blocker status")
owner_optional_tasks = [
    item
    for group in roadmap_state.get("taskGroups", [])
    for item in group.get("items", [])
    if item.get("status") == "owner-optional"
]
require(
    [item.get("id") for item in owner_optional_tasks] == ["BAS-006", "SHR-001", "SHR-015"],
    "roadmap owner-optional task set differs",
)
require(
    all(item.get("dependsOn") == [] for item in owner_optional_tasks),
    "roadmap owner-optional observations retain dependencies",
)
owner_optional_ids = {item.get("id") for item in owner_optional_tasks}
require(
    all(
        not owner_optional_ids.intersection(item.get("dependsOn", []))
        for group in roadmap_state.get("taskGroups", [])
        for item in group.get("items", [])
    ),
    "roadmap task depends on an owner-optional observation",
)
try:
    require(
        date.fromisoformat(roadmap_state["asOfDate"]) >= date.fromisoformat(release_date),
        "roadmap ledger predates current release documentation",
    )
except (KeyError, TypeError, ValueError):
    ERRORS.append("roadmap ledger has an invalid asOfDate")

for relative in ("docs/architecture/ModuleGraph.md", "docs/architecture/ForsettiCompliance.md"):
    require(
        f"Current Core, Progression, and UI module version `{marketing}`" in read(relative),
        f"{relative} lacks the current module-version note",
    )

ledger = read("docs/verification/ElvenSeriesBlockingResolutionLedger.md")
require(
    f"**Application:** version {marketing} build {build}" in ledger,
    "resolution ledger application version differs",
)
require("stat.message.incoming-decoded.unique" in ledger, "resolution ledger lacks canonical decode statistic")
passing_findings = re.findall(r"^\| DEV-ELVEN-\d{3} \| PASS \|", ledger, re.MULTILINE)
require(len(passing_findings) == 9, "resolution ledger does not record exactly nine passing findings")
require("Phase C: PASS / MERGED TO MAIN" in ledger, "resolution ledger lacks current Phase C status")
require("Phase D: READY FOR AUTHORIZATION / NOT STARTED" in ledger, "resolution ledger lacks the Phase D boundary")
require(RECOVERY_STATUS in ledger, "resolution ledger lacks the closed recovery result")
require(
    f"corrected v3.1 package is `{CORRECTED_V31_PACKAGE_STATUS}`" in ledger,
    "resolution ledger lacks the accepted corrected v3.1 package result",
)
require("PENDING_PHYSICAL_DEVICE" not in ledger, "resolution ledger retains Phase C hardware-pending status")

historical_reports = (
    "docs/verification/ElvenSeriesBlockingDeviationReport.md",
    "docs/verification/ElvenSeriesBlockingRemediationFinalAudit.md",
    "docs/verification/ThemeScaffoldAndNorseBaseImplementationReport.md",
)
for relative in historical_reports:
    content = read(relative)
    banner = leading_blockquote(content)
    require(
        any("Historical" in line for line in banner.splitlines()),
        f"{relative} lacks a historical-status marker",
    )
    require(RECOVERY_STATUS in banner, f"{relative} banner lacks the closed recovery result")
    require(CORRECTED_V31_PACKAGE_STATUS in banner, f"{relative} banner lacks the accepted corrected v3.1 package result")
    require(PHASE_C_OUTCOME in banner, f"{relative} banner lacks the merged Phase C boundary")
    require("READY FOR AUTHORIZATION / NOT STARTED" in banner, f"{relative} banner lacks the Phase D boundary")
    require(
        re.search(r"physical|hardware|pending", banner, re.IGNORECASE) is None,
        f"{relative} banner retains a hardware gate or residual status",
    )

historical_hardware_reports = (
    "docs/verification/BuildAndTestReport.md",
    "docs/verification/FeatureParityReport.md",
    "docs/verification/ForsettiComplianceReport.md",
    "docs/verification/ProgressionImplementationReport.md",
)
for relative in historical_hardware_reports:
    banner = leading_blockquote(read(relative))
    banner_text = "\n".join(re.sub(r"^>\s?", "", line) for line in banner.splitlines())
    require("Historical" in banner_text, f"{relative} lacks an immediate historical-status banner")
    require(
        re.search(r"owner-operated\s+optional", banner_text, re.IGNORECASE) is not None,
        f"{relative} banner lacks the owner-operated optional disposition",
    )
    require(
        "outside Agent Coding scope" in banner_text,
        f"{relative} banner lacks the Agent Coding scope boundary",
    )
    require(
        "pull-request readiness" in banner_text,
        f"{relative} banner lacks the non-gating pull-request boundary",
    )

phase_c_final = read("docs/verification/elven-phase-c/PhaseCFinalAudit.md")
recovery_final = read("docs/verification/elven-recovery-v3/RecoveryFinalAudit.md")
remediation_readme = read("docs/verification/elven-remediation/README.md")
require(
    f"| Application version | `{marketing}` |" in phase_c_final,
    "Phase C final audit application version differs",
)
require(
    f"| Application build | `{build}` |" in phase_c_final,
    "Phase C final audit application build differs",
)
require(
    f"Application release: **version {marketing} build {build}**" in recovery_final,
    "recovery final audit application version differs",
)
require(
    f"current application is version {marketing} build {build}" in remediation_readme,
    "remediation archive current application version differs",
)
section_markers = (
    ("docs/verification/elven-phase-c/PhaseCFinalAudit.md", phase_c_final, "## Outcome", "## Source and package boundary"),
    ("docs/verification/elven-recovery-v3/RecoveryFinalAudit.md", recovery_final, "## Outcome", "## Repository Boundary"),
    ("docs/verification/elven-remediation/README.md", remediation_readme, "## Current boundary", None),
    ("docs/verification/ElvenSeriesBlockingResolutionLedger.md", ledger, "## Current boundary", None),
)
for relative, content, start, end in section_markers:
    require(content.count(start) == 1, f"{relative} must contain exactly one {start} marker")
    if end is not None:
        require(content.count(end) == 1, f"{relative} must contain exactly one {end} marker")

current_phase_c_sections = (
    (
        "docs/verification/elven-phase-c/PhaseCFinalAudit.md",
        phase_c_final.split("## Outcome", 1)[-1].split("## Source and package boundary", 1)[0],
    ),
    (
        "docs/verification/elven-recovery-v3/RecoveryFinalAudit.md",
        recovery_final.split("## Outcome", 1)[-1].split("## Repository Boundary", 1)[0],
    ),
    ("docs/verification/elven-remediation/README.md", remediation_readme.split("## Current boundary", 1)[-1]),
    ("docs/verification/ElvenSeriesBlockingResolutionLedger.md", ledger.split("## Current boundary", 1)[-1]),
)
for relative, content in current_phase_c_sections:
    require(RECOVERY_STATUS in content, f"{relative} current section lacks the closed recovery result")
    require(
        CORRECTED_V31_PACKAGE_STATUS in content,
        f"{relative} current section lacks the accepted corrected v3.1 package result",
    )
    require(PHASE_C_OUTCOME in content, f"{relative} current section lacks the merged Phase C boundary")
    require("READY FOR AUTHORIZATION / NOT STARTED" in content, f"{relative} current section lacks the Phase D boundary")
    require(
        re.search(r"physical|hardware|pending", content, re.IGNORECASE) is None,
        f"{relative} current section retains a hardware gate or residual status",
    )
for relative, content in (
    ("docs/verification/elven-phase-c/PhaseCFinalAudit.md", phase_c_final),
    ("docs/verification/elven-remediation/README.md", remediation_readme),
):
    require("PENDING_PHYSICAL_DEVICE" not in content, f"{relative} retains hardware-pending status")

link_pages = (
    "README.md",
    "docs/PRIVACY.md",
    "docs/SUPPORT.md",
    "docs/APP_STORE_SUBMISSION.md",
    "docs/architecture/RoadmapAlignment.md",
    "docs/architecture/ForsettiCompliance.md",
    "docs/architecture/ForsettiSupersessionIndex.md",
    "docs/architecture/MigrationDecisions.md",
    "docs/architecture/decisions/README.md",
    "docs/architecture/decisions/ADR-RS-005-forward-compatibility.md",
    "docs/architecture/decisions/ADR-RS-012-cipher-invitation-presentation.md",
    "docs/verification/ElvenSeriesBlockingDeviationReport.md",
    "docs/verification/ElvenSeriesBlockingRemediationFinalAudit.md",
    "docs/verification/ElvenSeriesBlockingResolutionLedger.md",
    "docs/verification/ThemeScaffoldAndNorseBaseImplementationReport.md",
    "docs/verification/BuildAndTestReport.md",
    "docs/verification/FeatureParityReport.md",
    "docs/verification/ForsettiComplianceReport.md",
    "docs/verification/ProgressionImplementationReport.md",
    "docs/verification/elven-phase-c/PhaseCFinalAudit.md",
    "docs/verification/elven-recovery-v3/RecoveryFinalAudit.md",
    "docs/verification/elven-remediation/README.md",
    "docs/superpowers/plans/2026-06-26-phase4-messages.md",
    "docs/superpowers/plans/2026-06-27-phase4-file-based-sharing.md",
)
markdown_link = re.compile(r"\[[^]]+\]\(([^)]+)\)")
for relative in link_pages:
    page = ROOT / relative
    for target in markdown_link.findall(read(relative)):
        target = target.strip().strip("<>").split("#", 1)[0]
        if not target or target.startswith(("/", "#", "mailto:")) or "://" in target:
            continue
        require((page.parent / target).exists(), f"{relative} has a missing link target: {target}")

historical_machine_records = {
    "docs/verification/elven-recovery-v3/PhaseABRegression.json": "HISTORICAL_SNAPSHOT",
    "docs/verification/elven-remediation/ElvenSeriesRemediationState.json":
        "HISTORICAL_REJECTED_ATTEMPT",
    "docs/verification/feature-parity-matrix.json": "HISTORICAL_SNAPSHOT",
    "docs/verification/p7-test-matrix.json": "HISTORICAL_SNAPSHOT",
}
for relative, classification in historical_machine_records.items():
    record = json.loads(read(relative))
    require(
        record.get("recordClassification") == classification,
        f"{relative} record classification differs",
    )
    current_policy = record.get("currentPolicy", {})
    require(
        current_policy.get("hardwareOnlyObservations") == "OWNER_OPERATED_OPTIONAL",
        f"{relative} hardware observation disposition differs",
    )
    require(
        current_policy.get("agentCodingStatus") == "OUTSIDE_SCOPE",
        f"{relative} Agent Coding status differs",
    )
    require(
        current_policy.get("gatingEffect") == "NONE",
        f"{relative} retains a hardware gating effect",
    )

rejected_remediation = json.loads(
    read("docs/verification/elven-remediation/ElvenSeriesRemediationState.json")
)
rejected_policy = rejected_remediation.get("currentPolicy", {})
require(
    rejected_policy.get("currentAuthority")
    == "docs/verification/elven-recovery-v3/RecoveryState.json",
    "rejected remediation record current authority differs",
)
require(
    rejected_policy.get("recoveryStatus") == RECOVERY_STATUS,
    "rejected remediation record current recovery status differs",
)

recovery = json.loads(read("docs/verification/elven-recovery-v3/RecoveryState.json"))
require(recovery.get("applicationVersion") == marketing, "recovery state application version differs")
require(recovery.get("applicationBuild") == build, "recovery state application build differs")
require(recovery.get("recoveryStatus") == RECOVERY_STATUS, "recovery state is not closed")
require(recovery.get("recoveryAcceptanceOutcome") == RECOVERY_ACCEPTANCE_OUTCOME, "recovery acceptance outcome differs")
phase_ab = recovery.get("phaseABRegression", {})
require("physicalDeviceStatus" not in phase_ab, "current Phase A/B state retains hardware status")
require("physicalDevicePending" not in phase_ab, "current Phase A/B state retains hardware residual work")
owner_validation = phase_ab.get("ownerOperatedOptionalValidation", {})
require(owner_validation.get("scope") == "HARDWARE_ONLY", "Phase A/B optional observation scope differs")
require(owner_validation.get("status") == "OUTSIDE_AGENT_SCOPE", "Phase A/B optional observation is not outside agent scope")
require(owner_validation.get("gatingEffect") == "NONE", "Phase A/B optional observation retains a gating effect")
findings = recovery.get("findings", [])
require(len(findings) == 9, "recovery state does not contain exactly nine findings")
require(all(item.get("status") == "PASS" for item in findings), "recovery state contains a nonpassing finding")
phase_c = recovery.get("phaseCContinuation", {})
require(phase_c.get("applicationVersion") == marketing, "Phase C application version differs")
require(phase_c.get("applicationBuild") == build, "Phase C application build differs")
require(phase_c.get("status") == "PASS", "Phase C continuation status differs")
require(phase_c.get("outcome") == PHASE_C_OUTCOME, "Phase C outcome differs")
require(
    phase_c.get("correctedV31PackageStatus") == CORRECTED_V31_PACKAGE_STATUS,
    "corrected v3.1 package is not accepted",
)
require(phase_c.get("firstIncompletePhase") == "Phase D - Build the four Theme Modules", "Phase C next phase differs")
require(phase_c.get("phaseDReadiness") == PHASE_D_READINESS, "Phase D readiness differs")
require(phase_c.get("phaseDStatus") == PHASE_D_STATUS, "Phase D status differs")
require(phase_c.get("pullRequestNumber") == PULL_REQUEST_NUMBER, "Phase C pull request differs")
require(phase_c.get("pullRequestState") == "MERGED", "Phase C pull request state differs")
require(phase_c.get("targetBranch") == "main", "Phase C target branch differs")
require(phase_c.get("mergeCommit") == MERGE_COMMIT, "Phase C merge commit differs")
require(phase_c.get("auditedSourceCommit") == AUDITED_SOURCE_COMMIT, "Phase C audited source commit differs")
require(phase_c.get("evidenceCommit") == EVIDENCE_COMMIT, "Phase C evidence commit differs")
require("physicalDeviceStatus" not in phase_c, "Phase C continuation retains hardware status")
require("physicalDevicePending" not in phase_c, "Phase C continuation retains hardware procedures")

phase_c_record = json.loads(read("docs/verification/elven-recovery-v3/PhaseCContinuation.json"))
for key in (
    "applicationVersion",
    "applicationBuild",
    "status",
    "outcome",
    "correctedV31PackageStatus",
    "firstIncompletePhase",
    "phaseDReadiness",
    "phaseDStatus",
    "pullRequestNumber",
    "pullRequestState",
    "targetBranch",
    "mergeCommit",
    "auditedSourceCommit",
    "evidenceCommit",
):
    require(phase_c_record.get(key) == phase_c.get(key), f"Phase C continuation records disagree on {key}")
require("physicalDeviceStatus" not in phase_c_record, "standalone Phase C record retains hardware status")
require("physicalDevicePending" not in phase_c_record, "standalone Phase C record retains hardware procedures")
require(
    phase_c_record.get("sourceFilesChanged") == phase_c.get("sourceFilesChanged"),
    "Phase C continuation records disagree on sourceFilesChanged",
)
package = phase_c_record.get("package", {})
require(package.get("logicalResourceCount") == 56, "Phase C logical resource count differs")
require(package.get("shippingOutputCount") == 184, "Phase C shipping output count differs")
require(package.get("provenanceRecordCount") == 198, "Phase C provenance count differs")
require(phase_c_record.get("remainingWork") == [], "Phase C continuation retains unfinished work")
require(phase_c.get("remainingWork") == [], "embedded Phase C continuation remainingWork must be present and empty")
require(
    phase_c_record.get("remainingWork") == phase_c.get("remainingWork"),
    "Phase C continuation records disagree on remainingWork",
)

phase_c_evidence = {
    "docs/verification/elven-phase-c/AllNineRegression.json": (("summary", "status"), "PASS"),
    "docs/verification/elven-phase-c/PhaseCValidation.json": ("status", "PASS"),
    "docs/verification/elven-phase-c/PhaseCValidatorMutations.json": ("status", "PASS"),
    "docs/verification/elven-phase-c/DeterministicRegeneration.json": ("status", "PASS"),
    "docs/verification/elven-phase-c/FinalPackageComparison.json": ("status", "PASS"),
    "docs/verification/elven-phase-c/PackageInventory.json": ("status", "PASS"),
    "docs/verification/elven-phase-c/RepositoryRegression.json": ("status", "PASS"),
    "docs/verification/elven-phase-c/PublicationAudit.json": ("status", "PASS"),
}
for relative, (key_path, expected) in phase_c_evidence.items():
    record = json.loads(read(relative))
    value = record
    for key in key_path if isinstance(key_path, tuple) else (key_path,):
        value = value.get(key) if isinstance(value, dict) else None
    require(value == expected, f"{relative} is not {expected}")

repository_regression = json.loads(read("docs/verification/elven-phase-c/RepositoryRegression.json"))
require(repository_regression.get("applicationVersion") == marketing, "repository regression application version differs")
require(repository_regression.get("applicationBuild") == build, "repository regression application build differs")
require(
    repository_regression.get("auditedSourceCommit") == AUDITED_SOURCE_COMMIT,
    "repository regression audited source commit differs",
)
require("physicalDeviceStatus" not in repository_regression, "repository regression retains hardware status")
require("physicalDevicePending" not in repository_regression, "repository regression retains hardware procedures")

publication_audit = json.loads(read("docs/verification/elven-phase-c/PublicationAudit.json"))
require(publication_audit.get("applicationVersion") == marketing, "publication audit application version differs")
require(publication_audit.get("applicationBuild") == build, "publication audit application build differs")
require(publication_audit.get("sourceBranch") == "feature/elven-phase-c-production", "publication audit source branch differs")
require(publication_audit.get("auditedSourceCommit") == AUDITED_SOURCE_COMMIT, "publication audit source commit differs")
require(publication_audit.get("evidenceCommit") == EVIDENCE_COMMIT, "publication audit evidence commit differs")
require(publication_audit.get("pullRequestNumber") == PULL_REQUEST_NUMBER, "publication audit pull request differs")
require(publication_audit.get("pullRequestState") == "MERGED", "publication audit pull request state differs")
require(publication_audit.get("targetBranch") == "main", "publication audit target branch differs")
require(publication_audit.get("mergeCommit") == MERGE_COMMIT, "publication audit merge commit differs")
require(publication_audit.get("mergedAtUTC") == "2026-08-22T11:30:03Z", "publication audit merge time differs")
require(publication_audit.get("pullRequestMetadataChecked") is True, "publication audit did not verify pull request metadata")
require("repositoryBranch" not in publication_audit, "publication audit retains an ambiguous repository branch")
require(
    "pullRequestMetadataRequiredBeforePublication" not in publication_audit.get("repositoryAudit", {}),
    "publication audit retains pre-merge pull request readiness state",
)

for command in phase_c_record.get("commands", []):
    require("<intended-" not in command and "<clean-" not in command, "Phase C command retains a path placeholder")

current_status_docs = {
    "README.md": readme,
    "CHANGELOG.md": changelog,
    "docs/architecture/RoadmapAlignment.md": roadmap,
    "docs/architecture/ForsettiSupersessionIndex.md": supersession_index,
    "docs/architecture/decisions/README.md": decision_index,
    "docs/architecture/decisions/ADR-RS-005-forward-compatibility.md": forward_compatibility,
    "docs/architecture/decisions/ADR-RS-012-cipher-invitation-presentation.md": invitation_presentation,
    "docs/verification/ElvenSeriesBlockingResolutionLedger.md": ledger,
}
stale_status = re.compile(
    r"DEV-ELVEN-003\s+through\s+DEV-ELVEN-009.{0,100}(?:remain|still).{0,30}(?:blocked|block)",
    re.IGNORECASE | re.DOTALL,
)
for relative, content in current_status_docs.items():
    require(stale_status.search(content) is None, f"{relative} retains the superseded finding blocker")

publication_tokens = [
    "".join(("cl", "aude")),
    "".join(("chat", "gpt")),
    "".join(("open", "ai")),
    "".join(("anthro", "pic")),
    "".join(("gem", "ini")),
]
named_package_patterns = [
    re.compile("".join(("codex", r"[- _]?", "spark")), re.IGNORECASE),
    re.compile("".join(("sol", r"[- _]?", "ultra")), re.IGNORECASE),
    re.compile("".join(("gpt", r"[- _]?", r"\d")), re.IGNORECASE),
]

tracked = sorted(set(
    git("ls-files", "-z").split("\0")
    + git("ls-files", "--others", "--exclude-standard", "-z").split("\0")
))
text_suffixes = {".md", ".json", ".swift", ".sh", ".py", ".rb", ".yml", ".yaml", ".plist", ".pbxproj"}
for relative in filter(None, tracked):
    path = ROOT / relative
    lowered_name = relative.lower()
    if any(token in lowered_name for token in publication_tokens) or any(pattern.search(relative) for pattern in named_package_patterns):
        ERRORS.append(f"publication-sensitive name: {relative}")
    if path.suffix.lower() not in text_suffixes and path.name not in {"README", "CHANGELOG"}:
        continue
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    for number, line in enumerate(content.splitlines(), start=1):
        if len(line) > 4096:
            continue
        lowered = line.lower()
        if any(token in lowered for token in publication_tokens) or any(pattern.search(line) for pattern in named_package_patterns):
            ERRORS.append(f"publication-sensitive text: {relative}:{number}")

branch = git("branch", "--show-current").strip().lower()
require(not any(token in branch for token in publication_tokens), "branch name violates publication policy")
metadata = git("log", "origin/main..HEAD", "--format=%H%n%an%n%ae%n%s%n%b").lower()
require(not any(token in metadata for token in publication_tokens), "commit metadata violates publication policy")

if ERRORS:
    for error in ERRORS:
        print(f"FAIL {error}")
    sys.exit(1)

print(
    f"Documentation alignment passed: version {marketing} build {build}, "
    "recovery closed, Phase C history retained, roadmap source-complete, "
    "owner test required, not shipped."
)
