# Phase 3 Verification

**Verifier**: Claude (verification subagent, cold context)
**Date**: 2026-05-21
**Phase**: 3 — UI and Control
**Verdict**: FAIL

## Gate criteria assessment

### Criterion 1: All views from 3.1–3.6 exist with the specified structure.

**Status**: Met

**Evidence**:

- `Sources/UI/ControlPanelView.swift` — root view, width 320 pt, dynamic
  height capped at 600 (820 with debug panel). Composes `HeaderView`,
  `SourcePickerView`, `ChainEditorView`, `FooterView`. Header order matches
  spec §3.1 (status surfaced via the header's status pill).
- `Sources/UI/SourcePickerView.swift` — `Picker` over `availableSources`,
  selection keyed by `pid_t?` per the dissent log entry. Disabled during
  `.starting` / `.stopping`. Refresh logic lives on `AppViewModel`
  (`startSourceRefreshTimer` + a 5 s `Timer`).
- `Sources/UI/ChainEditorView.swift` — `LazyVStack` of `EffectRow`s inside
  a `ScrollView` (max height 360), followed by an `AddEffectButton` menu.
  Effect-types menu is sourced from `viewModel.availableEffectTypes`
  (the injected registry).
- `Sources/UI/EffectRow.swift` — header with expand chevron, reorder
  up/down buttons (per ADR-013, not drag-and-drop), display name, bypass
  toggle, optional wet/dry slider (gated on `Self.showsWetDryByDefault`,
  hidden on EQ per ADR-007), remove button. Expanded `EffectControlsView`
  appears when `viewModel.expandedEffectID == node.id`.
- `Sources/UI/EffectControlsView.swift` — switches on `parameter.unit`:
  continuous units → `ParameterSlider` (throttled at 30 Hz via a per-slider
  `PassthroughSubject` + Combine `throttle`); `.integer` → `Stepper`;
  `.enumValue` → `Picker`. Wet/dry row always rendered in the expanded
  panel so EQ users can still reach it.
- `Sources/UI/PresetMenu.swift` — Menu with Save As (`NSSavePanel`),
  Open (`NSOpenPanel`), and a "Factory Presets" submenu iterating
  `FactoryPresets.all`. AppKit panels presented through
  `beginSheetModal(for:)` or `runModal()` per ADR-012.
- `Sources/UI/PowerToggle.swift` — single button rendering Start / Stop /
  Starting…/Stopping… / Retry per `captureState`. Disabled during
  transitions. Adjacent `info.circle` button surfaces the latest error.
- `Sources/tap-n-filter/App.swift` — `MenuBarExtra` with
  `.menuBarExtraStyle(.window)` hosts `ControlPanelView` with the shared
  `@StateObject` view model.

Two surface additions beyond the spec letter:

- `Sources/UI/HeaderView.swift` — adds a status pill that satisfies the
  spec's "status line showing capture state and current source" (§3.1)
  and a debug-panel toggle (the ladybug). The pill discharges criterion 1
  for the status line; the debug toggle is additive (see audit-lite below).
- `Sources/UI/DebugPanel.swift` + `Sources/ViewModel/DebugLogStore.swift`
  — toggleable scrolling log mounted below the footer. Additive instrumentation,
  not in the spec.

### Criterion 2: Source switching, effect add/remove/reorder, parameter changes, preset save/load, persistence, and power toggle all work without crashes.

**Status**: Met (live behavior) / partially Unable to evaluate (no end-to-end
test log)

**Evidence**:

- Source switching: `AppViewModel.setSource` calls `powerOff()` when running
  and coalesces concurrent shutdowns through `sourceChangeShutdownTask`
  (round-2 Codex P2 fix in commit `14b240b`). Unit test
  `test_setSource_while_running_calls_stop` asserts `capture.stopCallCount
  >= 1` after a swap.
- Effect add / remove: `AppViewModel.addEffect` and `removeEffect` go through
  `mutateGraph`, which detaches the live graph, mutates, then re-attaches
  via `attemptReattach`. Tests `test_addEffect_appends_node` and
  `test_removeEffect_drops_node` pass on CI.
- Reorder: `moveEffect(from:to:)` uses `Graph.move`'s post-removal index
  convention (per ADR-013). Test `test_moveEffect_reorders_nodes` passes on
  CI.
- Parameter changes: `updateParameter` throttles at 30 Hz; test
  `test_updateParameter_writes_are_throttled` passes.
- Preset save/load: `savePreset(to:)` calls `PresetStore.save`,
  `loadPreset(from:)` calls `PresetStore.load` then `installPreset` which
  swaps the graph and reattaches. `loadFactoryPreset(named:)` loads through
  `FactoryPresets.load`. No direct view-model test exercises load/save with
  a real file, but `PresetStoreTests` (existing) cover the round-trip at the
  store level.
- Persistence: `test_persistence_round_trip_restores_graph` writes through
  one model and reads through a second; passes. `test_falls_back_to_distant_engines_on_corrupt_data`
  exercises the fallback path; passes.
- Power toggle: `PowerToggle.tap()` dispatches to `powerOn`/`powerOff` per
  `captureState`. Retry path on `.failed` calls `clearError()` and re-runs
  `powerOn` per the CR Major fix in `580e0f1`. Live verification cited in
  the PR body and in `docs/audits/verification/phase-3-accessibility.md`:
  user ran the manual VoiceOver pass against the built `.app` on macOS 26.3
  with Bluetooth output, and the orchestrator's note says VoiceOver
  navigation worked. The same session uncovered the live-audio routing bug
  that prompted commits `28e5938`, `580e0f1`, and `d108da2`; those fixes are
  the explanation for why the gate now reads "without crashes" — without
  them, the live audio path was silently broken (audible original audio
  plus a faint processed copy).

Caveat I could not check without running the app:

- No committed log or screenshot demonstrates a complete loop of
  "save → quit → relaunch → load" with a real `.tnf` file. The PR's
  "Manual" section of the test plan includes this as an unchecked
  checkbox. Unit tests cover the persistence-to-UserDefaults path but
  not the on-disk preset round-trip from the menubar UI.

I am marking this criterion **Met** on the strength of the unit tests
(all 10 ViewModelTests passing on CI commit `14b240b`), the manual
VoiceOver pass which exercised the menu surface, and the documented
live audio bug being fixed in `d108da2`. The Save/Open file round-trip
through the UI is the one gap; it is best-effort covered by
`PresetStoreTests` at the store layer.

### Criterion 3: Snapshot tests pass.

**Status**: Not met

**Gap**:

The three snapshot tests
(`test_snapshot_idle`, `test_snapshot_running`, `test_snapshot_failed`)
are **skipped on CI**, not passing. The committed
`Tests/UISnapshotTests/__Snapshots__/` directory contains only
`README.md`; no PNG baselines exist. On a clean checkout the helper
calls `XCTSkip` for every test with a message instructing the developer
to re-run with `TNF_SNAPSHOT_REGEN=1` to generate baselines.

CI log (run `26259045936`, commit `f7868ca`) confirms:

```
Test Case '-[UISnapshotTests.ControlPanelViewSnapshotTests test_snapshot_failed]' skipped (0.817 seconds).
Test Case '-[UISnapshotTests.ControlPanelViewSnapshotTests test_snapshot_idle]' skipped (0.033 seconds).
Test Case '-[UISnapshotTests.ControlPanelViewSnapshotTests test_snapshot_running]' skipped (0.030 seconds).
Executed 3 tests, with 3 tests skipped and 0 failures (0 unexpected) in 0.879 (0.879) seconds
```

The phase spec's gate criterion 3 is literally "Snapshot tests pass." A
skipped test is not a passing test. The orchestrator's previous behavior
(write-on-missing) was flagged P1 by Codex on round 1; the round-2
remedy was to convert silent-pass into `XCTSkip`, which Codex then
re-flagged P1 on round 2 (comment on commit `14b240b`):

> In strict mode, a missing baseline throws `XCTSkip`, which lets CI
> pass without asserting any pixels for that snapshot. With this
> commit only adding `__Snapshots__/README.md` (no PNG baselines),
> snapshot coverage becomes non-blocking and visual regressions can
> ship unnoticed. Fresh evidence relative to prior review comments:
> this revision changed the behavior from auto-pass to skip, but skip
> still does not enforce baseline presence.

This round-2 P1 has not been addressed in the current PR head.

Uncertainty log entry U-009 acknowledges the gap and defers strict
baseline gating to V0.2. That is a legitimate documented deviation
parallel to ADR-010 (the Phase 2 env-bounded deviation precedent), but
it is a *deviation*, not literal compliance. The phase spec did not
authorize this deviation; the spec calls snapshot tests a hard gate
criterion (§3.9 "SwiftUI snapshot tests for `ControlPanelView` in
three states: idle, running, failed"; §Gate criteria #3 "Snapshot
tests pass").

A strict reading of the gate criterion forces FAIL. If the orchestrator
believes this should be treated as an env-bounded deviation analogous
to ADR-010, that needs to be promoted from a U-log entry to an ADR
*before* the verification subagent rules on it, because ADR-010 was
written and acknowledged before Phase 2 verification ruled on a
similar pattern. U-009 records an intent to defer, not an accepted
deviation.

I am marking this Not met. The orchestrator's options are:
(1) generate and commit the three PNG baselines on a CI runner and
re-run verification; (2) write an ADR explicitly authorizing the
deviation and re-run verification; (3) accept the FAIL and remediate.

### Criterion 4: View model tests pass.

**Status**: Met

**Evidence**:

CI run `26259045936` (commit `f7868ca`) ran the `AppViewModelTests`
suite to completion:

```
Test Suite 'AppViewModelTests' passed at 2026-05-21 23:26:42.772.
Executed 10 tests, with 0 failures (0 unexpected) in 0.754 (0.755) seconds
```

All ten cases pass on CI: state mirroring, source-switch-calls-stop,
persistence round-trip, corrupt-data fallback, add/remove/move,
parameter throttling, and the `powerOn` no-source error path.

Caveat: source switching test asserts `stopCallCount >= 1`; it does not
assert the chain restarts on the new source. Per the spec (§3.2) "the
view model handles the transition cleanly" — the spec is satisfied by
the stop-and-stay-off semantics the implementation chose (and the
dissent log entry confirms this is the intentional V1 behavior, with
user pressing Power again to restart).

### Criterion 5: The accessibility audit passes both parts.

**Status**: Met (with documented deviation from the spec's XCUITest approach)

**Evidence**:

**Part (a) — programmatic check**:

- `test-artifacts/phase-3-accessibility-tree.json` is committed
  (generated 2026-05-21T20:49:21Z on macOS 26.3). 19 total nodes, 11
  interactive elements (6 sliders, 4 buttons, 1 popup button), 15
  nodes with non-empty `value`, 2 nodes with non-empty `label`.
- `Tests/AccessibilityTreeTests/AccessibilityTreeTests.swift` ran all
  6 tests to completion on CI (run `26259045936`):
    - `test_dump_artifact_exists_and_parses` passes.
    - `test_dump_environment_metadata_is_present` passes.
    - `test_dump_has_plausible_structural_counts` passes (>=10 nodes,
      >=8 interactive, >=3 sliders, >=1 popup).
    - `test_dump_contains_expected_action_buttons` passes ("Add Effect"
      and "Presets" present).
    - `test_source_accessibility_label_literals_are_non_empty` passes
      (27 modifier sites across 6 UI files, all literals non-empty).
    - `test_source_accessibility_value_literals_are_non_empty` passes.
- ADR-011 documents the SwiftPM/XCUITest workaround. The spec's
  literal requirement (XCUIApplication walking the menubar) cannot be
  satisfied in a SwiftPM-only build (per ADR-009). The implementation
  splits the audit into an `NSHostingView`-based artifact producer
  (`tap-n-filter-a11y-dump`) and a JSON-validating XCTest target.

**Part (b) — manual VoiceOver pass**:

- `docs/audits/verification/phase-3-accessibility.md` records the pass
  on 2026-05-21 against macOS 26.3 with VoiceOver enabled and a
  Bluetooth output device. Result: PASS (accessibility surface).
- The doc notes that VoiceOver navigation worked and every interactive
  control was reachable and announced its label. The same session
  surfaced a functional audio bug, which was fixed in `28e5938` and
  follow-up commits (ADR-014); the accessibility verdict is documented
  as independent of that audio bug.

I am marking this Met. The artifact exists, the CI test passes, the
manual pass record exists with a PASS result. The orchestrator's
ADR-011-driven deviation from the spec's XCUITest approach is well
documented, has a credible rationale (SwiftPM-only build), and
preserves the artifact contract (`test-artifacts/phase-3-accessibility-tree.json`).
The only concern is that the JSON's `nodesWithLabel` count (2 of 19)
is low; ADR-011 explains this is a KVC-API limitation, not a
source-level omission, and the source-grep test backs that up. The
manual VoiceOver pass is the authoritative check that labels read
correctly, and it passed.

### Criterion 6: CodeRabbit and Codex review pass.

**Status**: Not met

**Gap**:

Two issues block strict compliance:

1. **CodeRabbit reviews are auto-paused on this PR** (per the bot
   comment dated 2026-05-21T17:07:29Z in the PR thread). CR has not
   reviewed the final three commits (`d108da2`, `14b240b`, `f7868ca`).
   The last CR review (commit `580e0f1`, 21:16:18Z) raised one Major
   duplicate comment about `attemptReattach()` still targeting
   `engine.outputNode` — the orchestrator addressed that in
   `d108da2` (verified in the code; see `AppViewModel.swift:702`,
   which now uses `engine.mainMixerNode`), but CR has not re-reviewed
   to confirm. "CodeRabbit pass" is ambiguous when CR is paused; on a
   literal reading it has not approved the final state.

2. **Codex's most recent review (commit `14b240b`, 23:22:41Z) raised
   two new comments that are unaddressed in the current PR head**:
   - **P1** on `Tests/UISnapshotTests/SnapshotHelper.swift:97`: "Fail
     missing snapshot baselines instead of skipping" — same issue as
     gate criterion 3 above. Codex explicitly flags that the round-2
     `XCTSkip` change is still not enforcement.
   - **P2** on `Sources/UI/EffectControlsView.swift:192`: "Resync slider
     state after preset or restore updates" — `ParameterSlider`'s
     `liveValue` seeds from `initialValue` once and never resyncs when
     a preset load mutates the underlying node. Codex describes this
     as a stale-state bug that can surface as a slider drift after
     preset load.

The PR's review response document (commit `14b240b`, 23:15:48Z) was
written before this round-3 Codex feedback was posted, so neither item
appears in the disposition matrix. The orchestrator has not
acknowledged or addressed these two findings.

I am marking this **Not met**. Resolving it requires either (a)
addressing both Codex findings and re-triggering CR review, or (b)
documenting the deferrals with explicit reasoning (which is what
review-protocol.md "Reasoning over acceptance" allows — but the
deferral has to be a recorded decision, not silence).

### Criterion 7: `state.json` shows phase `3` → `passed`.

**Status**: Not met

**Evidence**:

`docs/orchestration/state.json` (committed at `f7868ca`):

```json
"3": {
    "name": "UI and Control",
    "status": "in_progress",
    ...
    "verification_report": null,
    ...
}
```

Status is `in_progress`, not `passed`. This is correct per the
verification protocol: the orchestrator should not advance to `passed`
before the verification subagent returns PASS, and the protocol's
state-transition diagram has phase status going `in_progress` →
`passed` as a result of *this* verification's PASS. So this criterion
is the consequence of a PASS verdict, not a precondition. From the
verification subagent's standpoint it should be read as: "after this
verification PASSes, state.json gets advanced". I cannot literally
confirm it shows `passed` because that update is what *follows* my
verdict. The orchestrator's pre-verification snapshot commit (`f7868ca`)
correctly sets `in_progress` and leaves the verdict to me.

I am marking this **Not met** literally — the gate criterion text reads
"state.json shows phase 3 → passed" and the file currently does not.
The expected sequence is verification PASSes → orchestrator advances
state.json → criterion 7 is satisfied as part of merging this PR. So
the criterion is structurally satisfied by the workflow when the prior
six criteria PASS; it is not literally satisfied right now.

If the literal reading is what verification should apply, then this
criterion is a no-op tautology (the state.json change happens in
response to verification). For a PASS verdict on this criterion alone,
treat it as "Met on advance"; for a FAIL verdict on the phase
overall, this criterion remains in its current state.

I am scoring the verdict on criteria 1–6. Criterion 7 is a workflow
artifact, not a substantive gate I can evaluate in cold context.

---

## Framing audit-lite

**Question**: Did this phase's implementation introduce reasoning or assumptions that weren't in the spec? If so, were those additions sound?

**Answer**:

The phase introduced four substantive deviations from the spec, and a
fifth piece of scope drift. Three of the four deviations are well
documented and sound; the fourth (snapshot tests as `XCTSkip` rather
than passing) is documented in the uncertainty log but should have been
escalated to an ADR before verification ruled on it. The scope drift
mixes a defensible necessity with a defensible-but-bloated luxury.

**Sound additions.** ADR-013 (reorder via up/down buttons rather than
drag-and-drop) is the right call: `MenuBarExtra` plus drag-and-drop is
historically flaky on macOS 14.x, and drag handles are invisible to
keyboard / VoiceOver navigation, which would have failed criterion 5.
The phase spec explicitly authorizes this degraded path in its Failure
Modes section. ADR-012 (`NSSavePanel` via `beginSheetModal` with
`runModal` fallback, rather than SwiftUI `.fileExporter` /
`.fileImporter`) is similarly forced by `MenuBarExtra`'s well-documented
flakiness around file modals. ADR-011 (in-process AppKit accessibility
walk instead of XCUITest) is the correct response to the SwiftPM-only
constraint codified in ADR-009; the spec's literal "XCUIApplication"
requirement cannot be satisfied without an `.xcodeproj`, and the
implementation preserves the artifact contract while running both a
programmatic test and a manual VoiceOver pass. ADR-014 (`muteBehavior =
.muted`) is technically Phase 2 work surfaced by Phase 3's live UI;
the rationale is clear and documents an honest mismatch between the
Phase 2 ear-test (offline render) and what the user actually hears at
the audio device. Without ADR-014's fix, the gate criterion 2 sentence
"power toggle ... works" would be technically true but practically
misleading — the app would do nothing audible.

**Unsound additions.** The snapshot-test deviation is the one I would
push back on. The spec's gate criterion 3 says "Snapshot tests pass."
The round-1 Codex P1 about silent-write-on-missing was a real catch.
The round-2 remedy — `XCTSkip` — does not address the underlying
problem (no baselines in the repo, no enforcement) and Codex flagged
that explicitly in round 2. U-009 records an intent to defer to V0.2,
but a phase gate should not be discharged by an uncertainty-log entry;
the protocol for accepting a deviation analogous to ADR-010 is to
write an ADR, document the constraint, and seek explicit acceptance.
The orchestrator can defensibly choose to defer; what they cannot do
is treat U-009 as a substitute for an ADR. This is the same audit
posture that surfaced ADR-010 during Phase 2.

**Scope-drift judgment.** The three audio-routing fixes (`28e5938`,
`580e0f1`, `d108da2`) were required by the gate criterion's "without
crashes" sentence interpreted against a live audio path. They could
have been a separate "phase-2-postscript" branch, but they touch
`AppViewModel.powerOn` — a Phase 3 deliverable — and the chain of
dependencies is real. Folding them in is defensible. The debug
infrastructure (`DebugLogStore`, `DebugPanel`, the ladybug toggle,
the `tap-n-filter-poweron-probe` CLI in commit `ea899cc`) is harder
to defend on the gate-criteria reading: it does not appear in
`docs/specs/ui.md`, does not affect any gate criterion, and the
orchestrator's own PR body says "should have been a separate PR" and
"recorded as a lesson in the dissent log." It is additive and does not
break anything (the debug panel is hidden by default and gated on a
UserDefault), so it is not "unsound" in the sense that should trigger
FAIL by itself. It is bloat.

The phase as a whole is mostly sound. The unsound piece is criterion 3,
and that is also a literal-gate failure on its own — those two paths
converge on the same FAIL verdict.

## Verdict reasoning

I am returning **FAIL** on three independent grounds, each of which on
its own is enough to require a re-run:

1. **Criterion 3 (snapshot tests pass) is literally Not met.** Three
   tests are `XCTSkip`ped on CI because no PNG baselines are committed.
   Skipped tests are not passing tests. The deviation is documented in
   U-009 but never elevated to an ADR. The phase spec calls this a
   gate criterion. Resolving requires either generating the baselines
   on a CI runner and committing them, or writing an ADR that mirrors
   ADR-010's env-bounded-deviation pattern and revisiting verification.

2. **Criterion 6 (CodeRabbit and Codex review pass) is Not met.**
   CodeRabbit is auto-paused and has not reviewed the final three
   commits. Codex's most recent review on `14b240b` raised two new
   comments (a P1 reiteration of the snapshot-baseline issue and a P2
   about stale `ParameterSlider.@State` after preset load) that the
   orchestrator has not acknowledged or addressed.

3. **The framing audit-lite flags the snapshot deviation as
   unsound** in the sense the protocol cares about: the orchestrator
   substituted an uncertainty-log entry for the ADR that ADR-010's
   precedent established. This is exactly the kind of hidden reasoning
   the audit posture is designed to catch.

Note on the EQNodeTests CI failure (`test_snapshot_restore_roundtrip_preserves_state`)
on commit `f7868ca`: this test also failed on main commit `4fd6b58`
with the same `14426.951` value bleeding from `lp.frequency` into
`hp.Q`'s slot, suggesting a pre-existing AVAudioUnitEQ aliasing flake
that is independent of phase-3 work (EQNode.swift and EQNodeTests.swift
did not change on this branch). I am NOT factoring this into the
verdict because it is not phase-3 caused, but it is worth flagging
that overall CI status is currently "failure" on the latest commit and
that condition will need to be cleared (either by re-running CI to
demonstrate it is a flake, or by fixing the test) before any merge.

To resolve to PASS the orchestrator should, at minimum:

- Generate and commit the three PNG snapshot baselines on a CI runner
  (and the orchestrator can do this by adding a `record-snapshots` job
  that the maintainer triggers once, as outlined in U-009) — or write
  an ADR documenting the env-bounded deviation analogous to ADR-010.
- Address (or document the deferral of, with reasoning) the two open
  Codex round-2 findings: the snapshot-baseline P1 reiteration and the
  `ParameterSlider` state P2.
- Resume CodeRabbit reviews (`@coderabbitai resume`) and let it review
  the final state, or document why the paused state is acceptable.
- Confirm the EQNodeTests CI flake is not a phase-3 regression
  (already true based on the main-branch failure on `4fd6b58`); re-run
  CI to clear the status check if the flake does not reproduce.

VERDICT: FAIL
