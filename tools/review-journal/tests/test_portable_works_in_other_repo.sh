#!/usr/bin/env bash
# Pins requirement: the tool is portable — copying tools/review-journal/ into a
# different working directory + a stub config + a fixture yields a working sync.
source "$(dirname "$0")/lib.sh"
start_test "test_portable_works_in_other_repo"

# Construct a clean target directory not under the tap-n-filter source tree.
other_repo="$TEST_WORKDIR/other-repo"
mkdir -p "$other_repo"
# Copy the tool directory (sans tests/) into the other repo.
mkdir -p "$other_repo/tools/review-journal"
cp "$TOOL_DIR/sync-pr.sh" "$other_repo/tools/review-journal/"
cp "$TOOL_DIR/extract-pr.sh" "$other_repo/tools/review-journal/"
cp "$TOOL_DIR/review_journal.py" "$other_repo/tools/review-journal/"

# Stub a per-repo config (custom journal_dir + named reviewers).
cat > "$other_repo/.review-journal.json" <<'EOF'
{
  "enforcement_mode": "warning",
  "reviewers": ["coderabbitai", "chatgpt-codex-connector"],
  "journal_dir": "docs/journal"
}
EOF

# Bring a captured fixture.
cp "$TESTS_DIR/fixtures/small-pr.json" "$other_repo/threads.json"

# Run from the other_repo. The tool should resolve the config relative to PWD
# and write the journal to docs/journal/pr-N.json per the config.
sync_exit=0
( cd "$other_repo" && bash tools/review-journal/sync-pr.sh 42 \
    --repo other/repo \
    --threads-from threads.json >/dev/null 2>&1 ) || sync_exit=$?
assert_exit_code "0" "$sync_exit" "portable sync should succeed in the foreign repo"

journal_path="$other_repo/docs/journal/pr-42.json"
assert_file_exists "$journal_path" "journal lands at configured path"

# Verify the file has the expected schema.
threads=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['threads']))" "$journal_path")
assert_eq "3" "$threads" "all three threads carried over"

finish_test
