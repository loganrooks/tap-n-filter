# ADR-010: Phase 2 live render check accepted as environment-bounded deviation

## Status

Accepted

## Context

Phase 2's gate (`docs/orchestration/phases/02-dsp-chain.md` section 2.9) calls for an end-to-end live render check: capture Safari audio through the menu-bar app, route it through the `distant-engines` preset, record the mixer output for 10 seconds via `installTap(onBus:bufferSize:format:)`, and spectrally compare to the offline render. The phase spec describes this as "the orchestrator's confidence check, not a user-facing gate, but it is required for Phase 2 to pass."

The orchestrator cannot perform this step autonomously in the current environment. Two specific constraints:

1. The Core Audio process tap permission grant is delivered via a system modal dialog the first time the app calls `AudioHardwareCreateProcessTap`. The available computer-use tooling does not have the app on its `request_access` snapshot. Even after the user restarted Claude Code to refresh the snapshot, `tap-n-filter` was not picked up (LaunchServices registration via `lsregister -dump` showed the bundle at `Build/tap-n-filter.app` but the request_access app list — apparently cached at session start from a different source — still excludes it).

2. The live render requires a running audio source process. The orchestrator cannot start Safari, navigate to a music URL, and play audio autonomously without computer-use access to those apps, plus the same grant-then-record-then-compare interactive flow.

This is the same constraint that produced the Phase 1 passthrough-wav deviation (`docs/orchestration/state.json` `human_inputs.other_escalations[phase-1-passthrough-test-needs-interactive]`). The Phase 1 verifier accepted that as an environment-bounded deviation (`docs/audits/verification/phase-1-rerun-1.md` criterion 2). The Phase 2 verifier (`docs/audits/verification/phase-2.md` criterion 3) flagged Phase 2's identical condition and recommended this ADR.

## Decision

Accept Phase 2's section 2.9 live render check as an environment-bounded deviation, with the following dispositions:

1. **The offline render is the canonical artifact for the ear test.** The user listens to `test-artifacts/ear-test-input.wav` and `test-artifacts/ear-test-output.wav` and replies `[EAR_TEST: PASS]` or `[EAR_TEST: FAIL: <reason>]`. The synthetic-input artifacts produced by `swift run tap-n-filter-eartest` are non-silent and demonstrably filter the signal (verified in `docs/audits/verification/phase-2.md` criterion 1c).

2. **The live render is the user's responsibility when they run the app interactively.** The Phase 1 debug UI ships in this build and contains the record path needed to capture a live render to a wav file (`Phase1DebugViewModel.installRecordingTap()`). The user can run a live render themselves after they grant the Audio Capture permission and have a real source playing; the orchestrator commits no `ear-test-live.wav`.

3. **The deviation does not block Phase 2 PASS.** The verification report cites this ADR for the criterion-3 disposition. State.json's phase 2 → `passed` transition is gated on the user's `[EAR_TEST: PASS]` reply, not on the live render check.

4. **The failure modes the live render would catch — sample-rate mismatch, buffer underflow producing dropouts, aggregate-device latency producing echoes — are now downstream risks the user encounters in Phase 3's real UI.** If any of those manifest there, the orchestrator addresses them under a new ADR. Phase 2 does not pre-resolve them.

## Considered

- **Implement an integration test that mocks the capture side and only exercises the DSP chain.** Rejected. The phase spec explicitly says the check is "live render check" — its value is exercising the real aggregate-device path, not the offline path. A mocked integration test would be redundant with the offline render coverage already in place.

- **Escalate to the user to run the check and report results back.** Rejected. The previous session's analogous Phase 1 escalation (`phase-1-passthrough-test-needs-interactive`) was reverted by the user with the rationale "Only log escalations for true blockers." The same applies here: the orchestrator's work is complete, the gap is interactive, and the user can run the check at their convenience without it blocking Phase 2 closure.

- **Defer the live render to Phase 3 as part of the real UI work.** Plausible, but Phase 3 is the UI replacement of the debug view, not a re-verification of Phase 2's audio pipeline. Tying the check to Phase 3 conflates two phases' work. Better to log this deviation under Phase 2 and let Phase 3 inherit it as already-deviated.

- **Treat the deviation as a Critical failure and FAIL Phase 2.** Rejected. The verifier's framing-audit-lite (`docs/audits/verification/phase-2.md`) explicitly weighs this and finds the deviation sound. The risks the live render would catch are downstream of the same interactive-attestation step the orchestrator cannot perform; FAILing here would leave the build permanently stuck at Phase 2 without changing the underlying autonomy gap.

## Consequences

- Phase 2's verification report points to this ADR for criterion 3.
- The Phase 1 debug UI's recording path is now also documented as the live-render-capture path for the user.
- Phase 3's UI work should retain or replace the recording-tap behavior — if the new menu-bar UI doesn't surface a "record output" toggle, the user has no UI affordance for the live-render capture. A note to that effect goes in the Phase 3 spec when the orchestrator begins that work.
- A future build run on a machine where the orchestrator can drive the GUI autonomously (computer-use access to `tap-n-filter` + Safari + audio source) would convert this deviation back into a fully-performed check; this ADR would be revised to "Superseded" at that point.
