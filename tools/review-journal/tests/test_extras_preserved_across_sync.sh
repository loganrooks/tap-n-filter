#!/usr/bin/env bash
# Pins: each thread record has an `extras` map that downstream consumers can
# write into (e.g., an agentic-devops router attaching `effort_estimate` or
# `risk_surface`). The extras pass through a re-sync untouched — they're
# never overwritten by the fetched-thread data.
source "$(dirname "$0")/lib.sh"
start_test "test_extras_preserved_across_sync"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

# Initial sync.
"$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" --enforce off >/dev/null 2>&1

# Downstream consumer attaches data to the first thread.
python3 -c "
import json
p = '$journal_dir/pr-1.json'
d = json.load(open(p))
d['threads'][0]['extras'] = {
    'effort_estimate': 'small',
    'risk_surface': 'safe-surface',
    'router_confidence': 0.93,
    'tags': ['routine', 'docs-adjacent']
}
json.dump(d, open(p, 'w'), indent=2)
"

# Re-sync.
"$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" --enforce off >/dev/null 2>&1

# Extras should survive untouched.
effort=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
print((d['threads'][0].get('extras') or {}).get('effort_estimate'))
")
tags=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
print(','.join((d['threads'][0].get('extras') or {}).get('tags') or []))
")
assert_eq "small" "$effort" "effort_estimate preserved"
assert_eq "routine,docs-adjacent" "$tags" "tags array preserved"

# Other threads that never had extras still have an empty extras field
# (or None — both are fine, just must not crash).
other_extras=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
ext = d['threads'][1].get('extras')
print('present' if isinstance(ext, dict) else 'absent')
")
# Default is an empty dict so the shape is always predictable.
assert_eq "present" "$other_extras" "default extras shape is dict"

finish_test
