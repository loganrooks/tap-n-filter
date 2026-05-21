# Uncertainty Log

Open questions whose answers would affect behavior but aren't currently determined. Each entry records what triggered it, current best guess, and what would resolve it.

## Format

Each entry:

```markdown
## U-NNN: <Short title>

**Status**: Open | Resolved (link) | Deferred to <future-version>
**Triggered by**: <what surfaced the question>
**Question**: <the actual uncertainty>
**Current best guess**: <what the project is doing in the meantime>
**Resolution path**: <how the question would get answered>
**Revisit trigger**: <when to come back to this>
```

Entries are numbered U-001, U-002, etc. Numbers persist. Resolved entries stay in the log (with status updated and the resolving ADR or commit linked) — they're not deleted. The point is for the auditor and future contributors to see what was unknown when decisions were made.

## Entries

---

## U-001: Capture API bridge approach

**Status**: Open
**Triggered by**: Phase 1 design (`docs/orchestration/phases/01-capture-spike.md`).
**Question**: Is AudioCap's aggregate-device pattern (Core Audio Process Tap wrapped in an aggregate device that AVAudioEngine reads as input) the right approach, or should the implementation use a raw `AudioDeviceIOProcID` callback feeding a ring buffer that AVAudioEngine reads via manual input?

**Current best guess**: AudioCap's pattern is the cleaner approach and is what `docs/specs/capture.md` commits to. The fallback (raw callback + ring buffer) is more code but avoids the aggregate-device complexity.

**Resolution path**: Phase 1 implementation. If the aggregate-device path produces stable audio with acceptable latency, U-001 is resolved with status "Resolved (AudioCap pattern)". If not, an ADR (likely ADR-006) documents the fallback.

**Revisit trigger**: Phase 1 spike work.

---

## U-002: AVAudioUnitReverb factory presets sufficiency

**Status**: Open
**Triggered by**: Phase 2 design (`docs/orchestration/phases/02-dsp-chain.md`).
**Question**: Will `AVAudioUnitReverb`'s factory presets (largeHall, plate, cathedral, etc.) produce the aesthetic the user wants — specifically, "engines drowning in long reverb" — or is custom IR convolution needed?

**Current best guess**: Factory presets are sufficient for V1. `largeHall` at 70% wet, combined with aggressive lowpass, should give the dissociating quality.

**Resolution path**: Phase 2 ear test. If `[EAR_TEST: PASS]` on the distant-engines preset using factory reverb, U-002 is resolved with status "Resolved (factory IRs sufficient)". If `[EAR_TEST: FAIL]` for reasons tied to the reverb sound, the orchestrator writes ADR-006-custom-ir-implementation and adds a convolution node to Phase 2's scope.

**Revisit trigger**: Phase 2 ear test response.

---

## U-003: MenuBarExtra modal panel hosting

**Status**: Open
**Triggered by**: Phase 3 design (`docs/orchestration/phases/03-ui-control.md`).
**Question**: Can SwiftUI's `MenuBarExtra` window cleanly host `NSSavePanel` and `NSOpenPanel` modals on macOS 14.4, or do those panels need to be presented from a separate `NSWindow`?

**Current best guess**: A direct `NSSavePanel.runModal()` call from a button action in the MenuBarExtra window should work. The SwiftUI `.fileImporter` modifier may behave less reliably.

**Resolution path**: Phase 3 implementation. The orchestrator tests both paths and documents the chosen approach in code comments and an ADR if the choice has follow-on implications.

**Revisit trigger**: Phase 3 preset I/O implementation.

---

## U-004: Multi-pair output device level attenuation

**Status**: Deferred to V0.2
**Triggered by**: Apple Developer forum thread on Core Audio process taps cited during scribing.
**Question**: When the user's output device has more than 2 stereo pairs (e.g., RME Fireface, MOTU 8M), the tap produces audio attenuated by approximately `20 * log10(N_pairs)` dB. Should V1 compensate, or accept the attenuation and note it as a known issue?

**Current best guess**: V1 accepts the attenuation and notes it as a known issue in `docs/specs/capture.md` and the README. The target audience runs on MacBook Air-class devices with 1 pair; the attenuation is invisible to them. Power users with multi-pair interfaces are a V0.2 audience.

**Resolution path**: Deferred. A V0.2 ADR can document a compensation hook (a per-source gain that defaults to 0 dB and can be set per the user's device).

**Revisit trigger**: A V1 user reports the issue or V0.2 planning begins.

---

## U-005: Bundled ear-test input source licensing

**Status**: Open
**Triggered by**: Phase 2 ear test harness design.
**Question**: The ear test harness uses a 30-second F1 onboard clip as input. Is there a freely-licensable source for this, or does the user need to provide one personally?

**Current best guess**: F1 broadcast audio is copyrighted; bundling a clip in a public repo is a licensing risk. Alternatives: (a) the user records a clip from a publicly-available stream and licenses it themselves to MIT (acceptable for V1's audience); (b) the harness uses a synthetic test signal (sine sweep, pink noise) that has no aesthetic resemblance to the target use case but allows technical verification; (c) the harness uses a Creative Commons–licensed engine recording from Wikimedia or Freesound.

**Resolution path**: Phase 2. The orchestrator surfaces `[ESCALATION: ear-test-input-source]` and asks the user to pick an option.

**Revisit trigger**: Phase 2 ear test harness implementation.

---

## U-006: Codex review re-trigger pattern

**Status**: Open
**Triggered by**: Phase 0 and review-protocol design.
**Question**: After pushing fixes for Codex review findings, does Codex auto-re-review or does the orchestrator need to re-post `@codex review`? Documentation suggests manual re-trigger but behavior may have changed.

**Current best guess**: Manual re-trigger. The orchestrator posts `@codex review` after the final round of fixes before requesting verification.

**Resolution path**: Verify during Phase 0's no-op PR cycle.

**Revisit trigger**: First Codex review during Phase 0.

---

## U-007: Snapshot test stability across macOS versions

**Status**: Open
**Triggered by**: Phase 3 design.
**Question**: SwiftUI snapshot tests are known to drift between macOS minor versions (different default fonts, slight layout changes). How brittle will the snapshot tests be in practice?

**Current best guess**: Pin CI to a specific macOS runner version and accept that snapshot updates are needed when the pin is bumped. Document the pin in `coding-standards.md` and as a CI comment.

**Resolution path**: Phase 3 implementation. If snapshots prove too brittle, the orchestrator may swap them for a smaller set of accessibility-tree-based tests that are more stable across versions.

**Revisit trigger**: Phase 3 testing.

---

## Future entries

The orchestrator appends new entries during build whenever an open question surfaces that's substantial enough to record. Examples:

- A Core Audio API behavior that's not documented and isn't yet certain.
- A choice between two implementation approaches where the right pick depends on empirical evidence the orchestrator doesn't yet have.
- A V0.2 design choice that affects V1 architecture and needs to be flagged for revisiting.

Entries that are resolved during build are updated in place (status changed, link to resolving ADR or commit added) but never deleted.
