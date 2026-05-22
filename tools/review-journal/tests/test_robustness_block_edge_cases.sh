#!/usr/bin/env bash
# Pins various edge cases the parser must handle without crashing:
#   - quoted block values (`verdict: "ACCEPTED"`)
#   - extra surrounding whitespace
#   - notes with multi-paragraph content (continuation lines)
#   - block embedded in a long reply with other markdown
source "$(dirname "$0")/lib.sh"
start_test "test_robustness_block_edge_cases"

# Quoted verdict value.
body=$'```review-verdict\nverdict: "ACCEPTED"\ncommit: "abc1234"\nreviewer: coderabbitai\n```'
out=$(printf '%s' "$body" | python3 "$REVIEW_JOURNAL_PY" parse-block)
verdict=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['verdict'])")
commit=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['commit'])")
assert_eq "ACCEPTED" "$verdict" "quoted verdict unquoted"
assert_eq "abc1234" "$commit" "quoted commit unquoted"

# Whitespace around values.
body=$'```review-verdict\nverdict:   ACCEPTED   \ncommit:\t abc1234   \nreviewer: coderabbitai\n```'
out=$(printf '%s' "$body" | python3 "$REVIEW_JOURNAL_PY" parse-block)
verdict=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['verdict'])")
commit=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['commit'])")
assert_eq "ACCEPTED" "$verdict" "whitespace-padded verdict trimmed"
assert_eq "abc1234" "$commit" "whitespace-padded commit trimmed"

# Multi-line notes (continuation lines that don't start with a key:).
body=$'```review-verdict\nverdict: REJECTED_BAD_FIT\nreviewer: coderabbitai\nnotes: First paragraph explaining context.\n\nSecond paragraph adding detail.\nThird line.\n```'
out=$(printf '%s' "$body" | python3 "$REVIEW_JOURNAL_PY" parse-block)
notes=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['notes'])")
assert_contains "First paragraph" "$notes" "notes line 1 captured"
assert_contains "Second paragraph" "$notes" "notes line 2 captured"
assert_contains "Third line" "$notes" "notes line 3 captured"

# Block embedded in a longer comment.
body=$'Hey, here is my take.\n\n```review-verdict\nverdict: ACCEPTED\ncommit: deadbee\nreviewer: coderabbitai\n```\n\nAnd here is more discussion of why.'
out=$(printf '%s' "$body" | python3 "$REVIEW_JOURNAL_PY" parse-block)
verdict=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['verdict'])")
assert_eq "ACCEPTED" "$verdict" "block extracted from longer body"

finish_test
