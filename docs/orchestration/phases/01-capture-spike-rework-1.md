# Phase 1 Rework 1: Audio Capture Architecture Refactor

Rework of Phase 1's capture implementation to the direct-IOProc +
`AVAudioSourceNode` architecture (ADR-018). The original Phase 1 spec
(`01-capture-spike.md`) is preserved as historical context for the V1
pattern that shipped through Phases 1–3. This rework is the unblock for
Phase 4.

## Why this exists

Phase 3's verification PASS relied on snapshot-test and code-review
evidence; live-app testing surfaced four bugs (PowerToggle indicator
never reaches "On"; effect parameter changes don't affect audio;
intermittent audio cutout; missing exit affordance — last one cosmetic,
ignored here). State.json Phase 4 `blocked_on` records the gap.

The investigation in `docs/investigations/2026-05-audio-pipeline.md`
(EXP-001 → EXP-026, FC-001 / FC-002 / FC-003) traced the audible bugs
to a single root cause: on macOS 26.3, `AVAudioEngine.inputNode` and
`outputNode` share one `kAudioUnitSubType_HALOutput` instance. Binding
the aggregate (tap-only, input-only) to the engine's input AU also
binds the engine's output to that no-output device, so the render loop
either dies on configuration change or runs nominally but never pulls
samples. Both states present to the user as silence. ADR-018 commits to
the direct-IOProc fix; this phase implements it.

## Scope

In:
- `Sources/Capture/TapIOProcReader.swift` — new class owning the tap +
  aggregate + IOProc + ring buffer (per `capture-v2.md`'s spec).
- `Sources/Capture/AudioRingBuffer.swift` — single-producer /
  single-consumer ring buffer for non-interleaved Float32.
- `Sources/Capture/CaptureController.swift` — refactor `start` and
  `stop` to use `TapIOProcReader` and attach an `AVAudioSourceNode` to
  the engine instead of binding `engine.inputNode`.
- `Sources/Capture/CoreAudioInterface.swift` — update aggregate creation
  to the working pattern (SubDeviceList=[], MasterSubDevice=0, post-set
  tap list as `CFArray<CFString>`); delete the
  `configureEngineInput` / `resetEngineInput` /
  `pinEngineOutputToDefault` methods.
- `Sources/ViewModel/AppViewModel.swift` — simplify `powerOn` and
  `powerOff` for the new flow; delete `waitForValidOutputHardwareFormat`,
  `attemptReattach`, the H4 config-change recovery branch, and all
  EXP-019/020/022/023 diagnostic helpers.
- Tests at `Tests/CaptureTests/`: ring buffer (unit), TapIOProcReader
  (unit, against a `FakeCoreAudioInterface`), CaptureController state
  machine (unit). Integration test at
  `Tests/CaptureIntegrationTests/` (gated behind
  `RUN_INTEGRATION_TESTS=1`).
- Removal of throwaway diagnostic code: `Sources/ViewModel/HFPSpike.swift`,
  `Sources/ViewModel/AudioteePatternTest.swift`,
  `MixerTapCollector` and the `runMixerTap` method in `AppViewModel`,
  and the corresponding debug-panel rows in
  `Sources/UI/DebugPanel.swift`.

Out:
- Any DSP changes. Effect graph (EQ, Reverb, EffectNode protocol) is
  unchanged.
- UI redesign. The MenuBarExtra UI is unchanged except for the removal
  of the three diagnostic rows from `DebugPanel`.
- ADR-014 mute behaviour changes. The tap still uses
  `muteBehavior = .muted`.
- Multi-source capture. V1 still captures one source at a time.
- Performance optimisation of the ring buffer beyond what the
  `OSAllocatedUnfairLock` pattern provides. True lock-free SPSC is a
  V0.2 follow-up if measured glitches warrant it.

## Reference implementations

1. **`Sources/ViewModel/AudioteePatternTest.swift` (current revision)**
   — the working aggregate creation + IOProc registration pattern.
   EXP-026 verified this fires the IOProc 471×/5s with 99.5% non-zero
   samples and peak 0.73. The aggregate-creation block (lines ~159-211)
   is the template for `TapIOProcReader.start`.
2. **`Sources/ViewModel/HFPSpike.swift`** — the SourceNode + ring buffer
   playback pattern. Its IOProc-no-fire bug was the missing aggregate
   keys (now fixed in EXP-026); the SourceNode render-callback half of
   the spike is structurally what `CaptureController.start` will
   attach. The ring buffer type in HFPSpike
   (`HFPSpikeRingBuffer`) is the template for `AudioRingBuffer`.
3. **[makeusabrew/audiotee](https://github.com/makeusabrew/audiotee)**
   — external reference, the original source of the working aggregate
   pattern. `Sources/AudioTeeCore/Core/AudioTapManager.swift` lines
   103-152.

The orchestrator does NOT copy these references verbatim. The new code
is a clean implementation informed by them, written to the
`capture-v2.md` spec.

## Tasks

### Task 1: Implement `AudioRingBuffer`

A non-interleaved Float32 single-producer / single-consumer ring buffer.
File: `Sources/Capture/AudioRingBuffer.swift`.

Public surface per `capture-v2.md` § AudioRingBuffer. V0.1
implementation may use `OSAllocatedUnfairLock` (the HFPSpike pattern).

**TDD anchors** (`Tests/CaptureTests/AudioRingBufferTests.swift`):

```
T1.1 — empty ring: read returns 0 frames, no zero-fill outside callee
T1.2 — write N, read N: identical samples returned (per-channel)
T1.3 — write 2N (capacity N): writes truncate at N, second write returns 0
T1.4 — write N, read N/2, write N/2: wraps correctly; read returns N samples
T1.5 — write N, read N+1: returns N (underrun); next read returns 0
T1.6 — multi-channel (2 ch): per-channel write/read does not cross channels
T1.7 — concurrent producer + consumer: 1s of 48 kHz × 2 ch writes
       in one thread, reads in another, no data corruption or lost frames
       (test harness uses GCD queues with serial fences for assertion)
T1.8 — zero frames: write(0) and read(0) are no-ops returning 0
```

### Task 2: Implement `TapIOProcReader`

The owner of the tap + aggregate + IOProc + ring buffer.
File: `Sources/Capture/TapIOProcReader.swift`.

Public surface per `capture-v2.md` § TapIOProcReader. The IOProc is a
file-scope `@convention(c)` function that retrieves the reader via
`Unmanaged.fromOpaque(inClientData)` and pushes samples into
`reader.ring`.

**Aggregate creation MUST follow `capture-v2.md` § "Aggregate device
dictionary — exact form" exactly:**

- `kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` ← required
- `kAudioAggregateDeviceMasterSubDeviceKey: 0` ← required
- NO `kAudioAggregateDeviceTapListKey` at creation
- NO `kAudioAggregateDeviceTapAutoStartKey`
- Tap list set after creation via `AudioObjectSetPropertyData` with
  `CFArray<CFString>` payload (UID array, not array-of-dict)

**TDD anchors** (`Tests/CaptureTests/TapIOProcReaderTests.swift`):

```
T2.1 — init resolves format from the tap's kAudioTapPropertyFormat
       (uses a FakeCoreAudioInterface that returns a known ASBD)
T2.2 — init allocates ring buffer at format's rate × 2 seconds capacity
T2.3 — start succeeds against a fake aggregate device; ioProcID is set
T2.4 — start failure (fake createAggregate throws): no leaked tap,
       no partial state; subsequent start succeeds
T2.5 — stop is idempotent: calling twice does not crash, leaves the
       reader in a fully-released state
T2.6 — IOProc callback push: feeding a fake AudioBufferList through the
       C IOProc results in ring.write being called with the right frame
       count and channel count
T2.7 — destroyTap and destroyAggregateDevice are both called by stop()
       (verified via FakeCoreAudioInterface call recording)
T2.8 — aggregate creation dictionary contains the required keys with
       the right values (verified via FakeCoreAudioInterface capturing
       the dict argument)
```

### Task 3: Refactor `CaptureController.start` and `stop`

File: `Sources/Capture/CaptureController.swift`.

New `start(source:into:)` flow:
1. Resolve `audioProcessID` from `pid` (unchanged from V1).
2. Create the tap via `coreAudio.createTap(for:)` (unchanged).
3. Construct `TapIOProcReader`.
4. Build `AVAudioSourceNode(format: reader.format) { ... }` whose render
   block pops from `reader.ring` and emits silence on underrun.
5. Attach the source node to the engine via `engine.attach(sourceNode)`.
6. Store the reader and source node as instance state for teardown.
7. Call `reader.start()`. This is the point where audio begins flowing
   into the ring.
8. Publish `.running(source:)`.

The graph wiring (sourceNode → effect chain → mainMixer) lives in
`AppViewModel.powerOn`. `CaptureController.start` does not perform
`engine.connect` calls; the view model owns the graph.

`stop()`:
1. Call `reader.stop()` (idempotent).
2. `engine.detach(sourceNode)`.
3. Destroy the tap.
4. Publish `.idle`.

**TDD anchors** (`Tests/CaptureTests/CaptureControllerTests.swift`,
extending existing tests):

```
T3.1 — start: with a fake CoreAudio that succeeds, state transitions
       idle → starting → running, the source node is attached to the
       provided engine, and engine.inputNode.audioUnit's CurrentDevice
       is unchanged (this is the load-bearing assertion vs V1)
T3.2 — start: with a fake CoreAudio that fails at createTap, state
       transitions idle → starting → failed; no leaked aggregate, no
       SourceNode attached
T3.3 — stop after start: state idle, source node detached, tap and
       aggregate destroyed
T3.4 — start → stop → start: returns to running state without leaks
T3.5 — stop while idle: no-op, no throw
T3.6 — engine.outputNode.audioUnit CurrentDevice is never set by start
       (assertion on the fake AU)
```

### Task 4: Simplify `AppViewModel`

File: `Sources/ViewModel/AppViewModel.swift`.

Delete:
- `waitForValidOutputHardwareFormat` and `outputHardwareFormatWaitTimeout`.
- `attemptReattach` method.
- The H4 detach-and-reattach branch in the `configChangeObserver`
  handler — the observer should now only log the configuration change
  for debugging.
- `logOutputAudioUnitState`, `logInputAndOutputAUIdentity`,
  `rebindOutputToSystemDefault`, `fourCCString`, and any other EXP-019
  / EXP-020 / EXP-022 / EXP-023 diagnostic helpers.
- `runMixerTap`, `performMixerTap`, `isMixerTapRunning`,
  `MixerTapCollector`.
- `runHFPSpike`, `stopHFPSpike`, `hfpSpike`, `isHFPSpikeRunning`.
- `runAudioteeTest`, `audioteeTest`, `isAudioteeTestRunning`.

`powerOn` simplifies to: resolve source → `capture.start(source:into:)`
→ wire graph (sourceNode → effect chain → mainMixer) → `engine.start()`
→ publish state.

`powerOff`: `engine.stop()` → `capture.stop()` → publish state.

**TDD anchors** (`Tests/ViewModelTests/AppViewModelTests.swift`,
extending existing tests):

```
T4.1 — powerOn against a fake capture + engine: completes synchronously
       without entering a wait loop; state transitions reach running
T4.2 — powerOn → powerOff → powerOn returns to running without leaks
T4.3 — capture.start failure surfaces as lastError = .capture(...)
T4.4 — graph mutations (addEffect, removeEffect) while running do not
       cycle the engine indefinitely; the engine returns to running
       within one detach/reattach cycle (T4.3 + T4.4 together guard
       against H4 regression in the simplified architecture)
T4.5 — engine.outputNode.audioUnit's CurrentDevice property is never
       read or set by the view model
```

### Task 5: Delete throwaway diagnostic code

Files to delete entirely:
- `Sources/ViewModel/HFPSpike.swift`
- `Sources/ViewModel/AudioteePatternTest.swift`

Files to edit:
- `Sources/UI/DebugPanel.swift`: remove `hfpSpikeRow`, `audioteeTestRow`,
  `mixerTapRow` from the panel `body`. The header + entries list
  remain.
- `Sources/Capture/CoreAudioInterface.swift`: delete
  `configureEngineInput`, `resetEngineInput`,
  `pinEngineOutputToDefault`, and `setInputUnitDevice`,
  `setOutputUnitDevice`, `defaultInputDevice` helpers. Update
  `createAggregateDevice` to use the working pattern.

### Task 6: Integration test (gated)

File: `Tests/CaptureIntegrationTests/RealTapIntegrationTests.swift`
(gated behind `RUN_INTEGRATION_TESTS=1` env var).

A real-world test that runs against an actual audio source — the
orchestrator's machine must have one process producing audio when the
test runs (e.g., a Music playback test fixture, or document the manual
setup).

```
TI.1 — TapIOProcReader against a real running process:
        after start() + 1s, ring.fill > 0 (samples have been delivered)
        within 5s, ring has received at least 1s of audio frames
        the audio is non-silent (RMS over the captured window > -60 dBFS)
TI.2 — start → stop → start → stop: both starts deliver audio; both
        stops cleanly release resources (verified by checking the HAL's
        process tap count via system tooling, or by ensuring a second
        run succeeds after a first run's resources were claimed)
```

The integration test produces an artifact wav at
`test-artifacts/phase-1-rework-1-passthrough.wav` so the verification
subagent can run an RMS level check (same pattern as Phase 1's original
gate criterion 2).

## Gate criteria

Phase 1 rework PASSES when the verification subagent confirms:

1. **ADR-018 exists and is Accepted.** File at
   `docs/decisions/ADR-018-direct-ioproc-capture-architecture.md`,
   status line "Accepted".
2. **`capture-v2.md` exists** at `docs/specs/capture-v2.md` and is
   referenced from ADR-018 and from this phase spec.
3. **`capture.md` is marked superseded.** First section of
   `docs/specs/capture.md` contains a status banner pointing to
   `capture-v2.md` and ADR-018.
4. **`AudioRingBuffer` exists** at
   `Sources/Capture/AudioRingBuffer.swift` with the public surface from
   `capture-v2.md` § AudioRingBuffer. All T1.* tests pass.
5. **`TapIOProcReader` exists** at
   `Sources/Capture/TapIOProcReader.swift`. The aggregate-creation
   dictionary includes `kAudioAggregateDeviceSubDeviceListKey: [] as
   CFArray` and `kAudioAggregateDeviceMasterSubDeviceKey: 0` and does
   NOT include `kAudioAggregateDeviceTapListKey` at creation. The tap
   list is set via `AudioObjectSetPropertyData` after creation with
   `CFArray<CFString>` payload. All T2.* tests pass.
6. **`CaptureController.start` does not call `setProperty` on any AU
   the engine created.** Verified by code inspection of
   `Sources/Capture/CaptureController.swift` and
   `Sources/Capture/CoreAudioInterface.swift`. The methods
   `configureEngineInput`, `resetEngineInput`, and
   `pinEngineOutputToDefault` are deleted. All T3.* tests pass.
7. **`AppViewModel` no longer contains** `waitForValidOutputHardware-
   Format`, `attemptReattach`, `logOutputAudioUnitState`,
   `logInputAndOutputAUIdentity`, `rebindOutputToSystemDefault`,
   `fourCCString`, `runMixerTap`, `performMixerTap`,
   `MixerTapCollector`, `runHFPSpike`, `stopHFPSpike`,
   `runAudioteeTest`, `isAudioteeTestRunning`. Verified by grep on the
   file. All T4.* tests pass.
8. **Throwaway diagnostic files deleted.** `git ls-files | grep -E
   'HFPSpike|AudioteePatternTest'` returns nothing. `DebugPanel.swift`
   does not contain `hfpSpikeRow`, `audioteeTestRow`, or
   `mixerTapRow`.
9. **Integration test artifact exists.** When
   `RUN_INTEGRATION_TESTS=1` is set,
   `test-artifacts/phase-1-rework-1-passthrough.wav` is produced by
   `TI.1`. RMS check on the wav over its 5-second window >
   -60 dBFS confirms non-silent audio. The orchestrator's run
   transcript is recorded under
   `docs/audits/verification/phase-1-rework-1-passthrough.md`.
   (Same accepted-deviation pattern as Phase 1's original gate 2 if
   the live-render step cannot be run autonomously: documented
   deviation with the code path in place.)
10. **All unit tests pass.** `swift test --skip-integration` returns 0
    (or equivalent; `RUN_INTEGRATION_TESTS=1` not set).
11. **The app builds clean.** `./Build/bundle-dev.sh` returns 0 and
    produces a signed `Build/tap-n-filter.app`.
12. **Existing Phase 2 / Phase 3 tests still pass.** The Effect graph
    (EQ, Reverb), preset save/load, UI snapshot tests are not
    regressed.
13. **CodeRabbit and Codex have reviewed the PR.** Any high-severity
    findings are addressed (per `docs/governance/review-protocol.md`).
14. **`state.json`** has Phase 1 status `passed` (the rework
    completes; Phase 1's overall state goes back to `passed`), and the
    `verification_report` field points to
    `docs/audits/verification/phase-1-rework-1.md`. Phase 4's
    `blocked_on` is cleared (set to null) since the live-app bugs
    are now fixed.

## Failure modes

- **Integration test can't run** (no real audio source available
  during orchestrator's autonomous run): record an accepted-deviation
  in the verification report, same pattern as the original Phase 1's
  `phase-1-passthrough-test-needs-interactive` resolution.
- **IOProc fires but ring stays empty**: capture is broken at the
  tap-aggregate level despite the working pattern. Investigate via
  source-grounded logging in the IOProc callback (frame count, channel
  count per fire); the working pattern from EXP-026 returned 471 fires
  in 5s, so any large deviation is a regression vs the proven pattern.
- **SourceNode render callback emits sustained silence** (ring stays
  empty during normal capture): the IOProc isn't delivering. Check the
  aggregate device's stream count post-creation (should be input=1,
  output=0). Check the tap's UID is correctly attached.
- **Live-app testing surfaces a new bug** during the autonomous run:
  surface an `[ESCALATION: <topic>]` halt marker per the orchestrator
  guidelines in CLAUDE.md.

## Outputs

- `docs/decisions/ADR-018-direct-ioproc-capture-architecture.md`
  (already exists in source control; verify status = Accepted).
- `docs/specs/capture-v2.md` (already exists; verify gate criterion 2).
- `docs/specs/capture.md` (banner edit; verify gate criterion 3).
- `Sources/Capture/AudioRingBuffer.swift` (new).
- `Sources/Capture/TapIOProcReader.swift` (new).
- `Sources/Capture/CaptureController.swift` (refactored).
- `Sources/Capture/CoreAudioInterface.swift` (refactored — methods
  deleted, aggregate creation updated; kept as the wrapper protocol
  for HAL functions so tests can still mock).
- `Sources/ViewModel/AppViewModel.swift` (simplified).
- `Sources/UI/DebugPanel.swift` (diagnostic rows removed).
- Deletions: `Sources/ViewModel/HFPSpike.swift`,
  `Sources/ViewModel/AudioteePatternTest.swift`.
- New tests under `Tests/CaptureTests/`: `AudioRingBufferTests.swift`,
  `TapIOProcReaderTests.swift`, extensions to
  `CaptureControllerTests.swift` and `AppViewModelTests.swift`.
- Integration test under `Tests/CaptureIntegrationTests/`:
  `RealTapIntegrationTests.swift`.
- `test-artifacts/phase-1-rework-1-passthrough.wav` (gitignored).
- `docs/audits/verification/phase-1-rework-1.md` — verification report.
- `docs/orchestration/state.json` — Phase 1 status returned to
  `passed` with `verification_report` pointing to the rework report;
  Phase 4 `blocked_on` cleared.
- PR titled `phase-1-rework-1: audio capture architecture refactor`,
  merged after CodeRabbit + Codex review + verification PASS.

## References

- ADR-018 — architectural decision.
- `docs/specs/capture-v2.md` — technical specification.
- `docs/investigations/2026-05-audio-pipeline.md` — full investigation
  trail (EXP-001 → EXP-026, FC-001/FC-002/FC-003, hypothesis ledger).
- `docs/orchestration/phases/01-capture-spike.md` — original Phase 1
  spec (historical context).
- `docs/governance/verification-protocol.md` — verification subagent
  protocol for the gate.
- `docs/governance/review-protocol.md` — CodeRabbit + Codex PR review
  flow.
- `docs/governance/coding-standards.md` — Swift style for new code.
