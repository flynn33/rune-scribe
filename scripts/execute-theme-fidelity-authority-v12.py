#!/usr/bin/env python3
"""Command-line entry point for executable Theme fidelity authority v1.2."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from theme_fidelity_execution_v12 import (
    AuthorityExecutor,
    ExecutionError,
    default_toolchain,
    load_json,
    require_clean_source,
    sha256_file,
    source_sha,
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--captures", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--toolchain-report", type=Path)
    parser.add_argument(
        "--source-exclusion",
        type=Path,
        action="append",
        default=[],
        help="Generated evidence tree to omit from the clean-source check.",
    )
    parser.add_argument(
        "--allow-dirty-source",
        action="store_true",
        help="Permit a dirty worktree for focused development runs only.",
    )
    parser.add_argument(
        "--command-record",
        action="append",
        default=[],
        help="Additional exact command provenance to bind into every generated record.",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    root = arguments.root.resolve()
    captures = arguments.captures.resolve()
    output_root = arguments.output_root.resolve()
    command = [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]]
    command.extend(arguments.command_record)
    try:
        if not arguments.allow_dirty_source:
            require_clean_source(root, output_root, arguments.source_exclusion)
        if arguments.toolchain_report is not None:
            toolchain_path = arguments.toolchain_report.resolve()
            toolchain = {
                "path": str(toolchain_path),
                "sha256": sha256_file(toolchain_path),
                "report": load_json(toolchain_path, "toolchain report"),
            }
        else:
            toolchain = default_toolchain()
        executor = AuthorityExecutor(
            root=root,
            capture_root=captures,
            output_root=output_root,
            source_sha=source_sha(root),
            command=command,
            toolchain=toolchain,
        )
        result = executor.run()
    except ExecutionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2
    summary = {
        key: result[key]
        for key in (
            "result", "entryCount", "mappingCount", "passingEntryCount",
            "passingMappingCount", "runtimeProbeEvaluationCount", "sourceSHA",
            "failures",
        )
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
