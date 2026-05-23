#!/usr/bin/env bash
# Pins requirement: extract-pr infers ACCEPTED_MODIFIED with the named commit
# when a reply (or the auto-resolution body) says "Fixed in <sha>".
source "$(dirname "$0")/lib.sh"
start_test "test_extract_inferred_accepted_from_commit_ref"

# Build a fixture with a single resolved thread where the reply says
# "Fixed in d108da2 by switching to mainMixerNode."
write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_inferred_fixed",
    "isResolved": true,
    "isOutdated": false,
    "path": "Sources/X.swift",
    "line": 5,
    "comments": {"nodes": [
      {
        "id": "c1",
        "author": {"login": "coderabbitai"},
        "body": "Major: routes through outputNode rather than mainMixerNode.",
        "createdAt": "2026-05-21T20:00:00Z",
        "url": "https://example/pr/1#1"
      },
      {
        "id": "c2",
        "author": {"login": "loganrooks"},
        "body": "Fixed in d108da2 by switching to mainMixerNode.",
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

# Verify inference.
out_path="$journal_dir/pr-1.json"
assert_file_exists "$out_path" "journal file"
verdict=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['threads'][0]['verdict'])" "$out_path")
commit=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['threads'][0]['verdict_commit'])" "$out_path")
source=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['threads'][0]['verdict_source'])" "$out_path")
assert_eq "ACCEPTED_MODIFIED" "$verdict" "inferred verdict"
assert_eq "d108da2" "$commit" "inferred commit"
assert_eq "inferred" "$source" "verdict_source"

finish_test
