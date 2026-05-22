#!/usr/bin/env bash
# Pins requirement: --enforce warning exits 0 but logs the backfill issues to stderr.
source "$(dirname "$0")/lib.sh"
start_test "test_sync_pr_enforce_warning_exits_zero_logs_to_stderr"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

set +e
stderr=$("$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" \
  --enforce warning 2>&1 >/dev/null)
ec=$?
set -e
assert_exit_code 0 "$ec" "warning mode exit code"
assert_contains "BACKFILL NEEDED" "$stderr" "stderr lists backfill needed"

# Also check that the unresolved-with-block thread is flagged as RESOLVE NEEDED.
# We constructed PRRT_unresolved_with_block to be exactly that case.
assert_contains "RESOLVE NEEDED" "$stderr" "stderr flags unresolved-with-block"

finish_test
