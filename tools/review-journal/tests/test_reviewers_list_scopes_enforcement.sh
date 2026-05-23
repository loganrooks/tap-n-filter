#!/usr/bin/env bash
# Pins fix B (Codex #2, PRRT_kwDOSjmLjM6EPXgP and #10, PRRT_kwDOSjmLjM6EPfpg):
# The `reviewers` list in config scopes which reviewers' threads can trigger
# BACKFILL/RESOLVE policy violations. A thread by a reviewer NOT in the list
# (e.g., a human contributor) should never trigger enforcement.
source "$(dirname "$0")/lib.sh"
start_test "test_reviewers_list_scopes_enforcement"

fake_repo="$TEST_WORKDIR/fake-repo"
mkdir -p "$fake_repo"

# Config explicitly lists only one bot — humans excluded.
cat > "$fake_repo/.review-journal.json" <<'EOF'
{
  "enforcement_mode": "warning",
  "reviewers": ["coderabbitai"],
  "journal_dir": "journal"
}
EOF

# Fixture: two resolved threads — one by CR (in list), one by a human.
cat > "$fake_repo/threads.json" <<'EOF'
{
  "data": {"repository": {"pullRequest": {"reviewThreads": {
    "pageInfo": {"hasNextPage": false, "endCursor": null},
    "nodes": [
      {"id": "PRRT_bot", "isResolved": true, "isOutdated": false,
       "path": "src/a.rs", "line": 1,
       "comments": {"nodes": [
         {"id": "c1", "author": {"login": "coderabbitai"},
          "body": "Minor: nit", "createdAt": "2026-05-21T20:00:00Z",
          "url": "https://example/1"}
       ]}},
      {"id": "PRRT_human", "isResolved": true, "isOutdated": false,
       "path": "src/b.rs", "line": 2,
       "comments": {"nodes": [
         {"id": "c2", "author": {"login": "alice"},
          "body": "Drive-by: looks good", "createdAt": "2026-05-21T20:01:00Z",
          "url": "https://example/2"}
       ]}}
    ]
  }}}}
}
EOF

set +e
stderr=$(cd "$fake_repo" && bash "$SYNC_PR" 1 --repo o/r \
  --threads-from threads.json \
  --enforce strict 2>&1 >/dev/null)
ec=$?
set -e

# With only `coderabbitai` in reviewers, the human-authored thread must NOT
# trigger a violation. The CR thread still violates → strict exits 1.
if [ "$ec" -eq 0 ]; then
  TEST_FAILURES=$((TEST_FAILURES + 1))
  echo "FAIL: CR thread should still trigger strict mode"
fi
assert_contains "PRRT_bot" "$stderr" "CR thread flagged"
assert_not_contains "PRRT_human" "$stderr" "human thread NOT flagged"

finish_test
