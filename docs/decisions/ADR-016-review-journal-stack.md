# ADR-016: Review journal — implementation stack and fence syntax

## Status

Accepted

## Context

The repo needs a per-PR review-journal that records, for every reviewer recommendation, what verdict the project reached (accepted, rejected with reason, deferred, obsolete, etc.). The tool has two jobs:

1. **Forward path** — parse a structured "verdict block" from each PR-thread reply, write a normalized JSON record, and surface backfill warnings.
2. **Backfill path** — for historical threads written before the discipline existed, infer a verdict from the reply chain (commit references, ADR references, "obsolete" prose) and emit a triage doc for human confirmation.

Three design questions drove this ADR:

1. **Implementation language.** The tool must be portable enough to copy into other repos with no install ceremony. Candidates: pure `bash` + `jq`, Python (stdlib only), TypeScript / Node, Swift.
2. **Comment-fence syntax.** The discipline relies on a parser anchor in every reply. Candidates: GitHub-flavored fenced code block with an info-string (` ```review-verdict `), a hidden HTML comment (`<!-- review-verdict: ... -->`), a YAML front-matter block, an unmarked structured prefix.
3. **Single tool with subcommands vs. two scripts.** The spec lists `sync-pr.sh` and `extract-pr.sh` separately. They share the GraphQL fetcher, the JSON writer, the config loader.

## Decision

**1. Python 3.8+, stdlib only, invoked through thin shell wrappers.**

The implementation is `tools/review-journal/review_journal.py`. `sync-pr.sh` and `extract-pr.sh` are wrapper scripts that exec `python3 review_journal.py <subcommand>`.

**2. Fenced code block with a `review-verdict` info-string.**

A reply begins with a fence of the form:

````markdown
```review-verdict
verdict: ACCEPTED_MODIFIED
commit: 14b240b
finding_category: source-resolution-correctness
reviewer: chatgpt-codex-connector
notes: PID-first match; bundle fallback kept for relaunch-between-pick-and-start.
```
````

**3. Single Python module, two subcommands.**

`review_journal.py` exposes `sync` and `extract` subcommands behind shell wrappers. Both share the GraphQL fetcher, the fence parser, the config loader, and the JSON writer.

**4. Reviewer behavior is config-driven (pluggable profiles).**

A reviewer is more than a GitHub login. The journal carries, per thread:

- `reviewer` — the GitHub login (`coderabbitai`, `chatgpt-codex-connector`, `copilot-pull-request-reviewer[bot]`, `loganrooks`, etc.)
- `reviewer_kind` — derived from the profile. Conventional values: `bot:agentic-llm`, `bot:static-analyzer`, `bot:author` (dependabot/renovate), `human`.
- `severity` — extracted from the original finding body using the reviewer's `severity_patterns`. The vocabularies differ by bot (CR's Critical / Major / Minor / Nit, Codex's P0..P3, Copilot's High/Medium/Low); the field records whatever the bot writes. Downstream tooling normalizes if needed.

Profiles live in `.review-journal.json` under `reviewer_profiles`. The Python module ships a default catalog for the bots tap-n-filter currently uses (CR, Codex) plus a stub for Copilot review. A maintainer adds a new bot — say, an in-house static-analysis bot or a fresh agentic reviewer — by appending one entry to the config; no Python edit is required.

Each profile carries:

- `kind` (free-form; the conventional values above are recommendations, not enums)
- `display_name` (optional, used in summaries)
- `severity_patterns` — ordered `[{pattern, severity}]`. First match wins; pattern runs against the original finding body.
- `auto_resolve_patterns` — list of regex strings. A match in any comment body triggers `ACCEPTED_MODIFIED` inference. If the regex has a capture group, the first group is treated as the commit sha. This is what makes CR's `✅ Addressed in commit X` auto-resolution understandable to the tool without bot-specific Python code.
- `notes` — free text about the reviewer's quirks.

This design is what lets the tool adapt as the upstream review ecosystem evolves. Adding GitHub Copilot review, swapping CodeRabbit for Greptile or Qodo, or registering a project-local bot (the `AgenticOpsResearch` corpus envisions consumer-owned reviewer roles — see `system-design/01-multi-provider-architecture.md` and `system-design/02-pr-review-taxonomy-and-router.md`) is a config change. The default catalog encodes the today-shape, not a closed world.

## Considered

### Stack alternatives

- **Pure `bash` + `jq`.** Rejected. The fence parser needs multi-line state (extract block → parse `key: value` lines → validate required fields). Doing that in `jq` is awkward; doing it in `bash` requires custom line-by-line code that's hard to keep correct as the format evolves. `jq` is also not always installed on contributor machines, and the script would need to dependency-check it on every run.

- **TypeScript / Node.** Rejected. Adds a `package.json` and a `node_modules/` if any helper is needed. Even with zero deps, the maintainer has to remember to install Node. macOS doesn't ship a stable system Node.

- **Swift.** Rejected. The host repo is Swift, so superficially the closest fit, but a Swift CLI either lives inside the Swift package (drags `tap-n-filter` into the journal's dependency graph) or ships as a `swift script` (which still needs SwiftPM at runtime in other repos). Neither helps portability.

- **Python (stdlib only).** Selected. Python 3 is pre-installed on every macOS 14+ and every modern Linux. The `gh` CLI handles authentication; the script shells out to `gh` for GraphQL. No third-party packages required. Single file copies clean.

### Fence-syntax alternatives

- **HTML comment (`<!-- review-verdict: ... -->`).** Rejected. Invisible to humans reading the PR thread. A reviewer scrolling the thread couldn't tell at a glance what verdict was applied — the visibility is part of the discipline's value, not just a parsing convenience.

- **YAML front-matter block.** Rejected. GitHub doesn't render `---` separators inside a comment specially, so the block would appear as plain text with no syntax cue. The triple-backtick form renders with monospace formatting that visually separates the verdict from the prose.

- **Unmarked key-value prefix (`verdict: X\ncommit: Y\n...`).** Rejected. Brittle. Any reply that happened to begin with `verdict:` would be misparsed. The fence makes the boundary explicit.

- **Fenced block with `review-verdict` info-string.** Selected. Visible to humans, parses with a trivial regex (`r"```review-verdict\n(.*?)\n```"` with `DOTALL`), and the info-string is uncommon enough that false-positive matches are vanishingly unlikely.

### Single tool vs. two scripts

Two physically separate scripts duplicate the GraphQL fetcher, the config loader, and the JSON schema. Folding them into one module means there's one place to fix a bug in the shared path. The wrappers exist so the documented command surface (`sync-pr.sh 7`) reads naturally to a maintainer who isn't thinking about the implementation.

## Consequences

- **Operational dependency surface is `python3` + `gh`.** The tool docs (`tools/review-journal/README.md`) state both as prerequisites. The `gh` CLI must be authenticated; the script doesn't manage credentials.
- **Fence syntax is committed to.** Future schema changes (e.g., a new field or a new verdict value) add to the block format; they don't rename the fence. A v2 format would use a different info-string (e.g., `review-verdict-v2`).
- **The tool installs by copy.** No package, no version pin, no install script — a maintainer drops `tools/review-journal/` and a `.review-journal.json` into another repo and runs it. The README documents the copy steps.
- **CI integration is opt-in.** The Actions workflow snippet lives at `tools/review-journal/install/ci-check.yml`; the maintainer chooses whether to enable it. The journal tool itself does not assume any CI is running.
- **Heuristic inference is best-effort.** The extraction logic is regex-driven and produces a triage doc, not authoritative records. Any inferred verdict requires a human confirmation pass before it counts as the project's position. The `verdict_source` field (`block` / `inferred` / `manual`) preserves the chain of custody.
- **The journal's output shape is the contract for downstream consumers.** Per-PR JSON + `index.json` is intentionally simple. An agentic-ops orchestrator (see the `AgenticOpsResearch` corpus) can read the journal as-is to feed a per-reviewer-kind quality signal, a per-category recurrence map, or a routing-confidence input. Schema changes go through a new ADR; the format ships with `reviewer_kind` and `severity` because both are downstream-load-bearing even if today's manual workflow only uses a subset.
