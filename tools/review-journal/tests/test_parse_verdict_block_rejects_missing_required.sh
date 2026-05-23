#!/usr/bin/env bash
# Pins requirement: a block missing required fields is rejected with a clear error.
# Required fields:
#   - `verdict` always
#   - `commit` when verdict is ACCEPTED / ACCEPTED_MODIFIED / OBSOLETE
#   - `notes` when verdict is REJECTED_* or DEFERRED
source "$(dirname "$0")/lib.sh"
start_test "test_parse_verdict_block_rejects_missing_required"

# Helper: run parse-block on a body, capture stderr and exit code without `|| true`
# (which would mask the exit code).
run_parse() {
  local body="$1"
  local err_file="$TEST_WORKDIR/err.txt"
  set +e
  printf '%s' "$body" | python3 "$REVIEW_JOURNAL_PY" parse-block >/dev/null 2>"$err_file"
  ec=$?
  set -e
  err=$(cat "$err_file")
}

# Case 1: missing the verdict field entirely.
run_parse $'```review-verdict\ncommit: abc1234\nreviewer: coderabbitai\n```'
assert_exit_code 2 "$ec" "exit code on missing verdict"
assert_contains "verdict" "$err" "error names the missing field"

# Case 2: ACCEPTED without commit (commit required for ACCEPTED).
run_parse $'```review-verdict\nverdict: ACCEPTED\nreviewer: coderabbitai\n```'
assert_exit_code 2 "$ec" "exit code on missing commit for ACCEPTED"
assert_contains "commit" "$err" "error names commit as missing"

# Case 3: REJECTED_BAD_FIT without notes.
run_parse $'```review-verdict\nverdict: REJECTED_BAD_FIT\nreviewer: coderabbitai\n```'
assert_exit_code 2 "$ec" "exit code on missing notes for REJECTED_BAD_FIT"
assert_contains "notes" "$err" "error names notes as missing"

# Case 4: invalid verdict value.
run_parse $'```review-verdict\nverdict: SOMETHING_ELSE\nnotes: huh\n```'
assert_exit_code 2 "$ec" "exit code on invalid verdict"
assert_contains "SOMETHING_ELSE" "$err" "error names the offending value"

finish_test
