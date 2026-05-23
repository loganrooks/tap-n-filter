#!/usr/bin/env bash
# Pins fix C (Codex #3 + #11, PRRT_kwDOSjmLjM6EPXgR / EPfph):
# When --repo is omitted, the tool should fall back to the GH_REPO environment
# variable (matches gh's convention) rather than erroring out.
source "$(dirname "$0")/lib.sh"
start_test "test_gh_repo_env_fallback"

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

# Run sync WITHOUT --repo but WITH GH_REPO set.
set +e
GH_REPO=test/repo "$SYNC_PR" 1 \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" \
  --enforce off >/dev/null 2>"$TEST_WORKDIR/err.txt"
ec=$?
set -e
err=$(cat "$TEST_WORKDIR/err.txt")
assert_exit_code 0 "$ec" "sync with GH_REPO env succeeds"
assert_not_contains "--repo OWNER/REPO is required" "$err" "no --repo-required error"

# Verify the repo field was set correctly in output.
repo=$(python3 -c "import json; print(json.load(open('$journal_dir/pr-1.json'))['repo'])")
assert_eq "test/repo" "$repo" "repo derived from GH_REPO"

# Sanity: without GH_REPO, sync should still error.
unset GH_REPO
set +e
"$SYNC_PR" 1 \
  --threads-from "$TESTS_DIR/fixtures/small-pr.json" \
  --journal-dir "$journal_dir" \
  --enforce off >/dev/null 2>"$TEST_WORKDIR/err2.txt"
ec=$?
set -e
err2=$(cat "$TEST_WORKDIR/err2.txt")
if [ "$ec" -eq 0 ]; then
  TEST_FAILURES=$((TEST_FAILURES + 1))
  echo "FAIL: sync without --repo or GH_REPO should fail"
fi

finish_test
