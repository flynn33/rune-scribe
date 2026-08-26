#!/usr/bin/env python3
"""Shared validation for current capture-runner source manifests."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


CURRENT_MANIFEST_KEYS = {
    "schemaVersion",
    "sourceSHA",
    "fileCount",
    "aggregateSHA256",
    "gitStatusSHA256",
    "isClean",
    "files",
}


def is_current_manifest(document: Mapping[str, Any]) -> bool:
    return set(document) == CURRENT_MANIFEST_KEYS and document.get("schemaVersion") == "1.0"


def validate_current_manifest(
    document: Mapping[str, Any],
    *,
    root: Path,
    exclusions: Sequence[Path],
    head: str | None,
    recompute: Callable[[Path, Sequence[Path]], Mapping[str, Any]],
) -> list[str]:
    errors: list[str] = []
    resolved_root = root.resolve()
    resolved_exclusions = [path.resolve() for path in exclusions]
    if not resolved_exclusions:
        return ["current source manifest requires at least one explicit --source-exclusion"]
    if any(
        exclusion == resolved_root or resolved_root not in exclusion.parents
        for exclusion in resolved_exclusions
    ):
        return ["current source-manifest exclusions must be narrow repository descendants"]
    if document.get("isClean") is not True:
        errors.append("current source manifest does not report a clean source-only tree")
    if head is not None and document.get("sourceSHA") != head:
        errors.append("current source manifest is not bound to repository HEAD")
    try:
        actual = recompute(resolved_root, resolved_exclusions)
    except Exception as exception:
        errors.append(f"unable to recompute current source manifest: {exception}")
    else:
        if document != actual:
            errors.append(
                "current source manifest does not match this tree and its exact exclusions"
            )
    return errors
