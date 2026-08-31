#!/usr/bin/env python3
"""Record and assemble truthful Theme Fidelity v4.3 qualification evidence.

This tool deliberately separates diagnostic/pre-publication evidence from final
acceptance evidence.  The package defines ``evidenceHeadSHA`` as the commit that
contains ``final-qualification.json`` and ``SourceBoundary.json``.  A generator
cannot write that commit's SHA into either tracked file without changing the
commit SHA.  Consequently this tool never promotes its own output to acceptance
evidence and never marks the publication-dependent gates as passing.

The records produced here are deterministic apart from explicitly recorded UTC
timestamps and command output.  JSON is always written with sorted keys and a
trailing newline.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
from importlib import metadata
import json
from pathlib import Path
import platform
import plistlib
import re
import shlex
import subprocess
import sys
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = "1.3"
EVIDENCE_RELATIVE = Path("docs/verification/theme-fidelity-v4-3")
AUTHORITY_RELATIVE = EVIDENCE_RELATIVE / "authority"
COMMAND_RECORDS_RELATIVE = Path("commands/records")
COMMAND_LOGS_RELATIVE = Path("commands/logs")
GATE_RECORDS_RELATIVE = Path("gate-records")
FAILURE_RECORDS_RELATIVE = Path("failure-records")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
PUBLICATION_DEPENDENT_GATES = {
    "SRC-001",
    "EVID-001",
    "PUB-001",
    "AUDIT-001",
}
AGGREGATE_TEMPLATES: Mapping[str, tuple[str, str]] = {
    "canonical-results.json": ("results", "canonical candidates"),
    "responsive-results.json": ("entries", "responsive entries"),
    "runtime-probe-results.json": ("results", "runtime probe instances"),
    "mapping-results.json": ("results", "mapping results"),
}


class EvidenceError(ValueError):
    """Raised when requested evidence cannot be represented truthfully."""


@dataclass(frozen=True)
class Paths:
    root: Path
    evidence: Path
    authority: Path
    comparison_authority: Path
    canonical_catalog: Path
    gate_catalog: Path


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def parse_timestamp(value: str) -> str:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError(f"invalid ISO-8601 timestamp: {value}") from error
    if parsed.tzinfo is None:
        raise EvidenceError("timestamp must include a timezone")
    return parsed.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def event_timestamp(value: str | None) -> str:
    return parse_timestamp(value) if value else utc_now()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json_bytes(value))


def read_json(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise EvidenceError(f"missing {label}: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceError(f"invalid {label}: {path}: {error}") from error
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be a JSON object: {path}")
    return value


def run_git(root: Path, *arguments: str, text: bool = True) -> str | bytes:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
    )
    if completed.returncode != 0:
        stderr = completed.stderr if text else completed.stderr.decode("utf-8", "replace")
        raise EvidenceError(f"git {' '.join(arguments)} failed: {stderr.strip()}")
    return completed.stdout


def resolve_root(value: Path | None) -> Path:
    root = (value or Path(__file__).resolve().parents[1]).resolve()
    if not (root / ".git").exists():
        # Worktrees have a .git file; normal repositories have a directory.
        raise EvidenceError(f"repository root has no .git entry: {root}")
    return root


def build_paths(root: Path, evidence_root: Path | None) -> Paths:
    evidence = (evidence_root or (root / EVIDENCE_RELATIVE)).resolve()
    try:
        evidence.relative_to(root)
    except ValueError as error:
        raise EvidenceError("evidence root must be inside the repository") from error
    authority = evidence / "authority"
    return Paths(
        root=root,
        evidence=evidence,
        authority=authority,
        comparison_authority=(
            authority
            / "03-COMPARISON-AUTHORITY/Comparison-Authority-v1.3.json"
        ),
        canonical_catalog=(
            authority
            / "03-COMPARISON-AUTHORITY/Canonical-Render-Catalog-v1.3.json"
        ),
        gate_catalog=authority / "06-EVIDENCE/Gate-Catalog-v4.3.json",
    )


def require_sha(value: str, label: str) -> str:
    if not HEX40.fullmatch(value):
        raise EvidenceError(f"{label} must be a lowercase 40-character Git SHA")
    return value


def resolve_commit(root: Path, value: str, label: str) -> str:
    output = str(run_git(root, "rev-parse", "--verify", f"{value}^{{commit}}"))
    return require_sha(output.strip(), label)


def head_sha(root: Path) -> str:
    return resolve_commit(root, "HEAD", "HEAD")


def relative_repo_path(path: Path, root: Path, label: str) -> str:
    resolved = path.resolve()
    try:
        relative = resolved.relative_to(root)
    except ValueError as error:
        raise EvidenceError(f"{label} must be inside the repository: {path}") from error
    return relative.as_posix()


def worktree_changes(root: Path, allowed_root: Path) -> tuple[list[str], list[str]]:
    tracked = str(run_git(root, "diff", "--name-only", "HEAD")).splitlines()
    untracked = str(
        run_git(root, "ls-files", "--others", "--exclude-standard")
    ).splitlines()
    all_changes = sorted(set(path for path in tracked + untracked if path))
    allowed = relative_repo_path(allowed_root, root, "evidence root").rstrip("/") + "/"
    outside = [path for path in all_changes if not path.startswith(allowed)]
    return all_changes, outside


def source_state(root: Path, evidence: Path, source_sha: str) -> dict[str, Any]:
    current_head = head_sha(root)
    changes, outside = worktree_changes(root, evidence)
    return {
        "requestedSourceSHA": source_sha,
        "headSHA": current_head,
        "headMatchesSource": current_head == source_sha,
        "worktreeChangeCount": len(changes),
        "worktreeChangesOutsideEvidenceRoot": outside,
        "worktreeCleanOutsideEvidenceRoot": not outside,
        "acceptanceEligible": current_head == source_sha and not outside,
    }


def load_authority(paths: Paths) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    return (
        read_json(paths.comparison_authority, "v4.3 comparison authority"),
        read_json(paths.canonical_catalog, "v4.3 canonical catalog"),
        read_json(paths.gate_catalog, "v4.3 gate catalog"),
    )


def binding(path: Path, evidence: Path) -> dict[str, Any]:
    relative = path.resolve().relative_to(evidence).as_posix()
    return {
        "path": relative,
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def repository_or_external_binding(path: Path, root: Path) -> dict[str, Any]:
    resolved = path.resolve()
    try:
        stored_path = resolved.relative_to(root).as_posix()
        location = "repository"
    except ValueError:
        stored_path = str(resolved)
        location = "external-absolute"
    return {
        "path": stored_path,
        "location": location,
        "bytes": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def resolve_evidence_path(value: str, paths: Paths, label: str) -> Path:
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = paths.root / candidate
    candidate = candidate.resolve()
    if not candidate.is_file():
        raise EvidenceError(f"{label} does not exist: {candidate}")
    return candidate


def batched_blob_records(root: Path, source_sha: str) -> list[dict[str, Any]]:
    raw = bytes(run_git(root, "ls-tree", "-r", "-z", "--full-tree", source_sha, text=False))
    entries: list[tuple[str, str, str, str]] = []
    for chunk in raw.split(b"\0"):
        if not chunk:
            continue
        metadata_bytes, path_bytes = chunk.split(b"\t", 1)
        mode, kind, object_id = metadata_bytes.decode("ascii").split(" ")
        path = path_bytes.decode("utf-8", "surrogateescape")
        entries.append((mode, kind, object_id, path))

    blob_ids = [object_id for _, kind, object_id, _ in entries if kind == "blob"]
    blob_data: dict[str, tuple[int, str]] = {}
    if blob_ids:
        process = subprocess.Popen(
            ["git", "cat-file", "--batch"],
            cwd=root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        for object_id in blob_ids:
            process.stdin.write(object_id.encode("ascii") + b"\n")
        process.stdin.close()
        for expected_id in blob_ids:
            header = process.stdout.readline().rstrip(b"\n")
            parts = header.split(b" ")
            if len(parts) != 3 or parts[1] != b"blob":
                process.kill()
                raise EvidenceError(f"unable to read Git blob {expected_id}: {header!r}")
            returned_id = parts[0].decode("ascii")
            size = int(parts[2])
            content = process.stdout.read(size)
            trailer = process.stdout.read(1)
            if returned_id != expected_id or len(content) != size or trailer != b"\n":
                process.kill()
                raise EvidenceError(f"malformed git cat-file response for {expected_id}")
            blob_data[expected_id] = (size, sha256_bytes(content))
        stderr = process.stderr.read() if process.stderr is not None else b""
        return_code = process.wait()
        if return_code != 0:
            raise EvidenceError(f"git cat-file failed: {stderr.decode('utf-8', 'replace')}")

    records: list[dict[str, Any]] = []
    for mode, kind, object_id, path in entries:
        if kind == "blob":
            size, digest = blob_data[object_id]
            record_kind = "symlink" if mode == "120000" else "file"
        elif kind == "commit":
            encoded = object_id.encode("ascii")
            size, digest, record_kind = len(encoded), sha256_bytes(encoded), "gitlink"
        else:
            raise EvidenceError(f"unsupported Git tree entry type {kind}: {path}")
        records.append(
            {
                "path": path,
                "kind": record_kind,
                "gitMode": mode,
                "gitObjectID": object_id,
                "bytes": size,
                "sha256": digest,
                "executable": mode == "100755",
            }
        )
    return sorted(records, key=lambda item: item["path"])


def source_manifest(
    paths: Paths,
    source_sha: str,
    phase: str,
    timestamp: str,
) -> dict[str, Any]:
    records = batched_blob_records(paths.root, source_sha)
    record_digest = hashlib.sha256()
    for record in records:
        record_digest.update(canonical_json_bytes(record))
    state = source_state(paths.root, paths.evidence, source_sha)
    failures: list[str] = []
    if not state["headMatchesSource"]:
        failures.append("HEAD does not equal the requested frozen application source SHA")
    if not state["worktreeCleanOutsideEvidenceRoot"]:
        failures.append("The worktree has changes outside the v4.3 evidence root")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "application-source-manifest",
        "phase": phase,
        "generatedAt": timestamp,
        "sourceSHA": source_sha,
        "gitTreeSHA": str(run_git(paths.root, "rev-parse", f"{source_sha}^{{tree}}")).strip(),
        "fileCount": len(records),
        "aggregateAlgorithm": "sha256-of-sorted-canonical-file-records-v1",
        "aggregateSHA256": record_digest.hexdigest(),
        "files": records,
        "sourceState": state,
        "failures": failures,
        "result": "PASS" if not failures else "FAIL",
        "acceptanceEvidence": False,
        "publicationState": "PREPUBLICATION",
    }


def write_source_manifest(args: argparse.Namespace) -> int:
    root = resolve_root(args.root)
    paths = build_paths(root, args.evidence_root)
    source_sha = resolve_commit(root, args.source_sha, "source SHA")
    timestamp = event_timestamp(args.timestamp)
    document = source_manifest(paths, source_sha, args.phase, timestamp)
    output = paths.evidence / f"SourceManifest.{args.phase}.json"
    write_json(output, document)
    print(json.dumps({"path": str(output), "result": document["result"]}, sort_keys=True))
    return 0 if document["result"] == "PASS" else 1


def normalize_command(arguments: Sequence[str]) -> list[str]:
    command = list(arguments)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise EvidenceError("record-command requires a command after --")
    if any("\0" in value for value in command):
        raise EvidenceError("command arguments cannot contain NUL")
    return command


def record_command(args: argparse.Namespace) -> int:
    if not IDENTIFIER.fullmatch(args.command_id):
        raise EvidenceError("command ID contains unsupported characters")
    root = resolve_root(args.root)
    paths = build_paths(root, args.evidence_root)
    source_sha = resolve_commit(root, args.source_sha, "source SHA")
    command = normalize_command(args.command)
    cwd = (args.cwd or root).resolve()
    if not cwd.is_dir():
        raise EvidenceError(f"command cwd does not exist: {cwd}")
    started = event_timestamp(args.timestamp)
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    ended = event_timestamp(args.end_timestamp)
    log_path = paths.evidence / COMMAND_LOGS_RELATIVE / f"{args.command_id}.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_bytes(completed.stdout)
    state = source_state(root, paths.evidence, source_sha)
    outputs: list[dict[str, Any]] = []
    failures: list[str] = []
    for value in args.output:
        try:
            output_path = resolve_evidence_path(value, paths, "declared command output")
        except EvidenceError as error:
            failures.append(str(error))
            continue
        outputs.append(
            repository_or_external_binding(output_path, root)
        )
    if completed.returncode != args.expect_exit_code:
        failures.append(
            f"exit code {completed.returncode} did not equal expected {args.expect_exit_code}"
        )
    if args.acceptance and not state["acceptanceEligible"]:
        failures.append("acceptance command was not run from the frozen clean source state")
    result = "PASS" if not failures else "FAIL"
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "command-execution",
        "commandID": args.command_id,
        "category": args.category,
        "sourceSHA": source_sha,
        "sourceState": state,
        "cwd": relative_repo_path(cwd, root, "command cwd")
        if cwd.is_relative_to(root)
        else str(cwd),
        "argv": command,
        "command": shlex.join(command),
        "destination": args.destination,
        "startTimestamp": started,
        "endTimestamp": ended,
        "exitCode": completed.returncode,
        "expectedExitCode": args.expect_exit_code,
        "log": binding(log_path, paths.evidence),
        "outputs": sorted(outputs, key=lambda item: item["path"]),
        "result": result,
        "failures": failures,
        "acceptanceEvidence": bool(args.acceptance and result == "PASS"),
    }
    record_path = paths.evidence / COMMAND_RECORDS_RELATIVE / f"{args.command_id}.json"
    if record_path.exists() and not args.replace:
        raise EvidenceError(f"command record already exists; use --replace: {record_path}")
    write_json(record_path, document)
    print(json.dumps({"path": str(record_path), "result": result}, sort_keys=True))
    return 0 if result == "PASS" else 1


def record_failure(args: argparse.Namespace) -> int:
    if not IDENTIFIER.fullmatch(args.failure_id):
        raise EvidenceError("failure ID contains unsupported characters")
    root = resolve_root(args.root)
    paths = build_paths(root, args.evidence_root)
    source_sha = resolve_commit(root, args.source_sha, "source SHA")
    resolved_at = event_timestamp(args.resolved_at) if args.status == "RESOLVED" else None
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "qualification-failure",
        "failureID": args.failure_id,
        "sourceSHA": source_sha,
        "gateIDs": sorted(set(args.gate_id)),
        "blocking": args.blocking,
        "status": args.status,
        "summary": args.summary,
        "detail": args.detail,
        "openedAt": event_timestamp(args.opened_at),
        "resolvedAt": resolved_at,
        "evidencePaths": sorted(set(args.evidence)),
    }
    output = paths.evidence / FAILURE_RECORDS_RELATIVE / f"{args.failure_id}.json"
    if output.exists() and not args.replace:
        raise EvidenceError(f"failure record already exists; use --replace: {output}")
    write_json(output, document)
    print(json.dumps({"path": str(output), "status": args.status}, sort_keys=True))
    return 0


def record_gate(args: argparse.Namespace) -> int:
    root = resolve_root(args.root)
    paths = build_paths(root, args.evidence_root)
    source_sha = resolve_commit(root, args.source_sha, "source SHA")
    _, _, gate_catalog = load_authority(paths)
    known = {gate["id"]: gate for gate in gate_catalog["gates"]}
    if args.gate_id not in known:
        raise EvidenceError(f"unknown v4.3 gate ID: {args.gate_id}")
    if args.result == "PASS" and not args.evidence:
        raise EvidenceError("a passing gate record requires at least one evidence path")
    evidence_bindings: list[dict[str, Any]] = []
    for value in args.evidence:
        path = resolve_evidence_path(value, paths, f"gate {args.gate_id} evidence")
        evidence_bindings.append(
            repository_or_external_binding(path, root)
        )
    state = source_state(root, paths.evidence, source_sha)
    failures = list(args.failure)
    result = args.result
    if result == "PASS" and not state["acceptanceEligible"]:
        result = "FAIL"
        failures.append("The gate was not assessed from the frozen clean source state")
    if args.gate_id in PUBLICATION_DEPENDENT_GATES and result == "PASS":
        result = "FAIL"
        failures.append(
            "This gate depends on the publication/evidence head and cannot be passed by "
            "an in-tree pre-publication recorder"
        )
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "gate-assessment",
        "gateID": args.gate_id,
        "gateTitle": known[args.gate_id]["title"],
        "sourceSHA": source_sha,
        "sourceState": state,
        "assessedAt": event_timestamp(args.timestamp),
        "commandIDs": sorted(set(args.command_id)),
        "evidence": sorted(evidence_bindings, key=lambda item: item["path"]),
        "result": result,
        "failures": failures,
        "acceptanceEvidence": result == "PASS",
    }
    output = paths.evidence / GATE_RECORDS_RELATIVE / f"{args.gate_id}.json"
    if output.exists() and not args.replace:
        raise EvidenceError(f"gate record already exists; use --replace: {output}")
    write_json(output, document)
    print(json.dumps({"path": str(output), "result": result}, sort_keys=True))
    return 0 if result == "PASS" else 1


def command_index(paths: Paths, source_sha: str, timestamp: str, complete: bool) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    failures: list[str] = []
    directory = paths.evidence / COMMAND_RECORDS_RELATIVE
    for path in sorted(directory.glob("*.json")) if directory.is_dir() else []:
        try:
            record = read_json(path, "command record")
            if record.get("sourceSHA") != source_sha:
                raise EvidenceError(f"source SHA mismatch in {path.name}")
            log_record = record.get("log")
            if not isinstance(log_record, dict):
                raise EvidenceError(f"missing log binding in {path.name}")
            log_path = paths.evidence / str(log_record.get("path", ""))
            if not log_path.is_file() or sha256_file(log_path) != log_record.get("sha256"):
                raise EvidenceError(f"log binding mismatch in {path.name}")
            records.append(
                {
                    "commandID": record.get("commandID"),
                    "category": record.get("category"),
                    "record": binding(path, paths.evidence),
                    "result": record.get("result"),
                    "acceptanceEvidence": record.get("acceptanceEvidence") is True,
                }
            )
        except EvidenceError as error:
            failures.append(str(error))
    identifiers = [record["commandID"] for record in records]
    if any(not isinstance(value, str) or not value for value in identifiers):
        failures.append("One or more command records have no command ID")
    if len(identifiers) != len(set(identifiers)):
        failures.append("Command IDs are not unique")
    if not complete:
        failures.append("Command coverage has not been declared complete")
    if not records:
        failures.append("No command records exist")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "command-index",
        "generatedAt": timestamp,
        "sourceSHA": source_sha,
        "commandsComplete": complete,
        "commandCount": len(records),
        "passingCommandCount": sum(item["result"] == "PASS" for item in records),
        "acceptanceCommandCount": sum(item["acceptanceEvidence"] for item in records),
        "commands": sorted(records, key=lambda item: str(item["commandID"])),
        "result": "PASS" if not failures else "FAIL",
        "failures": failures,
        "acceptanceEvidence": False,
        "publicationState": "PREPUBLICATION",
    }


def gate_results(
    paths: Paths,
    source_sha: str,
    timestamp: str,
    gate_catalog: dict[str, Any],
) -> dict[str, Any]:
    records_by_id: dict[str, dict[str, Any]] = {}
    directory = paths.evidence / GATE_RECORDS_RELATIVE
    for path in sorted(directory.glob("*.json")) if directory.is_dir() else []:
        record = read_json(path, "gate record")
        gate_id = record.get("gateID")
        if isinstance(gate_id, str) and gate_id not in records_by_id:
            records_by_id[gate_id] = record

    results: list[dict[str, Any]] = []
    for gate in sorted(gate_catalog["gates"], key=lambda item: item["order"]):
        gate_id = gate["id"]
        record = records_by_id.get(gate_id)
        failures: list[str] = []
        evidence_paths: list[str] = []
        command_ids: list[str] = []
        result = "FAIL"
        if record is None:
            failures.append("No explicit gate assessment record exists")
        else:
            if record.get("sourceSHA") != source_sha:
                failures.append("Gate assessment is bound to a different source SHA")
            result = "PASS" if record.get("result") == "PASS" and not failures else "FAIL"
            failures.extend(str(item) for item in record.get("failures", []))
            command_ids = sorted(set(str(item) for item in record.get("commandIDs", [])))
            for item in record.get("evidence", []):
                if isinstance(item, dict) and isinstance(item.get("path"), str):
                    evidence_paths.append(item["path"])
                    path = Path(item["path"])
                    if not path.is_absolute():
                        path = paths.root / path
                    if not path.is_file() or sha256_file(path) != item.get("sha256"):
                        result = "FAIL"
                        failures.append(
                            f"Gate evidence binding is stale or missing: {item['path']}"
                        )
            if result == "PASS" and not evidence_paths:
                result = "FAIL"
                failures.append("Passing gate assessment has no evidence paths")
        if gate_id in PUBLICATION_DEPENDENT_GATES:
            result = "FAIL"
            failures.append(
                "Publication-dependent gate remains unresolved in pre-publication mode"
            )
        results.append(
            {
                "gateID": gate_id,
                "title": gate["title"],
                "sourceSHA": source_sha,
                "commandIDs": command_ids,
                "evidencePaths": sorted(set(evidence_paths)),
                "result": result,
                "failures": sorted(set(failures)),
            }
        )
    passing = sum(item["result"] == "PASS" for item in results)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "blocking-gate-results",
        "generatedAt": timestamp,
        "templateOnly": False,
        "acceptanceEvidence": False,
        "sourceSHA": source_sha,
        "gateCount": len(results),
        "passingGateCount": passing,
        "failingGateCount": len(results) - passing,
        "results": results,
        "result": "FAIL",
        "publicationState": "PREPUBLICATION",
    }


def failure_ledger(
    paths: Paths,
    source_sha: str,
    timestamp: str,
    gates: dict[str, Any],
    state: dict[str, Any],
) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    directory = paths.evidence / FAILURE_RECORDS_RELATIVE
    for path in sorted(directory.glob("*.json")) if directory.is_dir() else []:
        record = read_json(path, "failure record")
        if record.get("sourceSHA") != source_sha:
            records.append(
                {
                    "failureID": f"STALE-{path.stem}",
                    "blocking": True,
                    "status": "OPEN",
                    "summary": "Failure record is bound to a different source SHA",
                    "evidencePaths": [relative_repo_path(path, paths.root, "failure record")],
                }
            )
        else:
            records.append(record)

    for gate in gates["results"]:
        if gate["result"] != "PASS":
            records.append(
                {
                    "failureID": f"GATE-{gate['gateID']}",
                    "sourceSHA": source_sha,
                    "gateIDs": [gate["gateID"]],
                    "blocking": True,
                    "status": "OPEN",
                    "summary": f"{gate['gateID']} has not passed",
                    "detail": "; ".join(gate["failures"]),
                    "evidencePaths": gate["evidencePaths"],
                }
            )
    if not state["acceptanceEligible"]:
        records.append(
            {
                "failureID": "SOURCE-NOT-FROZEN",
                "sourceSHA": source_sha,
                "gateIDs": ["SRC-001"],
                "blocking": True,
                "status": "OPEN",
                "summary": "Application source is not a clean frozen worktree state",
                "detail": json.dumps(state, sort_keys=True),
                "evidencePaths": [],
            }
        )
    records.append(
        {
            "failureID": "EVIDENCE-HEAD-SELF-REFERENCE",
            "sourceSHA": source_sha,
            "gateIDs": ["SRC-001", "EVID-001", "PUB-001", "AUDIT-001"],
            "blocking": True,
            "status": "OPEN",
            "summary": "The in-tree evidence head cannot cryptographically name itself",
            "detail": (
                "The package requires the PR head commit SHA inside files contained by that "
                "same commit. Writing the SHA changes the Git tree and therefore the commit SHA."
            ),
            "evidencePaths": [],
        }
    )
    unique: dict[str, dict[str, Any]] = {}
    for record in records:
        identifier = str(record.get("failureID", ""))
        if not identifier:
            raise EvidenceError("failure record has no failureID")
        if identifier in unique:
            # Explicit records take precedence over derived gate records only when identical.
            if canonical_json_bytes(unique[identifier]) != canonical_json_bytes(record):
                raise EvidenceError(f"duplicate failure ID with different content: {identifier}")
            continue
        unique[identifier] = record
    ordered = [unique[key] for key in sorted(unique)]
    unresolved = [
        item
        for item in ordered
        if item.get("blocking") is True and item.get("status") != "RESOLVED"
    ]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "failure-ledger",
        "generatedAt": timestamp,
        "sourceSHA": source_sha,
        "failureCount": len(ordered),
        "unresolvedFailureCount": sum(item.get("status") != "RESOLVED" for item in ordered),
        "unresolvedBlockingFailureCount": len(unresolved),
        "failures": ordered,
        "result": "FAIL" if unresolved else "PASS",
        "acceptanceEvidence": False,
        "publicationState": "PREPUBLICATION",
    }


def read_plist(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException):
        return {}
    return value if isinstance(value, dict) else {}


def package_version(distribution: str) -> str | None:
    try:
        return metadata.version(distribution)
    except metadata.PackageNotFoundError:
        return None


def toolchain(paths: Paths, source_sha: str, timestamp: str) -> dict[str, Any]:
    selected_developer = ""
    try:
        selected_developer = str(
            run_git(paths.root, "config", "--get", "xcode.developerDir")
        ).strip()
    except EvidenceError:
        selected_developer = ""
    if not selected_developer:
        xcode_select = subprocess.run(
            ["/usr/bin/xcode-select", "-p"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        selected_developer = xcode_select.stdout.strip() if xcode_select.returncode == 0 else ""
    xcode_root = Path(selected_developer).parents[1] if selected_developer else Path()
    version_plist = read_plist(xcode_root / "Contents/version.plist") if selected_developer else {}
    info_plist = read_plist(xcode_root / "Contents/Info.plist") if selected_developer else {}
    packages = {
        name: package_version(distribution)
        for name, distribution in [
            ("Pillow", "Pillow"),
            ("NumPy", "numpy"),
            ("OpenCV", "opencv-python"),
            ("OpenCVHeadless", "opencv-python-headless"),
            ("scikit-image", "scikit-image"),
            ("jsonschema", "jsonschema"),
        ]
    }
    required_present = (
        packages["Pillow"] is not None
        and packages["NumPy"] is not None
        and (packages["OpenCV"] is not None or packages["OpenCVHeadless"] is not None)
        and packages["scikit-image"] is not None
    )
    failures: list[str] = []
    if not selected_developer:
        failures.append("No selected Xcode developer directory was found")
    if not required_present:
        failures.append("One or more package-required Python distributions are missing")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "toolchain-inventory",
        "generatedAt": timestamp,
        "sourceSHA": source_sha,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "pythonImplementation": platform.python_implementation(),
            "pythonVersion": platform.python_version(),
            "pythonExecutable": sys.executable,
        },
        "pythonPackages": packages,
        "xcode": {
            "developerDirectory": selected_developer or None,
            "version": version_plist.get("CFBundleShortVersionString")
            or info_plist.get("CFBundleShortVersionString"),
            "build": version_plist.get("ProductBuildVersion")
            or info_plist.get("DTXcodeBuild"),
            "collectedWithoutLaunchingXcode": True,
        },
        "result": "PASS" if not failures else "FAIL",
        "failures": failures,
        "acceptanceEvidence": False,
        "publicationState": "PREPUBLICATION",
    }


def aggregate_status(path: Path, key: str, source_sha: str) -> dict[str, Any]:
    if not path.is_file():
        return {
            "path": path.name,
            "present": False,
            "count": 0,
            "passingCount": 0,
            "acceptanceEvidence": False,
            "sourceBound": False,
        }
    value = read_json(path, path.name)
    results = value.get(key)
    if not isinstance(results, list):
        results = []
    return {
        "path": path.name,
        "present": True,
        "count": len(results),
        "passingCount": sum(
            isinstance(item, dict) and item.get("result") == "PASS" for item in results
        ),
        "acceptanceEvidence": value.get("acceptanceEvidence") is True,
        "sourceBound": value.get("sourceSHA") == source_sha,
        "sha256": sha256_file(path),
    }


def write_missing_aggregate_templates(paths: Paths, source_sha: str) -> None:
    for name, (key, _) in AGGREGATE_TEMPLATES.items():
        path = paths.evidence / name
        if not path.exists():
            write_json(
                path,
                {
                    "schemaVersion": SCHEMA_VERSION,
                    "templateOnly": True,
                    "acceptanceEvidence": False,
                    "sourceSHA": source_sha,
                    key: [],
                    "result": "FAIL",
                    "failures": ["No qualification result records have been assembled"],
                },
            )


def source_boundary(
    paths: Paths,
    source_sha: str,
    current_head: str,
    timestamp: str,
) -> dict[str, Any]:
    allowed = relative_repo_path(paths.evidence, paths.root, "evidence root").rstrip("/") + "/"
    changed: list[str] = []
    if source_sha != current_head:
        changed = str(
            run_git(paths.root, "diff", "--name-only", f"{source_sha}..{current_head}")
        ).splitlines()
    outside = sorted(path for path in changed if path and not path.startswith(allowed))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "application-source-to-evidence-head-boundary",
        "generatedAt": timestamp,
        "applicationSourceSHA": source_sha,
        "evidenceHeadSHA": current_head,
        "evidenceHeadStatus": "PREPUBLICATION_CURRENT_HEAD_NOT_FINAL",
        "allowedEvidenceRoot": allowed,
        "changedPathCount": len(changed),
        "changedPaths": sorted(path for path in changed if path),
        "pathsOutsideAllowedEvidenceRoot": outside,
        "onlyEvidencePathsAfterApplicationSource": False,
        "worktreeCleanAtApplicationSource": False,
        "selfBindingVerified": False,
        "result": "FAIL",
        "failures": [
            "No final immutable evidence-head commit exists in pre-publication mode",
            (
                "The requested PR-head SHA cannot be written into files contained by that same "
                "commit without changing the SHA"
            ),
        ],
        "acceptanceEvidence": False,
        "publicationState": "PREPUBLICATION",
    }


def final_self_audit_text(
    source_sha: str,
    current_head: str,
    timestamp: str,
    gate_document: dict[str, Any],
    ledger: dict[str, Any],
) -> str:
    lines = [
        "# Theme Fidelity v4.3 Pre-Publication Self-Audit",
        "",
        f"- Generated: `{timestamp}`",
        f"- Requested application source SHA: `{source_sha}`",
        f"- Current Git head: `{current_head}`",
        "- Acceptance evidence: `false`",
        "- Overall result: `FAIL`",
        f"- Passing blocking gates: `{gate_document['passingGateCount']}/40`",
        f"- Unresolved blocking failures: `{ledger['unresolvedBlockingFailureCount']}`",
        "- Complete package reread at final evidence head: `PENDING`",
        "",
        "## Gate status",
        "",
        "| Gate | Result | Reason |",
        "| --- | --- | --- |",
    ]
    for gate in gate_document["results"]:
        reason = "; ".join(gate["failures"]) or "Explicit evidence record passed"
        reason = reason.replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {gate['gateID']} | {gate['result']} | {reason} |")
    lines.extend(
        [
            "",
            "## Publication/evidence-head blocker",
            "",
            "The package asks tracked evidence files to contain the SHA of the commit that "
            "contains those same bytes. Git computes the commit SHA from the tree, so inserting "
            "the SHA changes the tree and changes the SHA. This pre-publication report therefore "
            "does not claim `SRC-001`, `EVID-001`, `PUB-001`, or `AUDIT-001` passed.",
            "",
            "No merge, tag, archive, notarization, upload, release, distribution, or "
            "physical-device action was performed by this evidence assembly.",
            "",
        ]
    )
    return "\n".join(lines)


def assemble_prepublication(args: argparse.Namespace) -> int:
    root = resolve_root(args.root)
    paths = build_paths(root, args.evidence_root)
    paths.evidence.mkdir(parents=True, exist_ok=True)
    source_sha = resolve_commit(root, args.source_sha, "source SHA")
    current_head = head_sha(root)
    timestamp = event_timestamp(args.timestamp)
    authority, catalog, gate_catalog = load_authority(paths)
    if len(authority.get("entries", [])) != 400:
        raise EvidenceError("comparison authority does not contain 400 entries")
    if len(catalog.get("candidates", [])) != 50:
        raise EvidenceError("canonical catalog does not contain 50 candidates")
    if len(gate_catalog.get("gates", [])) != 40:
        raise EvidenceError("gate catalog does not contain 40 gates")

    write_missing_aggregate_templates(paths, source_sha)
    before = source_manifest(paths, source_sha, "before", timestamp)
    after = source_manifest(paths, source_sha, "after", timestamp)
    write_json(paths.evidence / "SourceManifest.before.json", before)
    write_json(paths.evidence / "SourceManifest.after.json", after)

    tools = toolchain(paths, source_sha, timestamp)
    commands = command_index(paths, source_sha, timestamp, args.commands_complete)
    gates = gate_results(paths, source_sha, timestamp, gate_catalog)
    state = source_state(root, paths.evidence, source_sha)
    ledger = failure_ledger(paths, source_sha, timestamp, gates, state)
    boundary = source_boundary(paths, source_sha, current_head, timestamp)

    write_json(paths.evidence / "Toolchain.json", tools)
    write_json(paths.evidence / "CommandIndex.json", commands)
    write_json(paths.evidence / "gate-results.json", gates)
    write_json(paths.evidence / "FailureLedger.json", ledger)
    write_json(paths.evidence / "SourceBoundary.json", boundary)
    audit_path = paths.evidence / "FinalSelfAudit.md"
    audit_path.write_text(
        final_self_audit_text(source_sha, current_head, timestamp, gates, ledger),
        encoding="utf-8",
    )

    aggregates = {
        name: aggregate_status(paths.evidence / name, key, source_sha)
        for name, (key, _) in AGGREGATE_TEMPLATES.items()
    }
    supporting = {
        "sourceManifestBefore": binding(
            paths.evidence / "SourceManifest.before.json", paths.evidence
        ),
        "sourceManifestAfter": binding(
            paths.evidence / "SourceManifest.after.json", paths.evidence
        ),
        "sourceBoundary": binding(paths.evidence / "SourceBoundary.json", paths.evidence),
        "toolchain": binding(paths.evidence / "Toolchain.json", paths.evidence),
        "commandIndex": binding(paths.evidence / "CommandIndex.json", paths.evidence),
        "failureLedger": binding(paths.evidence / "FailureLedger.json", paths.evidence),
        "finalSelfAudit": binding(audit_path, paths.evidence),
    }
    expected_counts = {
        "canonicalCandidates": 50,
        "responsiveEntries": 400,
        "runtimeProbeInstances": 576,
        "mappingResults": 1104,
        "gates": 40,
    }
    observed_counts = {
        "canonicalCandidates": aggregates["canonical-results.json"]["count"],
        "responsiveEntries": aggregates["responsive-results.json"]["count"],
        "runtimeProbeInstances": aggregates["runtime-probe-results.json"]["count"],
        "mappingResults": aggregates["mapping-results.json"]["count"],
        "gates": len(gates["results"]),
    }
    failures = [
        "Pre-publication scaffolding is not acceptance evidence",
        "No self-bound final evidence-head commit exists",
    ]
    for key, expected in expected_counts.items():
        if observed_counts[key] != expected:
            failures.append(
                f"Observed {key} count {observed_counts[key]} does not equal required {expected}"
            )
    if gates["passingGateCount"] != 40:
        failures.append(f"Only {gates['passingGateCount']} of 40 gates pass")
    final = {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceType": "final-qualification",
        "generatedAt": timestamp,
        "templateOnly": False,
        "acceptanceEvidence": False,
        "sourceSHA": source_sha,
        "evidenceHeadSHA": current_head,
        "evidenceHeadVerified": False,
        "authoritySHA256": sha256_file(paths.comparison_authority),
        "canonicalCatalogSHA256": sha256_file(paths.canonical_catalog),
        "gateCatalogSHA256": sha256_file(paths.gate_catalog),
        "counts": observed_counts,
        "requiredCounts": expected_counts,
        "observedCounts": observed_counts,
        "supportingEvidence": supporting,
        "aggregateStatus": aggregates,
        "publicationState": "PREPUBLICATION",
        "result": "FAIL",
        "failures": failures,
    }
    write_json(paths.evidence / "final-qualification.json", final)
    report = {
        "result": "FAIL",
        "acceptanceEvidence": False,
        "sourceSHA": source_sha,
        "currentHeadSHA": current_head,
        "passingGates": gates["passingGateCount"],
        "unresolvedBlockingFailures": ledger["unresolvedBlockingFailureCount"],
        "evidenceRoot": str(paths.evidence),
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1


def verify_head_binding(args: argparse.Namespace) -> int:
    root = resolve_root(args.root)
    paths = build_paths(root, args.evidence_root)
    source_sha = resolve_commit(root, args.source_sha, "source SHA")
    evidence_head = resolve_commit(root, args.evidence_head_sha, "evidence head SHA")
    allowed = relative_repo_path(paths.evidence, root, "evidence root").rstrip("/") + "/"
    changed = str(
        run_git(root, "diff", "--name-only", f"{source_sha}..{evidence_head}")
    ).splitlines()
    outside = sorted(path for path in changed if path and not path.startswith(allowed))
    final_relative = (EVIDENCE_RELATIVE / "final-qualification.json").as_posix()
    boundary_relative = (EVIDENCE_RELATIVE / "SourceBoundary.json").as_posix()
    errors: list[str] = []
    if outside:
        errors.append("Paths outside the allowed evidence root changed after source freeze")
    for relative, field in [
        (final_relative, "evidenceHeadSHA"),
        (boundary_relative, "evidenceHeadSHA"),
    ]:
        completed = subprocess.run(
            ["git", "show", f"{evidence_head}:{relative}"],
            cwd=root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if completed.returncode != 0:
            errors.append(f"Evidence head does not contain {relative}")
            continue
        try:
            document = json.loads(completed.stdout)
        except json.JSONDecodeError:
            errors.append(f"Evidence head contains invalid JSON at {relative}")
            continue
        if document.get(field) != evidence_head:
            errors.append(f"{relative} does not self-bind to the evidence head SHA")
    result = "PASS" if not errors else "FAIL"
    print(
        json.dumps(
            {
                "result": result,
                "applicationSourceSHA": source_sha,
                "evidenceHeadSHA": evidence_head,
                "allowedEvidenceRoot": allowed,
                "changedPaths": changed,
                "pathsOutsideAllowedEvidenceRoot": outside,
                "failures": errors,
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0 if not errors else 1


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    root.add_argument("--root", type=Path)
    root.add_argument("--evidence-root", type=Path)
    commands = root.add_subparsers(dest="subcommand", required=True)

    manifest = commands.add_parser("source-manifest")
    manifest.add_argument("--source-sha", required=True)
    manifest.add_argument("--phase", choices=("before", "after"), required=True)
    manifest.add_argument("--timestamp")
    manifest.set_defaults(function=write_source_manifest)

    command = commands.add_parser("record-command")
    command.add_argument("--command-id", required=True)
    command.add_argument("--category", required=True)
    command.add_argument("--source-sha", required=True)
    command.add_argument("--cwd", type=Path)
    command.add_argument("--destination", default="local-cli")
    command.add_argument("--expect-exit-code", type=int, default=0)
    command.add_argument("--output", action="append", default=[])
    command.add_argument("--acceptance", action="store_true")
    command.add_argument("--replace", action="store_true")
    command.add_argument("--timestamp")
    command.add_argument("--end-timestamp")
    command.add_argument("command", nargs=argparse.REMAINDER)
    command.set_defaults(function=record_command)

    failure = commands.add_parser("record-failure")
    failure.add_argument("--failure-id", required=True)
    failure.add_argument("--source-sha", required=True)
    failure.add_argument("--gate-id", action="append", default=[])
    failure.add_argument("--blocking", action=argparse.BooleanOptionalAction, default=True)
    failure.add_argument("--status", choices=("OPEN", "RESOLVED"), default="OPEN")
    failure.add_argument("--summary", required=True)
    failure.add_argument("--detail", default="")
    failure.add_argument("--evidence", action="append", default=[])
    failure.add_argument("--opened-at")
    failure.add_argument("--resolved-at")
    failure.add_argument("--replace", action="store_true")
    failure.set_defaults(function=record_failure)

    gate = commands.add_parser("record-gate")
    gate.add_argument("--gate-id", required=True)
    gate.add_argument("--source-sha", required=True)
    gate.add_argument("--result", choices=("PASS", "FAIL"), required=True)
    gate.add_argument("--evidence", action="append", default=[])
    gate.add_argument("--command-id", action="append", default=[])
    gate.add_argument("--failure", action="append", default=[])
    gate.add_argument("--timestamp")
    gate.add_argument("--replace", action="store_true")
    gate.set_defaults(function=record_gate)

    assemble = commands.add_parser("assemble-prepublication")
    assemble.add_argument("--source-sha", required=True)
    assemble.add_argument("--commands-complete", action="store_true")
    assemble.add_argument("--timestamp")
    assemble.set_defaults(function=assemble_prepublication)

    verify = commands.add_parser("verify-head-binding")
    verify.add_argument("--source-sha", required=True)
    verify.add_argument("--evidence-head-sha", required=True)
    verify.set_defaults(function=verify_head_binding)
    return root


def main() -> int:
    arguments = parser().parse_args()
    try:
        return arguments.function(arguments)
    except EvidenceError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
