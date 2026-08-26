#!/usr/bin/env python3
"""Command-line entry point for Theme-fidelity v4.2 evidence assembly."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from theme_fidelity_evidence_v42 import EvidenceError, assemble


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Assemble the 40-gate v4.2 evidence set from an exact final capture "
            "run and source-bound qualification results."
        )
    )
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("docs/verification/theme-fidelity-v4"),
    )
    parser.add_argument("--capture-run", type=Path, required=True)
    parser.add_argument("--qualification-results", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    root = arguments.root.resolve()
    output_root = (
        arguments.output_root.resolve()
        if arguments.output_root.is_absolute()
        else (root / arguments.output_root).resolve()
    )
    capture_run = (
        arguments.capture_run.resolve()
        if arguments.capture_run.is_absolute()
        else (root / arguments.capture_run).resolve()
    )
    qualification_results = (
        arguments.qualification_results.resolve()
        if arguments.qualification_results.is_absolute()
        else (root / arguments.qualification_results).resolve()
    )
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--root",
        str(root),
        "--output-root",
        str(output_root),
        "--capture-run",
        str(capture_run),
        "--qualification-results",
        str(qualification_results),
    ]
    try:
        summary = assemble(
            root,
            output_root,
            capture_run,
            qualification_results,
            command,
        )
    except EvidenceError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: assembled "
        f"{summary['passingGateCount']}/{summary['gateCount']} blocking gates"
    )
    print(f"SUMMARY: {output_root / 'gate-summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
