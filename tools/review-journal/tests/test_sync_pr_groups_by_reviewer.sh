#!/usr/bin/env bash
# Pins requirement: sync output groups threads by reviewer; the small fixture has
# both coderabbitai and chatgpt-codex-connector threads and both groups appear.
source "$(dirname "$0")/lib.sh"
start_test "test_sync_pr_groups_by_reviewer"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

stdout=$("$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" \
  --enforce off \
  --summary 2>/dev/null)

# The summary output groups by reviewer. Each reviewer name appears as a section
# header. Both expected reviewers are present.
assert_contains "chatgpt-codex-connector" "$stdout" "codex group header"
assert_contains "coderabbitai" "$stdout" "CR group header"

# The same reviewer names also appear in the json file under threads[].reviewer.
reviewers=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
seen = sorted({t['reviewer'] for t in d['threads']})
print(','.join(seen))
" "$journal_dir/pr-1.json")
assert_eq "chatgpt-codex-connector,coderabbitai" "$reviewers" "both reviewers in json"

# Within the threads array, the threads are ordered by (reviewer, created_at).
# Verify codex's thread comes before either of CR's threads.
first_reviewer=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['threads'][0]['reviewer'])" "$journal_dir/pr-1.json")
assert_eq "chatgpt-codex-connector" "$first_reviewer" "first thread reviewer (alphabetical)"

finish_test
