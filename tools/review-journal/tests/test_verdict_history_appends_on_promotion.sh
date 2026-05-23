#!/usr/bin/env bash
# Pins: when a verdict changes source (e.g., inferred → manual after human
# confirmation), the tool appends to a `verdict_history` log so the chain of
# custody is auditable.
source "$(dirname "$0")/lib.sh"
start_test "test_verdict_history_appends_on_promotion"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

# First run: extract with inference. The single thread starts as inferred.
write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_promo",
    "isResolved": true,
    "isOutdated": false,
    "path": "src/a.rs",
    "line": 1,
    "comments": {"nodes": [
      {"id": "c1", "author": {"login": "coderabbitai"},
       "body": "Major: bad path.\n\n✅ Addressed in commit feedbac",
       "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"}
    ]}
  }
]'

"$EXTRACT_PR" 1 \
  --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" >/dev/null 2>&1

first_source=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
print(d['threads'][0].get('verdict_source'))
")
assert_eq "inferred" "$first_source" "starts as inferred"

# History initialized with the inferred entry.
hist_initial=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
h = d['threads'][0].get('verdict_history') or []
print(len(h))
")
assert_eq "1" "$hist_initial" "history has one entry"

# Promote to manual.
python3 -c "
import json
p = '$journal_dir/pr-1.json'
d = json.load(open(p))
d['threads'][0]['verdict_source'] = 'manual'
d['threads'][0]['verdict_notes'] = 'confirmed against round-2 matrix'
json.dump(d, open(p, 'w'), indent=2)
"

# Re-sync. The tool should detect the source transition and append to history.
"$EXTRACT_PR" 1 \
  --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" >/dev/null 2>&1

hist_after=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
h = d['threads'][0].get('verdict_history') or []
print(len(h))
")
assert_eq "2" "$hist_after" "history grew by one"

# The latest entry records source=manual.
latest_source=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
h = d['threads'][0]['verdict_history']
print(h[-1].get('source'))
")
assert_eq "manual" "$latest_source" "latest history entry source=manual"

# Current verdict_source is still manual.
cur_source=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
print(d['threads'][0].get('verdict_source'))
")
assert_eq "manual" "$cur_source" "current source preserved as manual"

finish_test
