#!/usr/bin/env bash
# Pins: GraphQL's `isOutdated` flag propagates to the journal record so
# downstream tooling can distinguish "resolved" from "outdated by force-push".
source "$(dirname "$0")/lib.sh"
start_test "test_outdated_thread_recorded"

write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_fresh",
    "isResolved": true,
    "isOutdated": false,
    "path": "src/a.rs",
    "line": 1,
    "comments": {"nodes": [
      {"id": "c1", "author": {"login": "coderabbitai"},
       "body": "Minor: rename foo",
       "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"}
    ]}
  },
  {
    "id": "PRRT_stale",
    "isResolved": true,
    "isOutdated": true,
    "path": "src/b.rs",
    "line": 2,
    "comments": {"nodes": [
      {"id": "c2", "author": {"login": "coderabbitai"},
       "body": "Major: refactor needed",
       "createdAt": "2026-05-21T19:00:00Z", "url": "https://example/2"}
    ]}
  }
]'

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"
"$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" --enforce off >/dev/null 2>&1

fresh_outdated=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_fresh')
print(t.get('outdated'))
")
stale_outdated=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_stale')
print(t.get('outdated'))
")
assert_eq "False" "$fresh_outdated" "fresh thread outdated=False"
assert_eq "True" "$stale_outdated" "stale thread outdated=True"

finish_test
