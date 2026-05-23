#!/usr/bin/env bash
# Thin wrapper: invoke `review_journal.py sync` with passed-through arguments.
# Maintainer-facing entry point. Lives alongside review_journal.py so that
# copying the tools/review-journal/ directory into another repo is a single
# step.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/review_journal.py" sync "$@"
