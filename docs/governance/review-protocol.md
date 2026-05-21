# Review Protocol

Every code change in tap-n-filter goes through a pull request. Every PR is reviewed by two automated reviewers — CodeRabbit and Codex — and the orchestrator addresses their findings before merging. This document specifies how the review flow works and what the orchestrator does with the reviewers' output.

## Reviewers

### CodeRabbit

CodeRabbit reviews every PR automatically. Its configuration lives in `.coderabbit.yaml` at the repo root, adapted from the user's reference repo `loganrooks/coderabbit`. The config tunes:

- Which file globs to review.
- Severity thresholds.
- Auto-comment behavior.
- Whether CodeRabbit blocks merge on critical findings (this is enabled in this repo's branch protection).

CodeRabbit posts inline comments on the PR. Each comment has a severity tag (critical / major / minor / nit). The orchestrator addresses critical and major comments before merging; minor and nit comments are addressed when reasonable or acknowledged with a brief reply when not.

### Codex

Codex is invoked by commenting `@codex review` on the PR. The Codex GitHub App is installed at the user level (no repo-level config required). Codex produces a review report as a PR comment, typically structured as:

- An overall assessment.
- Specific findings, often line-referenced.
- Suggested patches where applicable.

The orchestrator triggers Codex by posting `@codex review` as a PR comment after pushing the phase's changes. Codex typically responds within 5–15 minutes.

## When each phase opens a PR

| Phase | PR title | Notes |
|---|---|---|
| -1 | N/A | No code; no PR. The audit and response are committed directly to main as documentation. |
| 0 | `phase-0: repo and tooling init` | The first PR ever opened in this repo. Verifies the tooling pipeline. |
| 1 | `phase-1: capture spike` | Includes `CaptureController`, tests, integration target. |
| 2 | `phase-2: dsp chain` | Includes EffectNode, Graph, EQ, Reverb, preset I/O, ear test harness. |
| 3 | `phase-3: ui and control` | Includes UI, view model, snapshot tests. |
| 4 | `phase-4: polish and release prep` | Includes app icon, signing scripts, DMG packaging, README polish, CHANGELOG, the v0.1.0 tag (created after merge). |

## PR workflow

The orchestrator follows this sequence for every code-producing phase:

1. **Create a feature branch**: `phase-<N>-<short-description>`.
2. **Implement the phase's tasks** per the phase spec.
3. **Write tests** as specified.
4. **Commit** with conventional-commits-style messages (see `coding-standards.md`).
5. **Push** the branch.
6. **Open the PR** via `gh pr create` with the title above and a body summarizing the phase's scope. The PR body includes a link to the phase spec.
7. **Wait for CI** to complete. If CI fails, fix and push again.
8. **Wait for CodeRabbit** to post its review (usually within a few minutes).
9. **Trigger Codex** with `@codex review` as a PR comment.
10. **Wait for Codex** to respond.
11. **Address findings** from both reviewers. Push fixes. CodeRabbit will re-review on each push; Codex needs another `@codex review` if a re-review is wanted.
12. **Run the verification subagent** per `verification-protocol.md`.
13. **On verification PASS and review approval**, merge the PR.

For phases 1–3, the orchestrator self-merges after verification + review pass. For Phase 4, the orchestrator does not merge until the user replies `[ACCEPT]`.

## Addressing review findings

For each finding from CodeRabbit or Codex:

- **Critical or major + clearly correct** → fix immediately and push.
- **Critical or major + the orchestrator disagrees** → reply on the PR comment explaining the disagreement, link to the relevant ADR or spec, ask for a second opinion in the next review pass.
- **Minor or nit + clearly correct** → fix if cheap, otherwise reply acknowledging and noting it's deferred to a follow-up issue.
- **Minor or nit + the orchestrator disagrees** → reply with a one-liner explanation and move on.

If both reviewers raise the same finding, that's a stronger signal than one alone. The orchestrator addresses it unless there's a strong documented reason not to.

If the reviewers contradict each other (CodeRabbit says do X, Codex says do not-X), the orchestrator reads both arguments, makes a call, and documents the call in a brief PR comment and an ADR if the call is substantive.

## When to escalate review disagreements

If the orchestrator and a reviewer disagree on a critical or major finding, and the orchestrator's argument feels weaker than the reviewer's on careful reading, the orchestrator surfaces `[ESCALATION: review-disagreement: PR-<num>]` and asks the user. This is per criterion (b) in `escalation-criteria.md` — High-severity, Low-confidence resolution.

## Re-review after fixes

After pushing fixes:

- CodeRabbit re-reviews automatically on each push.
- Codex needs another `@codex review` comment for a re-review.

The orchestrator triggers Codex re-review after the final round of fixes before requesting verification.

## Branch protection enforcement

The repo's `main` branch is protected with:
- Required status checks: CI.
- Required reviews: 1 approving review.
- No direct pushes; PR-only.
- Linear history (squash or rebase merges).

The "1 approving review" requirement is satisfied by CodeRabbit's approval (when the config grants approval on clean reviews) or by an explicit `gh pr review --approve` command from the orchestrator on PRs that have cleared both reviewers and verification.

The orchestrator does not bypass branch protection. If a PR can't be merged because branch protection is blocking, the orchestrator surfaces `[ESCALATION: branch-protection-blocking]`.

## What the orchestrator does NOT do

- Doesn't dismiss CodeRabbit's reviews to bypass them.
- Doesn't merge with failing CI.
- Doesn't merge with unresolved critical or major findings unless the orchestrator's disagreement is documented and the user has approved the override.
- Doesn't squash or rewrite reviewer comments. They persist on the PR as historical record.

## Self-review

In addition to the automated reviewers, the orchestrator does a self-review pass before opening each PR:

1. Read the diff end-to-end.
2. Check that every file touched is necessary and the change in each is justified.
3. Run the local test suite and confirm it passes.
4. Read the commit messages and check they're informative.
5. Check that any new public surface has docstrings.

The self-review is not a review report — it's just the orchestrator being careful before submitting work for review. Findings from self-review go into the diff before the PR opens.
