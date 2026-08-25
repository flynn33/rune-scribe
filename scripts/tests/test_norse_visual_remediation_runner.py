#!/usr/bin/env python3
"""Regression tests for source-bound Norse mutation qualification."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RUNNER_PATH = REPOSITORY_ROOT / "scripts/test-norse-visual-remediation.py"


def load_runner():
    spec = importlib.util.spec_from_file_location(
        "test_norse_visual_remediation_runner_module",
        RUNNER_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {RUNNER_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


runner = load_runner()


class NorseVisualRemediationRunnerTests(unittest.TestCase):
    def test_source_fingerprint_ignores_build_and_tool_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Packages/Example/Sources/Example.swift"
            source.parent.mkdir(parents=True)
            source.write_text("struct Example {}\n", encoding="utf-8")
            baseline = runner.source_fingerprint(root)

            ignored_files = (
                root / "Packages/Example/.build/debug/object.o",
                root / "Packages/Example/build/output.bin",
                root / "Packages/Example/DerivedData/index/store",
                root / "Packages/Example/result.xcresult/Data/data.0~abc",
                root / "Packages/Example/__pycache__/module.pyc",
                root / "Packages/Example/.DS_Store",
            )
            for path in ignored_files:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"ignored output\n")

            self.assertEqual(runner.source_fingerprint(root), baseline)

    def test_source_fingerprint_detects_source_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Packages/Example/Sources/Example.swift"
            source.parent.mkdir(parents=True)
            source.write_text("struct Example {}\n", encoding="utf-8")
            baseline = runner.source_fingerprint(root)

            source.write_text("struct Changed {}\n", encoding="utf-8")

            self.assertNotEqual(runner.source_fingerprint(root), baseline)


if __name__ == "__main__":
    unittest.main()
