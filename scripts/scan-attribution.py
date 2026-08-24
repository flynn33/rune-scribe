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
EXCLUDED_CONTENT_PARTS = {".git", ".build", "DerivedData", "artifacts"}
EXCLUDED_PATH_PARTS = {".git", ".build", "DerivedData"}


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
            print(
                f"FAIL: {finding['source']}:{finding['line']} matched "
                f"{finding['pattern']}",
                file=sys.stderr,
            )
        return 1
    print(f"PASS: scanned {scanned} text files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
