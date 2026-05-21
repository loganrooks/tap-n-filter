# Orchestration plan

The master plan for building tap-n-filter. The orchestrator reads this file at the start of each session and follows the structure described below.

## Overview

tap-n-filter is built in six phases, numbered `-1` through `4`. Each phase has its own spec under `phases/`. Phases run sequentially. State is persisted in `state.json`. Decisions made during build are logged under `../decisions/`. Audit reports land under `../audits/`.

The build is performed by a Claude Code session running under `/goal`. That session is the orchestrator. The orchestrator spawns subagents for verification and for the framing audit. Pull requests are reviewed by CodeRabbit (automatic) and Codex (triggered by `@codex review` in PR comments).

Two phases require human input: Phase 2 (ear test) and Phase 4 (acceptance). Every other gate is agent-evaluated.

## Phase summary

| # | Name | Purpose | Gate type |
|---|---|---|---|
| -1 | Framing Audit | Cold review of the design bundle before any code is written | Audit + audit response |
| 0 | Repo and Tooling Init | Bootstrap the GitHub repo, CI, review apps, signing | Verification subagent |
| 1 | Capture Spike | Get audio from one selected app routed through an AVAudioEngine pass-through to default output | Verification subagent |
| 2 | DSP Chain | EQ + Reverb + wet/dry mixing, with the EffectNode protocol implemented | Verification + **ear test** |
| 3 | UI and Control | MenuBarExtra UI, source picker, effect chain editor, preset save/load | Verification subagent |
| 4 | Polish and Release Prep | Signing, notarization, packaging, README polish, v0.1.0 tag | Verification + **acceptance** |

Each phase's full spec is under `phases/`. The orchestrator reads the relevant phase spec at the start of every phase.

## Agent topology

```
        ┌─────────────────────────────┐
        │   Orchestrator (main)       │
        │   Claude Code under /goal   │
        └──────────────┬──────────────┘
                       │
       ┌───────────────┼───────────────┐
       │               │               │
       ▼               ▼               ▼
  Framing       Verification      PR review:
  auditor       subagent          CodeRabbit
  (Phase -1)    (every phase)     + Codex
       │
       ▼
  Audit-response
  agent
```

- **Orchestrator** — main session. Reads specs, writes code, opens PRs, updates `state.json`.
- **Framing auditor** — cold-context subagent run once at Phase -1. Reads the entire design bundle and `audits/design-rationale.md`. Returns structured findings. See `../governance/audit-protocol.md`.
- **Audit-response agent** — separate cold-context subagent that processes the auditor's findings and produces responses per `../governance/audit-response-protocol.md`. Escalates to user per `../governance/escalation-criteria.md`.
- **Verification subagent** — spawned at each phase gate. Reads the phase spec and the diff, returns PASS or FAIL with reasoning, plus the framing-audit-lite question response. See `../governance/verification-protocol.md`.
- **PR review** — CodeRabbit and Codex review every PR. See `../governance/review-protocol.md`.

All subagents are fresh-context. They do not see the orchestrator's reasoning. They see only their inputs and produce a structured report.

## State management

`state.json` is the canonical source of truth for project status. Its schema is documented in the file itself. Every state transition is committed with a message of the form `state: <phase> -> <new_status> (<short reason>)`.

The orchestrator never modifies `state.json` without a corresponding verification report or audit response. The orchestrator never moves a phase to `passed` without verification PASS.

## Decision logging

Three logs under `../decisions/`:

1. **ADRs** — discrete decision documents. One file per substantive architectural decision. Format follows the convention described in `../decisions/README.md`. The orchestrator writes a new ADR whenever it makes a non-trivial architectural choice during build, with a brief context, the decision, alternatives considered, and consequences.

2. **Dissent log** — `../decisions/dissent-log.md`. Append-only. One entry per option-between-options choice during build. The point is to make rejected alternatives visible.

3. **Uncertainty log** — `../decisions/uncertainty-log.md`. Append-only. One entry per open question discovered during build. Each entry records what triggered it, current best guess, what would resolve it, and a trigger condition for revisiting.

These logs are inputs to the per-phase audit-lite question. They are also the place reviewers (CodeRabbit, Codex, future contributors) go to understand why a thing is the way it is.

## Halt markers

The orchestrator uses precise halt markers in transcript so the `/goal` evaluator can read state. The markers are documented in `CLAUDE.md` at repo root. Use them exactly as specified. The evaluator and the user both rely on their literal form.

## Failure modes the orchestrator must avoid

1. **Skipping verification.** Every phase gate runs the verification subagent. No exceptions.
2. **Skipping Phase -1.** The framing audit happens first. It is the cheapest place to catch design errors.
3. **Pushing to main.** Every change goes through a PR. Phases -1 through 3 self-merge after PR review and verification. Phase 4 waits for human `[ACCEPT]`.
4. **Hidden reasoning.** Decisions go to ADRs, dissent log, or uncertainty log. Burying reasoning in commit messages is a failure mode the audits look for.
5. **Drifting from spec.** If the spec is wrong, write an ADR documenting the change. Do not silently deviate.
6. **Rubber-stamping a verification.** If verification returns FAIL, fix the underlying issue and re-run. Do not edit the verification report to flip its conclusion.
7. **Re-prompting the auditor or verifier after a FAIL.** They get one chance per phase to review the work. If they FAIL the phase, the orchestrator addresses the findings and produces a new diff for a fresh verification run.

## What "complete" means

The build is complete when all five conditions in the `/goal` condition (see `../../goal-prompt.md`) are met:

1. All phases show `passed` in `state.json`.
2. `release_candidate_path` in `state.json` points to a signed, notarized release artifact.
3. The transcript contains `[EAR_TEST: PASS]` from the user.
4. The transcript contains `[ACCEPT]` from the user.
5. The main branch on GitHub has a `v0.1.0` release tag.

The `/goal` evaluator (default Haiku) checks these by reading the transcript. The orchestrator must therefore surface these facts in transcript clearly, ideally via the halt markers in `CLAUDE.md`.

## Resumption

If the session ends mid-build (window closes, machine sleeps, network drops), resume with `claude --resume`. The `/goal` condition is restored. Read `state.json` to find the current phase, read the phase spec, continue from wherever you stopped. Verification reports are committed, so they survive session boundaries.

If you discover the prior orchestrator's work is in an inconsistent state on resume (e.g., uncommitted changes, partial PR, half-written verification report), surface `[ESCALATION: resume-state-recovery]` and wait for guidance.
