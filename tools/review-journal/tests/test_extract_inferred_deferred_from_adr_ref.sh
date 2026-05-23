#!/usr/bin/env bash
# Pins requirement: extract-pr infers DEFERRED when a reply references an ADR
# or U-log entry as the disposition rationale.
source "$(dirname "$0")/lib.sh"
start_test "test_extract_inferred_deferred_from_adr_ref"

write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_deferred_adr",
    "isResolved": true,
    "isOutdated": false,
    "path": "Sources/Y.swift",
    "line": 8,
    "comments": {"nodes": [
      {
        "id": "c1",
        "author": {"login": "chatgpt-codex-connector"},
        "body": "P2: snapshot helper writes-on-missing rather than failing.",
        "createdAt": "2026-05-21T20:00:00Z",
        "url": "https://example/pr/1#1"
      },
      {
        "id": "c2",
        "author": {"login": "loganrooks"},
        "body": "Deferred per ADR-015 — accepted env-bounded deviation. TNF_SNAPSHOT_REGEN=1 is the opt-in regen path.",
        "createdAt": "2026-05-21T21:00:00Z",
        "url": "https://example/pr/1#2"
      }
    ]}
  }
]'

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

"$EXTRACT_PR" 1 \
  --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" \
  --accept-inferred >/dev/null 2>&1
ec=$?
assert_exit_code 0 "$ec" "extract exit code"

out_path="$journal_dir/pr-1.json"
verdict=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['threads'][0]['verdict'])" "$out_path")
notes=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['threads'][0]['verdict_notes'])" "$out_path")
source=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['threads'][0]['verdict_source'])" "$out_path")
assert_eq "DEFERRED" "$verdict" "inferred verdict"
assert_contains "ADR-015" "$notes" "notes capture ADR reference"
assert_eq "inferred" "$source" "verdict_source"

finish_test
