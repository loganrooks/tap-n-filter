# Shared helpers for review-journal shell tests.
# Each test file `source`s this and uses the assert_* / setup_workdir functions.
# Tests should be runnable individually (`bash test_foo.sh`) and from the
# top-level runner (`bash run-tests.sh`).

set -euo pipefail

# Resolve directories. TESTS_DIR is the directory containing test_*.sh files;
# TOOL_DIR is one level up.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SYNC_PR="$TOOL_DIR/sync-pr.sh"
EXTRACT_PR="$TOOL_DIR/extract-pr.sh"
REVIEW_JOURNAL_PY="$TOOL_DIR/review_journal.py"

# Colored output if stdout is a tty.
if [ -t 1 ]; then
  CRED=$'\033[31m'
  CGRN=$'\033[32m'
  CYLW=$'\033[33m'
  CRST=$'\033[0m'
else
  CRED=""; CGRN=""; CYLW=""; CRST=""
fi

# A test starts by calling `start_test "name"`. The runner uses this for output.
start_test() {
  TEST_NAME="${1:-$(basename "${BASH_SOURCE[1]}" .sh)}"
  TEST_FAILURES=0
  TEST_WORKDIR="$(mktemp -d -t review-journal-test.XXXXXX)"
  trap '_cleanup_workdir' EXIT
}

_cleanup_workdir() {
  if [ -n "${TEST_WORKDIR:-}" ] && [ -d "${TEST_WORKDIR:-}" ]; then
    rm -rf "$TEST_WORKDIR"
  fi
}

# Assert helpers. Each appends to TEST_FAILURES; the test prints PASS/FAIL at end.
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" != "$actual" ]; then
    TEST_FAILURES=$((TEST_FAILURES + 1))
    echo "${CRED}FAIL${CRST}: $TEST_NAME: ${msg:-assert_eq}"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual:   $(printf '%q' "$actual")"
  fi
}

assert_contains() {
  local needle="$1" haystack="$2" msg="${3:-}"
  if ! grep -qF -- "$needle" <<<"$haystack"; then
    TEST_FAILURES=$((TEST_FAILURES + 1))
    echo "${CRED}FAIL${CRST}: $TEST_NAME: ${msg:-assert_contains}"
    echo "  needle:   $needle"
    echo "  haystack (first 400 chars): ${haystack:0:400}"
  fi
}

assert_not_contains() {
  local needle="$1" haystack="$2" msg="${3:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    TEST_FAILURES=$((TEST_FAILURES + 1))
    echo "${CRED}FAIL${CRST}: $TEST_NAME: ${msg:-assert_not_contains}"
    echo "  unexpected needle present: $needle"
  fi
}

assert_exit_code() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" != "$actual" ]; then
    TEST_FAILURES=$((TEST_FAILURES + 1))
    echo "${CRED}FAIL${CRST}: $TEST_NAME: ${msg:-assert_exit_code}"
    echo "  expected exit: $expected"
    echo "  actual exit:   $actual"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  if [ ! -f "$path" ]; then
    TEST_FAILURES=$((TEST_FAILURES + 1))
    echo "${CRED}FAIL${CRST}: $TEST_NAME: ${msg:-assert_file_exists}"
    echo "  missing: $path"
  fi
}

# Pretty-print pass/fail at the end of a test.
finish_test() {
  if [ "${TEST_FAILURES:-0}" -eq 0 ]; then
    echo "${CGRN}PASS${CRST}: $TEST_NAME"
    exit 0
  else
    echo "${CRED}FAIL${CRST}: $TEST_NAME ($TEST_FAILURES failures)"
    exit 1
  fi
}

# Build a minimal raw-threads fixture in $TEST_WORKDIR/threads.json. Threads is
# a JSON array of {id, path, line, isResolved, comments: [{author, body, ...}]}.
# We wrap it in the GraphQL response shape the script expects.
write_threads_fixture() {
  local out_path="$1"
  local threads_json="$2"
  mkdir -p "$(dirname "$out_path")"
  python3 -c "
import json, sys
threads = json.loads(sys.argv[1])
out = {
  'data': {
    'repository': {
      'pullRequest': {
        'reviewThreads': {
          'pageInfo': {'hasNextPage': False, 'endCursor': None},
          'nodes': threads,
        }
      }
    }
  }
}
with open(sys.argv[2], 'w') as f:
  json.dump(out, f)
" "$threads_json" "$out_path"
}
