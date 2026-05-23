#!/usr/bin/env bash
# Pins fix A (Codex #1, PRRT_kwDOSjmLjM6EPXgM):
# A thread with verdict_source: "manual" must NOT appear in BACKFILL NEEDED,
# even if the current PR replies have no parsed verdict block. Manual entries
# are the maintainer-confirmed end state; enforcement must respect them.
source "$(dirname "$0")/lib.sh"
start_test "test_manual_source_excluded_from_backfill"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

# Step 1: synthetic thread with no block in any reply (just a resolved finding).
write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_to_be_manual",
    "isResolved": true,
    "isOutdated": false,
    "path": "src/x.rs",
    "line": 1,
    "comments": {"nodes": [
      {"id": "c1", "author": {"login": "coderabbitai"},
       "body": "Minor: rename foo",
       "createdAt": "2026-05-21T20:00:00Z", "url": "https://example/1"}
    ]}
  }
]'

# Initial sync — thread should land in BACKFILL NEEDED.
set +e
stderr=$("$SYNC_PR" 1 --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" \
  --enforce warning 2>&1 >/dev/null)
ec=$?
set -e
assert_exit_code 0 "$ec" "first sync exit"
assert_contains "BACKFILL NEEDED" "$stderr" "first sync flags backfill needed"

# Step 2: maintainer promotes the thread to manual.
python3 -c "
import json
p = '$journal_dir/pr-1.json'
d = json.load(open(p))
t = d['threads'][0]
t['verdict_source'] = 'manual'
t['verdict'] = 'REJECTED_BAD_FIT'
t['verdict_notes'] = 'confirmed: local convention differs from suggestion'
json.dump(d, open(p, 'w'), indent=2)
"

# Step 3: re-sync. With manual already recorded, BACKFILL NEEDED must be empty.
set +e
stderr=$("$SYNC_PR" 1 --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" \
  --enforce strict 2>&1 >/dev/null)
ec=$?
set -e
assert_exit_code 0 "$ec" "strict mode passes after manual"
assert_not_contains "BACKFILL NEEDED" "$stderr" "no BACKFILL NEEDED for manual thread"

finish_test
