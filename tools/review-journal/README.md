# review-journal

A per-PR journal that records every reviewer recommendation and the project's
verdict on it. Designed to work with any GitHub-app reviewer — CodeRabbit,
Codex (via `chatgpt-codex-connector`), GitHub Copilot review, Greptile, Qodo,
or an in-house bot — by treating reviewer behaviour as **config**, not code.

The tool lives in tap-n-filter as governance infrastructure; it is portable by
design and meant to drop into any repo where reviewer findings need to be
auditable across PR threads.

---

## What it does

For each PR, the tool produces `docs/governance/review-journal/pr-{N}.json`
listing every review thread with:

- `id`, `path`, `line`, `reviewer`, `reviewer_kind`, `severity`, `category`
- `finding_excerpt` (first 300 chars of the original finding)
- `created_at`, `resolved`
- `verdict` (`ACCEPTED` / `ACCEPTED_MODIFIED` / `DEFERRED` / `REJECTED_FALSE_POSITIVE` / `REJECTED_BAD_FIT` / `REJECTED_REGRESSION` / `OBSOLETE` / `DUPLICATE`)
- `verdict_commit`, `verdict_notes`
- `verdict_source` — `block` (parsed from a structured `review-verdict` comment), `inferred` (regex-derived from history), or `manual` (human-confirmed)
- `reconsidered_verdict` — optional revision block

Per repo, an `index.json` summarises every journal entry. The tool is one
Python module + two shell wrappers, depending only on `python3` and `gh`.

---

## Why this exists

This started as a local fix for a workflow problem: the tap-n-filter project
uses CodeRabbit (in trial) and Codex for PR review, and rejecting a reviewer's
suggestion (for example because it conflicts with a local convention CR's
training data doesn't know about) leaves no durable record of *why*. The
review-protocol's "Reasoning over acceptance" principle (see
`docs/governance/review-protocol.md`) prescribes the discipline; this tool
mechanises it.

It is built to outlive the specific bots that exist today. Reviewers come and
go: CR may stay or get swapped for Greptile; GitHub Copilot's PR review may or
may not become viable; project-local agents (see
`../../docs/decisions/ADR-016-review-journal-stack.md` for the broader agentic
context) may add themselves to the mix. The journal records dispositions in a
shape that downstream agentic-devops tooling can read; adding a new reviewer
is a config change.

---

## The verdict-block discipline

Every reply on a review thread starts with a fenced block:

````markdown
```review-verdict
verdict: ACCEPTED_MODIFIED
commit: 14b240b
finding_category: source-resolution-correctness
reviewer: chatgpt-codex-connector
notes: PID-first match; bundle fallback kept for relaunch-between-pick-and-start.
```
````

Field rules:

- `verdict` — always required
- `commit` — required for `ACCEPTED`, `ACCEPTED_MODIFIED`, `OBSOLETE`
- `notes` — required for any `REJECTED_*` or `DEFERRED`
- `reviewer` — optional; auto-derived from the thread's first author when absent
- `finding_category` — free-form (e.g. `style/import-ordering`,
  `lifecycle/preset-reattach`)

A later reply can supersede an earlier verdict with a `review-verdict-reconsidered`
block; the tool records both with timestamps.

---

## Quick start (in this repo)

```bash
# Sync the current verdict state (parses existing blocks; does not infer).
bash tools/review-journal/sync-pr.sh 7

# Backfill verdicts for threads that pre-date the discipline.
bash tools/review-journal/extract-pr.sh 7
```

The first writes `docs/governance/review-journal/pr-7.json` and
`docs/governance/review-journal/index.json`. The second additionally infers
verdicts from common auto-resolution prose ("Addressed in commit `<sha>`",
"per ADR-NNN", "deferred", "obsolete", "duplicate") and emits a
`pr-7-backfill.md` listing inferred entries with confirmation checkboxes.

Promote inferred entries to `manual` once you've confirmed them:

```bash
# Hand-edit pr-7.json to set verdict_source: "manual" on confirmed entries.
# Re-run sync; manual entries are preserved across re-runs.
bash tools/review-journal/sync-pr.sh 7
```

---

## Portability — installing in another repo

Drop the directory and a config file:

```bash
# 1. Copy the tool into another repo.
cp -r tap-n-filter/tools/review-journal/ otherrepo/tools/review-journal/

# 2. Create a minimal .review-journal.json at the other repo's root.
cat > otherrepo/.review-journal.json <<'EOF'
{
  "enforcement_mode": "warning",
  "reviewers": ["coderabbitai", "chatgpt-codex-connector"],
  "journal_dir": "docs/governance/review-journal"
}
EOF

# 3. Run.
cd otherrepo && bash tools/review-journal/sync-pr.sh 42 --repo owner/otherrepo
```

That's it — no package install, no submodule. The tool runs against any repo
where `gh` is authenticated and Python 3.8+ is available.

To enable CI gating, copy the workflow snippet:

```bash
cp tools/review-journal/install/ci-check.yml .github/workflows/review-journal.yml
```

---

## Configuration (`.review-journal.json`)

All keys are optional. Defaults shown:

```json
{
  "enforcement_mode": "warning",
  "reviewers": ["coderabbitai", "chatgpt-codex-connector"],
  "categories": [],
  "journal_dir": "docs/governance/review-journal",
  "reviewer_profiles": {}
}
```

- `enforcement_mode` — `off` | `warning` | `strict`
  - `off`: never warn, exit 0 even if backfill needed
  - `warning` (default): log to stderr, exit 0 — CI-friendly
  - `strict`: exit non-zero if any resolved thread lacks a verdict block
- `reviewers` — list of bot logins to flag in the journal. Used by the
  `BACKFILL NEEDED` / `RESOLVE NEEDED` reporters. Human reviewers are still
  recorded; this list controls whose absent-verdict-block is treated as a
  policy violation.
- `categories` — auto-complete hints for `finding_category` values
- `journal_dir` — where pr-N.json files land, relative to the config's
  directory
- `reviewer_profiles` — see below

### Reviewer profiles (multi-bot support)

The tool ships sensible defaults for `coderabbitai` and
`chatgpt-codex-connector`, plus a stub for `copilot-pull-request-reviewer[bot]`.
You can override any of them, or register a new reviewer entirely, in
`.review-journal.json`:

```json
{
  "reviewer_profiles": {
    "my-house-static-analyzer[bot]": {
      "kind": "bot:static-analyzer",
      "display_name": "House Analyzer",
      "severity_patterns": [
        {"pattern": "(?i)\\b(CRITICAL|SEV0)\\b", "severity": "critical"},
        {"pattern": "(?i)\\b(WARN|SEV1)\\b", "severity": "warning"}
      ],
      "auto_resolve_patterns": [
        "(?i)House auto-closed in commit ([0-9a-f]{7,40})"
      ],
      "notes": "Internal pre-merge analyzer; closes its own threads when the next pipeline run passes."
    }
  }
}
```

Profile fields:

| Field                   | Type           | Purpose |
|-------------------------|----------------|---------|
| `kind`                  | string         | Free-form taxonomy. Conventional values: `bot:agentic-llm`, `bot:static-analyzer`, `bot:author`, `human`. Stored on each thread record as `reviewer_kind`. |
| `display_name`          | string         | Optional; shown in summaries. |
| `severity_patterns`     | `[{pattern,severity}]` | Ordered list; first match wins. `pattern` is a Python regex run against the original finding body. `severity` is the value stored on the thread record. |
| `auto_resolve_patterns` | `[string]`     | List of regexes. A match in any comment body triggers `ACCEPTED_MODIFIED` inference. First capture group (if present) is treated as the commit sha. |
| `notes`                 | string         | Free text. |

The default profiles cover:

- **`coderabbitai`** — Critical / Major / Minor / Nit severity (`🔴`/`🟠`/`🟡`/`⚪`); auto-resolve via `✅ Addressed in commit X` (and `Addressed in commits A to B`, capturing B).
- **`chatgpt-codex-connector`** — Codex P0 / P1 / P2 / P3 severity tiers. Codex doesn't auto-resolve threads, so `auto_resolve_patterns` is empty; verdicts come from the maintainer's reply.
- **`copilot-pull-request-reviewer[bot]`** — High / Medium / Low severity. Stub; refine once GH Copilot review is enabled and patterns are observed in practice.

When `reviewer_profiles` is present in the config, entries deep-replace the
defaults for the same login. Unknown logins fall back to a `human` profile
with no severity extraction or auto-resolution.

---

## CLI reference

### `sync-pr.sh <PR_NUMBER>`

Fetch threads, parse any `review-verdict` blocks, write the journal.

```
--repo OWNER/REPO            Required (or set via `gh repo set-default`).
--threads-from PATH          Offline mode: load raw GraphQL response from a file.
--journal-dir DIR            Override the configured journal directory.
--enforce off|warning|strict Override the configured enforcement mode.
--summary                    Print a per-reviewer summary to stdout.
```

Exit codes:

| Code | Meaning |
|------|---------|
| 0    | success (or strict-mode success with no violations) |
| 1    | strict-mode: at least one resolved thread lacks a verdict block, or at least one unresolved thread has one |
| 2    | argument or config error |

### `extract-pr.sh <PR_NUMBER>`

Same arguments as `sync-pr.sh`, plus:

```
--accept-inferred            Reserved — see "Inferred → manual" below.
```

Writes the same `pr-N.json` plus a `pr-N-backfill.md` triage document listing
threads where the verdict was inferred. Each entry has a `- [ ]` checkbox for
the maintainer to confirm.

### `review_journal.py parse-block`

Reads a single comment body from stdin; emits the parsed verdict block as JSON
or exits non-zero with a diagnostic. Used by the test suite; useful for
ad-hoc validation.

```
--all   Return ALL blocks in the body (including any RECONSIDERED block) as a JSON array.
```

---

## Output schema

`pr-{N}.json`:

```json
{
  "pr_number": 7,
  "repo": "loganrooks/tap-n-filter",
  "last_synced_at": "2026-05-22T...",
  "threads": [
    {
      "id": "PRRT_...",
      "path": "Sources/UI/PresetMenu.swift",
      "line": 5,
      "reviewer": "coderabbitai",
      "reviewer_kind": "bot:agentic-llm",
      "severity": "major",
      "category": "style/import-ordering",
      "finding_excerpt": "_🛠️ Refactor suggestion_ | _🟠 Major_ ...",
      "created_at": "2026-05-21T23:51:53Z",
      "resolved": true,
      "verdict": "REJECTED_BAD_FIT",
      "verdict_commit": "e083b9d",
      "verdict_notes": "Generic suggestion from CR's training data that conflicts...",
      "verdict_source": "block",
      "reconsidered_verdict": null
    }
  ]
}
```

`index.json`:

```json
{
  "generated_at": "2026-05-22T...",
  "entries": [
    {"pr_number": 7, "repo": "loganrooks/tap-n-filter", "last_synced_at": "...", "thread_count": 47, "file": "pr-7.json"}
  ]
}
```

---

## Inferred → manual workflow

Inference is best-effort. Any inferred entry should be confirmed before the
journal is treated as authoritative for that thread.

```
sync-pr.sh 7         # writes block verdicts; flags backfill-needed threads
extract-pr.sh 7      # adds inferred verdicts + writes pr-7-backfill.md
# (maintainer reads pr-7-backfill.md, hand-edits pr-7.json)
sync-pr.sh 7         # re-sync; manual entries are preserved
```

Manual entries always win on re-sync — the tool merges them in on top of the
freshly-derived records. The only way an inferred entry becomes block is for
the maintainer to actually go post a verdict block on the thread.

---

## Integration with larger systems

The journal's output shape is intentionally simple JSON. Downstream agentic
systems can consume it as:

- A **quality signal** per reviewer: count `REJECTED_BAD_FIT` verdicts to
  measure how often a bot's training data misfires against this codebase.
- A **category recurrence map**: which findings keep coming back across PRs
  → candidates for codifying as project-wide checks or for adding to bot
  configuration (e.g., CodeRabbit `learnings`).
- A **routing-confidence input** for a multi-reviewer router: which reviewer
  catches what kinds of issues here, weighted by accept-rate.

The `reviewer_kind` and `severity` fields are designed for these downstream
consumers even when the immediate workflow only uses a subset. See
`docs/decisions/ADR-016-review-journal-stack.md` for the design rationale.

---

## Troubleshooting

**`gh api graphql failed`** — confirm `gh auth status`; the token needs `repo`
scope for private repos and `read:org` for org-level threads.

**Threads appear with `reviewer: unknown`** — the original comment was deleted
or made by a ghost user. The thread is still recorded; the reviewer column is
just stamped `unknown`.

**A custom severity pattern matches everything** — Python regex is greedy by
default. Anchor with `\b` boundaries and test against a real finding body
before deploying. The default profiles' patterns use `\b...\b` extensively as
reference.

**The same reviewer appears under multiple logins** — GitHub Apps post as
`<name>[bot]`, but a human can also use `<name>`. Register both logins as
profiles if they should be treated as the same reviewer kind.

---

## Tests

```bash
bash tools/review-journal/tests/run-tests.sh
```

16 tests covering: block parsing (5), sync schema (4), inference (3),
portability (1), config (1), PR #7 acceptance (1), profile flexibility (2).
Tests use captured fixtures and golden expected outputs; no network.
