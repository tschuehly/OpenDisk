#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/opendisk-scan-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/input/subdir"
printf 'hello\n' > "$TMP_DIR/input/file.txt"
printf 'world\n' > "$TMP_DIR/input/subdir/other.txt"

"$ROOT_DIR/tools/opendisk-scan" "$TMP_DIR/input" "$TMP_DIR/scan.json" >/dev/null

python3 - "$TMP_DIR/scan.json" <<'PY'
import json
import sys

scan = json.load(open(sys.argv[1], encoding="utf-8"))
assert scan["format"] == "opendisk.scan"
assert scan["schemaVersion"] == 1
assert scan["pathMode"] == "relative"
assert scan["scan"]["state"] == "finished"
assert scan["truncated"] is False
assert scan["nodes"][0]["name"] == "."
assert {node["name"] for node in scan["nodes"]} >= {".", "file.txt", "subdir", "other.txt"}
print("headless scan test: passed")
PY

# Fresh copy: a rescan of "input" would replay the scan cache.
cp -R "$TMP_DIR/input" "$TMP_DIR/input2"
OPENDISK_EXCLUDE="$TMP_DIR/input2/subdir" \
  "$ROOT_DIR/tools/opendisk-scan" "$TMP_DIR/input2" "$TMP_DIR/excluded.json" >/dev/null 2>&1

python3 - "$TMP_DIR/excluded.json" <<'PY'
import json
import sys

names = {node["name"] for node in json.load(open(sys.argv[1], encoding="utf-8"))["nodes"]}
assert "subdir" in names and "other.txt" not in names, names
print("exclude test: passed")
PY
