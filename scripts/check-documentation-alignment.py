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


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        ERRORS.append(f"missing file: {relative}")
        return ""
    return path.read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        ERRORS.append(message)


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

readme = read("README.md")
require(
    f"version-{marketing}%20build%20{build}" in readme,
    "README version badge differs from project version",
)
require("All nine Elven Series recovery findings pass simultaneously" in readme, "README lacks current recovery result")
require("Phase C remains in progress" in readme, "README lacks current Phase C boundary")

submission = read("docs/APP_STORE_SUBMISSION.md")
require(
    f"**Last prepared for:** {marketing} (build {build}) — {release_date}" in submission,
    "App Store packet header differs from current release",
)
require(f"| **Version** | `{marketing}` |" in submission, "App Store packet version differs")
require(f"| **Build** | `{build}` |" in submission, "App Store packet build differs")
require(f"## What ships in {marketing}" in submission, "App Store packet summary differs")

roadmap = read("docs/architecture/RoadmapAlignment.md")
require("Continue Elven Series Phase C" in roadmap, "roadmap lacks current Elven next gate")
require("validated Elven Series recovery boundary" in roadmap, "roadmap lacks recovery result")
require("Keep Elven Series Phase C blocked" not in roadmap, "roadmap retains superseded Phase C blocker")

roadmap_state = json.loads(read("docs/verification/roadmap-alignment.json"))
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
require("stat.message.incoming-decoded.unique" in ledger, "resolution ledger lacks canonical decode statistic")
require(ledger.count("| PASS |") == 9, "resolution ledger does not record exactly nine passing findings")
require("Phase C in progress" in ledger, "resolution ledger lacks current Phase C status")

historical_reports = (
    "docs/verification/ElvenSeriesBlockingDeviationReport.md",
    "docs/verification/ElvenSeriesBlockingRemediationFinalAudit.md",
    "docs/verification/ThemeScaffoldAndNorseBaseImplementationReport.md",
)
for relative in historical_reports:
    require(
        any("Historical" in line for line in read(relative).splitlines()[2:10]),
        f"{relative} lacks a historical-status marker",
    )

link_pages = (
    "README.md",
    "docs/APP_STORE_SUBMISSION.md",
    "docs/architecture/RoadmapAlignment.md",
    "docs/verification/ElvenSeriesBlockingDeviationReport.md",
    "docs/verification/ElvenSeriesBlockingRemediationFinalAudit.md",
    "docs/verification/ThemeScaffoldAndNorseBaseImplementationReport.md",
)
markdown_link = re.compile(r"\[[^]]+\]\(([^)]+)\)")
for relative in link_pages:
    page = ROOT / relative
    for target in markdown_link.findall(read(relative)):
        target = target.strip().strip("<>").split("#", 1)[0]
        if not target or target.startswith(("/", "#", "mailto:")) or "://" in target:
            continue
        require((page.parent / target).exists(), f"{relative} has a missing link target: {target}")

recovery = json.loads(read("docs/verification/elven-recovery-v3/RecoveryState.json"))
require(recovery.get("recoveryStatus") == "PASS / UNBLOCKED FOR PHASE C", "recovery state is not accepted")
findings = recovery.get("findings", [])
require(len(findings) == 9, "recovery state does not contain exactly nine findings")
require(all(item.get("status") == "PASS" for item in findings), "recovery state contains a nonpassing finding")
phase_c = recovery.get("phaseCContinuation", {})
require(phase_c.get("status") == "IN_PROGRESS", "Phase C continuation status differs")

current_status_docs = {
    "README.md": readme,
    "CHANGELOG.md": changelog,
    "docs/architecture/RoadmapAlignment.md": roadmap,
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

tracked = git("ls-files", "-z").split("\0")
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

print(f"Documentation alignment passed: version {marketing} build {build}, nine recovery findings, Phase C in progress.")
