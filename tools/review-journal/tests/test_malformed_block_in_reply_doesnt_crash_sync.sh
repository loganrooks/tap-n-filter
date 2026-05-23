#!/usr/bin/env bash
# Pins fix G (Codex #7, PRRT_kwDOSjmLjM6EPXgc):
# A malformed `review-verdict` block in any reply must NOT crash the full sync.
# The malformed thread is logged + skipped; other threads still get journaled.
source "$(dirname "$0")/lib.sh"
start_test "test_malformed_block_in_reply_doesnt_crash_sync"

write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_malformed",
    "isResolved": true, "isOutdated": false,
    "path": "src/a.rs", "line": 1,
    "comments": {"nodes": [
      {"id": "c1", "author": {"login": "coderabbitai"},
       "body": "Minor: oops",
       "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"},
      {"id": "c2", "author": {"login": "loganrooks"},
       "body": "```review-verdict\nverdict: TOTALLY_INVALID_VALUE\nnotes: typo here\n```",
       "createdAt": "2026-05-21T20:01:00Z", "url": "https://example/2"}
    ]}
  },
  {
    "id": "PRRT_good",
    "isResolved": true, "isOutdated": false,
    "path": "src/b.rs", "line": 2,
    "comments": {"nodes": [
      {"id": "c3", "author": {"login": "coderabbitai"},
       "body": "Major: real",
       "createdAt": "2026-05-21T20:02:00Z", "url": "https://example/3"},
      {"id": "c4", "author": {"login": "loganrooks"},
       "body": "```review-verdict\nverdict: ACCEPTED\ncommit: abc1234\nreviewer: coderabbitai\nnotes: applied.\n```",
       "createdAt": "2026-05-21T20:03:00Z", "url": "https://example/4"}
    ]}
  }
]'

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

set +e
stderr=$("$SYNC_PR" 1 --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" \
  --enforce off 2>&1 >/dev/null)
ec=$?
set -e

# Sync must NOT crash on the malformed block.
assert_exit_code 0 "$ec" "sync survives malformed block"
# A warning must be logged.
assert_contains "PRRT_malformed" "$stderr" "stderr names the malformed thread"

# Both records should land in the journal.
count=$(python3 -c "import json; print(len(json.load(open('$journal_dir/pr-1.json'))['threads']))")
assert_eq "2" "$count" "both threads journaled"

# The good thread retained its verdict.
good_verdict=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_good')
print(t.get('verdict') or '')
")
assert_eq "ACCEPTED" "$good_verdict" "good thread's verdict preserved"

finish_test
