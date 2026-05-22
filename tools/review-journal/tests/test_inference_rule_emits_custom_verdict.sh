#!/usr/bin/env bash
# Pins: config can register a generic inference rule that emits ANY verdict
# (not just ACCEPTED_MODIFIED). This is the seam that lets the tool encode
# new disposition patterns without code changes — e.g., a future "shipped via
# revert PR" pattern → REJECTED_REGRESSION, or "covered by ADR" → DEFERRED.
source "$(dirname "$0")/lib.sh"
start_test "test_inference_rule_emits_custom_verdict"

fake_repo="$TEST_WORKDIR/fake-repo"
mkdir -p "$fake_repo"

cat > "$fake_repo/.review-journal.json" <<'EOF'
{
  "enforcement_mode": "off",
  "journal_dir": "journal",
  "inference_rules": [
    {
      "name": "duplicate-of-thread",
      "pattern": "duplicate of\\s+(PRRT_[A-Za-z0-9_-]+)",
      "verdict": "DUPLICATE",
      "ref_group": 1,
      "notes_template": "Inferred duplicate of thread {ref}."
    },
    {
      "name": "regression-reverted",
      "pattern": "reverted in\\s+([0-9a-f]{7,40})",
      "verdict": "REJECTED_REGRESSION",
      "commit_group": 1,
      "notes_template": "Inferred regression; reverted in {commit}."
    }
  ]
}
EOF

cat > "$fake_repo/threads.json" <<'EOF'
{
  "data": {"repository": {"pullRequest": {"reviewThreads": {
    "pageInfo": {"hasNextPage": false, "endCursor": null},
    "nodes": [
      {
        "id": "PRRT_dup",
        "isResolved": true, "isOutdated": false,
        "path": "src/a.rs", "line": 1,
        "comments": {"nodes": [
          {"id": "c1", "author": {"login": "coderabbitai"},
           "body": "Minor: missing docstring",
           "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"},
          {"id": "c2", "author": {"login": "loganrooks"},
           "body": "Closing — duplicate of PRRT_abcDEF123_xyz_HJK.",
           "createdAt": "2026-05-21T20:01:00Z", "url": "https://example/2"}
        ]}
      },
      {
        "id": "PRRT_reg",
        "isResolved": true, "isOutdated": false,
        "path": "src/b.rs", "line": 2,
        "comments": {"nodes": [
          {"id": "c3", "author": {"login": "coderabbitai"},
           "body": "Major: race condition",
           "createdAt": "2026-05-21T20:02:00Z", "url": "https://example/3"},
          {"id": "c4", "author": {"login": "loganrooks"},
           "body": "Tried the fix; reverted in 4f3e2d1 after it broke prod.",
           "createdAt": "2026-05-21T20:03:00Z", "url": "https://example/4"}
        ]}
      }
    ]
  }}}}
}
EOF

( cd "$fake_repo" && bash "$EXTRACT_PR" 1 \
    --repo o/r --threads-from threads.json >/dev/null 2>&1 ) || true

journal_path="$fake_repo/journal/pr-1.json"
assert_file_exists "$journal_path" "journal exists"

dup_verdict=$(python3 -c "
import json
d = json.load(open('$journal_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_dup')
print(t.get('verdict'))
")
dup_notes=$(python3 -c "
import json
d = json.load(open('$journal_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_dup')
print(t.get('verdict_notes') or '')
")
reg_verdict=$(python3 -c "
import json
d = json.load(open('$journal_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_reg')
print(t.get('verdict'))
")
reg_commit=$(python3 -c "
import json
d = json.load(open('$journal_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_reg')
print(t.get('verdict_commit') or '')
")

assert_eq "DUPLICATE" "$dup_verdict" "custom DUPLICATE rule fired"
assert_contains "PRRT_abcDEF123_xyz_HJK" "$dup_notes" "ref captured in notes"
assert_eq "REJECTED_REGRESSION" "$reg_verdict" "custom REJECTED_REGRESSION rule fired"
assert_eq "4f3e2d1" "$reg_commit" "commit captured by rule"

finish_test
