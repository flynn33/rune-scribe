#!/usr/bin/env python3
"""Scan publication text for prohibited automated-authorship credits."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Iterable


TEXT_SUFFIXES = {
    ".swift", ".md", ".txt", ".json", ".yml", ".yaml", ".plist", ".xml",
    ".sh", ".py", ".rb", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm",
}
BINARY_METADATA_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".heic", ".heif", ".pdf",
}
EXCLUDED_CONTENT_PARTS = {".git", ".build", "DerivedData", "artifacts"}
EXCLUDED_PATH_PARTS = {".git", ".build", "DerivedData"}
IMMUTABLE_HISTORICAL_EVIDENCE_ROOTS = (
    Path("docs/verification/theme-fidelity-v4"),
    Path("docs/verification/theme-fidelity-v4-1"),
    Path("docs/verification/theme-fidelity-v4-2"),
)


def binary_metadata_markers() -> tuple[bytes, ...]:
    """Return publication-prohibited authorship/vendor markers for media metadata.

    These markers are intentionally assembled from fragments so the scanner's own
    source remains clean while still rejecting embedded provenance certificates or
    text chunks in publication media.
    """

    return (
        b"open" + b"ai",
        b"chat" + b"gpt",
        b"dall" + b"-e",
    )


def default_pattern_values() -> list[str]:
    tools = ("chat" + "gpt", "open" + "ai", "co" + "dex")
    values = [
        f"{credit} by {tool}"
        for credit in ("generated", "written", "created")
        for tool in tools
    ]
    values.extend(
        [
            "ai" + "-generated",
            "ai" + " generated",
            *(f"co-authored-by:.*{tool}" for tool in tools),
            "authored by an " + "ai",
            "authored with " + "ai",
        ]
    )
    return values


def load_patterns(path: Path | None) -> list[re.Pattern[str]]:
    values: Iterable[str]
    if path is None:
        values = default_pattern_values()
    else:
        data = json.loads(path.read_text(encoding="utf-8"))
        values = data["caseInsensitivePatterns"]
    return [re.compile(value, re.IGNORECASE) for value in values]


def text_files(root: Path):
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if any(part in EXCLUDED_CONTENT_PARTS for part in path.parts):
            continue
        yield path


def binary_metadata_files(root: Path):
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in BINARY_METADATA_SUFFIXES:
            continue
        if any(part in EXCLUDED_CONTENT_PARTS for part in path.parts):
            continue
        relative = path.relative_to(root)
        if is_immutable_historical_evidence(relative):
            continue
        yield path


def is_immutable_historical_evidence(relative: Path) -> bool:
    return any(
        relative == historical or historical in relative.parents
        for historical in IMMUTABLE_HISTORICAL_EVIDENCE_ROOTS
    )


def immutable_historical_media_count(root: Path) -> int:
    count = 0
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in BINARY_METADATA_SUFFIXES:
            continue
        if any(part in EXCLUDED_CONTENT_PARTS for part in path.parts):
            continue
        if is_immutable_historical_evidence(path.relative_to(root)):
            count += 1
    return count


def publication_paths(root: Path):
    for path in sorted(root.rglob("*")):
        if not path.is_file() or any(part in EXCLUDED_PATH_PARTS for part in path.parts):
            continue
        yield path.relative_to(root).as_posix()


def scan_text(
    label: str,
    value: str,
    patterns: list[re.Pattern[str]],
) -> list[dict[str, object]]:
    findings: list[dict[str, object]] = []
    for line_number, line in enumerate(value.splitlines(), 1):
        for pattern in patterns:
            if pattern.search(line):
                findings.append(
                    {
                        "source": label,
                        "line": line_number,
                        "pattern": pattern.pattern,
                    }
                )
    return findings


def scan_binary_metadata(root: Path, path: Path) -> list[dict[str, object]]:
    value = path.read_bytes().lower()
    findings: list[dict[str, object]] = []
    for marker_index, marker in enumerate(binary_metadata_markers(), 1):
        if marker in value:
            findings.append(
                {
                    "source": path.relative_to(root).as_posix(),
                    "binaryMetadataMarker": marker_index,
                }
            )
    return findings


def git_messages(root: Path) -> str:
    result = subprocess.run(
        ["git", "log", "--format=%H%x09%B%x00", "--max-count=200"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout if result.returncode == 0 else ""


def git_branch(root: Path) -> str:
    result = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def normalized_label(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", " ", value)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--patterns", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--publication-text",
        type=Path,
        action="append",
        default=[],
        help="additional PR, comment, or release text to audit",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    patterns = load_patterns(args.patterns.resolve() if args.patterns else None)
    findings: list[dict[str, object]] = []
    scanned = 0
    scanned_binary = 0
    immutable_historical_binary = immutable_historical_media_count(root)
    scanned_paths = 0
    for relative in publication_paths(root):
        scanned_paths += 1
        findings.extend(
            scan_text(
                f"path:{relative}",
                normalized_label(relative),
                patterns,
            )
        )
    for path in text_files(root):
        scanned += 1
        try:
            value = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        findings.extend(
            scan_text(path.relative_to(root).as_posix(), value, patterns)
        )
    for path in binary_metadata_files(root):
        scanned_binary += 1
        findings.extend(scan_binary_metadata(root, path))
    messages = git_messages(root)
    if messages:
        findings.extend(scan_text("git-log", messages, patterns))
    branch = git_branch(root)
    if branch:
        findings.extend(
            scan_text("git-branch", normalized_label(branch), patterns)
        )
    scanned_publication_texts = 0
    for publication_path in args.publication_text:
        resolved = publication_path.resolve()
        try:
            value = resolved.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exception:
            print(
                f"FAIL: unable to read publication text {resolved}: {exception}",
                file=sys.stderr,
            )
            return 1
        scanned_publication_texts += 1
        findings.extend(scan_text(f"publication:{resolved.name}", value, patterns))

    record = {
        "schemaVersion": "1.0",
        "result": "PASS" if not findings else "FAIL",
        "scannedTextFiles": scanned,
        "scannedBinaryFiles": scanned_binary,
        "preservedImmutableHistoricalMediaFiles": immutable_historical_binary,
        "immutableHistoricalEvidenceRoots": [
            path.as_posix() for path in IMMUTABLE_HISTORICAL_EVIDENCE_ROOTS
        ],
        "scannedPathLabels": scanned_paths,
        "scannedPublicationTexts": scanned_publication_texts,
        "branchScanned": bool(branch),
        "findings": findings,
    }
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    if findings:
        for finding in findings:
            if "binaryMetadataMarker" in finding:
                print(
                    f"FAIL: {finding['source']} contains prohibited binary metadata "
                    f"marker {finding['binaryMetadataMarker']}",
                    file=sys.stderr,
                )
            else:
                print(
                    f"FAIL: {finding['source']}:{finding['line']} matched "
                    f"{finding['pattern']}",
                    file=sys.stderr,
                )
        return 1
    print(
        f"PASS: scanned {scanned} text files and {scanned_binary} media files; "
        f"preserved {immutable_historical_binary} immutable historical media files"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
