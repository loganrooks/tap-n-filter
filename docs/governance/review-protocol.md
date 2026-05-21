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

### Reasoning over acceptance

Automated reviewers see only the snippet they're commenting on. They don't see how the snippet interacts with the rest of the codebase, with downstream tests, with the specs, with ADRs that codify earlier trade-offs, or with the larger architecture. As a result, even technically-correct findings can come with fixes that are narrow, miss the real cause, or break something the reviewer can't see.

The orchestrator responds to every actionable finding with a reasoning trace, not just a fix or an acceptance:

1. **Verify the finding against current code.** Reviewers sometimes flag issues that don't exist any more (rebases, prior commits, stale snippets) or describe an issue that the surrounding code already handles. If the finding doesn't reproduce, the orchestrator replies with the evidence (line numbers, related code) and closes the comment.

2. **Identify the actual root cause, not the surface symptom.** A "fix" the reviewer suggests is often a symptomatic patch. Before applying it, the orchestrator traces the bug to its origin and checks whether the suggested fix addresses the root or just hides the symptom. Patches that quiet a test failure without fixing the underlying bug are a known anti-pattern (see the Phase 3 AccessibilityTreeTests history for a worked example).

3. **Consider the wider blast radius.** Before applying a suggested patch, the orchestrator checks: does the change touch a protocol other types implement? Does it interact with ADR-codified trade-offs? Does it conflict with how the same code is used elsewhere? Are there callers whose assumptions would now be wrong? The narrower the reviewer's framing, the more likely a literal patch breaks something off-screen.

4. **Pick the right scope for the fix.** Sometimes the right fix is the one the reviewer suggested. Sometimes it's a smaller intervention (a doc fix, a comment, a guard). Sometimes it's a larger change (lift a method onto a protocol, refactor a chain of callers). Sometimes the right answer is to defer with an `uncertainty-log` entry because the proper fix requires infrastructure the current build environment lacks.

5. **Document the reasoning in the commit, the PR response, or both.** When the orchestrator pushes back, accepts with modifications, or defers, the reasoning is written down. The next session (with no memory of this conversation) needs to be able to read the commit message, the PR summary comment, or the ADR and understand why each finding was resolved the way it was. Hidden reasoning is the failure mode the audit catches (`CLAUDE.md`).

When a reviewer's suggested fix is wrong but the underlying observation is right, the orchestrator does the work to find the correct fix rather than refusing the finding outright. "Skip this comment" is rarely the right answer for actionable severities.

### CodeRabbit vs Codex: how their outputs differ

Both reviewers analyse the same diff but have different shapes:

| | CodeRabbit | Codex |
|---|---|---|
| Trigger | Automatic on every push | Manual: post `@codex review` |
| Comment style | Inline line-anchored comments with severity tags (critical/major/minor/nit) | Inline + summary report, severity as `P1`/`P2` badges |
| Suggested fixes | Frequently includes a committable diff suggestion | Frequently describes the fix in prose; diff only when small |
| Pre-built rules | Strong library of language-specific lint patterns (force-unwraps, race conditions, formatting). Tends to surface "Swift coding-standards" violations the orchestrator's own self-review missed | Less rule-based, more reasoning-driven; tends to surface architectural and correctness issues (silent-failure paths, missing teardown, unhandled async edges) |
| False-positive rate | Higher on style/format nits; lower on safety issues | Lower overall, but flags fewer items per pass |
| Re-review behaviour | Re-reviews automatically on each new commit | Stays silent unless re-triggered with another `@codex review` |

Practical implications for response:

- **CodeRabbit's diff suggestions are tempting to apply verbatim.** Don't. The orchestrator reads the suggestion, traces it to the root cause (see "Reasoning over acceptance" above), and either applies it, modifies it, or replaces it with the correct fix.
- **Codex's prose-only fixes need translation.** The orchestrator turns each Codex finding into a concrete code change, not a "noted, will think about it" reply.
- **Overlapping findings are higher-confidence.** When both reviewers flag the same line, the underlying issue is almost always real; the disagreement (if any) is about scope.
- **Codex's P1/P2 doesn't map cleanly to CodeRabbit's critical/major/minor.** P1 is closer to "this can produce a wrong result in production" — usually critical or major. P2 is closer to "this is a code-health issue" — usually major or minor. The orchestrator triages each item on its actual impact, not the badge.

When the reviewers' findings are in tension (CodeRabbit suggests fix A, Codex suggests fix B for the same code), the orchestrator reads both rationales, picks the one that addresses the root cause, and posts a comment on the PR explaining the choice. If both fixes have merit but address different aspects, the orchestrator may combine them.

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
