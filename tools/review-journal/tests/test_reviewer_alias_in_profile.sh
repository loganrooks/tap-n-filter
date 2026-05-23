#!/usr/bin/env bash
# Pins: a profile can declare aliases so multiple GitHub logins map to one
# reviewer identity (handles bot renames, marketplace-vs-app suffix variation,
# etc.).
source "$(dirname "$0")/lib.sh"
start_test "test_reviewer_alias_in_profile"

fake_repo="$TEST_WORKDIR/fake-repo"
mkdir -p "$fake_repo"

# Register a single profile whose canonical login is `analyzer[bot]` but which
# also handles findings posted by an older alias `legacy-analyzer`.
cat > "$fake_repo/.review-journal.json" <<'EOF'
{
  "enforcement_mode": "off",
  "journal_dir": "journal",
  "reviewer_profiles": {
    "analyzer[bot]": {
      "kind": "bot:static-analyzer",
      "display_name": "Analyzer",
      "aliases": ["legacy-analyzer", "analyzer-old[bot]"],
      "severity_patterns": [
        {"pattern": "(?i)\\bSEV0\\b", "severity": "critical"}
      ]
    }
  }
}
EOF

cat > "$fake_repo/threads.json" <<'EOF'
{
  "data": {"repository": {"pullRequest": {"reviewThreads": {
    "pageInfo": {"hasNextPage": false, "endCursor": null},
    "nodes": [
      {
        "id": "PRRT_canonical",
        "isResolved": true,
        "isOutdated": false,
        "path": "src/a.rs",
        "line": 1,
        "comments": {"nodes": [
          {"id": "c1", "author": {"login": "analyzer[bot]"},
           "body": "SEV0: stack overflow possible",
           "createdAt": "2026-05-21T20:00:00Z",
           "url": "https://example/1"}
        ]}
      },
      {
        "id": "PRRT_legacy_alias",
        "isResolved": true,
        "isOutdated": false,
        "path": "src/b.rs",
        "line": 2,
        "comments": {"nodes": [
          {"id": "c2", "author": {"login": "legacy-analyzer"},
           "body": "SEV0: another stack overflow",
           "createdAt": "2026-05-21T20:01:00Z",
           "url": "https://example/2"}
        ]}
      }
    ]
  }}}}
}
EOF

sync_exit=0
( cd "$fake_repo" && bash "$SYNC_PR" 1 \
    --repo o/r --threads-from threads.json >/dev/null 2>&1 ) || sync_exit=$?
assert_exit_code "0" "$sync_exit" "alias-resolution sync should succeed"

journal_path="$fake_repo/journal/pr-1.json"
assert_file_exists "$journal_path" "journal exists"

# Both threads should get reviewer_kind from the canonical profile.
canonical_kind=$(python3 -c "
import json
d = json.load(open('$journal_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_canonical')
print(t.get('reviewer_kind'))
")
legacy_kind=$(python3 -c "
import json
d = json.load(open('$journal_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_legacy_alias')
print(t.get('reviewer_kind'))
")
assert_eq "bot:static-analyzer" "$canonical_kind" "canonical reviewer_kind"
assert_eq "bot:static-analyzer" "$legacy_kind" "aliased reviewer_kind"

# Severity pattern also applied to the alias.
legacy_sev=$(python3 -c "
import json
d = json.load(open('$journal_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_legacy_alias')
print(t.get('severity'))
")
assert_eq "critical" "$legacy_sev" "alias severity extracted"

finish_test
