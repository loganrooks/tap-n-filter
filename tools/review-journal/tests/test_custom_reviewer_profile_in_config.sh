#!/usr/bin/env bash
# Pins requirement: a maintainer can add a new bot via config without code
# changes. The custom profile defines severity patterns and auto-resolve
# patterns; the tool uses them when handling threads from that reviewer.
source "$(dirname "$0")/lib.sh"
start_test "test_custom_reviewer_profile_in_config"

# Set up a fake repo with a config that registers a brand-new bot.
fake_repo="$TEST_WORKDIR/fake-repo"
mkdir -p "$fake_repo"

cat > "$fake_repo/.review-journal.json" <<'EOF'
{
  "enforcement_mode": "warning",
  "journal_dir": "journal",
  "reviewer_profiles": {
    "shinybot[bot]": {
      "kind": "bot:static-analyzer",
      "display_name": "Shiny Bot",
      "severity_patterns": [
        {"pattern": "(?i)\\bSHINY-CRIT\\b", "severity": "critical"},
        {"pattern": "(?i)\\bSHINY-WARN\\b", "severity": "warning"}
      ],
      "auto_resolve_patterns": [
        "(?i)Shiny auto-closed in commit ([0-9a-f]{7,40})"
      ]
    }
  }
}
EOF

# Synthetic threads with the custom reviewer.
cat > "$fake_repo/threads.json" <<'EOF'
{
  "data": {"repository": {"pullRequest": {"reviewThreads": {
    "pageInfo": {"hasNextPage": false, "endCursor": null},
    "nodes": [
      {
        "id": "PRRT_shiny_1",
        "isResolved": true,
        "isOutdated": false,
        "path": "src/foo.rs",
        "line": 42,
        "comments": {"nodes": [
          {
            "id": "c1",
            "author": {"login": "shinybot[bot]"},
            "body": "SHINY-CRIT: integer overflow on signed cast.\n\nShiny auto-closed in commit feedbac.",
            "createdAt": "2026-05-21T20:00:00Z",
            "url": "https://example/pr/1#1"
          }
        ]}
      }
    ]
  }}}}
}
EOF

# Run from inside fake_repo so the config is discovered.
journal_dir_rel="journal"
# Capture exit code explicitly instead of swallowing with `|| true`, which
# would mask real regressions in sync/extract.
set +e
( cd "$fake_repo" && bash "$SYNC_PR" 1 \
    --repo other/repo \
    --threads-from threads.json \
    --enforce off >/dev/null 2>&1 )
sync_ec=$?
set -e
assert_exit_code 0 "$sync_ec" "sync exit code"

# Then run extract with inference enabled (auto-resolve pattern matches even
# without a reply, since the original comment contains the marker).
set +e
( cd "$fake_repo" && bash "$EXTRACT_PR" 1 \
    --repo other/repo \
    --threads-from threads.json >/dev/null 2>&1 )
extract_ec=$?
set -e
assert_exit_code 0 "$extract_ec" "extract exit code"

journal_path="$fake_repo/$journal_dir_rel/pr-1.json"
assert_file_exists "$journal_path" "journal file"

reviewer_kind=$(python3 -c "
import json
d = json.load(open('$journal_path'))
print(d['threads'][0].get('reviewer_kind'))
")
sev=$(python3 -c "
import json
d = json.load(open('$journal_path'))
print(d['threads'][0].get('severity'))
")
verdict=$(python3 -c "
import json
d = json.load(open('$journal_path'))
print(d['threads'][0].get('verdict'))
")
commit=$(python3 -c "
import json
d = json.load(open('$journal_path'))
print(d['threads'][0].get('verdict_commit'))
")
source=$(python3 -c "
import json
d = json.load(open('$journal_path'))
print(d['threads'][0].get('verdict_source'))
")

assert_eq "bot:static-analyzer" "$reviewer_kind" "custom reviewer_kind"
assert_eq "critical" "$sev" "custom severity pattern matched"
assert_eq "ACCEPTED_MODIFIED" "$verdict" "custom auto-resolve pattern inferred verdict"
assert_eq "feedbac" "$commit" "custom auto-resolve commit captured"
assert_eq "inferred" "$source" "inferred via custom pattern"

finish_test
