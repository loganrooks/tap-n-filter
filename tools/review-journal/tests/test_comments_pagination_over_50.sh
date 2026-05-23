#!/usr/bin/env bash
# Pins fix D (Codex #4 + #12, PRRT_kwDOSjmLjM6EPXgU / EPfpj):
# A thread with more than 50 comments must have its replies fully parsed —
# the verdict block could be in the 51st comment. The tool must not silently
# drop later replies.
#
# Test approach: synthesize a thread with 60 comments, where the verdict
# block is in comment #58. After sync, the verdict should be captured.
source "$(dirname "$0")/lib.sh"
start_test "test_comments_pagination_over_50"

# Build a 60-comment thread programmatically.
python3 - "$TEST_WORKDIR/threads.json" <<'PY'
import json, sys
out = sys.argv[1]
comments = []
for i in range(57):
    comments.append({
        "id": f"c{i:03d}",
        "author": {"login": "coderabbitai" if i == 0 else "loganrooks"},
        "body": "Real-looking long discussion message #{}".format(i),
        "createdAt": f"2026-05-21T20:{i:02d}:00Z",
        "url": f"https://example/{i}"
    })
# Comment #57 (the 58th, 1-indexed) contains the verdict block.
comments.append({
    "id": "c057",
    "author": {"login": "loganrooks"},
    "body": "```review-verdict\nverdict: ACCEPTED\ncommit: 5151515\nreviewer: coderabbitai\nnotes: late but landed.\n```",
    "createdAt": "2026-05-21T20:57:00Z",
    "url": "https://example/57"
})
# Two more trailing messages to push the verdict past the 50-comment boundary.
for i in (58, 59):
    comments.append({
        "id": f"c{i:03d}",
        "author": {"login": "loganrooks"},
        "body": f"Trailing follow-up #{i}",
        "createdAt": f"2026-05-21T20:{i:02d}:00Z",
        "url": f"https://example/{i}"
    })

payload = {
    "data": {"repository": {"pullRequest": {"reviewThreads": {
        "pageInfo": {"hasNextPage": False, "endCursor": None},
        "nodes": [
            {
                "id": "PRRT_long_thread",
                "isResolved": True, "isOutdated": False,
                "path": "src/x.rs", "line": 1,
                "comments": {"nodes": comments}
            }
        ]
    }}}}
}
with open(out, "w") as f:
    json.dump(payload, f)
PY

journal_dir="$TEST_WORKDIR/journal"
mkdir -p "$journal_dir"

"$SYNC_PR" 1 --repo test/repo \
  --threads-from "$TEST_WORKDIR/threads.json" \
  --journal-dir "$journal_dir" --enforce off >/dev/null 2>&1

verdict=$(python3 -c "import json; print(json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('verdict') or '')")
commit=$(python3 -c "import json; print(json.load(open('$journal_dir/pr-1.json'))['threads'][0].get('verdict_commit') or '')")

assert_eq "ACCEPTED" "$verdict" "verdict from comment #58 captured (past 50)"
assert_eq "5151515" "$commit" "commit from comment #58 captured"

finish_test
