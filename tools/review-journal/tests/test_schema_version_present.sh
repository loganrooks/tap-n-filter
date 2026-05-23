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
# Use a strict prefix check so values like "21.0" or "v1.0" don't pass.
case "$version" in
  1.*) ;;
  *)
    TEST_FAILURES=$((TEST_FAILURES + 1))
    echo "${CRED}FAIL${CRST}: $TEST_NAME: schema_version must start with '1.' (got: $(printf '%q' "$version"))"
    ;;
esac

# Same field present in index.json.
idx_version=$(python3 -c "
import json
d = json.load(open('$journal_dir/index.json'))
print(d.get('schema_version', ''))
")
case "$idx_version" in
  1.*) ;;
  *)
    TEST_FAILURES=$((TEST_FAILURES + 1))
    echo "${CRED}FAIL${CRST}: $TEST_NAME: index.json schema_version must start with '1.' (got: $(printf '%q' "$idx_version"))"
    ;;
esac

finish_test
