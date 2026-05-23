#!/usr/bin/env bash
# Pins requirement: backfilling against the captured PR #7 GraphQL response
# produces a journal entry with the right number of thread records and at least
# one each of `block`, `inferred`, and `manual` verdict-sources.
#
# Test #14 in the spec list. The spec describes ~38 threads; the captured
# GraphQL response has 47 (every CR review-comment maps to a thread, plus
# Codex replies). The test asserts that distinct count.
source "$(dirname "$0")/lib.sh"
start_test "test_backfill_pr7_produces_correct_thread_records"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

"$EXTRACT_PR" 7 \
  --repo loganrooks/tap-n-filter \
  --threads-from "$TESTS_DIR/fixtures/pr7-threads.raw.json" \
  --journal-dir "$journal_dir" \
  --accept-inferred >/dev/null 2>&1
ec=$?
assert_exit_code 0 "$ec" "extract exit code"

out_path="$journal_dir/pr-7.json"
assert_file_exists "$out_path" "journal file"

# 47 threads in the captured fixture.
count=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['threads']))" "$out_path")
assert_eq "47" "$count" "thread count"

# Sources tally: block, inferred, manual all >= 1.
# (The PR #7 raw fixture itself has no `manual`-source entries yet — they're
# produced post-hoc when a human edits the journal. To exercise the third
# verdict-source we drop a manual override file into the journal dir before
# extract runs; the tool merges manual overrides into the output.)
#
# This `manual` test is the canary that `verdict_source: "manual"` is preserved
# through a re-sync. We simulate it by writing a starter journal with a manual
# entry, then re-running extract.
python3 -c "
import json
p = '$out_path'
d = json.load(open(p))
# Pick the first thread and tag it as manual.
d['threads'][0]['verdict_source'] = 'manual'
d['threads'][0]['verdict_notes'] = (d['threads'][0].get('verdict_notes') or '') + ' [manually confirmed]'
json.dump(d, open(p, 'w'), indent=2)
"

# Re-run extract; the manual entry should be preserved. Capture and assert
# the exit code so a silent failure on the second run can't mask a
# regression that later assertions might still pass against prior file state.
set +e
"$EXTRACT_PR" 7 \
  --repo loganrooks/tap-n-filter \
  --threads-from "$TESTS_DIR/fixtures/pr7-threads.raw.json" \
  --journal-dir "$journal_dir" \
  --accept-inferred >/dev/null 2>&1
second_extract_ec=$?
set -e
assert_exit_code 0 "$second_extract_ec" "second extract preserving manual entry"

sources=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
seen = sorted({t.get('verdict_source') for t in d['threads'] if t.get('verdict_source')})
print(','.join(seen))
" "$out_path")

assert_contains "block" "$sources" "block source present"
assert_contains "inferred" "$sources" "inferred source present"
assert_contains "manual" "$sources" "manual source preserved across re-sync"

finish_test
