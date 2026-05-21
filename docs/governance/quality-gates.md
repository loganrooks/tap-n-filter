# Quality Gates

This document describes the gates that govern phase transitions. Every phase has a gate. Every gate has explicit criteria. No phase advances without passing its gate.

## Gate types

Three kinds of gates appear in tap-n-filter's build:

1. **Agent verification** — a verification subagent reads the phase spec and diff, evaluates against the criteria, returns PASS or FAIL. See `verification-protocol.md`.

2. **PR review** — every phase that produces code goes through a pull request. CodeRabbit reviews automatically; Codex reviews on `@codex review`. PR review is concurrent with agent verification; both must clear before the phase advances. See `review-protocol.md`.

3. **Human input** — two phases (2 and 4) have human-in-the-loop gates: the ear test and the acceptance gate. These require explicit confirmation from the user via specific halt markers in chat.

## Phase-by-phase gate summary

| Phase | Verification | PR review | Human input |
|---|---|---|---|
| -1 Framing Audit | Yes (after audit + response complete) | No (no code yet) | Only if audit-response escalates |
| 0 Repo and Tooling Init | Yes | Yes (no-op PR) | No |
| 1 Capture Spike | Yes | Yes | No |
| 2 DSP Chain | Yes | Yes | **Ear test** |
| 3 UI and Control | Yes | Yes | No |
| 4 Polish and Release Prep | Yes | Yes | **Acceptance** |

## The two human-input gates

### Phase 2: Ear Test

The orchestrator produces an A/B comparison: the source audio and the source audio after passing through the bundled `distant-engines` preset. Files land at `test-artifacts/ear-test-input.wav` and `test-artifacts/ear-test-output.wav`.

The orchestrator surfaces:

```
PHASE 2 GATE: AWAITING ear_test
[EAR_TEST_READY: test-artifacts/]

I've rendered the distant-engines preset against a 30-second sample. Please listen to 
both files in your DAW or a media player you trust:

- test-artifacts/ear-test-input.wav (source)
- test-artifacts/ear-test-output.wav (after the chain)

Confirm the output sounds like what you wanted from a "distant engines" preset.

Reply [EAR_TEST: PASS] to advance Phase 2.
Reply [EAR_TEST: FAIL: <reason>] to request changes. I'll iterate.
```

The user listens, replies. If `[EAR_TEST: PASS]`, the orchestrator records the result in `state.json` and proceeds. If `[EAR_TEST: FAIL: <reason>]`, the orchestrator addresses the reason (typically by adjusting preset parameters or, in the structural-failure case, escalating).

The user can also reply with a refined request like `[EAR_TEST: FAIL: too wet, try 50%]`, in which case the orchestrator applies the suggestion and re-renders.

### Phase 4: Acceptance

After the release candidate is built, signed, and notarized, the orchestrator surfaces:

```
PHASE 4 GATE: AWAITING acceptance
[RC_READY: Build/Release/tap-n-filter-v0.1.0.dmg]

The release candidate is ready. Please:

1. Download and install from the GitHub release at <URL>.
2. Run it for a real listening session.
3. Confirm everything works as expected.

Reply [ACCEPT] to complete the build.
Reply [REVISE: <what>] to request changes.
```

The user installs, uses, replies. On `[ACCEPT]`, the orchestrator finalizes and the build is complete. On `[REVISE: <what>]`, the orchestrator returns to whichever phase covers the issue, then re-runs Phase 4.

## Other halt markers

Halt markers are precise strings the orchestrator emits in transcript to communicate state to the `/goal` evaluator and to the user:

| Marker | Used by | Meaning |
|---|---|---|
| `PHASE <N> GATE: PASS. Advancing to Phase <N+1>.` | Orchestrator | Phase complete; moving on |
| `PHASE <N> GATE: FAIL. <reason>` | Orchestrator | Phase gate didn't clear; will retry or escalate |
| `PHASE <N> GATE: AWAITING <ear_test\|acceptance>` | Orchestrator | Need human input |
| `[EAR_TEST_READY: <path>]` | Orchestrator | Ear test artifacts at path |
| `[RC_READY: <path>]` | Orchestrator | Release candidate at path |
| `[ESCALATION: <topic>]: <question>` | Orchestrator | Need user guidance |
| `[EAR_TEST: PASS]` | User | Ear test approved |
| `[EAR_TEST: FAIL: <reason>]` | User | Ear test rejected with reason |
| `[ACCEPT]` | User | Release accepted |
| `[REVISE: <what>]` | User | Release needs changes |

Use these exact strings. The `/goal` evaluator pattern-matches them. The user is documented on them in `goal-prompt.md` and the README.

## Strict-mode criteria

Some criteria are non-negotiable: failure here FAILs the phase regardless of other criteria's status. These are explicitly marked in each phase spec. Strict-mode criteria typically cover:

- Safety: no crashes, no data loss, permission handling.
- User input: the user-input gates literally require user input; no agent can simulate them.
- Audit-lite outcome: if the verification subagent's audit-lite flags unsound additions, the phase FAILs.

## Re-runs after FAIL

A phase that FAILs verification is not closed. The orchestrator addresses the gap, re-runs verification, and continues until PASS. There is no hard limit, but a phase that fails verification three times in a row triggers `[ESCALATION: phase-stuck]`.

This is by design: the orchestrator has the time and patience to iterate. The user's time is the scarce resource. The protocol's job is to make sure the orchestrator iterates on the right things, not to limit how many tries it gets.

## What the gates protect against

- **Drift from spec.** The verification subagent reads the spec and checks compliance. Silent deviations get caught.
- **Hidden reasoning.** The audit-lite question catches additions that should have been ADRs.
- **Sloppy completion claims.** "I think this works" doesn't pass verification. The orchestrator must produce evidence.
- **Skipped phases.** The orchestrator cannot reach Phase 4 without Phase 1 passing. The state.json transitions enforce ordering.
- **Bad release.** The acceptance gate prevents a botched RC from being declared v0.1.0.
- **Bad sound.** The ear test prevents technically-correct-but-aesthetically-wrong DSP from passing.
