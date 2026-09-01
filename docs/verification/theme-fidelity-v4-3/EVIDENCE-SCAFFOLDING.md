# Theme Fidelity v4.3 Evidence Scaffolding

`scripts/theme_fidelity_evidence_v43.py` records qualification commands and
assembles the package-required top-level evidence files without inferring an
acceptance result.

## Record a command

Run acceptance commands only after the application source commit is frozen. The
recorder captures the exact argument vector, working directory, timestamps,
exit code, combined log, declared output hashes, and source-tree state.

```zsh
python3 scripts/theme_fidelity_evidence_v43.py record-command \
  --source-sha "$SOURCE_SHA" \
  --command-id package-preflight \
  --category preflight \
  --acceptance \
  -- ./05-AUTOMATION/run-v4.3-preflight.sh
```

The recorder does not interpret a successful process exit as proof that a
blocking gate passed. Record that assessment separately and bind it to exact
evidence files:

```zsh
python3 scripts/theme_fidelity_evidence_v43.py record-gate \
  --source-sha "$SOURCE_SHA" \
  --gate-id PRE-001 \
  --result PASS \
  --command-id package-preflight \
  --evidence docs/verification/theme-fidelity-v4-3/commands/records/package-preflight.json
```

## Assemble the pre-publication state

```zsh
python3 scripts/theme_fidelity_evidence_v43.py assemble-prepublication \
  --source-sha "$SOURCE_SHA" \
  --commands-complete
```

This command is expected to exit nonzero. It writes real diagnostic records
with `acceptanceEvidence: false` and `result: FAIL`, represents every missing or
failing gate, and keeps unresolved blockers in `FailureLedger.json`. It never
converts a package template, an absent result set, or a successful shell exit
into acceptance evidence.

## Evidence-head boundary

The package defines `evidenceHeadSHA` as the PR-head commit while also requiring
that SHA inside `final-qualification.json` and `SourceBoundary.json`, which are
files contained by the same commit. Updating either file changes the Git tree
and therefore changes the commit SHA. The package also requires `PUB-001` to
pass before publication even though that gate requires the branch to be pushed
and a review PR to exist.

The pre-publication assembler keeps `SRC-001`, `EVID-001`, `PUB-001`, and
`AUDIT-001` failed and records the circularity as a blocking failure. It does not
substitute a parent commit, placeholder SHA, or predicted SHA. The read-only
head verifier can test a proposed committed state:

```zsh
python3 scripts/theme_fidelity_evidence_v43.py verify-head-binding \
  --source-sha "$SOURCE_SHA" \
  --evidence-head-sha "$EVIDENCE_HEAD_SHA"
```

A final acceptance run requires a corrected authority contract that provides a
non-self-referential publication attestation or defines the evidence head as a
pre-attestation commit. Until then, the package evidence validator must reject
the pre-publication scaffold.
