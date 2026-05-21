# CLAUDE.md

Instructions for any Claude Code session working in this repository.

## What this project is

**tap-n-filter** is a macOS menubar app that captures audio from a specific application via Core Audio process taps and routes it through a configurable graph of audio effects. V1 is described in detail under `docs/specs/architecture.md`.

## Working mode

This repository is built using an agent-driven workflow centered on `/goal`. The full plan lives at `docs/orchestration/plan.md`. The current phase and status are recorded in `docs/orchestration/state.json`.

If you are starting work in this repo for the first time, read the following in order before doing anything else:

1. `docs/orchestration/plan.md`
2. `docs/orchestration/state.json`
3. The phase doc at `docs/orchestration/phases/<current_phase>.md`
4. `docs/governance/quality-gates.md`

Then proceed to whatever the current phase requires.

## Phases and gates

Every phase has a spec under `docs/orchestration/phases/`. Every phase has gate criteria documented in that spec. **Do not advance a phase to `passed` in `state.json` until verification has returned PASS per `docs/governance/verification-protocol.md`.**

Phases are numbered:

- `-1` — Framing Audit (cold-context review of the design bundle itself)
- `0` — Repo and Tooling Init
- `1` — Capture Spike
- `2` — DSP Chain
- `3` — UI and Control
- `4` — Polish and Release Prep

Run them in order. Do not skip Phase -1.

## Verification

Each phase ends with a verification subagent invocation. Spawn the verification subagent per `docs/governance/verification-protocol.md`. The subagent reads the phase spec and the diff, returns PASS or FAIL with reasoning, and answers the framing-audit-lite question. Record its report under `docs/audits/verification/<phase>.md` and update `state.json` accordingly.

## Delegation

Delegate work to subagents per `docs/governance/delegation-protocol.md`. The doc covers when to delegate, the six required parts of a delegation prompt, and per-subagent-type model selection (Opus for the auditor and audit-response agent; Sonnet for verification by default; code-writing subagents pick per the trickiness rubric). Read it before spawning a subagent.

## Human-input gates

Two phases require human input:

- **Phase 2** requires an ear test. Produce an A/B comparison wav, surface it via the marker `[EAR_TEST_READY: <path>]`, then wait for `[EAR_TEST: PASS]` or `[EAR_TEST: FAIL: <reason>]` in chat.
- **Phase 4** requires user acceptance. Build a release candidate, surface it via `[RC_READY: <path>]`, then wait for `[ACCEPT]` or `[REVISE: <what>]`.

These are the only two human-in-the-loop points. All other review is performed by subagents per the protocols in `docs/governance/`.

## Decision logging

Decisions made during build go to one of three places, depending on type:

- **ADRs** (`docs/decisions/ADR-NNN-<topic>.md`) — decisions you commit to, with full context, alternatives considered, and consequences. Write a new ADR whenever you make a substantive architectural choice during build.
- **Dissent log** (`docs/decisions/dissent-log.md`) — append an entry whenever you choose between options. One-line summary, rejected alternatives, reasoning.
- **Uncertainty log** (`docs/decisions/uncertainty-log.md`) — append an entry whenever you discover a question you can't fully answer. Note what triggered the entry, current best guess, and what would resolve it.

The auditor reads these. Hidden reasoning is the failure mode the audit catches.

## Style

This is a public repo. Code is written for other people to read, not just for the orchestrator.

- Swift code follows the conventions in `docs/governance/coding-standards.md`.
- Markdown docs use declarative prose. Avoid AI writing patterns: no "not X, but Y" constructions, no anaphoric paragraph openers, no aphoristic sentence closers, no tricolon padding.
- Commit messages: imperative mood, first line ≤ 72 chars, body wrapped at 80.

## PR workflow

Each phase ends with a PR. Branch naming: `phase-<N>-<short-description>`.

Open the PR via `gh pr create`. CodeRabbit reviews automatically. Comment `@codex review` to trigger a Codex review pass. Address review comments before requesting human acceptance (Phase 4 only; earlier phases self-merge after PR review).

See `docs/governance/review-protocol.md` for the full review flow.

## What you do not do without explicit user instruction

- Do not delete files in `docs/`.
- Do not modify `goal-prompt.md`.
- Do not skip phases.
- Do not advance `state.json` past `pending` without a passing verification.
- Do not commit `Package.resolved` updates that introduce new top-level dependencies without an ADR.
- Do not push directly to `main`. Every change goes through a PR.

## Halt markers

Use these exact markers in transcript when you need to communicate state to `/goal` or the user:

| Marker | Meaning |
|---|---|
| `PHASE <N> GATE: PASS. Advancing to Phase <N+1>.` | Phase complete, moving on |
| `PHASE <N> GATE: FAIL. <reason>` | Phase incomplete, will retry or escalate |
| `PHASE <N> GATE: AWAITING <ear_test\|acceptance>` | Need human input |
| `[EAR_TEST_READY: <path>]` | Ear-test artifact is ready |
| `[RC_READY: <path>]` | Release candidate is built |
| `[ESCALATION: <topic>]` | Need user guidance on something unanticipated |

The `/goal` evaluator watches for these. Use them precisely.
