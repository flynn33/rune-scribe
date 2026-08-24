# Norse Production Provenance Tooling

This directory is excluded from the shipping resource bundle. The checked-in visual and
audio resources are the release-candidate inputs and are not recreated by repository tooling.
The provenance generator binds those exact bytes to the runtime catalog and integrity
manifest, REM-007 baseline approval, the project ownership statement, and the bundled
font license.

Regenerate and verify their machine-readable provenance from the repository root:

```sh
python3 scripts/generate-norse-production-provenance.py
python3 scripts/check-norse-production-provenance.py
python3 scripts/test-norse-production-provenance.py
```
