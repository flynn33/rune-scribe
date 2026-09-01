#!/usr/bin/env python3
"""Focused tests for the isolated v4.3 negative-mutation runner."""

from __future__ import annotations

import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RUNNER_PATH = REPOSITORY_ROOT / "scripts/theme_fidelity_mutations_v43.py"
AUTHORITY_PACKAGE_NAME = (
    "Rune-Scribe-Theme-Fidelity-v4.3-Canonical-Authority-and-Remediation"
)


def resolve_authority_root() -> Path:
    configured = os.environ.get("RUNESCRIBE_V43_AUTHORITY_PACKAGE")
    candidates = (
        Path(configured) if configured else None,
        Path.home() / "Projects/RuneScribe" / AUTHORITY_PACKAGE_NAME,
        Path.home() / "Projects" / AUTHORITY_PACKAGE_NAME,
    )
    for candidate in candidates:
        if candidate is not None and candidate.is_dir():
            return candidate
    return Path.home() / "Projects/RuneScribe" / AUTHORITY_PACKAGE_NAME


def load_runner():
    spec = importlib.util.spec_from_file_location(
        "theme_fidelity_mutations_v43_under_test", RUNNER_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load mutation runner")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


runner = load_runner()


class MutationRunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.package_root = resolve_authority_root()

    def sandbox(self) -> tuple[tempfile.TemporaryDirectory, Path, dict]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / "repository"
        runner.copy_sandbox(REPOSITORY_ROOT, root)
        contract = runner.build_contract(
            root, source_sha=runner.git_sha(REPOSITORY_ROOT)
        )
        runner.write_json(root / runner.CONTRACT_RELATIVE, contract)
        runner.write_executable_fixtures(root, contract)
        return temporary, root, contract

    def test_declares_every_package_mutation_exactly_once(self) -> None:
        definitions = runner.definitions()
        self.assertEqual(len(definitions), 47)
        self.assertEqual(
            [item.mutation_id for item in definitions],
            [f"V43-MUT-{ordinal:03d}" for ordinal in range(1, 48)],
        )
        self.assertEqual(
            [item.requirement for item in definitions],
            list(runner.MUTATION_REQUIREMENTS),
        )
        self.assertEqual(len(set(runner.CONTRACT_CODES.values())), 38)

    def test_every_declared_target_matches_the_actual_mutation_target(self) -> None:
        _, root, _ = self.sandbox()
        for definition in runner.definitions():
            if definition.ordinal == 13 and not self.package_root.is_dir():
                continue
            expected = root / Path(definition.source_or_authority_file)
            original = runner.snapshot(expected)
            targets, detail = runner.apply_mutation(
                root, definition, self.package_root
            )
            try:
                self.assertEqual(targets, [expected], definition.mutation_id)
                self.assertTrue(detail.strip(), definition.mutation_id)
                mutated = runner.snapshot(expected)
                self.assertNotEqual(original.data, mutated.data, definition.mutation_id)
            finally:
                runner.restore(expected, original)

    def test_text_mutation_anchors_are_unique_and_mutated_swift_parses(self) -> None:
        xcrun = shutil.which("xcrun")
        if xcrun is None:
            self.skipTest("xcrun is unavailable")
        _, root, _ = self.sandbox()
        for ordinal, mutation in runner.TEXT_MUTATIONS.items():
            source = (root / mutation.relative).read_text(encoding="utf-8")
            self.assertEqual(source.count(mutation.before), 1, ordinal)
            self.assertEqual(source.count(mutation.after), 0, ordinal)
            definition = runner.definitions()[ordinal - 1]
            target = root / mutation.relative
            original = runner.snapshot(target)
            runner.apply_mutation(root, definition, self.package_root)
            try:
                parsed = runner.run_command(
                    [xcrun, "swiftc", "-parse", str(target)],
                    cwd=root,
                    timeout=120,
                )
                self.assertEqual(
                    parsed.exit_status,
                    0,
                    f"{definition.mutation_id}: {parsed.stderr}",
                )
            finally:
                runner.restore(target, original)

    def test_non_authority_guards_reject_exact_mutations_and_restore(self) -> None:
        _, root, contract = self.sandbox()
        pristine = runner.inventory_digest(root)
        for definition in runner.definitions():
            if definition.ordinal <= 9 or definition.ordinal == 13:
                continue
            target = root / Path(definition.source_or_authority_file)
            original = runner.snapshot(target)
            targets, _ = runner.apply_mutation(root, definition, self.package_root)
            self.assertEqual(targets, [target], definition.mutation_id)
            findings = runner.case_findings(root, contract, definition.ordinal)
            self.assertEqual(
                [item.code for item in findings],
                [definition.diagnostic_code],
                definition.mutation_id,
            )
            runner.restore(target, original)
            self.assertEqual(
                runner.case_findings(root, contract, definition.ordinal),
                [],
                definition.mutation_id,
            )
            self.assertEqual(
                runner.inventory_digest(root), pristine, definition.mutation_id
            )

    def test_fixture_cases_reject_malformed_or_unbound_state(self) -> None:
        _, root, contract = self.sandbox()
        fixture_ordinals = sorted(runner.FIXTURE_TARGETS)
        for ordinal in fixture_ordinals:
            relative = runner.FIXTURE_TARGETS[ordinal]
            baseline = runner.snapshot(root / relative)
            runner.write_json(
                root / relative,
                {
                    "schemaVersion": "1.0",
                    "fixtureOnly": True,
                    "acceptanceEvidence": False,
                },
            )
            findings = runner.case_findings(root, contract, ordinal)
            self.assertEqual(
                [item.code for item in findings],
                ["V43M-000-CASE-BASELINE"],
                ordinal,
            )
            runner.restore(root / relative, baseline)

        definition = runner.definitions()[29]
        bound = root / Path(definition.bound_source_or_evidence_file)
        original = runner.snapshot(bound)
        runner.atomic_write(bound, original.data + b"\n")
        try:
            findings = runner.case_findings(root, contract, 30)
            self.assertEqual(
                [item.code for item in findings],
                ["V43M-000-CASE-BASELINE"],
            )
        finally:
            runner.restore(bound, original)

    def test_fixture_claims_are_exact_and_explicitly_non_acceptance(self) -> None:
        _, root, contract = self.sandbox()
        documents = runner.executable_fixture_documents(root, contract)
        for ordinal, relative in runner.FIXTURE_TARGETS.items():
            definition = runner.definitions()[ordinal - 1]
            matching = [
                item
                for item in documents[relative]["executableClaims"]
                if item["mutationID"] == definition.mutation_id
            ]
            self.assertEqual(len(matching), 1, definition.mutation_id)
            claim = matching[0]
            self.assertEqual(claim["requirement"], definition.requirement)
            self.assertEqual(claim["scope"], "executable-guard-fixture-only")
            self.assertEqual(
                claim["bindingRole"],
                "context-integrity-only-not-semantic-proof",
            )
            self.assertTrue(documents[relative]["fixtureOnly"])
            self.assertFalse(documents[relative]["acceptanceEvidence"])

    def test_authority_mutations_are_rejected_by_real_import_guard(self) -> None:
        if shutil.which("ffmpeg") is None:
            self.skipTest("ffmpeg is unavailable")
        _, root, _ = self.sandbox()
        pristine = runner.inventory_digest(root)
        for definition in runner.definitions()[:9]:
            target = root / Path(definition.source_or_authority_file)
            original = runner.snapshot(target)
            runner.apply_mutation(root, definition, self.package_root)
            rejected = runner.run_command(
                runner.authority_guard_command(root), cwd=root, timeout=180
            )
            passed, codes, _ = runner.parse_guard_result(definition, rejected)
            self.assertTrue(passed, definition.mutation_id)
            self.assertIn(definition.diagnostic_code, codes)
            runner.restore(target, original)
            positive = runner.run_command(
                runner.authority_guard_command(root), cwd=root, timeout=180
            )
            self.assertTrue(
                runner.positive_guard_passed(positive)[0], definition.mutation_id
            )
            self.assertEqual(
                runner.inventory_digest(root), pristine, definition.mutation_id
            )

    def test_protected_reference_copy_is_rejected_by_real_boundary_guard(self) -> None:
        if not self.package_root.is_dir():
            self.skipTest("v4.3 authority package is unavailable")
        _, root, _ = self.sandbox()
        definition = runner.definitions()[12]
        target = root / Path(definition.source_or_authority_file)
        original = runner.snapshot(target)
        pristine = runner.inventory_digest(root)
        runner.apply_mutation(root, definition, self.package_root)
        rejected = runner.run_command(
            runner.boundary_guard_command(root, self.package_root),
            cwd=root,
            timeout=600,
        )
        passed, codes, _ = runner.parse_guard_result(definition, rejected)
        self.assertTrue(passed)
        self.assertIn("PRB-101", codes)
        runner.restore(target, original)
        positive = runner.run_command(
            runner.boundary_guard_command(root, self.package_root),
            cwd=root,
            timeout=600,
        )
        self.assertTrue(runner.positive_guard_passed(positive)[0])
        self.assertEqual(runner.inventory_digest(root), pristine)

    def test_publication_scanner_fails_closed_for_process_variants(self) -> None:
        prohibited = (
            'import subprocess\nsubprocess.run(["git", "tag", "v1"])',
            'import subprocess as sp\nsp.Popen(["git", "merge", "main"])',
            'from subprocess import run as invoke\nCMD = ["gh", "release", "create"]\ninvoke(CMD)',
            'import os\nos.system("git archive HEAD")',
            'from os import popen\npopen("xcrun notarytool submit app.zip")',
            'def publish():\n import subprocess as sp\n sp.run(args=["git", "tag", "v1"])',
            'import subprocess\ninvoke = subprocess.run\ninvoke(["git", "merge", "main"])',
            'import subprocess\ncommand = input()\nsubprocess.call(command)',
            'not valid Python !!!',
        )
        for source in prohibited:
            self.assertTrue(runner.forbidden_publication_operations(source), source)
        safe = (
            'import subprocess\nsubprocess.run(["git", "status", "--short"])'
        )
        self.assertEqual(runner.forbidden_publication_operations(safe), [])

    def test_guard_result_rejects_unexpected_pass_and_baseline_diagnostics(self) -> None:
        definition = runner.definitions()[29]
        unexpected = runner.CommandResult("guard", 0, '{"result":"PASS"}', "")
        self.assertFalse(runner.parse_guard_result(definition, unexpected)[0])

        mixed = runner.CommandResult(
            "guard",
            1,
            json.dumps(
                {
                    "result": "FAIL",
                    "findings": [
                        {"code": definition.diagnostic_code},
                        {"code": "V43M-000-CASE-BASELINE"},
                    ],
                }
            ),
            "",
        )
        self.assertFalse(runner.parse_guard_result(definition, mixed)[0])

    def test_inventory_and_snapshot_include_bytes_type_and_mode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "record"
            target.write_bytes(b"abcd")
            os.chmod(target, 0o640)
            baseline = runner.inventory_digest(root)
            original = runner.snapshot(target)

            target.write_bytes(b"wxyz")
            self.assertNotEqual(runner.inventory_digest(root), baseline)
            target.write_bytes(b"abcd")
            os.chmod(target, 0o600)
            self.assertNotEqual(runner.inventory_digest(root), baseline)

            runner.restore(target, original)
            self.assertEqual(runner.inventory_digest(root), baseline)
            self.assertEqual(target.stat().st_mode & 0o777, 0o640)

            link = root / "link"
            link.symlink_to("record")
            linked = runner.inventory_digest(root)
            link.unlink()
            link.symlink_to("elsewhere")
            self.assertNotEqual(runner.inventory_digest(root), linked)


if __name__ == "__main__":
    unittest.main()
