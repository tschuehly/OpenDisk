#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/opendisk-cleanup-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/scan.json" <<'JSON'
{
  "format": "opendisk.scan",
  "pathMode": "relative",
  "schemaVersion": 1,
  "truncated": false,
  "scan": {
    "coverage": "best_effort",
    "finishedAt": "2026-09-22T07:13:15Z",
    "reportedUnreadableDirectories": 1,
    "startedAt": "2026-09-22T07:12:59Z",
    "state": "finished"
  },
  "nodes": [
    {"id":0,"parentId":null,"name":".","isDirectory":true,"allocatedBytes":"20000"},
    {"id":1,"parentId":0,"name":"Users","isDirectory":true,"allocatedBytes":"12000"},
    {"id":2,"parentId":1,"name":"alice","isDirectory":true,"allocatedBytes":"12000"},
    {"id":3,"parentId":2,"name":"Library","isDirectory":true,"allocatedBytes":"9000"},
    {"id":4,"parentId":3,"name":"Caches","isDirectory":true,"allocatedBytes":"6000"},
    {"id":5,"parentId":4,"name":"Homebrew","isDirectory":true,"allocatedBytes":"6000"},
    {"id":6,"parentId":5,"name":"downloads","isDirectory":true,"allocatedBytes":"6000"},
    {"id":7,"parentId":6,"name":"tool.pkg","isDirectory":false,"allocatedBytes":"6000"},
    {"id":8,"parentId":2,"name":".git","isDirectory":true,"allocatedBytes":"3000"},
    {"id":9,"parentId":8,"name":"objects","isDirectory":true,"allocatedBytes":"3000"},
    {"id":10,"parentId":9,"name":"pack","isDirectory":true,"allocatedBytes":"3000"},
    {"id":11,"parentId":10,"name":"pack-1.pack","isDirectory":false,"allocatedBytes":"3000"},
    {"id":12,"parentId":0,"name":"System","isDirectory":true,"allocatedBytes":"1000"},
    {"id":13,"parentId":12,"name":"important.bin","isDirectory":false,"allocatedBytes":"1000"},
    {"id":14,"parentId":0,"name":"unknown.iso","isDirectory":false,"allocatedBytes":"2000000000"},
    {"id":15,"parentId":0,"name":"Library","isDirectory":true,"allocatedBytes":"500"},
    {"id":16,"parentId":15,"name":"Developer","isDirectory":true,"allocatedBytes":"500"},
    {"id":17,"parentId":16,"name":"CoreSimulator","isDirectory":true,"allocatedBytes":"500"},
    {"id":18,"parentId":17,"name":"Caches","isDirectory":true,"allocatedBytes":"500"},
    {"id":19,"parentId":18,"name":"dyld","isDirectory":true,"allocatedBytes":"500"},
    {"id":20,"parentId":19,"name":"shared_cache","isDirectory":false,"allocatedBytes":"500"},
    {"id":99,"parentId":-1,"name":"detached.pkg","isDirectory":false,"allocatedBytes":"999999"}
  ]
}
JSON

"$ROOT_DIR/tools/opendisk-cleanup.sh" "$TMP_DIR/scan.json" "$TMP_DIR/report.json" >/dev/null

python3 - "$TMP_DIR/report.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["format"] == "opendisk.cleanup"
assert report["schemaVersion"] == 1
assert report["source"]["reportedUnreadableDirectories"] == 1
assert report["source"]["rootAllocatedBytes"] == "20000"
assert report["totals"]["candidateBytes"] == "9500"
assert report["totals"]["candidateFiles"] == 3
assert report["totals"]["unclassifiedLargeFiles"] == 1

findings = {finding["id"]: finding for finding in report["findings"]}
assert findings["homebrew-cache"]["allocatedBytes"] == "6000"
assert findings["git-pack"]["allocatedBytes"] == "3000"
assert findings["simulator-runtime"]["scopes"][0]["path"] == "./Library/Developer/CoreSimulator/Caches/dyld"
assert "detached.pkg" not in json.dumps(report)
assert "System/important.bin" not in json.dumps(report["findings"])
assert report["warnings"]
print("cleanup report test: passed")
PY
