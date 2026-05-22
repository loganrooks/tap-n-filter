#!/usr/bin/env bash
# Pins requirement: a minimal valid ACCEPTED block parses with each field round-tripping.
source "$(dirname "$0")/lib.sh"
start_test "test_parse_verdict_block_minimal"

# Pipe a comment body containing a verdict block to the parser. The parser
# emits the parsed block as JSON to stdout on success, exit 0.
body='```review-verdict
verdict: ACCEPTED
commit: abc1234
finding_category: style/import-ordering
reviewer: coderabbitai
notes: Applied as-is.
```'

out=$(printf '%s' "$body" | python3 "$REVIEW_JOURNAL_PY" parse-block)
ec=$?
assert_exit_code 0 "$ec" "parse exit"

# Each field round-trips. We assert via jq-free Python so the test doesn't
# depend on jq being installed.
verdict=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['verdict'])")
commit=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['commit'])")
category=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['finding_category'])")
reviewer=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['reviewer'])")
notes=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['notes'])")

assert_eq "ACCEPTED" "$verdict" "verdict field"
assert_eq "abc1234" "$commit" "commit field"
assert_eq "style/import-ordering" "$category" "finding_category field"
assert_eq "coderabbitai" "$reviewer" "reviewer field"
assert_eq "Applied as-is." "$notes" "notes field"

finish_test
