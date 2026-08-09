#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 /path/to/RuneScribMacParityHost.app /path/to/report.json" >&2
  exit 2
fi

app_path="$1"
report_path="$2"
executable_name="RuneScribMacParityHost"

if [ ! -d "$app_path" ]; then
  echo "macOS parity host not found: $app_path" >&2
  exit 1
fi

rm -f "$report_path"
/usr/bin/open -n "$app_path" --args --native-share-self-test "$report_path"

for _ in $(seq 1 160); do
  if [ -f "$report_path" ]; then
    break
  fi
  sleep 0.1
done

if [ ! -f "$report_path" ]; then
  /usr/bin/pkill -x "$executable_name" >/dev/null 2>&1 || true
  echo "macOS native-share self-test did not produce a report" >&2
  exit 1
fi

python3 - "$report_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    report = json.load(handle)

assert report.get("version") == 1, report
assert report.get("passed") is True, report
for name in ("file", "link"):
    step = report.get(name, {})
    assert step.get("triggerCount") == 1, report
    assert step.get("nativePickerPresented") is True, report
    assert step.get("dismissedByLocalEscape") is True, report

print("macOS native-share self-test passed for file and link presentation/dismissal")
PY

for _ in $(seq 1 40); do
  if ! /usr/bin/pgrep -x "$executable_name" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.1
done

/usr/bin/pkill -x "$executable_name" >/dev/null 2>&1 || true
echo "macOS parity host did not terminate after reporting" >&2
exit 1
