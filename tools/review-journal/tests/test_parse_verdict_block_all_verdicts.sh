#!/usr/bin/env bash
# Pins requirement: every verdict in the 8-value vocabulary parses correctly.
source "$(dirname "$0")/lib.sh"
start_test "test_parse_verdict_block_all_verdicts"

verdicts=(
  ACCEPTED
  ACCEPTED_MODIFIED
  DEFERRED
  REJECTED_FALSE_POSITIVE
  REJECTED_BAD_FIT
  REJECTED_REGRESSION
  OBSOLETE
  DUPLICATE
)

for v in "${verdicts[@]}"; do
  # Build a minimally-valid block per the field-requirement matrix.
  # ACCEPTED*/OBSOLETE need `commit`; REJECTED_*/DEFERRED need `notes`.
  case "$v" in
    ACCEPTED|ACCEPTED_MODIFIED|OBSOLETE)
      body=$'```review-verdict\nverdict: '"$v"$'\ncommit: deadbee\nreviewer: coderabbitai\n```'
      ;;
    REJECTED_FALSE_POSITIVE|REJECTED_BAD_FIT|REJECTED_REGRESSION|DEFERRED)
      body=$'```review-verdict\nverdict: '"$v"$'\nreviewer: coderabbitai\nnotes: reason here.\n```'
      ;;
    DUPLICATE)
      body=$'```review-verdict\nverdict: '"$v"$'\nreviewer: coderabbitai\nnotes: same as thread X.\n```'
      ;;
  esac
  out=$(printf '%s' "$body" | python3 "$REVIEW_JOURNAL_PY" parse-block 2>/dev/null) || {
    TEST_FAILURES=$((TEST_FAILURES + 1))
    echo "${CRED}FAIL${CRST}: $TEST_NAME: parser rejected verdict=$v"
    continue
  }
  got=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['verdict'])")
  assert_eq "$v" "$got" "verdict round-trip for $v"
done

finish_test
