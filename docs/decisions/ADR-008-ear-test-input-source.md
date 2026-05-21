# ADR-008: Ear Test Input Source

## Status

Accepted

## Context

Phase 2's ear test harness needs an audio input to render through the `distant-engines` preset. The source-of-truth aesthetic for the project is "F1 onboard audio sitting underneath ambient music" (per `docs/audits/design-rationale.md`), but F1 broadcast audio is copyrighted and bundling a clip in a public repo is a licensing risk.

The original design (`docs/orchestration/phases/02-dsp-chain.md` as scribed) deferred this question to a Phase 2 `[ESCALATION: ear-test-input-source]`, leaving the ear test at risk of stalling mid-build over an asset question.

Three options were considered:

1. The user records a clip from a publicly-available stream and licenses it themselves to MIT for the project (acceptable for the V1 audience).
2. The harness uses a synthetic test signal (sine sweep, pink noise, test tones) that has no aesthetic resemblance to the target use case but allows technical verification.
3. The harness uses a Creative Commons-licensed engine recording from Wikimedia or Freesound.

## Decision

**Default to synthetic test signal; user provides their own clip via CLI flag for the aesthetic ear test.**

The harness generates a 30-second synthetic composite (pink noise + log sine sweep + test tones) when no input is specified. The `--input <path>` flag accepts a user-provided wav for the aesthetic test.

The user's own clip is the user's responsibility licensing-wise; the project ships no third-party audio.

## Alternatives considered

### Option 1: User provides a personally-licensed clip

Works but requires the user to do the licensing thinking before the harness can run. Adds friction at a build-time gate. Less general — the synthetic option works for any future ear test, not just this preset.

### Option 3: CC-licensed engine recording

Solves the licensing question but commits to a specific source's character. Wikimedia / Freesound engine recordings tend to be static-shot vehicle pass-bys, not in-cockpit onboard audio, so the aesthetic fit to "F1 onboard" is loose. Also adds a binary file to the repo, which is mild repo-hygiene cost. The synthetic option avoids both issues.

### Option (chosen): Synthetic default, user-clip override

- **Why yes**: Harness runs immediately, no licensing question for the project, the aesthetic test becomes a one-line user action ("I dropped my clip at X.wav and re-ran with --input X.wav"). Phase 2 gate is unblocked.
- **Trade-off**: The synthetic input doesn't tell the user whether the preset achieves the dissociating "distant engines" character — that requires a real source. But that's true of any non-target source; the synthetic just makes the technical chain runnable.

## Consequences

**Enabled:**
- Phase 2 ear test runs without escalation.
- No licensed audio in the repo; no licensing concerns at distribution time.
- The harness is reusable for future presets — same synthetic input works regardless of the preset's aesthetic target.

**Precluded or constrained:**
- The orchestrator cannot self-verify the preset's aesthetic match without the user's clip. The user must do the aesthetic verification step. (This is fine — it was already a human-in-loop gate.)

**Risks:**
- The synthetic input may produce confusing-sounding output through aggressive lowpass + reverb (sine sweep through `distant-engines` is going to sound strange). Mitigation: the harness output is labeled "synthetic test signal — for technical verification only" so the user knows not to judge the preset's aesthetic from it.

## References

- `docs/decisions/uncertainty-log.md` U-005 (now resolved).
- `docs/orchestration/phases/02-dsp-chain.md` section 2.8.
- `docs/audits/framing-audit-001.md` finding F-012.
