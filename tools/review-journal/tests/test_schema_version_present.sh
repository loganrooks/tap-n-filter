#!/usr/bin/env bash
# Pins: every journal file carries a `schema_version` field so future tools
# can migrate older journals without guessing.
source "$(dirname "$0")/lib.sh"
start_test "test_schema_version_present"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

"$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" \
  --enforce off >/dev/null 2>&1

version=$(python3 -c "
import json
d = json.load(open('$journal_dir/pr-1.json'))
print(d.get('schema_version', ''))
")
# We commit to schema_version 1.x; the major-version is the contract.
assert_contains "1." "$version" "schema_version starts with 1."

# Same field present in index.json.
idx_version=$(python3 -c "
import json
d = json.load(open('$journal_dir/index.json'))
print(d.get('schema_version', ''))
")
assert_contains "1." "$idx_version" "index.json schema_version starts with 1."

finish_test
