#!/usr/bin/env python3
"""Focused determinism and negative controls for Norse production provenance."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import ModuleType


def load_module(path: Path, name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    generator_path = root / "scripts/generate-norse-production-provenance.py"
    validator_path = root / "scripts/check-norse-production-provenance.py"
    generator = load_module(generator_path, "norse_provenance_generator_test")
    validator = load_module(validator_path, "norse_provenance_validator_test")

    document_path = root / generator.PROVENANCE_RELATIVE
    document = json.loads(document_path.read_text(encoding="utf-8"))
    baseline_errors = validator.validate_document(root, document)
    if baseline_errors:
        for error in baseline_errors:
            print(f"FAIL: valid provenance rejected: {error}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="runescribe-norse-provenance-") as temporary:
        first = Path(temporary) / "first.json"
        second = Path(temporary) / "second.json"
        for output in (first, second):
            result = subprocess.run(
                [sys.executable, str(generator_path), "--root", str(root), "--output", str(output)],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                print(result.stdout, end="", file=sys.stderr)
                print(result.stderr, end="", file=sys.stderr)
                return 1
        if first.read_bytes() != second.read_bytes() or first.read_bytes() != document_path.read_bytes():
            print("FAIL: Norse provenance generation is not byte-for-byte deterministic", file=sys.stderr)
            return 1

    resource_id = "resource.relic.norse.runestone.weathered.art"
    resource_index = next(
        index
        for index, resource in enumerate(document["resources"])
        if resource["resourceID"] == resource_id
    )

    def mutate(field: str, value: object) -> dict[str, object]:
        changed = copy.deepcopy(document)
        changed["resources"][resource_index][field] = value
        return changed

    mutations = {
        "production path": mutate(
            "normalizedProductionPath",
            "Production/Shipping" + "Candidates/relic.norse.runestone.weathered.png",
        ),
        "byte count": mutate("byteCount", 1),
        "SHA-256": mutate("sha256", "0" * 64),
        "dimensions": mutate("pixelDimensions", {"height": 1, "width": 1}),
        "rights": mutate("rightsProvenanceID", "rights.norse.unknown"),
        "accessibility": mutate("accessibilityDescriptionKey", ""),
        "release status": mutate("releaseStatus", "publicly-approved"),
    }
    for name, changed in mutations.items():
        if not validator.validate_document(root, changed):
            print(f"FAIL: {name} mutation was accepted", file=sys.stderr)
            return 1

    print(
        "PASS: Norse provenance is exact, deterministic, and rejects path, byte, hash, "
        "dimension, rights, accessibility, and status mutations"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
