# Verification Protocol

The verification protocol governs how each phase's gate is evaluated. At the end of every phase, the orchestrator spawns a verification subagent in fresh context. The subagent reads the phase spec and the diff, evaluates against the gate criteria, and returns a structured PASS / FAIL report.

This document specifies the subagent's prompt, the report schema, and the orchestrator's handling of the result.

## When verification runs

Once per phase, after the orchestrator has finished implementing the phase's tasks and before the orchestrator advances `state.json` to `passed`. The orchestrator does not advance any phase without a PASS verification report.

Re-runs happen when verification FAILs: the orchestrator addresses the findings, then re-spawns a fresh verification subagent. There is no limit on re-runs, but a phase that fails verification three times in a row triggers `[ESCALATION: phase-stuck]`.

## What the verification subagent sees

Inputs:

1. The phase spec at `docs/orchestration/phases/<phase>.md`.
2. The diff of the orchestrator's work for the phase. The orchestrator produces this via `git diff main...HEAD` on the phase's feature branch (or equivalent if the working state is not committed yet — though the orchestrator should commit before verification).
3. Any files referenced in the phase spec's gate criteria (e.g., the audit report and audit response for Phase -1; the integration test log for Phase 1; etc.).
4. The relevant spec docs (e.g., `docs/specs/audio-graph.md` for Phase 2).
5. This document (`verification-protocol.md`).
6. The `audit-protocol.md` (for the audit-lite question).

The verification subagent does NOT see:
- The orchestrator's reasoning.
- The conversation log.
- Other phases' work in progress.

## The verification prompt (verbatim)

The orchestrator spawns the subagent with this system prompt:

> You are the verification subagent for tap-n-filter Phase <N>. Your job is to evaluate whether the orchestrator's work for this phase meets the gate criteria in the phase spec. You have no prior context. You read the spec, the diff, and any referenced artifacts.
>
> Your output is a structured verification report following the schema in `docs/governance/verification-protocol.md`. Your verdict is PASS or FAIL.
>
> Apply the gate criteria literally. If a criterion says "verification subagent confirms X" and you cannot confirm X from the evidence provided, return FAIL with a clear statement of what's missing. Do not infer compliance from absence of contradicting evidence.
>
> In addition to the gate criteria, answer this question: "Did this phase's implementation introduce reasoning or assumptions that weren't in the spec? If so, were those additions sound?" Your answer is 1–3 paragraphs. If your answer flags unsound additions, return FAIL even if the literal gate criteria are met.
>
> Be precise about what you saw and what you couldn't see. If the orchestrator's diff lacks a piece of evidence you'd need to confirm a criterion (e.g., a test output log, a screenshot, a commit message), say so explicitly. Do not guess.
>
> Write your report to `docs/audits/verification/phase-<N>.md`. After writing, return your verdict (PASS or FAIL) as the final message.

The placeholder `<N>` is filled in by the orchestrator with the phase number.

## Report schema

The subagent writes a Markdown file with this structure:

```markdown
# Phase <N> Verification

**Verifier**: Claude (verification subagent, cold context)
**Date**: <ISO date>
**Phase**: <N> — <phase name>
**Verdict**: PASS | FAIL

## Gate criteria assessment

<For each numbered gate criterion in the phase spec:>

### Criterion <N>: <verbatim criterion text>

**Status**: Met | Not met | Unable to evaluate

**Evidence**:
<What the verifier saw in the diff / artifacts that supports the status>

<If "Not met":>
**Gap**:
<What's missing or wrong>

<If "Unable to evaluate":>
**Reason**:
<Why the verifier couldn't determine status (e.g., no test log committed, no artifact at the expected path)>

---

## Framing audit-lite

**Question**: Did this phase's implementation introduce reasoning or assumptions that weren't in the spec? If so, were those additions sound?

**Answer**:
<1–3 paragraphs>

## Verdict reasoning

<1–2 paragraphs synthesizing the above. Why PASS or FAIL.>
```

## Orchestrator handling of the report

**On PASS**: the orchestrator updates `state.json` to advance the phase to `passed`, commits the verification report along with the state update, and proceeds to the next phase.

**On FAIL**: the orchestrator reads the report's "Gap" entries and "Unable to evaluate" reasons, addresses each one (either by writing the missing artifact, fixing the underlying issue, or — rarely — disputing the verification with documented reasoning), then re-runs a fresh verification subagent.

The orchestrator does NOT edit the verification report to flip its conclusion. If the orchestrator disputes a FAIL, the dispute is recorded in a separate document (`docs/audits/verification/phase-<N>-dispute.md`) and the user is escalated via `[ESCALATION: verification-disputed]`. This is rare; in most cases, the right move on FAIL is to fix the underlying issue.

## Strict-mode criteria

Some criteria are strict-mode: even if everything else passes, failure here FAILs the phase. Examples from the phase specs:

- Phase 1: "Permission denial is handled gracefully (does not crash, surfaces a clear error)."
- Phase 2: "User has confirmed `[EAR_TEST: PASS]`."
- Phase 4: "User has confirmed `[ACCEPT]`."

The verification subagent treats these like any other criterion: evaluate, mark Met / Not met / Unable to evaluate, contribute to verdict.

## Per-phase verification report locations

- Phase -1: `docs/audits/verification/phase-minus-1.md`
- Phase 0: `docs/audits/verification/phase-0.md`
- Phase 1: `docs/audits/verification/phase-1.md`
- Phase 2: `docs/audits/verification/phase-2.md`
- Phase 3: `docs/audits/verification/phase-3.md`
- Phase 4: `docs/audits/verification/phase-4.md`

Re-runs of a failed verification get suffixes: `phase-2.md` first, `phase-2-rerun-1.md`, `phase-2-rerun-2.md`. The orchestrator points `state.json`'s `verification_report` field to the most recent run on success.

## Combining verification with PR review

PRs are reviewed by CodeRabbit and Codex per `review-protocol.md`. PR review is a different evaluation: code-quality, line-level. Verification is gate-criterion evaluation. Both run for every phase that produces a PR (all phases except possibly Phase -1, which has no code yet).

Sequence:
1. Orchestrator opens PR.
2. CI runs.
3. CodeRabbit reviews automatically. Codex reviews on `@codex review` comment.
4. Orchestrator addresses PR review comments.
5. Orchestrator runs verification subagent.
6. On PASS, orchestrator merges PR and updates `state.json`.

The PR review process and the verification process are independent. A passing verification does not bypass review comments. A clean review does not bypass verification.

## Failure modes

- **Verification returns PASS but criteria are clearly not met.** Indicates a verification failure. The orchestrator re-runs verification with explicit prompt: "On your prior run, you returned PASS but criterion N appears not met because <reason>. Re-evaluate." If second run still incorrectly PASSes, surface `[ESCALATION: verification-misjudgment]`.

- **Verification returns FAIL with vague reasoning.** If the report doesn't specify which criteria failed or what's missing, the orchestrator's only option is to re-run with explicit prompt: "Your prior report was unclear about which criteria failed. Re-run and produce a per-criterion assessment per the schema."

- **Verification produces a PASS that contradicts the audit-lite answer.** If the audit-lite flags unsound additions but the verdict is PASS, the orchestrator treats the verdict as FAIL anyway (per the prompt's instruction). The audit-lite is a strict-mode check.

## Idempotence

Running verification on the same diff twice should produce equivalent verdicts (PASS still passes, FAIL still fails). If two verification runs disagree, the orchestrator runs a third as tiebreaker and documents the disagreement in the phase's verification directory.
