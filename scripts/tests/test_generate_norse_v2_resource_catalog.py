#!/usr/bin/env python3
"""Focused tests for the Norse v2 resource-catalog generator."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
GENERATOR_PATH = REPO_ROOT / "scripts/generate-norse-v2-resource-catalog.py"
SPEC = importlib.util.spec_from_file_location("norse_v2_resource_catalog", GENERATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"unable to load {GENERATOR_PATH}")
GENERATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GENERATOR
SPEC.loader.exec_module(GENERATOR)


class NorseV2ResourceCatalogGeneratorTests(unittest.TestCase):
    def test_inventory_is_exact_unique_and_current(self) -> None:
        values = GENERATOR.resource_specs()
        self.assertEqual(len(values), 70)
        self.assertEqual(len({value.handle for value in values}), 70)
        self.assertEqual(len({value.relative_path for value in values}), 70)
        self.assertEqual(
            len({(value.application_name, value.extension) for value in values}),
            70,
        )
        handles = {value.handle for value in values}
        self.assertIn("resource.relic.norse.runestone-tablet.master", handles)
        self.assertIn("resource.seal.norse.berserk.vector-master", handles)
        self.assertIn("resource.codex-card.norse.unavailable", handles)
        self.assertIn("resource.panel.norse.tab-selector", handles)
        self.assertNotIn("resource.relic.norse.runestone.weathered.art", handles)
        self.assertNotIn("resource.crest.norse.forge-master.vector", handles)

    def test_application_catalog_declares_every_handle_once(self) -> None:
        values = GENERATOR.resource_specs()
        source = GENERATOR.application_catalog_source(values)
        for value in values:
            self.assertEqual(source.count(f'"{value.handle}"'), 1)
            self.assertIn(
                f'resource("{value.application_name}", "{value.extension}")',
                source,
            )
        self.assertIn("Norse-Resource-Integrity-Manifest-v2.0", source)

    def test_exact_file_gate_rejects_missing_and_unexpected_resources(self) -> None:
        values = GENERATOR.resource_specs()
        with tempfile.TemporaryDirectory(prefix="norse-v2-catalog-") as temporary:
            root = Path(temporary)
            resource_root = root / GENERATOR.RESOURCE_ROOT_RELATIVE
            for value in values:
                path = resource_root / value.path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"resource")
            GENERATOR.ensure_exact_files(root, values)

            missing = resource_root / values[0].path
            missing.unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                GENERATOR.ensure_exact_files(root, values)
            missing.write_bytes(b"resource")

            unexpected = resource_root / "Production/unexpected.bin"
            unexpected.write_bytes(b"unexpected")
            with self.assertRaisesRegex(ValueError, "unexpected"):
                GENERATOR.ensure_exact_files(root, values)


if __name__ == "__main__":
    unittest.main()
