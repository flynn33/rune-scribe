from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "scan-attribution.py"
SPEC = importlib.util.spec_from_file_location("scan_attribution", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AttributionScannerTests(unittest.TestCase):
    def test_binary_media_metadata_marker_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "asset.png"
            media.write_bytes(b"independent-pixels\x00" + b"open" + b"ai")

            findings = MODULE.scan_binary_metadata(root, media)

            self.assertEqual(len(findings), 1)
            self.assertEqual(findings[0]["source"], "asset.png")
            self.assertEqual(findings[0]["binaryMetadataMarker"], 1)

    def test_independent_media_metadata_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "asset.png"
            media.write_bytes(b"independent-pixels\x00sRGB\x00aspect")

            self.assertEqual(MODULE.scan_binary_metadata(root, media), [])

    def test_excluded_artifacts_are_not_scanned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "artifacts" / "diagnostic.png"
            media.parent.mkdir()
            media.write_bytes(b"open" + b"ai")

            self.assertEqual(list(MODULE.binary_metadata_files(root)), [])

    def test_immutable_historical_evidence_is_not_rewritten_or_scanned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            historical = (
                root
                / "docs"
                / "verification"
                / "theme-fidelity-v4"
                / "source-master.png"
            )
            historical.parent.mkdir(parents=True)
            historical.write_bytes(b"open" + b"ai")
            current = (
                root
                / "docs"
                / "verification"
                / "theme-fidelity-v4-3"
                / "source-master.png"
            )
            current.parent.mkdir(parents=True)
            current.write_bytes(b"independent-pixels")

            self.assertEqual(list(MODULE.binary_metadata_files(root)), [current])
            self.assertEqual(MODULE.immutable_historical_media_count(root), 1)

    def test_cli_fails_closed_and_records_binary_count(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "asset.png"
            media.write_bytes(b"certificate\x00" + b"chat" + b"gpt")
            output = root / "report.json"

            completed = subprocess.run(
                [sys.executable, str(SCRIPT), str(root), "--output", str(output)],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["result"], "FAIL")
            self.assertEqual(report["scannedBinaryFiles"], 1)
            self.assertEqual(report["findings"][0]["binaryMetadataMarker"], 2)


if __name__ == "__main__":
    unittest.main()
