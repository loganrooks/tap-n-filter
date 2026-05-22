#!/usr/bin/env bash
# Pins requirement: a repo without `.review-journal.json` defaults to warning mode.
source "$(dirname "$0")/lib.sh"
start_test "test_config_per_repo_default_warning"

# Set up a stand-in repo directory in TEST_WORKDIR. The config file is ABSENT.
fake_repo="$TEST_WORKDIR/fake-repo"
mkdir -p "$fake_repo/docs/governance/review-journal"
# Symlink the small fixture so the script can find it offline.
cp "$TESTS_DIR/fixtures/small-pr.json" "$fake_repo/threads.json"

# Invoke without --enforce flag from the fake-repo directory so the script picks
# up the default. (Config-lookup search starts at $PWD.)
set +e
stderr=$(cd "$fake_repo" && "$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from threads.json 2>&1 >/dev/null)
ec=$?
set -e

# Default should be `warning` per spec:
#   - exits 0
#   - emits BACKFILL NEEDED to stderr
assert_exit_code 0 "$ec" "default mode exit code (warning)"
assert_contains "BACKFILL NEEDED" "$stderr" "default mode warns on stderr"

finish_test
