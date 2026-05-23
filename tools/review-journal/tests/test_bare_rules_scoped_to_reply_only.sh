#!/usr/bin/env bash
# Pins fix I (Codex #9, PRRT_kwDOSjmLjM6EPXgj + #13, PRRT_kwDOSjmLjM6EPfpl):
# The bare-keyword rules (deferred/duplicate) must only match against
# MAINTAINER REPLIES, not the reviewer's original finding text. Otherwise a
# reviewer mentioning "obsolete API" or "this is a duplicate concern" in the
# original finding corrupts the inferred verdict.
source "$(dirname "$0")/lib.sh"
start_test "test_bare_rules_scoped_to_reply_only"

# Thread where the REVIEWER says "deferred" but no maintainer reply discusses
# the disposition. The bare-deferred rule must NOT fire.
write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_no_reply_decision",
    "isResolved": true, "isOutdated": false,
    "path": "src/x.rs", "line": 1,
    "comments": {"nodes": [
      {"id": "c1", "author": {"login": "coderabbitai"},
       "body": "Major: this work was deferred to a future PR per the original spec; suggesting a guard here.",
       "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"}
    ]}
  }
]'

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

"$EXTRACT_PR" 1 --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" >/dev/null 2>&1

verdict=$(python3 -c "import json; print(json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('verdict') or '')")
source=$(python3 -c "import json; print(json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('verdict_source') or '')")

# We require: NOT inferred as DEFERRED from the reviewer's prose. Acceptable
# outcomes: no verdict at all, OR a different verdict the reply text supports.
if [ "$verdict" = "DEFERRED" ] && [ "$source" = "inferred" ]; then
  TEST_FAILURES=$((TEST_FAILURES + 1))
  echo "FAIL: bare-DEFERRED inferred from reviewer's original text"
  echo "  verdict=$verdict source=$source"
fi

# Sanity: when the MAINTAINER says "deferred" in a reply, the rule SHOULD fire.
write_threads_fixture "$TEST_WORKDIR/threads2.json" '[
  {
    "id": "PRRT_reply_decision",
    "isResolved": true, "isOutdated": false,
    "path": "src/y.rs", "line": 2,
    "comments": {"nodes": [
      {"id": "c1", "author": {"login": "coderabbitai"},
       "body": "Major: this needs a guard",
       "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"},
      {"id": "c2", "author": {"login": "loganrooks"},
       "body": "Deferred for now; will revisit.",
       "createdAt": "2026-05-21T20:01:00Z", "url": "https://example/2"}
    ]}
  }
]'

journal_dir2="$TEST_WORKDIR/journal2"
mkdir -p "$journal_dir2"
"$EXTRACT_PR" 1 --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads2.json" \
  --journal-dir "$journal_dir2" >/dev/null 2>&1
verdict2=$(python3 -c "import json; print(json.load(open('$journal_dir2/pr-1.json'))['threads'][0].get('verdict') or '')")
assert_eq "DEFERRED" "$verdict2" "reply-side deferred IS inferred"

finish_test
