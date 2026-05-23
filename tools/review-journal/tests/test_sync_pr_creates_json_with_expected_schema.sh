#!/usr/bin/env bash
# Pins requirement: sync-pr produces a pr-N.json with the documented schema.
source "$(dirname "$0")/lib.sh"
start_test "test_sync_pr_creates_json_with_expected_schema"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

# Run sync against a captured fixture (offline mode).
"$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" \
  --enforce off >/dev/null 2>&1
ec=$?
assert_exit_code 0 "$ec" "sync exit code"

out_path="$journal_dir/pr-1.json"
assert_file_exists "$out_path" "journal file"

# Strip non-deterministic fields (timestamps in last_synced_at and in any
# verdict_history entries) and compare structurally to the golden file.
diff_out=$(python3 -c "
import json, sys
got = json.load(open(sys.argv[1]))
want = json.load(open(sys.argv[2]))
got.pop('last_synced_at', None)
for t in got.get('threads', []):
    for h in t.get('verdict_history', []) or []:
        h.pop('at', None)
if got == want:
  print('OK')
else:
  import difflib
  g = json.dumps(got, indent=2, sort_keys=True).splitlines()
  w = json.dumps(want, indent=2, sort_keys=True).splitlines()
  for l in difflib.unified_diff(w, g, lineterm='', fromfile='golden', tofile='actual'):
    print(l)
" "$out_path" "$TESTS_DIR/golden/small-pr.expected.json")

assert_eq "OK" "$diff_out" "structural diff"

# Verify required top-level keys.
top_keys=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(','.join(sorted(d.keys())))" "$out_path")
assert_contains "last_synced_at" "$top_keys" "last_synced_at present"
assert_contains "pr_number" "$top_keys" "pr_number present"
assert_contains "repo" "$top_keys" "repo present"
assert_contains "threads" "$top_keys" "threads present"

finish_test
