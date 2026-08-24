#!/usr/bin/env python3
"""Select or create deterministic iPhone and iPad Simulator devices."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Runtime:
    identifier: str
    name: str
    version: tuple[int, ...]


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, check=False)


def version_tuple(name: str) -> tuple[int, ...]:
    match = re.search(r"(\d+(?:\.\d+)*)", name)
    return tuple(int(part) for part in match.group(1).split(".")) if match else (0,)


def load() -> dict:
    result = run("xcrun", "simctl", "list", "-j")
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "simctl list failed")
    return json.loads(result.stdout)


def choose_runtime(data: dict) -> Runtime:
    runtimes = []
    for item in data.get("runtimes", []):
        if not item.get("isAvailable") or "iOS" not in item.get("name", ""):
            continue
        runtimes.append(
            Runtime(item["identifier"], item["name"], version_tuple(item["name"]))
        )
    if not runtimes:
        raise RuntimeError("No available iOS Simulator runtime")
    return max(runtimes, key=lambda item: item.version)


def choose_device_type(data: dict, family: str) -> dict:
    candidates = []
    for item in data.get("devicetypes", []):
        name = item.get("name", "")
        if family not in name:
            continue
        if family == "iPhone" and any(
            token in name for token in ("SE (1st", "4s", "5s")
        ):
            continue
        candidates.append(item)
    if not candidates:
        raise RuntimeError(f"No {family} Simulator device type")
    return candidates[-1]


def find_existing(data: dict, runtime: Runtime, family: str) -> dict | None:
    for device in data.get("devices", {}).get(runtime.identifier, []):
        if device.get("isAvailable") and family in device.get("name", ""):
            return device
    return None


def create(name: str, device_type: dict, runtime: Runtime) -> dict:
    result = run(
        "xcrun",
        "simctl",
        "create",
        name,
        device_type["identifier"],
        runtime.identifier,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"Unable to create {name}")
    return {
        "name": name,
        "udid": result.stdout.strip(),
        "state": "Shutdown",
        "isAvailable": True,
    }


def boot(udid: str) -> None:
    result = run("xcrun", "simctl", "bootstatus", udid, "-b")
    if result.returncode == 0:
        return
    run("xcrun", "simctl", "boot", udid)
    result = run("xcrun", "simctl", "bootstatus", udid, "-b")
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"Unable to boot {udid}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ensure", action="store_true", help="Create devices when needed")
    parser.add_argument("--boot", action="store_true")
    parser.add_argument("--output")
    args = parser.parse_args()
    try:
        data = load()
        runtime = choose_runtime(data)
        selected = {}
        for family, stable_name in (
            ("iPhone", "RuneScribe-Remediation-iPhone"),
            ("iPad", "RuneScribe-Remediation-iPad"),
        ):
            device = find_existing(data, runtime, family)
            if device is None:
                if not args.ensure:
                    raise RuntimeError(
                        f"No existing {family} device; rerun with --ensure"
                    )
                device = create(
                    stable_name,
                    choose_device_type(data, family),
                    runtime,
                )
            if args.boot:
                boot(device["udid"])
            selected[family] = {
                "name": device["name"],
                "udid": device["udid"],
            }
        record = {
            "schemaVersion": "1.0",
            "runtime": {"identifier": runtime.identifier, "name": runtime.name},
            "devices": selected,
            "physicalHardwareRequired": False,
        }
        value = json.dumps(record, indent=2, sort_keys=True) + "\n"
        if args.output:
            from pathlib import Path

            path = Path(args.output)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value, encoding="utf-8")
        print(value, end="")
        return 0
    except (RuntimeError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
