#!/usr/bin/env bash
# Pins requirement: --enforce strict exits non-zero on a resolved thread with no
# verdict block.
source "$(dirname "$0")/lib.sh"
start_test "test_sync_pr_enforce_strict_exits_nonzero_on_missing_block"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

# small-pr.json has PRRT_block_missing — resolved, no verdict block.
set +e
stderr=$("$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" \
  --enforce strict 2>&1 >/dev/null)
ec=$?
set -e
# Non-zero exit expected. Anything > 0 is acceptable but we expect a specific value.
if [ "$ec" -eq 0 ]; then
  TEST_FAILURES=$((TEST_FAILURES + 1))
  echo "${CRED}FAIL${CRST}: $TEST_NAME: strict mode should not exit 0"
fi

assert_contains "BACKFILL NEEDED" "$stderr" "stderr lists backfill needed"
assert_contains "PRRT_block_missing" "$stderr" "stderr names the thread"

finish_test
