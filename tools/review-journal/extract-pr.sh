#!/usr/bin/env bash
# Thin wrapper: invoke `review_journal.py extract` with passed-through args.
# Extract is sync + inference + backfill markdown for threads missing a block.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/review_journal.py" extract "$@"
