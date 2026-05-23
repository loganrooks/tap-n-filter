#!/usr/bin/env bash
# Pins fix E (Codex #5, PRRT_kwDOSjmLjM6EPXgW):
# An inferred OBSOLETE verdict must include a commit (or the rule that emits
# it must not exist). Otherwise the inferred record fails `validate`.
source "$(dirname "$0")/lib.sh"
start_test "test_obsolete_bare_rule_emits_valid_record"

# Thread where a reply says "this is obsolete" — currently the bare-word rule
# would emit OBSOLETE without a commit, producing an invalid record.
write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_obsolete_bare",
    "isResolved": true, "isOutdated": false,
    "path": "src/a.rs", "line": 1,
    "comments": {"nodes": [
      {"id": "c1", "author": {"login": "coderabbitai"},
       "body": "Suggestion: tighten the guard",
       "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"},
      {"id": "c2", "author": {"login": "loganrooks"},
       "body": "This whole path is obsolete; closing.",
       "createdAt": "2026-05-21T20:01:00Z", "url": "https://example/2"}
    ]}
  }
]'

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

"$EXTRACT_PR" 1 --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" >/dev/null 2>&1

# Outcome we want: EITHER
#  (a) no verdict is inferred (the thread lands as backfill-needed), OR
#  (b) a verdict IS inferred but is NOT bare OBSOLETE without commit.
# Both options are valid implementation choices. What we forbid is:
# inferring OBSOLETE without a commit (which would fail validate).
verdict=$(python3 -c "import json; print(json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('verdict') or '')")
commit=$(python3 -c "import json; print(json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('verdict_commit') or '')")

# Run validate; it must pass.
set +e
python3 "$REVIEW_JOURNAL_PY" validate "$journal_dir/pr-1.json" >/dev/null 2>"$TEST_WORKDIR/verr.txt"
ec=$?
set -e
verr=$(cat "$TEST_WORKDIR/verr.txt")
assert_exit_code 0 "$ec" "validate passes (no OBSOLETE without commit)"
assert_not_contains "requires verdict_commit" "$verr" "no OBSOLETE-without-commit violation"

# Specifically: if a verdict was inferred, it must not be OBSOLETE-without-commit.
if [ "$verdict" = "OBSOLETE" ] && [ -z "$commit" ]; then
  TEST_FAILURES=$((TEST_FAILURES + 1))
  echo "FAIL: inferred bare OBSOLETE without commit (would fail validate)"
fi

finish_test
