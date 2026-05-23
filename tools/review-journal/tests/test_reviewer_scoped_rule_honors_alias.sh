#!/usr/bin/env bash
# Pins fix H (Codex #8, PRRT_kwDOSjmLjM6EPXgg):
# An inference rule scoped to a CANONICAL reviewer login (`applies_to_reviewer`)
# must fire when the thread author posted under an ALIAS for that reviewer.
source "$(dirname "$0")/lib.sh"
start_test "test_reviewer_scoped_rule_honors_alias"

fake_repo="$TEST_WORKDIR/fake-repo"
mkdir -p "$fake_repo"

cat > "$fake_repo/.review-journal.json" <<'EOF'
{
  "enforcement_mode": "off",
  "journal_dir": "journal",
  "reviewer_profiles": {
    "shinybot[bot]": {
      "kind": "bot:static-analyzer",
      "display_name": "Shiny",
      "aliases": ["shiny-legacy"]
    }
  },
  "inference_rules": [
    {
      "name": "shiny-scoped-rule",
      "pattern": "shiny-resolves\\s+([0-9a-f]{7,40})",
      "applies_to_reviewer": "shinybot[bot]",
      "verdict": "ACCEPTED_MODIFIED",
      "commit_group": 1,
      "notes_template": "Inferred from Shiny-specific marker, commit {commit}."
    }
  ]
}
EOF

# Thread is authored by the ALIAS, not the canonical login.
cat > "$fake_repo/threads.json" <<'EOF'
{
  "data": {"repository": {"pullRequest": {"reviewThreads": {
    "pageInfo": {"hasNextPage": false, "endCursor": null},
    "nodes": [
      {"id": "PRRT_alias", "isResolved": true, "isOutdated": false,
       "path": "src/x.rs", "line": 1,
       "comments": {"nodes": [
         {"id": "c1", "author": {"login": "shiny-legacy"},
          "body": "Critical: stack overflow\n\nshiny-resolves cafe123",
          "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"}
       ]}}
    ]
  }}}}
}
EOF

( cd "$fake_repo" && bash "$EXTRACT_PR" 1 --repo o/r \
    --threads-from threads.json >/dev/null 2>&1 ) || true

verdict=$(python3 -c "
import json
d = json.load(open('$fake_repo/journal/pr-1.json'))
print(d['threads'][0].get('verdict') or '')
")
commit=$(python3 -c "
import json
d = json.load(open('$fake_repo/journal/pr-1.json'))
print(d['threads'][0].get('verdict_commit') or '')
")

assert_eq "ACCEPTED_MODIFIED" "$verdict" "alias-authored thread matched canonical-scoped rule"
assert_eq "cafe123" "$commit" "rule's commit_group captured under alias"

finish_test
