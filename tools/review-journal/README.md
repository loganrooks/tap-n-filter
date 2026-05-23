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
      "aliases": ["my-house-analyzer", "house-analyzer-old[bot]"],
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
| `aliases`               | `[string]`     | Additional logins that map to this profile. Handles bot renames, marketplace-vs-app suffix variants, and the same human posting under multiple identities. |
| `severity_patterns`     | `[{pattern,severity}]` | Ordered list; first match wins. `pattern` is a Python regex run against the original finding body. `severity` is the value stored on the thread record. |
| `auto_resolve_patterns` | `[string]`     | Convenience shorthand for the common case where a bot self-closes a thread with `<some prose> commit X`. The match emits `ACCEPTED_MODIFIED` with the first capture group as the commit sha. For richer rules (other verdicts, ref captures, reviewer-scoping) use `inference_rules` instead. |
| `inference_rules`       | `[rule]`       | Profile-scoped inference rules; see below. Run before global rules. |
| `notes`                 | string         | Free text. |

The default profiles cover:

- **`coderabbitai`** — Critical / Major / Minor / Nit severity (`🔴`/`🟠`/`🟡`/`⚪`); auto-resolve via `✅ Addressed in commit X` (and `Addressed in commits A to B`, capturing B).
- **`chatgpt-codex-connector`** — Codex P0 / P1 / P2 / P3 severity tiers. Codex doesn't auto-resolve threads, so `auto_resolve_patterns` is empty; verdicts come from the maintainer's reply.
- **`copilot-pull-request-reviewer[bot]`** — High / Medium / Low severity. Stub; refine once GH Copilot review is enabled and patterns are observed in practice.

When `reviewer_profiles` is present in the config, entries deep-replace the
defaults for the same login. Unknown logins (not in any profile's `aliases`
either) fall back to a `human` profile with no severity extraction or
auto-resolution.

### Inference rules (the generic engine)

`auto_resolve_patterns` covers one common case (a bot self-closes with a
commit). For anything else — `DEFERRED` via an ADR reference, `DUPLICATE`
via a thread cite, `REJECTED_REGRESSION` via "reverted in X" — register an
inference rule directly.

A rule is a dict:

```json
{
  "inference_rules": [
    {
      "name": "duplicate-of-thread",
      "pattern": "(?i)duplicate of\\s+(PRRT_[A-Za-z0-9_-]+)",
      "match_against": "all_bodies",
      "verdict": "DUPLICATE",
      "ref_group": 1,
      "notes_template": "Inferred duplicate of {ref}."
    },
    {
      "name": "regression-reverted",
      "pattern": "(?i)reverted in\\s+([0-9a-f]{7,40})",
      "verdict": "REJECTED_REGRESSION",
      "commit_group": 1,
      "notes_template": "Inferred regression; reverted in {commit}."
    }
  ]
}
```

Rule fields:

| Field                  | Type     | Purpose |
|------------------------|----------|---------|
| `name`                 | string   | Human label for the rule itself; identifies it in logs and config diffs. The text that appears in a thread's `verdict_notes` after inference is controlled by `notes_template`, not by `name`. |
| `pattern`              | string   | Python regex. Use inline `(?i)` for case-insensitivity (default-ON for the shipped rules but explicit in your custom rules). |
| `match_against`        | string   | `all_bodies` (default), `original_only`, or `reply_only`. |
| `verdict`              | string   | Any of the 8 verdict values. |
| `commit_group`         | int      | Capture-group number whose match is recorded as `verdict_commit` and substituted as `{commit}` in `notes_template`. |
| `ref_group`            | int      | Capture-group number for non-commit references (ADRs, U-logs, thread IDs). Substituted as `{ref}` in `notes_template`. |
| `notes_template`       | string   | Free-form; supports `{commit}`, `{ref}`, `{match}` placeholders. |
| `applies_to_reviewer`  | string   | If set, the rule only fires when the thread's reviewer matches this login (or one of its aliases). Omit for global rules. |

Rule precedence (highest first):

1. Profile `inference_rules`
2. Profile `auto_resolve_patterns` (sugar for the common case)
3. Repo-level `inference_rules` from `.review-journal.json`
4. The shipped `DEFAULT_INFERENCE_RULES` (cr-range, fixed-in, deferred-per-ADR, obsolete, duplicate, etc.)

A custom rule with the same name as a default rule does NOT replace the default — it adds to it, and the higher-precedence rule simply fires first.

### Per-thread `extras` map

Each thread record has an `extras: {}` map that downstream consumers can write
into without participating in the sync flow. Use cases:

- An agentic-devops router attaches `risk_surface`, `effort_estimate`, or
  `router_confidence`.
- A metrics consumer attaches `time_to_resolution_hours`,
  `commits_per_thread`.
- A learning system attaches `embeddings_id`, `cluster_id`, or
  `learned_category`.

The map is preserved across `sync-pr` / `extract-pr` runs; the tool never
reads or overwrites it. The keys are entirely up to the consumer.

### `verdict_history` provenance log

Each thread record carries an append-only `verdict_history: []` log capturing
state transitions. A new entry is appended whenever `verdict_source` or
`verdict` changes (e.g., promotion from `inferred` to `manual`, or a
re-inference that yields a different verdict). Entries are dicts:

```json
{"at": "2026-05-22T18:00:00Z", "source": "inferred", "verdict": "ACCEPTED_MODIFIED", "by": "tool"}
```

`verdict_refs: []` complements `verdict_commit` for cases where a disposition
references multiple commits, ADRs, U-log entries, or other threads.

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

### `review_journal.py validate <path>`

Validates a journal file against the schema. Checks:

- `schema_version` is present and matches the supported major (`1.x`).
- All required top-level keys are present.
- Every thread has the required fields.
- Every `verdict` is in the canonical 8-value vocabulary.
- `ACCEPTED` / `ACCEPTED_MODIFIED` / `OBSOLETE` entries have a `verdict_commit`.
- `REJECTED_*` / `DEFERRED` entries have `verdict_notes`.
- `extras` is a dict if present; `verdict_history` is a list if present.

Exit 0 on success, 1 on schema violation, 2 on argument or I/O error. Designed
to be safe to run in CI on every push (in addition to `sync-pr.sh`) so
hand-edits to journal files don't silently corrupt them.

---

## Output schema

Schema version `1.0`. Future additive fields are minor-bumps; on-disk-incompatible
changes are major-bumps with a migration path.

`pr-{N}.json`:

```json
{
  "schema_version": "1.0",
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
      "outdated": false,
      "verdict": "REJECTED_BAD_FIT",
      "verdict_commit": "e083b9d",
      "verdict_refs": [],
      "verdict_notes": "Generic suggestion from CR's training data that conflicts...",
      "verdict_source": "block",
      "reconsidered_verdict": null,
      "verdict_history": [],
      "extras": {}
    }
  ]
}
```

`index.json`:

```json
{
  "schema_version": "1.0",
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

25 tests covering: block parsing (5), sync schema (4), inference (3),
portability (1), config (1), PR #7 acceptance (1), profile flexibility (2),
extensibility (4: schema_version, aliases, rules engine, validate),
provenance (1: verdict_history), and robustness (4: edge cases, missing
authors, outdated threads, extras pass-through). Tests use captured fixtures
and golden expected outputs; no network.

## Robustness notes

Several edge cases the tool handles without crashing:

- **Missing comment author** (deleted user, ghost account, app uninstalled mid-review) — thread is recorded with `reviewer: "unknown"`, no profile lookup is attempted.
- **Empty or null comment body** — thread is recorded; the finding excerpt is the empty string.
- **Thread with zero comments** — recorded with all body-derived fields null.
- **Quoted or whitespace-padded block values** (`verdict: "ACCEPTED"`, `commit: abc1234`) — unquoted and trimmed.
- **Multi-paragraph notes in a block** — continuation lines after `notes:` are captured (including blank lines preserving paragraph structure).
- **Malformed regex in a custom rule** — the rule is skipped with a stderr warning; the rest of the inference continues.
- **Invalid `verdict` value in a custom rule** — same: skip with warning.
- **Concurrent invocations** — atomic write (temp file + `os.replace`) prevents truncation; the journal file never appears half-written.
- **GraphQL pagination** — `hasNextPage` is honored; PRs with >100 threads paginate correctly.
- **Outdated threads** (`isOutdated: true`) — recorded with `outdated: true` so downstream tools can distinguish a force-pushed-away resolution from a normal one.
