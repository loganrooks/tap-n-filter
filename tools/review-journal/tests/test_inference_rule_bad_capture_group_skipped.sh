#!/usr/bin/env bash
# Pins fix F (Codex #6 + #14, PRRT_kwDOSjmLjM6EPXgZ / EPfpn):
# A custom inference rule with an invalid commit_group or ref_group must NOT
# crash sync. It should be skipped with a stderr warning, and the rest of
# inference continues normally.
source "$(dirname "$0")/lib.sh"
start_test "test_inference_rule_bad_capture_group_skipped"

fake_repo="$TEST_WORKDIR/fake-repo"
mkdir -p "$fake_repo"

# A rule whose pattern has ZERO capture groups but claims commit_group: 1.
cat > "$fake_repo/.review-journal.json" <<'EOF'
{
  "enforcement_mode": "off",
  "journal_dir": "journal",
  "inference_rules": [
    {
      "name": "broken-rule",
      "pattern": "(?i)reverted",
      "verdict": "REJECTED_REGRESSION",
      "commit_group": 1,
      "notes_template": "Inferred regression at {commit}."
    }
  ]
}
EOF

cat > "$fake_repo/threads.json" <<'EOF'
{
  "data": {"repository": {"pullRequest": {"reviewThreads": {
    "pageInfo": {"hasNextPage": false, "endCursor": null},
    "nodes": [
      {"id": "PRRT_break_inference", "isResolved": true, "isOutdated": false,
       "path": "src/a.rs", "line": 1,
       "comments": {"nodes": [
         {"id": "c1", "author": {"login": "coderabbitai"},
          "body": "Major: a thing",
          "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"},
         {"id": "c2", "author": {"login": "loganrooks"},
          "body": "reverted in another PR",
          "createdAt": "2026-05-21T20:01:00Z", "url": "https://example/2"}
       ]}}
    ]
  }}}}
}
EOF

set +e
stderr=$(cd "$fake_repo" && bash "$EXTRACT_PR" 1 --repo o/r \
  --threads-from threads.json 2>&1 >/dev/null)
ec=$?
set -e

# Sync survives.
assert_exit_code 0 "$ec" "sync survives bad capture-group rule"
assert_contains "broken-rule" "$stderr" "stderr names the broken rule"

finish_test
