#!/usr/bin/env bash
# Pins: the `validate` subcommand catches hand-edit corruption — invalid
# verdict values, missing required fields, schema-version mismatch.
source "$(dirname "$0")/lib.sh"
start_test "test_validate_subcommand"

# Case A — a journal that's fully valid passes.
cat > "$TEST_WORKDIR/good.json" <<'EOF'
{
  "schema_version": "1.0",
  "pr_number": 99,
  "repo": "x/y",
  "last_synced_at": "2026-05-22T00:00:00Z",
  "threads": [
    {
      "id": "PRRT_ok",
      "path": "x.swift", "line": 1,
      "reviewer": "coderabbitai", "reviewer_kind": "bot:agentic-llm",
      "severity": "minor", "category": null,
      "finding_excerpt": "test", "created_at": "2026-05-21T00:00:00Z",
      "resolved": true,
      "verdict": "ACCEPTED", "verdict_commit": "abc1234",
      "verdict_notes": null, "verdict_source": "block",
      "reconsidered_verdict": null
    }
  ]
}
EOF
set +e
python3 "$REVIEW_JOURNAL_PY" validate "$TEST_WORKDIR/good.json" >/dev/null 2>&1
good_ec=$?
set -e
assert_exit_code 0 "$good_ec" "valid journal passes"

# Case B — verdict value is not in the vocabulary.
cat > "$TEST_WORKDIR/bad-verdict.json" <<'EOF'
{
  "schema_version": "1.0",
  "pr_number": 99,
  "repo": "x/y",
  "last_synced_at": "2026-05-22T00:00:00Z",
  "threads": [
    {
      "id": "PRRT_bad",
      "path": "x.swift", "line": 1,
      "reviewer": "coderabbitai", "reviewer_kind": "bot:agentic-llm",
      "severity": null, "category": null,
      "finding_excerpt": "", "created_at": "2026-05-21T00:00:00Z",
      "resolved": true,
      "verdict": "MAYBE", "verdict_commit": null,
      "verdict_notes": null, "verdict_source": "block",
      "reconsidered_verdict": null
    }
  ]
}
EOF
set +e
err=$(python3 "$REVIEW_JOURNAL_PY" validate "$TEST_WORKDIR/bad-verdict.json" 2>&1 >/dev/null)
bad_ec=$?
set -e
if [ "$bad_ec" -eq 0 ]; then
  TEST_FAILURES=$((TEST_FAILURES + 1))
  echo "FAIL: invalid verdict should fail validation"
fi
assert_contains "MAYBE" "$err" "error names the invalid value"

# Case C — missing required field for ACCEPTED verdict (no commit).
cat > "$TEST_WORKDIR/bad-required.json" <<'EOF'
{
  "schema_version": "1.0",
  "pr_number": 99,
  "repo": "x/y",
  "last_synced_at": "2026-05-22T00:00:00Z",
  "threads": [
    {
      "id": "PRRT_nocommit",
      "path": "x.swift", "line": 1,
      "reviewer": "coderabbitai", "reviewer_kind": "bot:agentic-llm",
      "severity": null, "category": null,
      "finding_excerpt": "", "created_at": "2026-05-21T00:00:00Z",
      "resolved": true,
      "verdict": "ACCEPTED", "verdict_commit": null,
      "verdict_notes": null, "verdict_source": "manual",
      "reconsidered_verdict": null
    }
  ]
}
EOF
set +e
err=$(python3 "$REVIEW_JOURNAL_PY" validate "$TEST_WORKDIR/bad-required.json" 2>&1 >/dev/null)
miss_ec=$?
set -e
if [ "$miss_ec" -eq 0 ]; then
  TEST_FAILURES=$((TEST_FAILURES + 1))
  echo "FAIL: missing-required-field should fail validation"
fi
assert_contains "commit" "$err" "error names commit as missing"

# Case D — schema_version absent on a journal that the validator was asked
# to check strictly.
cat > "$TEST_WORKDIR/no-version.json" <<'EOF'
{
  "pr_number": 99,
  "repo": "x/y",
  "last_synced_at": "2026-05-22T00:00:00Z",
  "threads": []
}
EOF
set +e
err=$(python3 "$REVIEW_JOURNAL_PY" validate "$TEST_WORKDIR/no-version.json" 2>&1 >/dev/null)
nv_ec=$?
set -e
if [ "$nv_ec" -eq 0 ]; then
  TEST_FAILURES=$((TEST_FAILURES + 1))
  echo "FAIL: missing schema_version should fail validation"
fi
assert_contains "schema_version" "$err" "error names schema_version"

finish_test
