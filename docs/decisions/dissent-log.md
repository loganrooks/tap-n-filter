# Dissent Log

An append-only record of option-between-options choices made during build. Smaller than ADRs. One entry per choice. The point is to make rejected alternatives visible so future readers (or the auditor) can see what was considered.

## Format

Each entry:

```markdown
## YYYY-MM-DD — <Short title>

**Decision**: <one line>
**Phase**: <-1 | 0 | 1 | 2 | 3 | 4 | post-V1>
**Considered**:
- <option A> — <why not>
- <option B> — <why not>
- <option C (chosen)> — <why yes>
```

Entries are added at the bottom. They are not edited after commit (except for typos). If a decision is later revisited and reversed, a new entry is added referencing the prior one; the prior entry is not deleted.

## Entries

---

## 2026-05-21 — Bundle as a suite, not a brief

**Decision**: The pre-build design bundle is written as ~30 markdown files committed at scribing time, rather than a single brief expanded by Claude Code at run time.

**Phase**: Pre-Phase -1 (during scribing).

**Considered**:
- One brief document with Claude Code expanding it on first turn — rejected. Routes load-bearing design through an agent re-derivation step. Adds a translation layer between intent and the artifacts the build phases consume.
- Full suite committed by scribing model — chosen. Documents the orchestrator reads are documents written at max reasoning during scribing. No expansion step, no implicit derivation.

---

## 2026-05-21 — Phase numbering starts at -1

**Decision**: The framing audit is Phase -1 rather than Phase 0 or "pre-Phase".

**Phase**: Pre-Phase -1 (during scribing).

**Considered**:
- Pre-Phase / Phase 0 (audit included with init) — rejected. Conflates two distinct activities (auditing design vs initializing repo). The verification subagent's prompt is structurally different for an audit vs a code-producing phase.
- Phase 0 (audit) and Phase 1 (init) and so on — rejected. Renames the rest of the phases inconveniently and makes the phase numbering less informative ("phase zero" reads like "first real phase").
- Phase -1 (audit), Phase 0 (init), Phase 1 (capture)… — chosen. The negative number signals "before the build starts." The numbering reads as: design check, then build phases.

---

## 2026-05-21 — Codex P2 "run blocking startup off main actor" partially deferred to Phase 3

**Decision**: PR #3 moves `availableSources()` (pure HAL) to `Task.detached` but keeps `controller.start(source:into:)` and `controller.stop()` on the main actor. The full off-main hop is deferred to Phase 3.

**Phase**: Phase 1 post-merge fix (PR #3).

**Considered**:
- Move `controller.start` to `Task.detached` (initial PR #3 attempt) — rejected. CodeRabbit Major flagged it correctly: capturing `AVAudioEngine` in a `@Sendable` closure is unsound (engine is not Sendable), and `configureEngineInput` mutates `engine.inputNode.audioUnit` off the main thread, violating AVFoundation's serial-configuration guidance.
- Refactor `CaptureController` to split HAL prep (process ID lookup, tap + aggregate device creation) from engine binding (the `kAudioOutputUnitProperty_CurrentDevice` set) so HAL prep can run off main and only the engine bind hops back — rejected for Phase 1 scope. Substantial restructure for a debug UI being replaced in Phase 3.
- Move only enumeration off main; document the deferred fix — chosen. Addresses the most common UI stall (the process-list lookup) without breaking the AVAudioEngine contract. Permission-prompt stall is acceptable because it's a system modal the user is already interacting with. Phase 3's real UI gets the proper split.

---

## 2026-05-21 — Bundling state.json advancement into PR #3 rather than direct push to main

**Decision**: PR #3 contains both the codex-feedback fixes AND the state.json advancement (phase 1 → passed, phase 2 → in_progress, current_phase → 2). State updates ride a PR rather than a direct push to main.

**Phase**: Phase 1 close-out / Phase 2 kickoff.

**Considered**:
- Direct push to main (the pattern in earlier commits 8701a34, 987ae82, 2bff1da) — rejected for this PR. Branch protection requires PR + CI status, and CLAUDE.md says "Do not push directly to main." Earlier direct pushes predated stricter branch protection on this build.
- Separate PR for state only — rejected. Two PRs for what is effectively one logical change (advance phase after merge + fix the code that just merged) adds review overhead without changing correctness.
- Bundle into the next phase's PR (Phase 2 PR) — rejected. State.json should reflect the post-PR-2 ground truth before Phase 2's PR opens, otherwise the Phase 2 PR's state-advancement diff conflates "advance Phase 1" with "advance Phase 2".

---

## Future entries

The orchestrator appends new entries here during build. Examples of decisions that would warrant an entry:

- Choice of DMG creation tool (`create-dmg` Homebrew vs `hdiutil` directly).
- Choice of test framework augmentation (XCTest only vs Quick/Nimble vs Testing).
- Choice of CodeRabbit-vs-Codex-first invocation order on PRs (whether the orchestrator triggers Codex before or after CodeRabbit's first pass).
- Choice of throttling interval for parameter slider updates (30 Hz, 60 Hz, debounce instead of throttle).
- Etc.

Entries should be terse. The dissent log is not the place for full reasoning — that goes in ADRs. The dissent log is the place for the option-list and the one-line "why not" per option.

If an entry needs more than ~10 lines of reasoning, it's probably an ADR.
