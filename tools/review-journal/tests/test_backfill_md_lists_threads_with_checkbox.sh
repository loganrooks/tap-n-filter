#!/usr/bin/env bash
# Pins requirement: extract-pr renders a backfill markdown doc with one
# `- [ ]` line per thread needing confirmation.
source "$(dirname "$0")/lib.sh"
start_test "test_backfill_md_lists_threads_with_checkbox"

# small-pr.json has 3 threads:
#   - PRRT_block_ok           — has a block (no inference needed)
#   - PRRT_block_missing      — resolved without a block, reply mentions "Fixed in bbb2222"
#   - PRRT_unresolved_with_block — has a block (still resolves to a verdict)
# Only PRRT_block_missing should appear in the backfill doc.

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

"$EXTRACT_PR" 1 \
  --repo test/repo \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" >/dev/null 2>&1
ec=$?
assert_exit_code 0 "$ec" "extract exit code"

md_path="$journal_dir/pr-1-backfill.md"
assert_file_exists "$md_path" "backfill md exists"

body=$(cat "$md_path")
# One checkbox line per inferred thread.
checkbox_count=$(grep -cE '^- \[ \]' "$md_path" || true)
assert_eq "1" "$checkbox_count" "exactly one checkbox line"
assert_contains "PRRT_block_missing" "$body" "the inferred thread is listed"
assert_contains "ACCEPTED_MODIFIED" "$body" "the inferred verdict is shown"
assert_contains "bbb2222" "$body" "the inferred commit is shown"

# The threads that already had blocks should NOT appear as inference targets.
assert_not_contains "PRRT_block_ok" "$body" "block-already-present thread not in backfill"

finish_test
