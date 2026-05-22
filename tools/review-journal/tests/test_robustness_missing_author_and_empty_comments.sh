#!/usr/bin/env bash
# Pins: the tool doesn't crash on degenerate GraphQL data — missing author
# (deleted/ghost user), empty comment body, single-comment thread, etc.
source "$(dirname "$0")/lib.sh"
start_test "test_robustness_missing_author_and_empty_comments"

write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_no_author",
    "isResolved": true, "isOutdated": false,
    "path": "src/a.rs", "line": 1,
    "comments": {"nodes": [
      {"id": "c1", "author": null, "body": "Major: race", "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"}
    ]}
  },
  {
    "id": "PRRT_empty_body",
    "isResolved": true, "isOutdated": false,
    "path": "src/b.rs", "line": 2,
    "comments": {"nodes": [
      {"id": "c2", "author": {"login": "coderabbitai"}, "body": "", "createdAt": "2026-05-21T20:01:00Z", "url": "https://example/2"}
    ]}
  },
  {
    "id": "PRRT_no_comments",
    "isResolved": false, "isOutdated": false,
    "path": "src/c.rs", "line": 3,
    "comments": {"nodes": []}
  }
]'

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

set +e
"$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" --enforce off >/dev/null 2>&1
ec=$?
set -e
assert_exit_code 0 "$ec" "sync survives degenerate threads"

# Missing author → reviewer field is "unknown".
no_author_rev=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_no_author')
print(t.get('reviewer'))
")
assert_eq "unknown" "$no_author_rev" "missing author → unknown"

# All three threads recorded (degenerate ones are still data).
count=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
print(len(d['threads']))
")
assert_eq "3" "$count" "all three degenerate threads recorded"

finish_test
