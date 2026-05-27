# Capture v2

The capture layer's technical specification under ADR-018. Replaces
`docs/specs/capture.md` for V0.1 onward; the older spec is retained as
historical context for Phase 1's original implementation.

## Architecture

```
   Source app (Safari, Music, ...)
            │
            │ produces audio (muted at OS level per ADR-014)
            ▼
   ┌──────────────────────────┐
   │  CATap (process tap)     │
   │  AudioHardwareCreate-    │
   │  ProcessTap              │
   └──────────────┬───────────┘
                  │
                  ▼
   ┌──────────────────────────┐
   │  Aggregate device        │
   │  SubDeviceList: []       │
   │  MasterSubDevice: 0      │
   │  (tap added post-create) │
   └──────────────┬───────────┘
                  │ AudioDeviceCreateIOProcID
                  │ + AudioDeviceStart
                  ▼
   ┌──────────────────────────┐
   │  C @convention(c) IOProc │     RING BUFFER
   │  pushes Float32 frames   │────▶ (lock-free or
   │  into a ring buffer      │      single-lock SPSC)
   └──────────────────────────┘            │
                                            │
                                            ▼
                              ┌─────────────────────────┐
                              │  AVAudioSourceNode      │
                              │  render callback pops   │
                              │  frames from ring; on   │
                              │  underrun writes silence│
                              └─────────────┬───────────┘
                                            │
                                            ▼
                                     effect graph
                                            │
                                            ▼
                                     mainMixerNode
                                            │
                                            ▼
                              outputNode (system default,
                              never re-bound)
```

Two key invariants:

1. **The engine's `inputNode` is never touched.** No
   `kAudioOutputUnitProperty_CurrentDevice` set on any AU the engine
   created. This avoids the macOS 26.3 unified-IO-AU failure mode
   documented in ADR-018.
2. **The IOProc and the SourceNode are decoupled.** Push side (IOProc)
   and pull side (SourceNode) communicate only through the ring buffer.
   The engine can reconfigure or transiently stop without stalling the
   tap, and tap startup gaps appear to the engine as brief silence
   (handled by the SourceNode's underrun path).

## Public surface

```swift
public protocol CaptureControllerProtocol: AnyObject {
    var state: CaptureState { get }
    var statePublisher: AnyPublisher<CaptureState, Never> { get }

    /// List applications currently producing audio that can be captured.
    func availableSources() throws -> [CaptureSource]

    /// Begin capturing from the given source, attaching the capture
    /// reader into the provided engine via an AVAudioSourceNode. The
    /// engine's inputNode is NOT touched; outputNode stays on the
    /// system default.
    func start(source: CaptureSource, into engine: AVAudioEngine) throws

    /// Stop the current capture. Tears down the IOProc, destroys the
    /// aggregate, destroys the tap, detaches the SourceNode.
    func stop() throws
}
```

The `CaptureSource`, `CaptureState`, and `CaptureError` types remain
unchanged from v1 (`docs/specs/capture.md`).

`CaptureControllerProtocol.start`'s contract changes:

| v1 (old)                                          | v2 (new)                                                    |
|---------------------------------------------------|-------------------------------------------------------------|
| Re-binds `engine.inputNode`'s AU to the aggregate | Attaches an `AVAudioSourceNode` to the engine               |
| Engine's outputNode AU may be re-bound implicitly | Engine's outputNode stays on system default                 |
| Audio flows: tap → engine inputNode → graph       | Audio flows: tap → IOProc → ring → SourceNode → graph       |
| Underrun = engine stall                           | Underrun = SourceNode emits silence; engine keeps running   |

## Internals

### TapIOProcReader

A new type (in `Sources/Capture/` alongside `CoreAudioInterface.swift`)
that owns the tap + aggregate + IOProc + ring buffer.

```swift
public final class TapIOProcReader {
    /// Resolved tap stream format (sample rate, channel count, layout).
    public var format: AVAudioFormat { get }

    /// The lock-protected (or lock-free) ring buffer the IOProc writes
    /// to and the SourceNode reads from. Public so the source node's
    /// render block can capture it weakly.
    public let ring: AudioRingBuffer

    /// Initialise against a process tap. Resolves the tap's format and
    /// allocates the ring buffer (capacity: 2 seconds at tap rate).
    public init(audioProcessID: AudioObjectID,
                coreAudio: CoreAudioInterface) throws

    /// Create the aggregate device wrapping the tap (with the required
    /// SubDeviceList + MasterSubDevice keys; tap list set after
    /// creation as CFArray<CFString>), register the IOProc, start it.
    /// Returns when the IOProc has been registered; first IOProc
    /// invocation may not have happened yet.
    public func start() throws

    /// Stop the IOProc, destroy the IOProc ID, destroy the aggregate,
    /// destroy the tap. Idempotent; safe to call from any state.
    public func stop()
}
```

The IOProc is a file-scope `@convention(c)` function. It retrieves the
reader instance via `Unmanaged.fromOpaque(inClientData)` and pushes the
delivered samples into `reader.ring`. The reader holds a strong
reference to the IOProc closure; the lifetime invariant is "reader
outlives all IOProc invocations" — enforced by `stop()` always calling
`AudioDeviceStop` before any deallocation.

### AudioRingBuffer

Single-producer (IOProc) / single-consumer (SourceNode) ring buffer.

```swift
public final class AudioRingBuffer {
    public let channelCount: Int
    public let capacity: Int  // frames per channel

    public init(channelCount: Int, capacity: Int)

    /// Producer side. Writes up to `frames` frames of `sources` into
    /// the ring. Returns the number actually written (less than
    /// `frames` if the ring would overflow). Real-time safe.
    public func write(from sources: [UnsafePointer<Float>],
                      frames: Int) -> Int

    /// Consumer side. Reads up to `frames` frames into `dests`. Returns
    /// the number actually read (less than `frames` on underrun;
    /// caller zero-fills the tail and reports silence). Real-time safe.
    public func read(into dests: [UnsafeMutablePointer<Float>],
                     frames: Int) -> Int
}
```

V0.1 implementation MAY use a single `OSAllocatedUnfairLock` (the
HFPSpike pattern, proven real-time-safe enough for the
audibility test). V0.2 may upgrade to true lock-free SPSC if measured
glitches require it.

Implementation contract:

- `write` is the only call site that advances the writer (head) pointer.
- `read` is the only call site that advances the reader (tail) pointer.
- Both functions are non-blocking and bounded; no allocation, no
  unbounded loops, no system calls inside the lock.
- Non-interleaved Float32 layout (one `UnsafePointer<Float>` per
  channel) matches AVAudioEngine's standard internal format.

### CaptureController.start (new flow)

```swift
public func start(source: CaptureSource, into engine: AVAudioEngine) throws {
    // 1. Resolve audioProcessID, create tap, get UID — same as v1.
    let tapID = try coreAudio.createTap(for: source.audioProcessID)
    let uid = try coreAudio.tapUID(for: tapID)

    // 2. Build TapIOProcReader.
    let reader = try TapIOProcReader(
        audioProcessID: source.audioProcessID,
        coreAudio: coreAudio
    )
    self.reader = reader

    // 3. Attach an AVAudioSourceNode to the engine. Uses
    //    `reader.format` so the engine graph runs at the tap's rate.
    let format = reader.format
    let ring = reader.ring
    let sourceNode = AVAudioSourceNode(format: format) {
        [weak ring] isSilence, _, frameCount, audioBufferList in
        return renderFromRing(
            ring: ring,
            isSilence: isSilence,
            frameCount: frameCount,
            audioBufferList: audioBufferList,
            channelCount: Int(format.channelCount)
        )
    }
    engine.attach(sourceNode)
    self.sourceNode = sourceNode

    // 4. Start the IOProc. After this point audio is pumping into the
    //    ring; the engine graph will start consuming once the source
    //    node is connected and the engine is started.
    try reader.start()

    // 5. Publish state transition.
    subject.send(.running(source: source))
}
```

The graph wiring (sourceNode → effect chain → mainMixer) is performed
by `AppViewModel.powerOn` after `capture.start` returns, identical in
shape to V1's wiring but with `sourceNode` substituted for
`engine.inputNode` as the chain head.

### What goes away

The new architecture removes the following from V1:

1. **`CoreAudioInterface.configureEngineInput`** — re-binds the engine's
   input AU. Deleted.
2. **`CoreAudioInterface.resetEngineInput`** — undoes (1). Deleted.
3. **`CoreAudioInterface.pinEngineOutputToDefault`** — the abandoned
   fix for output-side mis-binding. Deleted (the new architecture
   never re-binds the output side either).
4. **`AppViewModel.waitForValidOutputHardwareFormat`** — the poll loop
   that waited for outputNode to settle on a valid format. Deleted;
   outputNode stays on the system default which is always settled.
5. **`AppViewModel.attemptReattach`** (H4 recovery) — handled engine
   self-stop on configuration change. Deleted; the new architecture
   tolerates engine reconfigurations without stalling capture, so the
   recovery path is no longer load-bearing.
6. The `AVAudioEngineConfigurationChange` observer in `AppViewModel`
   simplifies to a logging-only handler. The detach + reattach branches
   are removed.
7. All EXP-019 / EXP-020 / EXP-022 / EXP-023 diagnostic helpers in
   `AppViewModel`.
8. **`Sources/ViewModel/HFPSpike.swift`** — its job was to validate this
   architecture; now done. Deleted.
9. **`Sources/ViewModel/AudioteePatternTest.swift`** — same; deleted.
   (Its aggregate creation code is the template for `TapIOProcReader`.)
10. **`Sources/ViewModel/MixerTapCollector`** — diagnostic for EXP-024;
    deleted with the rest of the diagnostic code.

The `Build/tap-n-filter.app` debug panel rows for HFP spike, Audiotee
test, and Mixer tap go away with their corresponding code.

## Aggregate device dictionary — exact form

The aggregate must be created with **exactly** these keys at creation
time:

```swift
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "tap-n-filter for \(displayName)",
    kAudioAggregateDeviceUIDKey: "tap-n-filter.aggregate.\(sourcePID).\(UUID().uuidString)",
    kAudioAggregateDeviceSubDeviceListKey: [] as CFArray,
    kAudioAggregateDeviceMasterSubDeviceKey: 0,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
]
```

**Do NOT** include `kAudioAggregateDeviceTapListKey` in the creation
dictionary. **Do NOT** include `kAudioAggregateDeviceTapAutoStartKey`.
These were present in HFPSpike's broken pattern; removing them is
load-bearing.

After `AudioHardwareCreateAggregateDevice` returns success, set the tap
list as a separate property write:

```swift
let tapArray = [tapUID] as CFArray  // ONE-element array of CFString
var address = AudioObjectPropertyAddress(
    mSelector: kAudioAggregateDevicePropertyTapList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
let status = withUnsafePointer(to: tapArray) { ptr in
    AudioObjectSetPropertyData(
        aggregateID, &address, 0, nil,
        UInt32(MemoryLayout<CFArray>.stride), ptr
    )
}
```

The payload is `CFArray<CFString>` (array of UID strings), **NOT**
`CFArray<CFDictionary>` (array of `{kAudioSubTapUIDKey: ..., kAudioSubTapDriftCompensationKey: ...}`).
The array-of-dict form is for the embedded-creation path and does not
work with the post-set path.

This pattern is verified working in EXP-026 (471 IOProc fires in 5s,
99.5% non-zero samples, peak 0.73) and mirrors audiotee's working
implementation byte-for-byte.

## Tap mute behaviour

Unchanged from ADR-014. The tap is still created with
`description.muteBehavior = .muted`. The user model is unchanged:
power on = source muted at OS level + processed audio plays through
the chain; power off = source unmutes and plays normally.

## Failure modes

- **AudioDeviceStart returns non-zero** (e.g., 'nope' /
  `kAudioHardwareIllegalOperationError`): aggregate is malformed.
  Surface as `CaptureError.aggregateDeviceCreationFailed(status)`.
- **IOProc fires but ring stays empty**: the tap delivers but the
  ring write is failing. Inspect `sources.count` and `frames` in the
  IOProc callback. Should not happen with the verified aggregate
  pattern.
- **SourceNode render callback fires but ring is empty (underrun)**:
  brief underrun (< ~200 ms) on capture startup is acceptable — silence
  for a few ms before the IOProc catches up. Sustained underrun means
  the tap stopped delivering; capture should transition to
  `.failed(.engineConfigurationFailed("sustained underrun"))`.
- **Aggregate device disappears mid-capture** (BT disconnect, source
  app killed): IOProc stops firing, ring drains, SourceNode underruns,
  surface a clear error in the UI. V0.1 acceptable: stop the engine,
  transition to `.failed`. (Identical to v1's behaviour.)
- **TCC denied**: same handling as v1 — `CaptureError.permissionDenied`,
  UI surfaces the System Settings deep-link.

## Tests

See `docs/orchestration/phases/01-capture-spike-rework-1.md` Tasks
section for the full TDD anchor list. Summary:

- Unit tests for `AudioRingBuffer` (write/read identity, overrun,
  underrun, wrap-around, multi-channel).
- Unit tests for `TapIOProcReader`'s lifecycle (start/stop idempotence,
  resource cleanup, error paths) against a `FakeCoreAudioInterface`.
- Integration test (gated behind `RUN_INTEGRATION_TESTS=1`): real tap on
  a known source, real ring write, real SourceNode read, assert
  non-zero RMS over a 5-second window.
- Live verification (human-driven): see phase spec gate criteria.

## References

- ADR-018 — the WHY (architectural decision).
- `docs/orchestration/phases/01-capture-spike-rework-1.md` — the HOW
  (implementation plan + TDD anchors + gate criteria).
- `docs/investigations/2026-05-audio-pipeline.md` — EXP-023 / EXP-024 /
  EXP-025 / EXP-026, FC-003.
- `docs/specs/capture.md` — original v1 spec (superseded for V0.1; kept
  as historical context for Phase 1's verification PASS).
- `Sources/ViewModel/AudioteePatternTest.swift` — current reference
  implementation of the aggregate pattern; to be deleted when this
  spec's implementation lands.
- ADR-014 — tap mute behaviour (unchanged).
- ADR-001 — Core Audio Process Taps as the capture API (unchanged).
