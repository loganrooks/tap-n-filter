#!/usr/bin/env bash
# Pins requirement: a reply that contains a RECONSIDERED block supersedes the
# original verdict; the tool records both with timestamps.
source "$(dirname "$0")/lib.sh"
start_test "test_parse_verdict_block_handles_reconsidered"

# The "body" here is a single comment that contains BOTH the original verdict
# block and a RECONSIDERED revision block. The parser is invoked with
# `parse-block --all` which returns a JSON array.
body=$'```review-verdict\nverdict: REJECTED_BAD_FIT\nreviewer: coderabbitai\nnotes: original take.\n```\n\nLater context made me reconsider.\n\n```review-verdict-reconsidered\nverdict: ACCEPTED_MODIFIED\ncommit: 9f8e7d6\nnotes: after more thought, applied via different patch.\n```'

out=$(printf '%s' "$body" | python3 "$REVIEW_JOURNAL_PY" parse-block --all)
ec=$?
assert_exit_code 0 "$ec" "parse --all exit"

# The output is a JSON array with two entries — the original and the reconsidered.
count=$(printf '%s' "$out" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
assert_eq "2" "$count" "two blocks parsed"

first_verdict=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['verdict'])")
first_kind=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['kind'])")
second_verdict=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)[1]['verdict'])")
second_kind=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)[1]['kind'])")

assert_eq "REJECTED_BAD_FIT" "$first_verdict" "first verdict"
assert_eq "verdict" "$first_kind" "first kind"
assert_eq "ACCEPTED_MODIFIED" "$second_verdict" "second verdict (reconsidered)"
assert_eq "reconsidered" "$second_kind" "second kind"

finish_test
