#!/usr/bin/env bash
# Runs every test_*.sh in this directory. Exit non-zero on any failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || { echo "FATAL: failed to cd to $HERE" >&2; exit 2; }

pass=0
fail=0
fail_names=()

for t in test_*.sh; do
  if [ ! -f "$t" ]; then
    continue
  fi
  echo "----- $t -----"
  if bash "$t"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    fail_names+=("$t")
  fi
done

echo
echo "Summary: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  printf 'Failed:\n'
  for n in "${fail_names[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
