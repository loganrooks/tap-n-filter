#!/usr/bin/env bash
# Pins fix J (Codex #16, PRRT_kwDOSjmLjM6EPot3):
# When a reply contains BOTH a `review-verdict` block AND a later
# `review-verdict-reconsidered` block, the record's current verdict fields
# should reflect the RECONSIDERED values. The original is preserved in
# verdict_history so the chain of custody is auditable.
source "$(dirname "$0")/lib.sh"
start_test "test_reconsidered_supersedes_current_verdict"

# A single reply that contains both blocks.
write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_reconsidered",
    "isResolved": true, "isOutdated": false,
    "path": "src/x.rs", "line": 1,
    "comments": {"nodes": [
      {"id": "c1", "author": {"login": "coderabbitai"},
       "body": "Major: race condition",
       "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"},
      {"id": "c2", "author": {"login": "loganrooks"},
       "body": "```review-verdict\nverdict: REJECTED_BAD_FIT\nreviewer: coderabbitai\nnotes: original take.\n```\n\nLater context made me change my mind.\n\n```review-verdict-reconsidered\nverdict: ACCEPTED_MODIFIED\ncommit: 9f8e7d6\nnotes: after more thought, applied via different patch.\n```",
       "createdAt": "2026-05-21T20:01:00Z", "url": "https://example/2"}
    ]}
  }
]'

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

"$SYNC_PR" 1 --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" --enforce off >/dev/null 2>&1

current_verdict=$(python3 -c "
import json
print(json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('verdict') or '')
")
current_commit=$(python3 -c "
import json
print(json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('verdict_commit') or '')
")
reconsidered=$(python3 -c "
import json
r = json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('reconsidered_verdict')
print(r['verdict'] if r else '')
")
history_len=$(python3 -c "
import json
h = json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('verdict_history') or []
print(len(h))
")

# Current verdict should be the RECONSIDERED one.
assert_eq "ACCEPTED_MODIFIED" "$current_verdict" "current verdict = reconsidered"
assert_eq "9f8e7d6" "$current_commit" "current commit = reconsidered commit"

# reconsidered_verdict still preserved for auditability.
assert_eq "ACCEPTED_MODIFIED" "$reconsidered" "reconsidered_verdict field still set"

# History should record the supersession.
if [ "$history_len" -lt 1 ]; then
  TEST_FAILURES=$((TEST_FAILURES + 1))
  echo "FAIL: verdict_history should record the reconsidered transition"
fi

# Validate cleanly.
set +e
python3 "$REVIEW_JOURNAL_PY" validate "$journal_dir/pr-1.json" >/dev/null 2>&1
ec=$?
set -e
assert_exit_code 0 "$ec" "validate passes on reconsidered record"

finish_test
