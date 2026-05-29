# ADR-018: Direct IOProc Capture Architecture

## Status

Accepted (2026-05-27). Supersedes the AVAudioEngine.inputNode binding pattern
introduced in Phase 1 (ADR-001 + `docs/specs/capture.md`).

## Context

Phase 1's capture implementation followed the
[insidegui/AudioCap](https://github.com/insidegui/AudioCap) reference: create
a `CATapDescription` per source process, wrap the tap in an aggregate device,
and bind that aggregate to `AVAudioEngine.inputNode` by setting
`kAudioOutputUnitProperty_CurrentDevice` on the input AU. The engine's
`inputNode` then reads from the aggregate, the effect graph processes the
audio, and `outputNode` plays it to the user's default output device. This
shipped through Phase 1, 2, and 3, with verification PASS at each gate.

On macOS 26.3 (Tahoe, current build target), live testing surfaced bugs that
the snapshot-test-based verification couldn't see (`state.json` Phase 4
`blocked_on`): the PowerToggle indicator never reaches "On"; effect
parameter changes are inaudible; audio cuts out entirely on Bluetooth; the
HFP route switch interferes with the chain. A focused investigation
(`docs/investigations/2026-05-audio-pipeline.md`, EXP-001 through EXP-026)
established the root cause:

- **EXP-023** (source-grounded): on macOS 26.3,
  `AVAudioEngine.inputNode.audioUnit === AVAudioEngine.outputNode.audioUnit`
  by pointer equality. The engine wires both nodes through one
  `kAudioUnitSubType_HALOutput` instance ("unified IO AU"). On earlier macOS
  versions, output went through `kAudioUnitSubType_DefaultOutput`, a
  separate AU. The unified AU has a single `CurrentDevice` property.
- **Consequence**: setting `CurrentDevice` for *input* (to the tap
  aggregate) also sets it for *output*. The tap aggregate has no output
  streams (a process tap is input-only). Output writes silently go to a
  device that can't play.
- **EXP-024** (source-grounded): with the engine in this state, a tap on
  `mainMixerNode` records *zero buffers* in 5 seconds — the pull-driven
  render loop never asks the mixer for samples because outputNode's IOProc
  isn't running.
- **EXP-025** (source-grounded): the HFP route switch triggers an
  `AVAudioEngineConfigurationChange` with `engine.isRunning = false`. The
  H4 recovery handler runs but `attemptReattach` silently fails to restore
  the engine. Both input and mixer taps record zero buffers.
- **FC-003 frame shift**: AVAudioEngine.inputNode + tap aggregate is
  structurally incompatible with macOS 26.3's unified IO AU. No recovery
  logic patches what is structurally broken.
- **EXP-026** (source-grounded): direct IOProc on the tap aggregate
  *works* inside our app — 471 IOProc fires in 5s, 99.5% non-zero samples,
  peak 0.73. The aggregate must include the keys
  `kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
  `kAudioAggregateDeviceMasterSubDeviceKey: 0`, with the tap list set
  *after* creation as `CFArray<CFString>`. Audiotee uses this pattern;
  earlier HFPSpike/AudioteePatternTest attempts missed those keys.

The architectural fix Codex recommended at the start of the investigation
is now empirically validated.

## Decision

V0.1 capture uses **direct IOProc on the tap aggregate** feeding an
**AVAudioSourceNode** in the engine. `AVAudioEngine.inputNode` is never
touched; the engine's `outputNode` is never re-bound away from the system
default output device.

Concretely:

1. Create a per-process tap with `AudioHardwareCreateProcessTap`
   (`muteBehavior = .mutedWhenTapped` — ADR-014 as amended 2026-05-29;
   `.muted` makes `AudioDeviceStart` fail on this path, EXP-027).
2. Create an aggregate device wrapping the tap with these dictionary keys:
   - `kAudioAggregateDeviceNameKey`, `kAudioAggregateDeviceUIDKey`
   - `kAudioAggregateDeviceIsPrivateKey: true`
   - `kAudioAggregateDeviceIsStackedKey: false`
   - **`kAudioAggregateDeviceSubDeviceListKey: [] as CFArray`** (required;
     empty array but key must be present)
   - **`kAudioAggregateDeviceMasterSubDeviceKey: 0`** (required)
   - **No** `kAudioAggregateDeviceTapListKey` and **no**
     `kAudioAggregateDeviceTapAutoStartKey` at creation.
3. Set the tap list *after* creation via `AudioObjectSetPropertyData` on
   `kAudioAggregateDevicePropertyTapList`, with the payload as
   `CFArray<CFString>` containing the tap's UID (not array-of-dict).
4. Register an IOProc via `AudioDeviceCreateIOProcID` with a
   `@convention(c)` C function pointer that pushes deinterleaved Float32
   samples into a lock-free SPSC ring buffer.
5. Start the IOProc with `AudioDeviceStart`.
6. The `AVAudioEngine` has only output wiring: `AVAudioSourceNode` (which
   pops from the ring buffer) → effect graph → `mainMixerNode` →
   `outputNode`. The engine's `inputNode` is unreferenced; the engine
   never calls `setProperty(kAudioOutputUnitProperty_CurrentDevice, ...)`.

The effect graph and the AVAudioEngine output path are unchanged from
V0.1's prior shape. The tap mute behaviour did change: this path requires
`.mutedWhenTapped` rather than ADR-014's original `.muted` (EXP-027 found
`.muted` makes `AudioDeviceStart` fail here). ADR-014 is amended to match.

## Alternatives considered

### Stay with AVAudioEngine.inputNode binding + tap aggregate

Rejected. FC-003 documents three independent failure paths (EXP-024,
EXP-025, EXP-025 first attempt) that all converge on user-perceived
silence. No combination of recovery logic patches a structurally broken
unified IO AU configuration on macOS 26.3.

### Two-engine pattern

One AVAudioEngine bound to the aggregate via inputNode (capture only, no
output graph wired), a second AVAudioEngine for playback. Buffers shuttled
across via a ring buffer. Rejected because the first engine still binds
inputNode to the aggregate, which still triggers the unified-IO-AU
failure paths. We'd add machinery without removing the root cause.

### Custom HAL Output AU graph (no AVAudioEngine)

Build the entire chain as a raw AUHAL graph: HALOutput input scope →
mixer → HALOutput output scope, all manually wired. Rejected for V0.1
as ~2× the LoC and a much larger change to the EffectNode protocol's
integration with mixer-based gain control. Worth revisiting in V0.2 if
AVAudioEngine continues to misbehave on future macOS versions.

### HAL plugin (Rogue Amoeba ARK pattern)

Install a virtual audio device as a HAL plugin (kernel-adjacent), route
system audio through it, read from it. Rejected for V0.1 — requires kext
or DriverKit, a fundamentally different distribution model, and full
disk access entitlements. Out of scope for a menubar app.

### Wait for Apple to fix the macOS 26.3 unified-AU semantics

Rejected as a passive choice. We don't know if/when Apple will revert.
Shipping V0.1 against current macOS is more useful than waiting.

## Consequences

**Enabled:**

- AVAudioEngine output stays on the user's default output device. No HFP
  trigger on Bluetooth; BT stays in A2DP at 44.1 kHz × 2 ch with effects
  audibly applied.
- The IOProc is push-driven by the tap device's clock, independent of
  the engine's render pull. Decoupling means engine reconfigurations
  don't stall capture and tap events don't stall the engine.
- `AVAudioEngineConfigurationChange` recovery is no longer load-bearing.
  The H4 detach + `attemptReattach` complexity in `AppViewModel` can be
  removed; if the engine reconfigures, the SourceNode keeps draining
  the ring buffer.
- Effect parameter changes are audible because the chain actually
  renders frames (the pull chain works once outputNode is on a real
  output device).

**Precluded or constrained:**

- The capture layer now owns three real-time-sensitive components: the
  IOProc (push side), the ring buffer (SPSC), and the SourceNode render
  callback (pull side). The buffer must be lock-free or use minimal
  locking; the SourceNode callback must not allocate or block.
- Underrun handling moves into the SourceNode callback: when the ring
  buffer is empty, the callback writes silence and sets the `isSilence`
  out-parameter. Brief underruns are acceptable on startup; sustained
  underrun means a tap pump problem.
- The Capture layer's API gains a "format" concept — the tap delivers
  samples at the tap's rate (usually 44.1 kHz × 2 ch), and the engine's
  graph runs at the SourceNode's declared format (same as the tap).
  Format negotiation lives in `TapIOProcReader`, not in the engine.

**Risks:**

- The lock-free SPSC ring buffer is real-time code; bugs in it are
  audible (clicks, dropouts). We mitigate by starting with a simple
  `OSAllocatedUnfairLock`-protected version (sufficient per
  HFPSpike's experience) and only optimizing to true lock-free SPSC if
  measured audio glitches require it.
- The C `@convention(c)` IOProc pointer can't capture Swift state. We
  pass the reader instance via `Unmanaged.passUnretained(self).toOpaque()`
  through `inClientData`. The reader must outlive every IOProc
  invocation; teardown must `AudioDeviceStop` before deallocating.

## References

- `docs/investigations/2026-05-audio-pipeline.md` — EXP-023, EXP-024,
  EXP-025, EXP-026, FC-003.
- `docs/specs/capture-v2.md` — the technical specification of the new
  architecture (the WHAT this ADR enables).
- `docs/orchestration/phases/01-capture-spike-rework-1.md` — the
  implementation plan + TDD anchors + gate criteria (the HOW).
- `Sources/ViewModel/AudioteePatternTest.swift` (current revision) —
  reference implementation of the aggregate-creation pattern proven to
  work in EXP-026. To be removed when this ADR's implementation lands.
- ADR-001 — original capture API decision (Core Audio Process Taps);
  this ADR supplements rather than supersedes ADR-001's API choice.
- ADR-014 — mute behaviour for the source process; **amended** by this
  architecture: `.muted` → `.mutedWhenTapped` (EXP-027).
- [makeusabrew/audiotee](https://github.com/makeusabrew/audiotee)
  `Sources/AudioTeeCore/Core/AudioTapManager.swift` lines 103-152 —
  the working aggregate creation + tap attachment reference pattern.
