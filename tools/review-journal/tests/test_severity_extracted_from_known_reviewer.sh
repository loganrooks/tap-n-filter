#!/usr/bin/env bash
# Pins requirement: severity is extracted from the original finding body using
# the per-reviewer profile's severity patterns. CodeRabbit and Codex have
# different severity vocabularies; both round-trip into a normalized field.
source "$(dirname "$0")/lib.sh"
start_test "test_severity_extracted_from_known_reviewer"

write_threads_fixture "$TEST_WORKDIR/threads.json" '[
  {
    "id": "PRRT_cr_major",
    "isResolved": true,
    "isOutdated": false,
    "path": "Sources/A.swift",
    "line": 10,
    "comments": {"nodes": [
      {
        "id": "c1",
        "author": {"login": "coderabbitai"},
        "body": "_🛠️ Refactor suggestion_ | _🟠 Major_ | _⚡ Quick win_\n\n**Reorder imports per coding guidelines.**\n\n...",
        "createdAt": "2026-05-21T20:00:00Z",
        "url": "https://example/pr/1#1"
      },
      {
        "id": "c2",
        "author": {"login": "loganrooks"},
        "body": "```review-verdict\nverdict: REJECTED_BAD_FIT\nreviewer: coderabbitai\nnotes: local convention differs.\n```",
        "createdAt": "2026-05-21T21:00:00Z",
        "url": "https://example/pr/1#2"
      }
    ]}
  },
  {
    "id": "PRRT_codex_p1",
    "isResolved": true,
    "isOutdated": false,
    "path": "Sources/B.swift",
    "line": 20,
    "comments": {"nodes": [
      {
        "id": "c3",
        "author": {"login": "chatgpt-codex-connector"},
        "body": "**P1** — preset load does not reattach the graph after stop().\n\nSee AppViewModel.swift:702...",
        "createdAt": "2026-05-21T20:10:00Z",
        "url": "https://example/pr/1#3"
      },
      {
        "id": "c4",
        "author": {"login": "loganrooks"},
        "body": "```review-verdict\nverdict: ACCEPTED_MODIFIED\ncommit: ddd4444\nreviewer: chatgpt-codex-connector\nnotes: now stops + reattaches.\n```",
        "createdAt": "2026-05-21T21:10:00Z",
        "url": "https://example/pr/1#4"
      }
    ]}
  }
]'

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

"$SYNC_PR" 1 \
  --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" \
  --enforce off >/dev/null 2>&1
ec=$?
assert_exit_code 0 "$ec" "sync exit code"

out_path="$journal_dir/pr-1.json"
sev_cr=$(python3 -c "
import json
d = json.load(open('$out_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_cr_major')
print(t.get('severity'))
")
sev_codex=$(python3 -c "
import json
d = json.load(open('$out_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_codex_p1')
print(t.get('severity'))
")
assert_eq "major" "$sev_cr" "CR major extracted"
assert_eq "P1" "$sev_codex" "Codex P1 extracted"

# Reviewer kind should be populated from the default profiles.
kind_cr=$(python3 -c "
import json
d = json.load(open('$out_path'))
t = next(t for t in d['threads'] if t['id'] == 'PRRT_cr_major')
print(t.get('reviewer_kind'))
")
assert_eq "bot:agentic-llm" "$kind_cr" "default reviewer_kind for CR"

finish_test
