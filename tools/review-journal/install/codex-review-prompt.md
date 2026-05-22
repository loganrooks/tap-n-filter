# Codex review prompt template

This file is the prompt body passed to `openai/codex-action` by the
`.github/workflows/codex-review.yml` workflow. It is also the seed template
for porting the codex-action setup to other repos.

The workflow injects the PR metadata (number, base/head SHAs, repo) directly
into the prompt at YAML render time. The static portion below describes how
Codex should structure its findings so the review-journal tool consumes them
cleanly.

---

You are reviewing a GitHub pull request. The workflow has already:

- Checked out the PR's merge commit
- Fetched the base ref and PR head into the working tree

You can read the diff with:

```
git diff <BASE_SHA>..<HEAD_SHA>
```

and the commit history of the PR with:

```
git log --oneline <BASE_SHA>..<HEAD_SHA>
```

## Repository conventions

This repo uses a **review-verdict** comment discipline (see
`docs/governance/review-protocol.md`). The maintainer replies to each finding
with a fenced `review-verdict` block stating what they did (accepted as-is,
applied a different patch, deferred, rejected with reason, etc.). Findings
that are specific and actionable are easiest for the maintainer to dispose of.

## Focus areas

Prioritize:

- **Correctness / crash paths** — null derefs, off-by-one, panics, leaks, unsafe casts
- **Concurrency** — data races, missing locks, incorrect actor boundaries,
  ordering assumptions
- **API contracts** — public-surface changes that break callers, type
  signature drift, schema-incompatible changes
- **Edge cases that are absent from tests** — boundary conditions, empty
  inputs, large inputs, failure-mode tests
- **Documentation drift** — code that contradicts adjacent comments / docstrings / specs
- **Security** — secrets in logs, injection surfaces, deserialization
  exposure, missing input validation

De-prioritize:

- Style preferences not enforced by the project's linter or coding-standards doc
- Personal taste in naming unless materially confusing
- Suggestions that conflict with documented project conventions (read the
  relevant ADRs under `docs/decisions/` before flagging anything that looks
  like a deliberate choice)

## Severity ladder

- **P0** — block-merge: would corrupt data, crash the app, expose a secret,
  or violate a hard correctness contract
- **P1** — major: bug, race, broken edge case, missing test for a critical
  path
- **P2** — minor: code-smell, suboptimal pattern, missing test for a
  secondary path
- **P3** — nit: style polish where the linter doesn't cover it

## Output format

Return JSON matching `tools/review-journal/install/codex-review-schema.json`.
Each finding must have a `severity`, `title`, and `body`. Findings tied to a
specific line should include `path` and `line`; findings that are
file-level or PR-level can omit them (they'll be posted as part of the
review summary instead of as inline comments).

When you suggest a fix, give a concrete code sketch in a fenced block — not
a vague directional hint.

If the PR is clean, return an empty `findings` array and a summary that
states what you checked and found unremarkable. A clean review is a real
review; don't invent issues to fill space.
