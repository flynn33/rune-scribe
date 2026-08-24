# AttributionAudit Test Assignments

Source test-matrix SHA-256: `04a91856646f01af203ce0f685fe94951ac15a2184b8340f21764712533142f1`

Every row below is an exact locked TEST-MATRIX execution binding. Paths and hashes identify the immutable result inputs used by this record.

| Test | Result | Suite | Command | Log / SHA-256 | Required evidence | Bound evidence / SHA-256 |
|---|---|---|---|---|---|---|
| T-102: Attribution clean | PASS | Rune Scribe Remediation Final Qualification | `python3 scripts/scan-attribution.py . --patterns /Users/jimdaley/Documents/RavenForge/RuneScribe/Rune-Scribe-Codex-Remediation-Package-v1.0/controls/PROHIBITED-ATTRIBUTION-PATTERNS-v1.0.json` | `docs/verification/remediation-v1/GateRun/final-qualification-results.json`<br>`a711216ffddc8251e8cc6784a467b801f4a8b66d89053cbd5774e06bb495a6d3` | AttributionAudit.json | `docs/verification/remediation-v1/AttributionAudit.json`<br>`8819469520c837a6114f8307f845f55ce63a7d78a878224cad68eebea73f2ef5`<br>`docs/verification/remediation-v1/GateRun/final-qualification-results.json`<br>`a711216ffddc8251e8cc6784a467b801f4a8b66d89053cbd5774e06bb495a6d3` |
<!-- T-102 area=Attribution; platform=All; kind=static; precondition=Final changed files and local commits; action=Run scanner; expected=No prohibited authorship/tool credits; gates=RC-030 -->
